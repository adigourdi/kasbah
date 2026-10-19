// Package atexit is the process's cleanup stack: what bash's chained EXIT trap
// was. Go runs no deferred call on os.Exit or on a fatal signal, so anything
// that must not outlive the run — an ssh master, a temp file, a terminal with
// echo off — registers here, and every way out goes through Exit.
package atexit

import (
	"os"
	"os/signal"
	"sync"
	"syscall"
)

var (
	mu    sync.Mutex
	stack []*entry
	// interrupted is set by the signal handler before it takes mu, so a
	// command racing it to the exit can tell an error the signal caused.
	interrupted sync.Once
	sigCode     int
	sigSeen     = make(chan struct{})
)

type entry struct{ fn func() }

// Push registers fn and returns what removes it again without running it.
// Cleanups run last-pushed first.
func Push(fn func()) (pop func()) {
	e := &entry{fn: fn}
	mu.Lock()
	stack = append(stack, e)
	mu.Unlock()
	return func() {
		mu.Lock()
		defer mu.Unlock()
		for i, s := range stack {
			if s == e {
				stack = append(stack[:i], stack[i+1:]...)
				return
			}
		}
	}
}

// Run runs every registered cleanup once, newest first, and empties the stack.
func Run() {
	mu.Lock()
	defer mu.Unlock()
	run()
}

func run() {
	for len(stack) > 0 {
		e := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		e.fn()
	}
}

// Exit runs the cleanups and ends the process. Concurrent callers serialise:
// the first one's code wins and the rest never return.
func Exit(code int) {
	mu.Lock()
	run()
	os.Exit(code)
}

// HandleSignals makes SIGINT, SIGTERM and SIGHUP exit 128+signal through the
// cleanups, as bash does with an EXIT trap installed. A second signal during
// the cleanups exits at once.
func HandleSignals() {
	sigs := make(chan os.Signal, 2)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		s := <-sigs
		code := 128 + int(s.(syscall.Signal))
		interrupted.Do(func() { sigCode = code; close(sigSeen) })
		holdMu.Lock()
		h := held
		holdMu.Unlock()
		if h != nil {
			// The holder acts on the first; a second one is insistence.
			h(s)
			s = <-sigs
			code = 128 + int(s.(syscall.Signal))
		}
		go func() {
			s := <-sigs
			os.Exit(128 + int(s.(syscall.Signal)))
		}()
		Exit(code)
	}()
}

var (
	holdMu sync.Mutex
	held   func(os.Signal)
)

// Hold defers the exit while a child the run streams through is alive: the
// first signal goes to fn (to forward it) and is left for the holder to read
// through Interrupted; a second exits as usual. release ends the hold.
func Hold(fn func(os.Signal)) (release func()) {
	holdMu.Lock()
	held = fn
	holdMu.Unlock()
	return func() {
		holdMu.Lock()
		held = nil
		holdMu.Unlock()
	}
}

// Interrupted reports the exit code of a signal HandleSignals has received,
// or 0 when none has arrived.
func Interrupted() int {
	select {
	case <-sigSeen:
		return sigCode
	default:
		return 0
	}
}
