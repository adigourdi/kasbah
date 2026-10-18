package main

import (
	"os"
	"path/filepath"
	"testing"
)

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
