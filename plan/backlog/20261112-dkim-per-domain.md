---
description: >
  Adding a mail domain leaves its DKIM to the operator: add-mail-domain neither
  generates the two keys nor lists them in the signing override, check --server
  then asks for a hand edit of override.d/dkim_signing.conf, and the setup guide
  prints placeholders even when the public keys are on the server. Let kasbah
  own a domain's DKIM end to end, in internal/mail, internal/check (M04) and
  docs/mail.md.
state: needs-decision
priority: normal
---

## Prompted by

Joining three domains to a running mail stack on 2026-11-12. Each
`add-mail-domain` succeeded, then `check --server` warned once per domain,
naming two `docker exec mail-dms setup config dkim …` commands *and* "add its
signing block to …/rspamd/override.d/dkim_signing.conf" — a file kasbah seeded
for the primary domain at init and that the operator must now edit by hand.
`mail-setup-guide` printed `"<rsa-2048-mail-<domain>.public.dns.txt>"` where the
record goes, though the generated keys were already readable on the server.

## Evidence

- `internal/mail/cmd.go:24` — add-mail-domain touches the registry and
  `postfix-virtual.cf` only.
- `internal/check/server.go:647` — the M04 warning with the manual steps.
- `internal/mail/mail.go:138`–`139` — the guide's placeholder DKIM lines, and
  `:216` "The two DKIM lines are placeholders — paste …".

## To decide

1. **When keys are made.** At add-mail-domain (and init for the primary), or a
   separate `server mail-dkim <domain>` — generating is irreversible in effect
   once DNS holds the public half, so never regenerate over existing keys.
2. **Who writes the override.** kasbah renders the whole signing override from
   the registry plus the keys present, rather than appending blocks.

## Work

- [ ] key generation per domain (rsa `mail` + ed25519 `ed`), skipping existing keys
- [ ] the signing override rendered from the registry, one writer
- [ ] mail-setup-guide prints the real TXT values when the keys exist, the
      placeholder only when they do not
- [ ] M04 message without the hand edit; rig test; docs/mail.md, cli.md
