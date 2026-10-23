# Files kasbah writes

Every path kasbah writes, on the workstation and on a VPS, with the command
that writes it, what reads it, its format and the spec that owns that format,
its mode, its owner, and what rewrites or removes it. This is the parity
contract of the Go port and roadmap Phase 4's inventory: a binary that writes a
path not listed here, or a listed path with a different mode or owner, has
changed a contract. Formats are not restated — each row links the spec that
owns it (`project-manifest.md` for the state file, `server-setup.md` for the
VPS layout, the pointer and the marker, `build-deploy.md` for `versions.log` and
the helper scripts, `backup.md`, `mail.md`, `traefik.md`).

`tests/integration/files_test.sh` reads the tables below as data, so their
shape is part of the contract:

- **Path** is one backticked pattern. `<apps>` is the apps path (default
  `/apps`), `<data>` the data path (default `<apps>/data`), `<tmp>` the
  workstation's `${TMPDIR:-/tmp}`, `<project-dir>` the project's checkout,
  `~` the invoking user's home, `<project>` the project's `name:`. Any other
  `<name>` is one path segment (`<pid>`, `<stamp>`, mktemp's `XXXXXX` as `*`),
  `*` matches within a segment, and `/**` — at the end or mid-pattern — stands
  for the entry itself or any depth below it (`a/**/*.tmp` covers `a/x.tmp` and
  `a/b/c/x.tmp`).
  `<path>` rows (whatever `sync:` names) document but never vouch for a file.
- **Mode** and **Owner** are checked when the cell is exactly one backticked
  value. `deploy` is the ssh user and its primary group. Anything in prose
  ("umask") is a value the code does not fix: the rig, at umask `022`, shows
  `755`/`644`.
- **Code** is the writer's `file:line`; lifecycle references are inline.
- *Transient* rows are files a successful run removes; they are listed
  because a failed or killed run leaves them behind.

Every command that reaches a server creates `<tmp>/kasbah-ssh.*`, and every one
that records `last_server` (`history`, `pending`, `changelog`, `logs`, `exec`,
`check --server` among them) merges `state.json`; beyond those two rows, the
commands not named as writers below write nothing — `check` (but see `--fix`),
`server status`, `mail-setup-guide` and `server prune` only read or remove.

## On the workstation

### The project tree

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<project-dir>/kasbah.yml` | `init-project`; `check --fix` (temp + rename); `migrate` (temp + rename, `kasbah_version` stamped) | every project command | YAML → `project-manifest.md` | umask on create; `--fix` keeps the original's (`chmod --reference`) | `deploy` | never removed by kasbah | `internal/initproject/initproject.go:137`, `internal/check/fix.go:702` |
| `<project-dir>/compose.prod.yml` | `check --fix` (edits, never creates) | `build-push`, `deploy`, `check` | YAML → `compliance.md` (`--fix`) | the original's | `deploy` | never removed | `internal/check/fix.go:702` |
| `<project-dir>/*.kasbah-fix.<pid>` | `check --fix` staging, one per file fixed, beside what the file resolves to (a symlink's target), so the commit is a plain rename | the rename (the diff, the guard and the re-plan work from memory) | YAML candidate | `600`, then the original's | `deploy` | *transient*: renamed, or removed by the `atexit` stack; SIGKILL leaves it | `internal/check/fix.go:702`, cleanup `:749` |
| `<project-dir>/.env.prod.example` | `init-project` | `env`, `check`, the deploy sync | text → `env-template.md` | umask | `deploy` | created once, never rewritten | `internal/initproject/initproject.go:140` |
| `<project-dir>/.gitignore` | `init-project` appends `.env` and `.kasbah/` | `check` S05/S06 | text | umask if created | `deploy` | never removed | `internal/initproject/initproject.go:178` |
| `<project-dir>/.git/**` | `rollback`, `deploy X.Y.Z`: `git fetch --tags` when the tag is missing | git | git's | git's | `deploy` | git's; not otherwise kasbah's | `internal/deploy/tagged.go:314` |

`deploy` in this table is the invoking user.

### The install (`install.sh`)

`<lib>` is `KASBAH_LIB_DIR`, else `$XDG_DATA_HOME/kasbah`, else
`~/.local/share/kasbah`; `<bin>` is `KASBAH_BIN_DIR`, else `~/.local/bin`.

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<lib>/<version>/kasbah` | `install.sh` (`.kasbah.new`, then rename), `<version>` being the build stamp; `self-update` (`.kasbah.part` streamed, size + sha256 checked against the signed `checksums.txt`, then rename) | the symlink; a hand-off (`cli.md` → Hand-off) | static ELF for this machine | `755` | the installing user | a re-install of the same stamp replaces it; never removed by kasbah | `install.sh:111` |
| `<lib>/<version>/server/kasbah-linux-<arch>` | `install.sh` (same way), amd64 and arm64; `self-update` (this machine's arch, a copy of its own binary); `serverbin.Local` fetching the missing arch of an installed release the same verified way | `serverbin.Local` — what that version ships to a server | static linux ELF | `755` | the installing user | as above | `install.sh:114`, `internal/serverbin/serverbin.go:56` |
| `<bin>/kasbah` | `install.sh`: `ln -sfn` to `<lib>/<newest>/kasbah`, newest by `internal/version` over the version directories whose binary runs (`kasbah __newest`); `self-update` the same, through `<bin>/.kasbah.new` and a rename | the shell | symlink | — | the installing user | repointed by every install; a regular file there (the pre-launcher install) is replaced, a directory refused | `install.sh:143` |

A pre-launcher install (`<lib>/server/kasbah-linux-*` at the top level, and the
pre-1.0 `libexec/`, `templates/`, `VERSION`, `*.sh`) is swept by the next install.

Developer tooling, not the CLI: `release.sh keygen` writes the minisign pair
`${KASBAH_RELEASE_KEY:-~/.config/kasbah/release.key}` (`600`, its directory
`700`) and `<repo>/release.pub` (committed, embedded in the binary);
`release.sh vX.Y.Z` writes the next `-dev` into `<repo>/VERSION`
(`release.sh:46`, `:133`).

### `.kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<project-dir>/.kasbah` | `init-project`; `mkdir -p` by every state write | — | directory | umask | `deploy` | never removed (`drop --prune` and `server destroy` included) | `internal/initproject/initproject.go:144`, `internal/state/state.go:44,100` |
| `<project-dir>/.kasbah/state.json` | created by `init-project`; merged by `build-push`, `deploy`, `rollback`, `env`, `history`, `pending`, `changelog`, `logs`, `exec`, `check --server`, `drop`, `migrate` (`schema_migrations_applied`) | every server-targeting command (`last_server`) | JSON → `project-manifest.md` (State file) | umask — each merge re-creates the file | `deploy` | rewritten on success only; never removed | `internal/state/state.go:43,90` |
| `<project-dir>/.kasbah/state.json.tmp.<pid>` | the merge's staging | — | JSON | umask | `deploy` | *transient*: renamed into place; a kill between render and the rename leaves it | `internal/state/state.go:131`, rename `:136` |

### The invoking user's home

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `~/.docker/**` | docker's buildx, during `build-push`'s `docker compose build` — not kasbah's code | docker | buildx state | docker's | `deploy` | docker's; never removed by kasbah | `internal/buildpush/buildpush.go:199` |

ssh may add to `~/.ssh/known_hosts` as the user's own ssh config says; kasbah
writes nothing under `~/.ssh`.

### Temporary files

`build-push` writes no image tarball on either end: `docker save`'s gzipped
stream goes over the ssh master straight into `docker load` under `kasbah remote
load` on the server (`internal/buildpush/ship.go`, `load.go`).

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<tmp>/kasbah-ssh.*` | every command that reaches a server | ssh (`ControlPath`) | directory → `build-deploy.md` (SSH multiplexing) | `700` | `deploy` | *transient*: removed on every exit path by the `internal/atexit` stack, SIGINT/SIGTERM/SIGHUP included; SIGKILL leaves it and a master living `ControlPersist` | `internal/ssh/ssh.go:116`, chmod `:118`, cleanup `:267` |
| `<tmp>/kasbah-ssh.*/m*` | ssh's ControlMaster | ssh | Unix socket | ssh's | `deploy` | *transient*, with its directory | `internal/ssh/ssh.go:95` |
| `<tmp>/kasbah-rollback.*/**` | `rollback`: the tag's manifest, compose file and fragment (`git show`) and its `sync:` list (`git archive`, unpacked in-process) | the plan readers, the project sync, the fragment | git tree export | dir `700`; files the archive's mode, umask applied | `deploy` | *transient*: removed on every return path, a signal's included (atexit); only SIGKILL leaves it | `internal/deploy/tagged.go:376,561`, removal `:381` |
| `<tmp>/kasbah-deploy.*/**` | `deploy X.Y.Z`: as above | as above | git tree export | dir `700`; files the archive's mode, umask applied | `deploy` | *transient*: as above | `internal/deploy/tagged.go:376` |
| `<tmp>/kasbah-backup-prune.*/**` | `server backup-prune`: `pw/<repo>.pass`, `env/<repo>.env` | `docker run` restic (`--env-file`, `/pw` mount) | password files; KEY=VALUE → `backup.md` (Credentials) | dirs `700`; files `600` | `deploy` | *transient*: removed on return and by the signal handlers; SIGKILL leaves the credentials | `internal/backup/prune.go:343`, cleanup `:348` |

Outside these, the local docker daemon keeps what `build-push` builds
(`<image>:<version>`) and the restic image `backup-prune` runs; kasbah removes
neither.

## On a VPS

### `/etc/kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `/etc/kasbah` | `server init` (`sudo mkdir -p`, `chmod 755` whenever the pointer step runs elevated — and it does on any run that finds the directory not `755`) | every pointer read | directory → `server-setup.md` (discovery pointer) | `755` | `root:root` | removed by `server destroy` once empty (`internal/destroy/destroy.go:179`) | `internal/serverinit/run.go:146` |
| `/etc/kasbah/apps-path` | `server init`, last, after the marker; staged, `cp`, `chown 0:0`, `chmod 644`, `mv` | every server command (the server binary's probe, `internal/serverbin/serverbin.go:216`), `server status`, `server destroy` | one absolute path → `server-setup.md` (discovery pointer) | `644` | `root:root` | rewritten when its content or mode/uid differs, or its directory is not `755`; removed by `server destroy` (`sudo -n`, a shell step after the server binary's) | `internal/serverinit/run.go:151`, destroy `internal/destroy/destroy.go:174` |
| `/etc/kasbah/apps-path.tmp.<pid>` | `server init` staging | — | as above | root's umask, then `644` | `root:root` | *transient*: renamed; a failure after the `cp` leaves it, and destroy's `rmdir` then keeps `/etc/kasbah` | `internal/serverinit/run.go:143` |

### `<apps>/.kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>` | `server init` (`sudo mkdir`, `chown` to the deploy user) when absent | everything | directory → `server-setup.md` (Who creates the apps path) | root's umask, never chmodded | `deploy` | never removed | `internal/serverinit/run.go:101` |
| `<apps>/.kasbah/migrate.lock` | `kasbah remote migrate` (`flock(2)`, taken without waiting) | — | empty | umask `022` | `deploy` | created on the first migration, never removed by it | `internal/migrate/server.go:104` |
| `<apps>/.kasbah/migrate/<from>-to-<to>-<stamp>.tar` | `kasbah remote migrate`, before any rewrite: every file the steps declare, the marker last (`archive/tar`, written beside its name and renamed) | `--undo` (the newest) | tar → `cli.md` (`migrate server`) | `644` | `deploy` | kept; the manual undo path when `versions.log` has moved on | `internal/migrate/server.go:54` |
| `<apps>/.kasbah-write-probe` | `server init` preflight, when `<apps>` is the user's but not writable | — | empty | — | `deploy` | *transient*: `rm -f` straight after | `internal/serverinit/probe.go:162` |
| `<apps>/.kasbah` | `server init` | — | directory → `server-setup.md` (What init creates) | umask | `deploy` | `rmdir` by `server destroy`, last of all, so any stray file keeps it | `internal/serverinit/remote.go:126`, `internal/destroy/destroy.go:202` |
| `<apps>/.kasbah/server.json` | `server init`, every run that changes its bytes (merge, never replace) | every server-targeting command, `server status`, `server prune`, `check --server` | JSON → `server-setup.md` (Server marker) | `644` | `deploy` | not touched by `upgrade-traefik`; removed by `server destroy`, only when every step before it succeeded | `internal/serverinit/remote.go:239`, `internal/destroy/remote.go:545` |
| `<apps>/.kasbah/server.json.tmp.<pid>` | `server init` staging (the pid is the server binary's) | — | JSON | `644` | `deploy` | *transient*: renamed; a failed rename is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<apps>/.kasbah/bin` | the Go binary's server step — `__ensure-server` now, every Go command that reaches a server from 10.6 on — in the upload (`mkdir -p` at umask `022`); `server init` ships it (`Options{Apps}`, the bootstrap) into the apps path it has just created or found, before any marker exists | — | directory → `phases/10-recast.md` (Rulings: one shared binary path) | `755` | `deploy` | never rewritten; `rmdir` by `server destroy` after the binary, `.lock` and any upload in it — a stray file keeps it | `internal/serverbin/serverbin.go:548`, `internal/destroy/destroy.go:195` |
| `<apps>/.kasbah/bin/kasbah` | `kasbah remote install-self`, run by a verified upload under `.lock`: renamed over the binary only when that is still absent, not runnable (not executable, not an ELF for this machine, exit 126 off a noexec mount, 127) or older — never the same build or newer (same-build rule: the workstation refuses a newer server build before uploading), so racing installs end on the newest | every `kasbah remote …` call; the `kasbah-backup` container, through its read-only `<apps>` mount (its entrypoint and healthcheck); the workstation's probe (`remote version`, bounded at 30 s) | static linux ELF, the workstation's own build for the server's `uname -m` | `755` | `deploy` | replaced by rename only, so a process running the old one keeps its inode; removed by `server destroy` — by a shell step once the binary's own step has exited, after the pointer | `internal/serverbin/install.go:72`, `internal/destroy/destroy.go:186` |
| `<apps>/.kasbah/bin/.lock` | `kasbah remote install-self` (`flock`, held across the re-check and the rename) | every install | empty lock file | `644` | `deploy` | created once, never removed by a run; removed by `server destroy` | `internal/serverbin/install.go:37`, `internal/destroy/destroy.go:191` |
| `<apps>/.kasbah/bin/.kasbah.*` | the upload (`set -C`, never over an existing file) | its own `remote version` check, then `install-self` | as `kasbah` | umask `022`, then `755` | `deploy` | *transient*: renamed over `kasbah` by `install-self`, else removed — by the run on any refusal or exit path (signals included), by the upload's own trap on SIGHUP/INT/TERM/PIPE or a short read; SIGKILL can leave it, and every later upload sweeps those older than 60 min; `server destroy` removes any left | `internal/serverbin/serverbin.go:546`, trap `:551`, sweep `:549`, destroy `internal/destroy/destroy.go:193` |
| `<apps>/.kasbah/backup` | `server init --with-backup` (`chmod 700` every run) | — | directory → `server-setup.md` (With backup) | `700` | `deploy` | removed whole by `server destroy` | `internal/backup/remote.go:156`, `internal/destroy/remote.go:479` |
| `<apps>/.kasbah/backup/compose.yml` | `server init --with-backup`, when its bytes differ (`kasbah remote init write`, after the credential probe passed); its start removes a Bash-era `backup.sh` beside it once `up -d` succeeded | docker compose (`kasbah-backup`) | compose → `backup.md` (The schedule) | `644` | `deploy` | as its directory | `internal/serverinit/backup.go:419`, `internal/remote/install.go:12`, `internal/backup/remote.go:433` |
| `<apps>/.kasbah/backup/env` | `server init --with-backup`: merged by the server binary — `KASBAH_BACKUP_REPO_BASE` and each `--backup-env` key rewritten by name, every other line copied through; its content never leaves the server | the backup container, the init probe | KEY=VALUE → `backup.md` (Credentials) | `600` | `deploy` | rewritten (temp + rename) only when its bytes differ, mode `600` enforced every run, before the probe — a refused run leaves it; as its directory | `internal/backup/remote.go:172` |
| `<apps>/.kasbah/backup/repos` | `server init --with-backup` (`chmod 700` every run) | — | directory | `700` | `deploy` | as its directory | `internal/backup/remote.go:156` |
| `<apps>/.kasbah/backup/repos/<repo>.pass` | `server init --with-backup`, for a repository it has not seen (sent on stdin, digest-checked); never rewritten | the backup container, `backup-prune` (over ssh) | one password → `backup.md` (Credentials) | `600` | `deploy` | as its directory | `internal/backup/remote.go:190` |
| `<apps>/.kasbah/backup/state` | `server init --with-backup` (`chmod 700` every run) | — | directory | `700` | `deploy` | as its directory | `internal/backup/remote.go:156` |
| `<apps>/.kasbah/backup/state/*` | the backup container (`kasbah remote backup`): the run record, `status.tmp.<pid>` + rename | its healthcheck (`kasbah remote backup health`), `server status`, `check --server` | → `backup.md` (The schedule), `server-setup.md` (With backup) | `644` | the container's root | rewritten every run; as its directory | `internal/backup/runner.go:127` |

### `<apps>/traefik/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/traefik` | `server init` | — | directory | umask | `deploy` | never removed | `internal/serverinit/remote.go:126` |
| `<apps>/traefik/compose.yml` | `server init` when its bytes differ (the server binary writes `<file>.tmp.<pid>` and renames it); `upgrade-traefik` (the same `kasbah remote init write`, after its backup) | docker compose (`traefik`), `server init` re-runs | compose → `server-setup.md` (Traefik stack) | `644` | `deploy` | kept by `server destroy` | `internal/remote/install.go:12`, `internal/upgrade/upgrade.go:571` |
| `<apps>/traefik/traefik.yml` | as above | Traefik, `server init` re-runs (baked values read back) | YAML → `server-setup.md` (`traefik.yml`), `traefik.md` (TLS) | `644` | `deploy` | kept by `server destroy` | `internal/remote/install.go:12` |
| `<apps>/traefik/dynamic` | `server init` | Traefik's file provider | directory → `traefik.md` (Why file provider) | umask | `deploy` | never removed | `internal/serverinit/remote.go:126` |
| `<apps>/traefik/dynamic/_shared.yml` | as `compose.yml` | Traefik, `check --server`, `server status` | YAML → `server-setup.md` (`dynamic/_shared.yml`), `traefik.md` (Middlewares) | `644` | `deploy` | kept by `server destroy` | `internal/remote/install.go:12` |
| `<apps>/traefik/*.yml.tmp.<pid>` | `server init` staging (the pid is the server binary's) | — | as the file | `644` | `deploy` | *transient*: renamed; a failed rename is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<apps>/traefik/dynamic/_shared.yml.tmp.<pid>` | `server init` staging (the pid is the server binary's) | — | as the file | `644` | `deploy` | *transient*: renamed; a failed rename is removed, a hard kill leaves it — Traefik reads `.yml` only, so it ignores it | `internal/remote/install.go:13` |
| `<apps>/traefik/dynamic/.kasbah-sync.<pid>.*` | the fragment's staging (`kasbah remote sync`; the pid is the server binary's), renamed over `<project>.yml` once its size and sha256 check | — | as the fragment | `600`, then `644` | `deploy` | *transient*: renamed; removed on a failed check, a cut stream, a dropped session (the step ignores SIGHUP) and SIGINT/SIGTERM; a hard kill leaves it — Traefik reads `.yml` only, so it ignores it | `internal/treesync/recv.go:381`, rename `:439`, cleanup `:80` |
| `<apps>/traefik/dynamic/_mail.yml` | `server init --with-mail`, when its bytes differ (the server binary writes `<file>.tmp.<pid>` and renames it) | Traefik | YAML → `traefik.md` (Discovery), `mail.md` (TLS flow) | `644` | `deploy` | kept by `server destroy` | `internal/serverinit/mail.go:221` through `internal/remote/install.go:12` |
| `<apps>/traefik/dynamic/<project>.yml` | `deploy` (shipped last), `rollback` (the tag's copy) | Traefik, `drop`, `server status` | YAML → `traefik.md` (Project fragment) | `644` | `deploy` | rewritten each run that has a fragment; removed by `drop`; kept by `server destroy` | `internal/deploy/session.go:119`, through `internal/treesync/recv.go:439` (shipped after the engine's report, `internal/deploy/deploy.go:299`; the tag's copy `internal/deploy/tagged.go:185`), `internal/drop/remote.go:350` |
| `<apps>/traefik/backups/<stamp>/**` | `server upgrade-traefik`: the three files (`cp -p`) and a `kasbah-upgrade` note | its own rollback on a failed start | copies → `traefik.md` (Upgrading Traefik) | dir umask; copies keep their mode and mtime, the note umask | `deploy` | never removed | `internal/upgrade/remote.go:277` |

### `<apps>/mail/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/mail` | `server init --with-mail` | `add-mail-domain` | directory → `server-setup.md` (With mail) | umask | `deploy` | kept by `server destroy` | `internal/mail/remote.go:286` |
| `<apps>/mail/compose.yml` | `server init --with-mail`, when its bytes differ | docker compose (`mail`) | compose → `mail.md` (Components) | `644` | `deploy` | kept by `server destroy` | `internal/serverinit/mail.go:221` through `internal/remote/install.go:12` |
| `<apps>/mail/cypht-nginx.conf` | `server init --with-mail`, when its bytes differ | `mail-cypht`'s nginx (bind mount, read-only); the start step recreates the container when it serves a different copy | nginx → `mail.md` (Webmail) | `644` | `deploy` | rewritten when it differs; never removed | `templates/mail/cypht-nginx.conf` |
| `<apps>/mail/kasbah.yml` | `server init --with-mail`; `add-mail-domain`; `drop --prune` of a claim | `deploy`, `server init`, `add-mail-domain`, `mail-setup-guide`, `drop`, `check --server`, `server status` (all through `internal/mailreg`) | YAML → `mail.md` (Multi-domain support) | `644` | `deploy` | removed by `server destroy` | `internal/serverinit/mail.go:221` through `internal/remote/install.go:12`, `internal/mail/remote.go:167`, `internal/drop/remote.go:382` (refused when its sha256 differs from the bytes the plan read; nothing locks it between that check and the rename, so a writer in that window can still be overwritten), `internal/destroy/remote.go:538` |
| `<apps>/mail/kasbah.yml.tmp.<pid>` | `drop --prune` staging (the pid is the server binary's), checked against the payload's size and sha256 before it is written | — | YAML | `644` | `deploy` | *transient*: renamed; a failed write or rename is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<apps>/mail/*.yml.tmp.<pid>` | `server init --with-mail` (`compose.yml`, `kasbah.yml`) and `add-mail-domain` (`kasbah.yml`) staging (the pid is the server binary's) | — | as the file | `644` | `deploy` | *transient*: renamed; a failed write is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<apps>/mail/.env` | `server init --with-mail`: created, then kasbah's three keys merged and every other line kept | docker compose, the backup container, `add-mail-domain`, `server destroy` | KEY=VALUE → `server-setup.md` (With mail, Idempotency rules) | `600` | `deploy` | mode enforced every run; `server destroy` keeps only the three keys (rewritten at `600`) | `internal/mail/remote.go:299,306,313`, `internal/destroy/remote.go:528` |
| `<apps>/mail/.env.tmp.<pid>` | `server init` staging (the pid is the server binary's) | — | KEY=VALUE | `600` | `deploy` | *transient*: renamed; a failed write is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<apps>/mail/.env.tmp.<pid>` | `server destroy` staging, beside the file a symlinked `.env` resolves to | — | KEY=VALUE | `600` | `deploy` | *transient*: renamed only once written whole; a failed write is removed and the file left as it was; a hard kill leaves it | `internal/remote/install.go:13`, through `internal/destroy/remote.go:403` |

### `<apps>/<project>/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/<project>` | `deploy`, `rollback`, `deploy X.Y.Z` (`kasbah remote deploy prepare`, `mkdir -p`); `env` (`kasbah remote setup-env prepare`) | everything per project | directory → `build-deploy.md` (deploy Flow) | umask | `deploy` | removed by `drop --prune` | `internal/deploy/remote.go:59`, `internal/drop/remote.go:389` |
| `<apps>/<project>/<path>` | `deploy`, `rollback`, `deploy X.Y.Z`: every `sync:` target, `kasbah remote sync` with `rsync -rlpt`'s semantics, no `--delete` | compose, the project | the project's → `project-manifest.md` (`sync`) | the source's (`-p`) | `deploy` | overwritten every run; never pruned of files the list stopped naming; removed by `drop --prune` | `internal/deploy/session.go:67`, `internal/deploy/tagged.go:168`, through `internal/treesync/recv.go:439` (files), `:332` (symlinks) |
| `<apps>/<project>/**/.kasbah-sync.<pid>.*` | `deploy`, `rollback`, `deploy X.Y.Z`, `env`: the sync's staging (`kasbah remote sync`; the pid is the server binary's), one file or symlink at a time, beside its target | — | as the file | `600`, then the source's | `deploy` | *transient*: renamed over the target once its size and sha256 check; removed on a failed check, a cut stream, a dropped session (the step ignores SIGHUP) and SIGINT/SIGTERM; a hard kill leaves it | `internal/treesync/recv.go:381` (files), `:325` (symlinks), cleanup `:80` |
| `<apps>/<project>/compose.yml` | the conventional `sync:` target (`compose.prod.yml -> compose.yml`) | compose, `kasbah remote deploy`, `logs`, `exec`, `server prune`, `drop` | compose → `build-deploy.md` (deploy Flow) | the source's | `deploy` | as `sync:`; kept by `server destroy` | `internal/deploy/session.go:67` |
| `<apps>/<project>/.env.prod.example` | the conventional `sync:` target; `env` ships it alone | the drift report (`kasbah remote setup-env drift`) | text → `env-template.md` | the source's | `deploy` | as `sync:` | `internal/deploy/session.go:67`, `internal/env/session.go:76` |
| `<apps>/<project>/.env` | the interactive setup (`kasbah env`, `deploy`, `rollback`, `deploy X.Y.Z`: `kasbah remote setup-env setup`), renamed over the file, or over a symlink's target; the `KASBAH_*` managed block on every `deploy`, `rollback`, `env` | compose, the drift report (`kasbah remote setup-env drift`), the backup container | KEY=VALUE → `env-template.md` | `600` | `deploy` | `server destroy` strips the sentinel comments only; removed by `drop --prune` | `internal/env/setup.go:469`, `internal/env/inject.go:162` (whatever the umask; a file that existed keeps its mode) |
| `<apps>/<project>/.env.tmp.<pid>` | `server destroy` stripping the sentinels: beside the resolved target, so a symlinked `.env` puts it beside the link's target | — | KEY=VALUE | the original's | `deploy` | *transient*: renamed only once written whole; a failed write is removed; the step ignores SIGHUP, so a dropped session does not cut it short; a hard kill leaves a copy of the secrets | `internal/remote/install.go:13`, through `internal/destroy/remote.go:403` |
| `<apps>/<project>/.env.kasbah-inject.<pid>` | the managed-block rewrite's staging | — | KEY=VALUE | the original's (`chmod --reference`) | `deploy` | *transient*: renamed; a kill leaves it | `internal/env/inject.go:158` |
| `<apps>/<project>/.env.kasbah-setup.<pid>` | `kasbah env`'s setup staging, beside the symlink-resolved target | — | KEY=VALUE | `600`, then the original's | `deploy` | *transient*: renamed; removed on a signal (atexit), a SIGKILL leaves it | `internal/env/setup.go:469` |
| `<apps>/<project>/scripts` | written by kasbah before Phase 10.8 (the Bash `deploy`, `rollback`, `deploy X.Y.Z`); nothing creates it now | — | directory → `build-deploy.md` (Helper scripts) | umask | `deploy` | `rmdir` by `server destroy` once its two scripts are gone; removed by `drop --prune` | `internal/destroy/remote.go:492` |
| `<apps>/<project>/scripts/remote-deploy.sh` | written by kasbah before Phase 10.8 (rendered per deploy and rollback); the engine is `kasbah remote deploy` now | nothing | bash → `build-deploy.md` (Helper scripts) | `755` | `deploy` | removed by `server destroy`, `drop --prune` | `internal/destroy/remote.go:492` |
| `<apps>/<project>/scripts/setup-env.sh` | written by kasbah before Phase 10.8 (a copy of `lib/env.sh`); the env setup is `kasbah remote setup-env` now | nothing | bash → `build-deploy.md` (Helper scripts) | `755` | `deploy` | as `remote-deploy.sh` | `internal/destroy/remote.go:492` |
| `<apps>/<project>/.kasbah-client` | `deploy`, when the value changes (temp + rename) | the backup container | one word → `project-manifest.md` (`client`), `backup.md` (Repos) | `644` | `deploy` | removed by `server destroy`, `drop --prune` | `internal/remote/install.go:13`, through `internal/deploy/remote.go:74` |
| `<apps>/<project>/.kasbah-client.tmp.<pid>` | its staging | — | one word | `644` | `deploy` | *transient*: renamed only once written whole; a failed write is removed; the step ignores SIGHUP, so a dropped session does not cut it short; a hard kill leaves it, and destroy does not remove it | `internal/remote/install.go:13`, through `internal/deploy/remote.go:74` |
| `<apps>/<project>/versions.log` | `kasbah remote deploy` (`internal/vlog`): one line per successful deploy or rollback, then rotation | `rollback`, `history`, `pending`, `changelog`, `server prune`, `server status`, the remote preflight | text → `build-deploy.md` (`versions.log` format) | umask at creation, then kept across rotation | `deploy` | appended every run; removed by `server destroy`, `drop --prune` | `internal/vlog/vlog.go:99`, rotation `:197`, mode `:278` |
| `<apps>/<project>/versions.log.gz` | rotation: a gzip member appended per rotation | `history --all`, `rollback` | gzip'd lines → `build-deploy.md` (Rotation) | a new archive copies the log's; an existing one keeps its own | `deploy` | grows only; removed by `server destroy`, `drop --prune` | `internal/vlog/vlog.go:256` |
| `<apps>/<project>/.versions.log.*` | rotation scratch: `.keep`, `.drop`, `.part` | — | text | umask | `deploy` | *transient*: removed on every return path; a kill leaves them, and destroy does not remove them | `internal/vlog/vlog.go:200` |
| `<apps>/<project>/.deploy.lock` | `kasbah remote deploy` (`O_TRUNC` open, then `flock(2)`), for `deploy`, `rollback` and `deploy X.Y.Z`; `drop` takes the same lock in its act (the same `O_TRUNC` open and `flock(2)`) | `drop` (probed read-only in its plan) | empty → `build-deploy.md` (The outgoing stack) | umask | `deploy` | truncated every run, never deleted by it; removed by `server destroy`, `drop --prune` | `internal/deploy/engine.go:246`, `internal/drop/remote.go:309`, destroy `internal/destroy/remote.go:505` |
| `<apps>/<project>/backups` | `deploy` | the backup hook | directory → `project-manifest.md` (`backup`) | umask | `deploy` | kept by `drop` and `server destroy`; removed by `drop --prune` | `internal/deploy/remote.go:59` |
| `<apps>/<project>/backups/pre-deploy-*` | `deploy`'s backup hook (`.partial`, then `mv`); never `rollback` | `$DEPLOY_BACKUP`, `versions.log` field 4, the backup container | the hook's output → `project-manifest.md` (`backup`) | umask | `deploy` | rotated to `retain` per run (current extension only); SIGINT or SIGTERM removes a `*.partial`, a dropped session (SIGHUP, SIGPIPE) does not stop the dump, a SIGKILL leaves it; removed by `drop --prune` | `internal/deploy/engine.go:422`, rotation `:497` |

### `<data>/` and `<apps>/backups/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<data>` | `server init` | every bind mount | directory → `server-setup.md` (What init creates) | umask | `deploy` | never removed | `internal/serverinit/remote.go:126` |
| `<data>/traefik` | `server init` | — | directory | umask | `deploy` | never removed | `internal/serverinit/remote.go:126` |
| `<data>/traefik/letsencrypt` | `server init` | — | directory | umask | `deploy` | never removed | `internal/serverinit/remote.go:126` |
| `<data>/traefik/letsencrypt/acme.json` | `server init` (`touch` when absent; `chmod 600` every run); Traefik writes it in place | Traefik, DMS, `check --server`, `server status`, `upgrade-traefik` | Traefik's ACME store → `server-setup.md` (The ACME endpoint), `traefik.md` (TLS) | `600` | `deploy` | never removed, never replaced: a CA-switch reset, run inside the Traefik start with the old Traefik stopped, copies it to the archive and empties it in place, so the inode DMS's file bind mount holds is the live store | `internal/serverinit/remote.go:139`, reset `:168` |
| `<data>/traefik/letsencrypt/acme.json.<stamp>` | `server init` on a CA switch with reset: a copy (`O_EXCL`, synced) of the store, never over an existing archive | — | an archived store → `server-setup.md` (When the store is reset) | `600` | `deploy` | never removed; a copy that did not finish is removed | `internal/serverinit/remote.go:195` |
| `<data>/mail` | `server init --with-mail` | — | directory | umask | `deploy` | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms` | `server init --with-mail` | — | directory | umask | `deploy` | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/mail-data` | `server init --with-mail`; filled by DMS | DMS | directory → `server-setup.md` (What init creates) | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/mail-state` | as above | DMS | directory | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/mail-logs` | as above | DMS | directory | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/config` | as above | DMS | directory | umask | `deploy` | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/config/rspamd` | as above | DMS | directory | umask | `deploy` | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/config/rspamd/override.d` | as above | DMS | directory | umask | `deploy` | never removed | `internal/mail/remote.go:286` |
| `<data>/mail/dms/config/rspamd/override.d/dkim_signing.conf` | `server init --with-mail`, when absent; never rewritten | DMS (Rspamd) | Rspamd conf → `mail.md` (Pre-seeding) | `644` | `deploy` | never removed | `internal/mail/remote.go:346` |
| `<data>/mail/dms/config/fail2ban-jail.cf` | `server init --with-mail`, when its bytes differ (kasbah-owned) | DMS: copied to `/etc/fail2ban/jail.d/user-jail.local` at its start, and by the start step into a running DMS before `fail2ban-client reload` | Fail2ban jail → `mail.md` (Webmail) | `644` | `deploy` | rewritten when it differs; never removed | `templates/mail/fail2ban-jail.cf` |
| `<data>/mail/dms/config/postfix-accounts.cf` | `server init --with-mail`, when it holds no account (absent, empty, or blank and comment lines only); never rewritten by kasbah | DMS | one `address` and `{SHA512-CRYPT}` hash per line → `mail.md` (Pre-seeding) | `600` | `deploy` | kept by `server destroy` | `internal/mail/remote.go:326` |
| `<data>/mail/dms/config/postfix-virtual.cf` | `add-mail-domain` (append) | DMS | alias lines → `mail.md` (Multi-domain support) | umask if created | `deploy` | never removed (`drop --prune` prints the `setup alias del` line instead) | `internal/mail/remote.go:182` |
| `<data>/mail/dms/config/*` | DMS at start (e.g. `dovecot-quotas.cf`) | DMS | DMS's | DMS's | DMS's (root) | never removed | — (not kasbah's code) |
| `<data>/mail/dms/config/**/*.tmp.<pid>` | the two seeds' staging | — | as the seed | `600`/`644` | `deploy` | *transient*: renamed; a failed write is removed, a hard kill leaves it | `internal/remote/install.go:13` |
| `<data>/mail/cypht` | `server init --with-mail` makes the directory and sets `755` while it is still the deploy user's; Cypht's entrypoint wrapper hands it to `www-data` and fills it | Cypht | directory → `mail.md` (Webmail) | `755` | `www-data` (33) after the first start | never removed | `internal/mail/remote.go` (layout) |
| `<data>/mail/cypht/cypht.sqlite` | the compose entrypoint wrapper (`touch`, `chown`), then Cypht's entrypoint creates the schema | Cypht (`brute_force`) | SQLite → `mail.md` (Webmail): failed-login counts only | `644` | `www-data` (33) | never removed | `templates/mail/compose.yml` |
| `<data>/mail/cypht/{users,attachments}/**` | Cypht: `users/<address>.txt` when a user saves settings, attachments while composing | Cypht | encrypted settings → `mail.md` (Webmail) | `755` dirs, `644` files | `www-data` (33) | never removed | — (not kasbah's code) |
| `<data>/<project>` | `deploy` (`mkdir -p`) | the project's bind mounts | directory → `build-deploy.md` (deploy Flow) | umask | `deploy` | kept by `drop` and `server destroy`; removed by `drop --prune` | `internal/deploy/remote.go:59`, `internal/drop/remote.go:388` |
| `<apps>/backups` | `server init` | — (operator's) | directory → `server-setup.md` (What init creates) | umask | `deploy` | never removed (`drop --prune` included) | `internal/serverinit/remote.go:126` |

### Outside the apps path

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `/tmp/kasbah-apps-path.<pid>` | `server init`: the pointer's unprivileged stage | `sudo cp` | one path | umask | `deploy` | *transient*: removed after the copy | `internal/serverinit/run.go:142` |
| `$TMPDIR/kasbah-dry-run.*/**` (default `/tmp`) | `server upgrade-traefik`, in the server binary: the candidate `traefik.yml` and `_shared.yml` for the dry-run container | the dry-run container | YAML (the static file as JSON, which Traefik reads as YAML) | dir `700`; files `644` | `deploy` | *transient*: removed on return and on HUP/INT/TERM | `internal/upgrade/remote.go:220` |
| `/tmp/kasbah-backup-probe.*/**` | `server init --with-backup`: the delete-probe's scratch — `src/probe.txt`, `pass`, `env` (the storage credential) — in the server binary's `$TMPDIR` | the probe's restic containers | restic environment → `backup.md` (Credentials) | dir `700`; `pass`, `env` `600` | `deploy` | *transient*: removed when the probe returns and by the signal handlers (SIGHUP and SIGPIPE are ignored), with every probe container it named (`kasbah-probe-<pid>-<n>`, `docker rm -f`); SIGKILL leaves it | `internal/backup/remote.go:317`, cleanup `:330` |

## Docker objects

| Object | Writer | Readers | Spec | Lifecycle | Code |
|---|---|---|---|---|---|
| network `kasbah-net` | `server init` (the Traefik compose file's fixed-name network) | Traefik, every routed service, the mail stack (external) | `server-setup.md` (Network), `traefik.md` (Network) | never removed | `templates/traefik/compose.yml` |
| compose project `traefik` | `server init`, `upgrade-traefik` | — | `traefik.md` | kept by `server destroy` | `templates/traefik/compose.yml` |
| compose project `mail` (`mail-dms`, `mail-cypht`) | `server init --with-mail` | — | `mail.md` (Components) | kept by `server destroy` | `templates/mail/compose.yml` |
| compose project `kasbah-backup` (container, network `kasbah-backup_default`, volume `kasbah-backup-cache`) | `server init --with-backup` | — | `backup.md` (The schedule) | all three removed by `server destroy` — the one container destroy stops | `templates/backup/compose.yml`, `internal/destroy/remote.go:455` |
| compose project `<project>` | `deploy`, `rollback` (`compose up -d --remove-orphans`) | — | `build-deploy.md` (deploy Flow) | `drop` downs it (no `-v`); kept by `server destroy` | `internal/deploy/engine.go:202` |
| image `<image>:<version>` | `build-push` (`docker load`) | the remote preflight, `rollback` | `build-deploy.md` (Image tags on the VPS) | removed by `server prune` (outside 3 versions + 3 months) and `drop` (every tag of a repository only this project declares) | `internal/buildpush/load.go:50` |
| image `<image>:current` | `deploy`, `rollback` (retag before `compose up`) | compose | `build-deploy.md` (Image tags on the VPS) | moved every run; never pruned; removed by `drop` | `internal/deploy/engine.go:555` |
| container `kasbah-traefik-dry-run-<stamp>` | `server upgrade-traefik` (`--network none`, label `kasbah.role=traefik-dry-run`) | — | `traefik.md` (Upgrading Traefik) | *transient*: its trap; leftovers swept by label on the next run | `internal/upgrade/remote.go:233` |

Containers are compose's, named by the projects' own compose files, and so are
a project's own networks (`<project>_<name>`) and the anonymous volumes its
images declare. Stock
images (`traefik:<tag>`, the mail images, `restic/restic`) are pulled, never
removed.
