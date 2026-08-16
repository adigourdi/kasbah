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

# --- Case 24: the exact set of globals env_setup_run leaks --------------------
# The verbatim port uses no `local`, so every scalar it touches lands in the
# caller's shell — harmless today, and pinned here so that adding one is seen
# in this suite rather than discovered inside hosting deploy. `env -i` keeps the
# ambient environment (DISPLAY, notably) out of the comparison.
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
expected+='ESCAPED_VALUE EXAMPLE EXISTING_VALUE GREEN HAS_EXISTING HINT KEPT_COUNT KEY OUTPUT '
expected+='RAW_VALUE RED RESET SUPPRESS_HEADERS TARGET_DIR UPDATE_ONLY VALUE YELLOW '
expected+='_HOSTING_ENV_LOADED dkey ekey line nkey tkey tline '
assert '[ "$leaked" = "$expected" ]' "env_setup_run leaks exactly the known globals (got '$leaked')"
# The six arrays are `declare`d inside the function, which makes them local —
# the one divergence from the standalone original that changes behaviour, and
# the reason a second call in one shell cannot read the first call's NEW_KEYS.
assert '! grep -qE "\b(EXISTING|TEMPLATE_KEYS|TEMPLATE_KEY_SET|NEW_KEYS|DROPPED_KEYS|OUTPUT_LINES)\b" <<<"$leaked"' \
       "the declared arrays stay function-local (got '$leaked')"

exit "$fail"
