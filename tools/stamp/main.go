// Command stamp prints the build stamp baked into kasbah, derived from VERSION
// and the state of the checkout (internal/version.Stamp): VERSION exactly
// when HEAD carries the tag v<VERSION> and the tree is clean — a release build,
// an rc included, is reproducible — and a pre-release stamp otherwise, with
// the commit count, the build time and `+g<sha>[.dirty]` as build metadata.
// Run from the repository root, as the compose build service does.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/version"
)

func main() {
	base, err := os.ReadFile("VERSION")
	if err != nil {
		fail(err)
	}
	wd, err := os.Getwd()
	if err != nil {
		fail(err)
	}
	s, err := stamp(string(base), wd, time.Now())
	if err != nil {
		fail(err)
	}
	fmt.Println(s)
}

// stamp is the build stamp for base in the checkout holding dir: base itself
// when HEAD is tagged v<base> and the tree is clean; otherwise a pre-release
// of the line's next version — the next patch once v<base> exists, base
// itself (with -dev when it has no pre-release part) before it does — with
// the commit count and `+g<sha>[.dirty]`. Outside a git checkout (a tarball)
// the count is 0 and there is no metadata, so such a build ranks below every
// checkout build of the same VERSION.
func stamp(base, dir string, now time.Time) (string, error) {
	base = strings.TrimSpace(base)
	if _, err := version.Parse(base); err != nil {
		return "", fmt.Errorf("VERSION: %v", err)
	}
	if !inCheckout(dir) {
		return version.Stamp(devBase(base), 0, now), nil
	}
	tag := "v" + base
	tagged, err := headTagged(dir, tag)
	if err != nil {
		return "", err
	}
	status, err := git(dir, "status", "--porcelain")
	if err != nil {
		return "", err
	}
	dirty := strings.TrimSpace(status) != ""
	if tagged && !dirty {
		return base, nil
	}
	released, err := git(dir, "tag", "-l", tag)
	if err != nil {
		return "", err
	}
	next := devBase(base)
	if strings.TrimSpace(released) != "" && !strings.Contains(base, "-") {
		next, err = nextPatch(base)
		if err != nil {
			return "", err
		}
	}
	count, err := git(dir, "rev-list", "--count", "HEAD")
	if err != nil {
		return "", err
	}
	commits, err := strconv.Atoi(strings.TrimSpace(count))
	if err != nil {
		return "", fmt.Errorf("git rev-list --count: %q is not a count", count)
	}
	sha, err := git(dir, "rev-parse", "--short", "HEAD")
	if err != nil {
		return "", err
	}
	meta := "+g" + strings.TrimSpace(sha)
	if dirty {
		meta += ".dirty"
	}
	return version.Stamp(next+meta, commits, now), nil
}

// devBase is base as a pre-release: itself when it has one, else base-dev.
func devBase(base string) string {
	if strings.Contains(base, "-") {
		return base
	}
	return base + "-dev"
}

// nextPatch is the -dev line after a released base.
func nextPatch(base string) (string, error) {
	v, err := version.Parse(base)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d.%d.%d-dev", v.Major, v.Minor, v.Patch+1), nil
}

// headTagged is whether tag is among the tags on HEAD — all of them, so
// another tag there does not hide it.
func headTagged(dir, tag string) (bool, error) {
	out, err := git(dir, "tag", "--points-at", "HEAD")
	if err != nil {
		return false, err
	}
	for _, t := range strings.Split(out, "\n") {
		if strings.TrimSpace(t) == tag {
			return true, nil
		}
	}
	return false, nil
}

// inCheckout reports whether dir or any parent holds a .git entry (a
// directory, or the file a worktree or submodule has instead).
func inCheckout(dir string) bool {
	for {
		if _, err := os.Lstat(filepath.Join(dir, ".git")); err == nil {
			return true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}

type gitError struct {
	args   []string
	code   int
	stderr string
	err    error
}

func (e *gitError) Error() string {
	return fmt.Sprintf("git %s: %v\n%s", strings.Join(e.args, " "), e.err, e.stderr)
}

func git(dir string, args ...string) (string, error) {
	var stderr bytes.Buffer
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		code := -1
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		}
		return "", &gitError{args: args, code: code, stderr: strings.TrimSpace(stderr.String()), err: err}
	}
	return string(out), nil
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "stamp: %v\n", err)
	os.Exit(1)
}
