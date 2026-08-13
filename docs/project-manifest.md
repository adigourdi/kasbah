# Project Manifest — `hosting.yml`

The single file hosting needs in a project. Lives at the project root.
Everything else hosting knows about the project is derived from it plus the
project's `compose.yml` and `.env.prod.example`.

Whether a project builds its own images or only pulls stock ones is
derived from `compose.prod.yml`: any service with a `build:` key is
built and shipped by `hosting build-push`; services with only `image:`
are pulled by `compose up -d` on the VPS. There is no `type` field.

## Minimal example (stock-image project)

```yaml
# jellyfin/hosting.yml
schema: 1                       # manifest schema version
hosting_version: 0.1.0          # hosting version that last wrote this file

name: jellyfin                  # project directory name on the VPS
domain: jellyfin.example.com    # primary Traefik hostname

sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
```

## Full example (project with built images)

```yaml
schema: 1
hosting_version: 0.1.0

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
  # the hook (hosting doesn't track migration counts).
  pre-rollback:
    - shop-php-fpm php artisan migrate:rollback --force

  post-rollback:
    - shop-php-fpm php artisan config:cache

# Backup hook — runs BEFORE pre-deploy hooks (so against the still-running
# previous version's containers), IF the `check` command exits 0. This
# ordering means a backup always exists before any pre-deploy work
# touches live state. Output goes to ./backups/ relative to the project
# dir on the VPS. Hosting rotates these (keeps last `retain` by default).
backup:
  container: shop-postgres
  # Any command. Exit 0 = take a backup. Exit non-zero = skip.
  # Examples: grep pending migrations; `[[ -f ./.force-backup ]]`; `true`
  # to always back up.
  check: sh -c 'shop-php-fpm php artisan migrate:status | grep -q pending'
  command: pg_dump -U $DB_USERNAME $DB_DATABASE
  extension: sql.gz
  pipe: gzip
  retain: 10

# Mail claim — tells hosting this project expects `mail.<domain>` (and SMTP)
# to be available. Hosting validates the domain is known to the mail stack
# on the VPS. Account management is NOT done here — use `docker exec
# mail-dms setup.sh email add foo@domain` on the VPS directly.
mail:
  domain: shop.example.com
  # Optional pre-seed files copied to the mail stack's data dir on first
  # deploy (safe to re-run — hosting only copies if the target is missing).
  snappymail_domain: ./mail/snappymail-domain.json
```

## Field reference

### `schema` *(required)*

Integer. The manifest schema version. Bumps when the format changes in a
breaking way. `hosting` refuses to operate on a manifest whose schema is newer
than the installed binary. In the other direction, every hosting version
reads all older schemas of its own major; crossing a major boundary requires
`hosting migrate` (see the compatibility policy in `overview.md`).

### `hosting_version` *(required, auto-written)*

The version of `hosting` that last wrote this file. Hosting writes this on
`init-project`, `check --fix`, and when running a schema migration. Projects
shouldn't edit it manually. Used by future Go binary to know whether to
migrate files in the source tree.

### `name` *(required)*

Directory name on the VPS (`/apps/<name>/`) and basis for container names.
Must match `^[a-z][a-z0-9-]*$`.

**Reserved: `traefik`, `data`, `backups`.** Those directories under `/apps/`
belong to hosting, and a project claiming one is not a naming collision but
a live hazard: a project named `traefik` would rsync its compose file over
the shared stack's, then run `docker compose -p traefik up -d
--remove-orphans` in that directory — and since Traefik is not a service in
the project's file, `--remove-orphans` removes the reverse proxy every site
on the box is behind. `hosting check` and `hosting deploy` both refuse these
names, and `init-project` will not scaffold one.

### `domain` *(required)*

The primary Traefik hostname. Used in checks (the compose file must route
this host somewhere), in `hosting server status` output, and for the mail
claim reconciliation.

### `client` *(optional)*

Groups this project's off-VPS backups: the restic repo is
`<repo_base>/<client>`, defaulting to `name` when absent. Projects that
declare the same `client` share a repo, so offboarding hands over (or
deletes) exactly one repo per client — and per-client degenerates
gracefully into per-project when the field is omitted. Same charset rules
as `name`. See `backup.md`.

### `sync` *(required, list)*

Rsync list applied on every deploy. Each entry is either `src` or `src -> dst`
(relative to project root on dev; `/apps/<name>/` on VPS). Trailing `/` means
"recurse". Hosting always syncs the manifest itself and the minimal helper
scripts (`setup-env.sh`, `remote-deploy.sh`) — you don't list those.

The Traefik dynamic config (`traefik-dynamic.yml` at project root) is
**not** listed here. Hosting rsyncs it directly to
`/apps/traefik/dynamic/<name>.yml` out-of-band, the same way it handles
its own helper scripts. See `traefik.md` for the fragment shape.

### `health` *(optional)*

Which container to block on during deploy before running `post-deploy` hooks.
Defaults to waiting on all services with a compose healthcheck.

### `hooks` *(optional)*

Each hook is a list of strings. Each string starts with a literal
**container name**, followed by the command to run inside it via
`docker exec -T`. The target service in `compose.prod.yml` must set an
explicit `container_name:` — compose's auto-generated
`<project>_<service>_1` won't match. `hosting check` (HK01) enforces this.

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

Environment variables available to hook commands (set by hosting):
- `$VERSION` — the version being deployed/rolled to.
- `$PREV_VERSION` — the version previously current (may be empty on first deploy).
- `$DEPLOY_BACKUP` — (post-deploy) path to the backup file, or `no-backup`.

Hosting does **not** generalize migration accounting. Projects that need to
count migrations (Laravel, Rails, Django, etc.) do that inside their hook
by querying their framework's migration table.

### `backup` *(optional)*

If present, hosting may take a backup after `compose up -d` + health wait,
before pre-deploy hooks run.

- `check` — any command. Exit code 0 triggers the backup; non-zero skips
  it. Projects decide their own trigger: pending migrations, a sentinel
  file, config change detection, or simply `true` to back up every deploy.
- `command` — command that writes the backup to stdout.
- `pipe` — optional stdout pipe (e.g. `gzip`).
- `extension` — filename extension (resulting file:
  `backups/pre-deploy-<timestamp>.<extension>`).
- `retain` — number of backups to keep (oldest are deleted on success).

### `mail` *(optional)*

Declares the project uses the VPS mail stack.
- `domain` — must be handled by the mail stack (checked at deploy time).
- `snappymail_domain` — optional JSON file to seed SnappyMail's domain
  config (matching the pattern already in use for the original project).

No `accounts` field — mailboxes are created/removed out-of-band with:

```
ssh you@vps 'docker exec mail-dms setup email add noreply@example.com'
```

This keeps accounts decoupled from the deploy cycle.

## State file (`.hosting/state.json`, not manifest)

Stored in the project root. Not committed (add to `.gitignore`). Not synced
to the VPS. Tracks:

```json
{
  "hosting_version": "0.1.0",
  "last_server": "user@vps",
  "last_deploy": "2026-04-12T01:00:00Z",
  "last_version": "1.3.0",
  "schema_migrations_applied": []
}
```

### Fields

| Field | Written by | Read by |
|---|---|---|
| `hosting_version` | `init-project`, `check --fix`, any migration | future `hosting migrate` (bash→Go cutover) |
| `last_server` | every project command that targets a server, on success | every project command — used as default when `USER@HOST` is omitted |
| `last_deploy` | `deploy`, `rollback` on success | `hosting check` (diff deployed vs local) |
| `last_version` | `deploy`, `rollback` on success | `hosting check` |
| `schema_migrations_applied` | `hosting migrate` | `hosting migrate` (idempotency) |

`hosting pending` does **not** read `last_version`. It resolves the deployed
version by querying `versions.log` on the VPS at runtime. State is a cache
for defaults, not a source of truth for what's actually running.

### Write rules

- Written **only on success**. Failed commands leave state untouched.
- `last_server` is updated by: `build-push`, `deploy`, `rollback`, `env`,
  `history`, `changelog`, `pending`, `logs`, `exec`, `check --server` *(v0.2)*.
- `init-project` creates the file with empty fields and the current
  `hosting_version`. First server-targeting command must be passed
  `USER@HOST` explicitly; subsequent ones default to `last_server`.

### Purpose

- Default `USER@HOST` so users don't repeat it every command in the same project.
- Anchor the source-tree schema migration story for the bash→Go transition.
- Let `hosting check` diff the deployed version against local HEAD.
