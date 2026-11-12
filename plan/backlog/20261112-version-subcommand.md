---
description: >
  `kasbah version` is an unknown command; only `--version` and `-v` print the
  version. Accept `version` as a subcommand too, in cmd/kasbah and docs/cli.md.
state: ready
priority: low
---

## Prompted by

2026-11-12, verifying a fresh install: `kasbah version` failed with "unknown
command 'version'". Many CLIs take both forms, and `kasbah remote version`
exists on the server side.

## Evidence

- `cmd/kasbah/usage.go:102` — `-v`/`--version` only.

## Work

- [ ] `kasbah version` prints what `--version` prints, exit 0
- [ ] usage text, docs/cli.md, a test
