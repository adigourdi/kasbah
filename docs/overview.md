# kasbah — Overview

A CLI that turns a plain VPS into a multi-project host using Docker + Traefik,
without a container registry, CI/CD pipeline, or PaaS runtime.

Think "cPanel for Docker Compose": one tool to prep a VPS, deploy projects, ship
images without a registry, manage env drift, and optionally run a mail stack.

A kasbah is a fortified citadel: many dwellings packed behind a single wall,
reached through one gate. That is the shape of the tool — one hardened server,
many projects, one way in.

## Why

Small homelabs and side-projects don't justify the cost/complexity of a CI/CD
pipeline, a private registry, Kubernetes, or a PaaS. One PHP project's repo
proved that `docker save | scp | docker load` is enough to ship images to a
VPS, and that Traefik + a well-structured compose file is enough to run real
production traffic.

`kasbah` generalizes that proof into a reusable CLI so every new project gets
the same battle-tested workflow without copying scripts between repos.

## Scope

### In
- **Server prep** — check Docker/Compose, create folder layout, start a shared
  Traefik (optionally DMS + Cypht mail stack).
- **Project lifecycle** — build, push (`docker save` streamed over ssh into `docker load`),
  deploy, rollback, check, logs.
- **Env management** — interactive `.env` generation from a rich template,
  drift detection against `.env.prod.example`.
- **Compliance check** — structural conformance (compose.yml, manifest, Traefik
  fragment, healthchecks, logging, restart policy, env sync).
- **Mail primitive** — shared DMS + Cypht stack apps can claim a domain
  from; accounts are managed out-of-band via DMS CLI.
- **Off-VPS backup (optional)** — restic push from each VPS to S3-compatible
  storage; per-client repos, append-only credentials.

### Out
- Private container registry — no Harbor, Zot or Distribution to manage.
- Git/CI integration (kasbah expects `git push` and local builds — no webhooks,
  no remote triggers).
- Metrics, log aggregation, uptime monitoring.
- A web UI.
- Swarm and Kubernetes.
- Automated DNS management (no Cloudflare API integration).
- Multi-user access control on a VPS. Several operators share one server as one
  trust domain, the `kasbah` group (`server-setup.md` → Operators); no
  per-project permissions.
- One project deployed to many servers: each project targets exactly one VPS. A
  fleet is many projects × many VPSes, which per-project `user@host` targeting
  already covers.
- Automated SSH hardening / firewall (`kasbah server init` does not run `ufw`
  or edit sshd_config).
- Cross-project shared databases or caches. Every project owns its own.
- Blue/green or canary deploys. Rollback is retag-and-restart.

## Key decisions (source of truth)

| Decision | Choice |
|---|---|
| Language | Go — one statically linked binary, built in a pinned `golang` container (`compose.yml`), no Go on the host. Every file kasbah writes records its version, so a later major can migrate older projects. (Bash through 0.x.) |
| Distribution | Every install path is in `install.md`. Versioned install on the dev machine: each build lives under `~/.local/share/kasbah/<version>/` (the workstation binary and its linux/amd64 and linux/arm64 server builds) and the `~/.local/bin/kasbah` symlink points at the newest installed version that runs. Releases come in through `kasbah self-update` and all stay installed; `install-dev.sh` builds a checkout and installs it as the one dev build, replacing the previous one, or, given `vN | vN.M | vN.M.P`, builds that tag in a temporary clone with the tag's own toolchain — byte-identical to the release. Both place a build through the same Go routine (`internal/install`). The VPS receives only the kasbah binary itself, at `<apps>/.kasbah/bin/kasbah` — shipped when absent or older — a dev build asks before it replaces a release (`--ship-dev` / `--keep-server`) — kept when the same build, and the workstation refuses a server whose build is newer (same-build rule: both ends always run one build). No `git clone` on the VPS, no scripts shipped, nothing else installed. Releases are GitHub Releases cut locally by `release.sh`: tag `vMAJOR.MINOR.PATCH`, assets `kasbah_<ver>_linux_amd64` and `kasbah_<ver>_linux_arm64` (one file per arch, a Linux workstation and every server alike), `kasbah_<ver>_darwin_amd64` and `kasbah_<ver>_darwin_arm64` (macOS workstations, which install both Linux builds beside their own to ship), `get.sh` (the `curl | sh` installer, its version stamped in), `checksums.txt` over all five, in name order, and its minisign signature, "Latest" only on the highest final version; the public key is `release.pub` in the repo and in the binary. Release builds are reproducible — a clean checkout at the tag `v<VERSION>` is stamped as the tag itself (`-rc.N` included), with no build time in it; any other tree gets a pre-release stamp of the line's next version: `<next patch>-dev.<commits>.<time>+g<sha>[.dirty]` once `v<VERSION>` exists, `<VERSION>-dev.<commits>.<time>…` before it does, and `<VERSION>.<commits>.<time>…` whenever `VERSION` is an rc. A later build therefore outranks an earlier one and a release outranks every dev build of its line; `release.sh` proves the reproducibility by building twice. `kasbah self-update` resolves versions from the published releases (a GitHub token optional — required while the repo is private) and verifies the signed checksums against the key in the binary before anything is installed; a downloaded release binary asked for its own version installs its own verified bytes (`cli.md`). |
| Project boundary | Each project is an independent directory under `/apps/<name>/` with its own compose.yml and .env. They only share the Traefik network. |
| Project shape | Derived from compose: services with a `build:` key are built+shipped locally; services with only `image:` are pulled on the VPS. No `type` field in the manifest — the compose file is the source of truth. |
| Compose files | User authors `compose.prod.yml` for prod; the manifest's `sync` rule renames it to `compose.yml` on the VPS. Kasbah does not generate compose files. `compose.yml` in the working tree is for local dev and is never synced to the VPS. |
| Image tags on VPS | `:<version>` (one per build-push) + `:current` (moved by deploy/rollback). No `:latest`. Compose references `:current` for built services; it never gets rewritten per deploy. |
| Image retention | `kasbah server prune` keeps the last 3 deployed versions (the one `:current` points at counts as the first; `--dirty` test builds never count) and anything newer than 3 months (time window mirrors versions.log rotation). The retention window is the rollback window — anything older is a roll-forward, not a rollback. |
| Version source | Git tags on the project repo (`vX.Y.Z`). `kasbah deploy` (no args) ships the working tree under HEAD's tag, and only a clean one; `--dirty` ships any tree as a test build labelled `<base>-dirty.<UTC stamp>`, never a rollback target. `kasbah deploy X.Y.Z` and `kasbah rollback X.Y.Z` pull files from `git archive v<X.Y.Z>` — no checkout needed. |
| Image delivery | `docker compose build` locally → `docker save \| gzip` streamed over ssh → `docker load` on VPS → retag `:current`. No registry, no tarball. |
| Build config | Lives in each project's `compose.yml` under `build:`. Kasbah does not duplicate it in the manifest. |
| Traefik | One shared instance per VPS, managed by kasbah. It is attached to each project's own network at deploy, so it is the one container on more than one. |
| Networks | Each project's routed containers join its own `kasbah` network (`<project>_kasbah`, not external), which deploy attaches Traefik to; every other service (DBs, caches, workers) lives on a project-internal network. No two projects share a network, so a compromised container reaches its own project only. The mail stack has its own too, and apps send through its public submission port. The shared `kasbah-net` remains for legacy projects, warned by `check`. |
| Resources | Every service sets hard limits `cpus: ${KASBAH_CPU_LIMIT}` / `mem_limit: ${KASBAH_MEM_LIMIT}` — 90% of host cores/RAM, computed at `server init`, injected into each project's `.env` at deploy. No reservations: ceilings against total takeover, not fair-share slices. A project may set lower per-container limits of its own in `kasbah.yml`'s `resources:` — cores, `m`/`g`, or a `%` of the host resolved on the server — never above the ceiling; `check --server` warns when those add up past the host. |
| Mail | Kasbah primitive (optional). Apps declare a domain in their manifest; admin manages accounts via DMS CLI. |
| Databases/caches | Always per-project. Kasbah does not run shared Postgres/Redis. |
| Hooks | Lines of shell from the manifest, run with `sh -c` on the server in the project folder (`docker compose exec -T <service>` reaches a container). No host scripts get copied into projects. |
| Rollback | `git archive v<target>` for config + retag `:<target>` as `:current` + `compose up -d`. Target image must still be on the VPS — outside the retention window, rollback fails with roll-forward/rebuild guidance. The target's `.env` and data come back only from its newest on-server backup, when asked: `.env` by kasbah (whole or per key, names listed, never values), data by the target's own `restore` hook. |
| Project detection | CLI runs from project root. Reads `./kasbah.yml`. Errors if not a kasbah project. |
| Interactivity | Commands never assume on an unspecified choice: an unset flag means *prompt*, not *no* — with two deliberate exceptions, for the same reason: `--acme-staging`, where the default is production, and `--acme-dns`, where the default is the DNS-01 resolvers the server already declares. Each default is also the status quo, and asking every `server init` which certificate authority, or which DNS providers, it wants would make the common path worse. Every prompt has an explicit flag for scripted use: a pair when both answers are real outcomes — spelled `--with-x` / `--no-x` for a feature, or after what it decides where that reads better (`--reset-acme` / `--keep-acme`) — and a single `--yes` only where the prompt guards a destructive act and declining just aborts. Without a TTY, an unanswered prompt is a hard fail that names its own flags. |
| Version compatibility | Same-major tool ↔ state interop is guaranteed; crossing a major requires `kasbah migrate server` for a VPS and `kasbah migrate` for a project (`cli.md`): explicit, snapshotted, idempotent per file, undoable while nothing has deployed since. The first server step, `0→1`, rewrites nothing — 0.x state is 1.x state. An older tool refuses newer state, and a workstation refuses a server binary newer than its own, in any major — except that a release build always replaces a dev build of its major, since dev builds are scaffolding, never a lock — then hands off to that version when it is installed beside it (`cli.md` → Hand-off), so no two builds ever talk to each other and `kasbah remote …` arguments can change in any release. `/apps/.kasbah/server.json` records what manages the VPS. |
| Off-VPS backup | Optional. Each night every project's `backup` hooks take a fresh backup of its live version on the host, then each VPS pushes restic snapshots (the backup tarballs — the `backup` hooks' dumps — and `.env`, never the data bind mounts) to S3-compatible storage using append-only credentials. One repo per client (`client:` manifest field, defaults to project name). Pruning runs from an operator machine with full credentials. |
| Removal | `kasbah drop` removes containers, fragment, and images but keeps config/data/backups (redeployable). `drop --prune` deletes those too. `kasbah server destroy` de-brands the whole VPS for handover — containers keep running. |

## Mental model

```
                ┌──────────────────────────────────────────────┐
                │   VPS                                         │
                │                                               │
 dev machine    │   /apps/                                      │
 ┌──────────┐   │   ├── traefik/        (kasbah-managed)       │
 │ kasbah  │──►│   │   └── compose.yml                         │
 │   CLI    │   │   ├── mail/           (kasbah-managed, opt.) │
 └──────────┘   │   │   └── compose.yml                         │
       ▲        │   ├── shop/           (user project, custom)  │
       │        │   │   ├── compose.yml                         │
 project root   │   │   ├── .env                                │
 ~/work/app/    │   │   └── kasbah.yml                         │
 ├ compose.yml  │   ├── jellyfin/       (user project, stock)   │
 ├ kasbah.yml  │   │   ├── compose.yml                         │
 ├ .env.prod.ex │   │   ├── .env                                │
 └ ...          │   │   └── kasbah.yml                         │
                │   ├── data/           (all bind mounts here)  │
                │   │   ├── traefik/letsencrypt/acme.json       │
                │   │   ├── shop/postgres/                      │
                │   │   └── jellyfin/config/                    │
                │   └── backups/                                │
                └──────────────────────────────────────────────┘
```

## Directory layout on VPS

Chosen defaults (overridable via `kasbah server init --apps-path=...`):

```
/apps/                           # project root
├── .kasbah/
│   └── server.json              # server marker: kasbah version, paths, limits
├── traefik/                     # shared reverse proxy (kasbah-managed)
│   ├── compose.yml
│   ├── traefik.yml              # static config
│   └── dynamic/                 # file-provider watch dir
│       ├── _shared.yml          # middlewares, TLS opts
│       ├── _mail.yml            # cert-trigger + webmail routers (with --with-mail)
│       └── <project>.yml        # one per deployed project
│   # no .env: Traefik interpolates no environment variables, so the ACME
│   # email, dashboard domain and auth hash are baked in at render time
├── mail/                        # optional mail stack (kasbah-managed)
│   ├── compose.yml
│   ├── kasbah.yml               # the registry: primary_domain + domains
│   └── .env                     # kasbah's three keys + the operator's relay block
├── <project>/                   # one per deployed project
│   ├── compose.yml              # from project's compose.prod.yml
│   ├── .env                     # generated by the interactive setup, mode 660 (operators' group)
│   ├── .env.prod.example        # synced from project for drift detection
│   ├── versions.log             # deploy/rollback history
│   └── backups/                 # tarballs: one per deploy and rollback, of the version it replaced, per kasbah backup and nightly backup, of the live one, and each kasbah restore fetched from off-box
├── data/                        # all bind mounts, by project
│   ├── traefik/letsencrypt/acme.json
│   ├── mail/dms/...
│   └── <project>/...
└── backups/                     # top-level backup archive (always created)
```

## Constraints that shape the design

- **No registry** — image flow must work over SSH only.
- **No CI** — deploys are triggered from the developer's laptop.
- **No project lock-in** — a project checked out without `kasbah` installed
  must still run via `docker compose up -d` locally.
- **No script leak into projects** — projects hold `kasbah.yml` only. They
  vendor no kasbah code, and servers run none but the kasbah binary.
- **Versioned state** — every file kasbah writes (on dev and VPS) records its
  version, and from 1.0.0 the schema is frozen: a change goes through an
  explicit `kasbah migrate`. An optional key that an older kasbah ignores is
  not a change of schema.
