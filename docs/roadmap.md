# Roadmap

## Phase 1 — v0.1 (Bash MVP)

Goal: Replicate the original project's deploy workflow as a generalized tool, and add
the multi-project layer.

### 1.1 Foundation
- Repo skeleton: `bin/kasbah`, `lib/*.sh`, `templates/`, `tests/`
- Global install: `./install.sh` copies `bin/` to `~/.local/bin`, `lib/`
  to `~/.local/share/kasbah/`
- Self-version: `kasbah --version` reports from a committed
  `VERSION` file
- Manifest parsing: yq-based reader with schema-version check
- `.kasbah/state.json` read/write

### 1.2 Server setup
- `kasbah server init user@host`
  - Docker/Compose preflight
  - Folder layout (`/apps/`, `/apps/data/`, `/apps/backups/`)
  - `acme.json` touched as file
  - Traefik compose + config templates
  - Interactive `.env` setup for projects (Traefik itself needs none — it interpolates nothing)
  - Health wait
- Server marker `/apps/.kasbah/server.json` + resource-limit
  computation (90% of host cores/RAM)
- `kasbah server status user@host`

### 1.3 Env template
- Port `setup-env.sh` verbatim to `lib/env.sh`
- Port `test-setup-env.sh` to `tests/env_test.sh`
- Drift detection function reused by `deploy` and `env` commands

### 1.4 Project lifecycle
- `kasbah init-project` — scaffold manifest + env skeleton (compose is user-authored)
- `kasbah check` — structural rules (S, C, T, H, E, HK)
- `kasbah check` rework: network split rules (C03/C07, T07) +
  resource rules (R01–R03; R04 belongs to `check --server`)
- `kasbah build-push user@host` — no-op when compose has zero `build:` services
- `kasbah deploy user@host` (working tree) + `kasbah deploy user@host X.Y.Z` (git archive)
- `kasbah rollback user@host [version]` — git-archive flow; target image must be within the VPS retention window
- `kasbah history / changelog / pending`

### 1.5 Docs
- README.md with install + first-project walkthrough
- All docs/*.md under this directory

**Exit criteria:** the original project can replace its `scripts/` folder with a
one-line `kasbah.yml` and deploy identically.

## Phase 2 — v0.2 (Mail + polish)

- `kasbah server init --with-mail` (DMS + SnappyMail, ported from the original project)
- `kasbah server add-mail-domain <domain>` — multi-domain support
- Mail claim reconciliation on deploy
- `kasbah server mail-setup-guide` — printed walkthrough
- `kasbah check --server user@host` — VPS-aware checks
- `kasbah logs user@host [service]` / `kasbah exec`
- `kasbah server upgrade-traefik` — version bump with backup-before-overwrite
  and a dry run of every dynamic fragment against the target version
- `kasbah server prune` — image retention (keep the last 3 deployed
  versions including current, plus anything < 3 months)

**Exit criteria:** the original project's mail stack migrated to kasbah; at least one
other project (e.g. a jellyfin stock, a second custom app) deployed
successfully.

## Phase 3 — v0.3 (Quality of life)

- Backups retention rotation
- `kasbah check --fix` for C01–C05, C08, R01–R03 and the `kasbah_version`
  backfill ✅
- Dashboard-optional Traefik template
- `kasbah drop [--prune]` — remove a project; `--prune` also deletes
  data + backups (double confirmation) ✅
- `kasbah server destroy` — de-brand a VPS for handover; containers
  keep running (double confirmation) ✅
- Off-VPS backups: `server init --with-backup` — restic → any restic backend,
  append-only creds, per-client repos (see `backup.md`) ✅

## Phase 4 — v1.0 (Go rewrite preparation)

> **Superseded by build-plan Phase 10 (`docs/phases/10-recast.md`), ruled
> 2026-10-18; this section and the next are rewritten at its cutover (10.14).**
> The file inventory lands first (10.2), the schema freezes at the Go cutover
> (v1.0.0), and `kasbah migrate` waits for the first format change that has
> users. The Go binary also runs on the VPS, and is built locally — no GitHub
> releases until publishing is decided.

Where the `kasbah_version` field starts earning its keep.

- Define the migration story: v0.x → v1.0 may rename/move files in the
  project source tree. Tool: `kasbah migrate` (still bash).
- Freeze the manifest schema — after v1.0, changes go through an
  explicit migration.
- Document every file kasbah writes (project + VPS) so a Go rewrite
  knows what's under management.

## Phase 5 — v1.x (Go binary)

- Go re-implementation of the CLI
- Single statically-linked binary distributed via GitHub releases
- Same manifest schema
- `kasbah --version` reports both tool version and schema version
- Auto-detect older projects (`kasbah_version < installed_version`)
  and offer to migrate:

  ```
  $ kasbah deploy user@vps
  Warning: project was last touched by kasbah 0.3.0; you have 1.0.0.
           Run `kasbah migrate` to update project files.
  ```

- Migration of VPS state is opt-in and reversible (because the VPS
  might still be talked to by another dev on an older version).

### Go vs Bash — what each is good at

Bash wins:
- Always available on every VPS.
- Env template parsing is inherently line-oriented.
- Short scripts are easier to audit than a compiled binary.

Go wins:
- Structured error handling.
- YAML/JSON parsing without `yq`/`jq`.
- Concurrency for multi-VPS operations (roadmap: deploy to N servers).
- Static binary → no runtime surprises on developer laptops.

The cutover point is when `kasbah` does enough (multi-VPS, more hooks,
templates) that bash maintainability starts to hurt. Current estimate:
around Phase 3.

## Backlog (unphased, low priority)

- Uptime monitoring: a Gatus stack on a separate operator VPS, its endpoint
  config generated from project manifests (`kasbah monitor sync`).
  Config-file-driven on purpose — same philosophy as the Traefik fragments.
  Deliberately deprioritized.

## Non-goals (staying out of scope)

- Private registry management (no Harbor/Zot/Distribution).
- Web UI for kasbah.
- Multi-user access control on a VPS.
- Support for Swarm / Kubernetes.
- Automated DNS management (no Cloudflare API integration).
- One-project-to-many-servers deploys — each project targets exactly one
  VPS. A fleet is many projects × many VPSes, which per-project `user@host`
  targeting already covers.

## Open questions (to revisit)

- Should the VPS state be mirrored into a git repo owned by kasbah?
  (Audit trail, but adds complexity.)
- Should there be a `kasbah secrets` command distinct from `kasbah env`
  for values that rotate (API keys)? For now, env template handles both.
