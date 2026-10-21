---
description: >
  There is no way to publish kasbah: `install.sh` builds from a checkout and
  nothing is tagged or uploaded, so a launcher has nothing to fetch and users
  have no verifiable artifact. A `release.sh` builds the two reproducible linux
  binaries, writes a minisign-signed `checksums.txt` and creates the GitHub
  Release under a frozen tag/asset naming, from the repo root.
state: ready
priority: normal
---

## Rulings (run of 2026-10-21 — settled, do not re-propose)

- **`release.sh` does the whole release locally.** Refuses a dirty tree, a
  `VERSION` that is not the tag's version, a HEAD without exactly that one
  v-tag (`internal/release.Pick`'s rule), an unpushed HEAD. Runs `./test.sh`.
  Builds through `docker compose run --rm build` **twice** and refuses unless
  the two builds hash identically (release stamps carry no time, so a release
  build is reproducible). Writes `checksums.txt` (sha256, `<hash>  <asset>`
  lines), signs it with **minisign from its container** (`jedisct1/minisign`,
  0.12 verified pullable), creates the release with `gh release create <tag>`
  and the four assets, with notes = commit subjects since the previous tag.
  Then bumps `VERSION` to the next patch `-dev` and leaves that uncommitted
  for the user.
- **Frozen contract:** tag `vMAJOR.MINOR.PATCH` (prerelease tags
  `vX.Y.Z-rc.N` are allowed and marked `--prerelease`); assets
  `kasbah_<ver>_linux_amd64`, `kasbah_<ver>_linux_arm64`, `checksums.txt`,
  `checksums.txt.minisig`. One file per arch serves workstation and server;
  no darwin builds.
- **Key:** minisign secret key at `${KASBAH_RELEASE_KEY:-$HOME/.config/kasbah/release.key}`,
  password-protected as minisign does; `release.sh keygen` creates it through
  the container. The **public key** is committed at `release.pub` (minisign
  format) and embedded in the binary for the later verifier
  ([[self-update-from-releases]]).
- **Workflow, disabled:** `.github/workflows/release.yml` builds in the pinned
  image and would sign and publish, but its trigger is `workflow_dispatch`
  only (the `push: tags:` trigger present and commented) and it is documented
  as the future path; enabling it means moving the key to a repository secret.
- **Tooling on the host:** `gh` (installed and authenticated, ssh protocol),
  `docker`; nothing else.
- The repo is private; `gh` carries the auth. Test releases may be created
  and deleted freely during the run (`gh release delete --cleanup-tag`).

## Evidence

- `VERSION` is `1.0.2-dev`; `git tag` is empty — 1.0.1 was never tagged or
  published (Phase 10 close report: "nothing is tagged or pushed").
- Release builds carry no build-time stamp (`docs/phases/10-recast.md` D1):
  `tools/stamp` prints `VERSION` as-is for a release.
- `compose.yml:52-65` the build service; `-trimpath`, `-buildvcs=false`,
  `CGO_ENABLED=0`, pinned `golang:1.27.2-trixie`.
- `internal/release/release.go:18` `Pick`: HEAD's single v-tag is the version.
- `docs/roadmap.md:100` deferred "Release distribution (GitHub releases)".
- `gh repo view`: PRIVATE, default branch `main`; no releases, no `.github/`.

## Work

- [ ] `release.sh` with the checks, the double build, checksums, signing,
      `gh release create`, the `VERSION` bump; `release.sh keygen`
- [ ] `release.pub` committed; `.github/workflows/release.yml` (dispatch only)
- [ ] `tests/release_test.sh`: hermetic — `gh`, `docker` stubbed on PATH as
      `tests/build_push_test.sh` does; asserts the refusals, the asset names,
      the checksums format, the prerelease flag, the bump
- [ ] Docs (orchestrator): `overview.md` Distribution row, `cli.md` install,
      README install section, `CLAUDE.md` Commands; the contract where
      `files.md`/`CLAUDE.md` keep frozen names

## References

- `install.sh`, `compose.yml` (build service), `tools/stamp`, `internal/release`
- `docs/research/landscape.md` (publishing notes)
