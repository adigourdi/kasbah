# CLI Reference

Two levels of commands:

- **`hosting server …`** — act on a VPS. Always take `user@host` as first arg.
- **`hosting …`** (everything else) — act on a project. Run from the project
  root. Read `./hosting.yml`. Error if missing.

```
$ cd ~/some/random/path
$ hosting deploy you@vps
ERROR: No hosting.yml in current directory.
       Run from the project root, or `hosting init-project` to scaffold.
```

## Server commands

### `hosting server init USER@HOST [flags]`

One-time VPS setup. Idempotent — safe to re-run.

Flags:
- `--domain=<apex>` — domain for the Traefik dashboard and acme email config.
- `--email=<addr>` — ACME email for Let's Encrypt registration.
- `--with-mail` — also scaffold `/apps/mail/` (DMS + SnappyMail).
- `--apps-path=/apps` — root directory on the VPS (default `/apps`).
- `--data-path=/apps/data` — bind-mount root (default `/apps/data`).
- `--traefik-auth=user:pass` — basic auth for the dashboard. Password is
  hashed with bcrypt locally; the hash is what lands in `.env`.

What it does:
1. Verify Docker ≥ 24 and Docker Compose v2 exist. **Does not install.** Fails
   with a clear message otherwise.
2. `mkdir -p /apps /apps/data /apps/backups`.
3. `mkdir -p /apps/data/traefik/letsencrypt && touch /apps/data/traefik/letsencrypt/acme.json && chmod 600 ...`
   (touch-as-file is mandatory — Docker silently creates a directory otherwise).
4. Scaffold `/apps/traefik/` (compose.yml, traefik.yml, dynamic.yml, .env).
5. Run `hosting env` interactively against `/apps/traefik/.env.prod.example`.
6. `docker compose up -d` in `/apps/traefik/`.
7. Health-check Traefik, print dashboard URL.
8. If `--with-mail`: scaffold `/apps/mail/`, run its env setup, start it.

### `hosting server status USER@HOST`

Prints:
- Docker + Compose versions
- Traefik status + last cert refresh
- List of projects under `/apps/` (name, running state, domain, last deploy)
- Disk usage on `/apps` and `/apps/data`
- Mail stack status if deployed

## Project commands

All run from the project root (where `hosting.yml` lives).

`USER@HOST` is optional on any command that takes it. If omitted, hosting
reads `last_server` from `.hosting/state.json` and uses that. After any
command succeeds against a given server, `last_server` is written so the
next invocation in the same project defaults to it. `hosting init-project`
writes an empty state file; the first command that needs a server must
pass `USER@HOST` explicitly.

### `hosting init-project [flags]`

Scaffold the hosting metadata for a new project. Creates:
- `hosting.yml` with schema version and sane defaults
- `.env.prod.example` skeleton
- `.hosting/state.json` (empty fields, current `hosting_version`)
- `.gitignore` entries for `.env` and `.hosting/`

Does **not** scaffold `compose.prod.yml`. The user authors that file — hosting
has no opinion on which service is "primary", what ports to expose, etc. After
running, hosting prints a minimal starter compose snippet to stdout so the
user can paste and adapt if useful.

Flags:
- `--name=<name>` (default: current directory name)
- `--domain=<fqdn>`

### `hosting check [--fix]`

Run the compliance check on the current project. See `compliance.md` for
the full rule set. Exit code 0 on pass, 6 on any failure (see "Exit codes" below).

`--fix` applies safe auto-fixes (add missing restart policy, add missing
logging rotation, add missing `traefik.enable=true`).

### `hosting build-push [USER@HOST]`

1. Resolve version from git tag on HEAD (exactly one `vX.Y.Z`). Fail otherwise.
2. Parse `compose.prod.yml` for services with a `build:` key. If zero, exit 0
   (stock-only project — nothing to ship; `compose up -d` will pull stock images at deploy time).
3. `docker compose -f compose.prod.yml build`.
4. Tag each built image: `<image>:<version>`.
5. `docker save ... | gzip > /tmp/<name>-<version>.tar.gz`.
6. `scp` to VPS, `docker load` there.
7. Clean up tarball on both ends.
8. `git push origin v<version>` if the tag isn't yet on origin.

`build-push` does **not** set `:current` and does **not** run `compose up`.
Moving `:current` is `deploy`'s responsibility. `:latest` is never set.

Flags:
- `--build-only` — skip scp/load/push (local build + tag only).
- `--no-git-push` — don't push the git tag.

### `hosting deploy [USER@HOST] [VERSION] [flags]`

Two modes:

- **No `VERSION` arg** — deploys the **working tree**, labeled with HEAD's
  `v-tag`. Fails fast if HEAD isn't tagged. This is the everyday path: you
  may have tweaked compose or env template since cutting the tag, and you
  want to ship current disk state under that version label.
- **Explicit `VERSION`** — deploys that tagged version exactly as it was,
  via `git archive v<VERSION>` (no checkout, working tree untouched). See
  the rollback flow in `build-deploy.md` — deploy of an explicit version
  uses the same code path, only the log entry (`action=deploy`) and hook
  pair (`pre-/post-deploy`) differ.

Flow (no-args / working-tree path):
1. Open SSH ControlMaster for the whole deploy (reuse across rsync/scp/ssh).
2. Verify SSH reachability.
3. Resolve version = HEAD's `v-tag` (fail if not tagged).
4. Ensure remote dirs exist (`/apps/<name>/`, `scripts/`, `backups/`, `/apps/data/<name>/`).
5. Rsync manifest's `sync:` list + helper scripts (`setup-env.sh`, `remote-deploy.sh`).
6. Env drift check on VPS — run setup-env if missing, prompt on drift.
7. Mail claim check (if manifest has `mail:`).
8. SSH into VPS, run `remote-deploy.sh deploy <version>`:
   - If `backup:` configured and its `check` exits 0 → run backup (against
     previous version's still-running containers), rotate.
   - Run `pre-deploy` hooks against previous version's containers.
   - Retag `:<version>` as `:current` for every built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for `health.container` to be healthy.
   - Run `post-deploy` hooks against new containers.
   - Append to `versions.log`, rotate.
9. Print local changelog (`git log <prev>..<new>`).

Flags:
- `--skip-hooks` — skip pre/post hooks (dry-run style).
- `--no-health-wait` — don't block on healthcheck.

### `hosting rollback [USER@HOST] [VERSION]`

Default target: second-most-recent entry in `versions.log` with `action=deploy`.

Flow (see `build-deploy.md` for full detail):
1. Resolve target version.
2. Verify target appears in `versions.log` (or `versions.log.gz`). If not —
   fail; it was never deployed here, so it's a first-time deploy, not a rollback.
3. Verify git tag `v<target>` exists locally (`git fetch --tags` if not).
4. Read v<target>'s files via `git show v<target>:hosting.yml` and
   `git show v<target>:compose.prod.yml` — no checkout.
5. For each `build:` service in v<target>'s compose: check `:<target>`
   image on VPS → else on local (auto-push if found) → else fail with
   instructions to rebuild from the tag.
6. `git archive v<target> <v<target>'s sync list> | ssh vps tar -x -C /apps/<name>/`.
7. On VPS: run `remote-deploy.sh rollback <target>`:
   - Run `pre-rollback` hooks against currently-running containers.
   - Retag `:<target>` as `:current` for each built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for health.
   - Run `post-rollback` hooks against rolled-back containers.
   - Append rollback entry to `versions.log`, rotate.

Rollback restores image + sync'd config only. It does **not** restore
data bind mounts or `.env` secret values. For schema rollback, use
`pre-rollback` hooks.

### `hosting history [USER@HOST] [flags]`

Tabular view of `versions.log`. Columns: timestamp, action, version,
backup file, hosting version.

Flags:
- `--all` — include the archived rotation (`versions.log.gz`). By default
  only the active log is shown.

### `hosting pending [USER@HOST] [VERSION]`

`git log <deployed>..<VERSION-or-HEAD>` formatted as a changelog. Useful
before cutting a tag.

### `hosting changelog [USER@HOST]`

`git log <prev-deploy>..<current-deploy>` — what changed in the currently
deployed version.

### `hosting env [USER@HOST]`

Drift-aware env setup. Rsyncs `.env.prod.example` to VPS, runs the interactive
`setup-env.sh` against it. See `env-template.md` for the template conventions.

### `hosting logs [USER@HOST] [SERVICE] [flags]`

Thin wrapper around `docker compose logs` on the VPS. If `SERVICE` is
omitted, shows all services in the project.

Flags:
- `-f` — follow.
- `--tail=100` — lines of history (default 100).

### `hosting exec [USER@HOST] SERVICE -- CMD…`

`docker compose exec SERVICE CMD…` over SSH. The `--` is mandatory so flags
after it belong to the inner command. `SERVICE` is required; if it looks
like `user@host` (contains `@`) hosting treats it as the server.

## Deferred commands

Referenced elsewhere in the docs but not yet in v0.1:

- `hosting migrate` — migrate a project's source-tree files to a newer
  hosting schema. (Phase 4 — see `roadmap.md`.)
- `hosting destroy` — remove a project from the VPS with double
  confirmation. (Phase 3 — see `roadmap.md`.)
- `hosting server add-mail-domain` — add a new domain to the shared mail
  stack. (Phase 2 — see `roadmap.md`.)
- `hosting server upgrade-traefik` — managed Traefik version bump.
  (Phase 3 — see `roadmap.md`.)
- `hosting check --server` — VPS-aware compliance check. (Phase 2 — see
  `compliance.md`.)

## Exit codes

- `0` success
- `1` generic failure
- `2` not a hosting project (no `hosting.yml`)
- `3` SSH unreachable
- `4` remote state missing (need `hosting server init` first)
- `5` .env drift detected and user declined to fix
- `6` compliance check failed
