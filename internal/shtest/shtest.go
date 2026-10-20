// Package shtest holds the scripts kasbah sends over ssh to POSIX sh: tests run
// each one under every shell Shells names, and Check parses them all and, for
// tests/posix_sh_test.sh's shellcheck pass, writes them to KASBAH_SCRIPT_DIR.
package shtest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Shell is one /bin/sh a server may have.
type Shell struct {
	Name string
	argv []string
}

// Shells is dash and bash in POSIX mode, or the commands KASBAH_TEST_SHELLS
// lists (busybox's sh, in tests/posix_sh_test.sh). A missing one fails.
func Shells(t testing.TB) []Shell {
	t.Helper()
	shells := []Shell{{"dash", []string{"dash"}}, {"bash", []string{"bash", "--posix"}}}
	if v := os.Getenv("KASBAH_TEST_SHELLS"); v != "" {
		shells = nil
		for _, w := range strings.Fields(v) {
			shells = append(shells, Shell{w, []string{w}})
		}
	}
	for _, s := range shells {
		if _, err := exec.LookPath(s.argv[0]); err != nil {
			t.Fatalf("%s is not installed: the remote scripts are held to it", s.argv[0])
		}
	}
	return shells
}

// Stdin is `sh -s -- ARGS…` with script on stdin, as ssh.Conn.Script runs it.
func (s Shell) Stdin(script string, args ...string) *exec.Cmd {
	cmd := exec.Command(s.argv[0], append(append(s.argv[1:], "-s", "--"), args...)...)
	cmd.Stdin = strings.NewReader(script)
	return cmd
}

// C is `sh -c SCRIPT sh ARGS…`.
func (s Shell) C(script string, args ...string) *exec.Cmd {
	return exec.Command(s.argv[0], append(append(s.argv[1:], "-c", script, "sh"), args...)...)
}

// Check parses every script under every shell and, when KASBAH_SCRIPT_DIR is
// set, writes each there as <pkg>-<name>.sh.
func Check(t *testing.T, pkg string, scripts map[string]string) {
	t.Helper()
	for _, sh := range Shells(t) {
		for name, body := range scripts {
			cmd := exec.Command(sh.argv[0], append(sh.argv[1:], "-n")...)
			cmd.Stdin = strings.NewReader(body)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Errorf("%s/%s under %s: %v %s", pkg, name, sh.Name, err, out)
			}
		}
	}
	dir := os.Getenv("KASBAH_SCRIPT_DIR")
	if dir == "" {
		return
	}
	for name, body := range scripts {
		if err := os.WriteFile(filepath.Join(dir, pkg+"-"+name+".sh"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
