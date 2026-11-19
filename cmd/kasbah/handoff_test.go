package main

import (
	"errors"
	"io/fs"
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
	older := func(min, ver string) error {
		p := filepath.Join(t.TempDir(), "kasbah.yml")
		os.WriteFile(p, []byte("schema: 1\nname: demo\nmin_kasbah: "+min+"\n"), 0o644)
		_, err := manifest.Require(p, ver)
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
		{"the server's build is not installed", newer("1.3.0"), lib, "", "Install it: `kasbah self-update v1.3.0`, or ./install-dev.sh"},
		{"the server's dev build is not installed", newerThan("1.0.1-dev.5.1+gabc1234", "1.0.1-dev.9.1+g1a2b3c4"), lib, "",
			"a dev build from another checkout (1.0.1-dev.9.1+g1a2b3c4): check out and build commit 1a2b3c4 and install it"},
		{"the server's dirty dev build is not installed", newerThan("1.0.1-dev.5.1", "1.0.1-dev.9.1+g1a2b3c4.dirty"), lib, "", "commit 1a2b3c4 (built from a dirty tree"},
		{"the server's unmarked dev build is not installed", newerThan("1.0.1-dev.5.1", "1.0.1-dev.9.1"), lib, "", "build that commit and install it"},
		{"the release kept over our dev build", remote.Kept("1.1.0", "1.1.1-dev.14.1"), lib, v110, ""},
		{"the release kept is not installed", remote.Kept("1.3.0", "1.3.1-dev.14.1"), lib, "", "Install it: `kasbah self-update v1.3.0`"},
		{"a newer major is no hand-off", newer("2.0.1"), lib, "", ""},
		{"the manifest's major, newest installed", schema("schema: 2\nname: demo\n"), lib, v201, ""},
		{"the manifest's major is not installed", schema("schema: 3\nname: demo\n"), lib, "", "kasbah self-update v3"},
		{"min_kasbah, newest of its major that meets it", older("1.1.0", "1.0.0"), lib, v120, ""},
		{"min_kasbah met by the newest installed", older("1.2.0", "1.1.0"), lib, v120, ""},
		{"min_kasbah of the next major", older("2.0.1", "1.2.0"), lib, v201, ""},
		{"min_kasbah above every install of its major, a newer major installed", older("1.3.0", "1.2.0"), lib, "",
			"kasbah 1.3.0 or a newer 1.x is not installed on this workstation (nothing under " + root + ")"},
		{"min_kasbah not installed keeps its remedy", older("1.3.0", "1.2.0"), lib, "", "`kasbah self-update v1.3.0`"},
		{"min_kasbah of an unstamped build", older("1.1.0", "dev"), lib, v120, ""},
		{"min_kasbah already handed off", older("1.1.0", "1.0.0"), map[string]string{"KASBAH_LIB_DIR": root, "KASBAH_HANDOFF": "1.0.0"}, "", "already handed off from kasbah 1.0.0"},
		{"already handed off", newer("1.1.0"), map[string]string{"KASBAH_LIB_DIR": root, "KASBAH_HANDOFF": "1.0.0"}, "", "already handed off from kasbah 1.0.0"},
		{"no library root", newer("1.1.0"), map[string]string{}, "", "nor HOME"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolve(tt.err, env(tt.env))
			if got != tt.want {
				t.Errorf("resolve = %q, want %q (%v)", got, tt.want, tt.err)
			}
			if tt.said != "" && (tt.err == nil || !strings.Contains(shown(tt.err), tt.said)) {
				t.Errorf("the refusal does not say %q: %s", tt.said, shown(tt.err))
			}
			if strings.Contains(tt.name, "dev build") && strings.Contains(shown(tt.err), "self-update") {
				t.Errorf("a dev build has no tag to self-update to: %s", shown(tt.err))
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

// A min_kasbah hand-off never goes to a build ranked at or below the running
// one, though a dev build there may meet more than the running release does.
func TestResolveMeetingAboveRunning(t *testing.T) {
	root := t.TempDir()
	dev := plantVersion(t, root, "1.2.1-dev.5.1")
	plantVersion(t, root, "1.2.0")
	saved := build
	t.Cleanup(func() { build = saved })
	getenv := func(k string) string { return map[string]string{"KASBAH_LIB_DIR": root}[k] }
	for running, want := range map[string]string{"1.2.0": dev, "1.2.1": ""} {
		build = running
		p := filepath.Join(t.TempDir(), "kasbah.yml")
		os.WriteFile(p, []byte("schema: 1\nname: demo\nmin_kasbah: 1.2.2\n"), 0o644)
		_, err := manifest.Require(p, running)
		if got := resolve(err, getenv); got != want {
			t.Errorf("running %s: resolve = %q, want %q", running, got, want)
		}
		if want == "" && !strings.Contains(shown(err), "kasbah 1.2.2 or a newer 1.x is not installed") {
			t.Errorf("running %s: the refusal does not say none is installed: %s", running, shown(err))
		}
	}
}

// A checkout build refuses a min_kasbah it does not meet, however many
// installed versions meet it.
func TestResolveFromCheckout(t *testing.T) {
	root := t.TempDir()
	plantVersion(t, root, "1.2.0")
	co := t.TempDir()
	os.MkdirAll(filepath.Join(co, "cmd", "kasbah"), 0o755)
	os.MkdirAll(filepath.Join(co, "dist"), 0o755)
	os.WriteFile(filepath.Join(co, "go.mod"), []byte("module x\n"), 0o644)
	os.WriteFile(filepath.Join(co, "dist", "kasbah"), nil, 0o755)
	saved := executable
	executable = func() (string, error) { return filepath.Join(co, "dist", "kasbah"), nil }
	t.Cleanup(func() { executable = saved })
	p := filepath.Join(t.TempDir(), "kasbah.yml")
	for ver, said := range map[string]string{
		"1.0.0": "and this kasbah is 1.0.0",
		"dev":   "this kasbah carries no build stamp",
	} {
		os.WriteFile(p, []byte("schema: 1\nname: demo\nmin_kasbah: 1.1.0\n"), 0o644)
		_, err := manifest.Require(p, ver)
		if got := resolve(err, func(k string) string { return map[string]string{"KASBAH_LIB_DIR": root}[k] }); got != "" {
			t.Errorf("a checkout handed off to %s", got)
		}
		msg := shown(err)
		for _, want := range []string{said, "this kasbah runs from a checkout, which does not hand off to an installed version",
			"Check out and build kasbah 1.1.0 or a newer 1.x, or run an installed kasbah."} {
			if !strings.Contains(msg, want) {
				t.Errorf("%s: the refusal does not say %q:\n%s", ver, want, msg)
			}
		}
	}
}

// shown is err as the terminal shows it, next step and help line included.
func shown(err error) string {
	var b strings.Builder
	(&cli.Output{Stdout: &b, Stderr: &b}).Report(err)
	return b.String()
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
	// S09 the same way.
	want = plantVersion(t, root, "1.3.0")
	os.WriteFile(filepath.Join(proj, manifest.File), []byte("schema: 1\nname: demo\nmin_kasbah: 1.3.0\n"), 0o644)
	got = ""
	code = check.Run(check.Env{Out: out, PWD: proj, Version: "1.0.0", Report: func(err error) int {
		got = resolve(err, func(k string) string { return map[string]string{"KASBAH_LIB_DIR": root}[k] })
		return out.Report(err)
	}})
	if got != want || code != cli.ExitFailure {
		t.Errorf("check's min_kasbah refusal resolved to %q (exit %d); want %q, exit 1", got, code, want)
	}
}

// Only a directory that is gone gets the cd step.
func TestCwdFailed(t *testing.T) {
	gone := shown(cwdFailed(&os.PathError{Op: "getwd", Path: ".", Err: fs.ErrNotExist}))
	if !strings.Contains(gone, "error: cannot read the current directory: getwd .: file does not exist\n"+
		"       The directory this shell is in is gone: cd into the project again.\n") {
		t.Errorf("a removed directory: %s", gone)
	}
	other := shown(cwdFailed(&os.PathError{Op: "getwd", Path: ".", Err: fs.ErrPermission}))
	if !strings.Contains(other, "error: cannot read the current directory: getwd .: permission denied\n") || strings.Contains(other, "cd into") {
		t.Errorf("another failure: %s", other)
	}
}
