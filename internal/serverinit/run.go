package serverinit

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/fs"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/tree"
)

// TraefikTimeout is how long the start step waits for Traefik's healthcheck.
const TraefikTimeout = 120

// Ctx is what a run needs from its surroundings.
type Ctx struct {
	Out       *cli.Output
	Prompter  *prompt.Prompter
	Version   string
	Templates fs.FS
	Self      remote.Info
	Local     func(arch string) (string, error)
	Hash      Hasher
	// Crypt hashes the postmaster password; nil is Crypt.
	Crypt Crypter
	Now   func() time.Time
}

// Features asks the two questions before anything is opened, mail first: a
// run nobody can answer costs no connection.
func Features(p *prompt.Prompter, o Options) (mail, backup bool, err error) {
	if mail, err = p.Bool("mail", fmt.Sprintf("Scaffold the mail stack (DMS + Cypht) on %s?", o.Target), o.Mail); err != nil {
		return
	}
	backup, err = p.Bool("backup", fmt.Sprintf("Install the restic backup stack on %s?", o.Target), o.Backup)
	return
}

// session is one run's connection and, once shipped, the server's binary.
type session struct {
	conn   *ssh.Conn
	target string
	bin    string
}

// script runs a bootstrap step under the server's sh with its args as $1….
func (s *session) script(body string, args ...string) (string, int) {
	cmd := s.conn.Script(body, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), ssh.ExitCode(err)
}

// call is `kasbah remote init ARGS…` on the server, bounded unless long.
func (s *session) call(stdin []byte, bounded bool, args ...string) (string, int) {
	return s.remote(stdin, bounded, append([]string{"init"}, args...)...)
}

// remote is `kasbah remote ARGS…` on the server, bounded unless long.
func (s *session) remote(stdin []byte, bounded bool, args ...string) (string, int) {
	words := append([]string{s.bin, "remote"}, args...)
	if bounded {
		words = serverbin.Bounded(s.bin, serverbin.RunTimeout, args...)
	}
	cmd := s.conn.Command(words...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), ssh.ExitCode(err)
}

// send is a bounded call installing body: its size and sha256 travel in argv,
// so a cut stream is refused rather than installed.
func (s *session) send(body []byte, args ...string) (string, int) {
	size, sum := remote.Digest(body)
	return s.call(body, true, append(args, size, sum)...)
}

func (s *session) ensure(c Ctx, apps string) (*serverbin.Result, error) {
	res, err := serverbin.Ensure(s.conn, c.Self, c.Local, serverbin.Options{Apps: apps})
	if err != nil {
		return nil, err
	}
	s.bin = serverbin.Path(res.Apps)
	return res, nil
}

// elevateScript creates the apps path as root and hands it over — asking
// root once more first, because the chown is the irreversible half.
const elevateScript = `set -u
export LC_ALL=C
apps=$1
owner=$2
fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }
if sudo -n test -e "$apps"; then
    fail "$apps exists after all (root sees it, owner $(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null)) — kasbah creates the apps path, it never takes over one that is already there"
fi
parent=${apps%/*}
[ -n "$parent" ] || parent=/
sudo -n mkdir -p "$parent" || fail "sudo mkdir -p $parent failed"
sudo -n mkdir "$apps" || fail "sudo mkdir $apps failed — it exists already, and kasbah only chowns what it created"
sudo -n chown "$owner" "$apps" || fail "sudo chown $owner $apps failed"
printf 'elevated=yes\n'
`

// pointerScript writes /etc/kasbah/apps-path as root: staged, installed,
// renamed. A right pointer is left alone, so a re-run needs no sudo; a
// drifted directory mode is repaired when sudo allows, else reported. $3 is
// root's uid, overridden only by tests.
const pointerScript = `set -u
export LC_ALL=C
cr=$(printf '\r')
apps=$1
pointer=$2
root_uid=${3:-0}
dir=${pointer%/*}
staged=""
drift=""
fail() { [ -z "$staged" ] || rm -f "$staged"; printf 'remote: %s\n' "$*" >&2; exit 1; }

if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    fail "$pointer exists and is not a regular file"
fi
if [ -f "$pointer" ] && [ -r "$pointer" ]; then
    current=""
    IFS= read -r current < "$pointer" || [ -n "$current" ] || current=""
    current=${current%"$cr"}
    meta=$(stat -c '%a %u' "$pointer" 2>/dev/null) || meta=""
    dmeta=$(stat -c '%a' "$dir" 2>/dev/null) || dmeta=""
    if [ "$current" = "$apps" ] && [ "$meta" = "644 $root_uid" ]; then
        if [ "$dmeta" = 755 ]; then
            printf 'pointer=unchanged\n'
            exit 0
        fi
        drift=${dmeta:-unknown}
    fi
fi

sudo_cmd=""
if [ "$(id -u)" != 0 ]; then
    if sudo -n true >/dev/null 2>&1; then
        sudo_cmd="sudo -n"
    elif [ -n "$drift" ]; then
        printf 'pointer=unchanged\npointer_dir_mode=%s\n' "$drift"
        exit 0
    else
        printf 'pointer=nosudo\n'
        exit 0
    fi
fi

staged="${TMPDIR:-/tmp}/kasbah-apps-path.$$"
tmp="$pointer.tmp.$$"
printf '%s\n' "$apps" > "$staged" || fail "could not stage the pointer at $staged"
$sudo_cmd mkdir -p "$dir" || fail "sudo mkdir -p $dir failed"
$sudo_cmd chmod 755 "$dir" || fail "sudo chmod 755 $dir failed"
$sudo_cmd cp "$staged" "$tmp" || fail "could not write $tmp"
rm -f "$staged"
$sudo_cmd chown 0:0 "$tmp" || fail "could not give $tmp to root"
$sudo_cmd chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
$sudo_cmd mv -f "$tmp" "$pointer" || fail "could not install $pointer"
printf 'pointer=written\n'
exit 0
`

// PointerVerdict is what a pointer that could not be written costs: a
// warning at the default apps path, which is found without it; a failure
// anywhere else, which is not.
func PointerVerdict(out *cli.Output, state, target, apps, user string) error {
	switch state {
	case "written", "unchanged":
		return nil
	case "nosudo":
	default:
		return cli.Fail("the pointer step on %s reported '%s', which this kasbah does not know", target, state)
	}
	dir := Pointer[:strings.LastIndex(Pointer, "/")]
	if apps != DefaultApps {
		return cli.Fail("could not write %s on %s — `sudo -n` is not available to %s", Pointer, target, user).Cont(
			fmt.Sprintf("%s is prepared at %s and nothing can find it: that file is", target, apps),
			"how `kasbah deploy` and `kasbah env` discover a server prepared anywhere other",
			fmt.Sprintf("than %s. Without it they look under %s, find no marker", DefaultApps, DefaultApps),
			"and exit 4. Grant NOPASSWD sudo and re-run, or create it once by hand:",
			fmt.Sprintf(`  ssh %s 'sudo mkdir -p %s && printf "%%s\n" %s | sudo tee %s >/dev/null && sudo chmod 644 %s'`, target, dir, apps, Pointer, Pointer))
	}
	out.Warn("could not write %s on %s — `sudo -n` is not available to %s", Pointer, target, user)
	out.Warn("nothing is broken: %s is where every project command looks when there is no", apps)
	out.Warn("pointer. It would only matter if this server were ever re-prepared elsewhere.")
	return nil
}

func stepFailed(what, target string, rc int) error {
	return cli.Fail("could not %s on %s (the remote step exited %d, see above)", what, target, rc)
}

// pointerPath is Pointer, moved only by tests.
var pointerPath = Pointer

// Run prepares o.Target in docs/server-setup.md's order: every question is
// answered before anything is created or restarted (on an existing apps path
// the server's binary may already have been brought up to date to read it);
// the marker signals completion, the pointer comes right after.
func Run(c Ctx, o Options) (err error) {
	out := c.Out
	conn, err := ssh.Connect(o.Target)
	if err != nil {
		return err
	}
	defer conn.Close()
	s := &session{conn: conn, target: o.Target}
	target := o.Target

	raw, rc := s.script(probeScript, o.Apps, o.Data, pointerPath)
	if rc != 0 {
		return cli.Fail("could not collect prerequisites from %s (the remote probe exited %d)", target, rc)
	}
	f, err := ParseProbe(target, raw)
	if err != nil {
		return err
	}
	if err := Preflight(f, target, o.Apps, o.Data); err != nil {
		return err
	}
	// Before anything ships: the binary's bootstrap mode ignores the pointer.
	if err := CheckPointer(f, target, o.Apps); err != nil {
		return err
	}
	cpu, mem, err := Limits(f["nproc"], f["memtotal_kb"])
	if err != nil {
		return err
	}
	elevate := f["apps_state"] == "absent"
	// From the Traefik start on, the tree may be in use: no bare rm -rf.
	started := false

	// Nothing exists under an apps path that does not, so a bare host reads
	// nothing; an existing one — a re-run, or one pre-created by hand as the
	// preflight suggests — is read by the server's binary, shipped first.
	var ensured *serverbin.Result
	markerPath := marker.Path(o.Apps)
	var existing []byte
	present := false
	cur := map[string]string{}
	if !elevate {
		if ensured, err = s.ensure(c, o.Apps); err != nil {
			return err
		}
		body, rc := s.call(nil, true, "read", o.Apps)
		var r ReadReport
		if rc != 0 {
			return cli.Fail("could not read %s on %s (the remote step exited %d, see above)", markerPath, target, rc)
		}
		if json.Unmarshal([]byte(body), &r) != nil || (r.Marker != "present" && r.Marker != "absent") || r.Traefik == nil {
			return cli.Fail("the read of %s/traefik on %s reported nothing kasbah can use", o.Apps, target).Cont(
				"the step was truncated, or the server's kasbah rejected it — raw output:", "| "+strings.TrimSpace(body))
		}
		present = r.Marker == "present"
		if existing, err = base64.StdEncoding.DecodeString(r.Body); err != nil {
			return cli.Fail("the read of %s on %s returned a marker that does not decode", markerPath, target)
		}
		for _, rel := range Files {
			b, err := base64.StdEncoding.DecodeString(r.Traefik[rel])
			if err != nil {
				return cli.Fail("the read of %s/traefik/%s on %s returned content that does not decode", o.Apps, rel, target)
			}
			cur[rel] = string(b)
		}
	}

	// The mail stack is read like Traefik's: on a bare host there is none.
	mailOn := o.Mail == prompt.Yes
	mr := freshMail
	var mcur map[string]string
	if mailOn {
		if !elevate {
			body, rc := s.remote(nil, true, "mail", "read", o.Apps, o.Data)
			if rc != 0 {
				return cli.Fail("could not read the mail stack on %s (the remote step exited %d, see above)", target, rc)
			}
			if json.Unmarshal([]byte(body), &mr) != nil {
				return cli.Fail("the mail stack read on %s reported nothing kasbah can use", target).Cont(
					"the step was truncated, or the server's kasbah rejected it — raw output:", "| "+strings.TrimSpace(body))
			}
		}
		if mcur, err = MailCurrent(&mr, target); err != nil {
			return err
		}
	}

	backupOn := o.Backup == prompt.Yes
	var br *backup.ReadReport
	if backupOn {
		fresh := backup.Fresh
		br = &fresh
		if !elevate {
			if br, err = s.backupRead(o); err != nil {
				return err
			}
		}
		// This run's mail stack is backed up from its first run on.
		br.Mail = br.Mail || mailOn
	}

	var existingMap *tree.Map
	if present {
		warns, err := marker.Compat(existing, c.Version, markerPath, target)
		if err != nil {
			return err
		}
		for _, w := range warns {
			out.Warn("%s", w)
		}
		v, _ := tree.ParseOne(existing)
		existingMap, _ = v.(*tree.Map)
		if existingMap == nil {
			return cli.Fail("internal: %s on %s passed the compatibility check and is not an object", markerPath, target)
		}
		if b, _ := tree.Lookup(existingMap, "backup", "enabled"); !backupOn && b == true {
			out.Warn("%s already has a backup stack at %s/.kasbah/backup and this run is not", target, o.Apps)
			out.Warn("touching it: init scaffolds backups, it never removes them. To take it down:")
			out.Warn("  ssh %s 'cd %s/.kasbah/backup && docker compose -p %s down'", target, o.Apps, backup.Project)
		}
	}

	v, err := Resolve(out, c.Prompter, o, cur, f["acme_store"], c.Hash)
	if err != nil {
		return err
	}
	var mv MailValues
	var mrendered map[string]string
	if mailOn {
		crypt := c.Crypt
		if crypt == nil {
			crypt = Crypt
		}
		if mv, err = MailResolve(out, c.Prompter, o, &mr, mcur["kasbah.yml"], v.Domain, crypt); err != nil {
			return err
		}
	}
	var bv *BackupValues
	if backupOn {
		if bv, err = BackupResolve(out, c.Prompter, o, br, existingMap); err != nil {
			return err
		}
	}
	rendered, err := Render(c.Templates, o, v)
	if err != nil {
		return err
	}
	if mailOn {
		if mrendered, err = MailRender(c.Templates, o, mv); err != nil {
			return err
		}
	}
	var bcompose, benv string
	var mb *marker.Backup
	if backupOn {
		if bcompose, benv, err = BackupRender(c.Templates, o, bv, br); err != nil {
			return err
		}
		mb = bv.Marker()
	}
	m, err := marker.Build(marker.Fields{KasbahVersion: c.Version, AppsPath: o.Apps, DataPath: o.Data, CPULimit: cpu, MemLimit: mem}, existingMap, mb)
	if err != nil {
		return cli.Fail("internal: could not build the server marker: %v", err)
	}

	// Elevation, once, on a bare host; then the binary lands in what it made.
	if elevate {
		res, rc := s.script(elevateScript, o.Apps, f["user"]+":"+f["group"])
		if rc != 0 {
			return stepFailed("lay out "+o.Apps, target, rc)
		}
		if _, err := checked("the apps path step", target, res, "elevated"); err != nil {
			return err
		}
		defer func() {
			if err == nil {
				return
			}
			out.Warn("%s was created with sudo by this run, which did not finish; it is left as it stands", o.Apps)
			if !started {
				out.Warn("a re-run picks it up (it is %s's), or remove it: ssh %s 'sudo rm -rf %s'", f["user"], target, o.Apps)
				return
			}
			out.Warn("a re-run picks it up (it is %s's). Traefik may be running from it: to remove it, take", f["user"])
			out.Warn("the stack down first: ssh %s 'cd %s/traefik && docker compose -p traefik down && sudo rm -rf %s'", target, o.Apps, o.Apps)
		}()
		if ensured, err = s.ensure(c, o.Apps); err != nil {
			return err
		}
	}

	res, rc := s.call(nil, true, "layout", o.Apps, o.Data)
	if rc != 0 {
		return stepFailed("lay out "+o.Apps, target, rc)
	}
	lay, err := checked("the layout step", target, res, "acme")
	if err != nil {
		return err
	}

	var changed []string
	restart := false
	for _, rel := range Files {
		if rendered[rel] == cur[rel] {
			continue
		}
		dest := o.Apps + "/traefik/" + rel
		if _, rc := s.send([]byte(rendered[rel]), "write", dest); rc != 0 {
			return cli.Fail("could not ship the Traefik %s to %s:%s", rel, target, dest)
		}
		changed = append(changed, rel)
		restart = restart || rel == "traefik.yml"
	}

	// Before Traefik starts, so it requests both certificates at
	// configuration load; the seeds before DMS's first start.
	var mlay, mst Facts
	var mchanged []string
	if mailOn {
		if mlay, err = s.mailLayout(o, mrendered, mv); err != nil {
			return err
		}
		if mchanged, err = s.mailSync(o, mrendered, mcur); err != nil {
			return err
		}
	}

	// Unbounded by RunTimeout: a first start pulls the image, and the health
	// wait is bounded on the server by TraefikTimeout. A reset happens inside
	// it, between stopping the running Traefik and starting the new one.
	yn := "no"
	if restart {
		yn = "yes"
	}
	args := []string{"start", o.Apps, yn, strconv.Itoa(TraefikTimeout)}
	if v.Acme.Reset {
		if err := resetNeedsRestart(restart); err != nil {
			return err
		}
		args = append(args, o.Data+"/traefik/letsencrypt/acme.json", c.Now().UTC().Format("20060102T150405Z"))
	}
	started = true
	res, rc = s.call(nil, false, args...)
	reset := Facts{"acme_reset": "skipped", "acme_archive": ""}
	for k, val := range remote.KV([]byte(res)) {
		if k == "acme_reset" || k == "acme_archive" {
			reset[k] = val
		}
	}
	if rc != 0 {
		return traefikStartFailed(target, rc, reset)
	}
	if v.Acme.Reset && reset["acme_reset"] != "done" {
		return cli.Fail("the Traefik start on %s reported no acme_reset — the store may not have been reset", target)
	}
	tfk, err := checked("the Traefik start", target, res,
		"traefik_action", "traefik_health", "traefik_started_at", "traefik_image", "traefik_container")
	if err != nil {
		return err
	}

	// After Traefik is healthy: DMS reads mail.<primary>'s certificate out of
	// acme.json, and kasbah-net is Traefik's to create.
	if mailOn {
		if mst, err = s.mailStart(o); err != nil {
			return err
		}
	}

	// Last of the stacks: a refusal leaves the credentials for the next run
	// and no marker, which is still the last thing init writes.
	var brep bkReport
	if backupOn {
		if brep, err = s.backupInstall(o, bv, br, bcompose, benv, ensured.Action != remote.Keep); err != nil {
			return err
		}
	}

	res, rc = s.send(marker.Render(m), "marker", o.Apps)
	if rc != 0 {
		return stepFailed("write the server marker", target, rc)
	}
	mk, err := checked("the marker step", target, res, "marker")
	if err != nil {
		return err
	}

	res, rc = s.script(pointerScript, o.Apps, pointerPath)
	if rc != 0 {
		return cli.Fail("could not write %s on %s (the remote step exited %d, see above)", Pointer, target, rc)
	}
	pt, err := checked("the pointer step", target, res, "pointer")
	if err != nil {
		return err
	}
	if err := PointerVerdict(out, pt["pointer"], target, o.Apps, f["user"]); err != nil {
		return err
	}
	if m := pt["pointer_dir_mode"]; m != "" {
		dir := pointerPath[:strings.LastIndex(pointerPath, "/")]
		out.Warn("%s on %s is mode %s, not 755, and `sudo -n` is not available to %s to repair it", dir, target, m, f["user"])
		out.Warn("a user who cannot traverse it reads no pointer and falls back to %s: ssh %s 'sudo chmod 755 %s'", DefaultApps, target, dir)
	}

	out.Info("Prepared %s", target)
	if elevate {
		out.Info("  created %s with sudo, owner %s:%s", o.Apps, f["user"], f["group"])
	}
	if lay["acme"] == "created" {
		out.Info("  touched %s/traefik/letsencrypt/acme.json as a file, mode 600", o.Data)
	}
	out.Info("  apps: %s   data: %s", o.Apps, o.Data)
	out.Info("  limits: cpu %s, mem %s (90%% of %s cores, %s kB)", cpu, mem, f["nproc"], f["memtotal_kb"])
	if ensured.Action == remote.Keep {
		out.Info("  kasbah: %s (kept %s)", s.bin, ensured.Now)
	} else {
		out.Info("  kasbah: %s (shipped %s)", s.bin, ensured.Now)
	}
	shipped := "nothing re-rendered"
	if len(changed) > 0 {
		shipped = "shipped " + strings.Join(changed, " ")
	}
	out.Info("  traefik: %s, %s, %s (%s)", tfk["traefik_action"], tfk["traefik_health"], tfk["traefik_image"], shipped)
	from := ""
	if v.Acme.Stored != "" && v.Acme.Stored != v.Acme.CA {
		from = v.Acme.Stored + " -> "
	}
	out.Info("  acme: %s%s", from, v.Acme.CA)
	if reset["acme_reset"] == "done" {
		out.Info("        acme.json reset, previous store archived as %s", reset["acme_archive"])
	} else if v.Acme.KeptUnknown {
		out.Info("        acme.json kept and NOT reset — nothing records which CA issued what is in it")
	}
	out.Info("  dashboard: https://traefik.%s (basic auth, credentials %s)", v.Domain, v.AuthOrigin)
	if mailOn {
		reportMail(out, o, mv, &mr, mchanged, mlay, mst)
	}
	if backupOn {
		reportBackup(out, o, bv, brep)
	}
	out.Info("  marker: %s (%s)", markerPath, mk["marker"])
	out.Info("  pointer: %s -> %s (%s)", Pointer, o.Apps, pt["pointer"])
	return nil
}

// resetNeedsRestart: an archived store is only worth it when the new
// endpoint is loaded, which takes a traefik.yml change and its restart.
func resetNeedsRestart(restart bool) error {
	if !restart {
		return cli.Fail("internal: the ACME endpoint changed but traefik.yml did not — the reset would outlive nothing")
	}
	return nil
}

// traefikStartFailed names the archived store when this run reset it.
func traefikStartFailed(target string, rc int, reset Facts) error {
	e := cli.Fail("could not start Traefik on %s (the remote step exited %d, see above)", target, rc)
	if reset["acme_reset"] == "done" {
		e.Cont("acme.json was reset before this — the previous store is at " + reset["acme_archive"])
	}
	return e
}
