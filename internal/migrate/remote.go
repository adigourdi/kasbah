package migrate

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
)

// ProbeReport is `kasbah remote migrate --probe`'s: what the plan's steps
// will cost, in order. Stops is each file a step cannot rewrite, which
// refuses the run before its snapshot; Warnings each step's Warn's Lost,
// Notes its Notes.
type ProbeReport struct {
	Stops    []string `json:"stops"`
	Warnings []string `json:"warnings"`
	Notes    []string `json:"notes"`
}

// ProbeKeys is what a ProbeReport must carry to be one (remote.Decode).
var ProbeKeys = []string{"stops", "warnings", "notes"}

// Probe is what every step from the marker's major to ours will cost, each
// step's files judged as the run judges them, as they are now — exact only
// while no step before the last rewrites a file: read-only and under no
// lock; nothing when there is nothing to migrate.
func Probe(apps, ours string, steps []Step) (*ProbeReport, error) {
	m, _, err := readMarker(apps)
	if err != nil {
		return nil, err
	}
	from, to, err := Majors(m, ours)
	if err != nil {
		return nil, err
	}
	r := &ProbeReport{Stops: []string{}, Warnings: []string{}, Notes: []string{}}
	if from >= to {
		return r, nil
	}
	plan, err := Plan(steps, from, to)
	if err != nil {
		return nil, err
	}
	for _, s := range plan {
		if s.Files != nil {
			_, _, err := prepare(apps, s)
			if st := (stop{}); errors.As(err, &st) {
				r.Stops = append(r.Stops, fmt.Sprintf("stops the migration at %s: it %s", st.rel, st.why))
			} else if err != nil {
				r.Stops = append(r.Stops, fmt.Sprintf("whether step %d->%d can rewrite its files is unjudged: %v", s.From, s.To, err))
			}
		}
		if s.Warn != nil {
			c := s.Warn(apps)
			r.Warnings = append(r.Warnings, c.Lost...)
			r.Notes = append(r.Notes, c.Notes...)
		}
	}
	return r, nil
}

// Remote is `kasbah remote migrate --apps=DIR --version=OURS [--undo|--probe]`,
// run by the server binary under remote.Outlive: one JSON report on stdout.
func Remote(args []string, stdout, stderr io.Writer) int {
	const usage = "usage: kasbah remote migrate --apps=DIR --version=OURS [--undo|--probe]"
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	var apps, ours string
	undo, probe := false, false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--apps="):
			apps = strings.TrimPrefix(a, "--apps=")
		case strings.HasPrefix(a, "--version="):
			ours = strings.TrimPrefix(a, "--version=")
		case a == "--undo":
			undo = true
		case a == "--probe":
			probe = true
		default:
			return fail(usage)
		}
	}
	if !strings.HasPrefix(apps, "/") || apps == "/" || ours == "" || undo && probe {
		return fail(usage)
	}
	if probe {
		r, err := Probe(apps, ours, Server)
		if err != nil {
			return fail("%s", cli.Full(err))
		}
		b, _ := json.Marshal(r)
		fmt.Fprintf(stdout, "%s\n", b)
		return 0
	}
	w, done := remote.Outlive(stderr)
	defer done()
	var r *Report
	var err error
	if undo {
		r, err = Undo(apps, Server)
	} else {
		r, err = Run(apps, ours, Server, time.Now())
	}
	var rf refused
	if errors.As(err, &rf) {
		fmt.Fprintf(w, "remote: %s\n", rf.Error())
		b, _ := json.Marshal(rf.Refusal)
		fmt.Fprintf(stdout, "%s\n", b)
		return ExitRefused
	}
	if err != nil {
		if r != nil && len(r.Steps) > 0 {
			fmt.Fprintf(w, "remote: before it stopped:\n")
			printSteps(w, r.Steps)
		}
		fmt.Fprintf(w, "remote: %s\n", cli.Full(err))
		if errors.As(err, new(partway)) {
			return ExitPartway
		}
		return 1
	}
	b, _ := json.Marshal(r)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}
