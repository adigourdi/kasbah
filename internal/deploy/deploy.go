// Package deploy is the working-tree `kasbah deploy` and, on the server,
// `kasbah remote deploy`, the engine running step 8's fixed order
// (docs/build-deploy.md). The fragment ships only after the engine's report.
package deploy

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/release"
	"github.com/adigourdi/kasbah/internal/state"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the working-tree deploy's arguments. A VERSION argument is the
// tagged path, which is not this package's.
type Options struct {
	Target, OnDrift                       string
	SkipHooks, NoHealthWait, AllowStopped bool
}

const usage = `Usage: kasbah deploy [USER@HOST] [VERSION] [--on-drift=setup|continue|abort]
                     [--skip-hooks] [--no-health-wait] [--allow-stopped]

Ships the working tree to a prepared server and brings the project up there.
Run from the project root. The version is HEAD's v-tag; USER@HOST defaults to
the last server this project deployed to (.kasbah/state.json).

With a VERSION, it ships that tag instead — every file out of ` + "`git archive\nv<VERSION>`" + `, the working tree neither read nor touched. That is the rollback
path with a ` + "`deploy`" + ` log entry and the pre-/post-deploy hooks, and it is
allowed to be the first time that version reaches this server.
An argument containing '@' is the server, anything else is the version.

What it does:
  * rsyncs every path in the manifest's sync: list to <apps>/<name>/
  * renders <apps>/<name>/.env when it is missing, checks it for drift against
    .env.prod.example otherwise, and refreshes the KASBAH_* block in it from
    the server marker's resource limits
  * runs ` + "`kasbah remote deploy`" + ` on the server: backup, pre-deploy hooks,
    retag <image>:current, docker compose -p <name> up -d --remove-orphans,
    health wait, post-deploy hooks, one versions.log entry
  * rsyncs traefik-dynamic.yml to <apps>/traefik/dynamic/<name>.yml, last
  * prints the commits between the version the server was running and this one

Flags:
  --on-drift=setup      re-run the interactive setup when .env has drifted
  --on-drift=continue   deploy against the .env as it stands
  --on-drift=abort      stop, changing nothing
Unset, a drifting .env asks; with no terminal to ask on, the run stops (exit 5).

For the server's side of the run:
  --skip-hooks          skip the pre- and post-deploy hooks. The backup still
                        runs — a dry-run-ish deploy must not also throw away
                        the data safety net
  --no-health-wait      bring the stack up without blocking on its health
  --allow-stopped       deploy over a stack that has deployed here before and
                        is not running, which is otherwise refused. Each step
                        whose own container is down is then skipped — the backup
                        if that is backup.container, a pre-deploy hook if it is
                        that hook's — and the run says which

See docs/build-deploy.md and docs/env-template.md.
`

// Usage is `kasbah deploy --help`.
func Usage() string { return usage }

// Tagged reports whether args name a VERSION — the tagged path, still the
// Bash tool's: any argument that is neither a flag nor a server.
func Tagged(args []string) bool {
	for _, a := range args {
		if !strings.HasPrefix(a, "-") && !strings.Contains(a, "@") {
			return true
		}
	}
	return false
}

// Parse reads the working-tree deploy's arguments.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--skip-hooks":
			o.SkipHooks = true
		case a == "--no-health-wait":
			o.NoHealthWait = true
		case a == "--allow-stopped":
			o.AllowStopped = true
		case strings.HasPrefix(a, "--skip-hooks=") || strings.HasPrefix(a, "--no-health-wait=") || strings.HasPrefix(a, "--allow-stopped="):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("deploy: %s takes no value — pass it on its own (`kasbah deploy USER@HOST %s`)", name, name)
		case strings.HasPrefix(a, "--on-drift="):
			o.OnDrift = strings.TrimSuffix(strings.TrimPrefix(a, "--on-drift="), "\r")
			if err := env.CheckOnDrift("deploy", o.OnDrift); err != nil {
				return o, err
			}
		case a == "--on-drift":
			return o, cli.Fail("deploy: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort")
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("deploy: unknown flag '%s' (deploy takes USER@HOST, VERSION, --on-drift=, --skip-hooks, --no-health-wait and --allow-stopped)", name)
		case o.Target != "":
			return o, cli.Fail("deploy: two servers given ('%s' and '%s') — one run goes to one server", o.Target, strings.TrimSuffix(a, "\r"))
		default:
			o.Target = strings.TrimSuffix(a, "\r")
		}
	}
	return o, nil
}

// Server is one server as a deploy needs it: the env step's session plus the
// deploy's own calls (session.go).
type Server interface {
	env.Session
	PrepareProject(apps, data, name, client string, parents []string) (string, error)
	Sync(e Entry, base string) error
	Mail(apps string) (*MailFacts, error)
	Seed(target string, data []byte) (string, error)
	Run(dir string, sp Spec) (stdout string, rc int)
	Fragment(local, dest string) error
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out           *cli.Output
	Prompter      *prompt.Prompter
	PWD           string
	Version       string
	TTYIn, TTYOut bool
	Color         bool
	Dial          func(target string) (Server, error)
	Now           func() time.Time
}

// Fragment is the project's Traefik file; kasbah owns where it lands.
const Fragment = "traefik-dynamic.yml"

type run struct {
	c       Ctx
	o       Options
	m       *manifest.Manifest
	p       *Plan
	s       Server
	mk      *marker.Marker
	target  string
	version string
	dir     string
}

// Run is the command.
func Run(c Ctx, o Options) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	r := &run{c: c, o: o, m: m, target: o.Target}
	if r.target == "" {
		stored, err := state.Get(state.File, "last_server")
		if err != nil {
			return err
		}
		if stored == "" || stored == "null" {
			return cli.Fail("deploy: no server given, and this project has never deployed to one").Cont(
				"pass it once — `kasbah deploy user@vps` — and it is remembered in",
				state.File+" as last_server")
		}
		r.target = stored
	}
	if r.version, err = release.Resolve(c.PWD); err != nil {
		return err
	}
	if r.p, err = ReadPlan(m, c.PWD, r.version); err != nil {
		return err
	}

	if r.s, err = c.Dial(r.target); err != nil {
		return err
	}
	defer r.s.Close()
	if r.mk, err = r.s.Marker(); err != nil {
		return err
	}
	r.dir = r.mk.AppsPath + "/" + m.Name

	claim, err := r.readClaim()
	if err != nil {
		return err
	}
	clientState, err := r.s.PrepareProject(r.mk.AppsPath, r.mk.DataPath, m.Name, r.p.Client, RemoteParents(r.dir, r.p.Sync))
	if err != nil {
		return err
	}
	for _, e := range r.p.Sync {
		if err := r.s.Sync(e, r.dir); err != nil {
			return err
		}
	}
	// After the rsync (the setup prompts from the template it shipped) and
	// before the engine (compose reads what it writes).
	st := &env.Step{Out: c.Out, Prompter: c.Prompter, S: r.s, Target: r.target, TTYIn: c.TTYIn, TTYOut: c.TTYOut, Color: c.Color}
	if err := st.Run(r.dir, r.mk.CPULimit, r.mk.MemLimit, o.OnDrift, false); err != nil {
		return err
	}
	if claim != nil {
		r.mailClaim(claim)
	}
	rep, err := r.remote()
	if err != nil {
		return err
	}
	shipped, err := r.fragment()
	if err != nil {
		return err
	}
	// Only now: a failed command leaves the state file untouched.
	if err := state.Record(state.File, c.Version,
		"last_server", r.target,
		"last_deploy", c.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"last_version", r.version); err != nil {
		return err
	}
	r.banner(rep, clientState, shipped)
	r.changelog(rep)
	return nil
}

func (r *run) rerun() string { return "kasbah deploy " + r.target }

// remote runs the engine and reads its report, which is the completion
// marker: no report means the run did not reach its end, and nothing after
// it — the fragment above all — may happen.
func (r *run) remote() (*Report, error) {
	b := r.p
	sp := Spec{
		Mode: "deploy", Version: r.version, Kasbah: r.c.Version,
		SkipHooks: r.o.SkipHooks, NoHealthWait: r.o.NoHealthWait, AllowStopped: r.o.AllowStopped,
		Images: b.Images, Pre: b.Hooks["pre-deploy"], Post: b.Hooks["post-deploy"],
		Health: b.Health, Backup: b.Backup,
	}
	out, rc := r.s.Run(r.dir, sp)
	if rc == 255 || rc == -1 {
		// ssh's own failure: the engine may have run to its end regardless.
		return nil, cli.Fail("the connection to %s was lost during the deploy (ssh exited %d)", r.target, rc).Cont(
			"the server may have finished it — check `kasbah history "+r.target+"` for a "+r.version+" entry.",
			"The Traefik fragment was not shipped. Re-running `"+r.rerun()+"` is safe.")
	}
	if rc != 0 {
		return nil, cli.Fail("the deploy failed on %s (the server's kasbah exited %d, see above)", r.target, rc).Cont(
			"the files are already there — fix what it reported and re-run `"+r.rerun()+"`.",
			r.m.Name+"'s images on "+r.target+" may already carry :current for",
			r.version+" even though its containers did not start — the retag runs",
			"before `compose up`, and nothing on the server records that it moved.",
			"`kasbah rollback "+r.target+"` is what puts it back.")
	}
	rep, missing, found := ParseReport(out)
	if rep == nil {
		what := "no report"
		if found {
			what = "no " + strings.Join(missing, " ")
		}
		e := cli.Fail("the deploy step on %s reported %s", r.target, what).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:")
		for _, l := range strings.Split(strings.TrimRight(strings.ReplaceAll(out, "\r", ""), "\n"), "\n") {
			e.Cont("| " + l)
		}
		return nil, e.Cont(
			"That report is the last thing the server's deploy writes, so this run got",
			"at least as far as `compose up`: the new containers may be up and",
			r.dir+"/versions.log may already record",
			r.version+". What did *not* happen is the Traefik fragment, so this",
			"host still serves whatever it served before. Check the server, then",
			"re-run `"+r.rerun()+"` — it is safe to run again.")
	}
	if rep.Version != r.version {
		return nil, cli.Fail("the deploy step on %s reported version '%s', not the %s it was asked for", r.target, rep.Version, r.version)
	}
	return rep, nil
}

// fragment ships the route last; a project without one deploys anyway.
func (r *run) fragment() (bool, error) {
	dest := r.mk.AppsPath + "/traefik/dynamic/" + r.m.Name + ".yml"
	if fi, err := os.Stat(Fragment); err != nil || !fi.Mode().IsRegular() {
		r.c.Out.Warn("no %s in %s — nothing was written to %s", Fragment, r.c.PWD, dest)
		r.c.Out.Warn("this project routes through Traefik only if that file exists (docs/traefik.md)")
		return false, nil
	}
	if err := r.s.Fragment(Fragment, dest); err != nil {
		return false, cli.Fail("could not ship %s to %s:%s", Fragment, r.target, dest).Cont(
			"the deploy itself succeeded — the new containers are up and versions.log",
			"already records "+r.version+". Only the Traefik route is missing, so this",
			"host serves whatever it served before (404 if it is a first deploy).",
			"re-run `"+r.rerun()+"` once the server is reachable again.")
	}
	return true, nil
}

func (r *run) banner(rep *Report, client string, shipped bool) {
	o, apps, name := r.c.Out, r.mk.AppsPath, r.m.Name
	o.Info("Deployed %s %s to %s", name, r.version, r.target)
	o.Info("  project: %s/%s   data: %s/%s", apps, name, r.mk.DataPath, name)
	o.Info("  limits:  KASBAH_CPU_LIMIT=%s KASBAH_MEM_LIMIT=%s (from the server marker)", r.mk.CPULimit, r.mk.MemLimit)
	if shipped {
		o.Info("  routing: %s/traefik/dynamic/%s.yml (Traefik reloads within a couple of seconds)", apps, name)
	}
	o.Info("  logged:  %s/%s/versions.log", apps, name)
	o.Info("  client:  %s (%s, at %s/%s/.kasbah-client — the backup repository this project files into)", r.p.Client, client, apps, name)
	if rep.Backup == "no-backup" {
		o.Info("  backup:  none taken")
	} else {
		o.Info("  backup:  %s/%s/%s", apps, name, rep.Backup)
	}
	if rep.Digest != "-" {
		o.Info("  images:  %s (read on the server after the retag)", rep.Digest)
	}
}

// changelog is step 10: the server knows the previous version, this checkout
// the commits. Never a failure — the deploy is done.
func (r *run) changelog(rep *Report) {
	o, prev, v := r.c.Out, rep.PrevVersion, r.version
	if prev == "" {
		if rep.DeployedBefore {
			o.Warn("%s has deployed %s before, but the last line of its", r.target, r.m.Name)
			o.Warn("versions.log is not one a version can be read out of — so there is no range to")
			o.Warn("compare against and no changelog. The deploy itself is done.")
			o.Warn("look at %s/versions.log, then `git log v<prev>..v%s`", r.dir, v)
			return
		}
		o.Info("  changes: first deploy to %s — no previous version to compare against", r.target)
		return
	}
	rng := "v" + prev + "..v" + v
	if exec.Command("git", "rev-parse", "-q", "--verify", "refs/tags/v"+prev+"^{commit}").Run() != nil {
		o.Warn("%s was running %s, and this checkout has no tag v%s — no changelog", r.target, prev, prev)
		o.Warn("`git fetch --tags`, then `git log %s`", rng)
		return
	}
	cmd := exec.Command("git", "log", "--no-color", "--format=%h %s", rng, "--")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		o.Warn("could not read `git log %s` (see git's error above) — no changelog", rng)
		return
	}
	log := strings.TrimRight(string(out), "\n")
	switch {
	case log == "" && prev == v:
		o.Info("  changes: none — %s is empty, so this is a redeploy of the version already there", rng)
	case log == "":
		o.Info("  changes: none in %s — %s is not ahead of the %s this server was running", rng, v, prev)
		o.Info("           this deploy takes it back to %s; `git log v%s..v%s` is what it gives up", v, v, prev)
	default:
		o.Info("  changes: %s", rng)
		for _, l := range strings.Split(log, "\n") {
			if l != "" {
				fmt.Fprintf(o.Stderr, "    %s\n", l)
			}
		}
	}
}

// claim is the mail facts and the registry, read before anything is written.
type claim struct {
	f   *MailFacts
	reg *mailreg.Registry
	// note is why the registry could not be judged, when it could not.
	note string
	seed []byte
}

// readClaim reads the server's mail facts up front, so a registry kasbah
// refuses (D4: no primary_domain) stops the run before the first write.
func (r *run) readClaim() (*claim, error) {
	if r.p.MailDomain == "" {
		return nil, nil
	}
	cl := &claim{}
	if p := r.p.MailSnappy; p != "" {
		if fi, err := os.Stat(p); err != nil || !fi.Mode().IsRegular() {
			r.c.Out.Warn("kasbah.yml names snappymail_domain: %s, and there is no such file in this checkout", p)
			r.c.Out.Warn("nothing is seeded — run kasbah check (M02); the deploy continues")
			r.p.MailSnappy = ""
		} else if b, err := os.ReadFile(p); err != nil || len(b) == 0 {
			r.c.Out.Warn("could not read %s — nothing is seeded; the deploy continues", p)
			r.p.MailSnappy = ""
		} else {
			cl.seed = b
		}
	}
	f, err := r.s.Mail(r.mk.AppsPath)
	if err != nil {
		return nil, err
	}
	cl.f = f
	if !f.Stack || !f.Env {
		return cl, nil
	}
	where := mailreg.Path(r.mk.AppsPath) + " on " + r.target
	data, derr := base64.StdEncoding.DecodeString(f.Registry)
	switch {
	case !f.HasRegistry || derr != nil || strings.TrimSpace(string(data)) == "":
		cl.note = "missing"
	default:
		reg, err := mailreg.Parse(data, where)
		if errors.Is(err, mailreg.ErrUnparseable) {
			cl.note = "unparseable"
		} else if err != nil {
			return nil, err
		} else {
			cl.reg = reg
		}
	}
	return cl, nil
}

// mailClaim is step 7, reconciled: every outcome is a warning, because an
// unmet claim costs mail, not the site.
func (r *run) mailClaim(cl *claim) {
	o, d, t, name := r.c.Out, r.p.MailDomain, r.target, r.m.Name
	dir := r.mk.AppsPath + "/mail"
	met := false
	switch {
	case !cl.f.Stack:
		o.Warn("%s claims the mail domain %s, and there is no mail stack at %s on %s", name, d, dir, t)
		o.Warn("enable it with: kasbah server init %s --with-mail — the deploy continues", t)
	case !cl.f.Env:
		o.Warn("%s claims the mail domain %s, and %s on %s has no .env", name, d, dir, t)
		o.Warn("the stack there looks half-made, so the claim is unmet as far as anything here")
		o.Warn("can tell — re-run server init --with-mail; the deploy continues")
	default:
		switch {
		case cl.note == "missing":
			o.Warn("%s claims the mail domain %s, and %s/kasbah.yml on %s is missing or unreadable", name, d, dir, t)
			o.Warn("that file is the registry — the only thing that answers whether this stack serves")
			o.Warn("a domain — so the claim cannot be checked; the deploy continues")
		case cl.note == "unparseable":
			o.Warn("%s claims the mail domain %s, and %s/kasbah.yml on %s does not parse as YAML", name, d, dir, t)
			o.Warn("the claim cannot be checked against a registry kasbah cannot read; the deploy continues")
		case cl.reg.Serves(d):
			met = true
			o.Info("  mail: %s is served by the stack at %s (dms %s, snappymail %s)", d, dir, cl.f.DMS, cl.f.Snappymail)
		default:
			o.Warn("%s claims the mail domain %s, and the stack at %s does not serve it", name, d, dir)
			o.Warn("%s/kasbah.yml lists: %s", dir, strings.Join(cl.reg.Domains, " "))
			o.Warn("add it with: kasbah server add-mail-domain %s %s", t, d)
			o.Warn("mail for %s is not accepted until then; the deploy continues", d)
		}
		switch cl.f.DMS {
		case "running", "nodocker":
		case "absent":
			o.Warn("%s claims mail, and there is no mail-dms container on %s", name, t)
			o.Warn("bring the stack up: ssh %s 'cd %s && docker compose -p mail up -d'", t, dir)
		default:
			o.Warn("%s claims mail, and mail-dms on %s is '%s', not running", name, t, cl.f.DMS)
			o.Warn("a restarting DMS is usually the certificate for mail.<primary> not being in acme.json yet")
			o.Warn("  ssh %s 'docker logs --tail 40 mail-dms'", t)
		}
	}
	if cl.seed == nil {
		return
	}
	snappy := r.p.MailSnappy
	if !met {
		o.Warn("kasbah.yml names snappymail_domain: %s, and it was NOT copied", snappy)
		o.Warn("the claim on %s is unmet (see above), and a SnappyMail domain", d)
		o.Warn("config for a domain this stack does not serve is configuration written on a")
		o.Warn("premise kasbah knows to be false — fix the claim and re-deploy")
		return
	}
	res, err := r.s.Seed("/var/lib/snappymail/_data_/_default_/domains/"+d+".json", cl.seed)
	if err != nil {
		res = "failed"
	}
	switch res {
	case "copied":
		o.Info("  mail: seeded SnappyMail's %s.json from %s", d, snappy)
	case "present":
		o.Info("  mail: SnappyMail already has a config for %s — left as it is", d)
	case "nocontainer":
		o.Warn("kasbah.yml names snappymail_domain: %s, and there is no mail-snappymail container on %s", snappy, t)
		o.Warn("nothing was seeded; the deploy continues")
	default:
		o.Warn("could not seed SnappyMail's config for %s from %s", d, snappy)
		o.Warn("SnappyMail builds _data_/_default_/domains/ on its first boot; if the container has")
		o.Warn("never come up, that directory is not there yet. The deploy continues.")
	}
}
