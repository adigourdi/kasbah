# Build, Deploy, Rollback

The core lifecycle loop. Grew out of one project's `scripts/{build-push,deploy,remote-deploy}.sh`
and generalized so every project gets the same flow.

## Versioning contract

Versions come from git tags on the project repo, formatted `vX.Y.Z` (semver).

- `build-push` requires HEAD to have exactly one `v<semver>` tag — not one
  shaped like a dirty label below — and a **clean tree**: no tracked change and
  no untracked file git does not ignore (`.kasbah/` aside — kasbah writes it),
  edits inside submodules and embedded repositories included whatever git's
  `ignore` settings say. A path git is told not to read from disk
  (assume-unchanged, skip-worktree, a sparse checkout) is refused outright,
  `--dirty` included: kasbah cannot see what it holds.
- `kasbah deploy` (no args) ships the **working tree** under HEAD's tag, and
  requires the same clean tree — so the tag names exactly what runs.
- **An untagged HEAD is a release in waiting**: build-push — and deploy, for a
  project that builds no images (one that does is sent to build-push, since
  that version was never built) — offer three tags — patch, minor and major
  bumps of the highest final `vX.Y.Z` merged into HEAD (rc and dirty-shaped
  tags ignored; `0.0.0` when there is none) — cut the chosen one at HEAD as a
  lightweight tag, and carry on as a tagged run. `--bump=patch|minor|major`
  answers without a terminal; without either the run fails naming it. A
  computed tag that already exists locally or on origin is refused (an origin
  that cannot be asked warns, and the run carries on); an untagged dirty HEAD
  is refused ("commit first"); a shallow clone, or one with no tag merged into
  HEAD while origin has v-tags this clone lacks, is refused (`git fetch
  --unshallow --tags`), so a CI checkout never counts from `0.0.0`. The tag is
  lightweight (`tag.gpgSign` is overridden) and cut before anything reaches
  the server — a run that fails later keeps it, and says how to drop it (`git
  tag -d`). Every call to origin says what it is asking. Without a terminal it
  is bounded (60 s, its whole process group killed) and runs with
  `GIT_TERMINAL_PROMPT=0`, plus `BatchMode=yes` when the ssh command is `ssh`
  itself — so nothing waits on a prompt nobody can answer. With a terminal git
  may prompt, and nothing is killed; only ssh's connect is bounded (15 s). A
  wrapper in `GIT_SSH_COMMAND` or `GIT_SSH` is never given options. kasbah
  reads origin and never writes to it: publishing a tag is `git push origin
  v<version>`, the operator's. Once a deploy (of HEAD or of a named version)
  or a rollback succeeded, or build-push shipped the images, a missing tag is
  one `git:` line under the summary — the server runs a version origin cannot
  fetch, and the push that publishes it; an origin that cannot be asked is
  one line saying the tag went unchecked; a tag origin has, or no `origin` at
  all, says nothing. Origin is asked only once kasbah has let go of the
  server (its lock, its ssh session).
- `--dirty`, on either, is the quick-test path: no commit, no tag. The build is
  labelled `<base>-dirty.<UTC yyyymmddhhmmss>` — base is the highest `v*` tag
  merged into HEAD, else `0.0.0` — in the image tag, `versions.log` and the
  report (`+` is not allowed in a Docker tag, `-` is). build-push records the
  label, the target and a digest of the working tree in `.kasbah/state.json` —
  only when the tree is the same after the build as before it, so an edit made
  mid-build is never vouched for. The digest writes nothing into git: HEAD's
  tree plus a sha256 of every changed or untracked file, submodules included; `deploy --dirty` deploys only that label, to that
  server, from that same tree, and otherwise refuses naming `build-push
  --dirty` (a stock-only project makes its own label). A dirty build is never
  a rollback target: naming one is refused, the implicit target steps over
  them, and `deploy X.Y.Z` refuses one too — git cannot reproduce it.
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

`:<version>` tags are pruned routinely: `kasbah server prune`
removes version tags that are **both** older than 3 months **and** not
among the project's last 3 deployed versions — where the version
`:current` points at counts as the first of the 3. `:current` itself is
never pruned. The time window mirrors the versions.log rotation cutoff;
the count floor guarantees rollback targets exist (current plus two
older) even on rarely-deployed projects. A `-dirty.` tag is never among
those three — it cannot be rolled back to — so it goes once it is outside the
window, unless `:current` still points at it.

Three further things are never removed, and `cli.md` → `kasbah server
prune` states them with the command: the image `:current` resolves to
(whatever the record says), a tag any container was created from, and
every tag of a repository more than one project declares — or that a
project whose `compose.yml` kasbah could not read *might* declare, which
stops the run outright.

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
     run with KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0 and
     DOCKER_DEFAULT_PLATFORM=linux/<server arch> in the environment
4. Tag each built image:
     <image>:<version>
5. kasbah remote layers <apps> <chain ids>   # which layers the server holds,
                                             # and their known blob names
   docker save <all built images> | (drop those layers) | gzip, streamed over
   the ssh master into
     <apps>/.kasbah/bin/kasbah remote load <apps> <images>   # gunzip → docker load,
                                                      # then inspect each image
6. Ask origin for v<version>   # read-only; a missing tag is one line under the
                               # summary (Versioning contract)
```

Three details in that flow are load-bearing.

**The build needs the resource-limit variables set to something.** A project
on `cpus: ${KASBAH_CPU_LIMIT}` and `mem_limit: ${KASBAH_MEM_LIMIT}` (R01/R02 —
the default `check --fix` writes) cannot interpolate them without values, and a
build has no server to read them from, so a bare `docker compose build` fails on
every such project before it reaches the Dockerfile:

```
error while interpolating services.web.cpus: failed to cast to expected type:
  strconv.ParseFloat: parsing "": invalid syntax
```

`build-push` therefore builds under `KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0`.
Both are runtime keys — nothing reaches the image, the stream or the server,
and `0` is Docker's "no limit" in the event anything ever consumed them. The
guarantee that keeps it inert is that no `build.args` references a `KASBAH_*`
key; nothing enforces that today.

**One `docker save` invocation carries every built image.** Saving them
separately throws away the layer dedup a single stream gives you across
images that share a base.

**Only the layers the server lacks cross the wire.** One round trip on the
same ssh session, `kasbah remote layers`, asks which of the built images'
layers the server's store already holds — by **chain ID**, since a layer is
reusable only on top of the same parents, which is how both image stores look
layers up — and a streaming tar filter drops those layers' `blobs/sha256/…`
entries (and docker 25's `<id>/layer.tar` links to them) from `docker save`'s
output, constant memory, `manifest.json` and the configs untouched. Measured on
the rig: a re-push after changing one page sent 6.4 kB where the whole images
gzip to 28.7 MB. Anything kasbah cannot trust — its own layer lists unreadable,
an answer that fails, times out or names an ID it did not ask about — ships the
whole images, with a warning. A `docker save` in the pre-25 format ships whole:
nothing in it can be matched.

**A containerd-store workstation** — Docker Desktop, a fresh Docker Engine 29 —
saves each layer compressed, under its compressed digest, and no Docker API
gives that digest for a local image without an export; `docker save` writes
its manifests last, so one pass cannot pair a layer with its ID before the
layer has gone by. The **server keeps the pairing**: `<apps>/.kasbah/layers.map`,
compressed blob digest → layer ID, learned by `remote load` from the
`manifest.json` and configs at the end of every stream it loads — they name
every layer, the ones left out included, a layer saved under its own ID too —
and pruned by `remote layers` to the layers still in the server's store, so it
never outgrows it. `remote layers`
returns the names it knows, and the filter drops a layer by its ID or any of
its names, and the workstation asks `docker info` for its store only when a
skippable layer has no recorded name at all. When a layer the server holds has no known name — the first push
from such a workstation, a base image the server pulled itself — the workstation
first runs one **learning save**: a local `docker save` read for its manifests
and thrown away, announced in one line; nothing crosses the network and nothing
touches disk. Measured from a containerd-store workstation to the rig: 7.2 kB
on the first push, 7.4 kB on a one-layer re-push, against 29.9 MB whole. A
layer another workstation compressed differently is sent once, and its name is
learned from that load. The workstation's store is read from `docker info`
(`driver-type io.containerd.snapshotter.v1`); an overlay2 workstation names
layers by ID and never needs the map.

On the containerd image store `docker load` of an archive missing a layer
succeeds when the store already has that layer unpacked — even one only a pull
put there — and when it does not, docker prints `Error unpacking image` and
**exits 0**, leaving a tagged image no container can be created from. `kasbah
remote load` therefore proves every image it loaded by creating — never
starting — a container from it (`docker create --pull=never <image> true`,
removed at once), and reads docker's output for that line as an early sign;
either refuses the load (`incomplete=`), which also stops a whole load from
passing in that state. On overlay2 a missing layer fails the load outright.
Whenever a stream that left layers out arrived whole and the load still failed
— a layer pruned between the question and the load included — the workstation
re-sends the images whole once, with a warning, and reports both streams'
bytes. A save in which nothing could be matched — the learning save failed, or
the store was misread — says so rather than reporting "0 already on the server".

**The images stream; no tarball touches disk.** The workstation gzips `docker
save` into the ssh master's stdin and the server's kasbah binary gunzips into
`docker load`, so a failed transfer leaves nothing behind on either machine.
The tar end marker and the gzip trailer are written only after `docker save`
exits 0, so a failed save arrives as a short stream and is refused. A partial image is never tagged:
`docker save` writes every layer before `manifest.json`, and docker refuses
short input. A broken transfer restarts from zero. Measured on the rig: 2.7 s for two images (28.7 MB gzipped) against 6.2 s
for the tarball path.

**A deploy that fails at `compose up` or its health wait reverts.** The order
is retag → up, and by then the workstation has already replaced the project's
files, so a revert has to put back both. Before the sync, `kasbah remote deploy
snapshot` — under `.deploy.lock`, refused when another run holds it — copies
every path the run will overwrite — the sync targets after their renames,
directories whole, and `.env` — into `<apps>/<name>/.kasbah-prev/`, noting which
did not exist, under a token the engine is handed, and stamps its manifest
with the time (`taken`, UTC, to the second). **A snapshot that exists
always holds the files the live stack started from**: one left by a run that
died on the workstation (the env step, the sync, an interrupt) is kept, and the
next run copies only the targets it does not cover. One taken no later than
the second of the last run the active `versions.log` records as live — a
success, a rollback, or a `deploy-failed … reason=post-hook` — is that run's
own, left behind when it could be neither moved into a backup nor removed:
it holds an earlier version's files, so the snapshot step refuses it, changing
nothing, and names `.kasbah-prev/` for the operator to remove by hand. A
manifest without `taken` is as old as its mtime; with no readable such entry
(a first deploy, a log only the archive holds, or a run whose own
`versions.log` line could not be written), a snapshot is kept as above.
The first engine run a snapshot
serves records in it each built image's `:current` id — the ids the live stack
started from, kept with a kept snapshot — and every run records the running
containers before retagging. Any
failure before the retag (the image preflight, a backup or `pre-deploy` hook
the operator chose to stop on) puts the files back; any failure from the retag through the health wait also puts every
`:current` back on its old id (untagging one that did not exist), runs `compose
up -d --remove-orphans` on the restored files, attaches Traefik to the
project's network again, and waits on the containers that were running before. A revert that works writes nothing to `versions.log` —
the server is where it was — and the run still fails, saying it is back on the
previous version. A revert that cannot work (no matching snapshot, the old
stack will not come up) appends a `deploy-failed` line naming why and keeps the
snapshot. A directory target is put back **in place** — every snapshot entry staged
beside its place and renamed over it first, entries the snapshot lacks removed
only afterwards, entries that already match left untouched, the directory itself
never replaced — so a container that survives the revert and bind-mounts it
sees the restored files, not an empty directory; files are put back by
temp-and-rename, as the sync writes them. A directory's mode and mtime are put
back where they differ, best-effort. When a container-owned entry refuses the
reconcile (permission denied), that target is swapped whole instead: the directory the failed run left is
kept as `.kasbah-aside.<pid>.<n>` beside it — the inode the running container
still has mounted — and the run names it, to remove once that container is
recreated. Whether an entry already matches is rsync's quick check (type,
mode, size, mtime, a symlink's target); no file is read to decide.
A reconcile cut short leaves its target part one version, part the other, and
the run says that rather than listing it as put back. A first deploy has nothing to revert to and is left as it failed. A
revert or restore that worked removes the snapshot — its manifest first, so a
removal cut short leaves no snapshot rather than half of one (a manifest whose
copies are missing counts as none) — and a run that leaves its version live
keeps it, as the backup below.

**A run that leaves its version live keeps a backup of the one it replaced.**
The *outgoing* version is the one live at the run's start: the version
`versions.log`'s last entry names when that entry is a success or a
`deploy-failed … reason=post-hook` (that version went live); after any other
`deploy-failed` — a failed revert — the last entry that is not a failed run's,
since the snapshot that run kept is that version's files; and `unknown` when
neither names one (a damaged line, or a log only the archive holds). On every
deploy that is not a first, the engine creates
`<apps>/<name>/backups/<outgoing>-<stamp>/` (`<stamp>` UTC `YYYYMMDD-HHMMSS`,
mode `770`) before the `backup` hooks run, and every deploy hook gets its path
as `$KASBAH_BACKUP_DIR` — `none` on a first deploy. The rollback hooks get the
target's backup instead, extracted (rollback flow, step 10).
Once the new version is live — the run succeeded, or only a `post-*` hook
failed — the snapshot's copies move into it, each at its path under
`kasbah-snapshot/` (manifest removed first), beside what the hooks wrote; the
directory is tar-gzipped into `backups/<outgoing>-<stamp>.tar.gz` (names
relative to it; each directory a copy holds with the mode it had on disk, and
`kasbah-snapshot/` and the directories leading to a copy `770`; mode `660`,
since it holds `.env`; written as `.part`, synced, then renamed, with SIGHUP
and SIGPIPE ignored and SIGINT and SIGTERM held — a second one exits,
removing the `.part` on its way out and keeping the backup directory, which
then holds the only copy of the outgoing `.env`, for the operator) and the
directory removed. A second signal while the copies move exits keeping the
backup directory with what reached it and setting what is left of
`.kasbah-prev/` aside as `.kasbah-prev.kept-<outgoing>-<stamp>/`, as a failed
move does (its fallback included), and writes one line to stderr naming both.
`versions.log` field 4 and the report's `backup` name the tarball. A
rollback keeps its snapshot the same way: its backup, of the version it left,
holds `kasbah-snapshot/` alone, because no hook writes into it. A first deploy
keeps none (`no-backup`). A run that stops at the question or reverts uses the
snapshot up and removes the backup directory; one whose restore or revert
fails keeps the directory beside the snapshot it keeps, and names it. A tarball
that cannot be written — a file a hook left unreadable, a full disk — is a
warning, never the run's failure: the directory, which by then holds the
snapshot's copies, is left where it is for the operator, and `versions.log`
records `no-backup`. A snapshot that cannot be moved into the backup
directory, or a backup directory that cannot be created, is the same warning:
what is left of `.kasbah-prev/` is renamed to
`.kasbah-prev.kept-<outgoing>-<stamp>/` beside it, which no run reads or
removes, the warning names it and the backup directory, and `versions.log`
records `no-backup`. Moved within a filesystem, each copy is in one of the
two; copied across filesystems, the backup directory's last copy may be
partial and the renamed directory holds the whole snapshot — or, once every
copy is whole and only the originals' removal failed, the backup directory
holds every copy and the renamed directory what is left of the originals.
When that rename
fails, the outgoing version's files are dropped rather than left for the next
run to merge as its own: `.kasbah-prev/` loses its manifest, so the next run's
snapshot removes it, `.env` copy and all; when the manifest cannot be removed
either, `.kasbah-prev/` is removed at once; when neither can be removed, the
warning says to remove `.kasbah-prev/` by hand, and the next run's snapshot
step refuses it until then (above). The
warning names the step that failed and what became of `.kasbah-prev/`.
A backup directory left behind — its tarball unwritten, or beside a snapshot
that could not move into it — and a kept-aside snapshot stay until the
operator removes them: `server status` counts them and `check --server` names
each by path (B02).

`backups/` may be a directory, a symlink to one, or a mount point. The engine
opens it once and does every backup step — the directory, the snapshot's move,
the tarball, retention — through that one handle; when the move crosses
filesystems, every copy is copied (modes and mtimes kept) before any is
removed from the project, so a copy that fails leaves the snapshot whole. A
`backups/` that is anything else, or a symlink to nothing, is refused by
`prepare`, naming it, before anything is synced; the engine checks again,
and should it ever find one, it refuses before the backup hooks and puts the
synced files back.

**Retention** runs at the end of every successful deploy and rollback, on the
server's clock: of the files in `backups/` named `<version>-<stamp>.tar.gz`,
every one stamped within the last 24 hours is kept, and of the older ones only
the newest; the rest are removed, each said on stderr. Nothing else in
`backups/` is touched — a directory a failed tarball left, a file an operator
put there. There is no setting: these backups are for getting back from a bad
deploy, and the off-box history is restic's (`backup.md`).

**Nothing typed is lost to a restore.** An operator told to fix `.env` on the
server after a failed env step may have done so before the next run fails too;
a restore that would replace a `.env` differing from the snapshot's first saves
it as `.env.kasbah-replaced` (`660`) and the run names it. If it cannot be
saved, `.env` is not put back. Two operators deploying the same project at the
same moment can still cost one of them its revert — the snapshot's lock is
released before the sync — and that run says so and records `deploy-failed`.

**A failed backup or `pre-deploy` hook asks first.** No container has moved
yet, so instead of putting the synced files back at once the engine asks the
workstation whether to carry on: a question line on its stdout, one answer line
read back on its stdin, after the spec's own line. The workstation answers from
`--on-hook-failure=continue|stop` — which travels in the spec, so no question is
asked — or else from its terminal. *continue* runs on to the retag and `compose
up` as if the step had passed — a failed `backup` hook still leaves the
backup kept, the snapshot and whatever the hooks wrote — and
both ends say the run carried on past the failure; *stop* puts the files back as
above and starts nothing — what the hooks that already ran did (an `artisan
down`, half a hook) is not undone. With no terminal the workstation answers so,
and the run stops and fails naming the flag. A session that drops while the
question waits, an answer that is neither *continue* nor *stop* (the engine
says what came back), and no answer within 10 minutes all read as *stop*.
A rollback asks the same way when the extraction of its target's backup, a
`pre-rollback` hook or the `restore` hook fails: *stop* puts the files back —
`.env` with them, so a `.env` the rollback restored is undone — and leaves
whatever the `restore` hook already did to the data.
A backup directory that cannot be created is asked about the same way (the
step is `backup`): carried past it, the backup hooks do not run and the
`pre-deploy` and `post-deploy` hooks get `$KASBAH_BACKUP_DIR=none`; once the
version is live the engine tries to create the directory again for the
snapshot, and keeps no backup (`no-backup`) when that fails too.

**A `post-deploy` hook that fails is not reverted**: a migration may already
have run, and old code on a new schema is worse than new code with a failed
hook. The run appends `deploy-failed … reason=post-hook` — the new version is
the one running — ships the Traefik fragment, which now matches the live
containers, and fails. A run whose stack came up but whose
`versions.log` line could not be written says exactly that: the new version is
live and unrecorded, and its fragment is not shipped.

`build-push` does **not** touch `:current` and does **not** run `compose up`.
That's `deploy`'s job — decoupling lets you build-push without deploying
(e.g. to stage an image ahead of time).

## `kasbah deploy`

### Two modes

1. **No version arg** — deploy the working tree, using HEAD's `v-tag` as
   the version label. Everyday path. An untagged HEAD is offered a tag first
   when the project builds nothing (Versioning contract).
2. **Explicit `X.Y.Z`** — deploy that tagged version *exactly* as it was.
   Files come from `git archive v<X.Y.Z>`, not the working tree. Reproducible.

The explicit-version path is structurally identical to `rollback` (see
below). The only differences:
- Log entry is `action=deploy` (not `rollback`).
- Hook pair is `pre-deploy` / `post-deploy` (not `pre-rollback` / `post-rollback`),
  and the `backup` hook runs, as on every deploy.
- Nothing is restored from a backup: no `.env` or data question, and no
  `--with-env`/`--with-data` (rollback flow, step 7).
- No "must be in versions.log" precondition — you're allowed to deploy
  a version for the first time.
- The tag's `resources:` is held to a plain deploy's rules — refused when this
  kasbah refuses the block, it cannot be resolved, or a value resolves above
  the ceiling — where a rollback warns and takes the ceiling (rollback flow,
  step 9).

### Flow (no-args path — working tree)

```
1. Resolve version = HEAD's v-tag, cutting one first when HEAD has none
   (`--bump=`, Versioning contract) — before anything connects.
2. Open SSH ControlMaster (see "SSH multiplexing" below).
3. Check SSH reachability (fail fast), and ship the kasbah binary to
   <apps>/.kasbah/bin/kasbah if the server's is absent or older — asking
   first when a dev build would replace a release (`cli.md` → Hand-off).
4. Snapshot what the run will overwrite (`kasbah remote deploy snapshot`:
   the sync targets and `.env`, into <name>/.kasbah-prev/ — see "A deploy
   that fails … reverts" above), then ensure remote dirs exist
   (`kasbah remote deploy prepare`):
     /apps/<name>/, backups/, /apps/data/<name>/
5. Sync from the working tree: every path in manifest's `sync:` list → /apps/<name>/.
   The Traefik fragment is deliberately **not** shipped here — see step 9.
6. Env drift check (`kasbah remote setup-env` on the VPS):
     MISSING .env         → run interactive setup
     DRIFT from template  → prompt: re-run setup / continue / abort
     OK                   → continue
   `--env-seed=FILE` answers the setup's keys first — every key on a
   missing .env, the keys .env lacks on drift (filled without the prompt
   when the seed has them all) — and the setup runs without a terminal when
   it would ask nothing else (`cli.md` → `kasbah env`, `env-template.md` →
   Seeding the setup).
   Then refresh the kasbah-managed `KASBAH_*` keys in `.env` (resource
   limits read from the server marker, or `kasbah.yml`'s `resources:`
   resolved on the server — once step 1's tag exists and the server lock is
   held, before step 4, so a value above the ceiling is refused with nothing
   of the project changed on the server; a tag step 1 just cut stays in the
   local repository). The `KASBAH_` prefix is
   reserved and exempt from drift detection.
7. Mail claim (if manifest has `mail:`):
     look for a mail stack on the server   # today: warn and continue when absent
     verify claimed domain is listed in /apps/mail/kasbah.yml   # warns, never stops
8. Run `kasbah remote deploy run` on the VPS, the manifest's hooks, health,
   snapshot targets and built-image list passed as JSON on stdin:
     a. Create backups/<outgoing version>-<stamp>/ and run the backup hooks
        into it ($KASBAH_BACKUP_DIR), against the currently-running (previous
        version) containers — --skip-hooks does not skip them.
     b. Run pre-deploy hooks, in the server's shell from <apps>/<name>/,
        while the previous version is still running.
     a–b are skipped on a first deploy (no versions.log entry, active or
        archived, a deploy-failed line counting as one), and the run says so.
     c. Retag :<version> as :current for each built image.
     d. docker compose up -d --remove-orphans — a routed service that can roll
        instead gets a new replica beside the old one, waited healthy, then the
        old one removed by id (see "What this intentionally skips") — then
        attach Traefik to <name>_kasbah (`docker network connect`, live;
        traefik.md → Network).
     e. Wait for manifest's health.container to be healthy.
     f. Run post-deploy hooks, once the new containers are up and healthy.
     a–b failing: ask whether to carry on (--on-hook-failure=); stop puts the
        files back. c–e failing: put the files back,
        retag :current back, up the old stack — or, when that cannot work,
        append `deploy-failed`. f failing: append `deploy-failed …
        reason=post-hook`, no revert; the fragment still ships (step 9).
     g. Render .kasbah-hooks.json; move the snapshot into the backup
        directory and tar-gzip it to backups/<outgoing version>-<stamp>.tar.gz
        (also after f failing). Append the deploy entry, field 4 naming that
        tarball, to versions.log, then rotate it (see Rotation below), then
        apply backup retention.
     h. Print the run's report on stdout — see "The remote report" below.
9. Sync traefik-dynamic.yml → /apps/traefik/dynamic/<name>.yml (its content —
   a symlinked fragment ships what it points to, mode 644). Done by the
   *local* side once the engine has returned 0 with a valid report — the file
   is on the workstation, and the ordering is the point (see below).
10. Ask origin for v<version>, read-only, once the server lock and the ssh
    session are released; a missing tag is one line under the summary
    (Versioning contract). Then compute the changelog
    (git log <prev-deploy>..<new>) and print it locally.
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
single filesystem event on an idle Traefik is ~44 ms; a temp-then-
rename is two events and opens the file provider's ~2 s throttle window.
Either is a rounding error against "broken until a human intervenes".

The same ordering is what makes a `container_name` change safe on a
redeploy: the new fragment never names a container that does not exist
yet.

### Why working-tree for no-args, git-archive for explicit versions

`kasbah deploy` with no args ships what is on disk, and what is on disk must be
what HEAD's tag says — so a version names one byte set wherever it ran, and
`rollback 1.2.0` restores what 1.2.0 really was. A tweak worth trying before it
is committed goes through `--dirty`, which says so in every record it leaves.

`kasbah deploy X.Y.Z` means "deploy version X.Y.Z as it was tagged" —
reproducible, so it comes from `git archive`. The working tree is
irrelevant (and untouched).

## SSH multiplexing

`kasbah deploy` and `kasbah rollback` open an SSH ControlMaster before
any remote operation and reuse it for every subsequent `ssh` session in the same run — the file
transfers included:

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
mkdir, sync, env check, mail claim, the engine) into one.

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
- **The usable path budget is 90 bytes, not 108** — on Linux; macOS and the
  BSDs have a 104-byte `sun_path`, so 86 there (derived, not yet measured on a
  Mac; a typical macOS `$TMPDIR` gives a ~69-byte path). `sun_path` is 108, but
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
  escaped: ssh splits a `ControlPath` option on spaces, and reads `%` as a token.
- **`ConnectTimeout` bounds setup only** — including the banner exchange,
  but not an established session. A remote command that wedges after
  connecting is unbounded without `ServerAlive*`.

kasbah takes no ssh-options flag. It runs plain `ssh user@host` and
inherits the user's own `ssh_config`, the same way git does over SSH:
jump hosts, non-standard ports and key selection are already that file's
job. Everything remote goes through `internal/ssh`; nothing else in the
codebase invokes `ssh` directly.

**Files travel through the kasbah binary, not `rsync`.** The workstation sends
`kasbah remote sync` a list of what it has (path, type, mode, size, mtime); the
server answers which files it lacks — a file whose size and whole-second mtime
already match is skipped, as rsync's quick check does — and only those are
streamed, in one session. Each arrives with its size and sha256, lands in a temp
file beside its target and is renamed into place only once both check, so a
reader never sees half a file and an interrupted transfer leaves the old one.
Modes, mtimes and symlinks are kept, nothing extra is deleted, special files are
skipped with a message, and every write on the server stays inside the
destination (`os.Root`). Held to rsync's own results by
`tests/integration/sync_parity_test.sh`; a changed file is sent whole, where
rsync sent only its changed blocks.

## `versions.log` format

Append-only, space-delimited. Lives at `/apps/<name>/versions.log` on the VPS:

```
<iso-timestamp> <action> <version> <backup-path-or-"no-backup"> kasbah=<version> digest=<sha256:…,…|-> by=<user>
```

Example:

```
2026-04-12T01:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=sha256:9f2a…
2026-04-15T14:30:00+00:00 deploy 1.3.0 backups/1.2.0-20260415-143000.tar.gz kasbah=0.1.0 digest=sha256:c81b…
2026-04-17T09:15:00+00:00 rollback 1.2.0 backups/1.3.0-20260417-091500.tar.gz kasbah=0.1.0 digest=sha256:9f2a…
```

Fields:
- `action` — `deploy`, `rollback`, or `deploy-failed` (a run the engine could
  not finish or revert; it carries `reason=up|health|post-hook|revert`, and
  `mode=rollback` when the run was a rollback). A `deploy-failed` line is
  history, never a rollback target and never a "previous version": the hooks'
  `KASBAH_PREV_VERSION`, the implicit rollback target, `rollback X`'s "was it
  deployed here" and prune's last three all step over it — a newest failed
  deploy still counts as what is running when the implicit target is picked.
- `version` — the semver that ran.
- `backup` — the backup this run kept of the version it replaced,
  `backups/<version>-<stamp>.tar.gz` relative to the project directory, or
  `no-backup`: a first deploy, a run that reverted, or a tarball that could not
  be written (A deploy that fails … reverts). Retention may since have removed
  the file it names.
- `kasbah=...` — version of kasbah that wrote the entry.
- `digest=...` — the image id the server's docker reports
  (`docker image inspect {{.Id}}`) for each built image that went live,
  comma-joined, or `-` for stock-only projects. Provenance: answers "which
  image actually ran" even after a rebuild of the same tag. What the id
  hashes depends on the server's image store — the config under overlay2,
  the manifest under the containerd store (the real host runs the latter) —
  so compare it only with ids from the same server. No registry is involved.
- `by=...` — the Unix user the server-side step ran as: the operator's ssh
  user (`server-setup.md` → Operators), or `uid=<n>` when the name could not
  be written as one token.

The four positional fields are **frozen forever** — never reordered, never
removed. New data lands as `key=value` pairs appended at the end.

**One predicate decides whether a line is an entry**, and both sides apply
it: four non-empty positional fields, and a first field beginning
`YYYY-MM-DDT`. The server-side reader and the workstation's agree, because
they disagreeing is a run that warns a line has no readable version and then
names the version the other reader took out of it. A line that fails the
test still **counts as history** — it is evidence the project has deployed
here — but yields no version, so `KASBAH_PREV_VERSION` is empty for the hooks and
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
be decoded, cannot be read, is not gzip, or ends in a truncated member: each
is a warning naming which, and the active log — which is authoritative for what
is deployed — is read either way. The
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
   - explicit `-dirty.` version: refused — git cannot reproduce it
   - implicit: the latest `action=deploy` entry before the running one that is
     not a `-dirty.` build (the running one counts even when dirty), across
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
7. Parse v<target>'s manifest for its `sync:` list. A v<target> whose
   kasbah.yml has a top-level `backup:` key is refused, naming the version:
   a tag is read with the manifest it was tagged with, so it cannot be
   rolled back to.
   Then find v<target>'s backup (`kasbah remote deploy backup-probe`,
   read-only, before anything on the server changes): the newest
   `backups/<target>-<stamp>.tar.gz` — the latest stamp; a version may
   itself contain `-`. With one, two questions are settled here, flag first,
   else the terminal, and with no terminal the run fails naming the flags,
   nothing changed:
     .env — when the backup holds `kasbah-snapshot/.env` and its keys differ
       from the server's `.env`: the names of the keys whose values differ,
       and of those only one side sets, are listed — never a value, which
       does not leave the server — `KASBAH_*` aside, `\r` stripped from both.
       Restore the backup's `.env` (--with-env), keep the server's
       (--no-env), or, on a terminal only, decide per key: one question per
       key, the backup's or the server's. No differing key, no question.
     data — when v<target>'s manifest has a `restore` hook: restore the data
       from that backup with it (--with-data), which replaces everything
       written since the backup was taken, or not (--no-data). --with-data
       when there is no backup or no `restore` hook is refused, naming which,
       pointing at --no-data.
   With no backup, neither is asked; `.env` is handled as on any rollback
   (step 9), and the data is left as it is. The probe reads the tarball up
   to `kasbah-snapshot/.env`, so a large dump ahead of it is read through.
8. Extract v<target> into a temp directory, then sync it entry by entry
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
9. Write the `.env` step 7 chose, on the server (`kasbah remote deploy
   restore-env`, the key names on argv, the values read out of the backup
   there): the backup's whole, or the server's with each chosen key's line
   taken from the backup — added where the server's has none, removed where
   the backup has none — every other line kept. It is written as every
   `.env` writer writes (`env-template.md`): under `.deploy.lock`, staged
   and renamed, mode `660`, SIGHUP and SIGPIPE ignored. The snapshot (step
   8) already holds the server's `.env`, so a revert puts it back.
   A failure from here until the engine runs — the drift check aborting
   (exit 5), the managed block failing to write, a question interrupted, or
   an engine that stops without a failure record (a refusal at its locks,
   or before it reads versions.log), so with no revert of its own — puts the server's `.env` back from the snapshot first (`kasbah remote
   deploy restore-env DIR --undo TOKEN`, under `.deploy.lock`, as a revert
   puts it back, the `.env` it replaces kept as `.env.kasbah-replaced`), and
   the failure says so. When that cannot be done — the session dropped, or
   the put-back failed — the failure says that `.env` holds the backup's
   values, which a plain deploy would run on, and prints the command that
   puts it back, `ssh <user@host> <apps>/.kasbah/bin/kasbah remote deploy
   restore-env <apps>/<name> --undo <token>`, good until the next deploy or
   rollback of the project; a SIGKILL leaves it unsaid.
   Then the env drift check, as a deploy runs it (step 6 there), against
   v<target>'s template: render .env when
   it is missing, prompt on drift, then refresh the managed KASBAH_* block.
   One difference: v<target>'s `resources:` never stops a rollback — a value
   above today's ceiling warns and takes the marker's ceiling for that half,
   and a block this kasbah refuses or a resolve that fails takes it for both
   (resolved before step 8, so nothing has shipped when it warns).
   v<target>'s .env.prod.example is what just landed in
   step 8, so this is the step that notices a template whose keys have
   changed since. --on-drift= answers it without a terminal, and so does
   --env-seed= for the keys .env lacks; exit 5 when there is no answer to
   be had.
10. Run the engine on the VPS in rollback mode (`kasbah remote deploy run`):
     a. Extract v<target>'s backup, when there is one and a hook below will
        run, into <apps>/<name>/.kasbah-unpacked.<pid>/ (mode 770 to the
        `kasbah` group like `.env`, on the project's filesystem: it holds
        `.env`; directories inside 770, files their own mode, owner `rw` at
        least and never past 660, so any operator's run can remove it), handed to the rollback hooks
        and the restore hook as $KASBAH_BACKUP_DIR — `none` without a
        backup. A member with an absolute name or a `..`, or one whose path
        runs through a symlink or anything but a directory, fails the
        extraction; symlinks are written as links and never followed; only
        the disk bounds its size. The directory is removed on every way out
        — success, failure, revert, a stop at the question, a signal — and
        one a killed run left is removed by the next deploy or rollback.
     b. Run pre-rollback hooks, in the server's shell from <apps>/<name>/,
        while the outgoing version is still running.
     c. Run v<target>'s restore hook, when step 7's answer was yes — the
        database still reachable through the outgoing containers.
        --skip-hooks never skips it.
     a–c failing asks whether to carry on (--on-hook-failure=), as a
        deploy's pre-deploy hook does; stop puts the files and `.env` back
        and leaves what the restore hook already did to the data. Carried
        past a failed extraction, b and g get `none` and c does not run:
        "data not restored: the backup could not be extracted".
     d. Retag :<target> as :current for each v<target>-era built image.
     e. docker compose up -d --remove-orphans, then attach Traefik to
        <name>_kasbah.
     f. Wait for health.container.
     g. Run post-rollback hooks, against the rolled-back containers.
     h. Render .kasbah-hooks.json from v<target>'s manifest, and keep the
        snapshot as the backup of the version left behind,
        backups/<outgoing version>-<stamp>.tar.gz — the `.env` it holds is
        the one the run replaced. Append the rollback entry, field 4 naming
        it, to versions.log, rotate, apply backup retention.
11. Restore v<target>'s Traefik fragment: <apps>/traefik/dynamic/<name>.yml,
    synced from the same extraction. **Last**, once the remote step has
    returned 0 — the same ordering, and the same reason, as a deploy's
    (see "Why the fragment ships last"). A rollback that dies at
    `compose up` must not have already pointed the live route at
    v<target>'s container names. A project with no fragment at v<target>
    is warned about and rolled back anyway; nothing is ever deleted.
12. Ask origin for v<target>, read-only, once the server lock and the ssh
    session are released; a missing tag is one line under the summary
    (Versioning contract) — a version that reached the server through
    `deploy X.Y.Z` may never have been published.
```

### Invariant

Every step that needs to know "what this version looks like" reads from
the `v<target>` git ref — manifest, compose, sync list, image set, and the
`restore` hook that puts its data back. Never from HEAD. This matters most when v<target>'s compose has a different
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
  synced out-of-band (same path as deploy).
- `.env`, from v<target>'s newest backup, when there is one and the answer is
  restore (whole) or per key (flow, step 7). Either way v<target>'s template
  then goes through the standard drift detection.
- Data, only through v<target>'s own `restore` hook reading that backup, when
  the answer is yes. kasbah copies no data itself.
- The engine is the **current** kasbah binary on the server, not anything
  from git: tooling belongs to kasbah, not to the project's version history.

Does NOT restore:
- `.env` or data when v<target> has no backup on the server — it was never
  the outgoing version of a run that kept one, or retention has removed it —
  and data when its manifest has no `restore` hook. Then `.env` is the
  server's, checked for drift as on any run.
- Anything externally provisioned (DNS, API keys, mailbox contents).

A rollback that fails and is reverted, or stopped at the question, puts back
the files it synced and the `.env` the server had (from the snapshot; a
restored `.env` is kept aside as `.env.kasbah-replaced`). It does not undo a
`restore` hook that ran: the data is what the hook left. A run that dies on
the workstation after step 9 leaves the restored `.env` on the server, with
the synced files, and the snapshot that holds the one it replaced.

`kasbah deploy X.Y.Z` is a deploy, not a rollback: it restores no `.env` and
no data, takes no `--with-env`/`--with-data`, and runs the `backup` hook.

## The engine on the VPS

`kasbah deploy` and `kasbah rollback` run the VPS side in the kasbah binary
itself — `kasbah remote deploy run`, the manifest's data (from the working tree,
or from the `v<target>` tag) passed as JSON on stdin — and ship no script.
Servers deployed by kasbah 0.x may still hold `scripts/setup-env.sh` and
`scripts/remote-deploy.sh`; nothing runs them, and `server destroy` removes them.
The engine has two modes:
  - `deploy <version>`  — backup hooks → pre-deploy → retag :current → up → health → post-deploy → backup kept.
  - `rollback <version>` — target's backup extracted → pre-rollback → restore (when asked for) → retag :current → up → health → post-rollback → backup kept.

  Flags: `--skip-hooks` (pre/post hooks only — the backup hooks still run,
  because a dry-run-ish deploy must not also discard the data safety net),
  `--no-health-wait`, and `--on-hook-failure=continue|stop`.

### A dropped session

The engine ignores `SIGHUP` and `SIGPIPE` and keeps draining its own output, so a
session that drops — a closed laptop, Ctrl-C at the workstation — never leaves a
deploy or rollback half-done: it runs to its `versions.log` line, or through its
revert, on the server. A failed backup or pre-hook it reaches afterwards has no
one to ask, and reads *stop*: the synced files are put back.
The workstation says it was interrupted, that the server carries on, and to look
at `kasbah history USER@HOST`; the Traefik fragment, which ships only after a
report, has not moved, so the next deploy ships it. A `SIGTERM` sent to kasbah
alone, with the session still up, waits for the run instead: a run that then
succeeds ships the fragment and exits 0 like any other.

A signal while the question is pending — on screen, or still to come once the
signal has arrived — answers it *stop*, and no prompt is shown after a signal:
the engine puts the synced files back, starts nothing and records nothing, and
the workstation says so instead of saying the server carries on.

### The remote report

The engine writes nothing to stdout for a human. Its progress, its warnings,
every command it runs and everything a hook prints narrate on **stderr**, and
stdout carries the report, printed as the run's last act — *after* the
`versions.log` entry is appended, as one JSON line. A run that carried on past
a failed backup or pre-hook adds `"continued":[…]`, naming each step.

```
{"version":"1.3.0","prev_version":"1.2.0","deployed_before":true,"backup":"backups/1.2.0-20260419-101500.tar.gz","digest":"sha256:9f2a…,sha256:c81b…"}
```

Before it, stdout may carry the one question a run asks,
`{"kasbah_deploy_question":1,"step":…,"error":…}`, after a failed backup or
pre-hook — on a rollback, the backup's extraction or the `restore` hook too; the workstation answers it with one line on the engine's stdin
(`continue`, `stop`, or `no-tty`; anything else is *stop*, and the engine
says what it read).

A run that fails prints a failure line there instead,
`{"kasbah_deploy_failed":1,"outcome":…,"reason":…,"prev":…}`, and the
workstation's message follows its outcome: `restored` (files put back before
any container moved), `reverted` (back on `prev`), `unrestored` / `unreverted`
(the put-back failed — `deploy-failed` recorded), and `saved` names a replaced
`.env` kept aside; `post-hook` (the new version
is live, its hook failed), `unrecorded` (live, but `versions.log` refused the
line). No line at all means the engine stopped before touching anything.

That placement makes it two things at once. It is how the local side learns
facts only the server has — chiefly the pair `deployed_before` and
`prev_version`, from which step 10's `git log <prev-deploy>..<new>` range is
computed and which exist nowhere on the workstation.

They are two keys because they answer two questions, and collapsing them is a
mistake this file has already made once. `prev_version` is empty both on a
genuine first deploy **and** when the log's last line is not one a version can
be read out of; only `deployed_before` separates those, and calling the second
one a first deploy would print "no previous version to compare against" about a
server that plainly has history. A log whose every entry is a `deploy-failed`
line adds `failed_only` (an optional key, not part of the required set): such a
server has run the project, so the backup and the `pre-*` hooks are not skipped
as on a first deploy, and the changelog says no earlier deploy succeeded rather
than calling it a first deploy. And it is the run's **completion marker**: an exit 0 with no
report, or with a report missing a key, means the script did not reach its end,
so the local side treats that as a failed deploy and **stops before shipping the
Traefik fragment**. A truncated run therefore leaves no route and no state, which
is the same failure shape the fragment-last ordering exists to prevent.

The local side validates the complete key set as a protocol before reading any
value, and checks the reported `version` against the one it asked for — the one
field in the report that can be verified rather than believed.

### The outgoing stack

The backup and the `pre-*` hooks act on the **outgoing** version, and whether
there is one is read off `versions.log`, never off a container list, which
cannot tell a first deploy from a crashed stack:

- **A first deploy** — `versions.log` has no entry for this project, active or
  archived; a `deploy-failed` line is an entry, since a first deploy whose
  `post-deploy` hook failed left its stack live. Both steps are skipped, said out loud, and the deploy proceeds.
  Running them would make a first deploy impossible for every project that
  declares either.
- **Anything else** — the project has deployed here before, so both steps run.
  kasbah does not inspect the containers first: a hook that needs the outgoing
  stack up says so by failing — a `docker compose exec` into a stopped
  container fails the `backup` hook that runs it. Either failure asks whether
  to carry on (`--on-hook-failure=`, above), and an operator who knows the
  stack is meant to be down answers *continue*. A `backup` hook that should
  skip its dump in some state tests for it and exits 0.

  Both modes hold an exclusive `flock` for the whole run, so a second
  concurrent deploy or rollback fails fast instead of interleaving hooks and
  retags (multi-operator safety). The whole run, from the marker read to the
  fragment, also holds the server lock `<apps>/.kasbah/server.lock` shared
  (`kasbah remote lock`), so a deploy never runs inside a
  `server init`, `upgrade-traefik`, `server prune` or `server destroy`, which
  take it exclusively; either refusal names every holder — command, user, pid. The lock is a dedicated file,
  `<project>/.deploy.lock`, held on its own file descriptor — flocking the
  directory path itself is not portable. Both are held while the engine waits
  on its question, so that wait is bounded: no answer within 10 minutes is
  *stop*, and the engine says it waited that long.

The manifest never reaches the server: the engine receives its data on stdin.
`.deploy.lock` is kasbah's — created, never shipped, its contents never read —
and the engine `flock(2)`s it, as `kasbah drop`, the snapshot step, `kasbah env`'s
setup, the managed-block refresh and `kasbah env set` do, so they exclude each
other — a refusal names the holder (every file kasbah writes in a project
directory is listed in `files.md`).

## What this intentionally skips

- **No `:latest` tag** — git is the source of truth for what's newest.
- **No blue/green across the project** — but a routed service **rolls**: one
  with no `container_name`, a healthcheck (its own or its image's), no
  published host port, no `depends_on` condition but `service_started` (only a
  plain `up` waits for the others — a migration that must succeed first), every
  host the **live** fragment reaches it by being its service name or a `kasbah`
  alias (so the route Traefik holds during the roll keeps answering), and
  health wait on, has its stopped old containers removed, gets its new replicas
  started beside the running ones (`up -d --no-deps --no-recreate --scale
  <svc>=<running+replicas>`), waits for them to be healthy under
  `health.timeout`, then has the old container stopped and removed **by id** —
  never by compose's choice on scale-down. Measured on the rig at ~15 req/s:
  2–7 502s per in-place recreate, 0 per roll. A replica that never turns
  healthy is removed and the deploy reverts, the old container untouched. Every
  other service — and a routed one that cannot roll, which the deploy names
  with why — is recreated in place, briefly unrouted. `kasbah check` warns
  beforehand about each routed service compose or the fragment keep from
  rolling (C11, `compliance.md`); live state stays the deploy's to judge. A
  process that exits on SIGTERM without draining can still drop its
  in-flight requests as the old container stops.
  Acceptable for the homelab / small-business target.
- **No pre-flight image scan** — assume local security scanning.
- **No database migration framework** — hosts hand that off to hooks.
- **No data / volume rollback** — rollback is image + config only.
