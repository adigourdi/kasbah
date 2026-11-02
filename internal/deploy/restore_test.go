package deploy

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/atexit"
)

type member struct {
	name, body, link string
	typ              byte
	mode             int64
}

// writeBackup writes members as a gzip'd tar at p.
func writeBackup(t *testing.T, p string, ms ...member) {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	for _, m := range ms {
		h := &tar.Header{Name: m.name, Typeflag: m.typ, Mode: 0o640, Size: int64(len(m.body)), Linkname: m.link}
		switch m.typ {
		case 0:
			h.Typeflag = tar.TypeReg
		case tar.TypeDir:
			h.Mode, h.Size = 0o750, 0
		case tar.TypeSymlink:
			h.Size = 0
		}
		if m.mode != 0 {
			h.Mode = m.mode
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			io.WriteString(tw, m.body)
		}
	}
	tw.Close()
	gz.Close()
	os.MkdirAll(filepath.Dir(p), 0o777)
	if err := os.WriteFile(p, b.Bytes(), 0o660); err != nil {
		t.Fatal(err)
	}
}

func TestNewestBackup(t *testing.T) {
	names := []string{
		"1.0.0-20261101-000000.tar.gz", "1.0.0-20261102-000000.tar.gz", "1.0.0-20261031-235959.tar.gz",
		"1.0.0-rc.1-20261105-000000.tar.gz", "11.0.0-20261106-000000.tar.gz", "1.0.0-20261107-000000.tar.gz.part",
		"1.0.0-20261108-000000", "notes.txt",
		"2.0.0-beta-2-20261101-000000.tar.gz", "2.0.0-beta-2-20261103-000000.tar.gz", "2.0.0-beta-20261109-000000.tar.gz",
	}
	for v, want := range map[string]string{
		"1.0.0":        "1.0.0-20261102-000000.tar.gz",
		"1.0.0-rc.1":   "1.0.0-rc.1-20261105-000000.tar.gz",
		"2.0.0-beta-2": "2.0.0-beta-2-20261103-000000.tar.gz",
		"2.0.0-beta":   "2.0.0-beta-20261109-000000.tar.gz",
		"1.0":          "",
		"3.0.0":        "",
	} {
		if got := newestBackup(names, v); got != want {
			t.Errorf("%s: %q, want %q", v, got, want)
		}
	}
}

func probe(t *testing.T, dir, version string) (BackupFacts, string) {
	t.Helper()
	var out, errb bytes.Buffer
	if rc := backupProbe(dir, version, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var f BackupFacts
	if err := json.Unmarshal(out.Bytes(), &f); err != nil {
		t.Fatalf("%v %q", err, out.String())
	}
	return f, out.String() + errb.String()
}

// The probe names the newest backup and the keys that differ; no value
// crosses, and an absent backups/ is no backup.
func TestBackupProbe(t *testing.T) {
	dir := t.TempDir()
	if f, out := probe(t, dir, "1.0.0"); f.Backup != "" || f.Env != "no" || f.Changed == nil || !strings.Contains(out, `"changed":[]`) {
		t.Fatalf("no backups/: %+v %s", f, out)
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("SAME=1\r\nPW=live-secret\r\nNEW=x\nKASBAH_CPU_LIMIT=2\n"), 0o660)
	writeBackup(t, filepath.Join(dir, Backups, "1.0.0-20261101-000000.tar.gz"),
		member{name: SnapDir + "/.env", body: "SAME=0\n"})
	writeBackup(t, filepath.Join(dir, Backups, "1.0.0-20261102-000000.tar.gz"),
		member{name: "db.sql", body: "dump"}, member{name: SnapDir + "/", typ: tar.TypeDir},
		member{name: SnapDir + "/.env", body: "SAME=1\nPW=old-secret\r\nGONE=y\nKASBAH_CPU_LIMIT=1\n"})
	f, out := probe(t, dir, "1.0.0")
	if f.Backup != "1.0.0-20261102-000000.tar.gz" || f.Env != "yes" || strings.Join(f.Changed, ",") != "PW" ||
		strings.Join(f.OnlyBackup, ",") != "GONE" || strings.Join(f.OnlyLive, ",") != "NEW" {
		t.Fatalf("%+v", f)
	}
	for _, v := range []string{"secret", "=1", "=x", "=y"} {
		if strings.Contains(out, v) {
			t.Errorf("a value crossed: %q in %s", v, out)
		}
	}
	writeBackup(t, filepath.Join(dir, Backups, "1.0.0-20261103-000000.tar.gz"), member{name: "db.sql", body: "dump"})
	if f, _ := probe(t, dir, "1.0.0"); f.Backup != "1.0.0-20261103-000000.tar.gz" || f.Env != "no" {
		t.Fatalf("a backup without .env: %+v", f)
	}
	os.WriteFile(filepath.Join(dir, Backups, "1.0.0-20261104-000000.tar.gz"), []byte("not gzip"), 0o660)
	if f, out := probe(t, dir, "1.0.0"); f.Backup != "1.0.0-20261104-000000.tar.gz" || f.Env != "unreadable" || !strings.Contains(out, "could not read") {
		t.Fatalf("a damaged backup: %+v %s", f, out)
	}
}

func TestRestoreEnvArm(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".env"), []byte("A=new\nB=same\nC=live\n"), 0o640)
	name := "1.0.0-20261102-000000.tar.gz"
	writeBackup(t, filepath.Join(dir, Backups, name), member{name: SnapDir + "/.env", body: "A='old value'\r\nB=same\nD=back\n"})
	arm := func(args ...string) (int, string) {
		var out, errb bytes.Buffer
		rc := Remote(append([]string{"restore-env", dir, name}, args...), nil, &out, &errb)
		return rc, out.String() + errb.String()
	}
	for _, bad := range [][]string{{"KASBAH_CPU_LIMIT"}, {"A=1"}, {"--all", "A"}} {
		if rc, out := arm(bad...); rc == 0 || !strings.Contains(out, "remote:") {
			t.Errorf("%v accepted: %s", bad, out)
		}
	}
	if rc, out := arm("A", "C", "D"); rc != 0 || out != "env=restored\n" {
		t.Fatalf("keys: %d %s", rc, out)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".env")); string(b) != "A='old value'\nB=same\nD=back\n" {
		t.Fatalf("per key: %q", b)
	}
	if fi, _ := os.Stat(filepath.Join(dir, ".env")); fi.Mode().Perm() != 0o660 {
		t.Errorf("mode %v", fi.Mode().Perm())
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("X=1\n"), 0o660)
	if rc, out := arm("--all"); rc != 0 || out != "env=restored\n" {
		t.Fatalf("all: %d %s", rc, out)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".env")); string(b) != "A='old value'\r\nB=same\nD=back\n" {
		t.Fatalf("whole: %q", b)
	}
	writeBackup(t, filepath.Join(dir, Backups, name), member{name: "db.sql", body: "x"})
	if rc, out := arm("--all"); rc == 0 || !strings.Contains(out, "holds no kasbah-snapshot/.env — .env left untouched") {
		t.Fatalf("no .env in the backup: %d %s", rc, out)
	}
}

func extractInto(t *testing.T, ms ...member) (string, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "b.tar.gz")
	writeBackup(t, p, ms...)
	f, _ := os.Open(p)
	defer f.Close()
	gz, _ := gzip.NewReader(f)
	dir := filepath.Join(t.TempDir(), "x")
	os.Mkdir(dir, 0o700)
	root, _ := os.OpenRoot(dir)
	defer root.Close()
	return dir, untarSafe(root, tar.NewReader(gz))
}

// Nothing a backup holds is written outside the extraction, or through a
// link it holds.
func TestUntarSafe(t *testing.T) {
	outside := t.TempDir()
	for name, ms := range map[string][]member{
		"dotdot":         {{name: "../escape", body: "x"}},
		"inner dotdot":   {{name: "a/../../escape", body: "x"}},
		"absolute":       {{name: outside + "/escape", body: "x"}},
		"through a link": {{name: "l", typ: tar.TypeSymlink, link: outside}, {name: "l/escape", body: "x"}},
		"inner link":     {{name: "d/", typ: tar.TypeDir}, {name: "l", typ: tar.TypeSymlink, link: "d"}, {name: "l/f", body: "x"}},
		"over a link":    {{name: "l", typ: tar.TypeSymlink, link: outside + "/escape"}, {name: "l", body: "x"}},
	} {
		if _, err := extractInto(t, ms...); err == nil {
			t.Errorf("%s: extracted", name)
		}
		if _, err := os.Lstat(filepath.Join(outside, "escape")); err == nil {
			t.Fatalf("%s: wrote outside the extraction", name)
		}
	}
	dir, err := extractInto(t, member{name: "db.sql", body: "dump"}, member{name: SnapDir + "/conf/", typ: tar.TypeDir},
		member{name: SnapDir + "/conf/app.conf", body: "v1"}, member{name: SnapDir + "/conf/link", typ: tar.TypeSymlink, link: "/etc/passwd"},
		member{name: "./x/y", body: "z"}, member{name: "fifo", typ: tar.TypeFifo})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, SnapDir, "conf", "app.conf")); string(b) != "v1" {
		t.Errorf("app.conf %q", b)
	}
	if l, err := os.Readlink(filepath.Join(dir, SnapDir, "conf", "link")); err != nil || l != "/etc/passwd" {
		t.Errorf("a link is kept as a link: %q %v", l, err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "x", "y")); string(b) != "z" {
		t.Errorf("x/y %q", b)
	}
	if _, err := os.Lstat(filepath.Join(dir, "fifo")); err == nil {
		t.Error("a fifo was made")
	}
	// Modes: directories 770, files their own, owner rw at least, never past 660.
	defer syscall.Umask(syscall.Umask(0o002))
	dir, err = extractInto(t, member{name: "d/", typ: tar.TypeDir, mode: 0o500}, member{name: "d/wide", body: "x", mode: 0o777},
		member{name: "d/ro", body: "x", mode: 0o400}, member{name: "e/f", body: "x", mode: 0o640})
	if err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]os.FileMode{"d": 0o770, "e": 0o770, "d/wide": 0o660, "d/ro": 0o600, "e/f": 0o640} {
		if fi, err := os.Lstat(filepath.Join(dir, p)); err != nil || fi.Mode().Perm() != want {
			t.Errorf("%s: %v, want %v (%v)", p, fi.Mode().Perm(), want, err)
		}
	}
}

// restoreRig is revertRig rolling back to 1.0.0, whose newest backup holds a
// dump and the .env it ran with.
func restoreRig(t *testing.T, ups string) (*rig, Spec) {
	r := revertRig(t, ups)
	writeBackup(t, filepath.Join(r.dir, Backups, "1.0.0-20261101-000000.tar.gz"),
		member{name: "db.sql", body: "dump-of-1.0.0"}, member{name: SnapDir + "/", typ: tar.TypeDir},
		member{name: SnapDir + "/.env", body: "A=from-1.0.0\n"})
	sp := r.revertSpec()
	sp.Mode = "rollback"
	sp.RestoreFrom = "1.0.0-20261101-000000.tar.gz"
	show := func(what string) string {
		return `echo "` + what + ` dir=$KASBAH_BACKUP_DIR $(cat "$KASBAH_BACKUP_DIR/db.sql" 2>/dev/null) $(stat -c %a "$KASBAH_BACKUP_DIR" 2>/dev/null)" >> "$LOG"`
	}
	sp.Pre, sp.Post, sp.Restore = []string{show("pre-rb")}, []string{show("post-rb")}, []string{show("restore")}
	return r, sp
}

func (r *rig) noRestoreDir(t *testing.T) {
	t.Helper()
	if m, _ := filepath.Glob(filepath.Join(r.dir, UnpackedPrefix+"*")); len(m) != 0 {
		t.Errorf("the extraction is left: %v", m)
	}
}

// pre-rollback, restore, retag, up, post-rollback; each hook sees the
// extraction, 770 to the group, and it is gone once the run ends.
func TestEngineRollbackRestoreOrder(t *testing.T) {
	r, sp := restoreRig(t, "")
	sp.RestoreData = true
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	at := filepath.Join(r.dir, UnpackedPrefix+strconv.Itoa(os.Getpid()))
	c := r.calls()
	pre, rest := index(c, "pre-rb dir="+at+" dump-of-1.0.0 770"), index(c, "restore dir="+at+" dump-of-1.0.0 770")
	tag, up, post := index(c, "tag demo-web:1.0.0 demo-web:current"), index(c, "compose -p demo up"), index(c, "post-rb dir="+at+" dump-of-1.0.0 770")
	if pre < 0 || rest <= pre || tag <= rest || up <= tag || post <= up {
		t.Fatalf("order pre %d restore %d tag %d up %d post %d: %v\n%s", pre, rest, tag, up, post, c, errs)
	}
	r.noRestoreDir(t)
	if rep, _, _ := ParseReport(out); rep == nil || !strings.HasPrefix(rep.Backup, "backups/0.9.0-") {
		t.Fatalf("the outgoing version's backup: %q", out)
	}
	// Answered no, the data hook does not run and the others still see it.
	r, sp = restoreRig(t, "")
	at = filepath.Join(r.dir, UnpackedPrefix+strconv.Itoa(os.Getpid()))
	if rc, _, errs := r.run(sp); rc != 0 || index(r.calls(), "restore ") >= 0 || index(r.calls(), "pre-rb dir="+at+" dump-of-1.0.0") < 0 {
		t.Fatalf("no data: rc %d %v %s", rc, r.calls(), errs)
	}
	r.noRestoreDir(t)
	// No backup: none, and nothing extracted.
	r, sp = restoreRig(t, "")
	sp.RestoreFrom = ""
	if rc, _, errs := r.run(sp); rc != 0 || index(r.calls(), "pre-rb dir=none") < 0 || index(r.calls(), "post-rb dir=none") < 0 || strings.Contains(errs, "extracted") {
		t.Fatalf("no backup: rc %d %v %s", rc, r.calls(), errs)
	}
	// No hook to hand it to: nothing extracted.
	r, sp = restoreRig(t, "")
	sp.Pre, sp.Post = nil, nil
	if rc, _, errs := r.run(sp); rc != 0 || strings.Contains(errs, "extracted") {
		t.Fatalf("no hooks: rc %d %s", rc, errs)
	}
	// --skip-hooks never skips the restore hook.
	r, sp = restoreRig(t, "")
	at = filepath.Join(r.dir, UnpackedPrefix+strconv.Itoa(os.Getpid()))
	sp.SkipHooks, sp.RestoreData = true, true
	if rc, _, errs := r.run(sp); rc != 0 || index(r.calls(), "restore dir="+at+" dump-of-1.0.0") < 0 || index(r.calls(), "pre-rb") >= 0 {
		t.Fatalf("--skip-hooks: rc %d %v %s", rc, r.calls(), errs)
	}
}

// A failed restore hook asks; stop puts the files and .env back and leaves
// the extraction behind on no path.
func TestEngineRestoreHookFails(t *testing.T) {
	for _, answer := range []string{AnswerStop, AnswerContinue} {
		r, sp := restoreRig(t, "")
		sp.RestoreData = true
		sp.Restore = []string{`echo half >> "$LOG"; exit 4`}
		var asked []Question
		rc, _, errs := r.converse(sp, func(q Question) string { asked = append(asked, q); return answer })
		if len(asked) != 1 || asked[0].Step != "restore hook" || !strings.Contains(asked[0].Error, "the restore hook failed (exit 4)") {
			t.Fatalf("%s: asked %+v", answer, asked)
		}
		tagged := index(r.calls(), "tag ") >= 0
		if answer == AnswerStop && (rc != 1 || tagged || !strings.Contains(errs, "the files it had shipped were put back")) {
			t.Fatalf("stop: rc %d tagged %v %s", rc, tagged, errs)
		}
		if answer == AnswerStop {
			r.restored(t)
		}
		if answer == AnswerContinue && (rc != 0 || !tagged) {
			t.Fatalf("continue: rc %d %s", rc, errs)
		}
		r.noRestoreDir(t)
	}
}

// A failed up reverts, .env included, and the extraction goes with it.
func TestEngineRollbackRevertDropsRestore(t *testing.T) {
	r, sp := restoreRig(t, "1\n0\n")
	sp.RestoreData = true
	rc, _, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "was reverted") {
		t.Fatalf("rc %d %s", rc, errs)
	}
	r.restored(t)
	if b, _ := os.ReadFile(filepath.Join(r.dir, Replaced)); string(b) != "A=new\n" {
		t.Errorf("the restored .env is not kept aside: %q", b)
	}
	r.noRestoreDir(t)
}

// An unsafe backup is a failed extraction, asked about like a hook; a
// leftover from a killed run is removed first.
func TestEngineExtractionFails(t *testing.T) {
	r, sp := restoreRig(t, "")
	writeBackup(t, filepath.Join(r.dir, Backups, sp.RestoreFrom), member{name: "../../escape", body: "x"})
	left := filepath.Join(r.dir, UnpackedPrefix+"1")
	os.MkdirAll(filepath.Join(left, "kasbah-snapshot"), 0o500)
	sp.OnHookFailure = AnswerStop
	rc, _, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "refusing archive member \"../../escape\"") || index(r.calls(), "pre-rb") >= 0 {
		t.Fatalf("rc %d %v %s", rc, r.calls(), errs)
	}
	if !strings.Contains(errs, "removed "+left+", a backup an interrupted rollback extracted") {
		t.Errorf("the leftover is not said: %s", errs)
	}
	r.restored(t)
	r.noRestoreDir(t)
	if _, err := os.Lstat(filepath.Join(filepath.Dir(r.dir), "escape")); err == nil {
		t.Error("wrote outside the extraction")
	}
	r, sp = restoreRig(t, "")
	sp.RestoreFrom, sp.OnHookFailure = "0.9.0-20261101-000000.tar.gz", AnswerContinue
	if rc, _, errs := r.run(sp); rc != 0 || !strings.Contains(errs, "is not a backup of 1.0.0") || index(r.calls(), "pre-rb dir=none") < 0 {
		t.Fatalf("another version's backup, carried past: rc %d %v %s", rc, r.calls(), errs)
	}
	// Carried past with data asked for, the restore hook never runs.
	r, sp = restoreRig(t, "")
	writeBackup(t, filepath.Join(r.dir, Backups, sp.RestoreFrom), member{name: "../escape", body: "x"})
	sp.RestoreData, sp.OnHookFailure = true, AnswerContinue
	rc, _, errs = r.run(sp)
	if c := r.calls(); rc != 0 || index(c, "restore ") >= 0 || index(c, "pre-rb dir=none") < 0 || index(c, "post-rb dir=none") < 0 ||
		!strings.Contains(errs, "data not restored: the backup could not be extracted") {
		t.Fatalf("no extraction, data asked: rc %d %v %s", rc, c, errs)
	}
	r.noRestoreDir(t)
}

// A signal's cleanup removes the extraction.
func TestExtractionGoesOnASignalToo(t *testing.T) {
	r, sp := restoreRig(t, "")
	e := &engine{dir: r.dir, sp: sp, stderr: io.Discard, project: "demo"}
	defer func() {
		if e.broot != nil {
			e.broot.Close()
		}
	}()
	// The project's setgid group is kept, so any operator can remove it.
	if err := os.Chmod(r.dir, 0o770|os.ModeSetgid); err != nil {
		t.Fatal(err)
	}
	if err := e.extract(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(e.rdir, "db.sql")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{e.rdir, filepath.Join(e.rdir, SnapDir)} {
		if fi, err := os.Stat(p); err != nil || fi.Mode()&(os.ModeSetgid|os.ModePerm) != os.ModeSetgid|0o770 {
			t.Errorf("%s: %v %v", p, fi.Mode(), err)
		}
	}
	atexit.Run()
	r.noRestoreDir(t)
}

// --undo puts .env back from the run's snapshot, the one it replaces kept.
func TestUndoEnvArm(t *testing.T) {
	dir := t.TempDir()
	envf := filepath.Join(dir, ".env")
	os.WriteFile(envf, []byte("A=server\n"), 0o660)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{".env", "compose.yml"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot: %s", errb.String())
	}
	arm := func(args ...string) (int, string) {
		var out, errb bytes.Buffer
		rc := Remote(append([]string{"restore-env"}, args...), nil, &out, &errb)
		return rc, out.String() + errb.String()
	}
	os.WriteFile(envf, []byte("A=backup\n"), 0o660)
	for _, bad := range [][]string{{"rel", "--undo", "tok"}, {dir, "--undo", "other"}, {dir, "--undo", "../x"}} {
		if rc, out := arm(bad...); rc == 0 || !strings.Contains(out, "remote:") {
			t.Errorf("%v accepted: %s", bad, out)
		}
	}
	if b, _ := os.ReadFile(envf); string(b) != "A=backup\n" {
		t.Fatalf("a refusal changed .env: %q", b)
	}
	if rc, out := arm(dir, "--undo", "tok"); rc != 0 || out != "env=put-back\nsaved="+dir+"/"+Replaced+"\n" {
		t.Fatalf("undo: %d %s", rc, out)
	}
	if b, _ := os.ReadFile(envf); string(b) != "A=server\n" {
		t.Errorf(".env %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, Replaced)); string(b) != "A=backup\n" {
		t.Errorf("kept %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, PrevDir, "snapshot.json")); err != nil {
		t.Errorf("the snapshot is not kept for the next run: %v", err)
	}
	// Already the snapshot's: nothing kept aside.
	os.Remove(filepath.Join(dir, Replaced))
	if rc, out := arm(dir, "--undo", "tok"); rc != 0 || out != "env=put-back\n" {
		t.Fatalf("undo again: %d %s", rc, out)
	}
	// No .env before the run: none after.
	dir = t.TempDir()
	if rc := takeSnapshot(dir, "tok", []string{".env"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot: %s", errb.String())
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("A=backup\n"), 0o660)
	if rc, out := arm(dir, "--undo", "tok"); rc != 0 {
		t.Fatalf("undo, no .env before: %d %s", rc, out)
	}
	if _, err := os.Lstat(filepath.Join(dir, ".env")); err == nil {
		t.Error("the backup's .env is left where there was none")
	}
	if rc, out := Remote([]string{"backup-probe", "rel", "1.0.0"}, nil, io.Discard, io.Discard), ""; rc == 0 {
		t.Errorf("backup-probe took a relative DIR %s", out)
	}
	if rc, out := arm("rel", "1.0.0-20261102-000000.tar.gz", "--all"); rc == 0 || !strings.Contains(out, "DIR absolute") {
		t.Errorf("restore-env took a relative DIR: %s", out)
	}
}
