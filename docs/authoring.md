# Authoring a project

A kasbah project is an ordinary repository with a few files at its root. This
guide takes them one by one — what each must hold, what it may hold, and what
`kasbah check` fails or only warns about, and why — then walks through the
common shapes of a project, each with a complete example under
[`examples/`](../examples/). The rules themselves, with every detail of what
passes, are in [compliance.md](compliance.md); the rule IDs below link there.
`kasbah check` prints each line's rule ID, and the binary explains them
without the docs: `kasbah help <id>` says why a rule exists and what to
change, and `kasbah help files` and `kasbah help setups` summarise this guide
([cli.md](cli.md) → `kasbah help`).

| File | Who writes it | Needed |
|---|---|---|
| `kasbah.yml` | `init-project`, then you | always |
| `compose.prod.yml` | you | always |
| `traefik-dynamic.yml` | you | when anything is routed |
| `.env.prod.example` | `init-project`, then you | always, even comment-only |
| `.gitignore` | `init-project` adds its two lines | recommended: without its two lines `check` warns |
| `Dockerfile` | you | when a service builds its own image |

`kasbah init-project --name=<name> --domain=<fqdn>` writes `kasbah.yml`,
`.env.prod.example` and the `.gitignore` lines, and prints a starter for
`compose.prod.yml` and `traefik-dynamic.yml` that passes `check` as it stands
([cli.md](cli.md) → `kasbah init-project`). `kasbah check` then reads the
files without building, pulling or running anything: it exits 0 when nothing
fails, warned or not, 6 when a rule fails, and 1 when it cannot check at all —
a `kasbah.yml` that does not load (bad YAML, a missing, non-integer or newer
`schema`, a missing, malformed or reserved `name`, a field of the wrong type)
or a file shaped too badly for a rule to read ([cli.md](cli.md) → `kasbah check`).
`kasbah check --fix` rewrites what can be fixed mechanically — restart
policies, log rotation, a top-level `version:`, the limits and reservations,
the `kasbah` network, the `:current` tag, a missing `kasbah_version` — and
shows the diff before it writes; what it leaves to you is listed in
[compliance.md](compliance.md#--fix-behavior).

## `kasbah.yml`

The manifest: what the project is called on the server, which domain it
answers on, and what a deploy ships. Field by field in
[project-manifest.md](project-manifest.md).

**Required.**

- `schema: 1` — a manifest without it, or with a newer one than this kasbah
  reads, is refused before any rule runs ([S02](compliance.md#structure)).
- `kasbah_version` — written by `init-project` and kept by kasbah; leave it as
  it is.
- `name` — the project's directory on the server and the prefix of every name
  Traefik can see: lowercase letters, digits and `-`, starting with a letter.
  `traefik`, `mail`, `data`, `backups` and `kasbah-backup` are kasbah's and
  refused ([S07](compliance.md#structure)): a project deployed under one
  would overwrite or remove what kasbah keeps there — the shared proxy, the
  mail stack, the backup scheduler.
- `sync` — the files a deploy copies to the server, as `src` or
  `src -> dst`, a trailing `/` for a directory. It always holds
  `compose.prod.yml -> compose.yml` and `.env.prod.example`, and anything a
  bind mount reads from the project folder (a `site/` mounted read-only, a
  config file). `check` does not read it; deploy refuses an empty list, and
  names every source the tree does not have. Never list `traefik-dynamic.yml`
  (shipped on its own) or `kasbah.yml` (never shipped).

**Expected when routed.** `domain` — the hostname the fragment's routers
answer on. Leaving it out only warns: T02 and T08, which match the routers
against it, are skipped.

**Optional.**

- `routed: false` — nothing is routed to this project: it ships no
  `traefik-dynamic.yml`, needs no `domain`, and a fragment beside it fails
  while a domain beside it warns ([T11](compliance.md#traefik)). A worker, or
  a service reached on a port of its own.
- `health` — which container a deploy waits on, and for how long (default
  120s). `health.container` must name a service or a `container_name`
  ([H02](compliance.md#healthchecks), a failure); a timeout shorter than a
  healthcheck's first probe warns ([H03](compliance.md#healthchecks)), since
  every deploy that recreates it would fail on health.
- `hooks` — one line of shell per entry, in six lists (`backup`, `restore`,
  `pre-deploy`, `post-deploy`, `pre-rollback`, `post-rollback`); anything
  else fails ([HK01](compliance.md#hooks)), and so does a top-level `backup:`
  ([HK02](compliance.md#hooks)), which is `hooks.backup`. A `backup` hook is
  the only way data reaches a backup: kasbah dumps no database itself.
- `resources` — this project's own `cpus` and `memory` ceiling, in place of
  the server's 90% ([R05](compliance.md#resources) fails a malformed one).
- `client` — groups the project's off-server backups with others
  ([S08](compliance.md#structure)).
- `mail.domain` — the mail domain the app sends from
  ([M01](compliance.md#mail-m01m03-only-if-mail-present-in-manifest) fails a
  block naming none); a deploy warns, without stopping, when the server's mail
  stack does not serve it.

## `compose.prod.yml`

The compose file the server runs, synced as `compose.yml` and brought up as
`docker compose -p <name> up -d`. It is your compose file with a handful of
conventions; [traefik.md](traefik.md) → Network explains the network ones.

**Every service** sets:

- `restart: unless-stopped` (or `always`, `on-failure`) — [C01](compliance.md#compose),
  a failure: a service that does not come back after a reboot is down.
- `logging` with `driver: json-file` and both `max-size` and `max-file` —
  [C02](compliance.md#compose), a failure: unrotated logs fill the disk every
  project shares.
- `cpus: ${KASBAH_CPU_LIMIT}` and `mem_limit: ${KASBAH_MEM_LIMIT}` —
  [R01, R02](compliance.md#resources), a failure when missing. kasbah writes
  the two variables into the server's `.env` at every deploy; never declare
  them in `.env.prod.example`. A literal (`mem_limit: 512m`) is allowed and
  warns locally, since only `check --server` can hold it to the host. To give
  the whole project less than the default, set `resources:` in `kasbah.yml`
  instead and keep the variables. Reservations fail
  ([R03](compliance.md#resources)).

**Routed services** — the ones a fragment's `loadBalancer` URL names — join
the project's own `kasbah` network, declared at the top level as exactly
`kasbah: {}`. Compose creates it as `<name>_kasbah` and deploy connects
Traefik to it.

- A routed service off it fails ([C03](compliance.md#compose)). The legacy
  shared `kasbah-net` warns instead, because every project's routed
  containers reach each other there, and a fragment cannot target a service
  on it by service name ([T07](compliance.md#traefik), a failure). `deploy`
  goes further and refuses any backend on `kasbah-net` alone: the server
  installs each backend qualified with the project's `kasbah` network
  ([traefik.md → Backends are the project's own](traefik.md#backends-are-the-projects-own)).
  A service reached by its `container_name` does not roll
  ([C11](compliance.md#compose), a warning).
- Any setting on the network (`external`, `name`, `driver`) fails
  ([C04](compliance.md#compose)): compose would try to recreate it under
  Traefik.
- Every name on it — service, alias, `container_name` — is `<name>` or
  `<name>-…` ([C09](compliance.md#compose), a failure): Traefik resolves names
  across every project's network, so a service called `web` could answer for
  another project's.
- No name on it, or on a legacy `kasbah-net` — service, alias,
  `container_name` — holds a dot ([C16](compliance.md#compose), a failure,
  and `deploy` refuses it too): Docker answers a whole dotted name on every
  network Traefik is on, so `web.<other>_kasbah` would answer for another
  project's backend.
- To **roll** on deploy — the new container started beside the old one, the
  old one stopped once the new one is healthy — a routed service sets no
  `container_name`, publishes no host port, declares a compose `healthcheck:`
  and has no `depends_on` condition but `service_started`; otherwise it is
  recreated in place, briefly unrouted, and `check` warns naming why
  ([C11](compliance.md#compose)). `depends_on: [db]` keeps the order without
  a condition.
- A routed service whose old and new containers must never run together —
  an app holding a file lock or a single-writer SQLite database, or one
  running its own scheduler — is labelled `kasbah.noRoll: "true"` instead.
  No deploy or rollback then rolls it; when one replaces it, compose recreates
  it in place, stopping all of its old containers before it starts any new
  one, whatever its replica count, and `check` says so rather than warning
  ([C11](compliance.md#compose)). The running containers carry the label too,
  so a rollback to a version without it is not rolled either. The value is a boolean, read as Traefik
  reads its labels ([C15](compliance.md#compose)). An unrouted service needs
  no label: it is never rolled.

**Everything else** — databases, caches, workers — stays off the `kasbah`
network and `kasbah-net` ([C07](compliance.md#compose), a failure): Traefik
is on that network, and a service there is one name lookup away from every
other project. Put them on a project-internal network, or leave out
`networks:` so they sit on the project's default one.

**Built services** — a `build:` key — name their image with the `:current`
tag, as `image: <name>-web:current` ([C08](compliance.md#compose), a
failure): deploy moves `:current` to the version it starts, and a pinned tag
would keep the old image running while the deploy reports success. A built
service without a compose `healthcheck:` warns
([H01](compliance.md#healthchecks)): `check` cannot see a `HEALTHCHECK` in a
Dockerfile, so declare it in compose too when you want the warning gone.
Stock images are pulled on the server by `compose up`; built ones travel from
your machine with `kasbah build-push`.

**Never:**

- `traefik.*` labels ([T06](compliance.md#traefik), a failure): routing lives
  in `traefik-dynamic.yml`, and the docker provider is not wired in.
- A host port 80 or 443, on any address or protocol
  ([C14](compliance.md#compose), a failure): they are the shared Traefik's.
  Any other port is the project's to publish; `check --server` fails one a
  container outside the project already holds
  ([C12](compliance.md#compose)).
- `mail-dms` outside a comment ([C10](compliance.md#compose), a warning): no
  project shares a network with the mail server; an app sends through
  `mail.<domain>:587` ([mail.md](mail.md) → SMTP access from apps).
- A top-level `version:` ([C05](compliance.md#compose), a warning): compose
  ignores it.

**Volumes** are not read by any rule. A named volume is kept by every deploy,
rollback and `drop`; a bind mount may point under `<data>/<name>/`, which
deploy creates and `drop --prune` removes, at a synced path in the project
folder, or at a host path the operator owns ([overview.md](overview.md) →
Where a bind mount may point). None of them is in a backup unless a `backup`
hook dumps it.

A project with nothing to run — every router a redirect — declares
`services: {}`: deploy then starts nothing and still ships the fragment
([traefik.md](traefik.md) → Redirect-only router).

## `traefik-dynamic.yml`

The project's routing, as a Traefik file-provider fragment; deploy renders it
on the server and installs it as `<apps>/traefik/dynamic/<name>.yml`, and
Traefik picks it up live
([traefik.md](traefik.md) → Project fragment). Absent, a routed project warns
([T01](compliance.md#traefik)); with `routed: false` it must be absent.

**The usual shape** is two routers on the domain and one service:

- a `websecure` router whose `rule` is ``Host(`<domain>`)``, with
  `tls.certResolver: http` and a `service` of the fragment's own;
- a `web` router on the same host with `middlewares: ["http-to-https@file"]`
  and `service: noop@internal`, so plain HTTP redirects;
- under `http.services`, a `loadBalancer` whose server URL is
  `http://<routed service>:<port>`.

What fails, and why:

- No router naming the manifest's `domain` ([T02](compliance.md#traefik)).
- A router without `entryPoints` ([T03](compliance.md#traefik)); the two
  there are `web` (:80) and `websecure` (:443).
- A `websecure` router without `tls.certResolver`
  ([T04](compliance.md#traefik)). `http` is the resolver kasbah configures; a
  DNS provider's resolver added by `server init --acme-dns` warns locally and
  is checked by `check --server`.
- A hostname whose first label is `traefik`, `mail` or `webmail`
  ([T05](compliance.md#traefik)): those are kasbah's on the server.
- A server URL naming nothing in `compose.prod.yml`, a service on no
  Traefik network, or a service on the legacy `kasbah-net` by its service
  name rather than its `container_name` ([T07](compliance.md#traefik)): there
  every project's same-named service answers too. `deploy` holds the
  rendered fragment to the stricter form on the server — a service, `kasbah`
  alias or `container_name` on the project's `kasbah` network, written bare
  (no IP, domain or network suffix).
- A Traefik `@internal` service other than `noop@internal`
  ([T09](compliance.md#traefik)): `api@internal` and its kin would publish
  Traefik's API with no authentication.
- A wildcard certificate (`*.`) from `http` ([T10](compliance.md#traefik)):
  HTTP-01 cannot issue one.
- A `${KEY}` that `.env.prod.example` does not declare, or a `KASBAH_` one
  ([T12](compliance.md#traefik)); a `${KEY}` in a router's `rule`,
  `service` or `middlewares`, under its `tls`, or in a service name T09 reads
  outside routers ([T13](compliance.md#traefik)): hosts and every service name
  stay literal.

What warns: no router serving the domain on `web`
([T08](compliance.md#traefik)) — plain HTTP then gets Traefik's 404. Leave it
out only for an HTTPS-only API nothing browses to.

**Middlewares.** kasbah's shared ones are named with `@file`:
`http-to-https`, `http-www-to-https-non-www`, `https-www-to-https-non-www`,
`security-headers`, `gzip-compression`, `api-rate-limit`
([traefik.md](traefik.md) → Middlewares provided by kasbah). A project's own
go under `http.middlewares` in the same file and are named without a suffix.

**Secrets.** A value that must stay out of git — a basicAuth users line — is
written `${KEY}` and filled at deploy from the server's `.env`
([traefik.md](traefik.md) → Project fragment). For basic auth: declare the
key in `.env.prod.example` with a generator (`MYAPP_AUTH_SECRET=! …` running
`htpasswd -niB <user>`, [env-template.md](env-template.md) → Sensitive value
handling) or a `# hint`, then name it in the fragment, single-quoted so a `$`
or `:` in the hash stays text, and attach the middleware to the router:

```yaml
http:
  routers:
    myapp:
      # rule, entryPoints, tls and service as above
      middlewares: ["myapp-auth"]
  middlewares:
    myapp-auth:
      basicAuth:
        users: ['${MYAPP_AUTH_SECRET}']
```

Only `${KEY}` with braces is filled: a `$apr1$…` hash written literally, a
regex's `$` and a replacement's `${1}` are left alone, and `$${` writes `${`.
A deploy whose `.env` leaves the key unset or empty stops before anything
changes and names `kasbah env set MYAPP_AUTH_SECRET USER@HOST`. A changed value
reaches Traefik on the next deploy.

**Names.** Traefik reads every project's fragment, and kasbah's own, from one
directory into one configuration, so a router, service or middleware name is
shared by every project on the server. Make each the project's `name` or
`<name>-…`, as every example does: when two fragments define the same name,
Traefik reports the conflict and serves at most one of the definitions,
which need not be yours. `check` reads no other project's fragment, so no
rule catches a clash.

## `.env.prod.example`

The template the server's `.env` is generated from: each key is asked for on
the first deploy, and a key added later by the deploy that finds `.env`
without it ([env-template.md](env-template.md) → Drift detection).
Committed; the `.env` never is. Its line forms — a default, a blank, a `#`
hint the operator must answer, a `!` command that generates the value — are in
[env-template.md](env-template.md) → Template conventions.

- Required ([S04](compliance.md#structure)), and a comment-only one is a
  normal end state: the hostname lives in `domain:` and the fragment, not
  here.
- A line that is none of the forms fails ([E01](compliance.md#env)).
- A value over 64 characters warns ([E04](compliance.md#env)) as a possible
  leaked secret: a secret is a `# hint` or a `! generator`, never a value.
- A `KASBAH_*` key warns ([E05](compliance.md#env)): kasbah injects those.
- A local `.env` whose keys differ from the template's warns
  ([E02, E03](compliance.md#env)); `check --server` asks the same of the
  server's.

Compose reads the server's `.env` when it interpolates `compose.prod.yml`,
so a value reaches a container through `${KEY}` in its `environment:`, and
the fragment through its own `${KEY}` (`traefik-dynamic.yml` above).

## `.gitignore`

Excludes `.env` and `.kasbah/` ([S05, S06](compliance.md#structure), both
warnings): the first holds secrets, the second this checkout's state.

## Setups

Each directory under `examples/` is a complete project for one shape: copy
it, replace its `name`, its domain and the names prefixed with it, and adapt
the services. Every one passes `kasbah check` with no failure and no warning;
the test suite runs `check` over each, so none can drift from the rules. The
images are real stock images standing in for yours; their versions are
pinned to exact releases, since a rollback runs the files of an older
version and a moving tag would not take the image back with them.

### A web app — [`examples/web-app/`](../examples/web-app/)

One service built from the project's `Dockerfile`, tagged `:current`, with a
compose healthcheck so it rolls on deploy, on the `kasbah` network alone.
Its fragment serves the domain over HTTPS, redirects plain HTTP, and sends
`www.` to the bare domain with kasbah's shared middlewares. `kasbah
build-push` ships the image before `kasbah deploy`.

### An app and its database — [`examples/app-database/`](../examples/app-database/)

A stock app routed on `kasbah` and `internal`, and PostgreSQL on `internal`
only, its data in a named volume. The app's `depends_on: [db]` carries no
condition, so the app still rolls. The database password is generated by a
`!` line on the first deploy and reaches both services through `${DB_PASSWORD}`.
A `backup` hook dumps the database into every deploy's backup, and a
`restore` hook loads it back when a rollback or a restore is asked to bring
data.

### A worker with no route — [`examples/worker/`](../examples/worker/)

`routed: false`, no `domain`, no `traefik-dynamic.yml`, and a service with no
`networks:`, on the project's default network. No rule asks a healthcheck of
it, since nothing is routed and nothing is built.

### A redirect-only domain — [`examples/redirect-only/`](../examples/redirect-only/)

An old domain sent to a new one, path kept, with a `redirectRegex` middleware
of the fragment's own on both entrypoints, so plain HTTP takes one hop.
Every router ends on `noop@internal`, `compose.prod.yml` declares
`services: {}`, and the template is comment-only.

### A raw TCP/UDP port — [`examples/raw-port/`](../examples/raw-port/)

A service clients reach on a port of its own, not through Traefik — a game
server, published on the host as `"25565:25565"` (TCP) and
`"25565:25565/udp"`. `routed: false`, since nothing is routed; a raw port on
a project that also routes a web app goes on a service the fragment does not
name, as a published port keeps a routed one from rolling. It also raises
`health.timeout` for a slow first start, sets the project's memory ceiling
as a share of the host in `resources:`, and asks for a value with a `#` hint
the operator must answer.

### An app that sends mail — [`examples/sends-mail/`](../examples/sends-mail/)

A routed app with `mail.domain` in its manifest, sending through the mail
stack's public hostname on port 587 with a mailbox login, as
[mail.md](mail.md) → SMTP access from apps describes. Host, port and login
are template keys, the password a hint, and the app joins no network but its
own `kasbah` one. Gitea is configured whole through its environment — its
database, a locked install wizard, closed registration — so nothing on the
public domain sets it up for the first visitor. The mailbox itself is made
on the server; kasbah creates none.

### Persistent volumes — [`examples/persistent-volumes/`](../examples/persistent-volumes/)

One routed service and the three places data lives: its configuration
bind-mounted from `<data>/<name>/` (written `../data/<name>/…`, which is that
directory under the default data path), a cache in a named volume, and a
library at a host path the operator creates, mounted read-only and named by a
template key. It carries no `backup` hook, so none of it is in a backup —
`examples/app-database/` shows one.
