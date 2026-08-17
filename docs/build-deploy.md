# Build, Deploy, Rollback

The core lifecycle loop. Grew out of one project's `scripts/{build-push,deploy,remote-deploy}.sh`
and generalized so every project gets the same flow.

## Versioning contract

Versions come from git tags on the project repo, formatted `vX.Y.Z` (semver).

- `build-push` requires HEAD to have exactly one `v<semver>` tag.
- `kasbah deploy` (no args) labels the **working tree** with HEAD's tag
  and rsyncs it as-is. Lets you iterate on compose / env template between
  tagged releases without forcing a commit for every tweak.
- `kasbah deploy X.Y.Z` and `kasbah rollback X.Y.Z` target a specific
  tagged version. Files come from `git archive v<X.Y.Z>` — no checkout,
  working tree untouched.
- `rollback` additionally requires the target to appear in `versions.log`
  with `action=deploy`; if not, it refuses (it would be a first-time deploy).

Why tags? No registry means no metadata store outside of git plus image
tags on the VPS. Semver tags are both human-meaningful and machine-sortable.

## Image tags on the VPS

- `:<version>` — permanent. Written by `build-push`, one per shipped version.
  Multiple live on the VPS at any time — enough to roll back to.
- `:current` — the tag that every built service in `compose.prod.yml`
  references. Moved on every `deploy` / `rollback`. Never moved by
  `build-push`.

Compose files on the VPS always reference `:current` for built images.
Deploy and rollback never rewrite compose — they just retag `:current`
and `compose up -d`.

**No `:latest` tag is used.** Git is the source of truth for what's newest.
Removing `:latest` eliminates the "emergency patch of an older release
silently clobbers `:latest`" class of bug and collapses the tag model to
two tags per image.

### Retention

`:<version>` tags are pruned routinely: `kasbah server prune` (roadmap v0.2)
removes version tags that are **both** older than 3 months **and** not
among the project's last 3 deployed versions — where the version
`:current` points at counts as the first of the 3. `:current` itself is
never pruned. The time window mirrors the versions.log rotation cutoff;
the count floor guarantees rollback targets exist (current plus two
older) even on rarely-deployed projects.

The retention window **is** the rollback window. Anything older is a
roll-forward (ship a fix), not a rollback. Kasbah does not promise to
resurrect pruned images from a dev machine: a rebuild from the tag is not
byte-identical to what originally shipped, and in a multi-operator setup
which laptop holds the original is unknowable.

## `kasbah build-push`

### Project shape is derived from compose

`build-push` walks `compose.prod.yml` and collects every service with a
`build:` key. Those are the images to ship.

- Any such services → build, tag, save, ship, load.
- Zero such services → exit 0 (stock-only project; stock images get
  pulled by `compose up -d` at deploy time).

There is no `type` field in the manifest. The project shape is derived
from compose itself.

### Flow

```
1. Resolve version from git tag on HEAD (exactly one v<semver>). Fail otherwise.
2. Parse compose.prod.yml for services with `build:`.
   - Zero → exit 0.
3. docker compose -f compose.prod.yml build
4. Tag each built image:
     <image>:<version>
5. docker save <all built images> | gzip > /tmp/<name>-<version>.tar.gz
6. scp tarball to VPS:/tmp
7. ssh VPS:
     docker load < tarball
     rm tarball
8. rm local tarball
9. git push origin v<version>   # if tag not on origin yet
```

`build-push` does **not** touch `:current` and does **not** run `compose up`.
That's `deploy`'s job — decoupling lets you build-push without deploying
(e.g. to stage an image ahead of time).

## `kasbah deploy`

### Two modes

1. **No version arg** — deploy the working tree, using HEAD's `v-tag` as
   the version label. Everyday path. Fails fast if HEAD isn't tagged.
2. **Explicit `X.Y.Z`** — deploy that tagged version *exactly* as it was.
   Files come from `git archive v<X.Y.Z>`, not the working tree. Reproducible.

The explicit-version path is structurally identical to `rollback` (see
below). The only differences:
- Log entry is `action=deploy` (not `rollback`).
- Hook pair is `pre-deploy` / `post-deploy` (not `pre-rollback` / `post-rollback`).
- No "must be in versions.log" precondition — you're allowed to deploy
  a version for the first time.

### Flow (no-args path — working tree)

```
1. Open SSH ControlMaster (see "SSH multiplexing" below).
2. Check SSH reachability (fail fast).
3. Resolve version = HEAD's v-tag. Fail if HEAD isn't tagged.
4. Ensure remote dirs exist:
     /apps/<name>/, scripts/, backups/, /apps/data/<name>/
5. Rsync from working tree:
     - every path in manifest's `sync:` list → /apps/<name>/
     - setup-env.sh and remote-deploy.sh (kasbah-owned helpers, overwritten
       on every deploy to match installed kasbah version) → /apps/<name>/scripts/
   The Traefik fragment is deliberately **not** shipped here — see step 8h.
6. Env drift check (via setup-env.sh on VPS):
     MISSING .env         → run interactive setup
     DRIFT from template  → prompt: re-run setup / continue / abort
     OK                   → continue
   Then refresh the kasbah-managed `KASBAH_*` keys in `.env` (resource
   limits read from the server marker). The `KASBAH_` prefix is reserved
   and exempt from drift detection.
7. Mail claim (if manifest has `mail:`):
     verify mail stack is up
     verify claimed domain is configured in /apps/mail/.env
     copy snappymail_domain pre-seed if file missing on VPS
8. SSH into VPS and run scripts/remote-deploy.sh deploy <version>:
     a. If manifest has `backup:` AND `backup.check` exits 0 → run backup
        against currently-running (previous version) containers. Rotate.
     b. Run pre-deploy hooks against currently-running containers.
     c. Retag :<version> as :current for each built image.
     d. docker compose up -d --remove-orphans.
     e. Wait for manifest's health.container to be healthy.
     f. Run post-deploy hooks against new containers.
     g. Append deploy entry to versions.log, rotate.
9. Rsync traefik-dynamic.yml → /apps/traefik/dynamic/<name>.yml. Done by the
   *local* side once remote-deploy.sh has returned 0 — the file is on the
   workstation, and the ordering is the point (see below).
10. Compute changelog (git log <prev-deploy>..<new>) and print it locally.
```

### Why the fragment ships last

Traefik registers a router the moment the file lands, whether or not
anything is behind it. Ship it before `compose up` and *every* way the
deploy can still fail — unpullable image, port conflict, a bad env value, a
compose file that will not parse — leaves a live route to a container that
never started. The host then serves **502 until some later deploy
succeeds**; on a first deploy it starts 502ing a hostname that was
previously an honest 404.

Shipping last trades that for a much smaller window: the container is up
but unrouted for as long as the fragment write takes to be noticed. A
single filesystem event on an idle Traefik is ~44 ms; a rsync temp-then-
rename is two events and opens the file provider's ~2 s throttle window.
Either is a rounding error against "broken until a human intervenes".

The same ordering is what makes a `container_name` change safe on a
redeploy: the new fragment never names a container that does not exist
yet.

### Why working-tree for no-args, git-archive for explicit versions

`kasbah deploy` with no args is the iterate-and-ship path: you've cut
a tag, tweaked compose or the env template since, and want to ship
what's on disk. Using `git archive` there would force every tweak to
be committed first, blocking the workflow.

`kasbah deploy X.Y.Z` means "deploy version X.Y.Z as it was tagged" —
reproducible, so it comes from `git archive`. The working tree is
irrelevant (and untouched).

## SSH multiplexing

`kasbah deploy` and `kasbah rollback` open an SSH ControlMaster before
any remote operation and reuse it for every subsequent `ssh` / `rsync` /
`scp` in the same run:

```bash
ctl="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-ssh.XXXXXX")"   # 0700, one per process
ssh -o ControlMaster=auto \
    -o ControlPath="$ctl/m1" \
    -o ControlPersist=60s \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    user@vps true
```

Turns ~5× TCP+TLS handshake overhead per deploy (reachability check,
mkdir, rsync, env check, mail claim, remote-deploy) into one.

Four details in that command are load-bearing:

- **The socket path must be unique per *process*, and no `%` token is.**
  Every expansion ssh offers — `%C`, `%h`, `%r`, `%p`, `%d` — is a
  function of the target and the invoking user. Two kasbah commands run
  against the same server therefore compute the same path and share one
  master, and `ssh -O exit` closes a master **together with every session
  multiplexed over it, including another process's**. Measured: a
  read-only `kasbah server status` finishing its run killed a concurrent
  `kasbah server init` mid-step, which then reported a Traefik that was
  in fact healthy and left the server with no marker. A `mktemp -d`
  directory cannot be computed by another process, and the counter inside
  it cannot repeat within this one — a name derived from the target
  repeats on a second `ssh_connect`, and a stale socket makes the next
  master silently fall back to no multiplexing at all.
- **The usable path budget is 90 bytes, not 108.** `sun_path` is 108, but
  the master binds `<path>.<16 random chars>` and renames it into place.
  Measured on OpenSSH 9.6p1: 90 connects, 91 fails with `unix_listener:
  path … too long for Unix domain socket`. `/tmp/kasbah-ssh.XXXXXX/m1`
  spends 26 of it; `~/.ssh/cm-` plus a 40-character `%C` spent 49 before
  the home directory was even counted.
- **`TMPDIR`, not `~/.ssh`.** The socket is worth exactly one run. It also
  keeps kasbah from creating anything in the user's `~/.ssh`, and
  sidesteps the fact that OpenSSH expands a leading `~` from the *passwd
  entry* rather than the environment — so `~/.ssh/cm-%C` ignores an
  overridden `HOME` and writes into the real home. (That same rule governs
  which per-user `ssh_config` is read, which is why the integration suite
  reaches the rig with `ssh -F` rather than by pointing `HOME` elsewhere.)
  A `TMPDIR` containing whitespace or a `%` is refused rather than
  escaped: rsync splits `-e` on spaces, and ssh reads `%` as a token.
- **`ConnectTimeout` bounds setup only** — including the banner exchange,
  but not an established session. A remote command that wedges after
  connecting is unbounded without `ServerAlive*`.

kasbah takes no ssh-options flag. It runs plain `ssh user@host` and
inherits the user's own `ssh_config`, the same way git does over SSH:
jump hosts, non-standard ports and key selection are already that file's
job. Everything remote goes through `lib/ssh.sh`; nothing else in the
codebase invokes `ssh`, `rsync` or `scp` directly.

## `versions.log` format

Append-only, space-delimited. Lives at `/apps/<name>/versions.log` on the VPS:

```
<iso-timestamp> <action> <version> <backup-path-or-"no-backup"> kasbah=<version> digest=<image@sha256,…|->
```

Example:

```
2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=shop-php@sha256:9f2a…
2026-04-15T14:30:00+00:00 deploy 1.3.0 backups/pre-deploy-20260415-143000.sql.gz kasbah=0.1.0 digest=shop-php@sha256:c81b…
2026-04-17T09:15:00+00:00 rollback 1.2.0 no-backup kasbah=0.1.0 digest=shop-php@sha256:9f2a…
```

Fields:
- `action` — `deploy` or `rollback`.
- `version` — the semver that ran.
- `backup` — relative path to backup file, or `no-backup`.
- `kasbah=...` — version of kasbah that wrote the entry.
- `digest=...` — content digest of each built image that went live
  (comma-joined), or `-` for stock-only projects. Provenance: answers
  "which image actually ran" even after a rebuild of the same tag.

The four positional fields are **frozen forever** — never reordered, never
removed. New data lands as `key=value` pairs appended at the end. Every
kasbah version within the same major must parse every line ever written
(see the compatibility policy in `overview.md`).

Kasbah does **not** track migration counts; that was a specific
framework's concern and now lives in project hooks.

### Rotation

Runs at the end of every successful write (`deploy`, `rollback`):

1. Compute cutoff: entries from months strictly older than
   `(current month - 3)` are moved out. E.g. writing in August prunes
   April-and-earlier entries.
2. Pruned entries are `gzip`-appended to `versions.log.gz`. Concatenated
   gzip streams are valid gzip — `zcat` reads all of them in order.
3. `versions.log` is rewritten with only the retained entries.
4. Nothing is ever deleted.

`kasbah history` transparently reads both files: `versions.log` first
(fast, usually enough), and `versions.log.gz` on demand (`--all`, or
when the requested version isn't in the active log).

### Why append-only

Fast to parse, cleanly survives single-deployer concurrent writes (the
only scenario kasbah targets), and rotation keeps the active file
small without sacrificing history.

## `kasbah rollback`

### Flow

```
1. Open SSH ControlMaster.
2. Resolve target version:
   - explicit: positional VERSION arg
   - implicit: second-latest entry in versions.log with action=deploy
3. Verify target appears in versions.log (or versions.log.gz).
     NOT present → fail:
       "Version X was never deployed to this VPS.
        Use `kasbah deploy <user@host> X` for a first-time deploy."
4. Verify git tag v<target> exists locally.
     missing → `git fetch --tags`, retry
     still missing → hard fail
5. Read v<target>'s files WITHOUT touching the working tree:
     git show v<target>:kasbah.yml       → used for the sync list
     git show v<target>:compose.prod.yml  → used for the image set
6. Image check — for each service with `build:` in v<target>'s compose,
   `:<target>` must be present on the VPS. Within the retention window
   (see "Retention") it always is. If pruned:
       "Image <image>:<target> is no longer on the VPS (outside the
        retention window). Prefer deploying a fix forward. To force a
        rollback anyway, rebuild from the tag (NOT byte-identical to the
        original — compare versions.log digests):
          git checkout v<target> && kasbah build-push <user@host>
        Then retry:
          kasbah rollback <user@host> <target>"
7. Parse v<target>'s manifest for its `sync:` list.
8. git archive v<target> <v<target>'s sync list> | ssh vps tar -x -C /apps/<name>/
   (Overwrites whatever HEAD sync produced at the last deploy.)
9. Restore v<target>'s Traefik config: git archive v<target>:traefik-dynamic.yml
   → /apps/traefik/dynamic/<name>.yml. Traefik reloads on its own.
10. SSH into VPS and run scripts/remote-deploy.sh rollback <target>:
     a. Run pre-rollback hooks against currently-running containers.
     b. Retag :<target> as :current for each v<target>-era built image.
     c. docker compose up -d --remove-orphans.
     d. Wait for health.container.
     e. Run post-rollback hooks against rolled-back containers.
     f. Append rollback entry to versions.log, rotate.
```

### Invariant

Every step that needs to know "what this version looks like" reads from
the `v<target>` git ref — manifest, compose, sync list, image set. Never
from HEAD. This matters most when v<target>'s compose has a different
set of built images than HEAD (service added / split / renamed) — the
image set must match what that version's compose expects, not what HEAD
expects.

### What rollback restores vs does NOT restore

Restores:
- Image (via retag of `:current`).
- Everything in v<target>'s `sync:` list: compose.prod.yml → compose.yml,
  .env.prod.example, init SQL, etc.
- v<target>'s `traefik-dynamic.yml` → /apps/traefik/dynamic/<name>.yml,
  rsynced out-of-band (same path as deploy).
- Kasbah helper scripts (`setup-env.sh`, `remote-deploy.sh`) — from the
  **current** kasbah install, not from git. Helpers belong to kasbah,
  not to the project's version history.

Does NOT restore:
- `.env` secret values. These aren't in git; only `.env.prod.example` is.
  If v<target>'s template has different keys, the standard drift detection
  fires and prompts the user.
- `data/` bind mounts (DB state, uploads, caches). For schema rollback,
  use `pre-rollback` hooks.
- Anything externally provisioned (DNS, API keys, mailbox contents).

## Helper scripts on the VPS

`kasbah deploy` and `kasbah rollback` sync two scripts per project:

- `setup-env.sh` — rich env template renderer (see `env-template.md`).
- `remote-deploy.sh` — orchestrates the VPS-side flow. Modes:
  - `deploy <version>`  — backup → pre-deploy → retag :current → up → health → post-deploy.
  - `rollback <version>` — pre-rollback → retag :current → up → health → post-rollback.

  Both modes hold an exclusive `flock` on the project directory for the
  whole run — a second concurrent deploy/rollback fails fast instead of
  interleaving hooks and retags (multi-operator safety).

These are the *only* kasbah-owned files that live on the VPS in a
project directory. They are overwritten on every deploy / rollback so
they match the kasbah version driving the operation.

## What this intentionally skips

- **No `:latest` tag** — git is the source of truth for what's newest.
- **No blue/green** — projects briefly overlap during `compose up -d`.
  Acceptable for the homelab / small-business target.
- **No pre-flight image scan** — assume local security scanning.
- **No database migration framework** — hosts hand that off to hooks.
- **No data / volume rollback** — rollback is image + config only.
