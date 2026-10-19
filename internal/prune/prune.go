// Package prune is `kasbah server prune`: image retention across every
// project on a server. The server binary reports (scan) and removes (rm); every
// decision is made here, from what it reported.
package prune

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/vlog"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the command's arguments.
type Options struct {
	Target string
	Yes    bool
}

// Usage is the command's --help.
const Usage = `Usage: kasbah server prune USER@HOST [--yes]

Image retention cleanup across every project on the server. Removes
<image>:<version> tags that are both older than 3 months and not among the
project's last 3 deployed versions — the version :current points at counts as
the first of the 3, and :current itself is never pruned. The time window is the
same one versions.log rotation uses.

Prints the plan and asks once before removing anything.

Flags:
  --yes   answer that question yes, for scripts. Without it and without a
          terminal, prune stops rather than assuming.

Where the server was prepared is the server's own answer: /etc/kasbah/apps-path,
falling back to /apps. There is no flag to override it — aiming a destructive
command at a tree the server does not consider its own is not a recovery path
(docs/cli.md).

A project whose deploy record cannot be read whole is skipped entirely, with a
warning: kasbah does not delete images on incomplete evidence.
`

// Parse reads the command line. There is deliberately no --apps-path.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case a == "--yes":
			o.Yes = true
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("server prune: unknown flag '%s' (expected --yes)", name)
		default:
			if o.Target != "" {
				return o, cli.Fail("server prune: unexpected argument '%s' (USER@HOST is given once)", a)
			}
			o.Target = strings.TrimSuffix(a, "\r")
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server prune: USER@HOST is required (the user kasbah deploys as is not optional)")
	}
	return o, nil
}

// Repos is the repositories a project builds: every service with a build:
// key, and its image: with the tag off. ok is false when the file does not
// parse, which is unknown and not empty.
func Repos(compose string) (repos []string, ok bool) {
	if compose == "" {
		return nil, false
	}
	docs, err := yamlx.Load([]byte(compose))
	if err != nil {
		return nil, false
	}
	seen := map[string]bool{}
	for _, d := range docs {
		var svcs []jv.Value
		sv, found := jv.Get(d, "services")
		if !found {
			return nil, false
		}
		switch s := jv.Alt(sv, nil).(type) {
		case nil:
		case *jv.Map:
			for _, k := range s.Keys() {
				v, _ := s.Get(k)
				svcs = append(svcs, v)
			}
		case []jv.Value:
			svcs = s
		default:
			return nil, false
		}
		for _, v := range svcs {
			m, isMap := v.(*jv.Map)
			if !isMap || !m.Has("build") {
				continue
			}
			img, _ := m.Get("image")
			if img == nil || img == false || img == "" {
				continue
			}
			ref := strings.TrimSuffix(jv.Raw(img), "\r")
			if ref == "" {
				continue
			}
			if b := buildpush.Base(ref); !seen[b] {
				seen[b] = true
				repos = append(repos, b)
			}
		}
	}
	return repos, true
}

// Keep is the last three distinct versions the record names, newest first,
// deploy and rollback alike. ok is false when the walk met a line it could not
// read before it had three, or the record holds no entry at all.
func Keep(r *vlog.Record) (keep []string, ok bool) {
	seen := map[string]bool{}
	for i := len(r.Items) - 1; i >= 0 && len(keep) < 3; i-- {
		it := r.Items[i]
		if !it.OK || it.Version == "" {
			return nil, false
		}
		if !seen[it.Version] {
			seen[it.Version] = true
			keep = append(keep, it.Version)
		}
	}
	return keep, len(keep) > 0
}

// Line is one candidate tag and its verdict.
type Line struct {
	Project, Tag, Verdict, Why string
}

// Skip is a project left alone whole, and why.
type Skip struct{ Name, Why string }

// Plan is the decision: every candidate in report order, the removal set in
// that same order, the skips and the projects whose declarations are unknown.
type Plan struct {
	Lines   []Line
	Remove  []string
	Skips   []Skip
	Unknown []string
}

// Decide is the policy over one scan. dataDir is the bind-mount root's name
// when it is a direct child of the apps path ("" otherwise).
func Decide(s *Scan, target, apps, dataDir string) (*Plan, error) {
	now, ok := vlog.MonthIndex(s.NowMonth + "-01")
	if !ok {
		return nil, cli.Fail("the prune probe on %s reported now_month='%s', which is not YYYY-MM", target, s.NowMonth)
	}
	cutoff := now - 3

	created := map[string]string{}
	idTags := map[string][]string{}
	tagID := map[string]string{}
	for _, im := range s.Images {
		created[im.ID] = im.Created
		idTags[im.ID] = im.Tags
		for _, t := range im.Tags {
			tagID[t] = im.ID
		}
	}
	held := map[string][]string{}
	for _, c := range s.Containers {
		held[c.Image] = append(held[c.Image], c.Name+"("+c.State+")")
	}

	var projects []Project
	for _, p := range s.Projects {
		if dataDir != "" && p.Name == dataDir {
			continue
		}
		projects = append(projects, p)
	}

	pl := &Plan{}
	repos := make([][]string, len(projects))
	reposOK := make([]bool, len(projects))
	owners := map[string][]string{}
	for i, p := range projects {
		if p.ComposeState == "ok" {
			if b, err := base64.StdEncoding.DecodeString(p.ComposeB64); err == nil {
				repos[i], reposOK[i] = Repos(string(b))
			}
		}
		if !reposOK[i] {
			repos[i] = nil
			pl.Unknown = append(pl.Unknown, p.Name)
		}
		for _, r := range repos[i] {
			owners[r] = append(owners[r], p.Name)
		}
	}
	unknown := strings.Join(pl.Unknown, " ")

	allTags := make([]string, 0, len(tagID))
	for t := range tagID {
		allTags = append(allTags, t)
	}
	sort.Strings(allTags)

	for i, p := range projects {
		skip := func(why string) { pl.Skips = append(pl.Skips, Skip{p.Name, why}) }
		if !vlog.Usable(p.ActiveState) {
			skip(fmt.Sprintf("its versions.log cannot be read (the probe called it '%s')", p.ActiveState))
			continue
		}
		raw, _ := json.Marshal(p.Probe)
		rec, err := vlog.ReadProbe(raw, target, apps+"/"+p.Name+"/"+vlog.Log)
		if err != nil {
			skip("its versions.log did not come back as base64 from " + target)
			continue
		}
		if !rec.Whole() {
			skip(rec.Note())
			continue
		}
		keep, ok := Keep(rec)
		if !ok {
			skip("its deploy record does not yield a keep set — a line the parser could not read among the newest entries, or no entry at all")
			continue
		}
		if !reposOK[i] {
			if p.ComposeState != "ok" {
				skip(fmt.Sprintf("its compose.yml cannot be read (the probe called it '%s'), so which images it builds is unknown", p.ComposeState))
			} else {
				skip("its compose.yml does not parse as YAML, so which images it builds is unknown")
			}
			continue
		}
		keepShow := strings.Join(keep, " ")
		inKeep := map[string]bool{}
		for _, v := range keep {
			inKeep[v] = true
		}
		for _, repo := range repos[i] {
			own := owners[repo]
			curID := tagID[repo+":current"]
			for _, tag := range allTags {
				version, found := strings.CutPrefix(tag, repo+":")
				if !found || version == "current" {
					continue
				}
				id := tagID[tag]
				cr := created[id]
				l := Line{Project: p.Name, Tag: tag, Verdict: "keep"}
				idx, dated := vlog.MonthIndex(cr)
				switch {
				case curID != "" && id == curID:
					l.Why = ":current points at this image"
				case len(own) != 1 || own[0] != p.Name:
					l.Why = fmt.Sprintf("%s is claimed by more than one project (%s)", repo, strings.Join(own, " "))
				case len(pl.Unknown) > 0:
					l.Why = "ownership cannot be established: " + unknown + " declare(s) images kasbah could not read, and such a file could name any repository"
				case inKeep[version]:
					l.Why = "among the last 3 deployed (" + keepShow + ")"
				case len(held[id]) > 0:
					l.Why = "held by container " + strings.Join(held[id], " ")
				case cr == "":
					l.Why = "the probe reported no creation time for it"
				case !dated:
					l.Why = fmt.Sprintf("its creation time '%s' is not a date prune can read", cr)
				case idx >= cutoff:
					l.Why = fmt.Sprintf("built %.10s, inside the 3-month window", cr)
				default:
					l.Verdict = "remove"
					l.Why = fmt.Sprintf("built %.10s, older than 3 months and not among the last 3 deployed (%s)", cr, keepShow)
					var other []string
					for _, t := range idTags[id] {
						if t != tag {
							other = append(other, t)
						}
					}
					if len(other) > 0 {
						l.Why += " — untags only, the image also carries " + strings.Join(other, " ")
					}
				}
				pl.Lines = append(pl.Lines, l)
			}
		}
	}
	sort.SliceStable(pl.Lines, func(a, b int) bool {
		if pl.Lines[a].Project != pl.Lines[b].Project {
			return pl.Lines[a].Project < pl.Lines[b].Project
		}
		return pl.Lines[a].Tag < pl.Lines[b].Tag
	})
	for _, l := range pl.Lines {
		if l.Verdict == "remove" {
			pl.Remove = append(pl.Remove, l.Tag)
		}
	}
	return pl, nil
}

// Report is the plan as the operator reads it, on stdout.
func (pl *Plan) Report(w io.Writer, target, apps string) {
	fmt.Fprintf(w, "kasbah server prune — %s (%s)\n", target, apps)
	width := 0
	for _, l := range pl.Lines {
		if len(l.Tag) > width {
			width = len(l.Tag)
		}
	}
	last := ""
	for _, l := range pl.Lines {
		if l.Project != last {
			fmt.Fprintf(w, "\n%s\n", l.Project)
			last = l.Project
		}
		fmt.Fprintf(w, "  %-6s %-*s  %s\n", l.Verdict, width, l.Tag, l.Why)
	}
	if len(pl.Skips) > 0 {
		fmt.Fprintf(w, "\nskipped — nothing of these was removed\n")
		for _, s := range pl.Skips {
			fmt.Fprintf(w, "  %s: %s\n", s.Name, s.Why)
		}
	}
	if len(pl.Unknown) > 0 {
		fmt.Fprintf(w, "\nno repository on %s is provably single-owner: kasbah could not read what\n", target)
		fmt.Fprintf(w, "images %d project(s) declare (%s), and such a file could name any\n", len(pl.Unknown), strings.Join(pl.Unknown, " "))
		fmt.Fprintf(w, "repository on this host. Nothing is removed anywhere until that is fixed.\n")
	}
	fmt.Fprintln(w)
	if len(pl.Remove) == 0 {
		fmt.Fprintf(w, "nothing to remove: every version tag on %s is inside the retention window.\n", target)
	} else {
		fmt.Fprintf(w, "%d tag(s) to remove on %s.\n", len(pl.Remove), target)
	}
}

// Session is what prune needs from a server.
type Session interface {
	// Ensure judges the marker, then ships the binary when needed; it says
	// where the apps path is and which entry under it is the data path.
	Ensure() (apps, dataDir string, err error)
	Scan(apps string) ([]byte, int)
	Remove(tags []string) ([]byte, int)
	Close()
}

// SSH is the real Session.
type SSH struct {
	Conn  *ssh.Conn
	Self  remote.Info
	Local func(arch string) (string, error)
	bin   string
}

// Dial connects.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

func (s *SSH) Ensure() (string, string, error) {
	// Prepared: the probe brings the marker's bytes back, and nothing is
	// shipped to a server whose marker prune would refuse.
	var dd string
	res, err := serverbin.Ensure(s.Conn, s.Self, s.Local, serverbin.Options{
		Prepared: func(b []byte, apps string) (err error) {
			dd, err = dataDir(b, apps, apps+"/.kasbah/server.json", s.Conn.Target.String())
			return err
		},
	})
	if err != nil {
		return "", "", err
	}
	s.bin = serverbin.Path(res.Apps)
	return res.Apps, dd, nil
}

func (s *SSH) Scan(apps string) ([]byte, int) {
	out, err := s.Conn.Run(serverbin.Bounded(s.bin, serverbin.RunTimeout, "prune", "scan", apps)...)
	return out, ssh.ExitCode(err)
}

// Remove is unbounded: one `docker image rm` per tag, however many.
func (s *SSH) Remove(tags []string) ([]byte, int) {
	out, err := s.Conn.Run(append([]string{s.bin, "remote", "prune", "rm"}, tags...)...)
	return out, ssh.ExitCode(err)
}

func (s *SSH) Close() { s.Conn.Close() }

// Ctx is what a run needs from its process.
type Ctx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	Dial     func(target string) (Session, error)
}

// readScan checks the report's keys as a protocol before any value is used.
func readScan(out []byte, target string) (*Scan, error) {
	var s Scan
	if err := remote.Decode(out, &s, []string{"now_month", "docker_error", "images", "containers", "projects", "project_count"},
		"the prune probe", target); err != nil {
		return nil, err
	}
	if s.Count != len(s.Projects) {
		return nil, cli.Fail("the prune probe on %s counted %d projects and described %d", target, s.Count, len(s.Projects)).Cont(
			"the payload was truncated — nothing was removed")
	}
	return &s, nil
}

// dataDir is the marker's data_path when it is a direct child of apps.
func dataDir(body []byte, apps, path, target string) (string, error) {
	v, err := jv.ParseOne(body)
	m, ok := v.(*jv.Map)
	if err != nil || !ok {
		return "", cli.Fail("%s on %s does not parse — prune will not decide a deletion against a marker it cannot read", path, target)
	}
	dv, _ := m.Get("data_path")
	data := strings.TrimRight(jv.ToString(jv.Alt(dv, "")), "\n")
	rest, found := strings.CutPrefix(data, apps+"/")
	if !found || rest == "" || strings.Contains(rest, "/") {
		return "", nil
	}
	return rest, nil
}

// Run is the command.
func Run(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	apps, dd, err := s.Ensure()
	if err != nil {
		return err
	}
	out, rc := s.Scan(apps)
	if rc != 0 {
		return cli.Fail("the prune probe on %s exited %d", o.Target, rc).Cont(
			"nothing was removed — prune reads the whole server before it deletes anything")
	}
	sc, err := readScan(out, o.Target)
	if err != nil {
		return err
	}
	if sc.DockerError != "" {
		return cli.Fail("docker did not answer on %s", o.Target).Cont(sc.DockerError,
			"prune has nothing to read and has removed nothing")
	}
	pl, err := Decide(sc, o.Target, apps, dd)
	if err != nil {
		return err
	}
	pl.Report(c.Out.Stdout, o.Target, apps)

	if len(pl.Skips) > 0 {
		c.Out.Warn("%d project(s) were skipped whole — see the report above", len(pl.Skips))
		c.Out.Warn("  kasbah does not remove images on a record it could not read")
	}
	if len(pl.Unknown) > 0 {
		c.Out.Warn("nothing was removed anywhere: %s declare images kasbah could", strings.Join(pl.Unknown, " "))
		c.Out.Warn("  not read, so no repository on this server is provably single-owner")
	}
	if len(pl.Remove) == 0 {
		return nil
	}
	yes, err := c.Prompter.Confirm("yes", fmt.Sprintf("remove %d image tag(s) from %s?", len(pl.Remove), o.Target), o.Yes)
	if err != nil {
		return err
	}
	if !yes {
		return cli.Fail("not confirmed — nothing was removed")
	}
	return remove(c, s, o.Target, pl.Remove)
}

func remove(c Ctx, s Session, target string, tags []string) error {
	for _, t := range tags {
		if strings.HasPrefix(t, "-") || strings.ContainsAny(t, " \t\n\r\v\f") {
			return cli.Fail("refusing to remove '%s' on %s: that is not an image tag docker gave back", t, target)
		}
	}
	out, rc := s.Remove(tags)
	if rc != 0 {
		return cli.Fail("the removal step on %s exited %d", target, rc).Cont(
			fmt.Sprintf("some of the %d tags may have been removed — `kasbah server prune %s` again to see", len(tags), target))
	}
	removed, failed := 0, 0
	for _, l := range strings.Split(string(out), "\n") {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		var r Removal
		if json.Unmarshal([]byte(l), &r) != nil {
			continue
		}
		switch {
		case r.Removed != "":
			removed++
			fmt.Fprintf(c.Out.Stdout, "  removed %s\n", r.Removed)
		case r.Failed != "":
			failed++
			reason := r.Reason
			if reason == "" {
				reason = "(no reason given)"
			}
			c.Out.Err("could not remove %s on %s: %s", r.Failed, target, reason)
		}
	}
	if removed+failed != len(tags) {
		return cli.Fail("the removal step on %s accounted for %d of %d tags", target, removed+failed, len(tags)).Cont(
			"the step was truncated; run prune again to see what is left")
	}
	c.Out.Info("removed %d of %d tag(s) on %s", removed, len(tags), target)
	if failed > 0 {
		return &cli.Error{Code: cli.ExitFailure}
	}
	return nil
}
