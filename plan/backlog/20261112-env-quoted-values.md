---
description: >
  kasbah's reading of quoted .env values still differs from compose's in edge
  cases: compose treats a quote with a backslash before it as escaped (so
  `A='a\'b'` reads differently, and compose refuses `A="a\\"`), and a
  multi-line quoted value is only half-replaced by `kasbah env set`. Match
  compose, in internal/envtpl (dotenvValue) and internal/env (env set).
state: needs-decision
priority: low
---

## Prompted by

2026-11-12, while making kasbah read `KEY = value` lines as compose does:
measuring compose with `docker compose config` turned up these two remaining
differences, both in quoted values.

## To decide

1. **Existing values.** Matching compose changes what kasbah reads for a value
   that holds `\'` or ends in `\\"` today: is reading them as compose does (the
   value the container actually gets) worth a different reading in drift and
   `check --server` for such a file?
2. **Multi-line values in `env set`.** Replace the whole quoted span, or refuse
   to set a key whose current value spans lines?

## Work

- [ ] dotenvValue's quote handling matches compose's (measure first)
- [ ] env set replaces a multi-line quoted value whole (or refuses, per 2)
- [ ] tests; docs/env-template.md
