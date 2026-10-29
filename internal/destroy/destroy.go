// Package destroy is `kasbah server destroy USER@HOST [--yes]`: the handover
// verb (docs/cli.md → server destroy). Project, Traefik and mail containers
// keep running; kasbah's backup scheduler, management layer and every
// agency-owned secret leave.
//
// The server binary reads (scan) and de-brands (act) everything up to the
// marker, which goes last of its work and only when all before it succeeded.
// The pointer (root-owned) and the binary itself are then removed by a
// shell step, after the binary has exited: it never deletes itself mid-run.
package destroy

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/rootsteps"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the command's arguments.
type Options struct {
	Target string
	Yes    bool
}

// Usage is the command's --help.
const Usage = `Usage: kasbah server destroy USER@HOST [--yes]

De-brands a VPS for handover. Project, Traefik and mail containers keep
running, so the sites stay up through the whole operation and after the next
restart. What leaves is kasbah's management layer, its backup scheduler first:

  removed   <apps>/.kasbah/ (the server marker, the backup stack and its
            credentials, the server's kasbah binary), ` + serverbin.Pointer + `, and per
            project: versions.log(.gz), the scripts/ helpers, .deploy.lock,
            .kasbah-client, and the .env managed-block sentinel comments
  mail      the operator's relay block in <apps>/mail/.env — every line that is
            not MAIL_HOSTNAME, DOMAIN or DATA_PATH — and <apps>/mail/kasbah.yml
  kept      every other container, every compose.yml, every .env value, the
            Traefik stack and its fragments, <data>/, <apps>/<project>/backups/,
            named volumes, images, the postmaster account, and the off-VPS
            restic repositories (operator property — docs/backup.md)

The trade is explicit and permanent: deploy history, the mail domain registry
and env tooling leave with kasbah, and no later ` + "`server init`" + ` can reproduce
them.

  --yes     answer both confirmations, for scripts. Without it and without a
            terminal, destroy stops rather than assuming.

Confirmation is double: a yes/no question, then the hostname typed back.
`

// Parse reads the command line; every argument meets it with its CR off.
func Parse(args []string) (Options, error) {
	var o Options
	for _, raw := range args {
		a := strings.TrimSuffix(raw, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--yes":
			o.Yes = true
		case strings.HasPrefix(a, "--yes="):
			return o, cli.Fail("server destroy: --yes takes no value — pass it on its own (`kasbah server destroy USER@HOST --yes`)")
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("server destroy: unknown flag '%s' (destroy takes USER@HOST and --yes)", f)
		default:
			if o.Target != "" {
				return o, cli.Fail("server destroy: two servers given ('%s' and '%s') — one run goes to one server", o.Target, a)
			}
			o.Target = a
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server destroy: no server given (expected `kasbah server destroy USER@HOST`)")
	}
	return o, nil
}

// Session is what destroy needs from a server.
type Session interface {
	// Marker ensures the binary and validates the marker; a server with none
	// is a *cli.Error with ExitNoRemoteState.
	Marker() (*marker.Marker, error)
	Host() string
	Scan(apps string) ([]byte, int)
	Act(apps string, names []string) ([]byte, int)
	// Tail is the shell step after the binary's: the pointer, then the binary.
	Tail(apps string) ([]byte, int)
	// Leftovers is the shell probe for a server with no marker.
	Leftovers() ([]byte, int)
	// Pointer is the shell probe for the pointer the tail could not remove.
	Pointer() ([]byte, int)
	Close()
}

// SSH is the real Session.
type SSH struct{ *env.SSH }

// Dial connects.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

func (s SSH) Host() string { return s.Conn.Target.Host }

func (s SSH) Scan(apps string) ([]byte, int) {
	out, err := s.Conn.Run(s.Bounded("destroy", "scan", apps, serverbin.Pointer)...)
	return out, ssh.ExitCode(err)
}

func (s SSH) Act(apps string, names []string) ([]byte, int) {
	out, err := s.Conn.Run(append([]string{s.Bin(), "remote", "destroy", "act", apps}, names...)...)
	return out, ssh.ExitCode(err)
}

func (s SSH) script(script string, args ...string) ([]byte, int) {
	cmd := s.Conn.Script(script, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), ssh.ExitCode(err)
}

func (s SSH) Tail(apps string) ([]byte, int) {
	return s.script(tailScript, apps, serverbin.Pointer, serverbin.TempPrefix, serverbin.LockName)
}

func (s SSH) Leftovers() ([]byte, int) {
	return s.script(leftoverScript, serverbin.Pointer, serverbin.DefaultApps)
}

func (s SSH) Pointer() ([]byte, int) {
	return s.script(pointerScript, serverbin.Pointer)
}

func (s SSH) Close() { s.Conn.Close() }

// pointerScript tells whether the pointer is still there; behind a directory
// this user cannot enter it may be, so that is not "absent".
const pointerScript = `set -u
export LC_ALL=C
pointer=$1
dir=${pointer%/*}
if [ -e "$pointer" ] || [ -L "$pointer" ]; then echo pointer=present
elif [ -d "$dir" ] && [ ! -x "$dir" ]; then echo pointer=unknown
else echo pointer=absent
fi
# empty: nothing in it but the pointer, so the operator's rmdir is still due.
if [ -d "$dir" ]; then
    other=no
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        { [ -e "$f" ] || [ -L "$f" ]; } && [ "$f" != "$pointer" ] && other=yes
    done
    if [ "$other" = no ] && [ -r "$dir" ] && [ -x "$dir" ]; then echo pointer_dir=empty; else echo pointer_dir=dir; fi
else
    echo pointer_dir=absent
fi
`

// tailScript removes the root-owned pointer (sudo -n), then — the binary that
// ran the act having exited — the binary, its directory and <apps>/.kasbah.
const tailScript = `set -u
export LC_ALL=C
apps=$1
pointer=$2
prefix=$3
lock=$4
case $apps in /?*) ;; *) echo "remote: refusing: apps path '$apps' is not absolute" >&2; exit 1 ;; esac
case $apps in */) echo "remote: refusing: apps path '$apps' ends in a slash" >&2; exit 1 ;; esac
case $pointer in /?*/?*) ;; *) echo "remote: refusing: pointer '$pointer' is not an absolute file path" >&2; exit 1 ;; esac
dir=${pointer%/*}
if [ "$(id -u)" = 0 ]; then s=""
elif sudo -n true >/dev/null 2>&1; then s="sudo -n"
else s=no
fi
if [ "$s" = no ]; then
    if { [ -d "$dir" ] && [ ! -x "$dir" ]; } || [ -e "$pointer" ] || [ -L "$pointer" ]; then
        echo pointer=nosudo
    else
        echo pointer=absent
    fi
    if [ -d "$dir" ]; then echo pointer_dir=nosudo; else echo pointer_dir=absent; fi
else
    if $s test -e "$pointer" 2>/dev/null; then
        if $s rm -f "$pointer"; then echo pointer=removed; else echo pointer=failed; fi
    else
        echo pointer=absent
    fi
    if $s test -d "$dir" 2>/dev/null; then
        if $s rmdir "$dir" 2>/dev/null; then echo pointer_dir=removed; else echo pointer_dir=kept; fi
    else
        echo pointer_dir=absent
    fi
fi
bin="$apps/.kasbah/bin"
if [ -L "$apps/.kasbah" ] || [ -L "$bin" ]; then
    # A link is followed by nothing here: what it points at is not kasbah's.
    echo binary=link
    echo bin_dir=link
elif [ -e "$bin/kasbah" ] || [ -L "$bin/kasbah" ]; then
    if rm -f "$bin/kasbah"; then echo binary=removed; else echo binary=failed; fi
else
    echo binary=absent
fi
if [ -d "$bin" ]; then
    rm -f "$bin/$lock" 2>/dev/null
    for f in "$bin/$prefix"*; do
        [ -f "$f" ] && rm -f "$f"
    done
    if rmdir "$bin" 2>/dev/null; then echo bin_dir=removed; else echo bin_dir=kept; fi
elif [ -e "$bin" ]; then
    echo bin_dir=notdir
else
    echo bin_dir=absent
fi
if [ -L "$apps/.kasbah" ]; then
    echo kasbah_dir=link
elif [ -d "$apps/.kasbah" ]; then
    if rmdir "$apps/.kasbah" 2>/dev/null; then echo kasbah_dir=removed; else echo kasbah_dir=kept; fi
elif [ -e "$apps/.kasbah" ]; then
    echo kasbah_dir=notdir
else
    echo kasbah_dir=absent
fi
echo done=yes
`

// leftoverScript reports, on a server with no marker, the pointer and any
// <apps>/.kasbah (and what is in it and its bin/) at the default apps path or
// where the pointer says. The pointer's value is used as it reads.
const leftoverScript = `set -u
export LC_ALL=C
pointer=$1
default=$2
if [ -e "$pointer" ]; then echo pointer=yes; else echo pointer=no; fi
pointed=""
if [ -f "$pointer" ] && [ -r "$pointer" ]; then
    IFS= read -r pointed < "$pointer" || [ -n "$pointed" ] || pointed=""
    pointed=$(printf '%s' "$pointed" | tr -d '\r')
    case $pointed in /?*) ;; *) pointed="" ;; esac
fi
seen=" "
for dir in "$default" "$pointed"; do
    [ -n "$dir" ] || continue
    case $seen in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    [ -d "$dir/.kasbah" ] || continue
    printf 'kasbah=%s\n' "$dir/.kasbah"
    [ ! -d "$dir/.kasbah/backup" ] || printf 'creds=%s\n' "$dir/.kasbah/backup"
    for d in "$dir/.kasbah" "$dir/.kasbah/bin"; do
        # Never through a link: what it points at is not kasbah's.
        if [ -L "$d" ]; then printf 'foreign=%s\n' "$d"; break; fi
        [ -d "$d" ] || continue
        for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
            { [ -e "$f" ] || [ -L "$f" ]; } && printf 'item=%s\n' "$f"
        done
    done
done
exit 0
`

// Ctx is what a run needs from its process.
type Ctx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	Dial     func(target string) (Session, error)
}

// Plan is the scan, judged.
type Plan struct {
	Target, Apps, Data string
	Scan               *Scan
	Projects           []Row
}

func kv(out []byte) map[string]string { return remote.KV(out) }

// Run is the command.
func Run(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	var ce *cli.Error
	if err != nil && errors.As(err, &ce) && ce.Code == cli.ExitNoRemoteState {
		return nothingToFind(c.Out, c.Prompter, s, o.Target, ce.Lines[0])
	}
	if err != nil {
		return err
	}
	p := &Plan{Target: o.Target, Apps: mk.AppsPath, Data: mk.DataPath}

	out, rc := s.Scan(p.Apps)
	if rc != 0 {
		return cli.Fail("the destroy probe on %s exited %d", o.Target, rc).Cont(
			"nothing was removed — destroy reads the whole server before it changes anything")
	}
	var sc Scan
	if err := remote.Decode(out, &sc, scanKeys, "the destroy probe", o.Target); err != nil {
		return err
	}
	if sc.Count != len(sc.Projects) {
		return cli.Fail("the destroy probe on %s counted %d projects and described %d", o.Target, sc.Count, len(sc.Projects)).Cont(
			"the payload was truncated — nothing was removed")
	}
	p.Scan = &sc
	if err := p.check(); err != nil {
		return err
	}
	dd := dataDir(p.Apps, p.Data)
	for _, r := range sc.Projects {
		if dd != "" && r.Name == dd {
			continue
		}
		if !reName.MatchString(r.Name) || isReserved(r.Name) {
			return cli.Fail("the destroy probe on %s described '%s' as a project, and that is not a project name", o.Target, r.Name)
		}
		p.Projects = append(p.Projects, r)
	}
	p.Report(c.Out.Stdout)

	if !p.anything() {
		fmt.Fprintf(c.Out.Stdout, "nothing of kasbah is left on %s — nothing to remove\n", o.Target)
		return nil
	}
	yes, err := c.Prompter.Confirm("yes", fmt.Sprintf("de-brand %s? the sites keep running, the backup scheduler stops; the deploy history and the mail registry are gone for good", o.Target), o.Yes)
	if err != nil {
		return err
	}
	if !yes {
		return cli.Fail("not confirmed — nothing was changed on %s", o.Target)
	}
	host := s.Host()
	typed, err := c.Prompter.Typed("yes", host, fmt.Sprintf("type the hostname (%s) to confirm:", host), o.Yes)
	if err != nil {
		return err
	}
	if !typed {
		return cli.Fail("that is not %s — nothing was changed on %s", host, o.Target)
	}
	return p.act(c.Out, c.Prompter, s)
}

func dataDir(apps, data string) string {
	rest, ok := strings.CutPrefix(data, apps+"/")
	if !ok || rest == "" || strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

func (p *Plan) check() error {
	s := p.Scan
	if !s.HaveDocker || s.DockerError != "" {
		e := cli.Fail("docker did not answer on %s", p.Target)
		if s.DockerError != "" {
			e.Cont(s.DockerError)
		}
		return e.Cont("the backup stack cannot be stopped without it, and a de-branding that leaves",
			"the schedule running would go on pushing this server's data into the",
			"departing operator's storage — nothing was removed")
	}
	switch s.AppsState {
	case "dir":
	case "notdir":
		return cli.Fail("%s on %s is not a directory", p.Apps, p.Target)
	case "noaccess":
		return cli.Fail("%s on %s cannot be entered by this user — destroy walks every project there", p.Apps, p.Target)
	default:
		return cli.Failf(cli.ExitNoRemoteState, "%s on %s is not there", p.Apps, p.Target).Cont(
			"the server marker names it, so this server's layout and its tree disagree",
			"— nothing was removed")
	}
	return nil
}

func hasWork(r Row) bool {
	return r.Vlog != "missing" || r.VlogGz != "missing" || r.Helpers != 0 ||
		r.Lock != "missing" || r.Client != "missing" || r.Sentinels != 0 || (r.Prev != "absent" && r.Prev != "")
}

func (p *Plan) anything() bool {
	s := p.Scan
	if s.MarkerState != "missing" || s.KasbahDir != "absent" || s.BackupContainer != "absent" ||
		s.BackupVolume != "absent" || s.BackupNetwork != "absent" || s.PointerState != "missing" ||
		s.RegistryState != "missing" || s.MailEnvExtra != 0 {
		return true
	}
	for _, r := range p.Projects {
		if hasWork(r) {
			return true
		}
	}
	return false
}

func planProject(r Row) string {
	var parts []string
	if r.Vlog != "missing" {
		parts = append(parts, "versions.log")
	}
	if r.VlogGz != "missing" {
		parts = append(parts, "versions.log.gz")
	}
	if r.Helpers != 0 {
		if r.Other == 0 {
			parts = append(parts, fmt.Sprintf("scripts/ (%d helper(s), and nothing else)", r.Helpers))
		} else {
			parts = append(parts, fmt.Sprintf("%d helper(s) out of scripts/, keeping %d other file(s) and the directory", r.Helpers, r.Other))
		}
	}
	if r.Lock != "missing" {
		parts = append(parts, ".deploy.lock")
	}
	if r.Client != "missing" {
		parts = append(parts, ".kasbah-client")
	}
	if r.Prev != "absent" && r.Prev != "" {
		parts = append(parts, ".kasbah-prev/ (a failed deploy's snapshot, with a copy of .env)")
	}
	if r.Sentinels != 0 {
		parts = append(parts, fmt.Sprintf(".env: %d managed-block sentinel comment(s), values kept", r.Sentinels))
	}
	return strings.Join(parts, ", ")
}

func pointerDir() string {
	return serverbin.Pointer[:strings.LastIndex(serverbin.Pointer, "/")]
}

// Report is the plan, on stdout, in the order the act runs.
func (p *Plan) Report(w io.Writer) {
	s := p.Scan
	fmt.Fprintf(w, "kasbah server destroy — %s (%s)\n\n", p.Target, p.Apps)
	fmt.Fprintf(w, "to remove\n")
	if s.BackupDir == "absent" && s.BackupContainer == "absent" {
		fmt.Fprintf(w, "  backups     none — no backup stack on this server\n")
	} else {
		fmt.Fprintf(w, "  backups     stop and remove the %s stack: container %s (%s),\n", BackupProject, BackupContainer, s.BackupContainer)
		fmt.Fprintf(w, "              volume %s (%s), network %s (%s),\n", BackupVolume, s.BackupVolume, BackupNetwork, s.BackupNetwork)
		fmt.Fprintf(w, "              and %s/.kasbah/backup/ (%s) — compose.yml, the run record, the\n", p.Apps, s.BackupDir)
		fmt.Fprintf(w, "              credentials in env, and every repository password\n")
	}
	if len(p.Projects) == 0 {
		fmt.Fprintf(w, "  projects    none under %s\n", p.Apps)
	} else {
		width := 0
		for _, r := range p.Projects {
			width = max(width, len(r.Name))
		}
		fmt.Fprintf(w, "  projects\n")
		for _, r := range p.Projects {
			if hasWork(r) {
				fmt.Fprintf(w, "    %-*s  %s\n", width, r.Name, planProject(r))
			} else {
				fmt.Fprintf(w, "    %-*s  nothing of kasbah's left here\n", width, r.Name)
			}
		}
	}
	fmt.Fprintf(w, "\n  mail        ")
	keys := strings.Join(MailKeys, " ")
	if s.MailDir == "dir" {
		if s.MailEnvState == "ok" && s.MailEnvExtra != 0 {
			fmt.Fprintf(w, "%d line(s) of %s/mail/.env that are not %s\n", s.MailEnvExtra, p.Apps, keys)
			fmt.Fprintf(w, "              (those three stay, so the stack still starts)\n")
		} else {
			fmt.Fprintf(w, "%s/mail/.env is %s — nothing to strip out of it\n", p.Apps, s.MailEnvState)
		}
		fmt.Fprintf(w, "              %s/mail/kasbah.yml (%s) — the domain registry\n", p.Apps, s.RegistryState)
	} else {
		fmt.Fprintf(w, "none — no mail stack at %s/mail\n", p.Apps)
	}

	fmt.Fprintf(w, "\n  marker      %s/.kasbah/server.json (%s)\n", p.Apps, s.MarkerState)
	sudo := s.Sudo == "root" || s.Sudo == "yes"
	fmt.Fprintf(w, "  pointer     %s (%s)", serverbin.Pointer, s.PointerState)
	if sudo || s.PointerState == "missing" {
		fmt.Fprintln(w)
	} else {
		fmt.Fprintf(w, " — root-owned, and `sudo -n` is not available here,\n              so the commands to remove it are printed for you to run\n")
	}
	switch {
	case !sudo || s.PointerDir != "dir":
	case s.PointerDirOther == 0:
		fmt.Fprintf(w, "              and %s/ with it, which holds nothing else\n", pointerDir())
	default:
		fmt.Fprintf(w, "              %s/ itself stays — it holds %d other file(s)\n", pointerDir(), s.PointerDirOther)
	}
	fmt.Fprintf(w, "  binary      %s (%s) — the kasbah that runs this, removed last\n", serverbin.Path(p.Apps), s.BinState)
	if len(s.KasbahExtra) > 0 {
		fmt.Fprintf(w, "              %s/.kasbah/ itself stays — it also holds %s\n", p.Apps, strings.Join(s.KasbahExtra, " "))
	} else {
		lock := ""
		if s.BinLock {
			lock = "with its lock, then "
		}
		fmt.Fprintf(w, "              %s%s/.kasbah/bin/ and %s/.kasbah/, which hold nothing else\n", lock, p.Apps, p.Apps)
	}

	fmt.Fprintf(w, "\nleft alone\n")
	if len(s.Skipped) > 0 {
		fmt.Fprintf(w, "  %s under %s — not a project name, so not kasbah's to touch\n", strings.Join(s.Skipped, " "), p.Apps)
	}
	fmt.Fprintf(w, "  every container but the backup scheduler's, projects and Traefik alike — the sites stay up\n")
	fmt.Fprintf(w, "  every compose.yml, .env value, and Traefik fragment\n")
	fmt.Fprintf(w, "  %s/, %s/<project>/backups/, named volumes and images\n", p.Data, p.Apps)
	if s.MailDir == "dir" {
		fmt.Fprintf(w, "  the postmaster account in %s/mail/dms/config/postfix-accounts.cf\n", p.Data)
	}
	fmt.Fprintf(w, "  the off-VPS restic repositories — operator property (docs/backup.md)\n")
	fmt.Fprintf(w, "\nthis is permanent: the deploy history in versions.log, and the mail domain\n")
	fmt.Fprintf(w, "registry, exist nowhere else. A later `server init` cannot reproduce them.\n\n")
}

type reporter struct {
	o      *cli.Output
	target string
	bad    bool
}

func (r *reporter) say(f string, a ...any) {
	if f == "" {
		fmt.Fprintln(r.o.Stdout)
		return
	}
	fmt.Fprintf(r.o.Stdout, "  "+f+"\n", a...)
}

// step is one removed|absent|failed verdict.
func (r *reporter) step(v, did, absent, failure string) {
	switch v {
	case "removed":
		r.say("%s", did)
	case "absent":
		r.say("%s", absent)
	default:
		r.say("FAILED: %s", failure)
		r.o.Err("%s", failure)
		r.bad = true
	}
}

func (p *Plan) act(o *cli.Output, pr *prompt.Prompter, s Session) error {
	names := make([]string, len(p.Projects))
	for i, r := range p.Projects {
		names[i] = r.Name
	}
	again := fmt.Sprintf("`kasbah server destroy %s`", p.Target)
	out, rc := s.Act(p.Apps, names)
	head, body, _ := bytes.Cut(bytes.ReplaceAll(out, []byte("\r"), nil), []byte("\n"))
	started := string(head) == "started=yes"
	if rc != 0 || !started {
		e := cli.Fail("the destroy step on %s exited %d", p.Target, rc)
		if started {
			return e.Cont("some of it may have run — " + again + " again to see what is left")
		}
		return e.Cont("it refused before changing anything — nothing was removed")
	}
	var a ActReport
	if err := remote.Decode(body, &a, actKeys, "the destroy step", p.Target); err != nil {
		return err
	}
	// By name and in order: the report below is keyed by name.
	if len(a.Projects) != len(names) {
		return cli.Fail("the destroy step on %s reported %d of %d projects", p.Target, len(a.Projects), len(names)).Cont(
			"the step was truncated; run destroy again to see what is left")
	}
	for i, n := range names {
		if a.Projects[i].Name != n {
			return cli.Fail("the destroy step on %s reported '%s' where the plan named '%s'", p.Target, a.Projects[i].Name, n).Cont(
				"the step and the plan disagree about which projects this server has —",
				"run destroy again to see what is left")
		}
	}
	r := &reporter{o: o, target: p.Target}
	p.reportBackup(r, &a)
	for _, res := range a.Projects {
		p.reportProject(r, res)
	}
	p.reportMail(r, &a)

	var tail map[string]string
	if a.Marker == "held" {
		r.say("kept the server marker and %s — a step above failed", serverbin.Pointer)
	} else {
		r.step(a.Marker, "removed the server marker "+p.Apps+"/.kasbah/server.json",
			"there was no server marker at "+p.Apps+"/.kasbah/server.json",
			"could not remove "+p.Apps+"/.kasbah/server.json on "+p.Target)
		if !r.bad {
			tout, trc := s.Tail(p.Apps)
			tail = kv(tout)
			if trc != 0 || tail["done"] != "yes" {
				r.say("FAILED: the last step — %s and the server's kasbah binary", serverbin.Pointer)
				o.Err("the last destroy step on %s exited %d", p.Target, trc)
				o.ErrCont("the marker is gone, so a re-run reports what is still there")
				r.bad = true
			} else {
				p.reportTail(r, tail)
			}
		}
	}

	if r.bad {
		e := cli.Fail("%s was not fully de-branded — see the FAILED line(s) above", p.Target)
		if a.Marker == "held" {
			e.Cont("the server marker and "+serverbin.Pointer+" were kept so a second run can find",
				"this server: fix what failed, then "+again+" again.")
		}
		return e
	}
	if tail["pointer"] == "nosudo" || tail["pointer_dir"] == "nosudo" {
		h, err := pointerByHand(pr, s, p.Target)
		if err != nil {
			return err
		}
		if !h.ending(r, pr.TTY) {
			return nil
		}
	}
	r.say("")
	r.say("%s is a plain Docker Compose host now. Every site is still running,", p.Target)
	r.say("and nothing kasbah installed is left to hand over with it.")
	return nil
}

// pointerBlock removes what the pointer probe sees: the pointer, and its
// directory while nothing else is in it.
func pointerBlock(target string, facts map[string]string) *rootsteps.Block {
	user, _, ok := strings.Cut(target, "@")
	if !ok {
		user = ""
	}
	b := &rootsteps.Block{Target: target, User: user}
	if facts["pointer"] != "absent" {
		b.Add("sudo rm -f " + rootsteps.Quote(serverbin.Pointer))
	}
	if facts["pointer_dir"] == "empty" {
		b.Add("sudo rmdir " + rootsteps.Quote(pointerDir()))
	}
	return b
}

// byHand is the pointer and its directory where `sudo -n` cannot reach them:
// first and last are what the pointer probe saw, left what was still to run.
type byHand struct {
	first, last map[string]string
	left        *rootsteps.Block
	done        bool
}

func probePointer(s Session, target string) (map[string]string, error) {
	out, rc := s.Pointer()
	facts := kv(out)
	if rc != 0 || facts["pointer"] == "" || facts["pointer_dir"] == "" {
		return nil, cli.Fail("the pointer check on %s exited %d", target, rc)
	}
	return facts, nil
}

// pointerByHand prints the commands for what the probe sees and, on a
// terminal, waits for them, probing again after each Enter.
func pointerByHand(pr *prompt.Prompter, s Session, target string) (*byHand, error) {
	first, err := probePointer(s, target)
	if err != nil {
		return nil, err
	}
	h := &byHand{first: first, last: first}
	why := func() []string {
		if h.last["pointer"] == "absent" {
			return []string{fmt.Sprintf("%s/ on %s is empty and root-owned, left behind by kasbah.", pointerDir(), target)}
		}
		return []string{fmt.Sprintf("%s on %s is root-owned and still names this server as one kasbah prepared.", serverbin.Pointer, target)}
	}
	h.done, h.left, err = rootsteps.Await(pr, why, pointerBlock(target, first), func() (*rootsteps.Block, error) {
		facts, err := probePointer(s, target)
		if err != nil {
			return nil, err
		}
		h.last = facts
		return pointerBlock(target, facts), nil
	})
	return h, err
}

// report says what the operator removed, or what is left for them: the
// commands, unless they are already on the terminal.
func (h *byHand) report(r *reporter, tty bool) {
	switch {
	case pointerBlock("", h.first).Empty():
	case !h.done && tty:
		r.say("The commands above finish it.")
	case !h.done:
		for _, l := range h.left.Lines() {
			r.say("%s", l)
		}
	case h.first["pointer"] == "absent":
		r.say("%s/ was removed by hand", pointerDir())
	case h.last["pointer_dir"] == "dir":
		r.say("%s was removed by hand; %s/ stays — it holds something kasbah did not write", serverbin.Pointer, pointerDir())
	default:
		r.say("%s and %s/ were removed by hand", serverbin.Pointer, pointerDir())
	}
}

// ending is a run's last word on the pointer: true when nothing of it is
// left, else what is left has been said, with how to remove it.
func (h *byHand) ending(r *reporter, tty bool) bool {
	if h.done {
		h.report(r, tty)
		return true
	}
	r.say("")
	if h.last["pointer"] == "absent" {
		r.say("%s is a plain Docker Compose host now, but for %s/, which is", r.target, pointerDir())
		r.say("still there, empty and root-owned.")
	} else {
		r.say("%s is one file short of a plain Docker Compose host. Every site is", r.target)
		r.say("still running, and the only thing kasbah installed that is still there is")
		r.say("%s, which this user cannot remove.", serverbin.Pointer)
	}
	h.report(r, tty)
	return false
}

func (p *Plan) reportBackup(r *reporter, a *ActReport) {
	switch a.BkDown {
	case "ok":
		r.say("stopped the %s stack", BackupProject)
	case "skipped":
		r.say("no backup stack to stop")
	default:
		r.say("FAILED: docker compose -p %s down", BackupProject)
		r.o.Err("the backup stack on %s could not be stopped", p.Target)
		if a.BkDownDetail != "" {
			r.o.ErrCont("%s", a.BkDownDetail)
		}
		r.o.ErrCont("it is still scheduled to push this server's data to the operator's storage")
		r.bad = true
	}
	stack := func(v, removed, went, none, failure string) {
		if v == "absent" {
			if a.BkDown == "skipped" {
				r.say("%s", none)
			} else {
				r.say("%s", went)
			}
			return
		}
		r.step(v, removed, none, failure)
	}
	stack(a.BkContainer, "removed the "+BackupContainer+" container, which survived `down`",
		"the "+BackupContainer+" container went down with the stack",
		"there was no "+BackupContainer+" container",
		"could not remove the "+BackupContainer+" container on "+p.Target)
	r.step(a.BkVolume, "removed the "+BackupVolume+" volume", "there was no "+BackupVolume+" volume",
		"could not remove the "+BackupVolume+" volume on "+p.Target)
	stack(a.BkNetwork, "removed the "+BackupNetwork+" network, which survived `down`",
		"the "+BackupNetwork+" network went with the stack",
		"there was no "+BackupNetwork+" network",
		"could not remove the "+BackupNetwork+" network on "+p.Target)
	r.step(a.BkFiles, "removed "+p.Apps+"/.kasbah/backup/ — the runner, the credentials and every repository password",
		"there was no "+p.Apps+"/.kasbah/backup/",
		"could not remove "+p.Apps+"/.kasbah/backup/ on "+p.Target+" — it holds the operator's credentials")
}

func (p *Plan) reportProject(r *reporter, pr ProjectResult) {
	file := func(name, v string) {
		switch v {
		case "removed":
			r.say("  removed %s", name)
		case "absent":
			r.say("  no %s", name)
		default:
			r.say("  FAILED to remove %s", name)
			r.o.Err("could not remove %s/%s/%s on %s", p.Apps, pr.Name, name, p.Target)
			r.bad = true
		}
	}
	helpers := strings.Join(Helpers, " ")
	r.say("%s:", pr.Name)
	file("versions.log", pr.Vlog)
	file("versions.log.gz", pr.VlogGz)
	switch pr.Scripts {
	case "removed":
		r.say("  removed scripts/ — kasbah's %s", helpers)
	case "kept":
		r.say("  removed kasbah's %s from scripts/, keeping the directory — it holds files kasbah did not write", helpers)
	case "absent":
		r.say("  no scripts/")
	case "notdir":
		r.say("  %s/%s/scripts is not a directory — left alone", p.Apps, pr.Name)
	default:
		r.say("  FAILED to remove scripts/ helpers")
		r.o.Err("could not remove %s/%s/scripts helpers on %s", p.Apps, pr.Name, p.Target)
		r.bad = true
	}
	file(".deploy.lock", pr.Lock)
	file(".kasbah-client", pr.Client)
	if pr.Prev != "absent" && pr.Prev != "" {
		file(".kasbah-prev/", pr.Prev)
	}
	switch pr.Env {
	case "stripped":
		r.say("  removed the managed-block sentinel comments from .env — every value is untouched")
	case "noblock":
		r.say("  .env carries no managed block")
	case "absent":
		r.say("  no .env")
	case "unreadable":
		r.say("  FAILED: .env could not be read or written")
		r.o.Err("%s/%s/.env on %s could not be rewritten", p.Apps, pr.Name, p.Target)
		r.o.ErrCont("it still carries the comment saying kasbah rewrites the block on every")
		r.o.ErrCont("deploy, which stopped being true — fix the file's mode or owner and re-run")
		r.bad = true
	default:
		r.say("  FAILED to rewrite .env")
		r.o.Err("could not rewrite %s/%s/.env on %s", p.Apps, pr.Name, p.Target)
		r.o.ErrCont("the file is unchanged — no value was lost")
		r.bad = true
	}
}

func (p *Plan) reportMail(r *reporter, a *ActReport) {
	keys := strings.Join(MailKeys, " ")
	me := p.Apps + "/mail/.env"
	switch a.MailEnv {
	case "stripped":
		r.say("removed %d line(s) from %s — %s stay", a.MailEnvN, me, keys)
	case "unchanged":
		r.say("%s holds nothing but %s", me, keys)
	case "absent":
		r.say("no %s", me)
	case "unreadable":
		r.say("FAILED: %s could not be read or written", me)
		r.o.Err("%s on %s could not be rewritten", me, p.Target)
		r.o.ErrCont("any relay credential in it is still on this server, which is the one thing")
		r.o.ErrCont("this command exists to prevent — fix the file's mode or owner and re-run")
		r.bad = true
	default:
		r.say("FAILED to rewrite %s", me)
		r.o.Err("could not rewrite %s on %s", me, p.Target)
		r.o.ErrCont("the file is unchanged, so the operator's relay credentials are still on this server")
		r.bad = true
	}
	r.step(a.MailRegistry, "removed "+p.Apps+"/mail/kasbah.yml — the domain registry",
		"no "+p.Apps+"/mail/kasbah.yml", "could not remove "+p.Apps+"/mail/kasbah.yml on "+p.Target)
}

func (p *Plan) reportTail(r *reporter, t map[string]string) {
	pd := pointerDir()
	switch t["pointer"] {
	case "removed":
		r.say("removed %s", serverbin.Pointer)
	case "absent":
		r.say("there was no %s", serverbin.Pointer)
	case "nosudo":
		r.say("could NOT remove %s — it is root-owned and `sudo -n` is not available", serverbin.Pointer)
	default:
		r.say("FAILED to remove %s", serverbin.Pointer)
		r.o.Err("could not remove %s on %s", serverbin.Pointer, p.Target)
		r.bad = true
	}
	switch t["pointer_dir"] {
	case "removed":
		r.say("removed %s/", pd)
	case "absent":
		r.say("there was no %s/", pd)
	case "kept":
		r.say("kept %s/ — it still holds something kasbah did not write", pd)
	case "nosudo":
	default:
		r.say("FAILED on %s/", pd)
		r.o.Err("could not remove %s/ on %s", pd, p.Target)
		r.bad = true
	}
	bin := serverbin.Path(p.Apps)
	if t["binary"] == "link" {
		r.say("%s/.kasbah or its bin/ is a symlink — left alone, with what it points at", p.Apps)
		r.o.Warn("%s/.kasbah or %s/.kasbah/bin is a symlink; kasbah removes nothing through it", p.Apps, p.Apps)
	} else {
		r.step(t["binary"], "removed the server's kasbah binary "+bin, "there was no "+bin,
			"could not remove "+bin+" on "+p.Target)
	}
	k := p.Apps + "/.kasbah"
	for _, d := range []struct{ v, path string }{{t["bin_dir"], k + "/bin"}, {t["kasbah_dir"], k}} {
		switch d.v {
		case "removed":
			r.say("removed %s/", d.path)
		case "absent":
			r.say("there was no %s/", d.path)
		case "kept":
			r.say("kept %s/ — it still holds something kasbah did not write", d.path)
			r.o.Warn("%s/ is not empty, so it stays: `ssh %s 'ls -a %s'`", d.path, p.Target, d.path)
		case "notdir":
			r.say("%s is not a directory — left alone", d.path)
		case "link":
		default:
			r.say("FAILED on %s/", d.path)
			r.o.Err("could not remove %s/ on %s", d.path, p.Target)
			r.bad = true
		}
	}
}

// ownOnly is whether everything left under .kasbah is the binary's own: bin/
// holding nothing but the binary, its lock and uploads.
func ownOnly(items []string) bool {
	for _, it := range items {
		i := strings.LastIndex(it, "/")
		if i < 0 {
			return false
		}
		dir, base := it[:i], it[i+1:]
		switch {
		case strings.HasSuffix(dir, "/.kasbah") && base == "bin":
		case strings.HasSuffix(dir, "/.kasbah/bin") && binOwn(base):
		default:
			return false
		}
	}
	return true
}

// finishTail is the last step a run never reached — its session dropped
// after the marker went: the pointer and the binary, removed now.
func finishTail(o *cli.Output, pr *prompt.Prompter, s Session, target string, kasbah []string) error {
	fmt.Fprintf(o.Stdout, "  what is left is kasbah's last step, which an earlier run did not reach — finishing it\n")
	apps := []string{serverbin.DefaultApps}
	if len(kasbah) > 0 {
		apps = nil
		for _, k := range kasbah {
			apps = append(apps, strings.TrimSuffix(k, "/.kasbah"))
		}
	}
	r := &reporter{o: o, target: target}
	var nosudo bool
	for _, a := range apps {
		out, rc := s.Tail(a)
		t := kv(out)
		if rc != 0 || t["done"] != "yes" {
			return cli.Fail("the last destroy step on %s exited %d", target, rc)
		}
		(&Plan{Target: target, Apps: a}).reportTail(r, t)
		nosudo = nosudo || t["pointer"] == "nosudo" || t["pointer_dir"] == "nosudo"
	}
	if r.bad {
		return cli.Fail("%s was not fully de-branded — see the FAILED line(s) above", target)
	}
	if nosudo {
		// Server-wide: one wait, whichever apps path's tail found it.
		h, err := pointerByHand(pr, s, target)
		if err != nil {
			return err
		}
		h.ending(r, pr.TTY)
	}
	return nil
}

// nothingToFind is a server with no marker: what a completed destroy leaves,
// so not an error — unless the backup credentials outlived it.
func nothingToFind(o *cli.Output, pr *prompt.Prompter, s Session, target, reason string) error {
	w := o.Stdout
	fmt.Fprintf(w, "kasbah server destroy — %s\n\n", target)
	if reason != "" {
		fmt.Fprintf(w, "  %s\n", reason)
	}
	out, rc := s.Leftovers()
	if rc != 0 {
		fmt.Fprintf(w, "  nothing was removed\n")
		o.Warn("could not check what %s is still carrying — re-run, or look by hand at", target)
		o.Warn("  %s and %s/.kasbah", serverbin.Pointer, serverbin.DefaultApps)
		return nil
	}
	var kasbah, creds, items []string
	pointer := false
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		l := strings.TrimSuffix(sc.Text(), "\r")
		switch {
		case l == "pointer=yes":
			pointer = true
		case strings.HasPrefix(l, "kasbah="):
			kasbah = append(kasbah, strings.TrimPrefix(l, "kasbah="))
		case strings.HasPrefix(l, "creds="):
			creds = append(creds, strings.TrimPrefix(l, "creds="))
		case strings.HasPrefix(l, "item="):
			items = append(items, strings.TrimPrefix(l, "item="))
		case strings.HasPrefix(l, "foreign="):
			items = append(items, "")
		}
	}
	if len(creds) == 0 && (pointer || len(kasbah) > 0) && ownOnly(items) {
		return finishTail(o, pr, s, target, kasbah)
	}
	left := false
	var credErr error
	switch {
	case len(creds) > 0:
		left = true
		c := strings.Join(creds, " ")
		fmt.Fprintf(w, "  %s is still there — the backup stack's runner and its\n", c)
		fmt.Fprintf(w, "  credentials, which is the one thing this command exists to take away.\n")
		credErr = cli.Fail("the marker is gone but %s is not, so destroy cannot enumerate this", c).Cont(
			"server and cannot remove them. That directory holds the repository URL and one",
			"password per repository, at mode 600. Take the stack down and delete it:",
			fmt.Sprintf("  ssh %s 'docker compose -p %s down; docker volume rm %s'", target, BackupProject, BackupVolume),
			fmt.Sprintf("  ssh %s 'rm -rf %s'", target, c))
	case len(kasbah) > 0:
		left = true
		k := strings.Join(kasbah, " ")
		fmt.Fprintf(w, "  %s is still there, with no marker in it.\n", k)
		o.Warn("%s on %s outlived the marker — look at what is in it:", k, target)
		o.Warn("  ssh %s 'ls -la %s'", target, k)
	}
	if pointer {
		left = true
		fmt.Fprintf(w, "  %s is still there, and it names this server as one kasbah prepared.\n", serverbin.Pointer)
		facts, err := probePointer(s, target)
		if err != nil {
			return err
		}
		// Reported, never waited on: this path removes nothing, sudo or not.
		b := pointerBlock(target, facts)
		b.User = ""
		for _, l := range b.Lines() {
			fmt.Fprintf(w, "  %s\n", l)
		}
	}
	if left {
		fmt.Fprintf(w, "  nothing else can be enumerated without a marker, and nothing was removed\n")
		// Credentials are a secret still pushing data to the departing
		// operator; a pointer or an empty .kasbah is a discovery hint.
		return credErr
	}
	fmt.Fprintf(w, "  no server marker, no %s and no .kasbah directory — this server\n", serverbin.Pointer)
	fmt.Fprintf(w, "  carries nothing of kasbah's management layer, and nothing was removed\n")
	return nil
}
