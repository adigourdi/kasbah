---
description: check --server and status call wildcard-covered hosts uncertified
cause: acme.FindIn matches a host to main or SANs by exact string only
where: internal/acme (FindIn, sansMatch), internal/check, internal/status
state: ready
priority: normal
urgency: the lab RPi's migration plans one DNS-01 wildcard per domain
---

## Prompted by

Planning the lab RPi's move to kasbah: every hostname, LAN and remote, is to be covered by a
DNS-01 wildcard (`*.lab.example.com` and the local domain's) rather than a growing list of SANs
— the user: "we need to see how kasbah handles subdomains that are covered by DNS-01 to not
appear as sans". `docs/traefik.md` (DNS-01) documents exactly that router shape, but the
certificate lookup behind `check --server` and `server status` would report every
`sonarr.lab…`-style host as having no certificate.

## Evidence

- `internal/acme/acme.go:104` — an entry matches when `main == domain || sansMatch(c, domain)`.
- `internal/acme/acme.go:142-146` — `sansMatch` compares each SAN to the host with `==`; a
  `*.example.com` SAN never matches `app.example.com`.
- `docs/traefik.md` (DNS-01) shows a router asking for `main: tenants.example.com`,
  `sans: ["*.tenants.example.com"]` and routing `HostRegexp(...)` subdomains to it — the shape
  whose hosts the lookup cannot find.

## Work

- [ ] Match a host against a `*.` SAN or main as one DNS label (`a.example.com` yes,
      `a.b.example.com` and `example.com` no), exact matches still preferred
- [ ] `check --server`'s cert rule and `server status` report the covering wildcard entry for
      such a host, with its `notAfter`
- [ ] Tests for exact, wildcard, deeper-label and apex hosts, and the docs that describe the
      lookup
