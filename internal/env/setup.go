// Package env is `kasbah env`: the setup, drift report and managed block the
// server runs under `kasbah remote setup-env`, and the workstation's driver.
package env

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/term"
)

// Exit statuses of the setup; EOF at a menu aborts with SetupFail.
const (
	SetupOK   = 0
	SetupFail = 1
)

// Setup is one interactive run against Dir's .env.prod.example.
type Setup struct {
	Dir string
	// In carries the answers. It is read a byte at a time, as bash's read
	// does, so a `! command` generator inherits whatever is left of it.
	In *os.File
	// Out carries the prompts; Err the two that bash's `read -p` writes.
	Out, Err io.Writer
	// TTY is whether In is a terminal: masked answers hide the typing and
	// a menu takes one keypress.
	TTY bool
	// TermFD is In's descriptor number, for the terminal mode calls.
	TermFD uintptr
	Color  bool
}

type palette struct{ bold, dim, cyan, yellow, green, red, reset string }

func (s *Setup) colors() palette {
	if !s.Color {
		return palette{}
	}
	return palette{"\033[1m", "\033[2m", "\033[36m", "\033[33m", "\033[32m", "\033[31m", "\033[0m"}
}

func sensitive(key string) bool {
	return strings.Contains(key, "PASSWORD") || strings.Contains(key, "SECRET") || strings.Contains(key, "KEY")
}

func reserved(key string) bool { return strings.HasPrefix(key, envtpl.ReservedPrefix) }

var errMenuEOF = errors.New("no answer at the menu")

// readByte is one byte of In; ok is false at EOF or on an error.
func (s *Setup) readByte() (byte, bool) {
	var b [1]byte
	for {
		n, err := s.In.Read(b[:])
		if n == 1 {
			return b[0], true
		}
		if err != nil {
			return 0, false
		}
	}
}

// readValue is `read -r VALUE || true`: up to the newline, NULs dropped,
// blanks and tabs trimmed at both ends, then a trailing CR. A last line without a newline is
// still the answer. masked is `-s`: echo off while a terminal reads.
func (s *Setup) readValue(masked bool) string {
	if masked && s.TTY {
		if restore, err := term.NoEcho(s.TermFD); err == nil {
			pop := atexit.Push(func() { restore() })
			defer func() { restore(); pop() }()
		}
	}
	var b []byte
	for {
		c, ok := s.readByte()
		if !ok || c == '\n' {
			break
		}
		if c != 0 {
			b = append(b, c)
		}
	}
	return strings.TrimSuffix(strings.Trim(string(b), " \t\n"), "\r")
}

// readKey is `read -r -n 1`: one character — on a terminal without waiting
// for Enter — or nothing when it is the newline. EOF before any byte is
// errMenuEOF.
func (s *Setup) readKey() (string, error) {
	if s.TTY {
		if restore, err := term.CharMode(s.TermFD); err == nil {
			pop := atexit.Push(func() { restore() })
			defer func() { restore(); pop() }()
		}
	}
	first, ok := s.readByte()
	if !ok {
		return "", errMenuEOF
	}
	if first == '\n' {
		return "", nil
	}
	b := []byte{first}
	// The rest of a UTF-8 character: bash counts characters, not bytes.
	for want := utf8Len(first); len(b) < want; {
		c, ok := s.readByte()
		if !ok {
			break
		}
		b = append(b, c)
	}
	return string(b), nil
}

func utf8Len(lead byte) int {
	switch {
	case lead&0xE0 == 0xC0:
		return 2
	case lead&0xF0 == 0xE0:
		return 3
	case lead&0xF8 == 0xF0:
		return 4
	}
	return 1
}

// generate is `VALUE=$(eval "$CMD" || echo "")` in sh: no rc file,
// KEY/TARGET_DIR/EXAMPLE/OUTPUT exported (its functions are not available).
// A command that ends the shell ends the setup with its status.
func (s *Setup) generate(key, cmd string) (string, int) {
	script := "kasbah_value=$(eval '" + strings.ReplaceAll(cmd, "'", `'\''`) + `' || echo "") || exit; printf '%s' "$kasbah_value"`
	sh, args := "bash", []string{"--norc", "--noprofile", "-u", "-o", "pipefail", "-c", script, "setup-env.sh", s.Dir}
	if _, err := exec.LookPath("bash"); err != nil {
		sh, args = "sh", []string{"-u", "-c", script, "setup-env.sh", s.Dir}
	}
	c := exec.Command(sh, args...)
	var env []string
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); k != "BASH_ENV" && k != "ENV" {
			env = append(env, kv)
		}
	}
	c.Env = append(env, "KEY="+key, "TARGET_DIR="+s.Dir, "EXAMPLE="+s.Dir+"/.env.prod.example", "OUTPUT="+s.Dir+"/.env")
	c.Stdin, c.Stderr = s.In, s.Err
	out, err := c.Output()
	rc := 0
	if err != nil {
		rc = 1
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() > 0 {
			rc = ee.ExitCode()
		}
	}
	return strings.TrimRight(strings.ReplaceAll(string(out), "\x00", ""), "\n"), rc
}

// Run is the setup. It writes .env, or returns having changed nothing on `q`,
// on "no changes, do not reconfigure", or on EOF at a menu (SetupFail).
func (s *Setup) Run() int {
	c := s.colors()
	out := func(format string, a ...any) { fmt.Fprintf(s.Out, format, a...) }
	example := s.Dir + "/.env.prod.example"
	output := s.Dir + "/.env"

	// Regular files only: reading a FIFO would block forever.
	if fi, err := os.Stat(example); err != nil || !fi.Mode().IsRegular() {
		out("ERROR: Template not found at %s\n", example)
		return SetupFail
	}
	tmplData, err := os.ReadFile(example)
	if err != nil {
		fmt.Fprintf(s.Err, "ERROR: cannot read %s: %v\n", example, err)
		return SetupFail
	}
	template := envtpl.Lines(tmplData)

	// The live values, reserved keys aside; the last assignment wins. A .env
	// that is there but unreadable is never taken for a first run.
	existing := map[string]string{}
	if fi, err := os.Stat(output); err == nil {
		if !fi.Mode().IsRegular() {
			fmt.Fprintf(s.Err, "ERROR: %s exists and is not a regular file\n", output)
			return SetupFail
		}
		data, err := os.ReadFile(output)
		if err != nil {
			fmt.Fprintf(s.Err, "ERROR: cannot read %s: %v\n", output, err)
			return SetupFail
		}
		for _, l := range envtpl.Lines(data) {
			if l == "" || envtpl.Comment(l) {
				continue
			}
			if k, v, ok := envtpl.Assign(l); ok && !reserved(k) {
				existing[k] = v
			}
		}
	}

	updateOnly := false
	var newKeys []string
	if len(existing) > 0 {
		var tkeys []string
		tset := map[string]bool{}
		for _, l := range template {
			if k, _, ok := envtpl.Assign(l); ok && !reserved(k) {
				tkeys = append(tkeys, k)
				tset[k] = true
			}
		}
		for _, k := range tkeys {
			if _, ok := existing[k]; !ok {
				newKeys = append(newKeys, k)
			}
		}
		var dropped []string
		for k := range existing {
			if !tset[k] {
				dropped = append(dropped, k)
			}
		}
		slices.Sort(dropped)
		kept := len(tkeys) - len(newKeys)

		out("\n")
		out("    Existing .env found — %s%d kept%s, %s%d new%s, %s%d removed%s\n",
			c.green, kept, c.reset, c.yellow, len(newKeys), c.reset, c.red, len(dropped), c.reset)
		if len(newKeys) > 0 {
			out("\n    %sNew:%s\n", c.yellow, c.reset)
			for _, k := range newKeys {
				out("      + %s%s%s\n", c.bold, k, c.reset)
			}
		}
		if len(dropped) > 0 {
			out("\n    %sRemoved:%s\n", c.red, c.reset)
			for _, k := range dropped {
				out("      - %s\n", k)
			}
		}
		out("\n")
		if len(newKeys) == 0 && len(dropped) == 0 {
			out("    No changes detected — .env is in sync with template.\n\n")
			// bash's `read -p` shows its prompt on stderr, and only to a terminal.
			if s.TTY {
				fmt.Fprint(s.Err, "    Reconfigure all vars? [y/N] ")
			}
			reply, err := s.readKey()
			if err != nil {
				return s.menuEOF()
			}
			out("\n")
			if reply != "y" && reply != "Y" {
				out("\n%s%s==> .env is up to date%s\n", c.green, c.bold, c.reset)
				return SetupOK
			}
		} else {
			out("    %s[Enter]%s Configure new vars only  %s|%s  %sa%s Reconfigure all  %s|%s  %sq%s Abort: ",
				c.bold, c.reset, c.dim, c.reset, c.bold, c.reset, c.dim, c.reset, c.bold, c.reset)
			choice, err := s.readKey()
			if err != nil {
				return s.menuEOF()
			}
			out("\n")
			switch strings.Trim(choice, " \t") {
			case "q", "Q":
				out("    Aborted.\n")
				return SetupOK
			case "a", "A":
				out("\n    Reconfiguring all variables...\n")
			default:
				updateOnly = true
				if len(newKeys) > 0 {
					out("\n    Configuring %d new variable(s)...\n", len(newKeys))
				} else {
					out("\n    No new variables — regenerating .env from template...\n")
				}
			}
		}
		out("\n")
	}

	suppress := updateOnly && len(newKeys) == 0
	var lines []string
	for _, line := range template {
		switch {
		case line == "":
			lines = append(lines, "")
			continue
		case isHeader(line):
			if !suppress {
				out("\n%s%s%s%s\n", c.cyan, c.bold, line, c.reset)
			}
			lines = append(lines, line)
			continue
		case strings.HasPrefix(line, "#"):
			if !suppress {
				out("%s%s%s\n", c.dim, line, c.reset)
			}
			lines = append(lines, line)
			continue
		}
		key, raw, ok := envtpl.Assign(line)
		if !ok {
			lines = append(lines, line)
			continue
		}
		if reserved(key) {
			continue
		}
		current, has := existing[key]
		if updateOnly && has {
			lines = append(lines, key+"="+current)
			continue
		}
		masked := sensitive(key)
		var typed string
		shown := func(v string) string {
			if masked {
				return "****"
			}
			return v
		}

		var value string
		switch {
		case strings.HasPrefix(raw, "! "):
			if has {
				out("%s%s%s [%s] %s(auto)%s: ", c.bold, key, c.reset, shown(current), c.yellow, c.reset)
			} else {
				out("%s%s%s %s(auto)%s: ", c.bold, key, c.reset, c.yellow, c.reset)
			}
			value = s.answer(masked, &typed)
			if value == "" {
				if has {
					value = current
				} else {
					var rc int
					if value, rc = s.generate(key, strings.TrimPrefix(raw, "! ")); rc != 0 {
						return rc
					}
					out("    %s→ generated%s\n", c.green, c.reset)
				}
			}
		case strings.HasPrefix(raw, "# "):
			hint := strings.TrimPrefix(raw, "# ")
			if has {
				out("%s%s%s %s(%s)%s [current: %s]: ", c.bold, key, c.reset, c.dim, hint, c.reset, shown(current))
			} else {
				out("%s%s%s %s(%s)%s: ", c.bold, key, c.reset, c.dim, hint, c.reset)
			}
			value = s.answer(masked, &typed)
			if value == "" && has {
				value = current
			}
		case strings.Contains(raw, " # "):
			def, comment, _ := strings.Cut(raw, " # ")
			if has {
				def = current
			}
			out("%s%s%s [%s] %s(%s)%s: ", c.bold, key, c.reset, shown(def), c.dim, comment, c.reset)
			if value = s.answer(masked, &typed); value == "" {
				value = def
			}
		case raw == "":
			if has {
				out("%s%s%s [current: %s]: ", c.bold, key, c.reset, current)
			} else {
				out("%s%s%s: ", c.bold, key, c.reset)
			}
			value = s.answer(masked, &typed)
			if value == "" && has {
				value = current
			}
		default:
			def := raw
			if has {
				def = current
			}
			out("%s%s%s [%s]: ", c.bold, key, c.reset, shown(def))
			if value = s.answer(masked, &typed); value == "" {
				value = def
			}
		}
		// Compose reads `$` as interpolation; a kept live value is already escaped.
		if typed == "" && has {
			lines = append(lines, key+"="+value)
		} else {
			lines = append(lines, key+"="+strings.ReplaceAll(value, "$", "$$"))
		}
	}

	out("\n")
	if err := writeEnv(output, lines); err != nil {
		out("ERROR: could not write %s: %v\n", output, err)
		return SetupFail
	}
	out("%s%s==> .env written to %s%s\n", c.green, c.bold, output, c.reset)
	return SetupOK
}

// answer is one answer, also left in *typed; a masked one ends the line the
// terminal did not echo.
func (s *Setup) answer(masked bool, typed *string) string {
	v := s.readValue(masked)
	*typed = v
	if masked {
		fmt.Fprint(s.Out, "\n")
	}
	return v
}

// menuEOF is EOF at a menu: exit 1, .env untouched.
func (s *Setup) menuEOF() int {
	fmt.Fprint(s.Err, "\n")
	fmt.Fprintln(s.Err, "ERROR: no answer at the menu (end of input) — .env left untouched")
	return SetupFail
}

// isHeader is `^# *[-=]{3,}`.
func isHeader(line string) bool {
	rest, ok := strings.CutPrefix(line, "#")
	if !ok {
		return false
	}
	rest = strings.TrimLeft(rest, " ")
	n := 0
	for n < len(rest) && (rest[n] == '-' || rest[n] == '=') {
		n++
	}
	return n >= 3
}

// writeEnv renames a staging file over .env (over a symlink's target), so a
// dropped session never leaves it half-written. A .env this creates is 600 —
// it holds secrets; an existing one keeps its mode.
func writeEnv(path string, lines []string) error {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	if len(lines) == 0 {
		// printf '%s\n' with no arguments still prints the newline.
		b.WriteByte('\n')
	}
	target := path
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		if target, err = resolve(path); err != nil {
			return err
		}
	}
	mode := os.FileMode(0o600)
	if fi, err := os.Stat(target); err == nil {
		mode = fi.Mode().Perm()
	}
	tmp := target + ".kasbah-setup." + strconv.Itoa(os.Getpid())
	os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	_, err = io.WriteString(f, b.String())
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp, mode)
	}
	if err == nil {
		err = os.Rename(tmp, target)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}
