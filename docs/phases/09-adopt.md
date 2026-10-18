# Phase 9 — Adopt

> Both existing consumers run on kasbah: the original project has no `scripts/`
> folder and deploys (mail included) through kasbah on its live VPS, and
> the lab RPi runs its stacks as independent kasbah projects with the
> root-compose + single-.env model retired.

**Prerequisite:** Phase 10 — the Go port runs first, so both consumers
migrate onto the binary they will keep (ruled 2026-10-18) — and through it
Phase 8 (drop/backup wanted before touching live services; the original project's mail
migration uses Phase 7's `--with-mail` path).
**Lightest spec — re-read mandatory; the lab cert question below gates
its half.** Both halves touch live production — checklist-first, same
discipline throughout.

**Spec:** `docs/roadmap.md` (both Phase-1 and Phase-2 exit criteria land here), `docs/mail.md`, `docs/traefik.md`, the homelab repo's `CLAUDE.md` (the model being replaced)

## Carried in from Phase 10

**The `linux/arm64` server binary has never run.** Phase 10 builds and
unit-tests it, but the rig and `vps` are both x86_64; 9.5 is its first real
execution, and Phase 10's last exit criterion stays unticked until it passes.

## Carried in from Phase 6

**9.2's cert reuse is what the ACME store choice was built for — use
`--keep-acme`.** Phase 6 added a certificate-store reconciliation to
`server init`: when the store has content and nothing records which CA issued
it, init asks, and `--reset-acme` / `--keep-acme` answer without a terminal.
At the time it looked like insurance for a population of zero. 9.2 is the
consumer.

The shape matches exactly. You copy the original project's existing `acme.json` — real
production certificates — into `/apps/data/traefik/letsencrypt/` on a server
kasbah has never initialised, so there is no `traefik.yml` for init to read a
`caServer` out of. That is `store=nonempty` + `ca_origin=nocontent`: the
unknown-store question, whose wrong answer archives live certificates and
forces a re-issue during a cutover, against Let's Encrypt's rate limits, on a
production domain.

**Pass `--keep-acme`.** It proceeds, records the endpoint, warns that the
store's provenance is unknown, and touches nothing. Do **not** pass `--yes`
hoping it covers the question — it deliberately does not answer this one, for
this reason. And copy the store in *before* `server init`, not after: init
seeing an empty store stays silent, which leaves the reuse unverified at the
one moment kasbah could have confirmed it.

## Part A — the original project

### 9.1 — Conformance, locally (M)
`kasbah.yml` per the `docs/project-manifest.md` full example (it was
modeled on the original project — hooks, backup, and now the `mail:` claim). Rework
`compose.prod.yml`: network split (only nginx routed; php-fpm/postgres
internal), `KASBAH_*` limits, `container_name`s. Convert
`traefik/dynamic.yml` into a project fragment. `check` clean; full
rehearsal on the rig with the real hooks firing.

**Watch out for:** the app reaching `postgres` by service name — after
the network split, verify Laravel's `DB_HOST` matches a name on the
internal network. This is C07's bug class; don't reintroduce it via a
config literal.

### 9.2 — Live VPS cutover (M)
The risky task. Write the checklist into Findings **before** executing:
`server init` onto the live VPS (layout already `/apps`), **reuse the
existing `acme.json`** into `/apps/data/traefik/letsencrypt/` before the
new Traefik starts (LE rate limits — never discard issued certs), swap
old label-based Traefik for the kasbah-managed one in a single scripted
SSH session (seconds of downtime, chosen hour), drop the fragment in,
verify serving. Keep the old traefik compose until 48h clean.

**Watch out for:** both Traefiks binding 80/443 — stop-old-then-start-new
must be one script, not two commands typed by hand. And `acme.json` perms
(600, deploy user) — Traefik silently starts fresh on an unreadable file
and burns rate limits.

### 9.3 — Mail migration + scripts deletion (M)
Move the mail stack under kasbah (`--with-mail`, domain claims, DMS data
bind mounts moved — **never regenerate DKIM keys**; DNS holds the
pubkey). Then delete the original project's `scripts/` folder, tag a trivial change,
deploy to production through kasbah alone. This is the roadmap's
original exit criterion, landed.

**Watch out for:** mailflow verification needs real SMTP round-trips
(send + receive on the migrated stack) before the old mail compose is
removed — a wrong bind-mount path here loses mailboxes silently.

## Part B — lab

### Open question (answer before 9.4)
**Cert strategy on a LAN host.** lab serves `*.lan.example.com` behind
NAT; HTTP-01 can't reach it. Options: DNS-01 (needs a provider hook —
currently a stated non-goal), a wildcard cert issued elsewhere and
synced, or an internal CA. Decides whether the Traefik template needs a
resolver variant; gates every lab task.

### 9.4 — Conversion inventory (S)
Per stack: services, bind mounts (CONFIG_DIR/STORAGE_DIR → per-project
mapping or in-place), routed container, env keys consumed. Output: a
table in Findings driving 9.6.

### 9.5 — RPi `server init` (S)
arm64, real hardware, `--apps-path` to fit the `/lab` layout.

**Watch out for:** shared media dirs (`movies/`, `series/`) are shared
across projects *by design* — keep them as absolute bind paths outside
the per-project `data/` model rather than forcing moves.

### 9.6 — Stack-by-stack migration (L)
Jellyfin first (most used, easiest rollback), then the rest, one at a
time: per-stack project dir + repo, compose rework (arm64 images, network
split, limits), fragment, env template, deploy, verify, remove from the
old root compose. Old traefik last, same choreography as 9.2.

**Watch out for:** hardware devices (`/dev/dri` transcode) and
host-network services (Home Assistant) bypass `kasbah-net` assumptions —
HA may be a legitimate documented exception rather than a forced fit.

### 9.7 — Retire the old models (S)
lab: delete `setup.sh`, root `compose.yml`, numbered dynamic configs;
README documents the kasbah workflow. The original project: remove any leftover
deploy tooling 9.3 missed.

## Exit criteria
- [ ] The original project deploys (site + mail) through kasbah on its live VPS; `scripts/` gone; site and mailflow verified
- [ ] Every lab stack runs as an independent `/apps/<name>` project on the RPi; single root `.env` decomposed per project
- [ ] Both old models retired from their repos
- [ ] One full drill on the RPi: `drop` a stack, redeploy, data intact

## Findings

_(filled during execution — the 9.2 cutover checklist goes here BEFORE
executing; then the cert decision, the inventory table, and which lab
conventions were worth folding back into kasbah's docs)_
