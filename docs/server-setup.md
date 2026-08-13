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
| `bash` on the remote | Every hosting step ships a script to `bash -s` over the SSH master | Hard fail |
| Passwordless `sudo` — **only** when the apps path does not exist yet | `/apps` lives outside the deploy user's home, so nobody but root can create it. Once it exists and is owned by that user, init never elevates again | Hard fail naming the two commands to run by hand |

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
    └── dynamic/                     file-provider watch dir
        ├── _shared.yml              middlewares + TLS options + dashboard router
        └── <project>.yml            one per deployed project (copied in on deploy)
```

**The Traefik stack has no `.env`, deliberately.** Traefik expands
environment variables in neither its static nor its dynamic configuration,
so the ACME email, the dashboard domain and the basic-auth hash are baked
into the rendered files at init time. The rendered `compose.yml` then
contains no `${…}` for compose to interpolate, which leaves an `.env` with
nothing to hold — and an env knob the container never receives is a dead
knob. Those three values are read back *out of* the rendered files on a
re-run, which is what lets init stay idempotent without storing them
anywhere else.

`acme.json` is touched as an empty file before `docker compose up`. If Docker
sees a missing path on a bind mount, it silently creates a **directory**,
which breaks Traefik (and later breaks DMS when it tries to read the file).
Hosting's init loop prevents this.

### Who creates the apps path

Init creates it with `sudo mkdir -p` and immediately `chown`s it to the SSH
user. Everything below is then created unelevated, which is what keeps
`/apps/data/` free of the mixed sudo/non-sudo ownership this document warns
about elsewhere. Elevation happens **only** on the first run against a bare
host: once the directory exists and the deploy user owns it, init takes the
unprivileged path and never calls `sudo` again.

A sudo that would *prompt* is detected up front (`sudo -n true`) and refused
with the manual commands to run, rather than being allowed to block on a
password prompt — a deploy driven from a script has no terminal to answer
it, and a hung init is worse than a named failure.

There are exactly two acceptable states, and a third that init refuses:

| Apps path | Init does |
|---|---|
| Does not exist, and the SSH user can reach where it would go | `sudo mkdir -p` the parent, bare `mkdir` the final component, `chown` it — once |
| Exists, owned by the SSH user | Nothing — stays unelevated |
| Exists, owned by anyone else | **Refuses**, naming the `chown` to run |
| The SSH user cannot traverse to it, whether or not it exists | **Refuses** |

The third row is a refusal rather than a `chown` on purpose. `--apps-path`
is an operator-supplied path, and a version of init that quietly took
ownership of whatever it was pointed at would hand `/var/www` to the deploy
user on a live host — while reporting that it had *created* it. Seizing a
directory hosting did not create is not a repair; one command from the
operator is cheaper than the class of accident it prevents.

The fourth row exists because the first three are not decidable by the
deploy user alone. A directory behind a parent they cannot traverse answers
"does it exist?" with *no*, so a path that plainly exists reads as row one
and gets seized by a root `chown` — the deploy user's blindness laundered
into permission. Init therefore re-asks root before elevating, and creates
the final component with a bare `mkdir` so an existing directory is an
error rather than a silent adoption. The refusal stands even when nothing
is there: everything below the apps path is written unelevated, so a path
the deploy user cannot enter is unusable no matter who creates it.

The alternative — requiring a pre-created `/apps` as a documented
prerequisite, which this document's "checked, not installed" philosophy
leans toward — was considered and rejected: one manual step before every
fresh VPS costs more than a sudo the prerequisites table can simply name.

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
      email: <baked at render time from --email>
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

Written as mode 644, temp-file-and-rename, so the file is identical across
hosts with different umasks and a reader never sees a half-written marker.

Compatibility rule: a hosting binary operates on a VPS whose marker shares
its **major** version. Older tool + newer marker → refuse. Newer tool +
older-major marker → refuse until `hosting migrate` is run. Within the
same major, everything interoperates (see `overview.md`).

Only the first direction is implemented. Refusing an *older* marker would
be a dead end today: the remedy it names, `hosting migrate`, does not exist
until roadmap v1.0, so the refusal would strand a server with no way
forward. It lands with that command.

Marker writes **merge, they never replace.** A command computes the fields it
owns and overlays them onto whatever is already there, so a key written by a
newer hosting — `backup.repo_base` is the one this document already
anticipates — survives a re-run by a tool that has never heard of it. Only
`hosting_version` is unconditionally overwritten, with the version that did
the writing.

## Resource limits

`server init` computes hard caps as 90% of the host: `cpu_limit` from
`nproc`, `mem_limit` from `MemTotal`. No reservations, ever — these are
anti-takeover ceilings (one runaway project can't lock out SSH, Traefik,
or its neighbors), not fair-share slices; idle capacity stays fully
burstable.

### How the numbers are spelled

Formatting is part of the contract, because the marker must be byte-identical
across re-runs on an unchanged host or the idempotency rule below is
unsatisfiable:

- `cpu_limit` — tenths of a core, always one decimal place: `nproc × 9 / 10`
  and `nproc × 9 % 10` as integers. 16 cores → `14.4`, 1 core → `0.9`.
- `mem_limit` — floored whole GiB with a `g` suffix once that is at least 1
  (`54g` on a 62 GiB host, `7g` on 8 GiB); below that, floored whole MiB with
  an `m` suffix, minimum `1m`. A 512 MiB host gets `460m`, never a `1g`
  ceiling larger than the machine it is capping.

All of it is integer arithmetic, computed on the workstation from `nproc` and
`MemTotal` collected over SSH. It is deliberately not `printf '%.1f'`: that
renders `14,4` under a comma-decimal `LC_NUMERIC`, and a marker whose bytes
depend on the operator's locale cannot be idempotent. The remote side is not
assumed to have `awk` or `bc` — the prerequisites table does not list them.

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
- `acme.json` is created if missing; its mode is enforced as 600 on every
  run, and a *directory* found at that path is a hard failure rather than
  something init works around.
- The Traefik stack has no `.env`; its three baked values (dashboard
  domain, ACME email, auth hash) are read back out of the rendered files,
  so a re-run without the flags reproduces them exactly.
- Traefik is restarted only when the static config actually changed *and*
  `compose up -d` did not already create or recreate the container — a
  container two seconds old has read the new config on its way up.
- Adding `--with-mail` on re-run scaffolds mail without touching Traefik.

## Handover / teardown

`hosting server destroy` (roadmap v0.3) de-brands a VPS for handover — when the
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
