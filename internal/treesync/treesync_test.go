package treesync

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
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

// The expectations below are rsync 3.2.7's, measured with `rsync -rlpt`,
// `-lpt` and `-pt --chmod=F644` on the same shapes; tests/integration/
// sync_parity_test.sh compares the two side by side on the rig.

type result struct {
	rep    Report
	err    error
	rc     int
	warn   string
	remote string
}

// transfer runs both halves in-process over two pipes.
func transfer(t *testing.T, src *Source, dest string) result {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	var remote, warn bytes.Buffer
	done := make(chan int)
	go func() {
		rc := newReceiver(src.Tree, &remote).run(dest, bufio.NewReader(inR), outW)
		outW.Close()
		inR.CloseWithError(io.ErrClosedPipe)
		done <- rc
	}()
	rep, err := src.Send(inW, outR, &warn)
	io.Copy(io.Discard, outR)
	return result{rep, err, <-done, warn.String(), remote.String()}
}

func dirSrc(t *testing.T, src string) *Source {
	t.Helper()
	var warn bytes.Buffer
	s, err := Dir(src, &warn)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func fileSrc(t *testing.T, src string) *Source {
	t.Helper()
	s, err := File(src, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func write(t *testing.T, p, body string, mode os.FileMode, mtime time.Time) {
	t.Helper()
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	if !mtime.IsZero() {
		os.Chtimes(p, mtime, mtime)
	}
}

func mkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func symlink(t *testing.T, target, p string, mtime time.Time) {
	t.Helper()
	if err := os.Symlink(target, p); err != nil {
		t.Fatal(err)
	}
	if !mtime.IsZero() {
		d, _ := os.Open(filepath.Dir(p))
		defer d.Close()
		if err := lutimes(d, filepath.Base(p), mtime.Unix(), int64(mtime.Nanosecond())); err != nil {
			t.Fatal(err)
		}
	}
}

func at(s string) time.Time {
	tm, err := time.Parse("2006-01-02 15:04:05.999999999", s)
	if err != nil {
		panic(err)
	}
	return tm
}

// snapshot is every entry under root: type, mode, exact mtime, and the
// content's sha256 or the link's target.
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	var walk func(rel string)
	walk = func(rel string) {
		p := filepath.Join(root, rel)
		fi, err := os.Lstat(p)
		if err != nil {
			t.Fatal(err)
		}
		mt := fi.ModTime().UnixNano()
		switch {
		case fi.IsDir():
			out[rel] = fmt.Sprintf("d %o %d", unixMode(fi.Mode()), mt)
			ents, err := os.ReadDir(p)
			if err != nil {
				t.Fatal(err)
			}
			for _, e := range ents {
				walk(filepath.Join(rel, e.Name()))
			}
		case fi.Mode()&os.ModeSymlink != 0:
			tg, _ := os.Readlink(p)
			out[rel] = fmt.Sprintf("l %d %q", mt, tg)
		case fi.Mode().IsRegular():
			b, _ := os.ReadFile(p)
			h := sha256.Sum256(b)
			out[rel] = fmt.Sprintf("f %o %d %s", unixMode(fi.Mode()), mt, hex.EncodeToString(h[:8]))
		default:
			out[rel] = "special"
		}
	}
	walk(".")
	return out
}

// asServer is a source snapshot as the receiver lays it down: directories
// get the group the owner's bits (dirMode).
func asServer(m map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range m {
		var mode uint32
		var mt int64
		if n, _ := fmt.Sscanf(v, "d %o %d", &mode, &mt); n == 2 {
			v = fmt.Sprintf("d %o %d", dirMode(mode, 0), mt)
		}
		out[k] = v
	}
	return out
}

func diff(a, b map[string]string) []string {
	var d []string
	for k, v := range a {
		if b[k] != v {
			d = append(d, fmt.Sprintf("%q: src %s, dest %s", k, v, b[k]))
		}
	}
	for k, v := range b {
		if _, ok := a[k]; !ok {
			d = append(d, fmt.Sprintf("%q: only in dest (%s)", k, v))
		}
	}
	sort.Strings(d)
	return d
}

func leftovers(t *testing.T, root string) []string {
	t.Helper()
	var got []string
	filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		if err == nil && strings.HasPrefix(filepath.Base(p), ".kasbah-sync.") {
			got = append(got, p)
		}
		return nil
	})
	return got
}

// corpus is every shape a sync: tree can hold.
func corpus(t *testing.T, s string) {
	t1, t2 := at("2021-01-01 00:00:00.5"), at("2019-05-05 05:05:05.25")
	write(t, s+"/plain", "plain\n", 0o644, t1)
	write(t, s+"/secret", "s\n", 0o600, t2)
	write(t, s+"/exec", "#!/bin/sh\n", 0o755, at("2020-02-02 02:02:02.123456789"))
	write(t, s+"/private", "p\n", 0o700, t1)
	write(t, s+"/suid", "u\n", 0o4755, t1)
	write(t, s+"/sgid", "g\n", 0o2755, t1)
	write(t, s+"/empty", "", 0o644, t2)
	write(t, s+"/sticky/f", "x\n", 0o644, t1)
	os.Chmod(s+"/sticky", 0o1777)
	write(t, s+"/ro/inner", "ro\n", 0o444, t2)
	os.Chmod(s+"/ro", 0o555)
	mkdir(t, s+"/emptydir")
	deep := s + "/a/b/c/d/e/f/g/h"
	write(t, deep+"/deep.txt", "deep\n", 0o644, t1)
	write(t, s+"/ünïcødé ✓/fichier é", "u\n", 0o644, t1)
	write(t, s+"/with space", "sp\n", 0o644, t1)
	write(t, s+"/new\nline", "nl\n", 0o644, t1)
	write(t, s+"/bad\xff\xfebytes", "nb\n", 0o644, t1)
	write(t, s+"/-leading-dash", "dash\n", 0o644, t1)
	write(t, s+"/"+strings.Repeat("n", 255), "long\n", 0o644, t1)
	long := s
	for i := range 12 {
		long += "/" + strings.Repeat(string(rune('a'+i)), 200)
	}
	write(t, long+"/f", "very long path\n", 0o644, t1)
	symlink(t, "/etc/passwd", s+"/abs", at("2020-01-02 03:04:05.123456789"))
	symlink(t, "plain", s+"/rel", at("2020-01-02 03:04:05.5"))
	symlink(t, "nowhere/at/all", s+"/dangling", t2)
	symlink(t, "../..", s+"/a/up", t2)
	if err := syscall.Mkfifo(s+"/fifo", 0o644); err != nil {
		t.Fatal(err)
	}
	// Directories last, deepest first: writing into them moved their mtimes,
	// and one left in this second would keep the copy's (TestDirMtimeSecond).
	var dirs []string
	filepath.WalkDir(s, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			dirs = append(dirs, p)
		}
		return nil
	})
	for i := len(dirs) - 1; i >= 0; i-- {
		os.Chtimes(dirs[i], t2, at("2018-03-03 03:03:03.75").Add(time.Duration(i)*time.Millisecond))
	}
}

// TestDirMtimeSecond: a directory's mtime is set when its whole second
// differs from the source's, exactly; within the same second it is kept, as
// rsync's modify-window comparison keeps it.
func TestDirMtimeSecond(t *testing.T) {
	dir := t.TempDir()
	mkdir(t, dir+"/src/same")
	mkdir(t, dir+"/src/other")
	mkdir(t, dir+"/dest/same")
	mkdir(t, dir+"/dest/other")
	os.Chtimes(dir+"/src/same", time.Time{}, at("2020-01-01 00:00:00.3"))
	os.Chtimes(dir+"/dest/same", time.Time{}, at("2020-01-01 00:00:00.8"))
	os.Chtimes(dir+"/src/other", time.Time{}, at("2020-01-01 00:00:00.3"))
	os.Chtimes(dir+"/dest/other", time.Time{}, at("2020-01-01 00:00:05.8"))
	if r := transfer(t, dirSrc(t, dir+"/src"), dir+"/dest"); r.rc != 0 {
		t.Fatalf("rc %d %s", r.rc, r.remote)
	}
	for n, want := range map[string]string{"same": "2020-01-01 00:00:00.8", "other": "2020-01-01 00:00:00.3"} {
		if fi, _ := os.Stat(dir + "/dest/" + n); !fi.ModTime().Equal(at(want)) {
			t.Errorf("%s: mtime %v, want %s", n, fi.ModTime(), want)
		}
	}
}

func TestTreeMatchesSource(t *testing.T) {
	dir := t.TempDir()
	src, dest := dir+"/src", dir+"/dest"
	mkdir(t, src)
	corpus(t, src)
	t.Cleanup(func() { os.Chmod(src+"/ro", 0o755); os.Chmod(dest+"/ro", 0o755) })
	r := transfer(t, dirSrc(t, src), dest)
	if r.err != nil || r.rc != 0 {
		t.Fatalf("sync failed: %v rc %d: %s", r.err, r.rc, r.remote)
	}
	want := asServer(snapshot(t, src))
	delete(want, "fifo")
	if d := diff(want, snapshot(t, dest)); len(d) > 0 {
		t.Errorf("dest differs from src:\n%s", strings.Join(d, "\n"))
	}
	if r.rep.Synced == 0 || r.rep.Failed != 0 {
		t.Errorf("report %+v", r.rep)
	}
	if fi, err := os.Lstat(dest + "/abs"); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Error("the link to /etc/passwd was followed, not copied")
	}
	// A rerun moves nothing and replaces nothing.
	var ino uint64
	if fi, err := os.Stat(dest + "/plain"); err == nil {
		ino = fi.Sys().(*syscall.Stat_t).Ino
	}
	r = transfer(t, dirSrc(t, src), dest)
	if r.rc != 0 || r.rep.Synced != 0 || r.rep.Unchanged == 0 {
		t.Errorf("an unchanged rerun reported %+v rc %d", r.rep, r.rc)
	}
	if fi, _ := os.Stat(dest + "/plain"); fi.Sys().(*syscall.Stat_t).Ino != ino {
		t.Error("an unchanged file was replaced")
	}
	if d := diff(want, snapshot(t, dest)); len(d) > 0 {
		t.Errorf("after a rerun:\n%s", strings.Join(d, "\n"))
	}
	if l := leftovers(t, dest); len(l) > 0 {
		t.Errorf("staging left behind: %v", l)
	}
}

func TestSkipsSpecialFiles(t *testing.T) {
	dir := t.TempDir()
	mkdir(t, dir+"/src")
	syscall.Mkfifo(dir+"/src/fifo", 0o644)
	var warn bytes.Buffer
	s, err := Dir(dir+"/src", &warn)
	if err != nil || len(s.Ents) != 1 {
		t.Fatalf("%v %v", s, err)
	}
	if got := warn.String(); got != "sync: skipping non-regular file \"fifo\"\n" {
		t.Errorf("warned %q", got)
	}
	warn.Reset()
	f, _ := File(dir+"/src/fifo", &warn)
	if len(f.Ents) != 0 || !strings.Contains(warn.String(), `skipping non-regular file "fifo"`) {
		t.Errorf("a fifo as the one file: %v, %q", f.Ents, warn.String())
	}
}

func TestDirMode(t *testing.T) {
	for _, c := range []struct {
		src  uint32
		cur  fs.FileMode
		want uint32
	}{{0o755, 0, 0o775}, {0o755, fs.ModeSetgid, 0o2775}, {0o700, fs.ModeSetgid | 0o770, 0o2770}, {0o555, 0, 0o555}} {
		if got := dirMode(c.src, c.cur); got != c.want {
			t.Errorf("dirMode(%o, %v) = %o, want %o", c.src, c.cur, got, c.want)
		}
	}
}

// TestOtherOperator: entries another user owns are never chmodded or
// re-timed — a current file whose mode differs is sent again and renamed
// over, a symlink re-made, a directory left as it is.
func TestOtherOperator(t *testing.T) {
	dir := t.TempDir()
	src, dest := dir+"/src", dir+"/dest"
	write(t, src+"/d/f", "AAAA\n", 0o644, at("2020-01-01 00:00:00"))
	os.Symlink("f", src+"/d/l")
	if r := transfer(t, dirSrc(t, src), dest); r.rc != 0 {
		t.Fatalf("rc %d: %s", r.rc, r.remote)
	}
	if fi, _ := os.Stat(dest + "/d"); fi.Mode().Perm() != 0o775 {
		t.Errorf("a received directory is %o, want the group given the owner's bits (775)", fi.Mode().Perm())
	}
	os.Chmod(src+"/d/f", 0o640)
	os.Chmod(src+"/d", 0o700)
	os.Chtimes(src+"/d", at("2021-01-01 00:00:00"), at("2021-01-01 00:00:00"))
	ino := func(p string) uint64 { fi, _ := os.Lstat(p); return fi.Sys().(*syscall.Stat_t).Ino }
	before, link := ino(dest+"/d/f"), ino(dest+"/d/l")
	lt := at("2022-01-01 00:00:00")
	if d, err := os.Open(src + "/d"); err == nil {
		lutimes(d, "l", lt.Unix(), 0)
		d.Close()
	}
	selfUID = func() int { return -1 }
	defer func() { selfUID = os.Getuid }()
	r := transfer(t, dirSrc(t, src), dest)
	if r.rc != 0 {
		t.Fatalf("rc %d: %s", r.rc, r.remote)
	}
	fi, _ := os.Stat(dest + "/d/f")
	if fi.Mode().Perm() != 0o640 || ino(dest+"/d/f") == before {
		t.Errorf("another's file: mode %o, renamed over %v — want 640 by a rename", fi.Mode().Perm(), ino(dest+"/d/f") != before)
	}
	if ino(dest+"/d/l") == link {
		t.Error("another's symlink with a new mtime was not re-made")
	}
	if fi, _ := os.Stat(dest + "/d"); fi.Mode().Perm() != 0o775 {
		t.Errorf("another's directory was chmodded to %o", fi.Mode().Perm())
	}
}

// TestQuickCheck is rsync's: size and the mtime's second decide, perms are
// corrected in place, and a sub-second difference alone is no difference.
func TestQuickCheck(t *testing.T) {
	dir := t.TempDir()
	src, dest := dir+"/src", dir+"/dest"
	write(t, src+"/same", "AAAA\n", 0o644, at("2020-01-01 00:00:00.1"))
	write(t, dest+"/same", "BBBB\n", 0o600, at("2020-01-01 00:00:00.9"))
	write(t, src+"/size", "AAAA\n", 0o644, at("2020-01-01 00:00:00.1"))
	write(t, dest+"/size", "AAAAA\n", 0o644, at("2020-01-01 00:00:00.1"))
	write(t, src+"/second", "AAAA\n", 0o644, at("2020-01-01 00:00:00.1"))
	write(t, dest+"/second", "AAAA\n", 0o644, at("2020-01-01 00:00:01.1"))
	ino := func(p string) uint64 { fi, _ := os.Stat(p); return fi.Sys().(*syscall.Stat_t).Ino }
	before := ino(dest + "/same")
	r := transfer(t, dirSrc(t, src), dest)
	if r.rc != 0 {
		t.Fatalf("rc %d: %s", r.rc, r.remote)
	}
	b, _ := os.ReadFile(dest + "/same")
	fi, _ := os.Stat(dest + "/same")
	if string(b) != "BBBB\n" || fi.Mode().Perm() != 0o644 || ino(dest+"/same") != before ||
		!fi.ModTime().Equal(at("2020-01-01 00:00:00.9")) {
		t.Errorf("same size and second: content %q mode %v mtime %v — want BBBB kept, 644 set, .9 kept", b, fi.Mode(), fi.ModTime())
	}
	for _, n := range []string{"size", "second"} {
		fi, _ := os.Stat(dest + "/" + n)
		if b, _ := os.ReadFile(dest + "/" + n); string(b) != "AAAA\n" || !fi.ModTime().Equal(at("2020-01-01 00:00:00.1")) {
			t.Errorf("%s: %q at %v, want the source's", n, b, fi.ModTime())
		}
	}
	if r.rep.Synced != 2 || r.rep.Unchanged != 1 {
		t.Errorf("report %+v, want 2 synced, 1 unchanged", r.rep)
	}
}

// TestTypeChanges is the matrix rsync -rlpt (no --force, no --delete) gives.
func TestTypeChanges(t *testing.T) {
	m := at("2020-01-01 00:00:00")
	for _, c := range []struct {
		name       string
		src, dest  func(t *testing.T, s string)
		ok         bool
		check      map[string]string // path → "d", "f:<content>", "l:<target>"
		remoteText string
	}{
		{"file becomes dir", func(t *testing.T, s string) { write(t, s+"/a/f", "1", 0o644, m) },
			func(t *testing.T, d string) { write(t, d+"/a", "old", 0o644, m) },
			true, map[string]string{"a": "d", "a/f": "f:1"}, ""},
		{"empty dir becomes file", func(t *testing.T, s string) { write(t, s+"/a", "1", 0o644, m) },
			func(t *testing.T, d string) { mkdir(t, d+"/a") },
			true, map[string]string{"a": "f:1"}, ""},
		{"non-empty dir refuses a file, the rest goes on", func(t *testing.T, s string) {
			write(t, s+"/a", "1", 0o644, m)
			write(t, s+"/b", "2", 0o644, m)
		}, func(t *testing.T, d string) { write(t, d+"/a/keep", "k", 0o644, m) },
			false, map[string]string{"a": "d", "a/keep": "f:k", "b": "f:2"}, "cannot delete non-empty directory: a"},
		{"non-empty dir refuses a symlink", func(t *testing.T, s string) { symlink(t, "t", s+"/a", m) },
			func(t *testing.T, d string) { write(t, d+"/a/keep", "k", 0o644, m) },
			false, map[string]string{"a/keep": "f:k"}, "could not make way for new symlink"},
		{"empty dir becomes symlink", func(t *testing.T, s string) { symlink(t, "t", s+"/a", m) },
			func(t *testing.T, d string) { mkdir(t, d+"/a") },
			true, map[string]string{"a": "l:t"}, ""},
		{"file becomes symlink", func(t *testing.T, s string) { symlink(t, "t", s+"/a", m) },
			func(t *testing.T, d string) { write(t, d+"/a", "old", 0o644, m) },
			true, map[string]string{"a": "l:t"}, ""},
		{"symlink becomes file", func(t *testing.T, s string) { write(t, s+"/a", "1", 0o644, m) },
			func(t *testing.T, d string) { symlink(t, "/etc/passwd", d+"/a", time.Time{}) },
			true, map[string]string{"a": "f:1"}, ""},
		{"symlink to a directory becomes a directory", func(t *testing.T, s string) { write(t, s+"/a/f", "1", 0o644, m) },
			func(t *testing.T, d string) { mkdir(t, d+"/../outside"); symlink(t, "../outside", d+"/a", time.Time{}) },
			true, map[string]string{"a": "d", "a/f": "f:1", "../outside": "d", "../outside/f": "absent"}, ""},
		{"fifo becomes dir", func(t *testing.T, s string) { write(t, s+"/a/f", "1", 0o644, m) },
			func(t *testing.T, d string) { syscall.Mkfifo(d+"/a", 0o644) },
			true, map[string]string{"a": "d", "a/f": "f:1"}, ""},
		{"fifo becomes file", func(t *testing.T, s string) { write(t, s+"/a", "1", 0o644, m) },
			func(t *testing.T, d string) { syscall.Mkfifo(d+"/a", 0o644) },
			true, map[string]string{"a": "f:1"}, ""},
		{"a file the source no longer has stays", func(t *testing.T, s string) { write(t, s+"/a/f", "1", 0o644, m) },
			func(t *testing.T, d string) { write(t, d+"/a/extra", "x", 0o644, m); write(t, d+"/top", "y", 0o644, m) },
			true, map[string]string{"a/f": "f:1", "a/extra": "f:x", "top": "f:y"}, ""},
		{"a file whose source turned fifo stays", func(t *testing.T, s string) { syscall.Mkfifo(s+"/a", 0o644) },
			func(t *testing.T, d string) { write(t, d+"/a", "old", 0o644, m) },
			true, map[string]string{"a": "f:old"}, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			src, dest := dir+"/src", dir+"/dest"
			mkdir(t, src)
			mkdir(t, dest)
			c.src(t, src)
			c.dest(t, dest)
			r := transfer(t, dirSrc(t, src), dest)
			if (r.rc == 0) != c.ok || (r.err == nil && r.rep.Failed == 0) != c.ok {
				t.Errorf("rc %d err %v report %+v, want ok=%v: %s", r.rc, r.err, r.rep, c.ok, r.remote)
			}
			if !strings.Contains(r.remote, c.remoteText) {
				t.Errorf("the server said %q, want %q", r.remote, c.remoteText)
			}
			for p, want := range c.check {
				fp := filepath.Join(dest, p)
				fi, err := os.Lstat(fp)
				got := "absent"
				switch {
				case err != nil:
				case fi.IsDir():
					got = "d"
				case fi.Mode()&os.ModeSymlink != 0:
					tg, _ := os.Readlink(fp)
					got = "l:" + tg
				default:
					b, _ := os.ReadFile(fp)
					got = "f:" + string(b)
				}
				if got != want {
					t.Errorf("%s is %s, want %s", p, got, want)
				}
			}
			if l := leftovers(t, dest); len(l) > 0 {
				t.Errorf("staging left behind: %v", l)
			}
		})
	}
}

// TestDestinationRoot is how rsync treats the destination it was given.
func TestDestinationRoot(t *testing.T) {
	dir := t.TempDir()
	mkdir(t, dir+"/src")
	write(t, dir+"/src/f", "1", 0o644, time.Time{})
	s := dirSrc(t, dir+"/src")

	write(t, dir+"/isfile", "x", 0o644, time.Time{})
	if r := transfer(t, s, dir+"/isfile"); r.rc == 0 || !strings.Contains(r.remote, "is not a directory") {
		t.Errorf("a file as the root: rc %d %q", r.rc, r.remote)
	}
	symlink(t, "/nonexistent/x", dir+"/dangling", time.Time{})
	if r := transfer(t, s, dir+"/dangling"); r.rc == 0 || !strings.Contains(r.remote, "symlink to nothing") {
		t.Errorf("a dangling symlink as the root: rc %d %q", r.rc, r.remote)
	}
	if r := transfer(t, s, dir+"/no/deeper"); r.rc == 0 || !strings.Contains(r.remote, "could not create") {
		t.Errorf("a root whose parent is missing: rc %d %q", r.rc, r.remote)
	}
	if r := transfer(t, s, dir+"/new"); r.rc != 0 {
		t.Errorf("a missing root is created: rc %d %q", r.rc, r.remote)
	}
	if b, _ := os.ReadFile(dir + "/new/f"); string(b) != "1" {
		t.Error("nothing landed in the created root")
	}
	mkdir(t, dir+"/real")
	symlink(t, "real", dir+"/linked", time.Time{})
	if r := transfer(t, s, dir+"/linked"); r.rc != 0 {
		t.Errorf("a root that is a symlink to a directory: rc %d %q", r.rc, r.remote)
	}
	if b, _ := os.ReadFile(dir + "/real/f"); string(b) != "1" {
		t.Error("a symlinked root is followed, as rsync follows it")
	}
	if r := transfer(t, s, "relative/x"); r.rc == 0 {
		t.Error("a relative destination was accepted")
	}
}

// TestFileDestination is `rsync -lpt src dst`.
func TestFileDestination(t *testing.T) {
	dir := t.TempDir()
	m := at("2021-06-06 06:06:06.66")
	write(t, dir+"/s/src", "new", 0o640, m)
	s := fileSrc(t, dir+"/s/src")
	read := func(p string) string { b, _ := os.ReadFile(p); return string(b) }

	if r := transfer(t, s, dir+"/d1"); r.rc != 0 || read(dir+"/d1") != "new" {
		t.Errorf("absent: rc %d %q", r.rc, r.remote)
	}
	if fi, _ := os.Stat(dir + "/d1"); fi.Mode().Perm() != 0o640 || !fi.ModTime().Equal(m) {
		t.Errorf("mode %v mtime %v, want the source's", fi.Mode(), fi.ModTime())
	}
	mkdir(t, dir+"/d2")
	if r := transfer(t, s, dir+"/d2"); r.rc != 0 || read(dir+"/d2/src") != "new" {
		t.Errorf("a directory: the file lands inside it under its own name (rc %d)", r.rc)
	}
	mkdir(t, dir+"/target")
	symlink(t, "target", dir+"/d3", time.Time{})
	if r := transfer(t, s, dir+"/d3"); r.rc != 0 || read(dir+"/target/src") != "new" {
		t.Errorf("a symlink to a directory is followed, as rsync stats the destination (rc %d)", r.rc)
	}
	write(t, dir+"/kept", "old", 0o644, time.Time{})
	symlink(t, "kept", dir+"/d4", time.Time{})
	if r := transfer(t, s, dir+"/d4"); r.rc != 0 || read(dir+"/d4") != "new" || read(dir+"/kept") != "old" {
		t.Errorf("a symlink to a file is replaced, its target untouched (rc %d)", r.rc)
	}
	if fi, _ := os.Lstat(dir + "/d4"); !fi.Mode().IsRegular() {
		t.Error("d4 is still a symlink")
	}
	if r := transfer(t, s, dir+"/missing/d5"); r.rc == 0 {
		t.Error("a missing parent was accepted — rsync does not create it")
	}
	write(t, dir+"/d6/src/keep", "k", 0o644, time.Time{})
	if r := transfer(t, s, dir+"/d6"); r.rc == 0 || !strings.Contains(r.remote, "cannot delete non-empty directory: src") {
		t.Errorf("a non-empty directory in the way: rc %d %q", r.rc, r.remote)
	}
	symlink(t, "../somewhere", dir+"/s/link", at("2020-01-01 00:00:00.5"))
	if r := transfer(t, fileSrc(t, dir+"/s/link"), dir+"/d1"); r.rc != 0 {
		t.Errorf("a symlink over a file: rc %d", r.rc)
	}
	if tg, _ := os.Readlink(dir + "/d1"); tg != "../somewhere" {
		t.Errorf("d1 links to %q", tg)
	}
	if fi, _ := os.Lstat(dir + "/d1"); !fi.ModTime().Equal(at("2020-01-01 00:00:00.5")) {
		t.Errorf("the link's own mtime is %v", fi.ModTime())
	}
}

// TestFixed is the fragment: mode forced, a symlinked source followed.
func TestFixed(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/real.yml", "http: {}\n", 0o600, at("2022-02-02 00:00:00.2"))
	symlink(t, "real.yml", dir+"/frag.yml", time.Time{})
	s, err := Fixed(dir+"/frag.yml", 0o644)
	if err != nil {
		t.Fatal(err)
	}
	write(t, dir+"/dyn/x.yml", "old\n", 0o600, time.Time{})
	if r := transfer(t, s, dir+"/dyn/x.yml"); r.rc != 0 {
		t.Fatalf("rc %d %q", r.rc, r.remote)
	}
	fi, _ := os.Lstat(dir + "/dyn/x.yml")
	b, _ := os.ReadFile(dir + "/dyn/x.yml")
	if !fi.Mode().IsRegular() || fi.Mode().Perm() != 0o644 || string(b) != "http: {}\n" || !fi.ModTime().Equal(at("2022-02-02 00:00:00.2")) {
		t.Errorf("got %v %q %v", fi.Mode(), b, fi.ModTime())
	}
}

// stream is a hand-built transfer of one file, for the integrity cases.
func stream(t *testing.T, body string, mutate func(frame []byte) []byte) []byte {
	var b bytes.Buffer
	w := newWriter(&b)
	writeManifest(w, []Entry{{Kind: kindFile, Path: "f", Mode: 0o644, Sec: 1, Size: int64(len(body))}})
	w.Flush()
	head := b.Len()
	w.uvarint(0)
	w.uvarint(uint64(len(body)))
	w.WriteString(body)
	w.uvarint(0)
	w.WriteByte(statusOK)
	w.uvarint(uint64(len(body)))
	h := sha256.Sum256([]byte(body))
	w.Write(h[:])
	w.WriteByte(endMark)
	w.Flush()
	out := b.Bytes()
	return append(out[:head:head], mutate(append([]byte{}, out[head:]...))...)
}

func TestIntegrity(t *testing.T) {
	for _, c := range []struct {
		name   string
		mutate func([]byte) []byte
		ok     bool
	}{
		{"intact", func(b []byte) []byte { return b }, true},
		{"a flipped byte", func(b []byte) []byte { b[3] ^= 0x20; return b }, false},
		{"cut in the content", func(b []byte) []byte { return b[:5] }, false},
		{"cut before the checksum", func(b []byte) []byte { return b[:len(b)-10] }, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			write(t, dir+"/f", "the old content", 0o644, time.Time{})
			var errb, out bytes.Buffer
			rc := newReceiver(false, &errb).run(dir+"/f", bufio.NewReader(bytes.NewReader(stream(t, "the new content", c.mutate))), &out)
			b, _ := os.ReadFile(dir + "/f")
			if c.ok {
				if rc != 0 || string(b) != "the new content" {
					t.Errorf("rc %d content %q: %s", rc, b, errb.String())
				}
				return
			}
			if rc == 0 || string(b) != "the old content" {
				t.Errorf("rc %d, content %q — a bad stream must install nothing", rc, b)
			}
			if !strings.Contains(errb.String(), "cut short or is corrupt") {
				t.Errorf("said %q", errb.String())
			}
			if l := leftovers(t, dir); len(l) > 0 {
				t.Errorf("staging left behind: %v", l)
			}
		})
	}
}

// A stream cut after a whole, verified file keeps that file, as an rsync
// interrupted between two files does, and still fails the run.
func TestNoEndMark(t *testing.T) {
	dir := t.TempDir()
	var errb, out bytes.Buffer
	body := stream(t, "content", func(b []byte) []byte { return b[:len(b)-1] })
	rc := newReceiver(false, &errb).run(dir+"/f", bufio.NewReader(bytes.NewReader(body)), &out)
	if b, _ := os.ReadFile(dir + "/f"); rc == 0 || string(b) != "content" || !strings.Contains(errb.String(), "no end mark") {
		t.Errorf("rc %d content %q said %q", rc, b, errb.String())
	}
}

// TestRefusesEscapes: no manifest path may leave the root, and nothing is
// touched when one tries.
func TestRefusesEscapes(t *testing.T) {
	for _, p := range []string{"../x", "a/../../x", "/etc/x", "a//b", "./x", "a/./b", "x\x00y", ""} {
		dir := t.TempDir()
		mkdir(t, dir+"/root")
		var b, errb, out bytes.Buffer
		w := newWriter(&b)
		writeManifest(w, []Entry{{Kind: kindDir, Path: ".", Mode: 0o755}, {Kind: kindDir, Path: "a", Mode: 0o755},
			{Kind: kindFile, Path: p, Mode: 0o644, Size: 0}})
		w.WriteByte(endMark)
		w.Flush()
		rc := newReceiver(true, &errb).run(dir+"/root", bufio.NewReader(&b), &out)
		if rc == 0 || !strings.Contains(errb.String(), "nothing was changed") {
			t.Errorf("%q: rc %d %q", p, rc, errb.String())
		}
		if ents, _ := os.ReadDir(dir + "/root"); len(ents) != 0 {
			t.Errorf("%q: the root was written to: %v", p, ents)
		}
	}
	// A file mode carries one name without a slash.
	var b, errb, out bytes.Buffer
	w := newWriter(&b)
	writeManifest(w, []Entry{{Kind: kindFile, Path: "a/b", Mode: 0o644}})
	w.Flush()
	if rc := newReceiver(false, &errb).run(t.TempDir()+"/f", bufio.NewReader(&b), &out); rc == 0 {
		t.Error("a file sync named a/b")
	}
}

func TestUnreadableSource(t *testing.T) {
	dir := t.TempDir()
	mkdir(t, dir+"/src")
	write(t, dir+"/src/ok", "ok", 0o644, time.Time{})
	write(t, dir+"/src/gone", "x", 0o644, time.Time{})
	s := dirSrc(t, dir+"/src")
	os.Remove(dir + "/src/gone")
	r := transfer(t, s, dir+"/dest")
	if r.err != nil || r.rep.Failed != 1 || !strings.Contains(r.warn, "cannot read") {
		t.Errorf("err %v report %+v warn %q", r.err, r.rep, r.warn)
	}
	if b, _ := os.ReadFile(dir + "/dest/ok"); string(b) != "ok" {
		t.Error("the rest was not synced")
	}
	if _, err := os.Lstat(dir + "/dest/gone"); err == nil {
		t.Error("a file that could not be read was installed")
	}
	if l := leftovers(t, dir+"/dest"); len(l) > 0 {
		t.Errorf("staging left behind: %v", l)
	}
}

// TestLargeStreams: content is chunked, never held whole.
func TestLargeStreams(t *testing.T) {
	dir := t.TempDir()
	mkdir(t, dir+"/src")
	big := bytes.Repeat([]byte("0123456789abcdef"), 3<<20/16+7)
	os.WriteFile(dir+"/src/big", big, 0o644)
	for i := range 2000 {
		write(t, fmt.Sprintf("%s/src/many/%04d", dir, i), fmt.Sprint(i), 0o644, time.Time{})
	}
	r := transfer(t, dirSrc(t, dir+"/src"), dir+"/dest")
	if r.rc != 0 || r.rep.Synced != 2001 {
		t.Fatalf("rc %d report %+v: %s", r.rc, r.rep, r.remote)
	}
	if b, _ := os.ReadFile(dir + "/dest/big"); !bytes.Equal(b, big) {
		t.Error("the large file differs")
	}
}

func TestMain(m *testing.M) {
	if dest := os.Getenv("TREESYNC_CHILD"); dest != "" {
		atexit.HandleSignals()
		atexit.Exit(Remote([]string{"file", dest}, os.Stdin, os.Stdout, os.Stderr))
	}
	os.Exit(m.Run())
}

// TestInterrupted: a server step killed by SIGTERM, or whose session dropped
// (SIGHUP, then the end of its stdin), removes the file in flight and leaves
// the old one in place.
func TestInterrupted(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP} {
		t.Run(sig.String(), func(t *testing.T) {
			dir := t.TempDir()
			write(t, dir+"/f", "old", 0o644, time.Time{})
			cmd := exec.Command(os.Args[0], "-test.run=^$")
			cmd.Env = append(os.Environ(), "TREESYNC_CHILD="+dir+"/f")
			in, _ := cmd.StdinPipe()
			out, _ := cmd.StdoutPipe()
			var errb bytes.Buffer
			cmd.Stderr = &errb
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			w := newWriter(in)
			writeManifest(w, []Entry{{Kind: kindFile, Path: "f", Mode: 0o644, Sec: 1, Size: 1 << 20}})
			w.Flush()
			if _, err := readNeed(bufio.NewReader(out), []Entry{{Kind: kindFile}}); err != nil {
				t.Fatal(err)
			}
			w.uvarint(0)
			w.uvarint(4096)
			w.Write(make([]byte, 4096))
			w.Flush()
			deadline := time.Now().Add(5 * time.Second)
			for len(leftovers(t, dir)) == 0 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if len(leftovers(t, dir)) == 0 {
				t.Fatal("no staging file appeared")
			}
			cmd.Process.Signal(sig)
			if sig == syscall.SIGHUP {
				time.Sleep(100 * time.Millisecond)
				if l := leftovers(t, dir); len(l) == 0 {
					t.Error("SIGHUP ended the step instead of being ignored")
				}
				in.Close()
			}
			err := cmd.Wait()
			if err == nil {
				t.Error("an interrupted sync exited 0")
			}
			if l := leftovers(t, dir); len(l) > 0 {
				t.Errorf("staging left behind: %v", l)
			}
			if b, _ := os.ReadFile(dir + "/f"); string(b) != "old" {
				t.Errorf("the file is %q, want the old one", b)
			}
		})
	}
}
