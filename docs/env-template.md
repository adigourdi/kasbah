# .env Template System

Descended from the original project's `scripts/setup-env.sh`, and the single biggest
friction-reducer on a first deploy. Kasbah owns the engine (`internal/env`, run on
the server as `kasbah remote setup-env`); projects own the template.

## Files

Per project:
- `.env.prod.example` — committed, template.
- `.env` — **not** committed, generated interactively (or from a seed file,
  below).

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
- Drift made only of missing keys, every one of them in `--env-seed=`'s file →
  no prompt: the setup fills those keys from the seed, every other line kept
  (below, Seeding the setup). An explicit `--on-drift=continue` or `abort`
  still wins.

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

With a seed that answers every new key, and no key the template dropped, the
menu is not shown: the run is *Configure new vars only*, from the seed.

## Restored from a backup

A `kasbah rollback` to a version the server holds a backup of can put that
version's `.env` back (`build-deploy.md` → rollback flow). The comparison is by
key, the last assignment of each winning, `\r` stripped from both files, the
`KASBAH_*` keys left out, values compared as written; only key names reach the
workstation. A whole restore writes the backup's `.env` byte for byte; a
per-key one keeps the server's file and, for each chosen key, replaces its
assignments with the backup's line, written as the backup holds it — in the
form a kasbah writer gave it then — adds that line at the end when the
server's file has none, or removes the key when the backup has none. Either is
written as the setup writes (staged beside the file and renamed, the mode kept
or `660` for a new file, under `.deploy.lock`), before the drift check against
the version's template and the managed block's refresh.

## Seeding the setup

`--env-seed=FILE` (`kasbah env`, `deploy`, `deploy X.Y.Z`, `rollback`) answers
the setup from a file the operator writes — one-off, never committed and never
written by kasbah:

```bash
# seed.env — chmod 600
DB_PASSWORD='an existing secret'
MAIL_HOST=smtp.example.com
export API_KEY=abc$$def
```

- Read as the setup reads a `.env`: `KEY=value` lines, optional leading blanks
  and `export `, blank lines and `#` comments skipped, a trailing CR stripped,
  the last assignment of a key winning. A value is **compose syntax**, written
  into `.env` as it stands — quote it, and write `$` as `$$`, as in `.env`
  itself: compose blanks a `$VAR` or `${VAR}` it cannot resolve, without a
  word. A value holding a bare `$` (not `$$`, outside single quotes) gets a
  warning naming its line number and key, never its value; the run goes on.
- Whenever the setup would ask a key `.env` does not set, the seed answers
  first: on a missing `.env` every key, on drift the keys `.env` lacks. A key it
  does not have is asked as usual. A key `.env` already sets is never touched
  — *Reconfigure all* still asks it. A `! command` key the seed answers does not
  run its generator.
- When nothing is left to ask, the setup needs no terminal (and runs over plain
  `ssh`); when something is, a run without a terminal stops with exit `5`
  naming the keys the seed lacks, and writes nothing. An `.env` already in sync
  is left alone. The same holds for a template with no key at all, seed or not.
- The setup names each key it answered from the seed and counts the seed's keys
  it did not use (already set, or not in the template); no value is ever
  printed.
- Refused on the workstation before anything connects: a file that is missing,
  not a regular file, open to group or others (mode `& 077`), empty or setting
  no key (comments only), over 256 KiB, with a value over 64 KiB (named by its
  key), with a line that is not `KEY=value` (named by its line number), or
  setting a `KASBAH_*` key (named by line number and key) — no refusal quotes
  a value.
- It reaches the server on stdin with its size and sha256, never on a command
  line. A setup without a terminal reads it on its own stdin: nothing but
  `.env` is written. A setup over `ssh -t` has the operator's terminal on its
  stdin, so the seed is first staged as
  `<apps>/<name>/.kasbah-env-seed.<token>` at mode `600` (`files.md`), under a
  token fresh to the run; the setup reads the file its token names, and only
  that one, and removes it before anything else. A workstation stopped
  between the staging and the setup leaves the file on the server until the
  first call of the next env step for that project, which removes every
  staged seed there, or `server destroy`.

## Sensitive value handling

**The template is required even when it declares nothing.** `S04` is a hard
fail: a project with no `.env.prod.example` does not pass `kasbah check`, and
there is no opt-out. For a project with no configuration at all — a static
bundle, say — the conforming shape is a **comment-only file**, which passes
E01, E04 and E05 (the key extractor yields nothing, so E05 has nothing to
object to). Its first deploy renders `.env` from it without a terminal, since
the setup has nothing to ask — as it does for any project whose every key
`--env-seed=` answers (Seeding the setup). Deploys come from a developer's
laptop by design (`overview.md` → No CI).

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
