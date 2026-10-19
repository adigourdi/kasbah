package ops

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
)

// TestWaitHelper is a child process: it installs the handlers a command
// does, runs one Wait and reports. Driven by TestWait.
func TestWaitHelper(t *testing.T) {
	c := os.Getenv("KASBAH_WAIT_CASE")
	if c == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	scripts := map[string]string{
		"forward":  `trap 'echo child-got-TERM; exit 7' TERM; echo ready; while :; do sleep 0.05; done`,
		"second":   `trap '' TERM; echo ready; while :; do sleep 0.05; done`,
		"released": `echo ready`,
		"killed":   `echo ready; kill -9 $$`,
	}
	r, w, _ := os.Pipe()
	cmd := exec.Command("sh", "-c", scripts[c])
	cmd.Stdout = w
	go func() {
		sc := bufio.NewScanner(r)
		for sc.Scan() {
			fmt.Println("child:", sc.Text())
			if sc.Text() == "ready" && (c == "forward" || c == "second") {
				syscall.Kill(os.Getpid(), syscall.SIGTERM)
				if c == "second" {
					time.Sleep(300 * time.Millisecond)
					syscall.Kill(os.Getpid(), syscall.SIGTERM)
				}
			}
		}
	}()
	rc, err := Wait(cmd)
	w.Close()
	time.Sleep(100 * time.Millisecond)
	fmt.Printf("rc=%d err=%v\n", rc, err)
	if c == "released" {
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(2 * time.Second)
		fmt.Println("still-here")
	}
	os.Exit(0)
}

func TestWait(t *testing.T) {
	for _, c := range []struct {
		name, want, not string
		code            int
	}{
		// The signal reaches the child, and the status says this process got it.
		{"forward", "child: child-got-TERM\nrc=143 err=<nil>", "", 0},
		// A child that ignores it keeps the hold; a second signal exits.
		{"second", "child: ready", "rc=", 143},
		// After the stream the handler is the ordinary one again.
		{"released", "rc=0 err=<nil>", "still-here", 143},
		// A child killed by a signal is 128+N.
		{"killed", "rc=137 err=<nil>", "", 0},
	} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestWaitHelper$")
		cmd.Env = append(os.Environ(), "KASBAH_WAIT_CASE="+c.name)
		out, _ := cmd.CombinedOutput()
		code := cmd.ProcessState.ExitCode()
		if code != c.code || !strings.Contains(string(out), c.want) || (c.not != "" && strings.Contains(string(out), c.not)) {
			t.Errorf("%s: exit %d, output:\n%s", c.name, code, out)
		}
	}
}

func TestWaitNeverRan(t *testing.T) {
	if _, err := Wait(exec.Command("/nonexistent/ssh")); err == nil {
		t.Error("a command that could not start is an error, not a status")
	}
}
