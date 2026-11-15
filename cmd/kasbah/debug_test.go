package main

import (
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/trace"
)

func TestDebugFlag(t *testing.T) {
	for _, tt := range []struct {
		in, want []string
		on       bool
	}{
		{[]string{"deploy", "--debug", "u@h"}, []string{"deploy", "u@h"}, true},
		{[]string{"--debug", "info"}, []string{"info"}, true},
		{[]string{"info"}, []string{"info"}, false},
		{[]string{"exec", "web", "--", "app", "--debug"}, []string{"exec", "web", "--", "app", "--debug"}, false},
		{[]string{"deploy", "--debug=1"}, []string{"deploy", "--debug=1"}, false},
	} {
		got, on := debugFlag(tt.in)
		if !slices.Equal(got, tt.want) || on != tt.on {
			t.Errorf("debugFlag(%q) = %q, %v", tt.in, got, on)
		}
	}
	for v, want := range map[string]bool{"": false, "0": false, "1": true, "yes": true} {
		if got := debugOn(func(string) string { return v }); got != want {
			t.Errorf("KASBAH_DEBUG=%q: %v", v, got)
		}
	}
}

func TestRemoteTrace(t *testing.T) {
	t.Cleanup(trace.Reset)
	if got := remoteTrace([]string{"remote", "version"}); !slices.Equal(got, []string{"remote", "version"}) {
		t.Errorf("no marker: %q", got)
	}
	if got := remoteTrace([]string{"remote", "deploy", "run", "/apps/x", trace.Marker}); !slices.Equal(got, []string{"remote", "deploy", "run", "/apps/x"}) {
		t.Errorf("marker: %q", got)
	}
}

// GITHUB_TOKEN is read before the trace begins, and still never recorded;
// KASBAH_DEBUG reaches no child kasbah, but a hand-off is given --debug.
func TestBeginTrace(t *testing.T) {
	t.Cleanup(trace.Reset)
	t.Cleanup(func() { debugging = false })
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("GITHUB_TOKEN", "ghp_never-in-the-trace-42")
	t.Setenv(debugEnv, "1")
	beginTrace([]string{"self-update", "--token=ghp_never-in-the-trace-42"}, false)
	trace.Note("asked with ghp_never-in-the-trace-42")
	if tr := trace.Text(); strings.Contains(tr, "ghp_never") || !strings.Contains(tr, "asked with ***") {
		t.Errorf("trace:\n%s", tr)
	}
	if got := trace.CommandLine([]string{"x", "ghp_never-in-the-trace-42"}); strings.Contains(got, "ghp_never") {
		t.Errorf("command line: %s", got)
	}
	if v, set := os.LookupEnv(debugEnv); set {
		t.Errorf("children inherit %s=%q", debugEnv, v)
	}
	handoffEnv()
	if os.Getenv(debugEnv) != "" {
		t.Errorf("a hand-off of a run without --debug turns it on")
	}
	debugging = true
	handoffEnv()
	if os.Getenv(debugEnv) != "1" {
		t.Errorf("a hand-off of a --debug run loses it")
	}
}
