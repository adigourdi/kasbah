---
description: Off-box backups copy data/ whole; no fresh dump is taken nightly
cause: restic ships mount points as they are; dumps only come from deploys
where: internal/backup, docs/backup.md, docs/cli.md, docs/server-setup.md
state: needs-decision
priority: medium
after: rollback-points
---

## Prompted by

The /interview that settled [[rollback-points]] (2026-11-01/02). Two findings came out
of it:
- The user, on a media project: "in a selfhosted jellyfin it can be whole movies, so
  copying data can be dangerous". restic copies every project's data/ whole, movies
  included.
- Once the dumps moved into a project's `backup` hook, the newest off-box dump became
  the last deploy's. A project deployed monthly would have a month-old database
  off-box, even though restic runs nightly.

The user then split it out: "I think backup and restore should be linked to restic,
and not deployment, needs a separate backlog item".

## Evidence (today)

- restic snapshots `/apps/data/<name>/` whole, with no exclusions, plus `backups/` and
  `.env`; mail goes to its own repo (`docs/backup.md` → Scope).
- The scheduler is a kasbah-owned container (`kasbah-backup`) running
  `kasbah remote backup` nightly. It reads the server's files, but runs no project
  commands (`docs/backup.md` → The schedule).
- Recovering a lost server today means `restic restore` back onto `/`, then
  `kasbah deploy` (`docs/backup.md` → Restore).

## Decisions (settled, do not re-propose)

1. **restic ships only backups.** A project's repo gets `backups/` (the
   [[rollback-points]] tarballs) and the current `.env`, and no longer
   `/apps/data/<name>/`. Whatever a project wants kept off-box, its `backup` hook
   writes.
2. **The mail repo is unchanged.** Mailboxes are kasbah's own stack and can't be
   rebuilt from git.
3. **Restore is rewritten:** after a lost server, recovery means pulling the backups
   and loading your own dumps (through the `restore` hook), not restoring `data/`
   wholesale.
4. **Fresh dumps come from the `backup` hook.** Each nightly run first runs every
   project's `backup` hook into a fresh backup of the live version, under the
   [[rollback-points]] retention rule, and then pushes.
5. **The container keeps the clock; the host runs the job.** The user would rather not
   use a systemd unit, and cron isn't a prerequisite.
   - The `kasbah-backup` scheduler keeps everything it has today: the schedule and
     jitter, `restart: unless-stopped`, the healthcheck, the status record, `B01`.
   - At the scheduled time, it launches `kasbah backup` **on the host**: through the
     Docker socket, a short-lived container from the same pinned restic image mounts
     `/` and chroots into it, running as the deploy user. So the nightly job is exactly
     the manual command, with the server's own shell, `docker` and compose.
   - The socket is root-equivalent, which the deploy user's `docker` group membership
     already is. It's documented, not hidden.
   - Rejected: hooks inside the scheduler (needs a kasbah-built image), cron (a new
     prerequisite), a systemd timer (a system unit, and it assumes systemd), driving it
     from an operator machine (`backup.md` rejected that already), and no nightly
     hooks (the freshness gap).

## To decide

- **The launch, proven first.** Spike on the rig before building on it: the chroot
  launch as the deploy user from the restic image (busybox `chroot` has no
  `--userspec`, so how the user switch happens), and the signal and timeout path when
  a hook hangs (`--backup-timeout` bounds restic today, not hooks). If the spike fails,
  this decision reopens.
- **What `kasbah backup <user@host>` does.** Run the `backup` hook and push now? Or
  only run the hook (a local backup, pushed by the next nightly run)?
- **What `kasbah restore <user@host> [backup]` does.** Pull a chosen restic snapshot's
  backup and run the `restore` hook on the live version? What does it ask first, and
  which flags answer it?
- **A failed `backup` hook at night:** push the backups already there and record the
  failure for `B01`, or skip the push?

## References

- `docs/backup.md` → The schedule, Scope, Restore
- `docs/server-setup.md` → With backup
- `internal/backup/`
- [[rollback-points]] — the hooks, the backup tarballs, retention
