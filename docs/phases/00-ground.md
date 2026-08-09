# Phase 0 — Ground ✅ done

> The local half of the tool exists and is tested: a project can be
> scaffolded and validated against the full rule set, and every design
> decision is written down.

**Prerequisite:** none.
**Spec:** `docs/overview.md`, `docs/project-manifest.md`, `docs/compliance.md`, `docs/traefik.md`

Recorded retroactively — this phase happened before the plan existed. Kept
so `/tackle` and future phases inherit its evidence and findings.

## Exit criteria
- [x] `./test.sh` passes all suites (check, init-project, manifest)
- [x] `hosting init-project` + `hosting check` work end-to-end on a fresh directory
- [x] Every design decision in this conversation's docs pass is reflected in `docs/*.md`

## Tasks

### 0.1 — Repo scaffold, install, self-version (S) ✅
**Evidence:** commits `9e4cb16`, `e84e4f4` — `bin/hosting`, `lib/`, `install.sh`, `test.sh`, `VERSION`.

### 0.2 — Dispatcher, init-project, state module (M) ✅
**Evidence:** commit `1a4f8a2` — symlink-safe self-resolution, `state_init`, rollback-safe scaffold with ERR-trap cleanup.

### 0.3 — Manifest reader with schema gate (M) ✅
**Evidence:** commit `56e97e3` + `tests/manifest_test.sh` — refuses schemas newer than the binary.

### 0.4–0.6 — `hosting check`, grown rule-group per commit (L) ✅
**Evidence:** commits `0bbab11` (S rules), `5d98ec8` (C rules), `1c9a57c` (T/H/E/HK rules) + `tests/check_test.sh`.

### 0.7 — File-provider routing decision (M) ✅
**Evidence:** commit `765972c` — docker labels rejected (T06), fragments + `_shared.yml` model in `docs/traefik.md`.

### 0.8 — Agency docs pass + check rework (L) ✅ *(working tree, uncommitted)*
Network split (C03/C07, T07), resource rules (R01–R03), retention =
3 months ∪ last-3-versions, drop/`--prune`/`server destroy` lifecycle,
server marker + same-major compat policy, off-VPS backup design
(`docs/backup.md`), interactivity rule, roadmap de-tracked, init-project
snippet updated. Tests reworked and green (22-rule golden path).
**Evidence:** current working tree; `./test.sh` PASS ×3. **Commit before Phase 1.**

### 0.9 — CLAUDE.md + minimal README (S) ✅
Repo conventions for agents (yq dialect, bash discipline, frozen
contracts, interactivity rule) and a status-honest README with install +
what-works-today.
**Evidence:** working tree (written during planning). Roadmap 1.5's full
walkthrough README waits until there's a deploy to walk through.

## Findings

- The installed `yq` is the **kislyuk wrapper** (jq dialect), not mikefarah
  v4 — all rule expressions are jq. This is a hard dependency of every
  future yq call.
- Under `set -euo pipefail`, piping a producer into `grep -q` races
  (SIGPIPE → pipefail → errexit). Pattern: capture to a variable, then
  `grep -q <<<`. Same for functions whose final `read` returns 1 — pin
  `return 0`.
- CRLF tolerance matters twice already (`.gitignore`, manifest) — strip
  `\r` before matching anywhere user-authored files are read.
- `container_name` is host-unique (Docker hard-errors duplicates); service
  names become DNS aliases on every joined network. This asymmetry is why
  T07 targets container names and C07 bans the default-alias shape.
- The check suite is slow (~2 min) because kislyuk yq spawns Python per
  call — dozens of calls per check run. Acceptable for now; if it hurts,
  batch yq calls per file rather than per service.
