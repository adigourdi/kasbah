---
description: check --server and status expect a certificate for a web-only host
cause: Cert rule and status line read every fragment Host(), routed on websecure or not
where: internal/check/server.go cert rule, internal/status/status.go, compliance.md
state: ready
priority: normal
---

## Prompted by

Review of the docs unit stating that a fragment with routers on `web` alone
serves plain HTTP (2026-11-01): the local `kasbah check` passes that shape, but
`check --server` warns "no certificate for '<domain>' … Traefik issues one when
a router claims the hostname" and `server status` prints "no certificate —
Traefik issues one when the hostname resolves here". Both are wrong for a host
no `websecure` router serves: no certificate will ever be issued, by design.

## Evidence

- `internal/check/server.go:712-714` — the no-entry warning.
- `internal/status/status.go:496`, called at `:869` for every `Host()` in the fragment.
- `docs/traefik.md` TLS bullet on web-only fragments currently states the warning.

## Work

- [ ] The cert rule and the status line skip a host that no `websecure` router claims (say so in one pass line / status line instead)
- [ ] Tests in `internal/check/server_test.go`, `internal/status/status_test.go`
- [ ] `docs/traefik.md` TLS bullet and `docs/compliance.md` `--server` row corrected
