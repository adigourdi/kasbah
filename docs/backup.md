# Backup — Off-VPS Disaster Recovery

Optional (`hosting server init --with-backup`). Everything else in hosting
survives a lost VPS via git plus a redeploy — except two things that exist
only on the VPS: **`.env` secret values** and **data bind mounts** (plus
the hook-produced dumps in `backups/`). This feature ships those off-box.

## Model

Each VPS **pushes** restic snapshots to S3-compatible storage on a daily
cron. No central coordinator — the same shape as the rest of hosting.

Why push, and not the alternatives:

- **Operator-machine pull** would require an always-on box holding SSH
  keys to every VPS — a crown-jewel target and a single point of failure
  for all backups at once.
- **VPSes backing each other up** puts one client's data on another
  client's machine, correlates failure when both sit at the same provider,
  and adds pairing topology hosting would have to manage.
- **Push with restricted credentials** keeps each VPS independent and
  needs no new infrastructure.

restic provides encryption at rest (client data never lands readable at
the storage provider), deduplication, and snapshot retention.

## Credentials

The credentials on the VPS are **append-only**: they can write snapshots
but not delete or overwrite them. A compromised VPS cannot destroy its own
history. Deleting (retention pruning) requires the full-access key, which
lives only on operator machines:

```
hosting server backup-prune user@host    # restic forget/prune with
                                         # operator credentials
```

(Exact command shape settles at implementation; the split — VPS writes,
operator deletes — is the design.)

## Repos — one per client

Repo path: `<repo_base>/<client>`, where `client` comes from the manifest
(`client:` field) and **defaults to the project name**. Projects that
declare the same `client` share a repo; projects that declare none get a
repo of their own — per-client degenerates gracefully into per-project.

Why: offboarding. A departing client is handed (or has deleted) exactly
one repo. No surgery inside a shared repo, no cross-client data in a
handover.

## Scope

Per project, each snapshot includes:

- `/apps/data/<name>/` — bind mounts (DB state, uploads, configs)
- `/apps/<name>/backups/` — hook-produced dumps
- `/apps/<name>/.env` — the only copy of the project's secrets

The manifest's `backup:` hook and this feature are complementary: the hook
produces *consistent* dumps (e.g. `pg_dump` before deploys); restic ships
*everything*, including those dumps, off the box. For databases, the dump
is the restorable artifact — a live bind-mount copy of a running Postgres
is crash-consistent at best.

## Cadence and retention (defaults, tunable)

- Daily snapshot at 02:00, with per-VPS jitter to avoid herding.
- Retention, applied by operator-side prune: 7 daily, 4 weekly, 3 monthly.

Both recorded in the server marker (`/apps/.hosting/server.json`).

## Restore

1. Fresh VPS: `hosting server init` (same flags as before).
2. `restic restore` the client repo into `/apps/data/<name>/`,
   `/apps/<name>/.env`, and `backups/`.
3. `hosting deploy` from the project repo.
4. Database projects: restore from the newest dump in `backups/` rather
   than trusting the live-file copy.

## Handover

`hosting server destroy` removes the cron and the S3 credentials from the
VPS — agency-owned secrets never transfer. The repos themselves are
operator property; export or delete per client as the offboarding deal
dictates.
