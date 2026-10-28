package migrate

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/remote"
)

// Remote is `kasbah remote migrate --apps=DIR --version=OURS [--undo]`, run by
// the server binary under remote.Outlive: one JSON report on stdout.
func Remote(args []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	var apps, ours string
	undo := false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--apps="):
			apps = strings.TrimPrefix(a, "--apps=")
		case strings.HasPrefix(a, "--version="):
			ours = strings.TrimPrefix(a, "--version=")
		case a == "--undo":
			undo = true
		default:
			return fail("usage: kasbah remote migrate --apps=DIR --version=OURS [--undo]")
		}
	}
	if !strings.HasPrefix(apps, "/") || apps == "/" || ours == "" {
		return fail("usage: kasbah remote migrate --apps=DIR --version=OURS [--undo]")
	}
	w, done := remote.Outlive(stderr)
	defer done()
	var r *Report
	var err error
	if undo {
		r, err = Undo(apps)
	} else {
		r, err = Run(apps, ours, Server, time.Now())
	}
	if err != nil {
		fmt.Fprintf(w, "remote: %v\n", err)
		return 1
	}
	b, _ := json.Marshal(r)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}
