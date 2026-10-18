package atexit

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"syscall"
	"testing"
	"time"
)

func TestRunOrderAndPop(t *testing.T) {
	var got []string
	Push(func() { got = append(got, "first") })
	pop := Push(func() { got = append(got, "popped") })
	Push(func() { got = append(got, "last") })
	pop()
	pop()
	Run()
	if want := []string{"last", "first"}; !slices.Equal(got, want) {
		t.Errorf("ran %v, want %v", got, want)
	}
	got = nil
	Run()
	if len(got) != 0 {
		t.Errorf("a second Run ran %v again", got)
	}
}

func TestInterruptedUnset(t *testing.T) {
	if c := Interrupted(); c != 0 {
		t.Errorf("Interrupted() = %d before any signal", c)
	}
}

// The child half of TestSignal: register a cleanup, say so, wait to be killed.
func TestMain(m *testing.M) {
	if out := os.Getenv("ATEXIT_TEST_CHILD"); out != "" {
		HandleSignals()
		Push(func() { os.WriteFile(out, []byte("cleaned"), 0o600) })
		if os.Getenv("ATEXIT_TEST_STUCK") != "" {
			Push(func() { os.WriteFile(out, []byte("stuck"), 0o600); select {} })
		}
		os.Stdout.WriteString("ready\n")
		select {}
	}
	os.Exit(m.Run())
}

func TestSignal(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM} {
		t.Run(sig.String(), func(t *testing.T) {
			out := filepath.Join(t.TempDir(), "out")
			cmd := exec.Command(os.Args[0], "-test.run=^$")
			cmd.Env = append(os.Environ(), "ATEXIT_TEST_CHILD="+out)
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			if line, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || line != "ready\n" {
				t.Fatalf("child said %q, %v", line, err)
			}
			cmd.Process.Signal(sig)
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case err = <-done:
			case <-time.After(10 * time.Second):
				cmd.Process.Kill()
				t.Fatal("the child did not exit on the signal")
			}
			var ee *exec.ExitError
			if !errors.As(err, &ee) || ee.ExitCode() != 128+int(sig) {
				t.Errorf("child exited %v, want code %d", err, 128+int(sig))
			}
			if b, _ := os.ReadFile(out); string(b) != "cleaned" {
				t.Errorf("the cleanup did not run (file holds %q)", b)
			}
		})
	}
}

// A cleanup that hangs does not hold the process: the second signal ends it.
func TestSecondSignal(t *testing.T) {
	out := filepath.Join(t.TempDir(), "out")
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "ATEXIT_TEST_CHILD="+out, "ATEXIT_TEST_STUCK=1")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if line, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("child said %q, %v", line, err)
	}
	cmd.Process.Signal(syscall.SIGTERM)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if b, _ := os.ReadFile(out); string(b) == "stuck" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	cmd.Process.Signal(syscall.SIGINT)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-time.After(10 * time.Second):
		cmd.Process.Kill()
		t.Fatal("a second signal did not end a stuck cleanup")
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) || ee.ExitCode() != 130 {
		t.Errorf("child exited %v, want 130 from the second signal", err)
	}
}
