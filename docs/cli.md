# CLI Reference

Two levels of commands:

- **`kasbah server …`** — act on a VPS. Always take `user@host` as first arg.
- **`kasbah …`** (everything else) — act on a project. Run from the project
  root. Read `./kasbah.yml`. Error if missing.

```
$ cd ~/some/random/path
$ kasbah deploy you@vps
error: No kasbah.yml in current directory.
       Run from the project root, or `kasbah init-project` to scaffold.
```

## Server commands

### `kasbah server init USER@HOST [flags]`

One-time VPS setup. Idempotent — safe to re-run.

Optional features are tri-state (see the interactivity decision in
`overview.md`): leaving `--with-mail`/`--no-mail` unset means init *asks* —
it never treats absence as "no". Without a TTY, an unanswered choice is a
hard fail naming the flag to pass.

Flags:
- `--domain=<apex>` — domain for the Traefik dashboard and acme email config.
- `--email=<addr>` — ACME email for Let's Encrypt registration.
- `--with-mail` / `--no-mail` — scaffold `/apps/mail/` (DMS + SnappyMail) and
  start it, or explicitly skip it. Unset → prompt. `--no-mail` against a
  server that already has mail leaves it alone: init scaffolds mail, it never
  removes it. See `mail.md` and `server-setup.md` → With mail.
- `--postmaster-password=<pw>` — the password for `postmaster@<mail domain>`,
  which DMS is seeded with before its first start because Dovecot panics
  without an account. Hashed on the workstation (SHA512-crypt);
  only the hash crosses the wire, on stdin. Asked for interactively when the flag is
  absent, and **not asked at all** when the server already has an account —
  init never rewrites that file. A trailing carriage return is stripped, like
  `--domain`'s and `--email`'s; a newline is refused, because only the first
  line would be hashed. Only meaningful with `--with-mail`.
- `--with-backup` / `--no-backup` — scaffold the off-box backup scheduler at
  `<apps>/.kasbah/backup/` and start it, or explicitly skip. Unset → prompt.
  **Installs nothing** — restic runs as a container (see `backup.md`).
  `--no-backup` against a server that already has backups leaves them alone:
  init scaffolds, it never removes. Init **refuses** if the storage credential
  turns out to be able to delete.
- `--backup-repo-base=<url>` — the repository base, ending in `/`. kasbah never
  parses it, so any restic backend works. Asked only when the marker records
  none. **Do not embed credentials in it** — the marker is mode 644 by
  contract, so a secret in this URL is world-readable on the VPS.
- `--backup-env=KEY=VALUE` (repeatable) / `--no-backup-env` — the storage
  credentials and anything else restic needs in its environment, written mode
  600. Asked once, on the run that creates the file; after that the file is the
  operator's, like `mail/.env`. **Five keys are refused**, here and in the
  environment file: `RESTIC_REPOSITORY`, `RESTIC_REPOSITORY_FILE`,
  `RESTIC_PASSWORD`, `RESTIC_PASSWORD_FILE` and `RESTIC_PASSWORD_COMMAND`. They
  decide which repository restic opens and what opens it — kasbah sets them, and
  an entry naming one would point the credential probe somewhere other than
  where the backups go, which is the one shape of that bug nothing else catches.
- `--backup-password=<repo>=<pw>` (repeatable) — the encryption password for one
  repository. Operator-supplied, never generated, **never rewritten** by a later
  run. A repository with no password is not backed up, and the run says so.
- `--backup-timeout=<seconds>` — how long **one** restic invocation may take before
  it is killed. Default 900, floor 30, recorded in the marker. This is what keeps
  a storage endpoint that accepts a connection and then answers nothing from
  wedging the scheduler forever: without a bound the run never returns to its
  sleep, so the container stays "running" and backs nothing up.
- `--backup-at=HH:MM`, `--backup-jitter=<seconds>` — when the daily run fires.
  The jitter defaults to a value derived from the server's own identity, so it
  is stable across re-runs and spreads load across hosts.
- `--backup-keep-daily=N`, `--backup-keep-weekly=N`, `--backup-keep-monthly=N` —
  retention, recorded in the marker and applied by `server backup-prune`, not on
  the VPS. Default 7 / 4 / 3.
- `--apps-path=/apps` — root directory on the VPS (default `/apps`).
- `--data-path=<dir>` — bind-mount root (default `<apps-path>/data`, so it
  follows `--apps-path` rather than being pinned to `/apps/data`).
- `--traefik-auth=user:pass` — basic auth for the dashboard. The password is
  hashed with bcrypt on the workstation and never sent in clear; the hash lands
  in `dynamic/_shared.yml`. The hashing normally runs in a throwaway
  `httpd:2-alpine` container, since `htpasswd` ships in a package
  (`apache2-utils` / `httpd-tools`) that few workstations have — **so Docker on
  the workstation is what `server init` actually depends on here**, and a
  machine with neither is a hard fail naming both ways out. An `htpasswd`
  already on `PATH` is used directly, to save pulling an image. Either way the
  password arrives on stdin (`-niB`), never in argv, where the process table
  would expose it to every other user of the machine for as long as it runs. Unset on a re-run means the stored hash is
  reused — bcrypt salts randomly, so re-hashing would break idempotency.
- `--acme-staging` — render Let's Encrypt's **staging** endpoint as the
  resolver's `caServer` instead of production. Unset means production: this is
  the one choice that does not prompt, because production is both the default
  and the status quo. Rehearse a new server against staging until DNS, port 80
  and the whole deploy flow are green, then re-run without the flag — failed
  challenges count against the production rate limits too, so the rehearsal is
  what keeps a misconfigured DNS from costing a week.
- `--yes` — answer the `acme.json` reset **confirmation** below: the case where
  the server records a CA, this run renders a different one, and declining
  simply aborts. Destructive, hence a confirmation; two outcomes only, hence
  `--yes` and no `--no-yes` (see `overview.md` → Interactivity).
- `--reset-acme` / `--keep-acme` — answer the other question below: the server's
  store has content and **nothing records which CA issued it**. That is a
  choice, not a confirmation — keeping is a real outcome that leaves the server
  running, so it gets a flag pair rather than `--yes`, and `--yes` deliberately
  does not answer it. A blanket `--yes` in a script cannot know which CA filled
  a store, and guessing wrong archives real certificates.
  Unset → prompt. Without a TTY, either unanswered question is a hard fail
  naming its own flags.

What it does:
1. Verify Docker ≥ 24 and Docker Compose v2 exist. **Does not install.** Fails
   with a clear message otherwise.
2. Create the apps path — `sudo mkdir -p` the *parent*, a bare `sudo mkdir`
   on the final component (so an existing directory is an error rather than
   a silent adoption), then `chown` to the SSH user — and only when the path
   does not already exist; everything below it is
   created unelevated. See `server-setup.md` ("Who creates the apps path").
   Then `mkdir -p /apps/data /apps/backups`.
3. `mkdir -p <data>/traefik/letsencrypt && touch <data>/traefik/letsencrypt/acme.json && chmod 600 ...`
   (touch-as-file is mandatory — Docker silently creates a directory otherwise).
4. Scaffold `/apps/traefik/` — compose.yml, traefik.yml, and dynamic/ with
   `_shared.yml`. No `.env`: Traefik interpolates no environment variables,
   so `--domain`, `--email`, the `--traefik-auth` hash and the ACME `caServer`
   are baked into the
   rendered files (see `server-setup.md`).
5. Reconcile the certificate store with the CA now configured. `acme.json`
   holds certificates issued by one CA; changing `caServer` does not
   invalidate them, so Traefik goes on serving certificates from the old
   endpoint and only swaps them at renewal — which is how a server ends up
   configured for staging while still presenting a production certificate.
   **An empty or absent store is never touched and never asks**, so a fresh
   server stays silent. A store with content takes one of two paths:
   - **The recorded CA differs from this run's.** Init asks once, archives the
     store to a timestamped sibling — never deletes it, since a production
     `acme.json` is real certificates — recreates an empty one at mode 600, and
     lets the restart below re-issue. Declining aborts with nothing created
     or restarted — on a re-run the kasbah binary may already have been brought
     up to date (`--yes` to confirm without asking).
   - **Nothing records which CA issued it** — a server that predates
     `caServer`, or a `traefik.yml` kasbah cannot read. Init cannot tell, so it
     asks which it should be (`--reset-acme` / `--keep-acme`). Keeping is not a
     refusal: the run proceeds, records the endpoint, and warns that the
     store's provenance is unknown. The next run has the CA recorded and is
     quiet.

   See `traefik.md` → "Which CA".
6. `docker compose -p traefik up -d` in `/apps/traefik/`, restarting only
   when the static config changed and the container was not just recreated.
7. Health-check Traefik, print the dashboard URL. Plain HTTP redirects to
   HTTPS, and the dashboard carries HSTS on its 401 (`traefik.md` → Dashboard).
8. If `--with-mail`: this is spread across steps 5-7 rather than sitting
   after them, because the ordering is what breaks the boot deadlock.
   `/apps/mail/` (`compose.yml`, `kasbah.yml`, `.env`), the cert-trigger +
   webmail fragment at `/apps/traefik/dynamic/_mail.yml`, and the two
   pre-seeds land **before** Traefik starts, so Traefik requests both
   certificates at configuration load. The mail containers start **after**
   Traefik is healthy, because DMS reads `mail.<domain>`'s certificate out of
   `acme.json`. Init waits for SnappyMail and reports DMS without waiting for
   it — a first-run crashloop is expected while the certificate is issued.
9. If `--with-backup`: scaffold `<apps>/.kasbah/backup/` — the scheduler stack,
   the runner, the mode-600 environment file and one encryption password per
   repository — then **probe the storage credential before starting anything**:
   write a probe repository, take two snapshots, attempt a real delete, count
   again. A credential that can delete stops the run with the stack unstarted,
   because a backup history the VPS can destroy is not a backup. Only then does
   the stack come up. Installs nothing: restic runs as a container
   (see `backup.md`).
10. Write the server marker `<apps>/.kasbah/server.json` — kasbah version,
    paths, resource limits computed as 90% of host cores/RAM (see
    `server-setup.md`). **Last of the steps that signal completion**: its
    presence is the "init completed" signal, so a failure at any earlier step
    leaves no marker behind.
11. Write the discovery pointer `/etc/kasbah/apps-path` (`root:root 644`, in a
    `755` directory, one absolute path) so every project command can find this server without
    being told where it is. Immediately after the marker, never before — a
    run that dies early must leave neither. See `server-setup.md` → the
    discovery pointer, including what happens when sudo is unavailable.

Re-running init against a server whose pointer records a **different** apps
path is refused: one machine runs one kasbah, because one Traefik holds `:80`
and `:443`.

### `kasbah server backup-prune USER@HOST [flags]`

Apply retention to the server's backup repositories: `restic forget` plus
`prune`. The counterpart to `server init --with-backup` — the VPS writes
snapshots and cannot delete them, so this is the only thing that ever removes
one.

**restic runs on the workstation, not the VPS.** The whole credential design is
that the full-access storage credential lives only on operator machines;
shipping it to the box the threat model assumes is compromised would defeat it.
The `USER@HOST` argument is for *discovery* — which repositories exist, and the
`repo_base` and retention the marker records. The repositories' **encryption**
passwords do come back over ssh, staged locally at mode 600: restic cannot write
a snapshot without them, so they are on the VPS already and fetching them widens
nothing (`backup.md` → Credentials).

It dry-runs every repository first, prints the plan, confirms once, then forgets
and prunes. **The plan and the outcome both go to stdout**, as `drop` and
`server destroy` do; only `warning:` and `error:` lines go to stderr, so
`kasbah server backup-prune … > prune.log` keeps the record. A repository whose
dry run fails is **skipped and not pruned** — it never reaches the plan, so it
is never in the set the act iterates — and the closing count is of what was
actually pruned, not of what was discovered.

Flags:
- `--repo-base=<url>`, `--repo=<name>` — override discovery, or act on one
  repository. `--repo=` accepts `kasbah.probe` as well as ordinary repository
  names, since it is in the default set; the dot is still refused everywhere a
  repository *name* is taken, such as `--backup-password=`.
- `--env=KEY=VALUE` / `--no-env` — the **full-access** storage credentials. These
  are the operator's, and are never read off the server.
- `--keep-daily=N`, `--keep-weekly=N`, `--keep-monthly=N` — override the marker's retention.
- `--dry-run` — plan only.
- `--yes` — skip the confirmation.
- `--docker-network=<name>` — put the restic container on a specific Docker
  network. Storage on the internet needs nothing; a self-hosted endpoint on
  another bridge is unreachable from the default one.

**Repositories are emptied, never removed.** There is no wire operation that
deletes a repository — deleting one is a manual act at the storage provider,
which is also what makes a client offboarding a deliberate decision.

### `kasbah server prune USER@HOST [--yes]`

Image retention cleanup across all projects on the VPS: removes
`:<version>` image tags that are both older than 3 months and not among
the project's last 3 deployed versions — the version `:current` points
at counts as the first of the 3, and `:current` itself is never pruned.
The time window mirrors versions.log rotation — see `build-deploy.md`.
Prints what it would remove and asks once; `--yes` answers that question
for scripts, and without it and without a terminal the run stops naming
the flag. There is **no `--apps-path`** here: among the commands that only
*read* an apps path, `server status` is the sole holder of that escape hatch
(`server init` takes one too, because it *establishes* the path).
Where the server was prepared is the server's own
answer, and aiming a destructive command at a tree the server does not
consider its own is not a recovery path: a damaged pointer refuses, and
the refusal sends you to `kasbah server status <host> --apps-path=<dir>`
(read-only) to find the tree and then to `kasbah server init` to repair
the pointer.

What a project's version tags *are* comes from the compose file on the
server: every service with a `build:` key, and the repository its
`image:` names. A stock image (`redis:7-alpine`) is in no project's
`build:` and is therefore never a candidate, and a repository two
projects both declare is left alone — no single project's record is
evidence about it.

"Last 3 deployed" comes from `versions.log`, never from an image's tags
or dates: a re-tagged image lies about its age. An image's age is its own
`Created`, which a `docker load` preserves. A tag a container holds is
kept and the report says which container.

**A project kasbah cannot read whole is skipped entirely**, with a
warning and not one tag removed — an unreadable `versions.log`, an
archive that did not decode whole, a record holding a line the parser
could not read among the entries it had to walk, a record with no
entries at all, or a `compose.yml` it cannot read **or cannot parse**.
Deleting on the absence of a record is deleting on no evidence.

A project whose `compose.yml` cannot be read or parsed is a stronger
condition than that, and it stops the whole run: kasbah cannot enumerate
what images that project declares, so it cannot rule it out as a second
claimant of *any* repository on the host, and nothing on the server is
provably single-owner. Prune removes nothing anywhere, says so in its own
sentence, and names the project to fix. Reading such a project as
"declares nothing" would defeat the multi-owner guard with the very
condition that triggers the skip, and there is no honest narrowing — the
file that would say which repositories it might have claimed is the file
kasbah could not read.

The bind-mount root is not a project: `--data-path` can put it under the
apps path with any name, so prune reads `data_path` out of the server
marker and drops that row, exactly as `server status` does.

Three round trips: the bootstrap probe (which brings kasbah's own binary up to
date), one batched read of the whole server (`kasbah remote prune scan`), and —
only if there is something to remove and the operator said yes — one removal
(`kasbah remote prune rm`). Every decision is made on the workstation. Exits 4
on a host with no server marker, 1 on one whose marker cannot be read: prune
does not delete images on a machine it cannot tell is a kasbah server.

### `kasbah server upgrade-traefik USER@HOST --version=<tag>`

A managed Traefik version bump. `--version=` is required — the command
exists to change the tag and there is no default to fall back on — and is
checked against Docker's own tag grammar before it reaches a compose file
and a `docker run`. There is **no `--apps-path`**, for the same reason
`prune` has none: where the server was prepared is the server's own answer.

Two halves, and the second is the point.

**Backup before overwrite.** `compose.yml`, `traefik.yml` and
`dynamic/_shared.yml` are kasbah's outright (`traefik.md` → Ownership), so
they are re-rendered from this kasbah's templates exactly as `server init`
does them and nothing is asked. What init does not do is keep a copy: the
bytes already on the server go to `<apps>/traefik/backups/<UTC timestamp>/`
first, and that directory is never deleted.

**The dry run.** A throwaway Traefik of the *target* version is booted with
`<apps>/traefik/dynamic/` mounted read-only — `_shared.yml`, `_mail.yml`
and every project's fragment, not just kasbah's — and **any line it logs at
`ERR` fails the upgrade before anything switches**. The throwaway runs on
`--network none`, publishes no port, mounts nothing writable and never sees
`acme.json`; it points at an unreachable loopback CA, so it contacts no
certificate authority and spends no rate-limit budget. Its one error family
— the certificate it therefore cannot obtain — is excluded from the verdict
by both the message and that URL, and those same lines are what proves it
read the fragments at all: one per TLS router it built, naming it. Two things
must hold or the run is a failure rather than a pass — `traefik-dashboard@file`
must be among them, and, whenever the server's `dynamic/` holds any fragment
besides `_shared.yml`, so must a router that is not one of `_shared.yml`'s. The
dashboard router comes from the `_shared.yml` this run renders and overlays, so
on its own it would appear even if the server's directory read as empty.

The target image is pulled during the dry run, so a tag that does not exist
fails while the live proxy is still untouched, and the pull cannot fail
later, mid-switch.

Four values are recovered off the server and reproduced verbatim: the
dashboard apex, its basic-auth entry, the ACME address and the ACME
endpoint. A stack that will not yield all four is refused, naming the one
that is missing and pointing at `server init` — repairing a stack is init's
job, and a version bump must not move a server's CA or its dashboard
credentials as a side effect. `acme.json` is never written; the run digests
it before and after and reports whether the new Traefik touched it.

If the new version does not come up healthy, the backup is copied back **on
the server** and the old version brought up again, in the same step rather
than a round trip later — so a dropped connection cannot leave the proxy
down with the fix on the wrong machine. Exits 4 on a host with no server
marker.

### `kasbah server destroy USER@HOST [--yes]`

De-brand the VPS for handover. **Every container keeps running throughout** —
projects *and* Traefik, the sites stay up, and a project still `compose up`s
afterwards from the server's own files. Removes kasbah's management layer, and
above all every agency-owned secret.

Server-wide:
- `<apps>/.kasbah/server.json`, and `<apps>/.kasbah/` once empty
- `/etc/kasbah/apps-path`, and `/etc/kasbah/` once it is empty — root-owned, so this needs
  passwordless `sudo`. Without it the run **warns and continues**, exits 0, and
  prints the exact command to finish by hand. A server left in that state has no
  marker but still has its pointer, and destroy says so on a re-run rather than
  claiming there is nothing to remove.
- the **backup stack**, stopped rather than merely unlinked: `docker compose -p
  kasbah-backup down`, then the container, the `kasbah-backup-cache` volume, the
  `kasbah-backup_default` network, then `<apps>/.kasbah/backup/` entire —
  `compose.yml`, `backup.sh`, `env`, `repos/*.pass`, `state/`. A schedule left
  running would go on pushing the new owner's data into the departing agency's
  storage. **The restic repositories are never touched**: operator property, and
  an append-only credential could not delete them anyway.

Per project:
- `versions.log` and `versions.log.gz`
- the `scripts/` helpers, **by name** — `remote-deploy.sh` and `setup-env.sh`,
  then `rmdir`. The directory survives if it holds anything else, because
  destroy cannot tell an operator's file from kasbah's except by name
- `.deploy.lock`, and `.kasbah-client` (written by `deploy`, read by the backup
  run — see `project-manifest.md`)
- the **managed-block sentinel comments** in `.env`. The `KASBAH_CPU_LIMIT` and
  `KASBAH_MEM_LIMIT` lines between them **stay**, as ordinary lines: compose
  interpolates them into every service's `cpus:` and `mem_limit:`, so removing
  them would stop the new owner's containers on their next `up`. What goes is
  the comment promising the block is "rewritten on every deploy", which becomes
  false the moment this command runs. Every other line survives byte for byte,
  carriage returns included; the edit happens **on the server**, because the
  file is the project's only copy of its secrets and it is not going to travel.

Mail, if the stack is there:
- every line of `<apps>/mail/.env` that is not `MAIL_HOSTNAME`, `DOMAIN` or
  `DATA_PATH` — the operator's relay block, and kasbah's own explanatory
  comments with it. The three keys stay, so the stack still starts. Outbound
  relay stops until the new owner configures their own.
- `<apps>/mail/kasbah.yml`, the registry — read by kasbah and nothing else.
- **`postfix-accounts.cf` stays.** Removing the postmaster would leave
  containers running that nobody can authenticate to.

Kept: every container and image, Traefik and its fragments, `data/`,
`<apps>/backups/`, named volumes, and the projects' compose files and `.env`
values. There is no `kasbah.yml` to remove — the manifest is never synced to a
server.

**The trade-off is explicit, and it is wider than it looks.** Deploy history and
env tooling leave with kasbah — and so does the mail registry, which is the only
record of `primary_domain` and the domain list. A later re-branding
`kasbah server init --with-mail` cannot reproduce either; both must be
re-entered.

**Double confirmation:** a yes/no question, then the **hostname** typed back.
Either decline exits 1 having changed nothing. `--yes` skips both.

A run that cannot finish **holds back the marker and the pointer**, so the
server is still discoverable and the command can be re-run. It exits 1 and says
which step failed. A second run on a fully de-branded server reports that the
server carries nothing of kasbah's and exits 0 — it does not exit 4, because a
completed destroy removes its own marker by design. But a server with **no
marker and a surviving `<apps>/.kasbah/backup/`** exits **1**: that directory is
the repository URL and one password per repository at mode 600, and without a
marker destroy cannot enumerate the rest to remove them. The contrast with the
no-sudo case above is deliberate — what that leaves is a world-readable
discovery pointer, and what this leaves is the credentials the command exists to
take away.

### `kasbah server status USER@HOST [--apps-path=<dir>]`

It changes nothing on the server but kasbah's own binary, which it brings up to
date first (`<apps>/.kasbah/bin/kasbah`, newer wins) — and never on a server
`server init` has not prepared.

Prints:
- Docker + Compose versions
- The server marker: kasbah version, paths, resource limits
- Disk: the filesystem behind the apps path and the one behind the data path,
  with used/total/free and the mount point. `df`, not `du` — the question is
  whether the host is about to run out of room, and it is answered in constant
  time. A `du` walk of a data path holding a mail spool would make the report
  cost whatever the server happens to hold, and the data path is named as
  sharing the apps path's filesystem rather than counted twice.
- Traefik: running state, health, the image tag it was created from **and**
  the resolved image id (a tag can be re-pushed; the id cannot), what its ACME
  store holds, and the dashboard hostname out of `_shared.yml`
- The mail stack: `mail-dms` and `mail-snappymail` by their compose labels with
  state, health and **restart count** — a DMS that cannot find a certificate for
  `mail.<primary>` restarts until one appears, and only the count says so — plus
  the registry's primary domain and the domains it serves. A server prepared
  without `--with-mail` has none, and that is an ordinary state, not a fault.
- The backup stack, when the marker records one: the repository base with any
  credential **redacted**, the schedule and its jitter, the `kasbah-backup`
  container's state, health and restart count, when the last run happened and
  how it went, the repositories this server has, and any that lack a password
  and are therefore not being backed up, and any **orphan password** — a
  repository file left behind when its last project was dropped, which kasbah
  reports and never deletes, because deleting it would make that client's
  off-box snapshots unrecoverable. The container is found by name **and**
  compose-project label, the same query `check --server` uses, so a foreign
  container holding the name reads as one (`notours`) rather than as an absence.
  A server prepared without
  `--with-backup` gets one line saying so, and a verdict measured against the
  workstation's clock rather than the server's says so on the header. The record it reads is the same one
  `check --server`'s B01 judges, through the same parser — so `status` and
  `check` cannot disagree about whether a backup is healthy, and its timestamps
  are read against the **server's** clock, in the same round trip, since a
  verdict computed against the workstation's would be a function of clock skew.
- Projects under the apps path — name, running/total containers, the
  last `versions.log` entry (action, version, timestamp, kasbah version), **the
  domains its Traefik fragment claims**, what the certificate store says about
  each of them, and each container's state and health. A project whose
  containers are all running and none unhealthy gets one line saying so; one
  that is not gets a line per container, because that is the case a count
  cannot show.

**Certificate expiry comes from Traefik's own `acme.json`**, read by the same
`internal/acme` that answers `check --server` — one store, one reader. The file
holds the ACME account key and every certificate's private key, so it is never
written to a temp file, echoed, or quoted in a message: the diagnostic that
echoes a truncated probe back reports that line by name and length only.

**All of it is one SSH round trip.** Each addition read on its own is what turns
`status` into several sessions, and the rig's `maxstartups 10` is what that
costs. One probe, one report, absorbed and key-checked before anything is read.

`--apps-path` is the escape hatch for a server whose discovery pointer is
missing, unreadable, or in a directory nobody can enter — and it is honoured in
every one of those states, since refusing to read a path the caller named
outright would leave no way in at all. Without it, `status` resolves the apps
path the same way every other command does — `/etc/kasbah/apps-path`, else
`/apps` — and
prints which of the three it used. No other command that merely *reads* an
apps path takes the flag — `server init` has one because it establishes the
path, not because it reads one. A value
repeated on every invocation is a belief each caller holds separately, and the
apps path is a property of the server (see `server-setup.md` → the discovery
pointer).

**The project's domain was the one open decision, and it is settled.** It lives
in `<apps>/traefik/dynamic/<name>.yml`, so printing it costs either a YAML parse
on a server where `yq` is not a prerequisite or a Traefik API call with the
dashboard credentials. kasbah **fetches the fragment base64 in the same round
trip and parses it with the workstation's `yq`**. The credentials route would
yield certificates and router health in one call, but `status` holds only the
bcrypt hash from `_shared.yml` — never the password — so it would need a new
flag or prompt plus reachability to `traefik.<apex>`. The VPS has no `yq`, `jq`
or `python3` and keeps needing none.

One value does cross that line and is checked rather than trusted: the **data
path**, which the certificate store and the data disk figure both hang off. The
probe scrapes it out of the marker's bytes without a JSON parser, and the
workstation compares the scrape with what `jq` read out of the same bytes. They
disagree only on a marker kasbah did not write; when they do, both reads are
reported as unread rather than as facts about some other tree.

## Project commands

All run from the project root (where `kasbah.yml` lives).

`USER@HOST` is optional on any command that takes it. If omitted, kasbah
reads `last_server` from `.kasbah/state.json` and uses that. After any
command succeeds against a given server, `last_server` is written so the
next invocation in the same project defaults to it. `kasbah init-project`
writes an empty state file; the first command that needs a server must
pass `USER@HOST` explicitly.

"Succeeds" means kasbah's own work — reach the server, find the project, do
what was asked, which is not always the same as exiting 0. `kasbah exec` exits
with the status of the command it ran, and writes `last_server` whenever that
command ran at all; `kasbah logs` writes it when the reader stopped early too,
since a closed pipe says nothing about whether the logs were readable
(`project-manifest.md` → write rules).

### `kasbah server add-mail-domain USER@HOST <domain>`

Joins a domain to the VPS's shared mail stack (`mail.md` → Multi-domain).
Two things change and nothing else does:

- the domain joins `domains:` in `<apps>/mail/kasbah.yml` — the registry, and
  the only thing asked whether this stack serves a domain. The file is
  re-rendered from the same template `server init` renders it from, so one
  writer owns its shape;
- `postmaster@<domain>` is aliased to the primary mailbox in
  docker-mailserver's `<data>/mail/dms/config/postfix-virtual.cf`, which is
  also what makes Postfix accept mail for the domain at all — DMS builds its
  accepted-domain list out of that file and `postfix-accounts.cf`. DMS watches
  it and reloads; no restart.

**No router is added.** `mail.<primary>` and `webmail.<primary>` are the
stack's own hostnames; an app domain needs an MX record pointing at
`mail.<primary>`, not a fragment of its own.

Adding a domain twice is a no-op that says so — not an error, and never a
duplicate entry. A domain listed in the registry whose alias is missing is
converged rather than reported as done: the two halves are what make the claim
true, and only one of them was there.

What it does not do, because none of it is kasbah's: DKIM keys (DMS's own
helper generates them on the VPS), the per-domain block in Rspamd's
`dkim_signing.conf`, and DNS. It prints all three as follow-ups, and
`mail-setup-guide` prints the records.

### `kasbah server mail-setup-guide USER@HOST`

Prints the mail stack's post-install walkthrough, rendered for this server:
its primary domain, every domain in the registry, and the DNS records each of
them needs — MX, SPF, DMARC and both DKIM selectors — with the address the ssh
session reached the server on filled in. Ported from the original project's
`mail/SETUP.md`.

Read-only. It reads the registry and changes nothing.

It carries two prerequisites kasbah cannot check and an operator will
otherwise miss: reverse DNS (PTR) on the VPS IP set to `mail.<primary>`, and
port 25 **outbound** not blocked by the provider — many block it by default.

The same guide prints once at the end of the `server init --with-mail` run
that *creates* the stack. A re-run prints the one-line pointer at this command
instead.

### `kasbah init-project [flags]`

Scaffold the kasbah metadata for a new project. Creates:
- `kasbah.yml` with schema version and sane defaults
- `.env.prod.example` — comments and no keys. The file is required (check S04)
  and declaring nothing in it is a normal end state: routing comes from the
  manifest's `domain:` and the fragment, so a project with no configuration of
  its own has nothing to put here and its first deploy has nothing to prompt
  for. Add keys as the app grows ones; see `env-template.md` for the line
  forms.
- `.kasbah/state.json` (empty fields, current `kasbah_version`)
- `.gitignore` entries for `.env` and `.kasbah/`

Does **not** scaffold `compose.prod.yml`. The user authors that file — kasbah
has no opinion on which service is "primary", what ports to expose, etc. After
running, kasbah prints a minimal starter compose snippet and a matching Traefik
fragment to stdout so the user can paste and adapt if useful. Both are shapes
`kasbah check` passes clean: one routed service named for the project (C09) on
`kasbah-net` alone, and two routers for the domain so plain HTTP redirects
rather than 404s (T08).

Flags:
- `--name=<name>` (default: current directory name)
- `--domain=<fqdn>`

### `kasbah check [--server [USER@HOST]] [--fix [--yes]]`

Run the compliance check on the current project. See `compliance.md` for
the full rule set. Exit code 0 on pass, 6 on any failure (see "Exit codes" below).

`--server USER@HOST` also asks that VPS: whether the project is deployed there,
whether its `.env` still matches this checkout's `.env.prod.example`, whether
the mail stack knows the claimed domain (M03), whether `health.container` is
healthy, what Traefik's `acme.json` holds for the project's domain, and whether
the effective resource limits are within the host's ceiling (R04). It also
tightens T05 from a first-label heuristic to the hostnames that server really
owns. It changes nothing on the server but kasbah's own binary, brought up to
date first. Given without a `USER@HOST`
it asks `last_server`, and a run that reaches the server records it — the same
rule every other server-targeting command follows (`project-manifest.md`).

`--fix` applies the auto-fixable rules — **C01–C05, C08, R01–R03** and the
`kasbah_version` backfill — and touches only `compose.prod.yml` and `kasbah.yml`.
It plans, stages a candidate, prints a unified diff of every file it would
change, and **then asks**; `--yes` answers that question, and without a terminal
and without `--yes` it is a hard fail naming the flag. Declining writes nothing
and leaves no candidate behind. `--yes` on its own is refused rather than
ignored — it does nothing without `--fix`.

The fixes are **targeted text edits, never a YAML round-trip**: `yq` reorders
keys and drops comments, and compose files carry load-bearing ones. Everything
not being changed comes back byte for byte — comments, blank lines, key order,
quoting, hand-spacing, CRLF line endings and a missing final newline included. A
comment sitting immediately *above* a removed key is **left**, because it cannot
be told from a file header, and a compose file that opens with prose and then
`version:` is the ordinary shape.

`yq` decides what is true; the text scanner only finds where it is written. When
the scanner cannot take a shape apart — a quoted key, a flow mapping, an
inline value — the fix is **refused and named**, never guessed. So is a
`compose.prod.yml` that does not parse. Two rules are also refused case by case,
with the reason printed: **C08** on a built service that names no `image:` at
all (it is a tag rewrite, and kasbah will not invent an image name), and **C04**
under the banned default-alias shape, where declaring the default network
external would entrench exactly what C07 is failing on.

`--fix` runs **before** the report, so the lines you read and the exit code you
get describe the project as it now is. Traefik rules, C07, C09, hooks and mail
claims are never auto-fixed — routing and topology are policy, and kasbah cannot
invent a command.

### `kasbah build-push [USER@HOST]`

1. Resolve version from git tag on HEAD (exactly one `vX.Y.Z`). Fail otherwise.
   Then reach the server and ship the kasbah binary if its own is absent or
   older — before any build, so an unreachable server (exit 3) or one `server
   init` never prepared (exit 4) is known in seconds.
2. Parse `compose.prod.yml` for services with a `build:` key. If zero, exit 0
   (stock-only project — nothing to ship; `compose up -d` will pull stock images at deploy time).
3. `docker compose -p <name> -f compose.prod.yml build`, under
   `KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0` — a compliant compose file cannot
   interpolate without them and a build has no server to read them from
   (`build-deploy.md`).
4. Tag each built image: `<image>:<version>`.
5. One `docker save` of every built image, gzipped and streamed over ssh into
   the server's `kasbah remote load`, which feeds `docker load` and confirms each
   image. Nothing is written to disk on either end; a stream cut short is refused.
6. `git push origin v<version>` if the tag isn't yet on origin. A repository
   with no `origin` remote at all warns and exits 0: the image has already
   shipped by then, and a local-only project is a real shape.

`build-push` does **not** set `:current` and does **not** run `compose up`.
Moving `:current` is `deploy`'s responsibility. `:latest` is never set. It does
run `compose build` — that is the one compose verb it uses.

`USER@HOST` follows the same rule as every other project command: the argument,
else `last_server` from `.kasbah/state.json`, which is written on success.
`--build-only` needs neither, since it never reaches a server.

Flags:
- `--build-only` — skip transfer/load/push (local build + tag only).
- `--no-git-push` — don't push the git tag.

### `kasbah deploy [USER@HOST] [VERSION] [flags]`

Two modes:

- **No `VERSION` arg** — deploys the **working tree**, labeled with HEAD's
  `v-tag`. Fails fast if HEAD isn't tagged. This is the everyday path: you
  may have tweaked compose or env template since cutting the tag, and you
  want to ship current disk state under that version label.
- **Explicit `VERSION`** — deploys that tagged version exactly as it was,
  read out of the `v<VERSION>` ref (no checkout, working tree untouched).
  See the rollback flow in `build-deploy.md`: it is the same code path, and
  only three things differ — the log entry is `action=deploy`, the hook pair
  is `pre-/post-deploy`, and there is no "must already be in versions.log"
  precondition, since deploying a version here for the first time is exactly
  what this mode is for.

Flow (no-args / working-tree path):
1. Open SSH ControlMaster for the whole deploy (reused by every ssh and rsync).
2. Verify SSH reachability; ship the kasbah binary if the server's is absent or older.
3. Resolve version = HEAD's `v-tag` (fail if not tagged).
4. Ensure remote dirs exist (`/apps/<name>/`, `backups/`, `/apps/data/<name>/`).
5. Rsync manifest's `sync:` list.
   The Traefik fragment is not shipped here — it goes last, after the stack is
   up, so a failed deploy cannot leave a live route to nothing (`build-deploy.md`).
6. Env drift check on VPS (`kasbah remote setup-env`) — run the setup if missing, prompt on drift.
   Then refresh the kasbah-managed `KASBAH_*` keys in `.env` (resource
   limits from the server marker) — reserved prefix, exempt from drift.
7. Mail claim check (if manifest has `mail:`).
8. Run the engine on the VPS, `kasbah remote deploy run`:
   - If `backup:` configured and its `check` exits 0 → run backup (against
     previous version's still-running containers), rotate.
   - Run `pre-deploy` hooks against previous version's containers.
   - Retag `:<version>` as `:current` for every built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for `health.container` to be healthy.
   - Run `post-deploy` hooks against new containers.
   - Append to `versions.log`, then rotate it (`build-deploy.md` → Rotation).
9. Rsync `traefik-dynamic.yml` to `/apps/traefik/dynamic/<name>.yml` — locally
   driven, after the stack is up, so a failed deploy leaves no live route.
10. Print local changelog (`git log <prev>..<new>`).

Flags:
- `--on-drift=setup|continue|abort` — what step 6 does when the server's `.env`
  has drifted from `.env.prod.example`. Unset it asks; with no terminal to ask
  on the run stops with exit `5`. See `kasbah env` below.
- `--skip-hooks` — skip the pre/post hooks (dry-run style). **The backup still
  runs**: a flag for a dry-run-ish deploy must not also discard the data safety
  net.
- `--no-health-wait` — don't block on healthcheck.
- `--allow-stopped` — deploy over a stack that has deployed here before but
  whose outgoing containers are not running. Without it that is a refusal,
  because the backup and the `pre-deploy` hooks act on those containers and
  skipping them silently is how a backup goes missing exactly when it was worth
  having. The refusal, and this flag, are **per container**: a stopped hook
  container does not excuse skipping a backup whose own container is up, and
  kasbah names which of the two it is talking about. See `build-deploy.md` §
  the outgoing stack.

### `kasbah rollback [USER@HOST] [VERSION]`

Default target: second-most-recent entry with `action=deploy`, read from
`versions.log` and `versions.log.gz` together (`build-deploy.md` → rollback flow).

Flow (see `build-deploy.md` for full detail):
1. Resolve target version.
2. Verify target appears in `versions.log` (or `versions.log.gz`). If not —
   fail; it was never deployed here, so it's a first-time deploy, not a rollback.
3. Verify git tag `v<target>` exists locally (`git fetch --tags` if not).
4. Read v<target>'s files via `git show v<target>:kasbah.yml` and
   `git show v<target>:compose.prod.yml` — no checkout.
5. Extract v<target> to a temp directory, then check each `build:` service
   in its compose: `:<target>` must still be on the VPS (see image
   retention in `build-deploy.md`) — if pruned, fail with roll-forward /
   rebuild-from-tag guidance. The extraction comes first because the check
   reads the ref's compose out of it; what matters is that **nothing
   reaches the server** before the check passes.
6. Rsync the extracted sync list into
   `/apps/<name>/` — not `git archive | tar -x`, which cannot honour the
   `src -> dst` renames every sync list has (`build-deploy.md` → rollback flow).
   The extracted tree is then checked to hold every source the list names:
   `git archive` drops anything marked `export-ignore`, which `git ls-tree`
   still reports, so the tree that will actually ship is what gets validated.
7. Env drift check, exactly as `deploy` runs it — v<target>'s
   `.env.prod.example` has just landed, and its keys may differ from the ones
   the server was last set up against. `--on-drift=` answers it headlessly.
8. On VPS: run the engine in rollback mode, `kasbah remote deploy run`:
   - Run `pre-rollback` hooks against currently-running containers.
   - Retag `:<target>` as `:current` for each built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for health.
   - Run `post-rollback` hooks against rolled-back containers.
   - Append rollback entry to `versions.log`, rotate.
9. Rsync v<target>'s `traefik-dynamic.yml` to
   `/apps/traefik/dynamic/<name>.yml` — **last**, once the remote step has
   returned 0, for the same reason `deploy` ships it last. A version carrying
   no fragment is rolled back anyway and warned about; the fragment already
   there is never deleted.

Flags:
- `--on-drift=setup|continue|abort` — rollback runs the same env step
  `deploy` does (step 7 above), because
  v<target>'s `.env.prod.example` may declare different keys from the one
  the server was last set up against. Unset it asks; with no terminal, the
  run stops with exit `5`. See `kasbah env`.
- `--skip-hooks` — skip the pre-/post-rollback hooks. Unlike `deploy`, there
  is no backup for this flag to preserve: a rollback never takes one.
- `--no-health-wait` — don't block on healthcheck.
- `--allow-stopped` — roll back over a stack that is not running. Per
  container, and for the same reason as `deploy`'s — except that here only
  the `pre-rollback` hooks are at stake.

Rollback restores image + sync'd config only. It does **not** restore
data bind mounts or `.env` secret values. For schema rollback, use
`pre-rollback` hooks.

### `kasbah drop [USER@HOST] [--prune] [--yes]`

Remove the project from the VPS. Plain `drop` is reversible:

Removes:
- containers (`docker compose down`)
- the Traefik fragment (`/apps/traefik/dynamic/<name>.yml`)
- the project's own images — every tag of every repository the project's
  server-side `compose.yml` declares on a service with a `build:` key

Keeps:
- `/apps/<name>/` (compose, `.env`, versions.log, scripts)
- `/apps/data/<name>/` (bind mounts)
- backups (on-VPS and off-VPS)
- named volumes — `down` runs without `-v`, because drop keeps data
- pulled images (`postgres:16`, `nginx:alpine`) — nothing declares them as
  this project's, and unpicking that is `kasbah server prune`'s job

**Which images are the project's, exactly.** The rule is `server prune`'s, in
the same code (`_prune_project_repos`), narrowed to one project — and then
widened in one direction: drop takes *every* tag of a repository it owns, with
no age window and no last-three floor, because after a drop there is no version
to roll back to. A repository **any other project on the server also declares**
is kept. And while **any** project's `compose.yml` cannot be read or parsed, no
repository anywhere is provably single-owner, so **no image is removed at all**
— on any project — and the report names who made it unknowable. This is the
same cliff `server prune` stands on, and for the same reason: a wrong deletion
here takes another project's image with it.

A later `kasbah deploy` brings the project back; the images must be re-shipped
with `build-push` first. **A project that declares `backup:` or a `pre-deploy` hook needs
`kasbah deploy --allow-stopped` for that first return trip** (a post-deploy
hook alone does not) — `versions.log`
survives a plain drop, so the remote preflight sees a project that has deployed
here before while the containers those steps need no longer exist, and refuses
rather than skipping them silently. `drop` prints the exact return command,
flag included when the manifest needs it. (`--prune` removes the record, so that
path is an ordinary first deploy and needs nothing.)

`--prune` additionally deletes `/apps/<name>/`, `/apps/data/<name>/`, and the
project's on-VPS backups (`/apps/<name>/backups/` — **not** the server's
top-level `/apps/backups/`) — everything except the off-VPS restic repo, which
is operator property (see `backup.md`). It also **releases the project's claim on
the shared mail stack**: the domain leaves `<apps>/mail/kasbah.yml`, read and
re-rendered through `_sm_read_registry`, which folds `primary_domain` into the
served list the way the writers do. **Five commands ask "does this stack serve
X"** — `deploy`, `server init`, `add-mail-domain`, `check --server` and `server
status` read through the Go reader (`internal/mailreg`); `drop` through
`_sm_read_registry`, which refuses the same registries, until it is Go (10.12). A
**hand-edited** registry with no `primary_domain`, a non-domain entry or a
non-list `domains:` is refused by name (decision D4): `check --server` reports it
as M03's failure, `server status` as a line. Two deliberate exclusions — a project claiming the
registry's `primary_domain` is refused (releasing it would unmake the stack for
every other project), and docker-mailserver's own `postfix-virtual.cf` alias is
left alone, with the `setup alias del` line printed instead. The reversal is
`kasbah server add-mail-domain USER@HOST <domain>`. Plain `drop` keeps the
claim, and says so.

`--prune` behaves three ways when a compose file cannot be read, because the
three have different reasons:

- **Another project's compose is unreadable** — refused, naming *that* project.
  No repository here is provably single-owner, so none of this project's tags
  can be removed; and `--prune` would stop it being a project on this server,
  after which nothing can attribute those tags to it again. Plain `drop` still
  works and changes nothing a redeploy cannot undo.
- **This project's own compose is unreadable or unparseable** — refused, because
  the deletion would take the only record of what this project builds with it.
  Here "fix the compose.yml" is a remedy that exists.
- **This project's directory holds no `compose.yml` at all** — **proceeds.**
  There is no record to destroy and nothing to fix; the deletion removes no
  images, says so, and names the orphan tags it leaves behind (repositories
  carrying a `:current` that no readable project claims — `:current` is written
  by `deploy` and nothing else, so stock images never appear in that list). A
  deploy that died between `mkdir` and the compose rsync leaves exactly this
  state, and refusing it would leave a hand-run `rm -rf` on the server as the
  only way out.

The plan and the outcome both go to **stdout**; only `warning:` and `error:`
lines go to stderr, so `kasbah drop > log` captures what was planned *and* what
happened. If anything is still wearing the project's compose label after
`down` — `docker compose` selects on `com.docker.compose.oneoff=False`, so an
operator's one-off container survives it — the outcome names it rather than
claiming the project came down.

**Double confirmation:** a yes/no question, then the project name typed back.
Either decline exits 1 having changed nothing. `--yes` skips both, for scripts;
without a terminal an unanswered prompt is a hard fail naming `--yes`.

Takes `<project>/.deploy.lock` **in the act**, the same exclusive lock
the deploy engine holds, so nothing is removed while a deploy is running. The
batched read, the plan and both confirmations run **unlocked** — a read step
never writes into the tree it is reading — so a deploy starting while you answer
the second prompt makes the act refuse. That refusal reads as one: a run stopped
at a guard says it changed nothing, and only a run that got past them says some
of it may have run. A held lock and a missing `flock` are reported as
themselves, never as each other.

Given without a `USER@HOST` it asks the server this project last talked to, and
`last_server` is recorded by a run that **acts** — the nothing-to-do path and a
completed act — not by one that reaches the server and then declines, meets a
held lock, finds no `flock`, or has `--prune` refused
(`project-manifest.md`).

Exits 4 on a host with no server marker; 1 on a decline, a held lock, a missing
`flock`, or a refused `--prune`.

### `kasbah history [USER@HOST] [--all]`

Tabular view of `versions.log`. Columns: timestamp, action, version,
backup file, kasbah version.

A line the frozen format cannot be read out of is still shown — in place,
marked, as the bytes the file holds. Inventing column values for it would
make a truncated write look like a deploy of an unknown version, and the
footer counts how many such lines the file has.

Flags:
- `--all` — include the archived rotation (`versions.log.gz`). By default
  only the active log is shown, with a footer naming how many more are
  archived. Either way, an archive kasbah could not read in full is said
  so in the report itself, not only as a warning: a run redirected to a
  file must not read as the whole record.

`history`, `pending` and `changelog` split their output on one rule: a
sentence that **answers the question asked** is the report and goes to
stdout — including "this project has never deployed here", a line the record
holds that kasbah cannot parse, and the note saying the archive was not read
in full. A **diagnostic about this checkout or the transport** goes to
stderr: a missing tag, an unborn HEAD, a `git log` that failed. Piping any of
the three gives the answer and nothing else.

### `kasbah pending [USER@HOST] [VERSION]`

`git log <deployed>..<VERSION-or-HEAD>` formatted as a changelog. Useful
before cutting a tag. The deployed version is resolved from the VPS at
runtime, never from `state.json` — state is a cache for defaults, not a
source of truth for what is running (`project-manifest.md`).

### `kasbah changelog [USER@HOST]`

`git log <prev>..<current>` — what changed in the version the server is
running now.

The two ends are the **last two entries of the record, whatever their
action** — not the last two `action=deploy` entries. After a rollback the
currently deployed version is the rollback's target, and a changelog
describing a version the server is not running would be answering a
different question. An inverted or empty range is reported as such, in the
same words `deploy` uses for it.

### `kasbah env [USER@HOST] [--on-drift=setup|continue|abort]`

Drift-aware env setup. Ships the kasbah binary if the server's is absent or
older, rsyncs `.env.prod.example` to `<apps>/<name>/`, runs the interactive setup
there over `ssh -t` (`kasbah remote setup-env`), then refreshes the kasbah-managed `KASBAH_*` block in `.env` from
the server marker's resource limits. See `env-template.md` for the template
conventions and the managed block.

The injection is not optional decoration: a `.env` without `KASBAH_CPU_LIMIT`
makes `compose up` fail outright, so a command whose job is producing a usable
`.env` finishes the job. That is also why it reads the server marker and exits
`4` when there is none, exactly as `deploy` does.

The setup is interactive and needs a terminal at both ends. Without one the run
stops with exit `5` rather than feeding the generator EOF, which its
non-interactive contract would turn into every default silently accepted,
secrets included.

Flags, which apply only when `.env` **has** drifted:
- `--on-drift=setup` — re-run the setup. What this command does anyway.
- `--on-drift=continue` — leave `.env` alone and only refresh the `KASBAH_*`
  block. The only answer that gets through without a terminal.
- `--on-drift=abort` — stop, changing nothing (exit `5`).

Unset, a drifting `.env` asks; with no terminal to ask on, the run stops naming
the flag. The prompt has **no default** — an empty answer is asked again, since
Enter must not be able to re-run the generator over a live `.env`.

`--on-drift=` is not a way to run `kasbah env` headlessly in general. With
`.env` missing, or in sync, the flag is never consulted and the run still needs
a terminal (exit `5`); only the drift case has a question for it to answer.

`deploy` carries the same flag for the same step (`build-deploy.md` step 6) —
the difference is that `deploy` runs the setup only when the `.env` is missing
or has drifted, while `env` runs it every time, since that is what it is for.

### `kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]`

Thin wrapper around `docker compose logs` on the VPS. If `SERVICE` is
omitted, shows all services in the project.

Flags:
- `-f` — follow.
- `--tail=100` — lines of history (default 100). `--tail=all` for the whole
  buffer; anything that is neither a count nor `all` is refused here rather
  than by compose on the far side.

Both positionals are optional, which is the same ambiguity `exec` has and it
is resolved the same way: **an argument carrying an `@` is the server, and
anything else is the service.** So `kasbah logs web` reads one service on the
remembered server, and `kasbah logs you@vps` reads every service on a named
one.

Run against `<apps>/<name>/compose.yml` as `docker compose -p <name>`, where
`<apps>` comes from the server's own discovery pointer exactly as `deploy` and
`env` find it. `logs` takes no `--apps-path`: `server init` has the flag
because it is what *establishes* the path, and among the commands that only
read one, `server status` is the sole holder — as the escape hatch for a server
whose pointer is gone.

**Exit status.** `0`, or `1` with a message when `docker compose logs` itself
failed — `logs` does **not** pass compose's status through the way `exec` does,
because the whole command line here is kasbah's (you supplied a service name
and a line count).

Two statuses are neither, and kasbah says nothing about either:

- `255` — the process reading kasbah's stdout closed the pipe: `kasbah logs |
  head`, `| sed 3q`, quitting `less`. 255 rather than the 141 you would expect,
  because OpenSSH ignores `SIGPIPE` — it has a socket to look after — and turns
  the failed write into its own fatal exit. It only arises when the log outruns
  the pipe buffer: a log small enough to fit in it is written in full before the
  reader is missed, and that run is an ordinary `0` (measured both ways on the
  rig). This is also the status of a session that broke for a real reason, and
  in that case ssh has already said so on stderr in its own words — kasbah
  passes those through untouched and adds nothing, rather than printing a
  sentence that would be wrong far more often than right. That is what tells
  the two apart, and it needs no exit code of its own: **255 with nothing on
  stderr is the reader stopping; 255 with a line on it is the link stopping.**
  The closed-pipe path is silent because OpenSSH's fatal exit writes nothing.
- `130` — interrupted.

`129` or `143` mean kasbah itself was sent `SIGHUP` or `SIGTERM` while the log
streamed: it forwards the signal to ssh, says so in one line naming the
signal, and writes no `last_server`, since the read did not finish.

Both are passed through rather than flattened to `0`, so a caller under
`set -o pipefail` is not told the whole log arrived when it did not; `git log |
head` does the same with its own number.

**No terminal is allocated**, `-f` included. `ssh -t` would cook the far side's
output through a pty's line discipline and put a CR before every LF, so
`kasbah logs | grep …` and `kasbah logs > file` would get a different byte
stream from the one compose wrote. Following a log needs no keystroke, only an
interrupt, and Ctrl-C reaches ssh through the terminal's foreground process
group without a pty.

**One consequence, and it accumulates.** A session with no pty is not hung up
when its client dies, so *every* interrupted `kasbah logs -f` leaves a
`docker compose logs -f` resident on the server, each holding an open stream
from dockerd, until its next write to a closed pipe — for a busy service that
is immediate, for a quiet one it is never. One per interrupted follow, forever,
on a box chosen for being small. This is the price of the choice above, not a
detail of ssh: kasbah picked no-pty and owns it. The broom, spelled narrowly
enough not to be a second problem:

```
ssh you@vps "pkill -f '<apps>/<name>/compose.yml logs'"
```

Not `pkill -f 'compose -f <apps>/<name>'`: that also matches a concurrent
`kasbah exec` on the same project, and another operator's follower with it.
A pty would hang the session up and cost every piped log its CRs, which is not
a trade this command makes.

### `kasbah exec [USER@HOST] SERVICE -- CMD…`

`docker compose exec SERVICE CMD…` over SSH. The `--` is mandatory so flags
after it belong to the inner command. `SERVICE` is required; if it looks
like `user@host` (contains `@`) kasbah treats it as the server.

Same apps-path discovery and same `-p <name>` as `logs` above.

**The terminal is decided per invocation, not per command.** A pty is asked for
only when this side has one at *both* ends — stdin and stdout are both a tty —
which is the shape an interactive shell has. That keeps
`kasbah exec db -- pg_dump … > dump.sql` free of the CRs a pty would insert.
Otherwise the command runs under `docker compose exec -T`, compose's own
spelling of "no tty", with its stdin closed: feeding data *into* an exec'd
command is not something this command does.

**CMD's own exit status is `kasbah exec`'s exit status** — see "Exit codes"
below. `last_server` is written whichever it is: kasbah's own work (resolve the
server, find the stack, run what was asked) succeeded the moment the command
ran, and `kasbah exec web -- test -f /srv/x` answering 1 is a fact about the
container rather than a failed run. Two exceptions: when ssh could not even
be started (exit 1, nothing written), and when kasbah itself is sent
`SIGHUP`/`SIGTERM` mid-command — it forwards the signal, warns in one line,
exits `129`/`143` and still writes `last_server`, since the command ran.

## Deferred commands

Referenced elsewhere in the docs but not yet in v0.1:

- `kasbah migrate` — migrate a project's source-tree files to a newer
  kasbah schema. (roadmap v1.0.)

## Exit codes

- `0` success
- `1` generic failure
- `2` not a kasbah project (no `kasbah.yml`)
- `3` SSH unreachable
- `4` remote state missing — no server marker where the apps path says it
  should be. Three situations, and none of them is "a server prepared with
  `--apps-path` cannot be found" — the discovery pointer
  (`/etc/kasbah/apps-path`) closed that one:
  - the server was never prepared, and `kasbah server init` is the answer;
  - it was prepared and the pointer is gone, so kasbah is looking under
    `/apps` at a server that lives elsewhere. **Re-running init is the wrong
    move here** — pointed at the default it would render a second Traefik
    stack under the frozen `traefik` compose project and recreate the running
    proxy against it, taking every site down. Find the real apps path
    (`kasbah server status <host> --apps-path=<dir>`) and restore the pointer.
  - the pointer names a tree with **no marker under it**. kasbah does not fall
    back to `/apps` here and says so: silently reading a different server's
    marker is how a deploy lands on the wrong machine.

  All three are one verdict — no marker where the apps path says one should be
  — so all three exit 4, and the **message** is what distinguishes them.
  Commands that exit 4 say which situation they are in rather than
  prescribing init.
- `5` env setup could not complete. Covers both halves of the same sentence —
  the project's `.env` on the server is not in a state kasbah will deploy
  against, and nothing was deployed: drift the user declined to fix
  (`--on-drift=abort`, or an aborted setup), a `.env` that is missing or
  unrenderable with no terminal to render it on, **and** the setup not
  finishing on the far side — including when it could not be run at all. One
  code rather than several, because the operator's next move is the same in
  every case: run `kasbah env` from a terminal, or pass `--on-drift=`.
- `6` compliance check failed

`kasbah exec` departs from this list furthest: it exits with **the status of
the command it was asked to run**, whatever that is, because a wrapper that
collapses its payload's status to 0 or 1 lies about the only thing it exists to
do. Every layer underneath it — ssh, `docker compose exec`, the command — passes
the status through already.

kasbah's own refusals still come first and still use the codes above (`2` with
no `kasbah.yml`, `3` for a server that does not answer, `4` with no marker).
**But a non-zero status from `exec` is not therefore the command's**, and there
is no rule that makes it one: `docker compose exec -T nosuch true` exits `1`
with `service "nosuch" is not running`, having never run anything, and an ssh
connection lost mid-command exits `255`. Both are indistinguishable by code
from `kasbah exec web -- test -f /srv/x` answering `1`. What separates them is
the text on stderr, and in those two cases it is **compose's or ssh's own line,
not kasbah's** — so read it rather than the number. A script that must know
whether its command ran should have the command say so.

`kasbah logs` does not propagate: compose failing is `1` with a kasbah message.
Its `255`/`130` — a reader that stopped reading, and an interrupt — are
described in its own section above.
