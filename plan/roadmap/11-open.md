# Phase 11 — Open

> Anyone with a Linux workstation installs kasbah with one `curl | sh`, or from
> source at any tag; every install path places its build through one Go routine,
> and `self-update` needs no token.

**Prerequisite:** Phase 10. **Runs before Phase 9** (2026-10-23): the
install path is settled before the repo goes public, and Adopt does not depend on it.
**Specs:** `docs/overview.md` (Distribution), `docs/cli.md` (`self-update`,
Hand-off between installed versions), `docs/files.md`, `README.md`, `CLAUDE.md`
(Commands, Hard conventions, Frozen contracts); `docs/install.md` is new in 11.7
**Retires:** the bootstrap gap — a release can only be installed by a kasbah that
is already installed, so every fresh machine today runs a dev build of whatever
`main` held

## Rulings (2026-10-23)

1. `install.sh` becomes **`install-dev.sh`**. No argument builds the working tree;
   `vN | vN.M | vN.M.P [--pre]` builds that tag in a temporary clone with the
   tag's own `compose.yml`.
2. **Install logic lives in Go once**: a hidden `kasbah __install` (run from
   `dist/`), `self-update`, and a loose release binary all place a build through
   the same routine. The pre-1.0 and 1.0.x layout sweeps are dropped.
3. **Exactly one dev build stays installed**: a working-tree install replaces any
   other dev build; releases are never removed.
4. **`get.sh` is a release asset**, its version stamped in by `release.sh` and
   listed in `checksums.txt`. The README shows
   `curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh`;
   `docs/install.md` adds `sh -s -- v1` for a version. POSIX `sh`, no sudo, no shell-rc edits.
5. **`get.sh` transport, in order**: curl (or wget) bare → curl with a token
   (`GITHUB_TOKEN`, else `gh auth token`) through the API → `gh release download`.
6. **One version grammar** everywhere: `vN | vN.M | vN.M.P` (the v optional,
   `-rc.K` named exactly), `--pre` for rcs. No argument: `get.sh` its own release
   (from `latest`, the newest), `self-update` the newest of its major,
   `install-dev.sh` the working tree. A version argument pins the symlink to what it
   resolved to (11.9).
7. **`self-update` resolves from the releases API**, a token optional (sent when
   present); `KASBAH_RELEASES_REMOTE` is retired.
8. **"Latest" goes only to the highest final release.** The `get.sh` asset name and
   its `releases/latest/download/get.sh` URL are frozen contracts.
9. **Releases cut in this phase are disposable**: they are cleaned up before the
   repo goes public, which starts again at a new v1 (done 2026-11-12). The licence is
   MIT (`LICENSE`).
10. **The proof runs in fresh containers only** (Debian/dash, Alpine/busybox);
    nothing touches `~/.local` on the workstation.
11. **Out of scope:** macOS (the asset name `kasbah_<ver>_darwin_<arch>` extends
    without renaming anything), a custom domain, CI signing, an uninstall
    command (documented as two `rm`s).

## Verification

Per unit, the bar its task names below — Go tests through `docker compose exec dev`,
the unit's own suite, `docker compose run --rm build`. The full `./test.sh` runs
between units, never while an agent is live; one full `KASBAH_RIG_TESTS=1 ./test.sh`
at the close.

## Exit criteria

- [x] In a fresh Debian container (dash) and a fresh Alpine container (busybox),
      `get.sh` from the v1.1.0 release installs 1.1.0; `v1` and `v1.1` resolve;
      `kasbah --version` answers from `~/.local/bin` — 2026-10-24, `debian:trixie-slim`
      (`/bin/sh` → dash) and `alpine:3.22` (busybox), a fresh user each, the private
      repo reached with `GITHUB_TOKEN`: the bare run installed the binary's own verified
      bytes (`1c39e9f3…` = the published amd64 sum, binary and server build), `v1`,
      `v1.1` and an up-to-date re-run exit 0, `kasbah 1.1.0 (schema 1)`
- [x] `./install-dev.sh v1.1.0` produces exactly the hashes in v1.1.0's `checksums.txt`
      — `1c39e9f3…` (amd64, binary and server) and `be62f33b…` (arm64)
- [x] A working-tree `./install-dev.sh` leaves one dev build installed beside the releases
      — a `1.1.1-dev…dirty` install removed a planted `1.1.0-dev…` and kept `1.1.0`
- [x] `./test.sh` and `KASBAH_RIG_TESTS=1 ./test.sh` green — `./test.sh` inside
      `release.sh v1.1.0`; on a reset rig at the released commit 37 suites passed,
      `install_test.sh` failed on a release checkout (fixed in `7628662`, both its
      branches then green) and `server_destroy_test.sh` skipped on a restic pull
      the laptop's suspend cut short (re-run alone: green)
- [x] *Only once the repo is public*: an anonymous `curl | sh` from
      the public URL, and `self-update` with no token — 2026-11-12, v1.0.0 on the
      public repo, a fresh `debian:stable-slim` with no `GITHUB_TOKEN` and no `gh`:
      the README's `curl … | sh` fetched `kasbah_1.0.0_linux_amd64` from
      `releases/download/v1.0.0/`, matched `checksums.txt`, verified it (key
      `FC8BCEC04912A5B7`, trusted comment "kasbah 1.0.0") and installed it;
      `kasbah --version` → `kasbah 1.0.0 (schema 1)`; `self-update` and
      `self-update v1` resolved 1.0.0 through the releases API anonymously and
      exited 0, already installed

## Tasks

### 11.1 — One install routine; `install.sh` → `install-dev.sh` (M)

The shared substrate: 11.2, 11.4 and `get.sh` all place a build the same way.

**Deliverables**
- [x] One Go routine places a build in `<lib>/<ver>/` (binary written beside and
      renamed, `server/kasbah-linux-<arch>` beside it, the result must answer
      `--version`) and repoints `<bin>/kasbah`; `self-update` uses it
- [x] `kasbah __install` (hidden) installs `dist/kasbah` and `dist/server/*` under
      its own stamp — the refusals `install.sh` had (a non-kasbah library dir, a
      binary that does not run, installing over `dist/`, a non-symlink non-file at
      `<bin>/kasbah`) kept
- [x] Installing a dev build removes every other dev build; releases stay
- [x] `install-dev.sh` builds through compose (`KASBAH_SKIP_BUILD=1` skips it) and
      calls `dist/kasbah __install`; `install.sh` is gone
- [x] A checkout is recognised by `go.mod` + `cmd/kasbah`, not a script name —
      `internal/serverbin/home.go`, `tests/integration/server_binary_test.sh:93`
- [x] Every message, test and doc naming `install.sh` names `install-dev.sh`
      (`cmd/kasbah/handoff.go`, `cmd/kasbah/selfupdate.go`, `internal/selfupdate`)
- [x] `tests/install_test.sh` covers the new script and the one-dev-build rule

**Verify on:** Go tests, `tests/install_test.sh`, the build; then
`tests/integration/server_binary_test.sh` on the rig. *Done:* `./test.sh` green;
the rig suite green against the new build; a failed repoint (read-only `<bin>`)
reproduced by the reviewer and now refused before the library is touched —
`internal/install` checks `<bin>`, places, repoints among the survivors, prunes last.

**Watch out for:** `launcher.Root` finds the library from the running binary's own
directory first — `dist/kasbah __install` must take its target from the
environment, never from where it runs. A dev build a server holds is still a
hand-off target; removing it only costs a rebuild, which the refusal message names.

### 11.2 — `install-dev.sh vN[.M[.P]] [--pre]` (M)

**Deliverables**
- [x] A version argument resolves among local tags (`vN` newest of N, `vN.M` newest
      patch, `vN.M.P` exact; rcs only with `--pre` or named exactly); no match names
      `git fetch --tags`
- [x] The tag is built in a temporary clone (not a worktree — the stamp reads
      `.git`) with its own `compose.yml`, sharing the module cache; the clone is
      removed on any exit
- [x] The installed build reports exactly the tag's version

**Verify on:** `./install-dev.sh v1.0.0` into a temporary prefix, its three hashes
compared against v1.0.0's published `checksums.txt`; suite cases for resolution.
*Done:* `d1e8ed4f…127e6b` (binary and amd64 server) and `70121ca2…4859` (arm64),
both equal to the published sums; interrupts at 0.8–1.4 s leave no clone,
container or network (`down --remove-orphans`). A version argument pins the symlink (11.9).

**Watch out for:** the tag's `compose.yml` pins its own Go image; the build must
not run the working tree's. A tag cut before 11.1 has no `__install`, so the tag's
`dist/` is installed by the *working tree's* binary (a `__install DIR` form), not
by its own.

### 11.3 + 11.4 — `self-update` for a public repo; a loose release binary installs itself (M)

11.3:

**Deliverables**
- [x] Versions resolve from the releases API (paged): drafts and tags without a
      release are invisible; `vN.M` accepted; `--pre` as before
- [x] A token is optional: sent to the API host when present, never on the
      redirect; a rate-limit refusal names `GITHUB_TOKEN`
- [x] `KASBAH_RELEASES_REMOTE` and the `git` dependency are gone
- [x] Resolution through `version.Pick` (11.2), `self-update` passing `v<own major>`
      for no argument (the pin rule became 11.9's: any version argument pins)

11.4:

**Deliverables**
- [x] `self-update` run from a release binary outside any library and outside a
      checkout, asked for its own version, verifies its own bytes against the
      signed `checksums.txt` and installs them — no download of the binary
- [x] Asked for another version, it installs that one as usual

**Verify on:** Go tests against the fake GitHub server; a real read-only run
against the private repo with a gh token, into a temporary prefix — resolving
`v1`, and a downloaded release binary installing itself.
*Done:* a loose dev build resolved `v1` through the releases API with gh's token and
installed 1.0.0 (`d1e8ed4f…`, the published sum); anonymous → the may-be-private
refusal; a bogus `GITHUB_TOKEN` → 401 naming it. The self-install is proven by Go tests
only until a release carries this code (11.8). "Already installed" exits 0 and repoints.

### 11.5 — `get.sh` (L)

**Deliverables**
- [x] POSIX `sh`, the whole body in a function called on the last line; `set -eu`,
      no pipelines whose failure matters
- [x] Linux on x86_64/amd64 or aarch64/arm64 only, anything else refused by name
- [x] Downloads the stamped version's asset and `checksums.txt` through the
      ladder in ruling 5; sha256 checked (`sha256sum` or `shasum -a 256`); the
      minisign signature checked too when `minisign` is on PATH
- [x] Hands off to `<binary> self-update [args]`, stdin from `/dev/tty` when it
      opens, else `/dev/null`; `--pre` and `--yes` pass through
- [x] `KASBAH_GET_BASE` points it at another release host (tests);
      `KASBAH_BIN_DIR` / `KASBAH_LIB_DIR` honoured as everywhere
- [x] `tests/get_test.sh` under `dash` and `busybox sh`, against a local fake
      release server, with a stub binary that records its arguments

**Verify on:** `tests/get_test.sh`.
*Done:* the suite under dash and busybox 1.37 (+ shellcheck), each token guard proven
by breaking `get.sh` and watching it fail; posh checked by hand. Beyond the brief:
the binary must answer `--version` before the hand-off (a noexec `$TMPDIR` is named);
busybox wget that cannot check TLS refuses over https unless minisign verifies;
the API redirect is followed by hand, so the token never leaves the API host.

**Watch out for:** download the asset into a directory that is not named as a
version (`mktemp -d`): `launcher.Root` takes any `<dir>/<semver>/kasbah` as a
library, and the self-install would then see itself as installed. Under `curl | sh` the script's stdin is the pipe — a child that
reads stdin eats the rest of the script. `| sh` is dash on Debian/Ubuntu: no
`pipefail`, no `[[`, no arrays, no `local` guarantees.

### 11.6 — `release.sh` and the workflow ship `get.sh` (S)

The stamp: `get.sh` holds exactly one line `stamped=''` at top level; the release
rewrites it to `stamped='<ver>'` (no v) — `sed "s/^stamped=''\$/stamped='<ver>'/"`,
as `tests/get_test.sh` does.

**Deliverables**
- [x] `get.sh` with its version stamped in is an asset, listed in `checksums.txt`
- [x] A release is marked latest only when it is the highest final version
- [x] `.github/workflows/release.yml` stages the same assets
- [x] CLAUDE.md's frozen contracts name the `get.sh` asset and URL

**Verify on:** the staging and "latest" logic tested as functions; the real proof
is 11.8.
*Done:* `release.sh stage` / `release.sh flags` are the one implementation, the
workflow calls both and `tests/release_test.sh` pins its upload list to what `stage`
writes. "Latest" reads origin's tags, so a tag left without a release counts — the
pre-public cleanup deleted tags with their releases. The workflow
still lacks release.sh's stamp check and re-upload path; it stays dispatch-only.

### 11.7 — `docs/install.md` (S) — the orchestrator's, after 11.6

**Deliverables**
- [x] One page owning every path: `get.sh`, the manual verified install
      (`gh release download` + `minisign -V` against `release.pub`), `install-dev.sh`,
      `self-update`, uninstall, and what each step trusts
- [x] README, `overview.md` (Distribution) and CLAUDE.md point to it

*Done:* `docs/install.md`; its by-hand and `get.sh` commands are run in 11.8.

### 11.9 — An explicit version pins the symlink (S) — before 11.8

Ruled 2026-10-23, after 11.3's review: `self-update v1` left `~/.local/bin/kasbah`
on an installed v2. Any version argument now pins what it resolved to.

**Deliverables**
- [x] `self-update` and `install-dev.sh`: any version argument (`vN | vN.M | vN.M.P`)
      points `<bin>/kasbah` at the version it resolved to; no argument → the newest
      installed that runs; the cross-major prompt (`--yes`) unchanged
- [x] Usage texts, tests and `docs/cli.md` / `docs/install.md` say so

**Verify on:** Go tests, `tests/install_test.sh`. *Done:* the old exact-only rule fails
four assertions; `v1` beside an installed v2 asks before moving down a major.

### 11.10 — `get.sh` spends no API calls on its own release (M) — before 11.8

Ruled 2026-10-23 after the phase review: each `get.sh` install made 4 anonymous
GitHub API calls (60 an hour per IP), and a stale `GITHUB_TOKEN` failed it even
on a public repository.

**Deliverables**
- [x] With no version argument `get.sh` installs the release it came from: it hands
      the binary its own version and the directory holding the `checksums.txt` and
      `checksums.txt.minisig` it fetched, and the binary verifies and installs from
      them — zero API calls
- [x] `self-update`: a token GitHub refuses (401) is dropped with one line naming
      its source, and the request retried anonymously
- [x] `get.sh` accepts `N.M.P` without the v and refuses a malformed version before
      downloading anything (exit 2)
- [x] `docs/install.md`, `docs/cli.md` say so

**Verify on:** Go tests, `tests/get_test.sh` (request log: no API call on a bare run).
*Done:* `self-update --from DIR` shares `verify()` with the API path; `Release()` now
checks the trusted comment too (the spec claimed it, the code only printed it). A
refused token is retried anonymously only when it was on the request; refusals and
transport errors after the redirect drop the signed query.

### 11.8 — Proof (M)

**Deliverables**
- [x] `VERSION` 1.1.0 in its release commit (`288d881`); `./release.sh v1.1.0` run by
      the user on `5ace57d` — two identical builds, five assets, marked Latest
- [x] The exit criteria walked in fresh containers, with the commands and their output
      recorded here — above, and:
  - every rung of `get.sh` against the real private release: the API with
    `GITHUB_TOKEN` (both containers), and `gh release download` (host, curl stubbed
    to fail, gh's token tried on the API rung first)
  - `docs/install.md`'s by-hand path in a fresh Debian: `minisign -Vm` with the
    published key ("Trusted comment: kasbah 1.1.0"), `sha256sum -c --ignore-missing`,
    then the asset's own `self-update v1.1.0` installed itself
  - a token GitHub refused: one warning, an anonymous retry, the private-repo 404
  - `self-update` with no token on the private repo: the may-be-private refusal, exit 1
  - not walked: arm64 (no arm64 host — the asset's hash matches the source build,
    its first run will be the lab RPi), and the public, tokenless path (walked
    2026-11-12 after the flip, under the exit criteria)

## Open decisions

None — the rulings above settle every deliverable.

## Findings

Ran 2026-10-23/24: 11.1–11.10, one commit per unit; 11.9 and 11.10 were added
mid-run (rulings above their blocks) and landed before the release. What a library
is, and who asks before moving the symlink, now live in `files.md` and `install.md`.

- **Two suites assumed what the build under test is.** `server_binary_test.sh` put
  its outranking release at `X.0.1`, below a `1.1.0-dev` line; `install_test.sh`
  assumed a dev build, so `./test.sh` failed on a clean checkout of a release tag —
  `release.sh` runs the suite before it tags, which is why the release passed. Both
  derive from the stamp now (`5ace57d`, `7628662`); the v1.1.0 tag predates the
  second fix, a disposable release. A suite must pass on a dev tree
  *and* on its tag's checkout.
- The spec claimed `self-update` checked the signature's trusted comment; the code only
  printed it (found in 11.10). A safety check a doc asserts is not one until a test
  breaks without it — the token, redirect and query guards here were each proven by
  breaking the code and watching the suite fail.
- `tests/integration/server_binary_test.sh` assumed the dev line sat at `X.0.1-dev`;
  the `VERSION` bump to 1.1.0 broke that silently until the rig ran. Version fixtures
  derive from the build under test now.
- On this kernel a binary just exec'd can report "text file busy" to an in-place
  write for a moment after it exits: replace binaries by rename, never rewrite them.
- No suite builds a tag: `install-dev.sh vN` is proven by hand (11.2) and in 11.8 —
  a suite case would tie `test.sh` to tags the pre-public cleanup deletes.
  `docker compose down` leaves a `run` container behind; only `--remove-orphans` takes it.
