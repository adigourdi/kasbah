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
    *Health*) cat "$HEALTH" 2>/dev/null || echo none ;;
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
    if [ "$2" = -e ]; then exit "${EXEC_RC:-0}"; fi
    shift 2; exec "$@" ;;
esac
exit 0
`

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
		Pre:    []string{"demo-web echo pre"},
		Post:   []string{"demo-web echo post"},
		Health: Health{Container: "demo-web", Timeout: 5},
		Backup: &Backup{Check: "echo check >> \"$LOG\"", Container: "demo-db", Command: "echo dump", Extension: "sql", Retain: 2},
	}
}

func (r *rig) run(sp Spec) (int, string, string) {
	r.t.Helper()
	b, _ := json.Marshal(sp)
	var out, errb bytes.Buffer
	rc := Engine(r.dir, bytes.NewReader(b), &out, &errb)
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
	rc, out, errs := r.run(r.spec())
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	c := r.calls()
	order := []int{index(c, "check"), index(c, "exec demo-db sh -c echo dump"), index(c, "exec -e VERSION=1.0.0 -e PREV_VERSION=0.9.0 -e DEPLOY_BACKUP=backups/pre-deploy-"),
		index(c, "tag demo-web:1.0.0 demo-web:current"), index(c, "compose -p demo up -d --remove-orphans"), index(c, "inspect --format")}
	for i := 1; i < len(order); i++ {
		if order[i-1] < 0 || order[i] <= order[i-1] {
			t.Fatalf("out of order %v:\n%s", order, strings.Join(c, "\n"))
		}
	}
	if last := c[len(c)-1]; !strings.Contains(last, "sh -c echo post") {
		t.Fatalf("the post-deploy hook is not last: %q", last)
	}
	rep, missing, found := ParseReport(out)
	if rep == nil || !found || missing != nil {
		t.Fatalf("report %q", out)
	}
	if rep.PrevVersion != "0.9.0" || !rep.DeployedBefore || !strings.HasPrefix(rep.Backup, "backups/pre-deploy-") || rep.Digest != "sha256:id-of-demo-web:current" {
		t.Fatalf("report %+v", rep)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, rep.Backup)); string(b) != "dump\n" {
		t.Fatalf("backup holds %q", b)
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
	if strings.Contains(out, "echo") || strings.Count(strings.TrimSpace(out), "\n") != 0 {
		t.Errorf("stdout carries more than the report: %q", out)
	}
}

func TestEngineFirstDeployAndRefusals(t *testing.T) {
	r := newRig(t)
	r.running("demo-web=created")
	rc, out, errs := r.run(r.spec())
	if rc != 0 || !strings.Contains(errs, "first deploy — versions.log has no entry") {
		t.Fatalf("first deploy: rc %d %s", rc, errs)
	}
	if rep, _, _ := ParseReport(out); rep.DeployedBefore || rep.Backup != "no-backup" || rep.PrevVersion != "" {
		t.Fatalf("first report %+v", rep)
	}

	// History, and the stack down: refused before any side effect.
	os.Remove(r.log)
	r.running("demo-web=exited")
	before, _ := os.ReadFile(filepath.Join(r.dir, "versions.log"))
	rc, _, errs = r.run(r.spec())
	if rc != 1 || !strings.Contains(errs, "demo-web is exited") || !strings.Contains(errs, "demo-db does not exist on this server") || !strings.Contains(errs, "HK01") {
		t.Fatalf("stopped + absent: rc %d %s", rc, errs)
	}
	if after, _ := os.ReadFile(filepath.Join(r.dir, "versions.log")); !bytes.Equal(before, after) || index(r.calls(), "tag") >= 0 {
		t.Fatal("a refused run changed something")
	}
	r.running("demo-web=exited", "demo-db=running")
	if rc, _, errs = r.run(r.spec()); rc != 1 || !strings.Contains(errs, "--allow-stopped if it is meant to be down") || !strings.Contains(errs, "the pre-deploy hooks in demo-web") || strings.Contains(errs, "the backup and") {
		t.Fatalf("stopped hook container: rc %d %s", rc, errs)
	}
	sp := r.spec()
	sp.AllowStopped = true
	if rc, _, errs = r.run(sp); rc != 0 || !strings.Contains(errs, "--allow-stopped:") || !strings.Contains(errs, "pre-deploy hook skipped: no demo-web is running") {
		t.Fatalf("--allow-stopped: rc %d %s", rc, errs)
	}

	// The backup gate says no; the backups rotate to retain.
	r.running("demo-web=running", "demo-db=running")
	sp = r.spec()
	sp.Backup.Check = "false"
	if rc, out, errs = r.run(sp); rc != 0 || !strings.Contains(errs, "backup.check exited non-zero") {
		t.Fatalf("gate: rc %d %s", rc, errs)
	}
	if rep, _, _ := ParseReport(out); rep.Backup != "no-backup" {
		t.Fatalf("gate report %+v", rep)
	}
	for _, n := range []string{"pre-deploy-20200101-000000.sql", "pre-deploy-20200102-000000.sql", "pre-deploy-20200103-000000.sql"} {
		os.WriteFile(filepath.Join(r.dir, "backups", n), nil, 0o644)
	}
	if rc, _, errs = r.run(r.spec()); rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	if left, _ := filepath.Glob(filepath.Join(r.dir, "backups", "*.sql")); len(left) != 2 || strings.Contains(strings.Join(left, " "), "20200102") {
		t.Fatalf("retain 2 left %v", left)
	}

	// A pipe that fails fails the run, and leaves no partial file.
	sp = r.spec()
	sp.Backup.Pipe = "cat >/dev/null; exit 3"
	if rc, _, errs = r.run(sp); rc != 1 || !strings.Contains(errs, "the backup failed in demo-db (exit 3)") {
		t.Fatalf("pipe failure: rc %d %s", rc, errs)
	}
	if p, _ := filepath.Glob(filepath.Join(r.dir, "backups", "*.partial")); len(p) != 0 {
		t.Fatalf("partial left %v", p)
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
	if code := cmd.ProcessState.ExitCode(); code != 0 || !strings.Contains(string(log), " deploy 1.0.0 backups/pre-deploy-") {
		t.Fatalf("exit %d (%v), versions.log %q", code, cmd.ProcessState, log)
	}
	if c := r.calls(); !strings.Contains(c[len(c)-1], "sh -c echo post") {
		t.Errorf("the run stopped before its post-deploy hook: %q", c[len(c)-1])
	}
	if left, _ := filepath.Glob(filepath.Join(r.dir, "backups", "*.partial")); len(left) != 0 {
		t.Errorf("a partial backup left: %v", left)
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

func TestBackupShellsRunUnderCLocale(t *testing.T) {
	r := newRig(t)
	r.running("demo-web=running", "demo-db=running")
	t.Setenv("LC_ALL", "fr_FR.UTF-8")
	sp := r.spec()
	sp.Backup.Check = `[ "$LC_ALL" = C ]`
	sp.Backup.Pipe = `[ "$LC_ALL" = C ] && cat`
	if rc, out, errs := r.run(sp); rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	} else if rep, _, _ := ParseReport(out); rep.Backup == "no-backup" {
		t.Fatalf("check or pipe did not see LC_ALL=C: %s", errs)
	}
}
