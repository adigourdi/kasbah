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
`retain`); pre/post hooks via `docker exec` with `VERSION`,
`PREV_VERSION`, `DEPLOY_BACKUP` exported; retag `:current`; `compose up -d
--remove-orphans`; wait on `health.container` up to `health.timeout`;
append + rotate `versions.log`.

**Deliverables**
- [x] Generated per-deploy, shipped to `/apps/<name>/scripts/`, matching the
  installed kasbah version — the rig asserts the shipped file *minus its
  generated block* is `sha256`-identical to the template minus its own, that
  the block names the driving kasbah version, that its rendered values match
  the manifest, mode 755, and that `kasbah.yml` was **not** shipped
- [x] Hook order + env vars asserted by the integration test (hooks write
  breadcrumbs) — read back by line number, not by presence:
  `pre-deploy version=1.5.0 prev=1.5.0 backup=backups/pre-deploy-…txt.gz`
  then `post-deploy` with the same three. All four reorder mutants die
- [x] Backup gate: fixture where `check` exits 1 → no backup file, deploy
  proceeds — the backup listing is unchanged, exit 0, `versions.log` field 4
  is `no-backup`, and the hooks saw `backup=no-backup`

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
- [x] `kasbah deploy user@host` runs the full sequence on the rig — steps 1–10
  including the mail claim and the changelog; `deploy_ship_test.sh` green,
  1m55s standalone
- [x] `--skip-hooks` and `--no-health-wait` honored — and `--allow-stopped`,
  which the shipped script grew in 4.2 with no CLI flag reaching it. On the
  rig: `--skip-hooks` leaves zero breadcrumbs **and still writes a backup**;
  `--no-health-wait` skips the wait against a positive control in the same
  section that reports `built-app-web is healthy`; `--allow-stopped` deploys
  over a stack the same deploy without it refuses
- [x] Exit codes match `cli.md` — 3 and 4 out of a real `kasbah deploy`
  against the rig (unreachable host; marker moved aside and restored), 5 from
  the suite's first deploy (no `.env`, no terminal) and hermetically from
  `--on-drift=abort`

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
  passes: 28 passed, 1 warning, 0 failed (H01, correctly — both healthchecks
  live in the Dockerfiles so they travel inside the tarball). The scaffolding
  is `tests/fixture_repo.sh`, shared with the spine suite
- [x] Digest in the log matches `docker inspect` on the rig —
  `digest=sha256:473485c7c9…,sha256:91a2bd2a65…`, each half compared against a
  **separate** `docker image inspect` on the rig, because `docker image inspect
  A B` exits 1 when either is missing and would collapse two facts into one

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

### Two things the spec said about `docker` that are not true

Both found by running the thing, not by reading it, and both had been copied
forward into this phase's own briefs.

- **`docker exec -T` does not exist.** `-T` is `docker compose exec`'s flag.
  `docker exec -T` fails with `unknown shorthand flag: 'T' in -T` and exit
  125, so every hook would have failed identically on any project. Plain
  `docker exec` allocates no pty unless asked with `-t`, which means it
  already *is* the TTY-free form the `-T` was reaching for. `project-manifest.md`,
  `build-deploy.md` and this file's own 4.2 task text all said `-T`; all three
  are corrected, and the manifest doc now says why, so it does not come back.
- **`docker inspect --format '{{.State.Health.Status}}'` does not return an
  empty string for a container with no healthcheck.** It exits 1 with
  `template parsing error: … map has no entry for key "Health"`. 4.2's
  watch-out — treat "no healthcheck defined" as an immediate pass rather than
  an infinite wait — is right about the behaviour wanted and wrong about how
  you detect it: the empty string it implies never arrives, an error does. The
  guarded form is `{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}`.

  The sharper lesson is about the stub, not the daemon. The hermetic suite's
  first `docker` stub answered health from its own map and ignored the format
  string, which made those two format strings **indistinguishable** — so the
  mutant that replaced the guarded template with the unguarded one survived,
  hiding exactly the infinite-wait trap the task warned about. A stub that
  models "what I asked for" instead of "what the daemon does" cannot fail the
  right way.

### A hook that spanned two lines ran half of itself and exited 0

The renderer read the hook list as one newline-joined dump and split it, so a
`|` block scalar — or any string with an embedded `\n` — became *several*
hooks, and each continuation line's first word was taken as a container name:

```
- "web echo one\necho two"     →  RD_HOOKS_PRE=( 'web echo one' 'echo two' )

remote-deploy: pre-deploy hook: web: echo one              ← ran
remote-deploy: pre-deploy hook skipped: no echo is running ← discarded
rc=0
```

`php artisan down && php artisan migrate` written across two lines runs the
`down`, drops the `migrate`, and reports success. A hook is now **one line**,
refused otherwise, and `project-manifest.md` says so — refused rather than
supported because "the first word is the container" has no meaning on the
second line, and because the failure it produces is silent.

### "Nothing is running" is two different situations and only one of them is safe

The VPS side skipped the backup and the pre-deploy hooks when the outgoing
containers were not up, which is right on a first deploy — there is no previous
state to act on, and refusing would make a first deploy impossible for any
project declaring either. But the test was `.State.Running`, which is equally
`false` for a container that **crashed**. So a project that had deployed here
before, declares a backup, and whose database had fallen over would be deployed
straight over, with `no-backup` in the log — the backup skipped at exactly the
moment it was worth having. The code half-knew: its own message read "first
deploy, *or the previous stack is down*".

The discriminator was already being computed one line earlier. `versions.log`
having no entry for this project is the only condition under which "there is no
outgoing state" is actually true:

- **no entry** → skip both, say so, proceed. Unchanged.
- **an entry, and the container is not running** → refuse *before any side
  effect*, naming each container and the state docker reports for it, with
  `--allow-stopped` for an operator who knows the stack is meant to be down.

It is a preflight rather than a test inside the backup step, because a stopped
*hook* container discovered later would already have a backup file on disk
behind it.

### A stub's expressive range bounds what its suite can ever falsify

The sharpest version of a lesson this phase keeps re-learning. The mutant that
turns `_rd_running` into "any container docker can inspect" — which is what
converts the silent skip above into a hard failure — **survived the entire unit
suite**. Not because an assertion was weak: because the `docker` stub could
only answer *running* or *no such object*. It had no way to say
`State.Running=false`, so no test written against it could ever have
distinguished the two situations, and the defect was unreachable from the
hermetic suite by construction.

The stub now carries a `stopped` file and a `{{.State.Status}}` branch. The
general rule: when a stub cannot express a state, that state is not merely
untested — it is untestable, and no amount of assertion-writing against that
stub will surface it. Ask what the stub *cannot say* before trusting a green
suite that depends on it.

### An independently derived survey wins for the third phase running

Author: **59 mutants, 57 killed, 2 survivors, both judged equivalent.**
Reviewer, building its set from the documented behaviour first: **63 mutants,
48 killed, 15 survivors — 9 real gaps.** None was a correctness hole in the
happy path; all nine were unasserted *refusals and defaults*, which is exactly
the region an author's survey underweights, because the author knows the
refusal is there.

The one worth its own line is `date -u -Iseconds` → `date -Iseconds`. It
survives every suite this repo can run: the unit regex accepts any offset and
the rig's clock is `Etc/UTC`, so nothing here can tell the difference. A VPS in
`Asia/Tokyo` would write `+09:00` into a **frozen-contract field** that every
future kasbah must parse. Pinned with a `TZ=Asia/Tokyo` case — a reminder that
"the rig cannot distinguish it" is a reason to construct the case, not to skip
it.

### A documented default that no manifest could reach

`project-manifest.md` promised that `health:` defaults to waiting on every
service with a compose healthcheck. But a `health:` block naming only
`timeout:` was refused by the renderer *and* by pre-existing `check` H02
("manifest health.container is empty"), so there was no way to raise the
timeout for the all-services path — the shipped script supported it, and no
manifest could ask for it. `health.container` is now optional in both places,
and H02 fails only when `container:` is present and names something compose
does not have.

### A guard that fails open, in the guard added to stop a silent skip

The refusal above keyed on `prev` — field 3 of the **last non-empty line** of
`versions.log`. A log with real history whose last line is malformed therefore
read as "never deployed here", took the first-deploy branch, printed a message
provably false about the file it had just read, and appended anyway:

```
2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=t digest=-
garbage
→ "first deploy — versions.log has no entry for this project"   rc=0
```

A `printf >>` killed mid-append is the realistic producer, and it is exactly
the state in which the refusal is most wanted. Two questions had been collapsed
into one variable: *has this project deployed here* (any non-empty line) and
*what version was it* (field 3, for the message and `$PREV_VERSION`). Split,
with the message adapting when the last line is one no version can be read out
of. **Round three found it** — after the round that introduced the guard had
been reviewed and its own fixes re-verified.

### The remote report, and why it is printed last

The local side needs one fact only the server has — the version previously
deployed — for step 10's `git log <prev>..<new>`. `remote-deploy.sh` therefore
narrates everything on stderr and keeps stdout for a `key=value` report,
printed **after** the `versions.log` append.

That placement buys a second property for nothing. The report is the run's
*completion marker*: exit 0 with no report, or with a key missing, means the
script did not reach its end, so the local side refuses — **before shipping the
Traefik fragment**. A truncated run leaves no route and no state, which is the
same failure shape the fragment-last ordering exists to prevent. The one field
that can be checked rather than believed is `version`, and it is: a report
naming a version other than the one asked for is a hard failure.

### A guard is only tested by a fixture that tries to defeat it

Two `>&2` redirects keep project-authored shell — a hook, and `backup.check` —
off the report channel. Deleting either **survived the entire hermetic suite**,
because every fixture hook and every `backup.check` in it redirected its own
output into a file. Nothing in the suite had ever tried to write to stdout, so
nothing could observe the guard that stops it.

The fix is one fixture hook that runs `echo version=9.9.9-from-the-hook` and
one `backup.check` that echoes to stdout, with the control the pair needs: the
leaked lines must show up on *stderr*, so a fixture that quietly stops printing
can no longer satisfy the four-line count. The general shape — a guard whose
test fixtures all happen to be well-behaved is not tested at all — is the
fixture-side cousin of the stub finding below.

Related, and load-bearing under it: `_deploy_absorb` **overwrites**, so a stray
`version=` arriving before the report loses to the report. That last-wins
property is what actually defangs contamination, and it was unpinned too;
first-wins turns the leak above into a wrong-version refusal.

### A test that accepted a crash as its evidence

Dropping `version` from the required key set left the run failing — but with
`_DEPLOY_FACT[version]: unbound variable` and a bash backtrace, and the
assertion was `grep -qF "$key"`, which a backtrace mentioning `version`
satisfies. The other three keys produced the real protocol sentence. The
assertion now requires the sentence *and* that no `unbound variable` appears
anywhere in the output. A test whose evidence is "the word appears somewhere in
the failure" cannot tell a diagnosis from a crash.

### The third defect hidden by what a stub could not say

`docker tag` was the one remote command left unredirected on the stdout path.
The mutant that removes its redirect survived — because the `docker` stub was
**silent on `tag`**, so the redirect was unfalsifiable. Giving the stub a voice
there killed it.

That is three in one phase: a stub that could only say *running* or *no such
object*, one that ignored the format string entirely, and one silent on a verb.
Each hid a real defect from a suite that was otherwise green and thorough. The
rule is worth stating plainly: **before trusting a green case, ask what the stub
cannot say** — an inexpressible state is not untested, it is untestable, and no
amount of assertion-writing against that stub will surface it.

Note the honest cost, taken deliberately: the stub now narrates on `tag`, which
today's docker does not. It models a daemon rather than reporting one, on the
grounds that the property under test is *kasbah's* guarantee about its own
stdout, not docker's current behaviour.

### The reviewer was wrong once, and pinning beat fixing

One of the eight survivors was a false positive: the changelog's commit lines
were reported as going to stdout against the repo's stderr convention. They go
through `info()`, which is `printf … >&2`, and always did. The right response
was not to change code that was already correct but to **pin the property that
was merely unobserved** — the streams are now split in the harness and kasbah
is asserted to write nothing at all to stdout. A review finding that turns out
to be wrong is still evidence that something was unpinned.

### Measured

- `flock` over SSH: the second concurrent deploy refused in **216 ms** against
  a first run holding the lock inside an 8 s pre-deploy hook. The first run
  completed untouched, one new `versions.log` line.
- Hook environment, read back off the rig:
  `pre-deploy version=1.5.0 prev=1.5.0 backup=backups/pre-deploy-20260819-040324.txt.gz`,
  then `post-deploy` with the same three.
- `digest=sha256:473485c7c9…,sha256:91a2bd2a65…`, each half matching a separate
  `docker image inspect` on the rig — inspected one at a time, because
  `docker image inspect A B` exits 1 if *either* is missing and would collapse
  two facts into one.
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
- **A rig suite killed mid-run poisons the next one, and the damage presents
  as unrelated suites failing.** Interrupting `KASBAH_RIG_TESTS=1 ./test.sh`
  (a tool timeout, a Ctrl-C) leaves the rig half-initialised. The next run
  showed `deploy_ship_test.sh` exiting 2 and `server_init_test.sh` and
  `spine_test.sh` failing, with two diagnostic tells worth recognising:
  `getwd: no such file or directory` — a shell whose working directory was
  deleted under it, i.e. a stale process from the killed run — and
  `acme.json exists and is not a regular file`, Docker materialising a missing
  bind-mount source as a root-owned directory. Each suite's opening
  `rig_clean` recovers the state, so a **second** run is green with no
  intervention. Diagnose before fixing: nothing was wrong with the code.
