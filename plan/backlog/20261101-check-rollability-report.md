---
description: No way to know before a deploy which services roll or recreate
cause: The roll predicate lives in the deploy engine and reports mid-run
where: internal/deploy/rolling.go, internal/check, docs/compliance.md
state: ready
priority: normal
---

## Prompted by

Design review, 2026-11-01. A routed service rolls only when a long list holds
(no `container_name`, a healthcheck, no host port, no `depends_on` condition,
the live fragment reaches it by service name or alias, health wait on). Most
existing compose files break at least one, so users will believe they have
zero-downtime deploys and will not. Agreed: "okay for the roll check report".

## Evidence

- `internal/deploy/rolling.go:153` `rolls()` computes the predicate; the deploy
  names a non-rolling service with why, but only mid-run.

## Work

- [ ] Extract the predicate so `check` can evaluate it from `compose.prod.yml` and the fragment
- [ ] One informational line per routed service: rolls, or will recreate in place because <first failed condition>
- [ ] Rule documented in `compliance.md`; the engine keeps using the same predicate
