// Package migrate moves kasbah's files across a major: the server's, under
// `kasbah migrate server USER@HOST` (docs/server-setup.md → Server marker),
// and a project's, under `kasbah migrate` (docs/project-manifest.md). A Step
// is one major to the next, idempotent per file from the file's own version
// stamp; the newest binary carries every step and runs them in order.
package migrate

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// Step rewrites the files of one major into the next.
type Step struct {
	From, To int
	// Desc is the plan's one line about the step.
	Desc string
	// Files lists the files the step rewrites, relative to the tree's root
	// (the apps path, or the project root); one that is absent is skipped.
	Files func(root string) ([]string, error)
	// Major reads a file's own version stamp; a file at To or above is
	// skipped, so a run that died halfway finishes on the next.
	Major func(body []byte) (int, error)
	// Rewrite is the step's transform of one file's bytes.
	Rewrite func(body []byte) ([]byte, error)
}

// Server is the server chain. 0.x state is 1.x state (docs/overview.md →
// Version compatibility), so 0→1 rewrites nothing and only the marker moves.
var Server = []Step{{
	From: 0, To: 1,
	Desc:    "rewrites no file (0.x server state is 1.x state); the marker's kasbah_version moves to this build's",
	Files:   func(string) ([]string, error) { return nil, nil },
	Major:   func([]byte) (int, error) { return 0, nil },
	Rewrite: func(b []byte) ([]byte, error) { return b, nil },
}}

// Project is the project chain: schema 1 is the first, so it is empty.
var Project []Step

// Plan is the steps that take a tree from major from to major to, in order.
func Plan(steps []Step, from, to int) ([]Step, error) {
	if from > to {
		return nil, fmt.Errorf("major %d is newer than this kasbah's %d — nothing migrates downwards", from, to)
	}
	var out []Step
	for cur := from; cur < to; {
		next := -1
		for i, s := range steps {
			if s.From == cur && s.To > cur && (next < 0 || s.To < steps[next].To) {
				next = i
			}
		}
		if next < 0 || steps[next].To > to {
			return nil, fmt.Errorf("this kasbah carries no migration step from major %d", cur)
		}
		out = append(out, steps[next])
		cur = steps[next].To
	}
	return out, nil
}

// FileResult is what a step did to one file.
type FileResult struct {
	Path   string `json:"path"`
	Action string `json:"action"`
}

// StepReport is what one step did.
type StepReport struct {
	From  int          `json:"from"`
	To    int          `json:"to"`
	Files []FileResult `json:"files"`
}

// writeAtomic renders data to a temp file beside path and renames it over,
// with mode; a reader never sees a half-written file.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, data, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not write %s: %v", tmp, err)
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not set the mode of %s: %v", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not install %s: %v", path, err)
	}
	return nil
}

// apply runs one step over its files under root, each rewritten only when
// its own stamp is below the step's To.
func apply(root string, s Step) (StepReport, error) {
	r := StepReport{From: s.From, To: s.To, Files: []FileResult{}}
	files, err := s.Files(root)
	if err != nil {
		return r, fmt.Errorf("step %d->%d could not list its files: %v", s.From, s.To, err)
	}
	for _, rel := range files {
		path := filepath.Join(root, rel)
		fi, err := os.Stat(path)
		if os.IsNotExist(err) {
			r.Files = append(r.Files, FileResult{rel, "absent"})
			continue
		}
		if err != nil || !fi.Mode().IsRegular() {
			return r, fmt.Errorf("step %d->%d: %s is not a regular file", s.From, s.To, path)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return r, fmt.Errorf("step %d->%d could not read %s: %v", s.From, s.To, path, err)
		}
		at, err := s.Major(body)
		if err != nil {
			return r, fmt.Errorf("step %d->%d cannot tell the version of %s: %v", s.From, s.To, path, err)
		}
		if at >= s.To {
			r.Files = append(r.Files, FileResult{rel, "skipped"})
			continue
		}
		out, err := s.Rewrite(body)
		if err != nil {
			return r, fmt.Errorf("step %d->%d failed on %s: %v", s.From, s.To, path, err)
		}
		if err := writeAtomic(path, out, fi.Mode().Perm()); err != nil {
			return r, fmt.Errorf("step %d->%d: %v", s.From, s.To, err)
		}
		r.Files = append(r.Files, FileResult{rel, "rewritten"})
	}
	return r, nil
}

// files is the union of every step's files under root, in step order, each once.
func files(root string, steps []Step) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, s := range steps {
		fs, err := s.Files(root)
		if err != nil {
			return nil, fmt.Errorf("step %d->%d could not list its files: %v", s.From, s.To, err)
		}
		for _, f := range fs {
			if !seen[f] {
				seen[f] = true
				out = append(out, f)
			}
		}
	}
	return out, nil
}
