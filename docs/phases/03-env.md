# Phase 3 — Env

> The interactive env template system is hosting's: ported verbatim with
> its tests, drift detection shared, and `HOSTING_*` injection working
> with the reserved-prefix exemption.

**Prerequisite:** Phase 0. **Parallel-safe with Phases 1–2** — pure local
bash and unit tests, disjoint files. Integrates with deploy at the end of
whichever finishes later.
**Spec:** `docs/env-template.md` (the whole file), `docs/compliance.md` (E rules, `HOSTING_` exemption), `docs/server-setup.md` (Resource limits section)

## Exit criteria
- [ ] `tests/env_test.sh` green — full coverage list from `env-template.md` preserved
- [ ] Drift detection is one shared function used by `check` (E02/E03) and the deploy path
- [ ] `HOSTING_*` keys are invisible to drift in both directions and never prompted
- [ ] `hosting env user@host` runs the interactive setup remotely

## Tasks

### 3.1 — Port `setup-env.sh` → `lib/env.sh` (M)
Verbatim port from the original project's `scripts/setup-env.sh` (331 lines,
battle-tested — `env-template.md` explicitly says don't redesign it).
Only packaging changes: sourced lib + a thin standalone wrapper that
deploys ship to the VPS as `scripts/setup-env.sh`.

**Deliverables**
- [ ] `lib/env.sh` + the VPS-side wrapper generation
- [ ] Behavior byte-identical on the original project's fixtures

**Watch out for:** the `$` → `$$` escaping on output and masked
`read -rs` prompts — both are load-bearing and easy to lose in a
"cleanup" port. Resist refactoring; the spec says verbatim.

### 3.2 — Port `test-setup-env.sh` → `tests/env_test.sh` (S)
Same fixtures, same stdin-piping technique, wired into `./test.sh`.

**Deliverables**
- [ ] All coverage cases from `env-template.md` § Testing present and green

### 3.3 — Drift function + `HOSTING_*` injection (S)
Extract the key-diff into one function; exclude the `HOSTING_` prefix
from both comm sides; add `env_inject_hosting_vars` that writes/refreshes
a managed block in `.env` from the server marker's limits.

**Deliverables**
- [ ] `check` E02/E03 and the deploy drift path call the same function
- [ ] Injection is idempotent (second run = no diff) and survives user edits elsewhere in `.env`
- [ ] Unit test: `.env` with extra `HOSTING_CPU_LIMIT` shows no drift

**Watch out for:** injection must not reorder or rewrite the rest of
`.env` — users edit it by hand; touch only the managed block.

### 3.4 — `hosting env` command + deploy wiring (S)
Rsync template, run remote setup over `ssh -t`; wire the drift check +
prompt (re-run / continue / abort, per `build-deploy.md` step 6) and the
injection into the deploy path from Phase 2.

**Deliverables**
- [ ] Missing `.env` on deploy → interactive setup fires (manual rig check)
- [ ] Integration test covers the non-interactive path: pre-seeded `.env` + drift → deploy fails with exit 5, no hang

**Watch out for:** `ssh -t` breaks when the local side has no TTY — the
interactive path needs a TTY end to end; without one, fall back to the
exit-5 hard fail (cross-phase rule 1), never a hung prompt.

## Carried in from Phase 2

Two things unit D left for this phase, with the evidence warm:

- **There is no exit code for "remote `.env` missing".** `docs/cli.md`
  reserves 5 for *drift the user declined to fix*, which is a different
  thing, so the thin deploy uses 1 and names the file. Settle it here —
  either widen 5's meaning in `cli.md` or add a code — because 3.4 is
  where that branch is replaced by the interactive setup, and after that
  the missing-`.env` case stops being reachable in the same shape.

- **The `HOSTING_*` seam is a hand-seeded pair of variables.** Phase 2's
  fixture `.env` carries `HOSTING_CPU_LIMIT` and `HOSTING_MEM_LIMIT`
  written by the test, because `compose up` fails on an unset variable and
  injection does not exist yet. Task 3.3 is what replaces that seeding.
  Note the values are seeded as `0`, not as the marker's real `14.4`/`54g`
  — **the rig cannot apply cgroup limits at all** (see
  `tests/rig/README.md`), so any real limit makes the container fail to
  start. Injection must therefore keep working when the values it writes
  are ones the host cannot honour, and the integration test for it has to
  probe rather than assume. R01/R02 enforcement is Phase 6's to prove.

- **The `HOSTING_` drift exemption is documented but not implemented, and
  Phase 2 made it reachable.** `compliance.md` and `env-template.md` both
  say `HOSTING_`-prefixed keys are exempt from E02/E03 and from drift;
  `lib/check.sh` diffs raw key sets with no prefix filter. It was
  unreachable until this phase's fixture seeded `HOSTING_CPU_LIMIT` and
  `HOSTING_MEM_LIMIT` into a `.env`, which now produces
  `⚠ .env has extra keys not in .env.prod.example: HOSTING_CPU_LIMIT
  HOSTING_MEM_LIMIT`. Warn-level, so exit stays 0 — but task 3.3 already
  owns the fix and its test ("`.env` with extra `HOSTING_CPU_LIMIT` shows
  no drift"). Do it there, and check both directions: the exemption has to
  hold for a key *missing* from the template as well as one *extra* in the
  `.env`.

- **The `.env` precondition is checked before anything is shipped, and
  that ordering is load-bearing.** Unit D originally checked it after the
  rsyncs and observed the result: the Traefik fragment was already live,
  pointing at a container that never started, so `demo.test` served a
  permanent 502. When 3.4 replaces the precondition with the interactive
  setup, keep it in the same position — nothing may reach
  `<apps>/traefik/dynamic/` until the deploy is known to be able to finish.

## Findings

_(filled during execution)_
