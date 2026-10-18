// Command stamp prints the build stamp baked into kasbah: VERSION, and on a
// pre-release the commit count and the build time (internal/version.Stamp).
// Run from the repository root, as the compose build service does.
package main

import (
	"bytes"
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
	// Outside a git checkout (a tarball) the count is 0, so such a build ranks
	// below every checkout build of the same VERSION. Inside one, a git that
	// fails is an error, not a missing count.
	commits := 0
	if inCheckout(wd) {
		out, err := git("rev-list", "--count", "HEAD")
		if err != nil {
			fail(err)
		}
		if commits, err = strconv.Atoi(strings.TrimSpace(out)); err != nil {
			fail(fmt.Errorf("git rev-list --count: %q is not a count", out))
		}
	}
	fmt.Println(version.Stamp(string(base), commits, time.Now()))
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

func git(args ...string) (string, error) {
	var stderr bytes.Buffer
	cmd := exec.Command("git", args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %v\n%s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "stamp: %v\n", err)
	os.Exit(1)
}
