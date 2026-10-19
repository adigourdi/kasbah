package env

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/term"
)

// RemoteUsage names the server half's modes: `kasbah remote setup-env MODE …`.
const RemoteUsage = "usage: kasbah remote setup-env prepare DIR | drift DIR | setup DIR [--color=yes|no] | inject DIR KASBAH_NAME=value…"

// Remote is `kasbah remote setup-env` on a server. stdout is a protocol in
// every mode but setup, whose prompts are the operator's over ssh -t;
// diagnostics go to stderr.
func Remote(args []string, stdin *os.File, stdout, stderr io.Writer) int {
	if len(args) < 2 || args[1] == "" {
		fmt.Fprintln(stderr, RemoteUsage)
		return 1
	}
	mode, dir := args[0], strings.TrimSuffix(args[1], "/")
	if dir == "" {
		dir = "/"
	}
	switch {
	case mode == "prepare" && len(args) == 2:
		// The project directory under an apps path that must already exist,
		// so rsync has somewhere to land.
		if fi, err := os.Stat(parent(dir)); err != nil || !fi.IsDir() {
			fmt.Fprintf(stderr, "remote: %s is not a directory\n", parent(dir))
			return 1
		}
		if err := os.MkdirAll(dir, 0o777); err != nil {
			fmt.Fprintf(stderr, "remote: could not create %s\n", dir)
			return 1
		}
		fmt.Fprintln(stdout, "prepared=yes")
		return 0
	case mode == "drift" && len(args) == 2:
		r, err := Report(dir)
		if err != nil {
			fmt.Fprintf(stderr, "ERROR: %v\n", err)
			return 1
		}
		fmt.Fprint(stdout, r)
		return 0
	case mode == "setup" && (len(args) == 2 || len(args) == 3 && strings.HasPrefix(args[2], "--color=")):
		// The workstation decides colour: NO_COLOR does not cross ssh.
		color := term.IsTerminal(1) && os.Getenv("NO_COLOR") == ""
		if len(args) == 3 {
			color = args[2] == "--color=yes"
		}
		s := &Setup{Dir: dir, In: stdin, Out: stdout, Err: stderr, TTY: term.IsTerminal(0), TermFD: 0, Color: color}
		return s.Run()
	case mode == "inject" && len(args) >= 2:
		return Inject(dir+"/.env", args[2:], stderr)
	}
	fmt.Fprintln(stderr, RemoteUsage)
	return 1
}

func parent(dir string) string {
	i := strings.LastIndex(dir, "/")
	if i <= 0 {
		return "/"
	}
	return dir[:i]
}
