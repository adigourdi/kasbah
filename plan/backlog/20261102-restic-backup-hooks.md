---
description: Off-box backups copy data/ whole; no fresh dump is taken nightly
cause: restic ships mount points as they are; dumps only come from deploys
where: internal/backup, docs/backup.md, docs/cli.md, docs/server-setup.md
state: ready
priority: medium
---

## Prompted by

The /interview that designed rollback backups (2026-11-01/02, now in `docs/build-deploy.md`). Two findings came out
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

1. **restic ships only backups.** A project's repo gets `backups/` (the per-version
   backup tarballs) and the current `.env`, and no longer
   `/apps/data/<name>/`. Whatever a project wants kept off-box, its `backup` hook
   writes.
2. **The mail repo is unchanged.** Mailboxes are kasbah's own stack and can't be
   rebuilt from git.
3. **Restore is rewritten:** after a lost server, recovery means pulling the backups
   and loading your own dumps (through the `restore` hook), not restoring `data/`
   wholesale.
4. **Fresh dumps come from the `backup` hook.** Each nightly run first runs every
   project's `backup` hook into a fresh backup of the live version, under the backups'
   retention rule (`docs/build-deploy.md`), and then pushes.
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
6. **`kasbah backup <user@host>`** takes a backup of the live version (the snapshot
   plus the `backup` hook, read from `.kasbah-hooks.json`), applies the backups'
   retention, then pushes with restic when the server has
   `--with-backup`; without it the backup stays local. The nightly job runs exactly
   this on the host.
7. **`kasbah restore <user@host>`** pulls the project's backups from the newest restic
   snapshot (or a chosen one), takes the newest backup (or a named one), asks on the
   `.env` key diff and on data loss (`--with-env/--no-env`, `--with-data/--no-data`),
   then runs the live version's `restore` hook (from `.kasbah-hooks.json`). After a
   lost server: init, deploy, then restore.
8. **A failed nightly `backup` hook** still pushes what `backups/` holds, records the
   run as failed naming the project, and `B01` / `server status` show it.

## The launch, proven on the rig (2026-11-02 spike)

Both ways worked on the rig as the deploy user: a launcher container started through
the socket, and the scheduler chrooting itself. The launcher container is the one
chosen.
- **Launcher container.** Created through the Engine API, since the image has no
  docker CLI:
  - image: the pinned restic image
  - `Binds: ["/:/host"]` (rw, for the job's lifetime only), `NetworkMode: host`
    (hooks reaching `127.0.0.1` need it)
  - private pid namespace: **never `--pid host`**, because stopping a hung job
    then wedged dockerd for ~5 minutes
  - `Init: true`, not privileged, the default caps (SYS_CHROOT, SETUID and SETGID
    are enough)
  - a label, so a restarted scheduler finds leftovers and stops them
  - exit code read from `/containers/{id}/wait`, container removed afterwards
- **Entering the host as the deploy user.**
  - `chroot /host setpriv --reuid=U --regid=U --init-groups --reset-env sh -c
    'umask 002; cd <apps>/<name> && …'`.
  - `runuser -u` leaks the container's environment (`KASBAH_BACKUP_*`), and `su -`
    sources login profiles.
  - Untested alternative: make the launcher's entrypoint the static kasbah binary
    (`/host<apps>/.kasbah/bin/kasbah`), doing chroot, setgroups and setuid itself
    through `SysProcAttr`. That avoids depending on the host's `setpriv` and is
    preferred if it works.
- **The job's environment.** Set `umask 002` explicitly (the job inherits its
  parent's), `cd` itself (`PWD=/`), and expect PATH `/usr/local/bin:/bin:/usr/bin`,
  no profile and the C locale. Under a private pid namespace `ps` and `pgrep` fail
  in hooks (procps "lookup self"); document it.
- **Bounding a hung job.** Use two layers:
  - inside the job, `timeout -k 30 <deadline>`, because the launcher outlives a
    scheduler restart;
  - from the scheduler, an API stop with a short grace period, then delete.

  A process that a hook started inside a service with `docker compose exec` survives
  either kill, and nothing on the job side can reach it. So the hook docs tell
  authors to bound commands inside the service, e.g.
  `docker compose exec -T db timeout 600 pg_dump …`.
- **restic stores a symlink as the link**, whatever the trailing `/` or `/.`. So
  kasbah resolves `backups/` (`filepath.EvalSymlinks`) before handing it to restic,
  and `docs/backup.md` says so.
- **Security cost, documented rather than avoided.** The scheduler holds the Docker
  socket, which is host root. Anyone who can replace `<apps>/.kasbah/bin/kasbah`
  (`deploy:kasbah 775`) can become host root through it. Every operator is already
  in `docker` (`docs/server-setup.md` → Operators), so this adds no access an
  operator lacks today. It is written down in `backup.md` and `server-setup.md`.

## References

- `docs/backup.md` → The schedule, Scope, Restore
- `docs/server-setup.md` → With backup
- `internal/backup/`
- `docs/build-deploy.md` and `docs/project-manifest.md` — the hooks, the backup tarballs, retention
