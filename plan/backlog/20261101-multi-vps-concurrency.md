---
description: Operating many projects on many servers is one serial command each
cause: Every command takes one project directory and one USER@HOST
where: cmd/kasbah, internal/deploy, internal/buildpush, docs/cli.md
state: parked
priority: low
---

## Prompted by

The migration of `docs/roadmap.md` into `plan/` on 2026-11-01. Its "Phase 5 —
v1.x" list carried one line never planned anywhere else: "Concurrency for
multi-VPS operations (deploy to N servers)". Filed so the idea survives the
roadmap's deletion; nothing has asked for it yet.

## Evidence

- `docs/overview.md` (Scope → Out): each project targets exactly one VPS, and a
  fleet is many projects × many VPSes covered by per-project `user@host`
  targeting. Concurrency here means running several such project deploys at
  once, not one project on many servers.

## To decide

- Whether this is a kasbah feature at all, or a shell loop over projects.
