# Phase 5 — Undo

> Deploys are reversible and inspectable: `rollback` restores a prior
> version from git + retained images, and `history` / `pending` /
> `changelog` read the record.

**Prerequisite:** Phase 4.
**Spec:** `docs/build-deploy.md` (rollback flow + invariant, retention, versions.log rotation), `docs/cli.md` (rollback, history, pending, changelog)

## Exit criteria
- [x] On the rig: deploy v1 → deploy v2 → `rollback` → compose file, fragment, and `:current` all match v1 (asserted from git show + docker inspect). `sha256sum` of `<apps>/built-app/compose.yml` and of `<apps>/traefik/dynamic/built-app.yml` equal `git show v2.1.0:…`; `built-app-{web,worker}:current` resolve to the v2.1.0 image ids; the recreated container no longer carries the env key v2's compose added; `docker exec … cat index.html` serves the v1 build's page
- [x] Rolling back to a never-deployed version fails with the "first-time deploy" message
- [x] Rolling back to a pruned-image version fails with the roll-forward guidance (no auto-reship). `server prune` is roadmap v0.2, so the pruned state is produced by removing the image from the rig by hand — the guidance is real, the prune that would cause it is simulated
- [x] `history` renders both the live log and `--all` including `versions.log.gz` — plain history footers the archived count, `--all` shows both halves separated by a rotation marker, and an archive that could not be read in full says so in the report itself

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
- [x] `lib/rollback.sh` + the three failure-path messages from the spec — all three printed and asserted; the never-deployed one grew a second form for a record kasbah could not read through (see Findings)
- [x] Integration test: v1→v2→rollback asserts all three surfaces at v1 — `tests/integration/rollback_test.sh`, green on the rig (exit 0, 1m12s)
- [x] pre/post-rollback hooks fire with correct VERSION/PREV_VERSION — read back from what the hooks wrote inside the container, not from kasbah's narration

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
entries of the record, whatever their action — settled during the run;
see Findings.

**Deliverables**
- [x] Three commands green against the rig's log from 5.1's test run — `tests/integration/history_test.sh`, exit 0, driving deploy 2.1.0 → deploy 2.2.0 → rollback → deploy and reading all three commands back
- [x] `pending` with an unreachable VPS exits 3, not garbage — all three commands, hermetically and on the rig, with empty stdout and `last_server` unchanged

**Watch out for:** concatenated gzip streams — read the rotation with
`zcat` (valid for appended gzips), never `gunzip -c` a partial copy.

### 5.3 — Log rotation (S)
The 3-month rotation from `build-deploy.md`: prune-to-gz on every
successful write, nothing ever deleted. Unit-testable locally with
synthetic timestamps.

**Deliverables**
- [x] `tests/rotation_test.sh` covering the month-boundary math — 9 cases (A–I), each mutation-proven. Cutoff `month_index(now) − 3` with `month_index = year*12 + month`; August 2026 → prunes April-and-earlier, January 2027 → prunes September 2026-and-earlier, March 2027 → prunes November 2026-and-earlier.
- [x] `history --all` transparently spans the rotation point — the archive it reads is the one `templates/remote-deploy.sh` wrote: `versions.log.gz` asserted absent before the triggering deploy and present after, `zcat` on the rig returning exactly the planted entries, and the active log no longer holding their timestamps

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

**And that fix was half of the step it described** — the phase's own named class,
committed in the entry recording it. The same function *creates*
`versions.log.gz` with a bare `cat >> `, so the archive was still taking the
run's umask: measured at `600` beside a `644` active log. The group review found
it, and found what it costs — an archive the ssh user cannot read is what makes
`rollback` assert things about a record it has not seen. Closed at the phase
close; both halves of rotation now carry the mode across.

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

### Unit 2 — `lib/versions_log.sh`, the reader (inserted; the plan names no such task)

**A task the plan did not have.** 5.1 needs to resolve a rollback target and
prove it was really deployed here; 5.2 needs the same file for `history`,
`pending` and `changelog`. Both were going to read `versions.log` off a server
and parse the frozen line. Left unhoisted, 5.1 would have built a
rollback-shaped reader and 5.2's review would have been a refactor, so the
substrate became its own unit and both consumers are briefed against one
contract.

It also collapsed a duplicate: `_ss_parse_log_line` moved out of
`lib/server_status.sh` into the new library, so the frozen format has **one**
parser locally. (The four copies of `kasbah_norm_path` are forced — a payload on
the far side of ssh can source nothing. These two were both local, so there was
no excuse.)

**The fail-open guard, for the third time in this codebase.** `vlog_has_entries`
answered "no record here" for a `versions.log` the ssh user cannot read — and
the suite asserted that answer was correct. The remote step goes to explicit
trouble to keep `notfile`, `unreadable` and `missing` apart, with a comment
saying "every 'cannot' is its own state, and none of them is 'missing'", and
then the one query asking "is there a record here at all?" flattened them. A
`0600 root:root` log left by a sudo-owned deploy would have handed `rollback`
the exact shape of "this project has never deployed here". The fix is
asymmetric on purpose: an unreadable **active** log is now a hard failure,
because no consumer can proceed honestly from it, while an unreadable
**archive** is a warning, because the active log is authoritative for what is
deployed and losing history must not block reading the record.

**A warning that under-described a partial read — the same class as unit 1's,
one layer up.** The damaged-archive warning said "gzip stopped before the end of
it", "every entry before the damage is read" and "the likely cause is a rotation
that ran out of disk", all three of which are false when the archive is not gzip
at all: gzip never started, nothing was read, no append happened. Empty output
with a non-zero status is a different state from output-then-failure, and they
now get different sentences. Three occurrences in two units is enough to call it
a rule for this codebase: **when a step can half-succeed, the message has to name
which half.**

**`notdir` was wider than it looked.** With `<apps>/<project>` a regular file,
both logs reported `missing` — and so did an `<apps>` path that was itself a
regular file. So a broken or unprepared apps path read as "this project has
never been deployed", and `rollback` would have answered it with "use
`kasbah deploy <host> X` for a first-time deploy": advice that cannot work,
because the path is occupied. Same shape as Phase 4's "stopped" versus "no
longer exists". No new vocabulary was needed — `server status` already had
`notdir` and `noaccess`, and reusing them made a comment claiming the two
commands share a vocabulary true instead of false.

**The tell caught a third time, and at a layer the earlier catches could not
reach.** The suite claimed "the log comes back byte for byte, so the parsing
happens on this side". Replacing the *remote* base64 helper with one that
stripped CRs and trailing blanks from every line before shipping left the entire
suite green: no fixture under the fake apps tree carried a CR, a trailing space
or a doubled space, and both sides of the comparison were `$( )` captures, which
hide a trailing-newline difference too. The loader-level version of the same
assertion was genuine — its mutant died. The transport-level one was theatre.
**A test whose name states a property its fixture does not contain** is now the
single most productive thing to look for in this phase's reviews.

**Two decisions taken after the fact, both now in `build-deploy.md`.**
`vlog_prev_deploy` searches the whole record rather than the active log alone —
otherwise a project deploying less often than the 3-month rotation has no
implicit rollback target at all, and the answer is identical whenever the active
log holds two deploys. And the fetch reads both files in one round trip; over
ssh a second round trip costs more than the archive's bytes, and it is the
*display* that is on demand, not the transport.

**A seam worth naming for whoever writes the consumers:** `vlog_find_version`
returns the most recent entry naming a version *whatever its action*. A caller
that reads `VLOG_ACTION` off that index and demands `deploy` would refuse a
version the server demonstrably ran — a version rolled back to twice has a
`rollback` line as its most recent mention. The versioning contract in
`build-deploy.md` used to say the target must appear "with `action=deploy`" and
now says any entry naming it counts.

### Unit 3 — `rollback` and `deploy X.Y.Z`

**A safety mechanism with no consumer is indistinguishable from no safety
mechanism.** Unit 2 built `VLOG_SKIPPED_DAMAGED` precisely so a caller could
tell when a query had stepped over an unreadable log line — the variable's own
comment says *"otherwise a damaged latest deploy silently makes the deploy
before it the rollback target"* — and unit 3 read it nowhere. Measured with a
truncated final append (the shape Phase 4 named as the realistic producer): a
bare `kasbah rollback` went **two versions back**, announced "rolling back to
1.0.0 — the deploy before the current one", and exited 0. The mirror case
refused a rollback to a version the record does mention, recommending a
first-time deploy of something that had already run. Neither unit was wrong on
its own; the defect lived entirely in the seam, which is why per-unit review
could not have found it and a reviewer reading across two units did.

**A wrong noun is cosmetic; a runnable instruction that is wrong for the run in
flight is a defect.** Two failure paths shared with `deploy` told the operator
to "re-run `kasbah deploy`" — during a rollback. Following that advice deploys
HEAD's working tree and silently undoes the rollback, and it sat on exactly the
two paths where an operator is reading most carefully (the fragment failing
after a successful stack, and a truncated remote report). The fix is a helper
that builds the command repeating *this* run, version included, since
`kasbah deploy <host>` and `kasbah deploy <host> 1.0.0` are different commands.

**`git archive` and `git ls-tree` are different predicates, and
`.gitattributes export-ignore` separates them.** Validating the sync list with
`ls-tree` and then extracting with `archive` shipped a directory silently
missing a file. Measured:

```
$ git ls-tree -r --name-only v1.0.0 -- site
site/index.html
site/private.txt                      # ls-tree sees it
$ git archive --format=tar v1.0.0 -- site | tar -tf -
site/
site/index.html                       # archive drops it, no error
$ git archive --format=tar v1.0.0 -- site/private.txt; echo $?
0                                     # a whole-file entry: exits 0, tar holds only the pax header
```

Which of the two shapes that produces matters, and the orchestrator got it
backwards before a reviewer measured it. A whole *file* entry fails the run
**loudly** — rsync exits 23 on the missing local source, blaming a transport
that is working perfectly (`ssh_rsync` passes no `--ignore-missing-args`). The
genuinely silent case is a file dropped from *inside* a directory entry that
otherwise survives. And because the run stops at the first failing entry, the
loud one can hide the quiet one behind it.

The orchestrator's error is worth recording as its own trap: it measured the
`git archive` step, saw exit 0 and an empty tar, and asserted a *downstream*
consequence — "the run simply proceeds without the file" — that it had never
measured. Reasoning one step past your evidence is the same mistake as a test
naming a property its fixture does not contain, and it reached both a code
comment and this file before it was caught.

Either way the guarantee now rests on the **extracted tree**, which is the only
artefact reflecting every decision `git archive` made; the `ls-tree` pre-check
keeps its separate job of producing a good message before an archive dies at 128.

**Two more measured `git` edges, both of which defeat the obvious
implementation.** `git archive <ref> <path-absent-at-ref>` exits **128** and
produces nothing at all — the whole archive dies, not just the missing entry, so
the list must be validated first. And `git ls-tree --name-only <ref> <missing>`
exits **0 with empty output**, so a validation written as `git ls-tree … || die`
can never fire; it has to compare the returned set against the requested one.
(`ls-tree <ref> sub` prints `sub`, while `ls-tree <ref> sub/` prints its
contents — two answers for what a sync entry treats as one thing.)

**The spec said something that cannot be done.** `git archive v<target> <sync
list> | ssh vps tar -x` was the flow in `build-deploy.md` and `cli.md` from the
start. `git archive` has no rename, and every kasbah project renames at least
once — `compose.prod.yml -> compose.yml` is required, since the server runs
compose on `<apps>/<name>/compose.yml` and nothing else. A literal
implementation lands `compose.prod.yml`, leaves the previous deploy's
`compose.yml` untouched, and brings the stack up on **HEAD-era compose against
v<target>'s images**: exactly the silent mismatch the invariant exists to
prevent. Both documents were corrected in this phase.

**A project renamed between the tag and HEAD is refused** — no spec anticipated
it. `manifest.name` decides the server directory, the compose project name and
the fragment filename, so it is the one thing the v<target> invariant cannot
read from the ref: the name is what identifies the thing being rolled back.

**The seam was wider than this unit's fix.** `VLOG_SKIPPED_DAMAGED` was the
one consumed; `VLOG_ARCHIVE_STATE` and `VLOG_ARCHIVE_DAMAGED` are the same idea
for the same purpose, and `lib/rollback.sh` read neither — `grep -c` returned 0
here against 11 in `lib/history.sh`. So a version aged into an *unreadable*
archive was answered "never deployed to this VPS. Use `kasbah deploy …` for a
first-time deploy", directly above a line claiming the archive had been read.
Found by the phase-close group review, not by this unit's own rounds, and it is
the clearest argument for that pass existing: **fixing one instance of a class
is not fixing the class**, and the unit that fixes an instance is the least
likely to look for its siblings.

**A trap for anyone writing tests against `lib/versions_log.sh`:**
`VLOG_ACTIVE_STATE` and `VLOG_ARCHIVE_STATE` are library globals that
`vlog_fetch` clears, and the clearing propagates into the exported environment
of the ssh child — so a stub keyed on those names silently reads empty. Cost a
debugging round; use a distinct prefix.

**One instruction from the orchestrator was wrong and the implementer caught
it.** "Everything local first" applied to *any* named version silently reorders
an explicit rollback: putting the tag check ahead of the record check makes
`kasbah rollback <host> 9.9.9` answer "v9.9.9 is not a tag in this repository"
instead of "never deployed to this VPS". Scoped to deploy mode, where nothing
needs the round trip first. The rig suite's own never-deployed case would have
caught it.

**Accepted limits.** The rig fixture builds the *same two* services at both
versions, so the image-set half of the invariant (reading `_BP_COMPOSE` from
HEAD) is killed only hermetically — growing the fixture to add a third built
service at v2 would drag in orphan-removal behaviour as well. And
`deploy X.Y.Z` is exercised hermetically only; no rig case ships a tagged
version in deploy mode. The engine is shared and the mode difference is one
argument, so the risk is the wiring, not the path.

Two more, found in the closing round. `readarray -d` is this repo's first use
and needs **bash 4.4**; nothing declares a minimum anywhere (`declare -A`
already implied 4.0). Not an issue on any Linux this targets, but it is now
undocumented rather than absent. And the `git ls-tree` failure guard inside
`_rollback_check_extraction` has **no test**: reaching it needs the repository
to break between two git calls in the same run, and no fixture simulates that.
The guard is there because a `readarray` fed by a process substitution
swallowed git's status into an empty array, which read as "nothing missing" —
a guard failing open inside the function written to close one. It is written
against the mechanism, not against a test.

A NUL-separated list also cannot travel through `$( )`, which is how the first
attempt at that fix broke the suite: command substitution discards NUL bytes,
so `readarray -d ''` on the result returns one giant element. The list goes
through a temp file, cleaned by the same trap as the extraction.

### Unit 4 — `history` / `pending` / `changelog`

**Every defect in this unit was a report contradicting itself inside one run.**
Four of them, and not one crashed, wrote to the server, or got an exit code
wrong. One report said *"its archive does [hold entries]"* directly above
*"no archived entry could be decoded"*; another asserted *"and neither does its
archive"* about an archive kasbah had just failed to read — telling an operator
the server never ran this project, on evidence kasbah does not have; a third
printed advice (`--all` will show it) that cannot work on a truncated gzip
member. A fourth said *"…missing from this table"* in three callers that print
no table, which the implementer caught in its own pasted output.

That makes **seven occurrences across four units** of one shape. The rule unit 1
wrote down — *when a step can half-succeed, the message has to name which half*
— turns out to generalise well past warnings: it governs every sentence a
command prints about state it only partly observed. Worth carrying into any
phase that adds a command which reports on a server.

The corollary this unit adds: **all three of those defects lived on paths the
suites never reached.** The commands' happy paths were thoroughly tested. What
was untested was every combination of "the record is partly unreadable" — which
is exactly the state the previous three units spent their whole effort making
possible to detect.

**"Structurally unreachable" deserves the same doubt as any other claim.** The
implementer listed four cases it could not verify; a reviewer measured three of
them reachable, cheaply. A repository with no HEAD commit is an orphan checkout
away (`git checkout --orphan` leaves `refs/tags/v1.0.0` resolvable while `HEAD`
is not — which is precisely the branch's precondition). A damaged line on the
rig is one more line in a heredoc the suite already writes. An unreadable
archive is a `chmod 000`, because the rig's ssh user is `stevedore` and not
root. Only the fourth — `git log` failing on a range both of whose ends
`rev-parse` already verified — survives as genuinely unreachable, and stands as
traced rather than proven.

**A row that did not parse is not a row.** `history` shows it in place, marked
`!!`, as the bytes the file holds with the CR stripped for display and nothing
else altered. Inventing `?` for four columns would make a truncated write look
like a deploy of an unknown version — the frozen format's whole point is that
every reader agrees on what a line says, and a line that says nothing must not
be rendered as though it did.

**`changelog` reads the last two entries whatever their action**, settled during
the run against `cli.md`'s original "between the two latest deploys". After a
rollback the deployed version *is* the rollback's target, so pairing the last
two `deploy` entries would describe a version the server is not running — in the
one phase whose entire purpose is making rollbacks happen. Both `cli.md` and
this file's own 5.2 task text were corrected.

**`VLOG_SKIPPED_DAMAGED` has no reader here, and that is correct.** Unit 3's
defect was calling a query that *skips* damaged lines without reporting it.
These three commands call no such query: `history` walks the arrays itself, and
`pending`/`changelog` reach the record through `vlog_last_entry`, which neither
skips nor counts. The obligation is discharged in kind rather than by reading a
counter — every unparsed line is shown. Recorded because the next reader will
otherwise go looking for a consumer that should not exist.

**Corrected at the phase close:** this entry originally also claimed "a range is
never built past one", and the group review disproved it — `changelog` built a
range across a *truncated archive* without a word, on the same record where
`history` said the record was incomplete. The unparsed-*line* claim holds; the
general one did not, and was fixed rather than reworded.

### Phase close — the exit criteria, walked by hand

Driven as an operator against the rig with `kasbah` itself, reading every fact
back off the server rather than inferring it from a green suite. The sequence
was `server init` → build-push/deploy 3.0.0 → build-push/deploy 3.1.0 →
`rollback` → build-push/deploy 3.2.0 → `rollback 3.0.0`, then the two refusals
and the rotation.

**The walk's first attempt proved two of its own three assertions vacuous**, and
only caught it because each comparison also printed whether the two versions
differ at all. v3.1.0 had been cut with a `sed` that silently matched nothing,
so its compose file was byte-identical to v3.0.0's — and because nothing in the
image changed either, `built-app-web:3.0.0` and `:3.1.0` resolved to the same
id. "The rollback restored v1's compose" and "`:current` points at v1" were both
true and both meaningless. v3.2.0 was then cut to differ in **the compose file
and the image payload**, and the criterion re-walked. The fifth occurrence in
this phase of an assertion naming a property its fixture did not contain, and
the first one the orchestrator wrote.

- **Criterion 1** — after `rollback 3.0.0` over a deployed 3.2.0: the server's
  `compose.yml` sha256 equals `git show v3.0.0:compose.prod.yml`, the fragment
  at `<apps>/traefik/dynamic/built-app.yml` equals `git show
  v3.0.0:traefik-dynamic.yml`, and `built-app-web:current` resolves to
  `:3.0.0`'s id — each with the two versions verified to differ first. The
  strongest evidence is the container rather than the files: it carries no
  `WALK_MARKER` (which only v3.2.0's compose declares) and
  `docker exec … cat index.html` serves the v3.0.0 build's payload, not
  v3.2.0's. **One sub-assertion is vacuous and stays that way**:
  `built-app-worker` was never changed between the two versions, so its
  `:current == :3.0.0` would hold either way. The web image carries the claim.
- **Criterion 2** — `kasbah rollback stevedore@rig 9.9.9` → exit 1,
  *"Version 9.9.9 was never deployed to this VPS. Use `kasbah deploy
  stevedore@rig 9.9.9` for a first-time deploy."*, followed by the line naming
  both files it read.
- **Criterion 3** — `docker image rm built-app-web:3.0.0` on the rig (`server
  prune` is roadmap v0.2, so the pruned state is produced by hand), then
  `rollback 3.0.0` → exit 1 with the roll-forward guidance and the
  rebuild-from-tag escape hatch, naming the image. Verified side-effect-free
  afterwards: `versions.log`'s last line unchanged, and
  `built-app-web:current` still resolving to `:3.2.0`. Nothing was reshipped.
- **Criterion 4** — two entries dated 2025-09 and 2025-10 planted in the active
  log, then a real deploy. `versions.log.gz` **absent before, present after**,
  holding exactly those two under `zcat`. `kasbah history` shows the 7 active
  entries and footers *"2 more entries archived"*; `--all` shows all 9 with the
  rotation marker between the halves.

Two things the walk saw that no suite asserts:

- **The exit-5 message's advice is correct and sufficient.** A first deploy with
  no `.env` and no terminal stops at exit 5 and prints, among the options,
  `ssh … 'cp /apps/built-app/.env.prod.example /apps/built-app/.env'`. Running
  exactly that and re-deploying worked. An error message whose instructions an
  operator can follow verbatim is worth more than one that is merely accurate.
- **Phase 4's carried-in `:current` item is closed, and observed firing.** A
  deploy that failed at `compose up` (the rig's cgroup limitation, before the
  marker was zeroed) printed: *"built-app's images on stevedore@rig may already
  carry :current for 3.0.0 even though its containers did not start — the retag
  runs before `compose up`, and nothing on the server records that it moved.
  `kasbah rollback stevedore@rig` is what puts it back."*

### Phase close — the group review, and what four approved units still had wrong

A fifth reviewer that had seen none of the four units' rounds judged them
together. Every unit had been approved on its own; the group pass found five
seam defects, four consistency defects and three overstatements in this file.
That is the argument for the pass existing, in one number.

**The phase's headline finding had a sibling nobody looked for.** Unit 3's
lesson was that `VLOG_SKIPPED_DAMAGED` had no consumer. `VLOG_ARCHIVE_STATE`
and `VLOG_ARCHIVE_DAMAGED` are the same idea, built by the same unit for the
same purpose — and `grep -c` in `lib/rollback.sh` returned **0** against 11 in
`lib/history.sh`. So `rollback` answered a version aged into an *unreadable*
archive with "never deployed to this VPS. Use `kasbah deploy …` for a
first-time deploy", directly above a line claiming to have read the archive.
An operator following that runs a deploy — backup, deploy hook pair — on a
version that already ran there. **Fixing one instance of a class is not fixing
the class, and the unit that fixes an instance is the least likely to go
looking for its siblings.**

**The producer of that defect was the incomplete half of another fix.**
`rd_rotate_log` preserves `versions.log`'s mode across its rewrite — unit 1's
own post-review fix, recorded above — and then creates `versions.log.gz` with a
bare `cat >>` under the run's umask. Measured: `600` archive beside a `644`
active log. A root-run deploy followed by a non-root `kasbah rollback` is the
whole chain from "half a fix" to "kasbah reasons about a record it cannot
read". Both halves of rotation now carry the mode across.

**Three readers of one frozen format disagreed, and one run said both things.**
`vlog_parse_line` required four fields and a leading ISO timestamp;
`rd_prev_version` on the VPS did `read -r ts action ver _` with no validation
at all. On a `printf >>` killed after field 3 — the shape this phase names as
realistic — the server read `3.0.0` and the workstation called the same line
damaged, so one `kasbah rollback` warned that a line had no readable version
and then, four lines later, named the version read out of it. `rd_prev_version`
now applies the same predicate, and a line failing it yields no `PREV_VERSION`
while still counting as history — which is exactly what `rd_deployed_before`
is a separate function for.

**Rotation's third parser stays deliberately weaker, and an orchestrator
instruction to "align" it was wrong.** `_rd_month_index` is called as
`_rd_month_index "$now-01"` where `$now` is `date -u +%Y-%m`, so requiring the
`T` makes every rotation compute no cutoff — measured at **67 FAILs** in
`rotation_test.sh`. It answers "which month is this line from", a strictly
weaker question than "is this a kasbah entry", and tightening it would pin a
datable truncated write in the active log forever, which is the one thing
rotation exists to move.

**A tell worth keeping, in its sharper form.** Five assertions in this phase
named a property their fixture did not contain. The last two are the
instructive ones: one was written by the orchestrator during the exit-criteria
walk, comparing two versions that were byte-identical; the other was found only
while *fixing a different defect*, when the mutation went **0 red** because the
fixture held no damaged line in the archive it claimed to be about. Mutating
first and confirming red — which every unit here did — still let five through,
because the mutation and the fixture were chosen from the same wrong
assumption. **A test that would pass both before and after the code exists is
not a test**, and the fixture is where to look for that, not the assertion.

**One claim to keep honest:** `_history_archive_note`'s count parameter, which
four callers each re-derived and one passed a hard-coded `0` to, was a *latent*
hazard rather than a live defect — the decoder only reports a truncated member
when something decoded, so the count and the reason always agreed, and the
hard-coded `0` sat in a branch where the archive contributed nothing and was
correct by construction. Replacing it with a reason chosen where the failure
happens is a real improvement and the only thing that could give the two new
shapes (no `zcat`, not base64) sentences of their own. It did not fix a wrong
message.

### Accepted limits at the close

- **Rotation's exit-3 message names one state where two are possible.** The
  append to the archive failing *after* writing bytes and failing *before*
  writing any are both reported as "stopped partway … may end in an incomplete
  gzip member". Reproduced with the archive path occupied by a directory:
  nothing was appended, and the repair advice is wrong for that state. The
  shell prints its own diagnosis on the line above, and the workstation
  independently calls that archive `notfile`, so nothing silently believes the
  wrong thing. Left as it stands rather than widened at a phase close.
- **The archive's mode under real ownership is rig-proof only in part.**
  `rotation_test.sh` uses real files and a real umask, but no test has a
  root-run deploy leaving an archive the ssh user cannot read. That is the one
  item from the group review's real-infrastructure list that this phase could
  not close.
- **No `zcat` on the workstation** is proven hermetically only, by rebuilding
  `PATH` from symlinks with `zcat` removed.
- **`deploy X.Y.Z` has no rig case.** The engine is shared with `rollback` and
  the mode difference is one argument, so the risk is the wiring rather than
  the path — but it is untested against a real server.
