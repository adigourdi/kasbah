# Phase 9 — Adopt

> Both existing consumers run on hosting: the original project has no `scripts/`
> folder and deploys (mail included) through hosting on its live VPS, and
> the lab RPi runs its stacks as independent hosting projects with the
> root-compose + single-.env model retired.

**Prerequisite:** Phase 8 (drop/backup wanted before touching live
services; the original project's mail migration uses Phase 7's `--with-mail` path).
**Lightest spec — re-read mandatory; the lab cert question below gates
its half.** Both halves touch live production — checklist-first, same
discipline throughout.

**Spec:** `docs/roadmap.md` (both Phase-1 and Phase-2 exit criteria land here), `docs/mail.md`, `docs/traefik.md`, the homelab repo's `CLAUDE.md` (the model being replaced)

## Part A — the original project

### 9.1 — Conformance, locally (M)
`hosting.yml` per the `docs/project-manifest.md` full example (it was
modeled on the original project — hooks, backup, and now the `mail:` claim). Rework
`compose.prod.yml`: network split (only nginx routed; php-fpm/postgres
internal), `HOSTING_*` limits, `container_name`s. Convert
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
old label-based Traefik for the hosting-managed one in a single scripted
SSH session (seconds of downtime, chosen hour), drop the fragment in,
verify serving. Keep the old traefik compose until 48h clean.

**Watch out for:** both Traefiks binding 80/443 — stop-old-then-start-new
must be one script, not two commands typed by hand. And `acme.json` perms
(600, deploy user) — Traefik silently starts fresh on an unreadable file
and burns rate limits.

### 9.3 — Mail migration + scripts deletion (M)
Move the mail stack under hosting (`--with-mail`, domain claims, DMS data
bind mounts moved — **never regenerate DKIM keys**; DNS holds the
pubkey). Then delete the original project's `scripts/` folder, tag a trivial change,
deploy to production through hosting alone. This is the roadmap's
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
host-network services (Home Assistant) bypass `hosting-net` assumptions —
HA may be a legitimate documented exception rather than a forced fit.

### 9.7 — Retire the old models (S)
lab: delete `setup.sh`, root `compose.yml`, numbered dynamic configs;
README documents the hosting workflow. The original project: remove any leftover
deploy tooling 9.3 missed.

## Exit criteria
- [ ] The original project deploys (site + mail) through hosting on its live VPS; `scripts/` gone; site and mailflow verified
- [ ] Every lab stack runs as an independent `/apps/<name>` project on the RPi; single root `.env` decomposed per project
- [ ] Both old models retired from their repos
- [ ] One full drill on the RPi: `drop` a stack, redeploy, data intact

## Findings

_(filled during execution — the 9.2 cutover checklist goes here BEFORE
executing; then the cert decision, the inventory table, and which lab
conventions were worth folding back into hosting's docs)_
