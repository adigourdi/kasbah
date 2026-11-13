---
description: A failure can say what broke but not what to do about it
cause: no convention makes an error carry the next step; causes were dropped
where: internal/cli (Error, Fail, Cause), every command's failure paths
state: blocked
priority: high
after:
  - "[[info-and-help-commands]] — the `kasbah help …` pointers need a target"
---

## Prompted by

2026-11-13, after the first public release and a first real use on a VPS:
"only you managed to fix stuff by reading the source of this project here,
which is not a convenient approach for potential users". `f032d81` and
`8e186b6` gave the failures met that day their cause back; nothing keeps the
next failure from losing it, or from stopping at the cause with no way out.

## Evidence

- `internal/cli/cli.go:102`–`151` — `Error`, `Fail`, `Failf`, `Cont`,
  `Cause`, `Report`: the one path every failure leaves through.
- `internal/check/fix.go:141`–`203` — check's own lines already name a rule
  (`C01 …`) and the change to make; runtime failures mostly do not.

## Work

- [ ] Every failure states what failed, the underlying cause, and the next
      step: a flag, a command, or `kasbah help <topic|rule>`
- [ ] Settled: no links to doc files in messages — `kasbah help` is the pointer
- [ ] check's warn/fail lines end with `kasbah help <rule id>`
- [ ] Hard convention in CLAUDE.md; a test that a failure path keeps its cause
- [ ] Sweep the main paths: check, deploy, build-push, env, server init,
      rollback (settled); file the remaining call sites as their own item
- [ ] `docs/troubleshooting.md`, keyed by the exact error text, each entry the
      cause and the fix — generic, not one operator's history
