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
| `<project-dir>/kasbah.yml` | `init-project`; `check --fix` (temp + rename) | every project command | YAML → `project-manifest.md` | umask on create; `--fix` keeps the original's (`chmod --reference`) | `deploy` | never removed by kasbah | `lib/init_project.sh:119`, `lib/check_fix.sh:1188` |
| `<project-dir>/compose.prod.yml` | `check --fix` (edits, never creates) | `build-push`, `deploy`, `check` | YAML → `compliance.md` (`--fix`) | the original's | `deploy` | never removed | `lib/check_fix.sh:1188` |
| `<project-dir>/*.kasbah-fix.<pid>` | `check --fix` staging, one per file fixed | `diff`, the re-plan | YAML candidate | `600`, then the original's | `deploy` | *transient*: renamed or removed by the EXIT trap; SIGKILL leaves it | `lib/check_fix.sh:1119`, trap `:1244` |
| `<project-dir>/.env.prod.example` | `init-project` | `env`, `check`, the deploy sync | text → `env-template.md` | umask | `deploy` | created once, never rewritten | `lib/init_project.sh:140` |
| `<project-dir>/.gitignore` | `init-project` appends `.env` and `.kasbah/` | `check` S05/S06 | text | umask if created | `deploy` | never removed | `lib/init_project.sh:153` |
| `<project-dir>/.git/**` | `rollback`, `deploy X.Y.Z`: `git fetch --tags` when the tag is missing | git | git's | git's | `deploy` | git's; not otherwise kasbah's | `lib/rollback.sh:261` |

`deploy` in this table is the invoking user.

### `.kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<project-dir>/.kasbah` | `init-project`; `mkdir -p` by every state write | — | directory | umask | `deploy` | never removed (`drop --prune` and `server destroy` included) | `lib/init_project.sh:88`, `lib/state.sh:16,66` |
| `<project-dir>/.kasbah/state.json` | created by `init-project`; merged by `build-push`, `deploy`, `rollback`, `env`, `history`, `pending`, `changelog`, `logs`, `exec`, `check --server`, `drop` | every server-targeting command (`last_server`) | JSON → `project-manifest.md` (State file) | umask — each merge re-creates the file | `deploy` | rewritten on success only; never removed | `lib/state.sh:14,53` |
| `<project-dir>/.kasbah/state.json.tmp.<pid>` | the merge's staging | — | JSON | umask | `deploy` | *transient*: renamed into place; a kill between render and `mv` leaves it | `lib/state.sh:88` |

### The invoking user's home

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `~/.docker/**` | docker's buildx, during `build-push`'s `docker compose build` — not kasbah's code | docker | buildx state | docker's | `deploy` | docker's; never removed by kasbah | `lib/build_push.sh:204` |

ssh may add to `~/.ssh/known_hosts` as the user's own ssh config says; kasbah
writes nothing under `~/.ssh`.

### Temporary files

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<tmp>/kasbah-ssh.*` | every command that reaches a server, Bash or Go (`__ensure-server`) | ssh, rsync (`ControlPath`) | directory → `build-deploy.md` (SSH multiplexing) | `700` | `deploy` | *transient*: removed on every exit path by the EXIT trap (Go: the `internal/atexit` stack, SIGINT/SIGTERM/SIGHUP included); SIGKILL leaves it and a master living `ControlPersist` | `lib/ssh.sh:130`, chmod `:134`, cleanup `:61`; `internal/ssh/ssh.go:116`, cleanup `:260` |
| `<tmp>/kasbah-ssh.*/m*` | ssh's ControlMaster | ssh, rsync | Unix socket | ssh's | `deploy` | *transient*, with its directory | `lib/ssh.sh:145`, `internal/ssh/ssh.go:94` |
| `<tmp>/<project>-<version>.tar.gz` | `build-push` (`docker save` piped to `gzip`; a fixed name, not mktemp) | `ssh_rsync` | gzip'd docker image tar → `build-deploy.md` (build-push) | umask | `deploy` | *transient*: EXIT trap; SIGKILL leaves it; not made with `--build-only` | `lib/build_push.sh:229`, trap `:309` |
| `<tmp>/kasbah-remote-deploy.*` | `deploy`, `rollback`, `deploy X.Y.Z`: the rendered `remote-deploy.sh` | `ssh_rsync` | bash → `build-deploy.md` (Helper scripts) | `600` | `deploy` | *transient*: EXIT trap | `lib/deploy.sh:758`, `lib/remote_deploy.sh:313`, trap `lib/deploy.sh:772` |
| `<tmp>/kasbah-rollback.*/**` | `rollback`: the tag's tree from `git archive` | manifest and compose readers, the project sync | git tree export | dir `700`; files umask or tar's | `deploy` | *transient*: EXIT trap | `lib/rollback.sh:412`, trap `:480` |
| `<tmp>/kasbah-deploy.*/**` | `deploy X.Y.Z`: as above | as above | git tree export | dir `700`; files umask or tar's | `deploy` | *transient*: EXIT trap | `lib/rollback.sh:412` |
| `<tmp>/kasbah-lstree.*` | `rollback`, `deploy X.Y.Z` | the extraction check | NUL-separated `git ls-tree` | `600` | `deploy` | *transient*: EXIT trap | `lib/rollback.sh:366` |
| `<tmp>/kasbah-traefik.*/**` | `server init`: every rendered file before it ships — Traefik, mail, backup (`env` and `repos/*.pass` hold secrets) | byte comparisons, `ssh_rsync` | the shipped files' formats | dir `700`; files `644`, `backup.sh` `755`, `env`/`repos/` `600`/`700` | `deploy` | *transient*: EXIT trap; SIGKILL leaves the restic passwords | `lib/server_init.sh:2018,1978`, `lib/backup.sh:759`, trap `lib/server_init.sh:2933` |
| `<tmp>/kasbah-upgrade.*/**` | `server upgrade-traefik`: the three Traefik files and `dry-run.yml` | comparisons, `ssh_rsync` | YAML → `traefik.md` (Upgrading) | dir `700`; files `644`, `dry-run.yml` umask | `deploy` | *transient*: EXIT trap | `lib/upgrade_traefik.sh:510`, trap `:487` |
| `<tmp>/kasbah-mail.*/**` | `server add-mail-domain`: the re-rendered registry | `cat` into the remote step | YAML → `mail.md` | dir `700`; file `644` | `deploy` | *transient*: EXIT trap | `lib/server_mail.sh:408`, trap `:56` |
| `<tmp>/kasbah-drop.*/**` | `drop --prune` of a mail claim: the re-rendered registry | `cat` into the remote step | YAML → `mail.md` | dir `700` | `deploy` | *transient*: EXIT trap | `lib/drop.sh:779`, trap `:1297` |
| `<tmp>/kasbah-drop-mail.*` | `drop`: the registry reader's stderr | `sed` | text | `600` | `deploy` | *transient*: `rm -f`, no trap — an interrupt leaves it | `lib/drop.sh:806` |
| `<tmp>/kasbah-destroy-marker.*` | `server destroy`: the marker read's stderr | `sed` | text | `600` | `deploy` | *transient*: `rm -f`, no trap | `lib/server_destroy.sh:181` |
| `<tmp>/kasbah-backup-prune.*/**` | `server backup-prune`: `pw/<repo>.pass`, `env/<repo>.env` | `docker run` restic (`--env-file`, `/pw` mount) | password files; KEY=VALUE → `backup.md` (Credentials) | dirs `700`; files `600` | `deploy` | *transient*: EXIT trap; SIGKILL leaves the credentials | `lib/backup.sh:1526`, trap `:1564` |

Outside these, the local docker daemon keeps what `build-push` builds
(`<image>:<version>`) and the restic image `backup-prune` runs; kasbah removes
neither.

## On a VPS

### `/etc/kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `/etc/kasbah` | `server init` (`sudo mkdir -p`, `chmod 755` when the pointer is written) | every pointer read | directory → `server-setup.md` (discovery pointer) | `755` | `root:root` | removed by `server destroy` once empty | `lib/server_init.sh:1235` |
| `/etc/kasbah/apps-path` | `server init`, last, after the marker; staged, `cp`, `chown 0:0`, `chmod 644`, `mv` | every project command (`lib/marker.sh:108`), `server status`, `server destroy` | one absolute path → `server-setup.md` (discovery pointer) | `644` | `root:root` | rewritten when its content or mode/uid differs; removed by `server destroy` (sudo) | `lib/server_init.sh:1240`, destroy `lib/server_destroy.sh:1235` |
| `/etc/kasbah/apps-path.tmp.<pid>` | `server init` staging | — | as above | root's umask, then `644` | `root:root` | *transient*: renamed; a failure after the `cp` leaves it, and destroy's `rmdir` then keeps `/etc/kasbah` | `lib/server_init.sh:1233` |

### `<apps>/.kasbah/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>` | `server init` (`sudo mkdir`, `chown` to the deploy user) when absent | everything | directory → `server-setup.md` (Who creates the apps path) | root's umask, never chmodded | `deploy` | never removed | `lib/server_init.sh:1321` |
| `<apps>/.kasbah-write-probe` | `server init` preflight, when `<apps>` is the user's but not writable | — | empty | — | `deploy` | *transient*: `rm -f` straight after | `lib/server_init.sh:786` |
| `<apps>/.kasbah` | `server init` | — | directory → `server-setup.md` (What init creates) | umask | `deploy` | `rmdir` by `server destroy`, so any stray file keeps it | `lib/server_init.sh:1328`, `lib/server_destroy.sh:1208` |
| `<apps>/.kasbah/server.json` | `server init`, every run that changes its bytes (merge, never replace) | every server-targeting command, `server status`, `server prune`, `check --server` | JSON → `server-setup.md` (Server marker) | `644` | `deploy` | not touched by `upgrade-traefik`; removed by `server destroy` | `lib/server_init.sh:1372`, `lib/server_destroy.sh:1204` |
| `<apps>/.kasbah/server.json.tmp.<pid>` | `server init` staging | — | JSON | `644` | `deploy` | *transient*: renamed; a failed `mv` leaves it | `lib/server_init.sh:1385` |
| `<apps>/.kasbah/bin` | the Go binary's server step — `__ensure-server` now, every Go command that reaches a server from 10.6 on — in the upload (`mkdir -p` at umask `022`); `--apps-path` (server init's bootstrap) creates it before any marker exists | — | directory → `phases/10-recast.md` (Rulings: one shared binary path) | `755` | `deploy` | never rewritten; the Bash `server destroy` does not remove it, so its `rmdir` keeps `<apps>/.kasbah` too (10.12 adds it) | `internal/serverbin/serverbin.go:548` |
| `<apps>/.kasbah/bin/kasbah` | `kasbah remote install-self`, run by a verified upload under `.lock`: renamed over the binary only when that is still absent, not runnable (not executable, not an ELF for this machine, exit 126 off a noexec mount, 127) or older — never the same build or newer (newer-wins), so racing installs end on the newest | every `kasbah remote …` call; the workstation's probe (`remote version`, bounded at 30 s) | static linux ELF, the workstation's own build for the server's `uname -m` | `755` | `deploy` | replaced by rename only, so a process running the old one keeps its inode; as its directory | `internal/serverbin/install.go:72` |
| `<apps>/.kasbah/bin/.lock` | `kasbah remote install-self` (`flock`, held across the re-check and the rename) | every install | empty lock file | `644` | `deploy` | created once, never removed by a run; as its directory | `internal/serverbin/install.go:37` |
| `<apps>/.kasbah/bin/.kasbah.*` | the upload (`set -C`, never over an existing file) | its own `remote version` check, then `install-self` | as `kasbah` | umask `022`, then `755` | `deploy` | *transient*: renamed over `kasbah` by `install-self`, else removed — by the run on any refusal or exit path (signals included), by the upload's own trap on SIGHUP/INT/TERM/PIPE or a short read; SIGKILL can leave it, and every later upload sweeps those older than 60 min | `internal/serverbin/serverbin.go:546`, trap `:551`, sweep `:549` |
| `<apps>/.kasbah/backup` | `server init --with-backup` (`chmod 700` every run) | — | directory → `server-setup.md` (With backup) | `700` | `deploy` | removed whole by `server destroy` | `lib/backup.sh:855`, `lib/server_destroy.sh:982` |
| `<apps>/.kasbah/backup/compose.yml` | `server init --with-backup`, when its bytes differ | docker compose (`kasbah-backup`) | compose → `backup.md` (The schedule) | `644` | `deploy` | as its directory | `lib/backup.sh:1207` |
| `<apps>/.kasbah/backup/backup.sh` | `server init --with-backup`, when its bytes differ | the backup container | POSIX sh → `backup.md` (The schedule) | `755` | `deploy` | as its directory | `lib/backup.sh:1207` |
| `<apps>/.kasbah/backup/env` | `server init --with-backup`, when it differs | the backup container, the init probe | KEY=VALUE → `backup.md` (Credentials) | `600` | `deploy` | rewritten (and its mode set) only when its bytes differ, before the probe — a refused run leaves it; as its directory | `lib/backup.sh:879` |
| `<apps>/.kasbah/backup/repos` | `server init --with-backup` | — | directory | `700` | `deploy` | as its directory | `lib/backup.sh:855` |
| `<apps>/.kasbah/backup/repos/<repo>.pass` | `server init --with-backup`, for a repository it has not seen; never rewritten | the backup container, `backup-prune` (over ssh) | one password → `backup.md` (Credentials) | `600` | `deploy` | as its directory | `lib/backup.sh:886` |
| `<apps>/.kasbah/backup/state` | `server init --with-backup` | — | directory | `700` | `deploy` | as its directory | `lib/backup.sh:855` |
| `<apps>/.kasbah/backup/state/*` | the backup container (`backup.sh`): the run record, temp + rename | its healthcheck, `server status`, `check --server` | → `backup.md` (The schedule), `server-setup.md` (With backup) | the container's umask | the container's root | rewritten every run; as its directory | `templates/backup/backup.sh:92` |

### `<apps>/traefik/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/traefik` | `server init` | — | directory | umask | `deploy` | never removed | `lib/server_init.sh:1328` |
| `<apps>/traefik/compose.yml` | `server init` when its bytes differ; `upgrade-traefik` | docker compose (`traefik`), `server init` re-runs | compose → `server-setup.md` (Traefik stack) | `644` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2083`, `lib/upgrade_traefik.sh:925` |
| `<apps>/traefik/traefik.yml` | as above | Traefik, `server init` re-runs (baked values read back) | YAML → `server-setup.md` (`traefik.yml`), `traefik.md` (TLS) | `644` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2083` |
| `<apps>/traefik/dynamic` | `server init` | Traefik's file provider | directory → `traefik.md` (Why file provider) | umask | `deploy` | never removed | `lib/server_init.sh:1328` |
| `<apps>/traefik/dynamic/_shared.yml` | as `compose.yml` | Traefik, `check --server`, `server status` | YAML → `server-setup.md` (`dynamic/_shared.yml`), `traefik.md` (Middlewares) | `644` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2083` |
| `<apps>/traefik/dynamic/_mail.yml` | `server init --with-mail`, when its bytes differ | Traefik | YAML → `traefik.md` (Discovery), `mail.md` (TLS flow) | `644` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2767` |
| `<apps>/traefik/dynamic/<project>.yml` | `deploy` (shipped last), `rollback` (the tag's copy) | Traefik, `drop`, `server status` | YAML → `traefik.md` (Project fragment) | `644` | `deploy` | rewritten each run that has a fragment; removed by `drop`; kept by `server destroy` | `lib/deploy.sh:822`, `lib/rollback.sh:580`, `lib/drop.sh:1016` |
| `<apps>/traefik/backups/<stamp>/**` | `server upgrade-traefik`: the three files (`cp -p`) and a `kasbah-upgrade` note | its own rollback on a failed start | copies → `traefik.md` (Upgrading Traefik) | dir umask; copies keep `644` | `deploy` | never removed | `lib/upgrade_traefik.sh:902` |

### `<apps>/mail/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/mail` | `server init --with-mail` | `add-mail-domain` | directory → `server-setup.md` (With mail) | umask | `deploy` | kept by `server destroy` | `lib/server_init.sh:2622` |
| `<apps>/mail/compose.yml` | `server init --with-mail`, when its bytes differ | docker compose (`mail`) | compose → `mail.md` (Components) | `644` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2767` |
| `<apps>/mail/kasbah.yml` | `server init --with-mail`; `add-mail-domain`; `drop --prune` of a claim | `deploy`, `drop`, `add-mail-domain`, `check --server`, `server status` | YAML → `mail.md` (Multi-domain support) | `644` | `deploy` | removed by `server destroy` | `lib/server_init.sh:2767`, `lib/server_mail.sh:331`, `lib/drop.sh:1063`, `lib/server_destroy.sh:1189` |
| `<apps>/mail/.kasbah.yml.<pid>` | `add-mail-domain`, `drop --prune` staging | — | YAML | umask, then `644` | `deploy` | *transient*: renamed; a failed write leaves it | `lib/server_mail.sh:333`, `lib/drop.sh:1062` |
| `<apps>/mail/.env` | `server init --with-mail`: created, then kasbah's three keys merged and every other line kept | docker compose, the backup container, `add-mail-domain`, `server destroy` | KEY=VALUE → `server-setup.md` (With mail, Idempotency rules) | `600` | `deploy` | mode enforced every run; `server destroy` keeps only the three keys | `lib/server_init.sh:2630,2694`, `lib/server_destroy.sh:1122` |
| `<apps>/mail/.env.tmp.<pid>` | `server init` staging | — | KEY=VALUE | `600` | `deploy` | *transient*: renamed | `lib/server_init.sh:2681` |
| `<apps>/mail/.env.kasbah-destroy.<pid>` | `server destroy` staging (`umask 077`, `chmod 600`) | — | KEY=VALUE | `600` | `deploy` | *transient*: renamed | `lib/server_destroy.sh:1126,1129` |

### `<apps>/<project>/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<apps>/<project>` | `deploy` (`mkdir -p`); `env` | everything per project | directory → `build-deploy.md` (deploy Flow) | umask | `deploy` | removed by `drop --prune` | `lib/deploy.sh:644`, `lib/env_cmd.sh:478`, `lib/drop.sh:1087` |
| `<apps>/<project>/<path>` | `deploy`, `rollback`, `deploy X.Y.Z`: every `sync:` target, rsync `-rlpt`, no `--delete` | compose, the project | the project's → `project-manifest.md` (`sync`) | the source's (`-p`) | `deploy` | overwritten every run; never pruned of files the list stopped naming; removed by `drop --prune` | `lib/deploy.sh:724`, `lib/rollback.sh:769` |
| `<apps>/<project>/compose.yml` | the conventional `sync:` target (`compose.prod.yml -> compose.yml`) | compose, `remote-deploy.sh`, `logs`, `exec`, `server prune`, `drop` | compose → `build-deploy.md` (deploy Flow) | the source's | `deploy` | as `sync:`; kept by `server destroy` | `lib/deploy.sh:724` |
| `<apps>/<project>/.env.prod.example` | the conventional `sync:` target; `env` ships it alone | `setup-env.sh` (drift) | text → `env-template.md` | the source's | `deploy` | as `sync:` | `lib/deploy.sh:724`, `lib/env_cmd.sh:512` |
| `<apps>/<project>/.env` | `setup-env.sh` (interactive setup, truncating write); the `KASBAH_*` managed block on every `deploy`, `rollback`, `env` | compose, `setup-env.sh --drift`, the backup container | KEY=VALUE → `env-template.md` | umask when setup creates it; the block rewrite keeps the existing mode | `deploy` | `server destroy` strips the sentinel comments only; removed by `drop --prune` | `lib/env.sh:414,580` |
| `<apps>/<project>/.env.kasbah-destroy.<pid>` | `server destroy` stripping the sentinels: beside the resolved target, so a symlinked `.env` puts it beside the link's target | — | KEY=VALUE | `600`, then the original's | `deploy` | *transient*: renamed; no trap, a dropped session leaves a partial copy of the secrets | `lib/server_destroy.sh:1035` |
| `<apps>/<project>/.env.kasbah-inject.<pid>` | the managed-block rewrite's staging | — | KEY=VALUE | the original's (`chmod --reference`) | `deploy` | *transient*: renamed; a kill leaves it | `lib/env.sh:580` |
| `<apps>/<project>/scripts` | `deploy`; `env` | — | directory → `build-deploy.md` (Helper scripts) | umask | `deploy` | `rmdir` by `server destroy` once its two scripts are gone; `drop --prune` | `lib/deploy.sh:644` |
| `<apps>/<project>/scripts/remote-deploy.sh` | `deploy`, `rollback`, `deploy X.Y.Z` (rendered per run) | the deploy's remote step | bash → `build-deploy.md` (Helper scripts) | `755` | `deploy` | rewritten every run; removed by `server destroy`, `drop --prune` | `lib/deploy.sh:762` |
| `<apps>/<project>/scripts/setup-env.sh` | `deploy`, `env` (a copy of `lib/env.sh`) | `env`, the deploy's env step | bash → `build-deploy.md` (Helper scripts) | `755` | `deploy` | as `remote-deploy.sh` | `lib/env_cmd.sh:79` |
| `<apps>/<project>/.kasbah-client` | `deploy`, when the value changes (temp + rename) | the backup container | one word → `project-manifest.md` (`client`), `backup.md` (Repos) | `644` | `deploy` | removed by `server destroy`, `drop --prune` | `lib/deploy.sh:652` |
| `<apps>/<project>/.kasbah-client.tmp.<pid>` | its staging | — | one word | `644` | `deploy` | *transient*: renamed; a kill leaves it, and destroy does not remove it | `lib/deploy.sh:661` |
| `<apps>/<project>/versions.log` | `remote-deploy.sh`: one line per successful deploy or rollback, then rotation | `rollback`, `history`, `pending`, `changelog`, `server prune`, `server status`, the remote preflight | text → `build-deploy.md` (`versions.log` format) | umask at creation, then kept across rotation | `deploy` | appended every run; removed by `server destroy`, `drop --prune` | `templates/remote-deploy.sh:221`, rotation `:277`, mode `:331` |
| `<apps>/<project>/versions.log.gz` | rotation: a gzip member appended per rotation | `history --all`, `rollback` | gzip'd lines → `build-deploy.md` (Rotation) | a new archive copies the log's; an existing one keeps its own | `deploy` | grows only; removed by `server destroy`, `drop --prune` | `templates/remote-deploy.sh:311` |
| `<apps>/<project>/.versions.log.*` | rotation scratch: `.keep`, `.drop`, `.part` | — | text | umask | `deploy` | *transient*: removed on every return path; a kill leaves them, and destroy does not remove them | `templates/remote-deploy.sh:290,339` |
| `<apps>/<project>/.deploy.lock` | `remote-deploy.sh` (`exec 9>` then `flock`); `drop` takes the same lock | `drop` | empty → `build-deploy.md` (The outgoing stack) | umask | `deploy` | truncated every run, never deleted by it; removed by `server destroy`, `drop --prune` | `templates/remote-deploy.sh:377`, `lib/drop.sh:995` |
| `<apps>/<project>/backups` | `deploy` | the backup hook | directory → `project-manifest.md` (`backup`) | umask | `deploy` | kept by `drop` and `server destroy`; removed by `drop --prune` | `lib/deploy.sh:644` |
| `<apps>/<project>/backups/pre-deploy-*` | `deploy`'s backup hook (`.partial`, then `mv`); never `rollback` | `$DEPLOY_BACKUP`, `versions.log` field 4, the backup container | the hook's output → `project-manifest.md` (`backup`) | umask | `deploy` | rotated to `retain` per run (current extension only); a kill leaves `*.partial`; removed by `drop --prune` | `templates/remote-deploy.sh:690`, rotation `:631` |

### `<data>/` and `<apps>/backups/`

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `<data>` | `server init` | every bind mount | directory → `server-setup.md` (What init creates) | umask | `deploy` | never removed | `lib/server_init.sh:1328` |
| `<data>/traefik` | `server init` | — | directory | umask | `deploy` | never removed | `lib/server_init.sh:1328` |
| `<data>/traefik/letsencrypt` | `server init` | — | directory | umask | `deploy` | never removed | `lib/server_init.sh:1328` |
| `<data>/traefik/letsencrypt/acme.json` | `server init` (`touch` when absent; `chmod 600` every run); Traefik writes it in place | Traefik, DMS, `check --server`, `server status`, `upgrade-traefik` | Traefik's ACME store → `server-setup.md` (The ACME endpoint), `traefik.md` (TLS) | `600` | `deploy` | never removed; archived and re-created on a CA switch | `lib/server_init.sh:1336,1346` |
| `<data>/traefik/letsencrypt/acme.json.<stamp>` | `server init` on a CA switch with reset | — | an archived store → `server-setup.md` (When the store is reset) | `600` | `deploy` | never removed | `lib/server_init.sh:2127` |
| `<data>/mail` | `server init --with-mail` | — | directory | umask | `deploy` | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms` | `server init --with-mail` | — | directory | umask | `deploy` | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/mail-data` | `server init --with-mail`; filled by DMS | DMS | directory → `server-setup.md` (What init creates) | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/mail-state` | as above | DMS | directory | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/mail-logs` | as above | DMS | directory | umask, then DMS's | `deploy` at creation, then DMS's | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/config` | as above | DMS | directory | umask | `deploy` | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/config/rspamd` | as above | DMS | directory | umask | `deploy` | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/config/rspamd/override.d` | as above | DMS | directory | umask | `deploy` | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/dms/config/rspamd/override.d/dkim_signing.conf` | `server init --with-mail`, when absent; never rewritten | DMS (Rspamd) | Rspamd conf → `mail.md` (Pre-seeding) | `644` | `deploy` | never removed | `lib/server_init.sh:2718` |
| `<data>/mail/dms/config/postfix-accounts.cf` | `server init --with-mail`, when empty or absent; never rewritten by kasbah | DMS | one `address` and `{SHA512-CRYPT}` hash per line → `mail.md` (Pre-seeding) | `600` | `deploy` | kept by `server destroy` | `lib/server_init.sh:2699` |
| `<data>/mail/dms/config/postfix-virtual.cf` | `add-mail-domain` (append) | DMS | alias lines → `mail.md` (Multi-domain support) | umask if created | `deploy` | never removed (`drop --prune` prints the `setup alias del` line instead) | `lib/server_mail.sh:353` |
| `<data>/mail/dms/config/*` | DMS at start (e.g. `dovecot-quotas.cf`) | DMS | DMS's | DMS's | DMS's (root) | never removed | — (not kasbah's code) |
| `<data>/mail/dms/config/**/*.tmp.<pid>` | the two seeds' staging | — | as the seed | `600`/`644` | `deploy` | *transient*: renamed | `lib/server_init.sh:2710,2727` |
| `<data>/mail/snappymail` | `server init --with-mail` makes the directory; SnappyMail builds `_data_/` and chowns it | SnappyMail | directory → `server-setup.md` (What init creates) | umask, then SnappyMail's (`750`) | `deploy` at creation, then SnappyMail's uid | never removed | `lib/server_init.sh:2622` |
| `<data>/mail/snappymail/_data_/_default_/domains/<domain>.json` | `deploy`, `rollback` of a project with `mail.snappymail_domain`, claim met: `docker cp` into `mail-snappymail` (bind mount `templates/mail/compose.yml:117`), only when absent | SnappyMail | JSON → `mail.md` (Per-app mail claims) | the staged file's (umask) | root — `docker cp` without `-a` | never rewritten; never removed | `lib/deploy.sh:1027,1057` |
| `<data>/<project>` | `deploy` (`mkdir -p`) | the project's bind mounts | directory → `build-deploy.md` (deploy Flow) | umask | `deploy` | kept by `drop` and `server destroy`; removed by `drop --prune` | `lib/deploy.sh:644`, `lib/drop.sh:1078` |
| `<apps>/backups` | `server init` | — (operator's) | directory → `server-setup.md` (What init creates) | umask | `deploy` | never removed (`drop --prune` included) | `lib/server_init.sh:1328` |

### Outside the apps path

| Path | Writer | Readers | Format → spec | Mode | Owner | Lifecycle | Code |
|---|---|---|---|---|---|---|---|
| `/tmp/<project>-<version>.tar.gz` | `build-push` (rsync of the workstation's tarball) | `docker load` | as on the workstation → `build-deploy.md` (build-push) | the workstation file's | `deploy` | *transient*: removed after the load, or by the workstation's EXIT trap; a dropped connection leaves it | `lib/build_push.sh:254`, removal `:273,318` |
| `/tmp/kasbah-apps-path.<pid>` | `server init`: the pointer's unprivileged stage | `sudo cp` | one path | umask | `deploy` | *transient*: removed after the copy | `lib/server_init.sh:1232` |
| `/tmp/kasbah-dry-run.*/**` | `server upgrade-traefik`: the candidate config for the dry-run container | the dry-run container | YAML | dir `700`; files `644` | `deploy` | *transient*: its own EXIT/HUP/INT/TERM trap | `lib/upgrade_traefik.sh:643` |
| `/tmp/tmp.*/**` | `deploy` of a mail claim: the SnappyMail domain seed, before `docker cp` (bare `mktemp -d`) | `docker cp` | JSON → `mail.md` (Per-app mail claims) | dir `700` | `deploy` | *transient*: removed after the copy; a kill leaves it | `lib/deploy.sh:1050` |
| `/tmp/tmp.*/**` | `server init --with-backup`: the delete-probe's scratch — `src/probe.txt`, `pass`, `env` (the storage credential) — bare `mktemp -d` | the probe's restic containers | restic environment → `backup.md` (Credentials) | dir `700`; `pass`, `env` `600` | `deploy` | *transient*: its trap | `lib/backup.sh:967` |

Not a row, because it is not a path kasbah names: rsync's own temp file
(`.<name>.<6 chars>`) beside any destination `ssh_rsync` writes, renamed into
place or deleted on error — only a hard kill leaves one, and in
`<apps>/traefik/dynamic/` Traefik ignores it (it reads `.yml` only).

## Docker objects

| Object | Writer | Readers | Spec | Lifecycle | Code |
|---|---|---|---|---|---|
| network `kasbah-net` | `server init` (the Traefik compose file's fixed-name network) | Traefik, every routed service, the mail stack (external) | `server-setup.md` (Network), `traefik.md` (Network) | never removed | `templates/traefik/compose.yml` |
| compose project `traefik` | `server init`, `upgrade-traefik` | — | `traefik.md` | kept by `server destroy` | `templates/traefik/compose.yml` |
| compose project `mail` (`mail-dms`, `mail-snappymail`) | `server init --with-mail` | — | `mail.md` (Components) | kept by `server destroy` | `templates/mail/compose.yml` |
| compose project `kasbah-backup` (container, network `kasbah-backup_default`, volume `kasbah-backup-cache`) | `server init --with-backup` | — | `backup.md` (The schedule) | all three removed by `server destroy` — the one container destroy stops | `templates/backup/compose.yml`, `lib/server_destroy.sh:936` |
| compose project `<project>` | `deploy`, `rollback` (`compose up -d --remove-orphans`) | — | `build-deploy.md` (deploy Flow) | `drop` downs it (no `-v`); kept by `server destroy` | `templates/remote-deploy.sh` |
| image `<image>:<version>` | `build-push` (`docker load`) | the remote preflight, `rollback` | `build-deploy.md` (Image tags on the VPS) | removed by `server prune` (outside 3 versions + 3 months) and `drop` (every tag of a repository only this project declares) | `lib/build_push.sh:272` |
| image `<image>:current` | `deploy`, `rollback` (retag before `compose up`) | compose | `build-deploy.md` (Image tags on the VPS) | moved every run; never pruned; removed by `drop` | `templates/remote-deploy.sh:767` |
| container `kasbah-traefik-dry-run-<stamp>` | `server upgrade-traefik` (`--network none`, label `kasbah.role=traefik-dry-run`) | — | `traefik.md` (Upgrading Traefik) | *transient*: its trap; leftovers swept by label on the next run | `lib/upgrade_traefik.sh:643` |

Containers are compose's, named by the projects' own compose files, and so are
a project's own networks (`<project>_<name>`) and the anonymous volumes its
images declare. Stock
images (`traefik:<tag>`, the mail images, `restic/restic`) are pulled, never
removed.
