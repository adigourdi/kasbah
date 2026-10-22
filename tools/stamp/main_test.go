package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// repo is a throwaway checkout with one commit; its git runs with no user
// config, so no signing or hook on this machine reaches the test.
func repo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run(t, dir, "init", "-q", "-b", "main")
	commit(t, dir, "first")
	return dir
}

func run(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func commit(t *testing.T, dir, msg string) {
	t.Helper()
	run(t, dir, "commit", "-q", "--allow-empty", "-m", msg)
}

func dirty(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "stray"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStamp(t *testing.T) {
	now := time.Unix(1700000000, 0)
	tests := []struct {
		name    string
		base    string
		prepare func(t *testing.T, dir string)
		// want is a regexp over the whole stamp; SHA stands for HEAD's short sha.
		want string
	}{
		{"tagged and clean is the release exactly", "1.0.0\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "-a", "v1.0.0", "-m", "kasbah 1.0.0")
		}, `^1\.0\.0$`},
		{"a lightweight tag counts too", "1.0.0", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.0.0")
		}, `^1\.0\.0$`},
		{"a second lightweight tag on HEAD does not hide the release", "1.0.0\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "aaa")
			run(t, dir, "tag", "-a", "v1.0.0", "-m", "kasbah 1.0.0")
			run(t, dir, "tag", "zzz")
		}, `^1\.0\.0$`},
		{"an annotated non-v tag added after the release tag", "1.0.0\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "-a", "v1.0.0", "-m", "kasbah 1.0.0")
			run(t, dir, "tag", "-a", "milestone", "-m", "later")
		}, `^1\.0\.0$`},
		{"tagged but dirty is the next patch, marked dirty", "1.0.0\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.0.0")
			dirty(t, dir)
		}, `^1\.0\.1-dev\.1\.1700000000\+gSHA\.dirty$`},
		{"commits after the tag are the next patch", "1.0.0\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.0.0")
			commit(t, dir, "second")
			commit(t, dir, "third")
		}, `^1\.0\.1-dev\.3\.1700000000\+gSHA$`},
		{"before any tag the line is heading to VERSION", "1.1.0\r\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.0.0")
			commit(t, dir, "second")
		}, `^1\.1\.0-dev\.2\.1700000000\+gSHA$`},
		{"another tag on HEAD is not this release", "1.1.0", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.0.0")
		}, `^1\.1\.0-dev\.1\.1700000000\+gSHA$`},
		{"an rc tagged and clean is itself", "1.1.0-rc.1\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.1.0-rc.1")
		}, `^1\.1\.0-rc\.1$`},
		{"an rc with commits after its tag stays on the rc line", "1.1.0-rc.1\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.1.0-rc.1")
			commit(t, dir, "second")
		}, `^1\.1\.0-rc\.1\.2\.1700000000\+gSHA$`},
		{"an rc not yet tagged", "1.1.0-rc.2\n", func(t *testing.T, dir string) {
			run(t, dir, "tag", "v1.1.0-rc.1")
			dirty(t, dir)
		}, `^1\.1\.0-rc\.2\.1\.1700000000\+gSHA\.dirty$`},
		{"a dirty tree before any tag", "0.1.0", func(t *testing.T, dir string) {
			dirty(t, dir)
		}, `^0\.1\.0-dev\.1\.1700000000\+gSHA\.dirty$`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := repo(t)
			tt.prepare(t, dir)
			sha := regexp.QuoteMeta(run(t, dir, "rev-parse", "--short", "HEAD"))
			want := regexp.MustCompile(strings.ReplaceAll(tt.want, "SHA", sha))
			got, err := stamp(tt.base, dir, now)
			if err != nil {
				t.Fatalf("stamp: %v", err)
			}
			if !want.MatchString(got) {
				t.Errorf("stamp(%q) = %q, want %s", tt.base, got, want)
			}
		})
	}
}

// The count comes from the directory the build runs in, below the root too.
func TestStampBelowRoot(t *testing.T) {
	dir := repo(t)
	run(t, dir, "tag", "v1.0.0")
	sub := filepath.Join(dir, "a", "b")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	// The new directory is empty, so the tree is still clean.
	got, err := stamp("1.0.0", sub, time.Unix(1700000000, 0))
	if err != nil || got != "1.0.0" {
		t.Errorf("stamp below the root = %q, %v; want 1.0.0", got, err)
	}
}

func TestStampNoCheckout(t *testing.T) {
	now := time.Unix(1700000000, 0)
	for base, want := range map[string]string{
		"1.0.0\n":      "1.0.0-dev.0.1700000000",
		"1.1.0-rc.1\n": "1.1.0-rc.1.0.1700000000",
	} {
		got, err := stamp(base, t.TempDir(), now)
		if err != nil || got != want {
			t.Errorf("stamp(%q) outside a checkout = %q, %v; want %q", base, got, err, want)
		}
	}
}

func TestStampRefusals(t *testing.T) {
	now := time.Unix(1700000000, 0)
	if _, err := stamp("devel\n", t.TempDir(), now); err == nil || !strings.Contains(err.Error(), "VERSION") {
		t.Errorf("a VERSION that is not a version: %v", err)
	}
	// A .git entry with no repository behind it: git fails, and so does the stamp.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".git"), []byte("gitdir: /nonexistent\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := stamp("1.0.0\n", dir, now); err == nil || !strings.Contains(err.Error(), "git tag --points-at") {
		t.Errorf("a broken checkout: %v", err)
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
