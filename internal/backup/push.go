package backup

import (
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// Push is `kasbah remote backup push APPS NAME`: NAME's repository backed up
// now by the scheduler container, which alone reads the credentials, its
// output on stderr; stdout is push=ok, push=failed rc=, or push=no-container state=.
func Push(apps, name string, stdout, stderr io.Writer) int {
	stderr, done := remote.Outlive(stderr)
	defer done()
	if !reRepo.MatchString(name) || !strings.HasPrefix(apps, "/") || strings.ContainsRune(apps, 0) {
		fmt.Fprintln(stderr, "remote: usage: kasbah remote backup push APPS NAME (APPS absolute, NAME a project's name)")
		return 1
	}
	if st := backuprec.Scheduler().State; st != "running" {
		fmt.Fprintf(stdout, "push=no-container\nstate=%s\n", st)
		return 0
	}
	c := exec.Command("docker", "exec", Container, apps+"/.kasbah/bin/kasbah", "remote", "backup", "once", "--project", name)
	c.Stdout, c.Stderr = stderr, stderr
	if err := c.Run(); err != nil {
		fmt.Fprintf(stdout, "push=failed\nrc=%d\n", ssh.ExitCode(err))
		return 0
	}
	fmt.Fprintln(stdout, "push=ok")
	return 0
}
