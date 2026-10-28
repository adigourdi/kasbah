---
description: >
  `--with-mail` starts direct port-25 delivery with nothing checking DKIM or
  reverse DNS, so mail from a fresh VPS lands in spam and the operator blames
  kasbah. Print a DKIM/PTR checklist at the end of `server init --with-mail`
  and have `check --server` warn when a claimed domain has no DKIM key, in
  internal/serverinit, internal/check and mail.md.
state: ready
priority: low
---

## Prompted by

Design review, 2026-10-28. User kept direct delivery as the default ("not my
problem if the user chose to have it … a cheap start, and they migrate
later"); only the cheap guards were agreed. The project's own server had no
DKIM keys generated at Phase 10's close (`docs/phases/README.md`).

## Work

- [ ] init's mail summary ends with the setup-guide pointer plus a three-line checklist: DKIM (`setup config dkim`), PTR matching the hostname, SPF
- [ ] `check --server` mail rule: a domain in the registry with no key under the Rspamd DKIM override → warn
