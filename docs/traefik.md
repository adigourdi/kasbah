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
them — the dashboard domain, the ACME email, the basic-auth hash, and the
Traefik image tag — and the list of DNS-01 resolvers `traefik.yml` declares
(TLS → DNS-01).

**The DNS providers' env files are installed by kasbah and supplied by the
operator.** `<apps>/traefik/acme-dns/<provider>.env` is written only by a
`server init --acme-dns=<provider>:<file>` that names it, from the file the
operator passed; no other run rewrites, re-modes or backs it up, and init
reads nothing of it back but the fact that it exists.

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
remove a network a foreign container is still on. A version whose compose
declares no service (Redirect-only router, below) runs no `compose up` and
attaches nothing; when an earlier version's containers are still there,
Traefik is detached from `<project>_kasbah` before the `compose down
--remove-orphans` that removes them, as on `drop`, so the network goes too. A compromised container
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

Every fragment in the directory feeds one configuration, so router, service
and middleware names form one namespace across every project and kasbah's
own fragments. A project names its own `<manifest.name>` or
`<manifest.name>-…`: when two fragments define the same name, Traefik reports
the conflict and serves at most one of the definitions. `kasbah check` reads
no other project's fragment, so no rule catches a clash.

## Project fragment

Each routed project ships `traefik-dynamic.yml` at its repo root (a project
with nothing to route says `routed: false` in its manifest and ships none —
`project-manifest.md` → `routed`). `kasbah deploy`
installs it as `/apps/traefik/dynamic/<manifest.name>.yml` — no
intermediate copy, no entry in the manifest's `sync:` list. Kasbah
handles it out-of-band: the server's kasbah fills its `${KEY}`s from the
project's `.env` (below) and renames the result into place, mode `640`.
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

### Values from the project's `.env`

A fragment can take a value it must not carry in git — a basicAuth users
line, a header token — from the project's `.env` on the server, the file
compose reads:

```yaml
http:
  middlewares:
    myapp-auth:
      basicAuth:
        users: ['${MYAPP_AUTH_SECRET}']
```

- `${KEY}`, braces and a key name required, is replaced by `KEY`'s value in
  `<apps>/<project>/.env`, verbatim, as compose reads that file. Anything else
  with a `$` is left as written — `$apr1$…` hashes, a regex's `^/x$`, a
  redirectRegex replacement's `${1}`. `$${` writes a literal `${` (a named
  group's `${name}` in a replacement is written `$${name}`). The scan is the
  file's text, comments included.
- The key must be one `.env.prod.example` declares, and not a `KASBAH_` key
  (T12). Its value comes from `.env`, which `kasbah env` or `kasbah env set
  KEY` fills like any other key (`env-template.md`).
- Hosts and every service name stay literal: a `${KEY}` in a router's
  `rule`, `service` or `middlewares` or under its `tls`, or in a service name
  outside routers (a `mirroring`, `weighted`, `highestRandomWeight` or
  `failover` service's, an `errors` middleware's `service`), is refused (T13),
  because `check`, `check --server` and `server status` read a project's hosts
  and resolvers from the fragment, and T09 every service it reaches.
- The deploy's preflight on the server renders the fragment before anything
  changes: a key not declared, a `KASBAH_` key, one `.env` leaves unset or
  empty, a value spanning lines or holding `{{` (Traefik would read it as a
  template), a `{{` the filling builds out of the text and a value, or a
  result that reads as other YAML than the fragment as written stops the run,
  naming the key and the `kasbah env set KEY USER@HOST` that sets it
  (`kasbah env USER@HOST` for a key new to the template, which the refused run
  put back), and nothing is started. A value may change only the scalar its
  `${KEY}` sits in: a result that does not parse, or has a key, a list item
  or nesting the fragment as written lacks, is refused naming the key and its
  line, never the value or YAML's message about it. A value YAML reads
  specially (`"`, `: `, `#`, `[`, a leading `*`, `&` or `!`) wants the
  `${KEY}` single-quoted in the fragment, so the fragment as written must
  parse with its `${KEY}`s in place. The same render, after the engine's
  report, is what is installed; a failure there leaves the live file as it
  was.
- `rollback` and `deploy X.Y.Z` render that version's fragment against the
  server's `.env` as the run leaves it, with the same preflight, but a `${…}`
  that is not a key the fragment may take — undeclared or `KASBAH_`, text
  written before deploys filled `${KEY}`s, such as a regex group — is left as
  written, with one warning line naming it. A declared key that `.env` leaves
  unset or empty still refuses. A deploy of the working tree refuses either.
- A changed value reaches Traefik on the next deploy, which renders new bytes
  and Traefik reloads them live; `kasbah env set` alone does not re-render the
  fragment.
- A fragment with no `${KEY}` and no `$${` is installed byte for byte.

Traefik's own `{{ env "X" }}` reads the Traefik container's environment, which
holds a DNS provider's credentials and nothing per project.

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

A project whose routers all end on `noop@internal` needs no container, and no
placeholder service to give compose something to start: its
`compose.prod.yml` declares `services: {}`. Deploy, rollback and restore then
start nothing and attach Traefik to no network (moving to such a version
detaches it from the project's network and removes the old containers —
Network, above), and still sync the files, render `.env`, run the hooks,
record `versions.log` and ship the fragment (`build-deploy.md`); `env set
--restart` has nothing to restart, and `server status` shows the project as
`no services`.

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

- ACME via HTTP-01 challenge (port 80 must be reachable) by default, through
  one resolver named `http` after the challenge it answers — a frozen name.
  Every `websecure` router names a resolver as `tls.certResolver` (T04):
  `http`, or a DNS provider's resolver it opts into (DNS-01, below).
- HTTPS is per router. A fragment whose routers sit on `web` alone serves plain
  HTTP and asks for no certificate; `kasbah check` passes it (T08 asks only
  for a `web` router). `check --server` passes such a domain without looking
  for a certificate, and `server status` lists it as plain HTTP, only when the
  verdict is certain: the fragment holds nothing but `http`, every router in
  it lists exactly `[web]` as its entrypoints and carries no `tls` key, an
  `http` router names the host in a `Host()`, the file holds no `{{` (Traefik
  renders a fragment as a Go template first), no key repeats (Traefik refuses
  such a file and keeps its last good configuration live), and no key spells
  `routers`, `entryPoints` or `tls` in another case (Traefik matches keys
  case-insensitively). Every other host is looked up in the certificate
  store, so a fragment mixing HTTPS and plain-HTTP hosts gets a "no
  certificate" warning for its plain-HTTP ones. Only the project's own
  fragment is read: another fragment routing the same host over HTTPS is not
  seen, nor is a configuration Traefik kept live after refusing a fragment
  for a field it does not know. The `http-to-https` and www redirect middlewares in `_shared.yml` are
  for projects that serve HTTPS, not required.
- Traefik keys `acme.json` by resolver name: each DNS resolver's certificates
  sit under its own top-level key beside `http`. `check --server` and `server
  status` look a host up under the resolver its router names (`http` when no
  router names one). An entry covers a host its `main` or a SAN names, in
  ASCII lowercase, or that a `*.` `main` or SAN covers by exactly one label:
  `*.example.com` covers `a.example.com`, not `a.b.example.com` nor
  `example.com`. An entry naming the host outright wins over any wildcard one,
  else the first wildcard entry in store order; the report names the wildcard
  and its entry's `main` beside the expiry. A store filled under the
  resolver's former name, `letsencrypt`, is not read for an `http` router:
  `check --server` reports no `http` store and names the former name, and
  `server status` counts every resolver's entries, then says the store holds
  `letsencrypt` and nothing under `http` yet.
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

### DNS-01: one resolver per DNS provider

HTTP-01 cannot issue a wildcard, and cannot issue at all while `:80` is
proxied or blocked. DNS-01 can, and it is opted into **per router**. `server
init --acme-dns=<provider>:<env file>` adds a resolver named after the
provider — lego's name: `cloudflare`, `ovh`, `route53`, `gandiv5`,
`digitalocean`; lowercase letters and digits opening with a letter, never
`http` or `letsencrypt`, nor a word YAML reads as a boolean or null (`yes`,
`no`, `on`, `off`, `true`, `false`, `null`) — beside `http`,
with the same ACME address, endpoint (so `--acme-staging` covers every
resolver) and store, a `dnsChallenge` for that provider, and propagation
checked against public resolvers (`1.1.1.1:53`, `8.8.8.8:53`), not the host's.
The env file holds the provider's credentials as `KEY=value` lines under
lego's variable names (`CF_DNS_API_TOKEN=…`); Traefik's `compose.yml` reads it
through `env_file:`. Docker Compose quotes a value back in its parse errors,
which reach the workstation, and interpolates `$`, so the file is held to a
shape it reads as written: blank lines, full-line `#` comments and
`KEY=value` lines, the key `[A-Z_][A-Z0-9_]*` with no space around `=`, the
value non-empty printable ASCII with none of `"` `'` `` ` `` `$` `\` `#` and
no space at either end; CRs are stripped. Anything else is refused on the
workstation, naming the line and the key, never the value. A router opts in
by naming the resolver:

```yaml
http:
  routers:
    tenants:
      rule: "HostRegexp(`^[a-z0-9-]+\\.tenants\\.example\\.com$`) || Host(`tenants.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: cloudflare
        domains:
          - main: tenants.example.com
            sans: ["*.tenants.example.com"]
      service: tenants
```

`server status` looks up every host a router names in a plain `Host()`, and
`check --server` the manifest's `domain`, each in the store of the resolver of
the router whose `Host()` names it, `http` when none does. So
`tenants.example.com` here, or `acme.tenants.example.com` given its own
``Host(`…`)``, is found in that entry — the subdomain through the
`*.tenants.example.com` SAN (one label: `a.b.tenants.example.com` is not
covered). A host matched only by the `HostRegexp` is not listed by `server
status`, and as a manifest `domain` is looked up under `http`, not found in
this entry.

Every other router keeps `certResolver: http`. A wildcard (`*.` in
`tls.domains` of an `http` or `tcp` router, or in an `http` router's
`Host()`) asked of a resolver without `dnsChallenge`
fails `kasbah check` (T10): locally for `http`, under `--server` for any
resolver the server's `traefik.yml` declares without one.

- **One credential per provider per server.** The credentials are the
  Traefik container's environment, and one container holds one value per
  variable, so two accounts at one provider cannot both be configured.
  Scope the token at the provider to the zones this server holds.
- `--acme-dns=` again replaces a provider's env file; a re-run without it
  keeps every DNS resolver `traefik.yml` declares, and refuses, naming
  `--acme-dns=<provider>:` and `--no-acme-dns=<provider>`, when a declared
  provider's env file is missing; a `traefik.yml` that is absent or cannot be
  read keeps every provider whose env file is there. `--no-acme-dns=<provider>`
  removes the resolver and, once Traefik is up without it, its env file —
  refused, listing them, while any file under `dynamic/` holds the provider's
  name as a whole word in any case: every file at any depth, any extension,
  `_mail.yml` included, comments too. A file kasbah cannot read as Traefik
  would counts as naming every provider: one that is not a regular file (a
  link, a FIFO), over 4 MiB or unreadable, or one that is not plain — not
  UTF-8, or holding a control character, a YAML-only line break or BOM, a
  backslash, a `!` (a YAML tag, or a negated rule) or a Go template (`{{`).
  Only `_shared.yml` is skipped — kasbah renders it and its one
  `certResolver` is `http`. Traefik matches keys in any case and
  renders Go templates, so a narrower read could miss a router; a false
  refusal costs an edit, a missed one a router that stops renewing. The same
  rule keeps, with a warning, any env file the post-start sweep would remove.
- `kasbah check` cannot see a server: it warns on a resolver name other than
  `http` that only `check --server` can verify, which fails a name the
  server's `traefik.yml` does not declare.
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

- **Deploy** — kasbah sends `traefik-dynamic.yml` to the server, which fills
  its `${KEY}`s from the project's `.env` and installs the result as
  `/apps/traefik/dynamic/<manifest.name>.yml` by temp + rename, so Traefik
  sees a single atomic replace event and reloads; bytes already there are
  left alone.
- **Rollback** — kasbah reads `traefik-dynamic.yml` from
  `git archive v<target>` and installs it the same way.
- **Deploy / rollback, before the fragment** — after `compose up`, Traefik is
  attached to `<project>_kasbah` (a failed attach fails the run, which reverts);
  a revert's own `up` attaches it again. A version with no service attaches
  nothing: Traefik leaves `<project>_kasbah`, and `compose down --remove-orphans`
  removes the containers and network an earlier version left (a failed detach
  is said, and leaves that network in place).
- **Deploy / rollback of an unrouted version** (`routed: false`) — kasbah
  removes `/apps/traefik/dynamic/<manifest.name>.yml` when an earlier version
  left one there, and says so; with none there it says nothing of routes.
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
- Bind ports 80 or 443 on the host (they belong to Traefik; C14).
- Replace the `kasbah-net` network, or declare their `kasbah` network
  `external` or with a fixed `name:`.
- Attach non-routed services (databases, caches, workers) to the `kasbah`
  network (or the legacy `kasbah-net`) — internal services stay on a
  project-internal network.

`kasbah check` enforces these (rules T01–T13, C03, C04, C07, C09, C14).

## Upgrading Traefik

```
kasbah server upgrade-traefik user@vps --version=v3.7.10
```

Two halves, and the second one is the point.

**Backup before overwrite.** The three kasbah-owned files are re-rendered
from this kasbah's templates, with the new tag in `compose.yml` and the
four recovered values and the DNS resolvers reproduced verbatim, and the bytes already on the
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
starts announcing deprecations. Every resolver, the DNS ones included, is
pointed at that CA and at a throwaway store, and the throwaway gets no env
file: a DNS resolver without credentials logs nothing at boot, and its
routers' certificates fail on the unreachable CA like `http`'s. A DNS
resolver whose env file is missing on the server refuses the upgrade before
the dry run, naming `server init --acme-dns=`/`--no-acme-dns=`: the upgraded
stack would not start without it, and upgrade never writes credentials.

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
untouched. A file that cannot be shipped, or an interrupt while the files
are shipped, has the server put the backup back over the three files, each
renamed into place whole, the proxy not restarted. A write still on its way
— its ssh killed, its payload already sent — never lands over the restored
files: the write holds a flock of its file's directory from before it reads
its payload through the rename, and refuses to install once the backup
holds a `.restored` flag; the restore takes both directories' flocks within
one 20-second wait, creates that flag, then copies. So either the write
renames first and the restore copies over it, or the restore flags first
and the write installs nothing. A restore that cannot take the flocks in
time, or cannot create the flag, reports that it failed and copies nothing.
The failure either says the previous files are back, or says the restore
failed or could not be confirmed and names the backup and the `cp -p` lines
that put it back by hand. If the new version will not come up healthy, the
backup is copied back **on the server** and the old version brought up
again — the restore is part of the same step rather than a round trip, so a
dropped connection cannot strand the proxy with the fix on the wrong
machine.

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
