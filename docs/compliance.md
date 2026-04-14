# Compliance Check — `hosting check`

Runs a set of structural/conventional checks against the current project so
the user knows it will behave sensibly when hosted. Runs locally (no SSH).

```
$ cd ~/projects/myapp
$ hosting check
Checking /home/you/projects/myapp

Structure:
  ✓ hosting.yml exists (schema 1)
  ✓ compose.yml or compose.prod.yml exists
  ✓ .env.prod.example exists
  ✓ .gitignore excludes .env

Compose:
  ✓ All services set restart policy
  ✓ All services set json-file logging with rotation
  ✓ Joins hosting-net (external)
  ✓ No `version:` field (deprecated)

Traefik:
  ✓ At least one service has traefik.enable=true
  ✓ At least one router references manifest domain (myapp.example.com)
  ✓ Routers declare entrypoints (web or websecure)
  ✓ Secure routers reference a certresolver

Healthchecks:
  ⚠ Service 'worker' has no HEALTHCHECK (warning only)

Env:
  ✓ .env.prod.example keys are syntactically valid
  ✓ .env (if present) matches .env.prod.example keys

Hooks:
  ✓ Every hook references a container defined in compose
  ✓ Backup hook: check + command + extension all set

Mail (if manifest has `mail:`):
  ✓ Domain matches an apex or subdomain of a known mail stack domain
    (this check only runs when --server is passed)

Summary: 12 passed, 1 warning, 0 failed
```

Exit code 0 if no failures (warnings are informational).

## Rule catalog

### Structure

| ID | Rule | Level |
|---|---|---|
| S01 | `hosting.yml` exists | fail |
| S02 | `hosting.yml` has valid schema version | fail |
| S03 | `compose.prod.yml` or `compose.yml` exists | fail |
| S04 | `.env.prod.example` exists | fail |
| S05 | `.gitignore` excludes `.env` | warn |
| S06 | `.gitignore` excludes `.hosting/` | warn |

### Compose

| ID | Rule | Level | Auto-fixable |
|---|---|---|---|
| C01 | Every service sets `restart: unless-stopped` (or stronger) | fail | yes |
| C02 | Every service has `logging.driver: json-file` with `max-size` + `max-file` | fail | yes |
| C03 | Every service joins `hosting-net` network | fail | yes |
| C04 | `hosting-net` declared `external: true` | fail | yes |
| C05 | No deprecated `version:` top-level field | warn | yes |
| C06 | Every service has `container_name` OR project uses compose's default naming | info | no |

### Traefik

| ID | Rule | Level |
|---|---|---|
| T01 | At least one service has `traefik.enable=true` | fail |
| T02 | At least one router rule references `manifest.domain` | fail |
| T03 | Routers declare `entrypoints` | fail |
| T04 | Routers on `websecure` reference `tls.certresolver=letsencrypt` | fail |
| T05 | No router uses reserved hosting names (`traefik.*`, `mail.*`) unless the project IS the mail/traefik owner | fail |

### Healthchecks

| ID | Rule | Level |
|---|---|---|
| H01 | Each custom-built service has a HEALTHCHECK in its Dockerfile or compose | warn |
| H02 | Manifest `health.container` exists among services | fail |

### Env

| ID | Rule | Level |
|---|---|---|
| E01 | `.env.prod.example` lines follow template syntax | fail |
| E02 | `.env` (if present) has no missing keys vs `.env.prod.example` | warn |
| E03 | `.env` (if present) has no extra keys vs `.env.prod.example` | warn |
| E04 | No obvious secret leaked into `.env.prod.example` (e.g. lines longer than 64 chars that aren't `!` commands) | warn |

### Hooks

| ID | Rule | Level |
|---|---|---|
| HK01 | Every hook's first word is a container_name from compose.yml | fail |
| HK02 | Backup hook has all required subfields (`check`, `command`, `extension`) | fail |
| HK03 | Backup hook's container exists among services | fail |

### Mail (only if `mail:` present in manifest)

| ID | Rule | Level |
|---|---|---|
| M01 | `domain` set | fail |
| M02 | `snappymail_domain` file exists (if set) and is valid JSON | fail |
| M03 | (with `--server` flag) Mail stack on VPS knows this domain | fail |

## `--fix` behavior

Only auto-fixable rules get applied. Never modifies `.env`. Never modifies
hook commands. Only edits `compose.prod.yml` and `hosting.yml` (with a
diff shown before writing).

Fixable today:
- C01, C02, C03, C04, C05 (compose hygiene)
- Adding `hosting_version` to manifest if missing

Unfixable (must be done by hand):
- Anything under Traefik (routing is policy, hosting can't guess)
- Hooks (hosting can't invent commands)
- Mail claims

## `hosting check --server USER@HOST`

Extended check that also queries the VPS:
- Does the project dir exist on VPS?
- Does `.env` on VPS match current `.env.prod.example`?
- Is the claimed mail domain known to the mail stack?
- Is the manifest's `health.container` currently healthy (if deployed)?
- Cert status for the project's `domain` in Traefik's `acme.json`.

Not run by default because it needs SSH and is slower. Useful as a
pre-deploy sanity check.

## Philosophy

The check is a linter, not a gatekeeper. `hosting deploy` does not implicitly
run `hosting check`. The user runs `hosting check` when they want it. This
keeps deploys fast and avoids the "tests passing but something weird on
prod" feedback lag.
