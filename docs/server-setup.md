# Server Setup

`kasbah server init` prepares a VPS to host projects. It is deliberately
thin: it doesn't install packages and doesn't harden the system. It checks
prerequisites and lays out the folder structure that every later command
assumes.

## Prerequisites (checked, not installed)

| Requirement | Rationale | Failure mode |
|---|---|---|
| SSH with key auth to `user@host` | Every kasbah operation is SSH-based | Hard fail, print ssh diagnostic |
| Docker ≥ 24 | `docker compose` v2 plugin required | Hard fail, link to docker docs |
| Docker Compose v2 **or newer** | Manifest uses `include:` and modern syntax. The check is on the major version, not the string: a live host ran Compose **v5.2.0** and passed | Hard fail |
| The SSH user can run `docker` without sudo | Avoids mixed sudo/non-sudo ownership in `/apps/data/` | Hard fail, suggest `usermod -aG docker` |
| `rsync`, `openssl`, `gzip` available on remote | Used by deploy and env setup | Hard fail |
| `bash` on the remote | Every kasbah step ships a script to `bash -s` over the SSH master | Hard fail |
| `flock` (util-linux) | `remote-deploy.sh` holds an exclusive lock on `<project>/.deploy.lock` for the whole of a deploy, so a second concurrent deploy fails fast instead of interleaving hooks and retags. The one tool kasbah's shipped scripts use that is **not** coreutils, which is why it gets its own row | Probed at `server init`, so it fails there rather than mid-deploy. If it goes missing afterwards the deploy refuses naming **flock**, not a concurrent operator — `flock -n \|\| fail` would otherwise turn "not installed" into "someone else is deploying" |
| A POSIX userland — `tr`, `cat`, `stat`, `nproc`, `date`, `find`, `sort`, `comm`, `readlink` | Every remote step is a shell script; these are assumed present rather than checked, because a box without them cannot run `bash -s` usefully in the first place. The rule kasbah's shipped scripts follow is **coreutils and bash builtins, nothing separately packaged** — which is why `scripts/setup-env.sh` parses env files with `read` loops rather than `awk` or `grep` | Not checked; failure surfaces as the step's own error |
| **`:80` and `:443` free, and reachable from the internet** | Traefik binds both, and ACME's HTTP-01 challenge is answered on `:80` from outside. **Not probed** — init does not look at what is listening or at any firewall, so a port already held, or a `ufw` rule, surfaces as Traefik failing to start or as a challenge that never validates | Not checked |
| **DNS in place before the first certificate** — `traefik.<apex>`, plus every project domain | A challenge for a name that does not resolve to this host fails, and **failed challenges count against Let's Encrypt's rate limits**. Rehearse with `--acme-staging` until DNS is right. **Not probed** — kasbah never resolves a name for you | Not checked |
| Passwordless `sudo` — when the apps path does not exist yet, **and** to write the discovery pointer | `/apps` lives outside the deploy user's home, so nobody but root can create it; `/etc/kasbah/apps-path` is root-owned for the same reason it is machine-wide. Once both exist, init never elevates again — re-runs only read the pointer | Apps path: hard fail naming the two commands to run by hand. Pointer: hard fail at a non-default apps path (the server would be undiscoverable), a warning at `/apps` (the fallback covers it) |

`kasbah server init` does **not**:

- Install Docker or Compose (too opinionated; distros vary).
- Configure `ufw` or iptables.
- Edit `/etc/ssh/sshd_config`.
- Manage users or groups.

These are the VPS owner's responsibility.

## On the workstation

The remote table above is what init *checks*. The workstation side is
unchecked and shorter, but one entry is easy to miss: **Docker**. The
dashboard password is bcrypt-hashed locally so it never crosses the wire in
clear, and the hashing runs in a throwaway `httpd:2-alpine` container unless
`htpasswd` happens to be on `PATH` — it ships in `apache2-utils` /
`httpd-tools`, which few workstations install. A machine with neither hashes
nothing and init exits naming both ways out. `rsync`, `ssh`, `gzip`,
`openssl`, `git`, `jq` and `yq` (the kislyuk wrapper, jq dialect) are the
rest. "Docker" here means the daemon **and the compose plugin** — `build-push`
runs `docker compose -f compose.prod.yml build` locally, so a workstation with
`docker` but no `compose` gets through init and fails at the first build.

## What init creates

Default paths (override with `--apps-path`, `--data-path`):

```
/etc/kasbah/                         root:root 755
└── apps-path                        root:root 644 — the discovery pointer
/apps/                               root owned by deploy user
├── .kasbah/
│   └── server.json                  server marker (version, paths, limits, backup)
├── data/                            bind-mount root for all projects
│   └── traefik/letsencrypt/
│       └── acme.json                touched as a file, chmod 600
├── backups/                         top-level backups (always created)
└── traefik/
    ├── compose.yml                  the shared Traefik stack
    ├── traefik.yml                  static config
    └── dynamic/                     file-provider watch dir
        ├── _shared.yml              middlewares + TLS options + dashboard router
        └── <project>.yml            one per deployed project (copied in on deploy)
```

**The Traefik stack has no `.env`, deliberately.** Traefik expands
environment variables in neither its static nor its dynamic configuration,
so the ACME email, the dashboard domain, the basic-auth hash and the ACME
`caServer` are baked into the rendered files at init time. The rendered `compose.yml` then
contains no `${…}` for compose to interpolate, which leaves an `.env` with
nothing to hold — and an env knob the container never receives is a dead
knob. All four are read back *out of* the rendered files on a re-run, which is what
lets init stay idempotent without storing them anywhere else — the first three
to be reproduced verbatim, the `caServer` to detect that this run renders a
different CA than the one in effect.

`acme.json` is touched as an empty file before `docker compose up`. If Docker
sees a missing path on a bind mount, it silently creates a **directory**,
which breaks Traefik (and later breaks DMS when it tries to read the file).
Kasbah's init loop prevents this.

## The ACME endpoint (`--acme-staging`)

`server init` renders the Let's Encrypt directory URL into `traefik.yml` as an
explicit `caServer`: production by default, staging with `--acme-staging`.
Production certificates are trusted and rate-limited; staging ones are neither,
which is what makes staging the right first run against a fresh VPS. The flag
has no `--no-` twin and there is no prompt, because production is both the
default and the status quo — the endpoint is re-decided from the command line
on every run, so **a re-run without `--acme-staging` switches a staging server
to production**, and a server meant to stay on staging keeps the flag.

### When the store is reset

The reset exists because Traefik files certificates by resolver rather than by
endpoint: entries the old CA issued stay in `acme.json` and stay in service, so
a switch that leaves them there serves a staging certificate to the public, or
keeps a production one an operator believes they have moved off. Resetting
means `acme.json` is renamed to `acme.json.<UTC timestamp>` (mode 600, kept —
the certificates in it may be real), a fresh empty `acme.json` mode 600 takes
its place, and Traefik restarts and re-issues.

**The question is about the store, not about the config.** Two facts decide it,
and only their pairing — what `acme.json` holds, and whether anything records
which CA filled it:

| `acme.json` | `caServer` on the server | Init does |
|---|---|---|
| Empty, absent, or not a file | anything | Nothing, silently. There is no certificate to lose, which is every fresh server and so every first init |
| Has content | present and equal to this run's | Nothing — the idempotent re-run |
| Has content | present and different | **Confirmation** (`--yes`), then resets. Declining aborts with nothing changed |
| Has content | absent, or `traefik.yml` missing, empty or unparseable | **Choice** (`--reset-acme` / `--keep-acme`) — kasbah cannot tell which CA issued what is there. Keeping proceeds, with a warning and a summary line |

The two prompts are not the same kind of question, and they do not share a flag:

- **The switch is a confirmation.** The server states one endpoint, the run
  renders another, and there are two outcomes: do it, or do not run. `--yes`
  answers it; declining aborts with nothing created, shipped or restarted, and
  the message names the re-run that keeps the endpoint the server is on.
- **The unknown store is a choice.** Kasbah raised it, not the operator, about
  state it cannot interpret — answering it takes knowing which CA issued those
  certificates, which a blanket `--yes` in a CI script cannot supply. So it has
  its own tri-state pair, `--reset-acme` / `--keep-acme`: unset means ask, and
  with no terminal and neither flag the run fails naming both. **Keeping is a
  real answer that proceeds**, because there is no reading of this question
  under which refusing to run is the safe one.

**Neither flag answers the other's question, and the pair never crosses into
the switch.** `--yes` cannot answer the choice, and `--reset-acme` cannot answer
the confirmation. Passing a choice flag to a run that never reaches the choice
is a **warning** naming why — a fleet script sets the pair once and meets
servers that do not need it, and failing those runs is what would make the pair
unusable. The exception is `--keep-acme` reaching a switch: keeping the store
and changing CA cannot both happen, so the run **refuses** rather than letting
`--yes` decide it, and refuses in the direction that never archives a store the
operator asked to keep. Re-run without `--keep-acme` to be asked, or with
`--yes` to switch and reset.

The last row is the one to read twice. It is the state of every server prepared
before `caServer` was rendered at all, and reading the config alone would call
it "no change" — which is how a staging endpoint gets shipped over a store full
of production certificates, silently, on the most ordinary run there is. The
run records the endpoint on its way through, so it is asked **once**.

The message distinguishes a `traefik.yml` that names no `caServer` from one
that does not parse and from one with nothing in it — they are different facts
and the fix differs. A `caServer` that is neither Let's Encrypt endpoint is
quoted verbatim and never called "staging" or "production": kasbah renders only
those two, so nothing it can offer reproduces such a value, and it does not
pretend otherwise.

The reset happens between shipping the new `traefik.yml` and restarting
Traefik, never in the layout step above: `acme.json` is bind-mounted as a
*file*, so a running Traefik holds the old inode and only the restart makes it
pick the new one up.

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
directory kasbah did not create is not a repair; one command from the
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
      caServer: <the production LE directory, or the staging one with --acme-staging>
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
  kasbah-net:
    name: kasbah-net
    driver: bridge
```

Only the containers Traefik routes to join `kasbah-net` (declared
`external: true` in the project compose); internal services stay on a
project-internal network — see `traefik.md` for the alias-collision
rationale. Traefik resolves routed containers by `container_name` on
this network — the file provider fragment names them explicitly in
`services.<x>.loadBalancer.servers`.

## The discovery pointer (`/etc/kasbah/apps-path`)

One line, one absolute path, `root:root 644`. It is how every project command
finds a server whose apps path is not `/apps`:

```
/etc/kasbah/apps-path  →  /srv/apps  →  /srv/apps/.kasbah/server.json
```

Resolution is: the pointer if it exists **and can be read**, else `/apps`. A
pointer naming a path with **no marker under it** is a hard failure rather than
a fallback — silently reading a different tree's marker is how a deploy lands
on the wrong server — and one that cannot be read is a refusal too, never a
quiet fall back to the default. The one exception is a pointer naming the
default tree itself, in any spelling (`/apps`, `/apps/`, `//apps`): the
fallback would read the same file anyway, so it degrades to the ordinary
"no marker" exit 4.

The directory is mode `755` for the same reason the file is `644`: a pointer
nobody but root can *traverse to* is indistinguishable from one that is not
there, and "not there" is the one state that falls back silently.

It lives in `/etc` rather than a home directory because **more than one person
administers a server**. A per-user pointer lets two admins hold different
beliefs about one machine, which is the failure being removed, not a cost worth
paying for avoiding sudo.

It is written immediately *after* the marker, so the marker remains the
"init completed" signal and a run that dies early leaves neither.

**One server runs one kasbah.** One Traefik holds `:80` and `:443`, so a second
apps path on the same machine is not a second install but a rival stack under
the frozen `traefik` compose project — which would recreate the running proxy
against its own `dynamic/` and `acme.json` and take every site down.
`server init` therefore refuses when the pointer records a *different* path
than the run would prepare, and says how to manage the server that is there.
Re-running with the same path stays idempotent.

**The refusal only protects a server that already carries a pointer.** One
prepared before this existed has none, so a bare `kasbah server init host`
against it still sees an unprepared machine and will stand a rival stack. The
pointer is written by any `server init` re-run, so the fix is to re-run init
once against the real apps path — which is also the only way an old server
becomes discoverable by `deploy` and `env`.

## Server marker (`<apps>/.kasbah/server.json`)

Written by `server init`, updated by any server-mutating command
(`upgrade-traefik`, re-run with `--with-mail` / `--with-backup`):

```json
{
  "kasbah_version": "0.1.0",
  "apps_path": "/apps",
  "data_path": "/apps/data",
  "cpu_limit": "3.6",
  "mem_limit": "7g",
  "backup": { "enabled": true, "repo_base": "s3:https://…/kasbah-backups" }
}
```

Written as mode 644, temp-file-and-rename, so the file is identical across
hosts with different umasks and a reader never sees a half-written marker.

Compatibility rule: a kasbah binary operates on a VPS whose marker shares
its **major** version. Older tool + newer marker → refuse. Newer tool +
older-major marker → refuse until `kasbah migrate` is run. Within the
same major, everything interoperates (see `overview.md`).

Only the first direction is implemented. Refusing an *older* marker would
be a dead end today: the remedy it names, `kasbah migrate`, does not exist
until roadmap v1.0, so the refusal would strand a server with no way
forward. It lands with that command.

Marker writes **merge, they never replace.** A command computes the fields it
owns and overlays them onto whatever is already there, so a key written by a
newer kasbah — `backup.repo_base` is the one this document already
anticipates — survives a re-run by a tool that has never heard of it. Only
`kasbah_version` is unconditionally overwritten, with the version that did
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
`.env` on every deploy as `KASBAH_CPU_LIMIT` / `KASBAH_MEM_LIMIT`, into a
sentinel-delimited managed block, written through unchanged — injection
formats nothing and validates nothing, so a `0` reaches the file as `0`
(reserved prefix, exempt from env drift detection; see `env-template.md` for
the block's shape and the stray-removal rule). Project compose files
must reference the vars, never literal values — `kasbah check` enforces
this (R01–R03), and `check --server` warns on values tightened below 90%
and fails anything above (R04).

## With backup (`--with-backup`)

*Not implemented yet — roadmap v0.3. `server init` hard-fails on
`--with-backup` rather than pretending.* Optional. Installs restic, writes append-only S3-compatible credentials,
and schedules a daily cron that snapshots each project's data bind
mounts, hook-produced backups, and `.env`. Full design — repo layout,
credential model, restore, pruning — in `backup.md`.

## With mail (`--with-mail`)

*Not implemented yet — roadmap v0.2. `server init` hard-fails on
`--with-mail` rather than pretending.* Additionally scaffolds `/apps/mail/` with DMS + SnappyMail (ported from
the original project's mail/compose.yml). See `mail.md` for details.

Mail requires the main Traefik stack to be running first so that the
`mail.<domain>` cert-trigger router can issue an ACME cert; init handles
the ordering automatically.

## `kasbah server status`

Read-only — it never creates, modifies or removes anything. Walks the apps
path, asks docker for each project's container *state* (health is reported
for Traefik alone, which is the only container kasbah gives a healthcheck),
reads `versions.log` for each project, and prints:

What it prints today:

```
VPS: you@vps (connected)
Docker: 29.7.2, Compose: 5.4.0
Root: /apps (pointer)  Data: /apps/data
Marker: kasbah 0.1.0-dev, cpu 14.4, mem 54g

Traefik: running (healthy)
  Image: traefik:v3.7.10 (sha256:9c3b91d5fb77)
  Container: traefik

Projects:
  shop           1/1 running    1.3.0      deploy 2026-04-01T09:12:44+00:00 (kasbah 0.1.0)
  jellyfin       0/1 stopped    2.4.1      deploy 2026-03-15T22:05:10+00:00 (kasbah 0.1.0)
```

Versions appear exactly as `versions.log` holds them — no `v` prefix, and
the full ISO timestamp the log records rather than a truncated date, because
the log is the source of truth and a reformat invites a mismatch. Both the
image tag and the resolved image id are shown: a tag can be re-pushed under
the same name, the id cannot.

The fuller report — cert status and expiry, disk usage, the mail stack,
per-container health — arrives with the rest of the operational surface in
roadmap v0.2. So does the per-project **domain**, which is not simply
missing: it lives in each project's Traefik fragment, so printing it means
parsing YAML on a server where `yq` is not a prerequisite, or asking the
Traefik API with the dashboard credentials.

## Idempotency rules

`kasbah server init` can be re-run:
- Folders are `mkdir -p`.
- `acme.json` is created if missing; its mode is enforced as 600 on every
  run, and a *directory* found at that path is a hard failure rather than
  something init works around. It is archived and re-created only when a CA
  switch calls for it — a re-run with the same flags never touches it.
- The Traefik stack has no `.env`; its three baked values (dashboard
  domain, ACME email, auth hash) are read back out of the rendered files,
  so a re-run without the flags reproduces them exactly.
- Traefik is restarted only when the static config actually changed *and*
  `compose up -d` did not already create or recreate the container — a
  container two seconds old has read the new config on its way up.
- Adding `--with-mail` on re-run scaffolds mail without touching Traefik.

## Handover / teardown

`kasbah server destroy` (roadmap v0.3) de-brands a VPS for handover — when the
server passes to a client or another operator. Every container keeps
running, projects **and** Traefik: the sites stay up. What's removed is
kasbah's management layer:

- `/apps/.kasbah/` (server marker)
- backup cron + S3 credentials (agency-owned secrets never transfer)
- per project: `versions.log(.gz)`, `scripts/` helpers, `.deploy.lock`. Not
  `kasbah.yml` — the manifest is never synced to a server (`project-manifest.md`)

What remains is a plain, self-contained Docker Compose setup the new owner
fully controls. The trade-off is explicit: deploy history and env tooling
leave with kasbah. Double confirmation (typed hostname).

Full teardown (actually stopping everything) stays manual on purpose —
too easy to misfire:

```
ssh user@host 'cd /apps/<project> && docker compose down'   # per project
ssh user@host 'cd /apps/traefik && docker compose down'
ssh user@host 'rm -rf /apps'                                 # dangerous
```
