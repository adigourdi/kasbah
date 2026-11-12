# Phase 3 — Env

> The interactive env template system is kasbah's: ported verbatim with
> its tests, drift detection shared, and `KASBAH_*` injection working
> with the reserved-prefix exemption.

**Prerequisite:** Phase 0. **Parallel-safe with Phases 1–2** — pure local
bash and unit tests, disjoint files. Integrates with deploy at the end of
whichever finishes later.
**Spec:** `docs/env-template.md` (the whole file), `docs/compliance.md` (E rules, `KASBAH_` exemption), `docs/server-setup.md` (Resource limits section)

## Exit criteria

Walked by hand at phase close, one at a time, against the real artifact — not
inferred from the suites having passed.

- [x] `tests/env_test.sh` green — full coverage list from `env-template.md`
      preserved. All 13 doc-listed cases mapped to cases in the suite by the
      group reviewer, none missing; 11 more added beyond them
- [x] Drift detection is one shared function used by `check` (E02/E03) and the
      deploy path — literally, not nominally. `lib/check.sh:679` calls
      `env_drift`; the deploy path never re-implements it, because
      `lib/env_cmd.sh` asks the *far side* (`lib/env.sh:629`, the `--drift`
      dispatch) and the far side is the same file byte-for-byte. The rig
      asserts that identity with `sha256sum` rather than trusting it
- [x] `KASBAH_*` keys are invisible to drift in both directions and never
      prompted — a `.env` carrying `KASBAH_MEM_LIMIT` against a template
      carrying `KASBAH_CPU_LIMIT` reports `MISSING=[] EXTRA=[]`, and a setup
      run over it prompts for the reserved prefix zero times
- [x] `kasbah env user@host` runs the interactive setup remotely — hand-walked
      from a real pty (see 3.4), and `tests/env_cmd_test.sh` drives the command
      behind `script(1)` asserting the `-t` reaches ssh

Final: `KASBAH_RIG_TESTS=1 ./test.sh` **17/17 PASS** in 5m49s; `./test.sh`
13/13. The 25-case differential against the origin script is unmoved at
`25 identical, 0 differing` through all three units and both close rounds.

**Not proven here.** The masked `read -rs` over an *ssh* pty: masking is
pinned locally against a real pty, but the far side's `stty` in an `ssh -t`
session is untested, and only real infrastructure settles it. And the
interactive path is single-witness — one hand-walk, one rig. The suites prove
kasbah asks ssh for a pty, and prove the shipped script renders a `.env` when
driven headless; nothing automated proves a human typing into `ssh -t` and the
value landing. That gap is structural and is recorded rather than papered over.

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
      `common.sh`, read `KASBAH_LIB_DIR`, or call `info`/`warn`/`err`/`die`
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

### 3.3 — Drift function + `KASBAH_*` injection (S)
Extract the key-diff into one function; exclude the `KASBAH_` prefix
from both comm sides; add `env_inject_kasbah_vars` that writes/refreshes
a managed block in `.env` from the server marker's limits.

**Deliverables**
- [x] `check` E02/E03 and the deploy drift path call the same function —
      `env_drift` in `lib/env.sh`, which `check.sh` sources and which the VPS
      runs as the same bytes. `kasbah check` diffed against `95b3241` over five
      fixtures: every difference is one added E05 pass line and the incremented
      total, nothing else
- [x] Injection is idempotent (second run = no diff) and survives user edits
      elsewhere in `.env` — `cmp`-verified byte-identical from run 2 on every
      awkward fixture, not just a tidy one: two blocks, CRLF throughout, a block
      at the top, an unterminated begin sentinel, trailing spaces, an unknown
      line, a comment-led tail
- [x] Unit test: `.env` with extra `KASBAH_CPU_LIMIT` shows no drift — and the
      other direction too, a reserved key in the template but absent from `.env`

**Watch out for:** injection must not reorder or rewrite the rest of
`.env` — users edit it by hand; touch only the managed block.

### 3.4 — `kasbah env` command + deploy wiring (S)
Rsync template, run remote setup over `ssh -t`; wire the drift check +
prompt (re-run / continue / abort, per `build-deploy.md` step 6) and the
injection into the deploy path from Phase 2.

**Deliverables**
- [x] Missing `.env` on deploy → interactive setup fires — **hand-walked
      against the rig from a real pty at phase close.** Clean rig → `server
      init` → a fixture with no `.env` on the server → `kasbah deploy` under
      `script(1)`, one line of input. The generator prompted for
      `DEMO_GREETING` over `ssh -t`, the typed value landed in
      `<apps>/demo/.env` with the template's comments and section header
      preserved, the managed block was injected beneath it from the marker,
      `docker inspect demo-web` showed
      `DEMO_GREETING=typed-at-a-real-terminal` in the container's own
      environment, and `curl -H 'Host: demo.test'` returned the fixture page
      through Traefik. Exit 0; `versions.log` well-formed
- [x] Integration test covers the non-interactive path: pre-seeded `.env` +
      drift → deploy fails with exit 5, no hang — the exit-5 assertion is
      bounded by `timeout` and asserts `rc != 124`, so "no hang" is observed
      rather than assumed. `--on-drift=abort` (5) and `--on-drift=continue`
      (0) are covered beside it, with a revert-to-sync control proving the
      deploy stops mentioning drift

**Watch out for:** `ssh -t` breaks when the local side has no TTY — the
interactive path needs a TTY end to end; without one, fall back to the
exit-5 hard fail (CLAUDE.md, "Interactive, never assume"), never a hung
prompt.

## Carried in from Phase 2

Two things unit D left for this phase, with the evidence warm:

- **There is no exit code for "remote `.env` missing".** `docs/cli.md`
  reserves 5 for *drift the user declined to fix*, which is a different
  thing, so the thin deploy uses 1 and names the file. Settle it here —
  either widen 5's meaning in `cli.md` or add a code — because 3.4 is
  where that branch is replaced by the interactive setup, and after that
  the missing-`.env` case stops being reachable in the same shape.

- **The `KASBAH_*` seam is a hand-seeded pair of variables.** Phase 2's
  fixture `.env` carries `KASBAH_CPU_LIMIT` and `KASBAH_MEM_LIMIT`
  written by the test, because `compose up` fails on an unset variable and
  injection does not exist yet. Task 3.3 is what replaces that seeding.
  Note the values are seeded as `0`, not as the marker's real `14.4`/`54g`
  — **the rig cannot apply cgroup limits at all** (see
  `tests/rig/README.md`), so any real limit makes the container fail to
  start. Injection must therefore keep working when the values it writes
  are ones the host cannot honour, and the integration test for it has to
  probe rather than assume. R01/R02 enforcement is Phase 6's to prove.

- **The `KASBAH_` drift exemption is documented but not implemented, and
  Phase 2 made it reachable.** `compliance.md` and `env-template.md` both
  say `KASBAH_`-prefixed keys are exempt from E02/E03 and from drift;
  `lib/check.sh` diffs raw key sets with no prefix filter. It was
  unreachable until this phase's fixture seeded `KASBAH_CPU_LIMIT` and
  `KASBAH_MEM_LIMIT` into a `.env`, which now produces
  `⚠ .env has extra keys not in .env.prod.example: KASBAH_CPU_LIMIT
  KASBAH_MEM_LIMIT`. Warn-level, so exit stays 0 — but task 3.3 already
  owns the fix and its test ("`.env` with extra `KASBAH_CPU_LIMIT` shows
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
| B | 3.3 | Shared drift function, `KASBAH_` exemption, E05, `env_inject_kasbah_vars` |
| C | 3.4 | `ssh_run_tty`, `kasbah env`, deploy wiring, integration test |

## Decisions settled at execution time

- **Exit 5 widens** rather than a new code being added. `cli.md` reserved it for
  "drift the user declined to fix"; it now reads "env setup could not
  complete", which covers both that and a missing `.env` with no TTY to fix it.
  This is the Phase 2 carry-in below, settled. One code, and `04-ship.md`'s
  "exit codes match cli.md" criterion stays one row.
- **A `KASBAH_`-prefixed key in a project's `.env.prod.example` is E05, warn
  level.** Every other E rule is a warning and `compliance.md` says the check is
  a linter, not a gatekeeper — a fail here would be the only env rule able to
  push `check` to exit 6. Setup skips the key; injection owns it.
- **The drift prompt's flag is `--on-drift=setup|continue|abort`**, not a
  `--with-x`/`--no-x` pair. The prompt has three answers and the boolean form
  leaves *abort* unrequestable, which is the one a scripted deploy wants.
- **Injection strips strays.** The managed block is sentinel-delimited and any
  `KASBAH_*` line outside it is removed. The alternative — leave and warn —
  means two lines set one variable and the last wins, so the effective limit can
  differ from the marker's silently.
- **`lib/env.sh` is dual-mode and *is* the shipped artifact.** See 3.1 above.

## Findings

### From unit A — the port

- **`|| true` on the two value reads is the non-interactive contract, and
  nothing tested it.** Template `A=1 B=2 C=3` with one newline of stdin: with
  `|| true`, exit 0 and a complete `.env`; without, exit 1 and **no `.env` at
  all**. That is precisely the shape a headless `kasbah deploy` produces on the
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

### From unit B — drift and injection

- **A stray `KASBAH_*` line outranked the marker, and the comment said it
  could not.** The strip rule was anchored at column 0, but Compose also
  honours `  KASBAH_CPU_LIMIT=0.1` and `export KASBAH_MEM_LIMIT=1g`, and
  takes the **last** assignment. So a hand-edit below the block — the ordinary
  position, since the block is appended on first injection and rewritten in
  place after — silently won. `docker compose config` on the resulting file
  reported `cpus: 0.1` against a marker saying `14.4`.

- **The fix had a mirror-image hazard one mutation away.** Widening the match
  from anchored to *substring* — the obvious way to catch more strays —
  deletes a user's `MY_KASBAH_URL=…` line outright. Data loss in the opposite
  direction, from the same rule. The match is anchored with optional blanks and
  an optional `export ` and nothing else, and both hazards are now pinned by
  fixtures; neither was before.

- **A mutation survey written from the code tests the code it was written
  from.** Unit B's own survey reported 26 mutants, 26 killed, 0 survivors. A
  reviewer that built its set independently, without reading that one, got 25
  mutants and **16 survivors, 13 of them real** — six being the entire question
  "is the reserved-prefix match anchored?", which no fixture in the repo
  touched. The lesson is not that the first survey was careless; it is that
  mutants must be derived from the *behaviour wanted*, not from the lines
  present. The fix round then found a **seventh** anchored site the review's own
  list had missed (the `TEMPLATE_KEYS` scan, whose observable is the *removed*
  count rather than the *kept* count).

- **`env_setup_run` destroys the managed block, and nothing said so.** A `.env`
  holding `APP=live` plus a block comes back as exactly `APP=live` — setup
  builds its output from the template, and the template has no reserved keys.
  `compose up` then fails on an unset `KASBAH_CPU_LIMIT`. Hence the ordering
  rule now in the file and in `env-template.md`: **inject after setup, never
  before.** 3.4 is the code that wires the two together.

- **The portability rule the code follows was not the one it stated.** A
  comment justified avoiding `awk` and `grep` by the prerequisites table, two
  functions above calls to `sort -u`, `comm` and GNU-only `chmod --reference`,
  which that table promises exactly as much. The real rule — **coreutils and
  bash builtins yes, separately-packaged tools no** — is now stated once in the
  file header, and `server-setup.md`'s prerequisites row names `sort`, `comm`
  and `readlink` rather than implying they were never needed.

- **`KASBAH_` with an empty name was judged by three rules at once**: exempt
  from drift, flagged by E05, not stripped as a stray, refused as a pair.
  Settled toward reserved — `docker compose config` reads `KASBAH_=x` as
  setting a variable, so the bare name is inside the namespace the frozen
  contract claims. One anchored rule now, at all seven sites.

- **A differential harness proves only what its fixtures contain.** The
  25-case proof from unit A uses LF-only fixtures, so it cannot detect the
  trailing-newline divergence 3.3 deliberately introduced — 25/25 was quoted
  twice as evidence the change was contained before a reviewer pointed out it
  is structurally incapable of being that evidence. Containment was real, but
  it was established by separate measurement.

### From the phase-close group review — the seam

Three units, each reviewed in isolation and each approved. A fourth reviewer
that had seen none of those rounds judged them together.

- **One file, two beliefs about what a `.env` line is — and a live secret paid
  for it.** Unit B's stray-stripper encodes a measured fact: Compose trims
  leading blanks and honours an `export ` prefix. Unit A's readers, ported
  verbatim, are anchored `^[A-Za-z_]…=` and see none of those shapes. Each unit
  was right alone; the contradiction existed only once both were in the file.
  Against a `.env` holding `export APP_KEY=live-secret`:

  ```
  docker compose config  →  SEEN: live-secret     # Compose reads it
  env_drift              →  MISSING=[APP_KEY]     # kasbah says it is absent
  printf '\n' | setup    →  APP_KEY=default       # the secret is gone
  ```

  No `[current:]` prompt and no menu, because the loader saw an empty `.env`
  and took the first-deploy path. Headless, that false drift became **exit 5 on
  a working project**. Before this phase the same mis-read was a warn-level
  `check` line — the deploy wiring is what made it consequential, which is the
  general shape: *a latent disagreement becomes a defect when something starts
  acting on it.*

  Settled by widening the readers: kasbah reads a `.env` the way Compose does,
  everywhere. One shared `ENV_ASSIGN_RE`, seven sites. The `--inject` pair guard
  is deliberately **not** among them — a pair is kasbah's own argv, not a
  user-authored line — and now says so.

- **The count of anchored sites was wrong three times running.** The plan
  implied one. Unit B's review found six. Unit B's fix round found a seventh
  (the `TEMPLATE_KEYS` scan, whose observable is the *removed* count rather than
  the *kept* count). The close brief listed three readers and the close round
  found a **fourth** — the prompt loop, a distinct value-loss path in which the
  template's value is written over the live one without a prompt. Nobody
  enumerating by memory got it right; only mutating each site individually did.

- **A test can pin the defect.** `tests/env_test.sh`'s `t28k` asserted, byte for
  byte, that `--inject` with no pairs writes an *empty* block — the exact
  behaviour that silently wipes the reserved keys and leaves `compose up`
  failing on an unset variable. The fix could not land without deleting an
  assertion, which is the honest signal that the assertion was wrong rather
  than the code.

- **The docs drifted as a set again, exactly as Phase 2 recorded.** Each unit
  reconciled what it touched; nobody owned the whole. Eight statements had gone
  false, two of them inside this phase's own blast radius: the demo fixture
  still said the `KASBAH_*` values were "seeded by hand for now" — which is
  precisely what these three commits retired — and still described deploy as
  refusing to run without a `.env`. `project-manifest.md` still promised
  `setup-env.sh` would arrive "in roadmap v0.1's env phase". This one.

### Carried into 3.3, with the evidence warm — settled

- **`lib/env.sh` and `lib/check.sh` disagree about a file with no trailing
  newline.** All three of `env.sh`'s read loops drop a final unterminated line;
  `check.sh:654` and `:706` read the *same* `.env.prod.example` with
  `|| [ -n "$line" ]`. So `check` sees a key `env.sh` does not, and a `.env`
  whose last line lacks `\n` loses that live value on reconfigure. Inherited
  verbatim, so unit A left it alone — but 3.3 owns `env_extract_keys` and the
  shared drift function, and cannot make one function serve both readers
  without picking a side. Pick it, and test it.
