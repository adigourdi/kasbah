# Phase 2 — Spine

> One thin path works end to end: `kasbah server init` prepares the rig,
> a thin `kasbah deploy` puts a stock nginx project on it, and the page
> serves **through Traefik via a file-provider fragment** — the routing
> model is proven.

**Prerequisite:** Phase 1. (Phase 3 may run in parallel — no shared files.)
**Spec:** `docs/server-setup.md`, `docs/traefik.md`, `docs/cli.md` (server init, deploy), `docs/build-deploy.md` (deploy flow steps 1–5, 8d, 8g)
**Retires:** file-provider-only routing (no docker socket, `container_name` DNS on `kasbah-net`) — designed in `765972c`, never yet run anywhere.

## Inherited from Phase 1 — read before starting

The rig exists and works (`tests/rig/README.md` documents its shape and
limits). What Phase 1 learned that lands on this phase:

1. **`kasbah` has no way to be told the rig's SSH contract — settle this
   before 2.4.** The CLI takes a bare `USER@HOST` and `cli.md` documents no
   `-F`, `-i` or port option, but the rig is reachable only as
   `ssh -F tests/rig/ssh_config rig` on a non-standard port with a
   per-checkout key. Either `kasbah` grows an ssh-options passthrough, or
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
- **kasbah grows no ssh-options flag.** It runs plain `ssh user@host` and
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
  works by *enumeration* — `docker compose ls -q`, then `down -v` per
  project — rather than by wildcard: no `docker rm -f $(docker ps -aq)`, no
  prunes. The rig's dockerd is a nested daemon, so a wildcard sweep *would*
  be contained, but the containment rests entirely on the command reaching
  the far side, which is precisely the assumption not worth betting the
  owner's `shop-*` stack on. An enumerated payload is harmless even if
  it escapes.

  To be exact about what that enumeration covers, since this paragraph and
  the code comment drifted apart once already: it tears down **every**
  compose project the rig's daemon reports, whoever created it — the
  breadth of a sweep, by the mechanism of an enumeration. On a disposable
  fake VPS the breadth is the point; the mechanism is what would keep it
  harmless anywhere else.
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
   installed kasbah would have no `templates/` at all and 2.3/2.4 would
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

Walked by hand against the real rig at phase close, from a cleaned rig, in
one sitting — not inferred from the suites having passed.

- [x] On a fresh rig: `server init` → deploy fixture → `curl -H 'Host: demo.test' localhost:5080` returns the fixture page, routed by Traefik — returns `served-by-demo-web-through-the-file-provider` **from the host**, on the rig's published port. That it is genuinely *through Traefik* is separately established: `demo-web` publishes no host port at all (`ports={"80/tcp":null}`), Traefik alone binds :80/:443, and an unrouted `Host:` on the same port gets Traefik's own 404
- [x] The Traefik container has **no docker socket mounted** — three mounts (`traefik.yml`, `dynamic/`, `acme.json`), zero matching `docker.sock`. The integration assertion is fenced by positive mount controls, so it cannot pass against an empty list
- [x] Re-running `server init` is a no-op — a second init **with no Traefik flags and stdin closed** left `/apps` byte-identical (`46e44dd4…dff36f` before and after, digest over type, mode, owner and content) and Traefik's `StartedAt` unmoved at `2026-08-14T02:02:55.301528274Z`. It reported `credentials reused` and `nothing re-rendered`; the page still served afterwards. That path is the real test, since bcrypt salts randomly and a re-render would change the tree
- [x] `/apps/.kasbah/server.json` exists with computed 90% limits — `cpu_limit 14.4`, `mem_limit 54g` against the rig's own 16 cores and 63624052 kB
- [x] `versions.log` has one well-formed deploy line (frozen fields + `kasbah=` + `digest=-`) — `2026-08-14T02:03:02+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-`

**Not proven here, and not tickable on a container:** ACME issuance (no
public DNS — Traefik serves its default cert and Let's Encrypt rejects the
account outright), and the resource limits actually being *enforced* — the
rig's cgroup root is in threaded mode, so any container with `--cpus` or
`--memory` fails to start and the fixture must seed `0`. R01/R02 are
computed and written correctly; that they bind is Phase 6's to show, on a
real VPS. Both are recorded in `tests/rig/README.md`.

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
touched **as a file**, chmod 600; write `/apps/.kasbah/server.json`
(kasbah version, paths, `cpu_limit` from `nproc` × 0.9, `mem_limit` from
`MemTotal` × 0.9). Mail/backup choices resolved via 2.1 (`--no-mail
--no-backup` in all rig tests); scaffolding of the mail/backup stacks
themselves stays in Phases 7/8.

**Deliverables**
- [x] `lib/server_init.sh` + integration test on a fresh rig — 11 suites
      green, integration pass 17.5 s
- [x] Marker JSON matches `server-setup.md`'s shape; limits plausible for
      the rig's host — derived from the rig's own `nproc`/`MemTotal`
      (16 / 63624052 kB → `14.4` / `54g`), never a hard-coded number
- [x] Second run changes nothing (assert via checksum of `/apps`) —
      byte-identical, digest covering type, mode, owner and content, and
      self-proved sensitive to both a new file and a mode change

**Open decision from Phase 1 — settled: `server init` sudo-creates the
apps path** and chowns it to the SSH user, then works unelevated below.
Recorded in `server-setup.md` ("Who creates the apps path"), which now
carries the four-state table including the two refusals. Elevation is
strictly for *creating*: init never adopts a directory it did not create,
and it re-asks root before deciding, because the deploy user cannot see
past a parent they cannot traverse.

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
- [x] Templates render, Traefik healthy on the rig, dashboard router answers
      with basic auth — `traefik:v3.7.10`; no credentials → 401, wrong
      password → 401, correct → 200 over HTTP/2, curled from inside the rig
- [x] Integration assert: `docker inspect` on the rig shows no
      `/var/run/docker.sock` mount — three mounts, none of them the socket,
      and the negative is fenced by positive mount controls so it cannot
      pass against an empty list

**Watch out for:** ACME will fail on the rig — assert Traefik *serves* with
its default cert (`curl -k`), never issuance.

**The `$$` warning above was wrong and is struck.** It presumed the hash
reaches a compose-interpolated `.env`; it does not, because Traefik
interpolates nothing and the stack therefore has no `.env` at all. In
`_shared.yml` — plain YAML that Traefik parses directly — a single `$` is
correct and doubling it would be the bug.

**What actually bit, and it was worse:** a `"` in the dashboard username.
It renders `- "ad"min:$2y$…"`, Traefik fails to parse the *whole file*, so
`tls.options.default` never registers — and `traefik.yml` points every
`websecure` entrypoint at it, so every project's HTTPS router stops
starting. Meanwhile `/ping` still answers 200, the health wait passes, init
prints `traefik: started, healthy`, writes the marker and exits 0. A wholly
green run over a wholly broken server. Two layers now: the input is refused
by name, and every rendered file is `yq -e .`-parsed before it ships.
`$` and `:` in `--apps-path`/`--data-path` are the same class one level
down — they produce *valid* YAML that compose then interpolates on the VPS
(`/apps/$HOME`) or re-splits (`/d:ata` mounts `/d` and leaves acme.json
unmounted), slipping both layers until the path validator banned them.

### 2.4 — Thin deploy (M)
The skeleton of `cmd_deploy`: SSH ControlMaster, reachability, version =
HEAD's v-tag, remote dirs, rsync of the manifest `sync:` list, fragment
rsynced out-of-band to `/apps/traefik/dynamic/<name>.yml`, `compose up
-d`, append to `versions.log`. Requires `.env` present on the VPS (drift
handling is Phase 3; hooks/backup/health are Phase 4). Stock-only.

**Deliverables**
- [x] `lib/deploy.sh` thin path + `versions.log` line with `digest=-` —
      `2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-`
- [x] Fragment lands atomically (rsync temp+rename) and Traefik picks it up
      without restart — boot count 1 before and after, `StartedAt` unmoved,
      mode 644, byte-identical to the project's `traefik-dynamic.yml`
- [x] **The fixture, pulled forward from 2.6** — `tests/fixtures/demo/`,
      stock nginx, passes `kasbah check` 22/0/0
- [x] `templates/remote-deploy.sh`, thin: `compose -p <name> up -d
      --remove-orphans` plus one log line. Phase 4 extends it

**Watch out for:** ControlPath length limits — real, but the plan's `%C`
remedy was itself wrong, and the group review is what caught it. See the
Findings: `%C` is unique per *target*, and the socket has to be unique per
*process*. The usable budget is 90 bytes, not ~104.

**What actually bit: the fragment shipped too early.** A router registers
the moment the file lands, whether or not anything is behind it — so any
later failure (unpullable image, port conflict, bad env, unparseable
compose) left a live route to a container that never started, and the host
served **502 until some future deploy succeeded**. On a first deploy that
turns an honest 404 into a permanent 502. Proven on the rig, fixed by
shipping the fragment last, and `build-deploy.md` now carries the ordering
and the reason. Two related hazards came out of the same review, both worse
than the bug because kasbah *told the operator to do them*: exit 4 offered
a bare `kasbah server init`, which against a `--apps-path` server renders
a second Traefik stack under the frozen `traefik` project and takes every
site down; and a project named `traefik` would `--remove-orphans` the
reverse proxy, gated only by a missing `.env` that the refusal message
explained how to create. `traefik`, `data` and `backups` are now reserved
names, refused at `check` time (S07).

**Carried from Phase 1:** every `docker compose` invocation kasbah makes
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
- [x] `kasbah server status` output matches reality on the rig after 2.4 —
      every value derived from the rig rather than a literal: the deployed
      version and timestamp read back out of `versions.log`, the Traefik tag
      *and* resolved image id off `docker inspect`, the project list off the
      apps path. Read-only, proved three ways (payload audit; hermetic digest
      with mtimes; live digest of `/apps`, `/home/stevedore`, `/tmp` and
      `/var/tmp` across a run — byte-identical)
- [x] `--apps-path`, which `deploy` still lacks — a server prepared
      elsewhere is otherwise uninspectable

### 2.6 — Spine integration test (S)
Fixture stock project under `tests/fixtures/`: nginx + baked index page,
compose in the new network pattern, fragment targeting its
`container_name`. Test: reset rig → init (`--no-mail --no-backup`) →
pre-seed `.env` → deploy → curl asserts the page → re-init no-op assert.
Curl from *inside* the rig (`rig.sh ssh -- 'curl …'`) so the test never
depends on a host port being free; 5080 is for driving it by hand.

**Deliverables**
- [x] `tests/integration/spine_test.sh` green on a fresh rig — the whole
      path: clean → init → seed → deploy → the page, HTTPS on the default
      cert, fragment placement and atomicity, no Traefik restart,
      `versions.log`, network membership, the unrouted-host negative, two
      failed-deploy cases, and `server status` against reality
- [x] The no-TTY hard-fail assertion from Phase 1 — **it lives in
      `tests/integration/server_init_test.sh`**, not here, because that is
      where the command with the prompt lives. Verified by mutation rather
      than by eye: with `prompt_bool`'s TTY branch replaced by a silent
      `return 1`, that suite goes red naming "the no-TTY failure names the
      flag that would answer it"

**Watch out for:** the fixture needs a git repo with a v-tag (deploy
resolves versions from tags) — `git init && tag` inside the fixture setup,
not the kasbah repo's own history. *Handled by copying the fixture to a
temp dir per run; the scratch `HOME` has no git identity, so the copy sets
`user.email`, `user.name` and `commit.gpgsign false` explicitly.*

## Findings

### The routing model, first observed — unit C

This is what the phase existed to retire: file-provider-only routing, no
docker socket, `container_name` DNS on `kasbah-net`. It was designed in
`765972c` and had never been run anywhere. It works, and here is what it
actually does.

- **Reload latency is a ~2 s throttle *window*, not a floor** — and the
  distinction cost a round to learn. Unit C measured 2136 ms for a new
  fragment, 2003 ms for a backend swap and 1958 ms for a delete, and
  concluded 2 s was a floor. Unit D measured the same Traefik with no ssh
  in the loop and found a *single* filesystem event on an idle Traefik
  lands in **25 ms** (delete → 404) to **44 ms** (rename-in → 200). The 2 s
  is `providersThrottleDuration` opening a window on the *first* event and
  holding everything until it closes. Unit C's numbers were all two-event
  operations, because **rsync's temp-then-rename is always two events** —
  which is exactly what kasbah does to ship a fragment. So a real deploy
  pays the ~2 s and a bare `rm` does not. **Poll regardless**: the floor is
  not what makes an immediate assertion wrong, the window is.
- **A stopped backend gives 502, and the router stays registered** —
  precisely the property the file provider was chosen for over the docker
  provider (`traefik.md` → "Why file provider"). Restarting the container
  returns 200 with no Traefik action of any kind. The app keeps ownership
  of its own error surface, which is the whole argument.
- **Traefik never restarts for a fragment.** Its `StartedAt` is unmoved
  across add, edit, delete, the 502 and the recovery.
- **Middlewares resolve by `<name>@file` and apply**: a fragment
  referencing the shared set produced `strict-transport-security`,
  `x-frame-options: DENY`, `x-content-type-options: nosniff` and the
  CSP-report-only stub on a real response, over HTTP/2.
- **An unrouted host on :443 gets 404 with the default cert**, not a
  connection error — so "Traefik is serving" and "this host is routed" are
  distinguishable from the client side.
- **The default certificate is `CN = TRAEFIK DEFAULT CERT`**, self-signed,
  one-year validity, `verify return code 18`. TLS 1.3 by default;
  forcing 1.2 negotiates from the configured cipher list.

### ACME on the rig fails at *account creation*, and that is worth keeping

Let's Encrypt rejects the account before any challenge is attempted:
`400 invalidContact :: contact email has invalid domain: Domain name does
not end with a valid public suffix (TLD)`. So `acme.json` stays **0 bytes**
and a suite can run all day without consuming new-account quota.

That is a property of using a reserved TLD in the rig's `--email`, not luck.
An address with a *real* TLD would register an account per fresh
`acme.json` and walk into the 10-per-IP-per-3h limit — a flake that would
arrive looking like a Traefik bug. Keep test emails on `.test`.

### From the phase-close group review — the seams

Five units were each reviewed in isolation and each approved. A sixth
reviewer that had seen none of those rounds judged them together and found
what per-unit review structurally cannot.

- **The transport was a remote kill switch between kasbah processes.**
  `ControlPath=$HOME/.ssh/cm-%C` looked careful — `%C` was chosen precisely
  to avoid the 104-byte overflow the plan warned about. But `%C` hashes
  user, host and port and *nothing about the process*, so two kasbah
  commands against one server shared a socket, and `ssh -O exit` closes a
  master **together with every session multiplexed over it, including
  another process's**. Measured: a read-only `kasbah server status`
  finishing its run killed a concurrent `kasbah server init` mid-step. The
  init reported a Traefik that was in fact `Up 21 seconds (healthy)`, left
  `/apps/.kasbah/` empty, and both commands then refused the server with
  "Do not re-run init until you know which" — while re-running init was
  exactly the fix.

  Unit A owned the transport, unit B init, unit E status; each was correct
  alone. `flock` in Phase 4 would not have helped, because the trigger is a
  read-only command no lock is ever held for. The socket now lives in a
  per-process `mktemp -d` under `TMPDIR`, named by a counter: no `%` token
  ssh offers is process-specific, so no expansion could have fixed it.

  Two measurements fell out. The usable `sun_path` budget is **90 bytes,
  not 108** — the master binds `<path>.<16 random chars>` and renames — and
  `~/.ssh/cm-` plus a 40-character `%C` had already spent 49 of it before
  the home directory was counted. And a name derived from the target
  repeats when `ssh_connect` runs twice, where a stale socket makes the
  next master silently fall back to no multiplexing at all; a counter
  cannot.

- **The phase's proudest fix had no unit test.** "The fragment ships last"
  is the 502 bug this phase is most pleased to have caught. Moving
  `_deploy_sync_fragment` back before the remote step left `./test.sh` at
  **10/10 PASS** — only the integration suite noticed. Behind it, the whole
  post-marker half of `cmd_deploy` had zero unit coverage, because the ssh
  stub always returned exit 3 or an unparseable marker and the happy path
  was unreachable. The phase's own standing bar, missed by the phase.

- **A test can pass for the wrong reason and look hermetic.** A block in
  `server_init_test.sh` whose comment claimed hermeticity had no ssh stub
  on `PATH`, so it did a real DNS lookup for `kasbah-unit-test.invalid`
  and its `[ "$rc" != "0" ]` assertions passed on the lookup failing — not
  on the guard under test. The fix is the one `deploy_test.sh` already
  used: assert the ssh log is *empty*, with a positive control proving the
  stub is really on `PATH`.

- **Docs reconciled unit by unit still drift as a set.** Each unit fixed
  the docs it touched; nobody owned the whole. `overview.md` still drew the
  Traefik `.env` this phase proved cannot exist, `roadmap.md` still
  promised to build it, and `traefik.md` told operators to edit
  `/apps/traefik/compose.yml` on the server — a file `server init` silently
  re-ships. That last one was in the *same file* as unit C's new ownership
  paragraph, 200 lines below it.

### Two facts about the rig, learned here

`curl`, `openssl` and `base64` are present; **`bc` is not** (use
`date +%s%3N` and shell arithmetic for timing). `git` is still absent, as
Phase 1 recorded.

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
  `lib/ssh.sh` therefore never reads `HOME` at all — see the group-review
  finding below, which moved the socket out of `~/.ssh` entirely.

- **`-F` does not sandbox a host the config does not name.** An alias with
  no matching block falls through to the built-in defaults — the real
  login name, the real `~/.ssh/id_*` keys, the real `known_hosts`:

  ```
  $ ssh -F tests/rig/ssh_config -G kasbah-not-in-any-config
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

- **Comments that overclaim are the review's most common catch.** Two more
  turned up in unit B, one of them describing a distinction (`no marker` vs
  `an empty marker`) that the next line discards.

### From unit B

- **Ask the question with the eyes that will do the work.** `server init`
  decided whether to elevate by testing the apps path as the *deploy user*,
  then ran the `chown` as *root*. A directory the deploy user cannot
  traverse to answers `-e` with false, so a path that plainly existed
  scored `absent`, elevation fired, and root took a directory belonging to
  someone else — leaving its contents behind in exactly the mixed
  ownership the check existed to prevent. The run then failed for an
  unrelated reason, so nothing in the output ever mentioned the chown.
  A privilege check is only as good as the privileges it was evaluated
  with, and the fix is to re-ask as root plus create the final component
  with a bare `mkdir` so an existing directory is `EEXIST` rather than a
  silent adoption.

- **Refusing is not the same as refusing correctly.** Several nearby cases
  refused safely while naming a remedy that could not work — `chmod u+rwx`
  on a read-only mount, "it sits outside /apps" about `/apps` itself. The
  guard held every time; the operator was misdirected every time.

- **A locale can make a correct implementation untestable.** `printf
  '%.1f'` renders `14,4` under a comma-decimal `LC_NUMERIC`, so the marker
  is computed with integer arithmetic instead. The test proving that,
  however, pinned nothing twice over: `LC_ALL=C` overrides `LC_NUMERIC`,
  and no comma locale was installed anyway, so it compared the function
  against itself — a deliberately locale-broken implementation passed it.
  The durable form is a structural assertion (no `printf`/`bc`/`awk` in
  the limit path) plus a live comparison under a locale *discovered* at
  runtime, skipping loudly when none exists. `en_DK.utf8` was present here.

- **Marker writes merge; they never replace.** A `9.0.0` marker carrying an
  unknown key was silently downgraded and the key erased. Within a major,
  a field written by a newer kasbah has to survive a re-run by an older
  one, or `backup.repo_base` disappears the first time someone runs plain
  `server init` after Phase 8.

- **Three assertions in one unit could not fail.** The locale pair above,
  and an integration guard that grepped for text only printed on failure —
  so a remote step that ran *successfully* read as "no remote step ran".
  Moving preflight after the layout left the suite green. The review that
  catches these is the one told to construct the failure rather than read
  the diff.

### The habit that actually worked — across all five units

**Counting mutations beats reading assertions.** Every unit in this phase
was reviewed by someone told to *construct* each failure rather than judge
the diff, and every unit produced assertions that could not fail — eight in
total, three of which were hiding real defects. Reading the test never found
them; breaking the code always did.

The sharpest version arrived in unit E, where the reviewer ran a **survey**
rather than spot-checks: 36 mutations, 15 survivors. Individually the
survivors looked like nitpicks; together they said something the defect list
could not — that the suite pinned the happy path and almost nothing else.
Two of them were properties the code's own comments named out loud
(`--apps-path` reaching the server, an image id truncated to 12 digits) and
neither was pinned by anything.

The cost is low and the yield is high, so it is now the standing bar for
this repo: **an assertion is not finished until its failure has been
observed.** Where a mutation cannot be constructed cheaply, say so in the
report rather than letting the green stand unexamined.
  `docker compose ls --all -q` was described as enumerating "what kasbah
  creates"; it lists every compose project on whatever host answered. The
  code was right for the rig and the comment was wrong everywhere, which
  is precisely the drift this repo's comment convention exists to stop.
