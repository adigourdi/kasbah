package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

func TestTopLevel(t *testing.T) {
	tests := []struct {
		args     []string
		code     int
		out, err string
	}{
		{nil, 0, "Usage: kasbah [--version]", ""},
		{[]string{"-h"}, 0, "server upgrade-traefik USER@HOST", ""},
		{[]string{"--help"}, 0, "init-project [--name=<n>]", ""},
		{[]string{"--version"}, 0, "kasbah 1.0.0 (schema 1)\n", ""},
		{[]string{"-v"}, 0, "kasbah 1.0.0 (schema 1)\n", ""},
		{[]string{"server"}, 1, "", "server: no subcommand given (expected: init, status, prune, backup-prune, destroy, upgrade-traefik, add-mail-domain, mail-setup-guide)"},
		{[]string{"server", "--help"}, 0, "Usage: kasbah server <subcommand>", ""},
		{[]string{"server", "-h"}, 0, "  init USER@HOST [flags]", ""},
		{[]string{"server", "statsu"}, 1, "", "server: unknown subcommand 'statsu'"},
		{[]string{"deplyo"}, 1, "", "unknown command 'deplyo'"},
	}
	for _, tt := range tests {
		var so, se bytes.Buffer
		code := topLevel(&cli.Output{Stdout: &so, Stderr: &se}, "1.0.0", tt.args)
		if code != tt.code || !strings.Contains(so.String(), tt.out) || !strings.Contains(se.String(), tt.err) {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", tt.args, code, so.String(), se.String())
		}
	}
	var so bytes.Buffer
	if topLevel(&cli.Output{Stdout: &so, Stderr: &so}, "", []string{"--version"}); so.String() != "kasbah (unstamped build)\n" {
		t.Errorf("unstamped --version: %q", so.String())
	}
}

// Every command main dispatches is in the usage, and every `server`
// subcommand in both lists.
func TestUsageListsEveryCommand(t *testing.T) {
	u := usage("1.0.0")
	for _, c := range []string{"init-project", "check", "build-push", "deploy", "rollback", "drop", "history", "pending", "changelog", "env", "logs", "exec", "migrate"} {
		if !strings.Contains(u, "\n  "+c+" ") {
			t.Errorf("usage does not list %s", c)
		}
	}
	for _, s := range serverSubcommands {
		if !strings.Contains(u, "\n  server "+s+" ") || !strings.Contains(serverUsage, "\n  "+s+" ") {
			t.Errorf("a usage does not list server %s", s)
		}
	}
}
