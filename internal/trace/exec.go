package trace

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/term"
)

// Every external command kasbah runs goes through Run, Output,
// CombinedOutput or Start and Wait: the command line and dir are recorded,
// stderr is teed into the trace (never one on a terminal, whose program would
// see a pipe instead), and the exit status closes it. Stdin and stdout are
// never touched. With no trace running they are exec's own calls.

// sshMeta is how internal/ssh describes a call: its own words instead of
// ssh's argv, whether it runs a server arm that sends its trace back, and
// whether stderr must stay ssh's own (a call that may leave a master behind).
type sshMeta struct {
	desc  string
	arm   bool
	noTee bool
}

var (
	metas sync.Map // *exec.Cmd → sshMeta
	runs  sync.Map // *exec.Cmd → *running
)

// SSH describes cmd, an ssh call, for the trace. arm marks a `kasbah remote`
// call to a server running this build: Marker is appended to its command line
// when it runs, and its frames are folded in. noTee leaves stderr alone.
func SSH(cmd *exec.Cmd, desc string, arm, noTee bool) {
	if active() {
		metas.Store(cmd, sshMeta{desc: desc, arm: arm, noTee: noTee})
	}
}

// sshWait bounds how long an ssh call's stderr may stay open past its exit:
// a master it forked keeps the pipe on older OpenSSH.
const sshWait = 5 * time.Second

type running struct {
	id      int
	start   time.Time
	rec     *lines
	filter  *frames
	capture *bytes.Buffer
	ourWait bool
}

// begin's modes: how the caller's run treats stderr.
const (
	plain    = iota
	capture  // Output: an *exec.ExitError carries stderr
	combined // CombinedOutput: stderr is the caller's, mixed with stdout
)

func begin(cmd *exec.Cmd, mode int) *running {
	if !active() {
		return nil
	}
	r := &running{id: next(), start: time.Now()}
	var m sshMeta
	isSSH := false
	if v, ok := metas.LoadAndDelete(cmd); ok {
		m, isSSH = v.(sshMeta), true
	}
	desc := m.desc
	if !isSSH {
		desc = "run: " + Words(cmd.Args)
		if cmd.Dir != "" {
			desc += "  (in " + cmd.Dir + ")"
		}
	}
	record(fmt.Sprintf("[%d] %s", r.id, desc))

	orig := cmd.Stderr
	f, isFile := orig.(*os.File)
	shown := isFile && f == os.Stderr
	// Stderr the same non-file writer as Stdout is one pipe and one copier to
	// exec: a tee would add a second writer racing the first.
	if mode == combined || m.noTee || (same(orig, cmd.Stdout) && !isFile) || (!m.arm && isFile && term.IsTerminal(f.Fd())) {
		return r
	}
	r.rec = &lines{id: r.id, shown: shown}
	var w io.Writer = r.rec
	switch {
	case orig != nil:
		w = &tee{to: orig, rec: r.rec}
	case mode == capture:
		r.capture = &bytes.Buffer{}
		w = &tee{to: r.capture, rec: r.rec}
	}
	if m.arm && len(cmd.Args) > 0 {
		cmd.Args[len(cmd.Args)-1] += " " + Marker
		r.filter = &frames{out: w}
		w = r.filter
	}
	cmd.Stderr = w
	if isSSH && cmd.WaitDelay == 0 {
		cmd.WaitDelay, r.ourWait = sshWait, true
	}
	return r
}

// same is exec's own test for one writer behind Stdout and Stderr; a
// writer whose type cannot be compared is never the same.
func same(a, b io.Writer) (eq bool) {
	defer func() { recover() }()
	return a != nil && a == b
}

func (r *running) end(cmd *exec.Cmd, err error) error {
	if r == nil {
		return err
	}
	if r.filter != nil {
		r.filter.flush()
	}
	if r.rec != nil {
		r.rec.flush()
	}
	if r.ourWait && errors.Is(err, exec.ErrWaitDelay) {
		err = nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) && r.capture != nil && ee.Stderr == nil {
		ee.Stderr = r.capture.Bytes()
	}
	took := time.Since(r.start).Seconds()
	switch {
	case err == nil:
		record(fmt.Sprintf("[%d] exit 0 after %.2fs", r.id, took))
	case errors.As(err, &ee):
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			record(fmt.Sprintf("[%d] killed by %v after %.2fs", r.id, ws.Signal(), took))
		} else {
			record(fmt.Sprintf("[%d] exit %d after %.2fs", r.id, ee.ExitCode(), took))
		}
	default:
		record(fmt.Sprintf("[%d] failed: %v", r.id, err))
	}
	return err
}

// Run is cmd.Run, traced.
func Run(cmd *exec.Cmd) error {
	r := begin(cmd, plain)
	return r.end(cmd, cmd.Run())
}

// Output is cmd.Output, traced; an *exec.ExitError still carries stderr.
func Output(cmd *exec.Cmd) ([]byte, error) {
	r := begin(cmd, capture)
	out, err := cmd.Output()
	return out, r.end(cmd, err)
}

// CombinedOutput is cmd.CombinedOutput, traced: what it returns mixes stdout
// in, so none of it is recorded.
func CombinedOutput(cmd *exec.Cmd) ([]byte, error) {
	r := begin(cmd, combined)
	out, err := cmd.CombinedOutput()
	return out, r.end(cmd, err)
}

// Start is cmd.Start, traced; Wait closes it.
func Start(cmd *exec.Cmd) error {
	r := begin(cmd, plain)
	if err := cmd.Start(); err != nil {
		r.end(cmd, err)
		return err
	}
	if r != nil {
		runs.Store(cmd, r)
	}
	return nil
}

// Wait is cmd.Wait for a command Start started.
func Wait(cmd *exec.Cmd) error {
	err := cmd.Wait()
	if v, ok := runs.LoadAndDelete(cmd); ok {
		return v.(*running).end(cmd, err)
	}
	return err
}

// tee writes to the caller's writer and the record. The caller's errors are
// swallowed: a child must never block on, or die of, a stderr whose reader
// went away (a server step outliving its session).
type tee struct {
	to   io.Writer
	rec  *lines
	dead bool
}

func (t *tee) Write(p []byte) (int, error) {
	if !t.dead {
		if _, err := t.to.Write(p); err != nil {
			t.dead = true
		}
	}
	t.rec.Write(p)
	return len(p), nil
}

// lines records what a command writes on stderr, a line at a time; \r ends
// one too, so progress meters land as their updates.
type lines struct {
	mu    sync.Mutex
	id    int
	shown bool
	buf   []byte
}

func (l *lines) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, c := range p {
		if c == '\n' || c == '\r' {
			l.emit()
			continue
		}
		if len(l.buf) < maxFrame {
			l.buf = append(l.buf, c)
		}
	}
	return len(p), nil
}

func (l *lines) emit() {
	if len(l.buf) > 0 {
		put(fmt.Sprintf("[%d] stderr: %s", l.id, l.buf), !l.shown)
	}
	l.buf = l.buf[:0]
}

func (l *lines) flush() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.emit()
}

// frames takes a server arm's trace frames out of its stderr, wherever in a
// line they start, and folds them in; every other byte passes on as written.
type frames struct {
	mu      sync.Mutex
	out     io.Writer
	pending []byte // a prefix of frame seen so far
	in      bool
	body    []byte
}

func (f *frames) Write(p []byte) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := len(p)
	for len(p) > 0 {
		switch {
		case f.in:
			i := bytes.IndexByte(p, '\n')
			if i < 0 {
				f.body = append(f.body, p...)
				return n, nil
			}
			f.body = append(f.body, p[:i]...)
			fold(string(f.body))
			f.in, f.body, p = false, f.body[:0], p[i+1:]
		case len(f.pending) > 0:
			if p[0] != frame[len(f.pending)] {
				f.out.Write(f.pending)
				f.pending = f.pending[:0]
				continue
			}
			f.pending, p = append(f.pending, p[0]), p[1:]
			if len(f.pending) == len(frame) {
				f.in, f.pending = true, f.pending[:0]
			}
		default:
			i := bytes.IndexByte(p, frame[0])
			if i < 0 {
				f.out.Write(p)
				return n, nil
			}
			if i > 0 {
				f.out.Write(p[:i])
			}
			f.pending, p = append(f.pending, p[i]), p[i+1:]
		}
	}
	return n, nil
}

func (f *frames) flush() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.pending) > 0 {
		f.out.Write(f.pending)
		f.pending = f.pending[:0]
	}
	if f.in && len(f.body) > 0 {
		fold(string(f.body))
	}
	f.in, f.body = false, f.body[:0]
}

// fold records one line of a server's trace.
func fold(text string) { record("server: " + text) }
