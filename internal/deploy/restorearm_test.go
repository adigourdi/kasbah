package deploy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/backup"
)

const restoreName = "1.0.0-20261101-000000.tar.gz"

// tarBytes is a backup tarball of members, as bytes.
func tarBytes(t *testing.T, ms ...member) []byte {
	t.Helper()
	p := filepath.Join(t.TempDir(), "b.tar.gz")
	writeBackup(t, p, ms...)
	b, _ := os.ReadFile(p)
	return b
}

func announce(body []byte) string {
	h := sha256.Sum256(body)
	return fmt.Sprintf("%s size=%d sha256=%s\n", backup.DumpKey, len(body), hex.EncodeToString(h[:]))
}

// A stream is kept only when it is what it announced and a whole gzip'd tar;
// anything else leaves neither the backup nor its .part.
func TestReceive(t *testing.T) {
	good := tarBytes(t, member{name: "db.dump", body: "dumped\n"})
	flipped := append([]byte{}, good...)
	flipped[len(flipped)/2] ^= 0xff
	garbage := []byte("not a tarball at all")
	for _, tc := range []struct {
		name, stream, want string
	}{
		{"whole", announce(good) + string(good), ""},
		{"short", announce(good) + string(good[:len(good)-3]), "cut short or padded"},
		{"padded", announce(good) + string(good) + "x", "cut short or padded"},
		{"corrupted", announce(good) + string(flipped), "sha256"},
		{"not a tar", announce(garbage) + string(garbage), "not a readable gzip'd tar"},
		{"no header", string(good), "did not start by announcing"},
		{"empty", "", "ended before announcing"},
		{"zero size", backup.DumpKey + " size=0 sha256=" + strings.Repeat("0", 64) + "\n", "did not start by announcing"},
	} {
		dir := t.TempDir()
		root, _ := os.OpenRoot(dir)
		n, err := receive(root, restoreName, bufio.NewReader(strings.NewReader(tc.stream)))
		root.Close()
		_, perr := os.Lstat(filepath.Join(dir, partName(restoreName)))
		fi, ferr := os.Stat(filepath.Join(dir, restoreName))
		if tc.want == "" {
			if err != nil || n != int64(len(good)) || ferr != nil || fi.Mode().Perm() != 0o660 || perr == nil {
				t.Errorf("%s: n %d err %v file %v part %v", tc.name, n, err, ferr, perr)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), tc.want) || ferr == nil || perr == nil {
			t.Errorf("%s: err %v, file kept %v, part kept %v", tc.name, err, ferr == nil, perr == nil)
		}
	}
}

// fetchRig is a project with backups/, and the container's dump replaced by a
// script printing stream.
func fetchRig(t *testing.T, stream string, rc int) (string, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "apps", "demo")
	os.MkdirAll(filepath.Join(dir, Backups), 0o777)
	logf := filepath.Join(root, "log")
	sp := filepath.Join(root, "stream")
	os.WriteFile(sp, []byte(stream), 0o644)
	old := inContainer
	inContainer = func(apps string, args ...string) *exec.Cmd {
		return exec.Command("sh", "-c", fmt.Sprintf(`printf '%%s\n' "$*" >> %q; cat %q; exit %d`, logf, sp, rc), "sh", strings.Join(append([]string{apps}, args...), " "))
	}
	t.Cleanup(func() { inContainer = old })
	return dir, logf
}

func TestFetchBackup(t *testing.T) {
	good := tarBytes(t, member{name: "db.dump", body: "dumped\n"})
	dir, logf := fetchRig(t, announce(good)+string(good), 0)
	var out, errb bytes.Buffer
	if rc := fetchBackup(dir, "abcd1234", restoreName, "", &out, &errb); rc != 0 || out.String() != fmt.Sprintf("fetch=fetched\nsize=%d\n", len(good)) {
		t.Fatalf("rc %d %q %s", rc, out.String(), errb.String())
	}
	if b, _ := os.ReadFile(logf); string(b) != filepath.Dir(dir)+" restore-dump --project demo abcd1234 "+restoreName+"\n" {
		t.Errorf("exec: %q", b)
	}
	// Already there: used as it is, the container not asked.
	os.Remove(logf)
	out.Reset()
	if rc := fetchBackup(dir, "abcd1234", restoreName, "", &out, &errb); rc != 0 || out.String() != "fetch=present\n" {
		t.Errorf("rc %d %q", rc, out.String())
	}
	if _, err := os.Stat(logf); err == nil {
		t.Error("a present backup was fetched again")
	}
	os.Remove(filepath.Join(dir, Backups, restoreName))
	if rc := fetchBackup(dir, "abcd1234", restoreName, "/srv/b", &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	if b, _ := os.ReadFile(logf); string(b) != filepath.Dir(dir)+" restore-dump --project demo --from-path /srv/b abcd1234 "+restoreName+"\n" {
		t.Errorf("exec: %q", b)
	}
	os.Remove(logf)
	out.Reset()
	// A name outside the pattern never reaches the container or the disk.
	for _, n := range []string{"../1.0.0-20261101-000000.tar.gz", "x.tar.gz", ".1.0.0-20261101-000000.tar.gz.part", "1.0.0-20261101-000000.tar.gz/x"} {
		out.Reset()
		errb.Reset()
		if rc := fetchBackup(dir, "abcd1234", n, "", &out, &errb); rc != 1 || out.Len() != 0 || !strings.Contains(errb.String(), "is not a backup's name") {
			t.Errorf("%q: rc %d %q %q", n, rc, out.String(), errb.String())
		}
	}
	if _, err := os.Stat(logf); err == nil {
		t.Error("the container was asked for a refused name")
	}
	// The container's dump failing after a whole stream keeps nothing.
	dir, _ = fetchRig(t, announce(good)+string(good), 3)
	out.Reset()
	errb.Reset()
	if rc := fetchBackup(dir, "abcd1234", restoreName, "", &out, &errb); rc != 1 || out.Len() != 0 || !strings.Contains(errb.String(), "nothing was kept") {
		t.Errorf("rc %d %q %q", rc, out.String(), errb.String())
	}
	if es, _ := os.ReadDir(filepath.Join(dir, Backups)); len(es) != 0 {
		t.Errorf("backups/ holds %v", es)
	}
}

// restoreHook logs what it ran with: the .env as it stood, and the dump.
const restoreHook = `echo "restore v=$KASBAH_VERSION prev=[$KASBAH_PREV_VERSION] project=$KASBAH_PROJECT env=$(tr '\n' ' ' < .env)dump=$(cat "$KASBAH_BACKUP_DIR/db.dump")" >> "$LOG"`

// restoreLive is a live 1.0.0 with a backup in backups/ holding .env A=old.
func restoreLive(t *testing.T, restore ...string) *rig {
	r := liveRig(t)
	if restore == nil {
		restore = []string{}
	}
	b, _ := json.Marshal(Hooks{Backup: []string{}, Restore: restore, Targets: []string{".env"}, Health: &Health{Timeout: 2}})
	os.WriteFile(filepath.Join(r.dir, HooksFile), b, 0o644)
	writeBackup(t, filepath.Join(r.dir, Backups, restoreName), member{name: "db.dump", body: "dumped"}, member{name: "kasbah-snapshot/.env", body: "A=old\nB=kept-from-backup\n"})
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("A=live\nC=only-live\n"), 0o600)
	r.running("cid=running")
	return r
}

func (r *rig) restore(live string, flags ...string) (int, map[string]string, string) {
	var out, errb bytes.Buffer
	rc := restoreArm(r.dir, restoreName, live, flags, &out, &errb, &errb)
	return rc, lines(out.Bytes()), errb.String()
}

func (r *rig) env() string {
	b, _ := os.ReadFile(filepath.Join(r.dir, ".env"))
	return string(b)
}

// In order: .env written, the restore hook on the extraction, then the stack
// recreated and waited on; the extraction goes.
func TestRestoreArmOrder(t *testing.T) {
	r := restoreLive(t, restoreHook)
	rc, kv, errs := r.restore("1.0.0", "--env=all", "--data")
	if rc != 0 || kv["restore"] != "done" || kv["env"] != "restored" || kv["data"] != "restored" || kv["recreated"] != "yes" {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if r.env() != "A=old\nB=kept-from-backup\n" {
		t.Errorf(".env %q", r.env())
	}
	calls := r.calls()
	hook, up := index(calls, "restore v="), index(calls, "compose -p demo up -d --remove-orphans")
	if hook < 0 || up < hook || index(calls, "compose -p demo ps -q") < up {
		t.Errorf("order:\n%s", strings.Join(calls, "\n"))
	}
	if calls[hook] != "restore v=1.0.0 prev=[] project=demo env=A=old B=kept-from-backup dump=dumped" {
		t.Errorf("hook ran with %q", calls[hook])
	}
	if index(calls, "tag ") >= 0 {
		t.Errorf("retagged:\n%s", strings.Join(calls, "\n"))
	}
	if m, _ := filepath.Glob(filepath.Join(r.dir, UnpackedPrefix+"*")); len(m) != 0 {
		t.Errorf("extraction left: %v", m)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "versions.log")); string(b) != live10 {
		t.Errorf("versions.log written: %s", b)
	}
}

// The stack is recreated only when .env changed.
func TestRestoreArmRecreatesOnlyOnChange(t *testing.T) {
	for _, tc := range []struct {
		name, env string
		flags     []string
		recreated string
		envOut    string
	}{
		{"data only", "A=live\n", []string{"--data"}, "no", "kept"},
		{"same .env", "A=old\nB=kept-from-backup\n", []string{"--env=all"}, "no", "unchanged"},
		{"one key", "A=live\nC=only-live\n", []string{"--env=B"}, "yes", "restored"},
	} {
		r := restoreLive(t, restoreHook)
		os.WriteFile(filepath.Join(r.dir, ".env"), []byte(tc.env), 0o600)
		rc, kv, errs := r.restore("1.0.0", tc.flags...)
		if rc != 0 || kv["recreated"] != tc.recreated || kv["env"] != tc.envOut {
			t.Errorf("%s: rc %d %v\n%s", tc.name, rc, kv, errs)
		}
		if up := index(r.calls(), "compose -p demo up"); (up >= 0) != (tc.recreated == "yes") {
			t.Errorf("%s: up at %d", tc.name, up)
		}
		if tc.name == "one key" && r.env() != "A=live\nC=only-live\nB=kept-from-backup\n" {
			t.Errorf("one key: .env %q", r.env())
		}
	}
}

// A failure after the .env write puts the previous .env back; a failed
// restore hook's work is left as it is.
func TestRestoreArmPutsEnvBack(t *testing.T) {
	r := restoreLive(t, `echo touched > "$LOG.data"; exit 4`)
	rc, kv, errs := r.restore("1.0.0", "--env=all", "--data")
	if rc != 1 || kv["restore"] != "failed" || kv["step"] != "hook" || kv["env"] != "put-back" || !strings.Contains(errs, "the restore hook failed (exit 4)") || !strings.Contains(errs, "left as it is") {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if r.env() != "A=live\nC=only-live\n" || index(r.calls(), "compose -p demo up") >= 0 {
		t.Errorf(".env %q calls %v", r.env(), r.calls())
	}
	if b, _ := os.ReadFile(r.log + ".data"); string(b) != "touched\n" {
		t.Errorf("the hook's work: %q", b)
	}

	r = restoreLive(t)
	t.Setenv("UP_RC", "1")
	rc, kv, errs = r.restore("1.0.0", "--env=all")
	if rc != 1 || kv["step"] != "up" || kv["env"] != "put-back" || r.env() != "A=live\nC=only-live\n" {
		t.Fatalf("rc %d %v %q\n%s", rc, kv, r.env(), errs)
	}
	ups := 0
	for _, c := range r.calls() {
		if strings.HasPrefix(c, "compose -p demo up") {
			ups++
		}
	}
	if ups != 2 {
		t.Errorf("up ran %d times — once on the backup's .env, once on the one put back", ups)
	}
}

// Refusals change nothing.
func TestRestoreArmRefusals(t *testing.T) {
	for _, tc := range []struct {
		name, live string
		restore    []string
		flags      []string
		want       string
	}{
		{"data, no hook", "1.0.0", nil, []string{"--env=all", "--data"}, "has no restore hook"},
		{"live moved", "0.9.0", []string{restoreHook}, []string{"--env=all"}, "live version is now 1.0.0, not 0.9.0"},
		{"reserved key", "1.0.0", nil, []string{"--env=KASBAH_DOMAIN"}, "not a key a restore writes"},
		{"bad flag", "1.0.0", nil, []string{"--yes"}, "usage: restore"},
	} {
		r := restoreLive(t, tc.restore...)
		rc, kv, errs := r.restore(tc.live, tc.flags...)
		if rc != 1 || kv["restore"] != "refused" || !strings.Contains(errs, tc.want) {
			t.Errorf("%s: rc %d %v\n%s", tc.name, rc, kv, errs)
		}
		if r.env() != "A=live\nC=only-live\n" || index(r.calls(), "compose") >= 0 {
			t.Errorf("%s: changed: %q %v", tc.name, r.env(), r.calls())
		}
	}
	r := restoreLive(t, restoreHook)
	os.Remove(filepath.Join(r.dir, "versions.log"))
	if rc, kv, errs := r.restore("1.0.0", "--data"); rc != 1 || kv["restore"] != "refused" || !strings.Contains(errs, "deploy first, then restore") {
		t.Errorf("nothing live: rc %d %v\n%s", rc, kv, errs)
	}
}

// A whole restore is the backup's keys, the server's KASBAH_* block kept.
func TestRestoreArmKeepsKasbahBlock(t *testing.T) {
	r := restoreLive(t)
	writeBackup(t, filepath.Join(r.dir, Backups, restoreName), member{name: "kasbah-snapshot/.env", body: "A=old\nKASBAH_CPU_LIMIT=9\n"})
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("A=live\nKASBAH_CPU_LIMIT=1\n"), 0o600)
	if rc, kv, errs := r.restore("1.0.0", "--env=all"); rc != 0 || kv["env"] != "restored" {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if r.env() != "A=old\nKASBAH_CPU_LIMIT=1\n" {
		t.Errorf(".env %q", r.env())
	}
}

func (r *rig) ups() int {
	n := 0
	for _, c := range r.calls() {
		if strings.HasPrefix(c, "compose -p demo up") {
			n++
		}
	}
	return n
}

func (r *rig) hooks(h Hooks) {
	b, _ := json.Marshal(h)
	os.WriteFile(filepath.Join(r.dir, HooksFile), b, 0o644)
}

// fakeClock moves on by each sleep.
type fakeClock struct {
	at    time.Time
	slept int
}

func (c *fakeClock) now() time.Time { return c.at }
func (c *fakeClock) sleep(d time.Duration) {
	c.at = c.at.Add(d)
	c.slept++
}

// restoreAt is r.restore on a fake clock.
func (r *rig) restoreAt(c *fakeClock, live string, flags ...string) (int, map[string]string, string) {
	var out, errb bytes.Buffer
	e := &engine{dir: r.dir, stderr: &errb, raw: &errb, now: c.now, sleep: c.sleep, forward: true}
	rc := e.restoreArm(restoreName, live, flags, &out)
	return rc, lines(out.Bytes()), errb.String()
}

// A failed health wait puts .env back and brings the stack up on it; the
// wait is on health.container when set, 120 seconds without a health block.
func TestRestoreArmHealth(t *testing.T) {
	r := restoreLive(t)
	os.WriteFile(os.Getenv("HEALTH"), []byte("starting\n"), 0o644)
	c := &fakeClock{at: time.Unix(0, 0)}
	rc, kv, errs := r.restoreAt(c, "1.0.0", "--env=all")
	if rc != 1 || kv["step"] != "health" || kv["env"] != "put-back" || kv["data"] != "kept" || kv["stack"] != "up" || kv["signal"] != "no" ||
		!strings.Contains(errs, "within 2s") || r.env() != "A=live\nC=only-live\n" || r.ups() != 2 {
		t.Fatalf("rc %d %v ups %d %q\n%s", rc, kv, r.ups(), r.env(), errs)
	}
	r = restoreLive(t)
	r.hooks(Hooks{Backup: []string{}, Restore: []string{}, Targets: []string{".env"}, Health: &Health{Container: "web", Timeout: 2}})
	r.running("cid=running", "web=running")
	os.WriteFile(os.Getenv("HEALTH"), []byte("healthy\n"), 0o644)
	if rc, kv, errs := r.restoreAt(c, "1.0.0", "--env=all"); rc != 0 || kv["recreated"] != "yes" {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if calls := r.calls(); index(calls, "compose -p demo ps -q") >= 0 || !strings.HasSuffix(calls[index(calls, "inspect --format {{if .State.Health}}")], " web") {
		t.Errorf("the wait was not on web:\n%s", strings.Join(calls, "\n"))
	}
	r = restoreLive(t)
	r.hooks(Hooks{Backup: []string{}, Restore: []string{}, Targets: []string{".env"}})
	os.WriteFile(os.Getenv("HEALTH"), []byte("starting\n"), 0o644)
	c = &fakeClock{at: time.Unix(0, 0)}
	if rc, kv, errs := r.restoreAt(c, "1.0.0", "--env=all"); rc != 1 || kv["step"] != "health" || !strings.Contains(errs, "within 120s") || c.slept != 120 {
		t.Errorf("rc %d %v slept %d\n%s", rc, kv, c.slept, errs)
	}
}

// A .env the restore created is removed again when it fails; a second up
// that fails too is reported down.
func TestRestoreArmPutBackRemovesACreatedEnv(t *testing.T) {
	r := restoreLive(t)
	os.Remove(filepath.Join(r.dir, ".env"))
	t.Setenv("UP_RC", "1")
	rc, kv, errs := r.restore("1.0.0", "--env=all")
	if rc != 1 || kv["step"] != "up" || kv["env"] != "put-back" || kv["stack"] != "down" || !strings.Contains(errs, "failed too") {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, ".env")); err == nil {
		t.Errorf(".env left: %q", r.env())
	}
}

// After a hook that restored the data, a failed recreate says so.
func TestRestoreArmDataThenRecreateFails(t *testing.T) {
	r := restoreLive(t, restoreHook)
	t.Setenv("UPS", filepath.Join(t.TempDir(), "ups"))
	os.WriteFile(os.Getenv("UPS"), []byte("1\n0\n"), 0o644)
	rc, kv, errs := r.restore("1.0.0", "--env=all", "--data")
	if rc != 1 || kv["step"] != "up" || kv["data"] != "restored" || kv["env"] != "put-back" || kv["stack"] != "up" {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
}

func TestRestoreArmSignalHelper(t *testing.T) {
	dir := os.Getenv("KASBAH_RESTORE_DIR")
	if dir == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	args := append([]string{"restore", dir, restoreName, "1.0.0"}, strings.Fields(os.Getenv("KASBAH_RESTORE_FLAGS"))...)
	atexit.Exit(Remote(args, strings.NewReader(""), os.Stdout, os.Stderr))
}

// restoreSignalled runs the restore in a child process, bounded.
func (r *rig) restoreSignalled(t *testing.T, flags string, env ...string) (int, map[string]string, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRestoreArmSignalHelper$")
	cmd.Env = append(append(os.Environ(), "KASBAH_RESTORE_DIR="+r.dir, "KASBAH_RESTORE_FLAGS="+flags), env...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.Run()
	if ctx.Err() != nil {
		t.Fatalf("the restore hung:\n%s", errb.String())
	}
	return cmd.ProcessState.ExitCode(), lines(out.Bytes()), errb.String()
}

// The first signal stops the restore through its failure path: the hook's
// process group signalled, .env put back, the report written.
func TestRestoreArmSignalDuringHook(t *testing.T) {
	r := restoreLive(t, `kill -TERM $PPID; sleep 5; echo after >> "$LOG.after"`)
	code, kv, errs := r.restoreSignalled(t, "--env=all --data")
	if code != 128+int(syscall.SIGTERM) || kv["restore"] != "failed" || kv["step"] != "hook" || kv["signal"] != "yes" ||
		kv["env"] != "put-back" || kv["data"] != "partial" || kv["stack"] != "untouched" {
		t.Fatalf("exit %d %v\n%s", code, kv, errs)
	}
	if r.env() != "A=live\nC=only-live\n" || r.ups() != 0 {
		t.Errorf(".env %q ups %d", r.env(), r.ups())
	}
	if _, err := os.Stat(r.log + ".after"); err == nil {
		t.Error("the hook ran on after the signal")
	}
	if m, _ := filepath.Glob(filepath.Join(r.dir, UnpackedPrefix+"*")); len(m) != 0 {
		t.Errorf("extraction left: %v", m)
	}
}

// During the health wait it stops waiting, puts .env back and brings the
// stack up on it.
func TestRestoreArmSignalDuringHealth(t *testing.T) {
	r := restoreLive(t)
	os.WriteFile(os.Getenv("HEALTH"), []byte("starting\n"), 0o644)
	once := filepath.Join(t.TempDir(), "signal")
	os.WriteFile(once, nil, 0o644)
	r.hooks(Hooks{Backup: []string{}, Restore: []string{}, Targets: []string{".env"}, Health: &Health{Timeout: 60}})
	start := time.Now()
	code, kv, errs := r.restoreSignalled(t, "--env=all", "HEALTH_SIGNAL="+once)
	if code != 128+int(syscall.SIGTERM) || kv["step"] != "health" || kv["signal"] != "yes" || kv["env"] != "put-back" || kv["stack"] != "up" ||
		!strings.Contains(errs, "a signal stopped the wait") || time.Since(start) > 20*time.Second {
		t.Fatalf("exit %d %v\n%s", code, kv, errs)
	}
	if r.env() != "A=live\nC=only-live\n" || r.ups() != 2 {
		t.Errorf(".env %q ups %d", r.env(), r.ups())
	}
}

// A second signal exits at once: its cleanup puts .env back without the
// atexit stack, so nothing hangs and no staging file is left.
func TestRestoreArmSecondSignal(t *testing.T) {
	r := restoreLive(t, `trap '' TERM INT; kill -TERM $PPID; sleep 0.5; kill -TERM $PPID; sleep 10`)
	code, kv, errs := r.restoreSignalled(t, "--env=all --data")
	if code != 128+int(syscall.SIGTERM) || kv["restore"] != "" || !strings.Contains(errs, "back as it was before this restore") {
		t.Fatalf("exit %d %v\n%s", code, kv, errs)
	}
	if r.env() != "A=live\nC=only-live\n" {
		t.Errorf(".env %q", r.env())
	}
	for _, g := range []string{".env.kasbah-setup.*", ".env.kasbah-putback.*", UnpackedPrefix + "*"} {
		if m, _ := filepath.Glob(filepath.Join(r.dir, g)); len(m) != 0 {
			t.Errorf("left: %v", m)
		}
	}
}

// The host's restore-list: the live version, the hooks, the tarballs in
// backups/, and the container's listing when it runs.
func TestRestoreListArm(t *testing.T) {
	r := restoreLive(t, restoreHook)
	os.WriteFile(filepath.Join(r.dir, Backups, "notes.txt"), nil, 0o644)
	logf := filepath.Join(t.TempDir(), "exec")
	old, oldState := inContainer, schedulerState
	t.Cleanup(func() { inContainer, schedulerState = old, oldState })
	inContainer = func(apps string, args ...string) *exec.Cmd {
		return exec.Command("sh", "-c", `printf '%s\n' "$*" >> "$0"; echo '{"repo":"acme","snapshots":[],"snapshot":"","path":"","backups":[],"looked":["/x"],"elsewhere":["/y"]}'`,
			logf, strings.Join(append([]string{apps}, args...), " "))
	}
	state := "running"
	schedulerState = func() string { return state }
	apps := filepath.Dir(r.dir)
	var out, errb bytes.Buffer
	if rc := Remote([]string{"restore-list", apps, "demo", "abcd", "--from-path=/srv/b"}, nil, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var f RestoreFacts
	if err := json.Unmarshal(out.Bytes(), &f); err != nil || f.State != "running" || f.Live != "1.0.0" || !f.Hooks || !f.RestoreHook ||
		strings.Join(f.Local, " ") != restoreName || f.List == nil || strings.Join(f.List.Elsewhere, " ") != "/y" {
		t.Fatalf("%v %+v", err, f)
	}
	if b, _ := os.ReadFile(logf); string(b) != apps+" restore-list --project demo --from-path /srv/b --snapshot abcd\n" {
		t.Errorf("exec: %q", b)
	}
	state = "exited"
	os.Remove(logf)
	out.Reset()
	if rc := Remote([]string{"restore-list", apps, "demo"}, nil, &out, &errb); rc != 0 || !strings.Contains(out.String(), `"state":"exited"`) || strings.Contains(out.String(), `"list"`) {
		t.Errorf("rc %d %s", rc, out.String())
	}
	if _, err := os.Stat(logf); err == nil {
		t.Error("the container was asked while not running")
	}
	for _, args := range [][]string{{"restore-list", "apps", "demo"}, {"restore-list", apps, "Demo"}, {"restore-list", apps, "demo", "XYZ"},
		{"restore-list", apps, "demo", "--from-path=rel"}, {"restore-list", apps, "demo", "abcd", "efgh"}, {"fetch", r.dir, "abcd", restoreName, "--from-path=/a/../b"}} {
		out.Reset()
		if rc := Remote(args, nil, &out, io.Discard); rc != 1 || out.Len() != 0 {
			t.Errorf("%v: rc %d %q", args, rc, out.String())
		}
	}
}

// backup-probe DIR --backup NAME reads that backup's .env against the
// server's, by key name; a name not there reads as none.
func TestProbeNamedArm(t *testing.T) {
	r := restoreLive(t)
	var out, errb bytes.Buffer
	if rc := Remote([]string{"backup-probe", r.dir, "--backup", restoreName}, nil, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var f BackupFacts
	if err := json.Unmarshal(out.Bytes(), &f); err != nil || f.Backup != restoreName || f.Env != "yes" || strings.Join(f.Changed, " ") != "A" ||
		strings.Join(f.OnlyBackup, " ") != "B" || strings.Join(f.OnlyLive, " ") != "C" {
		t.Fatalf("%v %+v", err, f)
	}
	out.Reset()
	if rc := Remote([]string{"backup-probe", r.dir, "--backup", "1.0.0-20200101-000000.tar.gz"}, nil, &out, &errb); rc != 0 || !strings.Contains(out.String(), `"backup":""`) {
		t.Errorf("rc %d %s", rc, out.String())
	}
	out.Reset()
	if rc := Remote([]string{"backup-probe", r.dir, "--backup", "../x.tar.gz"}, nil, &out, io.Discard); rc != 1 || out.Len() != 0 {
		t.Errorf("rc %d %s", rc, out.String())
	}
}
