---
description: Failures outside the main commands still stop at the cause
cause: the next-step sweep covered check, deploy, build-push, env, init, rollback
where: internal/backup, selfupdate, status, install, mail, release, destroy, …
state: ready
priority: normal
---

## Prompted by

2026-11-15, the errors-say-next-step unit: the convention (cause, next step,
`kasbah help` pointer) and its tests landed with a sweep of the main paths
only, as ruled. A text heuristic over the rest found failures with no visible
next step.

## Evidence

Rough counts (no next step / all failure sites), by package:
- `internal/backup` ~31/43, `cmd/kasbah` ~24/39, `selfupdate` ~18/42,
  `status` ~17/20, `install` ~14/27, `mail` ~14/22, `release` ~14/23,
  `destroy` ~11/21, `migrate` ~10/16, `upgrade` ~10/29, `drop` ~10/23
- smaller: `state` 6, `prune` 5, `mailreg` 5, `ops` 4, `serverlock` 4,
  `initproject` 4, `tmpl` 4, `vlog` 2, `history` 2, `info` 1
- still bare inside the swept packages (~209, mostly deliberate): argument
  checks that state the rule, "see above", malformed server answers, internal
  errors; among the rest, `restore` flag checks, `buildpush/tags.go` "already
  holds … as another build", the `serverbin` apps-path and machine refusals
- failure messages still naming a doc file (CLAUDE.md: `kasbah help` is the
  pointer): `internal/ops/ops.go:207,341`, `internal/destroy/destroy.go:559`,
  `internal/drop/drop.go:461`
- cause-dropping sites allowed on purpose: `dropsCause` in
  `internal/cli/cause_test.go`

## Work

- [ ] sweep each package above, command by command, as the main paths were
- [ ] shrink `dropsCause` where a site can carry its cause after all
