// Package trace is the record of what a run did: every external command with
// its exit status and stderr, every ssh call, every `kasbah remote` arm and
// the server's own half, and the decisions worth knowing (docs/cli.md
// "Debugging a failure"). The workstation keeps it in memory, streams it to
// stderr under --debug, and saves it as a log when the run fails; a server
// arm called with --trace sends its lines back as frames on stderr, which the
// workstation folds in and strips. Secrets never enter it: stdin and stdout
// are never recorded, and every value registered through Secret is replaced
// before a line is kept.
package trace

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// Marker is the word a workstation appends to a server arm's command line to
// have its trace sent back; the server strips it before dispatch.
const Marker = "--trace"

// frame opens a server's trace line on its stderr: an ASCII record separator
// no other output carries, then a tag.
const frame = "\x1ekasbah-trace "

// maxKept bounds the trace a workstation holds; past it lines still stream.
const maxKept = 8 << 20

// maxFrame keeps a frame within one atomic pipe write (PIPE_BUF).
const maxFrame = 4000

// Redacted replaces a secret in every recorded line.
const Redacted = "***"

// minSecret is the shortest value scrubbed: shorter ones ("1", "yes") cannot
// be told from ordinary text, and are never recorded in the first place.
const minSecret = 4

var st struct {
	mu      sync.Mutex
	on      bool // a workstation recording
	server  bool // a server arm sending frames
	debug   bool
	stderr  io.Writer
	start   time.Time
	kept    bytes.Buffer
	full    bool
	seq     int
	secrets map[string]bool
	repl    *strings.Replacer
	log     logState
}

// Config is a workstation run's.
type Config struct {
	// Debug streams the trace to Stderr as it is recorded.
	Debug bool
	// Version is the header's version line; Args the command line after
	// kasbah, its global flags taken out.
	Version string
	Args    []string
	Stderr  io.Writer
	Getenv  func(string) string
	Now     func() time.Time
}

// Begin starts a workstation run's trace.
func Begin(c Config) {
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Getenv == nil {
		c.Getenv = os.Getenv
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	st.on, st.server, st.debug, st.stderr = true, false, c.Debug, c.Stderr
	st.start = c.Now()
	st.kept.Reset()
	st.full, st.seq = false, 0
	closeLog()
	st.log = logState{version: c.Version, args: append([]string{}, c.Args...), getenv: c.Getenv, now: c.Now}
}

// Serve starts a server arm's trace: each line goes out as a frame on stderr.
func Serve(stderr io.Writer) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.on, st.server, st.stderr, st.start = false, true, stderr, time.Now()
}

// Reset ends any trace; for tests.
func Reset() {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.on, st.server, st.debug, st.stderr = false, false, false, nil
	st.kept.Reset()
	st.secrets, st.repl = nil, nil
	closeLog()
	st.log = logState{}
}

func active() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.on || st.server
}

// Debug reports a run streaming its trace.
func Debug() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.on && st.debug
}

// Secret registers values never to appear in the trace or a log: a .env
// value, a password, a token. Empty and very short ones are ignored. A value
// registered before Begin or Serve is kept for the trace they start.
func Secret(vals ...string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	added := false
	var all []string
	for _, v := range vals {
		all = append(all, v)
		// A trace line is one line: a multi-line value is caught line by line.
		if strings.ContainsAny(v, "\n\r") {
			all = append(all, strings.FieldsFunc(v, func(r rune) bool { return r == '\n' || r == '\r' })...)
		}
	}
	for _, v := range all {
		v = strings.TrimSpace(v)
		if len(v) < minSecret || st.secrets[v] {
			continue
		}
		if st.secrets == nil {
			st.secrets = map[string]bool{}
		}
		st.secrets[v], added = true, true
	}
	if !added {
		return
	}
	// Longest first, so a secret holding another is replaced whole.
	all = make([]string, 0, len(st.secrets))
	for v := range st.secrets {
		all = append(all, v)
	}
	sort.Slice(all, func(i, j int) bool {
		if len(all[i]) != len(all[j]) {
			return len(all[i]) > len(all[j])
		}
		return all[i] < all[j]
	})
	pairs := make([]string, 0, 2*len(all))
	for _, v := range all {
		pairs = append(pairs, v, Redacted)
	}
	st.repl = strings.NewReplacer(pairs...)
}

// Scrub is s with every registered secret replaced.
func Scrub(s string) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return scrub(s)
}

func scrub(s string) string {
	if st.repl == nil {
		return s
	}
	return st.repl.Replace(s)
}

// Note records a decision: which binary a server keeps, a hand-off.
func Note(format string, args ...any) {
	record("note: " + fmt.Sprintf(format, args...))
}

// record keeps one line, streams it under --debug, or sends it as a frame.
func record(text string) { put(text, true) }

// put is record; stream false keeps a line from the debug stream because the
// operator already sees it.
func put(text string, stream bool) {
	text = strings.NewReplacer("\n", " ", "\r", " ").Replace(text)
	st.mu.Lock()
	defer st.mu.Unlock()
	text = scrub(text)
	switch {
	case st.server:
		if len(text) > maxFrame {
			text = text[:maxFrame] + "…"
		}
		if st.stderr != nil {
			io.WriteString(st.stderr, frame+text+"\n")
		}
	case st.on:
		line := fmt.Sprintf("%8.3f %s\n", time.Since(st.start).Seconds(), text)
		if !st.full {
			if st.kept.Len()+len(line) > maxKept {
				st.full = true
				st.kept.WriteString("         (trace truncated here: over 8 MiB)\n")
			} else {
				st.kept.WriteString(line)
			}
		}
		if st.debug && stream && st.stderr != nil {
			io.WriteString(st.stderr, "debug: "+line)
		}
	}
}

// Text is the trace so far.
func Text() string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.kept.String()
}

func next() int {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.seq++
	return st.seq
}

// Words is argv as the trace shows it: a word with a blank, a quote or a
// shell operator single-quoted.
func Words(argv []string) string {
	q := make([]string, len(argv))
	for i, w := range argv {
		if w != "" && !strings.ContainsAny(w, " \t\n'\"\\$`|&;<>()#") {
			q[i] = w
			continue
		}
		q[i] = "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
	}
	return strings.Join(q, " ")
}
