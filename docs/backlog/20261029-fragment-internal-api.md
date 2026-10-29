---
description: >
  A project's `traefik-dynamic.yml` can route a hostname to `service:
  api@internal` and publish Traefik's API and dashboard with no auth — `server
  init --no-dashboard` does not stop it, and no compliance rule refuses it.
  Add a T-rule failing any project router whose service is an `@internal` one
  other than `noop@internal`, in internal/check and compliance.md.
state: ready
priority: normal
---

## Prompted by

Found while building `dashboard-optional` (2026-10-29): "`traefik.yml` keeps
`api.dashboard: true` without `api.insecure` … Gap (existing before this
change): no compliance rule stops a project fragment from setting `service:
api@internal`." Turning the dashboard off is only half a promise while any
project can route to the API itself.

## Work

- [ ] new T-rule (next free id): a project fragment router whose `service` ends
  in `@internal` and is not `noop@internal` fails, naming the router
- [ ] local and `--server` runs alike; tests in internal/check and tests/check_test.sh
- [ ] docs: compliance.md Traefik table; traefik.md "What projects may NOT do"
