// Command kasbah is the kasbah CLI, on the workstation and, under the hidden
// `kasbah remote …` subcommands, on every server it manages.
package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
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
	"github.com/adigourdi/kasbah/internal/history"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/migrate"
	"github.com/adigourdi/kasbah/internal/ops"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/prune"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/selfupdate"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/status"
	"github.com/adigourdi/kasbah/internal/term"
	"github.com/adigourdi/kasbah/internal/treesync"
	"github.com/adigourdi/kasbah/internal/upgrade"
	"github.com/adigourdi/kasbah/internal/version"
	"github.com/adigourdi/kasbah/internal/vlog"
	"github.com/adigourdi/kasbah/templates"
)

// build is stamped at build time: -ldflags "-X main.build=…".
var build string

// argv is the command line a hand-off re-runs, and shipDev the answer it
// carries in devEnv.
var (
	argv    = os.Args[1:]
	shipDev string
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] != "remote" {
		rest, answer, err := answerShipDev(prompt.Std(cli.Std()), args, os.Getenv)
		if err != nil {
			os.Exit(cli.Std().Report(err))
		}
		args, argv, shipDev = rest, rest, answer
	}
	if len(args) > 0 {
		switch args[0] {
		case "remote":
			// Group-writable by default: every operator is in the kasbah group,
			// and setgid directories give what is created here that group.
			syscall.Umask(0o002)
			if len(args) > 1 && args[1] == "lock" {
				os.Exit(serverlock.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "load" {
				// A signal abandons the docker load rather than let it finish
				// on a stream that was cut short.
				atexit.HandleSignals()
				atexit.Exit(buildpush.Load(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "layers" {
				os.Exit(buildpush.Layers(args[2:], os.Stdout, os.Stderr))
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
			if len(args) > 1 && args[1] == "sync" {
				// A dropped session ends the stream and SIGHUP/SIGPIPE are
				// ignored, so the file in flight is removed, never installed;
				// SIGINT and SIGTERM remove it through atexit.
				atexit.HandleSignals()
				atexit.Exit(treesync.Remote(args[2:], os.Stdin, os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "vlog" {
				os.Exit(vlog.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "migrate" {
				// Snapshot, rewrites and the marker outlive a dropped session
				// (remote.Outlive); the locks go with the process.
				os.Exit(migrate.Remote(args[2:], os.Stdout, os.Stderr))
			}
			if len(args) > 1 && args[1] == "deploy" {
				// run and prepare outlive a dropped session (SIGHUP and
				// SIGPIPE ignored, remote.Outlive); SIGINT and SIGTERM still
				// remove a partial backup. The lock goes with the process.
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
		case "__sync":
			out := cli.Std()
			atexit.HandleSignals()
			atexit.Exit(report(out, syncCmd(args[1:])))
		case "__install":
			out := cli.Std()
			atexit.HandleSignals()
			atexit.Exit(report(out, installCmd(out, args[1:])))
		case "__pick-tag":
			out := cli.Std()
			atexit.HandleSignals()
			atexit.Exit(report(out, pickTagCmd(out, args[1:], os.Stdin)))
		case "__ensure-server":
			out := cli.Std()
			atexit.HandleSignals()
			code := report(out, ensureServer(out, args[1:]))
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
		case "migrate":
			o, err := migrate.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(migrateCmd(o, err))
		case "self-update":
			o, err := selfupdate.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(selfUpdateCmd(o, err))
		case "check":
			o, err := check.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(checkCmd(o, err))
		case "init-project":
			o, err := initproject.Parse(args[1:])
			atexit.HandleSignals()
			atexit.Exit(initProjectCmd(o, err))
		}
	}

	os.Exit(topLevel(cli.Std(), build, args))
}

func remoteCmd(args []string) int {
	out := cli.Std()
	if len(args) == 1 && args[0] == "version" {
		fmt.Fprintln(out.Stdout, remote.Self(build).Line())
		return cli.ExitOK
	}
	// Kept for 1.0.0 workstations, which read the marker this way.
	if len(args) == 2 && args[0] == "marker" {
		body, err := marker.ReadLocal(args[1])
		if err != nil {
			fmt.Fprintf(out.Stderr, "remote: %v\n", err)
			return cli.ExitFailure
		}
		out.Stdout.Write(body)
		return cli.ExitOK
	}
	if len(args) == 3 && args[0] == "install-self" && strings.HasPrefix(args[2], "--over=") {
		exe, err := os.Executable()
		if err != nil {
			return report(out, cli.Fail("cannot locate this binary: %v", err))
		}
		return report(out, serverbin.InstallSelf(remote.Self(build), exe, args[1], strings.TrimPrefix(args[2], "--over="), out.Stdout))
	}
	sub := "(none)"
	if len(args) > 0 {
		sub = args[0]
	}
	return report(out, cli.Fail("remote: unknown subcommand '%s' — `kasbah remote` is what a workstation runs on a server, and this binary knows: version, install-self, marker, setup-env, load, deploy, sync, vlog, init, mail, backup, backup-init, status, check, prune, traefik, drop, destroy, migrate", sub))
}

// ensureServer is `kasbah __ensure-server [--apps-path=<dir>] USER@HOST`: the
// server binary's same-build rule on its own, for the rig suites. One result
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
	local, err := localBinary()
	if err != nil {
		return err
	}
	c, err := ssh.Connect(args[0])
	if err != nil {
		return err
	}
	defer c.Close()
	res, err := serverbin.Ensure(c, remote.Self(build), local, opt)
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

// syncCmd is the hidden `kasbah __sync USER@HOST dir|file|fragment SRC DEST`:
// one sync exactly as deploy ships a sync: entry or the fragment, for the
// rig's parity suite against rsync.
func syncCmd(args []string) error {
	if len(args) != 4 {
		return cli.Fail("usage: kasbah __sync USER@HOST dir|file|fragment SRC DEST")
	}
	var src *treesync.Source
	var err error
	switch args[1] {
	case "dir":
		src, err = treesync.Dir(args[2], os.Stderr)
	case "file":
		src, err = treesync.File(args[2], os.Stderr)
	case "fragment":
		src, err = treesync.Fixed(args[2], 0o644)
	default:
		return cli.Fail("usage: kasbah __sync USER@HOST dir|file|fragment SRC DEST")
	}
	if err != nil {
		return cli.Fail("%v", err)
	}
	local, err := localBinary()
	if err != nil {
		return err
	}
	c, err := ssh.Connect(args[0])
	if err != nil {
		return err
	}
	defer c.Close()
	res, err := serverbin.Ensure(c, remote.Self(build), local, serverbin.Options{})
	if err != nil {
		return err
	}
	if err := treesync.Push(c, serverbin.Path(res.Apps), src, args[3]); err != nil {
		return cli.Fail("could not sync %s to %s:%s", args[2], args[0], args[3]).Cont(err.Error())
	}
	return nil
}

// serverInitCmd runs `server init` to its exit.
func serverInitCmd(args []string) {
	out := cli.Std()
	atexit.HandleSignals()
	o, err := serverinit.Parse(args)
	if err != nil {
		atexit.Exit(report(out, err))
	}
	if o.Help {
		fmt.Fprint(out.Stdout, serverinit.Usage)
		atexit.Exit(cli.ExitOK)
	}
	p := prompt.Std(out)
	mail, bk, err := serverinit.Features(p, o)
	if err != nil {
		atexit.Exit(report(out, err))
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
	code := report(out, serverInit(out, p, o))
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
		return report(out, err)
	}
	if o.Help {
		fmt.Fprint(out.Stdout, backup.PruneUsage)
		return cli.ExitOK
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, backup.Prune(backup.PruneCtx{
		Out:      out,
		Prompter: prompt.Std(out),
		Dial:     backup.DialPrune(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func serverInit(out *cli.Output, p *prompt.Prompter, o serverinit.Options) error {
	v, err := kasbahVersion(true)
	if err != nil {
		return err
	}
	local, err := localBinary()
	if err != nil {
		return err
	}
	return serverinit.Run(serverinit.Ctx{
		Out:       out,
		Prompter:  p,
		Version:   v,
		Templates: templates.FS,
		Self:      remote.Self(build),
		Local:     local,
		Hash:      serverinit.Bcrypt,
		Now:       time.Now,
	}, o)
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
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, mail.Run(mail.Ctx{
		Out:       out,
		Templates: templates.FS,
		Dial:      mail.DialSSH(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

// kasbahVersion is the VERSION this binary was built from: what files kasbah
// writes record, never the build stamp. An unstamped build has none, so only
// a command that writes no file of its own runs on one.
func kasbahVersion(writes bool) (string, error) {
	if build == "" {
		if !writes {
			return "unstamped", nil
		}
		return "", cli.Fail("this kasbah carries no build stamp, so it cannot record which version wrote its files").Cont(
			"build it with `docker compose run --rm build`, which stamps it")
	}
	v, err := version.Base(build)
	if err != nil {
		return "", cli.Fail("%v", err)
	}
	return v, nil
}

func checkCmd(o check.Options, err error) int {
	out := cli.Std()
	if err == check.ErrHelp {
		fmt.Fprint(out.Stdout, check.Usage())
		return cli.ExitOK
	}
	if err != nil {
		return report(out, err)
	}
	v, err := kasbahVersion(o.Fix)
	if err != nil {
		return report(out, err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return report(out, cli.Fail("cannot read the current directory: %v", err))
	}
	target, err := check.Target(o)
	if err != nil {
		return report(out, err)
	}
	e := check.Env{Out: out, PWD: pwd, Version: v, Fix: o.Fix, Yes: o.Yes, Server: target,
		Report: func(err error) int { return report(out, err) }}
	if target != "" {
		local, err := localBinary()
		if err != nil {
			return report(out, err)
		}
		e.Dial = check.Dial(remote.Self(build), local)
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
		return report(out, err)
	}
	v, err := kasbahVersion(false)
	if err != nil {
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, status.Run(status.Ctx{Out: out, Version: v, Dial: status.Dial(remote.Self(build), local)}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func initProjectCmd(o initproject.Options, err error) int {
	out := cli.Std()
	if err == initproject.ErrHelp {
		fmt.Fprint(out.Stdout, initproject.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return report(out, cli.Fail("cannot read the current directory: %v", err))
	}
	code := report(out, initproject.Run(out, o, pwd, v))
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
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return report(out, cli.Fail("cannot read the current directory: %v", err))
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, buildpush.Run(buildpush.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		PWD:      pwd,
		Version:  v,
		Self:     remote.Self(build),
		Local:    local,
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
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return report(out, cli.Fail("cannot read the current directory: %v", err))
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
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
	code := report(out, rerr)
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

func envCmd(o env.Options, err error) int {
	out := cli.Std()
	if err == env.ErrHelp && o.Set {
		fmt.Fprint(out.Stdout, env.SetUsage())
		return cli.ExitOK
	}
	if err == env.ErrHelp {
		fmt.Fprint(out.Stdout, env.Usage())
		return cli.ExitOK
	}
	if err != nil {
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	pwd, err := os.Getwd()
	if err != nil {
		return report(out, cli.Fail("cannot read the current directory: %v", err))
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, env.Run(env.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		PWD:      pwd,
		Version:  v,
		TTYIn:    term.IsTerminal(0),
		TTYOut:   term.IsTerminal(1),
		Color:    term.IsTerminal(1) && os.Getenv("NO_COLOR") == "",
		Dial:     env.DialSSH(remote.Self(build), local),
		DialSet:  env.DialSetSSH(remote.Self(build), local),
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
		return report(out, err)
	}
	v, err := kasbahVersion(false)
	if err != nil {
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, history.Run(history.Ctx{
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
	return serverbin.LocalFor(exe), nil
}

// opsCmd is `logs` and `exec`: the exit status is the stream's.
func opsCmd(o ops.Options, err error) int {
	out := cli.Std()
	if err == ops.ErrHelp {
		fmt.Fprint(out.Stdout, ops.Usage(o.Cmd))
		return cli.ExitOK
	}
	if err != nil {
		return report(out, err)
	}
	v, err := kasbahVersion(false)
	if err != nil {
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
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
		code = report(out, err)
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
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, prune.Run(prune.Ctx{
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
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, upgrade.Run(upgrade.Ctx{
		Out:       out,
		Templates: templates.FS,
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
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, drop.Run(drop.Ctx{
		Out:       out,
		Prompter:  prompt.Std(out),
		Version:   v,
		Templates: templates.FS,
		Dial:      drop.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}

// migrateCmd is `kasbah migrate` in a project and `kasbah migrate server`.
func migrateCmd(o migrate.Options, err error) int {
	out := cli.Std()
	if err == migrate.ErrHelp {
		fmt.Fprint(out.Stdout, migrate.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return report(out, err)
	}
	v, err := kasbahVersion(true)
	if err != nil {
		return report(out, err)
	}
	if !o.Server {
		pwd, err := os.Getwd()
		if err != nil {
			return report(out, cli.Fail("cannot read the current directory: %v", err))
		}
		return report(out, migrate.RunProject(out.Stdout, pwd, v, migrate.Project))
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, migrate.RunServer(migrate.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		Version:  v,
		Dial:     migrate.Dial(remote.Self(build), local),
		Now:      time.Now,
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
		return report(out, err)
	}
	local, err := localBinary()
	if err != nil {
		return report(out, err)
	}
	code := report(out, destroy.Run(destroy.Ctx{
		Out:      out,
		Prompter: prompt.Std(out),
		Dial:     destroy.Dial(remote.Self(build), local),
	}, o))
	if c := atexit.Interrupted(); c != 0 {
		code = c
	}
	return code
}
