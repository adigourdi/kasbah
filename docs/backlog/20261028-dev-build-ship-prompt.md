---
description: >
  A dev build is newer than the release it follows, so a deploy from a
  checkout silently replaces the server's release binary with unreleased code
  and a second operator on the release is then refused. Ask before shipping a
  dev build over a release (`--ship-dev` / `--keep-server`), keep auto-shipping
  when the server already runs a dev build, and print every server-binary
  change, in internal/serverbin and internal/launcher.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28, user: "we shouldn't auto sync, maybe we prompt the
user, hey the version you're using is newer... or if the server is already on
dev we auto sync as now, since it might be a testing target".

## Work

- [ ] server on a release, workstation a newer dev build → prompt; unset flag = ask, no TTY = fail naming both flags; declining keeps the server's binary and the run continues on it if it can (same-build rule: otherwise hand off or refuse as today)
- [ ] server on a dev build → newer dev or release ships automatically, as now
- [ ] one line on every change: `server kasbah 1.1.0 → 1.1.0-dev.14+g…`
- [ ] docs: overview.md Distribution, cli.md Hand-off

## References

- `docs/overview.md` → Distribution ("a release build always replaces a dev build"), `internal/serverbin`, `internal/launcher`
