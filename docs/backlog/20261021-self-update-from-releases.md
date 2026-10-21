---
description: >
  A workstation refused by a newer server, or meeting a server arch it holds no
  build for, has to find and build that version by hand. `kasbah self-update
  [version]` resolves the newest `vN.*` tag with `git ls-remote`, downloads the
  assets from the GitHub Release, verifies the signed `checksums.txt` against
  the embedded key and installs into the versioned dir; server-arch builds are
  fetched lazily the first time a server of that arch is met — in the launcher.
state: blocked
priority: normal
after: "[[release-sh-and-signing]] and at least one published release to fetch"
---

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
