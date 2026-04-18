# Build, Deploy, Rollback

The core lifecycle loop. Grew out of one project's `scripts/{build-push,deploy,remote-deploy}.sh`
and generalized so every project gets the same flow.

## Versioning contract

Versions come from git tags on the project repo, formatted `vX.Y.Z` (semver).

- `build-push` requires HEAD to have exactly one `v<semver>` tag.
- `hosting deploy` (no args) labels the **working tree** with HEAD's tag
  and rsyncs it as-is. Lets you iterate on compose / env template between
  tagged releases without forcing a commit for every tweak.
- `hosting deploy X.Y.Z` and `hosting rollback X.Y.Z` target a specific
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

## `hosting build-push`

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

## `hosting deploy`

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
     - setup-env.sh and remote-deploy.sh (hosting-owned helpers, overwritten
       on every deploy to match installed hosting version) → /apps/<name>/scripts/
     - traefik-dynamic.yml → /apps/traefik/dynamic/<name>.yml (hosting-owned
       path, handled out-of-band — see traefik.md)
6. Env drift check (via setup-env.sh on VPS):
     MISSING .env         → run interactive setup
     DRIFT from template  → prompt: re-run setup / continue / abort
     OK                   → continue
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
9. Compute changelog (git log <prev-deploy>..<new>) and print it locally.
```

### Why working-tree for no-args, git-archive for explicit versions

`hosting deploy` with no args is the iterate-and-ship path: you've cut
a tag, tweaked compose or the env template since, and want to ship
what's on disk. Using `git archive` there would force every tweak to
be committed first, blocking the workflow.

`hosting deploy X.Y.Z` means "deploy version X.Y.Z as it was tagged" —
reproducible, so it comes from `git archive`. The working tree is
irrelevant (and untouched).

## SSH multiplexing

`hosting deploy` and `hosting rollback` open an SSH ControlMaster before
any remote operation and reuse it for every subsequent `ssh` / `rsync` /
`scp` in the same run:

```bash
ssh -o ControlMaster=auto \
    -o ControlPath=~/.ssh/cm-%r@%h:%p \
    -o ControlPersist=60s \
    user@vps true
```

Turns ~5× TCP+TLS handshake overhead per deploy (reachability check,
mkdir, rsync, env check, mail claim, remote-deploy) into one.

## `versions.log` format

Append-only, space-delimited. Lives at `/apps/<name>/versions.log` on the VPS:

```
<iso-timestamp> <action> <version> <backup-path-or-"no-backup"> hosting=<version>
```

Example:

```
2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup hosting=0.1.0
2026-04-15T14:30:00+00:00 deploy 1.3.0 backups/pre-deploy-20260415-143000.sql.gz hosting=0.1.0
2026-04-17T09:15:00+00:00 rollback 1.2.0 no-backup hosting=0.1.0
```

Fields:
- `action` — `deploy` or `rollback`.
- `version` — the semver that ran.
- `backup` — relative path to backup file, or `no-backup`.
- `hosting=...` — version of hosting that wrote the entry.

Hosting does **not** track migration counts; that was a specific
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

`hosting history` transparently reads both files: `versions.log` first
(fast, usually enough), and `versions.log.gz` on demand (`--all`, or
when the requested version isn't in the active log).

### Why append-only

Fast to parse, cleanly survives single-deployer concurrent writes (the
only scenario hosting targets), and rotation keeps the active file
small without sacrificing history.

## `hosting rollback`

### Flow

```
1. Open SSH ControlMaster.
2. Resolve target version:
   - explicit: positional VERSION arg
   - implicit: second-latest entry in versions.log with action=deploy
3. Verify target appears in versions.log (or versions.log.gz).
     NOT present → fail:
       "Version X was never deployed to this VPS.
        Use `hosting deploy <user@host> X` for a first-time deploy."
4. Verify git tag v<target> exists locally.
     missing → `git fetch --tags`, retry
     still missing → hard fail
5. Read v<target>'s files WITHOUT touching the working tree:
     git show v<target>:hosting.yml       → used for the sync list
     git show v<target>:compose.prod.yml  → used for the image set
6. Image check — for each service with `build:` in v<target>'s compose:
     :<target> present on VPS  → ok
     :<target> present locally → auto-push (save | gzip | scp | load)
     neither                   → fail with:
       "Image <image>:<target> is not on the VPS and not on this machine.
        Rebuild with:
          git checkout v<target> && hosting build-push <user@host>
        Then retry:
          hosting rollback <user@host> <target>"
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
- Hosting helper scripts (`setup-env.sh`, `remote-deploy.sh`) — from the
  **current** hosting install, not from git. Helpers belong to hosting,
  not to the project's version history.

Does NOT restore:
- `.env` secret values. These aren't in git; only `.env.prod.example` is.
  If v<target>'s template has different keys, the standard drift detection
  fires and prompts the user.
- `data/` bind mounts (DB state, uploads, caches). For schema rollback,
  use `pre-rollback` hooks.
- Anything externally provisioned (DNS, API keys, mailbox contents).

## Helper scripts on the VPS

`hosting deploy` and `hosting rollback` sync two scripts per project:

- `setup-env.sh` — rich env template renderer (see `env-template.md`).
- `remote-deploy.sh` — orchestrates the VPS-side flow. Modes:
  - `deploy <version>`  — backup → pre-deploy → retag :current → up → health → post-deploy.
  - `rollback <version>` — pre-rollback → retag :current → up → health → post-rollback.

These are the *only* hosting-owned files that live on the VPS in a
project directory. They are overwritten on every deploy / rollback so
they match the hosting version driving the operation.

## What this intentionally skips

- **No `:latest` tag** — git is the source of truth for what's newest.
- **No blue/green** — projects briefly overlap during `compose up -d`.
  Acceptable for the homelab / small-business target.
- **No pre-flight image scan** — assume local security scanning.
- **No deploy locking** — single-developer model. If two people push at
  once, the second wins (and their hooks run).
- **No database migration framework** — hosts hand that off to hooks.
- **No data / volume rollback** — rollback is image + config only.
