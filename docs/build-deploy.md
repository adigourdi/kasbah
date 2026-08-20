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
- `rollback` additionally requires the target to appear in
  `versions.log(.gz)`; if not, it refuses (it would be a first-time
  deploy). Any entry naming the version counts — a `rollback` entry is
  proof the version ran here exactly as a `deploy` entry is, and a
  version rolled back to twice has a `rollback` line as its most recent
  mention. Picking the *implicit* target is the separate question that
  does look at `action=deploy`.

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
3. docker compose -p <name> -f compose.prod.yml build
     run with KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0 in the environment
4. Tag each built image:
     <image>:<version>
5. docker save <all built images> | gzip > $TMPDIR/<name>-<version>.tar.gz
6. rsync tarball to VPS:/tmp, over the same ssh master
7. ssh VPS:
     docker load < tarball
     rm tarball
8. rm local tarball
9. git push origin v<version>   # if tag not on origin yet
```

Three details in that flow are load-bearing.

**The build needs the resource-limit variables set to something.** Compliance
rules R01/R02 make `cpus: ${KASBAH_CPU_LIMIT}` and `mem_limit:
${KASBAH_MEM_LIMIT}` mandatory in every project's compose file, and a build
has no server to read them from, so a bare `docker compose build` fails on
every kasbah-compliant project before it reaches the Dockerfile:

```
error while interpolating services.web.cpus: failed to cast to expected type:
  strconv.ParseFloat: parsing "": invalid syntax
```

`build-push` therefore builds under `KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0`.
Both are runtime keys — nothing reaches the image, the tarball or the server,
and `0` is Docker's "no limit" in the event anything ever consumed them. The
guarantee that keeps it inert is that no `build.args` references a `KASBAH_*`
key; nothing enforces that today.

**One `docker save` invocation carries every built image.** Saving them
separately throws away the layer dedup a single tarball gives you across
images that share a base.

**The tarball moves by `rsync`, not `scp`.** Everything remote goes through
`lib/ssh.sh`, which has no scp helper and gains none: rsync is already a
documented remote prerequisite and already rides the deploy's ControlMaster.
The local side writes into `${TMPDIR:-/tmp}` rather than a hardcoded `/tmp`,
following the same rule as the ssh control socket; the remote side is
literally `/tmp`. Both ends are removed by a trap rather than a final line —
a failed transfer must not leave gigabytes behind on either machine.

**A deploy that fails at `compose up` has already moved `:current`.** The
order is retag → up, so the tag then points at a version whose containers
did not start — and because `versions.log` is only appended to at the end of
a successful run, nothing on the server records that the tag moved. This is
by design: `:current` is a pointer, not a record, and `versions.log` plus the
image `:<version>` tags are the record. `kasbah rollback` is what puts the
pointer back, and the deploy's own failure message says so.

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
     look for a mail stack on the server   # today: warn and continue when absent
     verify claimed domain is configured in /apps/mail/.env   # roadmap v0.2
     copy snappymail_domain pre-seed if file missing on VPS   # roadmap v0.2
8. SSH into VPS and run scripts/remote-deploy.sh deploy <version>:
     a. If manifest has `backup:` AND `backup.check` exits 0 → run backup
        against currently-running (previous version) containers. Rotate.
     b. Run pre-deploy hooks against currently-running containers.
     c. Retag :<version> as :current for each built image.
     d. docker compose up -d --remove-orphans.
     e. Wait for manifest's health.container to be healthy.
     f. Run post-deploy hooks against new containers.
     g. Append deploy entry to versions.log, then rotate it (see Rotation
        below).
     h. Print the run's report on stdout — see "The remote report" below.
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
any remote operation and reuse it for every subsequent `ssh` and `rsync`
in the same run:

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
removed. New data lands as `key=value` pairs appended at the end.

**One predicate decides whether a line is an entry**, and both sides apply
it: four non-empty positional fields, and a first field beginning
`YYYY-MM-DDT`. The server-side reader and the workstation's agree, because
they disagreeing is a run that warns a line has no readable version and then
names the version the other reader took out of it. A line that fails the
test still **counts as history** — it is evidence the project has deployed
here — but yields no version, so `PREV_VERSION` is empty for the hooks and
the readers show the line's own bytes rather than inventing fields for it.
"Has this project deployed here" and "what version was it" are two questions
throughout, and collapsing them has produced defects in this codebase twice.

Rotation is the deliberate exception: it asks only "which month is this line
from", a strictly weaker question, so a truncated-but-datable line ages out
of the active log like any other. Requiring the full format there would pin
exactly the damaged write rotation exists to move. Every
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
   gzip streams are valid gzip — `zcat` reads all of them in order. A
   newly created archive takes the active log's mode and an existing one
   keeps its own, for the reason step 3 gives: an archive only one
   administrator can read is what makes a later `rollback` reason about a
   record it cannot see.
3. `versions.log` is rewritten with only the retained entries, keeping the
   mode it already had — `mv` replaces the inode, and a deploy record only
   one of several administrators can read is not one.
4. Nothing is ever deleted.

The three scratch files rotation works through — `.versions.log.keep`,
`.versions.log.drop` and `.versions.log.part` — live beside the record in
`<apps>/<name>/` and are removed on every path. A rotation killed outright
leaves them there; the next one truncates them before use, so a stale one
cannot corrupt it.

**Rotation has three failure shapes and the operator's next move differs in
each**, so it reports which happened rather than a single "could not
rotate". Nothing was written anywhere; or the append to the archive stopped
partway, so it may end in an incomplete gzip member while `versions.log` is
still whole; or the archive took the entries and the rewrite of
`versions.log` then failed — in which case **the entries are in both files**,
and every later run appends them to the archive again until `versions.log`
is trimmed by hand. That last state is the price of the gz-first ordering:
duplicated rather than lost, and loud rather than silent. A rotation failure
never fails the run — the deploy is already recorded, and a log compaction
must not cost the project its Traefik route.

**On the workstation, nothing about the archive is ever fatal.** It cannot
be decoded, cannot be read, is not gzip, ends in a truncated member, or the
workstation has no `gzip` at all: each is a warning naming which, and the
active log — which is authoritative for what is deployed — is read either
way. The prerequisite table in `server-setup.md` covers the *server*; a
workstation missing `gzip` loses the archived history and no more. The
asymmetry is deliberate: an unreadable **active** log stops the run, because
no command can answer honestly without it.

`kasbah history` transparently spans both files. They are fetched
together, in one round trip — over ssh a second round trip costs far more
than the archive's bytes ever will — and it is the *display* that is
on demand: plain `history` shows the active log, `--all` adds the
archive. Anything that has to answer "was this version ever deployed
here" (`rollback`) consults both regardless, since a target that has
aged into the archive was still deployed.

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
   - implicit: second-latest entry with action=deploy, across
     versions.log **and** versions.log.gz — a project that deploys less
     often than the 3-month rotation would otherwise have no implicit
     target at all, and the answer is identical whenever the active log
     holds two deploys. The image check in step 6 is what refuses a
     target too old to still be on the VPS.
3. Verify target appears in versions.log (or versions.log.gz).
     NOT present → fail:
       "Version X was never deployed to this VPS.
        Use `kasbah deploy <user@host> X` for a first-time deploy."
     That wording is an assertion about the whole record, so it is only
     used when the whole record was read. When a line could not be parsed,
     or the archive could not be decoded, the refusal says instead that
     the record could not be read through and that an unreadable part may
     be the one naming the target — kasbah does not answer "never
     deployed" from evidence it does not have.
4. Verify git tag v<target> exists locally.
     missing → `git fetch --tags`, retry
     still missing → hard fail
5. Read v<target>'s files WITHOUT touching the working tree:
     git show v<target>:kasbah.yml       → used for the sync list
     git show v<target>:compose.prod.yml  → used for the image set
6. Image check — for each service with `build:` in v<target>'s compose,
   `:<target>` must be present on the VPS. The message below is
   `rollback`'s: it can say "no longer" because the version provably ran
   here. `kasbah deploy X.Y.Z` reaches the same check without that
   evidence — the version may have been pruned or may never have been
   built — so it names both possibilities rather than asserting one. Nothing has reached the server
   at this point and nothing will until step 8; the implementation extracts
   (step 8's local half) before running this check, because the check reads
   the ref's compose out of the extraction, and the ordering that matters is
   that no *remote* write happens before it. Within the retention window
   (see "Retention") it always is. If pruned:
       "Image <image>:<target> is no longer on the VPS (outside the
        retention window). Prefer deploying a fix forward. To force a
        rollback anyway, rebuild from the tag (NOT byte-identical to the
        original — compare versions.log digests):
          git checkout v<target> && kasbah build-push <user@host>
        Then retry:
          kasbah rollback <user@host> <target>"
7. Parse v<target>'s manifest for its `sync:` list.
8. Extract v<target> into a temp directory, then rsync it entry by entry
   into /apps/<name>/, exactly as a deploy ships the working tree.
   (Overwrites whatever the last deploy's sync produced.)

   **Not** `git archive … | ssh vps tar -x`, which the earlier drafts of
   this file specified: `git archive` has no rename, and every kasbah
   project's sync list has at least one — `compose.prod.yml ->
   compose.yml` is required, since the server runs compose on
   <apps>/<name>/compose.yml and nothing else. A tar stream would land
   `compose.prod.yml`, leave the previous deploy's `compose.yml` in
   place, and bring the stack up on HEAD-era compose against
   v<target>'s images: the exact silent mismatch the invariant below
   exists to prevent. Two further `git archive` edges make the same
   point — a path that never existed at v<target> exits 128 and kills
   the *whole* archive rather than skipping the entry, so the list is
   validated against `git ls-tree v<target>` first; and `git ls-tree`
   exits 0 with empty output for a path it does not have, so the check
   compares the returned set against the requested one rather than
   trusting an exit status.
9. Env drift check, exactly as a deploy runs it (step 6 there): render
   .env when it is missing, prompt on drift, then refresh the managed
   KASBAH_* block. v<target>'s .env.prod.example is what just landed in
   step 8, so this is the step that notices a template whose keys have
   changed since. --on-drift= answers it without a terminal; exit 5 when
   there is no answer to be had.
10. SSH into VPS and run scripts/remote-deploy.sh rollback <target>:
     a. Run pre-rollback hooks against currently-running containers.
     b. Retag :<target> as :current for each v<target>-era built image.
     c. docker compose up -d --remove-orphans.
     d. Wait for health.container.
     e. Run post-rollback hooks against rolled-back containers.
     f. Append rollback entry to versions.log, rotate.
11. Restore v<target>'s Traefik fragment: <apps>/traefik/dynamic/<name>.yml,
    rsynced from the same extraction. **Last**, once the remote step has
    returned 0 — the same ordering, and the same reason, as a deploy's
    (see "Why the fragment ships last"). A rollback that dies at
    `compose up` must not have already pointed the live route at
    v<target>'s container names. A project with no fragment at v<target>
    is warned about and rolled back anyway; nothing is ever deleted.
```

### Invariant

Every step that needs to know "what this version looks like" reads from
the `v<target>` git ref — manifest, compose, sync list, image set. Never
from HEAD. This matters most when v<target>'s compose has a different
set of built images than HEAD (service added / split / renamed) — the
image set must match what that version's compose expects, not what HEAD
expects.

### A project renamed between the tag and HEAD is refused

`manifest.name` decides the server directory (`<apps>/<name>`), the compose
project name, and the Traefik fragment's filename. A project called `shop`
today and `store` at v<target> is therefore two directories on the server,
and a rollback naming one of them would ship v<target>'s files into the
other's tree, retag images the other's compose does not reference, and
leave a fragment pointing at containers that never start. Kasbah cannot
tell which of the two the run is about, so it refuses and says both names.
The same holds for `kasbah deploy X.Y.Z`.

Not a case any spec anticipated; found while building the tagged path. It
is the one thing the v<target> invariant *cannot* simply read from the ref,
because the name is what identifies the thing being rolled back.

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

  Flags: `--skip-hooks` (pre/post hooks only — the backup still runs, because a
  dry-run-ish deploy must not also discard the data safety net),
  `--no-health-wait`, and `--allow-stopped`.

### The remote report

`remote-deploy.sh` writes nothing to stdout for a human. Its progress, its
warnings and every command it runs narrate on **stderr**, and stdout carries
exactly one thing: a `key=value` report, one pair per line, printed as the
run's last act — *after* the `versions.log` entry is appended.

```
version=1.3.0
prev_version=1.2.0
deployed_before=yes
backup=backups/pre-deploy-20260419-101500.sql.gz
digest=sha256:9f2a…,sha256:c81b…
```

That placement makes it two things at once. It is how the local side learns
facts only the server has — chiefly the pair `deployed_before` and
`prev_version`, from which step 10's `git log <prev-deploy>..<new>` range is
computed and which exist nowhere on the workstation.

They are two keys because they answer two questions, and collapsing them is a
mistake this file has already made once. `prev_version` is empty both on a
genuine first deploy **and** when the log's last line is not one a version can
be read out of; only `deployed_before` separates those, and calling the second
one a first deploy would print "no previous version to compare against" about a
server that plainly has history. And it is the run's **completion marker**: an exit 0 with no
report, or with a report missing a key, means the script did not reach its end,
so the local side treats that as a failed deploy and **stops before shipping the
Traefik fragment**. A truncated run therefore leaves no route and no state, which
is the same failure shape the fragment-last ordering exists to prevent.

The local side validates the complete key set as a protocol before reading any
value, and checks the reported `version` against the one it asked for — the one
field in the report that can be verified rather than believed.

### The outgoing stack, and when a stopped one is a refusal

The backup and the `pre-*` hooks act on the **outgoing** version's containers.
When those are not running there is nothing for them to act on, and there are
two quite different reasons for that:

- **A first deploy** — `versions.log` has no entry for this project. Both steps
  are skipped, said out loud, and the deploy proceeds. Refusing here would make
  a first deploy impossible for every project that declares either.
- **Anything else** — the project has deployed here before, so a stopped stack
  means a crash, a manual `down`, or a host that rebooted. The deploy
  **refuses**, before any side effect, naming each container and the state
  docker reports for it. Deploying over it would skip the backup at exactly the
  moment it is worth having, and silently.

`--allow-stopped` is the override for an operator who knows the stack is meant
to be down. Both the refusal and the flag work **per container**: a stopped
hook container does not excuse skipping a backup whose own container is up, and
kasbah names which of the two it is talking about rather than announcing a
blanket skip it is not performing.

Two shapes need the flag that arguably should not: a `pre-deploy` hook
targeting a container that is deliberately `restart: "no"`, and a project whose
`backup.check` would have declined anyway while its backup container happens to
be stopped. The refusal is computed from static manifest data on purpose —
consulting `backup.check` first would mean running project-authored shell
*before* deciding whether the deploy may proceed at all.

**A container that no longer exists is a different thing from one that is
stopped**, and kasbah says so. Rename a `container_name:` in
`compose.prod.yml` without updating the hook that targets it, and the old name
is not down — it is gone. Telling the operator to start it would be advice they
cannot follow, and `--allow-stopped` would silently disable that hook on every
deploy from then on, which is the exact silent skip this guard exists to
prevent. The refusal therefore names the manifest/compose mismatch and points
at `kasbah check`'s HK01, which catches it locally before a deploy is
attempted.

  Both modes hold an exclusive `flock` for the whole run, so a second
  concurrent deploy or rollback fails fast instead of interleaving hooks and
  retags (multi-operator safety). The lock is a dedicated file,
  `<project>/.deploy.lock`, held on its own file descriptor — flocking the
  directory path itself is not portable.

These two scripts are the only kasbah-owned **files** in a project directory
on the VPS, and they are overwritten on every deploy / rollback so they match
the kasbah version driving the operation. `remote-deploy.sh` is rendered per
deploy rather than copied: the manifest never reaches the server, so the data
it carries — hooks, backup, health, the built-image list — is pre-rendered into
a marked block inside it. `.deploy.lock` is kasbah's too, but it is created
rather than shipped, and its contents are never read.

## What this intentionally skips

- **No `:latest` tag** — git is the source of truth for what's newest.
- **No blue/green** — projects briefly overlap during `compose up -d`.
  Acceptable for the homelab / small-business target.
- **No pre-flight image scan** — assume local security scanning.
- **No database migration framework** — hosts hand that off to hooks.
- **No data / volume rollback** — rollback is image + config only.
