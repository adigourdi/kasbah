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
What survives a re-run is exactly the three values init reads back out of
them: the dashboard domain, the ACME email, and the basic-auth hash.

Project fragments in `dynamic/<project>.yml` are a different matter — those
belong to their projects and init never touches them. Files you add under
`dynamic/` yourself survive too, provided they do not start with `_`, which
is kasbah's prefix. If you need to change what `traefik.yml` contains, the
change belongs in kasbah's template rather than on the server; otherwise
it lasts until the next init.

## Network

```yaml
# /apps/traefik/compose.yml (excerpt)
networks:
  kasbah-net:
    name: kasbah-net
    driver: bridge
```

Only the containers Traefik routes to join this network — explicitly, never
via the project's `default` network:

```yaml
# /apps/<project>/compose.yml
services:
  web:
    container_name: myapp-web
    networks: [kasbah-net, internal]
  postgres:
    networks: [internal]

networks:
  kasbah-net:
    external: true
  internal: {}
```

Why not put the whole project on `kasbah-net` via `default:`? Compose
registers every service's **service name** as a DNS alias on each network
it joins. On a shared network, two projects that each have a service called
`postgres` would both register the `postgres` alias — and Docker DNS
round-robins between them, so project A's app can silently connect to
project B's database. Keeping internal services on a project-internal
network scopes those aliases. `kasbah check` enforces the split (C03/C07).

**The split scopes the internal half only.** A *routed* service still carries
its service name as an alias on the shared `kasbah-net`, and nothing warns:
two projects that each call their routed service `web` both register `web`
there, and a third project resolving that bare name round-robins between them.
Only `container_name` is guaranteed unique, because Docker refuses a duplicate
outright — which is why fragments target it. Name routed services as
distinctly as their containers, or pin the alias with
`networks.kasbah-net.aliases:`.

The network is what lets Traefik resolve `http://<container_name>:<port>`
in the file fragment. Container names — unlike service-name aliases — are
unique per host (Docker refuses to start a duplicate), so fragments always
target `container_name` (T07).

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
- `_mail.yml` — cert-trigger + webmail routers. Only written when
  `--with-mail` is passed. See `mail.md`.

Project fragments are named `<manifest.name>.yml`. Filenames starting
with `_` belong to kasbah and get overwritten on
`kasbah server upgrade-traefik` — don't author your own `_`-prefixed files.

## Project fragment

Each project ships `traefik-dynamic.yml` at its repo root. `kasbah deploy`
rsyncs it directly to `/apps/traefik/dynamic/<manifest.name>.yml` — no
intermediate copy, no entry in the manifest's `sync:` list. Kasbah
handles it out-of-band, same as `setup-env.sh` and `remote-deploy.sh`.
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
        certResolver: letsencrypt
      middlewares: ["security-headers@file", "gzip-compression@file"]
      service: myapp

  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://myapp-web:80"
```

The service URL names a container on `kasbah-net`. Pin it via compose's
`container_name:` so the URL stays stable across restarts.

### Redirect-only router

A www→apex redirect with no backend:

```yaml
http:
  routers:
    myapp-www:
      rule: "Host(`www.myapp.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
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

- ACME via HTTP-01 challenge (port 80 must be reachable).
- Stored in `/apps/data/traefik/letsencrypt/acme.json`, `chmod 600`.
- TLS options default to TLS 1.2–1.3 with modern cipher suites
  (declared in `_shared.yml`).
- **Never compute a certificate's age from `notBefore`.** Let's Encrypt
  backdates it by roughly an hour — measured twice against Traefik's own log
  on synchronised clocks, both UTC: 58m32s and 58m31s. A certificate issued
  twelve seconds ago reads as an hour old, so anything deciding "is this
  fresh" (a future `check --server` cert rule, for one) must use the log, or
  treat anything under ~2 h as just issued.

### Which CA — production or staging

`kasbah server init --acme-staging` points the resolver at Let's Encrypt's
staging endpoint; without the flag it is production. Both are written into
`traefik.yml` as an explicit `caServer`, production included, so the file
always says which CA is in effect and a re-run decides by comparing one line
rather than by reasoning about a missing field.

```yaml
certificatesResolvers:
  letsencrypt:
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
after the new `traefik.yml` is in place and before the restart: `acme.json` is
bind-mounted as a file, so a running Traefik holds the old inode until it is
restarted.

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

Enabled by default at `traefik.<init-domain>`, protected by basic auth (hash
generated during `kasbah server init`). Both routers live in `_shared.yml`, not
the docker-provider API entrypoint, and there are two of them:

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

- **Deploy** — kasbah rsyncs `traefik-dynamic.yml` directly to
  `/apps/traefik/dynamic/<manifest.name>.yml`. Rsync writes temp + rename,
  so Traefik sees a single atomic replace event and reloads.
- **Rollback** — kasbah reads `traefik-dynamic.yml` from
  `git archive v<target>` and rsyncs it to the same destination.
- **Drop** (roadmap v0.3) — `rm /apps/traefik/dynamic/<manifest.name>.yml`
  before `docker compose down`. (`kasbah server destroy` deliberately
  leaves fragments in place — a handover keeps every site routing.)

## What projects may NOT do

- Use `traefik.*` labels in compose (the docker provider is not wired in).
- Add routers in their fragment for `traefik.<domain>` (reserved for the
  dashboard).
- Add routers in their fragment for `mail.<domain>` or `webmail.<domain>`
  (claimed by kasbah's `_mail.yml` — cert-trigger and SnappyMail).
- Bind ports 80 or 443 on the host (they belong to Traefik).
- Replace the `kasbah-net` network.
- Attach non-routed services (databases, caches, workers) to `kasbah-net` —
  internal services stay on a project-internal network.

`kasbah check` enforces these (rules T01–T07, C07).

## Upgrading Traefik

```
kasbah server upgrade-traefik user@vps --version=v3.7
```

(Roadmap v0.3.) Until then, change the pinned tag in kasbah's own
`templates/traefik/compose.yml` and re-run `kasbah server init` — **not**
the copy on the VPS. `compose.yml` is one of the three kasbah-owned files
init re-ships whenever its bytes differ, so an edit made on the server is
reverted by the next init, without a backup and without a warning.
