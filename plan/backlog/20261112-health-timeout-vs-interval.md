---
description: >
  A compose healthcheck whose first probe comes after the manifest's
  health.timeout can never report healthy in time, so every deploy fails on
  health while the container is fine. kasbah check could see it statically
  (interval / start_period / start_interval against health.timeout) and warn,
  in internal/check's health section and docs/compliance.md (H rules).
state: ready
priority: low
---

## Prompted by

A first deploy on 2026-11-12: a placeholder service with
`healthcheck.interval: 60s` and `health.timeout: 30s` failed with
`did not become healthy within 30s — its last state was 'starting'`. Docker
runs the first probe one interval after start (or `start_interval` inside
`start_period`), so it was still `starting` at the deadline. Fixed by a 10s
interval; check passed it beforehand (26 passed, 0 failed).

## Evidence

- `internal/deploy/engine.go:981` — the health wait's failure message.
- `internal/check/check.go:1242` — the health section, which reads
  `health.container` and `health.timeout` but not the service's healthcheck
  timing.

## Work

- [ ] H rule: warn when the earliest possible healthy (first probe at
      `start_interval` if set inside `start_period`, else `interval`) is after
      `health.timeout`; say which to change
- [ ] durations as compose reads them (`1m30s`, `500ms`), and a healthcheck
      only in the Dockerfile is out of reach (as H01 already says)
- [ ] docs/compliance.md row, tests
