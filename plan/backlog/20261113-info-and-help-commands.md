---
description: The binary cannot say which docs match it, or where its logs live
cause: no `kasbah info`; only `kasbah version` and `kasbah help` exist
where: cmd/kasbah, internal/version (docs.go), internal/remote, docs/cli.md
state: ready
priority: high
---

## Prompted by

2026-11-13, discussing how users fix things without the source. Ruled out: a
Claude skill, a `kasbah docs` command printing the full docs. `kasbah help
[topic]` has landed (rule table, IDs on every check line); `kasbah info` is
what remains.

## Settled

`kasbah info` takes an optional `USER@HOST` and then adds the server's kasbah
version, Docker and compose versions and OS. `kasbah version` stays the bare
version. A dev build links docs at `main`, as `kasbah help` does
(`internal/version/docs.go` `DocsURL`/`DocsRef`, the tree URL when the file
is empty).

## Work

- [ ] `kasbah info`: name, version, build stamp, os/arch, binary path and how it
      was installed, state and log directories, and the docs URL at the
      version tag (`…/tree/vX.Y.Z/docs`); the latest debug log once
      [[debug-trace-and-log]] exists
- [ ] `kasbah info USER@HOST`: the server's kasbah version, Docker and compose
      versions, OS, through a `kasbah remote` arm
- [ ] in `commands` (cmd/kasbah/usage.go) so `kasbah help info` works; rig
      test for the host form; docs/cli.md
