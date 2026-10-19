// Package serverbin puts kasbah's own binary on a server, at the one shared
// path <apps>/.kasbah/bin/kasbah, under the newer-wins rule
// (docs/phases/10-recast.md, Rulings): absent or older is replaced by this
// build's, the same or newer is kept, a newer major refuses.
package serverbin

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// Pointer and DefaultApps are where a server's apps path is discovered
// (docs/server-setup.md, the discovery pointer).
const (
	Pointer     = "/etc/kasbah/apps-path"
	DefaultApps = "/apps"
)

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

// Local is this build's server binary for arch: dist/server/ in a checkout,
// server/ in an installed library directory (install.sh).
func Local(home string, checkout bool, arch string) (string, error) {
	name := "kasbah-linux-" + arch
	p := filepath.Join(home, "server", name)
	remedy := "reinstall kasbah (install.sh), which installs both server binaries"
	if checkout {
		p = filepath.Join(home, "dist", "server", name)
		remedy = "build it: docker compose run --rm build"
	}
	fi, err := os.Stat(p)
	if err != nil || !fi.Mode().IsRegular() {
		return "", cli.Fail("there is no linux/%s server binary at %s", arch, p).Cont(remedy)
	}
	return p, nil
}

// Facts are what is known about an existing server binary before judging it.
type Facts struct {
	Present, Regular, Executable bool
	// Head is the file's first 20 bytes: enough for the ELF class and machine.
	Head []byte
	// RC is `remote version`'s status: 124/137 timed out, -1 not run.
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
	switch f.RC {
	case 0:
		lines := strings.Split(strings.TrimRight(strings.ReplaceAll(f.Stdout, "\r", ""), "\n"), "\n")
		if len(lines) == 1 {
			if i, err := remote.ParseInfo(lines[0]); err == nil {
				return &i, nil
			}
		}
		return nil, cli.Fail("%s answered `remote version` with %q, not a version line — kasbah will not replace what it cannot order", file, f.Stdout)
	case 124, 137:
		return nil, cli.Fail("%s did not answer `remote version` within %d s, or was killed (exit %d)", file, RunTimeout, f.RC).Cont(
			"kasbah does not replace a binary it cannot account for; look at it on the server")
	case 126:
		if noexec != nil {
			if err := noexec(); err != nil {
				return nil, err
			}
		}
		return nil, nil
	case 127:
		return nil, nil
	}
	return nil, cli.Fail("%s exited %d on `remote version` — kasbah will not replace a binary it cannot account for", file, f.RC).Cont(
		nonEmpty(strings.Split(strings.TrimRight(f.Stderr, "\n"), "\n"))...)
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
	Marker       bool
	Machine      string
	Bin          Facts
	Mount        []string
}

// probeScript resolves the apps path ($3 when given, else the pointer $2, else
// $1) and reports the marker, `uname -m` and the existing binary, run for at
// most $4 s. POSIX sh; exit 5/6/7 are lib/marker.sh's pointer refusals.
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
    printf 'remote: %s exists and is not a regular file\n' "$pointer" >&2
    exit 1
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

if [ -d "$apps" ]; then echo apps_dir=yes; else echo apps_dir=no; fi
marker="$apps/.kasbah/server.json"
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$marker" >&2
    exit 1
fi
if [ -f "$marker" ]; then echo marker=yes; else echo marker=no; fi
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
    0|124|127|137) ;;
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
		case "marker":
			p.Marker = v == "yes"
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
	if n < 2 {
		return nil, fmt.Errorf("no apps= and source= headers")
	}
	p.Bin.Stdout = strings.Join(vlines, "\n")
	p.Bin.Stderr = strings.Join(elines, "\n")
	return p, nil
}

// normPath is lib/common.sh's kasbah_norm_path.
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
// refusals (lib/marker.sh's, the same exit codes). An explicit apps path
// needs the directory, not a marker: server init ships before it writes one.
func judge(target string, rc int, out []byte) (*Probe, error) {
	switch rc {
	case 0, 5, 6, 7:
	default:
		return nil, cli.Fail("could not read the server layout on %s (the remote step exited %d, see above)", target, rc)
	}
	p, err := ParseProbe(out)
	if err != nil {
		return nil, cli.Fail("the server probe on %s did not report where it looked (%v) — raw output:", target, err).Cont(
			nonEmpty(strings.Split(string(out), "\n"))...)
	}
	switch rc {
	case 7:
		return nil, cli.Fail("%s on %s cannot be entered by this deploy user", path.Dir(probePointer), target).Cont(
			"whether this server carries a pointer cannot be told from outside it, and",
			probeDefault+" is only the right tree if it does not",
			fmt.Sprintf("(ssh %s 'sudo chmod 755 %s')", target, path.Dir(probePointer)))
	case 6:
		return nil, cli.Fail("%s on %s cannot be read by this deploy user", probePointer, target).Cont(
			"it is world-readable by contract, and reading "+probeDefault+" instead could be a different server",
			fmt.Sprintf("(ssh %s 'sudo chmod 644 %s')", target, probePointer))
	case 5:
		if p.Source == "explicit" {
			return nil, cli.Fail("the apps path '%s' is not an absolute path", p.Apps)
		}
		return nil, cli.Fail("%s on %s does not name an absolute path", probePointer, target).Cont(
			"it holds '"+p.Apps+"'; correct it, or re-run init with --apps-path=<dir> set to",
			"the directory the server was actually prepared at")
	}
	if !strings.HasPrefix(p.Apps, "/") || p.Apps == "/" {
		return nil, cli.Fail("the server probe on %s named '%s' as the apps path, which is not an absolute path", target, p.Apps)
	}
	if p.Source == "explicit" {
		if !p.AppsDir {
			return nil, cli.Fail("%s has no directory at %s to put kasbah's binary under", target, p.Apps)
		}
		return p, nil
	}
	if !p.Marker {
		mk := marker.Path(p.Apps)
		if p.Source == "pointer" && p.Apps != probeDefault {
			return nil, cli.Failf(cli.ExitNoRemoteState, "%s has no server marker at %s", target, mk).Cont(
				probePointer+" says this server was prepared at "+p.Apps+", and there is no marker there;",
				"kasbah does not fall back to "+probeDefault+". Look at both before doing anything else.")
		}
		// No runnable init line: a lost pointer looks exactly like this, and a
		// bare init there takes the running proxy down.
		return nil, cli.Failf(cli.ExitNoRemoteState, "%s has no server marker at %s", target, mk).Cont(
			"kasbah puts its binary only on a server `kasbah server init` has prepared,",
			"and this is one of two situations, with different answers:",
			"  * the server has never been prepared, and initialising it is the answer.",
			"  * it was prepared at another apps path and the pointer has been lost. Find",
			"    that tree (its marker is at <dir>/.kasbah/server.json), then re-run init",
			"    with --apps-path=<dir> set to it — that restores the pointer.",
			"Do not guess the path: init at the wrong one takes the running Traefik down.")
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
				"kasbah runs its own binary on the server from the apps path; remount",
				f[0]+" without noexec, or prepare the server at an apps path on another filesystem")
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
}

// Options for Ensure. Apps, when set, is used as the apps path instead of
// discovery, and needs no marker — the bootstrap `server init` runs.
type Options struct{ Apps string }

// Ensure leaves at Path(apps) this build's binary when the server's is absent,
// not runnable or older, and keeps the server's when it is the same or newer
// of our major. local finds this build's server binary for a GOARCH.
func Ensure(c *ssh.Conn, self remote.Info, local func(arch string) (string, error), opt Options) (*Result, error) {
	target := c.Target.String()
	cmd := c.Script(probeScript, probeDefault, probePointer, opt.Apps, strconv.Itoa(RunTimeout))
	var out bytes.Buffer
	cmd.Stdout = &out
	p, err := judge(target, ssh.ExitCode(cmd.Run()), out.Bytes())
	if err != nil {
		return nil, err
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
	res := &Result{Action: action, Apps: p.Apps}
	switch {
	case srv != nil:
		res.Old = srv.Build
	case p.Bin.Present:
		res.Old = "unknown"
	}
	if action == remote.Keep {
		res.Now = srv.Build
		return res, nil
	}

	if archErr != nil {
		return nil, archErr
	}
	file, err := local(arch)
	if err != nil {
		return nil, err
	}
	kept, err := ship(c, self, file, bin)
	if err != nil {
		return nil, err
	}
	if kept != nil {
		// Another workstation installed a build of its own meanwhile.
		if _, err := remote.Decide(self, kept); err != nil {
			return nil, err
		}
		res.Action, res.Now = remote.Keep, kept.Build
		return res, nil
	}
	res.Now = self.Build
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
umask 022
mkdir -p "$1"
find "$1" -maxdepth 1 -name '` + TempPrefix + `*' -type f -mmin +60 -exec rm -f {} + 2>/dev/null || :
(set -C; : > "$1/$2")
trap 'rm -f "$1/$2"; exit 1' HUP INT TERM PIPE
if ! cat > "$1/$2" || [ "$(wc -c < "$1/$2")" -ne "$3" ]; then
    rm -f "$1/$2"
    echo "remote: the upload of $1/$2 was cut short" >&2
    exit 1
fi
chmod 755 "$1/$2"`

// ship uploads file beside bin, proves the upload runs there and is this
// build, then has it install itself under the server-side lock. A non-nil
// Info is the newer build another run installed meanwhile.
func ship(c *ssh.Conn, self remote.Info, file, bin string) (*remote.Info, error) {
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

	removeTmp := func() { c.Command("rm", "-f", tmp).Run() }
	pop := atexit.Push(removeTmp)
	// Every way out, a panic's included; after a successful install the name
	// is already gone.
	defer func() { pop(); removeTmp() }()

	up := c.Command("sh", "-c", uploadScript, "sh", dir, name, strconv.FormatInt(fi.Size(), 10))
	up.Stdin = f
	if err := up.Run(); err != nil {
		return nil, cli.Fail("could not upload kasbah to %s on %s (exit %d, see above)", tmp, target, ssh.ExitCode(err))
	}

	timeout := []string{"timeout", "-k", "5", strconv.Itoa(RunTimeout)}
	var vout, verr bytes.Buffer
	run := c.Command(append(timeout, tmp, "remote", "version")...)
	run.Stdout, run.Stderr = &vout, &verr
	switch rc := ssh.ExitCode(run.Run()); rc {
	case 0:
	case 124, 137:
		return nil, cli.Fail("the kasbah binary uploaded to %s on %s did not answer within %d s", dir, target, RunTimeout)
	case 126:
		m := c.Command("sh", "-c", `findmnt -n -o TARGET,FSTYPE,OPTIONS -T "$1" 2>/dev/null || cat /proc/mounts`, "sh", dir)
		mo, _ := m.Output()
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
			file, strings.TrimSpace(vout.String()), self.Build).Cont(
			"the workstation and server binaries come from one build: docker compose run --rm build",
			"(or install.sh), then retry")
	}

	var iout bytes.Buffer
	inst := c.Command("timeout", "-k", "5", strconv.Itoa(2*RunTimeout+LockWait), tmp, "remote", "install-self", bin)
	inst.Stdout = &iout
	if err := inst.Run(); err != nil {
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
