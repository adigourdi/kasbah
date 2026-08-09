# Phase 6 — Proof  ← the real milestone

> A real project — deliberately not named in this plan — runs on a freshly
> provisioned VPS through hosting alone: from bare server to HTTPS with a
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
- [ ] A fresh VPS goes from bare Docker host to serving the project over HTTPS (valid LE cert) using only hosting commands
- [ ] A second deploy of a trivial change lands end to end (tag → build-push → deploy → hooks → live)
- [ ] A rollback on the real VPS restores the prior version (the Phase 5 drill, repeated on real infra)
- [ ] Docs reconciled: everything reality contradicted is fixed in `docs/` now

## Tasks

### 6.1 — Project conformance, locally (M)
`init-project` in the chosen project, compose in the new pattern (network
split, `HOSTING_*` limits, `container_name`s, logging), fragment, env
template. `hosting check` clean, then a full rehearsal deploy to the rig
— hooks and all, if the project has them.

**Deliverables**
- [ ] `hosting check` exits 0 in the project
- [ ] Rehearsal deploy on the rig serves the project via fragment routing

**Watch out for:** this is the first non-fixture project — expect the
manifest or check rules to pinch somewhere the fixtures didn't. A pinch
here is a finding about the *tool*, not the project; record it before
working around it.

### 6.2 — Fresh VPS + `server init` (M)
Provision the VPS, point the project's DNS at it, `server init` with a
real domain and email (`--no-mail --no-backup` — those are Phases 7/8).
Verify Traefik health and dashboard auth over the real network.

**Deliverables**
- [ ] Init from a clean SSH session, no manual server prep beyond Docker
- [ ] Dashboard reachable over HTTPS at `traefik.<domain>`

**Watch out for:** Let's Encrypt rate limits on a brand-new setup — point
the resolver at the **staging** endpoint until the whole flow works, then
switch to production and re-issue once. Confirm DNS has propagated and
port 80 is reachable from outside *before* the first ACME attempt; failed
challenges count against limits too.

### 6.3 — Deploy, change, roll back (M)
First real deploy; then a trivial tagged change; then `rollback`. Measure
what the rig couldn't: `save|gzip|scp|load` duration over a real uplink,
ACME issuance time, fragment reload latency in production Traefik.

**Deliverables**
- [ ] Three `versions.log` entries (deploy, deploy, rollback), all well-formed
- [ ] `hosting history` / `pending` / `server status` correct against the real VPS
- [ ] Measurements recorded in Findings

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

_(filled during execution — staging→production ACME switch notes, real
timings, TTY quirks, and every place the tool pinched on a real project)_
