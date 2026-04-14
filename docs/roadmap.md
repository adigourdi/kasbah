# Roadmap

## Phase 1 — v0.1 (Bash MVP)

Goal: Replicate the original project's deploy workflow as a generalized tool, and add
the multi-project layer.

### 1.1 Foundation
- [ ] Repo skeleton: `bin/hosting`, `lib/*.sh`, `templates/`, `tests/`
- [ ] Global install: `./install.sh` copies `bin/` to `~/.local/bin`, `lib/`
  to `~/.local/share/hosting/`
- [ ] Self-version: `hosting --version` reports from a committed
  `VERSION` file
- [ ] Manifest parsing: yq-based reader with schema-version check
- [ ] `.hosting/state.json` read/write

### 1.2 Server setup
- [ ] `hosting server init user@host`
  - Docker/Compose preflight
  - Folder layout (`/apps/`, `/apps/data/`, `/apps/backups/`)
  - `acme.json` touched as file
  - Traefik compose + config templates
  - Interactive `.env` setup for Traefik
  - Health wait
- [ ] `hosting server status user@host`

### 1.3 Env template
- [ ] Port `setup-env.sh` verbatim to `lib/env.sh`
- [ ] Port `test-setup-env.sh` to `tests/env_test.sh`
- [ ] Drift detection function reused by `deploy` and `env` commands

### 1.4 Project lifecycle
- [ ] `hosting init-project` — scaffold manifest + env skeleton (compose is user-authored)
- [ ] `hosting check` — structural rules (S, C, T, H, E, HK)
- [ ] `hosting build-push user@host` — no-op when compose has zero `build:` services
- [ ] `hosting deploy user@host` (working tree) + `hosting deploy user@host X.Y.Z` (git archive)
- [ ] `hosting rollback user@host [version]` — git-archive flow, auto-reship images from local if pruned on VPS
- [ ] `hosting history / changelog / pending`

### 1.5 Docs
- [ ] README.md with install + first-project walkthrough
- [ ] All docs/*.md under this directory

**Exit criteria:** the original project can replace its `scripts/` folder with a
one-line `hosting.yml` and deploy identically.

## Phase 2 — v0.2 (Mail + polish)

- [ ] `hosting server init --with-mail` (DMS + SnappyMail, ported from the original project)
- [ ] `hosting server add-mail-domain <domain>` — multi-domain support
- [ ] Mail claim reconciliation on deploy
- [ ] `hosting server mail-setup-guide` — printed walkthrough
- [ ] `hosting check --server user@host` — VPS-aware checks
- [ ] `hosting logs user@host [service]` / `hosting exec`
- [ ] `hosting server upgrade-traefik`

**Exit criteria:** the original project's mail stack migrated to hosting; at least one
other project (e.g. a jellyfin stock, a second custom app) deployed
successfully.

## Phase 3 — v0.3 (Quality of life)

- [ ] Backups retention rotation
- [ ] `hosting check --fix` for C01-C05
- [ ] Dashboard-optional Traefik template
- [ ] Project removal: `hosting destroy` (with double confirmation)

## Phase 4 — v1.0 (Go rewrite preparation)

Where the `hosting_version` field starts earning its keep.

- [ ] Define the migration story: v0.x → v1.0 may rename/move files in the
  project source tree. Tool: `hosting migrate` (still bash).
- [ ] Freeze the manifest schema — after v1.0, changes go through an
  explicit migration.
- [ ] Document every file hosting writes (project + VPS) so a Go rewrite
  knows what's under management.

## Phase 5 — v1.x (Go binary)

- [ ] Go re-implementation of the CLI
- [ ] Single statically-linked binary distributed via GitHub releases
- [ ] Same manifest schema
- [ ] `hosting --version` reports both tool version and schema version
- [ ] Auto-detect older projects (`hosting_version < installed_version`)
  and offer to migrate:

  ```
  $ hosting deploy user@vps
  Warning: project was last touched by hosting 0.3.0; you have 1.0.0.
           Run `hosting migrate` to update project files.
  ```

- [ ] Migration of VPS state is opt-in and reversible (because the VPS
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

The cutover point is when `hosting` does enough (multi-VPS, more hooks,
templates) that bash maintainability starts to hurt. Current estimate:
around Phase 3.

## Non-goals (staying out of scope)

- Private registry management (no Harbor/Zot/Distribution).
- Web UI for hosting.
- Multi-user access control on a VPS.
- Support for Swarm / Kubernetes.
- Automated DNS management (no Cloudflare API integration).
- Cross-cloud deploys — hosting targets single VPS, period.

## Open questions (to revisit)

- Should `hosting deploy` support deploying to multiple VPS in one command?
  (Roadmap says phase 5, but worth a design note before Go.)
- Should the VPS state be mirrored into a git repo owned by hosting?
  (Audit trail, but adds complexity.)
- Should there be a `hosting secrets` command distinct from `hosting env`
  for values that rotate (API keys)? For now, env template handles both.
