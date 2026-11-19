---
description: deploy of a missing tag says the server "ran" it, with no next step
cause: requireTag's text is written for rollback and lacks a .Next
where: internal/deploy/tagged.go (requireTag)
state: ready
priority: low
---

## Prompted by

The bare-host unit's rig pass (2026-11-19): `kasbah deploy 1.2.3 stevedore@rig` answered
`v1.2.3 is not a tag in this repository, and git fetch --tags did not bring it` followed by
"stevedore@rig ran 1.2.3, so the tag exists somewhere" — a deploy never ran on that server.

## Evidence

- `internal/deploy/tagged.go` `requireTag`: the `.Cont` lines name `r.target+" ran "+r.version`
  for both modes; the failure carries no `.Next`/`.Help` (CLAUDE.md: every failure says what to
  do).

## Work

- [ ] Rollback keeps "the server ran it, so the tag exists somewhere"; deploy says the tag is
      missing here and to create or fetch it (`git tag v<ver>` / `git fetch`), via `.Next`.
- [ ] A test per mode; the owning doc sentence (`docs/build-deploy.md`, the tagged flow) checked.
