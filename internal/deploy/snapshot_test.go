package deploy

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
	for _, bad := range []string{"../x", PrevDir + "/a", "a//b", "/abs"} {
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
