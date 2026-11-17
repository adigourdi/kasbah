---
description: A few failures in swept packages still lack a true next step
cause: leftovers each package sweep found outside its own scope
where: internal/serverinit, serverbin, buildpush, marker, mail/remote.go
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
- still bare inside the swept packages (~209, mostly deliberate): argument
  checks that state the rule, "see above", malformed server answers, internal
  errors; among the rest, `serverinit/backup.go`'s "see above" layout and
  start failures, `buildpush/tags.go` "already
  holds … as another build", the `serverbin` apps-path and machine refusals; `serverbin.Ensure`'s probe
  exiting 1 on a marker that is not a regular file (so `server status`'s own
  step for it never shows); `marker.Validate` saying "re-run `server init`"
  for a marker that is not an object, which `server init` refuses;
  `serverinit`'s handling of a mail registry it cannot parse, and the
  server-side `fmt.Errorf` texts in `internal/mail/remote.go`
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

- [ ] the leftovers in the swept packages, listed above
- [ ] shrink `dropsCause` where a site can carry its cause after all
