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

var aug = time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)

// Lines travel byte for byte in both directions, whatever their whitespace.
func TestRotateMessyLines(t *testing.T) {
	dir := t.TempDir()
	old := "2026-01-01T00:00:00+00:00  deploy 1.0.0 no-backup\r\n" +
		"2026-02-01T00:00:00+00:00 deploy 1.1.0 no-backup kasbah=0.1.0 \n"
	body := old[:strings.Index(old, "\n")+1] + "\n" + old[strings.Index(old, "\n")+1:] +
		"   \n2026-08-01T00:00:00+00:00 deploy\t2.0.0  no-backup \r\n\n"
	os.WriteFile(filepath.Join(dir, Log), []byte(body), 0o644)
	if moved, _, err := Rotate(dir, aug); moved != 2 || err != nil {
		t.Fatalf("Rotate = %d %v", moved, err)
	}
	if got := gunzip(t, filepath.Join(dir, Archive)); got != old {
		t.Errorf("archived %q, want %q", got, old)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, Log)); string(b) != "\n   \n2026-08-01T00:00:00+00:00 deploy\t2.0.0  no-backup \r\n\n" {
		t.Errorf("kept %q", b)
	}
}

// Stale scratch from a killed run is overwritten, never appended to.
func TestRotateStaleScratch(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{".versions.log.keep", ".versions.log.drop", ".versions.log.part"} {
		os.WriteFile(filepath.Join(dir, f), []byte("2026-01-01T00:00:00+00:00 stale junk\n"), 0o644)
	}
	os.WriteFile(filepath.Join(dir, Log), []byte("2026-01-02T00:00:00+00:00 deploy 1.0.0 no-backup\n2026-08-01T00:00:00+00:00 deploy 2.0.0 no-backup\n"), 0o644)
	if moved, _, err := Rotate(dir, aug); moved != 1 || err != nil {
		t.Fatalf("Rotate = %d %v", moved, err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, Log))
	if strings.Contains(string(b), "junk") || strings.Contains(gunzip(t, filepath.Join(dir, Archive)), "junk") {
		t.Errorf("stale scratch leaked: log %q archive %q", b, gunzip(t, filepath.Join(dir, Archive)))
	}
}

func TestRotateFailures(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, Log)
	body := "2026-01-02T00:00:00+00:00 deploy 1.0.0 no-backup\n2026-08-01T00:00:00+00:00 deploy 2.0.0 no-backup\n"
	os.WriteFile(log, []byte(body), 0o644)
	// The append cannot happen: the log is untouched and says so.
	os.Mkdir(filepath.Join(dir, Archive), 0o755)
	_, _, err := Rotate(dir, aug)
	if err != Partial || !strings.Contains(err.Error(), "the append to versions.log.gz stopped partway") {
		t.Errorf("archive not appendable: %v", err)
	}
	if b, _ := os.ReadFile(log); string(b) != body {
		t.Errorf("the log changed: %q", b)
	}
	os.Remove(filepath.Join(dir, Archive))
	if os.Geteuid() != 0 {
		os.Chmod(log, 0)
		if _, _, err := Rotate(dir, aug); err != Untouched || !strings.Contains(err.Error(), "could not be rotated") {
			t.Errorf("unreadable log: %v", err)
		}
		os.Chmod(log, 0o644)
		if _, err := os.Stat(filepath.Join(dir, Archive)); err == nil {
			t.Error("an untouched rotation wrote an archive")
		}
	}
	if msg := Duplicated.Error(); !strings.Contains(msg, "BOTH files") || !strings.Contains(msg, "nothing was lost") {
		t.Errorf("duplicated: %q", msg)
	}
}

// zcat ignores zero padding after the last member; a cut member is not that.
func TestDecodeZeroPadding(t *testing.T) {
	var z bytes.Buffer
	w := gzip.NewWriter(&z)
	w.Write([]byte("a\nb\n"))
	w.Close()
	padded := append(append([]byte{}, z.Bytes()...), make([]byte, 512)...)
	if text, why := Decode(padded); text != "a\nb\n" || why != "" {
		t.Errorf("padded: %q %q", text, why)
	}
	junk := append(append([]byte{}, z.Bytes()...), 0, 0, 1)
	if _, why := Decode(junk); why == "" {
		t.Error("non-zero trailing bytes read as whole")
	}
	two := append(append([]byte{}, z.Bytes()...), z.Bytes()...)
	if text, why := Decode(append(two, 0, 0)); text != "a\nb\na\nb\n" || why != "" {
		t.Errorf("two members, padded: %q %q", text, why)
	}
}
