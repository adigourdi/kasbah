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
	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/destroy"
	"github.com/adigourdi/kasbah/internal/drop"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/handoff"
	"github.com/adigourdi/kasbah/internal/history"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/ops"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/prune"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/status"
	"github.com/adigourdi/kasbah/internal/term"
	"github.com/adigourdi/kasbah/internal/upgrade"
	"github.com/adigourdi/kasbah/internal/vlog"
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
			if len(args) > 1 && args[1] == "init" {
				os.Exit(serverinit.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "mail" {
				os.Exit(mail.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "backup" {
				// The kasbah-backup container's process (D2): restic's image,
				// this binary mounted from the apps path.
				os.Exit(backup.NewRunner(os.Stdout, os.Stderr).Run(args[2:]))
			}
			if len(args) > 1 && args[1] == "backup-init" {
				// A signal removes the probe's credential scratch on the way out.
				atexit.HandleSignals()
				atexit.Exit(backup.RemoteInit(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "status" {
				os.Exit(status.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "check" {
				os.Exit(check.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "prune" {
				os.Exit(prune.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "traefik" {
				// dry-run: a signal, a dropped session's SIGHUP included, removes
				// the throwaway on the way out. start ignores SIGHUP and SIGPIPE
				// itself, so its rollback outlives the session.
				atexit.HandleSignals()
				atexit.Exit(upgrade.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "drop" {
				os.Exit(drop.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "destroy" {
				os.Exit(destroy.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "vlog" {
				os.Exit(vlog.Remote(args[2:], os.Stdout, os.Stderr))
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
			o, err := deploy.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(deployCmd("deploy", o, err))
		case "rollback":
			o, err := deploy.ParseRollback(args[1:])
			atexit.HandleSignals()
			atexit.Exit(deployCmd("rollback", o, err))
		case "history", "pending", "changelog":
			o, err := history.Parse(args[0], args[1:])
			atexit.HandleSignals()
			atexit.Exit(historyCmd(o, err))
		case "logs", "exec":
			o, err := ops.Parse(args[0], args[1:])
			atexit.HandleSignals()
			atexit.Exit(opsCmd(o, err))
		case "drop":
			o, err := drop.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(dropCmd(o, err))
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
		case "server":
			if len(args) > 1 && args[1] == "init" {
				serverInitCmd(args[2:])
			}
			if len(args) > 1 && args[1] == "backup-prune" {
				o, err := backup.ParsePrune(args[2:])
				atexit.HandleSignals()
				atexit.Exit(backupPruneCmd(o, err))
			}
			if len(args) > 1 && args[1] == "status" {
				o, err := status.Parse(args[2:])
				atexit.HandleSignals()
				atexit.Exit(statusCmd(o, err))
			}
			if len(args) > 1 && args[1] == "prune" {
				o, err := prune.Parse(args[2:])
				atexit.HandleSignals()
				atexit.Exit(pruneCmd(o, err))
			}
			if len(args) > 1 && args[1] == "destroy" {
				o, err := destroy.Parse(args[2:])
				atexit.HandleSignals()
				atexit.Exit(destroyCmd(o, err))
			}
			if len(args) > 1 && args[1] == "upgrade-traefik" {
				o, err := upgrade.Parse(args[2:])
				atexit.HandleSignals()
				atexit.Exit(upgradeCmd(o, err))
			}
			if len(args) > 1 && (args[1] == "add-mail-domain" || args[1] == "mail-setup-guide") {
				o, err := mail.Parse(args[1], args[2:])
				atexit.HandleSignals()
				atexit.Exit(mailCmd(o, err))
			}
		case "check":
			o, err := check.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(checkCmd(o, err))
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
	return out.Report(cli.Fail("remote: unknown subcommand '%s' — `kasbah remote` is what a workstation runs on a server, and this binary knows: version, install-self, marker, setup-env, load, deploy, vlog, init, mail, backup, backup-init, status, check, prune, traefik, drop, destroy", sub))
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

// serverInitCmd runs `server init` to its exit.
func serverInitCmd(args []string) {
	out := cli.Std()
	atexit.HandleSignals()
	o, err := serverinit.Parse(args)
	if err != nil {
		atexit.Exit(out.Report(err))
	}
	if o.Help {
		fmt.Fprint(out.Stdout, serverinit.Usage)
		atexit.Exit(cli.ExitOK)
	}
	p := prompt.Std(out)
	mail, bk, err := serverinit.Features(p, o)
	if err != nil {
		atexit.Exit(out.Report(err))
	}
	o.Mail, o.Backup = prompt.No, prompt.No
	if mail {
		o.Mail = prompt.Yes
	}
	if bk {
		o.Backup = prompt.Yes
	} else {
		serverinit.FlagsUnused(out, o)
	}
	code := out.Report(serverInit(out, p, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	atexit.Exit(code)
}

// backupPruneCmd is `server backup-prune`: restic runs here, never on the
// server — the full-access credential stays on this machine.
func backupPruneCmd(o backup.PruneOptions, err error) int {
	out := cli.Std()
	if err != nil {
		return out.Report(err)
	}
	if o.Help {
		fmt.Fprint(out.Stdout, backup.PruneUsage)
		return cli.ExitOK
	}
	exe, err := os.Executable()
	if err != nil {
		return out.Report(cli.Fail("cannot locate this binary: %v", err))
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return out.Report(cli.Fail("%v", err))
	}
	code := out.Report(backup.Prune(backup.PruneCtx{
		Out:      out,
		Prompter: prompt.Std(out),
		Dial: backup.DialPrune(remote.Self(build), func(arch string) (string, error) {
			return serverbin.Local(home, checkout, arch)
		}),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func serverInit(out *cli.Output, p *prompt.Prompter, o serverinit.Options) error {
	v, err := kasbahVersion()
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return cli.Fail("cannot locate this binary: %v", err)
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return cli.Fail("%v", err)
	}
	return serverinit.Run(serverinit.Ctx{
		Out:       out,
		Prompter:  p,
		Version:   v,
		Templates: templatesDir(home),
		Self:      remote.Self(build),
		Local:     func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) },
		Hash:      serverinit.Bcrypt,
		Now:       time.Now,
	}, o)
}

// templatesDir is the dispatcher's rule: templates travel with the library
// directory.
func templatesDir(home string) string {
	if tpl := os.Getenv("KASBAH_TEMPLATE_DIR"); tpl != "" {
		return tpl
	}
	lib := os.Getenv("KASBAH_LIB_DIR")
	if lib == "" {
		lib = home
	}
	return filepath.Join(lib, "templates")
}

// mailCmd is `server add-mail-domain` and `server mail-setup-guide`.
func mailCmd(o mail.Options, err error) int {
	out := cli.Std()
	if err == mail.ErrHelp {
		if o.Cmd == "add-mail-domain" {
			fmt.Fprint(out.Stdout, mail.AddUsage)
		} else {
			fmt.Fprint(out.Stdout, mail.GuideUsage)
		}
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
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
	code := out.Report(mail.Run(mail.Ctx{
		Out:       out,
		Templates: templatesDir(home),
		Dial:      mail.DialSSH(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
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

func checkCmd(o check.Options, err error) int {
	out := cli.Std()
	if err == check.ErrHelp {
		fmt.Fprint(out.Stdout, check.Usage())
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
	target, err := check.Target(o)
	if err != nil {
		return out.Report(err)
	}
	e := check.Env{Out: out, PWD: pwd, Version: v, Fix: o.Fix, Yes: o.Yes, Server: target}
	if target != "" {
		exe, err := os.Executable()
		if err != nil {
			return out.Report(cli.Fail("cannot locate this binary: %v", err))
		}
		home, checkout, err := handoff.Home(exe, os.Getenv)
		if err != nil {
			return out.Report(cli.Fail("%v", err))
		}
		e.Dial = check.Dial(remote.Self(build), func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) })
	}
	code := check.Run(e)
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func statusCmd(o status.Options, err error) int {
	out := cli.Std()
	if err == status.ErrHelp {
		fmt.Fprint(out.Stdout, status.Usage())
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
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
	code := out.Report(status.Run(status.Ctx{Out: out, Version: v, Dial: status.Dial(remote.Self(build), local)}, o))
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

func deployCmd(cmd string, o deploy.Options, err error) int {
	out := cli.Std()
	if err == deploy.ErrHelp {
		if cmd == "rollback" {
			fmt.Fprint(out.Stdout, deploy.RollbackUsage())
		} else {
			fmt.Fprint(out.Stdout, deploy.Usage())
		}
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
	c := deploy.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		PWD:      pwd,
		Version:  v,
		TTYIn:    term.IsTerminal(0),
		TTYOut:   term.IsTerminal(1),
		Color:    term.IsTerminal(1) && os.Getenv("NO_COLOR") == "",
		Dial:     deploy.DialSSH(remote.Self(build), local),
		Now:      time.Now,
	}
	var rerr error
	switch {
	case cmd == "rollback":
		rerr = deploy.RunTagged(c, o, "rollback")
	case o.Version != "":
		rerr = deploy.RunTagged(c, o, "deploy")
	default:
		rerr = deploy.Run(c, o)
	}
	code := out.Report(rerr)
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

func historyCmd(o history.Options, err error) int {
	out := cli.Std()
	if err == history.ErrHelp {
		fmt.Fprint(out.Stdout, history.Usage(o.Cmd))
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
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
	code := out.Report(history.Run(history.Ctx{
		Out:     out,
		Version: v,
		Dial:    history.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

// localBinary is serverbin.Local for this installation.
func localBinary() (func(arch string) (string, error), error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, cli.Fail("cannot locate this binary: %v", err)
	}
	home, checkout, err := handoff.Home(exe, os.Getenv)
	if err != nil {
		return nil, cli.Fail("%v", err)
	}
	return func(arch string) (string, error) { return serverbin.Local(home, checkout, arch) }, nil
}

// opsCmd is `logs` and `exec`: the exit status is the stream's.
func opsCmd(o ops.Options, err error) int {
	out := cli.Std()
	if err == ops.ErrHelp {
		fmt.Fprint(out.Stdout, ops.Usage(o.Cmd))
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
	}
	local, err := localBinary()
	if err != nil {
		return out.Report(err)
	}
	fed := false
	if fi, err := os.Stdin.Stat(); err == nil {
		fed = fi.Mode()&os.ModeNamedPipe != 0 || fi.Mode().IsRegular()
	}
	code, err := ops.Run(ops.Ctx{
		Out:     out,
		Version: v,
		TTY:     term.IsTerminal(0) && term.IsTerminal(1),
		Fed:     fed,
		Dial:    ops.Dial(remote.Self(build), local),
	}, o)
	if err != nil {
		code = out.Report(err)
		if c := atexit.Interrupted(); c != 0 {
			code = c
		}
	}
	return code
}

func pruneCmd(o prune.Options, err error) int {
	out := cli.Std()
	if err == prune.ErrHelp {
		fmt.Fprint(out.Stdout, prune.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	local, err := localBinary()
	if err != nil {
		return out.Report(err)
	}
	code := out.Report(prune.Run(prune.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		Dial:     prune.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func upgradeCmd(o upgrade.Options, err error) int {
	out := cli.Std()
	if err == upgrade.ErrHelp {
		fmt.Fprint(out.Stdout, upgrade.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
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
	code := out.Report(upgrade.Run(upgrade.Ctx{
		Out:       out,
		Templates: templatesDir(home),
		Dial:      upgrade.Dial(remote.Self(build), local),
		Now:       time.Now,
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func dropCmd(o drop.Options, err error) int {
	out := cli.Std()
	if err == drop.ErrHelp {
		fmt.Fprint(out.Stdout, drop.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	v, err := kasbahVersion()
	if err != nil {
		return out.Report(err)
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
	code := out.Report(drop.Run(drop.Ctx{
		Out:       out,
		Prompter:  prompt.Std(out),
		Version:   v,
		Templates: templatesDir(home),
		Dial:      drop.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func destroyCmd(o destroy.Options, err error) int {
	out := cli.Std()
	if err == destroy.ErrHelp {
		fmt.Fprint(out.Stdout, destroy.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	local, err := localBinary()
	if err != nil {
		return out.Report(err)
	}
	code := out.Report(destroy.Run(destroy.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		Dial:     destroy.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}
