# Build Plan — hosting

Phased plan for taking hosting from "local half done" (scaffold, manifest,
check) to both real consumers migrated (the original PHP project, the homelab). Produced by
`/phase-out` from `docs/*.md`; executed by `/tackle`. Each phase file is
self-contained: deliverables verbatim, spec links inline, findings filled
during execution.

## Phases

| # | Phase | State of the thing at the end |
|---|---|---|
| 0 | [Ground](00-ground.md) | **Done.** Scaffold, install, manifest/state, init-project, full `check`, docs corpus with all decisions |
| 1 | [Rig](01-rig.md) | **Done.** A fake VPS (DinD container: sshd + dockerd) with reset script and integration-test runner |
| 2 | [Spine](02-spine.md) | `server init` + thin `deploy` work against the rig: a stock project serves through Traefik via file-provider fragment |
| 3 | [Env](03-env.md) | Env template system ported with tests; drift + `HOSTING_*` injection. *Parallel-safe with 1–2* |
| 4 | [Ship](04-ship.md) | `build-push` + full `deploy` (hooks, backup, health, flock, digests): a custom-built app ships to the rig |
| 5 | [Undo](05-undo.md) | `rollback` + `history` / `pending` / `changelog` |
| 6 | [Proof](06-proof.md) | **The real milestone.** A real project (deliberately unnamed) on a freshly provisioned VPS: bare host → HTTPS with real ACME, change deploy, rollback — hosting only |
| 7 | [Operate](07-operate.md) | Mail port, `logs`/`exec`, `check --server`, `upgrade-traefik`, `server prune`, full `server status` |
| 8 | [Keep](08-keep.md) | `drop [--prune]`, `server destroy`, `--with-backup` (restic), `check --fix` |
| 9 | [Adopt](09-adopt.md) | Both existing consumers migrated: the original project (scripts/ deleted, mail included, live cutover) and lab (RPi stacks as hosting projects) |

## The real milestone

**Phase 6 — Proof.** A greenfield deployment: a real project hosting was
*not* extracted from, on a VPS that starts bare. Migrating the original project
would prove little — the tool fits it by construction — so the origin
projects migrate later (Phase 9), and Proof is the honest test.
Everything after is post-milestone: operational breadth (7), lifecycle
safety (8), and the existing consumers (9, where the roadmap's own exit
criteria land). If time pressure ever forces a cut, cut from the tail,
never from 1–6.

## Sequencing rationale

Vertical slices, not capability silos: each phase takes thin cuts across
commands to end at something observable. The rig comes first because the
chosen exit bar is "works against a container that plays VPS" — it is the
last-mile equivalent that makes every later phase checkable. Spine goes
straight through the one live unknown (file-provider-only Traefik routing
via `container_name`, no docker socket — never run by either reference
repo) against a throwaway fixture, so a routing-model failure costs a day
instead of a Ship rework. Within phases, tasks keep the repo's established
rhythm: one capability slice per task, tests landing with it.

## Parallelism

- **Phase 3 (Env) ∥ Phases 1–2** — pure local bash + tests, zero server
  dependency, disjoint files. One agent on Rig/Spine, another on Env.
- Everything else is sequential at the phase level. Parallel-safe tasks
  inside a phase are marked individually.

## Cross-phase rules

1. **Interactive, never assume.** An unset flag means *prompt*, not *no*
   (`overview.md` → Interactivity). Every prompt has a `--with-x`/`--no-x`
   flag pair; without a TTY an unanswered prompt is a hard fail naming the
   flag. This is also what lets the rig tests drive everything headless.
2. **Frozen contracts — never rename:** `hosting-net`, entrypoints
   `web`/`websecure`, certresolver `letsencrypt`, `_shared.yml` middleware
   names, versions.log's four positional fields, the `HOSTING_` env prefix.
3. **yq is the kislyuk wrapper (jq dialect).** Do not write mikefarah v4
   syntax — it will parse differently or not at all.
4. **Bash discipline:** `set -euo pipefail` everywhere; mind SIGPIPE with
   `grep -q` under pipefail (capture first, then grep — see check.sh
   comments); helpers sourced with load guards.
5. **Tests land with the code, same phase.** Unit suite: `./test.sh`
   (fast, no rig). Integration suite: requires the rig, opt-in via
   `HOSTING_RIG_TESTS=1 ./test.sh` (wired in Phase 1).
6. **Docs are the spec.** When reality disagrees, fix the doc in the same
   phase — reconciliation is part of every phase's exit bar.
7. **Compose conventions:** files named `compose.yml` (not
   docker-compose.yml), no `version:` attribute.
8. **VPS-side helpers are hosting-owned** and overwritten on every deploy;
   projects never vendor hosting bash.

## Before starting Phase 1 ✅

Phase 0's final act is committed (`7ea63e1`, `7c5f7d1`, `f8fe1cf`), so
task baselines are clean. Unit-suite baseline at the start of Phase 1:
`./test.sh` PASS ×3 in 1m52s.

## Re-read notes

Phases 1–4 are specified tightly. **7–9 are deliberately lighter and need
a re-read before starting.** The likeliest reorder trigger is what Phase 6
learns on first contact with real infrastructure (ACME, DNS, TTY quirks,
where the tool pinches on a non-fixture project); the second is Phase 9's
two live cutovers (label→fragment Traefik swap with `acme.json` reuse)
and its open question — cert strategy on a LAN host where HTTP-01 can't
reach (DNS-01 vs internal CA), recorded in `09-adopt.md`.
