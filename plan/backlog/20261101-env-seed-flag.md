---
description: A first deploy, or one whose template gained keys, needs a TTY
cause: The env generator answers only from a TTY; --on-drift skips new keys
where: internal/env, internal/deploy, remote setup-env, env-template.md
state: ready
priority: normal
---

## Prompted by

Design review, 2026-11-01. `docs/env-template.md:180` already concedes "a first
deploy needs a terminal even for a project with zero variables". The user
wants a file of actual values the operator writes, passed as an argument rather
than a manifest field ("I don't like adding it to the yml for a one time
thing, better as an argument --env-seed=file"), and consumed whenever the
server's `.env` lacks a key the template has, not only on the first deploy.
Having `kasbah env` write the seed was rejected: it invites secrets into git.

## Evidence

- `docs/cli.md:1048`: `--on-drift=` is not a way to run `kasbah env` headlessly; the missing-`.env` case still needs a TTY.
- `env set` already reads one value from stdin without a TTY, with size and sha256 on stdin (`cli.md:1056`).

## Work

- [ ] `--env-seed=<file>` on `deploy` and `env`; plain `KEY=value`, refused when group or world readable
- [ ] Sent like every stdin install (size, sha256); whenever the generator would ask a key, the seed answers first
- [ ] A key already set in `.env` is never touched; seeded keys not asked are counted in one line, never printed
- [ ] Headless: a key asked and not seeded fails naming it (exit 5), as today
- [ ] Docs: `env-template.md`, `cli.md`; suite under `tests/`
