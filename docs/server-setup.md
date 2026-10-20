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
| `rsync` available on remote | The project's `sync:` files and the Traefik fragment are rsynced | Hard fail |
| A POSIX `sh` on the remote — no `bash` | The bootstrap probe and the `sudo` steps of `server init` and `server destroy` run as POSIX shell scripts over the SSH master (tested under dash and busybox ash, linted with shellcheck); everything else runs the kasbah binary there, shipped to `<apps>/.kasbah/bin/kasbah` | Hard fail |
| A POSIX userland — `uname`, `id`, `stat`, `od`, `timeout`, `sed`, `head`, `tr`, `wc`, `find`, `cat`, `mkdir`, `mv`, `rm`, `nproc`, `df` | The remaining shell steps (the bootstrap probe and the `sudo` steps) assume these rather than check them, because a box without them cannot run a shell step usefully in the first place. The rule kasbah's remote shell follows is **POSIX `sh` builtins and the coreutils that busybox also provides, nothing separately packaged** (GNU coreutils and busybox are both exercised); the deploy engine and the env setup are the kasbah binary and need none of it | Not checked; failure surfaces as the step's own error |
| **`:80` and `:443` free, and reachable from the internet** | Traefik binds both, and ACME's HTTP-01 challenge is answered on `:80` from outside. **Not probed** — init does not look at what is listening or at any firewall, so a port already held, or a `ufw` rule, surfaces as Traefik failing to start or as a challenge that never validates | Not checked |
| **DNS in place before the first certificate** — `traefik.<apex>`, plus every project domain | A challenge for a name that does not resolve to this host fails, and **failed challenges count against Let's Encrypt's rate limits**. Rehearse with `--acme-staging` until DNS is right. **Not probed** — kasbah never resolves a name for you | Not checked |
| Passwordless `sudo` — when the apps path does not exist yet, **and** to write the discovery pointer | `/apps` lives outside the deploy user's home, so nobody but root can create it; `/etc/kasbah/apps-path` is root-owned for the same reason it is machine-wide. Once both exist, init elevates again only to repair `/etc/kasbah` if its mode has drifted from `755` — re-runs otherwise only read the pointer | Apps path: hard fail naming the two commands to run by hand. Pointer: hard fail at a non-default apps path (the server would be undiscoverable), a warning at `/apps` (the fallback covers it) |

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
nothing and init exits naming both ways out. `rsync`, `ssh` and `git` are the
rest — the kasbah binary parses YAML and JSON
itself. "Docker" here means the daemon **and the compose plugin** — `build-push`
runs `docker compose -f compose.prod.yml build` locally, so a workstation with
`docker` but no `compose` gets through init and fails at the first build.

## What init creates

Every file kasbah writes, with mode and owner: `docs/files.md`.

Default paths (override with `--apps-path`, `--data-path`):

```
/etc/kasbah/                         root:root 755
└── apps-path                        root:root 644 — the discovery pointer
/apps/                               root owned by deploy user
├── .kasbah/
│   ├── server.json                  server marker (version, paths, limits, backup)
│   ├── bin/kasbah                   the kasbah binary — shipped by the workstation when absent
│   │                                or older, kept when the same or newer (installed under bin/.lock)
│   └── backup/                      only with --with-backup (see below)
│       ├── compose.yml              the scheduler stack — its runner is the mounted kasbah binary
│       ├── env                      mode 600 — kasbah's repo_base, the operator's credentials
│       └── repos/<repo>.pass        mode 600 — one encryption password per repository
├── data/                            bind-mount root for all projects
│   └── traefik/letsencrypt/
│       └── acme.json                touched as a file, chmod 600
├── backups/                         top-level backups (always created)
├── mail/                            only with --with-mail (see below)
│   ├── compose.yml                  DMS + SnappyMail
│   ├── kasbah.yml                   the registry: primary_domain + domains
│   └── .env                         mode 600 — kasbah's three keys, the operator's relay block
└── traefik/
    ├── compose.yml                  the shared Traefik stack
    ├── traefik.yml                  static config
    └── dynamic/                     file-provider watch dir
        ├── _shared.yml              middlewares + TLS options + dashboard router
        ├── _mail.yml                cert-trigger + webmail routers (only with --with-mail)
        └── <project>.yml            one per deployed project (copied in on deploy)
```

With `--with-mail`, the data path gains `mail/dms/{mail-data,mail-state,mail-logs,config}`
and `mail/snappymail`. Only those; SnappyMail builds its own `_data_/` tree
inside the last one and chowns it to the container's uid — pre-creating any of
it is what makes the *second* run fail, since the deploy user can no longer
traverse in. The postmaster account (`mail/dms/config/postfix-accounts.cf`,
mode 600) and the Rspamd DKIM override
(`mail/dms/config/rspamd/override.d/dkim_signing.conf`) are seeded there before
DMS first starts, and never written over afterwards.

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
means — inside the Traefik restart, once the running Traefik has stopped —
`acme.json` is copied to `acme.json.<UTC timestamp>` (mode 600, kept — the
certificates in it may be real; the copy is compared with the store before
anything is emptied) and emptied **in place**, and the new Traefik issues every
certificate afresh as it loads its configuration. A reset that fails brings
Traefik back on the store as it was, and init fails saying so — and, since a
re-run sees `traefik.yml` already naming the new CA and would not redo it, prints
the four commands that reset the store by hand. In
place, because the mail server mounts `acme.json` as a single file: a rename
would leave it on the archived copy, serving the old certificate and never
seeing a renewal (found on the real host).

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
  answers it; declining aborts with nothing created or restarted — on a re-run
  the kasbah binary may already have been brought up to date — and the message
  names the re-run that keeps the endpoint the server is on.
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
unprivileged path and calls `sudo` again only to put `/etc/kasbah` back to `755`.

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

Written by `server init`, and by any later run of it (`--with-mail`,
`--with-backup`). **`server upgrade-traefik` deliberately does not touch
it**: nothing the marker records — the paths, the resource limits — changes
when the proxy's image tag does, and the marker's presence is init's
"this completed" signal, which no other command should be able to write:

```json
{
  "kasbah_version": "0.1.0",
  "apps_path": "/apps",
  "data_path": "/apps/data",
  "cpu_limit": "3.6",
  "mem_limit": "7g",
  "backup": { "enabled": true, "repo_base": "s3:https://…/kasbah-backups/",
              "at": "02:00", "jitter": 1847, "timeout": 900,
              "retention": { "daily": 7, "weekly": 4, "monthly": 3 } }
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

Optional. Scaffolds a kasbah-owned scheduler stack that pushes restic
snapshots off-box daily: each project's data bind mounts, hook-produced
backups and `.env`, plus the shared mail stack's data into a repository of
its own. Full design — repository layout, the two-secret credential model,
restore and pruning — in `backup.md`.

**It installs nothing.** restic runs as a container
(`restic/restic:<pinned>`), so this section does not weaken the promise at
the top of this file. No apt, no sudo, no binary download.

What lands under the apps path:

| Path | Mode | Owner | On a re-run |
|---|---|---|---|
| `.kasbah/backup/` | 700 | kasbah | — |
| `.kasbah/backup/compose.yml` | 644 | kasbah | Re-shipped whenever its bytes differ, like Traefik's three |
| `.kasbah/backup/env` | 600 | **split** | `KASBAH_BACKUP_REPO_BASE` is kasbah's and rewritten by name; every other line is the operator's and copied through untouched — the same split `mail/.env` has |
| `.kasbah/backup/repos/` | 700 | kasbah | — |
| `.kasbah/backup/repos/<repo>.pass` | 600 | operator | **Written once, never rewritten.** A password kasbah could overwrite is a repository kasbah could orphan |
| `.kasbah/backup/state/` | 700 | kasbah | The one writable path in an otherwise read-only tree |
| `.kasbah/backup/state/status` | 644 | kasbah | The last-run record — when the run started and finished, how it went, which repositories, and the deadline. Three readers: the container's own healthcheck, `kasbah server status`, and `check --server`'s B01, the last two through one shared parser |

Docker objects: compose project and container `kasbah-backup`, network
`kasbah-backup_default`, and the named volume `kasbah-backup-cache`.

The idempotency rules mirror mail's, and for the same reasons:

- **`--no-backup` on a server that already has backups leaves them alone.**
  Init scaffolds; it does not remove. Taking the stack down is
  `docker compose -p kasbah-backup down` on the server, and removing it
  entirely is `kasbah server destroy`.
- The repository base is asked only when the marker does not already record
  one; the environment block is asked only on the run that creates the
  file; a password is asked only for a repository that has none. Everything
  with a documented default — the time, the jitter, the retention counts —
  is read back off the marker rather than re-asked, the same rule the
  dashboard credentials follow.
- The marker's `backup` object **merges**, it never replaces — including
  `backup.retention`. This is the field the compatibility rule above
  already anticipated.

**Init refuses rather than pretending** when the storage credential turns
out not to be append-only. Before the stack is started, it writes a probe
repository, takes two snapshots, attempts a real delete and counts again;
if the count drops, the credential can destroy history and init stops with
the stack unstarted. See `backup.md` → Credentials for the three refusals
and why the exit status of the delete is not what decides it.

## With mail (`--with-mail`)

Scaffolds `/apps/mail/` with docker-mailserver + SnappyMail (ported from
the original project's `mail/compose.yml`) and starts it. See `mail.md` for the stack
itself; this section is what `server init` does with it.

Three files land in `/apps/mail/`, and they have different owners:

| File | Owner | On a re-run |
|---|---|---|
| `compose.yml` | kasbah | Re-shipped whenever its bytes differ, like Traefik's three. A hand edit is reverted without a backup |
| `kasbah.yml` | kasbah, seeded from you | The registry — `primary_domain` and `domains:`. Both are **read back off the server** and reproduced, so an edit here survives and is how you move the MX hostname |
| `.env` | **split** | Three keys are kasbah's — `MAIL_HOSTNAME`, `DOMAIN`, `DATA_PATH` — derived from `kasbah.yml` and rewritten by name on every run. Every other line is copied through untouched, so the relay block stays yours |

A fourth file, `/apps/traefik/dynamic/_mail.yml`, carries the routers — the
cert-trigger for `mail.<domain>`, webmail for `webmail.<domain>`, and a `web`
redirect for each — and belongs to Traefik's watch directory rather than to
`mail/`. It is kasbah's and re-shipped on difference like the rest.

`primary_domain` defaults to `--domain`'s apex on the first run — the same
apex the dashboard hangs off, and the one `mail.<domain>` and
`webmail.<domain>` are formed from. Nothing prompts for it, because the
operator has already named it; changing it later is an edit to `kasbah.yml`
and a re-run.

### The postmaster account

DMS's Dovecot panics within 120 s if `postfix-accounts.cf` holds no account,
so init seeds one. It **prompts on the workstation** for the password
(`--postmaster-password=` for a script), hashes it locally (SHA512-crypt), and
ships only the hash — hashed where it was typed and never sent in any other
form, which is the rule the dashboard's bcrypt hash follows too. It travels on
the server binary's stdin with its size and sha256, never in argv. It is seeded
whenever `postfix-accounts.cf` holds no account line, comments-only included.

A trailing carriage return in the value is stripped, not refused — the flag
exists to be scripted, and a fleet script may have been saved on Windows. A
password with a *newline* in it is refused outright: a password field in DMS's
account file cannot hold one.

It is asked **once**. A server that already has an account is neither asked
about nor written to: that file holds every mailbox on the host, and a re-run
that rotated the postmaster password would be a re-run that locked somebody
out. Passing `--postmaster-password` to such a run is a warning, not a change.
To rotate it: `docker exec -it mail-dms setup email update postmaster@<domain>`.

### Ordering, and the mail ports

Mail requires the main Traefik stack to be running first so that the
`mail.<domain>` cert-trigger router can issue an ACME cert; init handles the
ordering automatically. Concretely: the fragment and both pre-seeds land
*before* Traefik starts, so Traefik requests both certificates at
configuration load; the mail containers start *after* Traefik is healthy.

**`25`, `465`, `587` and `993` are bound on the host** by DMS, and are not in
the prerequisites table above — nothing probes them. A port already held
surfaces as `docker compose up` failing in `/apps/mail`. Port 25 *outbound*
is blocked by default at many providers; that is a deliverability problem, not
a startup one, and the relay block in `.env` is the way out.

**DMS not being healthy the moment init finishes is expected**, not a failure,
and it has two quite different causes that look identical at that instant: a
container that was just created is inside its healthcheck's 60 s
`start_period`, and a container that cannot find a certificate for
`mail.<domain>` restarts until one appears. Init reports the state and the
restart count and says both rather than waiting.

Because the fragment lands before the containers start, issuance usually
finishes during the image pull and DMS comes up healthy on its first try —
measured on a real host, 0 restarts on a first run. Where it does not, expect
30–90 s. If `mail.<domain>` does not resolve to the host from the public
internet the challenge never validates, so the restarts are permanent — which
is also why this is not something init can wait on.

## `kasbah server status`

It changes nothing but kasbah's own binary, brought up to date first. Walks the apps
path, asks docker for every container's state and health, reads `versions.log`
and the Traefik fragment for each project, asks `df` about the apps and data
paths, reads Traefik's certificate store, and reads the backup stack's last-run
record:

```
VPS: you@vps (connected)
Docker: 29.6.0, Compose: 5.2.0
Root: /apps (pointer)  Data: /apps/data
Marker: kasbah 0.1.0-dev, cpu 1.8, mem 3g
Disk: /apps  12.8G of 37.6G used (35%), 24.8G free — /dev/sda1 on /
      /apps/data  the same filesystem

Traefik: running (healthy)
  Image: traefik:v3.7.10 (sha256:9c3b91d5fb77)
  Container: traefik
  Certificates: 4 in /apps/data/traefik/letsencrypt/acme.json
  Dashboard: traefik.example.com
      certificate valid for 87 more day(s) (until Nov 20 23:16:22 2026 GMT, C = US, O = Let's Encrypt, CN = YR2)

Mail: /apps/mail
  mail-dms         running (healthy)
  mail-snappymail  running (healthy)
  Primary: example.com   Domains: example.com
  mail.example.com
      certificate valid for 89 more day(s) (until Nov 23 08:05:25 2026 GMT, C = US, O = Let's Encrypt, CN = YR1)
  webmail.example.com
      certificate valid for 89 more day(s) (until Nov 23 08:05:31 2026 GMT, C = US, O = Let's Encrypt, CN = YR1)

Backup: rest:http://kasbah-vps:***@backups.example.com:8000/  daily at 02:00 plus 42s jitter
  kasbah-backup    running (healthy)
  last run         ok 4h ago — repositories: gallery jellyfin mail
  next run         in 19h
  repositories     gallery jellyfin mail

Projects:
  gallery        1/1 running    0.1.0      rollback 2026-08-23T00:16:46+00:00 (kasbah 0.1.0-dev)
      gallery.example.com
          certificate valid for 87 more day(s) (until Nov 20 23:16:21 2026 GMT, C = US, O = Let's Encrypt, CN = YR2)
      1 container(s), all running and none unhealthy
  jellyfin       0/1 stopped    2.4.1      deploy 2026-03-15T22:05:10+00:00 (kasbah 0.1.0)
      jellyfin.example.com
          no certificate — Traefik issues one when the hostname resolves here
      jellyfin-web             exited (none)
```

Versions appear exactly as `versions.log` holds them — no `v` prefix, and
the full ISO timestamp the log records rather than a truncated date, because
the log is the source of truth and a reformat invites a mismatch. Both the
image tag and the resolved image id are shown: a tag can be re-pushed under
the same name, the id cannot.

**The backup line's repository base is redacted**, here and everywhere else it
is printed: the base may carry a credential and the marker recording it is mode
644 by contract. A stack that has never fired, one whose record cannot be read,
one whose last run failed and one whose state has outlived its own deadline are
four different sentences, not one — a missing record on a server that has never
run a backup is not the same fact as a scheduler that stopped a month ago, and
reporting them identically would make the line decoration. `check --server`
answers the same question as a rule (B01) through the same parser.

**The per-project domain comes from `<apps>/traefik/dynamic/<name>.yml`**,
returned by the server binary in the same round trip and parsed by kasbah on the
workstation. The VPS needs no `yq`, `jq` or `python3`. Every `Host()` in the
fragment's rules is listed, once, in the order they appear.

**Certificate expiry comes from `<data>/traefik/letsencrypt/acme.json`**,
Traefik's own store, read by the same `internal/acme` that answers
`check --server`. The store holds the ACME account key and every certificate's
private key: it is never written to disk, echoed, or quoted in a message, and
the diagnostic that echoes a truncated probe back reports that one line by name
and length only. `notBefore` is deliberately not read — Let's Encrypt backdates
it by roughly an hour, so it is not issuance time.

**Disk is `df`, not `du`.** The question is whether the host is about to run out
of room, and it is answered in constant time; a `du` walk of a data path holding
a mail spool would make the report cost whatever the server happens to hold. A
data path on the apps path's filesystem is named as sharing it rather than
counted twice.

**Health is per container now**, not Traefik's alone. A project whose containers
are all running and none unhealthy gets one line saying so; a project that is
not gets one line per container, because a running-but-unhealthy container is
exactly what `1/1 running` cannot show.

**A server with no mail stack says so and moves on** — `Mail: not installed`
is an ordinary state, not a fault.

**All of it is one SSH round trip.** Each of those reads performed on its own is
what turns `status` into several sessions; the rig's `maxstartups 10` is what
that costs. The one value the far side has to work out for itself is the data
path, since the certificate store and the data disk figure hang off it: the
server binary reads it out of the marker.

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
- With mail on, a re-run: re-ships `mail/compose.yml`, `mail/kasbah.yml` and
  `dynamic/_mail.yml` only when their bytes differ; **rewrites `.env`'s three
  kasbah keys and copies every other line through**, so a hand-edited relay
  block is not a difference; **never rewrites `postfix-accounts.cf`**, so the
  postmaster password is not regenerated and no mailbox is lost; **never
  rewrites the Rspamd DKIM override**, which `setup config dkim` extends; and
  never touches mail data. It does not prompt for a password it will not use.
- `mail/.env`'s mode is enforced as 600 on every run, exactly as `acme.json`'s
  is and for the same reason: the mode is a fact about the file, not about the
  run that happened to write it, so a file left 644 by a hand edit converges on
  the next re-run rather than staying wrong while this document says otherwise.
- `--no-mail` on a server that already has mail **leaves it alone**. Init
  scaffolds mail; it does not remove it. Taking the stack down is
  `docker compose -p mail down` on the server.

## Handover / teardown

`kasbah server destroy` de-brands a VPS for handover — when the
server passes to a client or another operator. Every project container keeps
running, and Traefik and mail with them: the sites stay up. Only kasbah's own
backup scheduler (`kasbah-backup`) is stopped and removed. What's removed is
kasbah's management layer:

- `/apps/.kasbah/` (server marker, the backup scheduler stack with its
  credentials — agency-owned secrets never transfer — and, last, kasbah's own
  binary), and the discovery pointer `/etc/kasbah/apps-path`. The repositories
  themselves are **not** removed: they are operator property, and an
  append-only credential could not delete them in any case
- per project: `versions.log(.gz)`, the `scripts/` helpers by name,
  `.deploy.lock`, `.kasbah-client`, and the `.env` managed-block **sentinel
  comments** — the `KASBAH_*` values between them stay, or compose loses the
  interpolation every service's `cpus:`/`mem_limit:` depends on. Not
  `kasbah.yml` — the manifest is never synced to a server (`project-manifest.md`)
- mail, if present: the operator's relay block in `<apps>/mail/.env` (kasbah's
  three keys stay so the stack still starts) and the registry
  `<apps>/mail/kasbah.yml`. The postmaster account stays

What remains is a plain, self-contained Docker Compose setup the new owner
fully controls, still serving — every container keeps running *through* the
operation, and a project still `compose up`s from the server's own files
afterwards. The trade-off is explicit: deploy history and env tooling leave with
kasbah, and so does the mail registry, the only record of `primary_domain` and
the domain list. Double confirmation (typed hostname); full detail in `cli.md`.

Full teardown (actually stopping everything) stays manual on purpose —
too easy to misfire:

```
ssh user@host 'cd /apps/<project> && docker compose down'   # per project
ssh user@host 'cd /apps/traefik && docker compose down'
ssh user@host 'rm -rf /apps'                                 # dangerous
```
