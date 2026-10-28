package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
)

func plantVersion(t *testing.T, root, ver string) string {
	t.Helper()
	bin := filepath.Join(root, ver, "kasbah")
	if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// The test binary lives under go's build cache, which is no checkout, so
// resolve treats it as installed.
func TestResolve(t *testing.T) {
	root := t.TempDir()
	v120 := plantVersion(t, root, "1.2.0")
	v110 := plantVersion(t, root, "1.1.0")
	v201 := plantVersion(t, root, "2.0.1")
	plantVersion(t, root, "2.0.0")
	env := func(m map[string]string) func(string) string {
		return func(k string) string { return m[k] }
	}
	lib := map[string]string{"KASBAH_LIB_DIR": root}
	newerThan := func(ours, srv string) error {
		_, err := remote.Decide(remote.Self(ours), &remote.Info{Build: srv})
		return err
	}
	newer := func(srv string) error { return newerThan("1.0.0", srv) }
	schema := func(body string) error {
		p := filepath.Join(t.TempDir(), "kasbah.yml")
		os.WriteFile(p, []byte(body), 0o644)
		_, err := manifest.Require(p, "1.0.0")
		return err
	}
	tests := []struct {
		name string
		err  error
		env  map[string]string
		want string
		said string
	}{
		{"not a hand-off", cli.Fail("boom"), lib, "", ""},
		{"nil", nil, lib, "", ""},
		{"the server's build", newer("1.1.0"), lib, v110, ""},
		{"the server's other build", newer("1.2.0"), lib, v120, ""},
		{"the server's build is not installed", newer("1.3.0"), lib, "", "install it: `kasbah self-update v1.3.0`, or ./install-dev.sh"},
		{"the server's dev build is not installed", newerThan("1.0.1-dev.5.1+gabc1234", "1.0.1-dev.9.1+g1a2b3c4"), lib, "",
			"a dev build from another checkout (1.0.1-dev.9.1+g1a2b3c4): check out and build commit 1a2b3c4 and install it"},
		{"the server's dirty dev build is not installed", newerThan("1.0.1-dev.5.1", "1.0.1-dev.9.1+g1a2b3c4.dirty"), lib, "", "commit 1a2b3c4 (built from a dirty tree"},
		{"the server's unmarked dev build is not installed", newerThan("1.0.1-dev.5.1", "1.0.1-dev.9.1"), lib, "", "build that commit and install it"},
		{"the release kept over our dev build", remote.Kept("1.1.0", "1.1.1-dev.14.1"), lib, v110, ""},
		{"the release kept is not installed", remote.Kept("1.3.0", "1.3.1-dev.14.1"), lib, "", "install it: `kasbah self-update v1.3.0`"},
		{"a newer major is no hand-off", newer("2.0.1"), lib, "", ""},
		{"the manifest's major, newest installed", schema("schema: 2\nname: demo\n"), lib, v201, ""},
		{"the manifest's major is not installed", schema("schema: 3\nname: demo\n"), lib, "", "kasbah self-update v3"},
		{"already handed off", newer("1.1.0"), map[string]string{"KASBAH_LIB_DIR": root, "KASBAH_HANDOFF": "1.0.0"}, "", "already handed off from kasbah 1.0.0"},
		{"no library root", newer("1.1.0"), map[string]string{}, "", "nor HOME"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolve(tt.err, env(tt.env))
			if got != tt.want {
				t.Errorf("resolve = %q, want %q (%v)", got, tt.want, tt.err)
			}
			if tt.said != "" && (tt.err == nil || !strings.Contains(tt.err.Error(), tt.said)) {
				t.Errorf("the refusal does not say %q: %v", tt.said, tt.err)
			}
			if strings.Contains(tt.name, "dev build") && strings.Contains(tt.err.Error(), "self-update") {
				t.Errorf("a dev build has no tag to self-update to: %v", tt.err)
			}
			if tt.err != nil {
				var e *cli.Error
				if !errors.As(tt.err, &e) || e.Code != cli.ExitFailure {
					t.Errorf("not an exit-1 refusal: %#v", tt.err)
				}
			}
		})
	}
}

// check reports its own refusals through Env.Report, so a newer schema there
// reaches the hand-off as everywhere else.
func TestCheckHandsOff(t *testing.T) {
	root := t.TempDir()
	want := plantVersion(t, root, "2.0.0")
	proj := t.TempDir()
	os.WriteFile(filepath.Join(proj, manifest.File), []byte("schema: 2\nname: demo\n"), 0o644)
	wd, _ := os.Getwd()
	os.Chdir(proj)
	t.Cleanup(func() { os.Chdir(wd) })
	var o, e strings.Builder
	out := &cli.Output{Stdout: &o, Stderr: &e}
	var got string
	code := check.Run(check.Env{Out: out, PWD: proj, Version: "1.0.0", Report: func(err error) int {
		got = resolve(err, func(k string) string { return map[string]string{"KASBAH_LIB_DIR": root}[k] })
		return out.Report(err)
	}})
	if got != want || code != cli.ExitFailure {
		t.Errorf("check's newer-schema refusal resolved to %q (exit %d); want %q, exit 1", got, code, want)
	}
}
