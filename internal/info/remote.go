package info

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"

	"github.com/adigourdi/kasbah/internal/probe"
)

// Remote is `kasbah remote info`, run by the server binary: Collect's lines as
// key=value. It reads and runs only read-only commands.
func Remote(build string, args []string, stdout, stderr io.Writer) int {
	if len(args) != 0 {
		fmt.Fprintln(stderr, "remote: usage: kasbah remote info")
		return 1
	}
	rel, err := os.ReadFile("/etc/os-release")
	if err != nil {
		rel, _ = os.ReadFile("/usr/lib/os-release")
	}
	for _, f := range Collect(build, runtime.GOARCH, rel, probe.HaveDocker(), docker) {
		fmt.Fprintf(stdout, "%s=%s\n", f.Key, f.Value)
	}
	return 0
}

// docker runs docker with args, its stdout and stderr kept apart; rc is -1
// when it could not run at all.
func docker(args ...string) (string, string, int) {
	var out, errOut bytes.Buffer
	cmd := exec.Command("docker", args...)
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	var x *exec.ExitError
	switch {
	case err == nil:
		return out.String(), errOut.String(), 0
	case errors.As(err, &x):
		return out.String(), errOut.String(), x.ExitCode()
	}
	return out.String(), err.Error(), -1
}
