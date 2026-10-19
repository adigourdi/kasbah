// Command kasbah is the kasbah CLI. The commands it owns run here; every
// other one is handed to the Bash dispatcher, which replaces this process.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/handoff"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/term"
)

// build is stamped at build time: -ldflags "-X main.build=…".
var build string

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "remote":
			// The server has no Bash tree: `remote` is never handed off.
			if len(args) > 1 && args[1] == "load" {
				// A signal abandons the docker load rather than let it finish
				// on a stream that was cut short.
				atexit.HandleSignals()
				atexit.Exit(buildpush.Load(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "setup-env" {
				// Interactive over ssh -t: a signal restores the terminal and
				// removes any staging file on the way out.
				atexit.HandleSignals()
				atexit.Exit(env.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "deploy" {
				// The lock is the kernel's and goes with the process; the
				// handlers run a backup's partial-file cleanup.
				atexit.HandleSignals()
				atexit.Exit(deploy.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			os.Exit(remoteCmd(args[1:]))
		case "build-push":
			o, err := buildpush.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(buildPushCmd(o, err))
		case "deploy":
			// `deploy VERSION` is the tagged path, still the Bash tool's.
			if !deploy.Tagged(args[1:]) {
				o, err := deploy.Parse(args[1:])
				atexit.HandleSignals()
				atexit.Exit(deployCmd(o, err))
			}
		case "env":
			o, err := env.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(envCmd(o, err))
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
	if len(args) == 2 && args[0] == "marker" {
		body, err := marker.ReadLocal(args[1])
		if err != nil {
			fmt.Fprintf(out.Stderr, "remote: %v\n", err)
			return cli.ExitFailure
		}
		out.Stdout.Write(body)
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
	return out.Report(cli.Fail("remote: unknown subcommand '%s' — `kasbah remote` is what a workstation runs on a server, and this binary knows: version, install-self, marker, setup-env, load, deploy", sub))
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

func buildPushCmd(o buildpush.Options, err error) int {
	out := cli.Std()
	if err == buildpush.ErrHelp {
		fmt.Fprint(out.Stdout, buildpush.Usage())
		return cli.ExitOK
	}
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
	exe, err := os.Executable()
	if err != nil {
		return out.Report(cli.Fail("cannot locate this binary: %v", err))
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return out.Report(cli.Fail("%v", err))
	}
	code := out.Report(buildpush.Run(buildpush.Ctx{
		Out:     out,
		PWD:     pwd,
		Version: v,
		Self:    remote.Self(build),
		Local:   func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) },
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func deployCmd(o deploy.Options, err error) int {
	out := cli.Std()
	if err == deploy.ErrHelp {
		fmt.Fprint(out.Stdout, deploy.Usage())
		return cli.ExitOK
	}
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
	exe, err := os.Executable()
	if err != nil {
		return out.Report(cli.Fail("cannot locate this binary: %v", err))
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return out.Report(cli.Fail("%v", err))
	}
	local := func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) }
	code := out.Report(deploy.Run(deploy.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		PWD:      pwd,
		Version:  v,
		TTYIn:    term.IsTerminal(0),
		TTYOut:   term.IsTerminal(1),
		Color:    term.IsTerminal(1) && os.Getenv("NO_COLOR") == "",
		Dial:     deploy.DialSSH(remote.Self(build), local),
		Now:      time.Now,
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func envCmd(o env.Options, err error) int {
	out := cli.Std()
	if err == env.ErrHelp {
		fmt.Fprint(out.Stdout, env.Usage())
		return cli.ExitOK
	}
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
	exe, err := os.Executable()
	if err != nil {
		return out.Report(cli.Fail("cannot locate this binary: %v", err))
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return out.Report(cli.Fail("%v", err))
	}
	local := func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) }
	code := out.Report(env.Run(env.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		PWD:      pwd,
		Version:  v,
		TTYIn:    term.IsTerminal(0),
		TTYOut:   term.IsTerminal(1),
		Color:    term.IsTerminal(1) && os.Getenv("NO_COLOR") == "",
		Dial:     env.DialSSH(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}
