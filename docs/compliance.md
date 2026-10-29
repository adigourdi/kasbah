# Compliance Check — `kasbah check`

Runs a set of structural/conventional checks against the current project so
the user knows it will behave sensibly when hosted. Runs locally (no SSH)
unless `--server USER@HOST` is given, which adds the VPS-aware rules below.

```
$ cd ~/projects/myapp
$ kasbah check
Checking /home/you/projects/myapp

Structure:
  ✓ kasbah.yml exists (schema 1)
  ✓ compose.prod.yml exists
  ✓ .env.prod.example exists
  ✓ .gitignore excludes .env

Compose:
  ✓ All services set restart policy
  ✓ All services set json-file logging with rotation
  ✓ All routed services join the project's kasbah network
  ✓ The kasbah network is the project's own (my-app_kasbah)
  ✓ No internal services on the kasbah network or kasbah-net
  ✓ Names on the kasbah network are project-prefixed
  ✓ No `version:` field (deprecated)
  ✓ All built services reference their image as :current

Resources:
  ✓ All services set cpus/mem_limit via KASBAH_* vars
  ✓ No resource reservations

Traefik:
  ✓ traefik-dynamic.yml exists
  ✓ At least one router references manifest domain (myapp.example.com)
  ✓ Routers declare entrypoints (web or websecure)
  ✓ Secure routers reference letsencrypt
  ✓ A router serves the domain on the web entrypoint

Healthchecks:
  ⚠ Service 'worker' has no HEALTHCHECK (warning only)

Env:
  ✓ .env.prod.example keys are syntactically valid
  ✓ .env (if present) matches .env.prod.example keys

Hooks:
  ✓ Every hook references a container defined in compose
  ✓ Backup hook: check + command + extension all set

Mail (if manifest has `mail:`):
  ✓ Mail claim names domain 'shop.example.com'
    (M03 — the stack on the VPS knows this domain — only runs with --server)

Summary: 21 passed, 1 warning, 0 failed
```

Exit code 0 if no failures (warnings are informational).

The verdicts do not depend on the locale: names and URL schemes are ASCII
everywhere, values are measured in UTF-8 characters, and lists (missing keys,
hosts) are in byte order.

## Rule catalog

### Structure

| ID | Rule | Level |
|---|---|---|
| S01 | `kasbah.yml` exists | fail |
| S02 | `kasbah.yml` has valid schema version | fail |
| S03 | `compose.prod.yml` exists | fail |
| S04 | `.env.prod.example` exists | fail |
| S05 | `.gitignore` excludes `.env` | warn |
| S06 | `.gitignore` excludes `.kasbah/` | warn |
| S07 | `name` is not one of kasbah's reserved directories (`traefik`, `mail`, `data`, `backups`) — see `project-manifest.md`. `mail` is reserved for the same reason `traefik` is: `<apps>/mail` holds the shared mail stack, and a project deployed there would `compose up -d --remove-orphans` it away. Refused when the manifest loads, so it exits 1 rather than 6: nothing else can be checked about a project that would overwrite the reverse proxy | fail |
| S08 | `client` is a repository name — `^[a-z][a-z0-9-]*$`, and not one of kasbah's reserved directories (`traefik`, `mail`, `data`, `backups`). It names the restic repository this project's snapshots file into (`backup.md`), so a project claiming `mail` would put every mailbox on the host into one client's handover. Same rule as S07's and in the same function, and `deploy` refuses the identical value — **checked here so a project learns it from `kasbah check` and not from the deploy that stopped before shipping**, which is the rule `name` has always followed. Absent is legal and means `name` | fail |

### Compose

| ID | Rule | Level | Auto-fixable |
|---|---|---|---|
| C01 | Every service sets `restart: unless-stopped` (or stronger) | fail | yes |
| C02 | Every service has `logging.driver: json-file` with `max-size` + `max-file`, each a non-empty string or a number | fail | yes |
| C03 | Every Traefik-routed service (targeted by a fragment `loadBalancer` URL) joins the project's `kasbah` network — or the legacy shared `kasbah-net`, which warns: every project's routed containers reach each other there (`traefik.md` → Network) | fail / warn | yes (adds the `kasbah` network where neither is joined) |
| C04 | The `kasbah` network is declared as exactly `kasbah: {}` (or empty) — compose names it `<project>_kasbah`, the network deploy attaches Traefik to, and any setting (`driver`, `labels`, `name`, `external`, …) would make compose try to recreate it under Traefik and fail every later deploy. No `external` network but the legacy `kasbah-net` (itself `external: true`): joining `mail_kasbah` or another project's network is refused, naming the network | fail | yes (adds a missing `kasbah: {}` only) |
| C05 | No deprecated `version:` top-level field | warn | yes |
| C06 | Every service has `container_name` OR project uses compose's default naming | info | no |
| C07 | No non-routed service joins the `kasbah` network or `kasbah-net` — internal services use a project-internal network (Traefik joins the `kasbah` network, and service-name aliases on a shared network round-robin across projects) | fail | no |
| C08 | Every service with a `build:` key names an `image:` tagged `:current`. Deploy moves `<image>:current` and never rewrites compose, so a service pinned to `:1.2.3` keeps running the old image while the deploy reports success and changes nothing — the quietest failure in the tool. Silent on projects that build nothing | fail | yes |
| C09 | On the project's `kasbah` network, every service name, every `networks.kasbah.aliases` entry and every `container_name` is `<manifest.name>` or `<manifest.name>-*` — **fail**. Traefik is on every project's network and resolves names across all of them, so a service named, or aliased, like another project's container answers for it: Traefik would send that project's traffic here (measured: 3 of 3 lookups). A prefix shared by two names (`shop` and `shop-admin`) is not caught. On the legacy `kasbah-net` the same naming is a warning, as compose registers service names as aliases there and two projects' `web` round-robin; silent on a project with nothing on `kasbah-net` | fail / warn | no |
| C10 | Neither `compose.prod.yml` nor `.env.prod.example` names `mail-dms` outside a `#` comment line: no project shares a network with the mail server, so an app sends through `mail.<domain>:587` with a mailbox login (`mail.md` → SMTP access from apps). Silent when neither does | warn | no |

### Resources

Hard limits only — reservations are banned. Every service sets both limits — as
`cpus`/`mem_limit` or as compose's `deploy.resources.limits` —
either to the kasbah-managed env vars (`KASBAH_CPU_LIMIT`, `KASBAH_MEM_LIMIT` —
90% of host cores/RAM, computed at `server init`, injected into the project's
`.env` at deploy — see `server-setup.md`), which scale with the host, or to a
literal of the project's choosing (`cpus: "0.5"`, `mem_limit: 512m`) — a
database given 2g and a web process 512m. A literal cannot be compared with a
host locally, so plain `check` warns on it and `check --server` (R04) holds it
to the server's ceiling. A per-container limit never stops two containers
hogging the host together; a per-project ceiling (a cgroup slice) is not done.

| ID | Rule | Level | Auto-fixable |
|---|---|---|---|
| R01 | Every service sets `cpus:` (or `deploy.resources.limits.cpus`) to `${KASBAH_CPU_LIMIT}` or a number above 0 — missing, malformed, or the two forms set to different values fails; a literal warns locally | fail/warn | yes (missing or malformed top-level only) |
| R02 | Every service sets `mem_limit:` (or `deploy.resources.limits.memory`) to `${KASBAH_MEM_LIMIT}` or a size Docker accepts — bytes or a decimal with `k`/`m`/`g`/`t`/`p`, an optional `b` or `ib`, any case, one optional space — of at least Docker's `6m` minimum and within int64 (a string under `deploy.resources.limits`, as compose requires); missing, malformed, or the two forms set to different values (compared as sizes) fails; a literal warns locally | fail/warn | yes (missing or malformed top-level only) |
| R03 | No service declares resource `reservations` | fail | yes |
| R04 | (`--server`) Effective limit vs host size — the server `.env`'s values for services on the variables, each literal for the others: above 90% fails; below 90% warns (deliberately tighter is allowed, but flagged) | fail/warn | no |

### Traefik

Rules parse `traefik-dynamic.yml` at the project root. `compose.prod.yml`
is also scanned: any `traefik.*` label is a hard fail (T06), since the
docker provider is not wired in.

| ID | Rule | Level |
|---|---|---|
| T01 | `traefik-dynamic.yml` exists and parses as one YAML document whose `http.routers` is a mapping; otherwise T02–T05, T08 and T09 are skipped, and so are C03 and C07, which need the services it routes | warn |
| T02 | At least one router's `rule` references `manifest.domain` | fail |
| T03 | Every router declares `entryPoints` (non-empty list) | fail |
| T04 | Routers on `websecure` reference `tls.certResolver: letsencrypt` | fail |
| T05 | Project fragment's routers don't claim reserved hostnames (`traefik.<domain>`, `mail.<domain>`, `webmail.<domain>`) — those belong to kasbah-owned `_`-prefixed fragments. Locally a heuristic: any `Host(\`…\`)` whose first DNS label is `traefik`, `mail`, or `webmail` fails, because the server apex is not knowable from a checkout. Under `--server` it is the exact match instead: `traefik.<apex>` from the dashboard router in `<apps>/traefik/dynamic/_shared.yml` — nothing at all when the server has no dashboard (`--no-dashboard`), though a later `--with-dashboard` would then collide with a project holding that name — and `mail.`/`webmail.` of the mail registry's `primary_domain` (falling back to the apex when there is no registry, since `server init --with-mail` would claim exactly those). That tightens the case the rule exists for and lets go of a hostname on somebody else's apex, which the strict rule never reserved. The two families answer separately, because they have two sources: `traefik.` comes from the dashboard fragment and `mail.`/`webmail.` from the registry, so either can be unreadable alone. A family whose source was read matches exactly; a family whose source was not **keeps the local heuristic** — never neither, which would let an unreadable `_shared.yml` on a mail-enabled server turn a dashboard-hostname claim into a silent pass. With no registry the mail pair is taken exactly from the apex, since that is what `server init --with-mail` would claim. | fail |
| T06 | No service in `compose.prod.yml` carries `traefik.*` labels | fail |
| T07 | Every fragment `loadBalancer` server URL hostname matches an explicit `container_name` in `compose.prod.yml` | fail |
| T08 | Some router whose `rule` references `manifest.domain` declares the `web` entrypoint. The minimum viable form (`traefik.md` → Project fragment) is two routers for one hostname, the `websecure` one that serves it and a `web` one that redirects; T03 asks only that a router declare *some* entrypoint, so a fragment carrying the HTTPS half alone passes every other rule and answers plain HTTP with Traefik's 404. Warn, not fail: HTTPS-only is legitimate for an API nothing browses to, and the rule cannot tell that apart from the omission. Domain matching is T02's substring test | warn |
| T09 | No project router's `service`, no `http.services` entry's `mirroring.service`, `mirroring.mirrors[].name`, `weighted.services[].name`, `highestRandomWeight.services[].name`, `failover.service` or `failover.fallback`, and no `errors` middleware's `service`, is a Traefik `@internal` service other than `noop@internal` — each reference reported once, routers first, then services, then middlewares. `api@internal`, `dashboard@internal`, `rest@internal` and `ping@internal` would publish Traefik's own API with no auth, which `server init --no-dashboard` cannot stop; `noop@internal` is the redirect router's placeholder. Same locally and under `--server` | fail |

### Healthchecks

| ID | Rule | Level |
|---|---|---|
| H01 | Each custom-built service declares a `healthcheck:` in compose. Warn-only and never a failure, because kasbah cannot see a `HEALTHCHECK` in the service's Dockerfile — which is the better place for one, since it travels inside the image. A project whose built services are healthchecked in their Dockerfiles warns here forever, correctly | warn |
| H02 | Manifest `health.container` exists among services | fail |

### Env

| ID | Rule | Level |
|---|---|---|
| E01 | `.env.prod.example` lines follow template syntax | fail |
| E02 | `.env` (if present) has no missing keys vs `.env.prod.example` | warn |
| E03 | `.env` (if present) has no extra keys vs `.env.prod.example` | warn |
| E04 | No obvious secret leaked into `.env.prod.example` (e.g. lines longer than 64 chars that aren't `!` commands) | warn |
| E05 | `.env.prod.example` declares no reserved `KASBAH_*` key — kasbah injects those, so a template line naming one is a knob that does nothing | warn |

A template that declares nothing is a first-class state, not a gap. S04 keeps
requiring the file, and a comment-only one passes E01, E04 and E05 because
`env_extract_keys` yields no keys from comments — which is exactly what
`init-project` scaffolds, since the hostname is load-bearing in the manifest's
`domain:` and in the fragment rather than here.

Keys prefixed `KASBAH_` are reserved — injected and refreshed by kasbah
at deploy (resource limits) and exempt from E02/E03 and drift detection.
The bare name `KASBAH_` counts as reserved: Compose reads `KASBAH_=x` as
setting a variable, so it is inside the namespace the frozen contract claims.

E02/E03 are not implemented here. They call the env engine's drift report
(`internal/env`) — the same code that runs on the VPS as
`kasbah remote setup-env drift` during a deploy, so the local check and the remote
one cannot drift apart by agreeing to differ. `--server` runs that same
function over the VPS's own `.env`, which comes back as bytes and is handed
to it through a process substitution: the file holds the project's secrets,
so it is never written to disk on the workstation, and only key *names* are
ever printed.

### Hooks

| ID | Rule | Level |
|---|---|---|
| HK01 | `hooks:` holds only the four lists deploy runs, and every hook's first word is an explicit `container_name:` from compose.prod.yml (compose's auto-generated `<project>_<svc>_1` won't match) | fail |
| HK02 | Backup hook has all required subfields (`check`, `command`, `extension`) | fail |
| HK03 | Backup hook's container exists among services | fail |

### Mail (M01–M03 only if `mail:` present in manifest)

| ID | Rule | Level |
|---|---|---|
| M01 | `domain` set | fail |
| M02 | *Retired, id not reused.* It validated `snappymail_domain`, a SnappyMail seed file that the manifest no longer has | — |
| M03 | (with `--server` flag) Mail stack on VPS knows this domain | fail |
| M04 | (with `--server` flag, any project, silent on a server without mail) Every domain in the mail registry has both DKIM keys, listed in the signing override | warn |

### Backup (only with `--server`, and only on a server that has backups)

| ID | Rule | Level |
|---|---|---|
| B01 | The VPS's backup stack has run, and its last run worked. **Silent** on a server whose marker records no backup — `--no-backup` is a documented answer, not a defect, and this is a project linter. Otherwise it reads `<apps>/.kasbah/backup/state/status`, the record the scheduler writes, through the same parser `kasbah server status` uses. **Fails** on three states: the last run reported failure, the recorded state has outlived its own deadline, and the scheduler container is not running — a stopped container is an observation rather than an absence, and it is asked first, because the record is only current while something is maintaining it. **Warns** on every way the record can decline to answer or fall short, each with its own message: the stack directory is gone, the record is absent (the scheduler writes it as its first act, so absence means it has never fired), it cannot be read by the ssh user, it is not a record this kasbah understands, no run has finished yet, a repository has an **orphan password** — a password file whose project was dropped, which kasbah reports and never deletes — a repository has **no password** and so is not being backed up at all, and a run that succeeded and **shipped nothing** — `repositories: none` is a green tick for a server where no data left the box. Those seven are warnings for the same reason the `acme.json` states are: "cannot be checked" is not "is broken", and they have different remedies. Timestamps are judged against the **server's** clock, collected in the same round trip, because a verdict computed against the workstation's would be a function of clock skew | fail/warn |

## `--fix` behavior

Only auto-fixable rules get applied. Never modifies `.env`. Never modifies
hook commands. Only edits `compose.prod.yml` and `kasbah.yml` (with a
diff shown before writing).

Fixable today:
- C01, C02, C03, C04, C05, C08 (compose hygiene — C03/C04 put a routed service
  that joins neither network on a `kasbah` network and declare `kasbah: {}`,
  leaving a project already on the legacy `kasbah-net` as it is, warned; C08 is
  a mechanical tag rewrite, refused for an image pinned by digest, which has no
  tag to move)
- R01, R02, R03 (insert the `KASBAH_*` var references where a limit is missing,
  replace a malformed top-level one; a valid literal is left alone, and a
  `deploy.resources.limits` limit is the author's to fix — no top-level key is
  ever added beside one, which compose would refuse)
- Adding `kasbah_version` to manifest if missing

Unfixable (must be done by hand):
- C07 (moving services between networks is topology — kasbah won't guess)
- C09 (renaming a service drags `depends_on`, profiles and every in-project
  hostname with it — same reason)
- Anything under Traefik (routing is policy, kasbah can't guess)
- Hooks (kasbah can't invent commands)
- Mail claims

### How it edits

**Targeted text edits, never a YAML round-trip.** A round-trip reorders keys and drops
comments, and compose files carry load-bearing ones — this repo's own do. So
everything not being changed comes back byte for byte: comments, blank lines,
key order, quoting, hand-spacing, CRLF line endings, and a missing final
newline.

**The parsed document decides what is true; the line scanner only finds where
it is written.** Every verdict and every insert-versus-replace decision comes
from the parsed tree (as `internal/yamlx` reads it — yaml.v3's reading; a
file it refuses, such as one with a `%YAML 1.2` directive, `.inf`/`.nan`, an
alias cycle or aliases expanding past 1000× its written size, does not
parse). If the scanner then cannot locate that key in the text — a quoted key,
a flow mapping, an inline value — the fix is **refused and named**, never
guessed. That split is what keeps a pattern-matcher from deciding semantics.

Where a new service-level key lands: the last *content* line of the service
block, stepping over blank lines and trailing comments, so an inserted key
appears above someone's `# TODO` rather than below it. **A `|` or `>` block
scalar is the exception, and it has to be**: inside one, `#` lines and blank
lines are the *value*, not commentary. The scanner skips such a region whole —
it runs from the header to the first non-blank line at or above the key's own
indent, which is YAML's rule — so an insertion cannot be spliced into the middle
of somebody's shell script. A header is any line whose value ends in a `|` or
`>` indicator — after `key:`, after one or more `- ` sequence dashes, and behind
anchors and tags (`- |`, `entrypoint: &ep |`, `test: !!str >-`); the region is
measured from the key's column or the last dash's. Under `|+`/`>+` the trailing blank lines are kept by
the scalar and belong to the region; under the default chomping YAML discards
them, so they stay outside it and the insertion goes above. The indent comes from
the block's own first child, and a deeper level uses the file's own step — a
4-space file gets 4-space nesting. When several insertions share an anchor (a
service's last line is also its last sub-block's last line) they are emitted
**deepest-indent first**: the other order puts `restart:` inside
`logging.options`, which is valid YAML and the wrong meaning.

Before anything is written, the staged candidate must parse, must declare the
same services and the same top-level keys (only `version:` may leave, only
`networks:` may appear), must **parse to exactly the original tree with the
planned edits applied** — so an insertion that landed inside a value, or moved
one, is caught whatever the scanner believed — and must **re-plan to an empty
plan** — idempotency proved at runtime rather than assumed. An edit that would
go through an alias is refused. Any failure removes the candidate and writes
nothing.

**A comment immediately above a removed key is left.** It cannot be told from a
file header, and a compose file that opens with prose and then `version:` is the
ordinary shape.

### Refusals, each reported rather than skipped

- A `compose.prod.yml` that does not parse, or holds several YAML documents
  where kasbah reads one — refused, not pattern-matched.
- **C08** on a built service naming no `image:` at all. It is a tag rewrite;
  kasbah will not invent an image name.
- **C04** under the banned default-alias shape, where declaring the default
  network external would entrench precisely what C07 is failing on.
- Any key written in a shape the scanner cannot take apart — including a quoted
  scalar with no closing quote on its line (a multi-line quoted value), where
  the value and a trailing comment cannot be told apart.

One edge worth stating: a `compose.prod.yml` that is a **symlink** is written
*through* — the link survives and its target is updated. Still only those two
filenames are ever edited; where the bytes actually live is the project's
choice, and replacing an operator's symlink with a regular file would be the
more surprising of the two behaviours.

### Interaction

`--fix` plans, stages, prints a unified diff of every file it would touch, and
**then asks**. `--yes` answers; without a terminal and without `--yes` it is a
hard fail naming the flag; declining writes nothing and leaves no candidate.
`--yes` alone is refused, since it does nothing without `--fix`. The fix pass
runs **before** the report, so the lines printed and the exit code returned
describe the project as it now is.

## `kasbah check --server USER@HOST`

Extended check that also queries the VPS. Everything in the local run still
runs; these are added, and T05 tightens (above).

| Asked | Level |
|---|---|
| Does the project dir exist on VPS? | warn if absent — a project that has not been deployed yet is the ordinary state a pre-deploy check runs in; **fail** if the path is there and is not a directory. Every rule below that needs the tree is then skipped rather than answered about a tree that is not there |
| Does `.env` on VPS match the current `.env.prod.example`? | warn — E02/E03 against the server's real file, and against *this checkout's* template rather than the copy the last deploy shipped |
| Is the claimed mail domain known to the mail stack? (M03) | fail — the registry `<apps>/mail/kasbah.yml` is the only thing asked, read one key at a time. A registry that cannot be parsed warns instead: "cannot be checked" is not "not served". This is where `deploy`'s warning has a level; deploy keeps warning, because an unmet claim costs mail rather than the site |
| Is the manifest's `health.container` currently healthy (if deployed)? | fail when the container reports `unhealthy` — Traefik keeps routing to it. Warn when it is starting, has no healthcheck, or is not running at all |
| Cert status for the project's `domain` in Traefik's `acme.json` | fail when the certificate has expired; warn inside Traefik's 30-day renewal window, and warn for every way the store can decline to answer, each with its own message (absent, empty, unreadable, not a regular file, no entry for this domain, not JSON, a resolver key that is not `letsencrypt`, a `Certificates` that is not a list, an entry with no `certificate`, one that is not base64, one openssl will not read) — they have different remedies, so collapsing them into "no certificate" throws away the only thing that says what to do next |
| Effective resource limits vs host size (R04) | above the marker's ceiling fails, below warns |
| Is the apps tree the operators' group's? | warn when the server has no `kasbah` group, and for every entry under the resolved apps path that an operator owns (`<data>/`'s contents, entries no operator owns and directories with no group bits aside) that is not the group's or lacks the bits another operator's write needs — setgid and group `rwx` on a directory, group read-write on a file kasbah rewrites in place (`.env`, `versions.log`, the locks, the marker), group `rwx` on the shared binary; counted exactly, the first twenty named. `kasbah server init` converges it (`server-setup.md` → Operators) |
| Is every mail domain DKIM-signed? (M04) | warn for each domain in `<apps>/mail/kasbah.yml` that lacks either key Rspamd signs with — `rsa-2048-mail-<d>.private.txt` and `ed25519-ed-<d>.private.txt` in `<data>/mail/dms/config/rspamd/dkim/`, names listed, keys never read — or whose paths the signing override `override.d/dkim_signing.conf` does not list (a domain added after init whose block was never added), naming the keygen commands and the block to add; warn "cannot be checked" for a registry that is unreadable or refused, a key directory that cannot be listed, or an override that cannot be read; silent on a server with no mail registry; runs whether or not the project has `mail:`. Unsigned mail is what lands in spam. A path commented out with `//` or `/* */` rather than `#` still counts as listed |
| Has the backup stack run, and did the last run work? (B01) | fail when the last run failed, when the scheduler's state has outlived its deadline, or when its container is not running; warn for every way the record can decline to answer, for a repository with no password, for an orphan password left by a dropped project, and for a run that shipped nothing; silent on a server with no backups. The record is `<apps>/.kasbah/backup/state/status`, read through the one parser `server status` shares |

The effective limits are, for a service on the variables, `KASBAH_CPU_LIMIT` /
`KASBAH_MEM_LIMIT` in the VPS's own `<apps>/<name>/.env` — the values compose
interpolates — and for one with literals — top-level or `deploy.resources.limits` — the
literals themselves, compared even before the project has deployed (only the
marker is needed). The `.env` is asked only for the keys some service takes from it. The ceiling is the server marker's, which `server init` computed
as 90% of the host. Sizes are compared in bytes, so `55296m` and `54g` are the
same limit.

**`--server` writes nothing but kasbah's own binary**, which it brings up to date
first. It is a linter: the server binary reads the files and asks docker, and
everything is judged on the workstation. Two round trips: the bootstrap probe, which carries
the server marker back, then one batched read. The far side never needs `jq`, `yq`,
`python3` or `openssl`.

`acme.json` holds private key material — the resolver's account key and every
certificate's private key — so nothing that reads it writes it to a temp file,
echoes it, or puts it in a diagnostic. A truncated report names the keys that
arrived and does not quote the payload. And expiry is reported, never age:
Let's Encrypt backdates `notBefore` by ~58.5 minutes, so a certificate cannot
say when it was issued.

Given without a `USER@HOST`, `--server` asks the server this project last
talked to, and a run that reaches one records it as `last_server` in
`.kasbah/state.json` — the one thing `check` writes anywhere, and the same rule
every other server-targeting command follows (`project-manifest.md`).

Not run by default because it needs SSH and is slower. Useful as a
pre-deploy sanity check.

## Philosophy

The check is a linter, not a gatekeeper. `kasbah deploy` does not implicitly
run `kasbah check`. The user runs `kasbah check` when they want it. This
keeps deploys fast and avoids the "tests passing but something weird on
prod" feedback lag.
