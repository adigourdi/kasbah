---
description: Rollback restores a version's image and files, not its env or data
cause: .kasbah-prev is deleted on success; dumps rotate by count, not time
where: internal/deploy, docs/build-deploy.md, docs/project-manifest.md
state: ready
priority: medium
---

## Prompted by

A 2026-11-01 review of the old roadmap's leftovers. Dropping the "mirror VPS state into
git" idea led to a comparison with Kubernetes' rollout history, and the user asked for
"the possibility of reverting to a version with its .env or even data, and configuring
how many to keep, and if on same day or hour counts (if we deploy 5 times in a day,
does it delete our one per week history)". The design below was settled through
/interview in the same session.

Three corrections from the user shaped it:
- "we provide hooks for the user to do as they like": kasbah owns no restore logic.
- "in a selfhosted jellyfin it can be whole movies, so copying data can be dangerous":
  nothing copies mount points, on the server or to restic.
- "we drop the backup, check is not necessary": no `backup:` block, and every hook
  runs in the server's shell.
- "put back backup/restore commands which run the same as the deploy/restore hooks":
  `backup` and `restore` come back as hooks, in the same form as the other four.

## Evidence (today)

- Rollback restores the image, the sync targets and the Traefik fragment. It does not
  restore `.env` or `data/` (`docs/build-deploy.md` → What rollback restores).
- `.kasbah-prev/` already copies the outgoing `.env` and every sync target before a
  deploy overwrites them. It is deleted once the disk matches the live stack again
  (`docs/files.md`, the `.kasbah-prev` rows; `internal/deploy/snapshot.go`).
- The `backup:` block runs one `command` in one `container` and captures its stdout to
  `backups/pre-deploy-<stamp>.<ext>`. It is gated by `check` and rotated to the newest
  `retain` files, so frequent deploys evict older dumps
  (`docs/project-manifest.md` → `backup`; `internal/deploy/engine.go:765`).
- Hooks are `<container> <command>` strings, run as `docker exec -e VERSION
  -e PREV_VERSION -e DEPLOY_BACKUP <container> sh -c '…'`. They run inside the
  container, so they cannot see server paths (`internal/deploy/engine.go:898`).

## Decisions (settled, do not re-propose)

1. **Rollback points.** The `.kasbah-prev` snapshot is taken as it is today, at the
   start of every deploy and every rollback: the outgoing `.env` and every sync target.
   A failed run that reverts uses it up, as today. A successful run keeps it, whole,
   as the **outgoing** version's backup instead of deleting it. Taking it at the start
   is what captures `.env` edits made while that version was live.
2. **One file per backup.** During the run, the backup is a directory,
   `backups/<version>-<stamp>/`, holding the snapshot and whatever the hooks wrote.
   Once the run succeeds, it is tar-gzipped into `backups/<version>-<stamp>.tar.gz`
   (mode `660`, because it holds `.env`), the directory is removed, and `versions.log`
   field 4 names the tarball.
3. **Six hooks, all in the server's shell.**
   - The hooks are `backup`, `pre-deploy`, `post-deploy`, `restore`, `pre-rollback`
     and `post-rollback`, each a list of plain shell commands.
   - The `backup:` block (`check`, `container`, `command`, `pipe`, `extension`,
     `retain`) is dropped.
   - The `backup` hook writes into `$KASBAH_BACKUP_DIR` and runs exactly where the
     block ran: on every deploy, after the snapshot and before `pre-deploy`, against
     the outgoing containers. A hook that wants to skip tests for that itself.
   - The `restore` hook reads the target's unpacked backup. It runs during a rollback,
     after `pre-rollback` and before the target version comes up (decision 8).
   - Every hook runs on the server with the working directory set to the project
     folder `/apps/<name>/`, so `docker compose exec -T <service> …` works by service
     name. The backup directory is never the working directory, because compose would
     then need `--project-directory`.
   - The `<container> <command>` form and kasbah's service-to-replica resolution
     go away, and so does `HK01`.
   - kasbah never copies `data/`.
4. **Hook variables.**
   - `KASBAH_VERSION`, `KASBAH_PREV_VERSION` and `KASBAH_PROJECT` replace today's
     `VERSION`, `PREV_VERSION` and `DEPLOY_BACKUP`.
   - `KASBAH_BACKUP_DIR` is one name with two meanings. On a deploy, it is the backup
     directory being written (the `backup` hook writes there). On a rollback, it is
     the target's backup, unpacked, or `none` when the target has none.
   - The project's `.env` is not loaded into the hooks' environment.
5. **A failed pre-hook prompts.** When `pre-deploy` or `pre-rollback` fails, nothing
   has changed yet. The files are put back and the old stack keeps running, so kasbah
   asks whether to continue anyway. A `--with-x/--no-x` flag pair answers it (the name
   is chosen at implementation), and without a TTY the prompt fails naming the flag.
   A failed post-hook stays as today: no revert, `deploy-failed reason=post-hook`.
6. **Retention:** every backup from the last rolling 24 hours, plus the single newest
   backup older than that, and nothing else. No cap and no setting. restic covers
   longer history; these backups exist for recovering from a broken deploy.
7. **`.env` on rollback:** when the target has a backup, rollback lists the keys whose
   values differ (names only, never values) and offers restore, keep, or decide per
   key. `--with-env` answers restore and `--no-env` answers keep. Per-key choice is
   interactive only. Unset flags prompt, and without a TTY an unanswered prompt fails
   naming the flag. The managed `KASBAH_*` block is refreshed afterwards, as today.
8. **Data is the `restore` hook's job.** kasbah itself restores no data.
   - A rollback extracts the target's newest tarball into a temporary directory and
     passes it to the rollback hooks and the `restore` hook as `$KASBAH_BACKUP_DIR`.
     It cleans up as it goes and removes the directory on every path, signals
     included.
   - Order: `pre-rollback`, then `restore`, then retag and `compose up` the target,
     then `post-rollback`. The database is still reachable through the outgoing
     containers when the restore runs.
   - A restore throws away every write made since that backup, so rollback asks first.
     It asks when the target has a backup and the project has a `restore` hook.
     `--with-data` / `--no-data` answer the prompt, and without a TTY it fails naming
     the flag.
   - A hook that needs a dump that isn't there fails the rollback itself.
   - A rollback writes nothing into the outgoing version's backup: no safety dump.
9. **Off-box work is not here.** The nightly restic run, the manual
   `kasbah backup` / `kasbah restore` commands, and what restic ships are all in
   [[restic-backup-hooks]]: "backup and restore should be linked to restic, and not
   deployment".
10. **Image retention is unchanged** (3 months / last 3). Rolling back past the backups
    restores the image and files only, as today.
11. **Backups are server-only.** No restic in rollback.
12. **Nothing is frozen yet.** There is no production server and no migration path to
    keep: the manifest, the hook form, the hook variables and `versions.log` field 4
    change in place, and the schema is reset to v1 before release (the user's call).

## Work

- [ ] Docs first:
      - `build-deploy.md`: snapshot lifecycle, the deploy and rollback flows, what
        rollback restores, `versions.log` field 4.
      - `project-manifest.md`: the six hooks as server-shell commands, their
        variables, the `backup:` block removed.
      - `compliance.md`: `HK01` and the backup rules.
      - `files.md`: the `.kasbah-prev` and `backups/` rows.
      - `cli.md`: `rollback --with-env/--no-env`, `--with-data/--no-data`, the
        pre-hook flag pair.
- [ ] Hook runner: server shell, cwd `/apps/<name>/`, the `KASBAH_*` variables, the
      `backup` and `restore` hooks, and the continue prompt on a pre-hook failure.
- [ ] Engine: keep the snapshot on success as `backups/<version>-<stamp>/`, then
      tar-gzip it.
- [ ] Rollback: extract the target's tarball to a temporary directory, and remove it on
      every path; `.env` key-diff prompt and flags; the restore prompt and the
      `restore` hook between `pre-rollback` and up.
- [ ] Retention: rolling 24h plus the newest older backup, replacing `retain`
      rotation.
- [ ] Remove the `backup:` block from the manifest reader, from `check` and from the
      fixtures; make `kasbah check` refuse the removed keys.
- [ ] Tests alongside each of the above (suites and rig)

## References

- `docs/build-deploy.md` → A deploy that fails … reverts; What rollback restores;
  Rotation; `versions.log` format
- `docs/project-manifest.md` → `hooks`, `backup`
- `docs/files.md` → the `.kasbah-prev` and `backups/pre-deploy-*` rows
- `internal/deploy/engine.go` (`hooks`, `backup`), `internal/deploy/snapshot.go`,
  `internal/backup/`
