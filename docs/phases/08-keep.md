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
| 5 | 8.4 | Purely local — no rig, no SSH. The only unit nothing can block, so it makes the safest tail |

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
