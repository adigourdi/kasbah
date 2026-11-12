---
description: >
  kasbah now makes each mail domain's DKIM keys and renders the signing
  override, but there is no command to repair or rotate them, the setup guide
  still prints placeholders and tells the operator to run the keygen and edit
  the override by hand, and M04's remedy names those hand steps. Add `server
  mail-dkim`, and true the guide and M04, in internal/mail, internal/check and
  docs/mail.md.
state: ready
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

## Ruling (2026-11-12)

1. **Both.** `add-mail-domain` generates the domain's two keys (rsa selector
   `mail`, ed25519 selector `ed`) and writes its signing block; `server init
   --with-mail` does the same for the primary domain. Neither ever replaces a
   key that exists. A new `kasbah server mail-dkim USER@HOST <domain>` repairs
   or rotates: it keeps existing keys by default; replacing them is a prompt
   answered by `--replace-keys` / `--keep-keys`, and without a TTY it fails
   naming both. DNS stays the operator's.
2. **The override is rendered whole** from the registry plus the keys present
   (one writer, like the mail `.env`). When the file on disk differs from what
   kasbah renders, the old one is saved beside it as
   `dkim_signing.conf.kasbah-prev` (Rspamd never loads it) and the output
   names it.
3. **Keys come from the docker-mailserver image's own `rspamadm`** in a one-off
   container, so the files match what `setup config dkim` writes and generation
   works before docker-mailserver first starts.

## Work

Key generation (`add-mail-domain`, `server init --with-mail`) and the rendered
signing override landed; what remains:

- [ ] `kasbah server mail-dkim USER@HOST <domain>`: repair (make missing keys,
      derive missing public files, re-render the override) and rotate
      (`--replace-keys` / `--keep-keys`, prompt, no TTY fails naming both)
- [ ] mail-setup-guide prints the real TXT values when the keys exist, the
      placeholder only when they do not; its step 2 no longer tells the
      operator to run `setup config dkim` or hand-edit the override (both now
      harmful: DMS refuses existing keys, and a hand edit goes to -prev)
- [ ] M04's remedy names `server mail-dkim` instead of the hand steps;
      docs/compliance.md M04 row; rig test; docs/mail.md, cli.md
