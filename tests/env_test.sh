#!/usr/bin/env bash
# Test: lib/env.sh — the interactive .env generator.
#
# Every case drives the file the way the VPS does: `bash lib/env.sh <dir>` with
# the answers on stdin. The stdin accounting is load-bearing — the update menu
# reads exactly one character (`read -r -n 1`) and the no-drift shortcut reads
# one too, so a case that feeds one newline too many passes for the wrong
# reason.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
env_sh="$repo_dir/lib/env.sh"

# The masked-read case needs a real pty: `read -rs` suppressing the echo is the
# terminal's doing, and a pipe cannot tell it from `read -r`.
if ! command -v script >/dev/null 2>&1; then
    echo "script(1) is required to prove the masked read does not echo" >&2
    exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Colour is decided by [ -t 1 ], true behind the pty; the escapes would then
# break the substring matches on the prompt transcript.
export NO_COLOR=1

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- Assertions over a generated .env -----------------------------------------
expect_kv() {
    local file="$1" key="$2" want="$3" desc="$4" got
    got=$(grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-)
    if [ "$got" != "$want" ]; then
        echo "  FAIL: $desc (expected '$want', got '$got')" >&2
        fail=1
    fi
}

expect_absent() {
    local file="$1" key="$2" desc="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        echo "  FAIL: $desc" >&2
        fail=1
    fi
}

expect_same() {
    if ! cmp -s "$1" "$2"; then
        echo "  FAIL: $3" >&2
        fail=1
    fi
}

# --- Drivers ------------------------------------------------------------------
# run_env <stdin> <dir> — sets out (stdout+stderr merged) and rc.
#
# stdin comes from a file, never a pipe. Under pipefail a pipe would hand back
# the producer's SIGPIPE (141) whenever the script returns without draining its
# input — which is exactly what the abort, no-drift and EOF cases do, and they
# are the cases that assert on rc. A here-string is no good either: it appends
# a newline, and the one-character menu reads count every byte.
run_env() {
    printf '%s' "$1" > "$tmpdir/stdin"
    out=$(bash "$env_sh" "$2" < "$tmpdir/stdin" 2>&1)
    rc=$?
}

# run_env_tty <stdin> <dir> <prompt-to-wait-for> [env-prefix...]
#
# Same, behind a pty. script(1) merges the session into one stream and turns
# every \n into \r\n, hence the strip. Input is withheld until the transcript
# shows the prompt: terminal echo belongs to the pty, so anything written
# before the program disables it is echoed regardless, and "the secret was not
# echoed" would otherwise pass or fail on how loaded the machine is. Polling
# the transcript rather than sleeping a fixed interval is what makes that
# adaptive; the 50 ms grace covers only the gap between the prompt reaching the
# pty and read(1) turning echo off.
run_env_tty() {
    local input="$1" dir="$2" wait_for="$3"; shift 3
    local cmd ts fifo i
    ts="$tmpdir/tty-out"; fifo="$tmpdir/tty-in"
    rm -f "$ts" "$ts.rc" "$fifo"
    : > "$ts"
    mkfifo "$fifo"
    cmd="$(printf '%q ' "$@" bash "$env_sh" "$dir")"
    # -f: without it script buffers the transcript to exit and the poll below
    # can never see the prompt.
    ( timeout 30 script -qfec "$cmd" "$ts" < "$fifo" >/dev/null 2>&1; echo $? > "$ts.rc" ) &
    local runner=$!
    exec 9>"$fifo"
    for ((i = 0; i < 400; i++)); do
        grep -qF -- "$wait_for" "$ts" 2>/dev/null && break
        sleep 0.05
    done
    sleep 0.05
    printf '%s' "$input" >&9
    exec 9>&-
    wait "$runner"
    tty_rc=$(cat "$ts.rc")
    tty_out=$(cat "$ts")
    tty_out=${tty_out//$'\r'/}
}

newdir() {
    local d="$tmpdir/$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

basic_template() {
    cat > "$1/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
APP_DEBUG=false
TMPL
}

# --- Case 1: first run, accept every default ----------------------------------
d=$(newdir t1); basic_template "$d"
run_env $'\n\n\n' "$d"
assert '[ "$rc" = "0" ]' "a first run exits 0 (got $rc)"
expect_kv "$d/.env" APP_NAME  MyApp "first run — Enter accepts the template default"
expect_kv "$d/.env" APP_PORT  3000  "first run — numeric default accepted"
expect_kv "$d/.env" APP_DEBUG false "first run — third default accepted"

# --- Case 2: first run, custom values -----------------------------------------
d=$(newdir t2); basic_template "$d"
run_env $'CustomApp\n8080\ntrue\n' "$d"
expect_kv "$d/.env" APP_NAME  CustomApp "first run — a typed value overrides the default"
expect_kv "$d/.env" APP_PORT  8080      "first run — second typed value lands"
expect_kv "$d/.env" APP_DEBUG true      "first run — third typed value lands"

# --- Case 3: update only, new var accepts its default -------------------------
d=$(newdir t3)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
APP_DEBUG=false
NEW_VAR=new_default
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
ENV
# Enter (the update-only menu choice) + Enter (accept NEW_VAR's default)
run_env $'\n\n' "$d"
expect_kv "$d/.env" APP_NAME  existing_app "update only — a known key keeps its live value"
expect_kv "$d/.env" APP_PORT  8080         "update only — second known key kept"
expect_kv "$d/.env" APP_DEBUG true         "update only — third known key kept"
expect_kv "$d/.env" NEW_VAR   new_default  "update only — the new key takes the template default"
assert '! grep -qF "APP_NAME [" <<<"$out"' "update only — known keys are never prompted for (said '$out')"

# --- Case 4: update only, new var with a typed value --------------------------
d=$(newdir t4)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
NEW_VAR=default_x
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
ENV
run_env $'\ncustom_x\n' "$d"
expect_kv "$d/.env" APP_NAME existing_app "update only (typed) — known key kept"
expect_kv "$d/.env" APP_PORT 8080         "update only (typed) — second known key kept"
expect_kv "$d/.env" NEW_VAR  custom_x     "update only — a typed value for the new key lands"

# --- Case 5: dropped vars are removed -----------------------------------------
d=$(newdir t5); basic_template "$d"
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
OLD_VAR=stale
LEGACY_KEY=old
ENV
run_env $'\n' "$d"
expect_kv     "$d/.env" APP_NAME existing_app "dropped vars — surviving key keeps its value"
expect_kv     "$d/.env" APP_PORT 8080         "dropped vars — second surviving key kept"
expect_absent "$d/.env" OLD_VAR               "a key no longer in the template is dropped"
expect_absent "$d/.env" LEGACY_KEY            "a second dropped key is dropped too"

# --- Case 6: mixed — new added, dropped removed -------------------------------
d=$(newdir t6)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
NEW_FEAT=on
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
OLD_VAR=stale
ENV
run_env $'\n\n' "$d"
expect_kv     "$d/.env" APP_NAME existing_app "mixed — known key kept"
expect_kv     "$d/.env" APP_PORT 8080         "mixed — second known key kept"
expect_kv     "$d/.env" NEW_FEAT on           "mixed — new key added with its default"
expect_absent "$d/.env" OLD_VAR               "mixed — dropped key removed"

# --- Case 7: no drift, early exit, .env untouched -----------------------------
d=$(newdir t7); basic_template "$d"
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
ENV
cp "$d/.env" "$d/.env.backup"
# Enter = the default N of "Reconfigure all vars? [y/N]"
run_env $'\n' "$d"
assert '[ "$rc" = "0" ]' "no drift exits 0 (got $rc)"
assert 'grep -qF "up to date" <<<"$out"' "no drift says the .env is up to date (said '$out')"
expect_same "$d/.env" "$d/.env.backup" "no drift leaves .env byte-identical"

# --- Case 8: abort with q ------------------------------------------------------
d=$(newdir t8)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
NEW_VAR=x
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
ENV
cp "$d/.env" "$d/.env.backup"
run_env 'q' "$d"
assert '[ "$rc" = "0" ]' "abort exits 0 (got $rc)"
assert 'grep -qF "Aborted." <<<"$out"' "abort says so (said '$out')"
expect_same "$d/.env" "$d/.env.backup" "abort leaves .env byte-identical"

# --- Case 9: reconfigure all — existing values become the defaults ------------
d=$(newdir t9)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
APP_PORT=3000
NEW_VAR=default_new
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
ENV
# `a` is consumed whole by `read -n 1`; the three newlines then accept each
# var's default in turn.
run_env $'a\n\n\n' "$d"
expect_kv "$d/.env" APP_NAME existing_app "reconfigure all — the live value is the default"
expect_kv "$d/.env" APP_PORT 8080         "reconfigure all — second live value is the default"
expect_kv "$d/.env" NEW_VAR  default_new  "reconfigure all — a key with no live value falls back to the template"
assert 'grep -qF "APP_NAME [existing_app]" <<<"$out"' "reconfigure all prompts for known keys (said '$out')"

# --- Case 10: structure preserved ---------------------------------------------
d=$(newdir t10)
cat > "$d/.env.prod.example" <<'TMPL'
# =============================================================================
# My App Config
# =============================================================================

# --- Database ---
DB_HOST=localhost
DB_PORT=5432

# --- Cache ---
CACHE_TTL=3600
TMPL
run_env $'\n\n\n' "$d"
assert 'grep -q "^# My App Config" "$d/.env"'      "a free-form comment survives into .env"
assert 'grep -q "^# --- Database ---" "$d/.env"'   "a section header survives into .env"
assert 'grep -q "^# --- Cache ---" "$d/.env"'      "a second section header survives"
assert '[ "$(grep -c "^$" "$d/.env")" = "2" ]'     "both blank lines survive (got $(grep -c "^$" "$d/.env"))"
expect_kv "$d/.env" DB_HOST   localhost "structure — first value still written"
expect_kv "$d/.env" CACHE_TTL 3600      "structure — last value still written"

# --- Case 11: hint type (VAR=# hint) ------------------------------------------
d=$(newdir t11)
cat > "$d/.env.prod.example" <<'TMPL'
# --- Mail ---
MAIL_HOST=smtp.example.com
MAIL_USER=# Your SMTP username
MAIL_PASS=# Your SMTP password
NEW_HINT=# Enter a value
TMPL
cat > "$d/.env" <<'ENV'
MAIL_HOST=smtp.brevo.com
MAIL_USER=me@example.com
MAIL_PASS=secret123
ENV
run_env $'\nmy_value\n' "$d"
expect_kv "$d/.env" MAIL_HOST smtp.brevo.com  "hint type — unrelated key kept"
expect_kv "$d/.env" MAIL_USER me@example.com  "hint type — a hint key's live value is kept"
expect_kv "$d/.env" MAIL_PASS secret123       "hint type — second hint key kept"
expect_kv "$d/.env" NEW_HINT  my_value        "hint type — a new hint key takes what was typed"
assert 'grep -qF "NEW_HINT (Enter a value)" <<<"$out"' "the hint text is shown, not stored (said '$out')"

# --- Case 12: default with an inline comment (VAR=value # comment) ------------
d=$(newdir t12)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_URL=https://example.com # Full URL with https
SESSION_DOMAIN=example.com # Without https
TMPL
run_env $'\n\n' "$d"
expect_kv "$d/.env" APP_URL        https://example.com "inline comment — only the value side becomes the default"
expect_kv "$d/.env" SESSION_DOMAIN example.com         "inline comment — second value side"
assert 'grep -qF "APP_URL [https://example.com] (Full URL with https)" <<<"$out"' \
       "inline comment — the comment is shown beside the default (said '$out')"

# --- Case 13: empty value type (VAR=) -----------------------------------------
d=$(newdir t13)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
OPTIONAL_VAR=
NEW_ONE=n_default
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=existing
OPTIONAL_VAR=
ENV
run_env $'\n\n' "$d"
expect_kv "$d/.env" APP_NAME     existing  "empty type — unrelated key kept"
expect_kv "$d/.env" OPTIONAL_VAR ""        "an empty value round-trips as empty"
expect_kv "$d/.env" NEW_ONE      n_default "empty type — the new key still gets its default"
# An existing key whose value is empty is *set*, not absent: update mode must
# auto-accept it rather than ask, or every optional var is re-prompted forever.
assert '! grep -qF "OPTIONAL_VAR" <<<"$out"' "an existing empty value counts as set and is not re-prompted (said '$out')"

# A first run over the same shape: Enter on an empty prompt stays empty.
d=$(newdir t13b)
cat > "$d/.env.prod.example" <<'TMPL'
OPTIONAL_VAR=
TMPL
run_env $'\n' "$d"
expect_kv "$d/.env" OPTIONAL_VAR "" "first run — Enter on an empty prompt yields an empty value"

# --- Case 14: the ! generator --------------------------------------------------
d=$(newdir t14)
cat > "$d/.env.prod.example" <<'TMPL'
# --- Gen ---
GEN_TOKEN=! echo generated-value
TMPL
run_env $'\n' "$d"
expect_kv "$d/.env" GEN_TOKEN generated-value "Enter on a ! generator runs the command"
assert 'grep -qF "GEN_TOKEN (auto)" <<<"$out"' "a generator prompt is marked (auto) (said '$out')"

# A live value outranks the generator: the command must not run again.
d=$(newdir t14b)
cat > "$d/.env.prod.example" <<'TMPL'
GEN_TOKEN=! echo generated-value
TMPL
cat > "$d/.env" <<'ENV'
GEN_TOKEN=old-value
ENV
# y = reconfigure anyway (no drift), then Enter on GEN_TOKEN
run_env $'y\n\n' "$d"
expect_kv "$d/.env" GEN_TOKEN old-value "a generator does not re-run over an existing value"

# A typed value outranks both.
d=$(newdir t14c)
cat > "$d/.env.prod.example" <<'TMPL'
GEN_TOKEN=! echo generated-value
TMPL
run_env $'typed-value\n' "$d"
expect_kv "$d/.env" GEN_TOKEN typed-value "a typed value outranks the ! generator"

# --- Case 15: $ is escaped to $$ for docker compose ----------------------------
# Untested upstream, and load-bearing: compose interpolates a single $ in .env.
d=$(newdir t15)
cat > "$d/.env.prod.example" <<'TMPL'
LITERAL=
DEF_DOLLAR=cost$5
TMPL
run_env $'a$b\n\n' "$d"
expect_kv "$d/.env" LITERAL    'a$$b'   "a typed \$ is doubled on the way out"
expect_kv "$d/.env" DEF_DOLLAR 'cost$$5' "a \$ in a template default is doubled too"

# --- Case 16: sensitive keys are masked in the display -------------------------
# The match is a substring, so MONKEY_COUNT is masked. That is the shipped
# behaviour and it is pinned here so nobody "fixes" it into a suffix match.
d=$(newdir t16)
cat > "$d/.env.prod.example" <<'TMPL'
APP_NAME=MyApp
DB_PASSWORD=supersecret
API_SECRET=topsecret
SIGNING_KEY=keyval
MONKEY_COUNT=7
TMPL
run_env $'\n\n\n\n\n' "$d"
assert 'grep -qF "APP_NAME [MyApp]" <<<"$out"'      "a plain key shows its default (said '$out')"
assert 'grep -qF "DB_PASSWORD [****]" <<<"$out"'    "a PASSWORD key is masked in the prompt (said '$out')"
assert 'grep -qF "API_SECRET [****]" <<<"$out"'     "a SECRET key is masked in the prompt (said '$out')"
assert 'grep -qF "SIGNING_KEY [****]" <<<"$out"'    "a KEY key is masked in the prompt (said '$out')"
assert 'grep -qF "MONKEY_COUNT [****]" <<<"$out"'   "the mask test is a substring match — MONKEY_COUNT is masked (said '$out')"
assert '! grep -qF "supersecret" <<<"$out"'         "a sensitive default is never printed in clear (said '$out')"
expect_kv "$d/.env" DB_PASSWORD supersecret "a masked prompt still writes the accepted default"
expect_kv "$d/.env" MONKEY_COUNT 7          "a masked non-secret still writes its default"

# --- Case 17: the masked read really does not echo -----------------------------
d=$(newdir t17)
cat > "$d/.env.prod.example" <<'TMPL'
DB_PASSWORD=
TMPL
run_env_tty $'hunter2\n' "$d" 'DB_PASSWORD:'
assert '[ "$tty_rc" = "0" ]' "the pty run exits 0 (got $tty_rc)"
expect_kv "$d/.env" DB_PASSWORD hunter2 "a secret typed at a terminal is stored whole"
assert 'grep -qF "DB_PASSWORD:" <<<"$tty_out"' "the secret prompt reaches the terminal (said '$tty_out')"
assert '! grep -qF "hunter2" <<<"$tty_out"'    "the typed secret never appears on the terminal (said '$tty_out')"

# A non-sensitive key on the same terminal is echoed — the control that proves
# the assertion above is about read -rs and not about script(1) losing input.
d=$(newdir t17b)
cat > "$d/.env.prod.example" <<'TMPL'
APP_NAME=
TMPL
run_env_tty $'hunter2\n' "$d" 'APP_NAME:'
expect_kv "$d/.env" APP_NAME hunter2 "a plain value typed at a terminal is stored whole"
assert 'grep -qF "hunter2" <<<"$tty_out"' "a plain value is echoed by the terminal (said '$tty_out')"

# --- Case 18: CRLF in either user-authored file --------------------------------
d=$(newdir t18)
printf '# --- App ---\r\nAPP_NAME=MyApp\r\n\r\nAPP_PORT=3000\r\n' > "$d/.env.prod.example"
printf 'APP_NAME=existing\r\nAPP_PORT=8080\r\n' > "$d/.env"
# y = reconfigure anyway (no drift), then Enter for each var
run_env $'y\n\n\n' "$d"
expect_kv "$d/.env" APP_NAME existing "a CRLF .env value loses its carriage return"
expect_kv "$d/.env" APP_PORT 8080     "second CRLF value cleaned too"
assert '! grep -q $'"'"'\r'"'"' "$d/.env"' "no carriage return survives into the generated .env"
assert 'grep -q "^# --- App ---$" "$d/.env"' "a CRLF comment line is preserved without its \r"

# --- Case 19: a missing template is exit 1 -------------------------------------
d=$(newdir t19)
run_env '' "$d"
assert '[ "$rc" = "1" ]' "a missing template exits 1 (got $rc)"
assert 'grep -qF "Template not found" <<<"$out"' "and says the template is missing (said '$out')"
assert '[ ! -e "$d/.env" ]' "a missing template writes no .env"

# --- Case 20: a live value is offered back as `[current: …]` ------------------
# The has-existing half of the hint and empty prompt types is only reachable in
# reconfigure-all mode — update-only auto-accepts those keys and never renders
# the prompt at all. The dropped key is what forces the menu instead of the
# no-drift shortcut.
d=$(newdir t20a)
cat > "$d/.env.prod.example" <<'TMPL'
# --- Mail ---
MAIL_HOST=# Your SMTP host
MAIL_PASSWORD=# SMTP password
OPTIONAL=
TMPL
cat > "$d/.env" <<'ENV'
MAIL_HOST=smtp.live.example
MAIL_PASSWORD=livepass
OPTIONAL=keepme
NOW_GONE=x
ENV
run_env $'a\n\n\n\n' "$d"
assert 'grep -qF "MAIL_HOST (Your SMTP host) [current: smtp.live.example]" <<<"$out"' \
       "a hint prompt offers the live value back (said '$out')"
assert 'grep -qF "MAIL_PASSWORD (SMTP password) [current: ****]" <<<"$out"' \
       "a sensitive hint prompt masks the live value (said '$out')"
assert '! grep -qF "livepass" <<<"$out"' "and never prints it in clear (said '$out')"
assert 'grep -qF "OPTIONAL [current: keepme]" <<<"$out"' \
       "an empty-type prompt offers the live value back (said '$out')"
expect_kv "$d/.env" MAIL_HOST     smtp.live.example "Enter on a hint prompt keeps the live value"
expect_kv "$d/.env" MAIL_PASSWORD livepass          "Enter on a sensitive hint prompt keeps the live value"
expect_kv "$d/.env" OPTIONAL      keepme            "Enter on an empty-type prompt keeps the live value"

# --- Case 20b: section headers are a feature, not just a comment --------------
# Both branches end in the same OUTPUT_LINES+=, so "the header survived into
# .env" cannot tell a header from a comment. What distinguishes them while
# prompting is the blank line and the bold — docs/env-template.md § Section
# headers.
d=$(newdir t20b)
cat > "$d/.env.prod.example" <<'TMPL'
APP_ONE=1
# free-form note
# --- Section ---
APP_TWO=2
# -- not a header --
APP_THREE=3
TMPL
run_env $'\n\n\n' "$d"
assert '[ -z "$(grep -B1 -xF -- "# --- Section ---" <<<"$out" | head -1)" ]' \
       "a section header is set off by a blank line (said '$out')"
assert 'grep -qF "APP_TWO [2]: # -- not a header --" <<<"$out"' \
       "two dashes is short of the {3,} boundary and stays a plain comment, printed inline (said '$out')"
d=$(newdir t20c); basic_template "$d"
run_env_tty $'\n\n\n' "$d" 'APP_NAME' env -u NO_COLOR
assert 'grep -qF "$(printf '"'"'\033[36m\033[1m'"'"')# --- App ---" <<<"$tty_out"' \
       "a header is rendered bold cyan at a terminal (said '$tty_out')"

# Update-only with nothing new to ask: the template is regenerated silently, so
# neither headers nor comments are printed.
d=$(newdir t20d)
cat > "$d/.env.prod.example" <<'TMPL'
# --- Section ---
# free-form note
APP_ONE=1
TMPL
cat > "$d/.env" <<'ENV'
APP_ONE=keep
NOW_GONE=x
ENV
run_env $'\n' "$d"
assert '! grep -qF "# --- Section ---" <<<"$out"' "a silent regeneration prints no section header (said '$out')"
assert '! grep -qF "# free-form note" <<<"$out"'  "and no free-form comment either (said '$out')"
assert 'grep -q "^# --- Section ---$" "$d/.env"'  "both are still written to .env"
assert 'grep -qF "1 kept, 0 new, 1 removed" <<<"$out"' "the drift summary counts kept, new and removed (said '$out')"

# The same shape with something new to ask: the headers come back.
d=$(newdir t20e)
cat > "$d/.env.prod.example" <<'TMPL'
# --- Section ---
APP_ONE=1
APP_TWO=2
TMPL
cat > "$d/.env" <<'ENV'
APP_ONE=keep
ENV
run_env $'\n\n' "$d"
assert 'grep -qF "# --- Section ---" <<<"$out"' "a run with new vars does print the header (said '$out')"
assert 'grep -qF "1 kept, 1 new, 0 removed" <<<"$out"' "the summary counts a new key (said '$out')"

# --- Case 20: sourced mode ------------------------------------------------------
# The same bytes are sourced by hosting deploy, where the original's top-level
# `exit 1` would have taken the whole deploy down with it.
d=$(newdir t20)
out=$(bash -c '
    set -euo pipefail
    . "$1"
    _env_prompt_value() { echo SENTINEL; }
    . "$1"   # the load guard makes the second source a no-op
    declare -f _env_prompt_value | grep -q SENTINEL && echo "guard-held"
    [ "$_HOSTING_ENV_LOADED" = 1 ] && echo "guard-flag-set"
    env_setup_run "$2" && echo "returned=0" || echo "returned=$?"
    echo "caller-alive"
    declare -F env_main >/dev/null && echo "have-env_main"
' _ "$env_sh" "$d" 2>&1)
rc=$?
assert '[ "$rc" = "0" ]'                          "sourcing lib/env.sh twice succeeds (got $rc)"
assert 'grep -qF "guard-held" <<<"$out"'          "the load guard makes a second source a no-op (said '$out')"
assert 'grep -qF "guard-flag-set" <<<"$out"'      "the load guard sets _HOSTING_ENV_LOADED (said '$out')"
assert 'grep -qF "returned=1" <<<"$out"'          "a sourced missing-template returns 1 (said '$out')"
assert 'grep -qF "caller-alive" <<<"$out"'        "a sourced failure does not exit the caller (said '$out')"
assert 'grep -qF "have-env_main" <<<"$out"'       "sourcing defines env_main (said '$out')"

# lib/prompt.sh owns `prompt_value`; lib/env.sh must not redefine it, or
# whichever loads second in lib/deploy.sh silently loses its helper.
out=$(HOSTING_LIB_DIR="$repo_dir/lib" bash -c '
    set -euo pipefail
    . "$HOSTING_LIB_DIR/common.sh"
    . "$HOSTING_LIB_DIR/prompt.sh"
    before=$(declare -f prompt_value)
    . "$HOSTING_LIB_DIR/env.sh"
    [ "$before" = "$(declare -f prompt_value)" ] && echo "prompt_value-intact"
    declare -F _env_prompt_value >/dev/null && echo "have-_env_prompt_value"
' 2>&1)
assert 'grep -qF "prompt_value-intact" <<<"$out"'      "sourcing env.sh leaves prompt.sh's prompt_value untouched (said '$out')"
assert 'grep -qF "have-_env_prompt_value" <<<"$out"'   "env.sh brings its own _env_prompt_value (said '$out')"

# --- Case 21: EOF at a menu is fatal, EOF at a value prompt is not ------------
# The two menu reads are the only ones without `|| true`, and the difference is
# the whole reason `env_main` calls `env_setup_run` bare: errexit has to reach
# the menu. Both halves are asserted, executed and sourced, because a caller
# that believes the function always returns will lose its own process.
d=$(newdir t21); basic_template "$d"
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
ENV
cp "$d/.env" "$d/.env.backup"
run_env '' "$d"
assert '[ "$rc" = "1" ]' "EOF at the reconfigure prompt exits 1 (got $rc)"
expect_same "$d/.env" "$d/.env.backup" "EOF at the reconfigure prompt leaves .env alone"

# The same, sourced: this is the shape hosting deploy runs, and it takes the
# caller down with it. Asserted rather than assumed — the contract Unit C reads
# is this one, not the missing-template return.
d=$(newdir t21b); basic_template "$d"
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
ENV
: > "$tmpdir/stdin"
out=$(bash -c '
    set -euo pipefail
    . "$1"
    env_setup_run "$2"
    echo "caller-alive"
' _ "$env_sh" "$d" < "$tmpdir/stdin" 2>&1)
rc=$?
assert '[ "$rc" = "1" ]' "a sourced EOF at the menu exits the caller with 1 (got $rc)"
assert '! grep -qF "caller-alive" <<<"$out"' "and does not return to the caller (said '$out')"

# EOF inside a *value* prompt is survivable — `|| true` is what makes an
# operator who answers three of five questions still get a complete .env.
d=$(newdir t21c)
# B_SECRET is masked, so this reaches EOF in the `read -rs` branch as well as
# the plain one — both carry their own `|| true`.
cat > "$d/.env.prod.example" <<'TMPL'
A=1
B_SECRET=2
C=3
TMPL
run_env $'\n' "$d"
assert '[ "$rc" = "0" ]' "EOF at a value prompt is not fatal (got $rc)"
assert '[ -f "$d/.env" ]' "EOF at a value prompt still writes .env"
expect_kv "$d/.env" A        1 "the answered prompt takes its default"
expect_kv "$d/.env" B_SECRET 2 "EOF in a masked read falls back to the default"
expect_kv "$d/.env" C        3 "every later prompt does too"

# --- Case 22: colour is decided by stdout ---------------------------------------
esc=$'\033'
d=$(newdir t22); basic_template "$d"
printf '\n\n\n' > "$tmpdir/stdin"
out=$(env -u NO_COLOR bash "$env_sh" "$d" < "$tmpdir/stdin" 2>&1)
assert '! grep -qF "$esc" <<<"$out"' "a piped run emits no colour, NO_COLOR or not"
d=$(newdir t22b); basic_template "$d"
run_env_tty $'\n\n\n' "$d" 'APP_NAME' env -u NO_COLOR
assert 'grep -qF "$esc" <<<"$tty_out"' "a terminal run does emit colour — the control for the assertion above"

# --- Case 23: self-contained -----------------------------------------------------
# On the VPS nothing else exists, so a reference to another lib or to any of
# common.sh's helpers would only fail there.
code_only=$(grep -vE '^[[:space:]]*#' "$env_sh")
assert '! grep -qE "HOSTING_LIB_DIR|common\.sh" <<<"$code_only"' "lib/env.sh references no other hosting file"
assert '! grep -qE "(^|[;&|(\`[:space:]])(info|warn|err|err_cont|die)[[:space:]]" <<<"$code_only"' \
       "lib/env.sh calls none of common.sh's helpers"

# --- Case 24: every global a sourced lib/env.sh plus one env_setup_run adds ---
# `before` is taken ahead of the `.`, so the pinned set is the file's source-time
# globals *and* env_setup_run's — which is the set that matters, because
# lib/check.sh sources this file into a live command. The verbatim port uses no
# `local`, so every scalar the run touches lands in the caller's shell; adding
# one is seen here rather than discovered inside hosting deploy. `env -i` keeps
# the ambient environment (DISPLAY, notably) out of the comparison.
d=$(newdir t24)
cat > "$d/.env.prod.example" <<'TMPL'
# === Head ===
# note
PLAIN=v
EMPTY=
HINTED=# a hint
INLINE=v # c
GEN=! echo g
TMPL
cat > "$d/.env" <<'ENV'
PLAIN=p
EMPTY=
HINTED=h
INLINE=i
GONE=x
ENV
printf 'a





' > "$tmpdir/stdin"
leaked=$(env -i PATH="$PATH" LC_ALL=C bash -c '
    set -euo pipefail
    before=$(compgen -v | sort)
    . "$1"
    env_setup_run "$2" >/dev/null 2>&1
    comm -13 <(printf "%s
" "$before") <(compgen -v | sort) | grep -vx before | tr "
" " "
' _ "$env_sh" "$d" < "$tmpdir/stdin")
expected='BASH_REMATCH BOLD CHOICE CMD COMMENT CYAN DEFAULT DIM DISPLAY DISPLAY_CURRENT '
expected+='ENV_ASSIGN_RE ENV_MANAGED_BEGIN ENV_MANAGED_END ENV_RESERVED_PREFIX '
expected+='ESCAPED_VALUE EXAMPLE EXISTING_VALUE GREEN HAS_EXISTING HINT KEPT_COUNT KEY OUTPUT '
expected+='RAW_VALUE RED RESET SUPPRESS_HEADERS TARGET_DIR UPDATE_ONLY VALUE YELLOW '
expected+='_HOSTING_ENV_LOADED dkey ekey line nkey tkey tline '
assert '[ "$leaked" = "$expected" ]' "env_setup_run leaks exactly the known globals (got '$leaked')"
# The six arrays are `declare`d inside the function, which makes them local —
# the one divergence from the standalone original that changes behaviour, and
# the reason a second call in one shell cannot read the first call's NEW_KEYS.
assert '! grep -qE "\b(EXISTING|TEMPLATE_KEYS|TEMPLATE_KEY_SET|NEW_KEYS|DROPPED_KEYS|OUTPUT_LINES)\b" <<<"$leaked"' \
       "the declared arrays stay function-local (got '$leaked')"

# --- Case 25: the library half — lib_run sources and evaluates ---------------
# The drift and injection helpers are never executed as a script; they are
# called by lib/check.sh here and by the deploy path on the VPS. Positional
# arguments after the snippet arrive as "$1", "$2", …
lib_run() {
    local snippet="$1"; shift
    out=$(bash -c "set -euo pipefail; . \"\$1\"; shift; $snippet" _ "$env_sh" "$@" 2>&1)
    rc=$?
}

d=$(newdir t25)
printf '# comment\nA=1\nB=\n\nnot a var line\n1BAD=x\nFOO BAR=y\n_C_1=z\nLAST=9' > "$d/keys"
lib_run 'env_extract_keys "$1" | tr "\n" " "' "$d/keys"
assert '[ "$out" = "A B _C_1 LAST " ]' "env_extract_keys returns the assignment keys in file order (got '$out')"
assert '[ "$rc" = "0" ]'               "env_extract_keys exits 0 (got $rc)"

# A key-less file and a missing file both come back empty with status 0 — under
# errexit either would otherwise take the caller down.
printf '# only comments\n\n' > "$d/keyless"
lib_run 'env_extract_keys "$1"; echo "alive-keyless"; env_extract_keys "$1/nope"; echo "alive-missing"' "$d/keyless"
assert '[ "$rc" = "0" ]'                          "a key-less and a missing file leave the caller alive (got $rc)"
assert 'grep -qF "alive-keyless" <<<"$out"'       "a key-less file returns 0 (said '$out')"
assert 'grep -qF "alive-missing" <<<"$out"'       "a missing file returns 0 (said '$out')"
assert '[ "$(grep -c . <<<"$out")" = "2" ]'       "and neither prints anything (said '$out')"

# --- Case 26: a final line with no newline is data ----------------------------
# lib/check.sh's E01/E04 readers, grep, awk and docker compose all see it, so
# every reader in lib/env.sh does too. The value at stake is a live one:
# without it, reconfigure regenerates the last key from the template default.
d=$(newdir t26)
printf 'A=1\nLAST=9' > "$d/unterminated"
lib_run 'env_extract_keys "$1" | tr "\n" " "' "$d/unterminated"
assert '[ "$out" = "A LAST " ]' "env_extract_keys sees an unterminated final key (got '$out')"

d=$(newdir t26b)
printf 'APP_NAME=MyApp\nAPP_PORT=3000' > "$d/.env.prod.example"
printf 'APP_NAME=live_name\nAPP_PORT=8080' > "$d/.env"
# Neither file ends in a newline, so all three of this file's readers are on
# trial. If the last key were invisible to any of them, APP_PORT would be new,
# or dropped, or absent from the output — instead of the no-drift shortcut.
run_env $'y\n\n' "$d"
assert 'grep -qF "No changes detected" <<<"$out"' \
       "an unterminated last key counts for drift, so nothing looks new (said '$out')"
expect_kv "$d/.env" APP_NAME live_name "the terminated key keeps its live value"
expect_kv "$d/.env" APP_PORT 8080      "the unterminated last key keeps its live value too"

# --- Case 27: env_drift ---------------------------------------------------------
d=$(newdir t27)
printf 'A=1\nB=2\nHOSTING_MEM_LIMIT=54g\n' > "$d/.env.prod.example"
printf 'A=x\nHOSTING_CPU_LIMIT=14.4\n' > "$d/.env"
drift='env_drift "$1" "$2"; echo "missing=[$ENV_DRIFT_MISSING] extra=[$ENV_DRIFT_EXTRA]"'
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[B] extra=[]" ]' \
       "a reserved key is not drift in either direction, a real one still is (got '$out')"

# In sync, values deliberately different — drift is a key-set question.
d=$(newdir t27b)
printf 'A=1\nB=2\n' > "$d/.env.prod.example"
printf 'B=changed\nA=alsochanged\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' "different values are not drift (got '$out')"

# Real drift both ways, more than one key each, reserved keys mixed in.
d=$(newdir t27c)
printf 'A=1\nM_ONE=1\nM_TWO=2\nHOSTING_MEM_LIMIT=54g\n' > "$d/.env.prod.example"
printf 'A=1\nX_ONE=1\nX_TWO=2\nHOSTING_CPU_LIMIT=14.4\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[M_ONE M_TWO] extra=[X_ONE X_TWO]" ]' \
       "both lists are space-joined and name only unreserved keys (got '$out')"

# A .env that is nothing but the injected block is in sync with any template
# whose keys it already has — the shape every deployed project is in.
d=$(newdir t27d)
printf 'A=1\n' > "$d/.env.prod.example"
printf 'A=1\nHOSTING_CPU_LIMIT=14.4\nHOSTING_MEM_LIMIT=54g\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' "an injected .env has no drift (got '$out')"

# A key set twice — the shape a stray leaves behind — is one key, not drift.
d=$(newdir t27f)
printf 'A=1\nB=2\n' > "$d/.env.prod.example"
printf 'A=1\nB=2\nA=override\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' "a key repeated in .env is not extra (got '$out')"

# A missing .env is every template key missing, not an error.
d=$(newdir t27g)
printf 'A=1\nHOSTING_CPU_LIMIT=0\n' > "$d/.env.prod.example"
lib_run "$drift" "$d/.env.prod.example" "$d/nope"
assert '[ "$rc" = "0" ]'                     "env_drift over a missing .env exits 0 (got $rc)"
assert '[ "$out" = "missing=[A] extra=[]" ]' "and reports every unreserved template key missing (got '$out')"

# Drift is reported through the two variables, never the exit status: the one
# call every caller makes must be safe to write bare under errexit.
d=$(newdir t27e)
printf 'A=1\n' > "$d/.env.prod.example"
printf 'B=1\n' > "$d/.env"
lib_run 'env_drift "$1" "$2"; echo "caller-alive"' "$d/.env.prod.example" "$d/.env"
assert '[ "$rc" = "0" ]'                     "a bare env_drift over a drifting pair returns 0 (got $rc)"
assert 'grep -qF "caller-alive" <<<"$out"'   "and the caller survives it (said '$out')"

# --- Case 28: env_inject_hosting_vars ------------------------------------------
inject='env_inject_hosting_vars "$1" HOSTING_CPU_LIMIT=14.4 HOSTING_MEM_LIMIT=54g'
block=$'# >>> hosting managed block - do not edit, rewritten on every deploy >>>\nHOSTING_CPU_LIMIT=14.4\nHOSTING_MEM_LIMIT=54g\n# <<< hosting managed block <<<\n'
bmark='# >>> hosting managed block - do not edit, rewritten on every deploy >>>'
emark='# <<< hosting managed block <<<'

expect_bytes() {
    printf '%s' "$2" > "$tmpdir/want"
    expect_same "$1" "$tmpdir/want" "$3"
}

# A hand-edited file: comments, blank lines, odd spacing, an unknown line, a
# trailing section. All of it survives in order; the block is appended.
d=$(newdir t28)
body=$'# --- App ---\nAPP=1\n\nSPACED=2   \nnot a var line\n# tail note\nLAST=3\n'
printf '%s' "$body" > "$d/.env"
lib_run "$inject" "$d/.env"
assert '[ "$rc" = "0" ]' "injection exits 0 (got $rc)"
expect_bytes "$d/.env" "$body$block" "a first injection appends the block and touches nothing else"

cp "$d/.env" "$d/.env.first"
lib_run "$inject" "$d/.env"
expect_same "$d/.env" "$d/.env.first" "a second injection with the same values is byte-identical"

# Stale values are refreshed in place — the block does not move to the end and
# the lines around it do not shift.
d=$(newdir t28b)
stale=$'# >>> hosting managed block - do not edit, rewritten on every deploy >>>\nHOSTING_CPU_LIMIT=0.9\nHOSTING_MEM_LIMIT=460m\n# <<< hosting managed block <<<\n'
printf '%s' "HEAD=1"$'\n'"$stale"$'# tail note\nTAIL=2\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" "HEAD=1"$'\n'"$block"$'# tail note\nTAIL=2\n' \
             "a stale block is refreshed where it stands, not moved to the end"
cp "$d/.env" "$d/.env.first"
lib_run "$inject" "$d/.env"
expect_same "$d/.env" "$d/.env.first" "refreshing an existing block is idempotent too"

# Any HOSTING_ line outside the block is removed: two lines setting one
# variable means the last wins, so a stray silently outranks the marker.
d=$(newdir t28c)
printf 'A=1\nHOSTING_CPU_LIMIT=stray\nB=2\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" $'A=1\nB=2\n'"$block" "a stray HOSTING_ line outside the block is removed"

# Including in a CRLF file, whose other lines keep their carriage returns —
# injection is not a line-ending rewrite.
d=$(newdir t28d)
printf 'A=1\r\nHOSTING_MEM_LIMIT=stray\r\nB=2\r\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" $'A=1\r\nB=2\r\n'"$block" "the user's CRLF lines survive byte-for-byte"

# No .env at all: the file is created holding the block, and nothing else.
d=$(newdir t28e)
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" "$block" "injection into a missing .env creates it with just the block"
assert '[ "$(stat -c %a "$d/.env")" = "600" ]' \
       "a .env injection created is 600 — it holds secrets (got $(stat -c %a "$d/.env"))"

# An existing file keeps the mode its owner gave it.
d=$(newdir t28f)
printf 'A=1\n' > "$d/.env"; chmod 640 "$d/.env"
lib_run "$inject" "$d/.env"
assert '[ "$(stat -c %a "$d/.env")" = "640" ]' \
       "injection leaves an existing .env's mode alone (got $(stat -c %a "$d/.env"))"

# A last line with no newline gets one; it is not merged with the block.
d=$(newdir t28g)
printf 'A=1\nLAST=9' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" $'A=1\nLAST=9\n'"$block" "an unterminated last line survives, terminated"

# A begin sentinel with no end is not a block: it marks the position, and
# everything after it stays. Running to EOF instead would swallow the tail of a
# half-written file.
d=$(newdir t28h)
printf '%s' $'A=1\n# >>> hosting managed block - do not edit, rewritten on every deploy >>>\nB=2\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" $'A=1\n'"$block"$'B=2\n' "an unterminated block keeps its place and swallows nothing"

# Values are written through unchanged — the marker's spelling is the contract,
# and the rig cannot honour a real limit, so 0 has to survive as 0.
d=$(newdir t28i)
lib_run 'env_inject_hosting_vars "$1" HOSTING_CPU_LIMIT=0 HOSTING_MEM_LIMIT=0' "$d/.env"
assert 'grep -qxF "HOSTING_CPU_LIMIT=0" "$d/.env"' "a limit of 0 is written through unvalidated"
assert 'grep -qxF "HOSTING_MEM_LIMIT=0" "$d/.env"' "both of them"

# No pairs at all is refused: it would rewrite an existing block empty, and
# `compose up` then fails on an unset HOSTING_CPU_LIMIT. The `for` guard below
# never runs with zero arguments, so this needs its own check.
d=$(newdir t28k)
printf '%s' $'A=1\nHOSTING_CPU_LIMIT=9\n' > "$d/.env"
lib_run 'env_inject_hosting_vars "$1" HOSTING_CPU_LIMIT=9' "$d/.env"
cp "$d/.env" "$d/.env.before"
lib_run 'env_inject_hosting_vars "$1" || echo "rc=$?"; echo caller-alive' "$d/.env"
assert '[ "$rc" = "0" ]'                          "an empty pair list does not kill the caller (got $rc)"
assert 'grep -qF "rc=1" <<<"$out"'                "it returns 1 (said '$out')"
assert 'grep -qF "no HOSTING_NAME=value pairs given" <<<"$out"' "and says why (said '$out')"
assert 'grep -qF "caller-alive" <<<"$out"'        "the caller runs on (said '$out')"
expect_same "$d/.env" "$d/.env.before" "and the block it would have emptied is untouched"

# A key outside the reserved prefix is a caller bug: refused, file untouched.
d=$(newdir t28j)
printf 'A=1\n' > "$d/.env"; cp "$d/.env" "$d/.env.backup"
lib_run 'env_inject_hosting_vars "$1" DATABASE_URL=x || echo "rc=$?"' "$d/.env"
assert 'grep -qF "rc=1" <<<"$out"'                    "an unreserved key is refused with 1 (said '$out')"
assert 'grep -qF "is not a HOSTING_NAME=value pair" <<<"$out"' "and says why (said '$out')"
expect_same "$d/.env" "$d/.env.backup" "a refused injection leaves .env untouched"

# The prefix is matched anchored, so a key that merely contains it is refused
# too — accepting it would let injection write outside its own namespace.
lib_run 'env_inject_hosting_vars "$1" MY_HOSTING_URL=x || echo "rc=$?"' "$d/.env"
assert 'grep -qF "rc=1" <<<"$out"'  "a key containing HOSTING_ but not starting with it is refused (said '$out')"
lib_run 'env_inject_hosting_vars "$1" "HOSTING_F BAR=x" || echo "rc=$?"' "$d/.env"
assert 'grep -qF "rc=1" <<<"$out"'  "so is a pair whose name is not a name (said '$out')"

# --- Case 29: reserved keys are never prompted and never land in .env ---------
# The template line and the injected block name the same key; setup must treat
# neither as drift and write neither, or the .env carries two lines for one
# variable and the last one wins.
d=$(newdir t29)
cat > "$d/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=MyApp
HOSTING_CPU_LIMIT=0
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=live_name
HOSTING_CPU_LIMIT=14.4
HOSTING_MEM_LIMIT=54g
ENV
# y = reconfigure anyway, then Enter for the one var that is actually prompted.
run_env $'y\n' "$d"
assert '[ "$rc" = "0" ]'                              "a reserved key in both files exits 0 (got $rc)"
assert 'grep -qF "No changes detected" <<<"$out"'     "reserved keys count as neither new nor removed (said '$out')"
assert '! grep -qF "HOSTING_" <<<"$out"'              "and are never prompted for (said '$out')"
expect_kv     "$d/.env" APP_NAME live_name            "the unreserved key keeps its live value"
expect_absent "$d/.env" HOSTING_CPU_LIMIT             "a reserved template key is not written to .env"
expect_absent "$d/.env" HOSTING_MEM_LIMIT             "nor is a reserved key the live .env carried"

# --- Case 31: what counts as a stray ------------------------------------------
# Compose trims leading blanks, honours an `export ` prefix, and lets the last
# assignment win — so every one of these outranks the marker.
d=$(newdir t31)
printf 'A=1\nexport HOSTING_MEM_LIMIT=1g\n  HOSTING_CPU_LIMIT=0.1\n\tHOSTING_MEM_LIMIT=2g\nexport\tHOSTING_CPU_LIMIT=0.2\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" $'A=1\n'"$block" "an exported or indented HOSTING_ assignment is a stray too"

# And what does not. MY_HOSTING_URL is the user's key; removing it would be
# data loss in the opposite direction from the one the stray rule prevents.
d=$(newdir t31b)
keep=$'# HOSTING_CPU_LIMIT=commented out\nMY_HOSTING_URL=https://mine\nNOTE=see HOSTING_MEM_LIMIT=1\nHOSTING_ SPACED=x\n'
printf '%s' "$keep" > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" "$keep$block" "a line that merely looks like a reserved assignment survives"

# --- Case 31c: HOSTING_ with an empty name is reserved, uniformly -------------
# Compose reads `HOSTING_=x` as setting a variable named HOSTING_, which is
# inside the reserved namespace — so every rule naming the prefix owns it:
# stripped as a stray, accepted as a pair, exempt from drift.
d=$(newdir t31c)
printf 'A=1\nHOSTING_=stray\n' > "$d/.env"
lib_run 'env_inject_hosting_vars "$1" HOSTING_=owned' "$d/.env"
assert '[ "$rc" = "0" ]' "a bare HOSTING_ pair is accepted (got $rc, said '$out')"
expect_bytes "$d/.env" $'A=1\n'"$bmark"$'\nHOSTING_=owned\n'"$emark"$'\n' \
             "the bare-name stray is removed and the block owns the key"
printf 'A=1\nHOSTING_=t\n' > "$d/.env.prod.example"
printf 'A=1\n' > "$d/.env.live"
lib_run "$drift" "$d/.env.prod.example" "$d/.env.live"
assert '[ "$out" = "missing=[] extra=[]" ]' \
       "and it is exempt from drift like any other reserved key (got '$out')"

# --- Case 32: two blocks collapse into one ------------------------------------
# Any future change to the sentinel text leaves a .env in this state, and a
# second pair that survived every run would be permanent.
d=$(newdir t32)
printf '%s' "A=1"$'\n'"$block"$'MID=1\n'"$block"$'TAIL=1\n' > "$d/.env"
lib_run "$inject" "$d/.env"
expect_bytes "$d/.env" "A=1"$'\n'"$block"$'MID=1\nTAIL=1\n' \
             "two blocks collapse into one, written where the first began"
cp "$d/.env" "$d/.env.first"
lib_run "$inject" "$d/.env"
expect_same "$d/.env" "$d/.env.first" "and collapsing is idempotent"

# --- Case 33: the sentinels are matched with the \r stripped ------------------
# A .env a Windows editor saved carries CRLF sentinels. Unstripped, the old
# block goes unrecognised and the file ends up holding two of them.
d=$(newdir t33)
printf 'A=1\r\n%s\r\nHOSTING_CPU_LIMIT=0.9\r\n%s\r\n' "$bmark" "$emark" > "$d/.env"
lib_run "$inject" "$d/.env"
assert '[ "$(grep -cF "$bmark" "$d/.env")" = "1" ]' \
       "a CRLF block is recognised, so one begin sentinel remains (got $(grep -cF "$bmark" "$d/.env"))"
assert '[ "$(grep -cF "$emark" "$d/.env")" = "1" ]' \
       "and one end sentinel (got $(grep -cF "$emark" "$d/.env"))"
expect_bytes "$d/.env" $'A=1\r\n'"$block" "the CRLF block is replaced where it stood"

# --- Case 34: failure paths return, and leave no temp behind ------------------
# The temp sits in the project directory `deploy` rsyncs, so no exit path may
# leave one; and a raw bash diagnostic would kill the calling shell under
# errexit rather than returning.
d=$(newdir t34)
printf 'A=1\n' > "$d/.env"
lib_run "$inject" "$d/.env"
assert '[ -z "$(ls -A "$d" | grep -F ".hosting-inject." || true)" ]' \
       "a successful injection leaves no temp file (saw '$(ls -A "$d")')"

# Root would bypass both permission cases.
if [ "$(id -u)" -ne 0 ]; then
    d=$(newdir t34b)
    printf 'A=1\n' > "$d/.env"; chmod 000 "$d/.env"
    lib_run 'env_inject_hosting_vars "$1" HOSTING_CPU_LIMIT=1 || echo "rc=$?"; echo caller-alive' "$d/.env"
    assert '[ "$rc" = "0" ]'           "an unreadable .env does not kill the caller (got $rc)"
    assert 'grep -qF "rc=1" <<<"$out"' "it returns 1 (said '$out')"
    assert 'grep -qF "ERROR: env_inject_hosting_vars: cannot read" <<<"$out"' \
           "with a diagnostic of its own, not bash's (said '$out')"
    assert 'grep -qF "caller-alive" <<<"$out"' "and the caller runs on (said '$out')"
    chmod 600 "$d/.env"

    d=$(newdir t34c)
    printf 'A=1\n' > "$d/.env"; chmod 500 "$d"
    lib_run 'env_inject_hosting_vars "$1" HOSTING_CPU_LIMIT=1 || echo "rc=$?"; echo caller-alive' "$d/.env"
    assert 'grep -qF "rc=1" <<<"$out"' "an unwritable directory returns 1 (said '$out')"
    assert 'grep -qF "ERROR: env_inject_hosting_vars: cannot write" <<<"$out"' \
           "and says so (said '$out')"
    assert 'grep -qF "caller-alive" <<<"$out"' "without killing the caller (said '$out')"
    chmod 700 "$d"
    assert '[ -z "$(ls -A "$d" | grep -F ".hosting-inject." || true)" ]' \
           "and leaves no temp in the tree deploy rsyncs (saw '$(ls -A "$d")')"
fi

# A temp path that cannot be cleared — a directory left where one belongs — is
# the same kind of failure: one diagnostic of this function's own, not `rm`'s
# on the way to an errexit abort. Called bare, so nothing masks the abort. The
# mkdir spells out the temp path, so it also pins that the name carries the pid.
d=$(newdir t34d)
printf 'A=1\n' > "$d/.env"
out=$(bash -c '
    set -euo pipefail
    . "$1"
    mkdir "$2/.env.hosting-inject.$$"
    env_inject_hosting_vars "$2/.env" HOSTING_CPU_LIMIT=1
    echo NOTREACHED
' _ "$env_sh" "$d" 2>&1); rc=$?
assert '[ "$rc" = "1" ]'                    "an unusable temp path fails with 1 (got $rc, said '$out')"
assert 'grep -qF "ERROR: env_inject_hosting_vars: cannot write beside" <<<"$out"' \
       "reported as this function's own failure (said '$out')"
assert '! grep -q "^rm:" <<<"$out"'         "not as a raw rm diagnostic (said '$out')"
assert '! grep -qF NOTREACHED <<<"$out"'    "and it does not carry on regardless (said '$out')"
expect_bytes "$d/.env" $'A=1\n'             "leaving .env untouched"

# --- Case 35: a symlinked .env is written through ------------------------------
# Renaming over the link would leave a regular file here and orphan the target
# with stale content.
d=$(newdir t35)
printf 'A=1\n' > "$d/real.env"
ln -s real.env "$d/.env"
lib_run "$inject" "$d/.env"
assert '[ "$rc" = "0" ]'  "injection through a symlink exits 0 (got $rc, said '$out')"
assert '[ -L "$d/.env" ]' "the .env is still a symlink afterwards"
expect_bytes "$d/real.env" $'A=1\n'"$block" "and the block landed in the file it points at"

# --- Case 36: the write is a rename over a fresh temp -------------------------
d=$(newdir t36)
printf 'A=1\n' > "$d/.env"
ino=$(stat -c %i "$d/.env")
lib_run "$inject" "$d/.env"
assert '[ "$(stat -c %i "$d/.env")" != "$ino" ]' \
       "the new .env is a renamed temp, not an in-place edit a reader could catch half-written"

# The temp is per-process and made fresh: one left by a crashed run would
# otherwise hand its mode to the .env this creates.
d=$(newdir t36b)
out=$(bash -c '
    set -euo pipefail
    . "$1"
    : > "$2/.env.hosting-inject.$$"
    chmod 666 "$2/.env.hosting-inject.$$"
    env_inject_hosting_vars "$2/.env" HOSTING_CPU_LIMIT=1
    stat -c %a "$2/.env"
' _ "$env_sh" "$d" 2>&1)
assert '[ "$out" = "600" ]' "a stale temp is removed rather than reused (got '$out')"

# --- Case 37: setup destroys the block, so injection has to run after it ------
# env_setup_run rebuilds .env from the template, which carries no reserved
# keys. In the other order `docker compose up` fails on an unset limit.
d=$(newdir t37)
printf 'APP=MyApp\n' > "$d/.env.prod.example"
printf '%s' $'APP=live\n'"$block" > "$d/.env"
run_env $'y\n' "$d"
assert '[ "$rc" = "0" ]'                              "reconfigure-all over an injected .env exits 0 (got $rc)"
assert '! grep -qF "hosting managed block" "$d/.env"' "setup leaves no managed block behind"
assert '! grep -q "^HOSTING_" "$d/.env"'              "nor any reserved key at all"
lib_run "$inject" "$d/.env"
assert 'grep -qxF "HOSTING_CPU_LIMIT=14.4" "$d/.env"' "which injection puts back — that is the required order"

# --- Case 38: the reserved prefix is matched anchored --------------------------
# MY_HOSTING_URL is a plausible user key. Every site naming the prefix has to
# see it as the user's, or the exemption swallows keys hosting never writes.
d=$(newdir t38)
printf 'A=1\nMY_HOSTING_URL=t\n' > "$d/.env.prod.example"
printf 'A=1\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[MY_HOSTING_URL] extra=[]" ]' \
       "a key containing HOSTING_ still drifts when the .env lacks it (got '$out')"

d=$(newdir t38b)
printf 'A=1\n' > "$d/.env.prod.example"
printf 'A=1\nMY_HOSTING_URL=x\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[MY_HOSTING_URL]" ]' \
       "and when the template lacks it (got '$out')"

# Setup's three readers at once: the .env loader (the kept count), the
# template-key scan (the removed count) and the prompt loop (the value written).
d=$(newdir t38c)
cat > "$d/.env.prod.example" <<'TMPL'
APP_NAME=MyApp
MY_HOSTING_URL=https://default
NEW_VAR=n
TMPL
cat > "$d/.env" <<'ENV'
APP_NAME=live
MY_HOSTING_URL=https://live
ENV
run_env $'\n\n' "$d"
assert 'grep -qF "2 kept, 1 new, 0 removed" <<<"$out"' \
       "setup counts a key containing HOSTING_ as an ordinary kept key (said '$out')"
expect_kv "$d/.env" MY_HOSTING_URL https://live "and keeps its live value rather than dropping the line"

# --- Case 40: every reader here sees the line Compose sees --------------------
# Compose trims leading blanks and honours an `export ` prefix. A reader that
# does not is worse than one that over-matches: the key reads as absent, drift
# calls it missing, and setup then overwrites a live value with the template's.
d=$(newdir t40)
printf 'A=1\nexport B=2\n  C=3\n\tD=4\nexport\tE=5\n# export F=6\nexportG=7\nexport H I=8\n' > "$d/keys"
lib_run 'env_extract_keys "$1" | tr "\n" " "' "$d/keys"
assert '[ "$out" = "A B C D E exportG " ]' \
       "env_extract_keys reads the key behind an export or an indent, bare (got '$out')"

# The seam itself: a live secret written with `export `, and a template default
# beside it. Anchored readers saw an empty .env here, reported the key missing,
# and regenerated it from the template.
d=$(newdir t40b)
printf 'APP_KEY=default\nAPP_URL=http://default\n' > "$d/.env.prod.example"
printf 'export APP_KEY=live-secret\n  APP_URL=http://live\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' \
       "an exported or indented .env key is not missing (got '$out')"
run_env $'y\n\n' "$d"
assert '[ "$rc" = "0" ]'                            "reconfiguring over it exits 0 (got $rc)"
assert 'grep -qF "No changes detected" <<<"$out"'   "and the keys read as already there (said '$out')"
assert 'grep -qF "[http://live]" <<<"$out"'         "the live value is what Enter accepts (said '$out')"
expect_kv "$d/.env" APP_KEY live-secret   "the exported live secret survives a regeneration"
expect_kv "$d/.env" APP_URL http://live   "so does the indented one"
assert 'grep -qxF "APP_KEY=live-secret" "$d/.env"'  "rewritten bare — .env is rebuilt from the template, not edited"

# The template side. A key the scan sees but the prompt loop does not would be
# preserved verbatim, taking the template's default with it.
d=$(newdir t40c)
printf 'export FOO=tfoo\n  BAR=tbar\n' > "$d/.env.prod.example"
printf 'FOO=live\n' > "$d/.env"
run_env $'\n\n' "$d"
assert 'grep -qF "1 kept, 1 new, 0 removed" <<<"$out"' \
       "the template scan counts an exported key as a key (said '$out')"
expect_kv "$d/.env" FOO live "and the prompt loop keeps its live value"
expect_kv "$d/.env" BAR tbar "the new one takes the template default"

# Reserved keys, through the same shapes: still never prompted, still not
# written, still not drift. E05 is what warns about them (tests/check_test.sh).
d=$(newdir t40d)
printf 'A=1\nexport HOSTING_CPU_LIMIT=0\n  HOSTING_MEM_LIMIT=0\n' > "$d/.env.prod.example"
printf 'A=live\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' "an exported reserved template key is not drift (got '$out')"
run_env $'y\n' "$d"
assert '! grep -qF "HOSTING_" <<<"$out"' "and is never prompted for (said '$out')"
expect_absent "$d/.env" HOSTING_CPU_LIMIT "nor written to .env"
expect_absent "$d/.env" HOSTING_MEM_LIMIT "either of them"
expect_kv "$d/.env" A live "the unreserved key keeps its live value"

d=$(newdir t40e)
printf 'A=1\n' > "$d/.env.prod.example"
printf 'A=live\nexport HOSTING_CPU_LIMIT=9\n  HOSTING_MEM_LIMIT=1g\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[] extra=[]" ]' "an exported reserved .env key is not drift either (got '$out')"
run_env $'y\n' "$d"
assert 'grep -qF "1 kept, 0 new, 0 removed" <<<"$out"' \
       "and the .env loader does not count it as a dropped key (said '$out')"

# The mirror hazard: widening to a substring would make MY_HOSTING_URL hosting's.
d=$(newdir t40f)
printf 'A=1\nexport MY_HOSTING_URL=d\n' > "$d/.env.prod.example"
printf 'A=1\n' > "$d/.env"
lib_run "$drift" "$d/.env.prod.example" "$d/.env"
assert '[ "$out" = "missing=[MY_HOSTING_URL] extra=[]" ]' \
       "an exported key that merely contains HOSTING_ is still the user's (got '$out')"

# --- Case 30: what the drift and injection helpers leak -----------------------
# Same pin as case 24, for the half lib/check.sh and the deploy path call.
d=$(newdir t30)
printf 'A=1\n' > "$d/.env.prod.example"
printf 'B=1\n' > "$d/.env"
leaked=$(env -i PATH="$PATH" LC_ALL=C bash -c '
    set -euo pipefail
    . "$1"
    before=$(compgen -v | sort)
    env_extract_keys "$2/.env" >/dev/null
    env_drift "$2/.env.prod.example" "$2/.env"
    env_inject_hosting_vars "$2/.env" HOSTING_CPU_LIMIT=1.0
    comm -13 <(printf "%s\n" "$before") <(compgen -v | sort) | grep -vx before | tr "\n" " "
' _ "$env_sh" "$d")
assert '[ "$leaked" = "BASH_REMATCH ENV_DRIFT_EXTRA ENV_DRIFT_MISSING " ]' \
       "the helpers leak only the two drift results (got '$leaked')"

# --- Case 39: the dispatch modes the VPS copy is driven with -------------------
# The same bytes answer three questions on the far side, so `hosting deploy` can
# ask "is there a .env and has it drifted" and "write the managed block" without
# a second script existing anywhere. The bare form is the standalone original's
# calling convention and must not move: the 25-case differential against
# the original project's setup-env.sh runs `bash env.sh <dir>`.

# --drift over a pair that is in sync.
d=$(newdir t39); mkdir -p "$d"
printf 'A=1\nB=2\n' > "$d/.env.prod.example"
printf 'A=x\nB=y\n' > "$d/.env"
out=$(bash "$env_sh" --drift "$d" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "--drift over an in-sync pair exits 0 (got $rc)"
assert '[ "$out" = "$(printf "template_exists=yes\nenv_exists=yes\nmissing=\nextra=")" ]' \
       "and reports four key=value lines, both lists empty (said '$out')"

# Drift both ways, reserved keys mixed in and invisible to both sides.
printf 'A=1\nNEW=2\nHOSTING_CPU_LIMIT=9\n' > "$d/.env.prod.example"
printf 'A=x\nGONE=y\nHOSTING_MEM_LIMIT=1g\n' > "$d/.env"
out=$(bash "$env_sh" --drift "$d" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "--drift over a drifting pair still exits 0 (got $rc)"
assert 'grep -qx "missing=NEW" <<<"$out"' "the template's own new key is missing (said '$out')"
assert 'grep -qx "extra=GONE" <<<"$out"'  "and the .env's own key is extra (said '$out')"
assert '! grep -q "HOSTING_" <<<"$out"'   "reserved keys are in neither list (said '$out')"

# The two flags are what the caller branches on, and each has to be able to say
# no — a report that always said yes would send a deploy into the setup it
# should have skipped, or past the one it needed.
d=$(newdir t39b)
out=$(bash "$env_sh" --drift "$d" 2>&1)
assert 'grep -qx "template_exists=no" <<<"$out"' "no template says so (said '$out')"
assert 'grep -qx "env_exists=no" <<<"$out"'      "and no .env says so (said '$out')"
printf 'A=1\n' > "$d/.env.prod.example"
out=$(bash "$env_sh" --drift "$d" 2>&1)
assert 'grep -qx "template_exists=yes" <<<"$out"' "a template that is there says so (said '$out')"
assert 'grep -qx "env_exists=no" <<<"$out"'       "with the .env still absent (said '$out')"
assert 'grep -qx "missing=A" <<<"$out"'           "and its keys all read as missing (said '$out')"
printf 'A=1\n' > "$d/.env"
out=$(bash "$env_sh" --drift "$d" 2>&1)
assert 'grep -qx "env_exists=yes" <<<"$out"'      "a .env that is there says so (said '$out')"

# An empty .env is not a missing one: the caller runs setup for the second and
# reports drift for the first, and `[ -s ]` would confuse them.
d=$(newdir t39c)
printf 'A=1\n' > "$d/.env.prod.example"
: > "$d/.env"
out=$(bash "$env_sh" --drift "$d" 2>&1)
assert 'grep -qx "env_exists=yes" <<<"$out"' "an empty .env exists (said '$out')"
assert 'grep -qx "missing=A" <<<"$out"'      "and every template key is missing from it (said '$out')"

# stdout is a protocol; a diagnostic on it would be absorbed as a fact.
d=$(newdir t39d)
printf 'A=1\n' > "$d/.env.prod.example"
mkdir -p "$d/.env"
out=$(bash "$env_sh" --drift "$d" 2>/dev/null); rc=$?
err_out=$(bash "$env_sh" --drift "$d" 2>&1 >/dev/null)
assert '[ "$rc" != "0" ]' "--drift over a .env that is not a regular file fails (got $rc)"
assert '[ -z "$out" ]'    "printing no facts at all (said '$out')"
assert 'grep -qF "is not a regular file" <<<"$err_out"' "and the reason on stderr (said '$err_out')"

# --inject, through the same entry point.
d=$(newdir t39e)
printf 'A=1\n' > "$d/.env"
out=$(bash "$env_sh" --inject "$d" HOSTING_CPU_LIMIT=14.4 HOSTING_MEM_LIMIT=54g 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "--inject exits 0 (got $rc: $out)"
expect_bytes "$d/.env" $'A=1\n'"$block" "and writes the same block env_inject_hosting_vars does"
cp "$d/.env" "$d/.env.first"
bash "$env_sh" --inject "$d" HOSTING_CPU_LIMIT=14.4 HOSTING_MEM_LIMIT=54g >/dev/null 2>&1
expect_same "$d/.env" "$d/.env.first" "a second --inject is byte-identical"
# The mode takes the *directory*, like every other mode, and appends /.env
# itself. A mode that took the file would have written $d/.env/.env here and
# left $d/.env empty of a block.
assert '[ "$(ls -A "$d" | grep -cx ".env")" = "1" ]' \
       "--inject named the directory, not the file (saw '$(ls -A "$d")')"

out=$(bash "$env_sh" --inject "$d" DATABASE_URL=x 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "--inject with an unreserved key fails (got $rc)"
assert 'grep -qF "is not a HOSTING_NAME=value pair" <<<"$out"' "and says why (said '$out')"
expect_same "$d/.env" "$d/.env.first" "leaving .env untouched"

# `--inject` is a documented interface in this file's own header, so the empty
# pair list has to be refused here too — it would rewrite the block empty and
# leave `compose up` failing on an unset HOSTING_CPU_LIMIT.
out=$(bash "$env_sh" --inject "$d" 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "--inject with no pairs fails (got $rc)"
assert 'grep -qF "no HOSTING_NAME=value pairs given" <<<"$out"' "and says why (said '$out')"
expect_same "$d/.env" "$d/.env.first" "leaving the block it would have emptied intact"
out=$(cd "$d" && bash "$env_sh" --inject 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "--inject with no arguments at all fails too (got $rc)"
expect_same "$d/.env" "$d/.env.first" "and touches nothing in the working directory"

# --- Case 39b: the bare form is untouched, and unknown modes are refused ------
# `bash env.sh <dir>` is the original's calling convention and the differential
# harness's. A mode word is a leading `--`, which a target directory is not.
d=$(newdir t39f)
printf 'A=1\nB=2\n' > "$d/.env.prod.example"
run_env $'\n\n' "$d"
assert '[ "$rc" = "0" ]' "the bare [target_dir] form still runs the setup (got $rc)"
expect_kv "$d/.env" A 1 "and writes the .env it always did"
expect_kv "$d/.env" B 2 "every key of it"

d=$(newdir t39g)
printf 'A=1\nB=2\n' > "$d/.env.prod.example"
printf '\n\n' > "$tmpdir/stdin"
out=$(bash "$env_sh" --setup "$d" < "$tmpdir/stdin" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "--setup is the same thing, named (got $rc: $out)"
expect_kv "$d/.env" A 1 "and writes the same .env"

# The bare form's errexit contract survives the dispatch: EOF at the update menu
# still aborts, and .env is still untouched. Wrapping the call in `|| rc=$?`
# anywhere in env_main would turn that into exit 0 over a file nothing wrote.
d=$(newdir t39h); basic_template "$d"
cat > "$d/.env" <<'ENV'
APP_NAME=existing_app
APP_PORT=8080
APP_DEBUG=true
ENV
cp "$d/.env" "$d/.env.backup"
: > "$tmpdir/stdin"
out=$(bash "$env_sh" --setup "$d" < "$tmpdir/stdin" 2>&1); rc=$?
assert '[ "$rc" = "1" ]' "--setup with EOF at the menu exits 1 (got $rc)"
expect_same "$d/.env" "$d/.env.backup" "and leaves .env alone"

out=$(bash "$env_sh" --nonsense "$d" 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "an unknown mode is refused (got $rc)"
assert 'grep -qF "unknown mode" <<<"$out"' "by name (said '$out')"
assert 'grep -qF -- "--drift" <<<"$out"'   "and the message lists the modes there are (said '$out')"

# Sourced, env_main is still the only entry point and the modes reach the same
# functions — lib/check.sh sources this file and must not gain a dispatch.
out=$(bash -c '
    set -euo pipefail
    . "$1"
    env_main --drift "$2"
    echo "caller-alive"
' _ "$env_sh" "$d" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "a sourced env_main --drift returns to its caller (got $rc: $out)"
assert 'grep -qF "caller-alive" <<<"$out"' "alive (said '$out')"

exit "$fail"
