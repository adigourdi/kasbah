---
description: A server's kasbah-written state has no history beyond versions.log
cause: Nothing records how /apps/<project> files changed across deploys
where: internal/remote, the server's <apps> tree, docs/files.md
state: needs-decision
priority: low
---

## Prompted by

The migration of `docs/roadmap.md` into `plan/` on 2026-11-01. Its "Open
questions (to revisit)" held one: "Should the VPS state be mirrored into a git
repo owned by kasbah? (Audit trail, but adds complexity.)" Never decided.

## To decide

- Whether an audit trail of the server's files is wanted at all, given
  `versions.log` already records every deploy and rollback, and
  `.kasbah-prev` snapshots the files a run overwrites (`docs/files.md`).
- If yes: a git repo under `<apps>/.kasbah/`, or a plain archive per deploy.
