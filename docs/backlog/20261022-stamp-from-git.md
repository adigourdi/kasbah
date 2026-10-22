---
description: >
  The build stamp trusts a hand-edited `VERSION`: a dirty tree with
  `VERSION=1.0.0` claims the release exactly, an `-rc.N` build needs
  `KASBAH_STAMP_EXACT` to be reproducible, every release needs a bump commit,
  and a `1.0.2-dev` build on a server locks a 1.0.0 workstation out with a
  remedy naming a tag that cannot exist — in `tools/stamp`, `internal/version`,
  `internal/remote.Decide`, `internal/serverbin/install.go`, `cmd/kasbah/handoff.go`.
state: ready
priority: high
---

## Rulings (design review of 2026-10-22, approved — settled)

- **Exactness from git, not a file or an env var.** The stamp is `VERSION`
  exactly iff HEAD is tagged `v<VERSION>` (`git describe --tags --exact-match`)
  and the tree is clean. Otherwise it is a pre-release stamp whatever the file
  says: when a tag `v<VERSION>` already exists (the line was released) the base
  is the next patch, `X.Y.(Z+1)-dev`; when it does not (the line is heading
  there) the base is `<VERSION>-dev` (and for an rc `VERSION`, `<VERSION>` with
  its own identifiers, e.g. `1.1.0-rc.1.<n>.<t>`); then `.<commits>.<time>` and
  build metadata `+g<sha>` (`.dirty` appended when the tree is dirty). `Compare`
  ignores metadata; `Base` strips it. `KASBAH_STAMP_EXACT` is removed from
  `tools/stamp`, `compose.yml`, `release.sh` and the workflow. Outside a git
  checkout (a tarball) the count is 0, as today.
- **No post-release bump.** `release.sh` no longer rewrites `VERSION`; after
  `v1.0.0`, `VERSION` stays `1.0.0` and dev builds are `1.0.1-dev…` by the rule
  above; setting `VERSION` to `1.1.0` or `2.0.0` is the one decision a release
  line takes, in its release commit.
- **A release replaces a pre-release on the server.** In `remote.Decide` and
  `serverbin.InstallSelf`, a release build (no pre-release part) ships over a
  server build of the same major that has one, whatever `Compare` says; the
  hand-off's not-installed remedy names `kasbah self-update v…` only when the
  wanted build is a release; for a dev stamp it says a dev build from another
  checkout is on the server and names the commit (`+g<sha>`) to build.
- **`self-update vN.M.P` repoints to what it installed** (the major-change
  prompt kept); a bare `self-update` keeps pointing at the newest that runs.
- Docs: `docs/phases/10-recast.md` records `protocol=1 min_protocol=1`, a
  "1.0.1 release" and `KASBAH_BUILD` — corrected to what exists; `overview.md`,
  `CLAUDE.md`, `server-setup.md`, `cli.md` carry the rules above.

## Work

- [ ] `tools/stamp`: exactness and base from git; `+g<sha>[.dirty]`
- [ ] `internal/version`: metadata through `Stamp`/`Base`; tests
- [ ] `remote.Decide` + `InstallSelf`: release over pre-release; `TestDecide`, rig case
- [ ] `handoff.go` remedy wording by kind of build
- [ ] `selfupdate` named-version repoint; test
- [ ] `release.sh`/`compose.yml`/workflow: drop the env var and the bump; `tests/release_test.sh`
- [ ] Docs (orchestrator)
