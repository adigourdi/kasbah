---
description: deploy and build-push push the version tag to origin by default
cause: Added for consistency between the server's version and the remote's tags
where: internal/deploy, internal/buildpush, build-deploy.md, cli.md
state: ready
priority: normal
---

## Prompted by

Design review, 2026-11-01. A deploy tool mutating a git remote by default will
draw a hostile issue in the first week. The user: "yeah bad move to be honest,
we did it to be consistent ... I guess we drop it" and "drop the push
altogether I think". Enforcing "tag must be pushed" was considered and rejected
as a requirement users would override anyway.

## Evidence

- `internal/deploy/deploy.go:51` offers `--no-git-push`; `:83` documents the push as the run's last step.
- `docs/build-deploy.md` flow step 6 (`build-push`) and step 11 (`deploy`).

## Work

- [ ] Remove the push and `--no-git-push` from both commands
- [ ] When the tag is not on origin, print one line saying the server runs a version origin cannot fetch; `pending`/`history` may repeat it
- [ ] Docs and suites updated
