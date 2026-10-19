# kasbah

Go CLI that turns a plain VPS into a multi-project Docker host
(Traefik file-provider routing, registry-less image shipping over SSH).
The same binary runs on the VPS: kasbah ships it to
`<apps>/.kasbah/bin/kasbah` and drives the server through `kasbah remote …`.
`docs/` is the spec and the source of truth; `docs/phases/` is the build
plan and the only progress tracker (the roadmap is scope, not status).

## Commands

- `./test.sh` — Go checks, a build of `dist/`, then the black-box suites
  (~3 min, needs Docker, no server). Must pass before any commit.
  `KASBAH_BIN=<path>` tests that binary instead and skips the build.
- `KASBAH_RIG_TESTS=1 ./test.sh` — adds integration tests against the
  fake-VPS rig (~35 min: run it in the background). Run `tests/rig/rig.sh up`
  first; see `tests/rig/README.md` for what the rig can and cannot prove.
  Exit 2 means the environment is wrong (rig down), not that a test failed.
- `docker compose run --rm build` — `dist/kasbah` plus the linux/amd64 and
  linux/arm64 server binaries in `dist/server/`; `docker compose run --rm test`
  — vet, gofmt, `go test`. Inner loop: `docker compose up -d dev`, then
  `docker compose exec dev go test ./...`. No Go on the host: the version
  lives in `compose.yml` alone. Build from the main checkout — a git worktree's
  `.git` points outside the mounted tree and the version stamp fails.
- `dist/kasbah <cmd>` — run the CLI from the checkout; no install needed.
- Versions: files kasbah writes record `VERSION`; `--version` prints the build
  stamp and the schema (`kasbah 1.0.0 (schema 1)`; a pre-release stamp adds the
  commit count and build time, so a later build always outranks an earlier one).

## Hard conventions

- **The server runs only the kasbah binary.** Remote work is a `kasbah remote …`
  subcommand, never a shell script; shell crosses ssh only for the bootstrap
  probe and the `sudo` steps init and destroy need. Anything a remote step
  installs from stdin carries its size and sha256 (`internal/remote`).
- **Newer wins on the server.** The workstation ships its build when the
  server's binary is absent or older and keeps it when the same or newer; an
  older workstation refuses a newer major.
- **YAML reads as kislyuk `yq` 3.1.0 printed it** — plain scalars per YAML 1.2
  (`yes`/`on` are strings) but `0755` octal, numbers in jq 1.7's spelling.
  `internal/yamlx` + `internal/jv` reproduce it (goldens from the real yq);
  parse a file once and query the tree, never re-parse per rule.
- **Output is locale-independent**: ASCII names and schemes, UTF-8 character
  counts, byte-order lists.
- **Signals:** every command calls `atexit.HandleSignals()` and leaves through
  `atexit.Exit`, so temp files, the ssh master and terminal echo are cleaned on
  Ctrl-C; every server-side step that changes state (deploy and rollback,
  `drop`, `destroy`, a Traefik start and its rollback, backup init) ignores
  SIGHUP/SIGPIPE, so a dropped session never leaves it half-done.
- **CRLF tolerance:** strip `\r` before matching any user-authored file.
- **Interactive, never assume:** an unset flag means *prompt*, not *no*.
  Every prompt has a `--with-x`/`--no-x` (or `--yes`) pair; without a TTY,
  an unanswered prompt is a hard fail naming the flag.
- **Compose:** files are `compose.yml` (never docker-compose.yml), no
  `version:` attribute.
- **Shell scripts** (`test.sh`, `install.sh`, `tests/`): `set -euo pipefail`;
  under pipefail never pipe a producer into `grep -q` — capture, then `grep -q <<<`.
- **Tests land with the code they test, in the same change.**
- **Docs are the spec:** when implementation contradicts a doc, fix the
  doc in the same change — never let them drift.

## Frozen contracts — never rename

`kasbah-net`; entrypoints `web`/`websecure`; certresolver `letsencrypt`;
the `_shared.yml` middleware names; `versions.log`'s four positional
fields (new data = appended `key=value` pairs); the `KASBAH_` env-var
prefix (reserved, injected at deploy, exempt from drift); the manifest schema
(1, frozen at 1.0.0 — a change goes through `kasbah migrate`).

## Layout

- `cmd/kasbah` — the CLI entry; `internal/` — one package per concern
  (`internal/remote` and each command's `remote.go` are the server side);
  `tools/stamp` — the build stamp.
- `templates/` — files kasbah renders onto servers, embedded in the binary.
- `tests/` — black-box `*_test.sh` suites (`tests/cli.sh` resolves `KASBAH_BIN`);
  `tests/rig/` fake VPS; `tests/integration/` rig-driven; `tests/fixtures/` sample projects.
- `docs/` — the spec; start with `overview.md` (decisions table), `compliance.md`
  (rule catalog) and `files.md` (every file kasbah writes).
- `docs/phases/` — build plan; phase Findings sections are the project's memory of traps. Read the relevant phase file before touching its area.
- `docs/research/` — dated competitive/background notes. **Not spec, not normative**; acted on by lifting findings into a spec doc, the roadmap, or the backlog.
