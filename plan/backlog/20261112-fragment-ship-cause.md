---
description: >
  When shipping a project's Traefik fragment fails, deploy and rollback report
  "could not ship traefik-dynamic.yml to <target>:<dest>" without the reason:
  the error SSH.Fragment returned is discarded, so the operator cannot tell a
  lost connection from a permission problem. Carry the cause into the message,
  in internal/deploy/deploy.go (fragment).
state: ready
priority: low
---

## Prompted by

A review on 2026-11-12, reading the route step while unrouted projects were
added: `internal/deploy/deploy.go` `fragment()` builds its failure from the
target and destination only (~:787-788), on every path that ships a route —
deploy, deploy <version>, rollback, and the post-hook failure message.

## Work

- [ ] the headline (or the line after it) carries `SSH.Fragment`'s error
- [ ] a test with a fake ship error asserting the cause is shown
