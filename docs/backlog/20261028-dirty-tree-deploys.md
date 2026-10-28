---
description: >
  `kasbah deploy` ships the working tree labelled with HEAD's tag, so one
  version can run as several different byte sets and `rollback 1.2.0` restores
  the tag's files, not what ran. Refuse when the synced paths differ from the
  tag, take `--dirty` to ship anyway as `<ver>+dirty` in the log, the image tag
  and the report, and refuse to roll back to a dirty entry, in internal/deploy,
  internal/buildpush and internal/vlog.
state: ready
priority: high
---

## Prompted by

Design review, 2026-10-28: "`v1.2.0` means three different things … Either
make working-tree deploys stamp a suffix in the log, or refuse when the tree
differs from the tag (with a `--dirty` override)." User: "blocking is fine
until all is committed and tagged and pushed, but --dirty can be an option".

## Work

- [ ] `git diff --quiet v<tag> -- <sync list> traefik-dynamic.yml` decides clean; untracked files in the sync list count as dirty
- [ ] `--dirty`: version string becomes `X.Y.Z+dirty` everywhere one run writes it (versions.log version field — still one token, the frozen format holds; the `:<version>` image tag; the report); the line's timestamp is what tells dirty deploys apart, no counter
- [ ] `rollback` refuses an explicit `+dirty` target and the implicit pick skips dirty lines
- [ ] build-push gets the same check, or a dirty tree ships images labelled as the clean tag
- [ ] docs: build-deploy.md Versioning contract and "Why working-tree for no-args"

## References

- `docs/build-deploy.md` → Versioning contract, `kasbah deploy` Two modes
