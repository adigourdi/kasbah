---
description: A project fragment cannot take a secret from the project's .env
cause: deploy ships traefik-dynamic.yml verbatim; Traefik renders only its env
where: docs/traefik.md (Project fragment), internal/deploy fragment sync
state: needs-decision
priority: normal
urgency: the lab RPi's remote routes need a basic-auth users line at cutover
---

## Prompted by

Planning the lab RPi's move to kasbah. Its remote hosts sit behind a basic-auth middleware whose
users line comes from `TRAEFIK_BASIC_AUTH_USERS` through `{{ env "…" }}` in a dynamic file — the
lab's own Traefik container carries that variable. Under kasbah the fragment is shipped as-is
and the shared Traefik's environment holds only DNS provider credentials, so the hash would
have to sit in the fragment literally. The user: "I think traefik can do it natively, backlog
this so we either check it's possible and put in docs, or we build the feature to transpose if
easy/possible".

## Evidence

- `docs/traefik.md` (Project fragment): `deploy` syncs `traefik-dynamic.yml` to
  `/apps/traefik/dynamic/<name>.yml` out of band; `docs/build-deploy.md` step 9 ships its
  content unchanged.
- Traefik renders a dynamic file as a Go template first (`docs/traefik.md`, TLS), and
  `{{ env }}` reads the Traefik container's environment — kasbah's holds the `--acme-dns` env
  files and nothing per project.
- Kasbah already reads `{{` in a fragment as uncertainty: the plain-HTTP verdict
  (`docs/traefik.md`, TLS) and `--no-acme-dns` (DNS-01) both treat such a file as naming
  anything, so a templated fragment costs those two checks.

## To decide

1. **Does Traefik offer a native way that needs no kasbah feature?** Candidates to check
   against Traefik v3: `basicAuth.usersFile` pointing at a file the shared Traefik can read
   (where would a project put it, and who owns it); a secret passed some other way the file
   provider resolves. If one works, the outcome is a documented recipe in `docs/traefik.md`
   and `docs/authoring.md`, and this item closes.
2. **If not, should deploy transpose?** E.g. `${VAR}` in `traefik-dynamic.yml` filled from the
   server's project `.env` at sync time — which keys may be used (template keys only?), how a
   missing key fails, whether the rendered file or the template is what `check` reads, and
   how the T rules and the two `{{`-based verdicts treat it.

## Options

- **Literal value in the fragment** — works today; a hash is not the password, but it lives in
  the project repo.
- **Native Traefik mechanism** — zero kasbah code if one exists; needs a recipe and a check that
  kasbah's rules accept it.
- **Deploy-time substitution from `.env`** — one place for secrets, matching how compose reads
  `.env`; new surface in deploy and check.
