# Compliance Check — `kasbah check`

Runs a set of structural/conventional checks against the current project so
the user knows it will behave sensibly when hosted. Runs locally (no SSH).

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
  ✓ Routed services join kasbah-net; internal services stay off it
  ✓ Services on kasbah-net are named for the project
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
  ✓ Mail pre-seed './mail/snappymail-domain.json' exists and parses
    (M03 — the stack on the VPS knows this domain — only runs with --server)

Summary: 22 passed, 1 warning, 0 failed
```

Exit code 0 if no failures (warnings are informational).

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

### Compose

| ID | Rule | Level | Auto-fixable |
|---|---|---|---|
| C01 | Every service sets `restart: unless-stopped` (or stronger) | fail | yes |
| C02 | Every service has `logging.driver: json-file` with `max-size` + `max-file` | fail | yes |
| C03 | Every Traefik-routed service (targeted by a fragment `loadBalancer` URL) joins `kasbah-net` | fail | yes |
| C04 | `kasbah-net` declared `external: true` | fail | yes |
| C05 | No deprecated `version:` top-level field | warn | yes |
| C06 | Every service has `container_name` OR project uses compose's default naming | info | no |
| C07 | No non-routed service joins `kasbah-net` — internal services use a project-internal network (service-name aliases on a shared network round-robin across projects) | fail | no |
| C08 | Every service with a `build:` key names an `image:` tagged `:current`. Deploy moves `<image>:current` and never rewrites compose, so a service pinned to `:1.2.3` keeps running the old image while the deploy reports success and changes nothing — the quietest failure in the tool. Silent on projects that build nothing | fail | yes |
| C09 | Every service on `kasbah-net` is named `<manifest.name>` or `<manifest.name>-*`. Compose registers the *service* name — not `container_name` — as a DNS alias on every network it joins, so a service called `web` claims the bare `web` alias on the network every project shares; two projects doing it leave two claimants and a third resolving `web` round-robins between them (measured: `aliases=[gbrev-web web]`). Latent rather than live, since Traefik targets `container_name`, which Docker keeps unique per host — hence warn. C07 already fails a non-routed service there, so in practice this bites the routed one. Silent — no line either way — on a project with no service on `kasbah-net` (nothing joins the shared network, so nothing can collide on it), and on the banned default-alias shape, where C07 has already failed on the shape and the fix is that, not a rename | warn | no |

### Resources

Hard limits only — reservations are banned. The values come from
kasbah-managed env vars (`KASBAH_CPU_LIMIT`, `KASBAH_MEM_LIMIT` — 90%
of host cores/RAM, computed at `server init`, injected into the project's
`.env` at deploy — see `server-setup.md`). Literal values are rejected so
limits scale with the host instead of fossilizing one VPS's numbers.

| ID | Rule | Level | Auto-fixable |
|---|---|---|---|
| R01 | Every service sets `cpus: ${KASBAH_CPU_LIMIT}` — missing or literal value fails | fail | yes |
| R02 | Every service sets `mem_limit: ${KASBAH_MEM_LIMIT}` — missing or literal value fails | fail | yes |
| R03 | No service declares resource `reservations` | fail | yes |
| R04 | (`--server`) Effective limit vs host size: above 90% fails; below 90% warns (deliberately tighter is allowed, but flagged) | fail/warn | no |

### Traefik

Rules parse `traefik-dynamic.yml` at the project root. `compose.prod.yml`
is also scanned: any `traefik.*` label is a hard fail (T06), since the
docker provider is not wired in.

| ID | Rule | Level |
|---|---|---|
| T01 | `traefik-dynamic.yml` exists and parses as YAML | warn |
| T02 | At least one router's `rule` references `manifest.domain` | fail |
| T03 | Every router declares `entryPoints` (non-empty list) | fail |
| T04 | Routers on `websecure` reference `tls.certResolver: letsencrypt` | fail |
| T05 | Project fragment's routers don't claim reserved hostnames (`traefik.<domain>`, `mail.<domain>`, `webmail.<domain>`) — those belong to kasbah-owned `_`-prefixed fragments. Implemented locally as a heuristic: any `Host(\`…\`)` whose first DNS label is `traefik`, `mail`, or `webmail` fails. Tightens to the exact server-apex match when `--server` mode lands. | fail |
| T06 | No service in `compose.prod.yml` carries `traefik.*` labels | fail |
| T07 | Every fragment `loadBalancer` server URL hostname matches an explicit `container_name` in `compose.prod.yml` | fail |
| T08 | Some router whose `rule` references `manifest.domain` declares the `web` entrypoint. The minimum viable form (`traefik.md` → Project fragment) is two routers for one hostname, the `websecure` one that serves it and a `web` one that redirects; T03 asks only that a router declare *some* entrypoint, so a fragment carrying the HTTPS half alone passes every other rule and answers plain HTTP with Traefik's 404. Warn, not fail: HTTPS-only is legitimate for an API nothing browses to, and the rule cannot tell that apart from the omission. Domain matching is T02's substring test | warn |

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

E02/E03 are not implemented here. They call `env_drift` in `lib/env.sh` —
the same function, in the same bytes, that runs on the VPS as
`scripts/setup-env.sh` during a deploy, so the local check and the remote
one cannot drift apart by agreeing to differ.

### Hooks

| ID | Rule | Level |
|---|---|---|
| HK01 | Every hook's first word is an explicit `container_name:` from compose.prod.yml (compose's auto-generated `<project>_<svc>_1` won't match) | fail |
| HK02 | Backup hook has all required subfields (`check`, `command`, `extension`) | fail |
| HK03 | Backup hook's container exists among services | fail |

### Mail (only if `mail:` present in manifest)

| ID | Rule | Level |
|---|---|---|
| M01 | `domain` set | fail |
| M02 | `snappymail_domain` file exists (if set) and is valid JSON. Checked with `jq`, not `yq`: JSON is a subset of YAML, so `{host: mail.example.com}` parses as YAML, is not JSON, and SnappyMail rejects it. It fails rather than warns because the deploy-time copy is **copy-if-missing** — a broken pre-seed that lands is the one SnappyMail keeps | fail |
| M03 | (with `--server` flag) Mail stack on VPS knows this domain | fail |

## `--fix` behavior

Only auto-fixable rules get applied. Never modifies `.env`. Never modifies
hook commands. Only edits `compose.prod.yml` and `kasbah.yml` (with a
diff shown before writing).

Fixable today:
- C01, C02, C03, C04, C05, C08 (compose hygiene — C08 is a mechanical tag rewrite)
- R01, R02, R03 (insert/replace limits with the `KASBAH_*` var references)
- Adding `kasbah_version` to manifest if missing

Unfixable (must be done by hand):
- C07 (moving services between networks is topology — kasbah won't guess)
- C09 (renaming a service drags `depends_on`, profiles and every in-project
  hostname with it — same reason)
- Anything under Traefik (routing is policy, kasbah can't guess)
- Hooks (kasbah can't invent commands)
- Mail claims

## `kasbah check --server USER@HOST`

Extended check that also queries the VPS:
- Does the project dir exist on VPS?
- Does `.env` on VPS match current `.env.prod.example`?
- Is the claimed mail domain known to the mail stack?
- Is the manifest's `health.container` currently healthy (if deployed)?
- Cert status for the project's `domain` in Traefik's `acme.json`.
- Effective resource limits vs host size (R04: above 90% fails, below warns).

Not run by default because it needs SSH and is slower. Useful as a
pre-deploy sanity check.

## Philosophy

The check is a linter, not a gatekeeper. `kasbah deploy` does not implicitly
run `kasbah check`. The user runs `kasbah check` when they want it. This
keeps deploys fast and avoids the "tests passing but something weird on
prod" feedback lag.
