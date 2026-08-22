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
  Traefik (optionally DMS + SnappyMail mail stack).
- **Project lifecycle** — build, push (via `docker save`/`rsync`/`docker load`),
  deploy, rollback, check, logs.
- **Env management** — interactive `.env` generation from a rich template,
  drift detection against `.env.prod.example`.
- **Compliance check** — structural conformance (compose.yml, manifest, Traefik
  fragment, healthchecks, logging, restart policy, env sync).
- **Mail primitive** — shared DMS + SnappyMail stack apps can claim a domain
  from; accounts are managed out-of-band via DMS CLI.
- **Off-VPS backup (optional)** — restic push from each VPS to S3-compatible
  storage; per-client repos, append-only credentials.

### Out (for v1)
- Private container registry.
- Git/CI integration (kasbah expects `git push` and local builds — no webhooks,
  no remote triggers).
- Metrics, log aggregation, uptime monitoring (backlog: a Gatus stack with
  endpoint config generated from manifests — see roadmap).
- Automated SSH hardening / firewall (`kasbah server init` does not run `ufw`
  or edit sshd_config).
- Cross-project shared databases or caches. Every project owns its own.
- Blue/green or canary deploys. Rollback is retag-and-restart.

## Key decisions (source of truth)

| Decision | Choice |
|---|---|
| Language | Bash (v1). Project state file tracks version so future Go binary can migrate. |
| Distribution | Global install on dev machine. VPS receives only the scripts a deploy needs. No `git clone` on the VPS. |
| Project boundary | Each project is an independent directory under `/apps/<name>/` with its own compose.yml and .env. They only share the Traefik network. |
| Project shape | Derived from compose: services with a `build:` key are built+shipped locally; services with only `image:` are pulled on the VPS. No `type` field in the manifest — the compose file is the source of truth. |
| Compose files | User authors `compose.prod.yml` for prod; the manifest's `sync` rule renames it to `compose.yml` on the VPS. Kasbah does not generate compose files. `compose.yml` in the working tree is for local dev and is never synced to the VPS. |
| Image tags on VPS | `:<version>` (one per build-push) + `:current` (moved by deploy/rollback). No `:latest`. Compose references `:current` for built services; it never gets rewritten per deploy. |
| Image retention | `kasbah server prune` keeps the last 3 deployed versions (the one `:current` points at counts as the first) and anything newer than 3 months (time window mirrors versions.log rotation). The retention window is the rollback window — anything older is a roll-forward, not a rollback. |
| Version source | Git tags on the project repo (`vX.Y.Z`). `kasbah deploy` (no args) labels the working tree with HEAD's tag. `kasbah deploy X.Y.Z` and `kasbah rollback X.Y.Z` pull files from `git archive v<X.Y.Z>` — no checkout needed. |
| Image delivery | `docker compose build` locally → `docker save \| gzip` → `rsync` → `docker load` on VPS → retag `:current`. No registry. |
| Build config | Lives in each project's `compose.yml` under `build:`. Kasbah does not duplicate it in the manifest. |
| Traefik | One shared instance per VPS, managed by kasbah. Routed containers join its `kasbah-net` via `external: true`. |
| Networks | Only containers Traefik routes to join `kasbah-net`; every other service (DBs, caches, workers) lives on a project-internal network. Compose registers service names as DNS aliases on every attached network — generic names (`postgres`) on a shared network would round-robin across projects. |
| Resources | Every service sets hard limits `cpus: ${KASBAH_CPU_LIMIT}` / `mem_limit: ${KASBAH_MEM_LIMIT}` — 90% of host cores/RAM, computed at `server init`, injected into each project's `.env` at deploy. No reservations: ceilings against total takeover, not fair-share slices. |
| Mail | Kasbah primitive (optional). Apps declare a domain in their manifest; admin manages accounts via DMS CLI. |
| Databases/caches | Always per-project. Kasbah does not run shared Postgres/Redis. |
| Hooks | Run via `docker exec` inside a project container. No host scripts get copied into projects. |
| Rollback | `git archive v<target>` for config + retag `:<target>` as `:current` + `compose up -d`. Target image must still be on the VPS — outside the retention window, rollback fails with roll-forward/rebuild guidance. Does not restore data bind mounts — schema rollback is hook-driven. |
| Project detection | CLI runs from project root. Reads `./kasbah.yml`. Errors if not a kasbah project. |
| Interactivity | Commands never assume on an unspecified choice: an unset flag means *prompt*, not *no*. Every prompt has an explicit flag for scripted use: a pair when both answers are real outcomes — spelled `--with-x` / `--no-x` for a feature, or after what it decides where that reads better (`--reset-acme` / `--keep-acme`) — and a single `--yes` only where the prompt guards a destructive act and declining just aborts. Without a TTY, an unanswered prompt is a hard fail that names its own flags. |
| Version compatibility | Same-major tool ↔ state interop is guaranteed; crossing a major requires `kasbah migrate`. An older tool refuses newer state. `/apps/.kasbah/server.json` records what manages the VPS. |
| Off-VPS backup | Optional. Each VPS pushes restic snapshots (data bind mounts, hook backups, `.env`) to S3-compatible storage using append-only credentials. One repo per client (`client:` manifest field, defaults to project name). Pruning runs from an operator machine with full credentials. |
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
│       └── <project>.yml        # one per deployed project
│   # no .env: Traefik interpolates no environment variables, so the ACME
│   # email, dashboard domain and auth hash are baked in at render time
├── mail/                        # optional mail stack (kasbah-managed)
│   ├── compose.yml
│   └── .env
├── <project>/                   # one per deployed project
│   ├── compose.yml              # from project's compose.prod.yml
│   ├── .env                     # generated via setup-env
│   ├── .env.prod.example        # synced from project for drift detection
│   ├── versions.log             # deploy/rollback history
│   ├── scripts/                 # minimal helpers copied per deploy
│   │   ├── setup-env.sh         # rich env template handler
│   │   └── remote-deploy.sh     # VPS-side deploy steps
│   └── backups/                 # hook-produced backups (opt-in)
├── data/                        # all bind mounts, by project
│   ├── traefik/letsencrypt/acme.json
│   ├── mail/dms/...
│   └── <project>/...
└── backups/                     # top-level backup archive (opt-in)
```

## Constraints that shape the design

- **No registry** — image flow must work over SSH only.
- **No CI** — deploys are triggered from the developer's laptop.
- **No project lock-in** — a project checked out without `kasbah` installed
  must still run via `docker compose up -d` locally.
- **No script leak into projects** — projects hold `kasbah.yml` only. They
  do not vendor `deploy.sh` or any kasbah bash.
- **Bash first, Go-ready** — every file kasbah writes (on dev and VPS)
  is versioned so a future Go binary can migrate older projects in place.
