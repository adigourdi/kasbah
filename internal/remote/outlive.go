package remote

import (
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Outlive keeps a state-changing step and its children running when the
// session drops: SIGHUP and SIGPIPE ignored, output through a pipe that keeps
// draining once w fails. done closes it and waits a bounded while for the copy.
func Outlive(w io.Writer) (out io.Writer, done func()) {
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
	r, pw, err := os.Pipe()
	if err != nil {
		return &dropErrors{w: w}, func() {}
	}
	copied := make(chan struct{})
	go func() {
		defer close(copied)
		io.Copy(&dropErrors{w: w}, r)
		r.Close()
	}()
	return pw, func() {
		pw.Close()
		select {
		case <-copied:
		case <-time.After(5 * time.Second):
		}
	}
}

// dropErrors reports every write as whole: after a failure, writes are discarded.
type dropErrors struct {
	w    io.Writer
	dead bool
}

func (d *dropErrors) Write(p []byte) (int, error) {
	if !d.dead {
		if _, err := d.w.Write(p); err != nil {
			d.dead = true
		}
	}
	return len(p), nil
}
