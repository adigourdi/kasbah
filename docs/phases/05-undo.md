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
- [x] `tests/rotation_test.sh` covering the month-boundary math — 9 cases (A–I), each mutation-proven. Cutoff `month_index(now) − 3` with `month_index = year*12 + month`; August 2026 → prunes April-and-earlier, January 2027 → prunes September 2026-and-earlier, March 2027 → prunes November 2026-and-earlier.
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

### Unit 1 — the VPS side (rotation, `rollback` mode, four hook lists)

Re-cut from the plan's own numbering: 5.3's rotation was pulled forward and
merged with 5.1's *remote* half, because both live in
`templates/remote-deploy.sh` and doing them apart means opening that file
twice. What is left of 5.1 is entirely local and is its own unit.

**The plan's `date -d` watch-out was not followed, deliberately.** Month
arithmetic is an integer index — `year*12 + month`, parsed from the leading
`YYYY-MM` of field 1 — which crosses a year boundary by subtraction and needs no
date library at all. The watch-out's real target is string surgery on month
*names*; an index is arithmetic, and it keeps GNU `date -d` outside a script
whose tool budget is coreutils and bash builtins. The budget grew by exactly one
entry, `gzip`, which `docs/server-setup.md` already made a hard-fail
prerequisite of a prepared server.

**One rotation failure has three shapes, and the first two attempts each
described two of them.** Rotation appends to `versions.log.gz` and then rewrites
`versions.log`; the gz goes first so a crash duplicates entries rather than
losing them (nothing is ever deleted). The first implementation warned "its
3-month compaction did not run" on *every* failure — which is false once the
archive has already taken the entries and only the rewrite failed: the entries
are then in both files, and because the active log is never trimmed, every later
run appends them again. Unbounded growth, under a message saying nothing
happened. That was found by review. The fix split it in two — and the *new*
exit-1 message then claimed "both files are exactly as they were", which is
equally false when the archive append itself dies partway (ENOSPC), leaving a
truncated gzip member the active log knows nothing about. Found by the same
reviewer on the line its own finding had just rewritten. There are now three
codes, because the operator's next move differs in each: nothing written (1),
archive possibly truncated and the log whole (3), archive complete and the log
untrimmed (2).

The general shape is worth keeping: **a warning that under-describes a partial
write is worse than no warning**, because it is the thing that stops anyone
looking. Both defects were the same sentence written one step apart in the
chain.

**Two assertions named a property and planted no instance of it.** The suite
said "a retained line comes back byte for byte", and no retained line in it
carried a CR, a trailing space, or doubled internal spacing — so
`printf '%s\n' "${line%$'\r'}"` (the exact CR-strip `rd_last_log_line` does two
functions away, and a plausible future edit) passed the whole suite. Separately,
`_rd_month_name` was never asserted at all: `y=$(( idx / 12 ))` prints `2027-00`
for a December cutoff and passed — while the December-cutoff case existed and
grepped only for the words after the month. The tell in both is a test whose
name states a property its fixture does not contain. Both now die to their
mutants.

**`mv` replaces the inode, so a rotation inherits the run's umask.** A
`versions.log` that had been group-readable since the first deploy came back
`0600` under a tight umask — on a host kasbah expects more than one person to
administer, which is why `/etc/kasbah/apps-path` exists at all. The mode is now
captured with `stat -c %a` and reapplied, both steps failure-tolerant: a host
without GNU `stat` loses the mode preservation and nothing else.

**`RD_VERB` is a verb and one slot needed a noun.** The mode-sensitive messages
read "refusing to $RD_VERB over a stack" (`roll back`) but also "on every
⟨noun⟩ after it", where `$RD_MODE` — literally `deploy` or `rollback` — is what
fits. Using it there also left every deploy-mode byte unchanged, so the existing
assertion on that sentence kept its meaning instead of being rewritten to match
new output.

**Not proven here:** that the shipped script reaches a server, and that a real
VPS's `gzip`, `mv` and `stat` behave like the stubs. `tests/rotation_test.sh`
and `tests/remote_deploy_test.sh` render the template and run it against a
recording `docker` stub and a `date` stub that fakes only `-u +%Y-%m` and
`-u -Iseconds`; the transport is `tests/integration/deploy_ship_test.sh`'s.
Rotation's three-month boundary is reachable only with synthetic timestamps, so
it is **traced, not aged**.
