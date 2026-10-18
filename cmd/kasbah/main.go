// Command kasbah is the kasbah CLI. Every command it does not own yet is
// handed to the Bash dispatcher, which replaces this process.
package main

import (
	"fmt"
	"os"

	"github.com/adigourdi/kasbah/internal/handoff"
)

// build is stamped at build time: -ldflags "-X main.build=…".
var build string

func main() {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasbah: cannot locate this binary: %v\n", err)
		os.Exit(1)
	}
	dispatcher, err := handoff.Locate(exe, os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasbah: %v\n", err)
		os.Exit(1)
	}
	err = handoff.Exec(dispatcher, os.Args[1:], handoff.Env(os.Environ(), build))
	fmt.Fprintf(os.Stderr, "kasbah: cannot run %s: %v\n", dispatcher, err)
	os.Exit(126)
}
