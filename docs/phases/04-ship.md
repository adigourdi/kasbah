# Phase 4 — Ship

> A custom-built application ships to the rig by git tag: images travel
> over SSH without a registry, hooks and backup fire in order, health
> gates the cutover, and the deploy is fully recorded.

**Prerequisite:** Phases 2 and 3.
**Spec:** `docs/build-deploy.md` (build-push flow, deploy steps a–g, versions.log format, SSH multiplexing, helper scripts), `docs/project-manifest.md` (hooks, backup, health), `docs/cli.md` (build-push, deploy flags)

## Exit criteria
- [ ] A built fixture app deploys to the rig end-to-end: backup → pre-deploy hook → retag `:current` → up → health wait → post-deploy hook, in that order (order asserted)
- [ ] `versions.log` line carries all frozen fields + `kasbah=` + real `digest=`
- [ ] Two concurrent deploys: the second fails fast on the flock, the first completes untouched
- [ ] `build-push` on a stock-only project exits 0 doing nothing

## Tasks

### 4.1 — `build-push` (M)
Version from HEAD's single v-tag (fail on zero or many); collect `build:`
services from `compose.prod.yml`; build, tag `<image>:<version>`,
`docker save | gzip` → rsync → `docker load` on the VPS; clean both ends;
push the git tag unless `--no-git-push`. `--build-only` short-circuit.

**Deliverables**
- [x] `lib/build_push.sh` + integration test shipping the built fixture —
  `tests/integration/ship_test.sh` reads both arrived images off the rig's own
  daemon: present under `<image>:1.5.0`, `:current` and `:latest` absent,
  `RepoTags` exactly the one tag, the page each Dockerfile generated read back
  out of a container started from the arrived image, the HEALTHCHECK intact,
  0 containers started, and no tarball left in either `/tmp`
- [x] Stock-only fixture → exit 0, no tarball created — asserted on the
  filesystem rather than on stdout, and on the rig by its full `docker image
  ls -aq` set being byte-identical before and after

**Watch out for:** one `docker save` invocation with all images (per-image
tarballs waste the shared-layer dedup save gives you within a tarball);
and tmp space on the rig — stream to `/tmp` and clean in a trap, or a
failed transfer leaks gigabytes per run.

### 4.2 — `remote-deploy.sh` generalized (L)
The VPS-side orchestrator, generalized from the original project's: modes
`deploy|rollback <version>`; exclusive `flock` for the whole run; backup
hook (run `check`, gate on exit 0, `command | pipe > backups/…`, rotate to
`retain`); pre/post hooks via `docker exec -T` with `VERSION`,
`PREV_VERSION`, `DEPLOY_BACKUP` exported; retag `:current`; `compose up -d
--remove-orphans`; wait on `health.container` up to `health.timeout`;
append + rotate `versions.log`.

**Deliverables**
- [ ] Generated per-deploy, shipped to `/apps/<name>/scripts/`, matching the installed kasbah version
- [ ] Hook order + env vars asserted by the integration test (hooks write breadcrumbs)
- [ ] Backup gate: fixture where `check` exits 1 → no backup file, deploy proceeds

**Watch out for:** `flock` needs a dedicated lock-file fd
(`exec 9>.deploy.lock; flock -n 9`) — flocking the directory path itself
is non-portable. Health wait must poll `docker inspect
--format {{.State.Health.Status}}`, and treat *no healthcheck defined* as
an immediate pass, not an infinite wait. Manifest data reaches the VPS
side as the synced `kasbah.yml` — parse with the same yq dialect, which
means yq must be a rig/VPS prerequisite **or** the local side pre-renders
hooks into the script; decide once, record it in Findings, and update
`server-setup.md`'s prerequisites table to match.

### 4.3 — Full deploy wiring (M)
Assemble `build-deploy.md` steps 1–9 in order: ControlMaster, reachability,
version, dirs, sync + helpers + fragment, env drift + `KASBAH_*`
injection (Phase 3), remote-deploy invocation, changelog print. Mail claim
(step 7) is a stub that warns and continues when no mail stack exists —
real reconciliation is Phase 7.

**Deliverables**
- [ ] `kasbah deploy user@host` runs the full sequence on the rig
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
- [x] `tests/fixtures/built-app/` with repo + v-tag scaffolding — three
  services, two of them built on different bases, hooks leaving breadcrumbs,
  a backup block emitting a known payload, a health block. `bin/kasbah check`
  passes: 27 passed, 1 warning, 0 failed (H01, correctly — both healthchecks
  live in the Dockerfiles so they travel inside the tarball). The scaffolding
  is `tests/fixture_repo.sh`, shared with the spine suite
- [ ] Digest in the log matches `docker inspect` on the rig — 4.2 owns the
  write; see the image-id finding below for how it must be read

**Watch out for:** `RepoDigests` stays empty for never-pushed images, so
the field to record is `docker image inspect --format {{.Id}}` (content ID),
not RepoDigest. **The rest of this warning was wrong and is corrected in
Findings: `docker save`/`load` does *not* preserve image IDs.** The id must
therefore be read on the server after the load, and can never be compared
against one computed on the workstation.

## Carried in from Phase 2

- **Deploy cannot find a server initialised with a non-default
  `--apps-path`.** It looks for the marker at `/apps/.kasbah/server.json`
  and reads the real paths out of it, which works only when the apps path
  *is* the default. A server at `/srv/apps` is undiscoverable, and neither
  `cli.md` nor `build-deploy.md` mentions it.

  **Settled during this phase, and neither of the two options the carry
  named.** A flag repeats itself forever; a `state.json` field makes the
  apps path a property of *the project's memory of the server*, so two
  projects — or two operators — can hold different beliefs about one
  machine and one of them is wrong. The apps path is a property of the
  **server**, so the server carries it: `server init` writes
  `/etc/kasbah/apps-path`, root-owned and world-readable, and every command
  reads it before falling back to `/apps`. `/etc` rather than `~`, because
  more than one user administers a server and a per-user pointer is exactly
  the split belief being removed. The name `kasbah` is unique enough to
  claim a fixed path, which was not true of the project's earlier name.

  The same fact makes a second guard possible: **one kasbah instance means
  one Traefik means one holder of :80/:443**, so `server init` refuses a
  second, different apps path on a server that already has a pointer,
  rather than rendering a rival Traefik stack under the frozen `traefik`
  compose project and recreating the running proxy against it. That refusal
  is what `lib/marker.sh`'s exit-4 message currently only warns about.

## Carried into 4.2, with the evidence warm

- **Nothing enforces that a built service's `image:` ends in `:current`.**
  `build-deploy.md` states it ("Compose files on the VPS always reference
  `:current` for built images") and no rule checks it. `build-push` strips
  whatever tag is there and tags `<image>:<version>`, so a project whose
  compose says `image: app:1.2.3` gets a `:current` that nothing references
  and a `compose up` that keeps running the pinned image — a deploy that
  reports success and changes nothing. 4.2 owns the retag and is where this
  either becomes a refusal or a compliance rule.
- **Hook breadcrumbs accumulate across deploys.** `_deploy_sync_project`
  rsyncs without `--delete`, so a bind-mounted file a hook appends to
  survives every later deploy. 4.2's hook-order assertions must truncate
  rather than assume a fresh file, or the second run of the suite reads the
  first run's order.

## Findings

### Settled before 4.1 — no yq, and no jq, on the VPS ever

4.2's watch-out framed this as a choice between making yq a VPS prerequisite
and pre-rendering the manifest into the shipped script. It is not a choice.
`project-manifest.md` says the manifest is deliberately **not** in any
project's `sync:` list — "a second copy to drift" — so there is nothing on
the far side to parse; and the rig, which exists to look like a VPS
provisioned today, has no `yq`, no `jq` and no `python3`:

```
$ tests/rig/rig.sh ssh -- 'command -v yq jq python3 || echo MISSING'
MISSING
```

kasbah's yq is the kislyuk wrapper, a Python package. Requiring it on every
host kasbah touches to read a file kasbah chose not to send is two mistakes
compounding. **The local side pre-renders manifest data into the generated
`remote-deploy.sh`**, `server-setup.md`'s prerequisites table gains no row,
and the shipped script stays runnable by hand on the server — which is the
property that made pre-rendering attractive anyway.

### `docker save` / `load` does **not** preserve image IDs

The task's own watch-out said it does. Measured across the two daemons, on
`nginx:alpine`, which sits on both sides untouched by kasbah:

```
workstation (overlay2)              sha256:2a855eac5070cae6…
rig (containerd snapshotter)        sha256:4a73073bd557c65b…
```

Both daemons are docker 29.7.2, so this is not a version skew and not a
build-provenance artifact — the two image stores compute the id differently,
and a plain `docker pull` of the same tag lands on a different id too.

**Consequence for `digest=`:** the value must be read with `docker image
inspect --format {{.Id}}` **on the server, after the load**, and can never
be compared against one computed on the workstation. `ship_test.sh` asserts
the *shape* of the rig's id plus the image's *contents* — the file the
Dockerfile wrote, read out of a container started from the arrived image,
and the surviving HEALTHCHECK. Both content assertions are real: removing
either from the fixture Dockerfile turns the rig suite red.

### `docker compose build` fails on every kasbah-compliant project

R01/R02 make `cpus: ${KASBAH_CPU_LIMIT}` and `mem_limit: ${KASBAH_MEM_LIMIT}`
mandatory, and a build has no server to read them from, so the flow's own
step 3 — a bare `docker compose -f compose.prod.yml build` — cannot run
anywhere:

```
error while interpolating services.web.cpus: failed to cast to expected type:
  strconv.ParseFloat: parsing "": invalid syntax
```

`build-push` builds under `KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0`, scoped to
the one invocation and never exported. Both are runtime keys, so nothing
reaches the image, the tarball or the server; `0` is Docker's "no limit" had
anything consumed them. The necessity is pinned — dropping the `env` prefix
turns the rig suite red. The guarantee that keeps the placeholder inert is
that no `build.args` references a `KASBAH_*` key, and **nothing enforces
that**.

### An independently derived mutation survey found three real gaps a thorough one missed

The implementer surveyed its own work: **53 mutants, 50 killed, 3 survivors**,
all three about stripping `\r` and all three genuinely equivalent (confirmed
by measurement: `yq -r` on a CRLF compose emits no CR at all). A reviewer that
built its set from the *behaviour the docs describe*, before reading any of
that, got **58 mutants and 9 survivors, 3 of them real defects**.

This is the third phase running in which the independent set wins, and this
time it says something sharper than "survey independently". **Five properties
were pinned only by the rig suite**, so `./test.sh` alone was green on all of
them — including a `docker load` whose cleanup had been disabled. A unit suite
that stubs the transport cannot see the payload it hands over; the honest
response is not to fake it hermetically but to say so at the assertion, which
is what the comment above those greps now does.

### A fix round is where unreviewed assertions get in

The seven review defects were fixed and each one demonstrated dying under its
own named mutant. A **scoped** re-verification — confirm the seven, then judge
only the surface the fixes introduced — found **four more defects in the fixes
themselves**, one of which survived the entire rig suite: a second image's
`_id` readback asserted `!= "absent"`, which passes on an empty value, while
its sibling carried the `^sha256:[0-9a-f]{64}$` check that made the first one
falsifiable. The loop that unified the two images duplicated the value
assertions and not the falsifiable one.

The lesson is procedural and now stands for this repo: **a fix round's new
code has been reviewed by nobody**, and the round that closes findings is
exactly where a weak assertion enters unexamined. Re-verification is scoped —
it is not a second review — but "the new surface" is part of its scope.

### One built image made three protocols untestable

The fixture began with a single `build:` service, and with one image the
remote payload's `loaded=<n>` count was right by accident: replacing it with
a constant `loaded=1` survived both suites. So did the whole argument for
one `docker save` carrying every image. And 4.4's `digest=` is specified as
**comma-joined** across built images, which one image cannot exercise at all.

`tests/fixtures/built-app/` therefore carries two built services on different
bases plus one stock service. Measured, and the reason the second one is not
cosmetic: web alone saves to 25,158,676 B, worker alone 3,511,020 B, both
together 28,671,258 B — two real layer sets, not a duplicate.

### A hermetic stub that recomputes the answer pins arity, not identity

The unit suite's `ssh` stub derives `loaded=<n>` by re-splitting the quoted
remote command the way a login shell would, rather than answering a constant.
It is faithful as far as it goes — handing it a duplicated image list is
caught. But passing the `:current` source names instead of the versioned
targets keeps the count at 2 and **survives the unit suite**; only the rig
kills it. Arity is the one thing that derivation looks like it fully covers,
and it is the only thing it does. No future assertion should lean on it for
identity.

### Measured

- `docker save | gzip` of both images **3056 ms** → 28,669,020 B; `rsync`
  **402 ms**; remote `docker load` **1559 ms**. A whole `kasbah build-push`
  against the rig, warm build cache: **5.9–6.2 s**.
- Suites: `./test.sh` **14 PASS in 2m52s** (13 / 2m32s at phase start);
  `KASBAH_RIG_TESTS=1 ./test.sh` **19 PASS in 5m35s** (17 / ~5m50s).

### Accepted limits

- **Two concurrent `build-push` runs of the same project and version clobber
  each other.** The tarball path is fixed per project+version on both ends,
  so each run's trap can remove the other's file. kasbah targets a single
  deployer per project (`build-deploy.md` → why append-only), and the
  multi-operator hazard the phase does design against is the concurrent
  *deploy*, which 4.2 locks with `flock`.
- **The "gigabytes leaked on a failed transfer" case is argued, not
  measured.** The trap is proven on a 28 MB tarball with a forced failure,
  against the rig's real `/tmp`.
