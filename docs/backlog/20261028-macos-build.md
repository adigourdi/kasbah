---
description: >
  kasbah has no macOS build, so the workstation must be Linux while most of
  the solo-dev audience is on a Mac; Docker, ssh and git are all there on
  macOS and the cross-arch build is `docker buildx --platform`, which
  build-push already owns. Add a darwin target to the build, the release
  assets, get.sh and install.md.
state: ready
priority: high
---

## Prompted by

Design review, 2026-10-28: "Linux-only workstation. This is the adoption
cliff, not a footnote … Until this exists, your user base is 'Linux desktop
people who also run VPSes'." Accepted as-is.

## Work

- [ ] darwin/amd64 and darwin/arm64 workstation builds in `compose.yml`'s build and `release.sh`
- [ ] build-push cross-builds for the server's arch (`--platform` from the marker) when it differs from the workstation's
- [ ] `get.sh`, `install.md`, README requirements updated; frozen asset names gain the darwin pair

## References

- `docs/install.md`, `docs/overview.md` (Distribution), `internal/install`, `internal/buildpush`
