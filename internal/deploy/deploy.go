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
	"regexp"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/release"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are a deploy's or a rollback's arguments. A Version is the tagged
// path (tagged.go).
type Options struct {
	Target, Version, OnDrift              string
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
  * ships every path in the manifest's sync: list to <apps>/<name>/
  * renders <apps>/<name>/.env when it is missing, checks it for drift against
    .env.prod.example otherwise, and refreshes the KASBAH_* block in it from
    the server marker's resource limits
  * runs ` + "`kasbah remote deploy`" + ` on the server: backup, pre-deploy hooks,
    retag <image>:current, docker compose -p <name> up -d --remove-orphans,
    health wait, post-deploy hooks, one versions.log entry
  * ships traefik-dynamic.yml to <apps>/traefik/dynamic/<name>.yml, last
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

var (
	reVTag   = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+`)
	reSemver = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$`)
)

// Classify files one positional argument: '@' makes it the server, anything
// else the version — bare semver, as versions.log carries it.
func Classify(cmd, arg string, target, version *string) error {
	arg = strings.TrimSuffix(arg, "\r")
	if strings.Contains(arg, "@") {
		if *target != "" {
			return cli.Fail("%s: two servers given ('%s' and '%s') — one run goes to one server", cmd, *target, arg)
		}
		*target = arg
		return nil
	}
	if *version != "" {
		return cli.Fail("%s: two versions given ('%s' and '%s') — kasbah will not choose between them", cmd, *version, arg)
	}
	if reVTag.MatchString(arg) {
		v := arg[1:]
		return cli.Fail("%s: write the version without the 'v' — `kasbah %s %s` (the tag is v%s, the version is %s)", cmd, cmd, v, v, v)
	}
	if !reSemver.MatchString(arg) {
		return cli.Fail("%s: '%s' is not a version kasbah can use — expected <major>.<minor>.<patch> (docs/build-deploy.md → versioning contract)", cmd, arg)
	}
	*version = arg
	return nil
}

// Parse reads deploy's arguments.
func Parse(args []string) (Options, error) { return parse("deploy", args) }

// ParseRollback reads rollback's, which are deploy's.
func ParseRollback(args []string) (Options, error) { return parse("rollback", args) }

func parse(cmd string, args []string) (Options, error) {
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
			return o, cli.Fail("%s: %s takes no value — pass it on its own (`kasbah %s USER@HOST %s`)", cmd, name, cmd, name)
		case strings.HasPrefix(a, "--on-drift="):
			o.OnDrift = strings.TrimSuffix(strings.TrimPrefix(a, "--on-drift="), "\r")
			if err := env.CheckOnDrift(cmd, o.OnDrift); err != nil {
				return o, err
			}
		case a == "--on-drift":
			return o, cli.Fail("%s: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort", cmd)
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("%s: unknown flag '%s' (%s takes USER@HOST, VERSION, --on-drift=, --skip-hooks, --no-health-wait and --allow-stopped)", cmd, name, cmd)
		default:
			if err := Classify(cmd, a, &o.Target, &o.Version); err != nil {
				return o, err
			}
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
	Run(dir string, sp Spec) (stdout string, rc int)
	Fragment(local, dest string) error
	// Images and Record are the tagged path's: which :<version> images are
	// gone, and the deploy record.
	Images(version string, images []string) (checked int, missing []string, err error)
	Record(apps, name string) (*vlog.Record, error)
	HoldServer(apps, what string) (release func(), err error)
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
	// Interrupted is atexit.Interrupted when nil.
	Interrupted func() int
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
	// mode is the engine's and the log's: deploy or rollback. tagged runs
	// ship v<version> out of git rather than the working tree.
	mode   string
	tagged bool
	frag   string
}

// Run is the command.
func Run(c Ctx, o Options) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	r := &run{c: c, o: o, m: m, target: o.Target, mode: "deploy", frag: Fragment}
	if r.target, _, err = state.Server(o.Target, "deploy", "kasbah deploy user@vps"); err != nil {
		return err
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
	release, err := r.s.HoldServer(r.mk.AppsPath, "deploy")
	if err != nil {
		return err
	}
	defer release()
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
	// After the sync (the setup prompts from the template it shipped) and
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
	r.banner("Deployed "+m.Name+" "+r.version+" to "+r.target, rep, clientState, shipped)
	r.changelog(rep)
	return nil
}

func (r *run) rerun() string {
	if r.tagged {
		return "kasbah " + r.mode + " " + r.target + " " + r.version
	}
	return "kasbah deploy " + r.target
}

// remote runs the engine and reads its report, which is the completion
// marker: no report means the run did not reach its end, and nothing after
// it — the fragment above all — may happen.
func (r *run) remote() (*Report, error) {
	b := r.p
	sp := Spec{
		Mode: r.mode, Version: r.version, Kasbah: r.c.Version,
		SkipHooks: r.o.SkipHooks, NoHealthWait: r.o.NoHealthWait, AllowStopped: r.o.AllowStopped,
		Images: b.Images, Pre: b.Hooks["pre-"+r.mode], Post: b.Hooks["post-"+r.mode],
		Health: b.Health, Backup: b.Backup,
	}
	// Held: the engine finishes on the server whatever happens to this end,
	// so a signal waits for ssh rather than tearing the master down under it.
	release := atexit.Hold(func(os.Signal) {})
	out, rc := r.s.Run(r.dir, sp)
	release()
	interrupted := r.c.Interrupted
	if interrupted == nil {
		interrupted = atexit.Interrupted
	}
	if c := interrupted(); c != 0 && rc != 0 {
		return nil, cli.Failf(c, "interrupted during the %s on %s", r.mode, r.target).Cont(
			"the server carries on without this end: it finishes the "+r.mode+" and records it",
			"in versions.log. `kasbah history "+r.target+"` shows where it ended.",
			"The Traefik fragment was not shipped. Re-running `"+r.rerun()+"` is safe.")
	}
	if rc == 255 || rc == -1 {
		// ssh's own failure: the engine may have run to its end regardless.
		return nil, cli.Fail("the connection to %s was lost during the %s (ssh exited %d)", r.target, r.mode, rc).Cont(
			"the server may have finished it — check `kasbah history "+r.target+"` for a "+r.version+" entry.",
			"The Traefik fragment was not shipped. Re-running `"+r.rerun()+"` is safe.")
	}
	if rc != 0 {
		e := cli.Fail("the %s failed on %s (the server's kasbah exited %d, see above)", r.mode, r.target, rc).Cont(
			"the files are already there — fix what it reported and re-run `"+r.rerun()+"`.",
			r.m.Name+"'s images on "+r.target+" may already carry :current for",
			r.version+" even though its containers did not start — the retag runs",
			"before `compose up`, and nothing on the server records that it moved.")
		if r.mode == "deploy" {
			e.Cont("`kasbah rollback " + r.target + "` is what puts it back.")
		}
		return nil, e
	}
	rep, missing, found := ParseReport(out)
	if rep == nil {
		what := "no report"
		if found {
			what = "no " + strings.Join(missing, " ")
		}
		e := cli.Fail("the %s step on %s reported %s", r.mode, r.target, what).Cont(
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
		return nil, cli.Fail("the %s step on %s reported version '%s', not the %s it was asked for", r.mode, r.target, rep.Version, r.version)
	}
	return rep, nil
}

// fragment ships the route last; a project without one deploys anyway.
func (r *run) fragment() (bool, error) {
	dest := r.mk.AppsPath + "/traefik/dynamic/" + r.m.Name + ".yml"
	if fi, err := os.Stat(r.frag); err != nil || !fi.Mode().IsRegular() {
		r.c.Out.Warn("no %s in %s — nothing was written to %s", Fragment, r.c.PWD, dest)
		r.c.Out.Warn("this project routes through Traefik only if that file exists (docs/traefik.md)")
		return false, nil
	}
	if err := r.s.Fragment(r.frag, dest); err != nil {
		e := cli.Fail("could not ship %s to %s:%s", Fragment, r.target, dest).Cont(
			"the "+r.mode+" itself succeeded — the new containers are up and versions.log",
			"already records "+r.version+". Only the Traefik route is missing, so this")
		// A rollback cannot be a first deploy: its target was in the record.
		if r.mode == "rollback" {
			e.Cont("host still serves the route the run before this one left, which points at the",
				"containers this rollback replaced, so it 502s for any of them v"+r.version+" renamed.")
		} else {
			e.Cont("host serves whatever it served before (404 if it is a first deploy).")
		}
		return false, e.Cont("re-run `" + r.rerun() + "` once the server is reachable again.")
	}
	return true, nil
}

func (r *run) banner(headline string, rep *Report, client string, shipped bool) {
	o, apps, name := r.c.Out, r.mk.AppsPath, r.m.Name
	o.Info("%s", headline)
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
		if rep.ArchiveOnly {
			o.Warn("%s has deployed %s before, but %s/versions.log held no entry — only", r.target, r.m.Name, r.dir)
			o.Warn("versions.log.gz does, so the active log was lost or replaced and there is no")
			o.Warn("previous version to compare against and no changelog. The %s itself is done.", r.mode)
			o.Warn("look at %s/versions.log.gz, then `git log v<prev>..v%s`", r.dir, v)
			return
		}
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
}

// readClaim reads the server's mail facts up front, so a registry kasbah
// refuses (D4: no primary_domain) stops the run before the first write.
func (r *run) readClaim() (*claim, error) {
	if r.p.MailDomain == "" {
		return nil, nil
	}
	cl := &claim{}
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
			o.Info("  mail: %s is served by the stack at %s (dms %s)", d, dir, cl.f.DMS)
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
}
