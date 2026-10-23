---
description: >
  The mail stack runs Cypht now, but the manifest still accepts
  `mail.snappymail_domain:`, a SnappyMail domain-config seed that deploy copies
  into a container that no longer exists. Remove the key, check rule M02 and the
  seed path in internal/deploy and internal/check.
state: ready
priority: normal
urgency: >
  Phase 9.3 (the original project's mail onto kasbah) has not started. If this lands
  first, the original project moves straight to Cypht instead of migrating its webmail twice.
---

## Prompted by

The user noticed that the latest `djmaze/snappymail` image is from 2024 and asked
why SnappyMail was chosen. Nobody chose it: it came over from the original project's `mail/`
with the rest of the stack, and `docs/mail.md:14` pins it because those two tags
were "known to work together". The options were weighed (keep the pin, build from
master, Roundcube, Cypht, no webmail). The user preferred Cypht for its
"Combined inbox for all your email accounts": you log in once and Cypht merges
the IMAP/JMAP/EWS accounts added in its settings into views like
Everything, Unread and Flagged. Roundcube has no such view; it only has
small third-party account-switching plugins.

## Evidence

Checked 2026-10-23:
- SnappyMail: Docker Hub and GitHub releases both end at v2.38.2 (2024-10-09).
  76 commits landed on master in the year since (CSP hardening among them) and
  none are released. One advisory is on record, GHSA-2rq7-79vp-ffxm (mXSS, medium,
  2024-09-16), probably fixed in v2.38.0.
- Cypht: started in 2014, it survived its founder's handoff to the `cypht-org`
  org (about 28 public members). It had ≥600 commits in each of the last two years,
  five contributors with 50+ commits in the last 12 months, about 20 releases in the
  last year (v2.13.0 on 2026-10-16) and a maintained 1.4.x line. The image is `cypht/cypht`.
- Cypht's risk: the contributors may share one funder. Several org members
  look like Tiki Wiki accounts (`marclaporte`, `tiki-jyhem`). Unverified.
- Cypht needs no database with `AUTH_TYPE=IMAP` (login checked against DMS) and
  `USER_CONFIG_TYPE=file`. Its default is `AUTH_TYPE=DB`, so this must be set
  explicitly (`config/app.php` upstream).
- Combined-view caveat: each combined view queries every account when it loads, so
  one slow account slows the whole view.

## Rulings (2026-10-23)

- **Client: Cypht.** Its releases are "supported by Evoludata" (cypht.org footer), a
  company whose site runs on Tiki. Cypht is also Tiki's webmail, which gives it a
  reason to outlive one sponsor. Roundcube remains the fallback.
- **`snappymail_domain:` is removed outright** from schema 1: no `kasbah migrate`, no
  deprecation warning, no schema bump. Nothing uses it ("we're still in private
  testing"). With Cypht there is no per-domain config: every address on the server
  logs in at `webmail.<primary>` against the one DMS. M02 is retired, and the other
  M rule ids keep their numbers.
- **No SnappyMail migration code.** No production server runs it. `vps` (a test
  target) is purged by hand during verification. The mail start step runs `up -d
  --remove-orphans` so that a re-run converges when the template drops a service.
- **Modules (curated):** core, imap, smtp, account, profiles, imap_folders, contacts,
  local_contacts, nux, idle_timer, themes, history, saved_searches, advanced_search,
  inline_message, keyboard_shortcuts, tags, highlights, brute_force, recover_settings.
  `developer` is excluded: its server-information page shows the site config to every
  logged-in user. `XDEBUG_MODE=off`, because the image ships Xdebug with `mode=debug`.
- **Shape:** `mail-cypht`, `cypht/cypht:2.13.0`. `<data>/mail/cypht` is mounted at
  `/var/lib/hm3`. `AUTH_TYPE=IMAP` against `mail.<primary>:993` with TLS, and SMTP
  `mail.<primary>:465` with TLS: the certificate names only that host, as it did for
  SnappyMail. `SESSION_TYPE=PHP`, `USER_CONFIG_TYPE=file`, and SQLite
  (`DB_DRIVER=sqlite`, `DB_NAME=/var/lib/hm3/cypht.sqlite`), because the image's
  entrypoint exits after 10 failed tries when it cannot reach a database (observed).
  The container and health key are named for the client. Making them client-neutral
  is [[webmail-choice-flag]]'s concern.
- **Two commits:** U1 swaps the stack; U2 removes `snappymail_domain:` and deletes
  this item.

## Work

- [x] `templates/mail/compose.yml`: `mail-cypht` service, `_mail.yml` router, init's
      health wait, `server status`, setup guide, rig test, docs (U1)
- [ ] the manifest key: `internal/deploy` (plan, seed step, the remote's
      `snappymail` fact and `seed` verb, tagged-ref warning), `internal/check`
      M02, their Go and shell tests, the setup guide's pre-seed paragraph; docs
      `project-manifest.md`, `build-deploy.md`, `compliance.md`, `mail.md`
      (Per-app mail claims), `files.md` (seed rows) (U2)

## References

- `docs/mail.md` (Components, TLS flow, Per-app mail claims)
- `templates/mail/compose.yml:108`
- `docs/phases/09-adopt.md` task 9.3
- [[webmail-choice-flag]]
