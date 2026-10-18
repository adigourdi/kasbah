# kasbah

CLI that turns a plain VPS into a multi-project Docker host
(Traefik file-provider routing, registry-less image shipping over SSH).
Written in Bash, being ported to Go strangler-style (`docs/phases/10-recast.md`):
the Go binary is `kasbah` and hands every command it does not own yet to
the Bash dispatcher, `libexec/kasbah-bash`.
`docs/` is the spec and the source of truth; `docs/phases/` is the build
plan and the only progress tracker (the roadmap is scope, not status).

## Commands

- `./test.sh` — Go checks, a build of `dist/`, then the unit suites (~10 min,
  needs Docker, no server). Must pass before any commit. `KASBAH_BIN=<path>`
  tests that binary instead and skips the build.
- `KASBAH_RIG_TESTS=1 ./test.sh` — adds integration tests against the
  fake-VPS rig. Run `tests/rig/rig.sh up` first; see `tests/rig/README.md`
  for what the rig can and cannot prove. Exit 2 means the environment is
  wrong (rig down), not that a test failed.
- `docker compose run --rm build` — `dist/kasbah` plus the linux/amd64 and
  linux/arm64 server binaries in `dist/server/`; `docker compose run --rm test`
  — vet, gofmt, `go test`. Inner loop: `docker compose up -d dev`, then
  `docker compose exec dev go test ./...`. No Go on the host: the version
  lives in `compose.yml` alone. Build from the main checkout — a git worktree's
  `.git` points outside the mounted tree and the version stamp fails.
- `dist/kasbah <cmd>` — run the CLI from the checkout (repo detection via the `install.sh` sibling; no install needed).
- Versions: files kasbah writes record `VERSION`; `--version` prints the build
  stamp (`KASBAH_BUILD`: `VERSION` + commit count, + build time when dirty).

## Hard conventions

- **yq is the kislyuk wrapper (jq dialect).** Never write mikefarah v4
  syntax (`type == "object"`, `to_entries[]`, `sub("a";"b")` are jq forms
  and correct here).
- **Read a YAML file once, never per rule.** `yq` is Python — ~180 ms a
  fork. `yaml_load`/`yaml_query` (`lib/common.sh`) convert a file once and
  answer every question with `jq`. A command substitution cannot fill that
  cache, so load in the shell the rules run in; invalidation is explicit —
  whatever rewrites a file it has read calls `yaml_forget`.
- **Bash:** `set -euo pipefail` everywhere; libs are sourced with load
  guards (`_KASBAH_X_LOADED`). Under pipefail, never pipe a producer
  into `grep -q` (SIGPIPE race) — capture to a variable, then
  `grep -q <<<`. Functions ending in a `read` loop pin `return 0`.
- **CRLF tolerance:** strip `\r` before matching any user-authored file.
- **Interactive, never assume:** an unset flag means *prompt*, not *no*.
  Every prompt has a `--with-x`/`--no-x` (or `--yes`) pair; without a TTY,
  an unanswered prompt is a hard fail naming the flag.
- **Compose:** files are `compose.yml` (never docker-compose.yml), no
  `version:` attribute.
- **Tests land with the code they test, in the same change.**
- **Docs are the spec:** when implementation contradicts a doc, fix the
  doc in the same change — never let them drift.

## Frozen contracts — never rename

`kasbah-net`; entrypoints `web`/`websecure`; certresolver `letsencrypt`;
the `_shared.yml` middleware names; `versions.log`'s four positional
fields (new data = appended `key=value` pairs); the `KASBAH_` env-var
prefix (reserved, injected at deploy, exempt from drift).

## Layout

- `cmd/kasbah`, `internal/` — the Go binary; `tools/stamp` — the build stamp.
- `libexec/kasbah-bash` — Bash dispatcher; `lib/*.sh` — one file per concern, sourced lazily.
- `templates/` — files kasbah renders onto servers.
- `tests/` — `*_test.sh` unit suites (`tests/cli.sh` resolves `KASBAH_BIN`); `tests/rig/` fake VPS; `tests/integration/` rig-driven; `tests/fixtures/` sample projects.
- `docs/` — the spec; start with `overview.md` (decisions table) and `compliance.md` (rule catalog).
- `docs/phases/` — build plan; phase Findings sections are the project's memory of traps. Read the relevant phase file before touching its area.
- `docs/research/` — dated competitive/background notes. **Not spec, not normative**; acted on by lifting findings into a spec doc, the roadmap, or the backlog.
