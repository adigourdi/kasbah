package serverbin

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/version"
)

// TempPrefix names an upload beside the binary; LockName is the lock every
// install takes in that directory; LockWait bounds the wait for it, seconds.
const (
	TempPrefix = ".kasbah."
	LockName   = ".lock"
	LockWait   = 60
)

// InstallSelf is `kasbah remote install-self DEST`, run by a verified upload:
// under the directory's lock it renames selfPath over DEST only if DEST is
// still replaceable, older, or a pre-release this release goes over
// (remote.Replaces), so racing installs end on the newest.
func InstallSelf(self remote.Info, selfPath, dest string, out io.Writer) error {
	ours, err := version.Parse(self.Build)
	if err != nil {
		return cli.Fail("this kasbah's build '%s' is not a version; it does not install itself", self.Build)
	}
	lock, err := serverlock.Open(filepath.Join(filepath.Dir(dest), LockName))
	if err != nil {
		return cli.Fail("cannot open the install lock beside %s: %v", dest, err)
	}
	defer lock.Close()
	deadline := time.Now().Add(LockWait * time.Second)
	for {
		err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
			return cli.Fail("could not take the install lock beside %s: %v", dest, err)
		}
		time.Sleep(100 * time.Millisecond)
	}

	srv, err := Classify(localFacts(dest), dest, runtime.GOARCH, nil)
	if err != nil {
		return err
	}
	old := "none"
	if srv != nil {
		sv, err := version.Parse(srv.Build)
		if err != nil {
			return cli.Fail("%s reports build '%s', which is not a version", dest, srv.Build)
		}
		if !remote.Replaces(ours, sv) {
			fmt.Fprintf(out, "kept %s\n", srv.Line())
			return nil
		}
		old = srv.Build
	} else if _, err := os.Lstat(dest); err == nil {
		old = "unknown"
	}
	if err := os.Rename(selfPath, dest); err != nil {
		return cli.Fail("could not move %s over %s: %v", selfPath, dest, err)
	}
	fmt.Fprintf(out, "installed old=%s\n", old)
	return nil
}

// localFacts is the probe's Facts, gathered in Go on the server itself.
func localFacts(file string) Facts {
	f := Facts{RC: -1}
	fi, err := os.Lstat(file)
	if err != nil {
		return f
	}
	f.Present = true
	if fi.Mode().IsRegular() {
		f.Regular = true
	} else if fi.Mode()&os.ModeSymlink != 0 {
		if st, err := os.Stat(file); err == nil && st.Mode().IsRegular() {
			f.Regular = true
		}
	}
	if !f.Regular {
		return f
	}
	f.Executable = syscall.Access(file, 1) == nil
	if r, err := os.Open(file); err == nil {
		f.Head = make([]byte, 20)
		n, _ := io.ReadFull(r, f.Head)
		f.Head = f.Head[:n]
		r.Close()
	}
	if !f.Executable || !runnableHere(f.Head, runtime.GOARCH) {
		return f
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(RunTimeout)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, file, "remote", "version")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	f.Stdout, f.Stderr = stdout.String(), stderr.String()
	var ee *exec.ExitError
	switch {
	case ctx.Err() != nil:
		f.RC = 124
	case err == nil:
		f.RC = 0
	case errors.As(err, &ee):
		f.RC = ee.ExitCode()
		if f.RC < 0 {
			f.RC = 128 + int(ee.Sys().(syscall.WaitStatus).Signal())
		}
	case errors.Is(err, syscall.ENOEXEC), errors.Is(err, syscall.EACCES):
		// The upload ran from this directory, so EACCES here is not a mount.
		f.RC = 126
	case errors.Is(err, syscall.ENOENT):
		f.RC = 127
	default:
		f.Stderr = err.Error()
	}
	return f
}
