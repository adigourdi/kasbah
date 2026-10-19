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
- **R1 — output is locale-independent** (2026-10-19, 10.5): Go reads and
  reports as the Bash tool did under `LC_ALL=C.UTF-8` — ASCII names and schemes,
  UTF-8 character counts, byte-order lists. Bash under `en_US` let `démo` pass
  and sorted the glibc way; that is not reproduced.
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
- [x] Root `compose.yml` (no `version:`): pinned `golang` image, `.:/workspace`,
      `user: ${UID:-1000}:${GID:-1000}`, `GOTOOLCHAIN=local`, module and build
      caches persisted; services `build`, `test`, `dev`, `shell` — `golang:1.27.2-trixie`;
      caches under `.cache/` in the tree (a named volume is root-owned); cold
      `run --rm test` and `build` both rc=0
- [x] `go.mod` (`github.com/adigourdi/kasbah`), `cmd/kasbah`, version stamped
      from `VERSION` at build time, `kasbah --version` unchanged in content —
      the stamp travels as `KASBAH_BUILD` and only `--version`/usage print it;
      every file kasbah writes still records plain `VERSION`
- [x] The handoff: an unowned command is replaced by the Bash dispatcher
      in-process (`exec`, not a child), argv/env/TTY/exit code intact — review
      drove `-x "" -- "a b" $'nl\nx'`, exit 42, an ignored SIGINT and rlimits
      through it unchanged; the dispatcher is `libexec/kasbah-bash`
- [x] `install.sh` builds through compose and installs the Go binary as `kasbah`,
      the two server binaries and the Bash tree it still hands off to;
      `tests/install_test.sh` follows — `<lib>/libexec/`, `<lib>/server/`;
      `KASBAH_SKIP_BUILD=1` installs an existing `dist/`
- [x] `KASBAH_BIN` honoured by `kasbah_cli` and every unit suite that runs the
      CLI; `./test.sh` runs `docker compose run --rm test` first — one default,
      in `tests/cli.sh`; an unusable Docker exits 2
- [x] `.gitignore` covers build output and any cache directory in the tree

**Verify on:** rig — full `KASBAH_RIG_TESTS=1 ./test.sh` green with the Go
binary in front, run both under a real terminal and piped. **Observed:** 48 PASS,
1 FAIL in 31m10s (`integration/prune_test.sh`, a test that assumed two stock
images a reset rig no longer holds — it now pulls them; rc=0 from a rig without
them). Unit half 30 PASS piped and under `script -qec`.

**Watch out for:**
- **Exec, not a child:** same PID, so signals reach the dispatcher and its exit
  status is kasbah's with no parent in between. (Phase 2's SIGTTIN hang came from
  `timeout` running its child in a process group of its own, not from exec.)
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
- [x] `docs/files.md`: every path kasbah writes on the workstation and on a VPS —
      writer(s), reader(s), format and its owning spec, mode, owner, when it is
      rewritten or removed (`drop`, `drop --prune`, `server destroy`)
- [x] Cross-linked from `docs/project-manifest.md` and `docs/server-setup.md`
      rather than duplicating them
- [x] One rig assertion helper that snapshots the written-file set of a run, so
      later tasks can diff Bash against Go — `tests/integration/rig_files.sh`;
      `KASBAH_FILES_SNAPSHOT_DIR` keeps normalised snapshots, and two passing runs
      diff byte-identical

**Verify on:** rig — snapshot after a full `server init --with-mail
--with-backup` + deploy + rollback matches the document. **Observed:**
`tests/integration/files_test.sh` rc=0 (~80 s); a deliberately broken row fails
it. Rows for `drop`, `drop --prune`, `server destroy`, `upgrade-traefik`,
`add-mail-domain`, `backup-prune`, `env`, `deploy X.Y.Z`, `init-project` and
`check --fix` are code-read, not run — the units porting those commands assert them.

**Watch out for:** modes and owners are contract — `versions.log` keeps its mode
across rotation, `/etc/kasbah/apps-path` is `root:root 644`, the SSH control
directory is `0700`. Temp files that outlive a failed run belong in the list too.

### 10.3 — Foundations (M)
The packages every command consumes: YAML and the manifest/state/marker models,
prompts, errors and exit codes, output, CRLF handling.

**Deliverables**
- [x] YAML loading with PyYAML's YAML 1.1 reading where `check` depends on it —
      prove parity (candidate: `go.yaml.in/yaml/v3`; returning with a better one
      is a valid outcome) over every fixture and the 13 projects Phase 8 used —
      the premise was wrong: yq 3.1.0 resolves scalars per **YAML 1.2** (only
      octal survives from 1.1), over libyaml, with jq 1.7 re-spelling numbers.
      `internal/yamlx` + `internal/jv` match `yq -c .` on 255 of 258 goldens made
      by the real yq (3 known divergences, all refusals or safe), and on all 727
      YAML files under `~/work`. The 13 projects are not in the repo; the inputs
      `check_test.sh` feeds yq were captured instead
- [x] Manifest, state (`.kasbah/state.json`, per
      `docs/project-manifest.md`) and marker readers/writers — byte-identical to
      the Bash writers (the review diffed 21 state, 29 manifest and 5 marker cases)
- [x] Prompt layer: TTY detection, `--with-x`/`--no-x` pairs, `--yes` for
      destructive acts, no-TTY hard fail naming the flags, the `--acme-staging`
      exception — secret input restores echo on SIGINT, proven on a pty
- [x] Exit-code and stdout/stderr conventions from `docs/cli.md`, as one package — `internal/cli`

**Verify on:** tests + build (`go test` over the shared fixtures).

**Watch out for:** the reading to match is the installed yq's, not PyYAML's
default — `on`/`yes` are strings, `0755` is octal 493, numbers carry jq's
spelling (`cpus: 0.5` is `"0.5"`, `1e3` is `1000.0`). A value read as the wrong
type flips a compliance rule silently; query the `jv` tree, never re-parse. Strip `\r` before matching any
user-authored file. "Read a YAML file once" stays a rule: parse into a struct
once per command.

### 10.4 — Transport and the server binary (L)
SSH in Go and the binary's arrival on a server: the substrate every remote
command ported after this rides.

**Deliverables**
- [x] Transport over the system `ssh`/`rsync` with one multiplexed master per
      run, cleaned up on every exit path including SIGINT
      — `internal/ssh` + `internal/atexit`; a second signal forces the exit
- [x] Arch detection and shipping to `<apps>/.kasbah/bin/kasbah`: absent or
      older → copy; same or newer → keep (per D1 for dev builds); atomic replace
      — `internal/serverbin`: the uploaded build proves its own stamp, then
      `kasbah remote install-self` re-checks under `bin/.lock` and renames, so two
      racing workstations leave the newer; every server-binary run is bounded at 30 s
- [x] A versioned workstation↔server protocol under `kasbah remote …`; a newer
      major on the server makes an older workstation refuse, naming both versions
      — `remote version` prints `build=… protocol=1 min_protocol=1`, a line meant
      never to change across majors
- [x] Unit tests for version ordering and protocol negotiation; rig cases for
      all three newer-wins outcomes
      — `tests/integration/server_binary_test.sh`: absent, older, same, newer,
      newer major, a racing pair, a hung binary, SIGINT mid-probe and mid-upload,
      noexec, the bootstrap mode, the stale-upload sweep

**Verify on:** rig, plus one `vps` shipping run (real uplink, real
`~/.ssh/config` port and user) — **moved to 10.7**, which prepares `vps` anyway.
**Observed:** full `KASBAH_RIG_TESTS=1 ./test.sh` 51 PASS, 0 FAIL in 31m35s.

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
- [x] `init-project`, `check` (every rule in `docs/compliance.md`), `check --fix`
      (diff shown first, touches only what it fixes) — `check --fix` split off to
      **10.5b**; plain `check` (no arguments) and `init-project` are Go, any
      `check` argument still reaches Bash
- [x] Env-template parsing and drift detection in Go (the local half of
      `lib/env.sh`; its VPS half moves in 10.6) — `internal/envtpl`
- [x] `tests/check_test.sh` and `tests/init_project_test.sh` green against Go;
      plain `check` output rule-for-rule equal to Bash over the 13 projects —
      `tests/check_parity_test.sh`: 672 projects (fixtures, the captured documents,
      ~300 edge cases, 79 checks lifted from `check_test.sh`), stdout and exit code
      equal with Bash under `C.UTF-8` and Go under five locales; also clean on
      `../gallery-website` and 40 sibling compose files. `check_test.sh` 2m18s, was ~4 min

**Verify on:** tests + build; rig suites untouched by this family must stay green.

**Watch out for:** rule ids, severities and exit codes are contract; wording is
not. Phase 8 proved plain `check` byte-identical across 13 projects
(`08-keep.md` Findings) — keep that comparison as a test, not a memory. `client:` is S08 on the working
tree but only warns on a tag's manifest.

### 10.5b — `check --fix` (L)
Split from 10.5 on contact: `lib/check_fix.sh` is 1,320 lines of targeted text
edits Phase 8 hardened, and deserves its own review.

**Deliverables**
- [x] `check --fix [--yes]` in Go: C01–C05, C08, R01–R03 and the `kasbah_version`
      backfill, diff shown first, nothing else touched; plain-check verdicts come
      from the same `internal/check` queries — `internal/check/{fix,scan,guard}.go`
- [x] `tests/check_test.sh` F-cases green against Go; the parity harness extended to
      `--fix` (resulting files byte-identical to Bash's, under `C.UTF-8`) — 701
      `--fix` projects (137 rewritten) and 750 plain, 0 differing; resulting trees
      also compared parsed, so a value lost where both tools wrote the same bytes fails

**Verify on:** tests + build.

**Watch out for:** Phase 8's design — *yq decides what is true; the line scanner
only finds where it is written* — a key the scanner cannot locate is refused and
named, never guessed; never a YAML round-trip (comments are load-bearing). Block
scalars (`|`, `>`) ending in comments broke `_cf_block_end` once.

**Found here, fixed in Go and Bash:** a block-scalar header after `- `, or behind
an anchor or tag (`- |`, `&ep |`, `!!str >-`), was not recognised — `--fix` spliced
its insertion into the script and the scalar lost its last lines, a silent
corruption since Phase 8. Both now recognise those headers, and both refuse any
candidate whose parsed tree is not the original plus exactly the planned edits.

### 10.6 — Env on both sides (M)
`kasbah env` and the deploy's env step, with the VPS side running
`kasbah remote setup-env` instead of a shipped `setup-env.sh`.

**Deliverables**
- [x] `kasbah env [--on-drift=setup|continue|abort]`, the interactive setup over
      `ssh -t`, the `KASBAH_*` managed block, drift exempting `KASBAH_` —
      `internal/env`; server side `kasbah remote setup-env prepare|drift|setup|inject`
      and `kasbah remote marker`; a created `.env` is `600`, staged and renamed over
- [x] Bash deploy keeps working while Go owns env (the strangler seam) — one
      case table (`internal/env/parity_test.go`) holds `lib/env.sh` to the Go engine
- [x] `tests/env_test.sh` / `env_cmd_test.sh` cases ported to Go; integration green —
      `tests/integration/env_test.sh` (headless, interactive, decline, drift matrix,
      Ctrl-C at a server prompt, an unreadable `.env`), piped and under a pty.
      **Fixed in both engines:** "reconfigure all" doubled every `$` in kept values
      on each run; a typed CR landed in `.env`; an unreadable `.env` read as absent
      (Go only) would have overwritten live secrets. Kept as Bash had them: two
      concurrent runs — the last rename wins; a one-key read leaves the rest of the
      line; a `! command` that exits the shell aborts the setup

**Verify on:** rig, under a real terminal and piped.

**Watch out for:** the project `.env` holds secrets but `lib/env.sh:414` creates
it at umask (`644` on the rig); only the inject path starts it `600` — decide
the Go mode deliberately and record it in `files.md`. In `lib/env.sh`, EOF at the menu aborts — that is errexit
behaviour and must become an explicit abort. `export FOO=x` is rewritten as
`FOO=x`. The env step sits after the project rsync and before the remote deploy.

### 10.7 — Ship: `build-push` (M)
Split on contact (2026-10-19): `build-push` first, `deploy` as **10.7b** — each
is a review of its own.

**Deliverables**
- [x] `build-push`: `docker compose build` → `docker save | gzip` streamed →
      rsync → `docker load`, digests recorded — streamed over ssh into the
      server's `kasbah remote load` with no tarball on either end (2.7 s vs Bash's
      6.2 s on the rig, two images, 28.7 MB); `digest=` is deploy's (10.7b). The
      server is reached and its binary ensured **before** the build, so exit 3/4
      come first; a server `server init` never prepared is refused (exit 4)
- [x] `tests/integration/ship_test.sh` green, and `deploy_ship_test.sh` with Go
      `build-push` feeding Bash `deploy`

**Verify on:** rig.

### 10.7b — Ship: `deploy` (L) — the milestone
The first deploy driven by Go on both ends. It runs through every unknown at
once: shipping the binary, the protocol, the remote lock, prompts over SSH.

**Deliverables**
- [x] `deploy` and `kasbah remote deploy`: backup → pre-deploy hooks → retag
      `:current` → `compose up -d --remove-orphans` → health wait → post-deploy
      hooks → one `versions.log` line, rotated — in that order — `internal/deploy`;
      every failure path checked against `templates/remote-deploy.sh`; the report
      is one JSON line, and no report means no fragment. Working-tree deploys;
      `deploy X.Y.Z` followed in 10.8. First deploy 3.5 s vs 4.6 s,
      redeploy 1.0 s vs 2.0 s on the rig
- [x] `versions.log` and rotation as one Go package used by both sides —
      `internal/vlog`; 11 synthetic logs rotate byte-identically to the Bash
      functions; the workstation readers move to it in 10.8
- [x] `tests/integration/deploy_ship_test.sh`, `ship_test.sh`, `spine_test.sh` green
      — full `KASBAH_RIG_TESTS=1 ./test.sh` 54 PASS, 0 FAIL in 35m; a Bash-vs-Go
      file snapshot of one deploy differs only by the `scripts/` Go no longer ships.
      **Deliberate:** a mail registry with no `primary_domain`, a non-domain entry or
      a non-list `domains:` refuses the deploy (D4, one reader: `internal/mailreg`);
      a failing SnappyMail seed is a warning

**Verify on:** rig; then gallery-website on `vps` once (server prepared by the
Bash `server init` until 10.9) — including 10.4's deferred first shipping of the
binary over the real uplink and `~/.ssh/config` (a non-standard port). **Observed
2026-10-19:** Bash `server init --keep-acme --no-mail --no-backup` re-branded `vps`
(4.0 s, credentials and certificate store reused); Go `build-push --no-git-push`
26.4 s (cold `npm` build, 62 MB image, the binary's first shipping over the real
uplink); Go `deploy` 9.7 s first, 4.0 s redeploy (~0.85 s per handshake, 44 ms
RTT; one master carried 11 ssh calls and 3 rsyncs); `https://gallery.example.com/`
200 on the kept production certificate; no `scripts/` on the server.

**Watch out for:**
- Deploy's env step becomes `env.Step` (`internal/env`) with `always=false`, and
  `lib/env.sh`, `lib/env_cmd.sh`, both Bash env suites and the Bash half of
  `internal/env/parity_test.go` retire with it. Ten integration suites run
  `./scripts/setup-env.sh` by hand (apps_path, rollback, check_server, drop,
  deploy_ship, files, server_destroy, ops, history, spine) — switch them to
  `kasbah remote setup-env setup` or `kasbah env` under `script`. Then the
  `files.md` `.env` mode cell becomes a single `600`, and the `scripts/setup-env.sh`
  row goes.
- `docs/build-deploy.md:303-305` calls `digest=` an `image@sha256` content
  digest; the code writes the image id (`templates/remote-deploy.sh:787`) — keep
  the bytes, fix the doc.
- The completion report is printed **after** the `versions.log` append and is
  the run's completion marker; no report → refuse **before shipping the Traefik
  fragment**. The fragment ships last, always.
- Hook and `backup.check` output must stay off the protocol channel.
- The VPS needed only docker, flock and gzip; it must now need only docker and
  the binary. Lock with the kernel's flock, not the util-linux command.
- Retag exactly what `build-push` tagged: use `buildpush.Built` (Bash deploy
  sourced `build_push.sh` for the same reason, `lib/remote_deploy.sh:9-14`); the
  version rule is `internal/release`.
- `rollback` still renders `templates/remote-deploy.sh` in its rollback mode until
  10.8 — leave the template working.
- A long server-side run cannot sit under the 30 s `RunTimeout`; say what bounds it.

### 10.8 — Undo: `rollback`, `deploy X.Y.Z`, `history`, `pending`, `changelog` (M)
Shares 10.7's engine; lands while that engine is fresh.

**Deliverables**
- [x] `rollback [VERSION]`, `deploy X.Y.Z` from `git archive v<X.Y.Z>` —
      `internal/deploy/tagged.go`: one path for both, the tag's tree extracted
      in-process (mtimes kept, `../` refused, cleaned on a signal), the engine in
      rollback or deploy mode; an archive-only record is not a first deploy
- [x] `history [--all]`, `pending`, `changelog`, reading `versions.log.gz` —
      `internal/history` over `kasbah remote vlog`; output matches `docs/cli.md`
- [x] One entry predicate for every reader (the three Bash readers converge) —
      every Go reader uses `internal/vlog`; `prune`, `drop`, `server status` and
      `destroy` still read through `lib/versions_log.sh` until they are ported.
      Retired: `lib/{rollback,history,deploy,build_push,remote_deploy,env_cmd}.sh`,
      `templates/remote-deploy.sh` and four unit suites (−9k lines); nothing ships
      `scripts/` any more. Kept: `lib/env.sh` (`check --server`, `destroy`)

**Verify on:** rig (`rollback_test.sh`, `history_test.sh`).

**Watch out for:** the Go engine already has `Mode: "rollback"` and the four hook
lists — only the workstation side needs writing. `vlog.Decode` keeps the whole
lines of a truncated gzip member: check that against what the Bash readers
showed. Once rollback leaves Bash, `scripts/` and both helper rows in `files.md`
go and the `.env` mode cell becomes a single `600` (destroy's helper list stays,
for older servers). Interrupting a hook leaves the server engine running until
its next stderr write, which can land after `:current` moved — Bash's exposure
too. The archive is never fatal on the workstation; the active log
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

**Ruling (2026-10-19), `vps` mail:** take the old mail stack down there
(`docker compose down` in `/apps/mail`, data kept), and re-init a fresh one with
`--with-mail` when a test needs it — 10.9's `vps` check is that test.

**Watch out for:** init ships the binary into the `<apps>` it has just created,
before the marker exists — `serverbin.Ensure` with `Options{Apps}`; that mode
ignores any pointer and accepts `..` segments, so init's pointer-conflict refusal
and path validation must run first. `/etc/kasbah` gets its `755` only when the pointer is
rewritten (`lib/server_init.sh:1207-1216`), and the backup `env` gets `600` only
when its content changes (`lib/backup.sh:878-884`) — Go should enforce both on
every run. `--keep-acme --yes` once destroyed a store because one code
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

**Watch out for:** `tests/integration/server_destroy_test.sh` currently accepts
`<apps>/.kasbah/bin/` surviving a destroy and removes it by hand — restore the
original "nothing left" assertion once destroy removes the binary. The Bash
rewrite of `mail/.env` renames its temp file over
the real one without checking the write finished (`lib/server_destroy.sh:1148-1168`)
— a full disk truncates the operator's relay block; Go checks before renaming.
`docs/server-setup.md:681-700` says every container keeps running, but destroy
removes the `kasbah-backup` container and its volume (`server_destroy.sh:948-966`)
and the discovery pointer — reconcile the doc. `docs/cli.md:870-873` says `drop`
records no `last_server` after a held lock; `lib/drop.sh:1376-1380` does. Destroy keeps every project container running. `/etc/kasbah` is
root-owned. A binary that destroy removes must not be the one executing the
removal mid-step — order the last remote call accordingly.

### 10.13 — Backup (M)
**Lighter spec — re-read `docs/backup.md` and Phase 8 findings before briefing.**

**Deliverables**
- [ ] `--with-backup` (append-only credential proved at init), `backup-prune`
      run locally, the backup record, the container runner per D2
- [ ] `backup_test.sh`, `backup_harness_test.sh` green

**Verify on:** rig (`rest:`); `s3:` stays traced.

**Watch out for:** `templates/backup/env:23` promises the backup credentials
"never leave this server", but init reads the whole `env` back to the
workstation (`lib/backup.sh:452`) and re-ships it (`:824`, `:879`). With Go on the
server the merge can happen there — make the promise true. The full-access credential never reaches the server. The
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

**Watch out for:** `vps` still runs a mail stack (`mail-dms`, `mail-snappymail`,
`/apps/mail`, `dynamic/_mail.yml`) that survived Phase 8's destroy, but its
marker records no mail since the 10.7b re-init used `--no-mail` — adopt it with
`--with-mail` (re-entering the registry) or drop it; decide before this walk.
The gallery certificate expires 2026-11-20, so its renewal window opens around
2026-10-21 — expect Traefik to renew during the phase. A UDP relay on
the host is not kasbah's. DNS and open ports were unprobed preconditions in Phase 6.
Leave `vps` as a kasbah server at the end — Phase 9 starts from it.

## Open decisions

- **D1 — dev builds under newer-wins (settle at 10.4).** Every build in this
  phase reports `0.1.0-dev`, so "same version → server's wins" keeps the first
  dev binary forever. Options: (a) pre-release versions compare by content hash
  and the workstation's wins on a mismatch, releases follow the rule exactly
  (recommended); (b) stamp a build counter into every version; (c) an explicit
  `--replace-server-binary` flag.
  **Settled 2026-10-18: (b), a build counter.** Every pre-release build stamps
  `<VERSION>.<commit count>.<unix build time>` (`0.1.0-dev.66.1792355995`) — the
  build time on clean builds too, since 10.4, so a clean rebuild outranks the dirty
  build before it and an amend still orders. Release versions (`1.0.0`) carry
  nothing, and from then on the rule applies exactly. A history rewritten to fewer
  commits still loses — accepted.
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
- **D6 — exit codes on malformed input (settle at 10.14).** Plain `check` exits
  5 or 3 when a query fails on a badly shaped file (`services: {web: nginx}`) —
  jq's status under errexit in the Bash tool, kept for parity — and those collide
  with `docs/cli.md`'s 5 (env setup) and 3 (ssh unreachable). Options: map every
  such abort to 1 at cutover, when the parity harness retires; or keep.
- **D5 — the checkout entry point (settle at 10.1).** `bin/kasbah` is the
  documented way to run from a checkout. Options: (a) the built binary at a
  fixed path (e.g. `dist/kasbah`) becomes it and `bin/` goes at cutover
  (recommended); (b) keep `bin/kasbah` as a small launcher of the built binary.
  **Settled 2026-10-18: (a)** — `dist/kasbah` (gitignored) is the checkout entry
  and the tests' default `KASBAH_BIN`; `bin/` goes at cutover.

## Findings

Run approved 2026-10-18: whole phase, plan order, unit bar as in Rulings.

- **A reset rig has an empty image store**, and suites that assert on stock
  images must pull them themselves — `integration/prune_test.sh` assumed two that
  only rig history had. Expect the same shape elsewhere after any `rig.sh reset`.
- **The rotation month table lives once**, `internal/vlog/testdata/month-index.table`,
  read by both `TestMonthIndexTable` and `tests/prune_test.sh`.
- **Every Go-owned command calls `atexit.HandleSignals()` and leaves through
  `atexit.Exit`**, or its cleanups (ssh master, temp files, terminal echo) are
  skipped on a signal. `kasbah __ensure-server USER@HOST [--apps-path=]` is a
  hidden driver for the rig suites, absent from usage and `cli.md`.
- **Bash ran EXIT traps around its secret prompts** (`lib/backup.sh` trap at
  1603 around the prompt at 1647, `lib/server_init.sh` trap at 2942); in Go a
  signal at `prompt.Secret` runs the `atexit` stack, so 10.9 and 10.13 push their
  cleanups there.
- **The Bash tool's YAML reading depends on the installed yq's version** — 3.1.0
  reads YAML 1.2 scalars; older wrappers may not. The Go binary fixes the 3.1.0
  reading for good.
- **The unit half is now ~9m40s** (Go checks + a build + 29 suites), up from
  ~7 min; the full rig run 31m10s.
