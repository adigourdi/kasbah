# Build Plan — kasbah

Phased plan for taking kasbah from "local half done" (scaffold, manifest,
check) to both real consumers migrated (the original PHP project, the homelab). Produced by
`/phase-out` from `docs/*.md`; executed by `/tackle`. Each phase file is
self-contained: deliverables verbatim, spec links inline, findings filled
during execution.

## Phases

| # | Phase | State of the thing at the end |
|---|---|---|
| 0 | [Ground](00-ground.md) | **Done.** Scaffold, install, manifest/state, init-project, full `check`, docs corpus with all decisions |
| 1 | [Rig](01-rig.md) | **Done.** A fake VPS (DinD container: sshd + dockerd) with reset script and integration-test runner |
| 2 | [Spine](02-spine.md) | **Done.** `server init`, the shared Traefik stack, thin `deploy` and minimal `server status`; a stock project serves through Traefik via a file-provider fragment |
| 3 | [Env](03-env.md) | **Done.** Env template system ported verbatim with its tests; one shared drift function used by `check` and by the VPS; `KASBAH_*` injected into a managed block |
| 4 | [Ship](04-ship.md) | **Done.** `build-push` + full `deploy` (hooks, backup, health, flock, digests): a custom-built app ships to the rig |
| 5 | [Undo](05-undo.md) | **Done.** `rollback` + `deploy X.Y.Z` from a git tag, `versions.log` rotation, and `history` / `pending` / `changelog` |
| 6 | [Proof](06-proof.md) | **Done.** A real project on a bare VPS: HTTPS with a real ACME cert, change deploy, rollback — kasbah only |
| 7 | [Operate](07-operate.md) | **Done.** Mail stack (`--with-mail`, `add-mail-domain`, claim reconciliation, setup guide), `logs`/`exec`, `check --server` + R04, full `server status`, `server prune`, `upgrade-traefik` |
| 8 | [Keep](08-keep.md) | **Done.** `drop [--prune]`, `server destroy`, `--with-backup` (restic push, append-only, proved), `check --fix`, and backups visible to `server status` / `check --server` |
| 9 | [Adopt](09-adopt.md) | Both existing consumers migrated: the original project (scripts/ deleted, mail included, live cutover) and lab (RPi stacks as kasbah projects) |

## The real milestone

**Phase 6 — Proof.** A greenfield deployment: a real project kasbah was
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
   (`overview.md` → Interactivity). Every prompt has a flag for scripted use:
   a `--with-x`/`--no-x` pair for a feature, a differently-spelled pair where
   that reads better (`--reset-acme`/`--keep-acme`), or a bare `--yes` where
   the prompt guards a destructive act and declining just aborts. Without a
   TTY an unanswered prompt is a hard fail naming its own flags. This is also
   what lets the rig tests drive everything headless. **One deliberate
   exception, added in Phase 6:** `--acme-staging` does not prompt, because
   production is both the default and the status quo.
2. **Frozen contracts — never rename:** `kasbah-net`, entrypoints
   `web`/`websecure`, certresolver `letsencrypt`, `_shared.yml` middleware
   names, versions.log's four positional fields, the `KASBAH_` env prefix.
3. **yq is the kislyuk wrapper (jq dialect).** Do not write mikefarah v4
   syntax — it will parse differently or not at all.
4. **Bash discipline:** `set -euo pipefail` everywhere; mind SIGPIPE with
   `grep -q` under pipefail (capture first, then grep — see check.sh
   comments); helpers sourced with load guards.
5. **Tests land with the code, same phase.** Unit suite: `./test.sh`
   (fast, no rig). Integration suite: requires the rig, opt-in via
   `KASBAH_RIG_TESTS=1 ./test.sh` (wired in Phase 1).
6. **Docs are the spec.** When reality disagrees, fix the doc in the same
   phase — reconciliation is part of every phase's exit bar.
7. **Compose conventions:** files named `compose.yml` (not
   docker-compose.yml), no `version:` attribute.
8. **VPS-side helpers are kasbah-owned** and overwritten on every deploy;
   projects never vendor kasbah bash.

## Before starting Phase 9

Phase 8 is committed and all four exit criteria were walked — two of them **against the
real host**, not the rig. Baselines: `KASBAH_RIG_TESTS=1 ./test.sh` **47 PASS, 0 FAIL, 0
SKIP, exit 0** (28 unit, 19 integration; Phase 7 closed at 25 and 39). `tests/check_test.sh`
alone was ~13 minutes and dominated the unit half; the post-close follow-up in
`08-keep.md` took it to ~4, so a run that looks like the old numbers is now a
regression rather than the norm.

**The real host is no longer a kasbah server.** `you@vps` was de-branded by
`server destroy` at the close, deliberately and with the price agreed: its marker,
`/etc/kasbah`, `gallery-website`'s deploy record and `/apps/mail/kasbah.yml` are gone for
good. Every container is still running and `gallery.example.com` still serves. Phase 9
must **re-run `kasbah server init` there** before it can use it, and the mail registry's
`primary_domain` and domain list have to be re-entered by hand — nothing else reproduces
them.

Four things Phase 8 leaves for whoever opens this next.

**Five commands ask "does this stack serve domain X" and only two share a reader.**
`drop --prune` and `add-mail-domain` call `_sm_read_registry`; `deploy`, `check --server`
and `server status` each carry their own copy of the same normalisation. On a registry
kasbah wrote they agree. On a **hand-edited** one with no `primary_domain` they do not —
the shared reader refuses where the three copies fall back to an empty primary and carry
on. **Phase 9's live cutovers make a hand-edited registry the ordinary case**, so this is
the phase that has to converge them, and `docs/cli.md` now states the divergence plainly
rather than claiming it is already solved.

**A claim that there is one reader is what stops anyone looking.** This happened twice in
Phase 8 — once in a comment, once in the spec — and both times the assertion was written
in good faith by someone who had just done the work. When a document says two things
cannot disagree, check that they share an implementation and not merely a rule; and when
they share only a rule, say so and pin them against each other with a test.

**`check --fix` will edit a project's compose file, and `client:` is now S08.** A project
whose manifest carries a `client:` outside `^[a-z][a-z0-9-]*$` fails `kasbah check`
rather than dying at the deploy — but a **tag's** manifest carrying one only warns, and
the rollback falls back to the directory name, so a version a server has already run
stays rollable after the rule tightened. Both consumers migrate in Phase 9; check theirs
before the first cutover.

**Backups are proven against `rest:` and traced against `s3:`.** The append-only
credential is refused a delete by a server that really enforces it, and init proves the
operator's credential the same way on any backend — but the bucket-policy JSON a real
provider needs has never been exercised. The first `--with-backup` against real storage
is a real test, not a formality.

## Before starting Phase 7

Phase 6 is committed and all four exit criteria were walked against **real
infrastructure**, not the rig. Baselines: `./test.sh` **20 PASS in ~7m10s**;
`KASBAH_RIG_TESTS=1 ./test.sh` **29 PASS in 16m27s**, exit 0, no skips. Phase 7
now has **two** carried sections — one from Phase 2, one from Phase 6 — and the
Phase 6 one holds live decisions, not notes.

Five things Phase 6 leaves for whoever opens this next.

**The milestone landed on the first attempt, and that is the least interesting
thing about it.** Bare Ubuntu host to a healthy, publicly-trusted HTTPS
deployment in 20.4 s of `server init` plus 10 s of ACME; deploy 11.4 s,
rollback 11.3 s. The uplink costs ~2.3× loopback on `build-push` and ~1.5× on
`deploy`, which says the wall clock is **SSH round trips and container
lifecycle, not bytes** — a much larger image would change that conclusion, and
nothing here has measured one.

**`notBefore` is not issuance time.** Let's Encrypt backdates it ~58.5 min
(measured twice, 58m32s and 58m31s, on clocks agreeing to 2 s). Phase 7's
`check --server` is chartered to report cert status from `acme.json`; the
obvious implementation is an hour wrong in the direction that calls a fresh
certificate stale.

**Three review rounds and a real-VPS run all missed the same defect**, and the
reason generalises: every one of them exercised flags that were *doing*
something. `--keep-acme --yes` destroyed a certificate store while the operator
said keep, because the choice variable was read on one code path out of three.
When a flag can be passed to a run that never consults it, test *that* run.

**The tool assumes every project has an environment**, and it surfaced three
ways on the first non-fixture project (S04 hard-fails without a template,
`init-project` scaffolds a `DOMAIN` key nothing reads, the starter compose
snippet teaches the two-service case as universal). Carried to Phase 7 **as one
decision** — answering the three separately produces three inconsistent
answers.

**A hand-set `caServer` is a trap-door**: no flag reproduces it and `--keep-acme`
does not save the store, so every future `server init` demands `--yes` and a
reset. That establishes "kasbah always overwrites `caServer`", which task 7.5's
promised "user-customized `traefik.yml` gets a diff + confirm, not a silent
replace" has to reconcile deliberately rather than by accident.

And one about running the work rather than the code: **`./test.sh` is only
evidence when nothing else is writing.** A verdict run started while an
implementer was live in the same files came back 19 PASS / 1 FAIL — the
failures were that agent's own new tests, ahead of the code satisfying them.

## Before starting Phase 6 ✅

Phase 5 is committed and its four exit criteria were walked by hand against the
rig at the close, driving `kasbah` as an operator. Baselines: `./test.sh`
**20 PASS in ~6m30s**; `KASBAH_RIG_TESTS=1 ./test.sh` **29 PASS in ~16m**, exit
0, no skips. **These are the numbers Phase 6 should regress against.**

Two of those 29 failed once for reasons that were not the code, and the shapes
are worth recognising: `integration/ship_test.sh` asserts a freshly loaded image
carries exactly one tag, and a hand-walk had left version tags on the rig —
`rig_clean` removes projects and networks but deliberately **leaves images
alone**. And `integration/smoke_test.sh` died on a 502 from
`registry-1.docker.io`. Both were green on re-run. Phase 4's Findings already
warn that a poisoned rig presents as *unrelated* suites failing: diagnose before
fixing.

Phase 5 has a
`## Findings` section that is unusually worth reading before Phase 6 —
the real-VPS milestone is where several of its accepted limits get their first
real test.

Four things Phase 5 leaves for whoever opens this code next.

**One predicate decides whether a `versions.log` line is an entry**, and three
readers apply it: `vlog_parse_line` on the workstation, `rd_prev_version` on the
VPS, and `kasbah server status` through the first. Four non-empty positional
fields and a first field beginning `YYYY-MM-DDT`. They disagreeing is a run that
warns a line has no readable version and then names the version the other reader
took out of it — which happened, and is fixed. Rotation's `_rd_month_index` is
the deliberate exception and asks only which month a line falls in; tightening it
stops rotation entirely (measured: 67 failures).

**The archive is never fatal on the workstation; the active log always is.**
Every way `versions.log.gz` can fail to arrive — not gzip, truncated member, not
base64, unreadable, no local `gzip` — is a warning naming which, and
`VLOG_ARCHIVE_STATE` / `VLOG_ARCHIVE_DAMAGED` / `VLOG_ARCHIVE_REASON` carry it to
the readers. Any command concluding something from the *absence* of a record must
consult them first; `rollback` shipped once without doing so and told an operator
a version had never been deployed on evidence it did not have.

**A safety mechanism with no consumer is indistinguishable from no safety
mechanism.** This phase produced that defect twice from the same library — once
caught by unit review, once only by the whole-phase pass. When a unit adds a fact
so that another unit can act on it, grep for the reader before believing it is
done.

**`kasbah deploy X.Y.Z` exists now and shares `rollback`'s engine.** The two
differ in the log action, the hook pair, and whether the deploy record is a
precondition. It has no rig case — the risk is the wiring, not the path.

## Before starting Phase 5 ✅

Phase 4 is committed and its four exit criteria were walked by hand against the
rig at the close. Baselines: `./test.sh` **16 PASS in ~5m15s**;
`KASBAH_RIG_TESTS=1 ./test.sh` **23 PASS in ~10m40s**. Phase 5 has a
`## Carried in from Phase 4` section; read it first.

Three things Phase 4 leaves for whoever opens this code next.

**`templates/remote-deploy.sh` is rendered, not copied.** The manifest is never
synced to a server, so `lib/remote_deploy.sh` pre-renders hooks, backup, health
and the built-image list into a marked block inside the script. The VPS needs no
`yq`, `jq` or `python3` and must keep needing none. Anything Phase 5 adds that
wants manifest data renders it the same way.

**Its stdout is a protocol, not output.** Everything the script says goes to
stderr; stdout carries a five-key `key=value` report printed *after* the
`versions.log` append, so it doubles as the run's completion marker — no report
means the local side refuses **before shipping the Traefik fragment**, leaving
no route and no state. Two `>&2` redirects keep project-authored hook and
`backup.check` output off that channel. `rollback` mode inherits all of it.

**Four implementations of one path-normalising rule** exist deliberately —
`lib/common.sh` plus a copy in each of three remote payloads, which cannot
source it. `tests/norm_path_test.sh` asserts the three copies are byte-identical
and drives one case table through both spellings. Adding a fourth remote reader
means adding a fourth copy *and* a line to that test.

## Before starting Phase 4 ✅

Phase 3 is committed and its exit criteria were walked by hand at close.
Baselines: `./test.sh` 13 PASS; `KASBAH_RIG_TESTS=1 ./test.sh` **17 PASS in
~5m50s**. Phase 4 has a `## Carried in from Phase 2` section; read it first.

Two things Phase 3 leaves on the table for whoever opens this code next.
**`lib/env.sh` is shipped to the VPS verbatim** — it is sourced by
`kasbah check` here and executed there as `scripts/setup-env.sh`, so nothing
in it may reach for `common.sh`, `jq`, `awk` or `bc`, and `set -euo pipefail`
at its top is a contract rather than a habit: the two menu reads are the only
ones without `|| true`, so "EOF at the menu aborts" *is* errexit. Never put
`env_setup_run` on the left of `||` or `&&`. And **`kasbah deploy` now has a
step that can prompt** — 4.3 assembles the full flow around it, so keep the env
step after the project rsync and before the remote deploy, and keep the Traefik
fragment last.

## Before starting Phase 3 ✅

Phase 2 is committed and its exit criteria were walked by hand against the
rig at close. Unit-suite baseline: `./test.sh` 10 PASS in ~1m50s; with the
rig, `KASBAH_RIG_TESTS=1 ./test.sh` 14 PASS in ~4m20s. **Run both under a
real terminal as well as piped** — the integration suites hung forever
under a pty for three units before anyone noticed, because a `timeout`
child reading the controlling terminal takes SIGTTIN and a stopped process
never receives the SIGTERM that follows.

Phase 3 has a `## Carried in from Phase 2` section; read it first. Phase 4
has one too.

## Before starting Phase 1 ✅

Phase 0's final act is committed (`7ea63e1`, `7c5f7d1`, `f8fe1cf`), so
task baselines are clean. Unit-suite baseline at the start of Phase 1:
`./test.sh` PASS ×3 in 1m52s.

## Re-read notes

Phases 1–4 are specified tightly. **7–9 are deliberately lighter and need
a re-read before starting.** The first reorder trigger has now fired: Phase 6
met real infrastructure and its findings are in `06-proof.md` plus the carried
section in `07-operate.md` — ACME behaved better than feared (one attempt, no
rate-limit trouble, staging rehearsal worth keeping), DNS and open ports turned
out to be unprobed preconditions, and the TTY quirk was that there is no quirk:
the interactive env step runs fine under a pty, and headless deploys are a
non-goal by design. The remaining trigger is Phase 9's
two live cutovers (label→fragment Traefik swap with `acme.json` reuse)
and its open question — cert strategy on a LAN host where HTTP-01 can't
reach (DNS-01 vs internal CA), recorded in `09-adopt.md`.
