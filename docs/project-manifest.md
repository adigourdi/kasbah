# Project Manifest — `kasbah.yml`

The single file kasbah needs in a project. Lives at the project root.
Everything else kasbah knows about the project is derived from it plus the
project's `compose.yml` and `.env.prod.example`.

Whether a project builds its own images or only pulls stock ones is
derived from `compose.prod.yml`: any service with a `build:` key is
built and shipped by `kasbah build-push`; services with only `image:`
are pulled by `compose up -d` on the VPS. There is no `type` field.

## Minimal example (stock-image project)

```yaml
# jellyfin/kasbah.yml
schema: 1                       # manifest schema version
kasbah_version: 0.1.0          # kasbah version that last wrote this file

name: jellyfin                  # project directory name on the VPS
domain: jellyfin.example.com    # primary Traefik hostname

sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
```

## Full example (project with built images)

```yaml
schema: 1
kasbah_version: 0.1.0

name: shop
domain: shop.example.com
client: shop                    # backup repo grouping — defaults to name

# Files/dirs to sync from project root to /apps/shop/ on each deploy.
# "a -> b" renames on arrival. No arrow = same path. Trailing / recurses.
sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
  - docker/postgres/init-postgis-prod.sql

# Healthcheck to block on after `compose up -d` before running post-deploy
# hooks. Uses Docker's native healthcheck state.
health:
  container: shop-php-fpm
  timeout: 120s

# Hooks are lines of shell, each run with `sh -c` on the VPS, in the project
# folder <apps>/<name>/ — so `docker compose exec -T <service>` reaches a
# container by its service name.
#
# backup runs first on every deploy but a project's first, while the previous
# version is still running, and writes into $KASBAH_BACKUP_DIR: what it
# writes is kept with the previous version's .env and synced files, as one
# tarball under ./backups/. restore is the way back: a rollback to this
# version runs it, when the operator says so, reading that tarball unpacked
# at $KASBAH_BACKUP_DIR before this version comes up.
# pre-deploy runs BEFORE `compose up -d`, while the previous version is
# still running. Use for: schema precheck, draining workers, anything that
# requires the old version still live.
# post-deploy runs AFTER `compose up -d` + healthcheck, against the new
# containers. Use for: migrations, cache warmup, cache rebuild.
hooks:
  backup:
    - docker compose exec -T postgres pg_dump -U shop shop | gzip > "$KASBAH_BACKUP_DIR/db.sql.gz"
  restore:
    - gunzip -c "$KASBAH_BACKUP_DIR/db.sql.gz" | docker compose exec -T postgres psql -U shop shop
  pre-deploy:
    - docker compose exec -T php-fpm php artisan migrate:status   # fail fast if DB unreachable
  post-deploy:
    - docker compose exec -T php-fpm php artisan migrate --force
    - docker compose exec -T php-fpm php artisan config:cache
    - docker compose exec -T php-fpm php artisan route:cache

  # Projects that need migration rollback count their own migrations in
  # the hook (kasbah doesn't track migration counts).
  pre-rollback:
    - docker compose exec -T php-fpm php artisan migrate:rollback --force

  post-rollback:
    - docker compose exec -T php-fpm php artisan config:cache

# Per-project limits, each container's own ceiling instead of the server's
# 90%. Either half may be left out. A % is a share of the whole host, worked
# out on the server at deploy; a value above the server's ceiling is refused.
resources:
  cpus: 2          # cores, at most one decimal (0.5), or a share (25%)
  memory: 25%      # MiB (512m), GiB (2g) or a share — a bare number is refused

# Mail claim — tells kasbah this project expects `mail.<domain>` (and SMTP)
# to be available. The deploy checks the stack is there and that its registry
# serves the domain, and warns without stopping when either is not so. Account
# management is NOT done here — use `docker exec mail-dms setup email add
# foo@domain` on the VPS directly.
mail:
  domain: shop.example.com
```

## Field reference

Types are what the YAML says, not what it can be printed as. A text field
(`name`, `domain`, `client`, `kasbah_version`, every command, container and
domain below) takes a string — a number reads as its text — and refuses a
boolean, a list or a block; a block (`health`, `hooks`, `resources`, `mail`)
that is not a mapping is refused, and an absent or null one means none
(`false` too, for `health` and `mail`); `sync` must be a list. A top-level
`backup:` key, whatever it holds, is refused by `kasbah check` (HK02) and by
every deploy and rollback, pointing at `hooks.backup` (below).

### `schema` *(required)*

Integer. The manifest schema version. Bumps when the format changes in a
breaking way. `kasbah` refuses to operate on a manifest whose schema is newer
than the installed binary. In the other direction, every kasbah version
reads all older schemas of its own major; crossing a major boundary requires
`kasbah migrate` (see the compatibility policy in `overview.md`). Schema 1 is
**frozen as of kasbah 1.0.0**: any change to the format is a new schema number
and goes through an explicit migration — except an optional key that an older
kasbah ignores, which schema 1 takes without a bump (`resources:` is one).
`kasbah --version` prints it.

### `kasbah_version` *(required, auto-written)*

The version of `kasbah` that last wrote this file. Kasbah writes this on
`init-project`, `check --fix`, and `kasbah migrate`. Projects shouldn't edit
it manually. `kasbah migrate` reads it to know which files in the source tree
still need moving.

### `name` *(required)*

Directory name on the VPS (`/apps/<name>/`) and basis for container names.
Must match `^[a-z][a-z0-9-]*$`.

**Reserved: `traefik`, `mail`, `data`, `backups`.** Those directories under
`/apps/` belong to kasbah, and a project claiming one is not a naming collision
but a live hazard: a project named `traefik` would sync its compose file over
the shared stack's, then run `docker compose -p traefik up -d
--remove-orphans` in that directory — and since Traefik is not a service in
the project's file, `--remove-orphans` removes the reverse proxy every site
on the box is behind. `mail` is the same hazard one directory over: `/apps/mail/`
holds the shared mail stack, and `--remove-orphans` there takes mail off the
whole server. `kasbah check` and `kasbah deploy` both refuse these names, and
`init-project` will not scaffold one.

### `domain` *(required)*

The primary Traefik hostname. Used in checks (the compose file must route
this host somewhere), in `kasbah server status` output, and for the mail
claim reconciliation.

### `client` *(optional)*

Groups this project's off-VPS backups: the restic repo is
`<repo_base>/<client>`, defaulting to `name` when absent. Projects that
declare the same `client` share a repo, so offboarding hands over (or
deletes) exactly one repo per client — and per-client degenerates
gracefully into per-project when the field is omitted. Same charset rules
as `name`. See `backup.md`.

**Checked by `kasbah check` as S08** (`compliance.md`) and **read by
`kasbah deploy`**, which renders the effective value (this field, or
`name` when absent) to `<apps>/<name>/.kasbah-client` on the server. The
manifest itself is never synced, so that record is how the VPS-side backup run
learns which repository a project belongs to — the same "render, never copy"
rule the deploy engine follows for hooks and health. The value must
match `^[a-z][a-z0-9-]*$` and may not be one of the reserved names kasbah owns
under `<apps>/` (`traefik`, `mail`, `data`, `backups`): a project claiming
`mail` would put every mailbox on the host into one client's handover. A
project deployed before backups were enabled has no record, and the backup run
falls back to its directory name — which is this field's default — while naming
it, so a project filing into the wrong repository is visible rather than silent. A **tag's** manifest carrying a value this kasbah refuses is a
warning, not a failure: `kasbah rollback` falls back to the directory name and
carries on, because a version the server has already run must stay rollable
after a rule tightens.

### `sync` *(required, list)*

Sync list applied on every deploy (only changed files travel). Each entry is either `src` or `src -> dst`
(relative to project root on dev; `/apps/<name>/` on VPS). Trailing `/` means
"recurse". Kasbah ships no scripts: its server side is the kasbah binary itself
(`<apps>/.kasbah/bin/kasbah`), so the drift check on the server is the same code
`kasbah check` runs here. The manifest itself is **not**
shipped: nothing on the server reads it yet, and `kasbah.yml` in a
project's sync list would be a second copy to drift.

The Traefik dynamic config (`traefik-dynamic.yml` at project root) is
**not** listed here. Kasbah syncs it directly to
`/apps/traefik/dynamic/<name>.yml` out-of-band. See `traefik.md` for the fragment shape.

`.env.prod.example` is required (check S04) whether or not the project has
anything to configure: a project with nothing to declare ships a comment-only
template, which is a normal end state rather than a gap, and what
`init-project` scaffolds. The hostname is not one of those things — it is
load-bearing in `domain:` above and in the fragment, not in the environment.

### `health` *(optional)*

Which container to block on during deploy before running `post-deploy` hooks,
and how long to wait:

```yaml
health:
  container: app-php-fpm   # optional
  timeout: 120s            # optional, default 120s
```

**Both keys are optional, and the block may carry either alone.** With
`container:` set, the deploy waits on that one container: a `container_name`,
or a compose service name, which resolves on the server to that service's
lowest-numbered running replica (or its first container when none runs) — what
lets it name a service compose names `<project>-<service>-N` and a rolling
deploy renames. An exact `container_name` wins on a clash; `kasbah check`
holds the name to the compose file. Without it — no
`health:` block at all, or a block naming only `timeout:` — the deploy waits on
every container in the project that declares a healthcheck, which is what lets
a project raise the timeout without singling out one container.

A container that declares **no** healthcheck is an immediate pass, never a
wait. Note that this cannot be detected by reading
`{{.State.Health.Status}}` and finding it empty: that template *errors* on a
container with no health block (`map has no entry for key "Health"`). The
guarded form is `{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}`.

### `hooks` *(optional)*

`hooks:` holds up to six lists — `backup`, `pre-deploy`, `post-deploy`,
`restore`, `pre-rollback` and `post-rollback` — and nothing else: any other key (a typo such as
`pre_deploy`) is refused, except in a tag's manifest (`rollback`,
`deploy X.Y.Z`), where it is a warning and ignored, so a version a server has
run stays rollable.

Each entry is one **shell command**, run on the server as

```
sh -c '<entry>'
```

in the server's own shell, with the working directory set to the project folder
`<apps>/<name>/`. A pipeline, a redirection, a quoted argument and
`$KASBAH_VERSION` all mean what they look like. Reaching into a container is the
hook's own business: `docker compose exec -T <service> …` finds the project's
container by its compose service name, since the folder holds the project's
`compose.yml` and kasbah sets `COMPOSE_PROJECT_NAME` to the project's name for
the hook — `-T`, because a hook has no terminal. The hooks run under `LC_ALL=C`,
with no stdin; what a hook prints, on stdout or stderr, reaches the operator on
stderr, because the engine's stdout is the report the workstation reads. The
entries of a list run in order; one that exits non-zero fails the list, unless
the operator carries on past it (below), and then the next entry runs.

**A hook is one line.** A multi-line value — a `|` block scalar, or a string
with an embedded newline — is refused, and so is an empty entry or one that is
not a string. Chain with `&&` on one line instead, or put the sequence in a
script and call that. Refused rather than accepted, because a value read as
several hooks would run the first line and fail or skip the rest silently.

Supported hooks and when they run:

| Hook | Runs |
|---|---|
| `backup` | on a deploy, after env/sync, before the `pre-deploy` hooks, the previous version still running; writes into `$KASBAH_BACKUP_DIR` |
| `pre-deploy` | after the `backup` hooks, before `compose up -d`, the previous version still running |
| `post-deploy` | after `compose up -d` + health wait, against the new version |
| `pre-rollback` | after the target tag's files are synced, before `compose up -d` |
| `restore` | on a rollback to this version answered `--with-data` (or yes), after the `pre-rollback` hooks and before `compose up -d`, the outgoing version still running; reads `$KASBAH_BACKUP_DIR`. Never on a deploy |
| `post-rollback` | after `compose up -d` + health wait, against the rolled-back version |

On a **first deploy** — `versions.log` holds no entry for the project, active or
archived, a `deploy-failed` line counting as one — there is no outgoing
version, so the `backup` and `pre-*` hooks do not run, and the run says so.
Otherwise they always run: kasbah does not look at the containers first, and a
hook that needs the outgoing stack up, or that wants to skip a dump, tests for
that itself. `--skip-hooks` skips the `pre-*` and `post-*` hooks, never `backup`
or `restore`. A rollback never runs `backup`.

The `restore` hook that runs is the **target's**: a rollback reads every hook
from the target tag's manifest, and asks for data only when that manifest has
one and the server holds a backup of that version, the newest
`backups/<version>-<stamp>.tar.gz` — a restore replaces everything written
since that backup, so it never runs unasked (`cli.md` → `kasbah rollback`,
`--with-data`/`--no-data`). kasbah restores no data itself, and a hook that
needs a dump the backup does not hold fails the rollback by failing. When a `backup`,
a `pre-*` or the `restore` hook fails, no container has moved yet, and kasbah asks whether to
carry on (`--on-hook-failure=continue|stop`, `cli.md`): stopping puts the synced
files back and leaves whatever the hooks already did, continuing runs on to the
retag and `compose up` as if the step had passed, and says so. Stopping after a
`restore` hook that ran leaves the data as the hook left it. A failed `post-*` hook is not reverted (`build-deploy.md`).

Environment variables available to hook commands (set by kasbah):
- `$KASBAH_VERSION` — the version being deployed or rolled back to.
- `$KASBAH_PREV_VERSION` — the version previously current (empty on a first
  deploy).
- `$KASBAH_PROJECT` — the project's name.
- `$KASBAH_BACKUP_DIR` — on a deploy that is not a first, the absolute path of
  the backup directory this run fills, `<apps>/<name>/backups/<version>-<stamp>/`
  (`<version>` the outgoing one): the `backup` hooks write their dumps there, and
  the `pre-deploy` and `post-deploy` hooks see the same path. `none` on a first
  deploy, and on a deploy carried past a backup
  directory that could not be created. Once the new version is live, the directory
  — what the hooks wrote, beside the snapshot kasbah took of the outgoing `.env`
  and synced files — becomes `backups/<version>-<stamp>.tar.gz`
  (`build-deploy.md` → A deploy that fails … reverts). The name
  `kasbah-snapshot` in it is kasbah's.
  On a rollback, the `pre-rollback`, `restore` and `post-rollback` hooks get the
  target version's newest backup, unpacked into a directory of its own,
  `<apps>/<name>/.kasbah-unpacked.<pid>/` (mode `770` to the `kasbah` group,
  as `.env` is `660`, removed when the run ends), laid out as it was written: the `backup` hooks' files at the top level,
  and the outgoing `.env` and synced files of that time under
  `kasbah-snapshot/<path>` — `kasbah-snapshot/.env`, `kasbah-snapshot/compose.yml`.
  `none` when the server holds no backup of the target. After a failed
  extraction carried past, the `pre-rollback` and `post-rollback` hooks get
  `none` and the `restore` hook does not run at all: the data is left as it
  is, and the run says so.

The manifest never reaches the server, so every deploy and rollback that
leaves its version live records the `backup` and `restore` lists, and the paths
its snapshot copies, in `<apps>/<name>/.kasbah-hooks.json` (`files.md`).

The project's `.env` is not loaded into the hooks' environment; `docker compose`
reads it as it always does.

Kasbah does **not** generalize migration accounting. Projects that need to
count migrations (Laravel, Rails, Django, etc.) do that inside their hook
by querying their framework's migration table.

### `resources` *(optional)*

The project's own resource limits, in place of the server's 90% ceiling:

```yaml
resources:
  cpus: 1.5      # cores, or a share of the host: 25%
  memory: 2g     # 512m, 2g, or a share of the host: 25%
```

Either key may be left out; an absent block, or an absent half, keeps the
server marker's ceiling for that half. What a deploy writes into the managed
block of `.env` (`KASBAH_CPU_LIMIT`, `KASBAH_MEM_LIMIT` — `env-template.md`) is
then this value, so every service on the variables gets it: it is a
**per-container** ceiling, not a budget the project's containers share.

- `cpus` — a number of cores above 0 with at most one decimal (`0.5`, `2`;
  compose's meaning), or a whole percentage from `1%` to `100%`.
- `memory` — whole MiB with `m` or GiB with `g` (`512m`, `2g`; at least
  docker's `6m`), or a whole percentage. A bare number is refused naming the
  three: docker would read it as bytes. A percentage that comes to less than
  `6m` on the host it resolves on (`1%` of a 512 MiB host) is refused there,
  as the server binary resolves it.

A `%` is a share of the **whole host** — `100%` is all of it — and is resolved
on the server, by the server binary reading its own CPU count and `MemTotal`,
the same two numbers `server init` measured. It is spelled the way the marker
spells its ceilings (`server-setup.md` → How the numbers are spelled): cores
with one decimal, floored to the tenth and never below `0.1`; memory floored to
whole GiB, else whole MiB. A bare core count gains its decimal (`2` → `2.0`);
`m` and `g` are written as given. So `.env` stays byte-identical across deploys
to an unchanged host.

The resolved values are held to the marker's 90% ceiling **before anything of
the project changes on the server** — at `deploy` before the sync, at
`kasbah env` before the template ships: a value above it fails with exit 1,
naming the field, what it came to and the ceiling. `deploy X.Y.Z` holds the
tag's block to the same rules (a block this kasbah refuses stops it before any
connection). `rollback` alone never refuses over it, so a version a server has
run stays rollable: a value above today's ceiling warns and takes the ceiling
for that half, and a block this kasbah refuses or a resolve that fails warns
and takes the ceiling for both. `kasbah check` validates the block (R05) and
`check --server` sums the projects that set limits of their own (R06,
`compliance.md`).

### `mail` *(optional)*

Declares the project uses the VPS mail stack. **The block is a mapping and
`domain` is required** — a `mail:` block without one is refused at deploy,
since a claim naming no domain claims nothing.

- `domain` — the domain the project expects the mail stack to handle. At
  deploy, kasbah checks that a mail stack exists on the server, that
  `/apps/mail/kasbah.yml` — the stack's registry — lists this domain, and that
  DMS is running. Every one of those **warns and continues**: an unmet mail
  claim costs mail, not the site. `kasbah server add-mail-domain USER@HOST
  <domain>` is what makes it met. `kasbah check`'s **M01** is the local half —
  a `mail:` block with no `domain` fails there and is refused at deploy.
  Webmail needs no per-domain configuration (`mail.md` → Webmail).

No `accounts` field — mailboxes are created/removed out-of-band with:

```
ssh you@vps 'docker exec mail-dms setup email add noreply@example.com'
```

This keeps accounts decoupled from the deploy cycle.

## State file (`.kasbah/state.json`, not manifest)

Every file kasbah writes, with mode and owner: `docs/files.md`.

Stored in the project root. Not committed (add to `.gitignore`). Not synced
to the VPS. Tracks:

```json
{
  "kasbah_version": "0.1.0",
  "last_server": "user@vps",
  "last_deploy": "2026-04-12T01:00:00Z",
  "last_version": "1.3.0",
  "schema_migrations_applied": []
}
```

### Fields

| Field | Written by | Read by |
|---|---|---|
| `kasbah_version` | `init-project` (set once, when the file is created) | `kasbah migrate` |
| `last_server` | every project command that targets a server, once kasbah's own work on it succeeded (see Write rules) | every project command — used as default when `USER@HOST` is omitted |
| `last_deploy` | `deploy`, `rollback` on success | nothing — recorded so a deployed-vs-local diff can read it |
| `last_version` | `deploy`, `rollback` on success | nothing |
| `schema_migrations_applied` | `kasbah migrate` | `kasbah migrate` (idempotency) |
| `dirty_build`, `dirty_server`, `dirty_tree` | `build-push --dirty` once the images shipped and only when the tree did not change during the build: the label, the target, and a digest of the working tree it built | `deploy --dirty`, which deploys that label only to that server from that same tree (`build-deploy.md` → Versioning contract) |

`kasbah pending` does **not** read `last_version`. It resolves the deployed
version by querying `versions.log` on the VPS at runtime. State is a cache
for defaults, not a source of truth for what's actually running.

### Write rules

- Written as standard JSON (2-space indent, key order kept); a file that is
  not valid JSON — a byte-order mark included — is refused and left untouched.
- Written **only on success**, where success means *kasbah's* work — reach the
  server, find the project, do what was asked. Failed commands leave state
  untouched.
- `kasbah exec` is where those two come apart, and it writes `last_server`
  whenever the command it was asked to run **ran at all**, whatever that
  command answered. Its own exit status is the command's (`cli.md` → exit
  codes), so `kasbah exec web -- test -f /srv/x` exits 1 on a file that is not
  there — a fact about the container, not a run that failed, and not a reason
  to make the next invocation name the server again. `kasbah logs` writes on
  0 and on the two statuses that mean the run stopped rather than failed — 255
  (the reader closed the pipe) and 130 (interrupted) — and not when compose
  failed.
- `last_server` is updated by: `build-push`, `deploy`, `rollback`, `drop`,
  `env`, `history`, `changelog`, `pending`, `logs`, `exec`, `check --server`.
- `init-project` creates the file with empty fields and the current
  `kasbah_version`. First server-targeting command must be passed
  `USER@HOST` explicitly; subsequent ones default to `last_server`.

### Purpose

- Default `USER@HOST` so users don't repeat it every command in the same project.
- Anchor the source-tree schema migration story: `kasbah_version` says which
  kasbah last wrote the project's files, the anchor `kasbah migrate` works from.
- Record the last deploy, so a deployed-vs-local diff can read it (nothing does).
