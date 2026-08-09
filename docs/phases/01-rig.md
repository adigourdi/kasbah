# Phase 1 — Rig

> A disposable fake VPS exists: hosting commands can SSH into a container
> that runs its own Docker daemon, and an integration-test runner drives it
> headless.

**Prerequisite:** Phase 0 committed.
**Spec:** `docs/server-setup.md` (prerequisites table — the rig must satisfy it), `docs/cli.md` (exit codes the tests will assert)
**Retires:** "can a container fake a VPS well enough to be the standing exit bar" — the premise of the whole test strategy.

## Exit criteria
- [ ] `tests/rig/rig.sh up` → `ssh` into the rig succeeds with key auth
- [ ] `docker run hello-world` works **inside** the rig over that SSH session
- [ ] `tests/rig/rig.sh reset` returns a pristine rig in under a minute
- [ ] `HOSTING_RIG_TESTS=1 ./test.sh` runs the integration suite; without the var, the unit suite is unchanged and fast
- [ ] Rig limitations documented (ACME cannot issue; TLS asserted via Traefik default cert until Phase 6)

## Tasks

### 1.1 — DinD image + compose (M)
`tests/rig/` — Dockerfile (Debian slim + docker-ce + openssh-server), a
`compose.yml` running it `privileged: true`, entrypoint that starts
`dockerd`, **waits for `/var/run/docker.sock`**, then starts `sshd`.
Dedicated keypair checked into `tests/rig/` (rig-only, not a secret).
Ports: 2222→22, 8080→80, 8443→443. Named volume for `/var/lib/docker`.

**Deliverables**
- [ ] `tests/rig/Dockerfile`, `tests/rig/compose.yml`, entrypoint script
- [ ] SSH as root@localhost:2222 with the rig key succeeds
- [ ] `docker info` inside the rig shows a working storage driver

**Watch out for:** overlayfs-on-overlayfs — without the named volume,
nested dockerd falls back to vfs or fails outright. Also dockerd startup
race (gate sshd on the socket, or tests flake), and MTU mismatch in
nested networks (symptom: TLS handshakes hang; fix: set dockerd MTU to
the outer network's).

### 1.2 — Rig lifecycle script (S)
`tests/rig/rig.sh up|down|reset|ssh` — reset = down -v && up && wait for
SSH. A rig-local ssh config (`StrictHostKeyChecking=no`,
`UserKnownHostsFile=/dev/null`, port, key) that every caller reuses, so
resets don't churn known_hosts.

**Deliverables**
- [ ] `rig.sh` with the four verbs, each idempotent
- [ ] `rig.sh ssh -- docker info` works from a clean checkout

**Watch out for:** waiting on "container is up" instead of "sshd answers"
— poll the SSH port with a timeout, not `sleep`.

### 1.3 — Integration runner + smoke test (S)
`tests/integration/` with the same assert-helper idiom as the unit tests.
`test.sh` runs it only when `HOSTING_RIG_TESTS=1`. First test: rig
reachable, docker functional, `rsync`/`gzip`/`openssl` present (the
`server-setup.md` prerequisites table, asserted).

**Deliverables**
- [ ] `tests/integration/smoke_test.sh` green against a fresh rig
- [ ] `./test.sh` timing unchanged when the var is unset

**Watch out for:** every hosting command the suite will ever run must be
flag-driven (cross-phase rule 1) — no test may ever block on a prompt.
The smoke test should assert `hosting` fails loudly, not hangs, when a
required flag is missing and stdin is not a TTY (once such a command
exists in Phase 2, move this assertion there).

## Findings

_(filled during execution — record the exact docker-ce version baked into
the image, observed reset time, and any MTU/storage-driver surprises)_
