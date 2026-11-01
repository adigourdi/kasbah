---
description: HTTP-01 only: no wildcards, none when :80 is proxied or blocked
cause: traefik.yml renders one httpChallenge resolver; nothing adds another
where: internal/serverinit, templates/traefik, check T04, docs/traefik.md
state: blocked
priority: high
after:
  - rename-cert-resolver-http
---

## Prompted by

Design review, 2026-11-01: "we need a default way http for the server, and dns
opt in per service, feasible?" and "the dns provider or env should be by
domain, not all domains on the vps are surely on the same provider". Traefik
binds a resolver to a provider, not to a domain, and a fragment picks the
resolver per router, so the unit is one resolver per provider; routers opt in.

## Evidence

- `templates/traefik/traefik.yml:30` renders a single `certificatesResolvers` block.
- Provider credentials are the Traefik container's environment, so one Traefik
  holds one credential per provider. Two Cloudflare accounts cannot share it.
  Settled — do not re-propose: document the limit, scope the token at the provider.

## Work

- [ ] `server init --acme-dns=<provider>:<env file>`, repeatable; `--no-acme-dns=<provider>` removes one
- [ ] Env file copied to `<apps>/traefik/acme-dns/<provider>.env` mode 600; `env_file:` lines in Traefik's compose
- [ ] Each provider renders a resolver named after it with `dnsChallenge` and public `resolvers`; same `acme.json`
- [ ] Re-runs recover the resolver list from the server's `traefik.yml` like the other four recovered values
- [ ] T04 becomes "names a resolver"; `check` warns on a name other than `http`, `check --server` verifies against the server
- [ ] New server rule: `tls.domains` wildcard on a resolver without `dnsChallenge` fails
- [ ] Docs: `traefik.md` TLS gets a DNS-01 subsection with the one-credential-per-provider limit; `server-setup.md`, `cli.md`, `files.md`
- [ ] Rig proves rendering, plumbing and rules; first live wildcard on a real VPS, recorded in the phase findings

## References

- Example fragment opting in: router with `tls.certResolver: cloudflare` and
  `tls.domains: [{main: tenants.example.com, sans: ["*.tenants.example.com"]}]`.
