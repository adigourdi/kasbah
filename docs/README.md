# kasbah documentation

These files are kasbah's specification: they describe what the tool does, and
change in the same commit as the code. Start with the overview.

| Document | Covers |
|---|---|
| [overview.md](overview.md) | What kasbah is for, its scope, the decisions table, the layout of a server |
| [install.md](install.md) | Every way to install kasbah, what each one trusts, uninstalling |
| [server-setup.md](server-setup.md) | Preparing a VPS: prerequisites, what `server init` creates, mail and backup options |
| [project-manifest.md](project-manifest.md) | `kasbah.yml`, field by field, and the project's local state |
| [env-template.md](env-template.md) | How a project's `.env` is generated on the server and kept in sync |
| [traefik.md](traefik.md) | The shared reverse proxy and the routing fragment each project declares |
| [build-deploy.md](build-deploy.md) | Building, shipping, deploying and rolling back, and the version history |
| [compliance.md](compliance.md) | Every rule `kasbah check` applies |
| [cli.md](cli.md) | Every command and flag, and the exit codes |
| [mail.md](mail.md) | The optional shared mail stack |
| [backup.md](backup.md) | The optional off-server backups |
| [files.md](files.md) | Every file kasbah writes, on the workstation and on a server |
| [roadmap.md](roadmap.md) | Scope by release, and what stays out |

Alongside the specification:

- [phases/](phases/README.md) — the build plan, phase by phase, with what each one taught.
- [backlog/](backlog/) — work not yet planned, one item per file.
- [research/](research/README.md) — dated background notes; not specification.
