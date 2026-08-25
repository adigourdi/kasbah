# Phase 7 — Operate

> Day-2 operations exist: the mail stack is kasbah-managed, the VPS can
> be inspected and upgraded remotely, and images get pruned on policy.

**Prerequisite:** Phase 6. **Lighter spec — re-read against Phase 6
Findings before starting; task order here is a guess made pre-Proof.**
**Spec:** `docs/mail.md`, `docs/cli.md` (logs, exec, server prune, upgrade-traefik), `docs/compliance.md` (`--server`, R04), `docs/build-deploy.md` (retention)

## Exit criteria
- [ ] The `--with-mail` path works end to end on the rig (container wiring, domain claims, SnappyMail seeding) — live mail migration itself is Phase 9.3
- [ ] `check --server` runs the full VPS-aware rule set incl. R04 against production without side effects
- [ ] `server prune` on the rig removes exactly the tags outside (3 months ∪ last 3 deployed incl. current)
- [ ] `upgrade-traefik` validates every existing fragment against the target version before switching

## Run order

Execution order, approved 2026-08-25. Task blocks below are in this order;
the **ids never move** — 7.0 and 7.6 are insertions at gap numbers, and every
reference elsewhere to 7.1–7.5 stays valid.

| # | Unit | Why here |
|---|---|---|
| 1 | 7.0 | Closes three Phase 6 carries before anything extends `check`, and reserves `mail` as a project name **before** 7.1 creates `/apps/mail/` |
| 2 | 7.2 | Small, independent, nothing depends on it |
| 3 | 7.1a, 7.1b | Biggest unknown early; the DMS image pull is a one-time rig cost (both images are already in the rig's cache: DMS 1.22 GB, SnappyMail 293 MB). Ahead of its dependants so M03, `status`'s mail line and 7.5's dry-run over `_mail.yml` are native rather than retrofits |
| 4 | 7.3 | Builds the `acme.json` cert reader 7.6 consumes, and `M03` against 7.1's registry |
| 5 | 7.6 | The phase index and the Phase 2 carry both say Phase 7 owns full `status`; the plan had no task for it |
| 6 | 7.4 | Reuses the per-project `versions.log` read `status` already does |
| 7 | 7.5 | Last on purpose: its dry-run must validate every existing fragment, and `_mail.yml` exists only after 7.1 |

Sequential, no parallelism — every rig task owns `/apps` and Traefik, which is
what made Phase 6 serialise 6.0 and 6.1.

## Verification regime — amended 2026-08-25, mid-run

The first three tasks spent **~226 min of wall clock on full suite runs** — 16
full unit runs at ~7 min and 6 full rig runs at ~19 min — against ~8.6 h of
agent time. The operator asked for the completion time down. Measured first,
because one obvious suspect was innocent: **the real host is not a cost**. It
was touched four times in three tasks, all brief. Moving VPS work to the phase
close would have saved nothing.

What changes for 7.1b onward:

1. **Per task, the affected suites only** — `bash tests/<x>_test.sh`, seconds
   rather than seven minutes. The unit suites are cleanly separated by library,
   so "affected" is legible rather than a guess.
2. **Per task, the task's own integration suite only**, not all eleven.
3. **The full `./test.sh` and the full `KASBAH_RIG_TESTS=1 ./test.sh` run once,
   at the phase close.** They become the gate rather than a per-round ritual.
4. **No routine confirmation review round.** The orchestrator verifies fixes
   directly and re-reviews only when the fix was *structural* — a new
   out-parameter, a protocol field, an ordering change. This is the single
   biggest lever: roughly 35 min per task.
5. **Agent briefs carry a tool-use budget** and forbid re-deriving what the
   brief already states or running a full suite.

**What this gives up, stated plainly:** a regression that crosses suite
boundaries can now land and stay hidden until the phase close, where it arrives
mixed with four other tasks' changes. The close is the gate that catches it, and
`git bisect` over five commits is cheap. The per-task bars in each task block
below are otherwise unchanged — the operator pass against the rig stays, because
that is what catches what suites do not.

**Baselines to regress against:** `./test.sh` **20 PASS, exit 0, 6m55s**
(measured 2026-08-25, matching Phase 6's ~7m10s); `KASBAH_RIG_TESTS=1 ./test.sh`
**29 PASS, 16m27s**, no skips.

**The real host.** `you@vps` is Phase 6's OVH
VPS and is **not** a throwaway: it serves `gallery-website` with production
certificates. The operator has since declared the whole kasbah install there a **test**
deployment, so every Phase 7 command may run against it, `upgrade-traefik`
included — `gallery-website` going down during an upgrade is an acceptable
cost there, and is itself the observation. The original project's **production** hosts
are off-limits entirely, as are its containers running on the
workstation and `~/work/gallery-website`.

DNS as measured 2026-08-25: `example.com`, `traefik.example.com` and
`mail.example.com` all resolve to the host; `MX 1 mail.example.com` and
`v=spf1 a mx ip4:<host> -all` are already published; `webmail.example.com`
was added as a CNAME to the apex during this run and resolves to the same
address (HTTP-01 follows it, so ACME validates). `_dmarc` and the DKIM selector
are absent — deliverability only, and 9.3's to settle. Ports
25/465/587/993 are free on the host. A router carrying a `certResolver` for a
hostname that does not resolve burns ACME budget at Traefik config load with
nobody visiting (Phase 6 → Findings), so the webmail A record is a
precondition of 7.1's VPS pass, not of its rig pass.

## Tasks

### 7.0 — Local `check` completion and the environment assumption (M) *(inserted)*

Three Phase 6 carries, answered together because they are one surface, plus
the reserved-name gap 7.1 would otherwise open.

- **T08** *(new, warn)* — no router on the `web` entrypoint for the manifest
  domain. Phase 6 fixed `init-project`'s scaffold to print the redirect router
  but left the rule that would catch a hand-written fragment missing; T03 only
  requires *some* entrypoint.
- **C09** *(new, warn)* — a service attached to `kasbah-net` whose name is
  neither `<manifest.name>` nor `<manifest.name>-*`. Compose registers the
  service name as a DNS alias on every attached network, so two projects both
  naming a service `web` put two claimants on one alias and a third project
  resolving bare `web` round-robins between them (measured Phase 6:
  `aliases=[gbrev-web web]`).
- **S07** gains **`mail`**. `/apps/mail/` becomes kasbah-owned in 7.1, and a
  project named `mail` would rsync over the mail stack and then run
  `docker compose -p mail up -d --remove-orphans` in it — the same live hazard
  the existing three names guard against.
- **The environment assumption**, answered as one decision: the template file
  stays mandatory and *empty is first-class*. S04 keeps failing on a missing
  `.env.prod.example` — it is a tested contract
  (`tests/integration/deploy_ship_test.sh:192`). `init-project` stops
  scaffolding `DOMAIN=<domain>` (nothing reads it; the manifest's `domain:` and
  the fragment are where the hostname is load-bearing) and emits a comment-only
  template instead. Its starter compose snippet stops printing
  `networks: [kasbah-net, internal]` for the single service it scaffolds.
- `tests/fixtures/built-app` renames its routed service to the prefixed form so
  the fixture teaches what C09 asks for.

**Verify on:** `./test.sh`; then by hand, `bin/kasbah check` in
`tests/fixtures/built-app` and in a scratch `init-project` tree, which must come
out clean under the new rules.

**Delivered.** All five, approved at round 2. `./test.sh` 20 PASS, exit 0.
Hand-run: `built-app` `30 passed, 1 warning, 0 failed` (the warning is
pre-existing H01 — its healthchecks live in its Dockerfiles, which
`compliance.md` says warns forever, correctly); `demo` `25 passed, 0 warning,
0 failed`; a fresh `init-project` tree with **both printed snippets
materialised** `25 passed, 0 warning, 0 failed` — zero warnings from a fresh
scaffold, which is the bar this task set itself. T08 and C09 both carry
mutation evidence (substring→exact match on T08: 2 FAILs; each of C09's two
silence gates: 1 FAIL; `mail` out of `KASBAH_RESERVED_NAMES`: FAILs in four
separate suites, which is what proves no enforcement site kept a literal list).
`docs/cli.md`'s "the scaffolded shapes pass `check` clean" is now a test rather
than a claim, guarded so that an extraction yielding an empty file fails loudly
instead of passing on nothing.

### 7.2 — `logs` / `exec` (S)
Thin wrappers per `cli.md`, including the `--` argument rule for exec.

**Verify on:** rig — deploy the `built-app` fixture, then `logs`, `logs -f`,
`logs --tail=N`, `exec <svc> -- sh -c …`, and the missing-`--` refusal, driven
as an operator. `./test.sh`.

**Delivered.** Approved at round 3. `lib/ops.sh` carries both commands and the
one shared positional rule (an argument containing `@` is the server, not the
service) — mutating that rule's arm costs **45 FAILs spanning the first `logs`
assertion to the last `exec` one**, which is what proves neither command kept a
private copy. `./test.sh` **21 PASS**, `KASBAH_RIG_TESTS=1 ./test.sh` **31
PASS**, both exit 0, no skips. Hand-driven on the rig against a deployed
`built-app`: `logs`, `logs <service>`, `logs --tail=5`, `logs -f`,
`exec … -- sh -c 'echo hi'`, a command carrying quotes, a glob and a
redirection (`a b hostname hosts`), `exit 7` propagating as 7, and every
refusal — missing `--`, no `--` at all, not a kasbah project (exit 2),
unreachable host (exit 3), unknown service.

**The two decisions the task turned on.** `logs` never allocates a pty, `-f`
included: `ssh -t` cooks output through a line discipline, putting a CR before
every LF in data that exists to be piped and redirected, and following a log
needs an interrupt rather than a keystroke. `exec` allocates one iff
`[ -t 0 ] && [ -t 1 ]` — the pair `lib/env_cmd.sh` already checks — because
stdin alone is not enough: `kasbah exec db -- pg_dump … > dump.sql` from a
terminal would put CRs in the file. Neither branch refuses, since unlike the
`.env` generator there is no prompt to strand. `exec` propagates its command's
status and writes `last_server` whenever that command *ran*; `logs` does not
propagate compose's status, because the whole command line there is kasbah's
own.

*Not proven here, and honestly so:* an interactive `exec` into a real shell got
as far as a pty existing at both ends (`TTY` under `script -qec`, `-t` on the
ssh line, `-T` dropped) — a human at a keyboard is the part no suite drives.
`logs -f` interrupted by a real Ctrl-C was simulated with a signal to the
process group; the mechanism is the same but the keystroke path is untested.

### 7.1 — Mail stack port (L)
`server init --with-mail` / `add-mail-domain` / `_mail.yml` cert-trigger
fragment, ported from the original project's `mail/`. Deploy-time claim
reconciliation replaces the Phase 4 stub. SnappyMail domain pre-seed
copy-if-missing. Live mail migration (the original project's) is deliberately NOT
here — it happens with its owner's migration in Phase 9.3.

Also in scope, named because the task text did not: `kasbah server
mail-setup-guide USER@HOST` (roadmap v0.2, `mail.md` → the walkthrough shown
once after init), and the **local** mail rules `M01`/`M02` from
`compliance.md`. **`M03` does not land here** — it is a `--server` rule and
`check --server` does not exist until 7.3. Because 7.1 runs first, 7.3 builds
it against a registry that already exists, which is the whole reason for the
order.

**Split into 7.1a and 7.1b** (same concept, letter suffixes; the id `7.1` stays
valid as their parent). The task is L and its two halves have a clean seam:
**7.1a is the stack** — `server init --with-mail`, the templates, `_mail.yml`,
the seeding, and a running pair of containers on the rig. **7.1b is everything
that talks to it** — `add-mail-domain`, `mail-setup-guide`, the deploy-time
claim reconciliation that replaces the Phase 4 stub, and `M01`/`M02`. A single
brief covering both produces a review with traction on neither.

**The constraint that shapes 7.1a's verification, and it is not negotiable.**
`SSL_TYPE: letsencrypt` makes a certificate a **boot requirement** for DMS, not
a nicety: the original project's own setup guide records the mailserver crashlooping for
30–90 s on a first deploy while Traefik completes the HTTP-01 challenge, then
coming up once the cert is in `acme.json`. **The rig cannot issue a
certificate** — no public DNS, the challenge never validates — so on the rig DMS
crashloops *forever* and there is no settling to wait for. The rig therefore
proves the fragment, the routers Traefik registers, SnappyMail up and seeded,
and idempotence; **DMS reaching healthy is provable only on the real host**,
where `mail.example.com` and `webmail.example.com` both resolve. Anyone who
briefs "wait for DMS healthy on the rig" has set an impossible task.

**Watch out for:** SMTP won't route from the rig, but container wiring,
claim checks, and seeding all can — test those with a throwaway domain
and mark deliverability "traced, not proven" until 9.3. The original project's stack
expresses every route as a **Traefik label**; kasbah's docker provider is not
wired in, so all of it moves into the file-provider `_mail.yml` — that is the
substance of the port, not a translation detail. The prerequisites table in
`server-setup.md` names `:80`/`:443` and not the mail ports.

**Verify on:** rig — `server init --with-mail` on a clean rig, DMS and
SnappyMail up, `_mail.yml` carrying the cert-trigger and webmail routers,
Traefik registering both, `add-mail-domain` appending and reconciling,
SnappyMail JSON seeded copy-if-missing, `mail-setup-guide` printing, a
`mail:`-claiming project deploying green and an unknown-domain one failing M03.
Then, after that pass is reviewed: the real host, for the cert-trigger
resolving a genuine Let's Encrypt certificate and DMS booting off it.
`./test.sh` plus the new rig suite.

### 7.3 — `check --server` + R04 (M)
The VPS-aware checks from `compliance.md`: project dir, env drift, mail
domain, health, cert status from `acme.json`, and R04 (effective limits
vs host 90%: above fails, below warns).

**Watch out for:** reading `acme.json` needs the deploy user's perms and
must never write; parse defensively — its schema shifts between Traefik
versions. **`notBefore` is not issuance time**: Let's Encrypt backdates it
~58.5 min, measured twice in Phase 6, so a cert-age rule reading it as issuance
calls a fresh certificate an hour old. The rig cannot fill `acme.json` at all
(no public DNS, HTTP-01 never validates), so the parser's evidence is
hand-built fixtures plus the real host.

**Verify on:** rig — `check --server` against a deployed fixture; R04 above, at
and below 90% of the rig's real host size. Cert status on hand-built
`acme.json` fixtures including a schema-shifted one and a permission-denied one,
**plus one run against `you@vps`'s real store**. `./test.sh`.

### 7.6 — Full `server status` (M) *(inserted)*

The plan named no task for this, while the phase index lists "full `server
status`" as Phase 7's end state and `## Carried in from Phase 2` says Phase 7
owns the rest. Adds to the minimal `lib/server_status.sh`: the per-project
domain, cert status and expiry (reusing 7.3's reader), disk usage on the apps
and data paths, the mail stack's state, and per-container health beyond
Traefik's.

**Watch out for:** keep the single batched round trip `server_init` and `status`
both use — it is what keeps the rig's `maxstartups 10` from biting. The domain
comes from each fragment fetched base64 and parsed with the *workstation's* yq;
yq stays off the VPS.

**Verify on:** rig, driven by hand, plus one run against `you@vps`.
`./test.sh`.

### 7.4 — `server prune` (M)
The retention policy, exactly as `build-deploy.md` states it: remove
`:<version>` tags older than 3 months AND not among the last 3 deployed
(the `:current` target counts as first). Show the removal list, ask once
(tri-state: `--yes` for scripts).

**Watch out for:** "last 3 deployed" comes from `versions.log` per
project, not from tag mtimes — a re-tagged image lies about its age. A project
whose `versions.log` is unreadable, or whose archive reports
`VLOG_ARCHIVE_DAMAGED`, is **skipped whole with a warning**: Phase 5's finding
is that a command concluding something from the absence of a record must
consult the archive state first, and this one concludes deletion.

**Verify on:** rig — at least five version tags across two projects with
doctored log entries and image dates; assert the exact removal set, and that
the unreadable-log project is skipped untouched. Then `you@vps`, where every
tag is inside the window so the correct answer is "remove nothing".
`./test.sh`.

### 7.5 — `upgrade-traefik` (M)
Version bump with backup-before-overwrite of kasbah-owned files, plus
the dry-run: boot a throwaway Traefik of the target version with the
dynamic dir mounted read-only and fail the upgrade on config errors in
its log.

**Watch out for:** the plan's original watch-out here said a user-customized
`traefik.yml` gets a diff + confirm, citing `traefik.md` § Ownership — which
says the opposite. **Settled: the doc's model holds.** `compose.yml`,
`traefik.yml` and `_shared.yml` are kasbah's outright; `upgrade-traefik` backs
them up before overwriting and never asks. That keeps one ownership story
across `init` and `upgrade`, and keeps Phase 6's `caServer` reasoning intact —
kasbah always overwrites that line, which is why a hand-set third-party CA is a
trap-door.

**Verify on:** rig — upgrade to a genuinely different Traefik tag with
`_mail.yml` and project fragments present, Traefik back and serving; then a
deliberately broken fragment must fail the dry-run and leave the version
unchanged. Then the real host: the install there is a test deployment, so the
upgrade runs against a Traefik holding **real Let's Encrypt certificates** and
serving a real project — the one thing the rig cannot stage. `./test.sh`.

## Open decisions — settled 2026-08-25

Answers given before the run started; not up for relitigation inside a task.

- **Scope.** The whole phase, ending in a dedicated close commit.
- **The real host.** Not read-only. Mail, `prune` and `server init` are
  authorised on `you@vps`, and so is `upgrade-traefik` — the operator declared
  that install test-only mid-run. See *Run order* above for the full boundary and
  the DNS state.
- **`traefik.yml` ownership** (7.5) — kasbah owns it outright; back up, never
  ask. Recorded in 7.5.
- **The environment assumption** (Phase 6 carry) — mandatory file, empty is
  first-class. Recorded in 7.0.
- **The alias rule** (Phase 6 carry) — warn on any un-prefixed service name on
  `kasbah-net`, not on a fixed list of five. Recorded in 7.0 as C09.
- **The mail domain registry** — **both files, split by owner.**
  `/apps/mail/kasbah.yml` is the registry (`primary_domain` plus `domains:`) and
  is the only thing anything asks "does this stack serve X?". `/apps/mail/.env`
  carries what compose and DMS interpolate (`MAIL_HOSTNAME`, `DOMAIN`,
  `DATA_PATH`) plus the operator-owned relay block `mail.md` describes. `.env`'s
  kasbah-owned values are **derived** from the registry and rewritten by every
  mail command, so there is one writer per fact and no drift by construction.
  Read on the workstation by base64-ing the file back and parsing with the local
  yq — the VPS keeps needing no yq. `docs/mail.md` § Multi-domain and
  § Per-app mail claims are reconciled to this in 7.1, and `lib/deploy.sh`'s
  stub is rewritten against it.
- **`server status`'s per-project domain** (Phase 2 carry) — fetch each
  fragment base64 in the existing round trip, parse with the workstation's yq.
  No credentials, no new server-side dependency. Recorded in 7.6.
- **`server prune` on incomplete evidence** — skip the project whole and warn.
  Recorded in 7.4.
- **Reserved name `mail`** — added to S07. Recorded in 7.0.

## Carried in from Phase 6

*(The dashboard-redirect question that opened this section was settled and
implemented at the Phase 6 close — see `06-proof.md` → Findings.)*

All three carries below are **answered** above and scheduled into 7.0; the
evidence is kept here because that is where the next reader looks. Two of them
reached this file only at the Phase 7 planning pass — they had been recorded in
`06-proof.md` → Findings and never copied across, which is the failure mode the
carry discipline exists to prevent.

**Should `check` warn on a generic service name on `kasbah-net`?** Compose
registers the service name as a DNS alias on *every* attached network, which is
the stated reason projects keep non-routed services off the shared net (C03/C07)
— but the routed service keeps its alias there too, and nothing warns.
Measured: a service named `web` yields `aliases=[<project>-web web]` on the
shared network. Two projects both naming their routed service `web` (the
`built-app` fixture does, and so does the first real project) put two claimants
on one alias; a third project resolving bare `web` round-robins between them.
Nothing routes through it today — Traefik targets `container_name`, unique per
host — so this is latent, and the fix is naming, not topology. **Answered:**
warn on any un-prefixed name (C09, 7.0), rather than on a five-name list —
a fixed list prescribes nothing and misses the sixth collision.

**kasbah assumes every project has an environment.** Three symptoms, carried
whole because answering them separately produces three inconsistent answers:
S04 hard-fails a project with no `.env.prod.example` (`lib/check.sh:76-81`) —
a comment-only file passes E01/E04/E05, so the file is real and simply declares
nothing; `init-project` scaffolds `DOMAIN=<domain>` (`lib/init_project.sh:134-144`)
into a template nothing reads, so a scaffolded project's template is never
empty and the tool creates the environment it then insists on; and the starter
compose snippet prints `networks: [kasbah-net, internal]` for the one service
it scaffolds, teaching the two-service case as universal. **Answered:**
mandatory file, empty first-class (7.0). Related and *not* reopened — a first
deploy requiring a terminal is the design, not a defect (`overview.md:143`,
`cli.md:451`, and an integration test that asserts exit 5).

**A `check` warn for "no router on `web` for the manifest domain".** Phase 6
fixed `init-project`'s starter fragment to print the redirect router — every
project scaffolded before that would 404 on plain HTTP — but no rule catches a
hand-written fragment with the same gap, because T03 requires only that a
router declare *some* entrypoint. **Answered:** T08, warn (7.0).

## Carried in from Phase 2

`kasbah server status` exists in minimal form (`lib/server_status.sh`):
docker/compose versions, the marker, Traefik's state/health/image, and each
project's last `versions.log` entry. Phase 7 owns the rest — scheduled as the
inserted task 7.6 — and two items needed a decision rather than just
implementation:

- **The per-project domain.** `cli.md` promised it and it is not printed. It
  lives in `<apps>/traefik/dynamic/<name>.yml`, so it costs either a YAML
  parse on a server where `yq` is not a prerequisite, or a Traefik API call
  with the dashboard credentials. **Answered:** fetch the fragment base64 and
  parse it on the workstation. The credentials route also yields certs and
  router health in one call, but `status` holds only the bcrypt hash from
  `_shared.yml` — never the password — so it would need a new flag or prompt
  plus reachability to `traefik.<apex>`.
- **Cert status, disk usage, mail, per-container health.** Straightforward,
  but they are what turns status from one batched SSH round trip into
  several. Keep the single-round-trip protocol shape that `server_init` and
  `status` both use; it is what keeps the rig's `maxstartups 10` from
  biting.

Also: every command now resolves the apps path through `/etc/kasbah/apps-path` (Phase 4 closed the carry); `status` keeps `--apps-path` as the escape hatch for a server whose pointer is gone.
If Phase 4 puts the apps path in `.kasbah/state.json`, `status` should read
it too rather than keeping two mechanisms.

## Findings

**Approved run (2026-08-25).** The whole phase, in the order 7.0 → 7.2 → 7.1 →
7.3 → 7.6 → 7.4 → 7.5, then a dedicated close commit. 7.0 and 7.6 are
insertions: 7.0 because three Phase 6 carries had no task and 7.1 would have
opened a reserved-name gap; 7.6 because the phase index and the Phase 2 carry
both assign full `status` to Phase 7 while the task list omitted it. Every
open decision listed above was settled before the first agent spawned. Sequential
throughout — each rig task owns `/apps` and Traefik. Verification bar: `./test.sh`
per task against the 20-PASS/6m55s baseline, a hand-driven rig pass per task, the
full `KASBAH_RIG_TESTS=1 ./test.sh` once at the close, and real-host passes for
7.1, 7.3, 7.6 and 7.4 on `you@vps`. Known-unverifiable and left unticked with
the reason: SMTP deliverability, MX, DKIM/SPF/DMARC end to end (9.3). Amended
mid-run at the operator's word: the VPS install is a test deployment, so 7.5
gets a real-host pass too, against a Traefik holding real certificates.

**The `acme.json` schema, measured on the real host before 7.3 was briefed**
(read-only; the local copy was deleted immediately). 28540 bytes, mode 600,
owned by the deploy user — `server init` touches it before Traefik ever mounts
it, and Traefik writing in place does not change the owner, so the deploy user
can read it without sudo. Shape:
`.letsencrypt.{Account,Certificates}`; each entry in `Certificates[]` carries
`Store`, `domain.main`, `domain.sans`, `certificate`, `key`. `certificate` is
base64 of the full PEM chain, so
`base64 -d | openssl x509 -noout -issuer -enddate` yields what a cert-status
rule needs. Confirmed against both live certificates: issuer
`C=US, O=Let's Encrypt, CN=YR2`, `notAfter` 2026-11-20. `notBefore` reads
Aug 22 23:16:22 against an issuance logged at 00:14:53Z — Phase 6's 58.5-minute
backdating, reproduced a third time.

**Two traps that follow from it.** `.letsencrypt.Account.PrivateKey` and each
certificate's `.key` are **private key material**, and the workstation-side
parse means the whole file crosses the wire and lands in a shell variable:
it must never be written to a temp file, echoed, or logged. In particular the
`_ss_absorb_checked` diagnostic path clips raw output to 20 lines × 120 bytes
and prints it on a truncated read — enough to spill key bytes onto stderr, so a
payload carrying `acme.json` needs its own redaction rather than that helper's
clipping. And there is no `jq` on the VPS, which is why the parse belongs on
the workstation in the first place.

**7.0, round 1 review — findings and dispositions.** Verdict needs-work; the
code itself was correct. The reviewer ran a differential test that is worth
copying: five compose shapes (explicit list, `networks:` dict, dict plus a
generic name, a service inheriting the default network when that default
aliases `kasbah-net`, and nothing on the net at all) driven through the new
`lib/check.sh` and through `HEAD`'s, filtered to C03/C04/C07 lines only — the
diff was empty, which is what proves an out-parameter added to a function
serving three **fail**-level rules changed none of their verdicts. Every
mutation was caught, including the one that matters most here: removing `mail`
from `KASBAH_RESERVED_NAMES` cost FAILs in four separate suites, which is how
you know no enforcement site still carries its own literal list.

All six findings **fixed**; none deferred, rejected or carried.

- *A comment claimed coverage that was not merely absent but impossible.*
  `tests/check_test.sh` said its negative control used `www.demo.example.com`
  — a host that contains the manifest domain as a substring, "so this also
  pins that T08 shares T02's matching rule". The heredoc below it actually
  used `www.example.net`, which shares nothing. And the named host would have
  inverted the test: verified, a `web` router for `www.demo.example.com`
  makes T08 **pass**, so the assertion beneath the comment would have failed.
  Net effect, T08's substring-*positive* path had no test at all — only the
  negative side did.
- *The repo's other reference fixture trips the rule this task adds.*
  `tests/fixtures/demo` kept its service named `web` while `built-app` was
  renamed, so `kasbah check` warns on the project `02-spine.md` calls canonical
  and that three suites copy. Confirmed independently before acting. It is
  worse than one rename: `demo` has a **single** service and still declares an
  `internal` network with nothing on it, under a comment about keeping internal
  services off the shared net — the same fixture-shaped anti-pattern this task
  removed from `init-project`'s snippet, in the file that teaches it. The
  service is renamed; the network **stays**, because `spine_test.sh` inspects
  the container's network set and changing topology under an integration
  assertion buys nothing. The comment now says why the second network is there.
- *C09 shouts twice.* Under the banned default-alias shape C07 already fails
  with "every service joins the shared network"; C09 then listed the same
  services individually. `_check_compose_section` establishes the opposite
  convention explicitly ("shouting twice adds noise"), and a code comment eight
  lines above C09 claimed the pattern was reported "not as a per-service list".
  C09 is now silent once C07 has reported that shape.
- *C09's silence was undocumented.* It prints nothing when no service joins
  `kasbah-net`, which also makes the pass count vary between otherwise identical
  projects (measured: 25 with the service on the net, 22 without). C08's row
  documents its own silence in exactly this situation; C09's now does too.
- *A doc claim about scaffolded output was true and untested.* `docs/cli.md`
  says both printed starter snippets pass `check` clean; the suite grepped six
  strings out of the snippet and never materialised it. It now writes the
  snippet into a real project and runs `check` against it — the difference
  between a claim and a test, in the one place the change's own rationale says
  the doc will rot.
- *A test comment left vaguer than the code beneath it.* Minor;
  `server_status_test.sh` also now hands `mail` to the payload-level filter, so
  the path is exercised rather than merely pinned.

**7.0, round 2 — approved, and the two things the confirmation round added.**
Every claimed mutation number reproduced, and the differential on
C03/C04/C07 was re-run against the *current* tree rather than round one's,
because the fix added a **second** out-parameter to the function those three
fail-level rules depend on: identical again.

- *A comment gave a false reason for a correct choice.* C09's gate is an `if`
  rather than `cond && return 0`, and the comment justified that by claiming
  errexit kills a run on a false `&&` head. It does not — errexit is exempt for
  any non-final command in an AND-OR list. Verified both ways:
  `set -e; f(){ [ 1 = 2 ] && return 0; echo reached; }; f` prints `reached` and
  exits 0, while the same function with the AND-list as its **last** statement
  returns 1. The trap is real and this repo does hit it, but only when the list
  is terminal — which is why the convention is to pin `return 0` at the end of
  a function, not to avoid `&&`. **Fixed by the orchestrator:** the gate keeps
  its `if` and the comment now states the reason that is actually load-bearing,
  which is C07 having already reported that shape.
- *A round-one escape, in the same finding class as one the reviewer did
  catch.* `docs/traefik.md`'s illustrative project compose named its routed
  service `web`, sixteen lines above the paragraph this task added telling the
  reader `kasbah check` warns on exactly that. **Fixed by the orchestrator.** A
  sweep of every compose example in `docs/*.md` mentioning `kasbah-net` found
  this one site and no others.

**What 7.0 is worth remembering for.** The mutation discipline earned its
keep twice in one task, and in the same shape both times: an assertion that
greps for a rule's **pass** line proves nothing about the rule's **warn** line,
because the two share no words. The author's first silence assertions scored
**0 FAILs** against the gate they existed to protect; rewritten to match either
line, each gate now costs 1. A test that only ever sees the happy line is the
producer-with-no-coverage defect wearing test clothes.

And a smaller one with a long tail: `kasbah check`'s pass count is not a
property of a project alone. C09 is silent when nothing joins `kasbah-net`, so
two otherwise identical projects report 25 and 22. Any future test asserting a
total rather than a line will be wrong for a reason that has nothing to do with
what it is testing.

**A trap in the orchestrator's own instructions, found by 7.2.** Every brief in
this phase asks the implementer to drive the tool by hand against the rig,
because a passing suite is not evidence the thing works. That hand-driven pass
**contaminates the next rig run**: it leaves version-tagged images behind, and
`tests/integration/ship_test.sh` asserts a freshly loaded image carries exactly
one tag. `rig_clean` removes projects and networks and deliberately leaves
images alone, so nothing cleans them up. 7.2's first rig verdict came back with
`["built-app-web:1.5.0","built-app-web:3.0.0"]` and a FAIL that had nothing to
do with the code — the same shape Phase 4's Findings warn about, where a
poisoned rig presents as an *unrelated* suite failing. Removing
`built-app-{web,worker}:<version>` at both ends and re-running gave 31 PASS.

Every brief from here says so: **an operator pass against the rig ends by
removing the image tags it created**, at both ends, before any verdict run.

**Two things 7.2 measured that are worth not re-deriving.** `docker compose
exec -T` is **not load-bearing on this docker**: removing it costs 5 FAILs in
the unit suite and **0** on the rig, because compose v2 already declines a tty
when its own stdin is not one. It stays as stated intent and for older compose,
but the rig cannot prove it and nothing should imply otherwise. And the rig
still issues transient `ssh` exit-255 refusals when several sessions are open at
once — almost certainly `maxstartups 10`, retried clean, container healthy
throughout. That is the pressure the single-batched-round-trip protocol exists
to stay under, and 7.6 is the task most able to break it.

**7.2, round 1 review — findings and dispositions.** Verdict needs-work; the
design work was sound and both terminal decisions survived scrutiny. All
findings **fixed**; none deferred, rejected or carried.

- *`kasbah logs | head` printed an error and exited 1.* The headline defect,
  user-visible, on the exact use the new documentation advertises: correct log
  lines, then `could not read the logs … exited 255`, with a `(see above)`
  pointing at nothing. Neither suite could catch it — both redirect kasbah's
  stdout to a **file**, so nothing ever closes the pipe early. Fixed by
  exempting the pipe-closed statuses and passing them through silently, rather
  than flattening to 0: flattening would claim the whole log arrived when it did
  not, and would break a caller's `pipefail`. `git log | head` passes its own
  number through the same way. The exemption is narrow — 125 still gets the full
  paragraph and exit 1 (mutation: widening it to swallow everything, 6 FAILs).

  **`ssh` exits 255 where a local process exits 141, and both the review and
  this record first said 141.** OpenSSH ignores `SIGPIPE` — it has a socket to
  look after — so a failed write to a closed stdout becomes `fatal()` and 255.
  Measured against the rig:
  `ssh -n rig 'seq 1 500000' | head -3` gives **255**, while a bare
  `seq 1 500000 | head -3` gives **141**. The implementer found it because a rig
  assertion pinned 141 and failed; its *unit* stub had been `exec seq …`, which
  dies of SIGPIPE honestly and would have blessed the wrong number for good. The
  stub now exits 255 explicitly. **An unfaithful stub agrees with a wrong
  expectation and nothing complains** — this is the second time in two tasks
  that only a real-transport assertion separated a shared guess from the truth.

  Two conditions, neither unconditional: the log has to **outrun the pipe
  buffer** *and* the reader has to stop early enough. A finite `logs | head -3`
  on a small project completes into the buffer and exits 0; `grep -q` drains a
  large block before exiting and returns 0 even matching line 1 of a 118 KB log.
  The suite proves 255 through `-f` (nginx's 5-second healthcheck line is the
  write that lands on the closed pipe) and keeps the finite case asserting 0, so
  255 reads as "the pipe closed under a write" rather than "piping is 255".
- *The state-file spec was left saying the opposite of the code.*
  `exec` deliberately writes `last_server` even when the inner command exits
  non-zero (`kasbah exec web -- test -f /srv/x` returning 1 is an answer about
  the container, not a failed run). `docs/cli.md`'s preamble was reconciled;
  `docs/project-manifest.md` — the file `lib/ops.sh` cites as its authority for
  the write rule — still read "written **only on success**", and
  `lib/state.sh`'s own comment claimed the same.
- *The rule offered for telling exit codes apart did not hold.* `cli.md` said a
  status from a run that printed no kasbah error is the command's own. Measured:
  `docker compose exec -T nosuch true` prints `service "nosuch" is not running`
  and exits 1 with no kasbah error at all — so the two likeliest `exec` failures,
  a typo'd service and a stopped container, are indistinguishable from the
  inner command's own 1. The propagation decision is right; the disambiguation
  rule was false, in the one section whose job is preventing that confusion.
- *`--apps-path` overclaimed as `server status`'s alone* — `server init` takes
  it too, in both the doc and a code comment.

**The `logs -f` orphan: documented, and the alternatives are on record.** No
pty means a client that dies leaves `docker compose logs -f` resident on the
server until its next write to a closed pipe — indefinitely for a quiet service,
measured still present at t+80s. Rejected: `ssh -tt` (a CR before every LF on
data meant to be piped, and the interrupt would go to the *remote* process, so
ssh returns 130 and the failure branch fires on an ordinary quit); a remote
wrapper that dies with its pipe (works, but needs a fourth transport mode in
`lib/ssh.sh`, since `ssh_run` uses `-n` and `ssh_script` spends stdin on the
payload — and remote shell syntax is what `ssh_run`'s contract exists to
forbid); and an INT trap firing `pkill` over the still-live master. That last
one is ten lines and would work, and is refused on this repo's own history:
`lib/ssh.sh` records a read-only `server status` tearing down a concurrent
`server init` because a teardown reached another process's work. Kill-by-pattern
on a shared VPS is that mistake automated. **A broom an operator reaches for
deliberately is not the same object as one the CLI swings on every Ctrl-C.**
What changed instead: the doc now says the leak **accumulates** — one resident
follower per interrupted follow, each holding an open dockerd stream, on a box
chosen for being small — the `pkill` recipe is narrowed to `… /compose.yml
logs` so it cannot take out a concurrent `kasbah exec` on the same project, and
"this is ssh's behaviour rather than kasbah's" is gone. kasbah chose no-pty for
good reasons and owns the consequence.

**Four guards that a green suite did not defend.** All fixed, and the first is
the sharpest instance yet of this phase's recurring shape: the assertion that
`logs` does not write `last_server` on failure scored **0 FAILs**, because the
failing run targeted **the same host** as the passing one — so a spurious write
rewrote byte-identical JSON and the assertion passed anyway. It needed a second
host to become real. Also unguarded: all three `\r` strips (0 FAILs each, and
CLAUDE.md mandates them), the `-f=VALUE` refusal, and `--help` for both
commands.

**7.2, round 3 — approved after a documentation-only sweep, and the sweep is
the finding.** The confirmation round found every fix landed and every mutation
number exact, then reported that the change had turned `logs` into a *partial*
status-propagator while **six passages still described the world before it** —
three of them saying in so many words that `exec` is the only command that
reports a status it did not choose. One was `--help` output. One was inside the
same comment block that explained the new behaviour twenty lines above. Two were
stale `141`s in test comments, i.e. the exact belief the round existed to
correct. All fixed by the orchestrator; no code or test change was needed for
any of them.

**The shape worth keeping:** a behaviour change lands in one place and its
description lives in six, and the ones that bite are the confident ones — "the
one command that", "the one exception to this list". A sentence that names
something as unique is a sentence that a later change silently falsifies, and
`grep` does not find it, because it does not contain the thing that changed.

*One stated reason for a decision was neutralised by the same round's fix.* The
anti-pty comment argued, among other things, that under `-t` ssh returns 130 and
"the refusal below would fire on an ordinary quit" — and the refusal below now
exempts 130. The decision stands on the CR argument alone, which is
independently sufficient; the dead reason is gone.

**The operator-facing rule the reviewer extracted, now in `docs/cli.md`.** 255
is both "the reader stopped" and "the link broke", and no exit code can separate
them — but nothing needs to, because the closed-pipe path is **silent** (OpenSSH's
fatal exit writes nothing, pinned by an integration assertion) while a genuine
drop writes `client_loop: send disconnect`. So: **255 with nothing on stderr is
the reader stopping; 255 with a line on it is the link stopping.** Rejected as
more expensive than the fact is worth: capturing ssh's stderr to branch on it
(breaks `lib/ssh.sh`'s no-wrapper rule), and probing kasbah's own stdout for
EPIPE (writing to a closed pipe under bash kills bash).

`130` was confirmed unable to mask anything: without a pty an interactive Ctrl-C
signals the whole foreground group, so bash dies inside `ssh_run` and never
evaluates `rc` — the branch is reachable only when ssh alone is signalled. The
unit test drives it with a forced return code and says so, which is the right
kind of honesty about testing a branch rather than a scenario.

*Accepted, not fixed:* the dropped-stdin warning still fires on
`while read … done < file`, where `ssh -n` is doing exactly the job
`lib/ssh.sh` says it exists for. There is no clean predicate separating "fed on
purpose" from "inherited", which is the argument for it being a warning rather
than a refusal; its second clause now states what was measured (a pipe or a
file) instead of guessing at intent.

### 7.1a — the mail stack

**The implementing agent died mid-report from an API error**, having finished
the work. Everything below the code itself — the mutation table, the design
rationale, the real-host evidence — was reconstructed afterwards by the
orchestrator and by a review briefed as the sole source of mutation evidence.
Two lessons came out of that alone, and both are about the run rather than the
tool.

**An agent's death leaves its children running.** Two orphaned `./test.sh` runs
were still driving the rig minutes later, one of them mid-`deploy` against it.
That is precisely the state Phase 6 recorded as making a suite result
worthless, arriving by a route Phase 6 did not anticipate: not a human starting
a second run, but a dead agent's process tree outliving it. Check
`pgrep -af 'test.sh|bin/kasbah'` before trusting any verdict taken after an
agent fails.

**A diagnostic can lie in the direction of good news.** The orchestrator ran
three suites in a loop with `echo "$(basename $t) exit=$?"` and reported all
three green. The command substitution runs **before** `$?` is expanded, so
every line reported `basename`'s status, not the suite's. `server_init_test.sh`
had been failing the whole time, and its 70-byte log said so. Write `rc=$?`
first, then interpolate.

**What was failing was the assertion Phase 6 added**, which has now earned its
keep twice: four `warn` lines opened with a capital. `tests/server_init_test.sh`
extracts every `warn` opener in the file and fails on an uppercase one. The dead
agent's last transmitted words were that it had found this; it never fixed it.

**The design decisions, recovered from the code and confirmed by measurement.**
The original project broke the DMS boot deadlock — DMS will not start without a certificate
for `mail.<domain>`, and Traefik only requests certificates a router claims — by
hanging the cert-trigger router on the *SnappyMail* container's labels, since
under the **docker** provider every router must name a real service, plus a
`replacepathregex` middleware rewriting every path so SnappyMail answered 404.
kasbah does not wire the docker provider in at all, so both routers move into
the kasbah-owned `_mail.yml` file fragment and the middleware disappears:
`service: noop@internal` is Traefik's own backend-less placeholder, already used
by `_shared.yml`'s dashboard redirect.

**`noop@internal` answers 418, not 404** — measured on both the rig and the real
host. The original project's 404 came from SnappyMail being handed a path it did not have.

**The original project's comment claiming its `:80` router is what lets ACME work is
wrong**, and the review's evidence is sharper than the suite's. Traefik answers
HTTP-01 from its own internal `acme-http@internal` router
(`PathPrefix(/.well-known/acme-challenge/)`, priority `MaxInt`, so no fragment
can shadow it). The decisive measurement:
`http://mail.<domain>/.well-known/acme-challenge/xyz` returns **404** —
acme-http's unknown-token answer — while `http://mail.<domain>/` returns **301**
to the redirect middleware. The `web` routers are genuinely not in the ACME
path, and equally do not break it. For `webmail` the redirect is the difference
between a working bookmark and a 404; for `mail` it is only consistency.

**Four traps that live only in code comments, recorded here so they survive the
file.** SnappyMail chowns its `_data_` directory to mode 750, which breaks the
*second* run's `mkdir -p`. The data path's checksum races itself — `rspamd.rrd`
and `mail.log` moved a digest twice in three seconds. A crashlooping container
reports its ports under `HostConfig.PortBindings` and **not** under
`NetworkSettings.Ports`, so anything inspecting a container that has not stayed
up must read the former. And the registry read makes three separate
`_si_yaml_get` calls rather than one, so a newline inside a domain value cannot
smuggle an extra list entry.

**Real-host result: the deadlock resolution works.** All four certificates in
`acme.json` — `gallery`, `traefik`, and the two new ones — `mail-dms` and
`mail-snappymail` both healthy, `gallery-website` undisturbed throughout.
`https://webmail.example.com` 200 with a publicly trusted certificate,
`https://mail.example.com` 418, `https://gallery.example.com` 200. This is
the one thing the rig can never show: there, `SSL_TYPE: letsencrypt` makes a
certificate a boot requirement that can never be met, so DMS crashloops forever
and the rig suite correctly asserts on the **cert-missing log signature** rather
than on health — a compose file broken for any *other* reason produces exactly
one FAIL against it.

**Idempotence was re-run, not read.** With a relay credential, an unrecognised
operator key and a mailbox planted first, a second no-flag run with stdin closed
left the data-path digest byte-identical, the postmaster hash unchanged and all
three operator values intact. The half-made case was driven over the real
transport too: `postfix-accounts.cf` truncated to zero, re-run with no flag and
no TTY, gives exit 1 naming `--postmaster-password=` and changes nothing.

**7.1a review and fix rounds — approved at round 2. Four findings worth keeping.**

**A brief can carry the very defect it is trying to fix.** The orchestrator told
the fix agent to pin the fragment-before-Traefik ordering by mirroring an
existing mtime assertion. That does not work: `ssh_rsync -pt` **preserves the
workstation's render mtime**, and the render precedes the Traefik start in
*both* orderings, so the assertion is green either way — reproducing exactly the
0-FAIL blindness it was written to close. The fix reads the fragment's **ctime**
instead, which rsync cannot preserve. Measured on a broken-ordering clean run:
`mtime < started` **TRUE** (blind), `ctime < started` **FALSE** (bites), with
mtime 607 ms *before* the start and ctime 6.5 s after it.

**And the nanoseconds are load-bearing, not decoration.** On a correctly ordered
clean run the gap is `ctime …304300089428` against `start …304597011574` — 296
ms, *inside the same second*. A whole-second comparison would not have been
merely coarse; it would have been a flaky false FAIL.

**A property test needs a control, or it passes vacuously.** D2 pins that no
password reaches a hasher's argv, using a stub `openssl`/`htpasswd` on `PATH`
that records its own arguments. The assertion that matters is not "the password
is absent from argv" — that is trivially true if the stub never ran. The suite
also asserts the stub *was reached*, and mutating the hasher to call
`/usr/bin/openssl` directly produces exactly that FAIL. Without it the whole
test is green for the wrong reason.

**Two claims this run got wrong and corrected by measuring.** `notBefore` is not
issuance time (Phase 6, reconfirmed here). And the reason `awk` rather than
`[ -gt ]` compares Traefik's ACME router priority is **not** int64 overflow, as
this file and two briefs first said: jq 1.7 prints the literal
`9223372036854775807`, which is exactly `INT64_MAX` and which bash compares
without complaint. The real hazard is jq ≤ 1.6, which renders it through a
double as `9.223372036854776e+18` — a float literal bash refuses outright with
`integer expression expected`. `awk` reads both. Verified both ways on this
machine.

*Accepted, not fixed:* the new unconditional `chmod 600` turns a `.env` kasbah
cannot chmod — hand-chowned to root, say — into a hard init failure where it
previously reported `mail_env=unchanged` and continued. That is precisely how
`_server_init_layout` already treats `acme.json`, so it is correct by
consistency rather than by separate argument.

*Deferred to 7.1b, with a home:* `docs/mail.md`'s "Mail is optional" block still
shows deploy **hard-failing** a mail claim with an `ERROR:` message; the code
warns and continues, and `docs/project-manifest.md` says so. 7.1b owns the claim
reconciliation, which is where that text either becomes true or gets rewritten.

**The rig's cgroup limitation is known, handled, and not worth re-diagnosing.**
The nested cgroup v2 tree runs in threaded mode and the rig's delegated
controllers are `[cpuset cpu pids]` — **no `memory`** — so a container asking
for a real `--memory` or `--cpus` limit fails with `cannot enter cgroupv2
"/sys/fs/cgroup/docker" with domain controllers`. The integration suites
already detect this and print `note: this rig cannot apply cgroup limits`,
setting the marker's limits to 0/0, which Docker reads as no limit. The outer
Docker on the workstation is unaffected.

Half an hour went into re-deriving that during 7.1b because a hand-driven
deploy hit it and the suites never do. Things that do **not** fix it, all tried:
restarting the containers, restarting the rig container, and removing and
recreating the rig container (the named volume `kasbah-rig_docker-data` survives
that, so the image cache is at least preserved). It is a property of nested
cgroup v2 delegation on this host, not rig state. **A hand-driven rig deploy
therefore cannot use real resource limits** — that is the one operator check the
rig cannot carry, and the real host is where it is observed instead.

**The verification regime's stated risk arrived inside one task.** 7.1b ran only
its own suites, as the amended regime tells it to, and left
`tests/integration/deploy_ship_test.sh:670` asserting the message of the stub it
had just replaced. Nothing in its own suites could see it. This is exactly the
cross-suite staleness the regime trades away, and it argues for one cheap habit
rather than reverting the trade: **when a change alters an operator-visible
message, grep the whole `tests/` tree for that message before reporting** — the
sweep costs one command, where the full rig suite costs nineteen minutes.

### 7.1b — everything that talks to the mail stack

`add-mail-domain`, `mail-setup-guide`, the deploy-time claim reconciliation that
replaced the Phase 4 stub, and `M01`/`M02`. Four things worth keeping.

**A 247-line byte-identical duplicate sat in `lib/deploy.sh` and every suite
passed over it.** Eight functions had two definitions; the file had grown from
1019 lines to 1477. Bash takes the last definition, the copies agreed, so
nothing misbehaved — and **every line of the first copy was unreachable**, so any
later edit there would have been silently dead. `bash -n` cannot see this class.
The proof that it mattered: a reviewer injected `die "POISON"` into the *first*
`_deploy_sync_fragment` and got `deploy_test` **rc=0, 0 FAILs, POISON never
printed**. After the deletion the same probe fires 51 times and rc=1. This is the
second duplicate-definition accident in one task — the implementer caught its own
smaller one (`_deploy_mail_claim`) when 35 assertions failed at once.

**The sweep that catches it, and the naive version that cries wolf.**
`grep -oE '^[a-z_]+\(\)' | sort | uniq -d` reports `dc()`, `emit()` and `fail()`
in `lib/server_init.sh` — all false, because they live inside separate
`<<'REMOTE'` heredocs: different shell programs, one namespace each. A sweep that
false-positives on six remote payloads is one nobody keeps running. The
heredoc-aware form:

    awk '/<<.REMOTE./{r=1} /^REMOTE$/{r=0} r==0 && /^[a-z_]+\(\)/{print $1}' "$f" \
      | sort | uniq -d

**`rollback` shipped the working tree's SnappyMail pre-seed, not the target
version's.** `_deploy_read_mail` reads the *extracted tag's* manifest — rollback
repoints `KASBAH_MANIFEST_FILE` into the extract — so the declared path was the
tag's; but `_deploy_mail_claim` runs outside `_rollback_in_extract`, with the
working directory back at the checkout, so both the existence test and the
base64 read resolved against today's tree. A rollback to a version that shipped
a pre-seed warned that it had not, and when it did seed, it seeded current bytes.
The same file already solved this for the Traefik fragment; the mail seed simply
missed the precedent. Copy-if-missing kept it latent, which is exactly why it
needed a test — when it bites, the wrong bytes are the ones that stay. Mutation:
removing the fix costs **7 FAILs**, and the diagnostic is the bug naming itself
(`RlJPTS1USEUtV09SS0lORy1UUkVF` decodes to `FROM-THE-WORKING-TREE`).

**A tri-state with one consumer, resolved by deleting the producer rather than
testing it.** `mail_aliases` reported `absent|notfile|unreadable|present` and only
`present` was ever distinguished; collapsing the remote to two states scored
**0 FAILs**. The fix went past collapsing: once it is `present|absent` it is a
second copy of a fact the payload bytes already carry, since "no alias seen"
falls out of scanning them. The producer is gone; the distinction stayed where it
belongs, in the write step, which is the only place holding both a file
descriptor and a verdict. The two neighbouring facts got *readers* instead —
a registry with no `.env` beside it is an unfinished init and the stack cannot
start, and the write step's `registry` key is now judged rather than merely
demanded.

**`postfix-aliases.cf` does not exist in docker-mailserver 15.1.0** — the alias
database is `postfix-virtual.cf`, and this brief and `docs/mail.md` both had it
wrong. It is load-bearing rather than cosmetic: DMS builds `/etc/postfix/vhost`
— `main.cf`'s `virtual_mailbox_domains` — from `postfix-accounts.cf` plus
`postfix-virtual.cf`, taking the domain of every account and of every alias
carrying an `@` (`helpers/postfix.sh` → `_vhost_collect_postfix_domains`), so a
registry entry without the alias is a domain Postfix refuses mail for. Verified
in the image *and* against the real host, whose `vhost` holds exactly the one
domain it serves.

**A process note, third instance of one cause.** A suite is evidence only when
nothing else is writing. It has now bitten this phase three ways: a false green
from a mis-expanded `$?`, a dead agent's orphaned runs still driving the rig,
and the orchestrator launching suites in the same turn it resumed an implementer
that was mid-edit in the file under test. **Never start a verification run in the
same turn as a spawn or a resume.**

**Agents stall themselves on polling loops, and it needs saying in the brief.**
The operator had to intervene on a run where an agent had stacked **nine**
`until ! pgrep …; do sleep …; done` waiters, each blocking on the last. Nothing
was wrong with the work — the agent was waiting for its own suites and had
invented a busy-wait to do it. Every brief from here forbids polling outright:
run the command in the **foreground** and read `rc=$?` on the next line, which
is all the waiting anyone needs, and let the harness notify about genuine
background work. The single legitimate use of `pgrep` is one non-looping call to
check nothing else is writing before a verification run.

Together with the earlier `echo "$(cmd) rc=$?"` mis-expansion and the two
concurrent-writer incidents, that is four separate ways this phase lost time to
**how a result was waited for or read**, rather than to the work itself.

### 7.3 — `check --server` and R04

**Delivered.** `lib/acme.sh` (the `acme.json` reader) plus `lib/check_server.sh`;
all six server rules, R04, and the T05 tightening `compliance.md` promised.
Against the real host: **`34 passed, 0 warning, 0 failed`**, reading
`gallery.example.com valid for 87 more day(s) (until Nov 20 23:16:21 2026 GMT,
CN = YR2)` — matching the `notAfter` measured independently before the task was
briefed — with nothing written there. Four things worth keeping.

**A reserved-hostname set built per family left one family guarded by nothing.**
T05 has two forms: a local heuristic on the first DNS label, and an exact match
against the real apex and mail registry under `--server`. The first
implementation built the exact set per family, so a server whose `_shared.yml`
was unreadable but whose mail registry was fine still produced a **non-empty**
set — which sent T05 down the exact-match branch, where `traefik.<apex>` was
guarded by neither the set (it was not in it) nor the heuristic (that branch was
skipped). A project claiming the dashboard hostname passed silently.
`docs/compliance.md` promised the opposite in as many words, so the **code**
changed, not the doc. The fix is better than the brief asked for: T05 now asks
*both* questions of every hostname — exact membership, then heuristic label — so
the local run became the same code path with the same two answers, **removing** a
branch rather than adding one. And it caught a case the instruction missed: apex
known, registry absent, nothing falls back, because `--with-mail` defaults
`primary_domain` to the apex, so those *are* the hostnames the server claims;
a registry naming a different primary is the case that genuinely is not
reserved, and reading it is what tells the two apart.

**An assertion bit its own author, and was widened rather than loosened.** The
read-only suite asserts *every docker verb in the payload is `inspect`*. Adding
a `docker version` probe — the cheapest question separating "daemon down" from
"container absent", which the health rule previously collapsed into "not
running" — made that assertion fail. It was widened to `(inspect|version)` with
a comment that both are reads and these two are the only ones allowed. A
read-only guarantee that erodes to "any docker command" is not a guarantee.

**`lib/env.sh` was widened, and that file also runs on the VPS.** `check --server`
must not write the server's `.env` to disk, so it hands `env_drift` a **process
substitution** — a pipe, which the old `[ -f ]` guard rejected, silently
reporting *every* template key as missing. A wrong verdict, not an error. The
widening to "readable and not a directory" was verified input by input against
the old copy: directory, nonexistent and regular-readable are unchanged, and the
only input that moves is an **unreadable** regular file, which was already the
wrong verdict and now merely loses a stderr breadcrumb. The real boundary is a
**fifo** `.env`, which `[ -f ]` skipped and `[ -r ]` accepts and would block on
forever — unreachable because `_env_report` refuses `[ -e ] && [ ! -f ]` on both
files before `env_drift` is called, and the local caller is gated on
`[ -f .env ]`. That is now a comment at the guard, naming the three call sites,
so the next person to widen it knows what the boundary was.

**A test that cannot fail for the reason it claims.** The redaction assertion
grepped the diagnostic for the *decoded* secret — but the payload carries
`acme.json` **base64'd**, so a mutant echoing the entire payload still would not
contain the plaintext. It scored **0 FAILs**. It now greps for the blob itself
and asserts the blob exceeds 200 bytes, so it cannot pass vacuously in either
direction. Same family as the phase's other zero-scoring assertions, with a new
twist: the encoding, not the wording, was what made it blind.

*Forward hazard for 7.6:* `_ss_absorb_checked` clips raw output to 20×120 bytes
and **prints it** on a truncated read. If `server status` adds `acme_b64` to its
batched probe it will spill key material onto stderr. `lib/acme.sh` warns in a
comment; nothing enforces it. `check --server` avoided this by writing its own
absorb rather than reusing that helper.

### 7.6 — full `server status`

**Delivered.** The five things the Phase 2 carry assigned here: the per-project
domain, cert status and expiry, disk usage, the mail stack, and per-container
health — **in one round trip**, which was the carry's stated constraint. Against
the real host the tool now prints four certificates with issuers and expiry, both
mail containers healthy, the dashboard apex, disk, and `gallery-website` with its
domain and certificate inline. One incidental observation only possible now that
the issuer is printed: the mail certificates came back `CN = YR1` at 89 days
against `gallery`'s `YR2` at 87 — Let's Encrypt rotated intermediates between the
two issuances.

**The vacuity class produced two more variants here, making four in the phase.**
An assertion can fail to be an assertion by **wording** (7.0: grepping a rule's
pass line, which shares no words with its warn line), by **encoding** (7.3:
grepping for a decoded secret in a payload that travels base64'd), by
**position** (found by the implementer: `_ss_absorb_checked` prints only the
first 20 lines of a truncated payload, so a fixture emitting the secret at line
36 put it outside the window the test existed to exercise), and by **clip
length** (found by the review: the needle was 120 bytes of a line that can only
ever print 111, because `acme_b64=` eats 9 of the 120-byte clip — it could never
match).

The last block was vacuous **three ways at once** — position, needle length, and
no positive counterpart — and the fixes had to be simultaneous: the needle fix
alone leaves it passing for the wrong reason, the position fix alone leaves it
silent. Under a mutant that disables redaction the block went from **2 FAILs to
5**, which is what proves all three assertions now bite.

**The generalisation worth carrying past this phase:** every one of the four
variants passes a green suite, reads as proof to a human, and dies under
mutation. A negative assertion — "the secret is *not* in the output" — is
vacuous by default and has to be *made* meaningful; the reliable way is to pair
it with a positive one that pins the same mechanism from the other side, so the
pair cannot both stay silent.

**A trap that guards itself, but only by accident until it is labelled.** The
20-line clip window means anyone adding a probe key ahead of `acme_b64` pushes it
out of the diagnostic's reach and silently un-tests the redaction. That *is*
caught — inserting three filler keys makes two assertions fail loudly — but only
because those assertions happen to pin position while reading like output
assertions. They now say so in a comment. An implicit guard nobody can see is one
edit away from being deleted as redundant.

**Also fixed:** a comment in `tests/integration/spine_test.sh` claiming a
one-round-trip guarantee the assertion beneath it did not make — that assertion
was wrong by construction as well (`grep -c` on a `tr`-joined single line is
always 1). The guarantee is real and pinned, in the *unit* suite, by counting
`bash -s` in the stub ssh log. A comment describing a check that is not there is
worse than no comment.

**`shared_b64` joined `acme_b64` in the redaction list.** `_shared.yml` carries
the dashboard's bcrypt hash — an offline-crackable credential. It sits outside
the 120-byte clip today only because the fragment's first line is short, and
nothing pins that; the file gains a line whenever a middleware is added. One
array element against a credential on stderr.

*Traced, not proven:* the name column now sizes to the longest project name, and
the real-host report is byte-identical either way — a single-project server
cannot show that defect. The evidence is a two-row unit case asserting both rows'
state columns start at the same offset.

### 7.4 — `server prune`

**Delivered.** The retention policy exactly as `build-deploy.md` states it, across
all projects, with a tri-state confirmation. Against the real host the answer was
the one that proves the policy does not over-delete:

    keep   gallery-website-web:0.1.0  :current points at this image
    keep   gallery-website-web:0.1.1  among the last 3 deployed (0.1.0 0.1.1)
    nothing to remove: every version tag on you@vps is inside the retention window.

13 images before and after, unchanged. The shared/stock rule proved itself on
real data rather than a fixture: `docker-mailserver:13` (2024-01),
`snappymail:v2.38.2`, `traefik:2.11`, and **two non-kasbah projects on that host**
(a static site and a UDP relay) are all older than the window and all
untouched, because none is a version tag of a built image under `/apps`.

**The safety hole was not in what prune deletes but in what a *skip* protects.**
"Skipped whole" protected the skipped project's own tags. It did not protect the
tags whose ownership that project could have **contested** — ownership was
collected before any skip was decided, so a project whose `compose.yml` could not
be read contributed no claims, and the multi-owner guard was defeated by the very
condition that triggered the skip. The reproduction indicts itself:

    skipped — nothing of these was removed
      omega: its compose.yml cannot be read …, so which images it builds is unknown
    …
      removed shared-web:1.0.0

The run states the premise that invalidates the deletion, and deletes anyway.

**The rule chosen is a deliberate cliff:** while kasbah cannot enumerate *any*
project's declared images, no repository on the server is provably single-owner
and prune removes nothing anywhere. Server-wide, not narrowed — because the file
that would say which repositories the project might have claimed is the file
nobody could read, and image names are not derivable from project names
(`image:` is whatever the compose says). Every narrowing is a guess about the
contents of an unread file. An *absent* compose poisons alike: a directory with a
`versions.log` and no compose is a project that has deployed, whose images sit on
the host under names only that file records. One rule, not four. The cliff is
loud — a dedicated report sentence naming the projects to fix, a per-tag reason
on every kept tag, and a warning pair — and prune is maintenance, so nothing is
blocked by deferring it.

**A pairing the orchestrator asked for that cannot exist.** Every "did not remove
X" assertion in this suite is paired with a positive on the same mechanism, and
the brief demanded one for D1 too. Under a server-wide rule that pair is
impossible in a single run: if unknown ownership poisons everything, no tag
anywhere stays removable. The implementer said so rather than faking it, and
moved the pairing to **two runs of one fixture** — same tags, same ages, differing
only in whether an unknowable project is present — with the in-run positive being
the exact reason string, so a keep for some other cause cannot masquerade as the
guard firing. When a safety rule is global, the counterfactual has to move to the
run level; there is nothing left inside one run to contrast with.

**Two skips that looked like one.** A `compose.yml` that read fine but did not
*parse* was neither skipped nor warned about: the skip test was on **file state**,
the parse failure was swallowed, and the project fell into the branch commented
"Nothing to prune, and nothing wrong: a project of stock images only." The
function-level test did assert bad YAML is refused — but no command-level fixture
had an `ok`-state compose that fails to parse, which is exactly why the
drop-through was invisible. The two now carry distinct reasons, and the split is
the legible statement of the two categories: **a record-side skip protects only
its own tags; a compose-side skip stops the server.**

**A shared predicate that nothing shared.** `vlog_active_usable` was extracted so
that `vlog_fetch` and prune would refuse on the same evidence, and its comment
said so — but `vlog_fetch` kept its own inline `case`. Gutting the predicate left
history, rollback and status at **0 FAILs** and only prune failing. The seam the
refactor existed to close was still open, and only a mutation across four suites
showed it. Now 16 FAILs in `versions_log_test` when gutted.

**`--apps-path` was added here and removed on review.** `docs/cli.md` states that
no command but `server status` takes it — a value repeated on every invocation is
a belief each caller holds separately — and an operator-supplied path is worse on
a *destructive* command, because it aims deletion at a tree the server does not
consider its own. The recovery messages were **re-pointed rather than deleted**:
find the tree with `server status --apps-path`, then repair the pointer.
