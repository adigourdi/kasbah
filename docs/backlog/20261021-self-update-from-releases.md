---
description: >
  A workstation refused by a newer server, or meeting a server arch it holds no
  build for, has to find and build that version by hand. `kasbah self-update
  [version]` resolves the newest `vN.*` tag with `git ls-remote`, downloads the
  assets from the GitHub Release, verifies the signed `checksums.txt` against
  the embedded key and installs into the versioned dir; server-arch builds are
  fetched lazily the first time a server of that arch is met — in the launcher.
state: ready
priority: normal
after: "at least one published release to fetch (the user cuts it with `./release.sh`, which needs the key password)"
---

## Rulings (run of 2026-10-21 — settled, do not re-propose)

- **Repo stays private.** `self-update` authenticates with `GITHUB_TOKEN`;
  when unset and `gh` is on PATH it runs `gh auth token`; neither → a failure
  naming both. Downloads go through the API asset endpoint
  (`/repos/adigourdi/kasbah/releases/tags/<tag>` → `assets[].url`,
  `Accept: application/octet-stream`). Versions are resolved with
  `git ls-remote --tags --refs git@github.com:adigourdi/kasbah.git 'vN.*'`
  (ssh, the user's own git), highest by `internal/version`; pre-release tags
  (`-rc.N`, `-dev`) are skipped unless `--pre`.
- **Verification before anything is written into the versions dir:** the
  minisign-signed `checksums.txt` is checked against the public key embedded
  in the binary (`release.pub` at the repo root, minisign format: key id
  `FC8BCEC04912A5B7`; signatures are minisign's prehashed form — alg `ED`,
  Blake2b-512 of the file, then ed25519 — as `release.sh` produces them), then
  each asset's sha256 against the file. The verifier is Go: `crypto/ed25519`
  with minisign's prehashed (Blake2b-512) format — `aead.dev/minisign` is
  acceptable if its only transitive dependency is `golang.org/x/crypto`,
  otherwise hand-rolled on `x/crypto/blake2b`.
- **Lazy server builds:** `serverbin.Local` on an installed kasbah, missing
  `server/kasbah-linux-<arch>` for its own version, fetches and verifies that
  one asset into place (temp + rename) before shipping; a checkout never
  fetches (build it). The server never downloads.
- **Install path:** `kasbah self-update [vN | vN.M.P]` installs into
  `<lib>/<ver>/` the same layout `install.sh` writes (the linux asset for this
  machine's arch is both the workstation binary and that arch's server build;
  the other arch's server build is fetched lazily), runs `--version` on it,
  then repoints `<bin>/kasbah` the way `install.sh` does — prompting first
  when the symlink would move to a different major (`--yes`).
- The frozen asset/tag names are the release item's contract.

## Prompted by

*"it might be useful to pull arm64 from there and push the link to the server
to download it there? or cache it locally somewhere then push, rather than each
version holding a different build"* — settled as: the **workstation** fetches,
verifies, caches and pushes over the existing ssh path (size + sha256,
`install-self`); the server never downloads (no outbound-to-GitHub requirement,
and on a first `server init` there is no verifier on the server yet). Each
version still owns its server builds, fetched on demand rather than installed
up front.

## Evidence

- Resolution without the API, no rate limit, `git` already required:
  `git ls-remote --tags --refs <repo> 'v3.*' | sed 's|.*refs/tags/||' | sort -V | tail -1`;
  download URL is deterministic: `releases/download/<tag>/<asset>`.
- The Releases API (`/repos/O/R/releases`) is 60 req/h unauthenticated and has
  no "latest of major N" — only worth it to skip drafts/prereleases, which tag
  naming (`-rc`, `-dev` excluded unless `--pre`) covers.
- The upload path the pushed build reuses: `docs/files.md:109-111`,
  `internal/serverbin/serverbin.go:546`.

## Work

- [ ] `kasbah self-update [vN | vN.M.P]`: resolve, download, verify, install
      into `~/.local/share/kasbah/<ver>/`, print what changed
- [ ] Lazy server build: `serverbin.Ensure`'s `local(arch)` fetches and caches
      the missing `linux_<arch>` for the running version before shipping
- [ ] The launcher's "not installed" path offers/does the fetch (`--yes`/no-TTY
      rules as every prompt)
- [ ] Offline: a clear failure naming the asset and the manual path
      (`install.sh` from the tag's checkout)
- [ ] Docs: `cli.md` (`self-update`), `overview.md` Distribution, `files.md`

## Options

- Server-as-verified-cache (bytes from `<apps>/.kasbah/bin/kasbah`, hash checked
  against the committed release checksums) — a fast path for amd64 Linux only,
  never a source; parked unless downloads prove slow.

## References

- `internal/serverbin/serverbin.go` (`Ensure`, `local func(arch)`), `install.sh`
