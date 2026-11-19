package migrate

import (
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the command's arguments: `kasbah migrate` in a project, or
// `kasbah migrate server [USER@]HOST [--yes] [--undo]`.
type Options struct {
	Server bool
	Target string
	Yes    bool
	Undo   bool
}

// Usage is the command's --help.
const Usage = `Usage: kasbah migrate
       kasbah migrate server [USER@]HOST [--yes] [--undo]

Crosses a major. Within a major nothing migrates: a newer kasbah reads every
older file of its major and rewrites one only when it writes it anyway. A
change that cannot be read that way is the next major, and this command is
how a project and a server get there (docs/overview.md → Version
compatibility).

  kasbah migrate            in a project: rewrites kasbah.yml and the files
                            under it from their schema to this kasbah's, stamps
                            kasbah_version, and records each step in
                            .kasbah/state.json. At this kasbah's schema already:
                            nothing to do, exit 0.
  kasbah migrate server     on a server: ships this build (the one command that
                            puts a new major on a server of an older one), takes
                            <apps>/.kasbah/migrate.lock and every project's
                            .deploy.lock, snapshots every file the steps touch
                            and the marker into <apps>/.kasbah/migrate/, rewrites
                            file by file, and writes the marker last. Afterwards
                            every workstation of the old major is refused by the
                            server. Idempotent: a file already at the target is
                            skipped, so a run that died halfway is finished by
                            the next. Every file a step rewrites is rewritten
                            in memory first: one it cannot rewrite stops the
                            run before any is. Before asking, the plan lists
                            what will lose its route and any file that would
                            stop it; a step's live action (1->2 disconnects
                            Traefik from kasbah-net) runs after its files,
                            before the marker.

  --undo    put the newest snapshot back, marker included — files only: the
            server binary stays this build, and Traefik is not put back on
            kasbah-net (the report says how). Refused when any project's
            versions.log has an entry newer than the snapshot: the tarball is
            named for the manual path.
  --yes     answer the confirmation, for scripts. Without it and without a
            terminal, migrate stops rather than assuming.
`

// Parse reads the command line; every argument meets it with its CR off.
func Parse(args []string) (Options, error) {
	o, err := parse(args)
	if err == nil {
		o.Target, err = ssh.ResolveTarget("migrate server", o.Target)
	}
	return o, err
}

func parse(args []string) (Options, error) {
	var o Options
	for i, raw := range args {
		a := strings.TrimSuffix(raw, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case i == 0 && a == "server":
			o.Server = true
		case a == "--yes":
			o.Yes = true
		case a == "--undo":
			o.Undo = true
		case strings.HasPrefix(a, "--yes=") || strings.HasPrefix(a, "--undo="):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("migrate: %s takes no value — pass it on its own", f)
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("migrate: unknown flag '%s' (migrate takes `server [USER@]HOST`, --yes and --undo)", f)
		case !o.Server:
			return o, cli.Fail("migrate: unexpected argument '%s' — in a project, migrate takes none; for a server, `kasbah migrate server [USER@]HOST`", a)
		default:
			if o.Target != "" {
				return o, cli.Fail("migrate server: two servers given ('%s' and '%s') — one run goes to one server", o.Target, a)
			}
			o.Target = a
		}
	}
	if o.Server && o.Target == "" {
		return o, cli.Fail("migrate server: no server given (expected `kasbah migrate server [USER@]HOST`)")
	}
	if !o.Server && (o.Yes || o.Undo) {
		return o, cli.Fail("migrate: --yes and --undo belong to `kasbah migrate server [USER@]HOST`; a project migration asks nothing and keeps no snapshot")
	}
	return o, nil
}

// Session is what migrate server needs from a server.
type Session interface {
	// Marker ships this build, an older-major marker admitted, and validates
	// the marker; a server with none is exit 4.
	Marker() (*marker.Marker, string, error)
	Migrate(apps, ours string, undo bool) ([]byte, int)
	// Probe is `kasbah remote migrate --probe`: a ProbeReport, read-only.
	Probe(apps, ours string) ([]byte, int)
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

func (s *SSH) Marker() (*marker.Marker, string, error) {
	target := s.Conn.Target.String()
	var mk *marker.Marker
	res, err := serverbin.Ensure(s.Conn, s.Self, s.Local, serverbin.Options{Migrating: true, Prepared: func(body []byte, apps string) (err error) {
		mk, err = marker.Validate(body, marker.Path(apps), target, serverbin.InitCmd(target, apps))
		return err
	}})
	if err != nil {
		return nil, "", err
	}
	s.bin = serverbin.Path(res.Apps)
	return mk, res.Apps, nil
}

func (s *SSH) Migrate(apps, ours string, undo bool) ([]byte, int) {
	args := []string{s.bin, "remote", "migrate", "--apps=" + apps, "--version=" + ours}
	if undo {
		args = append(args, "--undo")
	}
	out, err := s.Conn.Run(args...)
	return out, ssh.ExitCode(err)
}

func (s *SSH) Probe(apps, ours string) ([]byte, int) {
	out, err := s.Conn.Run(s.bin, "remote", "migrate", "--apps="+apps, "--version="+ours, "--probe")
	return out, ssh.ExitCode(err)
}

func (s *SSH) Close() { s.Conn.Close() }

// Ctx is what a run needs from its process.
type Ctx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	// Version is this kasbah's VERSION: what the marker will record.
	Version string
	Dial    func(target string) (Session, error)
	Now     func() time.Time
}

// RunServer is `kasbah migrate server`.
func RunServer(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, apps, err := s.Marker()
	if err != nil {
		return err
	}
	from, to, err := Majors(mk.JSON, c.Version)
	if err != nil {
		return cli.Fail("cannot migrate %s: %v", o.Target, err)
	}
	w := c.Out.Stdout
	path := marker.Path(apps)
	v, _ := mk.JSON.Get("kasbah_version")
	recorded := strings.TrimRight(fmt.Sprint(v), "\n")
	if o.Undo {
		fmt.Fprintf(w, "undo the last migration of %s from its snapshot under %s: a run that stopped partway has the files it rewrote put back, %s untouched; else the newest finished one goes back, %s last\n", o.Target, filepath.Join(apps, Dir), path, path)
		fmt.Fprintf(w, "refused if it has a file to put back and any project has deployed since it was taken\n")
		return confirmAndRun(c, s, o, apps, fmt.Sprintf("Undo? Once a finished migration goes back, this kasbah's major is refused until it is migrated again, and the server binary stays this build, which a workstation of the old major refuses until that major's binary is put at %s by hand.", serverbin.Path(apps)))
	}
	if from == to {
		fmt.Fprintf(w, "nothing to migrate: %s on %s is at major %d (kasbah %s), which is this kasbah's\n", path, o.Target, from, recorded)
		return nil
	}
	plan, err := Plan(Server, from, to)
	if err != nil {
		return cli.Fail("cannot migrate %s: %v", o.Target, err)
	}
	fmt.Fprintf(w, "migrate %s: %s from major %d (kasbah %s) to %d (kasbah %s)\n", o.Target, path, from, recorded, to, c.Version)
	warns := false
	for _, st := range plan {
		fmt.Fprintf(w, "  step %d->%d: %s\n", st.From, st.To, st.Desc)
		warns = warns || st.Warn != nil
	}
	fmt.Fprintf(w, "  snapshot: %s, written before anything is rewritten\n", filepath.Join(apps, Dir, SnapshotName(from, to, c.Now())))
	fmt.Fprintf(w, "  locks: %s and every project's .deploy.lock, taken without waiting\n", filepath.Join(apps, Lock))
	if warns {
		printProbe(w, s, apps, c.Version, o.Target)
	}
	return confirmAndRun(c, s, o, apps, fmt.Sprintf("Migrate? Every kasbah workstation older than %d.x will be refused by this server afterwards.", to))
}

// printProbe lists, before the prompt, what the plan will cost on target:
// a warning, never a refusal, as the prompt is the way to stop.
func printProbe(w io.Writer, s Session, apps, ours, target string) {
	out, rc := s.Probe(apps, ours)
	var r ProbeReport
	err := remote.Decode(out, &r, ProbeKeys, "the migration probe", target)
	switch {
	case rc != 0:
		fmt.Fprintf(w, "  what will lose its route is unjudged: the probe on %s exited %d (see above); the run's report lists it\n", target, rc)
		return
	case err != nil:
		fmt.Fprintf(w, "  what will lose its route is unjudged: %v; the run's report lists it\n", err)
		return
	}
	list := func(head string, l []string) {
		fmt.Fprintf(w, "  %s\n", head)
		for _, x := range l {
			fmt.Fprintf(w, "    - %s\n", x)
		}
	}
	if len(r.Stops) > 0 {
		list("will stop before rewriting any file (fix it by hand first):", r.Stops)
	}
	if len(r.Warnings) == 0 {
		fmt.Fprintf(w, "  nothing found that will lose its route\n")
	} else {
		list("will lose its route (answer no to stop here):", r.Warnings)
	}
	if len(r.Notes) > 0 {
		list("left as it is:", r.Notes)
	}
}

func confirmAndRun(c Ctx, s Session, o Options, apps, question string) error {
	yes, err := c.Prompter.Confirm("yes", question, o.Yes)
	if err != nil {
		return err
	}
	if !yes {
		return cli.Fail("not confirmed — nothing was changed on %s", o.Target)
	}
	out, rc := s.Migrate(apps, c.Version, o.Undo)
	if rc != 0 {
		e := cli.Fail("the migration step on %s exited %d (see above)", o.Target, rc)
		again := "kasbah migrate server " + o.Target
		if rc == ExitRefused {
			var rf Refusal
			if err := remote.Decode(out, &rf, RefusalKeys, "the migration step", o.Target); err != nil {
				same := again
				if o.Undo {
					same += " --undo"
				}
				return e.Cause(err).Cont("nothing was changed on " + o.Target + ": the server refused, but its refusal's report did not read back").
					Next("Re-run `" + same + "` to see the refusal again.")
			}
			return e.Next(rf.Step(o.Target, o.Undo))
		}
		// Only a run that stopped partway is resumed by a re-run.
		if rc == ExitPartway {
			if o.Undo {
				e.Next("Once the cause above is fixed, re-run `" + again + " --undo`: it picks the same snapshot again, which is noted undone only once every file is back.")
			} else {
				e.Next("Once the cause above is fixed, re-run `"+again+"`: it picks up where it stopped, skipping every file already rewritten.",
					"Or go back: `"+again+" --undo` puts back from its snapshot any file it rewrote.")
			}
		}
		return e
	}
	var r Report
	if err := remote.Decode(out, &r, Keys, "the migration step", o.Target); err != nil {
		return err
	}
	Print(c.Out.Stdout, o.Target, &r)
	return nil
}

// Print is a report in words.
func Print(w io.Writer, target string, r *Report) {
	switch {
	case r.Undo && r.Marker == "unchanged" && len(r.Restored) == 0:
		fmt.Fprintf(w, "undone on %s: the run from major %d to %d had stopped; every file still there already matches what %s holds — closed, the marker unchanged at major %d\n", target, r.From, r.To, r.Snapshot, r.From)
		printGone(w, r)
	case r.Undo && r.Marker == "unchanged":
		fmt.Fprintf(w, "undone on %s: the run from major %d to %d that stopped partway — %d file(s) put back from %s; the marker is unchanged, still at major %d\n", target, r.From, r.To, len(r.Restored), r.Snapshot, r.From)
		for _, f := range r.Restored {
			fmt.Fprintf(w, "  restored %s\n", f)
		}
		printGone(w, r)
	case r.Undo:
		fmt.Fprintf(w, "undone on %s: %s restored (%d file(s), the marker %s) — the marker is back at major %d\n", target, r.Snapshot, len(r.Restored), r.Marker, r.From)
		for _, f := range r.Restored {
			fmt.Fprintf(w, "  restored %s\n", f)
		}
		printGone(w, r)
		apps := filepath.Dir(filepath.Dir(filepath.Dir(r.Snapshot)))
		fmt.Fprintf(w, "  the server binary is still this build, which a kasbah of major %d refuses as newer: to manage %s with one, put that kasbah's server build (the release asset kasbah_<version>_linux_<arch>) at %s by hand\n", r.From, target, serverbin.Path(apps))
	case r.Nothing:
		fmt.Fprintf(w, "nothing to migrate on %s: the marker is already at major %d\n", target, r.To)
	default:
		reused := ""
		if r.SnapshotReused {
			reused = " (an earlier run's, kept: it holds the originals)"
		}
		fmt.Fprintf(w, "migrated %s from major %d to %d; snapshot %s%s\n", target, r.From, r.To, r.Snapshot, reused)
		printSteps(w, r.Steps)
		fmt.Fprintf(w, "  marker %s\n", r.Marker)
	}
	for _, l := range r.Left {
		fmt.Fprintf(w, "  %s\n", l)
	}
}

// printSteps is each step's files, what its live action did, and its cost.
func printSteps(w io.Writer, steps []StepReport) {
	for _, s := range steps {
		fmt.Fprintf(w, "  step %d->%d: %d file(s)\n", s.From, s.To, len(s.Files))
		for _, f := range s.Files {
			fmt.Fprintf(w, "    %s %s\n", f.Path, f.Action)
		}
		for _, l := range s.Done {
			fmt.Fprintf(w, "    %s\n", l)
		}
		for _, l := range s.Warnings {
			fmt.Fprintf(w, "    warning: %s\n", l)
		}
		for _, l := range s.Notes {
			fmt.Fprintf(w, "    note: %s\n", l)
		}
	}
}

func printGone(w io.Writer, r *Report) {
	for _, f := range r.Gone {
		fmt.Fprintf(w, "  not restored %s: its directory is gone\n", f)
	}
}
