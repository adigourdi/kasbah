# CLI Reference

Two levels of commands:

- **`kasbah server …`** — act on a VPS. Always take `user@host` as first arg.
- **`kasbah …`** (everything else) — act on a project. Run from the project
  root. Read `./kasbah.yml`. Error if missing.

`kasbah`, `kasbah -h` and `kasbah --help` print the command list and exit 0;
`kasbah --version` (`-v`) prints the tool and the manifest schema it writes —
`kasbah 1.0.0 (schema 1)`. An unknown command, or `kasbah server` with a missing
or unknown subcommand, names itself and exits 1.

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
it never treats absence as "no". `--with-dashboard`/`--no-dashboard` is asked
only on a first init; a re-run with neither keeps the server's dashboard as
`_shared.yml` has it (`traefik.md` → Dashboard). Without a TTY, an unanswered
choice is a hard fail naming the flag to pass.

Flags:
- `--domain=<apex>` — the apex the Traefik dashboard is served under
  (`traefik.<apex>`), and a new mail stack's primary domain. Unused — a warning,
  not an error — with the dashboard off and no new mail stack.
- `--with-dashboard` / `--no-dashboard` — serve the Traefik dashboard behind
  basic auth, or leave it out (`traefik.md` → Dashboard).
- `--email=<addr>` — ACME email for Let's Encrypt registration.
- `--with-mail` / `--no-mail` — scaffold `/apps/mail/` (DMS + Cypht) and
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
  none. **Do not embed credentials in it** — the marker is mode 664 by
  contract, world-readable, so a secret in this URL is readable by anyone on the VPS.
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
- `--acme-dns=<provider>:<env file>` (repeatable) — add or replace a DNS-01
  resolver named after the provider (lego's name: lowercase letters and
  digits opening with a letter, never `http`, `letsencrypt` or a word YAML
  reads as a boolean or null), its credentials read here from the file's
  `KEY=value` lines and installed at `<apps>/traefik/acme-dns/<provider>.env`
  (mode `640`, group `kasbah`). The file is refused before anything connects
  when it is missing, not a regular file, readable by group or others, or not
  in the plain shape compose reads as written (`traefik.md` → DNS-01: unquoted
  printable-ASCII values without `"` `'` `` ` `` `$` `\` `#`); a refusal names
  the line and the key, and the values are never printed.
  `--no-acme-dns=<provider>` removes the resolver and its env file — refused,
  naming each file, while any file under `dynamic/` but `_shared.yml` holds
  the provider's name as a whole word in any case, comments included, or is a
  file kasbah cannot read as Traefik would (`traefik.md` → DNS-01). Unset
  keeps every DNS resolver the server's `traefik.yml` declares, without asking — like `--acme-staging`, the status quo is the
  default, and asking on every run would make the common one worse; a
  declared provider whose env file is missing is a hard fail naming both
  flags. `traefik.md` → DNS-01.
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
   created unelevated. Without passwordless sudo, init prints those commands
   and, at a terminal, waits for Enter and re-checks; without one it fails
   naming them. See `server-setup.md` ("Who creates the apps path").
   Then `mkdir -p /apps/data /apps/backups`.
3. `mkdir -p <data>/traefik/letsencrypt && touch <data>/traefik/letsencrypt/acme.json && chmod 600 ...`
   (touch-as-file is mandatory — Docker silently creates a directory otherwise).
4. Scaffold `/apps/traefik/` — compose.yml, traefik.yml, and dynamic/ with
   `_shared.yml`. No `.env`: Traefik interpolates no environment variables,
   so `--domain`, `--email`, the `--traefik-auth` hash and the ACME `caServer`
   are baked into the
   rendered files (see `server-setup.md`). The container's one environment is
   each DNS provider's credentials (`--acme-dns=`), whose env files are
   installed under `acme-dns/` before `compose.yml`, which names them in
   `env_file:`, ships.
5. Reconcile the certificate store with the CA now configured. `acme.json`
   holds certificates issued by one CA; changing `caServer` does not
   invalidate them, so Traefik goes on serving certificates from the old
   endpoint and only swaps them at renewal — which is how a server ends up
   configured for staging while still presenting a production certificate.
   **An empty or absent store is never touched and never asks**, so a fresh
   server stays silent. A store with content takes one of two paths:
   - **The recorded CA differs from this run's.** Init asks once, archives the
     store to a timestamped sibling — never deletes it, since a production
     `acme.json` is real certificates — empties it in place (mode 600), and lets
     the restart below re-issue. Declining aborts with nothing created
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
   Once Traefik is healthy, the env files of providers it no longer reads are
   removed — save one a file under `dynamic/` still names, which is kept with
   a warning naming those files.
7. Health-check Traefik, print the dashboard URL. Plain HTTP redirects to
   HTTPS, and the dashboard carries HSTS on its 401 (`traefik.md` → Dashboard).
8. If `--with-mail`: this is spread across steps 5-7 rather than sitting
   after them, because the ordering is what breaks the boot deadlock.
   `/apps/mail/` (`compose.yml`, `kasbah.yml`, `.env`), the cert-trigger +
   webmail fragment at `/apps/traefik/dynamic/_mail.yml`, and the two
   pre-seeds land **before** Traefik starts, so Traefik requests both
   certificates at configuration load. The mail containers start **after**
   Traefik is healthy, because DMS reads `mail.<domain>`'s certificate out of
   `acme.json`. Init waits for Cypht and reports DMS without waiting for
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
the project's last 3 deployed clean versions — the version `:current` points
at counts as the first of the 3, and `:current` itself is never pruned, even
when it is a `-dirty.` build; other dirty tags never count toward the 3.
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
(`kasbah remote prune rm <apps> <tag>…`), holding the server lock exclusively
(`server-setup.md` → Operators). Every decision is made on the workstation. Exits 4
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
must hold or the run is a failure rather than a pass — `kasbah-dry-run-anchor@file`,
a router only the dry run's overlay carries, must be among them, and, whenever
the server's `dynamic/` holds any fragment besides `_shared.yml`, so must a
router that is not one of `_shared.yml`'s. The anchor comes from the overlay
this run writes, so on its own it would appear even if the server's directory
read as empty.

The target image is pulled during the dry run, so a tag that does not exist
fails while the live proxy is still untouched, and the pull cannot fail
later, mid-switch.

The values are recovered off the server and reproduced verbatim: the ACME
address and endpoint, the DNS-01 resolvers, and — when the dashboard is on —
its apex and basic-auth entry; a stack with no dashboard router upgrades as one
without a dashboard. Every resolver, the DNS ones included, points at the dry
run's loopback CA and a throwaway store, and the throwaway gets no provider
credentials. A DNS resolver whose env file is missing on the server is refused
before the dry run (the stack would not start without it); the env files are
never backed up or written. A
stack that will not yield them is refused, naming the one
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

De-brand the VPS for handover. **Every project container keeps running
throughout** — projects, Traefik and mail; the sites stay up — except kasbah's
own backup scheduler (`kasbah-backup`, removed with its volume and network), and a project still `compose up`s
afterwards from the server's own files. Removes kasbah's management layer, and
above all every agency-owned secret.

Server-wide:
- `<apps>/.kasbah/server.json`, then — as the run's last act, once every step
  before it succeeded — kasbah's own binary `<apps>/.kasbah/bin/kasbah` and
  `<apps>/.kasbah/` once empty
- `/etc/kasbah/apps-path`, and `/etc/kasbah/` once it is empty — root-owned, so this needs
  root. Without passwordless `sudo`, destroy prints the commands
  (`sudo rm -f …`, `sudo rmdir …`) and, at a terminal — `--yes` included —
  waits for Enter and re-checks. `sudo rmdir /etc/kasbah` stays among the
  commands while the directory exists and holds nothing else; one holding
  something kasbah did not write is left alone and said so. Without a
  terminal, or after `q`, the run **warns and continues**, exits 0, and leaves
  the commands to finish by hand. A server left in that state has no
  marker but still has its pointer, and destroy says so on a re-run rather than
  claiming there is nothing to remove.
- the **backup stack**, stopped rather than merely unlinked: `docker compose -p
  kasbah-backup down`, then the container, the `kasbah-backup-cache` volume, the
  `kasbah-backup_default` network, then `<apps>/.kasbah/backup/` entire —
  `compose.yml`, `env`, `repos/*.pass`, `state/` (and a `backup.sh` left by a
  kasbah 0.x). A schedule left
  running would go on pushing the new owner's data into the departing agency's
  storage. **The restic repositories are never touched**: operator property, and
  an append-only credential could not delete them anyway.

Per project:
- `versions.log` and `versions.log.gz`
- the `scripts/` helpers, **by name** — `remote-deploy.sh` and `setup-env.sh`,
  then `rmdir`. The directory survives if it holds anything else, because
  destroy cannot tell an operator's file from kasbah's except by name
- `.kasbah-prev/`, a failed deploy's snapshot, which holds a copy of `.env`
- every snapshot a backup could not take in (`.kasbah-prev.kept-*/`), and
  every backup a killed rollback left extracted (`.kasbah-unpacked.*/`), each
  likely holding a copy of `.env`
- every staged `--env-seed` (`.kasbah-env-seed.*`), which holds `.env` values
- `.deploy.lock`, and `.kasbah-client` (written by `deploy`, read by the backup
  run — see `project-manifest.md`), and `.kasbah-hooks.json`
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

Traefik, if `server init --acme-dns=` gave it DNS providers:
- `<apps>/traefik/acme-dns/`, every provider's credentials, after their
  `env_file:` lines are dropped from `<apps>/traefik/compose.yml` so the stack
  still comes up from its own files. The running Traefik keeps the values until
  it is recreated; the resolvers stay in `traefik.yml`, for the new owner to
  give credentials of their own or remove.

Kept: every container and image, Traefik and its fragments, `data/`,
`<apps>/backups/` and every `<apps>/<project>/backups/`, named volumes, and the projects' compose files and `.env`
values. There is no `kasbah.yml` to remove — the manifest is never synced to a
server.

**The trade-off is explicit, and it is wider than it looks.** Deploy history and
env tooling leave with kasbah — and so does the mail registry, which is the only
record of `primary_domain` and the domain list. A later re-branding
`kasbah server init --with-mail` cannot reproduce either; both must be
re-entered.

**Double confirmation:** a yes/no question, then the **hostname** typed back.
Either decline exits 1 having changed nothing but, possibly, kasbah's own binary
(brought up to date before the plan is read). `--yes` skips both.

A run that cannot finish **holds back the marker and the pointer**, so the
server is still discoverable and the command can be re-run. It exits 1 and says
which step failed. A second run on a fully de-branded server reports that the
server carries nothing of kasbah's and exits 0 — it does not exit 4, because a
completed destroy removes its own marker by design. When the marker is gone but
only kasbah's own last step is left — the pointer and the kasbah binary, a run
whose session dropped before it got there — the re-run finishes that step and
says so. But a server with **no
marker and a surviving `<apps>/.kasbah/backup/`** exits **1**: that directory is
the repository URL and one password per repository at mode 600, and without a
marker destroy cannot enumerate the rest to remove them. The contrast with the
no-sudo case above is deliberate — what that leaves is a world-readable
discovery pointer, and what this leaves is the credentials the command exists to
take away.

### `kasbah server status USER@HOST [--apps-path=<dir>]`

It changes nothing on the server but kasbah's own binary, which it brings up to
date first (`<apps>/.kasbah/bin/kasbah`, same-build rule) — and never on a server
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
- The mail stack: `mail-dms` and `mail-cypht` by their compose labels with
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
  each of them (or, when the fragment has no HTTPS router, that no
  certificate is expected), and each container's state and health. A project
  whose containers are all running and none unhealthy gets one line saying so;
  one that is not gets a line per container, because that is the case a count
  cannot show.
  Then, for a project holding any, each kind of leftover a deploy or rollback
  left in its directory — backup directories under `backups/` whose tarball
  was never written, `.kasbah-prev.kept-*` snapshots a backup could not take
  in, `.kasbah-unpacked.*` extractions a killed rollback left — with its count,
  the newest by the stamp in its name aged against the server's clock (an
  extraction's name carries none), and that each may hold a copy of `.env`,
  then to inspect each and remove it by hand. While a run holds the project's
  `.deploy.lock` — read from `/proc/locks`, without taking it — its backup
  directories and extractions are not called leftovers: they are followed by
  a line saying a run holds the lock now, naming it, and that a backup directory or
  extraction may be its own; the extraction named by the holder's pid is left
  out. Kept-aside snapshots are leftovers whatever holds the lock. A project
  whose directory or `backups/` cannot be listed gets a line saying its
  leftovers cannot be checked, and why. Nothing is printed for a project with
  none, and nothing inside them is read; `check --server` names every path
  (B02). The projects scanned are B02's: an entry under the apps path with a
  project's name, not one kasbah reserves, that is a directory or a symlink to
  one.

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
or a Traefik API call with the dashboard credentials. kasbah **fetches the
fragment in the same round trip and parses it on the workstation**. The credentials route would
yield certificates and router health in one call, but `status` holds only the
bcrypt hash from `_shared.yml` — never the password — so it would need a new
flag or prompt plus reachability to `traefik.<apex>`. The VPS has no `yq`, `jq`
or `python3` and keeps needing none.

One value the server has to work out for itself is the **data path**, which the
certificate store and the data disk figure both hang off: the server binary reads
it out of the server's marker.

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
the project's own `kasbah` network, with a healthcheck so a deploy rolls it
(C11), and two routers for the domain so plain HTTP
redirects rather than 404s (T08).

Flags:
- `--name=<name>` (default: current directory name)
- `--domain=<fqdn>`

### `kasbah check [--server [USER@HOST]] [--fix [--yes]]`

Run the compliance check on the current project. See `compliance.md` for
the full rule set. Exit code 0 on pass, 6 on any failure (see "Exit codes" below),
and 1 — naming the file and the reason — when a file is shaped so badly that a
rule cannot be evaluated at all: inside a mapping `services:`, a service that is
neither null nor a mapping (`services: {web: nginx}`) or a `networks:` entry
that is not a mapping; inside a mapping `http.routers`, a router that is not a
mapping or a `websecure` router whose `tls:` is not one; and an unreadable
`.env.prod.example`. Every other bad shape — a compose file that does not parse,
holds several documents, or whose document or `services:` is not a mapping, and
every manifest shape — is a named failure (6).

`--server USER@HOST` also asks that VPS: whether the project is deployed there,
whether its `.env` still matches this checkout's `.env.prod.example`, whether
the mail stack knows the claimed domain (M03), whether `health.container` is
healthy, what Traefik's `acme.json` holds for the project's domain (under the
resolver its router names), and whether
the effective resource limits are within the host's ceiling (R04), whether
the projects' own limits fit the host together (R06), whether
every mail domain on it can sign (M04), whether the backup stack ran (B01),
whether any project holds a leftover backup directory, kept-aside snapshot or
rollback extraction that may hold a copy of `.env` (B02) and
whether the apps tree is the operators' group's. It also
tightens T05 from a first-label heuristic to the hostnames that server really
owns, and reads the server's `traefik.yml` so T04 and T10 judge a resolver
other than `http` against the ones it declares. It changes nothing on the server but kasbah's own binary, brought up to
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

The fixes are **targeted text edits, never a YAML round-trip**: a round-trip reorders
keys and drops comments, and compose files carry load-bearing ones. Everything
not being changed comes back byte for byte — comments, blank lines, key order,
quoting, hand-spacing, CRLF line endings and a missing final newline included. A
comment sitting immediately *above* a removed key is **left**, because it cannot
be told from a file header, and a compose file that opens with prose and then
`version:` is the ordinary shape.

The parsed document decides what is true; the text scanner only finds where it is written. When
the scanner cannot take a shape apart — a quoted key, a flow mapping, an
inline value — the fix is **refused and named**, never guessed. So is a
`compose.prod.yml` that does not parse. Two rules are also refused case by case,
with the reason printed: **C08** on a built service that names no `image:` at
all (it is a tag rewrite, and kasbah will not invent an image name), and **C04**
under the banned default-alias shape, where declaring the default network
external would entrench exactly what C07 is failing on.

`--fix` runs **before** the report, so the lines you read and the exit code you
get describe the project as it now is. Traefik rules, C07, C09, C11, hooks and
mail claims are never auto-fixed — routing and topology are policy, and kasbah cannot
invent a command.

### `kasbah build-push [USER@HOST]`

1. Resolve version from git tag on HEAD (exactly one `vX.Y.Z`), on a clean tree
   (`build-deploy.md` → Versioning contract). Fail otherwise — or, with
   `--dirty`, label the build `<base>-dirty.<UTC stamp>`.
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
5. Ask the server which layers it already holds (`kasbah remote layers`), then
   one `docker save` of every built image with those layers left out, gzipped
   and streamed over ssh into the server's `kasbah remote load`, which feeds
   `docker load` and confirms each image (`build-deploy.md`). Nothing is written
   to disk on either end; a stream cut short is refused. The summary says how
   many layers, and how many bytes, were not sent. On a containerd-store
   workstation an unknown layer name first costs one local learning export,
   announced in a line (`build-deploy.md`).
6. Ask origin whether it has `v<version>` — read-only: kasbah never pushes a
   tag. When it lacks it, one `git:` line under the summary says the server
   runs a version origin cannot fetch, and how to publish it (`git push
   origin v<version>`); an origin that cannot be asked is one line saying the
   tag went unchecked, never a failure. A tag origin has, or a repository with
   no `origin` remote, says nothing.

`build-push` does **not** set `:current` and does **not** run `compose up`.
Moving `:current` is `deploy`'s responsibility. `:latest` is never set. It does
run `compose build` — that is the one compose verb it uses.

`USER@HOST` follows the same rule as every other project command: the argument,
else `last_server` from `.kasbah/state.json`, which is written on success.
`--build-only` needs neither, since it never reaches a server.

Flags:
- `--build-only` — skip transfer and load (local build + tag only).

Images are built for the **server's** platform, `linux/<arch>` from the
bootstrap probe, through `DOCKER_DEFAULT_PLATFORM` — so an arm64 Mac or an arm64
Linux machine ships what an amd64 VPS runs; the run says so when it differs from
the local engine's, and overrides a `DOCKER_DEFAULT_PLATFORM` set by hand (saying
so too). A cross build needs the engine's emulation (`tonistiigi/binfmt
--install <arch>`), which a failing one names. A service's own `platform:` in
`compose.prod.yml` still wins and is not checked against the server.
`--build-only` reaches no server and builds for the local engine.
- `--bump=patch|minor|major` — on an untagged HEAD, which tag to cut
  (`build-deploy.md` → Versioning contract); unset means ask.
- `--dirty` — build the working tree as it stands, as a test build labelled
  `<base>-dirty.<UTC stamp>`; no tag is needed, and origin is not asked. The
  label, target and the tree's digest are recorded in `.kasbah/state.json`
  for `deploy --dirty` (not when the tree changed during the build);
  `--dirty --build-only` records nothing.

### `kasbah deploy [USER@HOST] [VERSION] [flags]`

Two modes:

- **No `VERSION` arg** — deploys the **working tree**, labeled with HEAD's
  `v-tag` — on an untagged HEAD of a project that builds nothing it asks which
  tag to cut first (`--bump=`); one that builds images is sent to `build-push`
  — and fails fast when the tree is not clean. With
  `--dirty` it deploys the tree as it stands under the label the last
  `build-push --dirty` recorded for this server and this exact tree (a
  stock-only project labels its own), and refuses otherwise, naming
  `kasbah build-push <target> --dirty`.
- **Explicit `VERSION`** — deploys that tagged version exactly as it was,
  read out of the `v<VERSION>` ref (no checkout, working tree untouched).
  See the rollback flow in `build-deploy.md`: it is the same code path, and
  only five things differ — the log entry is `action=deploy`, the hook pair
  is `pre-/post-deploy` and the `backup` hook runs, nothing is restored from
  a backup (no `.env` or data question, no `--with-env`/`--with-data`),
  there is no "must already be in versions.log"
  precondition, since deploying a version here for the first time is
  exactly what this mode is for, and the tag's `resources:` is held to a
  plain deploy's rules (refused when malformed, unresolvable or above the
  ceiling) where a rollback warns and takes the ceiling. Its summary carries
  the same origin check as a rollback's: a tag origin lacks is one `git:`
  line under it.

Flow (no-args / working-tree path):
1. Resolve version = HEAD's `v-tag`, cutting one first on an untagged HEAD of a project that builds nothing (`--bump=`) — before anything connects.
2. Open SSH ControlMaster for the whole deploy (reused by every ssh session and file transfer).
3. Verify SSH reachability; ship the kasbah binary if the server's is absent or older (asking first when a dev build would replace a release — Hand-off below).
4. Snapshot what the run will overwrite (the sync targets and `.env`, so a
   failed `up` or health wait can revert — `build-deploy.md`), then ensure
   remote dirs exist (`/apps/<name>/`, `backups/`, `/apps/data/<name>/`).
5. Sync the manifest's `sync:` list (`kasbah remote sync`: only changed files travel).
   The Traefik fragment is not shipped here — it goes last, after the stack is
   up, so a failed deploy cannot leave a live route to nothing (`build-deploy.md`).
6. Env drift check on VPS (`kasbah remote setup-env`) — run the setup if missing, prompt on drift.
   Then refresh the kasbah-managed `KASBAH_*` keys in `.env` (resource
   limits from the server marker, or `kasbah.yml`'s `resources:` — resolved
   on the server once step 1's tag exists and the server lock is held, before
   step 4: a value above the marker's ceiling stops the run with nothing of the
   project changed on the server, though a tag step 1 just cut stays in the
   local repository) — reserved prefix, exempt from drift. The summary's `limits:` line says where each came from.
7. Mail claim check (if manifest has `mail:`).
8. Run the engine on the VPS, `kasbah remote deploy run`:
   - Create `backups/<outgoing version>-<stamp>/` and run the `backup` hooks
     into it (`$KASBAH_BACKUP_DIR`), against the previous version's
     still-running containers; `--skip-hooks` does not skip them.
   - Run `pre-deploy` hooks — shell, on the server, from the project folder —
     while the previous version still runs. On a first deploy these and the
     `backup` hooks are skipped; otherwise a failure of either asks whether to
     carry on (`--on-hook-failure=`).
   - Retag `:<version>` as `:current` for every built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for `health.container` to be healthy.
   - Run `post-deploy` hooks, against the new containers.
   - Keep the outgoing version's backup: the snapshot of step 4 and what the
     `backup` hooks wrote, as `backups/<outgoing version>-<stamp>.tar.gz`
     (also when only a `post-deploy` hook failed); render
     `.kasbah-hooks.json`.
   - Append to `versions.log`, field 4 naming that tarball, then rotate it
     (`build-deploy.md` → Rotation), then remove the backups older than 24
     hours but the newest of them (`build-deploy.md` → A deploy that fails …
     reverts). The summary's `backup:` line names the tarball, or says none
     was taken.
9. Sync `traefik-dynamic.yml` to `/apps/traefik/dynamic/<name>.yml` — locally
   driven, after the stack is up, so a failed deploy leaves no live route.
10. Ask origin whether it has `v<version>`, once the server is let go — the
    same read-only check and one `git:` line as `build-push` step 6; it never
    fails the run. Then print the local changelog (`git log <prev>..<new>`).

Flags:
- `--bump=patch|minor|major` — on an untagged HEAD, which tag to cut; unset
  means ask.
- `--on-drift=setup|continue|abort` — what step 6 does when the server's `.env`
  has drifted from `.env.prod.example`. Unset it asks; with no terminal to ask
  on the run stops with exit `5`. See `kasbah env` below.
- `--env-seed=FILE` — answer the keys step 6 would ask from `FILE`'s
  `KEY=value` lines: every key on a first deploy, the keys `.env` lacks on
  drift. See `kasbah env` below.
- `--skip-hooks` — skip the pre/post hooks (dry-run style). **The `backup`
  hooks still run**: a flag for a dry-run-ish deploy must not also discard the
  data safety net.
- `--no-health-wait` — don't block on healthcheck.
- `--on-hook-failure=continue|stop` — what the engine does when the backup or a
  `pre-deploy` hook fails, before any container has moved.
  `continue` runs on to the retag and `compose up` as if it had passed, and both
  the server's output and the summary say the run carried on past it; `stop`
  puts back the files the run shipped, starts nothing and fails — what the
  hooks that already ran did is not undone. Unset it asks on the terminal; with
  no terminal to ask on the run stops as with `stop` and fails naming the flag.
  The server waits 10 minutes for the answer, holding the project's and the
  server's locks, then stops; a signal at the workstation answers `stop`. Any
  other value is refused before anything connects. See `build-deploy.md` → A deploy that fails … reverts.

### `kasbah rollback [USER@HOST] [VERSION]`

Default target: the most recent `action=deploy` entry before the running one
that is not a `-dirty.` build, read from `versions.log` and `versions.log.gz`
together (`build-deploy.md` → rollback flow); it says how many dirty deploys it
stepped over. A dirty `VERSION` is refused.

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
   Then the run looks for v<target>'s newest backup on the server,
   `backups/<target>-<stamp>.tar.gz`, and settles what it restores from it:
   `.env` — the names of the keys its `.env` and the server's disagree on are
   listed, never a value, and the answer is restore, keep, or per key — and
   the data, when v<target>'s manifest has a `restore` hook. Flags below;
   without them and without a terminal, the run fails here naming them,
   nothing changed.
6. Sync the extracted sync list into
   `/apps/<name>/` — not `git archive | tar -x`, which cannot honour the
   `src -> dst` renames every sync list has (`build-deploy.md` → rollback flow).
   The extracted tree is then checked to hold every source the list names:
   `git archive` drops anything marked `export-ignore`, which `git ls-tree`
   still reports, so the tree that will actually ship is what gets validated.
7. The `.env` chosen above written on the server (after the snapshot, so a
   revert puts the server's back; a failure before the engine runs puts it
   back too, and says so), then the env drift check, as `deploy` runs
   it — v<target>'s
   `.env.prod.example` has just landed, and its keys may differ from the ones
   the server was last set up against. `--on-drift=` answers it headlessly.
   v<target>'s `resources:` never stops it: a value above today's ceiling
   warns and takes the marker's ceiling for that half, and a block this
   kasbah refuses or a resolve that fails takes it for both.
8. On VPS: run the engine in rollback mode, `kasbah remote deploy run`:
   - Extract the backup into `<apps>/<name>/.kasbah-unpacked.<pid>/`, handed
     to the hooks below as `$KASBAH_BACKUP_DIR` (`none` without a backup),
     and removed however the run ends.
   - Run `pre-rollback` hooks — shell, on the server, from the project folder —
     while the outgoing version still runs.
   - Run v<target>'s `restore` hook, when the data answer was yes.
   - A failed extraction, `pre-rollback` or `restore` hook asks whether to
     carry on (`--on-hook-failure=`); stop puts the files and `.env` back and
     leaves whatever the `restore` hook already did to the data. Carried past
     a failed extraction, the `restore` hook does not run.
   - Retag `:<target>` as `:current` for each built image.
   - `docker compose up -d --remove-orphans`.
   - Wait for health.
   - Run `post-rollback` hooks, against the rolled-back containers.
   - Keep the snapshot of what the run overwrote as the backup of the version
     it left, `backups/<outgoing version>-<stamp>.tar.gz`; render
     `.kasbah-hooks.json` from v<target>'s manifest.
   - Append rollback entry to `versions.log`, field 4 naming that backup,
     rotate, apply backup retention (as `deploy`).
9. Sync v<target>'s `traefik-dynamic.yml` to
   `/apps/traefik/dynamic/<name>.yml` — **last**, once the remote step has
   returned 0, for the same reason `deploy` ships it last. A version carrying
   no fragment is rolled back anyway and warned about; the fragment already
   there is never deleted.
10. Ask origin whether it has `v<target>`, once the server is let go — the
    same read-only check and one `git:` line as `build-push` step 6; it never
    fails the run.

Flags:
- `--on-drift=setup|continue|abort` — rollback runs the same env step
  `deploy` does (step 7 above), because
  v<target>'s `.env.prod.example` may declare different keys from the one
  the server was last set up against. Unset it asks; with no terminal, the
  run stops with exit `5`. See `kasbah env`.
- `--env-seed=FILE` — answers that env step's keys from a file, as on
  `deploy`. See `kasbah env`.
- `--with-env` / `--no-env` — restore the `.env` held in v<target>'s backup,
  whole, or keep the server's. Unset, differing keys ask — restore, keep, or
  one question per key (backup's or server's), which only a terminal can
  answer; with no terminal the run fails naming the pair. No backup, or no
  key that differs, asks nothing.
- `--with-data` / `--no-data` — restore the data with v<target>'s `restore`
  hook, from that backup — it replaces everything written since the backup
  was taken — or leave it. Unset, a backup and a `restore` hook ask; with no
  terminal the run fails naming the pair. `--with-data` when v<target> has no
  backup on the server, or its manifest no `restore` hook, is refused before
  anything changes, naming which and pointing at `--no-data`.
  Both pairs are a rollback's: `deploy` refuses them.
- `--skip-hooks` — skip the pre-/post-rollback hooks, never the `restore`
  hook. Unlike `deploy`, there
  is no backup hook for this flag to preserve: a rollback never runs one, and
  keeps its snapshot as the backup either way.
- `--no-health-wait` — don't block on healthcheck.
- `--on-hook-failure=continue|stop` — what the engine does when the
  backup's extraction, a `pre-rollback` hook or the `restore` hook fails, as
  on `deploy`: unset it asks, and with no terminal it stops and fails naming
  the flag.

Rollback restores the image and the synced config, and, from v<target>'s
newest backup on the server, its `.env` and — through its own `restore`
hook — its data, when answered so. Without such a backup it restores neither
(`build-deploy.md` → What rollback restores).

### `kasbah drop [USER@HOST] [--prune] [--yes]`

Remove the project from the VPS. Plain `drop` is reversible:

Removes, in this order:
- the Traefik fragment (`/apps/traefik/dynamic/<name>.yml`)
- Traefik's attachment to the project's network (`<project>_kasbah`), which
  `compose down` could not otherwise remove
- containers and the project's networks (`docker compose down`) — a network
  that is still there afterwards (still in use) is reported as a failed down
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
the same code (`prune.Repos`), narrowed to one project — and then
widened in one direction: drop takes *every* tag of a repository it owns, with
no age window and no last-three floor, because after a drop there is no version
to roll back to. A repository **any other project on the server also declares**
is kept. And while **any** project's `compose.yml` cannot be read or parsed, no
repository anywhere is provably single-owner, so **no image is removed at all**
— on any project — and the report names who made it unknowable. This is the
same cliff `server prune` stands on, and for the same reason: a wrong deletion
here takes another project's image with it.

A later `kasbah deploy` brings the project back; the images must be re-shipped
with `build-push` first. **A project that declares a `backup` or a `pre-deploy`
hook may need `kasbah deploy --on-hook-failure=continue` for that first return
trip** (a post-deploy hook alone does not) — `versions.log` survives a plain
drop, so the engine runs the `backup` and `pre-deploy` hooks, and the
containers they may reach for no longer exist; without a terminal, a failure
there stops the deploy. `drop` prints the return command, flag included when
the manifest declares either. (`--prune` removes the record, so that
path is an ordinary first deploy and needs nothing.)

`--prune` additionally deletes `/apps/<name>/`, `/apps/data/<name>/`, and the
project's on-VPS backups (`/apps/<name>/backups/` — **not** the server's
top-level `/apps/backups/` — and any snapshot a backup could not take in,
kept aside as `/apps/<name>/.kasbah-prev.kept-*/`, and any backup a killed
rollback left extracted, `.kasbah-unpacked.*/`) — everything except the off-VPS restic repo, which
is operator property (see `backup.md`). It also **releases the project's claim on
the shared mail stack**: the domain leaves `<apps>/mail/kasbah.yml`, read and
re-rendered through `internal/mailreg`, which folds `primary_domain` into the
served list the way the writers do; a registry that changed between drop's read
and its write is left alone and the run fails naming it. **Every command that
asks "does this stack serve X"** — `deploy`, `drop`, `server init`,
`add-mail-domain`, `check --server`, `server status` — reads through that one
reader. A
**hand-edited** registry with no `primary_domain`, a non-domain entry or a
non-list `domains:` is refused by name: `check --server` reports it
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
  deploy that died between `mkdir` and the compose sync leaves exactly this
  state, and refusing it would leave a hand-run `rm -rf` on the server as the
  only way out.

The plan and the outcome both go to **stdout**; only `warning:` and `error:`
lines go to stderr, so `kasbah drop > log` captures what was planned *and* what
happened. If anything is still wearing the project's compose label after
`down` — `docker compose` selects on `com.docker.compose.oneoff=False`, so an
operator's one-off container survives it — the outcome names it rather than
claiming the project came down.

**Double confirmation:** a yes/no question, then the project name typed back.
Either decline exits 1 having changed nothing but, possibly, kasbah's own binary.
`--yes` skips both, for scripts;
without a terminal an unanswered prompt is a hard fail naming `--yes`.

Takes `<project>/.deploy.lock` **in the act**, the same exclusive lock
the deploy engine holds (and, for the whole run, the server lock
`<apps>/.kasbah/server.lock` shared, so it never runs inside a `server init`
or `upgrade-traefik`), so nothing is removed while a deploy is running. The
batched read, the plan and both confirmations run **unlocked** — a read step
never writes into the tree it is reading — so a deploy starting while you answer
the second prompt makes the act refuse. That refusal reads as one: a run stopped
at a guard says it changed nothing, and only a run that got past them says some
of it may have run. The lock is the kernel's `flock(2)` on
`<project>/.deploy.lock`, the same one the deploy engine takes; no `flock`
binary is needed on the server.

Given without a `USER@HOST` it asks the server this project last talked to, and
`last_server` is recorded by a run that **acts** — the nothing-to-do path and a
completed act — not by one that reaches the server and then declines, meets a
held lock, or has `--prune` refused
(`project-manifest.md`).

Exits 4 on a host with no server marker; 1 on a decline, a held lock, or a
refused `--prune`.

### `kasbah history [USER@HOST] [--all]`

Tabular view of `versions.log`. Columns: timestamp, action, version,
backup file, kasbah version, and BY — the operator whose ssh user wrote the
line (`by=`; empty for lines written before it existed).

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

A changelog's two ends never land on a `deploy-failed` line; it says when it
stepped over one.

A `-dirty.` version has no git tag: `changelog` and the changelog a deploy or
rollback prints read it as its base tag and say so in a line — and skip the
changelog when that base is no tag here (`0.0.0`, or a tag whose `+metadata`
the label dropped). `pending` refuses a dirty `VERSION`.

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

### `kasbah env [USER@HOST] [--on-drift=setup|continue|abort] [--env-seed=FILE]`

Drift-aware env setup. Ships the kasbah binary if the server's is absent or
older, syncs `.env.prod.example` to `<apps>/<name>/`, runs the interactive setup
there over `ssh -t` (`kasbah remote setup-env`), then refreshes the kasbah-managed `KASBAH_*` block in `.env` from
the server marker's resource limits, or from `kasbah.yml`'s `resources:`
resolved on the server before the template ships (a value above the marker's
ceiling stops the run there, exit 1); the closing `limits:` line names the
source. See `env-template.md` for the template conventions and the managed
block.

The injection is not optional decoration: a `.env` without `KASBAH_CPU_LIMIT`
makes `compose up` fail outright, so a command whose job is producing a usable
`.env` finishes the job. That is also why it reads the server marker and exits
`4` when there is none, exactly as `deploy` does.

The setup is interactive and needs a terminal at both ends. Without one the run
stops with exit `5` rather than feeding the generator EOF, which its
non-interactive contract would turn into every default silently accepted,
secrets included — unless the setup would ask nothing: every key it asks is
answered by `--env-seed=`, or the template has no key at all. It then runs
without a terminal (plain `ssh`, no `-t`). When a key would still be asked,
the run stops with exit `5` naming the keys the seed lacks, before the seed
is sent.

`--env-seed=FILE` answers the setup from a file the operator writes and keeps
out of git (`env-template.md` → Seeding the setup): `KEY=value` lines, blank
lines and `#` comments, read as the setup reads a `.env`. Whenever the setup
would ask a key `.env` does not already set, the seed answers first — on a
missing `.env` that is every key, on drift the keys `.env` lacks — and a key
it does not cover is asked as usual. A key `.env` already sets is never
touched, and a `! command` key it answers never runs its generator. Drift
made only of keys `.env` lacks, all of them in the seed, is filled without the
drift question (an explicit `--on-drift=continue` or `abort` still wins); any
other drift asks it as usual (or needs `--on-drift=`).
An `.env` already in sync is left alone: the setup does not run. The output
names the keys it answered and counts those it did not use; it never prints a
value. Refused on the workstation, before anything connects (exit `1`): a file
that is missing, not a regular file, open to group or others (any bit of
`0o077`), over 256 KiB, empty or with no key (comments only), with a value
over 64 KiB (named by key), with a line that is not `KEY=value` (named by line
number), or setting a `KASBAH_*` key (named by line number and key); no
refusal quotes a value. A value with a bare `$` (not `$$`, outside single
quotes) is warned of by line number and key, not refused: compose reads it as
a variable. Keys the template does not have are ignored. The file always
travels on stdin with its size and sha256, never on a command line. A setup
without a terminal reads it on its own stdin, and nothing is written to the
server but the `.env`; like every unattended server step, it ignores a
dropped session and finishes. A setup over `ssh -t` cannot read it there —
its stdin is the operator's terminal — so a `kasbah remote setup-env seed` step first stages
it as `<apps>/<name>/.kasbah-env-seed.<token>`, mode `600` (`files.md`), the
token random and fresh each run; the setup reads the file its token names
and removes it before anything else. A workstation stopped between the two
steps leaves the file there; the first call of the next env step for that
project removes every staged seed, as does `server destroy`. `deploy`,
`deploy X.Y.Z` and `rollback` take the same flag for the same step.

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
a terminal (exit `5`) — or, for a missing `.env`, a seed answering every key;
only the drift case has a question for it to answer.

`deploy` carries the same flag for the same step (`build-deploy.md` step 6) —
the difference is that `deploy` runs the setup only when the `.env` is missing
or has drifted, while `env` runs it every time, since that is what it is for.

### `kasbah env set KEY [USER@HOST] [--restart|--no-restart]`

Changes one key of the project's server `.env` — a rotated API key, a new
password — without re-running the whole setup. KEY must be a key of the
server's `.env.prod.example`; `KASBAH_*` keys are kasbah's and refused. On a
terminal the value is asked with echo off; without one it is read from stdin
(one value, its trailing newline dropped; empty, multi-line or over 64 KiB is
refused), so it never reaches argv or shell history, and no output names it.

The value is taken exactly as typed or piped and written in the form compose
reads back exactly (`env-template.md`); its size and sha256 travel on stdin with
it, never on a command line. Every assignment of KEY is replaced (`export KEY=`
becomes `KEY=`), a key not yet in `.env` is placed beside its template
neighbours, every other line is kept byte for byte, mode `660`. A line compose
would read as KEY but kasbah cannot rewrite (`KEY =v`, `KEY: v`, invalid UTF-8)
and a key inside the `KASBAH_*` managed block are refused, naming the line. `--restart` then runs `docker compose -p <name> up -d`, which
recreates what reads the key; `--no-restart` leaves the containers on the old
value. Unset means ask; without a terminal and without either, the run fails
naming both. The set holds `.deploy.lock` and the server lock shared (both never
waited on), so it never lands inside a deploy whose revert would put the old
`.env` back. Every `.env` writer takes `.deploy.lock` — `kasbah env`'s setup for
its whole interactive session, the managed-block refresh, `env set` — and a
refusal names the holder. No `versions.log` line is written.

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

### `kasbah self-update [vN | vN.M | vN.M.P] [--pre] [--yes] [--from DIR]`

Installs a released kasbah beside this one and repoints `~/.local/bin/kasbah`
(`KASBAH_BIN_DIR`): to the version the argument resolved to, or with no
argument to the newest installed version that runs. No argument
means the newest release of this kasbah's major; `vN` the newest of that
major; `vN.M` the newest of N.M; `vN.M.P` exactly that one. Pre-release tags
(`-rc.N`) are skipped unless `--pre` or named exactly. Versions resolve the way
`install-dev.sh` resolves local tags (`internal/version` `Pick`).

Versions come from the repository's published releases — `GET
/repos/adigourdi/kasbah/releases`, 100 a page, at most 50 pages — so drafts and
tags without a release do not count; a pre-release is a version with a
pre-release part, whatever the API's flag says. The API base is
`https://api.github.com` (`KASBAH_RELEASES_API`). A token is optional:
`GITHUB_TOKEN`, else `gh auth token --hostname github.com` when gh is on PATH
and the API is GitHub's, else none. A private repository needs one; a public
one only gets a higher rate limit. The token goes to the API host only — never
on the redirect to the storage host, never to an asset URL outside the API.
Refusals name their way out, all exit 1: an anonymous 404 (the repository may
be private: set `GITHUB_TOKEN` or `gh auth login`), a 404 with a token (no such
release, or the token cannot see the repository), a used-up rate limit (until
when), a `Retry-After` (the wait), a plain 429 (retry later). A token the API
answers 401 is dropped with one warning naming its source, and the request
retried without it — a stale `GITHUB_TOKEN` never blocks a public repository.
A refusal or network error after the redirect names the storage URL without
its query: a signed URL's query is its credential.

`--from DIR` verifies from local files instead of the API: DIR holds the
release's `checksums.txt` and `checksums.txt.minisig` (what `get.sh` downloaded),
the version is named exactly, and it is this binary's own release stamp, run
from outside any library (the self-install below). Nothing is fetched; anything
else is refused before a byte is read.

Trust runs in this order, and nothing lands under `~/.local/share/kasbah`
before it holds: `checksums.txt` and `checksums.txt.minisig` are fetched (or
read from `--from`'s DIR) and the signature verified against the key compiled into the binary
(`release.pub`, minisign's prehashed form: Blake2b-512, then ed25519, key id
and trusted comment checked) before a single checksum line is read; the asset
for this machine (`kasbah_<ver>_linux_<arch>`) is streamed to
`<lib>/<ver>/..kasbah.new.part`, its size and sha256 compared to the verified
entry, then renamed to `<lib>/<ver>/kasbah` and copied beside as
`server/kasbah-linux-<arch>` (the same bytes serve both roles). On a Mac the asset
is `kasbah_<ver>_darwin_<arch>`, and both `kasbah_<ver>_linux_amd64` and
`_arm64` are installed beside it as the server builds — downloaded, or read from
`--from`'s DIR — each checked against its signed entry; the new binary
must answer `--version` with its own version. A release binary run from
outside any version directory and outside a checkout — an asset just
downloaded, as `get.sh` runs it — asked for its own version installs itself:
after the signature, its own bytes are read once, their size and sha256
compared to the signed entry for `kasbah_<ver>_linux_<arch>`, and those same
bytes installed; nothing is downloaded, and bytes that do not match are
refused. The symlink then moves — to the version resolved when one was
named (`vN`, `vN.M` or `vN.M.P`), else to the newest installed that runs — through
`<bin>/.kasbah.new` and a rename; when that is a different major from the one
it points at now the command asks first (`--yes`; no TTY → hard fail naming the
flag). A version already installed and answering for itself downloads nothing,
is reported as already installed, still gets the repoint, and exits 0. A checkout
(`dist/kasbah`, with `go.mod` and `cmd/kasbah/` two levels up) refuses: build
it and run `./install-dev.sh`. A library directory that is not kasbah's (not
empty, and no directory in it named as a version) is refused before anything
is fetched.

The other architecture's server build is not installed up front. An installed
*release* kasbah that meets a server of an arch it holds no build for fetches
exactly that asset the same verified way, into `<lib>/<ver>/server/`, before
shipping it; a dev build or a checkout never fetches.

## Hand-off between installed versions

Every release installed stays, under `~/.local/share/kasbah/<version>/` (the
binary and its two linux server builds), beside at most one dev build — each
`install-dev.sh` from a checkout replaces the previous one (`install-dev.sh
vN[.M[.P]]` builds and installs a release tag instead) — and
`~/.local/bin/kasbah` is a symlink to the newest installed version that runs, or
to the one a version argument named. A running kasbah hands off to a sibling version — re-executing
`<lib>/<version>/kasbah` with the same arguments and environment, before any
side effect — in three cases:

- **A server holds a newer build** of its major. The same-build rule refuses
  to talk to it; when that build is installed, the refusal becomes a hand-off
  to it. The message names both builds; when the version is not installed it
  names the remedy: `kasbah self-update vN.M.P` when the wanted build is a
  release; when it is a dev build from another checkout, the commit to build
  (`+g<sha>`) — or ship a release, which replaces any dev build of its major.
- **The operator keeps the server's release** over this dev build
  (`--keep-server`, below): when that release is installed, it runs the
  command; otherwise the run stops naming `kasbah self-update vN.M.P`.
- **A manifest's `schema` belongs to a newer major**: the newest installed
  kasbah of that major runs the command.

**A dev build asks before it replaces a release.** When the workstation runs a
dev build and the server a release (an `-rc.N` included) that the dev build
would replace, every command that reaches the server asks first: ship the dev
build, or keep the server's release. `--ship-dev` / `--keep-server` answer it
on any such command (both together are refused; they are taken out of the
arguments before a hand-off, so an older release never sees them, and the
answer travels as `KASBAH_SHIP_DEV=ship|keep`, honoured only beside
`KASBAH_HANDOFF`); without a terminal and without either, the run fails naming
both. The server's install re-checks under its lock: a release another
operator installed since the probe is kept, and the workstation asks about it
once more; a further release landing during that second install is where the
run goes — handed off to when installed, else the run stops. A dev build on the
server is a test target and is replaced by any newer build without asking, and
a release replaces a dev build, or an older release, without asking. Every
change of the server's binary prints `server kasbah OLD → NEW` (`(none)` on a
first install, `(unknown)` when the old binary could not say).

One hop only: the exec'd binary carries `KASBAH_HANDOFF=<build it came from>`,
and a second refusal is final. A kasbah run from a checkout (`dist/kasbah`)
never hands off; it says so and names the version to build. The library root
is the running binary's own parent directory when it sits in a version
directory, else `KASBAH_LIB_DIR`, `$XDG_DATA_HOME/kasbah`, `~/.local/share/kasbah`.

### `kasbah migrate server USER@HOST [--yes] [--undo]`

Moves a server's kasbah-owned files from the major its marker records to this
kasbah's. It is the one command that ships its binary onto a server whose
marker is an older major (every other command refuses that server and names
this one); the same-build rule still applies, so a newer server build is
refused or handed off as elsewhere. It prints the plan — the steps from the
marker's major up to ours, the files each rewrites, the snapshot path, the
locks — and asks *Migrate? Every kasbah workstation older than N.x will be
refused by this server afterwards.* (`--yes`; without a TTY the unanswered
prompt is a hard fail naming the flag). A server already at this major does
nothing and exits 0.

On the server (`kasbah remote migrate`, outliving a dropped session): the
migration lock `<apps>/.kasbah/migrate.lock`, the server lock
`<apps>/.kasbah/server.lock` (exclusive) and every project's
`.deploy.lock` are taken without waiting (a held one refuses, naming the
project); every file the steps declare, plus the marker, is written into
`<apps>/.kasbah/migrate/<from>-to-<to>-<stamp>.tar` before anything is
rewritten — unless one for this step already exists while the marker still
says `<from>`: that one holds the originals (a run that died halfway, or an
undone run), so it is kept and reused — a step that rewrites files under
`traefik/` or `mail/` must therefore compare the tree to the tarball before
reusing it, which none does yet; files are rewritten one by one, temp + rename, each skipped when
its own stamp already says `<to>`, so a run that died halfway finishes on the
next; the marker moves last (merged — keys it does not own survive). Steps are
compiled into the binary, one per major, and the newest binary carries them
all. Today the chain holds one, `0→1`, which rewrites nothing: 0.x server
state is 1.x state.

`--undo` restores the newest snapshot that ends at the marker's current major — files and marker, the marker as it was
snapshotted, so a key written after the migration (a later `server init
--with-backup`) is lost with it — after the same prompt, and refuses when any
project's `versions.log` has an entry newer than the snapshot: the server has
moved on, and the tarball is the manual path. An entry in the same second as
the snapshot does not count as newer.

Exit codes: 3 unreachable, 4 no marker, 1 refused.

### `kasbah migrate`

In a project: moves `kasbah.yml` and the tree files kasbah writes from their
schema to this kasbah's, bumps `kasbah_version`, and appends `<from>-><to>`
to `.kasbah/state.json`'s `schema_migrations_applied`. Schema 1 is the first,
so today there is no step and a schema-1 project answers *nothing to migrate*
(exit 0). A manifest of a newer major hands off to that kasbah when it is
installed (Hand-off, above). Project and server migrations are independent and
run in either order; `deploy` needs both at this kasbah's schema.

## Deferred commands

Nothing — every command the docs name exists.

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
  unrenderable with no terminal to render it on (or with keys `--env-seed=`
  does not answer), **and** the setup not finishing on the far side —
  including when it could not be run at all. One code rather than several,
  because the operator's next move is the same in every case: run
  `kasbah env` from a terminal, or pass `--on-drift=` or `--env-seed=`.
- `6` compliance check failed
- `128+N` kasbah was stopped by signal N — `130` for Ctrl-C, `143` for
  `SIGTERM`, `129` for `SIGHUP`. Its own temp files and ssh connection are
  cleaned up first; a step already running on the server finishes there.

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
