---
description: Nothing watches whether a deployed project's domain still answers
cause: Monitoring is out of scope; no stack or config is generated for it
where: a new kasbah monitor command, project manifests, docs/overview.md
state: parked
priority: low
---

## Prompted by

The migration of `docs/roadmap.md` into `plan/` on 2026-11-01. Its unphased
backlog carried: "Uptime monitoring: a Gatus stack on a separate operator VPS,
its endpoint config generated from project manifests (`kasbah monitor sync`).
Config-file-driven on purpose — same philosophy as the Traefik fragments.
Deliberately deprioritized."

## Evidence

- `docs/overview.md` (Scope → Out) lists metrics, log aggregation and uptime
  monitoring as out of scope; this item is the one shape that was ever sketched.
