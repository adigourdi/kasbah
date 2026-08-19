# CLI Reference

Two levels of commands:

- **`kasbah server …`** — act on a VPS. Always take `user@host` as first arg.
- **`kasbah …`** (everything else) — act on a project. Run from the project
  root. Read `./kasbah.yml`. Error if missing.

```
$ cd ~/some/random/path
$ kasbah deploy you@vps
ERROR: No kasbah.yml in current directory.
       Run from the project root, or `kasbah init-project` to scaffold.
```

## Server commands

### `kasbah server init USER@HOST [flags]`

One-time VPS setup. Idempotent — safe to re-run.

Optional features are tri-state (see the interactivity decision in
`overview.md`): leaving `--with-mail`/`--no-mail` unset means init *asks* —
it never treats absence as "no". Without a TTY, an unanswered choice is a
hard fail naming the flag to pass.

Flags:
- `--domain=<apex>` — domain for the Traefik dashboard and acme email config.
- `--email=<addr>` — ACME email for Let's Encrypt registration.
- `--with-mail` / `--no-mail` — scaffold `/apps/mail/` (DMS + SnappyMail),
  or explicitly skip it. Unset → prompt. **The mail stack itself arrives in
  roadmap v0.2**, so `--with-mail`, and answering yes at the prompt, both
  hard-fail today rather than silently doing nothing. `--no-mail` works.
- `--with-backup` / `--no-backup` — install restic + append-only S3
  credentials + daily backup cron (see `backup.md`), or explicitly skip.
  Unset → prompt. **Backup arrives in roadmap v0.3**; as with mail, asking
  for it today is a hard failure rather than a silent no-op.
- `--apps-path=/apps` — root directory on the VPS (default `/apps`).
- `--data-path=<dir>` — bind-mount root (default `<apps-path>/data`, so it
  follows `--apps-path` rather than being pinned to `/apps/data`).
- `--traefik-auth=user:pass` — basic auth for the dashboard. The password is
  hashed with bcrypt on the workstation (`htpasswd -niB`, or the same via a
  throwaway `httpd:2-alpine` container when htpasswd is absent); the hash
  lands in `dynamic/_shared.yml`. Unset on a re-run means the stored hash is
  reused — bcrypt salts randomly, so re-hashing would break idempotency.

What it does:
1. Verify Docker ≥ 24 and Docker Compose v2 exist. **Does not install.** Fails
   with a clear message otherwise.
2. Create the apps path — `sudo mkdir -p` the *parent*, a bare `sudo mkdir`
   on the final component (so an existing directory is an error rather than
   a silent adoption), then `chown` to the SSH user — and only when the path
   does not already exist; everything below it is
   created unelevated. See `server-setup.md` ("Who creates the apps path").
   Then `mkdir -p /apps/data /apps/backups`.
3. `mkdir -p <data>/traefik/letsencrypt && touch <data>/traefik/letsencrypt/acme.json && chmod 600 ...`
   (touch-as-file is mandatory — Docker silently creates a directory otherwise).
4. Scaffold `/apps/traefik/` — compose.yml, traefik.yml, and dynamic/ with
   `_shared.yml`. No `.env`: Traefik interpolates no environment variables,
   so `--domain`, `--email` and the `--traefik-auth` hash are baked into the
   rendered files (see `server-setup.md`).
5. `docker compose -p traefik up -d` in `/apps/traefik/`, restarting only
   when the static config changed and the container was not just recreated.
6. Health-check Traefik, print dashboard URL.
7. If `--with-mail`: scaffold `/apps/mail/`, write the cert-trigger +
   webmail router fragment to `/apps/traefik/dynamic/_mail.yml`, run its
   env setup, start it.
8. If `--with-backup`: install restic, write append-only S3 credentials,
   schedule the backup cron (see `backup.md`).
9. Write the server marker `<apps>/.kasbah/server.json` — kasbah version,
   paths, resource limits computed as 90% of host cores/RAM (see
   `server-setup.md`). **Last of the steps that signal completion**: its
   presence is the "init completed" signal, so a failure at any earlier step
   leaves no marker behind.
10. Write the discovery pointer `/etc/kasbah/apps-path` (`root:root 644`, in a
    `755` directory, one absolute path) so every project command can find this server without
    being told where it is. Immediately after the marker, never before — a
    run that dies early must leave neither. See `server-setup.md` → the
    discovery pointer, including what happens when sudo is unavailable.

Re-running init against a server whose pointer records a **different** apps
path is refused: one machine runs one kasbah, because one Traefik holds `:80`
and `:443`.

### `kasbah server prune USER@HOST` *(roadmap v0.2)*

Image retention cleanup across all projects on the VPS: removes
`:<version>` image tags that are both older than 3 months and not among
the project's last 3 deployed versions — the version `:current` points
at counts as the first of the 3, and `:current` itself is never pruned.
The time window mirrors versions.log rotation — see `build-deploy.md`.
Prints what it would remove and asks once.

### `kasbah server destroy USER@HOST` *(roadmap v0.3)*

De-brand the VPS for handover. Every container keeps running — projects
**and** Traefik, the sites stay up. Removes kasbah's management layer only:

- `/apps/.kasbah/` server marker
- backup cron + S3 credentials (agency-owned secrets never transfer)
- per project: `versions.log(.gz)`, `scripts/` helpers, `.deploy.lock` (not
  `kasbah.yml` — the manifest is never synced to a server)

The new owner inherits a plain, working Docker Compose setup; deploy
history and env tooling leave with kasbah. Double confirmation (typed
hostname). See `server-setup.md` ("Handover / teardown").

### `kasbah server status USER@HOST [--apps-path=<dir>]`

Read-only — it never creates, modifies or removes anything on the server.

Prints today:
- Docker + Compose versions
- The server marker: kasbah version, paths, resource limits
- Traefik: running state, health, the image tag it was created from **and**
  the resolved image id (a tag can be re-pushed; the id cannot)
- Projects under the apps path — name, running/total containers, and the
  last `versions.log` entry (action, version, timestamp, kasbah version)

`--apps-path` is the escape hatch for a server whose discovery pointer is
missing, unreadable, or in a directory nobody can enter — and it is honoured in
every one of those states, since refusing to read a path the caller named
outright would leave no way in at all. Without it, `status` resolves the apps
path the same way every other command does — `/etc/kasbah/apps-path`, else
`/apps` — and
prints which of the three it used. No other command takes the flag: a value
repeated on every invocation is a belief each caller holds separately, and the
apps path is a property of the server (see `server-setup.md` → the discovery
pointer).

Deferred to roadmap v0.2 (`docs/phases/07-operate.md`):
- Cert status and last refresh
- Disk usage on the apps and data paths
- Mail stack status
- Per-container health beyond Traefik's

**The project's domain is not printed and is not merely deferred.** It lives
in `<apps>/traefik/dynamic/<name>.yml`, so printing it means parsing every
fragment on a server where yq is not a prerequisite, or querying the Traefik
API with the dashboard credentials. Both are real work with a real
dependency; whichever a later phase picks, it is a decision rather than an
omission.

## Project commands

All run from the project root (where `kasbah.yml` lives).

`USER@HOST` is optional on any command that takes it. If omitted, kasbah
reads `last_server` from `.kasbah/state.json` and uses that. After any
command succeeds against a given server, `last_server` is written so the
next invocation in the same project defaults to it. `kasbah init-project`
writes an empty state file; the first command that needs a server must
pass `USER@HOST` explicitly.

### `kasbah init-project [flags]`

Scaffold the kasbah metadata for a new project. Creates:
- `kasbah.yml` with schema version and sane defaults
- `.env.prod.example` skeleton
- `.kasbah/state.json` (empty fields, current `kasbah_version`)
- `.gitignore` entries for `.env` and `.kasbah/`

Does **not** scaffold `compose.prod.yml`. The user authors that file — kasbah
has no opinion on which service is "primary", what ports to expose, etc. After
running, kasbah prints a minimal starter compose snippet to stdout so the
user can paste and adapt if useful.

Flags:
- `--name=<name>` (default: current directory name)
- `--domain=<fqdn>`

### `kasbah check [--fix]`

Run the compliance check on the current project. See `compliance.md` for
the full rule set. Exit code 0 on pass, 6 on any failure (see "Exit codes" below).

`--fix` *(not implemented — `check` refuses the flag today)* would apply
safe auto-fixes (add missing restart policy, add missing logging rotation).
Traefik rules are never auto-fixed — routing is policy.

### `kasbah build-push [USER@HOST]`

1. Resolve version from git tag on HEAD (exactly one `vX.Y.Z`). Fail otherwise.
2. Parse `compose.prod.yml` for services with a `build:` key. If zero, exit 0
   (stock-only project — nothing to ship; `compose up -d` will pull stock images at deploy time).
3. `docker compose -p <name> -f compose.prod.yml build`, under
   `KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0` — a compliant compose file cannot
   interpolate without them and a build has no server to read them from
   (`build-deploy.md`).
4. Tag each built image: `<image>:<version>`.
5. `docker save ... | gzip > ${TMPDIR:-/tmp}/<name>-<version>.tar.gz`.
6. `rsync` to VPS `/tmp`, `docker load` there.
7. Clean up tarball on both ends — by a trap, so a failed transfer leaks nothing.
8. `git push origin v<version>` if the tag isn't yet on origin. A repository
   with no `origin` remote at all warns and exits 0: the image has already
   shipped by then, and a local-only project is a real shape.

`build-push` does **not** set `:current` and does **not** run `compose up`.
Moving `:current` is `deploy`'s responsibility. `:latest` is never set. It does
run `compose build` — that is the one compose verb it uses.

`USER@HOST` follows the same rule as every other project command: the argument,
else `last_server` from `.kasbah/state.json`, which is written on success.
`--build-only` needs neither, since it never reaches a server.

Flags:
- `--build-only` — skip transfer/load/push (local build + tag only).
- `--no-git-push` — don't push the git tag.

### `kasbah deploy [USER@HOST] [VERSION] [flags]`

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
   The Traefik fragment is not shipped here — it goes last, after the stack is
   up, so a failed deploy cannot leave a live route to nothing (`build-deploy.md`).
6. Env drift check on VPS — run setup-env if missing, prompt on drift.
   Then refresh the kasbah-managed `KASBAH_*` keys in `.env` (resource
   limits from the server marker) — reserved prefix, exempt from drift.
7. Mail claim check (if manifest has `mail:`).
8. SSH into VPS, run `remote-deploy.sh deploy <version>`:
   - If `backup:` configured and its `check` exits 0 → run backup (against
     previous version's still-running containers), rotate.
   - Run `pre-deploy` hooks against previous version's containers.
   - Retag `:<version>` as `:current` for every built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for `health.container` to be healthy.
   - Run `post-deploy` hooks against new containers.
   - Append to `versions.log`. (Rotation lands with `history`, Phase 5.)
9. Rsync `traefik-dynamic.yml` to `/apps/traefik/dynamic/<name>.yml` — locally
   driven, after the stack is up, so a failed deploy leaves no live route.
10. Print local changelog (`git log <prev>..<new>`).

Flags:
- `--on-drift=setup|continue|abort` — what step 6 does when the server's `.env`
  has drifted from `.env.prod.example`. Unset it asks; with no terminal to ask
  on the run stops with exit `5`. See `kasbah env` below.
- `--skip-hooks` — skip the pre/post hooks (dry-run style). **The backup still
  runs**: a flag for a dry-run-ish deploy must not also discard the data safety
  net.
- `--no-health-wait` — don't block on healthcheck.
- `--allow-stopped` — deploy over a stack that has deployed here before but is
  not running. Without it that is a refusal, because the backup and the
  `pre-deploy` hooks act on the outgoing containers and skipping them silently
  is how a backup goes missing exactly when it was worth having. See
  `build-deploy.md` § the outgoing stack.

### `kasbah rollback [USER@HOST] [VERSION]`

Default target: second-most-recent entry in `versions.log` with `action=deploy`.

Flow (see `build-deploy.md` for full detail):
1. Resolve target version.
2. Verify target appears in `versions.log` (or `versions.log.gz`). If not —
   fail; it was never deployed here, so it's a first-time deploy, not a rollback.
3. Verify git tag `v<target>` exists locally (`git fetch --tags` if not).
4. Read v<target>'s files via `git show v<target>:kasbah.yml` and
   `git show v<target>:compose.prod.yml` — no checkout.
5. For each `build:` service in v<target>'s compose: `:<target>` must
   still be on the VPS (see image retention in `build-deploy.md`) — if
   pruned, fail with roll-forward / rebuild-from-tag guidance.
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

### `kasbah drop [USER@HOST] [--prune]` *(roadmap v0.3)*

Remove the project from the VPS. Plain `drop` is reversible:

Removes:
- containers (`docker compose down`)
- the Traefik fragment (`/apps/traefik/dynamic/<name>.yml`)
- the project's loaded images (every `:<version>` tag + `:current`)

Keeps:
- `/apps/<name>/` (compose, `.env`, manifest, versions.log, scripts)
- `/apps/data/<name>/` (bind mounts)
- backups (on-VPS and off-VPS)

A later `kasbah deploy` fully resurrects the project (images must be
re-shipped via `build-push` first).

`--prune` additionally deletes `/apps/<name>/`, `/apps/data/<name>/`, and
the project's on-VPS backups — everything except the off-VPS restic repo,
which is operator property (see `backup.md`). Double confirmation (typed
project name).

### `kasbah history [USER@HOST] [flags]`

Tabular view of `versions.log`. Columns: timestamp, action, version,
backup file, kasbah version.

Flags:
- `--all` — include the archived rotation (`versions.log.gz`). By default
  only the active log is shown.

### `kasbah pending [USER@HOST] [VERSION]`

`git log <deployed>..<VERSION-or-HEAD>` formatted as a changelog. Useful
before cutting a tag.

### `kasbah changelog [USER@HOST]`

`git log <prev-deploy>..<current-deploy>` — what changed in the currently
deployed version.

### `kasbah env [USER@HOST] [--on-drift=setup|continue|abort]`

Drift-aware env setup. Rsyncs `.env.prod.example` and kasbah's own
`setup-env.sh` to `<apps>/<name>/`, runs the interactive setup there over
`ssh -t`, then refreshes the kasbah-managed `KASBAH_*` block in `.env` from
the server marker's resource limits. See `env-template.md` for the template
conventions and the managed block.

The injection is not optional decoration: a `.env` without `KASBAH_CPU_LIMIT`
makes `compose up` fail outright, so a command whose job is producing a usable
`.env` finishes the job. That is also why it reads the server marker and exits
`4` when there is none, exactly as `deploy` does.

The setup is interactive and needs a terminal at both ends. Without one the run
stops with exit `5` rather than feeding the generator EOF, which its
non-interactive contract would turn into every default silently accepted,
secrets included.

Flags, which apply only when `.env` **has** drifted:
- `--on-drift=setup` — re-run the setup. What this command does anyway.
- `--on-drift=continue` — leave `.env` alone and only refresh the `KASBAH_*`
  block. The only answer that gets through without a terminal.
- `--on-drift=abort` — stop, changing nothing (exit `5`).

Unset, a drifting `.env` asks; with no terminal to ask on, the run stops naming
the flag. The prompt has **no default** — an empty answer is asked again, since
Enter must not be able to re-run the generator over a live `.env`.

`--on-drift=` is not a way to run `kasbah env` headlessly in general. With
`.env` missing, or in sync, the flag is never consulted and the run still needs
a terminal (exit `5`); only the drift case has a question for it to answer.

`deploy` carries the same flag for the same step (`build-deploy.md` step 6) —
the difference is that `deploy` runs the setup only when the `.env` is missing
or has drifted, while `env` runs it every time, since that is what it is for.

### `kasbah logs [USER@HOST] [SERVICE] [flags]`

Thin wrapper around `docker compose logs` on the VPS. If `SERVICE` is
omitted, shows all services in the project.

Flags:
- `-f` — follow.
- `--tail=100` — lines of history (default 100).

### `kasbah exec [USER@HOST] SERVICE -- CMD…`

`docker compose exec SERVICE CMD…` over SSH. The `--` is mandatory so flags
after it belong to the inner command. `SERVICE` is required; if it looks
like `user@host` (contains `@`) kasbah treats it as the server.

## Deferred commands

Referenced elsewhere in the docs but not yet in v0.1:

- `kasbah migrate` — migrate a project's source-tree files to a newer
  kasbah schema. (roadmap v1.0.)
- `kasbah server add-mail-domain` — add a new domain to the shared mail
  stack. (roadmap v0.2.)
- `kasbah server upgrade-traefik` — managed Traefik version bump.
  (roadmap v0.3.)
- `kasbah check --server` — VPS-aware compliance check. (roadmap v0.2 — see
  `compliance.md`.)

## Exit codes

- `0` success
- `1` generic failure
- `2` not a kasbah project (no `kasbah.yml`)
- `3` SSH unreachable
- `4` remote state missing — no server marker where the apps path says it
  should be. Two situations now, and neither is "a server prepared with
  `--apps-path` cannot be found" — the discovery pointer
  (`/etc/kasbah/apps-path`) closed that one:
  - the server was never prepared, and `kasbah server init` is the answer;
  - it was prepared and the pointer is gone, so kasbah is looking under
    `/apps` at a server that lives elsewhere. **Re-running init is the wrong
    move here** — pointed at the default it would render a second Traefik
    stack under the frozen `traefik` compose project and recreate the running
    proxy against it, taking every site down. Find the real apps path
    (`kasbah server status <host> --apps-path=<dir>`) and restore the pointer.

  Commands that exit 4 say which situation they are in rather than
  prescribing init.
- `5` env setup could not complete. Covers both halves of the same sentence —
  the project's `.env` on the server is not in a state kasbah will deploy
  against, and nothing was deployed: drift the user declined to fix
  (`--on-drift=abort`, or an aborted setup), a `.env` that is missing or
  unrenderable with no terminal to render it on, **and** `setup-env.sh` not
  finishing on the far side — including when it could not be run at all. One
  code rather than several, because the operator's next move is the same in
  every case: run `kasbah env` from a terminal, or pass `--on-drift=`.
- `6` compliance check failed
