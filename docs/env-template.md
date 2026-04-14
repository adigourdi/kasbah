# .env Template System

Ported verbatim from the original project's `scripts/setup-env.sh`. It works well, has
tests, and is the single biggest friction-reducer on a first deploy. The only
change is packaging: hosting owns the script, projects own the template.

## Files

Per project:
- `.env.prod.example` — committed, template.
- `.env` — **not** committed, generated interactively.

Hosting syncs `.env.prod.example` to the VPS on every deploy and runs
`setup-env.sh` there when `.env` is missing or drifts from the template.

## Template conventions

Any line in `.env.prod.example` is one of:

| Form | Meaning | Prompt behavior |
|---|---|---|
| `VAR=value` | Default value | `[value]`, Enter accepts |
| `VAR=` | No default | blank prompt, Enter → empty |
| `VAR=# hint text` | Hint (no default) | shows `(hint text)`, user must type |
| `VAR=! command` | Auto-generator | `(auto)`, Enter runs command |
| `VAR=value # comment` | Default + inline hint | `[value] (comment)`, Enter accepts |
| `# === Section ===` | Section header | rendered bold during prompts, preserved in output |
| `# free-form comment` | Preserved in output | shown dimly during prompt |

Values are escaped on the way out: `$` becomes `$$` so docker-compose
doesn't interpret it.

Sensitive vars (`KEY`, `PASSWORD`, `SECRET` in the name) are masked during
input (`****` display, `read -rs`).

### Example template

```bash
# =============================================================================
# MyApp — Production Configuration
# =============================================================================

# --- Domain ---
DOMAIN=myapp.example.com
APP_URL=https://myapp.example.com # Full URL with https

# --- Database ---
DB_HOST=postgres
DB_NAME=myapp_db
DB_USER=myapp
DB_PASSWORD=! docker run --rm alpine sh -c 'tr -dc A-Za-z0-9 </dev/urandom | head -c 32'

# --- Mail ---
MAIL_HOST=# Your SMTP host
MAIL_USER=# SMTP login (leave empty to disable mail)
MAIL_PASSWORD=# SMTP password

# --- Optional ---
DEBUG_TOKEN=
```

Conventions used here:
- `DOMAIN` has a concrete default.
- `APP_URL` has a default with inline guidance (`# Full URL with https`).
- `DB_PASSWORD` auto-generates via docker (works anywhere docker does — no
  dep on local openssl/python).
- `MAIL_*` are pure hints (user must provide or leave empty).
- `DEBUG_TOKEN` is optional; Enter leaves it empty.

### Section headers

Lines matching `^# *[-=]{3,}` are treated as section headers — printed bold
between value prompts to give structure to long `.env` files. Preserved in
the output `.env`.

## Drift detection

Run on every `hosting deploy` before touching anything:

```bash
EXAMPLE_KEYS=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env.prod.example | cut -d= -f1 | sort)
LIVE_KEYS=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | cut -d= -f1 | sort)
MISSING=$(comm -23 <(echo "$EXAMPLE_KEYS") <(echo "$LIVE_KEYS"))
EXTRA=$(comm -13 <(echo "$EXAMPLE_KEYS") <(echo "$LIVE_KEYS"))
```

Outcomes:
- `MISSING=`, `EXTRA=` → in sync, continue silently.
- `.env` missing → launch interactive setup.
- Any drift → warn, prompt: *"re-run setup" / "continue with current .env" /
  "abort"*.

## Update modes

When `.env` exists, setup offers three modes:

- **Enter** — *Configure new vars only*: auto-accepts existing values for
  known keys, prompts only for new ones (added to the template since last
  generation). Drops keys no longer in the template.
- **`a`** — *Reconfigure all*: re-prompts every variable, existing values
  become defaults.
- **`q`** — *Abort*: `.env` untouched.

If there's no drift (i.e. user ran setup just for the sake of it), a shortcut
prompt asks whether to re-configure anyway; default is no.

## Sensitive value handling

- `*_PASSWORD`, `*_SECRET`, `*_KEY` are masked in displays and read via
  `read -rs` (no echo).
- Defaults from the template are never printed in clear for these keys
  when regenerating.
- The `! command` form runs in a subshell when Enter is pressed; the
  generated value is stored directly. Useful for:
  - `! docker run --rm alpine …` (random strings, no local deps)
  - `! echo "base64:$(docker run --rm alpine sh -c 'head -c 32 /dev/urandom | base64')"`
  - `! read -rsp "Password: " P && echo >&2 && echo "user:$(docker run --rm httpd:alpine htpasswd -nbB user "$P" | cut -d: -f2)"`

## Testing

The port keeps `test-setup-env.sh` from the original project. It builds fixtures,
pipes stdin, and asserts the resulting `.env`. Runs in CI (or `./test.sh`).

Coverage (preserved from the original project):
- First run — accept defaults
- First run — custom values
- Update only — new var accepts default / custom value
- Dropped vars removed
- Mixed — new + dropped
- No drift — early exit, unchanged
- Abort with `q`
- Reconfigure all — existing values become defaults
- Structure preserved (comments, sections, blank lines)
- Hint / Comment / Empty types

## Why this stays in bash

The template parser is 200 lines of bash and already battle-tested. Porting
it to Go would cost more than it buys — the interactivity is the value, not
the parsing.
