# Server Setup

`hosting server init` prepares a VPS to host projects. It is deliberately
thin: it doesn't install packages and doesn't harden the system. It checks
prerequisites and lays out the folder structure that every later command
assumes.

## Prerequisites (checked, not installed)

| Requirement | Rationale | Failure mode |
|---|---|---|
| SSH with key auth to `user@host` | Every hosting operation is SSH-based | Hard fail, print ssh diagnostic |
| Docker ≥ 24 | `docker compose` v2 plugin required | Hard fail, link to docker docs |
| Docker Compose v2 | Manifest uses `include:` and modern syntax | Hard fail |
| The SSH user can run `docker` without sudo | Avoids mixed sudo/non-sudo ownership in `/apps/data/` | Hard fail, suggest `usermod -aG docker` |
| `rsync`, `openssl`, `gzip` available on remote | Used by deploy and env setup | Hard fail |

`hosting server init` does **not**:

- Install Docker or Compose (too opinionated; distros vary).
- Configure `ufw` or iptables.
- Edit `/etc/ssh/sshd_config`.
- Manage users or groups.

These are the VPS owner's responsibility.

## What init creates

Default paths (override with `--apps-path`, `--data-path`):

```
/apps/                               root owned by deploy user
├── .hosting/
│   └── server.json                  server marker (version, paths, limits, backup)
├── data/                            bind-mount root for all projects
│   └── traefik/letsencrypt/
│       └── acme.json                touched as a file, chmod 600
├── backups/                         top-level backups (opt-in per project)
└── traefik/
    ├── compose.yml                  the shared Traefik stack
    ├── traefik.yml                  static config
    ├── dynamic/                     file-provider watch dir
    │   ├── _shared.yml              middlewares + TLS options
    │   └── <project>.yml            one per deployed project (copied in on deploy)
    ├── .env.prod.example
    └── .env                         generated interactively at init
```

`acme.json` is touched as an empty file before `docker compose up`. If Docker
sees a missing path on a bind mount, it silently creates a **directory**,
which breaks Traefik (and later breaks DMS when it tries to read the file).
Hosting's init loop prevents this.

## Traefik stack (ported from the original project, generalized)

### `traefik.yml` (static)

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    http:
      tls:
        options: default

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: <from .env>
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

api:
  dashboard: true

log:
  level: INFO

ping:
  entryPoint: "web"
```

### `dynamic/_shared.yml` (middlewares)

Ships baseline middlewares that any project fragment can reference via `@file`:
- `http-to-https` — scheme redirect.
- `http-www-to-https-non-www`, `https-www-to-https-non-www` — apex canonicalization.
- `security-headers` — HSTS, frame-deny, CSP-report-only stub.
- `gzip-compression`.
- `api-rate-limit` (50 avg / 100 burst) — opt-in from a project fragment.

Projects add their own middlewares in their own `traefik-dynamic.yml`
(rsynced into the same `dynamic/` directory as `<manifest.name>.yml`).
The `_` prefix on shared files keeps them sorted at the top and distinct
from project fragments.

### Network

Created by the Traefik compose:

```yaml
networks:
  hosting-net:
    name: hosting-net
    driver: bridge
```

Only the containers Traefik routes to join `hosting-net` (declared
`external: true` in the project compose); internal services stay on a
project-internal network — see `traefik.md` for the alias-collision
rationale. Traefik resolves routed containers by `container_name` on
this network — the file provider fragment names them explicitly in
`services.<x>.loadBalancer.servers`.

## Server marker (`/apps/.hosting/server.json`)

Written by `server init`, updated by any server-mutating command
(`upgrade-traefik`, re-run with `--with-mail` / `--with-backup`):

```json
{
  "hosting_version": "0.1.0",
  "apps_path": "/apps",
  "data_path": "/apps/data",
  "cpu_limit": "3.6",
  "mem_limit": "7g",
  "backup": { "enabled": true, "repo_base": "s3:https://…/hosting-backups" }
}
```

Compatibility rule: a hosting binary operates on a VPS whose marker shares
its **major** version. Older tool + newer marker → refuse. Newer tool +
older-major marker → refuse until `hosting migrate` is run. Within the
same major, everything interoperates (see `overview.md`).

## Resource limits

`server init` computes hard caps as 90% of the host: `cpu_limit` from
`nproc`, `mem_limit` from `MemTotal`. No reservations, ever — these are
anti-takeover ceilings (one runaway project can't lock out SSH, Traefik,
or its neighbors), not fair-share slices; idle capacity stays fully
burstable.

The values live in the server marker and are injected into each project's
`.env` on every deploy as `HOSTING_CPU_LIMIT` / `HOSTING_MEM_LIMIT`
(reserved prefix, exempt from env drift detection). Project compose files
must reference the vars, never literal values — `hosting check` enforces
this (R01–R03), and `check --server` warns on values tightened below 90%
and fails anything above (R04).

## With backup (`--with-backup`)

Optional. Installs restic, writes append-only S3-compatible credentials,
and schedules a daily cron that snapshots each project's data bind
mounts, hook-produced backups, and `.env`. Full design — repo layout,
credential model, restore, pruning — in `backup.md`.

## With mail (`--with-mail`)

Additionally scaffolds `/apps/mail/` with DMS + SnappyMail (ported from
the original project's mail/compose.yml). See `mail.md` for details.

Mail requires the main Traefik stack to be running first so that the
`mail.<domain>` cert-trigger router can issue an ACME cert; init handles
the ordering automatically.

## `hosting server status`

Read-only. Walks `/apps/`, asks docker for container health, reads
`versions.log` for each project, and prints:

```
VPS: user@vps (connected)
Docker: 27.3.1, Compose: 2.29.7
Root: /apps  Data: /apps/data  Disk: 41% used (168G free)

Traefik: running (healthy)
  Dashboard: https://traefik.example.com
  ACME email: you@example.com
  Certs: 4 issued (next renewal in 42d)

Mail: running (healthy)
  MX: mail.example.com
  Domains: example.com, shop.example.com

Projects:
  shop           running  v1.3.0   deployed 2026-04-01 (hosting 0.1.0)
  jellyfin       running  latest   deployed 2026-03-15 (hosting 0.1.0)
  paperless      stopped  latest   deployed 2026-02-10 (hosting 0.1.0)
```

## Idempotency rules

`hosting server init` can be re-run:
- Folders are `mkdir -p`.
- `acme.json` is only touched if missing.
- Traefik `.env` runs in drift-check mode (see `env-template.md`).
- Traefik is restarted only if the static config files changed.
- Adding `--with-mail` on re-run scaffolds mail without touching Traefik.

## Handover / teardown

`hosting server destroy` (Phase 3) de-brands a VPS for handover — when the
server passes to a client or another operator. Every container keeps
running, projects **and** Traefik: the sites stay up. What's removed is
hosting's management layer:

- `/apps/.hosting/` (server marker)
- backup cron + S3 credentials (agency-owned secrets never transfer)
- per project: `hosting.yml`, `versions.log(.gz)`, `scripts/` helpers

What remains is a plain, self-contained Docker Compose setup the new owner
fully controls. The trade-off is explicit: deploy history and env tooling
leave with hosting. Double confirmation (typed hostname).

Full teardown (actually stopping everything) stays manual on purpose —
too easy to misfire:

```
ssh user@host 'cd /apps/<project> && docker compose down'   # per project
ssh user@host 'cd /apps/traefik && docker compose down'
ssh user@host 'rm -rf /apps'                                 # dangerous
```
