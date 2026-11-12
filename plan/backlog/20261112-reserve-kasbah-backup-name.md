---
description: >
  A project may be named `kasbah-backup`, which is the compose project name of
  kasbah's own backup stack; its deploy would then be refused as a name
  collision with that stack, and other commands could act on the backup stack
  as if it were the project. Reserve the name like `mail` and `traefik`, in
  internal/manifest and docs/project-manifest.md.
state: ready
priority: low
---

## Prompted by

A review on 2026-11-12 of the foreign-stack pre-flight: the name refusal is
correct for a project called `kasbah-backup`, but the name itself should never
have been accepted (internal/manifest/manifest.go ~:28 reserves others; the
backup stack's project is `kasbah-backup`).

## Work

- [ ] `kasbah-backup` (and any other compose project name kasbah's own stacks use) refused as a project name, naming why
- [ ] test; docs/project-manifest.md's reserved-names sentence
