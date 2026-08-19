# Phase 5 — Undo

> Deploys are reversible and inspectable: `rollback` restores a prior
> version from git + retained images, and `history` / `pending` /
> `changelog` read the record.

**Prerequisite:** Phase 4.
**Spec:** `docs/build-deploy.md` (rollback flow + invariant, retention, versions.log rotation), `docs/cli.md` (rollback, history, pending, changelog)

## Exit criteria
- [ ] On the rig: deploy v1 → deploy v2 → `rollback` → compose file, fragment, and `:current` all match v1 (asserted from git show + docker inspect)
- [ ] Rolling back to a never-deployed version fails with the "first-time deploy" message
- [ ] Rolling back to a pruned-image version fails with the roll-forward guidance (no auto-reship)
- [ ] `history` renders both the live log and `--all` including `versions.log.gz`

## Tasks

### 5.1 — `rollback` (M)
Target = arg or second-latest `action=deploy` entry; must exist in
versions.log(.gz); `git fetch --tags` fallback; read v<target>'s manifest
+ compose via `git show` (never HEAD — the invariant in
`build-deploy.md`); image `:<target>` must be on the VPS (retention
window; fail with the rebuild-from-tag escape hatch, rebuild explicitly
noted as not byte-identical); `git archive` the target's own sync list;
restore the target's fragment; run remote-deploy `rollback` mode.

**Deliverables**
- [ ] `lib/rollback.sh` + the three failure-path messages from the spec
- [ ] Integration test: v1→v2→rollback asserts all three surfaces at v1
- [ ] pre/post-rollback hooks fire with correct VERSION/PREV_VERSION

**Watch out for:** the sync list must come from *v<target>'s* manifest —
a file added to `sync:` after v<target> would otherwise survive rollback
as a stale HEAD artifact. And `git archive` paths that no longer exist at
HEAD are fine, but paths that never existed at v<target> hard-fail the
whole archive — validate the list against `git ls-tree v<target>` first.

### 5.2 — `history` / `pending` / `changelog` (S)
Tabular history (timestamp, action, version, backup, kasbah version;
`--all` appends the gz rotation). `pending` resolves the deployed version
from the VPS at runtime — never from state.json (state is a cache, per
`project-manifest.md`). `changelog` = git log between the two latest
deploys.

**Deliverables**
- [ ] Three commands green against the rig's log from 5.1's test run
- [ ] `pending` with an unreachable VPS exits 3, not garbage

**Watch out for:** concatenated gzip streams — read the rotation with
`zcat` (valid for appended gzips), never `gunzip -c` a partial copy.

### 5.3 — Log rotation (S)
The 3-month rotation from `build-deploy.md`: prune-to-gz on every
successful write, nothing ever deleted. Unit-testable locally with
synthetic timestamps.

**Deliverables**
- [ ] `tests/rotation_test.sh` covering the month-boundary math
- [ ] `history --all` transparently spans the rotation point

**Watch out for:** month arithmetic in bash (August − 3 crossing the year
boundary) — compute with `date -d`, not string surgery.

## Carried in from Phase 4

- **A deploy that fails at `compose up` has already moved `:current`.** The
  order is retag → up, so a failed deploy leaves the tag pointing at a version
  whose containers did not start, and `versions.log` has no entry for the run —
  so nothing on the server records that the tag moved. Observed by hand at
  Phase 4's close. It is by design, and rollback is the thing that puts the tag
  back, which makes 5.1 the place to decide whether that is worth saying out
  loud (a note in `build-deploy.md`, or a line in the deploy's own failure
  message).
- **`versions.log` rotation is 5.3's, and 4.2's task text claiming it was
  deliberately dropped.** Phase 5 reopens `templates/remote-deploy.sh` for
  `rollback` mode anyway, so rotation costs nothing to wait for. The writer now
  repairs a missing final newline before appending (see Phase 4's Findings —
  a truncated last line used to fuse with the new entry); **rotation must
  preserve that property**, since it rewrites the file wholesale.
- **`rd_last_log_line` and `rd_prev_version` are two functions on purpose.**
  "Has this project deployed here" and "what version was it" are different
  questions, and collapsing them into one variable has already produced two
  defects in Phase 4 — a guard that failed open, and a changelog that called a
  server with history a first deploy. `history` and `pending` read the same
  file; keep them apart.

## Findings

_(filled during execution)_
