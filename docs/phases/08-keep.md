# Phase 8 — Keep

> Projects can be removed safely at every scope, VPSes can be handed over,
> and everything that exists only on a VPS also exists off it.

**Prerequisite:** Phase 7 (destroy touches mail creds; backup scope
includes mail data). **Lighter spec — re-read before starting.**
**Spec:** `docs/backup.md` (whole file), `docs/cli.md` (drop, server destroy), `docs/server-setup.md` (Handover / teardown), `docs/compliance.md` (`--fix`)

## Exit criteria
- [ ] Rig: deploy → `drop` → redeploy resurrects fully (data intact); `drop --prune` leaves no trace under `/apps/<name>` or `/apps/data/<name>`
- [ ] Rig: `server destroy` → every container still serving, no `kasbah.yml` / `versions.log` / helpers / marker / backup creds remain
- [ ] A restic snapshot from the rig restores onto a **fresh** rig and the project comes back (the restore drill from `backup.md`, executed once for real)
- [ ] `check --fix` applies C01–C05 + R01–R03 with a diff shown first, and never touches anything else

## Tasks

### 8.1 — `drop [--prune]` (M)
Per `cli.md`: down, fragment removed, all project images removed; keeps
config/data/backups. `--prune` deletes those too. Double confirmation
(typed project name); `--yes` for scripts.

**Watch out for:** image removal must not touch tags shared with other
projects (stock images like `postgres:16` are shared — remove only tags
matching this project's built images, plus project-specific pulls only if
unreferenced).

### 8.2 — `server destroy` (M)
Full de-branding per `server-setup.md`: marker, backup cron + creds,
per-project kasbah.yml/versions.log/helpers. Containers and Traefik keep
running. Typed-hostname confirmation.

**Watch out for:** verify serving *after* each removal step on the rig —
the point is proving de-branding is non-disruptive, so the test asserts
uptime through the whole operation.

### 8.3 — `--with-backup`: restic push (L)
Per `backup.md`: install restic, append-only S3 credentials, daily cron
with jitter, repo per `client:` (default `name`), scope = data + backups
+ `.env`. Operator-side prune command with full creds. Rig tests target a
MinIO container as the S3 endpoint.

**Watch out for:** append-only enforcement is credential-side (bucket
policy / restic rest-server append-only), not a restic flag on the VPS —
the rig test must *prove* the VPS creds cannot delete (attempt a delete,
assert failure), or the whole security property is decorative.

### 8.4 — `check --fix` (M)
Auto-fixes per `compliance.md`: C01–C05, R01–R03, `kasbah_version`
backfill. Diff before writing; only `compose.prod.yml` and `kasbah.yml`
are ever touched.

**Watch out for:** yq round-trips reorder YAML and drop comments — fix
with targeted edits (or yq in-place only on files it already formats),
and assert comment survival in the test, since compose files carry
load-bearing comments in real projects.

## Findings

_(filled during execution)_
