# Phase 2 — Spine

> One thin path works end to end: `hosting server init` prepares the rig,
> a thin `hosting deploy` puts a stock nginx project on it, and the page
> serves **through Traefik via a file-provider fragment** — the routing
> model is proven.

**Prerequisite:** Phase 1. (Phase 3 may run in parallel — no shared files.)
**Spec:** `docs/server-setup.md`, `docs/traefik.md`, `docs/cli.md` (server init, deploy), `docs/build-deploy.md` (deploy flow steps 1–5, 8d, 8g)
**Retires:** file-provider-only routing (no docker socket, `container_name` DNS on `hosting-net`) — designed in `765972c`, never yet run anywhere.

## Exit criteria
- [ ] On a fresh rig: `server init` → deploy fixture → `curl -H 'Host: demo.test' localhost:5080` returns the fixture page, routed by Traefik (the rig's published HTTP port — see 01-rig.md; the suite itself curls from inside the rig, so it doesn't depend on the host port being free)
- [ ] The Traefik container has **no docker socket mounted** (asserted by the integration test)
- [ ] Re-running `server init` is a no-op (idempotency rules in `server-setup.md`)
- [ ] `/apps/.hosting/server.json` exists with computed 90% limits
- [ ] `versions.log` has one well-formed deploy line (frozen fields + `hosting=` + `digest=-`)

## Tasks

### 2.1 — Prompt/flag helper (S) [parallel-safe]
`lib/prompt.sh`: `prompt_bool <flagname> <question>` implementing the
tri-state rule — explicit `--with-x`/`--no-x` wins, else TTY prompt, else
hard fail naming the flag (`overview.md` → Interactivity). Unit-tested
with a closed stdin.

**Deliverables**
- [ ] `lib/prompt.sh` + `tests/prompt_test.sh`
- [ ] No-TTY + no-flag exits non-zero with the flag name in the message

**Watch out for:** `[ -t 0 ]` inside command substitution — test TTY-ness
in the function's own context, not a subshell's.

### 2.2 — `server init`: preflight, layout, marker (M)
Preflight per the `server-setup.md` table (docker ≥ 24, compose v2,
sudo-less docker, rsync/openssl/gzip); `mkdir -p` layout; `acme.json`
touched **as a file**, chmod 600; write `/apps/.hosting/server.json`
(hosting version, paths, `cpu_limit` from `nproc` × 0.9, `mem_limit` from
`MemTotal` × 0.9). Mail/backup choices resolved via 2.1 (`--no-mail
--no-backup` in all rig tests); scaffolding of the mail/backup stacks
themselves stays in Phases 7/8.

**Deliverables**
- [ ] `lib/server_init.sh` + integration test on a fresh rig
- [ ] Marker JSON matches `server-setup.md`'s shape; limits plausible for the rig's host
- [ ] Second run changes nothing (assert via checksum of `/apps`)

**Open decision, carried forward from Phase 1 — settle it explicitly, do
not let it be settled by a stray `sudo`.** The rig's SSH user is
`stevedore`, not root, and the image deliberately does not pre-create
`/apps`. So `mkdir -p /apps` needs an answer: does `server init` sudo, or
is a pre-created `/apps` owned by the deploy user a documented
prerequisite? `server-setup.md` warns against mixed sudo/non-sudo
ownership in `/apps/data/` and lists prerequisites as *checked, not
installed* — which leans toward the prerequisite. Whichever wins, record
it in `server-setup.md` in the same change.

**Watch out for:** Docker silently creating a *directory* at a missing
bind-mount path — the acme.json touch must precede any `compose up`
forever. Write the marker last: its presence is the "init completed"
signal.

### 2.3 — Traefik stack templates + start (M)
`templates/traefik/`: `compose.yml` (no socket mount, healthcheck via
`traefik healthcheck --ping`), `traefik.yml` (file provider watching
`/etc/traefik/dynamic`, entrypoints `web`/`websecure`, `letsencrypt`
resolver), `dynamic/_shared.yml` (the six middlewares from `traefik.md`,
TLS options, dashboard router). Rendered and started by `server init`.
Traefik `.env` minimal, values from init flags (interactive env comes with
Phase 3).

**Deliverables**
- [ ] Templates render, Traefik healthy on the rig, dashboard router answers with basic auth
- [ ] Integration assert: `docker inspect` on the rig shows no `/var/run/docker.sock` mount

**Watch out for:** `$` in the bcrypt hash — compose interpolates `.env`
values, so the hash must be `$$`-escaped on write (the env-template port
does this later; do it manually here). ACME will fail on the rig — assert
Traefik *serves* with its default cert (`curl -k`), don't assert issuance.

### 2.4 — Thin deploy (M)
The skeleton of `cmd_deploy`: SSH ControlMaster, reachability, version =
HEAD's v-tag, remote dirs, rsync of the manifest `sync:` list, fragment
rsynced out-of-band to `/apps/traefik/dynamic/<name>.yml`, `compose up
-d`, append to `versions.log`. Requires `.env` present on the VPS (drift
handling is Phase 3; hooks/backup/health are Phase 4). Stock-only.

**Deliverables**
- [ ] `lib/deploy.sh` thin path + `versions.log` line with `digest=-`
- [ ] Fragment lands atomically (rsync temp+rename) and Traefik picks it up without restart

**Watch out for:** ControlPath length limits (~104 chars) — use `%C`
hashing, not `%r@%h:%p`, or long hostnames break multiplexing silently.

**Carried from Phase 1:** every `docker compose` invocation hosting makes
on the VPS must pass `-p <project>`. `name:` in a compose file is the
*weakest* source of the project name — `COMPOSE_PROJECT_NAME` in the
remote environment outranks it, and `down` removes by project label, not
by the services the file lists. On the dev workstation this was proven to
put nine unrelated containers in range (see 01-rig.md Findings).

### 2.5 — Minimal `server status` (S) [parallel-safe]
Enough to verify the spine by hand: docker/compose versions, Traefik
health, project list from `/apps/` with last `versions.log` entry. The
full version (certs, mail, disk) grows in Phase 7.

**Deliverables**
- [ ] `hosting server status` output matches reality on the rig after 2.4

### 2.6 — Spine integration test (S)
Fixture stock project under `tests/fixtures/`: nginx + baked index page,
compose in the new network pattern, fragment targeting its
`container_name`. Test: reset rig → init (`--no-mail --no-backup`) →
pre-seed `.env` → deploy → curl through 8080 asserts the page → re-init
no-op assert.

**Deliverables**
- [ ] `tests/integration/spine_test.sh` green on a fresh rig
- [ ] The no-TTY hard-fail assertion moved here from Phase 1 (init without mail/backup flags, stdin closed → exit ≠ 0, message names `--with-mail`)

**Watch out for:** the fixture needs a git repo with a v-tag (deploy
resolves versions from tags) — `git init && tag` inside the fixture setup,
not the hosting repo's own history.

## Findings

_(filled during execution — first real observation of fragment routing:
reload latency, 502 behavior when the container is stopped, default-cert
TLS shape)_
