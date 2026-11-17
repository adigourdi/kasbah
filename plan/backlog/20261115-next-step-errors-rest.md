---
description: Server-side arms drop a failure's next step when they print it
cause: they print `%v` of the error, which leaves out next and help lines
where: each package's remote.go: serverinit, deploy, env, upgrade, drop, …
state: ready
priority: normal
---

## Prompted by

2026-11-15, the errors-say-next-step unit: the convention (cause, next step,
`kasbah help` pointer) and its tests landed with a sweep of the main paths
only, as ruled. A text heuristic over the rest found failures with no visible
next step.

## Evidence

Every package has had its sweep. What is left:
- server-side arms print their failure as `fail("%v", err)`, which drops a
  `*cli.Error`'s next step and help line; the backup and mail arms print
  `cli.Full(err)` instead. About 20 others do not (serverinit, deploy, env,
  upgrade, buildpush, prune, drop, destroy, status, check, serverlock): each
  needs a per-path check that the workstation does not already print the same
  step, so it is printed once
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
- Units: (backup/prune/state/restore flags and
  selfupdate/install/upgrade/release and
  cmd/kasbah/status/info/history/vlog/initproject/tmpl and
  mail/mailreg/destroy/drop/migrate/ops/serverlock done); the swept packages'
  leftovers and what remains of `dropsCause`.

## Work

- [ ] every server-side arm prints a failure's next step and help, once
