# Phase 8 — Keep

> Projects can be removed safely at every scope, VPSes can be handed over,
> and everything that exists only on a VPS also exists off it.

**Prerequisite:** Phase 7 (destroy touches mail creds; backup scope
includes mail data). **Lighter spec — re-read before starting.**
**Spec:** `docs/backup.md` (whole file), `docs/cli.md` (drop, server destroy), `docs/server-setup.md` (Handover / teardown), `docs/compliance.md` (`--fix`)

## Exit criteria
- [ ] Rig: deploy → `drop` → redeploy resurrects fully (data intact); `drop --prune` leaves no trace under `/apps/<name>` or `/apps/data/<name>`
- [ ] Rig: `server destroy` → every container still serving, no `kasbah.yml` / `versions.log` / helpers / marker / backup creds / backup stack remain
- [ ] A restic snapshot from the rig restores onto a **fresh** rig and the project comes back (the restore drill from `backup.md`, executed once for real). *"Fresh" is operationalised as `rig_clean`: `/apps` and every nested compose project wiped. The snapshot store is a named volume on the workstation's Docker, outside the rig, so it survives that.*
- [ ] `check --fix` applies C01–C05, C08, R01–R03 and the `kasbah_version` backfill with a diff shown first, and never touches anything else

## Run order

Execution order, approved 2026-08-26. Task blocks below are in this order; the
**ids never move** — 8.0 is an insertion at a gap number, so every reference
elsewhere to 8.1–8.4 stays valid.

| # | Unit | Why here |
|---|---|---|
| 1 | 8.0 | Changes `tests/rig/compose.yml`, which all 15 integration suites load. Separate from 8.3 so a harness regression surfaces before 8.3's restic logic lands on top of it |
| 2 | 8.1 | Independent of everything. Adds `prompt_typed` to `lib/prompt.sh`, which 8.2 reuses, and establishes the "remove a project's remote footprint" shape |
| 3 | 8.3 | Needs 8.0. Moved **ahead of 8.2**: the plan's own order has destroy removing a backup stack and credentials that do not exist yet, so destroy's second half would land untested |
| 4 | 8.2 | Needs 8.3's artifacts to remove and to assert removed; reuses 8.1's `prompt_typed` and its removal idioms |
| 5 | 8.4 | Purely local — no rig, no SSH. The only unit nothing can block |
| 6 | 8.5 | *Inserted mid-run from 8.3's review.* Reads the record 8.3 writes, so it cannot precede it; small, and last because nothing depends on it |

**Fully sequential**, by the operator's choice. 8.4 is genuinely parallel-safe
(it touches only `lib/check.sh`, `tests/check_test.sh` and docs — not even the
`bin/kasbah` dispatcher that 8.1 and 8.2 touch), and was offered as a
concurrency lever; sequential was taken so every suite run has the tree to
itself, which is what Phase 7's findings argue for.

## Verification regime

Phase 7's amended regime, carried forward, plus a real-host pass at the close.

1. **Per task, the affected unit suites only** — `bash tests/<x>_test.sh`.
2. **Per task, the task's own integration suite only** — `bash tests/integration/<x>_test.sh`.
3. **Per task, one hand-driven operator pass against the rig** — what suites do not catch.
4. **The gate, at the phase close, with nothing else writing:** `./test.sh`
   (baseline **25 PASS**, exit 0, ~7m) and `KASBAH_RIG_TESTS=1 ./test.sh`
   (baseline **39 PASS**, exit 0, no skips, ~16m).
5. **No routine confirmation review round.** The orchestrator verifies fixes
   directly and re-reviews only when the fix was structural.
6. **Command output is captured to `/tmp/kasbah-phase8-logs/` and queried**,
   never filtered live — outside the repo so the review checkpoint stays clean.

**The real host.** `you@vps`, Phase 6's OVH
VPS, declared a test deployment by the operator. Phase 8's close drives
`drop`/redeploy and the backup drills there, and then `server destroy` **last**,
with the price accepted in advance: re-branding is a `server init` re-run, but
that host's `versions.log` deploy history is gone permanently and any relay
block in `/apps/mail/.env` must be re-entered by hand. The original project's
**production** hosts, its containers on the workstation and
`~/work/gallery-website` are off-limits entirely.

## Open decisions — settled 2026-08-26

Every one of these was a contradiction between the plan and a spec, or a gap the
spec never filled. They are settled; they are not up for relitigation.

**D1 — `server init` installs no packages. restic runs as a container.**
`server-setup.md:4` promises init "doesn't install packages"; its own
`--with-backup` section and `backup.md` said "installs restic". The promise
wins: backups run as `docker run --rm … restic/restic`. No apt, no sudo, no
distro assumption, one pinned restic version across every VPS, and it matches
the standing rule that the far side needs no `jq`, `yq` or `python3`.
*Reconciles: `server-setup.md` → With backup, `backup.md` → Model.*

**D2 — the restic repo password is operator-supplied, one per client repo.**
`backup.md` specified the S3 credential split and never said where the
*encryption* password lives — a password whose only copy is on the VPS makes the
backups unreadable in the exact scenario the feature exists for. kasbah never
generates one. Repos are the offboarding unit, so the password is per repo: a
departing client's repo can be handed over with its password without exposing
any other. *Adds: `backup.md` → Credentials.*

**D3 — the schedule is a kasbah-owned compose stack, not cron.**
`/apps/.kasbah/backup/compose.yml`: one always-on container, `restart:
unless-stopped`, sleeping until 02:00 plus a per-VPS jitter, then invoking
restic. Cron is not in the prerequisites table and the rig has neither the
binary nor a daemon (probed 2026-08-26: no `cron`, no `crontab`, no `restic`,
no `wget`). This keeps the prerequisites table unchanged, survives reboot, and
is the same "kasbah owns a compose stack" pattern as Traefik and mail.
*Reconciles: `backup.md` → Cadence.*

**D4 — the rig's backup target is `restic/rest-server --append-only`.**
The append-only assertion is the whole security property, so the endpoint has to
actually *enforce* it. Every lightweight S3 stand-in fails that: `s3mock` and
`s3proxy` have no auth model, LocalStack community does not enforce IAM, and
SeaweedFS and Garage fold delete into "write" so append-only is not expressible.
rest-server's `--append-only` is a first-class restic feature — and this phase's
own watch-out already named it as valid enforcement. ~20 MB, versus Ceph RGW's
~1.5 GB on a rig every suite waits for.

**D5 — kasbah never parses the repo URL.** Consequence of D4: the rig speaks
`rest:` and production speaks `s3:`, so special-casing either would leave the
rig testing a path production never runs. `--with-backup` stores an opaque
`repo_base`, a per-client repo path, a password and an environment block handed
to restic — backend-agnostic by construction. *Reconciles: `backup.md` says
S3-compatible is the documented target, not the only one.*

**D6 — init probes the credentials for real.** kasbah cannot *create*
append-only credentials; the operator creates them at their provider and hands
kasbah a key pair. So `--with-backup` writes a probe object, attempts to delete
it, and refuses when the delete succeeds. One code path, both backends — which
is what stops the property being decorative on real infrastructure as well as on
the rig.

**D7 — mail data is backed up, in a repo of its own.** `backup.md` → Scope is
strictly per-project and `mail` is a *reserved* name excluded from project
discovery, so under a literal reading every mailbox on the VPS was backed up by
nobody. `/apps/data/mail/` and `/apps/mail/.env` snapshot to `<repo_base>/mail`,
alongside the per-client repos — a separate repo rather than the primary
domain's client repo, because folding the whole VPS's mail into one client's
repo is exactly what the per-client split exists to prevent. *Adds:
`backup.md` → Scope.*

**D8 — `server destroy` removes four things the documented lists omit.** The
handover lists in `cli.md` and `server-setup.md` predate features that landed
after them. Added: `/etc/kasbah/apps-path` (the Phase 4 discovery pointer —
warns and continues when there is no passwordless sudo, rather than failing);
the `.env` managed-block **sentinel comments** in every project (the *values*
stay — compose interpolates `KASBAH_CPU_LIMIT`/`KASBAH_MEM_LIMIT` into every
service's `cpus:`/`mem_limit:`, so stripping them stops the new owner's
containers — but nothing will ever rewrite that block again, so its own text
becomes false); the operator's relay block in `/apps/mail/.env`, by the same
logic that removes the S3 credentials, with kasbah's three keys left so the
stack still starts; and 8.3's backup stack and credentials. **The postmaster
account (`postfix-accounts.cf`) stays** — removing it leaves containers running
that nobody can authenticate to, which contradicts destroy's "every container
still serving" promise. *Reconciles: `cli.md` → server destroy,
`server-setup.md` → Handover.*

**D9 — `check --fix` includes C08.** The rule set was spelled three ways:
`roadmap.md` said C01–C05, this file's task said C01–C05 + R01–R03 +
`kasbah_version`, and `compliance.md` said C01–C05, **C08**, R01–R03 and
`kasbah_version`. C08 landed in Phase 7 (task 7.0), after this file was written.
Docs are the spec, so `compliance.md` wins; the exit criterion above and the
`roadmap.md` line are corrected in 8.4's change.

**D10 — confirmation shape for `drop` and `server destroy`.** `prompt_confirm`
(yes/no) **then** a typed project name or hostname; `--yes` skips both. A new
`prompt_typed` in `lib/prompt.sh` lands with 8.1 and is reused by 8.2, so the
two commands cannot drift on what "double confirmation" means.

**D11 — `drop` and the mail claim.** Plain `drop` **keeps** the project's
mail-domain claim in the registry: it is the reversible verb, a redeploy
resurrects the project, and the claim is what makes that whole. `drop --prune`
**releases** it and names the domain in the confirmation summary. Reversal is
`kasbah server add-mail-domain USER@HOST <domain>`.

## Tasks

### 8.0 — the rig's backup harness (S) *(inserted)*
`restic/rest-server` as a service in `tests/rig/compose.yml`, running
`--append-only`, with **two credential sets**: the append-only one the VPS
gets, and a full-access one for the operator side. `rig.sh` gains its
readiness wait; `tests/integration/rig_env.sh` gains the helpers that
hand a repo URL and credentials to a suite; `tests/rig/README.md` gains a
section saying what this can and cannot prove.

**Watch out for:** every other integration suite loads this compose file
and waits on the rig coming up — a slow or unhealthy new service taxes
all fifteen. The snapshot store must be a **named volume on the
workstation's Docker**, so `rig_clean` (which wipes `/apps` and every
*nested* compose project) cannot reach it; that survival is what makes
exit criterion 3's "fresh rig" executable at all.

**Verify on:** rig — the harness comes up, restic reaches it from inside
the rig, the append-only credential is refused a delete and the
full-access one is not. Plus a spot-check that two unrelated integration
suites still pass unchanged.

### 8.1 — `drop [--prune]` (M)
Per `cli.md`: down, fragment removed, all project images removed; keeps
config/data/backups. `--prune` deletes those too. Double confirmation
(typed project name); `--yes` for scripts. Per **D10**, `prompt_typed`
lands here. Per **D11**, `--prune` releases the mail claim and plain
`drop` does not.

**Watch out for:** image removal must not touch tags shared with other
projects (stock images like `postgres:16` are shared — remove only tags
matching this project's built images, plus project-specific pulls only if
unreferenced). `lib/prune.sh`'s `_prune_project_repos` and `_prune_plan`
already establish exactly this ownership rule across every project on the
server; `drop` needs the same rule over one. Read it before writing a
second answer to the same question — Phase 7's close records what "one
question, four readers, two answers" cost.

**Verify on:** rig — deploy, `drop`, redeploy resurrects with data intact;
`drop --prune` leaves nothing under `/apps/<name>` or `/apps/data/<name>`;
a stock image another project uses survives both.

### 8.3 — `--with-backup`: restic push (L)
Per `backup.md` as amended by **D1–D7**: containerised restic, a
kasbah-owned compose stack for the daily schedule with jitter, repo per
`client:` (default `name`) plus a `mail` repo, scope = data + backups +
`.env`, operator-supplied password per repo, and a live delete-probe at
init. Operator-side `kasbah server backup-prune USER@HOST` with full
credentials. Rig tests target 8.0's rest-server.

**Watch out for:** append-only enforcement is credential-side, not a
restic flag on the VPS — the rig test must *prove* the VPS credential
cannot delete (attempt a delete, assert failure), or the whole security
property is decorative. Pair it with a positive that pins the same
mechanism from the other side, per Phase 7's rule on vacuous negatives.
The marker write **merges, never replaces** (`server-setup.md`), and
`backup.repo_base` is the key that document already anticipates surviving
a re-run by an older kasbah — Phase 2's finding names this exact field.

**Verify on:** rig — snapshot taken, VPS credential refused a delete,
operator credential prunes; then the full restore drill: `rig_clean`,
`server init`, restic restore, `kasbah deploy`, project back with its
data. Real host at the close.

### 8.2 — `server destroy` (M)
Full de-branding per `server-setup.md` as amended by **D8**: marker,
`/etc/kasbah/apps-path`, backup stack + creds, per-project
`versions.log(.gz)` / `scripts/` helpers / `.deploy.lock`, the `.env`
managed-block sentinel comments, the mail relay block. Containers and
Traefik keep running. Typed-hostname confirmation via 8.1's
`prompt_typed`.

**Watch out for:** verify serving *after* each removal step on the rig —
the point is proving de-branding is non-disruptive, so the test asserts
uptime through the whole operation. The `.env` values must survive the
sentinel strip or every service loses its `cpus:`/`mem_limit:`
interpolation on the next `compose up`; assert a project still starts
*after* destroy, not just that it is still running.

**Verify on:** rig — every container still serving through the whole
operation and after a restart; none of the listed artifacts remain. Real
host at the close, last.

### 8.4 — `check --fix` (M)
Auto-fixes per `compliance.md`: C01–C05, **C08**, R01–R03, `kasbah_version`
backfill (**D9**). Diff before writing; only `compose.prod.yml` and
`kasbah.yml` are ever touched. Corrects `roadmap.md`'s "C01-C05" line and
`cli.md`'s "not implemented" note in the same change.

**Watch out for:** yq round-trips reorder YAML and drop comments — fix
with targeted edits (or yq in-place only on files it already formats),
and assert comment survival in the test, since compose files carry
load-bearing comments in real projects.

**Verify on:** unit suites plus a hand-driven pass over
`tests/fixtures/` — a deliberately non-compliant fixture goes to fully
compliant, with its comments intact, and a compliant one is left
byte-identical.

### 8.5 — `server status` and `check` learn about backups (S) *(inserted)*
Carried out of 8.3's review, with a home rather than a hope. 8.3 writes a
last-run record beside the backup config; **nothing reads it**. `server status`
prints no backup line at all, `check` has no rule for it, and the stack has no
healthcheck a `docker ps` would show — so a backup that has silently stopped is
visible only in `docker logs`, on a feature whose entire value is that somebody
notices before the restore.

Deliverables: a backup section in `kasbah server status` following
`_ss_print_mail`'s shape (enabled, repo base with credentials redacted, when it
last ran and how it went, which repositories have no password); and a rule in
`check --server` that fails a stack whose last run failed or is older than its
cadence allows.

**Watch out for:** Phase 5's rule — a command concluding something from the
*absence* of a record must say so rather than inferring. A missing last-run file
on a server whose stack has never fired once is not the same fact as a stack
that stopped a month ago, and reporting them identically is how this rule
becomes decoration.

**Verify on:** rig — status reports a healthy stack, a never-run stack and a
failed run distinctly; `check --server` fails the last of the three.

## Findings

**Approved scope, 2026-08-26:** the whole phase, fully sequential, in the order
8.0 → 8.1 → 8.3 → 8.2 → 8.4, then the close. Verification regime and the
real-host terms are above; the eleven settled decisions are above. Baselines to
regress against: `./test.sh` 25 PASS exit 0 ~7m; `KASBAH_RIG_TESTS=1 ./test.sh`
39 PASS exit 0, no skips, ~16m — **40 from 8.0 onward**, which adds
`tests/integration/backup_harness_test.sh` (~21 s).

Two things the Tasks section cannot carry. **The rig was probed before the run,
not assumed:** no `cron`, no `crontab`, no `restic`, no `wget`, no `jq`, no
`yq`, no `python3`, no cron daemon; Debian 12; `stevedore` in `docker` with
passwordless sudo. D3 rests on that probe. And **five of the eleven decisions
above exist because a doc contradicted another doc, not because the plan was
ambiguous** — `server-setup.md` contradicted itself 413 lines apart, and three
of the handover/scope lists predate the features they omit. Anything in Phase 9
that reads these documents should expect the same and check the code.

### 8.0 — the rig's backup harness

Review verdict: **needs-work**, on nine defects and four matters of taste. The
one that mattered came back clean: the reviewer attacked the append-only
assertion from every angle in the vacuity catalogue and could not make it pass
while the property was false. Property false ⇒ `forget` exits 0 ⇒ the paired
non-zero-exit assertion fails before the `403` grep is ever reached; a wrong
credential is a `401`, not a `403`; an ssh drop is non-zero with no `403`. Both
halves are load-bearing. Confirmed independently: `kasbah-vps` against the
full-access endpoint is `401`, `kasbah-ops` against the append-only one is
`401`, and over the *shared* volume an overwrite is `403`, an object delete is
`403`, and a repository `DELETE` is `405` on **both** endpoints — only `locks/`
deletes pass, which is what restic needs to run at all.

Dispositions — all nine defects and three of the four taste items **fixed in
this task**, one taste item **rejected**:

- **F1 (fix) — the pinned subnet was inside Docker's own default pool.**
  `docker info --format '{{json .DefaultAddressPools}}'` is `null`, so Docker
  auto-allocates from `172.16.0.0/12` in `/16` blocks — `172.17` through
  `172.31`. `172.29.0.0/24` is squarely inside it, so the third unrelated
  compose project a developer starts while the rig is down claims `172.29.0.0/16`
  and from then on `rig.sh up` dies on "Pool overlaps" — blocking **all fifteen**
  integration suites until someone hand-edits `compose.yml`. Moved outside the
  default pools entirely. The lesson generalises: *pinning an address inside the
  range your allocator draws from is not a pin, it is a race you usually win.*
- **F2, F6, F7 (fix, as one) — a broken harness took the whole rig down with it.**
  `write_backup_env`'s `die` ran *after* the rig was up and healthy, so a
  one-suite problem became a no-rig problem for fifteen; meanwhile the comments
  claimed the file's existence meant "usable" and that it was regenerated per
  invocation like `ssh_config`, neither of which the code did. One coherent fix:
  warn instead of dying, and **remove** the contract file when the harness is not
  serving, so absence means what the comment always claimed it meant.
- **F5 (fix) — "404 proves authentication is on" was false, in three places.**
  A `--no-auth` server answers `404` to a bogus credential just as happily; what
  `404` proves is *listening* and *credential not rejected*. The empty-htpasswd
  half of the claim was right. Fixed by making the claim true rather than by
  weakening it — the probe now also requires a bogus credential to be refused,
  which is this repo's own rule about pairing a negative with a positive.
- **F3, F4 (fix) — two documented facts that were not facts.** `rig.sh down -v`
  is rejected by `rig.sh` itself (`down` takes no arguments). And the comment
  justifying the `forget` spelling cited one spelling against the *other*
  spelling's error — both strings are real on restic 0.18.0, which is why the
  review read it as a fabricated quote and the first correction I asked for was
  itself wrong: `forget --keep-last 0 --prune` says `Fatal: no policy was
  specified, no snapshots will be removed`, while adding
  `--unsafe-allow-remove-all` says `Fatal: --unsafe-allow-remove-all is not
  allowed unless a snapshot filter option is specified`. Both now appear against
  their own spelling, with the version pinned. The *reasoning* in both cases was
  right; the pairing was not — and a mismatched-but-real quote is harder to
  catch than an invented one, because grepping for the string finds it.
- **F8 (fix) — `%q` was building a URL.** It makes the file sourceable, not
  URL-safe: a password with a space, `@` or `/` yields a repo URL restic cannot
  parse, and a `'` breaks the two ssh probes that interpolate it. Constrained
  and guarded loudly rather than percent-encoded — these are harness constants
  declared in `compose.yml`, so the cheap guard is proportionate and the comment
  no longer claims otherwise.
- **F9 (fix) — `{{range .Networks}}{{.IPAddress}}{{end}}` concatenates.** Two
  networks would yield `172.29.0.10172.30.0.5` and the non-empty guard waves it
  through. Single-network today, silent tomorrow.
- **Taste (fix ×3):** `restart: unless-stopped` on both sidecars while the `rig`
  service has none meant a workstation reboot brought the backup endpoints back
  and not the thing they exist for — the sidecars now follow the rig's lifecycle;
  `export RIG_RESTIC_MOUNT` leaked a `-v` into every later `rig_restic`; and a
  bare `403` needle became `403 Forbidden`.
- **Taste (reject):** `wait_backup_ready`'s ssh carrying no local `timeout`. The
  deadline lives on the far side, which is exactly what the existing `probe()`
  does — matching the established idiom is right, and changing one of the two
  would be the drift.

Measured during the task and worth keeping: nested dockerd copies the rig's
`/etc/resolv.conf`, finds the embedded resolver at `127.0.0.11`, decides a
loopback nameserver cannot be inherited, and substitutes `8.8.8.8` — so a
sibling service name resolves from the rig's shell and **not** from a container
two namespaces down, while the same address by IP works from both. Routing is
fine; only the name dies. `restic/rest-server:0.14.0` is 18.6 MB and
`restic/restic:0.18.0` is 17.3 MB. `rig.sh up` went 0.88 s → 1.33 s.
`rest-server` answers **405** to a `DELETE` on a repository path, so repositories
cannot be removed over the wire at all — 8.3's `backup-prune` inherits that.
And `bash` cannot see a heredoc delimiter through `$(…)`: `out=$(ssh … <<'R' … R)`
emits `warning: command substitution: 1 unterminated here-document` and runs
anyway, which is worth remembering when 8.3 writes remote payloads.

The fix round closed all twelve and cost one round. Three of the fixes changed
`rig.sh up`'s failure behaviour, so each was driven for real rather than argued:
a sidecar that cannot start, an endpoint serving with `--no-auth`, and a
credential with a space and an `@` in it. All three now leave `up` exiting 0 with
the ready line printed and `backup_env.sh` **absent**, and the harness suite
exits 2 — the environment-is-wrong code — instead of failing. The `--no-auth`
case is also the direct proof that F5's fix bites: that server passed the old
single-404 gate and is refused by the new one.

### 8.1 — `drop [--prune]`

Review verdict: **needs-work**, on eight defects and four matters of taste. The
part that could destroy a server came back clean and was left alone: the
reviewer attacked the `rm -rf` path directly with `../beta`, `alpha/../beta`,
`.`, `..`, `/`, `-rf`, `Demo`, empty, an embedded `;`, an embedded newline and
CRLF — every one refused — and independently re-ran two of the implementer's
mutations, both red. **The payload's own guard is the last word**, and that is
the layer that matters: a payload on the far side of ssh can source nothing and
must not trust an argument this side assembled.

Dispositions:

- **A, B (fix) — the failure path lies twice.** A failed image removal printed
  *above* the route and `down` lines, under a comment claiming lines were
  collected precisely so the report reads in the order the far side did the
  work. Only the success branch was collected. And the closing paragraph printed
  unconditionally, so a failed run's last line was "alpha is off <host>, and
  everything a redeploy needs is still there" — then exit 1. The same exit also
  skipped `state_record last_server` on a run that had reached and changed the
  server. **The ordering defect was found by hand, fixed once, and left on the
  failure path — which is where the operator is least able to check the claim.**
- **C (fix) — `--prune`'s refusal gave a reason that was false in two of the
  three cases that triggered it.** When the unreadable compose belonged to a
  *different* project, the message named this one. And when **this** project's
  directory held no `compose.yml` at all, it refused with "Fix the compose.yml
  above" — naming a file that is not there, leaving a hand-run `rm -rf` on the
  server as the only remedy, which is the exact act `--prune` exists to avoid. A
  deploy that dies between `mkdir` and the compose rsync leaves precisely that
  state. Now: refusal kept where it is defensible, with the true reason and the
  right project named; and `--prune` proceeds when there is no record to destroy.
- **D (fix) — a whole validation layer could not fire.** `_drop_check_name` ran
  one line *after* `manifest_require`, which already enforces the identical
  regex and the identical reserved list, so every hostile manifest came back in
  `manifest.sh`'s words and never `drop.sh`'s. Verified before ordering the
  deletion. Its 24 unit assertions were exercising the dead copy, not the guard
  — **a test suite can be thorough about the wrong layer and read as coverage.**
- **E (fix) — the plan and the act disagreed about which containers exist.** The
  probe filtered on the project label alone; `docker compose down` additionally
  requires `com.docker.compose.oneoff=False`. A container carrying only the
  project label survives `down` with rc=0, so the run reported "brought down"
  while the container the confirmation had listed was untouched, and
  `_drop_anything_to_do` would report work outstanding forever.
- **F (fix ×4) — message defects:** a `build-push` hint printed in the cliff case
  where nothing was removed and the images are all still there; an unparseable
  registry tolerated while a parseable-but-invalid one killed the run before the
  plan printed, with a message never mentioning `drop`; named volumes never
  removed by `--prune` and nowhere said; and the plan going to stdout while the
  outcome went to stderr, so `kasbah drop > log` captures what was planned and
  not what happened.
- **G (fix ×3) — test gaps**, one of them the "reading nothing" vacuity pattern:
  `[ -e $data/$neighbour ] || [ -e $apps/$neighbour ]` where the right-hand side
  is always true because that project is never dropped, so the assertion could
  not fail.
- **H (fix ×3) — taste:** `drop.sh` sourced `server_mail.sh` → `server_init.sh`
  (~2000 lines) on *every* drop, while a comment eleven hundred lines down
  explains declining to source `deploy.sh` on exactly that ground; the payload's
  hardcoded reserved-name list had nothing pinning it to `KASBAH_RESERVED_NAMES`
  (now pinned by assertion, the `norm_path_test.sh` answer to the same problem);
  and `keep` rows printed under a heading reading `removed`.
- **Reject:** unquoted `for repo in $_DROP_REPOS`. Same shape as `prune.sh:804`
  — matching the established idiom is right, and changing one of two copies is
  the drift.

**Three round trips, not the two the idiom uses** — `marker_read`, the batched
probe, the act — and that is correct here. Folding the marker in would need a
*fifth* copy of the path-normalising helper on the far side, and
`tests/norm_path_test.sh` hardcodes the four it knows; a fifth would be drift no
suite can see. And `lib/ssh.sh` multiplexes over one ControlMaster, so none of
the three is a new sshd session and `maxstartups 10` is not in play. The brief
asserted the two-trip rule; the implementer was right to push back.

**The plan's own watch-out contradicted `cli.md`.** The watch-out said image
removal covers "project-specific pulls only if unreferenced"; `cli.md` says "the
project's **loaded** images", which is `build-push`'s `docker load` set — built
images. Built-images-only is implemented, both the implementer and the reviewer
independently judged `cli.md` right, and the reason is the stronger argument: a
"pulls if unreferenced" rule would let dropping one project reach images no
compose file attributes to it, which is the very thing the ownership rule
exists to prevent. **The watch-out above is corrected; `cli.md` wins.**

**A plain `drop` leaves a redeploy needing `--allow-stopped`.** `versions.log`
survives by design, so `rd_outgoing_preflight` sees "this project has deployed
here before" while the hook and backup containers no longer exist, and refuses.
It bites only projects declaring hooks or `backup:` — `--prune` removes the
record, so that path is a clean first deploy. `cli.md` promised a later deploy
"fully resurrects the project" with no caveat, which was wrong as written.
`drop` now prints the exact return command, flag included when the manifest
needs it, because the doc nobody rereads is not where that belongs.

**Found in a neighbouring command and fixed here:** declining
`kasbah server prune` exited 1 with **nothing printed** — `prompt_confirm`
called bare under `errexit` — so an operator answering `n` and an operator
hitting a failure saw the identical run. `drop` answering the same question in
two sentences while `prune` answered it in silence is the inconsistency this
project keeps rediscovering under a different name.

**D12 — `deploy` records the effective `client` on the server.** Found before
8.3 was briefed: `backup.md` puts each project's snapshots in
`<repo_base>/<client>`, `project-manifest.md` documents `client:` as a manifest
field defaulting to `name` — and **the manifest is never synced to a server**,
so nothing on the VPS can know it. `client:` is also read by no code anywhere
today. The backup stack runs *on* the VPS, so it needs the answer there.
Resolved the way Phase 4 already established for hooks, backup and health:
manifest data is **rendered** onto the server, never synced. `deploy` writes the
effective client alongside the project; the backup run reads it, falls back to
the project's directory name when it is absent — which is `client`'s documented
default, so the fallback is correct rather than a guess — and **names every
project that fell back**, so a project deployed before backups were enabled and
filing into the wrong repo is visible instead of silent. Rejected: dropping
per-client grouping and giving every project its own repo. That is a smaller
change, and it discards the offboarding property — one client, one repo, handed
over or deleted whole — that D7 had just invoked to give mail a repo of its own.

**D13 — `server backup-prune` runs restic on the workstation, not the VPS.** The
whole credential design is that full-access keys live only on operator machines;
shipping them to the VPS for the duration of a prune would put them on the box
the model assumes is compromised. The host argument is for *discovery* — which
repositories exist, from the marker's `repo_base` and the server's project list
— and the deletion runs locally. The workstation already needs Docker for
`server init`'s bcrypt hashing, so the containerised restic of D1 works on both
sides.

### 8.3 — `--with-backup`

Review verdict: **needs-work**, on one critical defect, one high, five
medium/low and five matters of taste. Idempotency, the marker merge, the file
modes and transport, D5, the POSIX runner, D12's blast radius and the whole
interactivity sweep came back clean and independently verified — three
consecutive inits left `/apps/.kasbah` byte-identical by sha256, container id
and start time included.

**The critical one is the shape to remember: a security check with a one-flag
bypass, followed by a report asserting the check it never ran.** The probe built
its `--env-file` with kasbah's keys **first** and the operator's after;
`docker --env-file` is last-wins; and the reserved-key check covered only
`KASBAH_BACKUP_*`. So `--backup-env=RESTIC_REPOSITORY=<somewhere else>`
redirected the probe while the runner — which sets that variable *after* loading
the operator's file — went on writing to the real target. Demonstrated on the
rig: a **full-access** credential, the exact thing the feature exists to refuse,
accepted with exit 0, stack started, marker written, under a summary line naming
a URL nothing had contacted. And sticky, because the key lands in the operator
half of the env file, which is copied through untouched for ever. Fixed in three
layers, because each alone leaves a hole: the five `RESTIC_*` keys that redirect
target or key material are reserved; kasbah's keys are written **last** so
last-wins works for the invariant instead of against it; and an env file already
carrying one is refused at read time rather than copied. **What made it
invisible was that probe and runner disagreed silently** — two readers of one
question, which is this project's most-repeated defect, in its most dangerous
possible location.

Second: **kasbah was less careful with a credential than the tool it wraps.**
`repo_base` was printed verbatim in nine places, including refusal messages, on
a URL whose whole point is that it may carry userinfo — while restic's own lines
in the *same output* printed `kasbah-ops:***`. The marker holding it is mode 644
by contract, so it is world-readable on the VPS. Now redacted on print and
warned about once, not refused: the rig's harness embeds credentials, and
refusing would put a rig-shaped constraint on production.

Also fixed: `backup-prune`'s errors named `server init` and three flags it does
not have (its tests asserted exit status and the word "unknown flag" only, so
nothing saw it); a **fifth and sixth** unpinned copy of `KASBAH_RESERVED_NAMES`
in a file whose own header explains why there must be one list; `_bk_read` and
the runner disagreeing about a non-default `--data-path` under the apps path, so
init would prompt for a repository the runner would never write to; the probe's
refusal failing open on a listing that *errored* rather than listed zero; and a
comment claiming `set -o pipefail` was "supported and used" in a script with no
pipeline in it.

**A wedged backup never slept again.** Pointed at a black-holed endpoint,
`backup.sh once` printed `run started` and was still running with twelve restic
threads five minutes later; the schedule loop never returns to `sleep`, so the
container stays "running" and backs nothing up for ever, and
`restart: unless-stopped` cannot help because the stack declared no healthcheck.
`backup.md` promised a failed run is "slept off" — a *wedged* one was not slept
off at all. Now bounded by a timeout with an operator-visible knob, with a
healthcheck and a last-run record. **Carried to 8.5:** nothing yet *reads* that
record — `server status` prints no backup line and `check` has no rule — and a
safety mechanism with no consumer is indistinguishable from no safety mechanism,
which is Phase 5's finding arriving for the third time in this project.

**Two restic facts, both measured twice and both load-bearing.**

*Exit status is a property of the content, not of the credential.*
`forget <id> --prune` over the append-only endpoint with two snapshots that
**differ** exits non-zero — but the fatal is on the *index* rebuild, not the
snapshot. With two **identical** snapshots the same command over the same
endpoint prints `403 Forbidden` and `unable to remove` and exits **0**. Any
probe judging the status is judging its fixture. Every verdict here rests on the
snapshot listing instead, and the design was vindicated end to end: pointed at
the full-access endpoint, init refused **in exactly the case where restic exited
0** — an exit-status probe would have waved it through.

*`forget --keep-last 1` is a vacuous delete probe.* restic groups snapshots by
host and paths before applying retention, and `docker run` assigns a random
hostname — so two probe snapshots are two groups, each keeps its last, and
nothing is removed **however much access the credential has**. That version
passed against the full-access endpoint. Both the `--hostname` pin and the
named-id spelling are load-bearing, and the rig test is what caught it.

**8.0's own assertion was fragile, and is now fixed here.**
`backup_harness_test.sh` asserted a non-zero exit as one of four checks on the
same property. It was not wrong — the failure direction holds, and the other
three rest on the listing — but it was reliable only because that fixture's two
snapshots differ. Make them identical, a one-line change nobody would connect to
the security property, and the suite goes red while the property still holds.
The status is now **reported and not asserted**, with the reason in the comment;
mutating the credential to the full-access endpoint still turns the suite red on
three listing-based assertions, so nothing was hollowed out by removing it.

Two more found by hand rather than by any suite, continuing this phase's
pattern: the env file grew **one newline per run**, so it was re-shipped for ever
and "a re-run changes nothing" was false — and the unit assertion that should
have caught it was itself vacuous, because `$(…)` strips trailing newlines and
both sides compared equal. And the probe repository was **un-prunable**: random
container hostnames made every probe snapshot its own retention group, so it grew
by two snapshots per init run, permanently.

The fix round closed all twelve and cost one round. Two judgement calls stand as
made. **`backup-prune`'s own restic is deliberately unbounded**, alone among
every restic call: it is an interactive foreground command whose legitimate
`prune` repack can take a very long time, and a bound there would fail exactly
the runs that most need patience. The wedge this phase fixed was an *unattended
loop that never slept again*; a foreground command with an operator watching it
is a different animal. And **`forget --keep-last 1` alone no longer reddens the
suite, which is correct**: the `--hostname` pin added for the prune-growth
defect independently makes the policy spelling work. Mutating *both* halves —
the spelling and a random hostname — reproduces the original defect and goes red
end to end. Two independent fixes for one bug, and the named-id spelling is the
stronger, because it does not depend on the pin.

Two more the implementer found in its own work while fixing, both about how a
result was read rather than what the code did — the fourth and fifth instances
of that class this project has recorded:

**`_server_init_usage` is an unquoted heredoc**, and two added lines used
backticks, so `kasbah server init --help` printed `retention, applied by` and
`one repository per` with the words in between **executed and discarded**. Now
pinned by a `--help` test that also asserts every backup flag is listed.

**The unit suite could exit non-zero while printing zero `FAIL` lines** — an
unbound variable inside an `assert`'s `eval` killed it under `set -u` — and
`grep -c FAIL` returning 0 was read as green across two rounds of edits. This is
Phase 7's `echo "$(cmd) rc=$?"` finding wearing a different hat: **the count of
failure lines is not the exit status, and only the exit status is the verdict.**
Relatedly, the wedge case had to stop capturing through `$( )`: `timeout`
signals only the process it starts, and descendants holding the capture's pipe
kept the outer bound as ineffective as the inner one it stood in for — measured
at 600 s against a 30 s bound before the harness cut it.

### 8.2 — `server destroy`

Review verdict: **needs-work**, on two behavioural defects, one demonstrated-
vacuous assertion, one weak witness and two message defects. The `.env` rewrite
— the one thing here that edits a file holding a project's only copy of its
secrets — came back **clean under every mutation the reviewer could construct**:
every awkward shape, mode preservation, `umask 077` creation with the mode set
before content, an atomic rename, and a genuinely unchanged file on every
failure branch. The sentinel-provenance claim held too: the strings appear
nowhere in `lib/server_destroy.sh`, both payloads take them as `ssh_script`
arguments from `lib/env.sh`'s own variables, so the two readers cannot disagree.

**The headline defect is 8.1's, recurring in a worse form.** Three far-side
outcomes warned and carried on without setting `bad` — an unreadable project
`.env`, an unreadable mail `.env`, and no passwordless sudo — while the closing
paragraph was gated on `bad` alone. So a run that could not strip a relay
credential ended with *"nothing kasbah installed is left to hand over with it"*
and **exit 0**. Worse than 8.1's version, because the marker and pointer are
removed on the same run: a second destroy then cannot enumerate the server and
reports it clean while `RELAY_PASSWORD=` is still in `<apps>/mail/.env`. The
command's headline security promise is the thing that failed silently, and the
comment above the paragraph claimed it "is only true of a run where every step
did what it was asked". Now split: an unreadable `.env` is a **failure** that
holds the marker and pointer and exits 1, while `nosudo` keeps its spec'd exit 0
and gets its own honest sentence.

**A stray file under `<apps>` blocked the whole command, after both
confirmations.** The probe enumerated every non-reserved entry including files
and dotfiles; the act's name guard then refused on the first one that was not a
project name. A `README.md`, a `notes.txt`, an `Old-Site`, a `.DS_Store` — each
an unrecoverable block on de-branding, on a tree `server status` and
`server prune` both walk happily. The fix is in the **probe**: such an entry is
reported as left alone and never presented as a project. The act guard stays
exactly as it is — it must keep trusting nothing this side assembled; it should
simply stop being reachable in the ordinary case. `drop`'s equivalent guard can
never fire because its name came from a validated manifest; this one fired on a
tree walk, which is the difference nobody had noticed.

**The seventh vacuous assertion of the phase, and this one was demonstrated
rather than argued.** `! ls "$dir/" | grep -q kasbah-destroy` — the temp file is
`.env.kasbah-destroy.$$`, a **dotfile**, which plain `ls` never lists. The
reviewer mutated the code to leave the temp file behind and the suite still
exited 0. The same line was also the change's only `producer | grep -q` under
pipefail, the shape CLAUDE.md bans for the SIGPIPE race: one line, both defects,
and the banned shape is what made the assertion vacuous.

**A witness whose floor did not bound its coverage.** The continuity test
asserted at least 20 samples and that none was non-200 — but nothing tied the
sample window to the destroy window, and "no sample is non-200" is trivially
true of an empty file. Measured: mean inter-sample gap **6.9 ms**, so 20 samples
is **~0.14 s** against a ~13 s operation — a sampler that died half a second in
passes both assertions and prints a green "the site never went down". *The
property itself is real*: the reviewer's own instrumented run got 68/68 in-window
samples at 200, and confirmed `200` discriminates as claimed — Traefik down
gives `000`, a stopped project container `502`, a missing fragment `404`. The
bookkeeping was the weak part, not the claim.

All four of the implementer's pushbacks against the brief were upheld. Two are
worth keeping: **`scripts/` is removed as its two named helpers plus an `rmdir`**
rather than `rm -rf`, so an operator's own file there survives and the last
`rm -rf` built from a project-name-derived path leaves the command entirely; and
**exit 4 and "a clean second run" are in genuine tension for this one command**,
since a completed destroy removes its own marker by design — resolved toward the
clean second run, with exit 4 kept for the different case where the marker names
an apps path that is not there.

Two defects the implementer's own hand-driven pass found before review, which is
now every task in this phase: `local IFS=', '` with `${parts[*]}` joins on the
**first character only**, so the plan printed `versions.log,scripts/ (…)` with no
spaces; and after `compose down` had taken the container, the report said "there
was no kasbah-backup container" — true, and reading as though the plan that had
just said "running" had lied.

**Baselines after this task: 28 unit suites, 46 rig-inclusive** — counted, not
inferred; the implementer's report quoted 26/42 from a stale base.

The fix round closed all seven and cost one round. Three of the eleven new
mutations **survived their first run**, each exposing a gap the fix had not
closed: nothing asserted the per-project `FAILED:` wording, nothing exercised
the plan under `sudo_state=no`, and `_sd_nothing_to_find` had **no unit coverage
at all**. All thirteen original mutations were re-run against the revised code
and stayed red, so nothing was hollowed out by the changes.

Two decisions in the fix worth keeping. The failing-mail-`.env` case is the
**last** case in the integration suite, on a re-prepared server, because the act
takes the backup stack and the project artifacts *before* it reaches the mail
file — run earlier it would strip the server of everything the main destroy has
to be seen removing, and every "is gone" assertion above it would then pass for
the wrong reason. **A test's position in a suite can make its neighbours
vacuous.** And the no-sudo case stays hand-driven and out of the suite on
purpose: proving it means moving `/etc/sudoers.d/stevedore` aside, and restoring
it needs the privilege the test just removed — a suite that can wedge the rig's
sudo would wedge it for the other seventeen.

**A number that measures two different things.** The implementer's 26/42 came
from adding its two new suites to the phase file's "25 PASS / 40 PASS"
baselines. Those baselines are `PASS` **counts**, and a suite that skips on
preconditions lands in `unrunnable`, not `PASS` — so "baseline plus mine" is the
wrong sum whenever anything skips. The file count is 28 and 46, and it predicts
the PASS line only on a run where nothing skips. Phase 7's numbers happened to
match their file counts exactly, which is what made the wrong arithmetic look
right.
