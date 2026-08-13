# Traefik — Shared Reverse Proxy

One Traefik instance per VPS, managed by hosting. Projects declare their
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
labels; `hosting check` rejects them.

## Ownership

The Traefik stack lives at `/apps/traefik/` on the VPS and is managed by
`hosting server init / status`. Users can customize `traefik.yml` and the
files under `dynamic/` — hosting keeps backups before overwriting on upgrade.

## Network

```yaml
# /apps/traefik/compose.yml (excerpt)
networks:
  hosting-net:
    name: hosting-net
    driver: bridge
```

Only the containers Traefik routes to join this network — explicitly, never
via the project's `default` network:

```yaml
# /apps/<project>/compose.yml
services:
  web:
    container_name: myapp-web
    networks: [hosting-net, internal]
  postgres:
    networks: [internal]

networks:
  hosting-net:
    external: true
  internal: {}
```

Why not put the whole project on `hosting-net` via `default:`? Compose
registers every service's **service name** as a DNS alias on each network
it joins. On a shared network, two projects that each have a service called
`postgres` would both register the `postgres` alias — and Docker DNS
round-robins between them, so project A's app can silently connect to
project B's database. Keeping internal services on a project-internal
network scopes those aliases. `hosting check` enforces the split (C03/C07).

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

Hosting-owned fragments (written by `hosting server init`):
- `_shared.yml` — middlewares, TLS options, dashboard router.
- `_mail.yml` — cert-trigger + webmail routers. Only written when
  `--with-mail` is passed. See `mail.md`.

Project fragments are named `<manifest.name>.yml`. Filenames starting
with `_` belong to hosting and get overwritten on
`hosting server upgrade-traefik` — don't author your own `_`-prefixed files.

## Project fragment

Each project ships `traefik-dynamic.yml` at its repo root. `hosting deploy`
rsyncs it directly to `/apps/traefik/dynamic/<manifest.name>.yml` — no
intermediate copy, no entry in the manifest's `sync:` list. Hosting
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

The service URL names a container on `hosting-net`. Pin it via compose's
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

## Middlewares provided by hosting

Referenced via `@file` from `_shared.yml`:

| Name | Purpose |
|---|---|
| `http-to-https@file` | 301 redirect from :80 to :443 |
| `http-www-to-https-non-www@file` | www → apex at the HTTP level |
| `https-www-to-https-non-www@file` | www → apex at the HTTPS level |
| `security-headers@file` | HSTS, frame-deny, content-type-nosniff, CSP-report-only stub |
| `gzip-compression@file` | Response compression |
| `api-rate-limit@file` | 50 avg / 100 burst requests/sec |

Project-specific middlewares go in the same project fragment under
`http.middlewares.<name>`.

## TLS

- ACME via HTTP-01 challenge (port 80 must be reachable).
- Stored in `/apps/data/traefik/letsencrypt/acme.json`, `chmod 600`.
- TLS options default to TLS 1.2–1.3 with modern cipher suites
  (declared in `_shared.yml`).

## Dashboard

Enabled by default at `traefik.<init-domain>`, protected by basic auth
(hash generated during `hosting server init`). The dashboard router lives
in `_shared.yml`, not the docker-provider API entrypoint.

## Health

Traefik has a compose healthcheck (`traefik healthcheck --ping`). `hosting
server status` surfaces it.

## Lifecycle on deploy / rollback / drop

- **Deploy** — hosting rsyncs `traefik-dynamic.yml` directly to
  `/apps/traefik/dynamic/<manifest.name>.yml`. Rsync writes temp + rename,
  so Traefik sees a single atomic replace event and reloads.
- **Rollback** — hosting reads `traefik-dynamic.yml` from
  `git archive v<target>` and rsyncs it to the same destination.
- **Drop** (roadmap v0.3) — `rm /apps/traefik/dynamic/<manifest.name>.yml`
  before `docker compose down`. (`hosting server destroy` deliberately
  leaves fragments in place — a handover keeps every site routing.)

## What projects may NOT do

- Use `traefik.*` labels in compose (the docker provider is not wired in).
- Add routers in their fragment for `traefik.<domain>` (reserved for the
  dashboard).
- Add routers in their fragment for `mail.<domain>` or `webmail.<domain>`
  (claimed by hosting's `_mail.yml` — cert-trigger and SnappyMail).
- Bind ports 80 or 443 on the host (they belong to Traefik).
- Replace the `hosting-net` network.
- Attach non-routed services (databases, caches, workers) to `hosting-net` —
  internal services stay on a project-internal network.

`hosting check` enforces these (rules T01–T07, C07).

## Upgrading Traefik

```
hosting server upgrade-traefik user@vps --version=v3.7
```

(Roadmap v0.3.) For now, edit `/apps/traefik/compose.yml` directly on
the VPS and `docker compose up -d`.
