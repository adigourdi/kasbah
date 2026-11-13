// Package info is `kasbah info [USER@HOST]`: which build this is, where it is
// installed and which docs match it, and given a server, what that server
// runs — read, never changed.
package info

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/status"
	"github.com/adigourdi/kasbah/internal/version"
)

// Usage is `kasbah info --help`.
const Usage = `Usage: kasbah info [USER@HOST]

Prints this kasbah as key: value lines, in a fixed order, for a bug report or
a script: name, version, build stamp, os, arch, the binary as invoked and
resolved, how it was installed (library, checkout or other), the library
directory, and the docs/ tree on GitHub that matches this build.

With USER@HOST it then reads the server, and changes nothing there: the apps
path, whether it is prepared, the server's kasbah build and machine, and —
when the server's kasbah is this same build — its OS, Docker engine and
compose versions. A server binary that is absent or another build is left
as it is: those three lines then say unknown, and stderr says what the next
command that reaches the server would do there — ship this build over an
absent or older one (asking first over a release, from a dev build), hand the
run to a newer one, or refuse, and why. --ship-dev and --keep-server change
nothing here.
`

// ErrHelp is --help.
var ErrHelp = errors.New("help")

// Options are info's arguments.
type Options struct {
	Target string
}

// Parse reads `info [USER@HOST]`.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("info: unknown flag '%s' — info takes only USER@HOST", f)
		case o.Target != "":
			return o, cli.Fail("info: unexpected argument '%s' — info takes one USER@HOST", a)
		default:
			o.Target = a
		}
	}
	return o, nil
}

// Field is one `key: value` line.
type Field struct{ Key, Value string }

// Write prints fields, one `key: value` line each.
func Write(w io.Writer, fs []Field) {
	for _, f := range fs {
		fmt.Fprintf(w, "%s: %s\n", f.Key, f.Value)
	}
}

// Binary is the running kasbah as found: Invoked is the path it was started
// by (a symlink, often), Exe that path resolved.
type Binary struct {
	Invoked, Exe string
}

// Locate is the running binary from argv[0] and os.Executable's exe: argv[0]
// as a path, or looked up on PATH, when it resolves to exe; else exe itself.
func Locate(argv0, exe string, lookPath func(string) (string, error)) Binary {
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	inv := argv0
	if !strings.Contains(inv, "/") {
		p, err := lookPath(inv)
		if err != nil {
			return Binary{Invoked: exe, Exe: exe}
		}
		inv = p
	}
	if abs, err := filepath.Abs(inv); err == nil {
		inv = abs
	}
	if real, err := filepath.EvalSymlinks(inv); err != nil || real != exe {
		return Binary{Invoked: exe, Exe: exe}
	}
	return Binary{Invoked: inv, Exe: exe}
}

// LookPath is exec.LookPath, for Locate.
var LookPath = exec.LookPath

// Install is how the binary at exe (resolved) came to be there: library, a
// version directory under the library root (get.sh, install-dev.sh,
// self-update); checkout, a checkout's dist/; other, anywhere else.
func Install(exe string) string {
	if _, ok := launcher.VersionDir(exe); ok {
		return "library"
	}
	if _, checkout := serverbin.Home(exe); checkout {
		return "checkout"
	}
	return "other"
}

// Self is the workstation's lines; build "" is an unstamped build.
func Self(build, goos, goarch string, b Binary, getenv func(string) string) []Field {
	ver, stamp := "unstamped", "unstamped"
	if build != "" {
		stamp = build
		if v, err := version.Base(build); err == nil {
			ver = v
		} else {
			ver = build
		}
	}
	lib, err := launcher.Root(b.Exe, getenv)
	if err != nil {
		lib = "unknown (" + err.Error() + ")"
	}
	return []Field{
		{"name", "kasbah"},
		{"version", ver},
		{"build", stamp},
		{"os", goos},
		{"arch", goarch},
		{"binary", b.Invoked},
		{"resolved", b.Exe},
		{"install", Install(b.Exe)},
		{"lib", lib},
		{"docs", version.DocsURL(build, "")},
	}
}

// Facts is what `kasbah remote info` reports, as key=value lines.
type Facts map[string]string

// Collect is the facts of the machine it runs on: its OS from os-release,
// the Docker engine's and compose's versions. docker runs docker and returns
// its stdout and stderr apart: a value is stdout alone, a failure's reason
// stderr first. No docker on PATH is docker= with no docker_error.
func Collect(build, goarch string, osRelease []byte, haveDocker bool, docker func(args ...string) (stdout, stderr string, rc int)) []Field {
	fs := []Field{{"build", build}, {"arch", goarch}, {"os", PrettyName(osRelease)}}
	if !haveDocker {
		return append(fs, Field{"docker", ""}, Field{"compose", ""})
	}
	out, errOut, rc := docker("version", "--format", "{{.Server.Version}}")
	if rc == 0 {
		fs = append(fs, Field{"docker", flat(out)})
	} else {
		fs = append(fs, Field{"docker", ""}, Field{"docker_error", or(firstLine(errOut), or(firstLine(out), fmt.Sprintf("docker exited %d", rc)))})
	}
	cv, _, rc := docker("compose", "version", "--short")
	if rc != 0 {
		cv = ""
	}
	return append(fs, Field{"compose", flat(cv)})
}

// PrettyName is os-release's PRETTY_NAME, its quotes removed; "" when absent.
func PrettyName(body []byte) string {
	for _, l := range strings.Split(string(body), "\n") {
		v, ok := strings.CutPrefix(strings.TrimSuffix(l, "\r"), "PRETTY_NAME=")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		if q := v; len(q) >= 2 && (q[0] == '"' || q[0] == '\'') && q[len(q)-1] == q[0] {
			v = q[1 : len(q)-1]
			if q[0] == '"' {
				v = strings.NewReplacer(`\"`, `"`, `\\`, `\`, `\$`, `$`, "\\`", "`").Replace(v)
			}
		}
		return flat(v)
	}
	return ""
}

func flat(s string) string {
	return strings.TrimSpace(strings.Join(strings.Fields(strings.ReplaceAll(s, "\r", "")), " "))
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(strings.TrimSpace(strings.ReplaceAll(s, "\r", "")), "\n")
	if len(l) > 120 {
		l = l[:120] + "…"
	}
	return l
}

// Server is the server's lines from the probe's inspection; read runs the
// server binary's `remote info` and is called only when that binary is this
// build (the same-build rule: no other build's arm is spoken to). notes are
// for stderr; err is a read that failed, after the lines that could be had.
func Server(target string, self remote.Info, in *serverbin.Inspection, read func(bin string) ([]byte, error)) (fs []Field, notes []string, err error) {
	p := in.Probe
	prepared := "no"
	if p.Marker {
		prepared = "yes"
	}
	bin := serverbin.Path(p.Apps)
	kasbah := "none"
	switch {
	case in.Bin != nil:
		kasbah = in.Bin.Build
	case p.Bin.Present:
		kasbah = "unknown"
		if in.BinErr != nil {
			notes = append(notes, strings.Split(in.BinErr.Error(), "\n")...)
		} else {
			notes = append(notes, bin+" is there and does not run on that server")
		}
	}
	arch := strings.TrimSpace(p.Machine)
	if a, err := serverbin.Arch(p.Machine); err == nil {
		arch = a
	}
	fs = []Field{
		{"server", target},
		{"server.apps", p.Apps + " (" + p.Source + ")"},
		{"server.prepared", prepared},
		{"server.kasbah", kasbah},
		{"server.arch", arch},
	}
	unknown := []Field{{"server.os", "unknown"}, {"server.docker", "unknown"}, {"server.compose", "unknown"}}
	if !sameBuild(self, in.Bin) {
		why := "has no kasbah"
		switch {
		case in.Bin != nil:
			why = "runs kasbah " + kasbah + ", another build"
		case p.Bin.Present:
			why = "has a kasbah that cannot say which build it is"
		}
		notes = append(notes, fmt.Sprintf("the server's os, docker and compose are read by its own kasbah at this build (%s), and the server %s — info changes nothing there",
			orUnstamped(self.Build), why))
		notes = append(notes, Next(target, self, in)...)
		return append(fs, unknown...), notes, nil
	}
	out, rerr := read(bin)
	if rerr != nil {
		return append(fs, unknown...), notes, cli.Fail("could not read the facts of %s (%v, see above)", target, rerr)
	}
	kv := remote.KV(out)
	if kv["build"] == "" {
		return append(fs, unknown...), notes, cli.Fail("`remote info` on %s reported no build= — raw output:", target).Cont(
			"| " + firstLine(string(out)))
	}
	docker := or(kv["docker"], "none")
	if kv["docker"] == "" && kv["docker_error"] != "" {
		docker = "unknown (" + kv["docker_error"] + ")"
	}
	return append(fs,
		Field{"server.os", or(kv["os"], "unknown")},
		Field{"server.docker", docker},
		Field{"server.compose", or(kv["compose"], "none")},
	), notes, nil
}

// Next is what the next command that reaches the server would do with its
// binary, judged as Ensure judges it for a prepared server (the layout, the
// marker, Classify, remote.Decide) and acted on in nothing.
func Next(target string, self remote.Info, in *serverbin.Inspection) []string {
	p := in.Probe
	refuses := func(err error) []string {
		return append([]string{"the next command that reaches the server stops there:"}, strings.Split(err.Error(), "\n")...)
	}
	switch {
	case p.AppsNotDir:
		return refuses(serverbin.AppsNotDir(target, p.Apps))
	case !p.Marker:
		return refuses(serverbin.NoMarker(target, p))
	case p.MarkerUnreadable:
		return refuses(serverbin.UnreadableMarker(target, p.Apps))
	}
	if err := marker.Check(p.MarkerBody, self.Build, marker.Path(p.Apps), target, false); err != nil {
		return refuses(err)
	}
	if err := status.JudgeMarker(p.MarkerBody, marker.Path(p.Apps), target); err != nil {
		return refuses(err)
	}
	// Every command but `server status` and `server prune` (an object will do)
	// and `server init` (it rewrites them) reads the marker this way.
	if _, err := marker.Validate(p.MarkerBody, marker.Path(p.Apps), target, serverbin.InitCmd(target, p.Apps)); err != nil {
		return append([]string{"every command but `kasbah server status`, `kasbah server prune` and `kasbah server init` stops there:"}, strings.Split(err.Error(), "\n")...)
	}
	if in.BinErr != nil {
		return []string{"kasbah does not replace that binary: every command that reaches the server refuses it, as above, until it is dealt with there"}
	}
	action, err := remote.Decide(self, in.Bin)
	var newer *remote.Newer
	switch {
	case errors.As(err, &newer):
		return append(refuses(err),
			"it then hands the run to kasbah "+newer.Server+" when that build is installed on this workstation (never from a checkout), and says how to install it otherwise")
	case err != nil:
		return refuses(err)
	case action != remote.Ship:
		return nil
	}
	if _, err := serverbin.Arch(p.Machine); err != nil {
		return refuses(err)
	}
	ship := "the next command that reaches the server, such as `kasbah server status " + target + "`, ships this build; info reads them after that"
	if remote.DevOverRelease(self, in.Bin) {
		ship = "the next command that reaches the server, such as `kasbah server status " + target + "`, asks before it ships this dev build over release " +
			in.Bin.Build + " (--ship-dev ships it, --keep-server keeps the release); info reads them once both ends are one build"
	}
	return []string{ship}
}

// sameBuild is whether srv is the build self is, as the same-build rule keeps
// it (remote.Decide's Keep).
func sameBuild(self remote.Info, srv *remote.Info) bool {
	if srv == nil {
		return false
	}
	a, err := remote.Decide(self, srv)
	return err == nil && a == remote.Keep
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func orUnstamped(b string) string { return or(b, "unstamped") }

// Ctx is what a run needs from its process.
type Ctx struct {
	Out    *cli.Output
	Build  string
	GOOS   string
	GOARCH string
	Binary Binary
	Getenv func(string) string
	// Inspect connects to target and inspects it, returning the reader of
	// `remote info` there and the connection's close; unused with no target.
	Inspect func(target string) (*serverbin.Inspection, func(bin string) ([]byte, error), func(), error)
}

// Run prints the lines: the workstation's first, so a server that cannot be
// reached still leaves them on stdout.
func Run(c Ctx, o Options) error {
	Write(c.Out.Stdout, Self(c.Build, c.GOOS, c.GOARCH, c.Binary, c.Getenv))
	if o.Target == "" {
		return nil
	}
	in, read, done, err := c.Inspect(o.Target)
	if err != nil {
		return err
	}
	defer done()
	fs, notes, err := Server(o.Target, remote.Self(c.Build), in, read)
	Write(c.Out.Stdout, fs)
	for _, n := range notes {
		c.Out.Info("%s", n)
	}
	return err
}

// Dial is Ctx.Inspect over ssh: the bootstrap probe, then the server
// binary's `remote info`, bounded as every run of it is.
func Dial(target string) (*serverbin.Inspection, func(bin string) ([]byte, error), func(), error) {
	c, err := ssh.Connect(target)
	if err != nil {
		return nil, nil, nil, err
	}
	in, err := serverbin.Inspect(c)
	if err != nil {
		c.Close()
		return nil, nil, nil, err
	}
	read := func(bin string) ([]byte, error) {
		out, err := c.Run(serverbin.Bounded(bin, serverbin.RunTimeout, "info")...)
		if err != nil {
			return out, errors.New(serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
		}
		return out, nil
	}
	return in, read, c.Close, nil
}
