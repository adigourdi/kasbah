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

## Tasks

### 7.1 — Mail stack port (L)
`server init --with-mail` / `add-mail-domain` / `_mail.yml` cert-trigger
fragment, ported from the original project's `mail/`. Deploy-time claim
reconciliation replaces the Phase 4 stub. SnappyMail domain pre-seed
copy-if-missing. Live mail migration (the original project's) is deliberately NOT
here — it happens with its owner's migration in Phase 9.3.

**Watch out for:** SMTP won't route from the rig, but container wiring,
claim checks, and seeding all can — test those with a throwaway domain
and mark deliverability "traced, not proven" until 9.3.

### 7.2 — `logs` / `exec` (S) [parallel-safe]
Thin wrappers per `cli.md`, including the `--` argument rule for exec.

### 7.3 — `check --server` + R04 (M)
The VPS-aware checks from `compliance.md`: project dir, env drift, mail
domain, health, cert status from `acme.json`, and R04 (effective limits
vs host 90%: above fails, below warns).

**Watch out for:** reading `acme.json` needs the deploy user's perms and
must never write; parse defensively — its schema shifts between Traefik
versions.

### 7.4 — `server prune` (M)
The retention policy, exactly as `build-deploy.md` states it: remove
`:<version>` tags older than 3 months AND not among the last 3 deployed
(the `:current` target counts as first). Show the removal list, ask once
(tri-state: `--yes` for scripts).

**Watch out for:** "last 3 deployed" comes from `versions.log` per
project, not from tag mtimes — a re-tagged image lies about its age.

### 7.5 — `upgrade-traefik` (M)
Version bump with backup-before-overwrite of kasbah-owned files, plus
the dry-run: boot a throwaway Traefik of the target version with the
dynamic dir mounted read-only and fail the upgrade on config errors in
its log.

**Watch out for:** only `_`-prefixed files are kasbah's to overwrite —
user-customized `traefik.yml` gets a diff + confirm, not a silent
replace (`traefik.md` § Ownership).

## Carried in from Phase 6

*(The dashboard-redirect question that opened this section was settled and
implemented at the Phase 6 close — see `06-proof.md` → Findings.)*

**Should `check` warn on a generic service name on `kasbah-net`?** Compose
registers the service name as a DNS alias on *every* attached network, which is
the stated reason projects keep non-routed services off the shared net (C03/C07)
— but the routed service keeps its alias there too, and nothing warns.
Measured: a service named `web` yields `aliases=[<project>-web web]` on the
shared network. Two projects both naming their routed service `web` (the
`built-app` fixture does, and so does the first real project) put two claimants
on one alias; a third project resolving bare `web` round-robins between them.
Nothing routes through it today — Traefik targets `container_name`, unique per
host — so this is latent, and the fix is naming, not topology. Either a warn-level
rule on a short list of generic names (`web`, `app`, `api`, `db`, `cache`), or a
line in `compliance.md` saying the alias is knowingly left unguarded. Evidence in
`06-proof.md` → Findings.

## Carried in from Phase 2

`kasbah server status` exists in minimal form (`lib/server_status.sh`):
docker/compose versions, the marker, Traefik's state/health/image, and each
project's last `versions.log` entry. Phase 7 owns the rest, and two items
need a decision rather than just implementation:

- **The per-project domain.** `cli.md` promised it and it is not printed. It
  lives in `<apps>/traefik/dynamic/<name>.yml`, so it costs either a YAML
  parse on a server where `yq` is not a prerequisite, or a Traefik API call
  with the dashboard credentials. Pick one deliberately — the credentials
  route also gives certs and router health in the same call, which may make
  it the cheaper answer overall.
- **Cert status, disk usage, mail, per-container health.** Straightforward,
  but they are what turns status from one batched SSH round trip into
  several. Keep the single-round-trip protocol shape that `server_init` and
  `status` both use; it is what keeps the rig's `maxstartups 10` from
  biting.

Also: every command now resolves the apps path through `/etc/kasbah/apps-path` (Phase 4 closed the carry); `status` keeps `--apps-path` as the escape hatch for a server whose pointer is gone.
If Phase 4 puts the apps path in `.kasbah/state.json`, `status` should read
it too rather than keeping two mechanisms.

## Findings

_(filled during execution)_
