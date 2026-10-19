// Command kasbah is the kasbah CLI. The commands it owns run here; every
// other one is handed to the Bash dispatcher, which replaces this process.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/handoff"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// build is stamped at build time: -ldflags "-X main.build=…".
var build string

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "remote":
			// The server has no Bash tree: `remote` is never handed off.
			os.Exit(remoteCmd(args[1:]))
		case "__ensure-server":
			out := cli.Std()
			atexit.HandleSignals()
			code := out.Report(ensureServer(out, args[1:]))
			if c := atexit.Interrupted(); c != 0 {
				code = c
			}
			atexit.Exit(code)
		case "check":
			// Plain `check` and --fix [--yes]; anything with --server, --help
			// or an argument check does not take is still the Bash tool's.
			if fix, yes, ok := checkArgs(args[1:]); ok {
				atexit.HandleSignals()
				atexit.Exit(checkCmd(fix, yes))
			}
		case "init-project":
			// --help falls through: the usage text is still the Bash tool's.
			if o, err := initproject.Parse(args[1:]); err != initproject.ErrHelp {
				atexit.HandleSignals()
				atexit.Exit(initProjectCmd(o, err))
			}
		}
	}

	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasbah: cannot locate this binary: %v\n", err)
		os.Exit(1)
	}
	dispatcher, err := handoff.Locate(exe, os.Getenv)
	if err != nil {
		// A server binary has no dispatcher, and --version is still a question
		// it can answer.
		if len(args) == 1 && (args[0] == "--version" || args[0] == "-v") {
			fmt.Printf("kasbah %s\n", buildOrUnknown())
			os.Exit(0)
		}
		fmt.Fprintf(os.Stderr, "kasbah: %v\n", err)
		os.Exit(1)
	}
	err = handoff.Exec(dispatcher, args, handoff.Env(os.Environ(), build))
	fmt.Fprintf(os.Stderr, "kasbah: cannot run %s: %v\n", dispatcher, err)
	os.Exit(126)
}

func buildOrUnknown() string {
	if build == "" {
		return "(unstamped build)"
	}
	return build
}

func remoteCmd(args []string) int {
	out := cli.Std()
	if len(args) == 1 && args[0] == "version" {
		fmt.Fprintln(out.Stdout, remote.Self(build).Line())
		return cli.ExitOK
	}
	if len(args) == 2 && args[0] == "install-self" {
		exe, err := os.Executable()
		if err != nil {
			return out.Report(cli.Fail("cannot locate this binary: %v", err))
		}
		return out.Report(serverbin.InstallSelf(remote.Self(build), exe, args[1], out.Stdout))
	}
	sub := "(none)"
	if len(args) > 0 {
		sub = args[0]
	}
	return out.Report(cli.Fail("remote: unknown subcommand '%s' — `kasbah remote` is what a workstation runs on a server, and this binary knows: version, install-self", sub))
}

// ensureServer is `kasbah __ensure-server [--apps-path=<dir>] USER@HOST`: the
// server binary's newer-wins rule on its own, for the rig suites. One result
// line on stdout. --apps-path is the bootstrap mode: no discovery, no marker.
func ensureServer(out *cli.Output, args []string) error {
	var opt serverbin.Options
	if len(args) == 2 && strings.HasPrefix(args[0], "--apps-path=") {
		opt.Apps = strings.TrimPrefix(args[0], "--apps-path=")
		if opt.Apps == "" {
			return cli.Fail("--apps-path= must not be empty")
		}
		args = args[1:]
	}
	if len(args) != 1 {
		return cli.Fail("usage: kasbah __ensure-server [--apps-path=<dir>] USER@HOST")
	}
	exe, err := os.Executable()
	if err != nil {
		return cli.Fail("cannot locate this binary: %v", err)
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return cli.Fail("%v", err)
	}
	c, err := ssh.Connect(args[0])
	if err != nil {
		return err
	}
	defer c.Close()
	res, err := serverbin.Ensure(c, remote.Self(build), func(arch string) (string, error) {
		return serverbin.Local(home, checkout, arch)
	}, opt)
	if err != nil {
		return err
	}
	if res.Action == remote.Keep {
		fmt.Fprintf(out.Stdout, "kept=%s\n", res.Now)
		return nil
	}
	old := res.Old
	if old == "" {
		old = "none"
	}
	fmt.Fprintf(out.Stdout, "shipped=%s->%s\n", old, res.Now)
	return nil
}

// kasbahVersion is VERSION as the Bash dispatcher reads it: from
// KASBAH_LIB_DIR when set, else from where this binary's files live. It is
// what files kasbah writes record, never the build stamp.
func kasbahVersion() (string, error) {
	dir := os.Getenv("KASBAH_LIB_DIR")
	if dir == "" {
		exe, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("cannot locate this binary: %v", err)
		}
		if dir, _, err = handoff.Home(exe, os.Getenv); err != nil {
			return "", err
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, "VERSION"))
	if err != nil {
		return "", fmt.Errorf("cannot read VERSION: %v", err)
	}
	return strings.TrimRight(string(b), "\n"), nil
}

// checkArgs accepts what lib/check.sh's loop does without --server: --fix and
// --yes in any order and number, --yes only with --fix.
func checkArgs(args []string) (fix, yes, ok bool) {
	for _, a := range args {
		switch a {
		case "--fix":
			fix = true
		case "--yes":
			yes = true
		default:
			return false, false, false
		}
	}
	return fix, yes, fix || !yes
}

func checkCmd(fix, yes bool) int {
	out := cli.Std()
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return out.Report(cli.Fail("cannot read the current directory: %v", err))
	}
	code := check.Run(check.Env{Out: out, PWD: pwd, Version: v, Fix: fix, Yes: yes})
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func initProjectCmd(o initproject.Options, err error) int {
	out := cli.Std()
	if err != nil {
		return out.Report(err)
	}
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return out.Report(cli.Fail("cannot read the current directory: %v", err))
	}
	code := out.Report(initproject.Run(out, o, pwd, v))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}
