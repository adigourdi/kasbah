package trace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Keep is how many logs the directory holds; writing one removes the oldest.
const Keep = 20

type logState struct {
	version string
	args    []string
	getenv  func(string) string
	now     func() time.Time
	path    string
	file    *os.File // open from its O_EXCL create to the exit, for the rewrite
	err     error
	saved   bool
}

// Dir is where logs go: $XDG_STATE_HOME/kasbah/logs, else
// ~/.local/state/kasbah/logs. A relative XDG_STATE_HOME is ignored, as the
// XDG spec has it.
func Dir(getenv func(string) string) (string, error) {
	if s := getenv("XDG_STATE_HOME"); filepath.IsAbs(s) {
		return filepath.Join(s, "kasbah", "logs"), nil
	}
	home := getenv("HOME")
	if home == "" {
		return "", fmt.Errorf("neither XDG_STATE_HOME nor HOME is set")
	}
	return filepath.Join(home, ".local", "state", "kasbah", "logs"), nil
}

// Latest is the newest log in dir, "" when there is none.
func Latest(dir string) string {
	logs := list(dir)
	if len(logs) == 0 {
		return ""
	}
	return filepath.Join(dir, logs[len(logs)-1])
}

var reLog = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}\.[0-9]{3}Z-[a-z0-9-]+(\.[0-9]+)?\.log$`)

// list is dir's logs, oldest first: their names start with the UTC time.
func list(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if e.Type().IsRegular() && reLog.MatchString(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// Name is a log's file name: the run's start in UTC, then the command.
func Name(start time.Time, args []string) string {
	return start.UTC().Format("20060102T150405.000Z") + "-" + Command(args) + ".log"
}

var reWord = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// Command is the command a log is named after: its first word, with the
// second for `server …`, `env set` and `migrate server`; "kasbah" for none.
func Command(args []string) string {
	words := []string{}
	for _, a := range args {
		if !reWord.MatchString(a) {
			break
		}
		words = append(words, a)
	}
	switch {
	case len(words) == 0:
		return "kasbah"
	case len(words) > 1 && (words[0] == "server" || words[0] == "env" && words[1] == "set" || words[0] == "migrate" && words[1] == "server"):
		return strings.TrimPrefix(words[0]+"-"+words[1], "-")
	}
	return words[0]
}

// secretFlag is a flag whose value is a credential, as is every `--env=`
// entry: the log's command line shows its name only.
var secretFlag = regexp.MustCompile(`(?i)(password|token|secret|auth|backup-env|repo-base)`)

// CommandLine is args as a log's header shows them: a secret flag's value
// and every registered secret replaced.
func CommandLine(args []string) string { return Scrub(commandLine(args)) }

func commandLine(args []string) string {
	out := make([]string, len(args))
	for i, a := range args {
		if name, _, ok := strings.Cut(a, "="); ok && strings.HasPrefix(name, "-") && (secretFlag.MatchString(name) || name == "--env") {
			a = name + "=" + Redacted
		}
		out[i] = a
	}
	return "kasbah " + Words(out)
}

// Failed saves the log of a run failing with code and returns its path; ""
// and nil when no workstation trace is running. A later Finish rewrites it
// whole.
func Failed(code int) (string, error) {
	st.mu.Lock()
	on := st.on
	st.mu.Unlock()
	if !on {
		return "", nil
	}
	return save(code)
}

// Finish is the run's end, for atexit: the log Failed saved is rewritten
// with everything since; a debug run's, or one a signal ended, is saved now.
// Its path is named on stderr when nothing named it yet.
func Finish(code int, signalled bool) {
	st.mu.Lock()
	on, saved, debug, w := st.on, st.log.saved, st.debug, st.stderr
	st.mu.Unlock()
	if !on || !saved && !debug && !signalled {
		return
	}
	if !saved && w != nil {
		path, err := save(code)
		switch {
		case err != nil:
			fmt.Fprintf(w, "log: not saved (%v)\n", err)
		case debug && !signalled:
			fmt.Fprintf(w, "debug: log: %s\n", path)
		default:
			fmt.Fprintf(w, "log: %s\n", path)
		}
		return
	}
	save(code)
}

// save writes the log, 0600 in a 0700 directory, and prunes past Keep.
func save(code int) (string, error) {
	st.mu.Lock()
	l := &st.log
	if l.saved {
		path, f := l.path, l.file
		body := header(l, code) + st.kept.String()
		st.mu.Unlock()
		err := f.Truncate(0)
		if err == nil {
			_, err = f.WriteAt([]byte(body), 0)
		}
		return path, err
	}
	if l.err != nil {
		st.mu.Unlock()
		return "", l.err
	}
	dir, err := Dir(l.getenv)
	if err == nil {
		err = mkdirs(dir)
	}
	var f *os.File
	var path string
	if err == nil {
		base := strings.TrimSuffix(Name(st.start, l.args), ".log")
		for i := 0; ; i++ {
			path = filepath.Join(dir, base+".log")
			if i > 0 {
				path = filepath.Join(dir, fmt.Sprintf("%s.%d.log", base, i))
			}
			f, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
			if err == nil || !os.IsExist(err) || i > 99 {
				break
			}
		}
	}
	if err != nil {
		l.err = err
		st.mu.Unlock()
		return "", err
	}
	l.path, l.file, l.saved = path, f, true
	body := header(l, code) + st.kept.String()
	st.mu.Unlock()
	_, err = io.WriteString(f, body)
	prune(dir)
	return path, err
}

func closeLog() {
	if st.log.file != nil {
		st.log.file.Close()
	}
}

func header(l *logState, code int) string {
	return fmt.Sprintf("%s\ncommand: %s\nstarted: %s\nexit: %d\n\n",
		l.version, scrub(commandLine(l.args)), st.start.UTC().Format(time.RFC3339), code)
}

// mkdirs makes dir and any directory above it that is missing 0700, as the
// XDG spec asks; one that exists is left as it is.
func mkdirs(dir string) error { return os.MkdirAll(dir, 0o700) }

func prune(dir string) {
	logs := list(dir)
	for len(logs) > Keep {
		os.Remove(filepath.Join(dir, logs[0]))
		logs = logs[1:]
	}
}
