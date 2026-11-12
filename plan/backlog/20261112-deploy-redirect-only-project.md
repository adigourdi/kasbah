---
description: >
  A project whose fragment only redirects needs no container, but deploy always
  runs `docker compose up`, which refuses a compose file with no services ("no
  service selected"), so the fragment is never shipped. Let deploy, rollback
  and drop handle a service-less project in internal/deploy, and document it in
  docs/build-deploy.md and docs/traefik.md (Redirect-only router).
state: ready
priority: normal
---

## Prompted by

Adopting a domain onto kasbah on 2026-11-12 whose only job, under the proxy it
came from, was to redirect every request to an external URL — no backend.
`kasbah check` accepts such a project (`compose.prod.yml declares no services —
skipping Compose checks`), but a deploy cannot succeed: compose up fails before
the fragment lands. The workaround in use is a placeholder service — a
`busybox` that sleeps (no network, read-only, 8m) only so compose has
something to start.

## Evidence

- `docker compose -f compose.prod.yml up -d --remove-orphans` with `services: {}`:
  `no service selected`, exit 1.
- `internal/deploy/engine.go:478` (and `rolling.go:408`, `:433`) run compose up
  unconditionally; `internal/check/check.go:281` is the only place that knows a
  project may have no services.
- `docs/traefik.md` → Redirect-only router presents `noop@internal` routers as
  a first-class shape, and the file provider's stated advantage over labels is
  that "redirect-only routes have no container to host the labels".

## Work

- [ ] deploy: with no services, skip compose up, the health wait and the Traefik
      network attach; still copy aside, sync, log to versions.log and ship the
      fragment
- [ ] rollback and `deploy <version>` the same; drop removes the fragment and
      the project directory with no `compose down` to run
- [ ] `server status` and `check --server`: a service-less project is not
      "0/0 running" or a failure
- [ ] rig test: a redirect-only project deploys, answers its redirect, rolls
      back, drops
- [ ] docs: build-deploy.md, traefik.md (Redirect-only router), cli.md
- [ ] docs: say that a placeholder service is no longer needed
