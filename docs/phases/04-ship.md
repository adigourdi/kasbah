# Phase 4 — Ship

> A custom-built application ships to the rig by git tag: images travel
> over SSH without a registry, hooks and backup fire in order, health
> gates the cutover, and the deploy is fully recorded.

**Prerequisite:** Phases 2 and 3.
**Spec:** `docs/build-deploy.md` (build-push flow, deploy steps a–g, versions.log format, SSH multiplexing, helper scripts), `docs/project-manifest.md` (hooks, backup, health), `docs/cli.md` (build-push, deploy flags)

## Exit criteria
- [ ] A built fixture app deploys to the rig end-to-end: backup → pre-deploy hook → retag `:current` → up → health wait → post-deploy hook, in that order (order asserted)
- [ ] `versions.log` line carries all frozen fields + `hosting=` + real `digest=`
- [ ] Two concurrent deploys: the second fails fast on the flock, the first completes untouched
- [ ] `build-push` on a stock-only project exits 0 doing nothing

## Tasks

### 4.1 — `build-push` (M)
Version from HEAD's single v-tag (fail on zero or many); collect `build:`
services from `compose.prod.yml`; build, tag `<image>:<version>`,
`docker save | gzip` → scp → `docker load` on the VPS; clean both ends;
push the git tag unless `--no-git-push`. `--build-only` short-circuit.

**Deliverables**
- [ ] `lib/build_push.sh` + integration test shipping the built fixture
- [ ] Stock-only fixture → exit 0, no tarball created

**Watch out for:** one `docker save` invocation with all images (per-image
tarballs waste the shared-layer dedup save gives you within a tarball);
and tmp space on the rig — stream to `/tmp` and clean in a trap, or a
failed scp leaks gigabytes per run.

### 4.2 — `remote-deploy.sh` generalized (L)
The VPS-side orchestrator, generalized from the original project's: modes
`deploy|rollback <version>`; exclusive `flock` for the whole run; backup
hook (run `check`, gate on exit 0, `command | pipe > backups/…`, rotate to
`retain`); pre/post hooks via `docker exec -T` with `VERSION`,
`PREV_VERSION`, `DEPLOY_BACKUP` exported; retag `:current`; `compose up -d
--remove-orphans`; wait on `health.container` up to `health.timeout`;
append + rotate `versions.log`.

**Deliverables**
- [ ] Generated per-deploy, shipped to `/apps/<name>/scripts/`, matching the installed hosting version
- [ ] Hook order + env vars asserted by the integration test (hooks write breadcrumbs)
- [ ] Backup gate: fixture where `check` exits 1 → no backup file, deploy proceeds

**Watch out for:** `flock` needs a dedicated lock-file fd
(`exec 9>.deploy.lock; flock -n 9`) — flocking the directory path itself
is non-portable. Health wait must poll `docker inspect
--format {{.State.Health.Status}}`, and treat *no healthcheck defined* as
an immediate pass, not an infinite wait. Manifest data reaches the VPS
side as the synced `hosting.yml` — parse with the same yq dialect, which
means yq must be a rig/VPS prerequisite **or** the local side pre-renders
hooks into the script; decide once, record it in Findings, and update
`server-setup.md`'s prerequisites table to match.

### 4.3 — Full deploy wiring (M)
Assemble `build-deploy.md` steps 1–9 in order: ControlMaster, reachability,
version, dirs, sync + helpers + fragment, env drift + `HOSTING_*`
injection (Phase 3), remote-deploy invocation, changelog print. Mail claim
(step 7) is a stub that warns and continues when no mail stack exists —
real reconciliation is Phase 7.

**Deliverables**
- [ ] `hosting deploy user@host` runs the full sequence on the rig
- [ ] `--skip-hooks` and `--no-health-wait` honored
- [ ] Exit codes match `cli.md` (3 unreachable, 4 no server state, 5 env declined)

**Watch out for:** the working-tree deploy labels *disk state* with HEAD's
tag — do not add a cleanliness check that blocks it; that's the designed
iterate-and-ship path (`build-deploy.md` § two modes).

### 4.4 — Built fixture + digest recording (S)
Second fixture: tiny Dockerfile (nginx + generated static file), hooks
that leave observable breadcrumbs, a backup command that emits a known
payload. Record image digests into the `versions.log` line (`digest=`
comma-joined, `-` for stock-only).

**Deliverables**
- [ ] `tests/fixtures/built-app/` with repo + v-tag scaffolding
- [ ] Digest in the log matches `docker inspect` on the rig

**Watch out for:** `docker save`/`load` preserves image IDs but
`RepoDigests` stays empty for never-pushed images — record
`docker image inspect --format {{.Id}}` (content ID), not RepoDigest,
and note the distinction in `build-deploy.md` if the docs imply otherwise.

## Findings

_(filled during execution — record the yq-on-VPS decision, observed
save|scp|load timing for the fixture, and flock behavior over SSH)_
