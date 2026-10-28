// Package prompt is the tri-state rule (docs/overview.md → Interactivity):
// a flag wins, else a terminal on stdin is asked, else the run fails naming
// the flags. Questions go to stderr; answers come back as values.
package prompt

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/term"
)

// Given is what the command line said about a yes/no question.
type Given int

const (
	Unset Given = iota
	Yes
	No
)

// Pair is a choice's two flags, spelled without the leading dashes.
type Pair struct{ Yes, No string }

// Feature is the pair for an optional feature: --with-<name> / --no-<name>.
func Feature(name string) Pair { return Pair{Yes: "with-" + name, No: "no-" + name} }

// Set records one flag of a pair. Giving both answers is refused rather than
// letting the later one win: `<cmd>: --with-x and --no-x cannot both be given`.
func (g *Given) Set(v Given, p Pair, cmd string) error {
	if *g != Unset && *g != v {
		return cli.Fail("%s: --%s and --%s cannot both be given", cmd, p.Yes, p.No)
	}
	*g = v
	return nil
}

// Prompter asks on a terminal. The zero value is unusable; build one with Std
// or fill every field.
type Prompter struct {
	// In is where answers are read, one byte at a time — nothing past the
	// answer's newline is consumed, as with bash's read.
	In io.Reader
	// Out carries the questions and warnings (its Stderr).
	Out *cli.Output
	// TTY is whether In is a terminal; without one nothing is asked.
	TTY bool
	// NoEcho hides typing for a secret and returns what restores it.
	NoEcho func() (func() error, error)
	// Exit ends the process when a signal interrupts a secret; nil is
	// atexit.Exit, which runs the command's registered cleanups first.
	Exit func(code int)
}

// Std asks on the process's stdin, a terminal or not.
func Std(out *cli.Output) *Prompter {
	return &Prompter{
		In:     os.Stdin,
		Out:    out,
		TTY:    term.IsTerminal(os.Stdin.Fd()),
		NoEcho: func() (func() error, error) { return term.NoEcho(os.Stdin.Fd()) },
	}
}

const (
	reasonNoTTY = "stdin is not a terminal"
	reasonEOF   = "no answer given"
)

// giveUp is the hard failure every unanswerable question ends in: exit 1,
// repeating the question and naming the flags that make it scriptable.
func giveUp(reason, question, flags string) error {
	return cli.Fail("cannot ask: %s", question).Cont(reason + " — pass " + flags + " instead")
}

var errEOF = errors.New("eof")

// readLine is `read -r` into one variable: the line without its newline,
// blanks and tabs trimmed at both ends, then one trailing CR dropped. A line
// that ends in EOF rather than a newline is no answer, whatever it held.
func (p *Prompter) readLine() (string, error) {
	var b []byte
	var c [1]byte
	for {
		n, err := p.In.Read(c[:])
		if n == 1 {
			if c[0] == '\n' {
				break
			}
			if c[0] != 0 {
				b = append(b, c[0])
			}
			continue
		}
		if err != nil {
			return "", errEOF
		}
	}
	s := strings.Trim(string(b), " \t\n")
	return strings.TrimSuffix(s, "\r"), nil
}

func (p *Prompter) ask(prompt string) (string, error) {
	fmt.Fprint(p.Out.Stderr, prompt)
	return p.readLine()
}

// yesNo is the terminal half the yes/no questions share; they differ only in
// the flags that answer them.
func (p *Prompter) yesNo(question, flags string) (bool, error) {
	if !p.TTY {
		return false, giveUp(reasonNoTTY, question, flags)
	}
	for {
		a, err := p.ask(question + " [y/n] ")
		if err != nil {
			return false, giveUp(reasonEOF, question, flags)
		}
		switch a {
		case "y", "Y", "yes", "Yes", "YES":
			return true, nil
		case "n", "N", "no", "No", "NO":
			return false, nil
		}
		p.Out.Warn("answer y or n")
	}
}

// Bool asks a feature's question, answered by --with-<feature>/--no-<feature>.
func (p *Prompter) Bool(feature, question string, given Given) (bool, error) {
	return p.Choice(Feature(feature), question, given)
}

// Choice asks a question whose two answers are named flags, neither derived
// from a feature name (--reset-acme/--keep-acme).
func (p *Prompter) Choice(flags Pair, question string, given Given) (bool, error) {
	switch given {
	case Yes:
		return true, nil
	case No:
		return false, nil
	}
	return p.yesNo(question, "--"+flags.Yes+" or --"+flags.No)
}

// Confirm guards a destructive act. Its only flag is --<flag> (`--yes`):
// declining is not a second way to run the command, so it has no flag, and
// a false answer is the caller's to abort on.
func (p *Prompter) Confirm(flag, question string, given bool) (bool, error) {
	if given {
		return true, nil
	}
	return p.yesNo(question, "--"+flag)
}

// Value asks for a flag's value. A given value wins (one trailing CR off); an
// empty answer takes def, or with no def is asked again. A default is not an
// answer without a terminal: the flag is still required.
func (p *Prompter) Value(flag, question, given, def string) (string, error) {
	if given != "" {
		return strings.TrimSuffix(given, "\r"), nil
	}
	flags := "--" + flag + "=<value>"
	if !p.TTY {
		return "", giveUp(reasonNoTTY, question, flags)
	}
	suffix := ""
	if def != "" {
		suffix = " [" + def + "]"
	}
	for {
		a, err := p.ask(question + suffix + ": ")
		if err != nil {
			return "", giveUp(reasonEOF, question, flags)
		}
		if a == "" {
			a = def
		}
		if a != "" {
			return a, nil
		}
		p.Out.Warn("an answer is required")
	}
}

// Secret is Value with the typing hidden and no default. The newline the
// terminal did not echo is written here, so the next line of output does not
// land on the prompt.
func (p *Prompter) Secret(flag, question, given string) (string, error) {
	if given != "" {
		return strings.TrimSuffix(given, "\r"), nil
	}
	flags := "--" + flag + "=<value>"
	if !p.TTY {
		return "", giveUp(reasonNoTTY, question, flags)
	}
	for {
		a, err := p.askHidden(question + ": ")
		fmt.Fprintln(p.Out.Stderr)
		if errors.Is(err, errEOF) {
			return "", giveUp(reasonEOF, question, flags)
		}
		if err != nil {
			return "", err
		}
		if a != "" {
			return a, nil
		}
		p.Out.Warn("an answer is required")
	}
}

// askHidden reads with echo off. SIGINT or SIGTERM meanwhile puts the
// terminal back and exits 128+signal, as bash's `read -s` does.
func (p *Prompter) askHidden(prompt string) (a string, err error) {
	if p.NoEcho == nil {
		return p.ask(prompt)
	}
	restore, err := p.NoEcho()
	if err != nil {
		return "", cli.Fail("could not hide typing on the terminal: %v", err)
	}
	// Whichever handler takes the signal — this one, or atexit's if the
	// command installed it — the terminal is put back.
	pop := atexit.Push(func() { restore() })
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		select {
		case s := <-sigs:
			restore()
			fmt.Fprintln(p.Out.Stderr)
			exit := p.Exit
			if exit == nil {
				exit = atexit.Exit
			}
			exit(128 + int(s.(syscall.Signal)))
		case <-done:
		}
	}()
	defer func() {
		signal.Stop(sigs)
		close(done)
		pop()
		if rerr := restore(); rerr != nil && err == nil {
			err = cli.Fail("could not restore the terminal: %v", rerr)
		}
	}()
	return p.ask(prompt)
}

// Wait holds the run until the operator presses Enter: true then, false on q
// or end of input. There is nothing to wait for without a terminal.
func (p *Prompter) Wait(question string) bool {
	if !p.TTY {
		return false
	}
	for {
		a, err := p.ask(question + " ")
		if err != nil {
			fmt.Fprintln(p.Out.Stderr)
			return false
		}
		switch a {
		case "":
			return true
		case "q", "Q", "quit":
			return false
		}
		p.Out.Warn("press Enter, or type q to stop")
	}
}

// Typed is the second half of a double confirmation (08-keep.md, D10): only
// expected typed back exactly is true, and a mismatch is an answer, never
// re-asked. --<flag> answers it for a script.
func (p *Prompter) Typed(flag, expected, question string, given bool) (bool, error) {
	if expected == "" {
		return false, cli.Fail("internal: prompt_typed %s was given nothing for the operator to type", flag)
	}
	if given {
		return true, nil
	}
	if !p.TTY {
		return false, giveUp(reasonNoTTY, question, "--"+flag)
	}
	a, err := p.ask(question + " ")
	if err != nil {
		return false, giveUp(reasonEOF, question, "--"+flag)
	}
	return a == expected, nil
}
