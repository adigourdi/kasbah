package selfupdate

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The one test of the real `git ls-remote` path; busybox (no git) skips it.

// repo is a git repository with the given tags.
func repo(t *testing.T, tags ...string) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("commit", "-q", "--allow-empty", "-m", "x")
	for _, tag := range tags {
		run("tag", tag)
	}
	return dir
}

func TestTagsGit(t *testing.T) {
	c := &Client{Remote: repo(t, "v1.0.0", "v1.2.0", "v1.3.0-rc.1", "v2.0.0", "vjunk", "other", "v01.2.3")}
	got, err := c.Tags("v1.*")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, v := range got {
		names = append(names, v.String())
	}
	if strings.Join(names, " ") != "1.3.0-rc.1 1.2.0 1.0.0" {
		t.Errorf("v1.*: %v", names)
	}
	if got, err := c.Tags("v2.0.0"); err != nil || len(got) != 1 || got[0].String() != "2.0.0" {
		t.Errorf("exact: %v, %v", got, err)
	}
	if got, err := c.Tags("v3.*"); err != nil || len(got) != 0 {
		t.Errorf("none: %v, %v", got, err)
	}
	// Resolve through the real path.
	if v, how, err := c.Resolve("", 1, false); err != nil || v.String() != "1.2.0" || !strings.Contains(how, c.Remote) {
		t.Errorf("resolve: %s, %q, %v", v, how, err)
	}
	// A dead remote: git's stderr becomes the continuation lines, none empty.
	c.Remote = filepath.Join(t.TempDir(), "nowhere")
	_, err = c.Tags("v1.*")
	if err == nil || !strings.Contains(err.Error(), "could not list the release tags on "+c.Remote) || !strings.Contains(err.Error(), "does not appear to be a git repository") {
		t.Fatalf("dead remote: %v", err)
	}
	if strings.HasSuffix(err.Error(), "\n") {
		t.Errorf("an empty continuation line: %q", err.Error())
	}
}

func TestTagsLines(t *testing.T) {
	c := &Client{ListTags: func(remote, pattern string) ([]string, error) {
		return []string{
			"aaaa\trefs/tags/v1.1.0\r",
			"bbbb\trefs/tags/v1.0.0",
			"cccc\trefs/tags/vjunk",
			"dddd\trefs/heads/v1.9.0",
			"no tab here",
			"",
		}, nil
	}}
	got, err := c.Tags("v1.*")
	if err != nil || len(got) != 2 || got[0].String() != "1.1.0" || got[1].String() != "1.0.0" {
		t.Errorf("lines: %v, %v", got, err)
	}
}
