# Traefik — Shared Reverse Proxy

One Traefik instance per VPS, managed by kasbah. Projects declare their
routing as file-provider fragments dropped into a shared dynamic directory.

## Why shared

Per-project Traefik has a real cost on a multi-project VPS:
- Port 80/443 can only be bound once — multiple Traefik instances are
  impossible anyway.
- Let's Encrypt rate-limits are per-certificate; sharing Traefik's
  `acme.json` avoids duplicate issuance when projects overlap on domains.
- Middlewares (HSTS, redirects, rate-limits) are identical in 90% of
  projects and shouldn't be duplicated.

## Why file provider (not docker labels)

Traefik's docker provider is the "obvious" default. It doesn't fit a
multi-project VPS:

- **Unhealthy containers disappear from routing.** The docker provider drops
  a container's routers the moment its healthcheck goes red. Users see
  Traefik's default 404 instead of the app's own error page, even when the
  container is up and perfectly capable of rendering one. Many apps serve
  a branded maintenance page from the same process — the docker provider
  takes that option away.
- **Redirect-only routes have no container to host the labels.** A pure
  www→apex or legacy-path redirect needs a router but no backend service.
  With labels you'd invent a dummy container just to carry the rule.
- **Routing is scattered across every project's compose file.** Grepping
  all current routes on a VPS means walking every `/apps/<project>/compose.yml`.

The file provider fixes all three:

- Routers are registered unconditionally. When a container is up but
  unhealthy, Traefik still forwards and the app owns the error surface.
  When the container is truly down, you get a 502 — customizable with an
  `errors` middleware to a static-error sidecar.
- Routers without services are native (redirect middlewares on a bare router).
- All routing lives under `/apps/traefik/dynamic/` — one directory to audit.

The docker provider is **not** wired in. Projects do not use `traefik.*`
labels; `kasbah check` rejects them.

## Ownership

The Traefik stack lives at `/apps/traefik/` on the VPS and is managed by
`kasbah server init / status`.

**`compose.yml`, `traefik.yml` and `_shared.yml` are kasbah's, and every
`server init` re-ships any of them whose bytes differ.** A hand edit to either is reverted on the next run, with
no backup — so treat them as generated files, not as configuration you own.
What survives a re-run is exactly the four values init reads back out of
them: the dashboard domain, the ACME email, the basic-auth hash, and the
Traefik image tag.

The image tag is the newest of the four and is there for one reason:
`kasbah server upgrade-traefik` changes it, and an init that re-rendered
kasbah's own pin over the top would revert a managed upgrade silently, on
a re-run nobody thought was risky. So the pin in `internal/serverinit/args.go`
(`TraefikImage`) is what a *first* init renders, and every later
one reproduces whatever the server's own `compose.yml` already names. Only
the official repository with a Docker tag on it is reproduced — a mirror,
a digest pin or anything else falls back to kasbah's pin with a warning,
because that value is substituted into a YAML scalar and into a `docker
run` argument.

**`upgrade-traefik` is the one command that backs these files up.** It
re-renders all three exactly as init does and copies the bytes that were
there to `<apps>/traefik/backups/<UTC timestamp>/` first. That copy is the
whole of the difference between the two commands: neither asks, because
neither is editing configuration you own.

Project fragments in `dynamic/<project>.yml` are a different matter — those
belong to their projects and init never touches them. Files you add under
`dynamic/` yourself survive too, provided they do not start with `_`, which
is kasbah's prefix. If you need to change what `traefik.yml` contains, the
change belongs in kasbah's template rather than on the server; otherwise
it lasts until the next init.

## Network

**Each project has its own network, and Traefik is the only thing on more than
one.** A project's compose file declares a network under the key `kasbah` — not
`external`, so the project still runs with plain `docker compose up` anywhere —
and puts its routed services on it, and everything else on a project-internal
network:

```yaml
# /apps/<project>/compose.yml
services:
  myapp-web:
    networks: [kasbah, internal]
  postgres:
    networks: [internal]

networks:
  kasbah: {}
  internal: {}
```

Compose names it `<project>_kasbah`. At every deploy and rollback, right after
`compose up`, kasbah attaches the running Traefik to it (`docker network
connect`, live — no restart, nothing changes in Traefik's compose file) before
the health wait; `drop` detaches it before `compose down`, which could not
remove a network a foreign container is still on. A compromised container
therefore reaches its own project and nothing else: no other project shares a
network with it. Traefik reaches everything, which is its job.

A recreated Traefik container keeps only the networks its compose file names,
so every Traefik start kasbah runs — `server init`, `upgrade-traefik` and its
restore, the mail stack's start — rejoins every network compose labels with the
key `kasbah` (`com.docker.compose.network=kasbah`) whose compose project is the
mail stack or has a directory under the apps path, so a compose project someone
runs by hand elsewhere on the host never gets Traefik attached. A Traefik recreated by hand
(`docker compose -p traefik up -d`) has lost them: every site answers 502 until
`server init` is re-run.

**`kasbah-net`** (a frozen name) is still created by the Traefik stack, and a
project still routed through it — `networks: [kasbah-net]`, `external: true` —
keeps working, with `kasbah check` warning that it should move to a `kasbah`
network. Projects on it see each other, as all projects did before.

Why not put the whole project on its network via `default:`? Compose registers
every service's **service name** as a DNS alias on each network it joins, and
Traefik — on every project network — resolves names across all of them: two
projects with a `postgres` both on the network Traefik shares would make the
name ambiguous from Traefik's side, and on the legacy shared network project A's
app could silently reach project B's database. Keeping internal services on a
project-internal network scopes those aliases. `kasbah check` enforces the split
(C03/C04/C07/C09).

The network is what lets Traefik resolve `http://<name>:<port>` in the file
fragment. On a project's `kasbah` network a fragment targets the routed
**service name** (or an alias, or a `container_name`, T07): Docker DNS answers
it with every replica, which is what lets a deploy roll a new container in
beside the old one with no 502 (`build-deploy.md`). A name is not unambiguous
on its own, though: Traefik resolves names across every network it is on, and
another project's service name or alias answers for the same name — so a project naming a service like
its neighbour's container would receive the neighbour's traffic. Every name on a
project's `kasbah` network must therefore carry the project's own prefix (C09,
a failure), and its network must be exactly `kasbah: {}` (C04): any setting
makes compose try to recreate it while Traefik is attached, which fails.

## Discovery

Traefik watches a directory of per-project fragments:

```yaml
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

`/etc/traefik/dynamic` inside the container is bind-mounted from
`/apps/traefik/dynamic/` on the host. Changes are picked up live — no
Traefik restart, no `compose up` on the project.

Kasbah-owned fragments (written by `kasbah server init`):
- `_shared.yml` — middlewares, TLS options, dashboard router.
- `_mail.yml` — four routers, only written when `--with-mail` is passed:
  `mail-cert` (`websecure`, `certResolver: http`, `noop@internal`) is
  the cert-trigger that makes DMS bootable at all; `webmail` (`websecure`,
  `security-headers`) proxies to `http://mail-cypht:80`; and
  `mail-cert-http` / `webmail-http` redirect on `web`. It defines no
  middlewares of its own — the frozen ones are `_shared.yml`'s. See `mail.md`.

  `https://mail.<domain>` answers **418**: that is what `noop@internal`
  returns when a router reaches it with no middleware in front, and nothing
  user-facing lives there. The `web` half is not what makes ACME work —
  Traefik answers the HTTP-01 challenge from its own `acme-http@internal`
  router on `:80` regardless of any fragment — it is only the redirect T08
  asks of every hostname.

Project fragments are named `<manifest.name>.yml`. Filenames starting
with `_` belong to kasbah and are re-shipped whenever their bytes differ —
`_shared.yml` by `server init` and by `server upgrade-traefik`, `_mail.yml`
by `server init --with-mail`. Don't author your own `_`-prefixed files.

## Project fragment

Each project ships `traefik-dynamic.yml` at its repo root. `kasbah deploy`
syncs it directly to `/apps/traefik/dynamic/<manifest.name>.yml` — no
intermediate copy, no entry in the manifest's `sync:` list. Kasbah
handles it out-of-band.
Traefik picks up the change on the next watch tick.

The filename `traefik-dynamic.yml` mirrors Traefik's own terminology
(static config vs dynamic config) — everything in this file is what
Traefik calls dynamic: routers, middlewares, services, TLS options.

Minimum viable HTTPS routing:

```yaml
# traefik-dynamic.yml
http:
  routers:
    myapp-http:
      rule: "Host(`myapp.example.com`)"
      entryPoints: [web]
      middlewares: ["http-to-https@file"]
      service: noop@internal   # redirect-only — no backend

    myapp:
      rule: "Host(`myapp.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
      middlewares: ["security-headers@file", "gzip-compression@file"]
      service: myapp

  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://myapp-web:80"
```

The service URL names the routed service on the project's `kasbah` network —
stable across restarts and rolling deploys, since compose registers the service
name as an alias for every replica. A `container_name` works too, but a service
pinned to one cannot roll: it is recreated in place, briefly unrouted. On the
legacy `kasbah-net` only a `container_name` will do (T07).

Both routers, not just the `websecure` one: without the `web` half the
hostname answers plain HTTP with Traefik's 404 rather than a redirect, which
`kasbah check` warns about (T08). A plain-HTTP project keeps the `web` router
alone, serving the app instead of redirecting (TLS below).

### Redirect-only router

A www→apex redirect with no backend:

```yaml
http:
  routers:
    myapp-www:
      rule: "Host(`www.myapp.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
      middlewares: ["https-www-to-https-non-www@file"]
      service: noop@internal
```

`noop@internal` is Traefik's built-in placeholder for routers whose
middleware fully handles the response (a redirect, in this case).

## Middlewares provided by kasbah

Referenced via `@file` from `_shared.yml`:

| Name | Purpose |
|---|---|
| `http-to-https@file` | 301 redirect from :80 to :443 |
| `http-www-to-https-non-www@file` | www → apex at the HTTP level |
| `https-www-to-https-non-www@file` | www → apex at the HTTPS level |
| `security-headers@file` | HSTS, frame-deny, content-type-nosniff, CSP-report-only stub |
| `gzip-compression@file` | Response compression |
| `api-rate-limit@file` | 50 avg / 100 burst requests/sec |
| `traefik-dashboard-auth@file` | Basic auth for the dashboard. **Deliberately outside the frozen set** — `traefik.<apex>` is kasbah's, and no project has a reason to reference it |

Project-specific middlewares go in the same project fragment under
`http.middlewares.<name>`.

## TLS

- ACME via HTTP-01 challenge (port 80 must be reachable), through one resolver
  named `http` after the challenge it answers — a frozen name, which every
  `websecure` router references as `tls.certResolver: http` (T04).
- HTTPS is per router. A fragment whose routers sit on `web` alone serves plain
  HTTP and asks for no certificate; `kasbah check` passes it (T08 asks only
  for a `web` router), though `check --server` warns that its domain has no
  certificate. The `http-to-https` and www redirect middlewares in
  `_shared.yml` are for projects that serve HTTPS, not required.
- Traefik keys `acme.json` by resolver name. A store filled under the
  resolver's former name, `letsencrypt`, is not read: `check --server` and
  `server status` report it as holding no `http` store.
- A server rendered under `letsencrypt` moves to `http` in two steps: re-run
  `server init` (with `--with-mail` where the mail stack runs, so `_mail.yml`
  is re-rendered too), then redeploy every project from a fragment edited to
  `http` (T04 refuses the old name). Between the two, a router still naming
  `letsencrypt` points at a resolver that no longer exists and serves
  Traefik's self-signed default certificate; each one gets a fresh
  certificate under `http` once it is redeployed. `upgrade-traefik` can take
  the first step only while no project fragment and no `_mail.yml` names
  `letsencrypt`: its dry run boots against them (with its own `_shared.yml`
  in place of the server's) and refuses on any that does.
- Stored in `/apps/data/traefik/letsencrypt/acme.json`, `chmod 600`.
- TLS options default to TLS 1.2–1.3 with modern cipher suites
  (declared in `_shared.yml`).
- **Never compute a certificate's age from `notBefore`.** Let's Encrypt
  backdates it by roughly an hour — measured twice against Traefik's own log
  on synchronised clocks, both UTC: 58m32s, 58m31s and a third measurement
  agreeing. A certificate issued twelve seconds ago reads as an hour old, so
  anything deciding "is this fresh" must use the log, or treat anything under
  ~2 h as just issued. `check --server`'s cert rule sidesteps the question
  entirely: it reports `notAfter` and the days remaining, which is what an
  operator can act on, and reads `notBefore` for nothing.

### Which CA — production or staging

`kasbah server init --acme-staging` points the resolver at Let's Encrypt's
staging endpoint; without the flag it is production. Both are written into
`traefik.yml` as an explicit `caServer`, production included, so the file
always says which CA is in effect and a re-run decides by comparing one line
rather than by reasoning about a missing field.

```yaml
certificatesResolvers:
  http:
    acme:
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging certificates are **not trusted by browsers** — that is the point.
Production rate limits are per registered domain and are spent by failed
challenges too, so the first run against a fresh VPS should be staging: it
proves DNS, port 80 and the whole challenge round trip without costing
issuance budget, and the switch to production afterwards is one command.

**The endpoint is decided on every run, and production is the default.**
There is no prompt for it and no stored value to fall back on: a re-run
without `--acme-staging` moves a staging server to production, which is how
the switch is meant to be made, and equally means a server that is meant to
stay on staging is re-run with the flag every time.

**A switch resets `acme.json`.** Traefik files certificates by resolver, not
by endpoint, so entries issued by the CA being left behind stay in the store
and stay in use — a staging certificate served to the public, or a production
certificate an operator believes they have moved off. Init therefore archives
the store beside itself as `acme.json.<UTC timestamp>` (mode 600, never
deleted — production certificates are real and re-issuing them costs budget),
re-creates an empty `acme.json` mode 600, and restarts Traefik, which
re-issues **every routed hostname as soon as the new configuration loads** —
no request needed, about 10 s per certificate (measured: register 1 s,
HTTP-01 5 s, certificate 3 s). Two consequences: the rate-limit budget is
spent at restart, so a hostname whose DNS is wrong burns it with nobody
visiting; and a switch is verifiable about fifteen seconds later rather than
whenever traffic happens to arrive. The reset runs
inside the restart, after the old container has stopped and before the new one
starts: Traefik saves its whole store into `acme.json` in place, so a reset made
while the old Traefik still runs could be refilled with the old CA's certificates.
The store is emptied in place rather than replaced, because Traefik and the mail
server both mount it as a single file and a new inode would leave them on the old one.

**Whether it happens turns on the store, not on the config.** An empty or
absent `acme.json` is never reset and never asked about — nothing is at risk,
and that covers every fresh server. A non-empty one is left alone when the
`caServer` on the server matches this run, and reset when it differs.

The two prompts that guard this are different kinds of question:

- **Switching away from a stated endpoint** is a confirmation: `--yes` answers
  it, and declining aborts with nothing changed.
- **A non-empty store whose provenance nothing records** — no `caServer`, or a
  `traefik.yml` missing, empty or unparseable — is a choice, and gets its own
  tri-state pair, `--reset-acme` / `--keep-acme`. Unset means ask; with no
  terminal and neither flag the run fails naming both. Keeping proceeds, with
  a warning, because kasbah raised this question rather than the operator and
  an abort would strand every server prepared before `caServer` existed.
  `--yes` deliberately does not answer it.

Neither flag answers the other's question. A choice flag on a run that never
asks the choice is a warning, not a failure; `--keep-acme` on a run that must
switch is a refusal, because keeping the store and changing CA cannot both
happen and `--yes` must not be what decides it.

The run records the endpoint either way, so the unknown case is asked once.
See `server-setup.md` for the full table.

## Dashboard

**Optional**: `server init --with-dashboard` serves it at `traefik.<init-domain>`,
protected by basic auth (hash generated during init); `--no-dashboard` leaves it
out. A first init with neither flag asks; a re-run with neither keeps what the
server has, and whether it has one is read from `_shared.yml` itself — its two
routers are there or they are not, so there is no stored setting to drift from
the file. `--no-dashboard` on a re-run removes both routers, the
`traefik-dashboard-auth` middleware and its hash, so turning it back on asks
for credentials as a first init does. While it is off a project may route
`traefik.<apex>` itself; every init with the dashboard on warns about any
project fragment that does, naming it. The frozen middlewares are there either
way. With it off, `traefik.yml` still says `api.dashboard: true` — Traefik's
API is then reachable through no router at all, since `api.insecure` is never
set and only `:80`/`:443` are published. When it is on, both routers live in
`_shared.yml`, not the docker-provider API entrypoint, and there are two of them:

- `traefik-dashboard-http` on `web` — **redirect only**, carrying
  `http-to-https` and served by `noop@internal`. It must never carry the auth
  middleware: a router that asks for credentials over plain HTTP is how they
  end up on the wire. The redirect answers first, so the browser
  authenticates against TLS.
- `traefik-dashboard` on `websecure` — `security-headers` **then**
  `traefik-dashboard-auth`. Headers first is deliberate: the 401 is the first
  response a browser sees, and carrying HSTS on it is what stops the *next*
  visit using plain HTTP at all, which beats depending on the redirect.

The residual exposure, which no arrangement here removes: a client that
pre-emptively sends `Authorization:` to the `http://` URL has already put the
password on the wire before any redirect or 404. Browsers do not do this
unprompted — basic-auth credentials are cached per origin, and `http://` and
`https://` are different origins — but `curl -u` against an `http://` URL
does.

### Every other hostname pointing at the box

Once Traefik holds `:80` and `:443`, *any* name resolving to the host that no
fragment claims gets Traefik's **404** on `:80` and its self-signed
`TRAEFIK DEFAULT CERT` on `:443` — observed on the apex of a domain whose
subdomains kasbah serves. Previously those ports refused the connection. This
is normal and is not an error to chase, but an operator who points an apex at
the box and expects nothing to change will notice.

## Health

Traefik has a compose healthcheck (`traefik healthcheck --ping`). `kasbah
server status` surfaces it.

## Lifecycle on deploy / rollback / drop

- **Deploy** — kasbah syncs `traefik-dynamic.yml` directly to
  `/apps/traefik/dynamic/<manifest.name>.yml`. The sync writes temp + rename,
  so Traefik sees a single atomic replace event and reloads.
- **Rollback** — kasbah reads `traefik-dynamic.yml` from
  `git archive v<target>` and syncs it to the same destination.
- **Deploy / rollback, before the fragment** — after `compose up`, Traefik is
  attached to `<project>_kasbah` (a failed attach fails the run, which reverts);
  a revert's own `up` attaches it again.
- **Drop** — `rm /apps/traefik/dynamic/<manifest.name>.yml`, then Traefik
  detached from `<project>_kasbah`, then `docker compose down`. That order is the
  point: the route goes first, so a run that dies between them leaves a stopped
  project nothing is routing to, rather than a live route onto nothing. (`kasbah server destroy` deliberately
  leaves fragments in place — a handover keeps every site routing.)

## What projects may NOT do

- Use `traefik.*` labels in compose (the docker provider is not wired in).
- Add routers in their fragment for `traefik.<domain>` (reserved for the
  dashboard).
- Add routers in their fragment for `mail.<domain>` or `webmail.<domain>`
  (claimed by kasbah's `_mail.yml` — cert-trigger and webmail).
- Route to a Traefik `@internal` service other than `noop@internal` — `api@internal`
  and its kin would publish Traefik's API with no auth (T09).
- Bind ports 80 or 443 on the host (they belong to Traefik).
- Replace the `kasbah-net` network, or declare their `kasbah` network
  `external` or with a fixed `name:`.
- Attach non-routed services (databases, caches, workers) to the `kasbah`
  network (or the legacy `kasbah-net`) — internal services stay on a
  project-internal network.

`kasbah check` enforces these (rules T01–T09, C03, C04, C07, C09).

## Upgrading Traefik

```
kasbah server upgrade-traefik user@vps --version=v3.7.10
```

Two halves, and the second one is the point.

**Backup before overwrite.** The three kasbah-owned files are re-rendered
from this kasbah's templates, with the new tag in `compose.yml` and the
four recovered values reproduced verbatim, and the bytes already on the
server are copied to `<apps>/traefik/backups/<UTC timestamp>/` before any
of them is replaced. Backups are never deleted and never land in
`dynamic/`, which Traefik watches.

**The dry run.** Before anything is touched, a throwaway Traefik of the
*target* version is booted with `<apps>/traefik/dynamic/` mounted
read-only and the freshly rendered `_shared.yml` laid over its own copy —
so what is validated is the configuration that will be live, and every
fragment in that directory is in it: `_shared.yml`, `_mail.yml` and every
project's `<project>.yml`. **Any line the throwaway logs at `ERR` fails the
upgrade**, with one family excluded: the certificate it cannot obtain from
the deliberately unreachable CA the dry run points it at
(`https://127.0.0.1:1/…`), which is how it contacts no CA, registers no
account, answers no challenge and spends no rate-limit budget. Warnings
are reported and are never fatal — a version bump is exactly when Traefik
starts announcing deprecations.

Those excluded lines are also the proof the dry run read anything: the file
provider emits one per TLS router it built out of the mounted fragments,
naming it, so a run that loaded nothing has none of them. The overlay of the
freshly rendered `_shared.yml` carries one extra router the live file never
has, `kasbah-dry-run-anchor` — the overlay is written as JSON for that, which
Traefik reads as YAML — and the upgrade refuses unless `kasbah-dry-run-anchor@file`
is among them **and** — when the server's `dynamic/` holds any fragment besides
`_shared.yml` — at least one router that is not `_shared.yml`'s. The anchor
comes from the overlay this run writes, so it alone would appear even with the
server's directory empty, dashboard or not; a clean log on its own is not evidence.

The throwaway is isolated in four ways: `--network none`, no published
port, both mounts read-only, and its own entrypoints moved to `:8080`
/`:8443` so nothing depends on remembering to leave `-p` off. Its name
carries the run's timestamp and it carries a label the next run sweeps by,
so a leftover from a crashed run is inert and is cleaned up rather than
colliding.

**`acme.json` is never opened for writing.** The certificates are the thing
that has to survive a version bump. The run digests the store before and
after and reports whether the new Traefik wrote to it, which is an
observation and not a failure — a renewal landing during the restart is
normal.

**What a failure leaves.** Everything up to the backup is read-only on the
server, so a dry run that says no leaves the old proxy running and
untouched. If the new version will not come up healthy, the backup is
copied back **on the server** and the old version brought up again — the
restore is part of the same step rather than a round trip, so a dropped
connection cannot strand the proxy with the fix on the wrong machine.

The endpoint (`caServer`), the ACME address, and — when the dashboard is on —
its apex and basic-auth entry are recovered off the server and reproduced
(the endpoint and address from the `http` resolver, or from one still named
`letsencrypt` when `http` has none — though the dry run refuses one whose
project fragments or `_mail.yml` still name it, and those move through `server
init`, TLS above); a stack with no dashboard router is recovered as one without
a dashboard. A stack
that will not yield them is refused and the operator is sent to `server
init`: repairing one of those is init's job, and a version bump must not
move a server's CA or its dashboard credentials as a side effect.
