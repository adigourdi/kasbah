package deploy

import (
	"bytes"
	"encoding/json"
	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/vlog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The docker stub: images and containers live in two files, every call is
// logged, and `exec` runs its sh -c command here so a backup dump has output.
const dockerStub = `#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
for last; do :; done
case "$1" in
image)
    [ -z "$IMAGE_ERR" ] || { echo "$IMAGE_ERR" >&2; exit 1; }
    grep -qxF "$last" "$IMAGES" || { echo "Error: No such image: $last" >&2; exit 1; }
    [ "$3" != -f ] || echo "sha256:id-of-$last"
    exit 0 ;;
tag) echo "$3" >> "$IMAGES"; exit 0 ;;
inspect)
    [ "$last" != traefik ] || { cat "${TNETS:-/dev/null}" 2>/dev/null; exit 0; }
    st=$(sed -n "s/^$last=//p" "$CONTAINERS")
    [ -n "$st" ] || exit 1
    case "$3" in
    *Running*) [ "$st" = running ] && echo true || echo false ;;
    # HEALTH_SIGNAL: a file whose presence sends one SIGTERM to the caller.
    *Health*) [ ! -e "${HEALTH_SIGNAL:-/nonexistent}" ] || { rm -f "$HEALTH_SIGNAL"; kill -TERM "$PPID"; }
        cat "$HEALTH" 2>/dev/null || echo none ;;
    *Status*) echo "$st" ;;
    *Name*) echo "/$last" ;;
    esac
    exit 0 ;;
compose) case "$*" in *" up "*) [ -z "$HUP_PARENT" ] || { kill -HUP "$PPID"; sleep 0.2; echo "Container demo-web Started" >&2; }
        # UPS: one "rc [health]" line per up, the health written for the wait after it.
        if [ -s "${UPS:-/nonexistent}" ]; then set -- $(head -n1 "$UPS"); sed -i 1d "$UPS"; [ -z "${2:-}" ] || echo "$2" > "$HEALTH"; exit "$1"; fi
        exit "${UP_RC:-0}" ;; *" ps "*) echo cid; exit 0 ;; esac ;;
network)
    # NETS: what network ls answers; CONNECTS: one rc per connect; TNETS: what traefik is on.
    case "$2" in
    ls) cat "${NETS:-/dev/null}" 2>/dev/null ;;
    connect) if [ -s "${CONNECTS:-/nonexistent}" ]; then rc=$(head -n1 "$CONNECTS"); sed -i 1d "$CONNECTS"; [ "$rc" = 0 ] || { echo "Error: refused" >&2; exit 1; }; fi
        echo "$3" >> "${TNETS:-/dev/null}" ;;
    esac
    exit 0 ;;
exec)
    shift 2; exec "$@" ;;
esac
exit 0
`

// The hooks log what they ran with, and write to stdout, which the engine must
// keep off the report channel.
const (
	preHook  = `echo "hook pre $KASBAH_VERSION prev=$KASBAH_PREV_VERSION project=$KASBAH_PROJECT dir=$(pwd) compose=$COMPOSE_PROJECT_NAME" >> "$LOG"; echo version=9.9.9-from-the-hook`
	postHook = `echo "hook post $KASBAH_VERSION prev=$KASBAH_PREV_VERSION project=$KASBAH_PROJECT" >> "$LOG"`
	// backupHook writes into the backup directory, and prints, which must
	// stay off the report channel too.
	backupHook = `echo "hook backup dir=$KASBAH_BACKUP_DIR cwd=$(pwd)" >> "$LOG"; echo dump > "$KASBAH_BACKUP_DIR/db.sql"; echo backup=from-the-hook`
)

type rig struct {
	t                         *testing.T
	dir, log, images, contain string
}

func newRig(t *testing.T) *rig {
	t.Helper()
	root := t.TempDir()
	r := &rig{t: t, dir: filepath.Join(root, "apps", "demo"), log: filepath.Join(root, "log"),
		images: filepath.Join(root, "images"), contain: filepath.Join(root, "containers")}
	bin := filepath.Join(root, "bin")
	os.MkdirAll(bin, 0o755)
	os.MkdirAll(r.dir, 0o755)
	os.WriteFile(filepath.Join(bin, "docker"), []byte(dockerStub), 0o755)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), nil, 0o644)
	os.WriteFile(filepath.Join(r.dir, ".env"), nil, 0o600)
	os.WriteFile(r.images, []byte("demo-web:1.0.0\n"), 0o644)
	os.WriteFile(r.contain, nil, 0o644)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("LOG", r.log)
	t.Setenv("IMAGES", r.images)
	t.Setenv("CONTAINERS", r.contain)
	t.Setenv("HEALTH", filepath.Join(root, "health"))
	return r
}

func (r *rig) running(names ...string) {
	var b strings.Builder
	for _, n := range names {
		b.WriteString(n + "\n")
	}
	os.WriteFile(r.contain, []byte(b.String()), 0o644)
}

func (r *rig) spec() Spec {
	return Spec{
		Mode: "deploy", Version: "1.0.0", Kasbah: "0.1.0", Images: []string{"demo-web"},
		Pre:    []string{preHook},
		Post:   []string{postHook},
		Health: Health{Container: "demo-web", Timeout: 5},
		Backup: []string{backupHook},
	}
}

func (r *rig) run(sp Spec) (int, string, string) {
	r.t.Helper()
	b, _ := json.Marshal(sp)
	var out, errb bytes.Buffer
	rc := Engine(r.dir, bytes.NewReader(append(b, '\n')), &out, &errb, &errb)
	return rc, out.String(), errb.String()
}

func (r *rig) calls() []string {
	b, _ := os.ReadFile(r.log)
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func index(calls []string, prefix string) int {
	for i, c := range calls {
		if strings.HasPrefix(c, prefix) {
			return i
		}
	}
	return -1
}

func TestEngineOrder(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=running", "demo-db=running")
	t.Setenv("COMPOSE_PROJECT_NAME", "somebody-else")
	rc, out, errs := r.run(r.spec())
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	c := r.calls()
	order := []int{index(c, "hook backup dir="+r.dir+"/backups/0.9.0-"), index(c, "hook pre 1.0.0 prev=0.9.0 project=demo dir="+r.dir+" compose=demo"),
		index(c, "tag demo-web:1.0.0 demo-web:current"), index(c, "compose -p demo up -d --remove-orphans"), index(c, "inspect --format")}
	for i := 1; i < len(order); i++ {
		if order[i-1] < 0 || order[i] <= order[i-1] {
			t.Fatalf("out of order %v:\n%s", order, strings.Join(c, "\n"))
		}
	}
	if last := c[len(c)-1]; last != "hook post 1.0.0 prev=0.9.0 project=demo" {
		t.Fatalf("the post-deploy hook is not last: %q", last)
	}
	rep, missing, found := ParseReport(out)
	if rep == nil || !found || missing != nil {
		t.Fatalf("report %q", out)
	}
	if rep.PrevVersion != "0.9.0" || !rep.DeployedBefore || rep.FailedOnly || !strings.HasPrefix(rep.Backup, "backups/0.9.0-") || rep.Digest != "sha256:id-of-demo-web:current" {
		t.Fatalf("report %+v", rep)
	}
	if g := reBackup.FindStringSubmatch(strings.TrimPrefix(rep.Backup, "backups/")); g == nil || g[1] != "0.9.0" {
		t.Fatalf("backup name %q", rep.Backup)
	}
	if got := readTar(t, filepath.Join(r.dir, rep.Backup)); got["db.sql"] != "dump\n" || len(got) != 1 {
		t.Fatalf("backup holds %v", got)
	}
	if left, _ := os.ReadDir(filepath.Join(r.dir, "backups")); len(left) != 1 {
		t.Fatalf("backups/ holds %v, not the tarball alone", left)
	}
	log, _ := os.ReadFile(filepath.Join(r.dir, "versions.log"))
	lines := strings.Split(strings.TrimSpace(string(log)), "\n")
	if len(lines) != 2 || !strings.HasSuffix(lines[1], " deploy 1.0.0 "+rep.Backup+" kasbah=0.1.0 digest=sha256:id-of-demo-web:current by="+serverlock.Who()) {
		t.Fatalf("versions.log %q", log)
	}
	if fi, _ := os.Stat(filepath.Join(r.dir, "versions.log")); fi.Mode().Perm() != vlog.Mode {
		t.Errorf("versions.log mode %o, want %o", fi.Mode().Perm(), vlog.Mode)
	}
	if fi, _ := os.Stat(filepath.Join(r.dir, ".deploy.lock")); fi.Mode().Perm() != serverlock.Mode {
		t.Errorf(".deploy.lock mode %o, want %o", fi.Mode().Perm(), serverlock.Mode)
	}
	if !strings.Contains(errs, "version=9.9.9-from-the-hook") || !strings.Contains(errs, "backup=from-the-hook") {
		t.Errorf("the hook's stdout did not reach stderr: %s", errs)
	}
	if strings.Contains(out, "from-the-hook") || strings.Count(strings.TrimSpace(out), "\n") != 0 {
		t.Errorf("stdout carries more than the report: %q", out)
	}
}

func TestEngineFirstDeploySkipsTheOutgoingSteps(t *testing.T) {
	r := newRig(t)
	r.running("demo-web=created")
	sp := r.spec()
	sp.Post = []string{`echo "hook post $KASBAH_VERSION prev=$KASBAH_PREV_VERSION project=$KASBAH_PROJECT backup=$KASBAH_BACKUP_DIR" >> "$LOG"`}
	rc, out, errs := r.run(sp)
	if rc != 0 || !strings.Contains(errs, "first deploy — versions.log has no entry for this project, so the backup hooks and the pre-deploy hooks will not run") {
		t.Fatalf("first deploy: rc %d %s", rc, errs)
	}
	if rep, _, _ := ParseReport(out); rep.DeployedBefore || rep.Backup != "no-backup" || rep.PrevVersion != "" {
		t.Fatalf("first report %+v", rep)
	}
	c := r.calls()
	if index(c, "hook backup") >= 0 || index(c, "hook pre") >= 0 {
		t.Fatalf("a first deploy ran an outgoing step:\n%s", strings.Join(c, "\n"))
	}
	if c[len(c)-1] != "hook post 1.0.0 prev= project=demo backup=none" {
		t.Fatalf("the post-deploy hook: %q", c[len(c)-1])
	}
	if es, _ := os.ReadDir(filepath.Join(r.dir, "backups")); len(es) != 0 {
		t.Fatalf("a first deploy left %v in backups/", es)
	}
	if !strings.Contains(r.logText(), " deploy 1.0.0 no-backup ") {
		t.Fatalf("versions.log %q", r.logText())
	}
}

// A log of failed runs only is history: a first deploy whose post-deploy hook
// failed left a live stack, so the next one backs it up and runs its hooks.
func TestEngineFailedEntriesAreHistory(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy-failed 0.9.0 no-backup kasbah=0.1.0 digest=- by=al reason=post-hook\n"), 0o640)
	r.running("demo-web=running", "demo-db=running")
	rc, out, errs := r.run(r.spec())
	if rc != 0 || strings.Contains(errs, "no entry") {
		t.Fatalf("rc %d %s", rc, errs)
	}
	if c := r.calls(); index(c, "hook backup") < 0 || index(c, "hook pre 1.0.0") < 0 {
		t.Fatalf("the outgoing steps did not run:\n%s", strings.Join(c, "\n"))
	}
	// The outgoing version is the failed entry's: its stack is the live one.
	if rep, _, _ := ParseReport(out); rep == nil || !strings.HasPrefix(rep.Backup, "backups/0.9.0-") || !rep.FailedOnly || rep.DeployedBefore {
		t.Fatalf("report %+v", rep)
	}
}

// With history, the outgoing steps always run: no container is looked at
// first, and --skip-hooks never skips the backup hooks.
func TestEngineBackupHooks(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=exited")
	if rc, _, errs := r.run(r.spec()); rc != 0 || index(r.calls(), "inspect -f {{.State.Running}}") >= 0 || index(r.calls(), "hook pre 1.0.0") < 0 {
		t.Fatalf("history and a stopped stack: rc %d %s\n%v", rc, errs, r.calls())
	}

	os.Remove(r.log)
	sp := r.spec()
	sp.SkipHooks = true
	rc, out, errs := r.run(sp)
	if rc != 0 || index(r.calls(), "hook backup dir="+r.dir+"/backups/1.0.0-") < 0 || index(r.calls(), "hook pre") >= 0 || index(r.calls(), "hook post") >= 0 {
		t.Fatalf("--skip-hooks: rc %d %s\n%v", rc, errs, r.calls())
	}
	if rep, _, _ := ParseReport(out); rep == nil || !strings.HasPrefix(rep.Backup, "backups/1.0.0-") {
		t.Fatalf("report %+v", rep)
	}

	// With no backup hook, the backup is the snapshot alone: here, none.
	sp = r.spec()
	sp.Backup = nil
	if rc, out, errs = r.run(sp); rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	if rep, _, _ := ParseReport(out); rep == nil || !strings.HasPrefix(rep.Backup, "backups/1.0.0-") || len(readTar(t, filepath.Join(r.dir, rep.Backup))) != 0 {
		t.Fatalf("report %+v", rep)
	}
}

func TestEngineHealthAndLock(t *testing.T) {
	r := newRig(t)
	r.running("demo-web=running", "demo-db=running")
	os.WriteFile(os.Getenv("HEALTH"), []byte("starting\n"), 0o644)
	sp := r.spec()
	sp.Backup = nil
	var out, errb bytes.Buffer
	now := time.Unix(1000, 0)
	e := &engine{dir: r.dir, sp: sp, stderr: &errb, now: func() time.Time { return now }, sleep: func(d time.Duration) { now = now.Add(d) }}
	if _, err := e.run(); err == nil || !strings.Contains(errb.String(), "did not become healthy within 5s — its last state was 'starting'") || !strings.Contains(err.Error(), "nothing to revert to") {
		t.Fatalf("health: %v\n%s", err, errb.String())
	}
	e.lockFile.Close()
	if _, err := os.Stat(filepath.Join(r.dir, "versions.log")); err == nil {
		t.Fatal("a failed health wait wrote versions.log")
	}

	// The lock is flock(2): held by another description, the run fails fast.
	f, _ := os.OpenFile(filepath.Join(r.dir, ".deploy.lock"), os.O_RDWR, 0)
	defer f.Close()
	syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	os.Remove(os.Getenv("HEALTH"))
	rc, _, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "is running in") || !strings.Contains(errs, ".deploy.lock") {
		t.Fatalf("lock: rc %d %s", rc, errs)
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	if rc, _, errs := r.run(sp); rc != 0 {
		t.Fatalf("after unlock: rc %d %s", rc, errs)
	}
	out.Reset()

	// The image preflight comes before anything else.
	sp.Version = "2.0.0"
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "not on this server: demo-web:2.0.0") {
		t.Fatalf("preflight: rc %d %s", rc, errs)
	}
}

func TestParseReport(t *testing.T) {
	if _, _, found := ParseReport("version=1\n"); found {
		t.Fatal("a key=value line read as the report")
	}
	r, missing, found := ParseReport(`{"kasbah_deploy_report":1,"version":"1"}`)
	if r != nil || !found || strings.Join(missing, " ") != "prev_version deployed_before backup digest" {
		t.Fatalf("partial: %v %v", r, missing)
	}
	stray := `{"kasbah_deploy_report":1,"version":"9","prev_version":"","deployed_before":false,"backup":"no-backup","digest":"-"}`
	real := `{"kasbah_deploy_report":1,"version":"1","prev_version":"0","deployed_before":true,"backup":"no-backup","digest":"-"}`
	if r, _, _ := ParseReport(stray + "\r\n" + real + "\r\n"); r == nil || r.Version != "1" || !r.DeployedBefore {
		t.Fatalf("last report wins: %+v", r)
	}
}

// TestRunHelper is `kasbah remote deploy run` in a child whose session
// vanishes: stdout and stderr are a pipe nobody reads, and `compose up`
// delivers SIGHUP to it, as a dropped ssh session does.
func TestRunHelper(t *testing.T) {
	dir := os.Getenv("KASBAH_RUN_DIR")
	if dir == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	spec, _ := os.Open(os.Getenv("KASBAH_RUN_SPEC"))
	atexit.Exit(Remote([]string{"run", dir}, spec, os.Stdout, os.Stderr))
}

func TestRunOutlivesSession(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=running", "demo-db=running")
	b, _ := json.Marshal(r.spec())
	specFile := filepath.Join(t.TempDir(), "spec")
	os.WriteFile(specFile, b, 0o644)
	pr, pw, _ := os.Pipe()
	pr.Close()
	cmd := exec.Command(os.Args[0], "-test.run=^TestRunHelper$")
	cmd.Env = append(os.Environ(), "KASBAH_RUN_DIR="+r.dir, "KASBAH_RUN_SPEC="+specFile, "HUP_PARENT=1")
	cmd.Stdout, cmd.Stderr = pw, pw
	cmd.Run()
	pw.Close()
	log, _ := os.ReadFile(filepath.Join(r.dir, "versions.log"))
	if code := cmd.ProcessState.ExitCode(); code != 0 || !strings.Contains(string(log), " deploy 1.0.0 backups/0.9.0-") {
		t.Fatalf("exit %d (%v), versions.log %q", code, cmd.ProcessState, log)
	}
	if c := r.calls(); !strings.HasPrefix(c[len(c)-1], "hook post 1.0.0") {
		t.Errorf("the run stopped before its post-deploy hook: %q", c[len(c)-1])
	}
	// The backup is whole: its tarball alone, no .part, no directory.
	if b := r.backups(); len(b) != 1 || !reBackup.MatchString(b[0]) || !strings.HasPrefix(b[0], "0.9.0-") {
		t.Errorf("backups/ holds %v", b)
	}
}

func TestEngineRefusesABadVersion(t *testing.T) {
	r := newRig(t)
	for _, v := range []string{"", "1.0.0 x", "1.0.0\u00a0", "1.0\x00", "-1"} {
		sp := r.spec()
		sp.Version = v
		if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "is not one versions.log can carry") {
			t.Errorf("version %q: rc %d %s", v, rc, errs)
		}
	}
	if _, err := os.Stat(filepath.Join(r.dir, ".deploy.lock")); err == nil {
		t.Error("a refused version took the lock")
	}
}

func TestShellsRunUnderCLocale(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=running", "demo-db=running")
	t.Setenv("LC_ALL", "fr_FR.UTF-8")
	sp := r.spec()
	sp.Backup = []string{`[ "$LC_ALL" = C ]`}
	sp.Pre = []string{`[ "$LC_ALL" = C ]`}
	if rc, _, errs := r.run(sp); rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
}
