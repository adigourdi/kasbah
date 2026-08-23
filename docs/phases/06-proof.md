# Phase 6 — Proof  ← the real milestone

> A real project — deliberately not named in this plan — runs on a freshly
> provisioned VPS through kasbah alone: from bare server to HTTPS with a
> real Let's Encrypt cert, plus a change deploy and a rollback, all on
> real infrastructure.

**Prerequisite:** Phase 5. **Real infrastructure — first contact.**
Greenfield on purpose: migrating the original project would prove little (the tool
was generalized *from* it, so it fits by construction, and its VPS is
already half-prepared). A fresh VPS + a different project exercises the
whole `server init` path and everything the rig cannot fake — DNS, public
port 80, ACME.
**Spec:** `docs/server-setup.md`, `docs/build-deploy.md`, `docs/traefik.md` (TLS section), `docs/cli.md`
**Retires:** real-world ACME/DNS/network behavior; "does the generalization hold for a project it wasn't extracted from".

## Exit criteria
- [ ] A fresh VPS goes from bare Docker host to serving the project over HTTPS (valid LE cert) using only kasbah commands
- [ ] A second deploy of a trivial change lands end to end (tag → build-push → deploy → hooks → live)
- [ ] A rollback on the real VPS restores the prior version (the Phase 5 drill, repeated on real infra)
- [ ] Docs reconciled: everything reality contradicted is fixed in `docs/` now

## Tasks

### 6.0 — ACME endpoint switch (M) [inserted during execution]
The tool cannot do what 6.2's own precaution requires: `traefik.yml` has no
`caServer`, `server init` has no flag for one, and `docs/traefik.md` § TLS
never mentions staging — so a first real run goes straight at production
Let's Encrypt and burns rate-limit budget on failed challenges.

**Deliverables**
- [x] `--acme-staging` on `server init`, rendered as `caServer` into `traefik.yml`; default stays production, so a user who wants production does nothing — production is rendered *explicitly*, not by omitting the field, so detection compares one line
- [x] A re-run whose CA differs from the one in effect on the server resets `acme.json` itself (archive + recreate, mode 600) and restarts Traefik, so staging→production is one command and no hand-editing on the server — keyed on the **store**, not the config: an empty or absent store is never touched and never asks
- [x] The reset confirms once, with `--yes` for scripts — it discards certificates and forces re-issue. **Amended in flight:** there are two questions, not one. The stated-CA switch is a confirmation (`--yes`, decline aborts); an *unrecorded* CA is a choice (`--reset-acme` / `--keep-acme`, keep proceeds and warns), because keeping is a real outcome and a blanket `--yes` cannot know which CA filled a store it did not create
- [x] `docs/traefik.md` § TLS and `docs/server-setup.md` say how the switch works — plus `docs/cli.md`, `docs/overview.md`'s Interactivity row, and a new "On the workstation" section
- [x] Unit tests in `tests/server_init_test.sh` — and in `tests/prompt_test.sh` for the new `prompt_choice`; the remote store probe is extracted from its heredoc and run for real against a scratch tree, mutation-scored rather than assumed

**Watch out for:** `traefik.yml` is the only file whose byte-change sets
`_SI_TRAEFIK_RESTART` (`lib/server_init.sh:1544-1561`) — a `caServer` change
must ride that path, not a second restart mechanism. Traefik holds `acme.json`
open, so the reset cannot ride the layout step that creates it
(`lib/server_init.sh:1120-1129`, which runs long before the stack ships):
replacing the file under a running Traefik leaves it writing to the old inode.
The reset belongs in the ship step, after the new `traefik.yml` is in place and
before the restart. Detection reads the CA back out of
`_SI_TRAEFIK_CURRENT[traefik.yml]`, which is already fetched — the same
mechanism as `_si_extract_email`.

### 6.1 — Project conformance, locally (M)
`init-project` in the chosen project, compose in the new pattern (network
split, `KASBAH_*` limits, `container_name`s, logging), fragment, env
template. `kasbah check` clean, then a full rehearsal deploy to the rig
— hooks and all, if the project has them.

**Deliverables**
- [x] `kasbah check` exits 0 in the project — **26 passed, 0 warning, 0 failed**
- [x] Rehearsal deploy on the rig serves the project via fragment routing — `:80` answers **301** to HTTPS and `:443` serves the bundle with the shared security headers. The 301 is correct, not a miss: the app's folder picker needs a secure context, so `http-to-https@file` on the `web` router is what `traefik.md` prescribes and what the app requires

**Settled:** the project is `~/work/gallery-website` — a Vite/TS static
bundle served by nginx (`Dockerfile` target `prod`), git, no tags, no
environment at all. Its dev `compose.yml` stays untouched: `lib/check.sh`
reads `compose.prod.yml` exclusively and the manifest's `sync:` renames it on
arrival. Expect `S04` (`.env.prod.example` missing = hard fail) to pinch a
project that has no environment — a comment-only template satisfies `E01`,
and the pinch is a finding about the tool.

**Watch out for:** this is the first non-fixture project — expect the
manifest or check rules to pinch somewhere the fixtures didn't. A pinch
here is a finding about the *tool*, not the project; record it before
working around it.

### 6.2 — Fresh VPS + `server init` (M)
Provision the VPS, point the project's DNS at it, `server init` with a
real domain and email (`--no-mail --no-backup` — those are Phases 7/8).
Verify Traefik health and dashboard auth over the real network.

**Deliverables**
- [x] Init from a clean SSH session, no manual server prep beyond Docker — **20.4 s wall clock**, exit 0, including pulling `traefik:v3.7.10`. No prompt fired with stdin closed; every question was answered by a flag
- [x] Dashboard reachable over HTTPS at `traefik.<domain>` — 401 without credentials, 200 with, on a staging cert (production switch is the tail of this task, after the deploy proves out)

**Settled — the target host.** Not a freshly provisioned VPS: the existing
OVH VPS (Ubuntu 26.04, Docker
29.6.0 / Compose v5.2.0, 2 cores / 3.7 GB), reused because it is **already
bare** — no running containers, nothing listening on 80/443/25, no `/apps`, no
`/etc/kasbah`, ufw inactive and `INPUT ACCEPT`, and 80/443 answer *refused*
rather than timing out from outside, so nothing filters them. Record the exit
criterion honestly as "pre-existing but bare" rather than "freshly
provisioned"; what it tests — bare Docker host → HTTPS, kasbah only — is
intact. **It is not disposable**: the SSH user (in `docker` and `sudo`,
passwordless), and the instruction is to change as little as possible.
Undoing kasbah afterwards is manual — `drop` and `server destroy` are Phase 8.

ACME account email: the operator's own address. Dashboard apex `example.com`
(A record already at the host; `www` CNAMEs to it). Still needed before 6.2:
A records for `traefik.example.com` and the project's own hostname
(proposed `gallery.example.com`), neither of which exists yet, and the
operator's go-ahead for Traefik to claim :80/:443 — after which the apex
returns a Traefik 404 instead of connection-refused, since it resolves here
and no router matches it.

**Watch out for:** Let's Encrypt rate limits on a brand-new setup — point
the resolver at the **staging** endpoint until the whole flow works, then
switch to production and re-issue once. Confirm DNS has propagated and
port 80 is reachable from outside *before* the first ACME attempt; failed
challenges count against limits too.

### 6.3 — Deploy, change, roll back (M)
First real deploy; then a trivial tagged change; then `rollback`. Measure
what the rig couldn't: `save|gzip|rsync|load` duration over a real uplink,
ACME issuance time, fragment reload latency in production Traefik.

**Deliverables**
- [ ] Three `versions.log` entries (deploy, deploy, rollback), all well-formed
- [ ] `kasbah history` / `pending` / `server status` correct against the real VPS
- [ ] Measurements recorded in Findings

**Settled:** version tags do not exist in gallery-website; this task creates
`v0.1.0`, a trivial change, and `v0.1.1` there, and commits 6.1's conformance
files to that repo. Approved as part of the run.

**Not exercised by this project:** gallery-website has no environment, so the
interactive env setup below never runs. That watch-out stays traced, not
proven, unless the project is deliberately given an env var.

**Watch out for:** the interactive env setup runs over `ssh -t` for real
for the first time — terminal quirks (masked input, section headers) that
the rig's clean TTY hid.

### 6.4 — Reconcile and record (S)
Walk `server-setup.md`, `build-deploy.md`, `traefik.md` against what
actually happened; fix contradictions. Findings here re-plan Phases 7–9.

**Deliverables**
- [ ] Doc diffs or an explicit "nothing contradicted"
- [ ] Findings written

## Findings

**Approved run (2026-08-22).** Full phase, in the order 6.0 → 6.1 → 6.2 → 6.3
→ 6.4. 6.0 is inserted: the plan assumed an ACME staging switch that does not
exist. 6.0 and 6.1 run against the rig while the VPS is provisioned; 6.2–6.4
wait on a throwaway OVH Ubuntu VPS plus two A records (`traefik.<apex>` and
the project's own hostname). Proof project: `gallery-website`. Verification
bar: `./test.sh` per task (baseline 20 PASS ~6m30s), full
`KASBAH_RIG_TESTS=1 ./test.sh` once at phase close (baseline 29 PASS ~16m);
iteration runs a single standalone suite. 6.0 and 6.1 are sequential, not
parallel — both own `/apps` on the rig. Rejected: `--acme-ca <url>` (no
private CA to serve, so a URL flag has no consumer). Out of scope, as the
plan states: mail (`--no-mail`, Phase 7) and backup (`--no-backup`, Phase 8).

**`server init --domain` is the dashboard apex, nothing else**
(`lib/server_init.sh:1413` → `traefik.<apex>`); `--email` is the server's one
Let's Encrypt account address. Project domains are per-project `domain:` keys
in `kasbah.yml`, routed by the fragment and certed at deploy.

**6.0, round 1 review — findings and dispositions.** Verdict needs-work; the
mechanism (ship → reset → restart ordering, archive-never-delete, the restart
guarantee, idempotence) passed and was executed for real against a scratch
directory, not just read.

- *The reset predicate asked about the config when the thing at risk is the
  store.* **Fixed.** An old-code server (no `caServer`, production certs) run
  with `--acme-staging` gave `reset=no`: a staging config shipped over a
  production store, restarting into "Traefik serves the old certs until
  renewal swaps them for untrusted ones" — silently, on the most common run
  the new code will ever see, with a test locking it in. The predicate is now
  keyed on the store: empty → never reset and never ask (so a fresh server
  stays silent); non-empty and the CA known-and-different → reset, decline
  aborts; non-empty and the CA **unrecorded** → confirm honestly, and a
  decline *proceeds with a warning* rather than aborting, because no flag
  avoids that question and refusing would wedge every server that predates
  `caServer`.
- *The confirmation named the wrong CA and its decline advice caused the loss
  it warned about* — `from`/`stay` derived from the target flag, so a
  hand-set third-party `caServer` was announced as the opposite Let's Encrypt
  endpoint and "re-run with `--acme-staging` to stay put" would have moved the
  operator to staging *and* reset the store. **Fixed:** the stored URL is
  quoted verbatim and only named when it matches one of kasbah's two literals.
- *Unparseable `traefik.yml` plus `--email=` collapsed "unknown CA" into
  "never had one".* **Fixed** by the same predicate; the two stay
  distinguishable in the confirm's wording, because the operator can act on
  the difference.
- *Two comments claimed the field records which CA **issued** what is in
  `acme.json`; it records which CA is **configured**.* **Fixed** — and the
  divergence between those two readings is exactly where the first finding
  lived.
- *Comment blocks past three lines.* **Rejected.** The rule was the
  orchestrator's briefing convention, not this repo's: `server_init.sh`'s
  established register is longer explanatory blocks, and matching the
  neighbours beats matching the brief.
- *`docs/cli.md` and `docs/overview.md` left behind.* **Fixed by the
  orchestrator**, not the implementer: the flag reference gained
  `--acme-staging` and `--yes` and a reconcile step in the numbered flow, and
  the Interactivity decision now admits a bare `--yes` where a prompt guards a
  destructive act with no third state to select.
- Taste, accepted: the CA decision hoisted above the domain/email/password
  branches, so a declined run no longer costs a bcrypt hash first.
  Taste, left alone: `--yes` is command-global but scoped to one confirmation,
  and the payload's "no store there yet" branch is unreachable from the CLI.

**6.0, round 2 — the fix round's own defects.** Both found by re-review, both
invisible to a passing suite.

- *"Declining proceeds, so nobody is stranded" was false without a TTY* — and
  the claim was in two docs and a code comment. The unknown-store question
  hard-failed naming `--yes`, and `--yes` selects the **destructive** branch,
  so the only scriptable answer archived a real production store and spent
  production rate-limit budget on a server that needed nothing. **Fixed by
  making the claim true:** the unknown-store question is a *choice*, not a
  confirmation, so it gets the pair this codebase gives every choice —
  `--reset-acme` / `--keep-acme` — while `--yes` keeps answering only the
  known-different confirmation, where the outcomes really are proceed-or-abort.
  `--yes` deliberately does **not** answer the choice: it means "I accept the
  destructive act I asked for", and a blanket `--yes` in a script cannot know
  which CA filled a store it did not create.
- *The `acme_store` producer had zero coverage, and the entire fix is keyed on
  it.* Mutation: replacing the remote four-state ladder with a flat
  `printf 'acme_store=empty'` produced **0 FAILs across the suite** — restoring
  the exact bug round 1 existed to close. The consumer half bit hard (removing
  the store gate or the unknown branch each cost 12 FAILs); the input to it was
  fabricated by the test driver. The lesson generalises past this task: a
  mutation that survives a green suite is the only honest evidence a test
  bites, and the half everyone tests is the half that reads the value.

Accepted cost, not fixed: with an unparseable `traefik.yml`, a non-empty store
and no `--email`, the operator answers the store question and *then* the run
dies at `_si_unreadable_stack`. One wasted question, nothing created — the tail
of hoisting the CA decision above the domain/email/auth branches, which is
worth more than the question is expensive.

**6.1 — six places the tool pinched on a project it was not extracted from.**
The task exists to find these, and it found them. Dispositions:

1. **S04 hard-fails a project with no environment**, exactly as predicted
   (`lib/check.sh:76-81`). A comment-only `.env.prod.example` does pass E01,
   E04 and E05 — `env_extract_keys` yields nothing, so E05 stays silent. The
   file is real; it just declares nothing. **Carried** (see below).
2. **A first deploy requires a terminal — and that is the design, not a
   defect.** Reported as a blocker, escalated by the orchestrator, and
   **rejected on the operator's challenge**: `docs/overview.md:143` says "No
   CI — deploys are triggered from the developer's laptop",
   `docs/overview.md:42` lists CI integration as out of scope, `docs/cli.md:451`
   says a non-interactive contract "would turn into every default silently
   accepted" and `:464` that `--on-drift=` is deliberately not a general
   headless escape — and `tests/integration/deploy_ship_test.sh:192` *asserts*
   exit 5 for "no `.env` and no terminal", then renders the env by running
   `setup-env.sh` itself. The behaviour is a tested contract.
   A fix was briefed, started, and reverted before review; the tree returned to
   `d2e2083` with nothing kept.
   What survives is narrower and not worth a special case: for a zero-key
   template the step has nothing to ask, but deciding that on the workstation
   means predicting what the generator will ask on the server — a second
   implementation of `lib/env.sh`'s logic, which is the duplication the repo
   warns about everywhere else.
   **The lesson is about the orchestrator, not the tool:** an agent reported a
   defect, the reproduction was real, and the premise behind it was never
   checked against the spec. "The tool refuses to do X" is only a defect once
   the docs say X is a goal. Here they said the opposite, twice, in a file the
   brief had already cited.
   Consequence for 6.3: the real deploy runs under a pty (`script -qec`),
   which is not a workaround — it is the developer's laptop the design targets.
3. **`init-project` scaffolds `DOMAIN=<domain>`** (`lib/init_project.sh:139-149`)
   into a template nothing reads — `nginx.conf` is `server_name _`, and the
   manifest's `domain:` plus the fragment are where the hostname is actually
   load-bearing. **Carried.** Note the interaction with 2: a scaffolded
   project's template is never empty, so every new project would have needed a
   terminal for its first deploy. The tool created the environment it then
   insisted on.
4. **Deploy creates `/apps/data/<project>/` and `/apps/<project>/backups/`
   unconditionally**, for a manifest with no volumes and no `backup:` block.
   Both stayed empty. Recorded, not fixed — cosmetic, but it is the "assumes
   persistent data" shape.
5. **`init-project`'s starter compose snippet is fixture-shaped**: it prints
   `networks: [kasbah-net, internal]` for the single service it scaffolds,
   teaching the two-service case as though it were the only one. **Carried.**
6. **For 6.3:** gallery-website has no `origin` remote, so `build-push` warns
   and the version tag stays on the workstation — which is the correct
   direction. And `kasbah.yml` carries `kasbah_version: 0.1.0-dev`, a `-dev`
   string that will land in the project's committed history.

1, 3 and 5 are one decision wearing three hats — **kasbah assumes every
project has an environment** — and it is carried to Phase 7 whole rather than
split, because answering it in pieces produces three inconsistent answers.

**Rehearsal timings on the rig, the local baseline the real VPS is measured
against:** `build-push` **5.44 s** warm (`docker save | gzip` 2.85 s → 24.0 MB
from a 59.1 MB image, rsync 0.44 s on loopback, `docker load` 1.24 s);
`deploy` **7.55 s**; `server init` on a clean rig **8 s**. Neither ACME
question fired on the rig — empty store, so 6.0 stayed silent exactly as
designed.

**6.1 review — the kasbah files were sound; the prose around them was not.**
Three defects, all fixed in the project's commit: the README still told a
reader to create `compose.prod.yml` and fill it with "reverse-proxy labels",
which T06 **hard-fails** (the docker provider is not wired in) — the change
created the file and left the instructions pointing at the one thing the tool
rejects; `docs/architecture.md` drifted the same way; a comment claimed
`compose.prod.yml` was "the only file kasbah reads" when kasbah also reads
`kasbah.yml`, `.env.prod.example` and the fragment; and the healthcheck's
placement was justified by a reason that does not hold (a Dockerfile
`HEALTHCHECK` is a Docker convention, not a kasbah one). The placement stands
— in compose, where `kasbah check` can see it — but the comment now states the
real tradeoff, which `compliance.md` H01 already spells out: the Dockerfile is
the better place because the check travels inside the image, and a project that
does it there warns forever, correctly.

**A latent collision worth knowing about, and the fixture teaches it.**
gallery-website's routed service is named `web`, so it claims the bare `web`
DNS alias on the shared `kasbah-net` — measured on a throwaway project:
`aliases=[gbrev-web web]`. Harmless here (Traefik resolves `container_name`,
which is unique per host, and this container resolves nothing itself), but
`tests/fixtures/built-app/compose.prod.yml:14` also puts a service called `web`
on `kasbah-net`. On a host running both, a third project resolving bare `web`
round-robins between them. No network topology fixes it — only naming does.
**Carried to Phase 7.**

**6.2 — first contact with real infrastructure. It worked on the first
attempt.** `kasbah server init you@vps --domain=example.com
--email=… --traefik-auth=… --acme-staging --no-mail --no-backup`, stdin
closed: **exit 0 in 20.4 s**, image pull included. Limits computed from the
real host: `cpu 1.8, mem 3g` (90% of 2 cores, 3906320 kB). `/apps` created
with sudo, `acme.json` touched as a file at mode 600, marker and
`/etc/kasbah/apps-path` written.

**Measured ACME, which the rig cannot fake** — from Traefik's own log, staging
endpoint, HTTP-01:

| | |
|---|---|
| Provider start → account registered | 1 s |
| Registered → challenge validated | 5 s |
| Validated → certificate in hand | 3 s |
| **Total issuance** | **10 s** |

`acme.json` went from 0 to 16256 bytes, so the production switch will take the
*known-and-different* branch and needs `--yes` under a closed stdin — the first
real exercise of what 6.0 built.

One number that looks wrong and is not: the certificate's `notBefore` is
22:58:57 GMT while the issuing log line reads 23:57:29Z. Let's Encrypt
backdates `notBefore` by roughly an hour to tolerate clock skew; the two agree.

**The dashboard answers HTTPS only — plain HTTP is a 404, not a redirect.**
`_shared.yml`'s `traefik-dashboard` router lists `websecure` alone, and the
`http-to-https` middleware sitting three lines above it is offered to project
fragments rather than used by kasbah's own router. Deliverable met (HTTPS
works), but kasbah preaches a redirect pattern its own dashboard does not
follow. **Carried to Phase 7** rather than fixed here: whether an admin
dashboard *should* redirect from plaintext or stay HTTPS-only is a decision,
not an oversight, and Phase 7 owns the dashboard surface.

Also observed, and expected: `example.com` itself now returns a Traefik 404
where it used to refuse the connection, because the apex resolves to this host
and no router matches it.

**The `httpd:2-alpine` container is the path, not the fallback** — operator
feedback, and a doc defect rather than a code one. `_si_bcrypt` prefers
`htpasswd` and reaches for Docker only if it is absent, which the docs
described as a fallback; but `htpasswd` ships in `apache2-utils` /
`httpd-tools`, which few workstations install — this one does not — so the
container is what almost every run uses. The consequence the docs never drew:
**Docker on the workstation is a real prerequisite of `server init`**, not
just of `build-push`. `docs/cli.md` and a new "On the workstation" section in
`docs/server-setup.md` now say so. While there, `env-template.md`'s suggested
password-generator snippet used `htpasswd -nbB user "$P"` — argv, where the
process table exposes the password — contradicting the reasoning in
`_si_bcrypt`'s own comment eight lines above the code; it now pipes to `-niB`.

**`docker restart` re-resolves a file bind mount** — measured with a throwaway
alpine container and a host-side `mv`+recreate: the container sees the old
inode before the restart and the new one after. That is the whole reason
archive-by-rename is safe here, and it is why the reset refuses to run unless
a restart is already queued behind it.

_(filled during execution — staging→production ACME switch notes, real
timings, TTY quirks, and every place the tool pinched on a real project)_
