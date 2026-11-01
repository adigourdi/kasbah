---
description: The default cert resolver is named for the CA, not the challenge
cause: Inherited from the original project; frozen at 1.0.0 before DNS-01 existed
where: templates/traefik, check T04, mail fragment, docs, CLAUDE.md
state: ready
priority: high
urgency: Nothing is deployed and public history restarts at a new v1; after that the name is frozen for real
---

## Prompted by

Design review, 2026-11-01. DNS-01 resolvers will be named after their provider
(`cloudflare`, `ovh`), so every resolver name says *how* the certificate is
obtained, except the default, which says *who* issues it. The same CA issues
all of them, and `letsencrypt` becomes wrong the day `caServer` points
elsewhere. The user asked whether to rename to `http`; the answer was no while
servers were in the field, and yes once it was confirmed none are: "there's
nothing already deployed, does this change your opinion?"

## Evidence

- `CLAUDE.md:80` lists `certresolver letsencrypt` under frozen contracts.
- `docs/compliance.md` T04: routers on `websecure` reference `tls.certResolver: letsencrypt`.
- 50 files name `letsencrypt` (Go, templates, docs, suites, fixtures).
- `acme.json` keys stored certificates by resolver name: a rename on a live
  server reissues every certificate once. Acceptable for the one dev VPS.

## Work

- [ ] `http` in `templates/traefik/traefik.yml`, `_shared.yml`, the mail fragment, `init-project`'s starter, fixtures
- [ ] T04 requires `http`; a fragment still saying `letsencrypt` fails naming the rename, not "unknown resolver"
- [ ] Docs: `traefik.md`, `compliance.md`, `server-setup.md`, `cli.md`, `files.md`; `CLAUDE.md` frozen contract reads `http`
- [ ] Re-run `server init` on the dev VPS and redeploy its projects

## References

- [[acme-dns-resolvers]] builds on the settled name and must land after this.
