# Backup — Off-VPS Disaster Recovery

Optional (`kasbah server init --with-backup`). Everything else in kasbah
survives a lost VPS via git plus a redeploy — except two things that exist
only on the VPS: **`.env` secret values** and **data bind mounts** (plus
the hook-produced dumps in `backups/`). This feature ships those off-box.

## Model

Each VPS **pushes** restic snapshots to off-box storage on a daily
schedule. No central coordinator — the same shape as the rest of kasbah.

Why push, and not the alternatives:

- **Operator-machine pull** would require an always-on box holding SSH
  keys to every VPS — a crown-jewel target and a single point of failure
  for all backups at once.
- **VPSes backing each other up** puts one client's data on another
  client's machine, correlates failure when both sit at the same provider,
  and adds pairing topology kasbah would have to manage.
- **Push with restricted credentials** keeps each VPS independent and
  needs no new infrastructure.

restic provides encryption at rest (client data never lands readable at
the storage provider), deduplication, and snapshot retention.

**restic runs as a container**, never as an installed package —
`docker run --rm restic/restic:<pinned>`, on the VPS and on the
workstation alike. `server init` opens by promising it installs nothing and
hardens nothing, and that promise wins: no apt, no sudo, no binary
download, no distro assumption, and one restic version across every host.
The VPS already has Docker; that is the whole dependency.

## The schedule

A kasbah-owned compose stack at `<apps>/.kasbah/backup/` — one always-on
container, `restart: unless-stopped`, sleeping until the configured time
plus a per-VPS jitter, then invoking restic, then sleeping again. Not cron:
cron is not in the prerequisites table, and adding a row for it would be a
second thing a VPS must have. This is the same "kasbah owns a compose
stack" pattern as Traefik and mail, and it survives a reboot for the same
reason they do.

A failed run is **slept off, not exited** — exiting would turn one
unreachable storage endpoint into a container restart loop. That is only true
because **every restic invocation is bounded** (`--backup-timeout=`, default 900
seconds): an endpoint that accepts a connection and then answers nothing is
indistinguishable from a working one until something gives up, and without a
bound the run never reaches its next sleep at all — the container stays
"running" and backs nothing up, permanently.

The stack declares a **healthcheck** asking one question: has the state the
scheduler last recorded outlived its own deadline? A wedged run and a sleep that
never woke both fail it, so `docker ps` and `restart: unless-stopped` can both
see what `docker logs` alone would hide. Each run writes a record to
`<apps>/.kasbah/backup/state/status` — when it started and finished, how it
went, which repositories it touched.

**Three readers, one rule, two implementations.** `kasbah server status` prints the
record — the schedule, the container's state and health, when the last run was
and how it went, which repositories exist and which lack a password — and
`kasbah check --server` asks the same question as a rule (**B01**,
`compliance.md`), failing a stack whose last run failed or whose state has
outlived its own deadline. They share `lib/backup_record.sh`. The **third** reader is the container's own
healthcheck, which runs inside the stack and so cannot source a workstation
library — it carries its own copy of the same rule, in POSIX `sh`, and the two
are pinned against each other by a test driving the identical values through
both. That pin is what makes "they cannot disagree" true rather than hoped for:
a deadline one accepts and the other refuses is exactly how a report and a
healthcheck come to describe one file three different ways. Timestamps are judged against the **server's** clock, read in the same
round trip: a verdict computed against the workstation's would be a function of
clock skew.

**A restart resets what the record knows.** The runner holds the last run's
facts in shell variables, so a container that restarts — a reboot, a
`compose up`, a crash — writes its next `sleeping` record with no last run in
it. A stack that has backed up faithfully for months then reads as one that has
never fired, until its next run completes. `status` and B01 report that honestly
rather than guessing, which means **a warning for up to a day after any
reboot** is expected and is not a fault.

A safety mechanism nothing reads is indistinguishable from no safety mechanism,
which is why these readers exist at all — the healthcheck alone would have left
a stopped backup visible only in `docker logs`.

The runner takes three verbs, and they are the operator's interface to it
rather than a test hook:

```
docker exec kasbah-backup sh <apps>/.kasbah/backup/backup.sh once
docker exec kasbah-backup sh <apps>/.kasbah/backup/backup.sh plan
docker exec kasbah-backup sh <apps>/.kasbah/backup/backup.sh next
docker exec kasbah-backup sh <apps>/.kasbah/backup/backup.sh health
```

`once` backs up now, `plan` prints what would be included without writing,
`next` says when the next run is due, and `health` is what the healthcheck runs.
`once` writes the same record a scheduled run does, so a hand-driven backup
cannot leave the healthcheck believing something stale.

## Credentials

Two separate secrets, and confusing them is the most expensive mistake
available here.

**The storage credential** on the VPS is **append-only**: it can write
snapshots but not delete or overwrite them. A compromised VPS cannot
destroy its own history. Deleting (retention pruning) requires the
full-access credential, which lives only on operator machines:

```
kasbah server backup-prune user@host
```

kasbah **cannot create** an append-only credential — the operator makes one
at their storage provider, as a bucket policy or a server-side flag. So
`server init --with-backup` **proves** it instead: it writes a probe
repository, takes two snapshots, attempts a real delete, and counts the
snapshots again. If the count drops, the credential can delete, and init
**refuses and does not start the stack**. Three refusals with three
messages, because they have three remedies: cannot *reach* the repository,
cannot *write* to it, or **can delete** from it. The write attempt is the
paired positive — a credential that is merely wrong fails earlier and
differently, so "refused a delete" cannot be satisfied by "could not
connect".

**The repository encryption password** is a different thing and kasbah
never generates one. It is **operator-supplied, one per repository**, asked
once, stored mode 600 on the VPS, and **never rewritten** by a later run.
It has to be on the VPS — restic cannot write a snapshot without it — so
`backup-prune` fetches it over ssh when it needs it. That is not a
violation of the split above: the *storage* credential is what stays local.

**Keep the password off the VPS as well.** A repository whose only password
copy is on the machine you are backing up is unrecoverable in the exact
scenario the feature exists for. Repositories are the offboarding unit, so
one password per repository means a departing client's repository can be
handed over with its password without exposing any other.

**Never embed a credential in the repository URL.** `repo_base` is recorded
in the server marker, which is mode **644** by contract — a URL carrying a
secret is world-readable on the VPS. Credentials belong in the environment
block, which is mode 600.

## The repository URL is opaque

kasbah stores `repo_base`, a per-repository path, a password and an
environment block, and hands them to restic. It **never parses the URL** —
no scheme check, no host extraction, no path assumptions. That is what lets
one implementation serve an S3-compatible bucket in production and a
`rest:` endpoint in the test rig without either being a special case, and
it means any restic backend works if the operator wants one.

The base **must end in `/`**; it is concatenated, not joined.

## Repos — one per client

Repo path: `<repo_base><client>`, where `client` comes from the manifest
(`client:` field) and **defaults to the project name**. Projects that
declare the same `client` share a repo; projects that declare none get a
repo of their own — per-client degenerates gracefully into per-project.

Why: offboarding. A departing client is handed (or has deleted) exactly
one repo. No surgery inside a shared repo, no cross-client data in a
handover.

**The manifest is never synced to a server**, so the VPS cannot read
`client:` — `kasbah deploy` *renders* it instead, writing the effective
value to `<apps>/<name>/.kasbah-client` on every deploy. This is the same
rule `remote-deploy.sh` follows for hooks, backup and health: manifest data
reaches a server rendered, never copied. A project deployed **before**
backups were enabled has no such record and falls back to its directory
name — which is `client`'s documented default, so the fallback is correct
rather than a guess. The backup run **names every project that fell back**,
so a project quietly filing into the wrong repo is visible.

Two further repos exist beside the per-client ones:

- `<repo_base>mail` — the shared mail stack's data (below).
- `<repo_base>kasbah.probe` — the delete-probe's own repository. It holds
  no client data.

## Scope

Per project, each snapshot includes:

- `/apps/data/<name>/` — bind mounts (DB state, uploads, configs)
- `/apps/<name>/backups/` — hook-produced dumps
- `/apps/<name>/.env` — the only copy of the project's secrets

And, when the host runs the shared mail stack, into the `mail` repo:

- `/apps/data/mail/` — every mailbox on the host
- `/apps/mail/.env` — the stack's configuration and relay block

Mail gets a repository of its own rather than riding in the primary
domain's client repo: folding the whole host's mail into one client's
repository is exactly what the per-client split exists to prevent.

The manifest's `backup:` hook and this feature are complementary: the hook
produces *consistent* dumps (e.g. `pg_dump` before deploys); restic ships
*everything*, including those dumps, off the box. For databases, the dump
is the restorable artifact — a live bind-mount copy of a running Postgres
is crash-consistent at best.

**A repository with no password is not backed up** until init is re-run and
one is supplied. The run says so rather than skipping quietly.

## Cadence and retention (defaults, tunable)

- Daily snapshot at 02:00, with per-VPS jitter to avoid herding. The jitter
  is derived from the server's own identity, so it is stable across re-runs
  and the rendered file stays byte-identical on an unchanged host.
- Retention, applied by operator-side prune: 7 daily, 4 weekly, 3 monthly.

Both recorded in the server marker (`/apps/.kasbah/server.json`), whose
`backup` object **merges** on every write rather than being replaced — a
field written by a newer kasbah survives a re-run by an older one.

## Restore

1. Fresh VPS: `kasbah server init` (same flags as before).
2. `restic restore <snapshot> --target /` — the snapshot's paths are the
   server's paths, so this lands `/apps/data/<name>/`, `/apps/<name>/.env`
   and `backups/` where they belong.
3. `kasbah deploy` from the project repo.
4. Database projects: restore from the newest dump in `backups/` rather
   than trusting the live-file copy.

Step 2 is what makes step 3 possible: without `.env` back on the box, the
deploy's env step has nothing to deploy against and exits 5.

## Handover

`kasbah drop --prune` removes a project but **never** a repository password: if
it was that client's last project, the password stays at mode 600 and both
`server status` and `check --server` report it as an orphan. kasbah does not
delete it, because the password is the only thing that can ever open that
client's snapshots again — removing it on a drop would destroy the backups the
drop was careful to leave alone.

`kasbah server destroy` removes the scheduler stack and the credentials
from the VPS — agency-owned secrets never transfer. It does **not** remove
the repositories: they are operator property, and with an append-only
credential the VPS could not delete them anyway. Export or delete per
client as the offboarding deal dictates.
