package deploy

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/tree"
)

const live10 = "2026-10-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n"

// envHook logs what a backup hook runs with, and writes a dump.
const envHook = `echo "backup v=$KASBAH_VERSION prev=[$KASBAH_PREV_VERSION] project=$KASBAH_PROJECT compose=$COMPOSE_PROJECT_NAME dir=$KASBAH_BACKUP_DIR cwd=$(pwd)" >> "$LOG"; echo dump > "$KASBAH_BACKUP_DIR/db.sql"; echo backup=from-the-hook`

func (r *rig) hooksFile(backup []string, targets ...string) {
	b, _ := json.Marshal(Hooks{Backup: backup, Restore: []string{}, Targets: targets})
	os.WriteFile(filepath.Join(r.dir, HooksFile), b, 0o644)
}

func (r *rig) take(at time.Time) (int, string, string) {
	var out, errb bytes.Buffer
	rc := takeBackup(r.dir, func() time.Time { return at }, &out, &errb)
	return rc, out.String(), errb.String()
}

// liveRig is a project deployed once: 1.0.0 live, its hooks recorded.
func liveRig(t *testing.T) *rig {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(live10), 0o640)
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("A=live\n"), 0o600)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("v1.0.0\n"), 0o644)
	os.MkdirAll(filepath.Join(r.dir, "site", "locked"), 0o755)
	os.WriteFile(filepath.Join(r.dir, "site", "locked", "f"), []byte("f\n"), 0o644)
	os.Chmod(filepath.Join(r.dir, "site", "locked"), 0o550)
	os.Chmod(filepath.Join(r.dir, "site"), 0o750)
	t.Cleanup(func() { os.Chmod(filepath.Join(r.dir, "site", "locked"), 0o755) })
	r.hooksFile([]string{envHook}, ".env", "compose.yml", "site", "absent.txt")
	return r
}

// The backup holds the live .env and the recorded targets under
// kasbah-snapshot/, each directory with its mode, beside what the hook wrote;
// versions.log is not written.
func TestTakeBackupLayout(t *testing.T) {
	// The server's umask: `kasbah remote` sets it.
	defer syscall.Umask(syscall.Umask(0o002))
	r := liveRig(t)
	rc, out, errs := r.take(at10)
	name := "backups/1.0.0-20261102-100000.tar.gz"
	if rc != 0 || out != "backup="+name+"\nversion=1.0.0\n" {
		t.Fatalf("rc %d out %q\n%s", rc, out, errs)
	}
	hs, files := tarball(t, filepath.Join(r.dir, name))
	want := map[string]string{"db.sql": "dump\n", SnapDir + "/.env": "A=live\n", SnapDir + "/compose.yml": "v1.0.0\n", SnapDir + "/site/locked/f": "f\n"}
	if len(files) != len(want) {
		t.Fatalf("tarball holds %v", files)
	}
	for k, v := range want {
		if files[k] != v {
			t.Errorf("%s is %q", k, files[k])
		}
	}
	for n, m := range map[string]int64{SnapDir + "/.env": 0o600, SnapDir + "/": 0o770, SnapDir + "/site/": 0o750, SnapDir + "/site/locked/": 0o550} {
		if h := hs[n]; h == nil || h.Mode != m {
			t.Errorf("%s: %+v, want mode %o", n, h, m)
		}
	}
	if fi, err := os.Stat(filepath.Join(r.dir, name)); err != nil || fi.Mode().Perm() != 0o660 {
		t.Errorf("tarball mode %v %v", fi, err)
	}
	if b := r.backups(); len(b) != 1 {
		t.Errorf("backups/ holds %v", b)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "versions.log")); string(b) != live10 {
		t.Errorf("versions.log written: %q", b)
	}
	if !strings.Contains(errs, "backup of 1.0.0 written to "+name) || !strings.Contains(errs, "backup=from-the-hook") {
		t.Errorf("stderr:\n%s", errs)
	}
	bdir := filepath.Join(r.dir, "backups", "1.0.0-20261102-100000")
	if got := r.calls(); len(got) != 1 || got[0] != "backup v=1.0.0 prev=[] project=demo compose=demo dir="+bdir+" cwd="+r.dir {
		t.Errorf("hook env: %q", got)
	}
}

// The live version is the deploy's rule; nothing live, or no record of the
// hooks, refuses with nothing made.
func TestTakeBackupRefusals(t *testing.T) {
	failed := "2026-10-02T00:00:00+00:00 deploy-failed 1.1.0 no-backup kasbah=0.1.0 digest=- by=al reason="
	for name, tc := range map[string]struct{ log, want string }{
		"no versions.log":         {"", "demo has no live version"},
		"only a failed run":       {failed + "revert\n", "demo has no live version"},
		"after a failed revert":   {live10 + failed + "revert\n", "backup=backups/1.0.0-"},
		"after a post-hook fail":  {live10 + failed + "post-hook\n", "backup=backups/1.1.0-"},
		"an unnameable live line": {"2026-10-01T00:00:00+00:00 deploy 1.0.0/x no-backup kasbah=0.1.0 digest=-\n", "backup=backups/unknown-"},
	} {
		t.Run(name, func(t *testing.T) {
			r := liveRig(t)
			os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(tc.log), 0o640)
			rc, out, errs := r.take(at10)
			if !strings.Contains(out+errs, tc.want) || (rc == 0) != strings.HasPrefix(tc.want, "backup=") {
				t.Fatalf("rc %d out %q\n%s", rc, out, errs)
			}
			if rc != 0 && len(r.backups()) != 0 {
				t.Errorf("backups/ holds %v", r.backups())
			}
		})
	}
	r := liveRig(t)
	os.Remove(filepath.Join(r.dir, HooksFile))
	if rc, _, errs := r.take(at10); rc != 1 || !strings.Contains(errs, HooksFile+" is missing") || len(r.backups()) != 0 {
		t.Errorf("no hooks file: rc %d %s %v", rc, errs, r.backups())
	}
	r.hooksFile(nil, "../out")
	if rc, _, errs := r.take(at10); rc != 1 || !strings.Contains(errs, "'../out' is not a path inside the project") {
		t.Errorf("a bad target: rc %d %s", rc, errs)
	}
	r.hooksFile(nil, ".env")
	f, _ := os.OpenFile(filepath.Join(r.dir, ".deploy.lock"), os.O_RDWR|os.O_CREATE, 0o664)
	defer f.Close()
	syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if rc, _, errs := r.take(at10); rc != 1 || !strings.Contains(errs, ".deploy.lock") {
		t.Errorf("under a held lock: rc %d %s", rc, errs)
	}
}

// A deploy's snapshot on disk — a run under way, one that died mid-way, or a
// failed revert's — refuses before anything is made or run.
func TestTakeBackupRefusesBesideASnapshot(t *testing.T) {
	failed := "2026-10-02T00:00:00+00:00 deploy-failed 1.1.0 no-backup kasbah=0.1.0 digest=- by=al reason=revert\n"
	for name, tc := range map[string]struct{ log, want string }{
		"a run's snapshot":      {live10, "holds a deploy's snapshot: a deploy or rollback is under way, or one stopped before it finished"},
		"a failed revert's":     {live10 + failed, "is the snapshot a failed revert kept (versions.log ends '" + strings.TrimSuffix(failed, "\n") + "'): the project's files may be part 1.1.0's"},
		"with no live version":  {"", "holds a deploy's snapshot"},
		"a post-hook's failure": {live10 + strings.Replace(failed, "revert", "post-hook", 1), "holds a deploy's snapshot"},
	} {
		t.Run(name, func(t *testing.T) {
			r := liveRig(t)
			os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(tc.log), 0o640)
			os.MkdirAll(filepath.Join(r.dir, PrevDir), 0o770)
			os.WriteFile(filepath.Join(r.dir, snapManifest), []byte(`{"token":"t","targets":[]}`), 0o660)
			rc, out, errs := r.take(at10)
			if rc != 1 || out != "" || !strings.Contains(errs, r.dir+"/"+PrevDir+" ") || !strings.Contains(errs, tc.want) || !strings.Contains(errs, "Nothing was changed") {
				t.Fatalf("rc %d out %q\n%s", rc, out, errs)
			}
			if b := r.backups(); len(b) != 0 || strings.Join(r.calls(), "") != "" {
				t.Errorf("backups/ holds %v, hooks ran %v", b, r.calls())
			}
		})
	}
	// One taken no later than the live run's entry is left over: removing it
	// by hand is the remedy, not waiting for a run that is not there.
	r0 := liveRig(t)
	os.MkdirAll(filepath.Join(r0.dir, PrevDir), 0o770)
	os.WriteFile(filepath.Join(r0.dir, snapManifest), []byte(`{"token":"t","targets":[],"taken":"2026-10-01T00:00:00+00:00"}`), 0o660)
	if rc, _, errs := r0.take(at10); rc != 1 || !strings.Contains(errs, "taken no later than the last run that went live (2026-10-01T00:00:00+00:00)") ||
		!strings.Contains(errs, "remove "+r0.dir+"/"+PrevDir+" by hand") || strings.Contains(errs, "let it finish") {
		t.Errorf("a stale manifest: rc %d %s", rc, errs)
	}
	os.WriteFile(filepath.Join(r0.dir, snapManifest), []byte(`{"token":"t","targets":[],"taken":"2026-10-01T00:00:01+00:00"}`), 0o660)
	if _, _, errs := r0.take(at10); !strings.Contains(errs, "let it finish, or re-run it") {
		t.Errorf("a manifest newer than the live run: %s", errs)
	}
	// A snapshot directory without its manifest is none: a drop cut short.
	r := liveRig(t)
	os.MkdirAll(filepath.Join(r.dir, PrevDir, "t"), 0o770)
	if rc, _, errs := r.take(at10); rc != 0 {
		t.Errorf("no manifest: rc %d %s", rc, errs)
	}
}

// A second backup within the same second refuses: the first's tarball holds
// the name, and is left as it is.
func TestTakeBackupSameSecond(t *testing.T) {
	r := liveRig(t)
	if rc, _, errs := r.take(at10); rc != 0 {
		t.Fatalf("first: rc %d %s", rc, errs)
	}
	tarball := filepath.Join(r.dir, "backups", "1.0.0-20261102-100000.tar.gz")
	before, _ := os.ReadFile(tarball)
	rc, out, errs := r.take(at10)
	if rc != 1 || out != "" || !strings.Contains(errs, "backups/1.0.0-20261102-100000.tar.gz already exists — re-run in a second. Nothing was changed") {
		t.Fatalf("rc %d out %q\n%s", rc, out, errs)
	}
	if after, _ := os.ReadFile(tarball); !bytes.Equal(before, after) {
		t.Error("the first tarball was changed")
	}
	if b := r.backups(); len(b) != 1 || len(r.calls()) != 1 {
		t.Errorf("backups/ holds %v, hooks ran %v", b, r.calls())
	}
}

// A failed hook keeps nothing: no tarball, the directory removed.
func TestTakeBackupHookFailureKeepsNothing(t *testing.T) {
	r := liveRig(t)
	r.hooksFile([]string{`echo half > "$KASBAH_BACKUP_DIR/db.sql"; exit 3`}, ".env")
	rc, out, errs := r.take(at10)
	if rc != 1 || out != "" || !strings.Contains(errs, "the backup hook failed (exit 3)") || !strings.Contains(errs, "no backup of 1.0.0 was kept") {
		t.Fatalf("rc %d out %q\n%s", rc, out, errs)
	}
	if b := r.backups(); len(b) != 0 {
		t.Errorf("backups/ holds %v", b)
	}
}

// Retention runs after the backup, as after a deploy.
func TestTakeBackupAppliesRetention(t *testing.T) {
	r := liveRig(t)
	os.MkdirAll(filepath.Join(r.dir, Backups), 0o775)
	for _, n := range []string{"0.9.0-20261030-090000.tar.gz", "0.9.0-20261031-090000.tar.gz", "0.9.0-20261102-090000.tar.gz"} {
		os.WriteFile(filepath.Join(r.dir, Backups, n), nil, 0o660)
	}
	rc, _, errs := r.take(at10)
	if rc != 0 || !strings.Contains(errs, "removed backups/0.9.0-20261030-090000.tar.gz") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if got := strings.Join(r.backups(), " "); got != "0.9.0-20261031-090000.tar.gz 0.9.0-20261102-090000.tar.gz 1.0.0-20261102-100000.tar.gz" {
		t.Errorf("backups/ holds %s", got)
	}
}

func TestTakeBackupSignalHelper(t *testing.T) {
	dir := os.Getenv("KASBAH_TAKE_DIR")
	if dir == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	atexit.Exit(Remote([]string{"backup", dir}, strings.NewReader(""), io.Discard, os.Stderr))
}

// A signal mid-hook exits removing the backup directory.
func TestTakeBackupSignalRemovesTheDirectory(t *testing.T) {
	r := liveRig(t)
	r.hooksFile([]string{`echo x > "$KASBAH_BACKUP_DIR/db.sql"; kill -TERM $PPID; sleep 1`}, ".env")
	cmd := exec.Command(os.Args[0], "-test.run=^TestTakeBackupSignalHelper$")
	cmd.Env = append(os.Environ(), "KASBAH_TAKE_DIR="+r.dir)
	out, _ := cmd.CombinedOutput()
	if code := cmd.ProcessState.ExitCode(); code != 128+int(syscall.SIGTERM) {
		t.Fatalf("exit %d\n%s", code, out)
	}
	if b := r.backups(); len(b) != 0 {
		t.Errorf("backups/ holds %v\n%s", b, out)
	}
}

// fakeBackup is a BackupServer.
type fakeBackup struct {
	enabled          bool
	push             map[string]string
	pushed, released bool
	takeErr          error
}

func (f *fakeBackup) Marker() (*marker.Marker, error) {
	js := `{}`
	if f.enabled {
		js = `{"backup":{"enabled":true}}`
	}
	v, _ := tree.ParseOne([]byte(js))
	return &marker.Marker{JSON: v.(*tree.Map), AppsPath: "/apps", DataPath: "/apps/data"}, nil
}
func (f *fakeBackup) HoldServer(string, string) (func(), error) {
	return func() { f.released = true }, nil
}
func (f *fakeBackup) TakeBackup(dir string) (string, string, error) {
	if dir != "/apps/built-app" {
		return "", "", cli.Fail("dir %s", dir)
	}
	return "backups/1.0.0-20261102-100000.tar.gz", "1.0.0", f.takeErr
}
func (f *fakeBackup) Push(apps, name string) (map[string]string, error) {
	f.pushed = apps == "/apps" && name == "built-app"
	return f.push, nil
}
func (f *fakeBackup) Close() {}

func runBackupCmd(t *testing.T, f *fakeBackup) (string, int) {
	t.Helper()
	t.Chdir(t.TempDir())
	os.WriteFile("kasbah.yml", []byte("schema: 1\nkasbah_version: 0.1.0\nname: built-app\ndomain: built-app.test\n"), 0o644)
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	code := out.Report(RunBackup(BackupCtx{Out: out, Version: "0.1.0", Dial: func(string) (BackupServer, error) { return f, nil }}, BackupOptions{Target: "deploy@vps"}))
	return se.String(), code
}

// Without off-box backups it stays local and says so; with them it pushes,
// and a push that could not happen fails naming the kept backup.
func TestRunBackup(t *testing.T) {
	for _, tc := range []struct {
		name     string
		f        *fakeBackup
		code     int
		pushed   bool
		want     string
		recorded bool
	}{
		{"not configured", &fakeBackup{}, 0, false, "off-box: none — deploy@vps has no off-box backups", true},
		{"pushed", &fakeBackup{enabled: true, push: map[string]string{"push": "ok"}}, 0, true, "off-box: pushed through kasbah-backup", true},
		{"no container", &fakeBackup{enabled: true, push: map[string]string{"push": "no-container", "state": "exited"}}, 1, true, "the kasbah-backup container is exited there", false},
		{"push failed", &fakeBackup{enabled: true, push: map[string]string{"push": "failed", "rc": "1"}}, 1, true, "failed (exit 1", false},
		{"no backup", &fakeBackup{enabled: true, takeErr: cli.Fail("nothing live")}, 1, false, "nothing live", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			se, code := runBackupCmd(t, tc.f)
			if code != tc.code || tc.f.pushed != tc.pushed || !strings.Contains(se, tc.want) || !tc.f.released {
				t.Fatalf("code %d pushed %v released %v\n%s", code, tc.f.pushed, tc.f.released, se)
			}
			if tc.f.takeErr == nil && !strings.Contains(se, "/apps/built-app/backups/1.0.0-20261102-100000.tar.gz") {
				t.Errorf("the backup is not named:\n%s", se)
			}
			if last, _ := state.Get(state.File, "last_server"); (last == "deploy@vps") != tc.recorded {
				t.Errorf("last_server %q", last)
			}
		})
	}
}

func TestParseBackup(t *testing.T) {
	if o, err := ParseBackup([]string{"deploy@vps\r"}); err != nil || o.Target != "deploy@vps" {
		t.Errorf("%+v %v", o, err)
	}
	if _, err := ParseBackup([]string{"--help"}); err != ErrHelp {
		t.Errorf("help: %v", err)
	}
	for _, args := range [][]string{{"--yes"}, {"1.0.0"}, {"a@b", "c@d"}} {
		if _, err := ParseBackup(args); err == nil {
			t.Errorf("%v accepted", args)
		}
	}
}
