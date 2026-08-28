# kasbah

Bash CLI that turns a plain VPS into a multi-project Docker host
(Traefik file-provider routing, registry-less image shipping over SSH).
`docs/` is the spec and the source of truth; `docs/phases/` is the build
plan and the only progress tracker (the roadmap is scope, not status).

## Commands

- `./test.sh` — unit suites (fast, no server needed). Must pass before any commit.
- `KASBAH_RIG_TESTS=1 ./test.sh` — adds integration tests against the
  fake-VPS rig. Run `tests/rig/rig.sh up` first; see `tests/rig/README.md`
  for what the rig can and cannot prove. Exit 2 means the environment is
  wrong (rig down), not that a test failed.
- `bin/kasbah <cmd>` — run the CLI from the checkout (repo detection via the `install.sh` sibling; no install needed).

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

- `bin/kasbah` — dispatcher; `lib/*.sh` — one file per concern, sourced lazily.
- `templates/` — files kasbah renders onto servers.
- `tests/` — `*_test.sh` unit suites; `tests/rig/` fake VPS; `tests/integration/` rig-driven; `tests/fixtures/` sample projects.
- `docs/` — the spec; start with `overview.md` (decisions table) and `compliance.md` (rule catalog).
- `docs/phases/` — build plan; phase Findings sections are the project's memory of traps. Read the relevant phase file before touching its area.
