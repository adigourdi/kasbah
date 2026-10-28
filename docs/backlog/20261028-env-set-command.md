---
description: >
  Changing one secret on the server means re-running the whole interactive
  env setup or editing `.env` by hand over ssh. Add `kasbah env set KEY`
  (prompt for the value, write it through the managed-block-aware writer,
  offer `compose up -d`) beside the existing `kasbah env`, in internal/env and
  cli.md.
state: ready
priority: low
---

## Prompted by

Design review, 2026-10-28: "no rotation story (your own open question) …
`kasbah env set KEY` that edits in place and re-ups would cover 90%." User:
"do we have an existing `env` command already?" — yes, `cli.md:950`, the
drift/setup command; the single-key edit is what is missing. Closes roadmap's
open question about a separate `kasbah secrets`.
