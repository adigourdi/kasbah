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

## Findings

_(filled during execution)_
