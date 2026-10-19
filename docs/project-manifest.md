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

# Files/dirs to rsync from project root to /apps/shop/ on each deploy.
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

# Hooks run via `docker exec` on the VPS. Each entry is:
#   "<container> <cmd...>"
# The container name is resolved against the running compose project.
#
# pre-deploy runs BEFORE `compose up -d` — against the currently-running
# (previous version) containers. Use for: schema precheck, draining
# workers, anything that requires the old version still live.
# post-deploy runs AFTER `compose up -d` + healthcheck — against the new
# containers. Use for: migrations, cache warmup, cache rebuild.
hooks:
  pre-deploy:
    - shop-php-fpm php artisan migrate:status   # fail fast if DB unreachable
  post-deploy:
    - shop-php-fpm php artisan migrate --force
    - shop-php-fpm php artisan config:cache
    - shop-php-fpm php artisan route:cache

  # Projects that need migration rollback count their own migrations in
  # the hook (kasbah doesn't track migration counts).
  pre-rollback:
    - shop-php-fpm php artisan migrate:rollback --force

  post-rollback:
    - shop-php-fpm php artisan config:cache

# Backup hook — runs BEFORE pre-deploy hooks (so against the still-running
# previous version's containers), IF the `check` command exits 0. This
# ordering means a backup always exists before any pre-deploy work
# touches live state. Output goes to ./backups/ relative to the project
# dir on the VPS. Kasbah rotates these (keeps last `retain` by default).
backup:
  container: shop-postgres
  # Any command, run in the VPS's shell with cwd = the project directory.
  # Exit 0 = take a backup. Exit non-zero = skip. Reaching into a container
  # means writing the `docker exec` yourself — `check` is not scoped to
  # `container:` above, which is the thing being backed up, not the thing
  # deciding. Other examples: `[ -f ./.force-backup ]`; `true` to always
  # back up.
  check: docker exec shop-php-fpm php artisan migrate:status | grep -q pending
  command: pg_dump -U $DB_USERNAME $DB_DATABASE
  extension: sql.gz
  pipe: gzip
  retain: 10

# Mail claim — tells kasbah this project expects `mail.<domain>` (and SMTP)
# to be available. The deploy checks the stack is there and that its registry
# serves the domain, and warns without stopping when either is not so. Account
# management is NOT done here — use `docker exec mail-dms setup email add
# foo@domain` on the VPS directly.
mail:
  domain: shop.example.com
  # Optional pre-seed files copied to the mail stack's data dir on first
  # deploy (safe to re-run — kasbah only copies if the target is missing).
  snappymail_domain: ./mail/snappymail-domain.json
```

## Field reference

### `schema` *(required)*

Integer. The manifest schema version. Bumps when the format changes in a
breaking way. `kasbah` refuses to operate on a manifest whose schema is newer
than the installed binary. In the other direction, every kasbah version
reads all older schemas of its own major; crossing a major boundary requires
`kasbah migrate` (see the compatibility policy in `overview.md`). Schema 1 is
**frozen as of kasbah 1.0.0**: any change to the format is a new schema number
and goes through an explicit migration. `kasbah --version` prints it.

### `kasbah_version` *(required, auto-written)*

The version of `kasbah` that last wrote this file. Kasbah writes this on
`init-project`, `check --fix`, and when running a schema migration. Projects
shouldn't edit it manually. Used by future Go binary to know whether to
migrate files in the source tree.

### `name` *(required)*

Directory name on the VPS (`/apps/<name>/`) and basis for container names.
Must match `^[a-z][a-z0-9-]*$`.

**Reserved: `traefik`, `mail`, `data`, `backups`.** Those directories under
`/apps/` belong to kasbah, and a project claiming one is not a naming collision
but a live hazard: a project named `traefik` would rsync its compose file over
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
rule the deploy engine follows for hooks, backup and health. The value must
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

Rsync list applied on every deploy. Each entry is either `src` or `src -> dst`
(relative to project root on dev; `/apps/<name>/` on VPS). Trailing `/` means
"recurse". Kasbah ships no scripts: its server side is the kasbah binary itself
(`<apps>/.kasbah/bin/kasbah`), so the drift check on the server is the same code
`kasbah check` runs here. The manifest itself is **not**
shipped: nothing on the server reads it yet, and `kasbah.yml` in a
project's sync list would be a second copy to drift.

The Traefik dynamic config (`traefik-dynamic.yml` at project root) is
**not** listed here. Kasbah rsyncs it directly to
`/apps/traefik/dynamic/<name>.yml` out-of-band, the same way it handles
its own helper scripts. See `traefik.md` for the fragment shape.

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
`container:` set, the deploy waits on that one container. Without it — no
`health:` block at all, or a block naming only `timeout:` — the deploy waits on
every container in the project that declares a healthcheck, which is what lets
a project raise the timeout without singling out one container.

A container that declares **no** healthcheck is an immediate pass, never a
wait. Note that this cannot be detected by reading
`{{.State.Health.Status}}` and finding it empty: that template *errors* on a
container with no health block (`map has no entry for key "Health"`). The
guarded form is `{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}`.

### `hooks` *(optional)*

Each hook is a list of strings. Each string starts with a literal
**container name**, followed by the command to run inside it. The target
service in `compose.prod.yml` must set an explicit `container_name:` —
compose's auto-generated `<project>_<service>_1` won't match. `kasbah check`
(HK01) enforces this.

The rest of the string is a **shell command**, not an argument vector. Kasbah
runs it as:

```
docker exec -e VERSION -e PREV_VERSION -e DEPLOY_BACKUP <container> sh -c '<rest>'
```

so a pipeline, a redirection, a quoted argument and `$VERSION` all mean what
they look like. There is no `-T`: that is `docker compose exec`'s flag, and
`docker exec` rejects it outright (`unknown shorthand flag: 'T'`). Plain
`docker exec` allocates no pty unless asked with `-t`, so it already is the
form a non-interactive hook wants.

**A hook is one line.** A multi-line value — a `|` block scalar, or a string
with an embedded newline — is refused, because "the first word is the
container" has no meaning on the second line. Chain with `&&` on one line
instead, or put the sequence in a script inside the image and call that. This
is refused rather than accepted because the failure it prevents is silent: read
as several hooks, the first line would run and the rest would be discarded as
hooks naming containers that do not exist. The cost is that the target container must have a `/bin/sh` —
a distroless or scratch image cannot be a hook target. That is the deliberate
trade: hooks are written by the project's author in the shell they already
think in, and every base image a kasbah project has ever used has a shell.

Supported hooks and when they run:

| Hook | Runs | Containers it exec's into |
|---|---|---|
| `pre-deploy` | after env/sync + backup, before `compose up -d` | currently-running (previous version) |
| `post-deploy` | after `compose up -d` + health wait | new version |
| `pre-rollback` | after git-archive sync, before `compose up -d` | currently-running (pre-rollback) |
| `post-rollback` | after `compose up -d` + health wait | rolled-back version |

The `pre-*` hooks exec against containers from the *outgoing* state; the
`post-*` hooks exec against containers from the *incoming* state. Container
names are the same across versions (compose project name is stable), so
the hook commands look identical — it's the timing that picks the target.

Environment variables available to hook commands (set by kasbah):
- `$VERSION` — the version being deployed/rolled to.
- `$PREV_VERSION` — the version previously current (may be empty on first deploy).
- `$DEPLOY_BACKUP` — path to the backup file, or `no-backup`. Available to
  **both** `pre-deploy` and `post-deploy`: the backup step runs before either,
  so a pre-deploy hook can already name the file that was just written.

Kasbah does **not** generalize migration accounting. Projects that need to
count migrations (Laravel, Rails, Django, etc.) do that inside their hook
by querying their framework's migration table.

### `backup` *(optional)*

If present, kasbah may take a backup as the **first** step of the VPS-side
deploy — before the `pre-deploy` hooks, and therefore against the still-running
previous version's containers. That ordering is the point: a backup always
exists before any hook touches live state.

- `check` — any command. Exit code 0 triggers the backup; non-zero skips
  it. Projects decide their own trigger: pending migrations, a sentinel
  file, config change detection, or simply `true` to back up every deploy.
  It runs in the **VPS's own shell**, with the working directory set to the
  project directory — so `[ -f ./.force-backup ]` reads a file next to the
  compose file, and reaching into a container means writing the `docker exec`
  yourself. It is deliberately not scoped to `backup.container`: the thing
  that decides whether to back up is often not the thing being backed up.
- `command` — command that writes the backup to stdout. Unlike `check`, this
  runs *inside* `backup.container`, as `docker exec <container> sh -c
  '<command>'` — so `$DB_USERNAME` resolves to the container's environment.
- `pipe` — optional stdout pipe (e.g. `gzip`). Runs on the VPS, not in the
  container.
- `extension` — filename extension (resulting file:
  `backups/pre-deploy-<timestamp>.<extension>`).
- `retain` — number of backups to keep (oldest are deleted on success).

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
- `snappymail_domain` — optional JSON file to seed SnappyMail's domain config,
  copied on deploy to
  `<data>/mail/snappymail/_data_/_default_/domains/<domain>.json` **if the
  domain check above passed and it is not already there** — copy-if-missing, never over one SnappyMail has since
  edited, and through `docker cp`, because that directory belongs to the
  container's uid at mode 750. `kasbah check`'s **M02** fails when the named
  file is missing or is not valid JSON: what lands is what stays.

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
| `kasbah_version` | `init-project` (set once, when the file is created) | future `kasbah migrate` |
| `last_server` | every project command that targets a server, once kasbah's own work on it succeeded (see Write rules) | every project command — used as default when `USER@HOST` is omitted |
| `last_deploy` | `deploy`, `rollback` on success | nothing yet — recorded for a future deployed-vs-local diff |
| `last_version` | `deploy`, `rollback` on success | nothing yet |
| `schema_migrations_applied` | `kasbah migrate` | `kasbah migrate` (idempotency) |

`kasbah pending` does **not** read `last_version`. It resolves the deployed
version by querying `versions.log` on the VPS at runtime. State is a cache
for defaults, not a source of truth for what's actually running.

### Write rules

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
  kasbah last wrote the project's files, for a future `kasbah migrate`.
- Record the last deploy, for a future deployed-vs-local diff (nothing reads it
  yet).
