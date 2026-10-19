package main

import (
	"fmt"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
)

// serverSubcommands is every `kasbah server` subcommand, in usage order.
var serverSubcommands = []string{"init", "status", "prune", "backup-prune", "destroy", "upgrade-traefik", "add-mail-domain", "mail-setup-guide"}

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
  drop [USER@HOST] [--prune]                 Remove this project from a server.
  history [USER@HOST] [--all]                Show a server's deploy record for this project.
  pending [USER@HOST] [VERSION]              Show the commits a deploy would ship.
  changelog [USER@HOST]                      Show what changed in the deployed version.
  env [USER@HOST]                            Render the project's .env on the server.
  logs [USER@HOST] [SERVICE] [-f] [--tail=N] Show this project's container logs on a server.
  exec [USER@HOST] SERVICE -- CMD...         Run a command in one of this project's containers.
  server init USER@HOST [flags]              Prepare a VPS to host projects.
  server status USER@HOST                    Report what a prepared VPS is running.
  server prune USER@HOST [--yes]             Remove image tags outside the retention window.
  server backup-prune USER@HOST              Apply the retention policy to the server's restic repositories.
  server destroy USER@HOST [--yes]           De-brand a VPS for handover; the sites keep running.
  server add-mail-domain USER@HOST DOMAIN    Join a domain to the VPS's shared mail stack.
  server mail-setup-guide USER@HOST          Print the mail stack's setup walkthrough.
  server upgrade-traefik USER@HOST --version=<tag>
                                             Dry-run the fragments against a Traefik version, then switch.

Run ` + "`kasbah <command> --help`" + ` for a command's flags. The docs/ files kasbah's
messages name are in the kasbah repository; docs/cli.md is the full reference.
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
  mail-setup-guide USER@HOST
                           Print the mail stack's setup walkthrough (read-only).

Run ` + "`kasbah server <subcommand> --help`" + ` for its flags.
`

// topLevel answers what no command handler took: usage, --version, `server`
// with no or an unknown subcommand, and unknown commands.
func topLevel(out *cli.Output, build string, args []string) int {
	if len(args) == 0 {
		fmt.Fprint(out.Stdout, usage(build))
		return cli.ExitOK
	}
	switch args[0] {
	case "-h", "--help":
		fmt.Fprint(out.Stdout, usage(build))
		return cli.ExitOK
	case "-v", "--version":
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
