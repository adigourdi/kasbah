// Package history is `kasbah history`, `pending` and `changelog`, three
// readers of one deploy record (internal/vlog). stdout is the answer about the
// server; diagnostics about this checkout or the transport go to stderr.
package history

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are one command's arguments.
type Options struct {
	Cmd             string
	Target, Version string
	All             bool
}

var usages = map[string]string{
	"history": `Usage: kasbah history [USER@HOST] [--all]

The deploy record on a server, as a table: timestamp, action, version, backup
file, kasbah version. Run from the project root. USER@HOST defaults to the last
server this project talked to (.kasbah/state.json).

By default the table is <apps>/<name>/versions.log — the active log. --all puts
the entries rotation moved into versions.log.gz in front of them, oldest first,
so the table spans the rotation point in one run.

A line the reader cannot get four fields out of is shown as it stands, marked
'!!': a write killed mid-append leaves exactly that, and it is still a deploy
that ran.

Reads the server's record and changes nothing in it — the one write is the
kasbah binary, installed when the server's is absent or older. See docs/build-deploy.md.
`,
	"pending": `Usage: kasbah pending [USER@HOST] [VERSION]

The commits between the version a server is running and this checkout — the
answer to "what would deploying ship", asked before a tag is cut. Run from the
project root.

The deployed version is read out of the server's versions.log at run time, never
out of .kasbah/state.json: state is this workstation's cache of what it last
did, and the server is what is running.

With VERSION, the range ends at v<VERSION> instead of HEAD.
An argument containing '@' is the server, anything else is the version.

Reads the server's record and changes nothing in it — the one write is the
kasbah binary, installed when the server's is absent or older. See docs/cli.md.
`,
	"changelog": `Usage: kasbah changelog [USER@HOST]

What changed in the version a server is running now: the commits between the
last two entries of its deploy record. Run from the project root.

The last two entries whatever their action — after a rollback the version
running is the rollback's target, and the range then runs backwards, which is
reported as what the rollback gave up rather than as an error.

Reads the server's record and changes nothing in it — the one write is the
kasbah binary, installed when the server's is absent or older. See docs/cli.md.
`,
}

// Usage is cmd's --help.
func Usage(cmd string) string { return usages[cmd] }

// Parse reads history's, pending's or changelog's arguments.
func Parse(cmd string, args []string) (Options, error) {
	o := Options{Cmd: cmd}
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--all":
			if cmd != "history" {
				t := o.Target
				if t == "" {
					t = "USER@HOST"
				}
				return o, cli.Fail("%s: unknown flag '--all' — the archived half of the record is `kasbah history %s --all`", cmd, t)
			}
			o.All = true
		case strings.HasPrefix(a, "--all="):
			return o, cli.Fail("%s: --all takes no value — pass it on its own (`kasbah history USER@HOST --all`)", cmd)
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			switch cmd {
			case "history":
				return o, cli.Fail("history: unknown flag '%s' (history takes USER@HOST and --all)", name)
			case "pending":
				return o, cli.Fail("pending: unknown flag '%s' (pending takes USER@HOST and VERSION)", name)
			}
			return o, cli.Fail("%s: unknown flag '%s' (%s takes USER@HOST)", cmd, name, cmd)
		default:
			arg := strings.TrimSuffix(a, "\r")
			if cmd != "pending" && !strings.Contains(arg, "@") {
				return o, cli.Fail("%s: '%s' is not a server — USER@HOST carries an '@', and %s takes no version (`kasbah pending [VERSION]` is the one that does)", cmd, arg, cmd)
			}
			if err := deploy.Classify(cmd, arg, &o.Target, &o.Version); err != nil {
				return o, err
			}
		}
	}
	return o, nil
}

// Session is what the three need from a server.
type Session interface {
	Marker() (*marker.Marker, error)
	Record(apps, name string) (*vlog.Record, error)
	Close()
}

// SSH is the real Session: no rsync needed.
type SSH struct{ *env.SSH }

// Dial connects; Marker ensures the server's binary.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

// Record reads both halves of the deploy record in one round trip.
func (s *SSH) Record(apps, name string) (*vlog.Record, error) {
	return deploy.FetchRecord(s.SSH, apps, name)
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out     *cli.Output
	Version string
	Dial    func(target string) (Session, error)
}

type run struct {
	c      Ctx
	o      Options
	name   string
	target string
	r      *vlog.Record
}

// Run is the command; last_server is recorded only once the report printed.
func Run(c Ctx, o Options) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	x := &run{c: c, o: o, name: m.Name, target: o.Target}
	if x.target == "" {
		stored, err := state.Get(state.File, "last_server")
		if err != nil {
			return err
		}
		if stored == "" || stored == "null" {
			return cli.Fail("%s: no server given, and this project has never deployed to one", o.Cmd).Cont(
				"pass it once — `kasbah "+o.Cmd+" user@vps` — and it is remembered in",
				state.File+" as last_server")
		}
		x.target = stored
	}
	if x.r, err = x.read(); err != nil {
		return err
	}
	for _, w := range x.r.Warnings {
		c.Out.Warn("%s", w)
	}
	switch o.Cmd {
	case "history":
		x.history()
	case "pending":
		x.pending()
	default:
		x.changelog()
	}
	return state.Record(state.File, c.Version, "last_server", x.target)
}

// read holds the connection only as long as the round trip.
func (x *run) read() (*vlog.Record, error) {
	s, err := x.c.Dial(x.target)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return nil, err
	}
	return s.Record(mk.AppsPath, x.name)
}

func (x *run) printf(format string, a ...any) { fmt.Fprintf(x.c.Out.Stdout, format, a...) }

func base(p string) string { return p[strings.LastIndex(p, "/")+1:] }

func word(n int) string {
	if n == 1 {
		return "entry"
	}
	return "entries"
}

func (x *run) offers() string {
	if x.r.Whole() {
		return "shows the whole record"
	}
	return "shows what could be read of it"
}

func (x *run) note() {
	if n := x.r.Note(); n != "" {
		x.printf("%s\n", n)
	}
}

// history is the table: five columns padded to the widest value shown, never
// narrower than the headings. An unparsed line is not a row — it is shown as
// the file holds it, marked, in its place.
func (x *run) history() {
	r := x.r
	nArch, nAct, nBad := 0, 0, 0
	w := [4]int{9, 6, 7, 6}
	type row struct {
		i, ord int
	}
	var shown []row
	for i, it := range r.Items {
		var ord int
		if it.Archived {
			nArch++
			ord = nArch
			if !x.o.All {
				continue
			}
		} else {
			nAct++
			ord = nAct
		}
		shown = append(shown, row{i, ord})
		if !it.OK {
			nBad++
			continue
		}
		for k, v := range []string{it.Time, it.Action, it.Version, it.Backup} {
			w[k] = max(w[k], utf8.RuneCountInString(v))
		}
	}
	if len(shown) == 0 {
		x.empty(nArch)
		return
	}
	line := func(a, b, c, d, e string) {
		x.printf("%-*s  %-*s  %-*s  %-*s  %s\n", w[0], a, w[1], b, w[2], c, w[3], d, e)
	}
	line("TIMESTAMP", "ACTION", "VERSION", "BACKUP", "KASBAH")
	sep := false
	for _, s := range shown {
		it := r.Items[s.i]
		if !sep && !it.Archived && nArch > 0 && x.o.All {
			sep = true
			x.printf("-- rotated into %s above / %s below --\n", base(r.ArchivePath), base(r.ActivePath))
		}
		if !it.OK {
			file := base(r.ActivePath)
			if it.Archived {
				file = base(r.ArchivePath)
			}
			x.printf("!! entry %d of %s is not a kasbah entry: %s\n", s.ord, file, strings.TrimSuffix(it.Raw, "\r"))
			continue
		}
		k := it.Kasbah
		if k == "" {
			k = "-"
		}
		line(it.Time, it.Action, it.Version, it.Backup, k)
	}
	if x.o.All {
		x.printf("%d %s on %s — %d archived in %s, %d active in %s\n",
			len(shown), word(len(shown)), x.target, nArch, r.ArchivePath, nAct, r.ActivePath)
	} else {
		x.printf("%d %s in %s on %s\n", nAct, word(nAct), r.ActivePath, x.target)
		if nArch > 0 {
			x.printf("%d more %s archived in %s — `kasbah history %s --all` %s\n",
				nArch, word(nArch), base(r.ArchivePath), x.target, x.offers())
		}
	}
	if nBad > 0 {
		x.printf("%d of them could not be read as a kasbah entry and are shown above as !!\n", nBad)
	}
	x.note()
}

// empty is no row to draw, and which of the reasons it is.
func (x *run) empty(nArch int) {
	r := x.r
	switch {
	case !x.o.All && nArch > 0:
		x.printf("no entry in %s on %s — %d archived %s in %s\n", r.ActivePath, x.target, nArch, word(nArch), base(r.ArchivePath))
		x.printf("rotation never empties the active log, so this is a log that was lost or replaced — `kasbah history %s --all` %s\n", x.target, x.offers())
	case r.ActiveState == "empty":
		x.printf("%s on %s is empty — no deploy of %s is recorded there\n", r.ActivePath, x.target, x.name)
	default:
		x.printf("no deploy record for %s on %s — there is no %s\n", x.name, x.target, r.ActivePath)
	}
	x.note()
}

// deployed is the active log's last entry and the header both changelogs
// open with; -1, reason printed, when there is none to compare against —
// "no entry" and "an entry that will not parse" being different answers.
func (x *run) deployed() int {
	r := x.r
	idx := r.LastActive()
	if idx < 0 {
		nArch, _ := r.Count()
		switch {
		case nArch > 0:
			x.printf("%s holds no entry for %s, and its archive does — so this is a record that was lost or replaced, not a first deploy\n", r.ActivePath, x.name)
		case r.Whole():
			x.printf("%s has never deployed %s — %s holds no entry, and neither does its archive\n", x.target, x.name, r.ActivePath)
		default:
			x.printf("%s holds no entry for %s, and whether its archive holds one cannot be told — this is not evidence that %s has never deployed it\n", r.ActivePath, x.name, x.target)
		}
		x.note()
		return -1
	}
	it := r.Items[idx]
	if !it.OK {
		x.printf("%s has deployed %s, and the last line of %s is not one a version can be read out of:\n", x.target, x.name, r.ActivePath)
		x.printf("  %s\n", strings.TrimSuffix(it.Raw, "\r"))
		x.printf("a write killed mid-append leaves exactly that, and the deploy it recorded is still one that ran — so there is no version here to compare against\n")
		return -1
	}
	x.printf("%s runs %s %s (%s, %s)\n", x.target, x.name, it.Version, it.Action, it.Time)
	return idx
}

func haveRef(ref string) bool {
	return exec.Command("git", "rev-parse", "-q", "--verify", ref+"^{commit}").Run() == nil
}

func commit(ref string) string {
	out, err := exec.Command("git", "rev-parse", "-q", "--verify", ref+"^{commit}").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func sameCommit(a, b string) bool {
	ca, cb := commit(a), commit(b)
	return ca != "" && ca == cb
}

// gitLog is git's to explain when it fails; it has said so on stderr.
func gitLog(rng string) (string, bool) {
	cmd := exec.Command("git", "log", "--no-color", "--format=%h %s", rng, "--")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return strings.TrimRight(string(out), "\n"), true
}

func (x *run) printLog(rng, log string) {
	lines := strings.Split(log, "\n")
	s := "s"
	if len(lines) == 1 {
		s = ""
	}
	x.printf("%s — %d commit%s\n", rng, len(lines), s)
	for _, l := range lines {
		x.printf("  %s\n", l)
	}
}

func (x *run) pending() {
	o := x.c.Out
	idx := x.deployed()
	if idx < 0 {
		return
	}
	deployed := x.r.Items[idx].Version
	label, ref := "HEAD", "HEAD"
	if x.o.Version != "" {
		label, ref = "v"+x.o.Version, "refs/tags/v"+x.o.Version
	}
	rng := "v" + deployed + ".." + label
	if !haveRef("refs/tags/v" + deployed) {
		o.Warn("%s is running %s and this checkout has no tag v%s — nothing to compare against", x.target, deployed, deployed)
		o.Warn("`git fetch --tags`, then `git log %s`", rng)
		return
	}
	if !haveRef(ref) {
		if x.o.Version != "" {
			o.Warn("v%s is not a tag in this checkout — `git fetch --tags`, or cut it first", x.o.Version)
		} else {
			o.Warn("this checkout has no HEAD commit — there is nothing yet to be pending")
		}
		return
	}
	log, ok := gitLog(rng)
	if !ok {
		o.Warn("could not read `git log %s` (see git's error above) — nothing pending can be listed", rng)
		return
	}
	switch {
	case log != "":
		x.printLog(rng, log)
	case sameCommit("refs/tags/v"+deployed, ref):
		x.printf("%s — nothing pending: %s is the commit %s is already running\n", rng, label, x.target)
	default:
		x.printf("%s — nothing pending: %s is not ahead of the %s %s is running\n", rng, label, deployed, x.target)
		x.printf("`git log %s..v%s` is what deploying it would give up\n", label, deployed)
	}
}

// changelog is the last two entries whatever their action, spanning the
// rotation point without noticing it.
func (x *run) changelog() {
	o, r := x.c.Out, x.r
	idx := x.deployed()
	if idx < 0 {
		return
	}
	curr := r.Items[idx].Version
	if idx == 0 {
		if r.Whole() {
			x.printf("nothing in the record before it — %s is the first version %s ran here\n", curr, x.target)
		} else {
			x.printf("nothing readable in the record before it, so there is no range to compare against\n")
			x.note()
		}
		return
	}
	p := r.Items[idx-1]
	if !p.OK {
		x.printf("the entry before it is not one a version can be read out of:\n")
		x.printf("  %s\n", strings.TrimSuffix(p.Raw, "\r"))
		x.printf("so there is no range to compare against — look at %s on %s\n", r.ActivePath, x.target)
		return
	}
	prev := p.Version
	arch := ""
	if p.Archived {
		arch = ", archived"
	}
	x.printf("after %s (%s, %s%s)\n", prev, p.Action, p.Time, arch)
	// A truncated member loses the newest archived entries — the ones right
	// against the active log — so the range may be across a gap.
	if p.Archived && !r.Whole() {
		x.printf("that entry came out of an archive this run could only read part of, so an entry between it and %s may be inside the part that could not be decoded\n", curr)
		x.note()
	}
	rng := "v" + prev + "..v" + curr
	for _, v := range []string{prev, curr} {
		if !haveRef("refs/tags/v" + v) {
			o.Warn("this checkout has no tag v%s — no changelog", v)
			o.Warn("`git fetch --tags`, then `git log %s`", rng)
			return
		}
	}
	log, ok := gitLog(rng)
	if !ok {
		o.Warn("could not read `git log %s` (see git's error above) — no changelog", rng)
		return
	}
	switch {
	case log != "":
		x.printLog(rng, log)
	case prev == curr:
		x.printf("%s — none: %s was already the version there, so the entry above it is a redeploy\n", rng, curr)
	default:
		x.printf("%s — none: %s is not ahead of the %s it replaced\n", rng, curr, prev)
		x.printf("`git log v%s..v%s` is what that gave up\n", curr, prev)
	}
}
