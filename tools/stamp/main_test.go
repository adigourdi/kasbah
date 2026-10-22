package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Exact mode prints VERSION as written, pre-release or not; stamped mode adds
// the count and the time to a pre-release. Run from this package's directory,
// inside the checkout, so the count is a real one.
func TestStampExact(t *testing.T) {
	now := time.Unix(1700000000, 0)
	for _, base := range []string{"1.0.0-rc.1\n", "1.0.0\n", "1.0.2-dev\n"} {
		want := base[:len(base)-1]
		if got := stamp(base, true, now); got != want {
			t.Errorf("stamp(%q, exact) = %q, want %q", base, got, want)
		}
	}
	if got := stamp("1.0.0\n", false, now); got != "1.0.0" {
		t.Errorf("stamp(1.0.0, stamped) = %q, want 1.0.0", got)
	}
	got := stamp("1.0.0-rc.1\n", false, now)
	if len(got) <= len("1.0.0-rc.1.") || got[:len("1.0.0-rc.1.")] != "1.0.0-rc.1." || got[len(got)-len(".1700000000"):] != ".1700000000" {
		t.Errorf("stamp(1.0.0-rc.1, stamped) = %q, want 1.0.0-rc.1.<commits>.1700000000", got)
	}
}

func TestInCheckout(t *testing.T) {
	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	worktree := filepath.Join(tmp, "worktree")
	plain := filepath.Join(tmp, "plain", "sub")
	for _, d := range []string{filepath.Join(repo, ".git"), filepath.Join(repo, "a", "b"), worktree, plain} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: elsewhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		dir  string
		want bool
	}{
		{"repository root", repo, true},
		{"below the root", filepath.Join(repo, "a", "b"), true},
		{"worktree's .git file", worktree, true},
		{"no checkout", plain, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := inCheckout(tt.dir); got != tt.want {
				t.Errorf("inCheckout(%q) = %v, want %v", tt.dir, got, tt.want)
			}
		})
	}
}
