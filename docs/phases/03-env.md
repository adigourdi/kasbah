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
- [x] `lib/env.sh` — **there is no wrapper to generate.** The file is dual-mode:
      sourced as a library locally, and the same bytes rsynced to the VPS as
      `scripts/setup-env.sh` and executed there (unit C ships it). That is what
      makes 3.3's "one shared drift function" literally true rather than two
      copies that agree today. Cost: nothing in this file may source
      `common.sh`, read `HOSTING_LIB_DIR`, or call `info`/`warn`/`err`/`die`
- [x] Behavior byte-identical on the original project's fixtures — **25 cases, 25
      byte-identical `.env`, 25 identical exit codes, 25 identical
      ANSI-stripped transcripts, 0 diffs.** The 13 upstream cases plus the
      generator in three shapes, `$`→`$$`, masking, missing template, unknown
      line formats, and EOF at each of the two menus. Re-run unchanged after
      every fix in the review round

**Watch out for:** the `$` → `$$` escaping on output and masked
`read -rs` prompts — both are load-bearing and easy to lose in a
"cleanup" port. Resist refactoring; the spec says verbatim.

### 3.2 — Port `test-setup-env.sh` → `tests/env_test.sh` (S)
Same fixtures, same stdin-piping technique, wired into `./test.sh`.

**Deliverables**
- [x] All coverage cases from `env-template.md` § Testing present and green —
      `tests/env_test.sh`, the 13 upstream cases plus 11 more, ~125 assertions,
      2.3 s. Hermetic: no reference to the original project's checkout, no Docker, no
      network

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

## Execution order

Three units, each one brief / one review / one commit.

| Unit | Tasks | Contents |
|---|---|---|
| A | 3.1 + 3.2 | `lib/env.sh` (the port) + `tests/env_test.sh`, wired into `./test.sh` |
| B | 3.3 | Shared drift function, `HOSTING_` exemption, E05, `env_inject_hosting_vars` |
| C | 3.4 | `ssh_run_tty`, `hosting env`, deploy wiring, integration test |

## Decisions settled at execution time

- **Exit 5 widens** rather than a new code being added. `cli.md` reserved it for
  "drift the user declined to fix"; it now reads "env setup could not
  complete", which covers both that and a missing `.env` with no TTY to fix it.
  This is the Phase 2 carry-in below, settled. One code, and `04-ship.md`'s
  "exit codes match cli.md" criterion stays one row.
- **A `HOSTING_`-prefixed key in a project's `.env.prod.example` is E05, warn
  level.** Every other E rule is a warning and `compliance.md` says the check is
  a linter, not a gatekeeper — a fail here would be the only env rule able to
  push `check` to exit 6. Setup skips the key; injection owns it.
- **The drift prompt's flag is `--on-drift=setup|continue|abort`**, not a
  `--with-x`/`--no-x` pair. The prompt has three answers and the boolean form
  leaves *abort* unrequestable, which is the one a scripted deploy wants.
- **Injection strips strays.** The managed block is sentinel-delimited and any
  `HOSTING_*` line outside it is removed. The alternative — leave and warn —
  means two lines set one variable and the last wins, so the effective limit can
  differ from the marker's silently.
- **`lib/env.sh` is dual-mode and *is* the shipped artifact.** See 3.1 above.

## Findings

### From unit A — the port

- **`|| true` on the two value reads is the non-interactive contract, and
  nothing tested it.** Template `A=1 B=2 C=3` with one newline of stdin: with
  `|| true`, exit 0 and a complete `.env`; without, exit 1 and **no `.env` at
  all**. That is precisely the shape a headless `hosting deploy` produces on the
  far side — stdin runs out mid-run and the remaining template defaults are
  accepted. Every ported fixture fed exactly as many answers as there were
  prompts, so no case ever reached EOF inside a value read, and the mutant
  survived the whole suite. Both halves are now pinned.

- **Errexit is this file's contract, which makes `|| rc=$?` a trap rather than
  defensive coding.** The two menu reads are the only ones *without* `|| true`,
  so "EOF at the menu aborts, leaving `.env` untouched" is an errexit behaviour
  and nothing else. Put `env_setup_run` on the left of `||` or `&&` — as this
  phase's own first brief prescribed — and bash switches errexit off for the
  entire function body: the failed menu read then falls through and exit 1
  becomes exit 0, reporting "up to date" over a file it never wrote. The call in
  `env_main` is bare on purpose, and unit C's subcommand dispatch must be too.

- **`env_setup_run` can kill the caller's process, not merely return.** Sourced,
  bare-called, EOF at the update menu: errexit fires inside the function and the
  whole shell exits 1 mid-menu. Correct, but the function's own contract comment
  said "returns 1 when the template is missing, 0 otherwise" — the exact comment
  unit C would have believed while wiring 3.4's no-TTY hard fail.

- **Three comments arrived false, inherited verbatim.** The sharpest:
  `# substring check — [[ "! x" == "! "* ]] fails due to ! negation`. It does
  not fail; `bash -c '[[ "! x" == "! "* ]]'` matches. A comment naming a
  rationale the code does not have is the thing later cited as a reason not to
  touch working code. Also struck: "lines starting with `#` are … skipped"
  (they are preserved, as `env-template.md` says) and the `env_setup_run`
  contract above. **A verbatim port copies the comments' claims along with the
  code, and those claims get a review this repo's conventions apply, not the
  origin repo's.**

- **Counting mutations again beat reading assertions, and the yield was in the
  features nobody doubted.** 49 mutants, 48 killed. Deleting the *entire*
  section-header branch survived the first suite — both the header and the
  free-form-comment branch end in the same `OUTPUT_LINES+=("$line")`, so the
  "section header survives into .env" assertion passed identically for a header,
  a plain comment, or no header branch at all. So did widening `[-=]{3,}` to
  `{4,}`, neutering `SUPPRESS_HEADERS`, and both `has-existing` prompt branches
  (cases that *looked* like they covered them ran in update-only mode, where the
  value is auto-accepted before the branch is reached). Five real gaps in a
  feature the spec documents by name.

- **The one surviving mutant is genuinely equivalent, and so are four others.**
  Stripping `\r` in the template-key loop is unobservable: that loop's regex is
  `^([A-Za-z_][A-Za-z0-9_]*)=`, prefix-anchored, so a `\r` can only land after
  the `=` and never enters the captured key. Kept anyway for uniform handling
  across the three readers of user-authored files. Recorded because "survivor"
  and "defect" are not the same word.

- **`script(1)` without `-f` buffers the typescript until the child exits.** A
  pty test that polls the transcript for a prompt therefore never sees one and
  burns its full timeout — the suite went to 87 s while staying green. With
  `-f`, 1.9 s, faster than the fixed `sleep 0.4` it replaced (which was itself a
  race: a loaded machine needing >0.4 s to reach `read` echoes the secret).

- **`declare` inside a function is local, so six arrays quietly became
  function-scoped** — a sixth divergence from the original, beneficial, and the
  reason `${#NEW_KEYS[@]}` cannot go stale across repeat calls in one shell.
  Documented and pinned.

- **`env-template.md` § Testing was right and the upstream test was wrong.** Its
  "empty value preserved in update mode" case never entered update mode (its
  fixture had no drift, so it exited early and asserted a file nothing touched);
  two of its three assertions could not fail. The doc needed no change — the
  test did.

### Carried into 3.3, with the evidence warm

- **`lib/env.sh` and `lib/check.sh` disagree about a file with no trailing
  newline.** All three of `env.sh`'s read loops drop a final unterminated line;
  `check.sh:654` and `:706` read the *same* `.env.prod.example` with
  `|| [ -n "$line" ]`. So `check` sees a key `env.sh` does not, and a `.env`
  whose last line lacks `\n` loses that live value on reconfigure. Inherited
  verbatim, so unit A left it alone — but 3.3 owns `env_extract_keys` and the
  shared drift function, and cannot make one function serve both readers
  without picking a side. Pick it, and test it.
