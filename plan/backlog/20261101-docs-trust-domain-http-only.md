---
description: Unsaid in the docs: operator trust domain, HTTP-only routing
cause: Written for the maintainer; only an outside reader asks these
where: docs/server-setup.md Operators, docs/traefik.md TLS
state: ready
priority: low
---

## Prompted by

Design review, 2026-11-01. Two reader questions the docs can close in a
sentence each. The shared binary at `775` looks like a supply-chain hole until
one notes every operator is also in `docker`, which is root on the host, so
the `kasbah` group adds nothing. And "how do I opt out of ACME" is answered by
the fragment: a router on `web` with no `websecure` router gets no certificate,
and T08 only warns about it.

## Work

- [ ] `server-setup.md` Operators: membership in `docker` is root on this host; `kasbah` plus `docker` is one trust domain, the binary's mode changes nothing
- [ ] `traefik.md` TLS: HTTPS is per router; a `web`-only fragment serves plain HTTP; the redirect middlewares are a choice
