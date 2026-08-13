# Phase 2 — Spine

> One thin path works end to end: `hosting server init` prepares the rig,
> a thin `hosting deploy` puts a stock nginx project on it, and the page
> serves **through Traefik via a file-provider fragment** — the routing
> model is proven.

**Prerequisite:** Phase 1. (Phase 3 may run in parallel — no shared files.)
**Spec:** `docs/server-setup.md`, `docs/traefik.md`, `docs/cli.md` (server init, deploy), `docs/build-deploy.md` (deploy flow steps 1–5, 8d, 8g)
**Retires:** file-provider-only routing (no docker socket, `container_name` DNS on `hosting-net`) — designed in `765972c`, never yet run anywhere.

## Inherited from Phase 1 — read before starting

The rig exists and works (`tests/rig/README.md` documents its shape and
limits). What Phase 1 learned that lands on this phase:

1. **`hosting` has no way to be told the rig's SSH contract — settle this
   before 2.4.** The CLI takes a bare `USER@HOST` and `cli.md` documents no
   `-F`, `-i` or port option, but the rig is reachable only as
   `ssh -F tests/rig/ssh_config rig` on a non-standard port with a
   per-checkout key. Either `hosting` grows an ssh-options passthrough, or
   2.6 injects the `Host rig` block into a temp `~/.ssh/config`. The
   passthrough is the better answer — the rig's rule is that its flags are
   never restated anywhere — and it is a real feature for users with
   jump hosts or non-22 ports, not test scaffolding.
2. **The rig must be created through `rig.sh`.** `RIG_AUTHORIZED_KEY`
   defaults empty and the entrypoint hard-fails on it, so a harness that
   calls `docker compose up` directly gets a dead rig.
3. **Write the compose preflight as major `>= 2`, not `== 2`.** The rig
   reports Compose 5.4.0. `tests/integration/smoke_test.sh` already does
   this correctly — copy it rather than reinventing it.
4. **`rig.sh reset` wipes the nested image cache** (`down -v` drops the
   `/var/lib/docker` volume), so a reset-per-test loop re-pulls Traefik and
   nginx every time. Decide deliberately: add a lighter "clean `/apps`
   only" verb, or accept the Docker Hub exposure — before it starts
   flaking.
5. **A wedged dockerd stops the rig container** rather than leaving it
   half-alive. A test that kills the daemon needs `rig.sh up` afterwards,
   not `reset`, and no test may assume the rig survives the suite.
6. **`git` is not installed in the rig.** Fine for the
   `git archive | ssh vps tar -x` model; do not add a step that needs git
   on the far end.
7. **Nothing will fail loudly if the `/apps` decision above is skipped** —
   `stevedore` has passwordless sudo, so a stray `sudo mkdir` just works on
   the rig and the question resurfaces on a real VPS in Phase 6 instead.

## Decisions settled at execution time

- **`server init` creates `/apps` itself, with sudo**, then chowns it to the
  SSH user so everything below is written unelevated. The alternative — a
  documented prerequisite, which `server-setup.md`'s "checked, not
  installed" philosophy leans toward — was considered and rejected: one
  manual step before every fresh VPS is worse than a sudo that the
  prerequisites table can simply name. Consequence: passwordless sudo
  becomes a prerequisite row, and init must *detect* a sudo that would
  prompt and fail cleanly naming the manual command, never hang on it.
- **hosting grows no ssh-options flag.** It runs plain `ssh user@host` and
  inherits the user's own ssh config, exactly as git does over SSH — jump
  hosts, non-standard ports and key selection are already that file's job.
  This overrules Phase 1's finding 1, which recommended a `--ssh-config`
  passthrough. Integration tests reach the rig through a scratch `HOME`
  **plus an `ssh` wrapper first on `PATH`** that adds
  `-F "$HOME/.ssh/config"`; that config `Include`s the rig's generated
  `tests/rig/ssh_config` and fences everything else off. The scratch
  `HOME` alone does not work and the wrapper is not decoration — see the
  measurements below.
- **The dashboard password is bcrypt via `htpasswd -nbB`**, falling back to
  `docker run --rm httpd:2-alpine htpasswd -nbB` when the binary is absent
  — docker is already required on the dev machine, so the fallback adds no
  dependency. apr1 via `openssl passwd` was rejected as a real weakening
  (salted MD5, ~1k iterations) for no gain. `docs/cli.md` already promised
  bcrypt; it stays true.
- **bcrypt salts randomly, so init must not re-hash on a re-run.** The
  stored hash is reused unless `--traefik-auth` is passed explicitly.
  Without this the "second run changes nothing" criterion below is
  unsatisfiable, since the same password yields a different hash every
  time.
- **Rig cleanup lives in the integration harness, not in `rig.sh`, and is
  targeted rather than blanket.** This is the answer to Phase 1's finding
  4: `reset` drops the nested image volume, so a reset-per-suite loop
  re-pulls Traefik and nginx every run. The replacement removes `/apps`
  and downs each compose project the rig knows about, keeping the image
  cache, and runs at the start of every suite — which also makes the
  suites order-independent.

  Two safety choices, both deliberate. It is **not** a `rig.sh` verb: that
  script is run by hand from arbitrary shells on a workstation carrying
  nineteen unrelated containers, and a destructive verb there is one typo
  from disaster; inside the test harness it is unreachable by hand. And it
  enumerates (`docker compose ls -q` → `down -v` per project) rather than
  sweeping (`docker rm -f $(docker ps -aq)`, prunes). The rig's dockerd is
  a nested daemon, so a sweep *would* be contained — but the containment
  rests entirely on the command reaching the far side, which is precisely
  the assumption not worth betting the owner's `shop-*` stack on.
  A targeted payload is harmless even if it escapes.
- **`templates/remote-deploy.sh` is introduced thin in 2.4** (compose up +
  the versions.log line) rather than inlined over SSH, so Phase 4 grows it
  instead of rewriting the whole VPS side of deploy. `build-deploy.md`
  already specifies the flow as running from that script.
- **The fixture routes plain HTTP straight to its service** — no
  `http-to-https` middleware — so the exit criterion's `curl` returns the
  page rather than a 301. It *also* declares a `websecure` router for the
  same host with `certResolver: letsencrypt`, which proves Traefik keeps
  serving (default cert, `curl -k`) while ACME fails. That is the shape
  Phases 4 and 6 depend on, and it costs nothing to prove now.

## Corrections to this plan, found before starting

1. **`install.sh` ships no templates.** It copies `lib/*.sh` only, so an
   installed hosting would have no `templates/` at all and 2.3/2.4 would
   ship commands that work from a checkout and break once installed.
   Template resolution and installation are hoisted into the first unit.
2. **Traefik expands environment variables in neither its static nor its
   dynamic configuration.** So `server-setup.md`'s `email: <from .env>` is
   not implementable as written, and the dashboard's basic-auth hash
   cannot live in `/apps/traefik/.env` either — both are baked at render
   time. 2.3's `$$`-escaping warning is therefore misplaced for
   `_shared.yml`, where a single `$` is correct; `$$` still governs
   anything landing in a compose-interpolated `.env`. Traefik's `.env`
   keeps only what compose actually interpolates (Phase 1's no-dead-knobs
   rule).
3. **`lib/ssh.sh` is hoisted ahead of 2.2.** The plan puts ControlMaster
   inside 2.4, but 2.2 must SSH first — without the hoist, `server init`
   invents its own transport and `deploy` rewrites it.
4. **`docs/cli.md`'s `(Phase 2)` / `(Phase 3)` annotations mean roadmap
   v0.2 / v0.3**, which collides with this directory's numbering. They get
   relabelled at phase close.
5. **`build-deploy.md`'s ControlPath example uses `%r@%h:%p`** — the very
   form 2.4 warns against. It becomes `%C`.

## Exit criteria
- [ ] On a fresh rig: `server init` → deploy fixture → `curl -H 'Host: demo.test' localhost:5080` returns the fixture page, routed by Traefik (the rig's published HTTP port — see 01-rig.md; the suite itself curls from inside the rig, so it doesn't depend on the host port being free)
- [ ] The Traefik container has **no docker socket mounted** (asserted by the integration test)
- [ ] Re-running `server init` is a no-op (idempotency rules in `server-setup.md`)
- [ ] `/apps/.hosting/server.json` exists with computed 90% limits
- [ ] `versions.log` has one well-formed deploy line (frozen fields + `hosting=` + `digest=-`)

## Execution order

Five units, each one brief / one review / one commit. Regrouped from the six
tasks below; every task's deliverables stay explicit and are ticked
individually.

| Unit | Tasks | Contents |
|---|---|---|
| A | 2.1 + hoisted | `lib/prompt.sh`, template shipping, `lib/ssh.sh`, the integration harness: scratch `HOME` + targeted rig cleanup |
| B | 2.2 | `server init`: dispatch, preflight, layout, marker, idempotency |
| C | 2.3 | Traefik templates, rendered and started by init |
| D | 2.4 | Thin deploy, `templates/remote-deploy.sh`, `versions.log`, **plus the fixture pulled forward from 2.6** — D cannot verify itself without one |
| E | 2.5 + 2.6 | `server status` and the end-to-end spine test |

## Tasks

### 2.1 — Prompt/flag helper (S) [parallel-safe]
`lib/prompt.sh`: `prompt_bool <flagname> <question>` implementing the
tri-state rule — explicit `--with-x`/`--no-x` wins, else TTY prompt, else
hard fail naming the flag (`overview.md` → Interactivity). Unit-tested
with a closed stdin.

**Deliverables**
- [x] `lib/prompt.sh` + `tests/prompt_test.sh` — `prompt_bool`, `prompt_value`
      and `prompt_secret`; the TTY branch is driven through a real pty
      (`script(1)`), not simulated
- [x] No-TTY + no-flag exits non-zero with the flag name in the message —
      both the no-TTY and the EOF-at-the-prompt paths, naming `--with-x`/
      `--no-x` or `--flag=<value>`

**Watch out for:** `[ -t 0 ]` inside command substitution — test TTY-ness
in the function's own context, not a subshell's.

**Resolved by API shape:** nothing is printed on stdout. Answers come back
in a caller-named variable, so `x=$(prompt_value …)` captures the empty
string rather than silently taking the wrong branch — the misuse is a unit
test, not a warning.

**Also delivered here (hoisted, see Corrections):** template resolution and
installation, `lib/ssh.sh`, and the integration harness. Two pty facts
worth keeping: `script -qec` costs a fixed 2 s when the child exits without
draining piped stdin, and terminal echo belongs to the pty rather than the
program — so "the secret was not echoed" is a race unless the input is
delayed until the child is inside `read -rs`. Both were checked against
controls that do leak.

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
pre-seed `.env` → deploy → curl asserts the page → re-init no-op assert.
Curl from *inside* the rig (`rig.sh ssh -- 'curl …'`) so the test never
depends on a host port being free; 5080 is for driving it by hand.

**Deliverables**
- [ ] `tests/integration/spine_test.sh` green on a fresh rig
- [ ] The no-TTY hard-fail assertion moved here from Phase 1 (init without mail/backup flags, stdin closed → exit ≠ 0, message names `--with-mail`)

**Watch out for:** the fixture needs a git repo with a v-tag (deploy
resolves versions from tags) — `git init && tag` inside the fixture setup,
not the hosting repo's own history.

## Findings

_(first real observation of fragment routing — reload latency, 502
behavior when the container is stopped, default-cert TLS shape — lands
with unit D)_

### From unit A

- **OpenSSH resolves `~` and its per-user config from the passwd entry,
  not from `$HOME`.** Measured on OpenSSH 9.6p1, and it invalidated two
  lines of this phase's own brief:

  ```
  HOME=<scratch> ssh -G rig        → reads /home/you/.ssh/config, hostname rig, port 22
  ControlPath=~/.ssh/cm-%C         → /home/you/.ssh/cm-03c5d4ab…      (the real home)
  ControlPath=$HOME/.ssh/cm-%C     → /tmp/tmp.e0CcgF…/.ssh/cm-03c5d4ab…
  ```

  So a scratch `HOME` on its own isolates nothing: the real config stays
  in play and control sockets land in the owner's `~/.ssh`. Isolation
  needs `-F`, which does suppress both the per-user and the system config
  — under the harness ssh reads only the scratch config and the rig's.
  `lib/ssh.sh` spells the control path `$HOME/.ssh/cm-%C` for the same
  reason.

- **`-F` does not sandbox a host the config does not name.** An alias with
  no matching block falls through to the built-in defaults — the real
  login name, the real `~/.ssh/id_*` keys, the real `known_hosts`:

  ```
  $ ssh -F tests/rig/ssh_config -G hosting-not-in-any-config
  user you / port 22 / batchmode no / identityfile ~/.ssh/id_rsa …
  ```

  That is what made the first cut of `rig_clean` aimable: one environment
  variable chose the host, and every guard checked whether *something*
  answered rather than whether the rig did. The fence is a catch-all in
  the harness config, and the exact form matters — `Host * !rig` leaves
  the rig connectable (`id -un` → `stevedore`) while a host that really
  does answer ssh on this box dies at `Connection closed by UNKNOWN port
  65535` with no key offered. The near-identical `Match host *,!rig`
  **breaks the rig too**, because the block's `IdentityFile` appends to
  rig's list rather than being skipped.

- **A destructive payload must prove where it is from the far side.**
  Local variables, config files and reachability probes all answer "did
  someone answer", never "is this the rig". The check that holds is one
  the payload makes about itself after arriving.

- **A guard that fails closed is worth designing for.** The marker read was
  probed across nine states — missing, empty, wrong, truncated, a directory
  at the path, correct with `\n`, with `\r\n`, with no trailing newline,
  with trailing junk. Every refusal reached the destructive lines zero
  times. The no-trailing-newline case refuses too, because `read` returns 1
  at EOF and the value it just set is discarded — accidental, and in the
  safe direction; the Dockerfile writes the newline, so the real rig never
  hits it.

- **`trap … EXIT` is last-writer-wins, so a library must not be the last
  writer.** `lib/ssh.sh` chains via `trap -p` rather than replacing. The
  residual case is inherent, not fixable inside the library: a caller that
  installs its EXIT trap *after* connecting still drops the master
  teardown (bounded by `ControlPersist=60s`). Callers install theirs first.

- **Assertions get mutation-checked here, not eyeballed.** Twelve
  deliberate breaks in the fix round, twelve red suites, each naming the
  right assertion; the reviewer independently mutated five more. One
  mutation is worth quoting because it shows the guard doing real work:
  with the marker check defeated, a refused clean became a completed one —
  the planted `/apps/guard-probe` went from surviving to `gone`.

- **Comments that overclaim are the review's most common catch.**
  `docker compose ls --all -q` was described as enumerating "what hosting
  creates"; it lists every compose project on whatever host answered. The
  code was right for the rig and the comment was wrong everywhere, which
  is precisely the drift this repo's comment convention exists to stop.
