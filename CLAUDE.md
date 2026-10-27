# kasbah

Go CLI that turns a plain VPS into a multi-project Docker host
(Traefik file-provider routing, registry-less image shipping over SSH).
The same binary runs on the VPS: kasbah ships it to
`<apps>/.kasbah/bin/kasbah` and drives the server through `kasbah remote …`.
`docs/` is the spec and the source of truth; `docs/phases/` is the build
plan and the only progress tracker (the roadmap is scope, not status).

## Commands

- `./test.sh` — Go checks, a build of `dist/`, then the black-box suites (a few
  minutes, no server). Must pass before any commit. Needs Docker and the host
  tools `CONTRIBUTING.md` lists. `KASBAH_BIN=<path>` tests that binary instead
  and skips the build (the suites still read YAML through `dist/yaml2json`).
  One line per suite; each suite's full output is in
  `.cache/test-logs/<suite>.log`, dumped after a FAIL; `KASBAH_TEST_VERBOSE=1`
  streams everything.
- `KASBAH_RIG_TESTS=1 ./test.sh` — adds integration tests against the
  fake-VPS rig (over half an hour: run it in the background). Run
  `tests/rig/rig.sh up` first; see `tests/rig/README.md` for what the rig can
  and cannot prove. Exit 2 means the environment is wrong (rig down), not that
  a test failed.
- `docker compose run --rm build` — `dist/kasbah` plus the server binaries in
  `dist/server/` and the suites' `dist/yaml2json`; `docker compose run --rm
  test` — vet, gofmt, `go test`. Inner loop: `docker compose up -d dev`, then
  `docker compose exec dev go test ./...`.
  No Go on the host: the version lives in `compose.yml` alone. Build from the
  main checkout — a git worktree's `.git` points outside the mounted tree and
  the version stamp fails.
- `dist/kasbah <cmd>` — run the CLI from the checkout; no install needed.
- Installing a build, releasing, and how builds are versioned:
  `CONTRIBUTING.md`, `docs/install.md` and `docs/overview.md` (Distribution).
  The next release's number is set by editing `VERSION` in its release
  commit — patch for fixes, minor for additive features, major for a schema
  change — and nothing bumps it after a release.

## Hard conventions

- **The server runs only the kasbah binary.** Remote work is a `kasbah remote …`
  subcommand, never a shell script; shell crosses ssh only for the bootstrap
  probe and the `sudo` steps init and destroy need. Anything a remote step
  installs from stdin carries its size and sha256 (`internal/remote`).
- **Same build on both ends.** The workstation ships its build when the
  server's binary is absent or older, keeps it when the same, and refuses when
  the server's is newer — then hands off to that version if it is installed
  under `~/.local/share/kasbah/<version>/` (`internal/launcher`). No protocol
  negotiation exists: a `kasbah remote` arm may change in any release.
  `remote version` prints `build=<stamp>` and readers ignore unknown keys.
- **YAML reads as kislyuk `yq` 3.1.0 printed it** — plain scalars per YAML 1.2
  (`yes`/`on` are strings) but `0755` octal, numbers in jq 1.7's spelling.
  `internal/yamlx` + `internal/jv` reproduce it (goldens from the real yq);
  parse a file once and query the tree, never re-parse per rule.
- **Output is locale-independent**: ASCII names and schemes, UTF-8 character
  counts, byte-order lists.
- **Signals:** every workstation command, and every server-side arm that leaves
  something to clean up, calls `atexit.HandleSignals()` and leaves through
  `atexit.Exit`, so temp files, the ssh master and terminal echo are cleaned on
  a signal. Every server-side step that changes state ignores SIGHUP/SIGPIPE,
  so a dropped session never leaves it half-done.
- **CRLF tolerance:** strip `\r` before matching any user-authored file.
- **Interactive, never assume:** an unset flag means *prompt*, not *no*.
  Every prompt has a `--with-x`/`--no-x` (or `--yes`) pair; without a TTY,
  an unanswered prompt is a hard fail naming the flag.
- **Compose:** files are `compose.yml` (never docker-compose.yml), no
  `version:` attribute.
- **Shell scripts:** every executed Bash script runs under `set -uo pipefail`,
  and `-e` too except `test.sh` and the `*_test.sh` suites, which count failures
  rather than stop at the first; under pipefail never pipe a producer into
  `grep -q` — capture, then `grep -q <<<`.
  `get.sh` is the exception: POSIX `sh` run as `curl | sh` (dash, busybox ash,
  posh), so `set -eu`, no pipefail, and the token never on any command's argv.
- **Tests land with the code they test, in the same change.**
- **Docs are the spec:** when implementation contradicts a doc, fix the
  doc in the same change — never let them drift.

## Frozen contracts — never rename

`kasbah-net`; entrypoints `web`/`websecure`; certresolver `letsencrypt`;
the `_shared.yml` middleware names; `versions.log`'s four positional
fields (new data = appended `key=value` pairs); the `KASBAH_` env-var
prefix (reserved, injected at deploy, exempt from drift); the manifest schema
(1, frozen at 1.0.0 — a change goes through `kasbah migrate`); release tags
`vMAJOR.MINOR.PATCH` and assets `kasbah_<ver>_linux_<arch>`, `get.sh`,
`checksums.txt`, `checksums.txt.minisig`; the installer URL
`https://github.com/adigourdi/kasbah/releases/latest/download/get.sh`.

## Layout

- `cmd/kasbah` — the CLI entry; `internal/` — one package per concern
  (`internal/remote` and each command's `remote.go` are the server side);
  `tools/stamp` — the build stamp.
- `templates/` — files kasbah renders onto servers, embedded in the binary.
- `tests/` — black-box `*_test.sh` suites (`tests/cli.sh` resolves `KASBAH_BIN`);
  `tests/rig/` fake VPS; `tests/integration/` rig-driven; `tests/fixtures/` sample projects.
- `README.md` is the project's front page; `CONTRIBUTING.md` covers building,
  testing and releasing for people.
- `docs/` — the spec, indexed by `docs/README.md`; `compliance.md` is the rule
  catalog, `files.md` lists every file kasbah writes, and `install.md` owns
  every install path.
- `docs/phases/` — build plan; phase Findings sections are the project's memory of traps. Read the relevant phase file before touching its area.
- `docs/research/` — dated competitive/background notes. **Not spec, not normative**; acted on by lifting findings into a spec doc, the roadmap, or the backlog.
