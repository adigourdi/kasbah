---
description: Leftover backup and kept-aside snapshot dirs pile up with .env unseen
cause: server status and check --server report neither kind of directory
where: internal/status, internal/check/server.go, docs/compliance.md
state: ready
priority: normal
---

## Prompted by

A confirming review in the rollback-backups run (2026-11-02): "`server status`
and `check --server` report neither kept-aside directories nor leftover backup
directories. Only the deploy warning and destroy's plan mention them, so they pile
up (each with `.env`) until destroy or `drop --prune`."

## Evidence

- A backup directory `backups/<v>-<stamp>/` is left when its tarball can't be
  written, and `.kasbah-prev.kept-<name>/` when moving the snapshot into it fails or
  is interrupted (`internal/deploy/backup.go`, `keep`/`keepAside`; `docs/files.md`
  rows for both).
- Retention prunes only tarballs (`pruneBackups`), and nothing else ever removes
  these directories except `server destroy` and `drop --prune`.

## Work

- [ ] `server status` lists each project's leftover backup directories and
      kept-aside snapshots (count and newest stamp).
- [ ] `check --server` warns for each (a new rule in `docs/compliance.md`), naming
      the path and that it holds a copy of `.env`.
- [ ] Tests alongside (status and check unit tests; a rig case that leaves one).
