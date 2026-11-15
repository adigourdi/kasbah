package main

import (
	"fmt"
	"os"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/trace"
)

// debugEnv streams the trace as --debug does. No child kasbah inherits it
// (a --version probe would save a log of its own); a hand-off is given it.
const debugEnv = "KASBAH_DEBUG"

// debugging is this run's --debug, for a hand-off to carry on.
var debugging bool

// debugFlag takes --debug out of a workstation command's arguments, wherever
// it sits before a `--`, so no command parses it itself.
func debugFlag(args []string) ([]string, bool) {
	rest := make([]string, 0, len(args))
	on := false
	for i, a := range args {
		if a == "--" {
			rest = append(rest, args[i:]...)
			break
		}
		if a == "--debug" {
			on = true
			continue
		}
		rest = append(rest, a)
	}
	return rest, on
}

// debugOn is KASBAH_DEBUG's answer: set, and neither empty nor 0.
func debugOn(getenv func(string) string) bool {
	v := getenv(debugEnv)
	return v != "" && v != "0"
}

// beginTrace starts the workstation's trace for args and has the exit save
// its log.
func beginTrace(args []string, debug bool) {
	debugging = debug
	os.Unsetenv(debugEnv)
	v := "kasbah (unstamped build)"
	if build != "" {
		v = fmt.Sprintf("kasbah %s (schema %d)", build, manifest.Schema)
	}
	trace.Secret(os.Getenv("GITHUB_TOKEN"))
	trace.Begin(trace.Config{Debug: debug, Version: v, Args: args, Stderr: os.Stderr})
	atexit.Final(trace.Finish)
}

// remoteTrace takes trace.Marker off the end of a server arm's arguments and,
// when it was there, sends the arm's trace back on stderr.
func remoteTrace(args []string) []string {
	if n := len(args); n > 1 && args[n-1] == trace.Marker {
		trace.Serve(os.Stderr)
		return args[:n-1]
	}
	return args
}
