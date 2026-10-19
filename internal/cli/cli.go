// Package cli is kasbah's exit codes and stream discipline (docs/cli.md):
// results on stdout, progress, warning: and error: lines on stderr.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/term"
)

// Exit codes — the shared contract of docs/cli.md "Exit codes".
const (
	ExitOK = 0
	// ExitFailure is every failure without a code of its own.
	ExitFailure = 1
	// ExitNoProject: no kasbah.yml in the current directory.
	ExitNoProject = 2
	// ExitSSHUnreachable: the target host did not answer ssh.
	ExitSSHUnreachable = 3
	// ExitNoRemoteState: no server marker where the apps path says one should
	// be. The message, not the code, says which of the three situations it is.
	ExitNoRemoteState = 4
	// ExitEnvSetup: the server's .env is not one kasbah will deploy against,
	// and nothing was deployed.
	ExitEnvSetup = 5
	// ExitComplianceFail: `kasbah check` recorded a failure.
	ExitComplianceFail = 6
)

// contIndent aligns a continuation line under the text of an `error: ` line.
const contIndent = "       "

const (
	red    = "\033[31m"
	yellow = "\033[33m"
	cyan   = "\033[36m"
	reset  = "\033[0m"
)

// Output writes kasbah's messages. Stdout carries results only; everything
// addressed to the operator goes to Stderr.
type Output struct {
	Stdout io.Writer
	Stderr io.Writer
	// Color colours the info, warning: and error: prefixes.
	Color bool
}

// Std is the process's own streams, coloured
// when stderr is a terminal and NO_COLOR is empty.
func Std() *Output {
	return &Output{
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Color:  term.IsTerminal(os.Stderr.Fd()) && os.Getenv("NO_COLOR") == "",
	}
}

func (o *Output) paint(c string) (string, string) {
	if o.Color {
		return c, reset
	}
	return "", ""
}

// Info is a progress line on stderr.
func (o *Output) Info(format string, args ...any) {
	on, off := o.paint(cyan)
	fmt.Fprintf(o.Stderr, "%s%s%s\n", on, fmt.Sprintf(format, args...), off)
}

// Warn is a `warning:` line on stderr.
func (o *Output) Warn(format string, args ...any) {
	on, off := o.paint(yellow)
	fmt.Fprintf(o.Stderr, "%swarning:%s %s\n", on, off, fmt.Sprintf(format, args...))
}

// Err is an `error:` line on stderr.
func (o *Output) Err(format string, args ...any) {
	on, off := o.paint(red)
	fmt.Fprintf(o.Stderr, "%serror:%s %s\n", on, off, fmt.Sprintf(format, args...))
}

// ErrCont is a continuation line of a multi-line error: no prefix, indented
// under the first line's text.
func (o *Output) ErrCont(format string, args ...any) {
	fmt.Fprintf(o.Stderr, "%s%s\n", contIndent, fmt.Sprintf(format, args...))
}

// Error is a failure on its way to the exit. Lines[0] is the error: line, the
// rest its continuation lines.
type Error struct {
	Code  int
	Lines []string
}

func (e *Error) Error() string { return strings.Join(e.Lines, "\n") }

// Fail is an exit-1 error of one line.
func Fail(format string, args ...any) *Error {
	return &Error{Code: ExitFailure, Lines: []string{fmt.Sprintf(format, args...)}}
}

// Failf is an error with its own exit code.
func Failf(code int, format string, args ...any) *Error {
	return &Error{Code: code, Lines: []string{fmt.Sprintf(format, args...)}}
}

// Cont appends continuation lines.
func (e *Error) Cont(lines ...string) *Error {
	e.Lines = append(e.Lines, lines...)
	return e
}

// Report prints err and returns the exit
// code to leave with: an *Error with its own lines and code, anything else as
// one error: line and exit 1. A nil err is exit 0, silently.
func (o *Output) Report(err error) int {
	if err == nil {
		return ExitOK
	}
	var e *Error
	if !errors.As(err, &e) {
		o.Err("%s", err.Error())
		return ExitFailure
	}
	for i, l := range e.Lines {
		if i == 0 {
			o.Err("%s", l)
		} else {
			o.ErrCont("%s", l)
		}
	}
	return e.Code
}
