package deploy

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
)

// tarball reads a backup: each entry's header, and each regular file's bytes.
func tarball(t *testing.T, p string) (map[string]*tar.Header, map[string]string) {
	t.Helper()
	f, err := os.Open(p)
	if err != nil {
		t.Fatalf("open %s: %v", p, err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gunzip %s: %v", p, err)
	}
	tr := tar.NewReader(gz)
	hs, files := map[string]*tar.Header{}, map[string]string{}
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("untar %s: %v", p, err)
		}
		hs[h.Name] = h
		if h.Typeflag == tar.TypeReg {
			b, _ := io.ReadAll(tr)
			files[h.Name] = string(b)
		}
	}
	return hs, files
}

func readTar(t *testing.T, p string) map[string]string {
	t.Helper()
	_, files := tarball(t, p)
	return files
}

func (r *rig) backups() []string {
	es, _ := os.ReadDir(filepath.Join(r.dir, Backups))
	var out []string
	for _, e := range es {
		out = append(out, e.Name())
	}
	return out
}

// A deploy that ends live keeps the snapshot and the hooks' output as the
// outgoing version's tarball, and renders the hooks file.
func TestEngineKeepsTheSnapshotAsABackup(t *testing.T) {
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot = "tok"
	sp.Restore = []string{`psql < "$KASBAH_BACKUP_DIR/db.sql"`}
	sp.Targets = []string{".env", "compose.yml", "extra.txt"}
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	rep, _, _ := ParseReport(out)
	if rep == nil || !strings.HasPrefix(rep.Backup, "backups/0.9.0-") || !strings.HasSuffix(rep.Backup, ".tar.gz") {
		t.Fatalf("report %+v", rep)
	}
	if !strings.Contains(r.logText(), " deploy 1.0.0 "+rep.Backup+" ") {
		t.Fatalf("versions.log %q", r.logText())
	}
	hs, files := tarball(t, filepath.Join(r.dir, rep.Backup))
	want := map[string]string{"db.sql": "dump\n", SnapDir + "/.env": "A=old\n", SnapDir + "/compose.yml": "v0.9.0\n"}
	if len(files) != len(want) {
		t.Fatalf("tarball holds %v", files)
	}
	for k, v := range want {
		if files[k] != v {
			t.Fatalf("tarball %s is %q, holds %v", k, files[k], files)
		}
	}
	if m := hs[SnapDir+"/.env"].Mode; m != 0o600 {
		t.Errorf(".env has mode %o in the tarball, not its own 600", m)
	}
	fi, err := os.Stat(filepath.Join(r.dir, rep.Backup))
	if err != nil || fi.Mode().Perm() != 0o660 {
		t.Fatalf("tarball mode: %v %v", fi, err)
	}
	if b := r.backups(); len(b) != 1 {
		t.Fatalf("backups/ holds %v", b)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Fatal("the snapshot is still in the project")
	}
	b, err := os.ReadFile(filepath.Join(r.dir, HooksFile))
	if err != nil {
		t.Fatal(err)
	}
	var h Hooks
	if json.Unmarshal(b, &h) != nil || len(h.Backup) != 1 || h.Backup[0] != backupHook || len(h.Restore) != 1 || h.Restore[0] != sp.Restore[0] ||
		strings.Join(h.Targets, " ") != ".env compose.yml extra.txt" {
		t.Fatalf("%s: %s", HooksFile, b)
	}
	if fi, _ := os.Stat(filepath.Join(r.dir, HooksFile)); fi.Mode().Perm() != 0o644 {
		t.Errorf("%s mode %o", HooksFile, fi.Mode().Perm())
	}
	// None declared is an empty list, never null.
	sp = r.spec()
	sp.Backup = nil
	if rc, _, errs := r.run(sp); rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, HooksFile)); string(b) != "{\"backup\":[],\"restore\":[],\"targets\":[]}\n" {
		t.Fatalf("%s: %s", HooksFile, b)
	}
}

// A directory target's copy is widened to be removable; the tarball carries
// the mode it really had.
func TestBackupKeepsDirectoryModes(t *testing.T) {
	r := revertRig(t, "")
	conf := filepath.Join(r.dir, "conf")
	os.MkdirAll(filepath.Join(conf, "ro"), 0o755)
	os.WriteFile(filepath.Join(conf, "ro", "a"), []byte("a\n"), 0o644)
	os.Chmod(filepath.Join(conf, "ro"), 0o555)
	defer os.Chmod(filepath.Join(conf, "ro"), 0o755)
	var o, e bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok2", []string{".env", "compose.yml", "conf"}, &o, &e); rc != 0 {
		t.Fatalf("snapshot: %s", e.String())
	}
	sp := r.spec()
	sp.Snapshot = "tok2"
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	rep, _, _ := ParseReport(out)
	hs, files := tarball(t, filepath.Join(r.dir, rep.Backup))
	if h := hs[SnapDir+"/conf/ro/"]; h == nil || h.Mode != 0o555 || files[SnapDir+"/conf/ro/a"] != "a\n" {
		t.Fatalf("conf/ro: %+v %v", h, files)
	}
	// The kept snapshot "tok" left by revertRig is what the merge started
	// from: the outgoing .env, not the one the run shipped.
	if files[SnapDir+"/.env"] != "A=old\n" {
		t.Fatalf(".env %q", files[SnapDir+"/.env"])
	}
}

// A post-hook failure leaves the new version live: the outgoing version's
// backup is kept, and the deploy-failed line names it.
func TestEnginePostHookFailureKeepsTheBackup(t *testing.T) {
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot = "tok"
	sp.Post = []string{"exit 4"}
	rc, out, errs := r.run(sp)
	if f := ParseFailure(out); rc != 1 || f == nil || f.Outcome != PostHook {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
	b := r.backups()
	if len(b) != 1 || !strings.HasPrefix(b[0], "0.9.0-") || !strings.HasSuffix(b[0], ".tar.gz") {
		t.Fatalf("backups/ %v", b)
	}
	if !strings.Contains(r.logText(), " deploy-failed 1.0.0 backups/"+b[0]+" ") {
		t.Fatalf("versions.log %q", r.logText())
	}
	if got := readTar(t, filepath.Join(r.dir, Backups, b[0])); got[SnapDir+"/.env"] != "A=old\n" || got["db.sql"] != "dump\n" {
		t.Fatalf("tarball %v", got)
	}
}

// A revert uses the snapshot up and removes the backup directory.
func TestEngineRevertLeavesNoBackup(t *testing.T) {
	r := revertRig(t, "1\n0\n")
	sp := r.spec()
	sp.Snapshot = "tok"
	rc, out, errs := r.run(sp)
	if f := ParseFailure(out); rc != 1 || f == nil || f.Outcome != Reverted {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
	if index(r.calls(), "hook backup") < 0 {
		t.Fatalf("the backup hook did not run: %v", r.calls())
	}
	if b := r.backups(); len(b) != 0 {
		t.Fatalf("a revert left %v in backups/", b)
	}
	r.restored(t)
}

// A rollback writes no hook output: its backup of the version it left is
// the snapshot alone.
func TestEngineRollbackKeepsASnapshotBackup(t *testing.T) {
	r := revertRig(t, "")
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line+"2026-10-02T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n"), 0o664)
	os.WriteFile(r.images, []byte("demo-web:0.9.0\ndemo-web:current\n"), 0o644)
	sp := r.spec()
	sp.Mode, sp.Version, sp.Snapshot = "rollback", "0.9.0", "tok"
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d %s", rc, errs)
	}
	rep, _, _ := ParseReport(out)
	if rep == nil || !strings.HasPrefix(rep.Backup, "backups/1.0.0-") || index(r.calls(), "hook backup") >= 0 {
		t.Fatalf("report %+v %v", rep, r.calls())
	}
	got := readTar(t, filepath.Join(r.dir, rep.Backup))
	if len(got) != 2 || got[SnapDir+"/.env"] != "A=old\n" || got[SnapDir+"/compose.yml"] != "v0.9.0\n" {
		t.Fatalf("tarball %v", got)
	}
	if _, err := os.Stat(filepath.Join(r.dir, HooksFile)); err != nil {
		t.Fatalf("a rollback did not render %s: %v", HooksFile, err)
	}
}

// A tarball that cannot be written leaves the directory for the operator,
// says so, and records no-backup.
func TestEngineTarballFailureRecordsNoBackup(t *testing.T) {
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot = "tok"
	at := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	stuck := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000.tar.gz.part")
	os.MkdirAll(stuck, 0o755)
	var errb bytes.Buffer
	e := &engine{dir: r.dir, sp: sp, stderr: &errb, now: func() time.Time { return at }, sleep: func(time.Duration) {}}
	rep, err := e.run()
	if e.lockFile != nil {
		e.lockFile.Close()
	}
	if e.serverLock != nil {
		e.serverLock.Close()
	}
	if err != nil || rep.Backup != "no-backup" {
		t.Fatalf("%v %+v\n%s", err, rep, errb.String())
	}
	left := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000")
	if !strings.Contains(errb.String(), "could not write the backup") || !strings.Contains(errb.String(), "is left in "+left) {
		t.Fatalf("narration: %s", errb.String())
	}
	if b, _ := os.ReadFile(filepath.Join(left, SnapDir, ".env")); string(b) != "A=old\n" {
		t.Fatalf("the directory left holds .env %q", b)
	}
	if !strings.Contains(r.logText(), " deploy 1.0.0 no-backup ") {
		t.Fatalf("versions.log %q", r.logText())
	}
}

// Retention keeps every backup of the last 24 hours and the newest older
// one; nothing else in backups/ is touched.
func TestPruneBackups(t *testing.T) {
	dir := t.TempDir()
	bk := filepath.Join(dir, Backups)
	os.MkdirAll(bk, 0o755)
	names := []string{
		"1.0.0-20261030-090000.tar.gz",         // old
		"1.0.1-20261031-090000.tar.gz",         // old
		"1.0.2-20261101-095959.tar.gz",         // newest older: kept
		"1.0.3-20261101-100000.tar.gz",         // exactly 24h: kept
		"1.0.4-dirty.1-20261102-090000.tar.gz", // kept
		"2.0.0-20261103-000000.tar.gz",         // ahead of the clock: kept
		"pre-deploy-20200101-000000.sql",       // not kasbah's pattern
		"notes.txt",
		"1.0.0-20200101-000000.tar.gz.part",
		"1.0.0-20200101-000000",
	}
	for _, n := range names {
		os.WriteFile(filepath.Join(bk, n), nil, 0o644)
	}
	os.Mkdir(filepath.Join(bk, "0.1.0-20200101-000000.tar.gz"), 0o755)
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	root, err := os.OpenRoot(bk)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	removed, errs := pruneBackups(root, bk, now)
	if len(errs) != 0 || strings.Join(removed, " ") != "1.0.0-20261030-090000.tar.gz 1.0.1-20261031-090000.tar.gz" {
		t.Fatalf("removed %v %v", removed, errs)
	}
	es, _ := os.ReadDir(bk)
	var left []string
	for _, e := range es {
		left = append(left, e.Name())
	}
	sort.Strings(left)
	want := append([]string{"0.1.0-20200101-000000.tar.gz"}, names[2:]...)
	sort.Strings(want)
	if strings.Join(left, " ") != strings.Join(want, " ") {
		t.Fatalf("left %v\nwant %v", left, want)
	}
	// Run again: the newest older one stays the one kept.
	if removed, _ := pruneBackups(root, bk, now); len(removed) != 0 {
		t.Fatalf("second prune removed %v", removed)
	}
}

// The engine applies retention after a successful run, on its own clock.
func TestEnginePrunesAfterARun(t *testing.T) {
	r := revertRig(t, "")
	os.MkdirAll(filepath.Join(r.dir, Backups), 0o755)
	for _, n := range []string{"0.8.0-20261020-000000.tar.gz", "0.8.1-20261025-000000.tar.gz"} {
		os.WriteFile(filepath.Join(r.dir, Backups, n), nil, 0o660)
	}
	sp := r.spec()
	sp.Snapshot = "tok"
	var errb bytes.Buffer
	at := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	e := &engine{dir: r.dir, sp: sp, stderr: &errb, now: func() time.Time { return at }, sleep: func(time.Duration) {}}
	rep, err := e.run()
	e.lockFile.Close()
	e.serverLock.Close()
	if err != nil || rep.Backup != "backups/0.9.0-20261102-100000.tar.gz" {
		t.Fatalf("%v %+v\n%s", err, rep, errb.String())
	}
	if b := strings.Join(r.backups(), " "); b != "0.8.1-20261025-000000.tar.gz 0.9.0-20261102-100000.tar.gz" {
		t.Fatalf("backups/ %s\n%s", b, errb.String())
	}
	if !strings.Contains(errb.String(), "removed backups/0.8.0-20261020-000000.tar.gz") {
		t.Fatalf("narration: %s", errb.String())
	}
}

func TestSafeName(t *testing.T) {
	for v, ok := range map[string]bool{"1.2.0": true, "1.2.0-dirty.20261102": true, "1.0.0+b.1": true, "": false, "a/b": false, ".x": false, "-1": false, "1 2": false} {
		if safeName(v) != ok {
			t.Errorf("safeName(%q) = %v", v, !ok)
		}
	}
}

// runAt runs the engine on a fixed clock, its question answered from answers.
func (r *rig) runAt(sp Spec, at time.Time, answers string) (*Report, error, string, string) {
	r.t.Helper()
	var out, errb bytes.Buffer
	e := &engine{dir: r.dir, sp: sp, stderr: &errb, stdout: &out, in: bufio.NewReader(strings.NewReader(answers)),
		answerWait: time.Second, now: func() time.Time { return at }, sleep: func(time.Duration) {}}
	rep, err := e.run()
	for _, f := range []*os.File{e.lockFile, e.serverLock} {
		if f != nil {
			f.Close()
		}
	}
	if e.broot != nil {
		e.broot.Close()
	}
	return rep, err, out.String(), errb.String()
}

var at10 = time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)

// A backups/ that links to a directory elsewhere holds the backups there,
// and retention works through the link.
func TestBackupsThroughASymlink(t *testing.T) {
	r := revertRig(t, "")
	elsewhere := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(r.dir, Backups)); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"0.8.0-20261020-000000.tar.gz", "0.8.1-20261025-000000.tar.gz"} {
		os.WriteFile(filepath.Join(elsewhere, n), nil, 0o660)
	}
	sp := r.spec()
	sp.Snapshot = "tok"
	rep, err, _, errs := r.runAt(sp, at10, "")
	if err != nil || rep.Backup != "backups/0.9.0-20261102-100000.tar.gz" {
		t.Fatalf("%v %+v\n%s", err, rep, errs)
	}
	if index(r.calls(), "hook backup dir="+r.dir+"/backups/0.9.0-20261102-100000 ") < 0 {
		t.Fatalf("calls %v", r.calls())
	}
	es, _ := os.ReadDir(elsewhere)
	var names []string
	for _, e := range es {
		names = append(names, e.Name())
	}
	if strings.Join(names, " ") != "0.8.1-20261025-000000.tar.gz 0.9.0-20261102-100000.tar.gz" {
		t.Fatalf("the link's directory holds %v\n%s", names, errs)
	}
	if got := readTar(t, filepath.Join(elsewhere, "0.9.0-20261102-100000.tar.gz")); got[SnapDir+"/.env"] != "A=old\n" || got["db.sql"] != "dump\n" {
		t.Fatalf("tarball %v", got)
	}
	if fi, err := os.Lstat(filepath.Join(r.dir, Backups)); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("backups/ is no longer the link: %v %v", fi, err)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Fatal("the snapshot is still in the project")
	}
}

// Across filesystems the snapshot's copies are copied, modes kept, then
// removed from the project.
func TestBackupAcrossFilesystems(t *testing.T) {
	r := revertRig(t, "")
	conf := filepath.Join(r.dir, "conf")
	os.MkdirAll(filepath.Join(conf, "ro"), 0o755)
	os.WriteFile(filepath.Join(conf, "ro", "a"), []byte("a\n"), 0o640)
	os.Chmod(filepath.Join(conf, "ro"), 0o555)
	defer os.Chmod(filepath.Join(conf, "ro"), 0o755)
	var o, e bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok2", []string{".env", "compose.yml", "conf"}, &o, &e); rc != 0 {
		t.Fatalf("snapshot: %s", e.String())
	}
	n := 0
	defer func(f func(*os.Root, string, *os.Root, string) error) { renameAt = f }(renameAt)
	renameAt = func(_ *os.Root, src string, _ *os.Root, dst string) error {
		n++
		return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EXDEV}
	}
	sp := r.spec()
	sp.Snapshot = "tok2"
	rep, err, _, errs := r.runAt(sp, at10, "")
	if err != nil || rep.Backup != "backups/0.9.0-20261102-100000.tar.gz" || n != 3 {
		t.Fatalf("%v %+v (%d renames)\n%s", err, rep, n, errs)
	}
	hs, files := tarball(t, filepath.Join(r.dir, rep.Backup))
	if h := hs[SnapDir+"/conf/ro/"]; h == nil || h.Mode != 0o555 || files[SnapDir+"/conf/ro/a"] != "a\n" || hs[SnapDir+"/conf/ro/a"].Mode != 0o640 {
		t.Fatalf("conf/ro: %+v %v", h, files)
	}
	if h := hs[SnapDir+"/.env"]; h == nil || h.Mode != 0o600 || files[SnapDir+"/.env"] != "A=old\n" {
		t.Fatalf(".env: %+v %v", h, files)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Fatal("the copied snapshot is still in the project")
	}
	if b := r.backups(); len(b) != 1 {
		t.Fatalf("backups/ holds %v", b)
	}
}

// A snapshot that cannot be moved into the backup directory is set aside
// whole where no run reads it, never dropped: across filesystems no original
// goes before every copy is whole, and a failed rename keeps what is left.
func TestBackupMoveFailureKeepsTheSnapshotAside(t *testing.T) {
	enospc := &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC}
	defer func(f, g func(*os.Root, string, *os.Root, string) error) { renameAt, copyAcross = f, g }(renameAt, copyAcross)
	real, realCopy := renameAt, copyAcross
	for _, across := range []bool{true, false} {
		r := revertRig(t, "")
		n := 0
		renameAt = func(from *os.Root, src string, to *os.Root, dst string) error {
			if across {
				return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EXDEV}
			}
			if n++; n == 2 {
				return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EACCES}
			}
			return real(from, src, to, dst)
		}
		copyAcross = func(from *os.Root, src string, to *os.Root, dst string) error {
			if n++; n == 2 {
				to.WriteFile(dst, []byte("ha"), 0o600)
				return enospc
			}
			return realCopy(from, src, to, dst)
		}
		sp := r.spec()
		sp.Snapshot = "tok"
		rep, err, _, errs := r.runAt(sp, at10, "")
		if err != nil || rep.Backup != "no-backup" {
			t.Fatalf("across %v: %v %+v\n%s", across, err, rep, errs)
		}
		kept := filepath.Join(r.dir, KeptPrefix+"0.9.0-20261102-100000")
		bdir := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000")
		rest := map[bool]string{true: "kept for the operator, holds the copies made so far, the last perhaps partial; the whole snapshot", false: "kept for the operator, holds the copies moved so far; the rest of the snapshot"}[across]
		if !strings.Contains(errs, "could not move the snapshot into the backup directory "+bdir) || !strings.Contains(errs, rest+" is kept in "+kept+" for the operator") {
			t.Fatalf("across %v: narration %s", across, errs)
		}
		if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
			t.Fatalf("across %v: a snapshot is left for the next run to merge", across)
		}
		if !strings.Contains(r.logText(), " deploy 1.0.0 no-backup ") {
			t.Fatalf("across %v: versions.log %q", across, r.logText())
		}
		want := map[string]string{".env": "A=old\n", "compose.yml": "v0.9.0\n"}
		for p, v := range want {
			b, err := os.ReadFile(filepath.Join(kept, "tok", p))
			if !across && err != nil {
				b, err = os.ReadFile(filepath.Join(bdir, SnapDir, p))
			}
			if err != nil || string(b) != v {
				t.Errorf("across %v: %s is %q (%v)", across, p, b, err)
			}
		}
		// The next run neither merges nor removes it.
		var o, e bytes.Buffer
		if rc := takeSnapshot(r.dir, "tok3", []string{".env"}, &o, &e); rc != 0 || strings.Contains(e.String(), "kept") {
			t.Fatalf("across %v: next snapshot: %d %s", across, rc, e.String())
		}
		if b, _ := os.ReadFile(filepath.Join(kept, "tok", ".env")); across && string(b) != "A=old\n" {
			t.Fatalf("across %v: the next snapshot touched the kept one", across)
		}
	}
}

// A backups/ that is not a directory, or links to nothing, stops the run
// before the backup hooks: the files it shipped go back.
func TestBackupsMustBeADirectory(t *testing.T) {
	for name, tc := range map[string]struct {
		make func(at string)
		want string
	}{
		"a file":          {func(at string) { os.WriteFile(at, []byte("x"), 0o644) }, "/backups is not a directory — make it one, or a link to one"},
		"a dangling link": {func(at string) { os.Symlink("/nonexistent/kasbah-backups", at) }, "/backups is a symlink to nothing"},
	} {
		t.Run(name, func(t *testing.T) {
			r := revertRig(t, "")
			tc.make(filepath.Join(r.dir, Backups))
			sp := r.spec()
			sp.Snapshot = "tok"
			rc, out, errs := r.run(sp)
			if f := ParseFailure(out); rc != 1 || f == nil || f.Outcome != Restored || !strings.Contains(errs, tc.want) {
				t.Fatalf("rc %d %q\n%s", rc, out, errs)
			}
			if index(r.calls(), "hook ") >= 0 || index(r.calls(), "tag ") >= 0 {
				t.Fatalf("calls %v", r.calls())
			}
			r.restored(t)
		})
	}
}

// The backup is named after the version live at the run's start.
func TestBackupNamesTheLiveVersion(t *testing.T) {
	const ok08 = "2026-09-01T00:00:00+00:00 deploy 0.8.0 no-backup kasbah=0.1.0 digest=-\n"
	failed := func(reason string) string {
		return "2026-10-01T00:00:00+00:00 deploy-failed 0.9.0 no-backup kasbah=0.1.0 digest=- by=al reason=" + reason + "\n"
	}
	for name, tc := range map[string]struct{ log, want string }{
		"after a success":        {ok08, "0.8.0"},
		"after a post-hook fail": {ok08 + failed("post-hook"), "0.9.0"},
		"after a failed revert":  {ok08 + failed("revert"), "0.8.0"},
		"a failed revert alone":  {failed("revert"), "unknown"},
		"after a damaged line":   {ok08 + "garbage\n", "unknown"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRig(t)
			os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(tc.log), 0o640)
			r.running("demo-web=running")
			rep, err, _, errs := r.runAt(r.spec(), at10, "")
			if err != nil || rep.Backup != "backups/"+tc.want+"-20261102-100000.tar.gz" {
				t.Fatalf("%v %+v\n%s", err, rep, errs)
			}
		})
	}
}

// A run stopped on a snapshot that is not its own keeps the backup directory,
// and names it.
func TestForeignSnapshotNamesTheBackupDir(t *testing.T) {
	r := revertRig(t, "")
	sp := r.revertSpec()
	sp.Snapshot, sp.Pre, sp.OnHookFailure = "another-run", []string{"exit 1"}, AnswerStop
	_, err, _, errs := r.runAt(sp, at10, "")
	left := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000")
	if err == nil || !strings.Contains(err.Error(), "beside the running stack. The backup directory "+left+" is kept for the operator") {
		t.Fatalf("%v\n%s", err, errs)
	}
	if fi, err := os.Stat(left); err != nil || !fi.IsDir() {
		t.Fatalf("the backup directory named is not there: %v", err)
	}
}

// A restore that fails keeps the backup directory beside the snapshot, and
// names it.
func TestFailedRestoreNamesTheBackupDir(t *testing.T) {
	r := revertRig(t, "")
	// A directory where the replaced .env is staged: the restore cannot keep it.
	os.MkdirAll(filepath.Join(r.dir, Replaced+".part", "x"), 0o755)
	sp := r.revertSpec()
	sp.Pre, sp.OnHookFailure = []string{"exit 1"}, AnswerStop
	_, err, _, errs := r.runAt(sp, at10, "")
	left := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000")
	if err == nil || !strings.Contains(err.Error(), "putting back the files it had shipped failed") || !strings.HasSuffix(err.Error(), "The backup directory "+left+" is kept for the operator") {
		t.Fatalf("%v\n%s", err, errs)
	}
	if _, err := os.Stat(left); err != nil {
		t.Fatal(err)
	}
}

// Every deploy hook of a deploy that is not a first sees the backup
// directory; one that could not be created is the hook-failure question, and
// carried past it, the hooks see none.
func TestBackupDirInEveryDeployHook(t *testing.T) {
	hook := func(what string) string {
		return `echo "` + what + ` dir=$KASBAH_BACKUP_DIR" >> "$LOG"; [ "$KASBAH_BACKUP_DIR" = none ] || test -d "$KASBAH_BACKUP_DIR"`
	}
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot, sp.Pre, sp.Post = "tok", []string{hook("pre")}, []string{hook("post")}
	rep, err, _, errs := r.runAt(sp, at10, "")
	want := " dir=" + r.dir + "/backups/0.9.0-20261102-100000"
	if err != nil || index(r.calls(), "pre"+want) < 0 || index(r.calls(), "post"+want) < 0 || rep.Backup != "backups/0.9.0-20261102-100000.tar.gz" {
		t.Fatalf("%v %+v\n%s\n%v", err, rep, errs, r.calls())
	}

	r = revertRig(t, "")
	os.MkdirAll(filepath.Join(r.dir, Backups, "0.9.0-20261102-100000"), 0o755)
	sp.Snapshot = "tok"
	rep, err, out, errs := r.runAt(sp, at10, AnswerContinue+"\n")
	if err != nil || !strings.Contains(out, `{"`+QuestionKey+`":1,"step":"backup","error":"could not create the backup directory `) {
		t.Fatalf("%v %q\n%s", err, out, errs)
	}
	if index(r.calls(), "hook backup") >= 0 || index(r.calls(), "pre dir=none") < 0 || index(r.calls(), "post dir=none") < 0 {
		t.Fatalf("calls %v", r.calls())
	}
	if len(rep.Continued) != 1 || rep.Continued[0] != "backup" || rep.Backup != "no-backup" || !strings.Contains(errs, "no backup of 0.9.0 is kept") {
		t.Fatalf("%+v\n%s", rep, errs)
	}
	// The snapshot goes aside whole, manifest and all, and is named.
	kept := filepath.Join(r.dir, KeptPrefix+"0.9.0-20261102-100000")
	b, err := os.ReadFile(filepath.Join(kept, "tok", ".env"))
	if _, merr := os.Lstat(filepath.Join(kept, "snapshot.json")); err != nil || merr != nil || string(b) != "A=old\n" || !strings.Contains(errs, "; its snapshot is kept in "+kept+" for the operator") {
		t.Fatalf("set aside: %q %v %v\n%s", b, err, merr, errs)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Fatal("a snapshot is left for the next run to merge")
	}
}

// A snapshot that cannot be set aside loses its manifest, or failing that is
// removed whole: the next run neither merges it nor fails on it.
func TestKeepAsideFallback(t *testing.T) {
	defer func(f func(*os.Root) error) { dropManifest = f }(dropManifest)
	real := dropManifest
	for _, stuck := range []bool{false, true} {
		r := revertRig(t, "")
		// A directory with something in it: the rename aside cannot replace it.
		os.MkdirAll(filepath.Join(r.dir, KeptPrefix+"x", "in"), 0o755)
		dropManifest = real
		if stuck {
			dropManifest = func(*os.Root) error {
				return &os.PathError{Op: "remove", Path: snapManifest, Err: syscall.EIO}
			}
		}
		e := &engine{dir: r.dir, stderr: io.Discard}
		clause := e.keepAside("x", "its snapshot")
		prev := filepath.Join(r.dir, PrevDir)
		_, perr := os.Lstat(prev)
		_, merr := os.Lstat(filepath.Join(r.dir, snapManifest))
		if !stuck && (perr != nil || merr == nil || !strings.Contains(clause, "; its snapshot could not be moved aside to "+r.dir+"/"+KeptPrefix+"x (") || !strings.HasSuffix(clause, "and is left in "+prev+" without its manifest, for the next run to remove")) {
			t.Fatalf("manifest: %v %v %q", perr, merr, clause)
		}
		if stuck && (perr == nil || !strings.HasSuffix(clause, "nor its manifest removed (remove "+snapManifest+": input/output error), so "+prev+" is removed, and those copies with it")) {
			t.Fatalf("whole: %v %q", perr, clause)
		}
		var o, eb bytes.Buffer
		if rc := takeSnapshot(r.dir, "tok2", []string{".env"}, &o, &eb); rc != 0 || o.String() != "snapshot=written\n" || eb.Len() != 0 {
			t.Fatalf("stuck %v: next snapshot: %d %q %s", stuck, rc, o.String(), eb.String())
		}
		var snap snapshot
		b, _ := os.ReadFile(filepath.Join(r.dir, snapManifest))
		_, terr := os.Lstat(filepath.Join(prev, "tok"))
		if json.Unmarshal(b, &snap) != nil || snap.Token != "tok2" || len(snap.Targets) != 1 || terr == nil {
			t.Fatalf("stuck %v: the next snapshot merged the old one: %s (old copies: %v)", stuck, b, terr)
		}
	}
}

// HooksFile is rewritten only when it changes, keeps shell readable, and
// leaves a non-regular file alone; a failed write is said.
func TestWriteHooks(t *testing.T) {
	dir := t.TempDir()
	at := filepath.Join(dir, HooksFile)
	var errb bytes.Buffer
	e := &engine{dir: dir, sp: Spec{Version: "1.0.0", Backup: []string{`pg_dump > "$KASBAH_BACKUP_DIR/db.sql"`}}, stderr: &errb}
	e.writeHooks()
	if b, _ := os.ReadFile(at); string(b) != `{"backup":["pg_dump > \"$KASBAH_BACKUP_DIR/db.sql\""],"restore":[],"targets":[]}`+"\n" {
		t.Fatalf("%s", b)
	}
	old := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	os.Chtimes(at, old, old)
	e.writeHooks()
	if fi, _ := os.Stat(at); !fi.ModTime().Equal(old) {
		t.Fatal("an unchanged hooks file was rewritten")
	}
	e.sp.Restore = []string{"psql"}
	e.writeHooks()
	if fi, _ := os.Stat(at); fi.ModTime().Equal(old) {
		t.Fatal("a changed hooks file was not rewritten")
	}

	os.Remove(at)
	os.Mkdir(at, 0o755)
	e.writeHooks()
	if fi, err := os.Lstat(at); err != nil || !fi.IsDir() || !strings.Contains(errb.String(), at+" exists and is not a regular file — left alone") {
		t.Fatalf("%v %v\n%s", fi, err, errb.String())
	}

	os.Remove(at)
	os.MkdirAll(fmt.Sprintf("%s.tmp.%d/x", at, os.Getpid()), 0o755)
	e.writeHooks()
	if _, err := os.Lstat(at); err == nil || !strings.Contains(errb.String(), "the server's record of 1.0.0's backup and restore hooks is not up to date") {
		t.Fatalf("%v\n%s", err, errb.String())
	}
}

func TestKeepSignalHelper(t *testing.T) {
	dir := os.Getenv("KASBAH_KEEP_DIR")
	if dir == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	signal := func() error {
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(200 * time.Millisecond)
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(10 * time.Second)
		return errors.New("no signal came")
	}
	// at=rename or at=copy signals on the move's second target, the first moved.
	n := 0
	real, realCopy := renameAt, copyAcross
	renameAt = func(from *os.Root, src string, to *os.Root, dst string) error {
		switch at := os.Getenv("KASBAH_KEEP_AT"); {
		case at == "copy":
			return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EXDEV}
		case at == "rename":
			if n++; n == 2 {
				return signal()
			}
		}
		return real(from, src, to, dst)
	}
	copyAcross = func(from *os.Root, src string, to *os.Root, dst string) error {
		if n++; n == 2 {
			to.WriteFile(dst, []byte("ha"), 0o600)
			return signal()
		}
		return realCopy(from, src, to, dst)
	}
	writeTar = func(root *os.Root, bdir, out string, _ map[string]fs.FileMode) error {
		root.WriteFile(out+".part", []byte("half"), 0o660)
		return signal()
	}
	// Through Remote, as on a server: its stderr wrapped by remote.Outlive.
	Remote([]string{"run", dir}, strings.NewReader(os.Getenv("KASBAH_KEEP_SPEC")+"\n"), io.Discard, os.Stderr)
	atexit.Exit(0)
}

// A signal that exits while the tarball is written removes its .part and
// keeps the backup directory, the outgoing .env's only copy.
func TestKeepCleansUpOnASignal(t *testing.T) {
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot = "tok"
	b, _ := json.Marshal(sp)
	cmd := exec.Command(os.Args[0], "-test.run=^TestKeepSignalHelper$")
	cmd.Env = append(os.Environ(), "KASBAH_KEEP_DIR="+r.dir, "KASBAH_KEEP_SPEC="+string(b))
	out, _ := cmd.CombinedOutput()
	if code := cmd.ProcessState.ExitCode(); code != 128+int(syscall.SIGTERM) || index(r.calls(), "hook post 1.0.0") < 0 {
		t.Fatalf("exit %d\n%s", code, out)
	}
	b = nil
	bs := r.backups()
	if len(bs) == 1 {
		b, _ = os.ReadFile(filepath.Join(r.dir, Backups, bs[0], SnapDir, ".env"))
	}
	if len(bs) != 1 || strings.HasSuffix(bs[0], ".part") || string(b) != "A=old\n" {
		t.Fatalf("backups/ holds %v, .env %q\n%s", bs, b, out)
	}
}

// A signal that exits while the snapshot moves renames what is left of it
// aside, never for the next run to drop, and keeps the backup directory with
// what was moved: every outgoing file is in one or the other.
func TestKeepSetsTheSnapshotAsideOnASignalMidMove(t *testing.T) {
	for _, at := range []string{"rename", "copy"} {
		r := revertRig(t, "")
		sp := r.spec()
		sp.Snapshot = "tok"
		b, _ := json.Marshal(sp)
		cmd := exec.Command(os.Args[0], "-test.run=^TestKeepSignalHelper$")
		cmd.Env = append(os.Environ(), "KASBAH_KEEP_DIR="+r.dir, "KASBAH_KEEP_SPEC="+string(b), "KASBAH_KEEP_AT="+at)
		out, _ := cmd.CombinedOutput()
		if code := cmd.ProcessState.ExitCode(); code != 128+int(syscall.SIGTERM) || index(r.calls(), "hook post 1.0.0") < 0 {
			t.Fatalf("%s: exit %d\n%s", at, code, out)
		}
		bs := r.backups()
		if len(bs) != 1 || strings.HasSuffix(bs[0], ".tar.gz") {
			t.Fatalf("%s: backups/ holds %v\n%s", at, bs, out)
		}
		if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
			t.Fatalf("%s: a snapshot is left for the next run to drop\n%s", at, out)
		}
		kept := filepath.Join(r.dir, KeptPrefix+bs[0], "tok")
		bdir := filepath.Join(r.dir, Backups, bs[0], SnapDir)
		rest := map[string]string{"copy": "the whole snapshot", "rename": "the rest of the snapshot"}[at]
		if !strings.Contains(string(out), "remote: a signal stopped the snapshot's move into the backup directory "+filepath.Join(r.dir, Backups, bs[0])+" — ") || !strings.Contains(string(out), "; "+rest+" is kept in "+filepath.Dir(kept)+" for the operator\n") {
			t.Errorf("%s: the kept directories are not named\n%s", at, out)
		}
		aside := 0
		for p, v := range map[string]string{".env": "A=old\n", "compose.yml": "v0.9.0\n"} {
			got, err := os.ReadFile(filepath.Join(kept, p))
			if err == nil {
				aside++
			} else if at == "rename" {
				got, err = os.ReadFile(filepath.Join(bdir, p))
			}
			if err != nil || string(got) != v {
				t.Errorf("%s: %s is %q (%v)\n%s", at, p, got, err, out)
			}
		}
		if want := map[string]int{"rename": 1, "copy": 2}[at]; aside != want {
			t.Errorf("%s: %d originals kept aside, want %d\n%s", at, aside, want, out)
		}
	}
}

// The line a signal's exit writes mid-move reaches stderr every time: it is
// written past the pipe os.Exit would cut short.
func TestKeepSignalLineArrives(t *testing.T) {
	for i := range 10 {
		r := revertRig(t, "")
		sp := r.spec()
		sp.Snapshot = "tok"
		b, _ := json.Marshal(sp)
		cmd := exec.Command(os.Args[0], "-test.run=^TestKeepSignalHelper$")
		cmd.Env = append(os.Environ(), "KASBAH_KEEP_DIR="+r.dir, "KASBAH_KEEP_SPEC="+string(b), "KASBAH_KEEP_AT=rename")
		out, _ := cmd.CombinedOutput()
		if !strings.Contains(string(out), "remote: a signal stopped the snapshot's move into the backup directory ") {
			t.Fatalf("run %d: no line\n%s", i, out)
		}
	}
}

// A move a signal's cleanup stopped before any copy starts none: the
// cleanup said every original was still in the snapshot.
func TestStoppedMoveStartsNoCopy(t *testing.T) {
	defer func(f, g func(*os.Root, string, *os.Root, string) error) { renameAt, copyAcross = f, g }(renameAt, copyAcross)
	r := revertRig(t, "")
	e := &engine{dir: r.dir, outgoing: "0.9.0", now: func() time.Time { return at10 }}
	if err := e.backupDir(); err != nil {
		t.Fatal(err)
	}
	defer e.broot.Close()
	renameAt = func(_ *os.Root, src string, _ *os.Root, dst string) error {
		return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EXDEV}
	}
	copied := 0
	copyAcross = func(*os.Root, string, *os.Root, string) error { copied++; return nil }
	e.move.Store(moveStopped)
	if err := e.moveSnapshot(); !errors.Is(err, errStopped) || copied != 0 {
		t.Fatalf("%v, %d copies", err, copied)
	}
}

// Across filesystems, a removal of the originals that fails once every copy
// is whole says so: the backup directory holds them all.
func TestBackupOriginalsRemovalFailure(t *testing.T) {
	defer func(f func(*os.Root, string, *os.Root, string) error, g func(*os.Root) error) {
		renameAt, removePrev = f, g
	}(renameAt, removePrev)
	renameAt = func(_ *os.Root, src string, _ *os.Root, dst string) error {
		return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: syscall.EXDEV}
	}
	removePrev = func(root *os.Root) error {
		root.Remove(PrevDir + "/tok/.env")
		return &os.PathError{Op: "unlinkat", Path: PrevDir + "/tok/compose.yml", Err: syscall.EIO}
	}
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot = "tok"
	rep, err, _, errs := r.runAt(sp, at10, "")
	kept := filepath.Join(r.dir, KeptPrefix+"0.9.0-20261102-100000")
	if err != nil || rep.Backup != "no-backup" || !strings.Contains(errs, "kept for the operator, holds every copy, whole; what is left of the snapshot's originals is kept in "+kept+" for the operator") {
		t.Fatalf("%v %+v\n%s", err, rep, errs)
	}
	bdir := filepath.Join(r.dir, Backups, "0.9.0-20261102-100000", SnapDir)
	for p, v := range map[string]string{".env": "A=old\n", "compose.yml": "v0.9.0\n"} {
		if b, err := os.ReadFile(filepath.Join(bdir, p)); err != nil || string(b) != v {
			t.Errorf("%s is %q (%v)", p, b, err)
		}
	}
}
