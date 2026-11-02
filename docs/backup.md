# Backup — Off-VPS Disaster Recovery

Optional (`kasbah server init --with-backup`). Everything else in kasbah
survives a lost VPS via git plus a redeploy — except what exists only on the
VPS: **`.env` secret values** and the project's data. The data travels as the
backup tarballs in `backups/`, which hold what the project's `backup` hooks
dump; this feature ships those and `.env` off-box, never the data bind mounts
themselves.

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
plus a per-VPS jitter, then having every project's `backup` hook run on the
host (below), then invoking restic, then sleeping again. Not cron:
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

### The backup hooks, nightly

Each run first takes a fresh backup of every project's live version, so the
newest dump off-box is last night's and not the last deploy's. The scheduler
cannot run a hook itself — the restic image has no shell tools, compose or
`docker` — so it starts a **launcher container** through the Docker Engine API
on the socket it mounts, `kasbah-backup-launcher`, from the same pinned restic
image:

- the host's `/` mounted at `/host`, read-write, for the job's lifetime only;
- the server's `<apps>/.kasbah/bin/kasbah` mounted read-only at `/kasbah`,
  its entrypoint. Docker resolves a mount's source on the host, so a
  symlinked apps path reaches the right binary;
- the host's network, so a hook reaching `127.0.0.1` reaches the host;
- a pid namespace of its own, never the host's: with the host's, stopping a
  hung job wedged dockerd; an init, no privilege and Docker's default
  capabilities;
- a `json-file` log with the scheduler's own limits (10 MB, 3 files), so the
  scheduler can read the job's report back whatever the daemon's default
  driver is;
- the label `kasbah.backup.launcher`.

As root in the launcher, `kasbah remote backup launch` resolves the user with
the host's own tools, run chrooted into `/host`: `id -u <user>`, `id -g
<user>` and `id -G <user>` give the uid, the primary group and every
supplementary group, all as numbers — never the names, which sssd or Active
Directory may give with spaces — and `getent passwd <user>` the home. They go
through the host's NSS, so a user from LDAP or sssd resolves as it does on the
host (the sockets those use come through the `/` mount). A host without `id`
is read from its `/etc/passwd` and `/etc/group`.
The launcher then chroots into `/host`, drops to that user with its groups,
and runs `kasbah remote backup host <apps> <seconds>`. So the nightly job runs
on the host, with the server's own shell, `docker` and compose — the host
needs no `setpriv` or `sudo` for it. A user the host does not have, or root,
is refused, and the run record says so and how the user was looked up.

**The user** is the backup user `server init --with-backup` records in the
marker's `backup.user`: the ssh user init runs as, unless `--backup-user=`
names another. Init looks it up the same way, through the host's `id`, and
refuses one the host does not have, or root. Membership is by number: the gid
`getent group kasbah` and `getent group docker` give (the host's `/etc/group`
without `getent`) among the user's groups. It warns, and goes on, about one
the job will run short as: not in the `kasbah` group and not the owner of the
apps path (the job cannot write the `backups/` of a project another operator
deployed), or not in `docker` (a hook that runs `docker` or compose fails).
Each warning comes with the root commands that fix it.

**What the job does**, for every project under the apps path — a directory
with a project's name, not one kasbah reserves — that has a
`.kasbah-hooks.json` and a live version: the same backup `kasbah backup`
takes (`kasbah remote deploy backup`, in-process), under the project's deploy
lock and the shared server lock, its `backup` hooks run from the project
directory. A project without either is skipped and said so. The job's
environment is its own: `umask 002`, `PATH=/usr/local/bin:/usr/bin:/bin`,
`LC_ALL=C`, the user's `HOME`, `USER` and `LOGNAME`, and nothing of the
scheduler's (`project-manifest.md` → Hooks).

**One deadline bounds the whole job**, `--backup-hook-timeout=` (default 1800
seconds, recorded in the marker), in two layers. Inside the job, kasbah itself
runs each hook as a process group of its own and, at the deadline, sends the
group SIGTERM and SIGKILL 30 seconds later; a project whose turn comes after
the deadline is not backed up and is named. From the scheduler, a launcher
still running 60 seconds past the deadline is stopped through the API (10
seconds' grace) and removed — the second layer, because the launcher outlives
a scheduler restart. A process a hook started inside a service with `docker
compose exec` survives both kills, which is why hooks bound what they run
there.

**Launchers left over.** A launcher is removed whatever happens to its run.
When the scheduler starts, it stops and removes every labelled launcher: none
can belong to a run then. Before each launch it removes only the ones that
have exited and the ones older than a whole job (the deadline and its 60
seconds); a younger one still running is another run's — a hand-run `once`
beside the nightly one, say — and is left alone. That run then launches
nothing: its record says a nightly job is already running, and the push goes
on, shipping what `backups/` holds.

**The results.** The job prints one line per project on its stdout, and the
launcher one line naming who it entered the host as, or why the job did not
start; the scheduler reads that stdout back from the launcher's log — its
last 4 MB, where the result lines are — into `docker logs kasbah-backup`. The
hooks' own output is on the job's stderr; the scheduler reads its last 64 KB
too, and when a project failed or the job did, writes it into `docker logs
kasbah-backup` after the results, between a line naming it the launcher's
stderr tail (saying it was cut, and to how many bytes, when it ran past
64 KB) and an end line. A run that worked shows none of it, and the rest
goes with the launcher's log. That tail stays in the scheduler's own log
(json-file, 10 MB × 3), which root and anyone in `docker` can read with
`docker logs`: a hook that prints a secret on failure leaves it there.

A project whose hook failed or ran past the deadline, or whose backup was
refused — under a deploy's lock, or beside a `.kasbah-prev/` snapshot a
deploy left (whose message says whether to let a run finish or to remove a
stale one by hand) — is recorded in the run record by name with its
reason. **The push runs regardless**, shipping what `backups/` holds, the
project's older backups included, and the run is recorded as failed: `kasbah
server status` and B01 name each project and why. A launcher that could not
start — no socket in the container, the image missing, no backup user, a user
the host does not have — or a job that failed as a whole — it ran past its
deadline, exited without naming a project, or its log could not be read back —
fails the run the same way, with that reason, and the push still runs.

The stack declares a **healthcheck** asking one question: has the state the
scheduler last recorded outlived its own deadline? A wedged run and a sleep that
never woke both fail it, so `docker ps` and `restart: unless-stopped` can both
see what `docker logs` alone would hide. Each run writes a record to
`<apps>/.kasbah/backup/state/status` — when it started and finished, how it
went, which repositories it touched, each project whose backup failed on the
host, and why the nightly job failed as a whole when it did. A running
run's deadline covers the hooks' deadline as well as restic's.

**Three readers, one rule, one implementation.** `kasbah server status` prints the
record — the schedule, the container's state and health, when the last run was
and how it went, which repositories exist and which lack a password — and
`kasbah check --server` asks the same question as a rule (**B01**,
`compliance.md`), failing a stack whose last run failed or whose state has
outlived its own deadline. They share one parser, `internal/backuprec`. The **third** reader is the container's own
healthcheck, which runs the same kasbah binary (mounted from
`<apps>/.kasbah/bin/kasbah`) and so the same parser — a deadline one accepts and
another refuses is how a report and a healthcheck come to describe one file
three different ways, and one implementation is what rules that out. Timestamps are judged against the **server's** clock, read in the same
round trip: a verdict computed against the workstation's would be a function of
clock skew.

**A restart does not reset what the record knows.** The runner reads the last
run's facts back out of the record before it writes anything — at start-up, and
again at the top of every run. A scheduler brought up by a reboot, a
`compose up` or a re-ship of the script carries the history the stack already
had, and a hand-driven `once` running beside a sleeping scheduler cannot have
its run overwritten by a copy of the record taken before it happened. So the
record's never-fired state — `last_run_status=-`, which is what `status` and
B01 both read as *never* — now means what it says. The last run is carried as
**one fact or none**: the epochs are admitted by the same `is_epoch` rule the
healthcheck uses, and a record that was hand-edited or half-written is left
where a runner with no history starts, rather than carried in halves that
describe a run nobody had.

One consequence worth expecting: **a failed run stays failed across a restart.**
Bouncing the container does not clear a ✗ from B01 — the verdict comes back out
of the record — so `kasbah check --server` keeps exiting 6 until a run actually
succeeds.

A safety mechanism nothing reads is indistinguishable from no safety mechanism,
which is why these readers exist at all — the healthcheck alone would have left
a stopped backup visible only in `docker logs`.

The runner takes these verbs, and they are the operator's interface to it
rather than a test hook:

```
docker exec kasbah-backup <apps>/.kasbah/bin/kasbah remote backup once
docker exec kasbah-backup <apps>/.kasbah/bin/kasbah remote backup once --project <name>
docker exec kasbah-backup <apps>/.kasbah/bin/kasbah remote backup plan
docker exec kasbah-backup <apps>/.kasbah/bin/kasbah remote backup next
docker exec kasbah-backup <apps>/.kasbah/bin/kasbah remote backup health
```

`once` backs up now — the hooks on the host first, then the push — `plan`
prints what would be included without writing,
`next` says when the next run is due, and `health` is what the healthcheck runs.
`once` writes the same record a scheduled run does, so a hand-driven backup
cannot leave the healthcheck believing something stale. `once --project`
runs no hook and backs up only the repository that project files into —
every project of that client with it, so the repository's newest snapshot still holds them all — and
writes no record: it is not the scheduled run. Only that project's own
unshipped `backups/` or `.env` (Scope) fails it; a sibling's is warned of. A
`once --project` and the nightly run that race on a repository that does not
exist yet may both try `restic init`; a run whose `init` fails warns ("could
not initialise the repository") and fails that repository. What restic makes
of two overlapping inits is not established here: after that warning, run
`restic check` against the repository before trusting its next snapshot.

## A backup now: `kasbah backup`

`kasbah backup USER@HOST`, from a project's root, takes a fresh backup of the
version live on the server — its `.env` and synced files, and what its `backup`
hooks dump, as a deploy keeps one (`build-deploy.md` → A deploy that fails …
reverts) — and, on a server with off-box backups, pushes that project's
repository at once. The push goes through the scheduler: on the server,
`kasbah remote backup push` runs `once --project <name>` in the `kasbah-backup`
container, which alone reads the credentials and passwords (mode `600`, owned
by whoever ran init). Without off-box backups the backup stays on the server,
and the run says so; with them, a scheduler container that is not running, or
a push that fails, fails the run, naming the backup it kept (`cli.md` →
`kasbah backup`).

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

**The scheduler holds the Docker socket, which is root on the host.** It is
what lets the nightly job reach the host at all, and anyone who can start a
container through it can mount `/` and become root. Through it, so can anyone
able to replace `<apps>/.kasbah/bin/kasbah` (`deploy:kasbah`, mode `775`): the
launcher runs that binary as root before it drops to the backup user. Every
operator is already in the `docker` group (`server-setup.md` → Operators),
which is the same root, so this gives no operator any access they lack — but
it is root, and a member of `kasbah` who is not in `docker` would gain it.

**Never embed a credential in the repository URL.** `repo_base` is recorded
in the server marker, which is mode **664** by contract — a URL carrying a
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
rule the deploy engine follows for hooks, backup and health: manifest data
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

restic ships only backups. Per project, each snapshot includes:

- `/apps/<name>/backups/` — the backup tarballs, each holding the `backup`
  hooks' dumps beside that version's `.env` and synced files: one per deploy
  and rollback, of the version it replaced, and one per `kasbah backup`, of
  the live one. restic stores a symlink as the link, so the runner resolves
  `backups/` first and hands restic the directory it leads to, which the
  snapshot then holds at that path. The backup container mounts only the
  apps and data paths: a `backups/` that resolves outside those (or to
  nothing there) is not shipped, and the run names it — `NOT shipped
  off-box` — and records itself as failed, the rest of the repository
  backed up all the same. So it fails every nightly run until it is fixed:
  keep `backups/` inside the apps or data path, or ship it off the box by
  other means
- `/apps/<name>/.env` — the only copy of the project's secrets; a symlinked
  `.env` is resolved the same way and, outside the mounts, named and failed
  the same way

`/apps/data/<name>/` — the bind mounts, which may be a media library — is
not shipped. Whatever a project wants kept off-box, its `backup` hook writes
into the backup (`project-manifest.md` → `hooks`); a project without one has
only its `.env` and synced files backed up.

And, when the host runs the shared mail stack, into the `mail` repo:

- `/apps/data/mail/` — every mailbox on the host
- `/apps/mail/.env` — the stack's configuration and relay block, resolved
  like a project's `.env`: a symlink is followed, and one that resolves
  outside the mounts, or to nothing, is named and fails the run

Mail gets a repository of its own rather than riding in the primary
domain's client repo: folding the whole host's mail into one client's
repository is exactly what the per-client split exists to prevent.

The manifest's `backup` hooks and this feature are complementary: the hooks
produce *consistent* dumps (e.g. `pg_dump`), kept in the tarballs under
`backups/` with the `.env` and synced files of their time; restic ships those
tarballs off the box. The dump is the restorable artifact — a live
bind-mount copy of a running Postgres is crash-consistent at best. The newest
dump off-box is the last backup's: a deploy's, or a `kasbah backup`'s.

**A repository with no password is not backed up** until init is re-run and
one is supplied. The run says so rather than skipping quietly.

## Cadence and retention (defaults, tunable)

- Daily snapshot at 02:00, with per-VPS jitter to avoid herding. The jitter
  is derived from the target as typed (`USER@HOST`, cksum'd), so it is stable
  across re-runs from the same workstation and the rendered file stays
  byte-identical on an unchanged host.
- Retention, applied by operator-side prune: 7 daily, 4 weekly, 3 monthly.

Both recorded in the server marker (`/apps/.kasbah/server.json`), whose
`backup` object **merges** on every write rather than being replaced — a
field written by a newer kasbah survives a re-run by an older one.

## Restore

After a lost server, recovery is the backups and your own dumps, not the data
directories: `kasbah server init` the fresh VPS, `kasbah deploy`, then
`kasbah restore`.

1. Fresh VPS: `kasbah server init USER@HOST --with-backup`, with the same
   repository base and each repository's password (`--backup-password=`) — the
   passwords kept off the VPS (Credentials).
2. `kasbah deploy` from the project repo. The fresh server has no `.env`, so
   the deploy's env step asks for its keys, or takes them from
   `--env-seed=FILE`; any value will do when `restore` brings the backup's
   `.env` back. The project's
   data directories start empty.
3. `kasbah restore USER@HOST` from the project repo (`cli.md` →
   `kasbah restore`). Through the `kasbah-backup` container, which alone
   holds the credentials, it lists the repository's snapshots holding the
   project's `backups/`, copies the newest backup of the live version out of
   the newest one into `backups/` (`--snapshot=`, `--backup=` choose another;
   `--list` shows them), verified by size and sha256 before it is kept. The
   container stages the whole tarball before streaming it, so its `/tmp`
   needs the tarball's size free. Snapshots are found by the path of
   `backups/` (as it resolves, or `<apps>/<name>/backups`): keep the apps
   path the old server had, and re-create a `backups/` that was a symlink
   (into the data path) as the same link before restoring; otherwise the
   refusal lists the paths in the snapshots that hold backups, and
   `--from-path=<path>` restores from one. It
   then asks, as a rollback does, whether to restore the backup's `.env` — the
   names of the keys that differ are listed, never a value — and whether to
   load the data with the live version's `restore` hook
   (`--with-env`/`--no-env`, `--with-data`/`--no-data`). The hook runs on the
   extracted tarball (`$KASBAH_BACKUP_DIR`), and a changed `.env` recreates the
   stack so its containers read it. A failure after the `.env` write, or a
   SIGINT or SIGTERM, puts the previous one back, and the report says whether
   the data is already the backup's.

A project without a `restore` hook gets its `.env` back from `kasbah
restore`, and loads its dump from the tarball however it restores one.

**When kasbah cannot be used** — no workstation with the project, or a
server that cannot run the scheduler — the same restore is done by hand:

1. Fresh VPS: `kasbah server init` (same flags as before).
2. `restic restore <snapshot> --target /` — the snapshot's paths are the
   server's paths, so this lands `/apps/<name>/.env` and `backups/` where
   they were (a `backups/` that was a symlink lands at the directory it led
   to: re-create the link, or move it into place).
3. `kasbah deploy` from the project repo. The project's data directories
   start empty. Without `.env` back on the box, the deploy's env step has
   nothing to deploy against and exits 5.
4. Load the dumps, on the server as the deploy user, the way the `restore`
   hooks run (`project-manifest.md` → hooks): extract the newest
   tarball in `backups/` into a directory of its own, then run each line of
   the project's `restore` list — `hooks.restore` in `kasbah.yml`, recorded
   on the server under `restore` in `/apps/<name>/.kasbah-hooks.json` — from
   the project directory, with every variable a hook gets:

   ```sh
   cd /apps/<name>
   dir=$(mktemp -d "$HOME/restore.XXXXXX")
   tar -xzf backups/<version>-<stamp>.tar.gz -C "$dir"
   export LC_ALL=C KASBAH_VERSION=<version> KASBAH_PREV_VERSION= \
       KASBAH_PROJECT=<name> COMPOSE_PROJECT_NAME=<name> KASBAH_BACKUP_DIR="$dir"
   sh -c '<the first restore line>'   # then each further line, in order
   rm -rf "$dir"
   ```

   `<version>` is the tarball's, and `KASBAH_PREV_VERSION` is empty, as on
   `kasbah restore`: no version is going out. A project without a `restore`
   hook loads its dump, at `$dir/<file>`, however it restores one.

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
