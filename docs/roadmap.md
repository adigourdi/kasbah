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
- Manifest parsing: a YAML reader with schema-version check
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

- `kasbah server init --with-mail` (DMS ported from the original project, Cypht webmail)
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

## Phase 4 — v1.0 (Go) ✅

Built as build-plan Phase 10 (`docs/phases/10-recast.md`).

- Go re-implementation of the whole CLI, on the workstation **and** the VPS: the
  server side is the same binary, shipped to `<apps>/.kasbah/bin/kasbah` when the
  server's is absent or older ✅
- Single statically linked binary per platform, built locally by `install.sh`
  (workstation, linux/amd64, linux/arm64) ✅
- Every file kasbah writes documented (`files.md`) and held to that list by a rig
  suite ✅
- Manifest schema frozen at 1.0.0; `kasbah --version` reports tool and schema ✅

## Phase 5 — v1.x

- `kasbah migrate` and `kasbah migrate server` exist (`cli.md`); the real
  steps are written with the first schema change.
- Release distribution: GitHub Releases, cut by `release.sh` (`overview.md`
  → Distribution). Done.
- Concurrency for multi-VPS operations (deploy to N servers).

## Backlog (unphased, low priority)

- Uptime monitoring: a Gatus stack on a separate operator VPS, its endpoint
  config generated from project manifests (`kasbah monitor sync`).
  Config-file-driven on purpose — same philosophy as the Traefik fragments.
  Deliberately deprioritized.

## Non-goals (staying out of scope)

- Private registry management (no Harbor/Zot/Distribution).
- Web UI for kasbah.
- Multi-user access control on a VPS. Several operators share one server as
  one trust domain, the `kasbah` group (`server-setup.md` → Operators); no
  per-project permissions.
- Support for Swarm / Kubernetes.
- Automated DNS management (no Cloudflare API integration).
- One-project-to-many-servers deploys — each project targets exactly one
  VPS. A fleet is many projects × many VPSes, which per-project `user@host`
  targeting already covers.

## Open questions (to revisit)

- Should the VPS state be mirrored into a git repo owned by kasbah?
  (Audit trail, but adds complexity.)
