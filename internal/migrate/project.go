package migrate

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/state"
)

var reVersionLine = regexp.MustCompile(`(?m)^kasbah_version:[^\r\n]*`)
var reSchemaLine = regexp.MustCompile(`(?m)^schema:[^\n]*\n`)

// stampManifest sets kasbah.yml's kasbah_version to ours, after schema: when
// the line is absent, in the file's own line ending; the rest is kept byte
// for byte.
func stampManifest(path, ours string) error {
	body, err := os.ReadFile(path)
	if err != nil {
		return cli.Fail("could not read %s: %v", path, err)
	}
	fi, _ := os.Stat(path)
	line := "kasbah_version: " + ours
	var out []byte
	switch {
	case reVersionLine.Match(body):
		out = reVersionLine.ReplaceAll(body, []byte(line))
	case reSchemaLine.Match(body):
		loc := reSchemaLine.FindIndex(body)
		eol := "\n"
		if loc[1] >= 2 && body[loc[1]-2] == '\r' {
			eol = "\r\n"
		}
		out = append(append(append([]byte{}, body[:loc[1]]...), []byte(line+eol)...), body[loc[1]:]...)
	default:
		return cli.Fail("%s has no schema: line to write kasbah_version after", path)
	}
	if err := writeAtomic(path, out, fi.Mode().Perm()); err != nil {
		return cli.Fail("%v", err)
	}
	return nil
}

// RunProject is `kasbah migrate` in a project at root: kasbah.yml's schema
// to manifest.Schema through steps, kasbah_version stamped, each step
// recorded in state.json's schema_migrations_applied. A newer schema is
// manifest's own refusal, which hands off.
func RunProject(w io.Writer, root, ours string, steps []Step) error {
	mf := root + "/" + manifest.File
	m, err := manifest.Require(mf, ours)
	if err != nil {
		return err
	}
	from, err := strconv.Atoi(m.Schema)
	if err != nil {
		return cli.Fail("%s: schema '%s' is not a number this kasbah can migrate from", mf, m.Schema)
	}
	if from == manifest.Schema {
		fmt.Fprintf(w, "nothing to migrate: %s is at schema %d, which is this kasbah's\n", manifest.File, from)
		return nil
	}
	plan, err := Plan(steps, from, manifest.Schema)
	if err != nil {
		return cli.Fail("%s: %v", mf, err)
	}
	for _, s := range plan {
		sr, err := apply(root, s)
		if err != nil {
			return cli.Fail("%v", err).Cont("a rerun picks up where this stopped: every file already rewritten is skipped")
		}
		for _, f := range sr.Files {
			fmt.Fprintf(w, "step %d->%d: %s %s\n", s.From, s.To, f.Path, f.Action)
		}
		if err := state.Append(root+"/"+state.File, ours, "schema_migrations_applied", fmt.Sprintf("%d->%d", s.From, s.To)); err != nil {
			return err
		}
	}
	if err := stampManifest(mf, ours); err != nil {
		return err
	}
	fmt.Fprintf(w, "migrated %s from schema %d to %d (kasbah_version %s)\n", manifest.File, from, manifest.Schema, ours)
	return nil
}
