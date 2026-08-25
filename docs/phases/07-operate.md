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
| 3 | 7.1 | Biggest unknown early; the DMS image pull is a one-time rig cost. Ahead of its dependants so M03, `status`'s mail line and 7.5's dry-run over `_mail.yml` are native rather than retrofits |
| 4 | 7.3 | Builds the `acme.json` cert reader 7.6 consumes |
| 5 | 7.6 | The phase index and the Phase 2 carry both say Phase 7 owns full `status`; the plan had no task for it |
| 6 | 7.4 | Reuses the per-project `versions.log` read `status` already does |
| 7 | 7.5 | Last on purpose: its dry-run must validate every existing fragment, and `_mail.yml` exists only after 7.1 |

Sequential, no parallelism — every rig task owns `/apps` and Traefik, which is
what made Phase 6 serialise 6.0 and 6.1.

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

### 7.1 — Mail stack port (L)
`server init --with-mail` / `add-mail-domain` / `_mail.yml` cert-trigger
fragment, ported from the original project's `mail/`. Deploy-time claim
reconciliation replaces the Phase 4 stub. SnappyMail domain pre-seed
copy-if-missing. Live mail migration (the original project's) is deliberately NOT
here — it happens with its owner's migration in Phase 9.3.

Also in scope, named because the task text did not: `kasbah server
mail-setup-guide USER@HOST` (roadmap v0.2, `mail.md` → the walkthrough shown
once after init), and **M03** in `check --server` — the rule needs the registry
this task creates, so it lands here rather than in 7.3.

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
