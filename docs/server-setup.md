# Server Setup

`hosting server init` prepares a VPS to host projects. It is deliberately
thin: it doesn't install packages and doesn't harden the system. It checks
prerequisites and lays out the folder structure that every later command
assumes.

## Prerequisites (checked, not installed)

| Requirement | Rationale | Failure mode |
|---|---|---|
| SSH with key auth to `user@host` | Every hosting operation is SSH-based | Hard fail, print ssh diagnostic |
| Docker ≥ 24 | `docker compose` v2 plugin required | Hard fail, link to docker docs |
| Docker Compose v2 | Manifest uses `include:` and modern syntax | Hard fail |
| The SSH user can run `docker` without sudo | Avoids mixed sudo/non-sudo ownership in `/apps/data/` | Hard fail, suggest `usermod -aG docker` |
| `rsync`, `openssl`, `gzip` available on remote | Used by deploy and env setup | Hard fail |

`hosting server init` does **not**:

- Install Docker or Compose (too opinionated; distros vary).
- Configure `ufw` or iptables.
- Edit `/etc/ssh/sshd_config`.
- Manage users or groups.

These are the VPS owner's responsibility.

## What init creates

Default paths (override with `--apps-path`, `--data-path`):

```
/apps/                               root owned by deploy user
├── data/                            bind-mount root for all projects
│   └── traefik/letsencrypt/
│       └── acme.json                touched as a file, chmod 600
├── backups/                         top-level backups (opt-in per project)
└── traefik/
    ├── compose.yml                  the shared Traefik stack
    ├── traefik.yml                  static config
    ├── dynamic.yml                  middlewares + TLS options
    ├── .env.prod.example
    └── .env                         generated interactively at init
```

`acme.json` is touched as an empty file before `docker compose up`. If Docker
sees a missing path on a bind mount, it silently creates a **directory**,
which breaks Traefik (and later breaks DMS when it tries to read the file).
Hosting's init loop prevents this.

## Traefik stack (ported from the original project, generalized)

### `traefik.yml` (static)

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    http:
      tls:
        options: default

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: hosting-net
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: <from .env>
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

api:
  dashboard: true

log:
  level: INFO

ping:
  entryPoint: "web"
```

### `dynamic.yml` (middlewares)

Ships baseline middlewares that any project can reference via `@file`:
- `http-to-https` — scheme redirect.
- `http-www-to-https-non-www`, `https-www-to-https-non-www` — apex canonicalization.
- `security-headers` — HSTS, frame-deny, CSP-report-only stub.
- `gzip-compression`.
- `api-rate-limit` (50 avg / 100 burst) — opt-in via project labels.

Projects may add their own middlewares in their own compose.yml labels; the
shared file provider is for things every project wants.

### Network

Created by the Traefik compose:

```yaml
networks:
  hosting-net:
    name: hosting-net
    driver: bridge
```

Projects declare `hosting-net` as `external: true`. Traefik discovers
project containers via labels.

## With mail (`--with-mail`)

Additionally scaffolds `/apps/mail/` with DMS + SnappyMail (ported from
the original project's mail/compose.yml). See `mail.md` for details.

Mail requires the main Traefik stack to be running first so that the
`mail.<domain>` cert-trigger router can issue an ACME cert; init handles
the ordering automatically.

## `hosting server status`

Read-only. Walks `/apps/`, asks docker for container health, reads
`versions.log` for each project, and prints:

```
VPS: user@vps (connected)
Docker: 27.3.1, Compose: 2.29.7
Root: /apps  Data: /apps/data  Disk: 41% used (168G free)

Traefik: running (healthy)
  Dashboard: https://traefik.example.com
  ACME email: you@example.com
  Certs: 4 issued (next renewal in 42d)

Mail: running (healthy)
  MX: mail.example.com
  Domains: example.com, shop.example.com

Projects:
  shop           running  v1.3.0   deployed 2026-04-01 (hosting 0.1.0)
  jellyfin       running  latest   deployed 2026-03-15 (hosting 0.1.0)
  paperless      stopped  latest   deployed 2026-02-10 (hosting 0.1.0)
```

## Idempotency rules

`hosting server init` can be re-run:
- Folders are `mkdir -p`.
- `acme.json` is only touched if missing.
- Traefik `.env` runs in drift-check mode (see `env-template.md`).
- Traefik is restarted only if the static config files changed.
- Adding `--with-mail` on re-run scaffolds mail without touching Traefik.

## Uninstall

There is no `hosting server uninstall` in v1. To remove hosting from a VPS:

```
ssh user@host 'cd /apps/<project> && docker compose down'   # per project
ssh user@host 'cd /apps/traefik && docker compose down'
ssh user@host 'rm -rf /apps'                                 # dangerous
```

This is intentional — an automated teardown is too easy to misfire.
