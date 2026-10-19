// Package drop is `kasbah drop [USER@HOST] [--prune] [--yes]`: one project
// off a server (docs/cli.md → kasbah drop). The server binary reads (scan)
// and removes (act); every decision is made here, from what it reported.
//
// What it will not remove is the point: a repository a second project also
// declares, and every repository on a server where some project's declared
// images cannot be read, are left alone — `server prune`'s ownership rule
// applied to one project.
package drop

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/prune"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the command's arguments.
type Options struct {
	Target     string
	Prune, Yes bool
}

// Usage is the command's --help.
const Usage = `Usage: kasbah drop [USER@HOST] [--prune] [--yes]

Removes this project from a server. Run from the project root. USER@HOST
defaults to the last server this project talked to (.kasbah/state.json).

Plain drop is reversible — a later ` + "`kasbah deploy`" + ` resurrects the project with
its data, once its images have been re-shipped with ` + "`kasbah build-push`" + `:

  removed   the Traefik fragment, the containers (` + "`docker compose down`" + `), and
            every tag of the images this project builds
  kept      <apps>/<name>/ (compose.yml, .env, versions.log, scripts, backups),
            <data>/<name>/, and the project's mail-domain claim

  --prune   delete the kept things too: <apps>/<name>/ with the on-VPS backups
            inside it, <data>/<name>/, and the project's entry in the mail
            registry. The off-VPS restic repository is never touched — it is
            operator property (docs/backup.md).
  --yes     answer both confirmations, for scripts. Without it and without a
            terminal, drop stops rather than assuming.

Confirmation is double: a yes/no question, then the project name typed back.

An image repository a second project on the server also declares is left alone,
and so is every repository on a server where some project's compose.yml cannot
be read: a deletion is not decided on a partial reading of what is deployed.
`

// Parse reads the command line.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--prune":
			o.Prune = true
		case a == "--yes":
			o.Yes = true
		case strings.HasPrefix(a, "--prune=") || strings.HasPrefix(a, "--yes="):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("drop: %s takes no value — pass it on its own (`kasbah drop USER@HOST %s`)", f, f)
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("drop: unknown flag '%s' (drop takes USER@HOST, --prune and --yes)", f)
		default:
			if o.Target != "" {
				return o, cli.Fail("drop: two servers given ('%s' and '%s') — one run goes to one server", o.Target, a)
			}
			t := strings.TrimSuffix(a, "\r")
			if !strings.Contains(t, "@") {
				return o, cli.Fail("drop: '%s' is not a USER@HOST — drop takes the server and nothing else positionally", t)
			}
			o.Target = t
		}
	}
	return o, nil
}

// Session is what drop needs from a server.
type Session interface {
	Marker() (*marker.Marker, error)
	Scan(apps, data, name string) ([]byte, int)
	// Act runs the removal with stdin as its payload; unbounded, one
	// `docker image rm` per tag however many.
	Act(stdin []byte, args []string) ([]byte, int)
	Close()
}

// SSH is the real Session.
type SSH struct{ *env.SSH }

// Dial connects; Marker ensures the server's binary.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

func (s SSH) Scan(apps, data, name string) ([]byte, int) {
	out, err := s.Conn.Run(s.Bounded("drop", "scan", apps, data, name)...)
	return out, ssh.ExitCode(err)
}

func (s SSH) Act(stdin []byte, args []string) ([]byte, int) {
	cmd := s.Conn.Command(append([]string{s.Bin(), "remote", "drop", "act"}, args...)...)
	cmd.Stdin = bytes.NewReader(stdin)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), ssh.ExitCode(err)
}

func (s SSH) Close() { s.Conn.Close() }

// Ctx is what a run needs from its process.
type Ctx struct {
	Out       *cli.Output
	Prompter  *prompt.Prompter
	Version   string
	Templates fs.FS
	Dial      func(target string) (Session, error)
}

// Line is one tag of the project's own repositories and its verdict.
type Line struct{ Tag, Verdict, Why string }

// Plan is everything decided before the operator is asked.
type Plan struct {
	Name, Target, Apps, Data string
	Prune, FromState         bool
	MailDomain               string
	NeedsAllowStopped        bool

	Scan         *Scan
	Containers   string
	Repos        []string
	ReposOK      bool
	ComposeState string
	Owners       map[string][]string
	Unknown      []string
	// UnknownOthers are the unknown owners that are not this project.
	UnknownOthers []string
	Orphans       []string
	Lines         []Line
	Remove        []string

	MailVerdict, MailPrimary string
	// MailRendered is the registry that releases the claim, "" for none;
	// MailPrev is the sha256 of the one it was rendered from.
	MailRendered, MailPrev string
}

func decode(b64 string) ([]byte, bool) {
	if b64 == "" {
		return nil, true
	}
	b, err := base64.StdEncoding.DecodeString(b64)
	return b, err == nil
}

// dataDir is the bind-mount root's name when it is a direct child of apps:
// counted as a project it would have no compose.yml, and stop every drop.
func dataDir(apps, data string) string {
	rest, ok := strings.CutPrefix(data, apps+"/")
	if !ok || rest == "" || strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

// Decide builds the plan from the scan: ownership, the removal set, the
// orphans and the mail release.
func Decide(p *Plan, templates fs.FS) error {
	s := p.Scan
	for _, c := range s.Containers {
		if p.Containers != "" {
			p.Containers += ", "
		}
		p.Containers += c.Name + "(" + c.State + ")"
	}

	idTags := map[string][]string{}
	tagID := map[string]string{}
	for _, im := range s.Images {
		idTags[im.ID] = im.Tags
		for _, t := range im.Tags {
			tagID[t] = im.ID
		}
	}

	dd := dataDir(p.Apps, p.Data)
	p.Owners = map[string][]string{}
	p.ComposeState = "absent"
	for _, pr := range s.Projects {
		if dd != "" && pr.Name == dd {
			continue
		}
		if pr.Name == p.Name {
			p.ComposeState = pr.ComposeState
		}
		var repos []string
		ok := false
		if pr.ComposeState == "ok" {
			if b, good := decode(pr.ComposeB64); good {
				repos, ok = prune.Repos(string(b))
			} else {
				return cli.Fail("the drop probe on %s sent %s's compose.yml as something that is not base64", p.Target, pr.Name)
			}
		}
		if !ok {
			repos = nil
			p.Unknown = append(p.Unknown, pr.Name)
			if pr.Name != p.Name {
				p.UnknownOthers = append(p.UnknownOthers, pr.Name)
			}
		} else if pr.Name == p.Name {
			p.Repos, p.ReposOK = repos, true
		}
		for _, r := range repos {
			p.Owners[r] = append(p.Owners[r], pr.Name)
		}
	}

	tags := make([]string, 0, len(tagID))
	for t := range tagID {
		tags = append(tags, t)
	}
	sort.Strings(tags)

	if p.ReposOK {
		unknown := strings.Join(p.Unknown, " ")
		for _, repo := range p.Repos {
			own := p.Owners[repo]
			for _, tag := range tags {
				if !strings.HasPrefix(tag, repo+":") {
					continue
				}
				l := Line{Tag: tag, Verdict: "remove"}
				switch {
				case len(own) != 1 || own[0] != p.Name:
					l.Verdict = "keep"
					l.Why = fmt.Sprintf("%s is claimed by more than one project (%s)", repo, strings.Join(own, " "))
				case len(p.Unknown) > 0:
					l.Verdict = "keep"
					l.Why = "ownership cannot be established: " + unknown + " declare(s) images kasbah could not read, and such a file could name any repository"
				default:
					var other []string
					for _, t := range idTags[tagID[tag]] {
						if !strings.HasPrefix(t, repo+":") {
							other = append(other, t)
						}
					}
					if len(other) > 0 {
						l.Why = "untags only, the image also carries " + strings.Join(other, " ")
					} else {
						l.Why = "built by " + p.Name + ", claimed by no other project"
					}
				}
				p.Lines = append(p.Lines, l)
			}
		}
		sort.SliceStable(p.Lines, func(a, b int) bool { return p.Lines[a].Tag < p.Lines[b].Tag })
		for _, l := range p.Lines {
			if l.Verdict == "remove" {
				p.Remove = append(p.Remove, l.Tag)
			}
		}
	}

	// Repositories carrying :current — deploy's pointer, nothing else sets
	// it — that no readable project declares.
	for _, tag := range tags {
		i := strings.LastIndex(tag, ":")
		if i < 0 {
			continue
		}
		repo := tag[:i]
		if _, cur := tagID[repo+":current"]; !cur {
			continue
		}
		if _, owned := p.Owners[repo]; owned {
			continue
		}
		p.Orphans = append(p.Orphans, tag)
	}
	return p.mailPlan(templates)
}

// mailPlan releases the claim under --prune only, through internal/mailreg and
// the registry's one template; no shape of the mail stack stops a drop.
func (p *Plan) mailPlan(templates fs.FS) error {
	if p.MailDomain == "" {
		return nil
	}
	if !p.Prune {
		p.MailVerdict = "kept: plain drop leaves the claim, so a redeploy resurrects the project whole"
		return nil
	}
	reg := p.Apps + "/mail/kasbah.yml"
	if p.Scan.MailDir != "dir" {
		p.MailVerdict = "nothing to release: there is no mail stack at " + p.Apps + "/mail"
		return nil
	}
	body, ok := decode(p.Scan.RegistryB64)
	if !ok {
		return cli.Fail("the drop probe on %s sent %s as something that is not base64", p.Target, reg)
	}
	if p.Scan.RegistryState != "ok" || len(body) == 0 {
		p.MailVerdict = "nothing to release: " + reg + " is " + p.Scan.RegistryState
		return nil
	}
	r, err := mail.ParseRegistry(string(body), p.Apps, p.Target)
	if err != nil {
		reason := err.Error()
		var e *cli.Error
		if errors.As(err, &e) && len(e.Lines) > 0 {
			reason = e.Lines[0]
		}
		p.MailVerdict = "NOT released: " + reason
		return nil
	}
	p.MailPrimary = r.Primary
	if p.MailDomain == r.Primary {
		p.MailVerdict = "NOT released: " + p.MailDomain + " is the stack's primary_domain — its MX target and certificate name — and no project's drop takes that away"
		return nil
	}
	var keep []string
	found := false
	for _, d := range r.Domains {
		if d == p.MailDomain {
			found = true
			continue
		}
		keep = append(keep, d)
	}
	if !found {
		p.MailVerdict = "nothing to release: " + reg + " does not list " + p.MailDomain
		return nil
	}
	rendered, err := mail.RenderRegistry(templates, r.Primary, keep)
	if err != nil {
		return err
	}
	p.MailRendered, p.MailPrev = rendered, Sum(body)
	p.MailVerdict = "released: " + p.MailDomain + " is removed from " + reg
	return nil
}

func (p *Plan) composeWord() string {
	if p.ComposeState == "ok" {
		return "not YAML kasbah can parse"
	}
	return p.ComposeState
}

// Report is the plan as the operator reads it, on stdout.
func (p *Plan) Report(w io.Writer) {
	verb := "drop"
	if p.Prune {
		verb = "drop --prune"
	}
	if p.FromState {
		fmt.Fprintf(w, "kasbah %s — %s on %s (%s), from %s last_server\n\n", verb, p.Name, p.Target, p.Apps, state.File)
	} else {
		fmt.Fprintf(w, "kasbah %s — %s on %s (%s)\n\n", verb, p.Name, p.Target, p.Apps)
	}
	frag := p.Apps + "/traefik/dynamic/" + p.Name + ".yml"
	fmt.Fprintf(w, "to remove\n")
	switch p.Scan.FragmentState {
	case "ok", "empty":
		fmt.Fprintf(w, "  route       %s\n", frag)
	case "missing":
		fmt.Fprintf(w, "  route       none — %s is not there\n", frag)
	default:
		fmt.Fprintf(w, "  route       %s (%s)\n", frag, p.Scan.FragmentState)
	}
	c := p.Containers
	if c == "" {
		c = "none labelled " + p.Name
	}
	fmt.Fprintf(w, "  containers  %s\n", c)

	switch {
	case len(p.Lines) == 0 && !p.ReposOK:
		fmt.Fprintf(w, "  images      none — %s/%s/compose.yml is %s, so which images this project builds is unknown\n", p.Apps, p.Name, p.composeWord())
	case len(p.Lines) == 0 && len(p.Repos) == 0:
		fmt.Fprintf(w, "  images      none — this project builds none of its own (stock images only)\n")
	case len(p.Lines) == 0:
		fmt.Fprintf(w, "  images      none of %s is on this server\n", strings.Join(p.Repos, " "))
	default:
		width := 0
		for _, l := range p.Lines {
			width = max(width, len(l.Tag))
		}
		if len(p.Remove) == 0 {
			fmt.Fprintf(w, "  images      none — every tag of this project is left alone, below\n")
		} else {
			fmt.Fprintf(w, "  images\n")
		}
		for _, l := range p.Lines {
			if l.Verdict == "remove" {
				fmt.Fprintf(w, "    %-*s  %s\n", width, l.Tag, l.Why)
			}
		}
		if len(p.Remove) != len(p.Lines) {
			fmt.Fprintf(w, "\nleft alone\n  images\n")
			for _, l := range p.Lines {
				if l.Verdict == "keep" {
					fmt.Fprintf(w, "    %-*s  %s\n", width, l.Tag, l.Why)
				}
			}
		}
	}

	if p.Prune {
		fmt.Fprintf(w, "\nto delete\n")
	} else {
		fmt.Fprintf(w, "\nto keep\n")
	}
	fmt.Fprintf(w, "  config      %s/%s/ (%s)\n", p.Apps, p.Name, p.Scan.ProjectState)
	fmt.Fprintf(w, "  data        %s/%s/ (%s)\n", p.Data, p.Name, p.Scan.DataState)
	fmt.Fprintf(w, "  backups     %s/%s/backups/ (%s, %d file(s))\n", p.Apps, p.Name, p.Scan.BackupsState, p.Scan.BackupsCount)
	if p.MailVerdict != "" {
		fmt.Fprintf(w, "  mail        %s — %s\n", p.MailDomain, p.MailVerdict)
	}
	if p.Prune {
		fmt.Fprintf(w, "\nthe off-VPS restic repository is not touched: it is operator property (docs/backup.md).\n")
	} else {
		fmt.Fprintf(w, "\na later `kasbah deploy` resurrects this project, once `kasbah build-push` has\nre-shipped its images.\n")
	}
	fmt.Fprintln(w)
}

// anything is whether this run has anything left to do at all.
func (p *Plan) anything() bool {
	if len(p.Remove) > 0 || p.Scan.FragmentState != "missing" || len(p.Scan.Containers) > 0 {
		return true
	}
	if p.Prune {
		return p.Scan.ProjectState != "absent" || p.Scan.DataState != "absent" || p.MailRendered != ""
	}
	return false
}

// pruneCliff is --prune with no provably single-owner repository: refused,
// unless this project's directory holds no compose.yml at all.
func (p *Plan) pruneCliff(out *cli.Output) error {
	without := fmt.Sprintf("`kasbah drop %s` without --prune, which changes nothing a redeploy", p.Target)
	if len(p.UnknownOthers) > 0 {
		o := strings.Join(p.UnknownOthers, " ")
		return cli.Fail("--prune is refused: %s declare(s) images kasbah could not read", o).Cont(
			"while that is true no repository on this host is provably single-owner, so not one",
			"of "+p.Name+"'s tags can be removed — and --prune would stop it being a project",
			"here, after which nothing can attribute those tags to it again.",
			"Fix the compose.yml of "+o+", or run",
			without, "cannot undo.")
	}
	if p.ComposeState != "missing" {
		return cli.Fail("--prune is refused: %s/%s/compose.yml is %s", p.Apps, p.Name, p.composeWord()).Cont(
			"that file is the only record of which images this project builds, and --prune",
			"deletes it — after that nobody can ever answer the question. Fix it, or run",
			without, "cannot undo.")
	}
	out.Warn("%s/%s has no compose.yml, so no image on %s can be", p.Apps, p.Name, p.Target)
	out.Warn("  attributed to %s — --prune goes ahead and removes none of them, because", p.Name)
	out.Warn("  there is no record here for it to destroy and nothing for you to fix")
	if len(p.Orphans) > 0 {
		out.Warn("  these tags are on the server, built by some kasbah project and claimed by none")
		out.Warn("  that kasbah could read — any of them may be %s's:", p.Name)
		for _, t := range p.Orphans {
			out.Warn("    %s", t)
		}
		out.Warn("  `docker image rm` on %s is the only thing that removes them", p.Target)
	} else {
		out.Warn("  no tag on %s is unclaimed, so there is likely nothing of it left", p.Target)
	}
	return nil
}

// needsAllowStopped is whether the manifest names a container a deploy's
// outgoing steps need: backup:'s, or a pre-deploy hook. A drop removes both.
func needsAllowStopped(m *manifest.Manifest) bool {
	if v, _ := m.Get("backup", "container"); v != nil && v != false {
		if s := strings.TrimSuffix(jv.Raw(v), "\r"); s != "" && s != "null" {
			return true
		}
	}
	v, _ := m.Get("hooks", "pre-deploy")
	switch h := v.(type) {
	case []jv.Value:
		return len(h) > 0
	case *jv.Map:
		return len(h.Keys()) > 0
	case string:
		return h != ""
	case nil, bool:
		return false
	}
	return jv.Raw(v) != "0"
}

// Run is the command.
func Run(c Ctx, o Options) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	md, err := deploy.MailDomain(m)
	if err != nil {
		return err
	}
	p := &Plan{Name: m.Name, Prune: o.Prune, MailDomain: md, NeedsAllowStopped: needsAllowStopped(m), Target: o.Target}
	if p.Target == "" {
		stored, err := state.Get(state.File, "last_server")
		if err != nil {
			return err
		}
		if stored == "" || stored == "null" {
			return cli.Fail("drop: no server given, and this project has never deployed to one").Cont(
				"pass it once — `kasbah drop user@vps` — and it is remembered in",
				state.File+" as last_server")
		}
		p.Target, p.FromState = stored, true
	}
	record := func() error { return state.Record(state.File, c.Version, "last_server", p.Target) }

	s, err := c.Dial(p.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return err
	}
	p.Apps, p.Data = mk.AppsPath, mk.DataPath

	out, rc := s.Scan(p.Apps, p.Data, p.Name)
	if rc != 0 {
		return cli.Fail("the drop probe on %s exited %d", p.Target, rc).Cont(
			"nothing was removed — drop reads the whole server before it deletes anything")
	}
	var sc Scan
	if err := remote.Decode(out, &sc, scanKeys, "the drop probe", p.Target); err != nil {
		return err
	}
	if sc.Count != len(sc.Projects) {
		return cli.Fail("the drop probe on %s counted %d projects and described %d", p.Target, sc.Count, len(sc.Projects)).Cont(
			"the payload was truncated — nothing was removed")
	}
	p.Scan = &sc
	if err := p.checkServer(); err != nil {
		return err
	}
	if err := Decide(p, c.Templates); err != nil {
		return err
	}
	p.Report(c.Out.Stdout)

	if len(p.Unknown) > 0 {
		c.Out.Warn("no image repository on %s is provably single-owner: kasbah could not read", p.Target)
		c.Out.Warn("  what images %s declare(s), and such a file could name any", strings.Join(p.Unknown, " "))
		c.Out.Warn("  repository on this host — so no image is removed")
		if p.Prune {
			if err := p.pruneCliff(c.Out); err != nil {
				return err
			}
		}
	}
	if !p.anything() {
		fmt.Fprintf(c.Out.Stdout, "%s is not on %s — nothing to drop\n", p.Name, p.Target)
		return record()
	}

	q := fmt.Sprintf("drop %s from %s?", p.Name, p.Target)
	if p.Prune {
		q = fmt.Sprintf("drop %s from %s and delete its config, data and on-VPS backups?", p.Name, p.Target)
	}
	yes, err := c.Prompter.Confirm("yes", q, o.Yes)
	if err != nil {
		return err
	}
	if !yes {
		return cli.Fail("not confirmed — nothing was changed on %s", p.Target)
	}
	typed, err := c.Prompter.Typed("yes", p.Name, fmt.Sprintf("type the project name (%s) to confirm:", p.Name), o.Yes)
	if err != nil {
		return err
	}
	if !typed {
		return cli.Fail("that is not %s — nothing was changed on %s", p.Name, p.Target)
	}

	started, actErr := p.act(c, s)
	// A run that got past the act's guards changed the server, whatever it
	// managed; one stopped at them (a held lock) did not, and records nothing.
	if started {
		if err := record(); err != nil && actErr == nil {
			return err
		}
	}
	return actErr
}

// checkServer refuses before the plan is printed: docker first, since it
// makes the apps path's question meaningless, then the tree, then the lock.
func (p *Plan) checkServer() error {
	s := p.Scan
	if !s.HaveDocker || s.DockerError != "" {
		e := cli.Fail("docker did not answer on %s", p.Target)
		if s.DockerError != "" {
			e.Cont(s.DockerError)
		}
		return e.Cont("drop has nothing to read and has removed nothing")
	}
	switch s.AppsState {
	case "dir":
	case "notdir":
		return cli.Fail("%s on %s is not a directory", p.Apps, p.Target)
	case "noaccess":
		return cli.Fail("%s on %s cannot be entered by this user — drop reads every project there to decide which images are this one's alone", p.Apps, p.Target)
	default:
		return cli.Failf(cli.ExitNoRemoteState, "%s on %s is not there", p.Apps, p.Target).Cont(
			"the server marker names it, so this server's layout and its tree disagree",
			"— nothing was removed")
	}
	switch s.LockState {
	// unknown: the probe could not ask; the act takes the lock or refuses.
	case "free", "unknown":
	case "held":
		return cli.Fail("a deploy or rollback of %s is running on %s", p.Name, p.Target).Cont(
			"it holds the lock on "+p.Apps+"/"+p.Name+"/.deploy.lock, which drop takes",
			"for the same reason: nothing was changed. Wait for it and run drop again.")
	default:
		return cli.Fail("the drop probe on %s reported lock_state='%s', which this kasbah does not know", p.Target, s.LockState)
	}
	return nil
}

// act runs the removal and reports it; started says whether the server's
// step got past its guards.
func (p *Plan) act(c Ctx, s Session) (started bool, err error) {
	for _, t := range p.Remove {
		if strings.HasPrefix(t, "-") || strings.ContainsAny(t, " \t\n\r\v\f") {
			return false, cli.Fail("refusing to remove '%s' on %s: that is not an image tag docker gave back", t, p.Target)
		}
	}
	a := ActArgs{Apps: p.Apps, Data: p.Data, Name: p.Name, Prune: p.Prune, RegSize: "0", RegSum: "-", RegPrev: "-", Tags: p.Remove}
	var stdin []byte
	if p.Prune && p.MailRendered != "" {
		stdin = []byte(p.MailRendered)
		a.RegSize, a.RegSum = remote.Digest(stdin)
		a.RegPrev = p.MailPrev
	}
	again := fmt.Sprintf("`kasbah drop %s%s`", p.Target, p.pruneArg())
	out, rc := s.Act(stdin, a.Argv())
	head, body, _ := bytes.Cut(bytes.ReplaceAll(out, []byte("\r"), nil), []byte("\n"))
	started = string(head) == "started=yes"
	if rc != 0 {
		e := cli.Fail("the drop step on %s exited %d", p.Target, rc)
		if started {
			return true, e.Cont("some of it may have run — " + again + " again to see what is left")
		}
		return false, e.Cont("it refused before changing anything — nothing was removed")
	}
	if !started {
		return false, cli.Fail("the drop step on %s did not say it started", p.Target).Cont(
			"the step was truncated; run " + again + " again to see what is left")
	}
	keys := []string{"fragment", "down", "down_detail", "down_left", "removed", "failed"}
	if p.Prune {
		keys = append(keys, "mail", "data", "config")
	}
	var r ActReport
	if err := remote.Decode(body, &r, keys, "the drop step", p.Target); err != nil {
		return true, err
	}
	if n := len(r.Removed) + len(r.Failed); n != len(p.Remove) {
		return true, cli.Fail("the drop step on %s accounted for %d of %d image tags", p.Target, n, len(p.Remove)).Cont(
			"the step was truncated; run drop again to see what is left")
	}
	return true, p.reportAct(c.Out, &r)
}

func (p *Plan) pruneArg() string {
	if p.Prune {
		return " --prune"
	}
	return ""
}

// reportAct is what the far side did, in the order it did it, on stdout;
// only problems and follow-ups go to stderr.
func (p *Plan) reportAct(o *cli.Output, r *ActReport) error {
	say := func(f string, a ...any) {
		if f == "" {
			fmt.Fprintln(o.Stdout)
			return
		}
		fmt.Fprintf(o.Stdout, "  "+f+"\n", a...)
	}
	bad := false
	frag := p.Apps + "/traefik/dynamic/" + p.Name + ".yml"
	switch r.Fragment {
	case "removed":
		say("removed route %s", frag)
	case "absent":
		say("route %s was not there", frag)
	default:
		say("FAILED to remove route %s", frag)
		o.Err("could not remove %s on %s", frag, p.Target)
		o.ErrCont("the site is still routed at a stack this run has taken down — remove the file")
		o.ErrCont("by hand, or re-deploy the project")
		bad = true
	}
	left := strings.TrimSpace(r.DownLeft)
	switch r.Down {
	case "ok":
		if left != "" {
			say("docker compose -p %s down returned 0, and %s is still there", p.Name, left)
			o.Warn("%s carries %s's compose label and `docker compose down` does not remove it", left, p.Name)
			o.Warn("  (it selects on com.docker.compose.oneoff=False as well) — `docker rm -f` is the only way it goes")
		} else {
			say("brought down docker compose -p %s", p.Name)
		}
	default:
		say("FAILED: docker compose -p %s down", p.Name)
		o.Err("`docker compose -p %s down` failed on %s", p.Name, p.Target)
		if r.DownDetail != "" {
			o.ErrCont("%s", r.DownDetail)
		}
		bad = true
	}
	for _, ref := range r.Removed {
		say("removed image %s", ref)
	}
	for _, f := range r.Failed {
		say("FAILED to remove image %s", f.Ref)
		reason := f.Reason
		if reason == "" {
			reason = "(no reason given)"
		}
		o.Err("could not remove %s on %s: %s", f.Ref, p.Target, reason)
		bad = true
	}
	say("removed %d of %d image tag(s)", len(r.Removed), len(p.Remove))

	if p.Prune {
		for _, d := range []struct{ state, path, extra string }{
			{r.Data, p.Data + "/" + p.Name, ""},
			{r.Config, p.Apps + "/" + p.Name, " (the on-VPS backups with it)"},
		} {
			switch d.state {
			case "removed":
				say("deleted %s%s", d.path, d.extra)
			case "absent":
				say("%s was not there", d.path)
			default:
				say("FAILED to delete %s", d.path)
				o.Err("could not delete %s on %s", d.path, p.Target)
				bad = true
			}
		}
		say("named docker volumes are not removed — `docker volume ls` on the server, then `docker volume rm`")
		reg := p.Apps + "/mail/kasbah.yml"
		switch r.Mail {
		case "written":
			say("released %s from %s", p.MailDomain, reg)
			o.Warn("postmaster@%s is still aliased in docker-mailserver's postfix-virtual.cf", p.MailDomain)
			o.Warn("  ssh %s 'docker exec mail-dms setup alias del postmaster@%s postmaster@%s'", p.Target, p.MailDomain, p.MailPrimary)
			o.Warn("  reverse the whole release with: kasbah server add-mail-domain %s %s", p.Target, p.MailDomain)
		case "skipped":
		case "stale":
			say("FAILED to rewrite %s — it changed after drop read it", reg)
			o.Err("%s on %s changed between drop's read and its write, so it was left as it is", reg, p.Target)
			o.ErrCont("%s is still claimed there; everything else was dropped", p.MailDomain)
			bad = true
		default:
			say("FAILED to rewrite %s", reg)
			o.Err("could not rewrite %s on %s", reg, p.Target)
			o.ErrCont("%s is still claimed there; everything else was dropped", p.MailDomain)
			bad = true
		}
	}

	if bad {
		return cli.Fail("%s was not fully dropped from %s — see the FAILED line(s) above", p.Name, p.Target).Cont(
			fmt.Sprintf("nothing here is undone by running it again: `kasbah drop %s%s` picks up what is left", p.Target, p.pruneArg()))
	}
	if !p.Prune {
		say("")
		say("%s is off %s, and everything a redeploy needs is still there", p.Name, p.Target)
		if len(r.Removed) > 0 {
			say("  kasbah build-push %s   # the images this run removed", p.Target)
		} else {
			say("  kasbah build-push %s   # if this project's images are not on the server", p.Target)
		}
		if p.NeedsAllowStopped {
			say("  kasbah deploy %s --allow-stopped", p.Target)
			say("     --allow-stopped because versions.log still records the deploys, and this")
			say("     project's backup: / pre-deploy hooks name containers this drop removed")
		} else {
			say("  kasbah deploy %s", p.Target)
		}
	}
	return nil
}
