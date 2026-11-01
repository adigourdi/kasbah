# .env Template System

Descended from the original project's `scripts/setup-env.sh`, and the single biggest
friction-reducer on a first deploy. Kasbah owns the engine (`internal/env`, run on
the server as `kasbah remote setup-env`); projects own the template.

## Files

Per project:
- `.env.prod.example` — committed, template.
- `.env` — **not** committed, generated interactively.

`kasbah env` syncs `.env.prod.example` to the VPS itself. `kasbah deploy`
does not: the template reaches the server through the manifest's `sync:` list
like any other project file, which is why the deploy path has a branch telling
the operator to add it there. Either way the setup runs on the server when
`.env` is missing or drifts from the template — `kasbah remote setup-env`, in the
kasbah binary, for both.

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

A template default taken with Enter is compose syntax already: it is written as
it stands, with `$` as `$$` so docker-compose does not interpolate it. A kept
value (untouched by an update) is written as it stands, since it was written
right the first time. A **typed or generated value is literal text**, written
in the form compose reads back exactly: bare with `$` as `$$` when nothing in it
needs quoting; single-quoted when it has blanks at either end, starts with a
quote or holds ` #` — and holds no `'` and does not end in `\`; otherwise
double-quoted, with `\` and `"` escaped and `$` as `$$`. A line break or NUL is
refused. A trailing CR in a typed answer is dropped. `kasbah env set` writes
the same way.
A `! command` generator runs in `bash --norc --noprofile` and sees `KEY`,
`TARGET_DIR`, `EXAMPLE` and `OUTPUT`, not the setup's functions.

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

Run on every `kasbah deploy` by the env engine's drift report (`internal/env`,
`kasbah remote setup-env drift` on the server), which works like this:

It reports two key lists: the keys the template has and `.env` lacks (missing),
and the keys `.env` has and the template lacks (extra).

A line counts as setting a key if Compose would read it as one: optional
leading blanks and an optional `export ` prefix, which `docker compose config`
honours and which kasbah therefore honours everywhere it reads a `.env` or a
template. The consequence is accepted rather than worked around — regenerating
`.env` rewrites `export FOO=x` as `FOO=x`, since the file is rebuilt from the
template wholesale. A reader that only matched column 0 would report a live
`export APP_KEY=…` as *missing*, and the setup would then overwrite it with the
template default.

Both lists are empty when in sync.

Outcomes:
- both empty → in sync, continue silently.
- `.env` missing → launch interactive setup.
- Any drift → warn, prompt: *"re-run setup" / "continue with current .env" /
  "abort"* — scriptable as `--on-drift=setup|continue|abort`.

One implementation serves `kasbah check` (E02/E03), `kasbah env`, `kasbah env set` and `deploy`:
the Go engine, on the workstation and as `kasbah remote setup-env` on the server.

Keys prefixed `KASBAH_` are reserved: kasbah injects and refreshes them
at deploy (resource limits — see `server-setup.md`). They are excluded from
**both** sides of the comparison, in both directions — reserved keys extra in
`.env` and reserved keys missing from it are equally not drift — and are never
prompted for. A template that declares one is warned about by E05.

## The kasbah-managed block

Injection writes the reserved keys into a sentinel-delimited block:

```
# >>> kasbah managed block - do not edit, rewritten on every deploy >>>
KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=54g
# <<< kasbah managed block <<<
```

Rules, all of them load-bearing:

- The block is rewritten **where it already stands**, never moved to the end.
  Every other line survives byte-for-byte in its original order, comments,
  blank lines and hand-spacing included — users edit this file.
- **Any line outside the block that Compose would read as assigning a
  `KASBAH_*` variable is removed.** Compose honours a leading-whitespace
  assignment and an `export ` prefix, and takes the *last* assignment — so a
  stray below the block would silently outrank the server marker. The match is
  anchored (optional blanks, optional `export `) and never a substring: a
  user's own `MY_KASBAH_URL` is not kasbah's to delete.
- The values are the server marker's ceilings, or the project's own from
  `kasbah.yml`'s `resources:`, resolved on the server before the env step and
  held to those ceilings (`project-manifest.md` → `resources`) — per half, so
  a manifest setting only `memory` keeps the marker's `KASBAH_CPU_LIMIT`.
- Values are written through unchanged. A `0` limit stays `0` — the rig cannot
  apply cgroup limits at all, and injection must keep working when the values
  it writes are ones the host cannot honour.
- Idempotent: the second run is byte-identical to the first. The one
  normalisation is a trailing newline on a file that lacked one, since the
  block has to start on its own line.

**Inject after setup, never before.** `env_setup_run` builds its output from
the template, and the template has no reserved keys — so regenerating `.env`
drops the block entirely, and `compose up` then fails on an unset
`KASBAH_CPU_LIMIT` until injection runs again.

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

**The template is required even when it declares nothing.** `S04` is a hard
fail: a project with no `.env.prod.example` does not pass `kasbah check`, and
there is no opt-out. For a project with no configuration at all — a static
bundle, say — the conforming shape is a **comment-only file**, which passes
E01, E04 and E05 (the key extractor yields nothing, so E05 has nothing to
object to). Note what that does not buy you: the first deploy still runs the
interactive env setup over `ssh -t` to render `.env` from it, and
`--on-drift=` does not reach the missing-`.env` case — so a first deploy needs
a terminal even for a project with zero variables. Deploys come from a
developer's laptop by design (`overview.md` → No CI).

- `*_PASSWORD`, `*_SECRET`, `*_KEY` are masked in displays and read via
  `read -rs` (no echo).
- Defaults from the template are never printed in clear for these keys
  when regenerating.
- The `! command` form runs in a subshell when Enter is pressed; the
  generated value is stored directly. Useful for:
  - `! docker run --rm alpine …` (random strings, no local deps)
  - `! echo "base64:$(docker run --rm alpine sh -c 'head -c 32 /dev/urandom | base64')"`
  - `! read -rsp "Password: " P && echo >&2 && printf '%s\n' "$P" | docker run --rm -i httpd:2-alpine htpasswd -niB user | cut -d: -f2`
    — `-niB` reads the password on stdin; `-nbB` would put it in argv, where
    the process table exposes it to every other user of the machine.

## Testing

`internal/env`'s tests drive the engine with fixtures and piped answers and
assert the resulting `.env`; `internal/env/testdata/frozen.json` pins 78 cases
carried over from the original suite.

Coverage:
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

## Where it runs

The setup, the drift report and the managed block are Go, in the kasbah binary:
on the workstation for `kasbah check`, on the server as `kasbah remote setup-env`.
