# Traefik — Shared Reverse Proxy

One Traefik instance per VPS, managed by hosting. All projects join the
`hosting-net` network and declare their own routing labels.

## Why shared

Per-project Traefik (as in the original project today) has a real cost on a multi-project
VPS:
- Port 80/443 can only be bound once — multiple Traefik instances are
  impossible anyway.
- Let's Encrypt rate-limits are per-certificate; sharing Traefik's
  `acme.json` avoids duplicate issuance when projects overlap on domains.
- Middlewares (HSTS, redirects, rate-limits) are identical in 90% of
  projects and shouldn't be duplicated.

## Ownership

The Traefik stack lives at `/apps/traefik/` on the VPS and is managed by
`hosting server init / status`. Users can customize `traefik.yml` and
`dynamic.yml` — hosting keeps backups before overwriting on upgrade.

## Network

```yaml
# /apps/traefik/compose.yml (excerpt)
networks:
  hosting-net:
    name: hosting-net
    driver: bridge
```

Every project joins this network as external:

```yaml
# /apps/<project>/compose.yml
networks:
  default:
    name: hosting-net
    external: true
```

Using `default:` avoids having to tag every service with `networks: - hosting-net`.

## Discovery

Traefik's docker provider scopes to `hosting-net`:

```yaml
providers:
  docker:
    exposedByDefault: false
    network: hosting-net
```

`exposedByDefault: false` means services must opt in with
`traefik.enable=true`. Safer default; fewer surprises.

## Labels a project adds

Minimum viable HTTPS routing for a project:

```yaml
labels:
  - "traefik.enable=true"

  # HTTP → HTTPS redirect
  - "traefik.http.routers.<svc>-http.rule=Host(`${DOMAIN}`)"
  - "traefik.http.routers.<svc>-http.entrypoints=web"
  - "traefik.http.routers.<svc>-http.middlewares=http-to-https@file"

  # HTTPS
  - "traefik.http.routers.<svc>.rule=Host(`${DOMAIN}`)"
  - "traefik.http.routers.<svc>.entrypoints=websecure"
  - "traefik.http.routers.<svc>.tls=true"
  - "traefik.http.routers.<svc>.tls.certresolver=letsencrypt"
  - "traefik.http.routers.<svc>.middlewares=security-headers@file,gzip-compression@file"

  # Service port (which container port Traefik forwards to)
  - "traefik.http.services.<svc>.loadbalancer.server.port=80"
```

Hosting's scaffolder (`hosting init-project`) writes this block for the
primary service, parameterized on `${DOMAIN}` (the manifest domain).

## Middlewares provided by hosting

Referenced via `@file` (they come from `dynamic.yml`):

| Name | Purpose |
|---|---|
| `http-to-https@file` | 301 redirect from :80 to :443 |
| `http-www-to-https-non-www@file` | www → apex at the HTTP level |
| `https-www-to-https-non-www@file` | www → apex at the HTTPS level |
| `security-headers@file` | HSTS, frame-deny, content-type-nosniff, CSP-report-only stub |
| `gzip-compression@file` | Response compression |
| `api-rate-limit@file` | 50 avg / 100 burst requests/sec |

Projects add project-specific middlewares inline as labels when they need
something bespoke.

## TLS

- ACME via HTTP-01 challenge (port 80 must be reachable).
- Stored in `/apps/data/traefik/letsencrypt/acme.json`, `chmod 600`.
- TLS options default to TLS 1.2–1.3 with modern cipher suites (ported
  from the original project's `dynamic.yml`).

## Dashboard

Enabled by default at `traefik.<init-domain>`, protected by basic auth
(hash generated during `hosting server init`). Hardened prod deployments
may want to remove the dashboard route — documented but not default.

## Health

Traefik has a compose healthcheck (`traefik healthcheck --ping`). `hosting
server status` surfaces it.

## What projects may NOT do

- Add routers for `traefik.<domain>` (reserved for the dashboard).
- Add routers for `mail.<domain>` or `webmail.<domain>` (reserved for the
  mail stack's cert-trigger and SnappyMail).
- Bind ports 80 or 443 on the host (they belong to Traefik).
- Replace the `hosting-net` network.

`hosting check` enforces these (rule T05).

## Upgrading Traefik

```
hosting server upgrade-traefik user@vps --version=v3.7
```

(Not v1; placeholder for roadmap.) For now, edit `/apps/traefik/compose.yml`
directly on the VPS and `docker compose up -d`.
