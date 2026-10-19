package main

import (
	"strings"
	"testing"
)

// Go takes what lib/check.sh's loop accepts without --server; everything else
// — --server, --help, an unknown argument, a lone --yes — reaches Bash.
func TestCheckArgs(t *testing.T) {
	for in, want := range map[string]string{
		"":                  "plain",
		"--fix":             "fix",
		"--fix --yes":       "fix yes",
		"--yes --fix":       "fix yes",
		"--yes --fix --fix": "fix yes",
		"--yes":             "bash",
		"--fix --server":    "bash",
		"--server=a@b":      "bash",
		"--fix --help":      "bash",
		"-h":                "bash",
		"--fix\r":           "bash",
		"--fix x":           "bash",
	} {
		var args []string
		if in != "" {
			args = strings.Split(in, " ")
		}
		fix, yes, ok := checkArgs(args)
		got := "bash"
		switch {
		case ok && fix && yes:
			got = "fix yes"
		case ok && fix:
			got = "fix"
		case ok:
			got = "plain"
		}
		if got != want {
			t.Errorf("check %q: %s, want %s", in, got, want)
		}
	}
}
