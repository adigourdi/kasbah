package deploy

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/serverlock"
)

func TestSnapshotTargets(t *testing.T) {
	got := SnapshotTargets([]Entry{{Dst: "compose.yml"}, {Dst: "conf", Recurse: true}, {Dst: "conf/a.yml"}, {Dst: ".env"}, {Dst: "conf2"}})
	if want := []string{".env", "compose.yml", "conf", "conf2"}; !reflect.DeepEqual(got, want) {
		t.Errorf("%v", got)
	}
}

type snapState struct {
	mode  os.FileMode
	mtime time.Time
	body  string
}

func walkState(t *testing.T, dir string) map[string]snapState {
	t.Helper()
	m := map[string]snapState{}
	filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		rel, _ := filepath.Rel(dir, p)
		if rel == PrevDir {
			return filepath.SkipDir
		}
		if rel == ".deploy.lock" || rel == Replaced {
			return nil
		}
		st := snapState{mode: fi.Mode(), mtime: fi.ModTime()}
		switch {
		case fi.Mode()&os.ModeSymlink != 0:
			st.body, _ = os.Readlink(p)
		case fi.Mode().IsRegular():
			b, _ := os.ReadFile(p)
			st.body = string(b)
		}
		m[rel] = st
		return nil
	})
	return m
}

func TestSnapshotRestoreRoundTrip(t *testing.T) {
	root := t.TempDir()
	dir, outside := filepath.Join(root, "demo"), filepath.Join(root, "outside")
	os.MkdirAll(filepath.Join(dir, "conf", "sub"), 0o755)
	os.MkdirAll(outside, 0o755)
	os.WriteFile(filepath.Join(outside, "secret"), []byte("s\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "compose.yml"), []byte("old\n"), 0o640)
	os.WriteFile(filepath.Join(dir, ".env"), []byte("A=1\n"), 0o660)
	os.WriteFile(filepath.Join(dir, "conf", "a.yml"), []byte("a\n"), 0o600)
	os.WriteFile(filepath.Join(dir, "conf", "sub", "b"), []byte("b\n"), 0o755)
	os.Symlink("a.yml", filepath.Join(dir, "conf", "link"))
	// A target that is a symlink out of the project is kept as the link.
	os.Symlink(outside, filepath.Join(dir, "out"))
	old := time.Unix(1_600_000_000, 0)
	for _, p := range []string{"compose.yml", "conf/a.yml", "conf/sub/b", "conf/sub", "conf"} {
		os.Chtimes(filepath.Join(dir, p), old, old)
	}
	os.Chmod(filepath.Join(dir, "conf", "sub"), 0o750)
	before := walkState(t, dir)

	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{".env", "compose.yml", "conf", "new.txt", "out"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	// The run: changes, an added file in a synced directory, a new target, a removal.
	os.WriteFile(filepath.Join(dir, "compose.yml"), []byte("new\n"), 0o644)
	os.WriteFile(filepath.Join(dir, ".env"), []byte("A=2\n"), 0o660)
	os.WriteFile(filepath.Join(dir, "conf", "added"), []byte("x\n"), 0o644)
	os.Remove(filepath.Join(dir, "conf", "sub", "b"))
	os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644)
	os.Chmod(filepath.Join(dir, "conf"), 0o700)

	if _, err := restore(dir, "other"); err == nil || !strings.Contains(err.Error(), "holds no snapshot of this run") {
		t.Fatalf("a foreign token restored: %v", err)
	}
	if _, err := restore(dir, "tok"); err != nil {
		t.Fatal(err)
	}
	after := walkState(t, dir)
	for k, v := range before {
		if k == "." {
			continue
		}
		if a, ok := after[k]; !ok || a.mode != v.mode || a.body != v.body || (v.mode&os.ModeSymlink == 0 && !a.mtime.Equal(v.mtime)) {
			t.Errorf("%s: before %+v, after %+v", k, v, after[k])
		}
	}
	for k := range after {
		if _, ok := before[k]; !ok {
			t.Errorf("%s survived the restore", k)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(dir, Replaced)); string(b) != "A=2\n" {
		t.Errorf("the .env the restore replaced was not kept: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(outside, "secret")); string(b) != "s\n" {
		t.Error("outside the project changed")
	}
	if fi, err := os.Lstat(filepath.Join(dir, PrevDir, "tok", "out")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Error("the snapshot followed a symlink out of the project")
	}
}

func TestSnapshotRefusals(t *testing.T) {
	dir := t.TempDir()
	var out, errb bytes.Buffer
	for _, bad := range []string{"../x", PrevDir + "/a", KeptPrefix + "1.0.0-20261102-100000", "a//b", "/abs"} {
		if rc := takeSnapshot(dir, "tok", []string{bad}, &out, &errb); rc != 1 {
			t.Errorf("%q accepted", bad)
		}
	}
	out.Reset()
	if rc := takeSnapshot(filepath.Join(dir, "absent"), "tok", []string{".env"}, &out, &errb); rc != 0 || out.String() != "snapshot=none\n" {
		t.Errorf("absent project: rc %d %q", rc, out.String())
	}
	// A snapshot that cannot read a target leaves none behind.
	os.WriteFile(filepath.Join(dir, "locked"), []byte("x"), 0o000)
	if os.Getuid() != 0 {
		if rc := takeSnapshot(dir, "tok", []string{"locked"}, &out, &errb); rc != 1 || !strings.Contains(errb.String(), dir+"/locked: ") ||
			!strings.Contains(errb.String(), "may not read it (permission denied). A file a container wrote") || !strings.Contains(errb.String(), "nothing was changed") {
			t.Errorf("unreadable: rc %d %s", rc, errb.String())
		}
		if _, err := os.Lstat(filepath.Join(dir, PrevDir)); err == nil {
			t.Error("a failed snapshot left its directory")
		}
	}
}

func TestSnapshotTargetsByAncestry(t *testing.T) {
	got := SnapshotTargets([]Entry{{Dst: "site", Recurse: true}, {Dst: "site.json"}, {Dst: "site/x"}})
	if want := []string{".env", "site", "site.json"}; !reflect.DeepEqual(got, want) {
		t.Errorf("%v", got)
	}
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "site"), 0o755)
	os.WriteFile(filepath.Join(dir, "site", "x"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "site.json"), nil, 0o644)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", got, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
}

// A snapshot a failed run left is the live stack's files: the next one keeps
// them, copying from disk only what it lacks, under the new token.
func TestSnapshotKeepsTheLiveStacksFiles(t *testing.T) {
	dir := t.TempDir()
	w := func(p, s string) {
		os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755)
		os.WriteFile(filepath.Join(dir, p), []byte(s), 0o644)
	}
	read := func(p string) string { b, _ := os.ReadFile(filepath.Join(dir, p)); return string(b) }
	w("compose.yml", "live\n")
	w("site/x", "live\n")
	w(".env", "A=live\n")
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "one", []string{"compose.yml", "site/x"}, &out, &errb); rc != 0 {
		t.Fatal(errb.String())
	}
	// The run fails on the workstation after its sync; the next lists more.
	w("compose.yml", "failed\n")
	w("site/x", "failed\n")
	errb.Reset()
	if rc := takeSnapshot(dir, "two", []string{".env", "compose.yml", "site"}, &out, &errb); rc != 0 || !strings.Contains(errb.String(), "kept") {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	if _, err := os.Lstat(filepath.Join(dir, PrevDir, "one")); err != nil {
		t.Error("the kept copies were removed")
	}
	w("compose.yml", "next\n")
	w("site/x", "next\n")
	w(".env", "A=next\n")
	if _, err := restore(dir, "one"); err == nil {
		t.Error("the old token still restores")
	}
	if _, err := restore(dir, "two"); err != nil {
		t.Fatal(err)
	}
	if read("compose.yml") != "live\n" || read("site/x") != "live\n" || read(".env") != "A=live\n" {
		t.Errorf("restored %q %q %q", read("compose.yml"), read("site/x"), read(".env"))
	}
	// An unreadable manifest is no snapshot: the next one starts from disk.
	os.WriteFile(filepath.Join(dir, PrevDir, "snapshot.json"), []byte("{"), 0o664)
	if rc := takeSnapshot(dir, "three", []string{"compose.yml"}, &out, &errb); rc != 0 {
		t.Fatal(errb.String())
	}
	if _, err := os.Lstat(filepath.Join(dir, PrevDir, "one")); err == nil {
		t.Error("a broken snapshot's copies survived")
	}
}

func TestSnapshotRefusesWhileARunHoldsTheLock(t *testing.T) {
	dir := t.TempDir()
	held, _, err := serverlock.Project(dir)
	if err != nil || held == nil {
		t.Fatal(err)
	}
	defer held.Close()
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{".env"}, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "holds "+dir+"/.deploy.lock") {
		t.Errorf("rc %d %s", rc, errb.String())
	}
}

// A directory without owner write is copied writable, so the snapshot can go,
// and put back with its own mode.
// A directory target is put back in place: a container's bind mount holds its
// inode, and must see the old contents through it.
func TestSnapshotRestoresADirectoryInPlace(t *testing.T) {
	dir := t.TempDir()
	st := filepath.Join(dir, "state")
	os.MkdirAll(filepath.Join(st, "sub"), 0o755)
	os.MkdirAll(filepath.Join(st, "was-dir"), 0o755)
	os.WriteFile(filepath.Join(st, "a"), []byte("old a\n"), 0o644)
	os.WriteFile(filepath.Join(st, "sub", "b"), []byte("old b\n"), 0o600)
	os.WriteFile(filepath.Join(st, "was-file"), []byte("f\n"), 0o644)
	os.WriteFile(filepath.Join(st, "was-dir", "x"), []byte("x\n"), 0o644)
	ino := func(p string) uint64 {
		fi, err := os.Stat(p)
		if err != nil {
			return 0
		}
		return fi.Sys().(*syscall.Stat_t).Ino
	}
	before, beforeSub := ino(st), ino(filepath.Join(st, "sub"))
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{"state"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	// The run, and a mount: an open handle on the directory.
	held, err := os.Open(st)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	os.WriteFile(filepath.Join(st, "a"), []byte("new a\n"), 0o644)
	os.WriteFile(filepath.Join(st, "added"), []byte("n\n"), 0o644)
	os.Remove(filepath.Join(st, "sub", "b"))
	os.Remove(filepath.Join(st, "was-file"))
	os.MkdirAll(filepath.Join(st, "was-file"), 0o755)
	os.RemoveAll(filepath.Join(st, "was-dir"))
	os.WriteFile(filepath.Join(st, "was-dir"), []byte("now a file\n"), 0o644)

	if _, err := restore(dir, "tok"); err != nil {
		t.Fatal(err)
	}
	if ino(st) != before || ino(filepath.Join(st, "sub")) != beforeSub {
		t.Fatalf("the directory was replaced: inode %d -> %d, sub %d -> %d", before, ino(st), beforeSub, ino(filepath.Join(st, "sub")))
	}
	names, _ := held.Readdirnames(-1)
	sort.Strings(names)
	if got := strings.Join(names, ","); got != "a,sub,was-dir,was-file" {
		t.Errorf("through the held handle: %s", got)
	}
	for p, want := range map[string]string{"a": "old a\n", "sub/b": "old b\n", "was-file": "f\n", "was-dir/x": "x\n"} {
		if b, _ := os.ReadFile(filepath.Join(st, p)); string(b) != want {
			t.Errorf("%s holds %q", p, b)
		}
	}
	if fi, _ := os.Stat(filepath.Join(st, "sub", "b")); fi.Mode().Perm() != 0o600 {
		t.Errorf("sub/b is %v", fi.Mode())
	}
}

func TestSnapshotReadOnlyDirectory(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "ro"), 0o755)
	os.WriteFile(filepath.Join(dir, "ro", "f"), []byte("x"), 0o644)
	os.Chmod(filepath.Join(dir, "ro"), 0o555)
	defer os.Chmod(filepath.Join(dir, "ro"), 0o755)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{"ro"}, &out, &errb); rc != 0 {
		t.Fatal(errb.String())
	}
	if fi, _ := os.Stat(filepath.Join(dir, PrevDir, "tok", "ro")); fi.Mode().Perm() != 0o755 {
		t.Errorf("the copy is %v", fi.Mode())
	}
	if _, err := restore(dir, "tok"); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "ro")); fi.Mode().Perm() != 0o555 {
		t.Errorf("restored as %v", fi.Mode())
	}
	dropSnapshot(dir)
	if _, err := os.Lstat(filepath.Join(dir, PrevDir)); err == nil {
		t.Error("the snapshot could not be removed")
	}
}

// A manifest whose copies are gone — a drop cut short — is no snapshot.
func TestSnapshotWithMissingCopiesIsNone(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "compose.yml"), []byte("live\n"), 0o644)
	os.WriteFile(filepath.Join(dir, ".env"), []byte("A=1\n"), 0o660)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "one", []string{".env", "compose.yml"}, &out, &errb); rc != 0 {
		t.Fatal(errb.String())
	}
	os.Remove(filepath.Join(dir, PrevDir, "one", "compose.yml"))
	if _, err := restore(dir, "one"); !errors.Is(err, errForeign) {
		t.Errorf("a half-dropped snapshot restored: %v", err)
	}
	os.WriteFile(filepath.Join(dir, "compose.yml"), []byte("now\n"), 0o644)
	errb.Reset()
	if rc := takeSnapshot(dir, "two", []string{".env", "compose.yml"}, &out, &errb); rc != 0 || strings.Contains(errb.String(), "kept") {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	if b, _ := os.ReadFile(filepath.Join(dir, PrevDir, "two", "compose.yml")); string(b) != "now\n" {
		t.Errorf("the fresh snapshot holds %q", b)
	}
}

// The ids a revert goes back to are the ones the live stack started from,
// recorded by the first run and kept with a kept snapshot.
func TestSnapshotPinsTheLiveStacksIDs(t *testing.T) {
	dir := t.TempDir()
	var out, errb bytes.Buffer
	takeSnapshot(dir, "one", []string{".env"}, &out, &errb)
	imgs := []string{"web", "new"}
	if got := pinIDs(dir, "one", imgs, map[string]string{"web": "v1"}, io.Discard); !reflect.DeepEqual(got, map[string]string{"web": "v1"}) {
		t.Errorf("first pin %v", got)
	}
	if got := pinIDs(dir, "one", imgs, map[string]string{"web": "v2", "new": "v2n"}, io.Discard); !reflect.DeepEqual(got, map[string]string{"web": "v1"}) {
		t.Errorf("second pin %v", got)
	}
	takeSnapshot(dir, "two", []string{".env"}, &out, &errb)
	if got := pinIDs(dir, "two", append(imgs, "third"), map[string]string{"web": "v3", "third": "t3"}, io.Discard); !reflect.DeepEqual(got, map[string]string{"web": "v1", "third": "t3"}) {
		t.Errorf("kept snapshot pin %v", got)
	}
	if got := pinIDs(dir, "other", imgs, map[string]string{"web": "v9"}, io.Discard); got["web"] != "v9" {
		t.Errorf("a foreign token pinned %v", got)
	}
}

// stateDir is a project with a synced state/ snapshotted under "tok": a, b,
// cache/c and a read-only ro/ holding r, every mtime fixed.
func stateDir(t *testing.T) (dir, st string) {
	t.Helper()
	dir = t.TempDir()
	st = filepath.Join(dir, "state")
	os.MkdirAll(filepath.Join(st, "cache"), 0o755)
	os.MkdirAll(filepath.Join(st, "ro"), 0o755)
	for p, b := range map[string]string{"a": "a\n", "b": "b\n", "cache/c": "c\n", "ro/r": "r\n"} {
		os.WriteFile(filepath.Join(st, p), []byte(b), 0o644)
	}
	old := time.Unix(1_600_000_000, 0)
	for _, p := range []string{"a", "b", "cache/c", "ro/r", "cache", "ro", "."} {
		os.Chtimes(filepath.Join(st, p), old, old)
	}
	os.Chmod(filepath.Join(st, "ro"), 0o555)
	t.Cleanup(func() { os.Chmod(filepath.Join(st, "ro"), 0o755) })
	var out, errb bytes.Buffer
	if rc := takeSnapshot(dir, "tok", []string{"state"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot rc %d %s", rc, errb.String())
	}
	return dir, st
}

func inode(p string) uint64 {
	fi, err := os.Lstat(p)
	if err != nil {
		return 0
	}
	return fi.Sys().(*syscall.Stat_t).Ino
}

// faults fails each operation under prefix with errno, logging every one.
func faults(t *testing.T, prefix string, errno error, ops ...string) *[]string {
	var log []string
	restoreFault = func(op, p string) error {
		log = append(log, op+" "+p)
		if strings.HasPrefix(p, prefix) && (len(ops) == 0 || slicesContains(ops, op)) {
			return &os.PathError{Op: op, Path: p, Err: errno}
		}
		return nil
	}
	t.Cleanup(func() { restoreFault = nil })
	return &log
}

func slicesContains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// A directory a container owns that the run left as it was is not touched:
// the restore stays in place.
func TestRestoreLeavesAnUntouchedForeignDirectory(t *testing.T) {
	dir, st := stateDir(t)
	os.WriteFile(filepath.Join(st, "a"), []byte("new a\n"), 0o644)
	faults(t, "state/cache", syscall.EPERM)
	before := inode(st)
	res, err := restore(dir, "tok")
	if err != nil || inode(st) != before || len(res.Done) != 1 || len(res.Notes) != 0 {
		t.Fatalf("err %v, inode %d -> %d, %+v", err, before, inode(st), res)
	}
	if b, _ := os.ReadFile(filepath.Join(st, "a")); string(b) != "a\n" {
		t.Errorf("a holds %q", b)
	}
}

// One the run changed blocks the reconcile: the target is swapped whole, and
// the restore says the running container's mount sees the old directory.
func TestRestoreFallsBackToASwap(t *testing.T) {
	dir, st := stateDir(t)
	os.WriteFile(filepath.Join(st, "cache", "c"), []byte("new c\n"), 0o644)
	faults(t, "state/cache", syscall.EACCES)
	before := inode(st)
	res, err := restore(dir, "tok")
	if err != nil || len(res.Done) != 1 || len(res.Partial) != 0 {
		t.Fatalf("err %v, %+v", err, res)
	}
	if len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "state could not be put back in place") || !strings.Contains(res.Notes[0], "the running container's mount still sees "+dir+"/.kasbah-aside.") || !strings.Contains(res.Notes[0], ", kept; remove it once that container is recreated") {
		t.Errorf("notes %q", res.Notes)
	}
	// The aside is the inode a container may hold: kept, with the run's files.
	asides, _ := filepath.Glob(filepath.Join(dir, ".kasbah-aside.*"))
	for _, a := range asides {
		t.Cleanup(func() { os.Chmod(filepath.Join(a, "ro"), 0o755) })
	}
	if len(asides) != 1 || inode(asides[0]) != before {
		t.Errorf("asides %v (inode %d, want %d)", asides, inode(asides[0]), before)
	} else if b, _ := os.ReadFile(filepath.Join(asides[0], "cache", "c")); string(b) != "new c\n" {
		t.Errorf("the aside's cache/c holds %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(st, "cache", "c")); string(b) != "c\n" || inode(st) == before {
		t.Errorf("cache/c holds %q, inode %d -> %d", b, before, inode(st))
	}
}

// Every snapshot entry is back before anything the run added is removed.
func TestRestoreStagesBeforeDeleting(t *testing.T) {
	dir, st := stateDir(t)
	os.WriteFile(filepath.Join(st, "a"), []byte("new a\n"), 0o644)
	os.Remove(filepath.Join(st, "b"))
	os.WriteFile(filepath.Join(st, "added"), []byte("x\n"), 0o644)
	log := faults(t, "-", nil)
	if _, err := restore(dir, "tok"); err != nil {
		t.Fatal(err)
	}
	firstRemove, lastPut := -1, -1
	for i, l := range *log {
		switch {
		case strings.HasPrefix(l, "remove state/") && firstRemove < 0:
			firstRemove = i
		case strings.HasPrefix(l, "rename state/"):
			lastPut = i
		}
	}
	if firstRemove < 0 || lastPut < 0 || lastPut > firstRemove || !slicesContains(*log, "rename state/b") || !slicesContains(*log, "remove state/added") {
		t.Errorf("order:\n%s", strings.Join(*log, "\n"))
	}
}

// A reconcile cut short is part put back, and says so.
func TestRestoreReportsAPartialTarget(t *testing.T) {
	dir, st := stateDir(t)
	os.WriteFile(filepath.Join(st, "a"), []byte("new a\n"), 0o644)
	os.WriteFile(filepath.Join(st, "b"), []byte("new b\n"), 0o644)
	faults(t, "state/b", syscall.EIO, "rename")
	res, err := restore(dir, "tok")
	if err == nil || !strings.Contains(err.Error(), "could not put all of state back") || len(res.Done) != 0 || len(res.Partial) != 1 {
		t.Fatalf("err %v, %+v", err, res)
	}
	if w := res.what(); w != "partly put back: state" {
		t.Errorf("what %q", w)
	}
	if m := res.mixed("1.0.0", "1.1.0"); m != "state is part 1.0.0's, part 1.1.0's" {
		t.Errorf("mixed %q", m)
	}
	if m := res.mixed("", "1.1.0"); m != "state is part as it was before this run, part 1.1.0's" {
		t.Errorf("mixed with no previous version %q", m)
	}
	if b, _ := os.ReadFile(filepath.Join(st, "a")); string(b) != "a\n" {
		t.Errorf("a holds %q", b)
	}
}

// Directories get their mode back — a narrowed one's real mode from Dirs —
// and their mtime, in place; a mode the restore may not set is only noted.
func TestRestoreDirectoryModesInPlace(t *testing.T) {
	dir, st := stateDir(t)
	ro := filepath.Join(st, "ro")
	before := inode(ro)
	os.Chmod(ro, 0o755)
	os.WriteFile(filepath.Join(ro, "added"), []byte("x\n"), 0o644)
	if _, err := restore(dir, "tok"); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Lstat(ro)
	if fi.Mode().Perm() != 0o555 || !fi.ModTime().Equal(time.Unix(1_600_000_000, 0)) || inode(ro) != before {
		t.Errorf("ro is %v at %v, inode %d -> %d", fi.Mode(), fi.ModTime(), before, inode(ro))
	}
	if _, err := os.Lstat(filepath.Join(ro, "added")); err == nil {
		t.Error("ro/added survived")
	}

	// A read-only directory widened for a reconcile that then fails is narrowed back.
	dir, st = stateDir(t)
	ro = filepath.Join(st, "ro")
	os.Chmod(ro, 0o755)
	os.WriteFile(filepath.Join(ro, "r"), []byte("changed\n"), 0o644)
	os.Chmod(ro, 0o555)
	faults(t, "state/ro/r", syscall.EIO, "rename")
	if _, err := restore(dir, "tok"); err == nil {
		t.Fatal("a failed rename restored")
	}
	if fi, _ := os.Lstat(ro); fi.Mode().Perm() != 0o555 {
		t.Errorf("ro was left %v after a failed reconcile", fi.Mode())
	}
	restoreFault = nil

	dir, st = stateDir(t)
	os.Chmod(filepath.Join(st, "cache"), 0o700)
	os.WriteFile(filepath.Join(st, "a"), []byte("new a\n"), 0o644)
	faults(t, "state/cache", syscall.EPERM, "chmod", "chtimes")
	res, err := restore(dir, "tok")
	if err != nil || len(res.Done) != 1 || len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "state/cache is back, and kept its mode -rwx------ rather than -rwxr-xr-x") {
		t.Errorf("err %v, %+v", err, res)
	}
}

// A snapshot older than the last run versions.log records as live is that
// run's own, left behind: the next run refuses it, changing nothing. One a
// run that died on the workstation left after that entry still merges.
func TestSnapshotRefusesAStaleOne(t *testing.T) {
	defer func(f func() time.Time) { snapNow = f }(snapNow)
	t0 := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	entry := func(at time.Time, action, extra string) string {
		return at.Format("2006-01-02T15:04:05+00:00") + " " + action + " 1.0.0 no-backup kasbah=0.1.0 digest=-" + extra + "\n"
	}
	for name, tc := range map[string]struct {
		log     string
		noTaken bool
		refused bool
	}{
		"a later success":           {entry(t0.Add(5*time.Second), "deploy", ""), false, true},
		"a success the same second": {entry(t0, "deploy", ""), false, true},
		"a later rollback":          {entry(t0.Add(time.Minute), "rollback", ""), false, true},
		"a later post-hook failure": {entry(t0.Add(time.Minute), "deploy-failed", " by=al reason=post-hook"), false, true},
		"a later failed revert":     {entry(t0.Add(-time.Hour), "deploy", "") + entry(t0.Add(time.Minute), "deploy-failed", " by=al reason=revert"), false, false},
		"an earlier success":        {entry(t0.Add(-5*time.Second), "deploy", ""), false, false},
		"no field, an older mtime":  {entry(t0.Add(5*time.Second), "deploy", ""), true, true},
		"no field, a younger mtime": {entry(t0.Add(-5*time.Second), "deploy", ""), true, false},
		"no versions.log":           {"", false, false},
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			os.WriteFile(filepath.Join(dir, ".env"), []byte("A=live\n"), 0o644)
			snapNow = func() time.Time { return t0 }
			var out, errb bytes.Buffer
			if rc := takeSnapshot(dir, "one", []string{".env"}, &out, &errb); rc != 0 {
				t.Fatal(errb.String())
			}
			man := filepath.Join(dir, PrevDir, "snapshot.json")
			if tc.noTaken {
				b, _ := os.ReadFile(man)
				os.WriteFile(man, []byte(strings.Replace(string(b), `,"taken":"2026-11-02T10:00:00+00:00"`, "", 1)), 0o664)
				os.Chtimes(man, t0, t0)
			}
			if tc.log != "" {
				os.WriteFile(filepath.Join(dir, "versions.log"), []byte(tc.log), 0o664)
			}
			before, _ := os.ReadFile(man)
			snapNow = func() time.Time { return t0.Add(time.Hour) }
			errb.Reset()
			rc := takeSnapshot(dir, "two", []string{".env", "compose.yml"}, &out, &errb)
			after, _ := os.ReadFile(man)
			_, twoErr := os.Lstat(filepath.Join(dir, PrevDir, "two"))
			if tc.refused {
				want := "remote: snapshot: " + dir + "/" + PrevDir + " is older than the last run versions.log records as live"
				if rc != 1 || !strings.Contains(errb.String(), want) || !strings.Contains(errb.String(), "remove "+dir+"/"+PrevDir+" by hand") {
					t.Fatalf("rc %d %s", rc, errb.String())
				}
				if string(after) != string(before) || twoErr == nil {
					t.Fatalf("the refusal changed the snapshot: %s", after)
				}
				return
			}
			if rc != 0 || !strings.Contains(errb.String(), "kept "+dir+"/"+PrevDir) {
				t.Fatalf("rc %d %s", rc, errb.String())
			}
			if !strings.Contains(string(after), `"token":"two"`) || !strings.Contains(string(after), `"taken":"2026-11-02T11:00:00+00:00"`) {
				t.Fatalf("manifest %s", after)
			}
		})
	}
}
