// Package udifftest proves unified diffs against GNU patch and GNU diff.
// The toolchain image has no patch; tests/udiff_test.sh runs the proofs on
// the host with KASBAH_UDIFF_GNU=1, which turns a missing tool into a failure.
package udifftest

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

var (
	probe   sync.Once
	missing string
)

// GNU reports whether GNU's patch and diff are here to prove against; a
// busybox one is not.
func GNU(t testing.TB) bool {
	t.Helper()
	probe.Do(func() {
		for _, tool := range []string{"patch", "diff"} {
			v, _ := exec.Command(tool, "--version").Output()
			if !bytes.Contains(bytes.SplitN(v, []byte("\n"), 2)[0], []byte("GNU")) {
				missing = tool
				return
			}
		}
	})
	if missing != "" && os.Getenv("KASBAH_UDIFF_GNU") == "1" {
		t.Fatalf("KASBAH_UDIFF_GNU=1 but there is no GNU %s on PATH", missing)
	}
	return missing == ""
}

// Patch applies diff to orig with GNU patch and returns the result, failing
// the test unless every hunk applies exactly where it says: no fuzz, no
// offset, no rejects.
func Patch(t testing.TB, orig, diff []byte) []byte {
	t.Helper()
	dir := t.TempDir()
	in, out, pf := filepath.Join(dir, "orig"), filepath.Join(dir, "out"), filepath.Join(dir, "diff")
	write(t, in, orig)
	write(t, pf, diff)
	cmd := exec.Command("patch", "--binary", "--force", "--fuzz=0", "--no-backup-if-mismatch",
		"-r", filepath.Join(dir, "rej"), "-o", out, "-i", pf, in)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	msg, err := cmd.CombinedOutput()
	if err != nil || strings.Contains(string(msg), "Hunk") {
		t.Fatalf("patch did not apply cleanly (%v):\n%s\ndiff:\n%s", err, msg, diff)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("patch wrote no output: %v\n%s", err, msg)
	}
	return got
}

// Diff is GNU `diff -a -u --label a --label b` of a → b.
func Diff(t testing.TB, a, b []byte) []byte {
	t.Helper()
	dir := t.TempDir()
	fa, fb := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	write(t, fa, a)
	write(t, fb, b)
	cmd := exec.Command("diff", "-a", "-u", "--label", "a", "--label", "b", fa, fb)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if ee, ok := err.(*exec.ExitError); err != nil && (!ok || ee.ExitCode() != 1) {
		t.Fatalf("diff: %v", err)
	}
	return out
}

// Count is the number of -/+ lines in a unified diff, headers aside.
func Count(diff []byte) int {
	n := 0
	for i, l := range bytes.SplitAfter(diff, []byte("\n")) {
		if i >= 2 && len(l) > 0 && (l[0] == '-' || l[0] == '+') {
			n++
		}
	}
	return n
}

func write(t testing.TB, name string, b []byte) {
	t.Helper()
	if err := os.WriteFile(name, b, 0o600); err != nil {
		t.Fatal(err)
	}
}
