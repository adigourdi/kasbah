# Phase 10 — Recast

> kasbah is a Go binary on the workstation and on every VPS it manages; no
> kasbah Bash remains on either side, and every contract the Bash tool kept —
> files, formats, exit codes, prompts and their flags — holds unchanged.

**Prerequisite:** Phase 8. **Runs before Phase 9**, which now depends on it
(approved 2026-10-18): the two consumers migrate onto the tool they will keep,
not onto one about to be replaced.
**Specs:** every file in `docs/` — this phase re-implements all of them. Owners
per task below; `docs/overview.md` (Key decisions: Language, Distribution,
Version compatibility), `docs/roadmap.md` (Phases 4–5, superseded here),
`docs/project-manifest.md` (state file, `kasbah_version`), `docs/server-setup.md`
(layout, discovery pointer), `docs/cli.md` (the whole surface and its exit codes)
**Retires:** the Bash maintainability ceiling the roadmap predicted, and the
duplicated readers it produced (mail registry ×5, the `versions.log` entry
predicate ×3, path normalisation ×4)

## Rulings (2026-10-18)

- **Strangler.** The Go binary is `kasbah` from 10.1 on; any command it does not
  own yet is handed to the Bash implementation unchanged. Every task leaves the
  full rig suite green, so the tool is usable throughout and stopping between
  tasks is always safe.
- **Go on the VPS too.** The server runs the same binary under hidden
  `kasbah remote …` subcommands. `remote-deploy.sh`, `setup-env.sh` and the ~45
  `ssh_script` heredocs are replaced, not embedded. `lib/env.sh`'s two roles
  (local drift, VPS setup) collapse into one Go implementation.
- **One shared binary path on the VPS**, `<apps>/.kasbah/bin/kasbah`: copied when
  absent or older; when the server's is the **same or newer, it wins**. The
  server binary therefore serves every older workstation of its major.
- **Local build, no releases.** `install.sh` builds the host binary plus
  `linux/amd64` and `linux/arm64` server binaries and installs them side by side.
  GitHub Releases stay out until publishing is decided (`docs/research/landscape.md`).
- **The Go toolchain is containerised** — a root `compose.yml` in the shape of
  the operator's other Go projects: a pinned `golang` image,
  the bind-mounted tree, `run --rm` services for anything whose result matters
  and a `dev` service (`sleep infinity`, driven by `exec`) for the warm inner
  loop. **The Go version is written there and nowhere on the host.**
- **Contracts exact, wording free.** Must match the Bash tool: exit codes, every
  file written (path, format, mode, owner), `versions.log`, the marker, prompts
  and their flag pairs, anything `docs/cli.md` quotes. Human-facing wording no
  doc quotes may change, with its test updated in the same task.
- **Roadmap Phase 4 folds in:** the file inventory now (10.2), the schema freeze
  at cutover (10.14, v1.0.0). `kasbah migrate` waits for the first format change
  that has users — nothing kasbah wrote exists in the wild today.
- **One phase.** The whole port is this phase; task boundaries are the stopping
  points.
- **Run (approved 2026-10-18):** the whole phase, 10.1–10.15, in plan order.
  Each unit passes `docker compose run --rm test`, `docker compose run --rm
  build`, the full `./test.sh` and the rig suites of the family it ported; the
  full `KASBAH_RIG_TESTS=1 ./test.sh` runs after 10.4, 10.7, 10.10 and at the end.
- **The Bash dispatcher moves to `libexec/kasbah-bash`** for the strangler's
  lifetime — its `../install.sh` sibling detection still resolves from there.

## Verification

- **Cheap path:** `docker compose up -d dev` once, then
  `docker compose exec dev go test ./<pkg>/...` / `go build`.
- **Real path:** `docker compose run --rm test` (vet, gofmt check, all Go tests),
  `docker compose run --rm build` (all three targets, `CGO_ENABLED=0`,
  `-trimpath`, version stamped from `VERSION`), `./test.sh`, and
  `KASBAH_RIG_TESTS=1 ./test.sh` against the built binary (`tests/rig/rig.sh up`
  first; exit 2 = rig down). Baseline entering the phase: **48 PASS, 0 FAIL,
  0 SKIP in 32m22s.**
- **The parity harness is the existing suites.** 18 of the 20 integration suites
  call kasbah only through `kasbah_cli` (`tests/integration/rig_env.sh`), and
  `tests/check_test.sh` drives the CLI 91 times; pointed at `KASBAH_BIN` they test
  whichever binary is built. The white-box unit suites (they source `lib/*.sh`)
  retire with the code they test, replaced by `go test` in the same task.
- **Real target: `vps`** (an ssh alias for a small OVH VPS).
  **Disposable, not production:** every container on it may be dropped or reset.
  `../gallery-website/` is the real project and may be reinstalled at will
  (`gallery.example.com`). It was de-branded at Phase 8's close — it is not a
  kasbah server until something re-inits it. Use it wherever the rig cannot
  falsify a task (real sudo, uplink, ACME, DNS); 10.15 is its full walk.
- **Off limits:** the original project's live VPS and the lab RPi — those are Phase 9's.

## Exit criteria
- [ ] No kasbah Bash on either side: `lib/`, the Bash dispatcher, the handoff
      shim and every shipped script are gone; what still crosses SSH as shell
      is the bootstrap only (pointer read, `uname -m`, the `sudo mkdir` server
      init already needs) — exception per open decision D2
- [ ] `./test.sh` and `KASBAH_RIG_TESTS=1 ./test.sh` green against the Go binary,
      no skips, nothing else writing
- [ ] Newer-binary-wins observed both ways on the rig: a newer workstation
      replaces an older server binary; an older workstation runs against a newer
      one; an older workstation meeting a newer **major** refuses, naming it
- [ ] `docs/files.md` lists every file kasbah writes, and a rig test asserts
      the Go binary writes exactly those (paths, modes, owners)
- [ ] On `vps`, from bare: `server init` → deploy gallery-website → change
      deploy → rollback → `server status` clean, Go binary only, HTTPS with a real
      certificate; timings recorded against Phase 6's (init 20.4 s, deploy
      11.4 s, rollback 11.3 s)
- [ ] Docs reconciled: `overview.md`, `roadmap.md`, `CLAUDE.md`, and every spec
      a task changed; `VERSION` is `1.0.0` and the schema is frozen
- [ ] **Cannot be observed here:** the `linux/arm64` server binary is built and
      unit-tested but first runs on the lab RPi (Phase 9, 9.5) — leave unticked
      until then: arm64 binary observed on real hardware

## Tasks

### 10.1 — Ground: toolchain, build paths, strangler (M)
The Go module, the containerised toolchain, both build paths, and the Go
`kasbah` in front of everything — owning nothing yet, handing every command to
Bash. After this task, nothing changes for a user and every later task is just
"move one command family across".

**Deliverables**
- [ ] Root `compose.yml` (no `version:`): pinned `golang` image, `.:/workspace`,
      `user: ${UID:-1000}:${GID:-1000}`, `GOTOOLCHAIN=local`, module and build
      caches persisted; services `build`, `test`, `dev`, `shell`
- [ ] `go.mod` (`github.com/adigourdi/kasbah`), `cmd/kasbah`, version stamped
      from `VERSION` at build time, `kasbah --version` unchanged in content
- [ ] The handoff: an unowned command is replaced by the Bash dispatcher
      in-process (`exec`, not a child), argv/env/TTY/exit code intact
- [ ] `install.sh` builds through compose and installs the Go binary as `kasbah`,
      the two server binaries and the Bash tree it still hands off to;
      `tests/install_test.sh` follows
- [ ] `KASBAH_BIN` honoured by `kasbah_cli` and every unit suite that runs the
      CLI; `./test.sh` runs `docker compose run --rm test` first
- [ ] `.gitignore` covers build output and any cache directory in the tree

**Verify on:** rig — full `KASBAH_RIG_TESTS=1 ./test.sh` green with the Go
binary in front, run both under a real terminal and piped.

**Watch out for:**
- **A child process under a pty takes SIGTTIN** — Phase 2's integration suites
  hung forever that way. The handoff must replace the process (`syscall.Exec`),
  not wait on a child, or every prompt-driving test regresses.
- The golang image runs as root; named volumes are created root-owned, so a
  `user:` container cannot write its caches into them. Give the caches a
  writable home (`HOME`, `GOCACHE`, `GOMODCACHE`) and prove it with a cold run.
- `GOTOOLCHAIN=local`, or a `toolchain` line in `go.mod` downloads a different
  Go than the one `compose.yml` pins — the version would live in two places.
- The Bash dispatcher finds `lib/` through its `../install.sh` sibling; wherever
  it moves, that detection must still resolve, from the checkout and installed.

### 10.2 — Inventory: every file kasbah writes (S) [parallel-safe with 10.1]
Roadmap Phase 4's file list, written against the Bash tool as it stands — the
contract every later task is checked against.

**Deliverables**
- [ ] `docs/files.md`: every path kasbah writes on the workstation and on a VPS —
      writer(s), reader(s), format and its owning spec, mode, owner, when it is
      rewritten or removed (`drop`, `drop --prune`, `server destroy`)
- [ ] Cross-linked from `docs/project-manifest.md` and `docs/server-setup.md`
      rather than duplicating them
- [ ] One rig assertion helper that snapshots the written-file set of a run, so
      later tasks can diff Bash against Go

**Verify on:** rig — snapshot after a full `server init --with-mail
--with-backup` + deploy + rollback matches the document.

**Watch out for:** modes and owners are contract — `versions.log` keeps its mode
across rotation, `/etc/kasbah/apps-path` is `root:root 644`, the SSH control
directory is `0700`. Temp files that outlive a failed run belong in the list too.

### 10.3 — Foundations (M)
The packages every command consumes: YAML and the manifest/state/marker models,
prompts, errors and exit codes, output, CRLF handling.

**Deliverables**
- [ ] YAML loading with PyYAML's YAML 1.1 reading where `check` depends on it —
      prove parity (candidate: `go.yaml.in/yaml/v3`; returning with a better one
      is a valid outcome) over every fixture and the 13 projects Phase 8 used
- [ ] Manifest, state (`.kasbah/state.json`, per
      `docs/project-manifest.md`) and marker readers/writers
- [ ] Prompt layer: TTY detection, `--with-x`/`--no-x` pairs, `--yes` for
      destructive acts, no-TTY hard fail naming the flags, the `--acme-staging`
      exception
- [ ] Exit-code and stdout/stderr conventions from `docs/cli.md`, as one package

**Verify on:** tests + build (`go test` over the shared fixtures).

**Watch out for:** YAML 1.1 vs 1.2 — `on`/`yes`/`no` are booleans and `0755` is
octal under PyYAML, strings under a 1.2 parser. A compose value read as the
wrong type flips a compliance rule silently. Strip `\r` before matching any
user-authored file. "Read a YAML file once" stays a rule: parse into a struct
once per command.

### 10.4 — Transport and the server binary (L)
SSH in Go and the binary's arrival on a server: the substrate every remote
command ported after this rides.

**Deliverables**
- [ ] Transport over the system `ssh`/`rsync` with one multiplexed master per
      run, cleaned up on every exit path including SIGINT
- [ ] Arch detection and shipping to `<apps>/.kasbah/bin/kasbah`: absent or
      older → copy; same or newer → keep (per D1 for dev builds); atomic replace
- [ ] A versioned workstation↔server protocol under `kasbah remote …`; a newer
      major on the server makes an older workstation refuse, naming both versions
- [ ] Unit tests for version ordering and protocol negotiation; rig cases for
      all three newer-wins outcomes

**Verify on:** rig, plus one `vps` shipping run (real uplink, real
`~/.ssh/config` port and user).

**Watch out for:**
- Never `x/crypto/ssh`: kasbah inherits the user's ssh config, agent and jump
  hosts by running `ssh USER@HOST`, the way git does (`lib/ssh.sh` header).
- The ControlPath budget is **90 bytes** (measured, OpenSSH 9.6p1) — `lib/ssh.sh`.
- `ssh host cmd args` re-joins argv with spaces; quote word by word as
  `_ssh_quote` does, or arguments with spaces split on the server.
- Replace by upload-then-rename: a deploy already running the old binary keeps
  its inode; an in-place write would corrupt a running process.
- The deploy user is not root and `<apps>` may sit on a `noexec` mount — exec
  failing there must be an error naming the mount, not a cryptic 126.
- Before `server init` there is no `<apps>`: the bootstrap reads
  `/etc/kasbah/apps-path` and `uname -m` with plain commands first.

### 10.5 — Local: `init-project`, `check`, `check --fix` (L)
Purely local; the first family to leave Bash, and the one with the strongest
ready-made parity suite.

**Deliverables**
- [ ] `init-project`, `check` (every rule in `docs/compliance.md`), `check --fix`
      (diff shown first, touches only what it fixes)
- [ ] Env-template parsing and drift detection in Go (the local half of
      `lib/env.sh`; its VPS half moves in 10.6)
- [ ] `tests/check_test.sh` and `tests/init_project_test.sh` green against Go;
      plain `check` output rule-for-rule equal to Bash over the 13 projects

**Verify on:** tests + build; rig suites untouched by this family must stay green.

**Watch out for:** rule ids, severities and exit codes are contract; wording is
not. Phase 8 proved plain `check` byte-identical across 13 projects
(`08-keep.md` Findings) — keep that comparison as a test, not a memory. `client:` is S08 on the working
tree but only warns on a tag's manifest.

### 10.6 — Env on both sides (M)
`kasbah env` and the deploy's env step, with the VPS side running
`kasbah remote setup-env` instead of a shipped `setup-env.sh`.

**Deliverables**
- [ ] `kasbah env [--on-drift=setup|continue|abort]`, the interactive setup over
      `ssh -t`, the `KASBAH_*` managed block, drift exempting `KASBAH_`
- [ ] Bash deploy keeps working while Go owns env (the strangler seam)
- [ ] `tests/env_test.sh` / `env_cmd_test.sh` cases ported to Go; integration green

**Verify on:** rig, under a real terminal and piped.

**Watch out for:** in `lib/env.sh`, EOF at the menu aborts — that is errexit
behaviour and must become an explicit abort. `export FOO=x` is rewritten as
`FOO=x`. The env step sits after the project rsync and before the remote deploy.

### 10.7 — Ship: `build-push` and `deploy` (L) — the milestone
The first deploy driven by Go on both ends. It runs through every unknown at
once: shipping the binary, the protocol, the remote lock, prompts over SSH.

**Deliverables**
- [ ] `build-push`: `docker compose build` → `docker save | gzip` streamed →
      rsync → `docker load`, digests recorded
- [ ] `deploy` and `kasbah remote deploy`: backup → pre-deploy hooks → retag
      `:current` → `compose up -d --remove-orphans` → health wait → post-deploy
      hooks → one `versions.log` line, rotated — in that order
- [ ] `versions.log` and rotation as one Go package used by both sides
- [ ] `tests/integration/deploy_ship_test.sh`, `ship_test.sh`, `spine_test.sh` green

**Verify on:** rig; then gallery-website on `vps` once (server prepared by the
Bash `server init` until 10.9).

**Watch out for:**
- The completion report is printed **after** the `versions.log` append and is
  the run's completion marker; no report → refuse **before shipping the Traefik
  fragment**. The fragment ships last, always.
- Hook and `backup.check` output must stay off the protocol channel.
- Stream the image; never hold a `docker save` in memory.
- The VPS needed only docker, flock and gzip; it must now need only docker and
  the binary. Lock with the kernel's flock, not the util-linux command.

### 10.8 — Undo: `rollback`, `deploy X.Y.Z`, `history`, `pending`, `changelog` (M)
Shares 10.7's engine; lands while that engine is fresh.

**Deliverables**
- [ ] `rollback [VERSION]`, `deploy X.Y.Z` from `git archive v<X.Y.Z>`
- [ ] `history [--all]`, `pending`, `changelog`, reading `versions.log.gz`
- [ ] One entry predicate for every reader (the three Bash readers converge)

**Verify on:** rig (`rollback_test.sh`, `history_test.sh`).

**Watch out for:** the archive is never fatal on the workstation; the active log
always is. Anything concluding from the **absence** of a record consults archive
state first — `rollback` once told an operator a version was never deployed on
evidence it did not have. Rotation's month index is the deliberate exception to
the entry predicate (tightening it stopped rotation: 67 failures).

### 10.9 — Server init and mail (L)
`server init` (3,074 Bash lines), `add-mail-domain`, `mail-setup-guide`, ACME.
**Lighter spec — re-read `docs/server-setup.md`, `docs/mail.md`,
`docs/traefik.md` and Phase 6–7 findings before briefing.**

**Deliverables**
- [ ] `server init` with every flag pair, sudo only where `docs/server-setup.md`
      says, the discovery pointer, the ACME store reconciliation
- [ ] One mail-registry reader for every command (settles D4)
- [ ] `server_init_test.sh`, `server_init_mail_test.sh`, `apps_path_test.sh` green

**Verify on:** rig; `vps` for real sudo and `--acme-staging`.

**Watch out for:** `--keep-acme --yes` once destroyed a store because one code
path out of three read the choice — test the run that **never consults** a flag.
`--yes` does not answer the unknown-store question, deliberately. kasbah always
overwrites `caServer`.

### 10.10 — Observe: `server status`, `check --server` (L)
**Lighter spec — re-read before briefing.**

**Deliverables**
- [ ] `server status` (backup record included), `check --server` with R04 and T05
- [ ] `server_status_test.sh` cases ported; `check_server_test.sh`,
      `backup_status_test.sh` green

**Verify on:** rig; `vps` once for a real certificate.

**Watch out for:** Let's Encrypt backdates `notBefore` by ~58.5 min — cert age
from it is an hour wrong toward "stale". T05's two families answer separately;
an unreadable source falls back to the heuristic, never to neither.

### 10.11 — Operate: `logs`, `exec`, `server prune`, `upgrade-traefik` (M)
**Lighter spec — re-read before briefing.**

**Deliverables**
- [ ] `logs`, `exec` with TTY passthrough and their `last_server` rules
- [ ] `server prune` (3 versions + 3 months), `upgrade-traefik` dry run then switch
- [ ] `ops_test.sh`, `prune_test.sh`, `upgrade_traefik_test.sh` green

**Verify on:** rig.

**Watch out for:** `exec` exits with the command's status and still writes
`last_server`; `logs` writes on 0, 255 and 130 only. Retention counts the
version `:current` points at as the first.

### 10.12 — Keep: `drop`, `server destroy` (L)
**Lighter spec — re-read before briefing.**

**Deliverables**
- [ ] `drop [--prune] [--yes]`, `server destroy [--yes]`, `<apps>/.kasbah/bin`
      included in what destroy removes
- [ ] `drop_test.sh`, `server_destroy_test.sh` green

**Verify on:** rig; `vps` once — destroy with gallery-website serving throughout.

**Watch out for:** destroy keeps every container running. `/etc/kasbah` is
root-owned. A binary that destroy removes must not be the one executing the
removal mid-step — order the last remote call accordingly.

### 10.13 — Backup (M)
**Lighter spec — re-read `docs/backup.md` and Phase 8 findings before briefing.**

**Deliverables**
- [ ] `--with-backup` (append-only credential proved at init), `backup-prune`
      run locally, the backup record, the container runner per D2
- [ ] `backup_test.sh`, `backup_harness_test.sh` green

**Verify on:** rig (`rest:`); `s3:` stays traced.

**Watch out for:** the full-access credential never reaches the server. The
backup record survives container restarts (commit `12e543a`).

### 10.14 — Cutover (M)
**Deliverables**
- [ ] Delete `lib/`, the Bash dispatcher, the shim, the shipped templates the
      binary replaced, the retired white-box suites and `tests/norm_path_test.sh`
- [ ] Docs: `overview.md` (Language, Distribution, "Bash first, Go-ready"),
      `roadmap.md` 4–5 rewritten, `build-deploy.md` helper-scripts sections,
      `cli.md`, `CLAUDE.md` (Bash rules → Go rules; frozen contracts, interactivity,
      CRLF and compose rules kept)
- [ ] `VERSION` → `1.0.0`; schema frozen (`docs/project-manifest.md`); `--version`
      per D3

**Verify on:** full real path; nothing else writing.

**Watch out for:** a doc claiming one reader where two remain — check that
things share an implementation, not merely a rule.

### 10.15 — Proof on `vps` (M)
**Deliverables**
- [ ] Bare `vps` (destroy, then reset containers as needed) → `server init` →
      gallery-website deploy → change deploy → rollback → `server status`, Go
      binary only; staging certificate rehearsal first
- [ ] Timings and anything the rig hid, in Findings

**Verify on:** `vps`.

**Watch out for:** DNS and open ports were unprobed preconditions in Phase 6.
Leave `vps` as a kasbah server at the end — Phase 9 starts from it.

## Open decisions

- **D1 — dev builds under newer-wins (settle at 10.4).** Every build in this
  phase reports `0.1.0-dev`, so "same version → server's wins" keeps the first
  dev binary forever. Options: (a) pre-release versions compare by content hash
  and the workstation's wins on a mismatch, releases follow the rule exactly
  (recommended); (b) stamp a build counter into every version; (c) an explicit
  `--replace-server-binary` flag.
  **Settled 2026-10-18: (b), a build counter.** A clean tree stamps
  `<VERSION>.<commit count>` (`0.1.0-dev.142`); a dirty tree appends build time
  in unix seconds (`0.1.0-dev.142.1760790000`), so every rebuild inside a unit
  outranks the last under semver pre-release ordering. Release versions
  (`1.0.0`) carry no counter, and from then on the rule applies exactly.
- **D2 — the backup runner (settle at 10.13).** `backup.sh` runs inside
  restic's own image, not on the host. Options: (a) keep it `sh` — it is
  container content, like a compose file; (b) mount the static linux binary into
  the container and run `kasbah remote backup`.
  **Settled 2026-10-18: (b).** Mounted read-only from the shared path;
  `backup.sh` retires. A newer binary reaches the container at its next restart.
- **D3 — `--version` content (settle at 10.14).** Roadmap Phase 5 asked for tool
  and schema version both. Options: both, or tool version only.
  **Settled 2026-10-18: both** — `kasbah 1.0.0 (schema 1)`.
- **D4 — a hand-edited mail registry with no `primary_domain` (settle at
  10.9).** Today the shared reader refuses while three copies fall back to an
  empty primary (`docs/cli.md` states the divergence). One reader means one
  behaviour; Phase 9's cutovers make hand-edited registries the ordinary case.
  **Settled 2026-10-18: refuse**, in every command, naming the file and the key
  to add.
- **D5 — the checkout entry point (settle at 10.1).** `bin/kasbah` is the
  documented way to run from a checkout. Options: (a) the built binary at a
  fixed path (e.g. `dist/kasbah`) becomes it and `bin/` goes at cutover
  (recommended); (b) keep `bin/kasbah` as a small launcher of the built binary.
  **Settled 2026-10-18: (a)** — `dist/kasbah` (gitignored) is the checkout entry
  and the tests' default `KASBAH_BIN`; `bin/` goes at cutover.

## Findings

Run approved 2026-10-18: whole phase, plan order, unit bar as in Rulings.
