---
description: >
  A deploy that fails at `compose up` has already moved `:current` and
  records nothing, so the server runs the old containers while the tag names
  a version that never started. Have the engine retag back to the previous
  image id and bring the old stack up, and append a `deploy-failed` line when
  even that fails, in internal/deploy/remote.go and the vlog readers.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28: "`:current` moves before `compose up`, and a failed
`up` leaves no record." User: "can we revert the tagging instead? before
filling versions.log with consecutive failures". Agreed: revert first, log
only when the revert itself fails.

## Work

- [ ] engine records each built image's previous `:current` id before retagging; on `up` failure retags back and runs `compose up -d` of the old stack
- [ ] when the revert fails too: append `<ts> deploy-failed <version> no-backup kasbah=… digest=-` — `action` is a field value, the four positional fields are untouched
- [ ] `history` shows it; `rollback`'s implicit target and `prev_version` ignore `deploy-failed` lines; the deploy's failure message says which of the two states the server is in
- [ ] docs: build-deploy.md "A deploy that fails at `compose up`…" and the versions.log field list

## References

- `docs/build-deploy.md:131`, `internal/vlog`
