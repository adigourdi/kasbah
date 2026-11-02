package deploy

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
)

// errDeadline is a hook stopped at the engine's deadline.
var errDeadline = errors.New("the deadline passed")

// killGrace is what `timeout -k` gives: SIGTERM to the hook's process group
// at the deadline, SIGKILL this long after. A seam for the tests.
var killGrace = 30 * time.Second

// runHook runs c, and with a deadline set or forward on runs it as its own
// process group, killed whole at the deadline: a hook's children go with it.
func (e *engine) runHook(c *exec.Cmd) error {
	if e.deadline.IsZero() && !e.forward {
		return c.Run()
	}
	ctx := context.Background()
	if !e.deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, e.deadline)
		defer cancel()
	}
	if ctx.Err() != nil {
		return errDeadline
	}
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// A child left holding the output does not hold the job past the kill.
	c.WaitDelay = killGrace + 5*time.Second
	if err := c.Start(); err != nil {
		return err
	}
	pgid := c.Process.Pid
	pop := atexit.Push(func() { syscall.Kill(-pgid, syscall.SIGKILL) })
	defer pop()
	if e.forward {
		e.hookPG.Store(int32(pgid))
		defer e.hookPG.Store(0)
		// A signal held before the group existed reaches it now.
		if e.stop.Load() != 0 {
			syscall.Kill(-pgid, syscall.SIGTERM)
		}
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
	}
	syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-done:
		syscall.Kill(-pgid, syscall.SIGKILL)
	case <-time.After(killGrace):
		syscall.Kill(-pgid, syscall.SIGKILL)
		<-done
	}
	return errDeadline
}

// interrupt is a restore's hold: the first SIGINT or SIGTERM is recorded for
// the steps to stop at, and forwarded to the running hook's process group.
func (e *engine) interrupt(s os.Signal) {
	sig, _ := s.(syscall.Signal)
	e.stop.CompareAndSwap(0, 128+int32(sig))
	if pg := e.hookPG.Load(); pg != 0 {
		syscall.Kill(-int(pg), sig)
	}
}
