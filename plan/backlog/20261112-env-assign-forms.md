---
description: >
  Compose reads `KEY = value` and `KEY: value` lines in a .env, but kasbah's
  line reader (envtpl.Assign) only knows `KEY=value`: env drift does not see
  such a key as set, docs/env-template.md claims Compose parity it does not
  have, and check --server's port reading can only warn on those lines. Read
  both forms the way compose does, in internal/envtpl and docs/env-template.md.
state: ready
priority: low
---

## Prompted by

A review on 2026-11-12 of check --server's port reading (C12): with
`WEB_PORT = 8080` in the server `.env`, compose publishes 8080 while kasbah read
the default. The fix in that change makes check warn ("cannot be checked") on
any line it cannot read; this item makes kasbah read the line instead.

## Evidence

- `internal/envtpl/envtpl.go:27` — the `assign` regex: `KEY=` only.
- `docs/env-template.md:98` — "A line counts as setting a key if Compose would
  read it as one", false for `KEY = v` and `KEY: v`; drift (`KeysOf`) has the gap.

## Work

- [ ] Assign (and so Keys/KeysOf, ValuesOf) reads `KEY = v` and `KEY: v` as compose does — check compose's exact rules with `docker compose config` first
- [ ] lines of only no-break space (U+00A0, U+2007, U+202F) or one before a
      `#`: compose skips them as blank/comment, kasbah's `Space` does not — match
      compose there too
- [ ] tests; docs/env-template.md true
