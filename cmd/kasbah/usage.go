package main

import (
	"fmt"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/help"
	"github.com/adigourdi/kasbah/internal/manifest"
)

// commands is every command the usage lists by its first word: what
// `kasbah help <command>` runs as `kasbah <command> --help`.
var commands = []string{"init-project", "check", "build-push", "deploy", "rollback", "backup", "restore", "drop", "history", "pending", "changelog", "env", "logs", "exec", "migrate", "self-update", "version", "info", "server"}

// serverSubcommands is every `kasbah server` subcommand, in usage order.
var serverSubcommands = []string{"init", "status", "prune", "backup-prune", "destroy", "upgrade-traefik", "add-mail-domain", "mail-dkim", "mail-setup-guide"}

// usage is the top-level help; build "" is an unstamped build.
func usage(build string) string {
	v := "unstamped build"
	if build != "" {
		v = "v" + build
	}
	return `kasbah — multi-project Docker host CLI (` + v + `)

Usage: kasbah [--version] [--help] <command> [args...]

Commands:
  init-project [--name=<n>] [--domain=<d>]   Scaffold kasbah metadata in cwd.
  check [--server [USER@HOST]] [--fix]       Run structural checks on the project, optionally against a server; --fix repairs what it can.
  build-push [USER@HOST]                     Build this project's images and load them on a server.
  deploy [USER@HOST] [VERSION]               Ship the working tree, or a tagged version, and bring it up.
  rollback [USER@HOST] [VERSION]             Put a server back on a version it has already run.
  backup [USER@HOST]                         Back up the live version on a server, and push it off-box.
  restore [USER@HOST]                        Bring .env and data back from the off-box backups.
  drop [USER@HOST] [--prune]                 Remove this project from a server.
  history [USER@HOST] [--all]                Show a server's deploy record for this project.
  pending [USER@HOST] [VERSION]              Show the commits a deploy would ship.
  changelog [USER@HOST]                      Show what changed in the deployed version.
  env [USER@HOST]                            Render the project's .env on the server.
  env set KEY [USER@HOST]                    Change one key of the project's .env on the server.
  logs [USER@HOST] [SERVICE] [-f] [--tail=N] Show this project's container logs on a server.
  exec [USER@HOST] SERVICE -- CMD...         Run a command in one of this project's containers.
  migrate                                    Move this project's files to this kasbah's schema.
  migrate server USER@HOST [--yes] [--undo]  Move a server to this kasbah's major, or undo the last move.
  self-update [vN | vN.M | vN.M.P] [--pre] [--yes]
                                             Install a released kasbah beside this one and repoint the symlink.
  version                                    Print this kasbah's version.
  info [USER@HOST]                           Print this build, where it lives and its docs; with a host, what the server runs.
  help [topic]                               Explain kasbah, a project's files and setups, a check rule, or debugging.
  server init USER@HOST [flags]              Prepare a VPS to host projects.
  server status USER@HOST                    Report what a prepared VPS is running.
  server prune USER@HOST [--yes]             Remove image tags outside the retention window.
  server backup-prune USER@HOST              Apply the retention policy to the server's restic repositories.
  server destroy USER@HOST [--yes]           De-brand a VPS for handover; the sites keep running.
  server add-mail-domain USER@HOST DOMAIN    Join a domain to the VPS's shared mail stack.
  server mail-dkim USER@HOST DOMAIN [--replace-keys|--keep-keys]
                                             Repair a mail domain's DKIM keys, or rotate them.
  server mail-setup-guide USER@HOST          Print the mail stack's setup walkthrough.
  server upgrade-traefik USER@HOST --version=<tag>
                                             Dry-run the fragments against a Traefik version, then switch.

Every command also takes:
  --debug                                    Stream the run's trace to stderr and save it as a log
                                             (KASBAH_DEBUG=1 does the same); a failure saves one anyway.
Every command that reaches a server also takes:
  --ship-dev | --keep-server                 When this dev build would replace the release the server
                                             runs: ship it, or keep the server's and run its build.

Run ` + "`kasbah <command> --help`" + `, or ` + "`kasbah help <command>`" + `, for a command's flags, and
` + "`kasbah help`" + ` for the topics. The docs/ files kasbah's messages name are in the
kasbah repository; docs/cli.md is the full reference.
`
}

const serverUsage = `Usage: kasbah server <subcommand> USER@HOST [args...]

Subcommands:
  init USER@HOST [flags]   Prepare a VPS to host projects.
  status USER@HOST         Report what a prepared VPS is running (read-only).
  prune USER@HOST [--yes]  Remove <image>:<version> tags older than 3 months and
                           outside each project's last 3 deployed versions.
  backup-prune USER@HOST   Apply the retention policy to this server's restic
                           repositories. restic runs here, not on the VPS: the
                           full-access credential never goes to the server.
  destroy USER@HOST [--yes]
                           De-brand a VPS for handover: the marker, the backup
                           stack and its credentials, the server's kasbah
                           binary, each project's deploy record and helpers,
                           and the mail relay block. Every container but the
                           backup scheduler's keeps running.
  upgrade-traefik USER@HOST --version=<tag>
                           Move the shared Traefik to another image tag: backs
                           up the three kasbah-owned files and dry-runs every
                           dynamic fragment against the target version first.
  add-mail-domain USER@HOST DOMAIN
                           Join a domain to the shared mail stack (docs/mail.md).
  mail-dkim USER@HOST DOMAIN [--replace-keys|--keep-keys]
                           Make a mail domain's missing DKIM keys and render the
                           signing override again; or replace its keys, the old
                           ones kept beside the new.
  mail-setup-guide USER@HOST
                           Print the mail stack's setup walkthrough (read-only).

Run ` + "`kasbah server <subcommand> --help`" + ` for its flags.
`

const versionUsage = `Usage: kasbah version

Prints this kasbah's version and the manifest schema it writes, as --version
does: kasbah <version> (schema <n>), or "kasbah (unstamped build)".
`

// helpArgs is the command line `kasbah help <command> [sub…]` stands for,
// `kasbah <command> [sub…] --help`, so the two print the same; any other
// command line is itself.
func helpArgs(args []string) []string {
	if len(args) > 1 && args[0] == "help" && slices.Contains(commands, args[1]) {
		return append(slices.Clone(args[1:]), "--help")
	}
	return args
}

// topLevel answers what no command handler took: usage, --version and
// `version`, `help` and its topics, `server` with no or an unknown
// subcommand, and unknown commands.
func topLevel(out *cli.Output, build string, args []string) int {
	if len(args) == 0 {
		fmt.Fprint(out.Stdout, usage(build))
		return cli.ExitOK
	}
	switch args[0] {
	case "help":
		topic := ""
		if len(args) > 1 {
			topic = args[1]
		}
		if len(args) > 2 {
			return out.Report(cli.Fail("help: unexpected argument '%s' — help takes one topic: %s, a rule ID (C01), or a command; `kasbah help` lists them", args[2], strings.Join(help.Topics, ", ")))
		}
		t, err := help.Topic(build, topic)
		if err != nil {
			return out.Report(err)
		}
		fmt.Fprint(out.Stdout, t)
		return cli.ExitOK
	case "-h", "--help":
		fmt.Fprint(out.Stdout, usage(build))
		return cli.ExitOK
	case "-v", "--version", "version":
		if args[0] == "version" && len(args) > 1 {
			a := args[1]
			switch {
			case a == "-h" || a == "--help":
				fmt.Fprint(out.Stdout, versionUsage)
				return cli.ExitOK
			case strings.HasPrefix(a, "-"):
				f, _, _ := strings.Cut(a, "=")
				return out.Report(cli.Fail("version: unknown flag '%s' — version takes none", f))
			}
			return out.Report(cli.Fail("version: unexpected argument '%s' — version takes none", a))
		}
		if build == "" {
			fmt.Fprintln(out.Stdout, "kasbah (unstamped build)")
		} else {
			fmt.Fprintf(out.Stdout, "kasbah %s (schema %d)\n", build, manifest.Schema)
		}
		return cli.ExitOK
	case "server":
		expected := strings.Join(serverSubcommands, ", ")
		switch {
		case len(args) == 1:
			return out.Report(cli.Fail("server: no subcommand given (expected: %s)", expected))
		case args[1] == "-h" || args[1] == "--help":
			fmt.Fprint(out.Stdout, serverUsage)
			return cli.ExitOK
		}
		return out.Report(cli.Fail("server: unknown subcommand '%s' (expected: %s)", args[1], expected))
	}
	return out.Report(cli.Fail("unknown command '%s' — `kasbah --help` lists the commands", args[0]))
}
