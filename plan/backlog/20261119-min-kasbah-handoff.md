---
description: A min_kasbah refusal stops the run even with a newer kasbah installed
cause: S09 only refuses; no hand-off like the newer-schema one
where: internal/manifest (Require), internal/launcher, docs/cli.md → Hand-off
state: ready
priority: normal
---

## Prompted by

The change that added `min_kasbah` (2026-11-19): its implementer noted that a manifest whose schema is
from a newer major hands the command to an installed newer kasbah, while `min_kasbah` "only
refuses, and `docs/cli.md` now says so. A hand-off to an installed version that meets it would be
a natural follow-up."

## Evidence

- A tag's kasbah.yml with a newer `schema` is refused (and `NewerSchema` passed up for hand-off)
  only after a rollback has connected, held the server and read its record
  (`internal/deploy/tagged.go`, `readRef` after `c.Dial`); only the tag's `min_kasbah` is checked
  before connecting (`tagMinKasbah`). A hand-off for either is best decided before the dial, the
  way `tagMinKasbah` reads the tag.

## Work

- [ ] When `manifest.Require` refuses for `min_kasbah`, hand the run to the newest kasbah
      installed under `~/.local/share/kasbah/<version>/` that meets it (same meets rule as S09),
      the way `NewerSchema` hands off; refuse as today when none is installed.
- [ ] `docs/cli.md` → Hand-off between installed versions, and the sentence saying `min_kasbah`
      only refuses, corrected in place.
