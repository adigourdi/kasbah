// Package cli is kasbah's exit codes and stream discipline (docs/cli.md):
// results on stdout, progress, warning: and error: lines on stderr.
package cli

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/term"
	"github.com/adigourdi/kasbah/internal/trace"
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
// rest its cause and continuation lines; Report prints the next step and the
// help pointer after them, whatever order they were added in, then the log line.
type Error struct {
	Code  int
	Lines []string
	next  []string
	help  string
}

// Error is the failure and its cause, without the next step or the help
// pointer: what another message quotes when it carries this one.
func (e *Error) Error() string { return strings.Join(e.Lines, "\n") }

// all is every line in the order Report prints them.
func (e *Error) all() []string {
	l := append(slices.Clone(e.Lines), e.next...)
	if e.help != "" {
		l = append(l, "help: kasbah help "+e.help)
	}
	return l
}

// Full is err as Report prints it, without the error: prefix and log line: an
// *Error's next step and help line included. A server arm writes its failure
// with it, so a step built on the server is printed there.
func Full(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return strings.Join(e.all(), "\n")
	}
	return err.Error()
}

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

// Next appends the next step: what to run, pass or change to get past the
// failure, printed after the cause and continuation lines.
func (e *Error) Next(lines ...string) *Error {
	e.next = append(e.next, lines...)
	return e
}

// SetNext replaces the next step, for a caller that knows a better one than
// the code that built the failure.
func (e *Error) SetNext(lines ...string) *Error {
	e.next = slices.Clone(lines)
	return e
}

// Help ends the failure with a `help: kasbah help <topic>` line, topic a help
// topic, a rule ID or a command (cmd/kasbah's tests hold every literal to
// that).
func (e *Error) Help(topic string) *Error {
	e.help = topic
	return e
}

// HelpTopic is the topic Help set, "" for none.
func (e *Error) HelpTopic() string { return e.help }

// NextLines is the next step Next and SetNext set.
func (e *Error) NextLines() []string { return slices.Clone(e.next) }

// Carry appends from's next step and takes its help topic, when it has one:
// for a failure that quotes from through Error(), which leaves both out.
func (e *Error) Carry(from *Error) *Error {
	if from == nil {
		return e
	}
	e.next = append(e.next, from.next...)
	if from.help != "" {
		e.help = from.help
	}
	return e
}

// Cause puts err's first line on the headline after ": ", trailing period
// dropped, and appends its further lines after any continuation lines already
// present, \r stripped. A nil err leaves e as it is.
func (e *Error) Cause(err error) *Error {
	if err == nil {
		return e
	}
	head, more, _ := strings.Cut(strings.ReplaceAll(err.Error(), "\r", ""), "\n")
	e.Lines[0] += ": " + strings.TrimSuffix(head, ".")
	if more = strings.TrimRight(more, "\n"); more != "" {
		e.Lines = append(e.Lines, strings.Split(more, "\n")...)
	}
	return e
}

// OSCause is err without the operation and paths the message already names.
func OSCause(err error) error {
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.As(err, &pe):
		return pe.Err
	case errors.As(err, &le):
		return le.Err
	}
	return err
}

// Report prints err and returns the exit
// code to leave with: an *Error with its own lines and code, anything else as
// one error: line and exit 1. A nil err is exit 0, silently. On a
// workstation the run's log is saved, and a last line names it.
func (o *Output) Report(err error) int {
	if err == nil {
		return ExitOK
	}
	var e *Error
	if !errors.As(err, &e) {
		o.Err("%s", err.Error())
		o.logLine(ExitFailure)
		return ExitFailure
	}
	for i, l := range e.all() {
		if i == 0 {
			o.Err("%s", l)
		} else {
			o.ErrCont("%s", l)
		}
	}
	o.logLine(e.Code)
	return e.Code
}

func (o *Output) logLine(code int) {
	switch path, err := trace.Failed(code); {
	case err != nil:
		o.ErrCont("log: not saved (%v)", err)
	case path != "":
		o.ErrCont("log: %s", path)
	}
}
