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
- `cmd/kasbah` ~24/39, `selfupdate` ~18/42,
  `status` ~17/20, `install` ~14/27, `mail` ~14/22, `release` ~14/23,
  `destroy` ~11/21, `migrate` ~10/16, `upgrade` ~10/29, `drop` ~10/23
- smaller: `mailreg` 5, `ops` 4, `serverlock` 4,
  `initproject` 4, `tmpl` 4, `vlog` 2, `history` 2, `info` 1
- still bare inside the swept packages (~209, mostly deliberate): argument
  checks that state the rule, "see above", malformed server answers, internal
  errors; among the rest, `serverinit/backup.go`'s "see above" layout and
  start failures, `buildpush/tags.go` "already
  holds … as another build", the `serverbin` apps-path and machine refusals
- failure messages still naming a doc file (CLAUDE.md: `kasbah help` is the
  pointer): `internal/ops/ops.go:207,341`, `internal/destroy/destroy.go:559`,
  `internal/drop/drop.go:461`
- cause-dropping sites allowed on purpose: `dropsCause` in
  `internal/cli/cause_test.go`

## Ruled (2026-11-17)

- The idiom of the main-path sweep: `.Help(topic|rule|command)` where a
  `kasbah help` topic explains it, `.Next(…)` (or the step inline when it
  reads as one sentence) for a concrete command, flag or file; argument checks
  that state the rule, "see above" failures and `internal:` errors stay bare.
- Tests: messages existing suites (`tests/`, `tests/integration/`) check are
  updated with them; a next step computed from data gets a unit test; a
  literal one does not.
- `docs/troubleshooting.md` gains an entry only for a failure a new user is
  likely to meet (install, self-update, restore), generic.
- No guard test for next steps: review is the guard.
- Messages that name a doc file, failures or not, point at `kasbah help`.
- Units: (backup/prune/state/restore flags done); selfupdate/install/upgrade/release;
  cmd/kasbah/status/info/history/vlog/initproject/tmpl;
  mail/mailreg/destroy/drop/migrate/ops/serverlock; the swept packages'
  leftovers and what remains of `dropsCause`.

## Work

- [ ] sweep each package above, command by command, as the main paths were
- [ ] shrink `dropsCause` where a site can carry its cause after all
