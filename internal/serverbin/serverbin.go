// Package serverbin puts kasbah's own binary on a server, at the one shared
// path <apps>/.kasbah/bin/kasbah, under the same-build rule: absent or older
// is replaced by this build's, the same is kept, a newer one refuses — the
// workstation then runs the server's build (remote.Newer). A dev build asks
// before it replaces a release (ShipDev).
package serverbin

import (
	"bufio"
	"bytes"
	"cmp"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/selfupdate"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/trace"
	"github.com/adigourdi/kasbah/internal/version"
)

// Pointer and DefaultApps are where a server's apps path is discovered
// (docs/server-setup.md, the discovery pointer).
const (
	Pointer     = "/etc/kasbah/apps-path"
	DefaultApps = "/apps"
)

// DevFlags answer ShipDev's question on the command line.
var DevFlags = prompt.Pair{Yes: "ship-dev", No: "keep-server"}

// ShipDev is whether this dev build replaces the release the server runs
// (remote.DevOverRelease); false keeps the server's, and the run goes to its
// build (remote.Kept). main answers it from DevFlags or the terminal; unset,
// it reads no terminal and fails naming the flags.
var ShipDev = func(server, ours string) (bool, error) {
	noTTY := &prompt.Prompter{In: strings.NewReader(""), Out: cli.Std()}
	return AskShipDev(noTTY, prompt.Unset, server, ours)
}

// AskShipDev is ShipDev's question, answered by given or asked on p.
func AskShipDev(p *prompt.Prompter, given prompt.Given, server, ours string) (bool, error) {
	return p.Choice(DevFlags, fmt.Sprintf(
		"the server runs the release kasbah %s; replace it with this dev build %s? (no keeps %s, and the command runs on %s if it is installed here, else stops)",
		server, ours, server, server), given)
}

// Notes carries the line naming each change of the server's binary.
var Notes = cli.Std()

// RunTimeout bounds every run of a server binary, in seconds.
var RunTimeout = 30

// The probe's two inputs, variables so a test can point them at a scratch tree.
var probePointer, probeDefault = Pointer, DefaultApps

// Path is the server binary's path under an apps path.
func Path(apps string) string { return apps + "/.kasbah/bin/kasbah" }

// Arch maps `uname -m` to the GOARCH a server binary is built for.
func Arch(machine string) (string, error) {
	switch strings.TrimSpace(machine) {
	case "x86_64":
		return "amd64", nil
	case "aarch64", "arm64":
		return "arm64", nil
	}
	return "", cli.Fail("the server's machine type is '%s', and kasbah builds server binaries for x86_64 and aarch64 only", strings.TrimSpace(machine))
}

// fetchRelease is the lazy fetch (selfupdate.FetchServerBuild), a variable
// so a test can stand in for the network.
var fetchRelease = func(home, ver, arch string) error {
	return selfupdate.FetchServerBuild(cli.Std(), home, ver, arch)
}

// Local is this build's server binary for arch: dist/server/ in a checkout,
// server/ beside the binary in an installed version directory (install-dev.sh).
// An installed release version (its directory a version with no pre-release
// part) missing the build fetches it from the release, verified, into place;
// a dev build and a checkout never fetch.
func Local(home string, checkout bool, arch string) (string, error) {
	name := "kasbah-linux-" + arch
	p := filepath.Join(home, "server", name)
	remedy := "Reinstall kasbah (./install-dev.sh), which installs both server binaries."
	if checkout {
		p = filepath.Join(home, "dist", "server", name)
		remedy = "Build it: `docker compose run --rm build`."
	}
	if isFile(p) {
		return p, nil
	}
	if !checkout {
		if v, err := version.Parse(filepath.Base(home)); err == nil && len(v.Pre) == 0 {
			if err := fetchRelease(home, v.String(), arch); err != nil {
				return "", fetchFailed(err, arch, p, v.String())
			}
			if isFile(p) {
				return p, nil
			}
		}
	}
	return "", cli.Fail("there is no linux/%s server binary at %s", arch, p).Next(remedy)
}

// fetchFailed quotes the failed fetch of release ver's linux/arch build,
// its next step and help line carried over, since Error() leaves them out.
func fetchFailed(err error, arch, p, ver string) error {
	f := cli.Fail("there is no linux/%s server binary at %s, and fetching it from release v%s failed", arch, p, ver).Cont(
		strings.Split(err.Error(), "\n")...)
	if e := (*cli.Error)(nil); errors.As(err, &e) {
		f.Carry(e)
	}
	if len(f.NextLines()) == 0 {
		f.Next("Re-run once that is fixed: an installed release fetches a server build it lacks each time a server needs one.")
	}
	return f
}

// rebuild is the step for a server binary at file, as Local found it, that is
// not this build: a checkout's dist/server/, an installed release's fetched
// build, or a dev install's server/.
func rebuild(file string) []string {
	home := filepath.Dir(filepath.Dir(file))
	if filepath.Base(home) == "dist" {
		return []string{"The workstation and server binaries come from one build: rebuild both with",
			"`docker compose run --rm build`, then re-run."}
	}
	if v, err := version.Parse(filepath.Base(home)); err == nil && len(v.Pre) == 0 {
		return []string{fmt.Sprintf("Delete %s and re-run: an installed release fetches its", file),
			"server build, verified, when a server needs one it lacks."}
	}
	return []string{"The workstation and server binaries come from one build: reinstall kasbah",
		"(./install-dev.sh), which installs both, then re-run."}
}

// Facts are what is known about an existing server binary before judging it.
type Facts struct {
	Present, Regular, Executable bool
	// Head is the file's first 20 bytes: enough for the ELF class and machine.
	Head []byte
	// RC is `remote version`'s status: TimedOut, or -1 not run.
	RC             int
	Stdout, Stderr string
}

var elfMachine = map[string]uint16{"amd64": 62, "arm64": 183}

// runnableHere reports whether head is a little-endian ELF for goarch; an
// unknown goarch accepts any ELF.
func runnableHere(head []byte, goarch string) bool {
	if len(head) < 20 || !bytes.HasPrefix(head, []byte("\x7fELF")) || head[5] != 1 {
		return false
	}
	want, ok := elfMachine[goarch]
	return !ok || binary.LittleEndian.Uint16(head[18:20]) == want
}

// Classify judges an existing binary: its Info when it answered, nil when
// it can be replaced (absent, not executable, not an executable for this
// machine, 126 off a noexec mount, 127), a refusal for anything else.
func Classify(f Facts, file, goarch string, noexec func() error) (*remote.Info, error) {
	switch {
	case !f.Present:
		return nil, nil
	case !f.Regular:
		return nil, cli.Fail("%s exists and is not a regular file — kasbah will not replace it", file)
	case !f.Executable, !runnableHere(f.Head, goarch):
		return nil, nil
	}
	switch rc := f.RC; {
	case rc == 0:
		lines := strings.Split(strings.TrimRight(strings.ReplaceAll(f.Stdout, "\r", ""), "\n"), "\n")
		if len(lines) == 1 {
			if i, err := remote.ParseInfo(lines[0]); err == nil {
				return &i, nil
			}
		}
		return nil, cli.Fail("%s answered `remote version` with %q, not a version line — kasbah will not replace what it cannot order", file, f.Stdout)
	case TimedOut(rc):
		return nil, cli.Fail("%s did not answer `remote version` within %d s, or was killed (exit %d)", file, RunTimeout, f.RC).Cont(
			"kasbah does not replace a binary it cannot account for.").Next(
			"Look at it on the server; moved aside, the next command ships this build in its place.")
	case rc == 126:
		if noexec != nil {
			if err := noexec(); err != nil {
				return nil, err
			}
		}
		return nil, nil
	case rc == 127:
		return nil, nil
	}
	return nil, cli.Fail("%s exited %d on `remote version` — kasbah will not replace a binary it cannot account for", file, f.RC).Cont(
		nonEmpty(strings.Split(strings.TrimRight(f.Stderr, "\n"), "\n"))...)
}

// clip shortens each line to 120 bytes, saying how long it was.
func clip(lines []string) []string {
	for i, l := range lines {
		if len(l) > 120 {
			lines[i] = fmt.Sprintf("%s… (%d bytes in all)", l[:120], len(l))
		}
	}
	return lines
}

func nonEmpty(lines []string) []string {
	var out []string
	for _, l := range lines {
		if l = strings.TrimSuffix(l, "\r"); l != "" {
			out = append(out, "| "+l)
		}
	}
	return out
}

// Probe is what one bootstrap round trip learns, with plain commands only:
// the server may not have a kasbah binary yet.
type Probe struct {
	Apps, Source string
	AppsDir      bool
	AppsNotDir   bool
	Marker       bool
	// MarkerNotFile: something other than a regular file is at the marker's path.
	MarkerNotFile bool
	// MarkerBody is the marker's first 256 KiB; MarkerUnreadable says this
	// user could not read them.
	MarkerBody       []byte
	MarkerUnreadable bool
	Machine          string
	Bin              Facts
	Mount            []string
}

// probeScript resolves the apps path ($3, else the pointer $2, else $1) and
// reports the marker, `uname -m` and the existing binary, whose `remote
// version` runs for at most $4 s. POSIX sh; exit 5/6/7/8 are pointer refusals.
const probeScript = `set -u
export LC_ALL=C
apps=$1
pointer=$2
explicit=$3
limit=$4
dir=${pointer%/*}
source=default
pointed=""
cr=$(printf '\r')

norm_path() {
    p=${1%"$cr"}
    while :; do
        case $p in
            *' '|*'	') p=${p%?} ;;
            *) break ;;
        esac
    done
    case $p in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    out=""
    oldifs=$IFS
    IFS=/
    set -f
    for seg in $p; do
        [ -n "$seg" ] && [ "$seg" != . ] || continue
        out="$out/$seg"
    done
    set +f
    IFS=$oldifs
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}

readable=yes
reachable=yes
if [ -n "$explicit" ]; then
    source=explicit
    pointed=$(norm_path "$explicit")
elif [ -f "$pointer" ]; then
    source=pointer
    if [ -r "$pointer" ]; then
        IFS= read -r pointed < "$pointer" || [ -n "$pointed" ] || pointed=""
        pointed=$(norm_path "$pointed")
    else
        readable=no
    fi
elif [ -e "$pointer" ]; then
    exit 8
elif [ -d "$dir" ] && [ ! -x "$dir" ]; then
    source=pointer
    reachable=no
fi

if [ "$source" = default ]; then
    printf 'apps=%s\n' "$apps"
else
    printf 'apps=%s\n' "$pointed"
fi
printf 'source=%s\n' "$source"
if [ "$source" != default ]; then
    [ "$reachable" = yes ] || exit 7
    [ "$readable" = yes ] || exit 6
    case $pointed in
        /?*) apps=$pointed ;;
        *) exit 5 ;;
    esac
fi

if [ -d "$apps" ]; then echo apps_dir=yes; elif [ -e "$apps" ]; then echo apps_dir=notdir; else echo apps_dir=no; fi
marker="$apps/.kasbah/server.json"
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    echo marker=notfile
elif [ -f "$marker" ]; then
    echo marker=yes
    if [ -r "$marker" ]; then
        printf 'marker_hex=%s\n' "$(od -An -tx1 -v -N 262144 "$marker" 2>/dev/null | tr -d ' \n')"
    else
        echo marker_readable=no
    fi
else
    echo marker=no
fi
printf 'machine=%s\n' "$(uname -m)"

bin="$apps/.kasbah/bin/kasbah"
if [ ! -e "$bin" ] && [ ! -L "$bin" ]; then
    echo bin=absent
    exit 0
fi
echo bin=present
[ -f "$bin" ] || { echo bin_regular=no; exit 0; }
echo bin_regular=yes
if [ -x "$bin" ]; then echo bin_exec=yes; else echo bin_exec=no; exit 0; fi
printf 'bin_head=%s\n' "$(od -An -tx1 -N20 "$bin" 2>/dev/null | tr -d ' \n')"
v=$(timeout -k 5 "$limit" "$bin" remote version 2>/dev/null </dev/null)
rc=$?
printf 'version_rc=%s\n' "$rc"
[ -z "$v" ] || printf '%s\n' "$v" | sed 's/^/version=/'
case $rc in
    0|124|127|137|143) ;;
    126) { findmnt -n -o TARGET,FSTYPE,OPTIONS -T "$bin" 2>/dev/null || cat /proc/mounts; } | sed 's/^/mount=/' ;;
    *) timeout -k 5 "$limit" "$bin" remote version 2>&1 >/dev/null </dev/null | head -n 5 | sed 's/^/stderr=/' ;;
esac
exit 0
`

// ParseProbe reads the probe's output; the two header lines are checked as
// a protocol, so a truncated probe is never absorbed into a path.
func ParseProbe(out []byte) (*Probe, error) {
	p := &Probe{Bin: Facts{RC: -1}}
	var vlines, elines []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	// marker_hex carries up to 256 KiB as 512 KiB of hex on one line.
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	n := 0
	for sc.Scan() {
		line := strings.TrimSuffix(sc.Text(), "\r")
		k, v, _ := strings.Cut(line, "=")
		switch n {
		case 0:
			if k != "apps" {
				return nil, fmt.Errorf("no apps= header")
			}
		case 1:
			if k != "source" || (v != "pointer" && v != "default" && v != "explicit") {
				return nil, fmt.Errorf("no source= header")
			}
		}
		n++
		switch k {
		case "apps":
			p.Apps = normPath(v)
		case "source":
			p.Source = v
		case "apps_dir":
			p.AppsDir = v == "yes"
			p.AppsNotDir = v == "notdir"
		case "marker":
			p.Marker = v == "yes"
			p.MarkerNotFile = v == "notfile"
		case "marker_hex":
			p.MarkerBody, _ = hex.DecodeString(v)
		case "marker_readable":
			p.MarkerUnreadable = v == "no"
		case "machine":
			p.Machine = v
		case "bin":
			p.Bin.Present = v == "present"
		case "bin_regular":
			p.Bin.Regular = v == "yes"
		case "bin_exec":
			p.Bin.Executable = v == "yes"
		case "bin_head":
			p.Bin.Head, _ = hex.DecodeString(v)
		case "version_rc":
			p.Bin.RC, _ = strconv.Atoi(v)
		case "version":
			vlines = append(vlines, v)
		case "stderr":
			elines = append(elines, v)
		case "mount":
			p.Mount = append(p.Mount, v)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("a line could not be read: %v", err)
	}
	if n < 2 {
		return nil, fmt.Errorf("no apps= and source= headers")
	}
	p.Bin.Stdout = strings.Join(vlines, "\n")
	p.Bin.Stderr = strings.Join(elines, "\n")
	return p, nil
}

// normPath reduces an apps path as the pointer is read: CR and trailing blanks
// off, `.` segments and repeated or trailing slashes dropped.
func normPath(p string) string {
	p = strings.TrimRight(strings.TrimSuffix(p, "\r"), " \t")
	if !strings.HasPrefix(p, "/") {
		return p
	}
	var out string
	for _, seg := range strings.Split(p, "/") {
		if seg != "" && seg != "." {
			out += "/" + seg
		}
	}
	if out == "" {
		return "/"
	}
	return out
}

// judge turns the probe's exit status and output into the apps path's
// refusals. An explicit apps path
// needs the directory, not a marker: server init ships before it writes one.
func judge(target string, rc int, out []byte, opt Options) (*Probe, error) {
	p, err := judgeLayout(target, rc, out, opt.Prepared != nil)
	if err != nil || opt.Prepared == nil {
		return p, err
	}
	// A reader ships nothing to a server whose marker it would refuse.
	if p.MarkerUnreadable {
		return nil, UnreadableMarker(target, p.Apps)
	}
	if err := opt.Prepared(p.MarkerBody, p.Apps); err != nil {
		return nil, err
	}
	return p, nil
}

func judgeLayout(target string, rc int, out []byte, prepared bool) (*Probe, error) {
	p, err := readLayout(target, rc, out)
	if err != nil {
		return nil, err
	}
	if prepared && p.AppsNotDir {
		return nil, AppsNotDir(target, p)
	}
	if prepared && p.Source == "explicit" && !p.Marker {
		return nil, NoMarker(target, p)
	}
	if p.Source == "explicit" {
		if !p.AppsDir {
			return nil, cli.Fail("%s has no directory at %s to put kasbah's binary under", target, p.Apps)
		}
		return p, nil
	}
	if !p.Marker {
		return nil, NoMarker(target, p)
	}
	return p, nil
}

// AppsNotDir is the refusal of an apps path that is there and not a
// directory, its next step worded for how that path was found.
func AppsNotDir(target string, p *Probe) *cli.Error {
	e := cli.Fail("%s on %s exists and is not a directory", p.Apps, target)
	switch p.Source {
	case "explicit":
		return e.Next("Name the directory the server was prepared at with --apps-path=<dir>.")
	case "pointer":
		return e.Cont(probePointer + " names it as the tree this server was prepared at.").Next(lookAtPointer(target, p.Apps))
	}
	return e.Next(notDirDefault(target, p.Apps)...)
}

// notDirDefault is the step for a default apps path that is a file: init
// refuses it there, so the choice is removing it or another apps path. No
// runnable bare init line, for the reason lostPointer gives.
func notDirDefault(target, apps string) []string {
	return []string{
		fmt.Sprintf("If the server has never been prepared, remove %s, and `kasbah server init` prepares it there,", apps),
		fmt.Sprintf("or prepare it elsewhere with `%s`. If it was prepared", InitCmd(target, "<dir>")),
		"at another apps path and the pointer has been lost, the same line with <dir>",
		"set to that tree (its marker is at <dir>/.kasbah/server.json) restores it.",
	}
}

// lookAtPointer is the step when the pointer names a tree that is not one.
func lookAtPointer(target, apps string) string {
	return fmt.Sprintf("Look at both before doing anything else: `ssh %s 'cat %s; ls -la %s'`.", target, probePointer, apps)
}

// lostPointer is the step for a default apps path that holds no tree: no
// runnable init line, since a lost pointer looks exactly like this, and a bare
// init there takes the running proxy down.
var lostPointer = []string{
	"If the server has never been prepared, `kasbah server init` prepares it.",
	"If it was prepared at another apps path and the pointer has been lost, find",
	"that tree (its marker is at <dir>/.kasbah/server.json), then re-run init with",
	"--apps-path=<dir> set to it — that restores the pointer.",
}

// UnreadableMarker is the refusal of a marker the probe could not read. Any
// operator may own the marker; its group is kasbah and its mode 664.
func UnreadableMarker(target, apps string) *cli.Error {
	mk := marker.Path(apps)
	login, _, _ := strings.Cut(target, "@")
	return cli.Fail("%s on %s could not be read", mk, target).Next(
		fmt.Sprintf("`ssh %s ls -l %s` shows its owner and mode; give it back to this user:", target, mk),
		fmt.Sprintf("`ssh %s 'sudo chown %s:kasbah %s && sudo chmod 664 %[3]s'`.", target, login, mk))
}

// NoMarker is the exit-4 refusal of a server with no marker under the apps
// path p names, worded for how that path was found.
func NoMarker(target string, p *Probe) *cli.Error {
	e := cli.Failf(cli.ExitNoRemoteState, "%s has no server marker at %s", target, marker.Path(p.Apps))
	switch {
	case p.Source == "explicit":
		return e.Cont(
			"That path is the one --apps-path named, and nothing else was looked at,",
			"so this is one of two situations, with different answers. Do not run init",
			"until you know which: at the wrong apps path it renders a second Traefik",
			"stack under the frozen 'traefik' compose project, which recreates the",
			"running proxy against it and takes every site down.").Next(
			"If the server has never been prepared, initialising it at that path is the answer.",
			"If it is prepared somewhere else, name that tree with --apps-path=<dir>.")
	case p.Source == "pointer" && p.Apps != probeDefault:
		return e.Cont(
			probePointer+" says this server was prepared at "+p.Apps+", and there is no marker there;",
			"kasbah does not fall back to "+probeDefault+".").Next(lookAtPointer(target, p.Apps))
	}
	return e.Cont(
		"kasbah puts its binary only on a server `kasbah server init` has prepared,",
		"and this is one of two situations, with different answers. Do not guess the",
		"path: init at the wrong one takes the running Traefik down.").Next(lostPointer...)
}

// MarkerNotFile is the refusal of something other than a regular file at
// the marker's path.
func MarkerNotFile(target, apps string) *cli.Error {
	mk := marker.Path(apps)
	return cli.Fail("%s on %s exists and is not a regular file", mk, target).Next(
		marker.StartOver(target, mk, InitCmd(target, apps), "ls -ld")...)
}

// readLayout reads the probe's answer and makes its pointer refusals: where
// the apps path is, whatever is or is not there.
func readLayout(target string, rc int, out []byte) (*Probe, error) {
	switch rc {
	case 0, 5, 6, 7:
	case 8:
		return nil, cli.Fail("%s on %s exists and is not a regular file", probePointer, target).Cont(
			"it is the server's record of where it was prepared: one absolute path, in a file root owns.").Next(
			fmt.Sprintf("Look at it (`ssh %s ls -ld %s`) and move it aside, then re-run `kasbah server init %s --apps-path=<dir>`", target, probePointer, target),
			"naming the tree the server was prepared at, which writes it again.")
	default:
		return nil, cli.Fail("could not read the server layout on %s (%s, see above)", target, ExitText(rc, 0))
	}
	p, err := ParseProbe(out)
	if err != nil {
		return nil, cli.Fail("the server probe on %s did not report where it looked (%v) — raw output:", target, err).Cont(
			clip(nonEmpty(strings.Split(string(out), "\n")))...)
	}
	switch rc {
	case 7:
		return nil, cli.Fail("%s on %s cannot be entered by this deploy user", path.Dir(probePointer), target).Cont(
			"whether this server carries a pointer cannot be told from outside it, and",
			probeDefault+" is only the right tree if it does not.").Next(
			fmt.Sprintf("Make it traversable again: `ssh %s 'sudo chmod 755 %s'`.", target, path.Dir(probePointer)))
	case 6:
		return nil, cli.Fail("%s on %s cannot be read by this deploy user", probePointer, target).Cont(
			"it is world-readable by contract, and reading " + probeDefault + " instead could be a different server.").Next(
			fmt.Sprintf("Make it readable again: `ssh %s 'sudo chmod 644 %s'`.", target, probePointer))
	case 5:
		if p.Source == "explicit" {
			return nil, cli.Fail("the apps path '%s' is not an absolute path", p.Apps)
		}
		return nil, cli.Fail("%s on %s does not name an absolute path", probePointer, target).Cont(
			"it holds '"+p.Apps+"'.").Next(
			"Correct it, or remove it and re-run init with --apps-path=<dir> set to the",
			"directory the server was actually prepared at: init refuses a pointer it cannot read.")
	}
	if p.MarkerNotFile {
		return nil, MarkerNotFile(target, p.Apps)
	}
	if !strings.HasPrefix(p.Apps, "/") || p.Apps == "/" {
		return nil, cli.Fail("the server probe on %s named '%s' as the apps path, which is not an absolute path", target, p.Apps)
	}
	return p, nil
}

// mountOf is the /proc/mounts line whose mount point holds file: the
// longest prefix. Octal escapes (\040 for a space) are decoded.
func mountOf(file string, procMounts []string) string {
	best, bestLen := "", -1
	for _, l := range procMounts {
		f := strings.Fields(l)
		if len(f) < 4 {
			continue
		}
		mp := unescape(f[1])
		if (file == mp || mp == "/" || strings.HasPrefix(file, mp+"/")) && len(mp) > bestLen {
			best, bestLen = mp+" "+f[2]+" "+f[3], len(mp)
		}
	}
	return best
}

func unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// mountLine is the mount holding file, from findmnt's one line or a
// /proc/mounts dump: "<mount point> <fstype> <options>".
func mountLine(file string, lines []string) string {
	if len(lines) == 1 && len(strings.Fields(lines[0])) == 3 {
		return strings.Join(strings.Fields(lines[0]), " ")
	}
	return mountOf(file, lines)
}

// noexec is the refusal for a binary under dir that cannot be executed there,
// when the mount says why; nil when the mount does not.
func noexec(target, dir, file string, mount []string) error {
	m := mountLine(file, mount)
	f := strings.Fields(m)
	if len(f) < 3 {
		return nil
	}
	for _, o := range strings.Split(f[2], ",") {
		if o == "noexec" {
			return cli.Fail("kasbah's binary cannot run from %s on %s: %s is mounted noexec (%s)", dir, target, f[0], m).Cont(
				"kasbah runs its own binary on the server from the apps path.").Next(
				"Remount " + f[0] + " without noexec, or prepare the server at an apps path on another filesystem.")
		}
	}
	return nil
}

// Result is what Ensure did: Action, the server's build before (empty when it
// had none, "unknown" when its binary could not say), and the build there now.
type Result struct {
	Action   remote.Action
	Old, Now string
	Apps     string
	// Source is how the apps path was found: explicit, pointer or default.
	Source string
	// Marker is the marker's bytes as the probe read them.
	Marker []byte
	// Arch is the server's GOARCH from its `uname -m`, "" when kasbah builds
	// for no such machine.
	Arch string
}

// TimedOut is a status `timeout` gives a run it ended: GNU's 124 (137 after
// -k), busybox's 143 (its TERM).
func TimedOut(rc int) bool { return rc == 124 || rc == 137 || rc == 143 }

// ExitText is a remote step's exit status in words; limit is its bound in
// seconds, 0 for a step run unbounded.
func ExitText(rc, limit int) string {
	switch {
	case rc == -1:
		return "ssh could not run, or was killed by a signal"
	case TimedOut(rc) && limit > 0:
		return fmt.Sprintf("it did not finish within %d s", limit)
	case rc == 137 || rc == 143:
		return fmt.Sprintf("it was killed (exit %d)", rc)
	}
	return fmt.Sprintf("it exited %d", rc)
}

// Options for Ensure. Apps, when set, is used as the apps path instead of
// discovery, and needs no marker — the bootstrap `server init` runs — unless
// Prepared is set: then every apps path needs a marker, and Prepared judges
// its bytes before anything is shipped.
type Options struct {
	Apps     string
	Prepared func(marker []byte, apps string) error
	// Migrating admits a marker of an older major: `kasbah migrate server` is
	// the one command that ships a new major to a server still on the old one.
	Migrating bool
}

// Ensure leaves at Path(apps) this build's binary when the server's is absent,
// not runnable or older, and keeps the server's when it is the same build; a
// newer one is refused before anything is uploaded, as is a marker of another
// major (marker.Check), and a dev build asks before replacing a release
// (ShipDev). Each change is one line on Notes. local finds this build's
// server binary for a GOARCH.
func Ensure(c *ssh.Conn, self remote.Info, local func(arch string) (string, error), opt Options) (*Result, error) {
	target := c.Target.String()
	// The major is judged before the command's own reading of the marker: a
	// newer major's marker may not read as this one's, and its remedy is an
	// upgrade here, never a re-init there.
	if prep := opt.Prepared; prep != nil {
		opt.Prepared = func(body []byte, apps string) error {
			if err := marker.Check(body, self.Build, marker.Path(apps), target, opt.Migrating); err != nil {
				return err
			}
			return prep(body, apps)
		}
	}
	cmd := c.Script(probeScript, probeDefault, probePointer, opt.Apps, strconv.Itoa(RunTimeout))
	var out bytes.Buffer
	cmd.Stdout = &out
	p, err := judge(target, ssh.ExitCode(trace.Run(cmd)), out.Bytes(), opt)
	if err != nil {
		return nil, err
	}
	// The marker's major is judged before anything ships: a binary landing on
	// a server of another major would lock that major's workstations out.
	if opt.Prepared == nil && p.Marker && !p.MarkerUnreadable {
		if err := marker.Check(p.MarkerBody, self.Build, marker.Path(p.Apps), target, opt.Migrating); err != nil {
			return nil, err
		}
	}
	bin := Path(p.Apps)
	arch, archErr := Arch(p.Machine)

	srv, err := Classify(p.Bin, bin, arch, func() error { return noexec(target, path.Dir(bin), bin, p.Mount) })
	if err != nil {
		return nil, err
	}
	action, err := remote.Decide(self, srv)
	if err != nil {
		return nil, err
	}
	res := &Result{Action: action, Apps: p.Apps, Source: p.Source, Marker: p.MarkerBody, Arch: arch}
	switch {
	case srv != nil:
		res.Old = srv.Build
	case p.Bin.Present:
		res.Old = "unknown"
	}
	if action == remote.Keep {
		res.Now = srv.Build
		c.SameBuild()
		trace.Note("server binary %s kept: the server runs this build (%s)", bin, res.Now)
		return res, nil
	}

	if archErr != nil {
		return nil, archErr
	}
	file, err := local(arch)
	if err != nil {
		return nil, err
	}
	over := res.Old
	// Another workstation may install meanwhile; a kept build is judged once
	// more, then the run goes to it.
	for try := 0; ; try++ {
		if remote.DevOverRelease(self, srv) {
			yes, err := ShipDev(srv.Build, self.Build)
			if err != nil {
				return nil, err
			}
			if !yes {
				return nil, remote.Kept(srv.Build, self.Build)
			}
		}
		kept, err := ship(c, self, file, bin, cmp.Or(over, "none"))
		if err != nil {
			return nil, err
		}
		if kept == nil {
			break
		}
		action, err := remote.Decide(self, kept)
		if err != nil {
			return nil, err
		}
		if action == remote.Keep {
			res.Action, res.Now = remote.Keep, kept.Build
			c.SameBuild()
			trace.Note("server binary %s kept: another run installed this build (%s) meanwhile", bin, res.Now)
			return res, nil
		}
		if try > 0 {
			return nil, remote.Kept(kept.Build, self.Build)
		}
		srv, over, res.Old = kept, kept.Build, kept.Build
	}
	res.Now = self.Build
	old := res.Old
	if old == "" || old == "unknown" {
		old = "(" + cmp.Or(old, "none") + ")"
	}
	Notes.Info("server kasbah %s → %s", old, res.Now)
	c.SameBuild()
	trace.Note("server binary %s shipped: %s → %s", bin, old, res.Now)
	return res, nil
}

func tempName() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	for i := range b {
		b[i] = alnum[int(b[i])%len(alnum)]
	}
	return TempPrefix + string(b), nil
}

// uploadScript writes stdin to $1/$2, never over an existing file, removing it
// on a signal or a short read ($3 bytes expected); uploads older than an
// hour, left by a killed run, are swept first.
const uploadScript = `set -eu
umask 002
mkdir -p "$1"
find "$1" -maxdepth 1 -name '` + TempPrefix + `*' -type f -mmin +60 -exec rm -f {} + 2>/dev/null || :
(set -C; : > "$1/$2")
trap 'rm -f "$1/$2"; exit 1' HUP INT TERM PIPE
if ! cat > "$1/$2" || [ "$(wc -c < "$1/$2")" -ne "$3" ]; then
    rm -f "$1/$2"
    echo "remote: the upload of $1/$2 was cut short" >&2
    exit 1
fi
chmod 775 "$1/$2"`

// ship uploads file beside bin, proves the upload runs there and is this
// build, then has it install itself under the server-side lock over the build
// the probe saw (over: a build, none or unknown). A non-nil Info is the build
// another run installed meanwhile, which install-self kept.
func ship(c *ssh.Conn, self remote.Info, file, bin, over string) (*remote.Info, error) {
	target := c.Target.String()
	dir := path.Dir(bin)
	name, err := tempName()
	if err != nil {
		return nil, err
	}
	tmp := dir + "/" + name
	f, err := os.Open(file)
	if err != nil {
		return nil, cli.Fail("cannot read %s: %v", file, err)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, cli.Fail("cannot read %s: %v", file, err)
	}

	removeTmp := func() { trace.Run(c.Command("rm", "-f", tmp)) }
	pop := atexit.Push(removeTmp)
	// Every way out, a panic's included; after a successful install the name
	// is already gone.
	defer func() { pop(); removeTmp() }()

	up := c.Command("sh", "-c", uploadScript, "sh", dir, name, strconv.FormatInt(fi.Size(), 10))
	up.Stdin = f
	if err := trace.Run(up); err != nil {
		return nil, cli.Fail("could not upload kasbah to %s on %s (exit %d, see above)", tmp, target, ssh.ExitCode(err))
	}

	var vout, verr bytes.Buffer
	run := c.Command(Bounded(tmp, RunTimeout, "version")...)
	run.Stdout, run.Stderr = &vout, &verr
	switch rc := ssh.ExitCode(trace.Run(run)); {
	case rc == 0:
	case TimedOut(rc):
		return nil, cli.Fail("the kasbah binary uploaded to %s on %s did not answer within %d s", dir, target, RunTimeout)
	case rc == 126:
		m := c.Command("sh", "-c", `findmnt -n -o TARGET,FSTYPE,OPTIONS -T "$1" 2>/dev/null || cat /proc/mounts`, "sh", dir)
		mo, _ := trace.Output(m)
		mount := strings.Split(strings.TrimRight(strings.ReplaceAll(string(mo), "\r", ""), "\n"), "\n")
		if err := noexec(target, dir, dir+"/kasbah", mount); err != nil {
			return nil, err
		}
		fallthrough
	default:
		return nil, cli.Fail("the kasbah binary uploaded to %s on %s did not run there (exit %d)", dir, target, rc).Cont(
			nonEmpty(strings.Split(verr.String()+vout.String(), "\n"))...)
	}
	got, perr := remote.ParseInfo(vout.String())
	if perr != nil || got.Build != self.Build {
		return nil, cli.Fail("%s is build %s, and this kasbah is %s — refusing to ship a server binary from another build",
			file, strings.TrimSpace(vout.String()), self.Build).Next(rebuild(file)...)
	}

	var iout bytes.Buffer
	inst := c.Command(Bounded(tmp, 2*RunTimeout+LockWait, "install-self", bin, "--over="+over)...)
	inst.Stdout = &iout
	if err := trace.Run(inst); err != nil {
		return nil, cli.Fail("installing kasbah at %s on %s failed (exit %d, see above)", bin, target, ssh.ExitCode(err))
	}
	line := strings.TrimSpace(strings.ReplaceAll(iout.String(), "\r", ""))
	if rest, ok := strings.CutPrefix(line, "kept "); ok {
		i, err := remote.ParseInfo(rest)
		if err != nil {
			return nil, cli.Fail("install-self on %s answered %q", target, line)
		}
		return &i, nil
	}
	if !strings.HasPrefix(line, "installed") {
		return nil, cli.Fail("install-self on %s answered %q", target, line)
	}
	return nil, nil
}
