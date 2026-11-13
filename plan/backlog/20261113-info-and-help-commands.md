---
description: The binary cannot say which docs match it, or how kasbah works
cause: only --help and `kasbah version` exist; `kasbah help` is unknown
where: cmd/kasbah, internal/cli, internal/check, docs/cli.md
state: ready
priority: high
---

## Prompted by

2026-11-13, discussing how users fix things without the source. Ruled out: a
Claude skill, a `kasbah docs` command printing the full docs. Chosen: `kasbah
info` and a git/go-style `kasbah help [topic]` holding what a skill would
have — summary level, never the full docs.

## Evidence

- `dist/kasbah help` → `unknown command 'help' — kasbah --help lists the commands`
- Rule IDs are inline strings across `internal/check` (`fix.go:141` …), not a
  table; compliance.md names 72 of them.

## Work

- [ ] `kasbah info`: name, version, build stamp, os/arch, binary path and how it
      was installed, state and log directories, the latest debug log, and the
      docs URL at the version tag (`…/tree/vX.Y.Z/docs`); a dev build links its
      commit, or main when the commit is not on GitHub. `kasbah version` stays
      the bare version
- [ ] `kasbah help`: what kasbah is, the project's files, the check →
      build-push → deploy flow, where debug logs go, the topic list
- [ ] `kasbah help <command>` = `<command> --help` (settled — do not re-propose
      a `help` that differs from `--help` for commands)
- [ ] `kasbah help <topic>`: `files`, `setups`, `rules`, `<rule id>`, `debug`,
      `troubleshooting` — each ends with its doc's URL at the version tag
- [ ] One rule table in internal/check that check, `help rules` and
      `help <id>` read; a test that IDs agree across check, help and
      compliance.md
- [ ] docs/cli.md; tests
