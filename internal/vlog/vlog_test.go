package vlog

import (
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParsePredicate(t *testing.T) {
	cases := []struct {
		line string
		ok   bool
		ver  string
	}{
		{"2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=-", true, "1.2.0"},
		{"2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup\r", true, "1.2.0"},
		{"2026-04-12T01:00:00+00:00\tdeploy\t1.2.0\tno-backup", true, "1.2.0"},
		{"2026-04-12T01:00:00+00:00 deploy 1.2.0", false, ""},
		{"2026-04-12 deploy 1.2.0 no-backup", false, ""},
		{"note: deploy 1.2.0 no-backup", false, ""},
		{"  2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup", true, "1.2.0"},
	}
	for _, c := range cases {
		e := Parse(c.line)
		if e.OK != c.ok || e.Version != c.ver {
			t.Errorf("Parse(%q) = ok %v version %q; want %v %q", c.line, e.OK, e.Version, c.ok, c.ver)
		}
	}
	e := Parse("2026-04-12T01:00:00+00:00 rollback 1.2.0 no-backup future=x kasbah=0.2.0 digest=sha256:a,sha256:b")
	if e.Kasbah != "0.2.0" || e.Digest != "sha256:a,sha256:b" || e.Action != "rollback" {
		t.Errorf("pairs: %+v", e)
	}
	if n := len(Entries("a b c d\n\n   \n2026-01-01T x y z\n")); n != 2 {
		t.Errorf("Entries kept %d non-blank lines, want 2", n)
	}
}

func TestLineRefuses(t *testing.T) {
	if l, err := Line("T", "deploy", "1.0.0", "no-backup", "0.1.0", "-"); err != nil || l != "T deploy 1.0.0 no-backup kasbah=0.1.0 digest=-" {
		t.Fatalf("Line = %q, %v", l, err)
	}
	for _, bad := range [][6]string{
		{"", "deploy", "1", "b", "k", "d"},
		{"T", "deploy", "1 0", "b", "k", "d"},
		{"T", "deploy", "1", "b", "k", ""},
		{"T", "deploy", "1", "b\n", "k", "d"},
	} {
		if _, err := Line(bad[0], bad[1], bad[2], bad[3], bad[4], bad[5]); err == nil {
			t.Errorf("Line(%q) accepted", bad)
		}
	}
	if s := Stamp(time.Date(2026, 4, 12, 1, 2, 3, 0, time.FixedZone("x", 3600))); s != "2026-04-12T00:02:03+00:00" {
		t.Errorf("Stamp = %q", s)
	}
}

func TestAppendRepairsATruncatedLine(t *testing.T) {
	dir := t.TempDir()
	if rep, err := Append(dir, "one"); err != nil || rep {
		t.Fatalf("first append: %v %v", rep, err)
	}
	os.WriteFile(filepath.Join(dir, Log), []byte("one\ntrunc"), 0o640)
	rep, err := Append(dir, "two")
	if err != nil || !rep {
		t.Fatalf("append after a cut: repaired %v, %v", rep, err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, Log))
	if string(b) != "one\ntrunc\ntwo\n" {
		t.Fatalf("log = %q", b)
	}
	if l, _ := LastLine(dir); l != "two" {
		t.Fatalf("LastLine = %q", l)
	}
	if l, err := LastLine(t.TempDir()); l != "" || err != nil {
		t.Fatalf("LastLine of nothing = %q, %v", l, err)
	}
}

func TestMonthIndex(t *testing.T) {
	if i, ok := MonthIndex("2026-08-01T"); !ok || i != 2026*12+8 || MonthName(i) != "2026-08" {
		t.Fatalf("MonthIndex = %d %v %s", i, ok, MonthName(i))
	}
	if MonthName(2027*12+1-3) != "2026-10" {
		t.Fatalf("a cut across the year: %s", MonthName(2027*12+1-3))
	}
	for _, bad := range []string{"", "2026-8-01", "x026-08-01", "2026/08/01"} {
		if _, ok := MonthIndex(bad); ok {
			t.Errorf("MonthIndex(%q) accepted", bad)
		}
	}
}

func gunzip(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	out.ReadFrom(zr)
	return out.String()
}

func TestRotate(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, Log)
	body := "2026-03-30T00:00:00+00:00 deploy 1.0.0 no-backup\n" +
		"2026-04-01T00:00:00+00:00 dep\n" + // datable and truncated: rotates anyway
		"garbage line\n" +
		"2026-05-01T00:00:00+00:00 deploy 1.1.0 no-backup\n" +
		"2026-08-01T00:00:00+00:00 deploy 1.2.0 no-backup"
	os.WriteFile(log, []byte(body), 0o640)
	os.Chmod(log, 0o640)
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	moved, cut, err := Rotate(dir, now)
	if err != nil || moved != 2 || MonthName(cut) != "2026-05" {
		t.Fatalf("Rotate = %d %s %v", moved, MonthName(cut), err)
	}
	b, _ := os.ReadFile(log)
	if string(b) != "garbage line\n2026-05-01T00:00:00+00:00 deploy 1.1.0 no-backup\n2026-08-01T00:00:00+00:00 deploy 1.2.0 no-backup\n" {
		t.Fatalf("kept %q", b)
	}
	for _, f := range []string{log, filepath.Join(dir, Archive)} {
		if fi, _ := os.Stat(f); fi.Mode().Perm() != 0o640 {
			t.Errorf("%s mode %o, want the log's 640", f, fi.Mode().Perm())
		}
	}
	if got := gunzip(t, filepath.Join(dir, Archive)); !strings.HasPrefix(got, "2026-03-30") || strings.Count(got, "\n") != 2 {
		t.Fatalf("archive %q", got)
	}
	// A second member appended; an existing archive keeps its own mode.
	os.Chmod(filepath.Join(dir, Archive), 0o600)
	moved, _, err = Rotate(dir, now.AddDate(0, 1, 0))
	if err != nil || moved != 1 {
		t.Fatalf("second rotation = %d %v", moved, err)
	}
	if fi, _ := os.Stat(filepath.Join(dir, Archive)); fi.Mode().Perm() != 0o600 {
		t.Errorf("archive mode %o, want its own 600", fi.Mode().Perm())
	}
	if got := gunzip(t, filepath.Join(dir, Archive)); strings.Count(got, "\n") != 3 {
		t.Fatalf("both members read back: %q", got)
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".versions.log") {
			t.Errorf("scratch %s left behind", e.Name())
		}
	}
	// Nothing old: the log is not rewritten.
	before, _ := os.Stat(log)
	if moved, _, err := Rotate(dir, now); moved != 0 || err != nil {
		t.Fatalf("idle rotation = %d %v", moved, err)
	}
	if after, _ := os.Stat(log); !os.SameFile(before, after) {
		t.Error("an idle rotation replaced the log")
	}
}

func TestDecode(t *testing.T) {
	var z bytes.Buffer
	for _, s := range []string{"a\n", "b\nc\n"} {
		w := gzip.NewWriter(&z)
		w.Write([]byte(s))
		w.Close()
	}
	if text, why := Decode(z.Bytes()); text != "a\nb\nc\n" || why != "" {
		t.Fatalf("Decode = %q %q", text, why)
	}
	if _, why := Decode(z.Bytes()[:z.Len()-4]); why == "" {
		t.Fatal("a truncated member read as whole")
	}
	if _, why := Decode([]byte("plain text")); why != "is not gzip" {
		t.Fatalf("plain text: %q", why)
	}
}
