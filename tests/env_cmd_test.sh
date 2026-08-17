#!/usr/bin/env bash
# Test: lib/env_cmd.sh — `kasbah env`, and the tri-state the deploy path shares
# with it.
#
# A unit suite: recording stubs for `ssh` and `rsync` go first on PATH, so
# nothing here opens a socket and the suite passes on a machine with no rig.
# What the stubs record is the contract — which calls the command makes, in
# which order, with which arguments.
#
# Two halves. Everything headless is driven straight through bin/kasbah with
# stdin on /dev/null, which is the shape a CI runner produces and the one that
# must never stop at a prompt. The prompt itself needs a terminal, so those
# cases run behind script(1): `[ -t 0 ]` is a property of the pty and no
# amount of piping can fake it.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v script >/dev/null 2>&1; then
    echo "script(1) is required to prove the drift prompt only fires on a terminal" >&2
    exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export NO_COLOR=1

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- Stubs ----------------------------------------------------------------------
stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir" "$tmpdir/home"
call_log="$tmpdir/calls.log"

# One line per ssh/rsync call, arguments |-separated so a flag matches as a whole
# field and the ordering of the whole run is one file to read.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
last="${!#}"
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
case "$last" in
    true) exit 0 ;;
    "'bash' '-s'"*) cat >/dev/null ;;
esac
case "$last" in
    "'bash' '-s' '--' '/apps'")
        marker_default='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'
        printf '%s\n' "${MARKER-$marker_default}" ;;
    "'bash' '-s' '--' '/apps' 'demo'") printf 'prepared=yes\n' ;;
    *"setup-env.sh' '--drift' "*)
        printf 'template_exists=%s\n' "${ENV_TEMPLATE:-yes}"
        printf 'env_exists=%s\n' "${ENV_EXISTS:-yes}"
        printf 'missing=%s\n' "${ENV_MISSING:-}"
        printf 'extra=%s\n' "${ENV_EXTRA:-}" ;;
    # The interactive run. Recorded above like everything else; what makes it
    # identifiable is the -t in its argument list.
    *"setup-env.sh' '/apps/demo'") exit "${SETUP_RC:-0}" ;;
    *"setup-env.sh' '--inject' "*) exit "${INJECT_RC:-0}" ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
{ printf 'rsync'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
# A transfer that fails is the shape the `|| die` in every ssh_rsync caller is
# for, and a stub that always succeeds cannot reach one.
if [ -n "${RSYNC_FAIL:-}" ]; then
    for a in "$@"; do
        case "$a" in
            *"$RSYNC_FAIL"*) echo "rsync: connection unexpectedly closed" >&2; exit 12 ;;
        esac
    done
fi
exit 0
STUB
chmod 0755 "$stub_dir/ssh" "$stub_dir/rsync"

project="$tmpdir/demo"
cp -R "$repo_dir/tests/fixtures/demo" "$project"

env_cli() {
    : > "$call_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" CALL_LOG="$call_log" \
        "$repo_dir/bin/kasbah" env "$@" </dev/null 2>&1
}

# The same command behind a pty, with the answers on its stdin. script(1) merges
# the session into one stream and turns every \n into \r\n, hence the strip.
# Its own stdin is a file, never the suite's terminal: `timeout` puts the child
# in a process group of its own, and a child reading the *controlling* terminal
# from there takes SIGTTIN and stops — a stopped process never handles the
# SIGTERM that follows, so a bounded wait becomes a permanent hang
# (tests/integration/rig_env.sh).
tty_rc=0
tty_out=""
env_cli_tty() {
    local input="$1"; shift
    local redirect=""
    # `--redirect-stdout` sends the command's stdout to a file *inside* the pty
    # session, so stdin stays a terminal while stdout is not — the shape
    # `kasbah env user@vps > out.log` produces, and the one that separates a
    # prompt this side can ask (stderr) from one the far side cannot show.
    if [ "${1:-}" = --redirect-stdout ]; then redirect=" > $(printf '%q' "$tmpdir/tty-stdout")"; shift; fi
    : > "$call_log"
    printf '%s' "$input" > "$tmpdir/tty-in"
    rm -f "$tmpdir/tty-out"
    local cmd
    # script(1) runs the string through `sh -c` in the *caller's* directory, and
    # every project command reads ./kasbah.yml — so the cd is part of the
    # command rather than of this function, which has globals to write back.
    cmd="cd $(printf '%q' "$project") && "
    cmd+="$(printf '%q ' env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" CALL_LOG="$call_log" NO_COLOR=1 \
        "${TTY_ENV[@]+"${TTY_ENV[@]}"}" \
        "$repo_dir/bin/kasbah" env "$@")$redirect"
    timeout 60 script -qfec "$cmd" "$tmpdir/tty-out" < "$tmpdir/tty-in" >/dev/null 2>&1
    tty_rc=$?
    tty_out=$(<"$tmpdir/tty-out")
    tty_out=${tty_out//$'\r'/}
    # util-linux prints its own banner when stdout is not a terminal, and it
    # quotes the whole command line into the transcript.
    tty_out=$(grep -v '^Script \(started\|done\) on ' <<<"$tty_out")
}
TTY_ENV=()

calls() { cat "$call_log"; }

# --- Case 1: the local refusals, before anything remote -------------------------
out=$( cd "$tmpdir" && env_cli deploy@vps ); rc=$?
assert '[ "$rc" = "2" ]' "env outside a project exits 2, like every project command (rc $rc: $out)"
assert 'grep -qF "No kasbah.yml" <<<"$out"' "naming the file it wanted (said '$out')"
assert '[ ! -s "$call_log" ]' "and opens no connection (calls: $(calls))"

out=$( cd "$project" && env_cli ); rc=$?
assert '[ "$rc" = "1" ]' "no server and no last_server is a plain failure (rc $rc: $out)"
assert 'grep -qF "last_server" <<<"$out"' "naming the field that would have answered (said '$out')"
assert '[ ! -s "$call_log" ]' "and opens no connection (calls: $(calls))"

mv "$project/.env.prod.example" "$tmpdir/held-template"
out=$( cd "$project" && env_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a project with no .env.prod.example is refused (rc $rc: $out)"
assert 'grep -qF ".env.prod.example" <<<"$out"' "naming the template (said '$out')"
assert '[ ! -s "$call_log" ]' "before connecting (calls: $(calls))"
mv "$tmpdir/held-template" "$project/.env.prod.example"

out=$( cd "$project" && env_cli deploy@vps --on-drift=maybe ); rc=$?
assert '[ "$rc" != "0" ]' "--on-drift=maybe is refused (rc $rc: $out)"
assert 'grep -qF "setup, continue or abort" <<<"$out"' "listing the three answers (said '$out')"
# Anchored on the message, not just on rc: every refusal in this command exits
# non-zero, so `rc != 0` alone passes just as well against a flag that was
# silently ignored and a run that then stopped for want of a terminal.
out=$( cd "$project" && env_cli deploy@vps --on-drift ); rc=$?
assert '[ "$rc" != "0" ]' "--on-drift without '=' is refused (rc $rc: $out)"
assert 'grep -qF -- "--on-drift=setup" <<<"$out"' "showing the form that works (said '$out')"
out=$( cd "$project" && env_cli deploy@vps --nonsense ); rc=$?
assert '[ "$rc" != "0" ]' "an unknown flag is refused (rc $rc: $out)"
assert 'grep -qF "unknown flag" <<<"$out"' "by name (said '$out')"
assert 'grep -qF -- "--nonsense" <<<"$out"' "quoting it back (said '$out')"
assert '[ ! -s "$call_log" ]' "before any connection (calls: $(calls))"
out=$( cd "$project" && env_cli deploy@vps extra-arg ); rc=$?
assert '[ "$rc" != "0" ]' "a second positional is refused (rc $rc: $out)"
assert 'grep -qF "too many arguments" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "extra-arg" <<<"$out"' "and quoting it (said '$out')"
out=$( cd "$project" && env_cli --help ); rc=$?
assert '[ "$rc" = "0" ]' "--help exits 0 (rc $rc)"
assert 'grep -qF -- "--on-drift=continue" <<<"$out"' "and documents the flag (said '$out')"

# --- Case 2: the server has to be prepared --------------------------------------
# Same code as deploy reads, and the same refusal: a marker somewhere else is
# not a server to initialise again (lib/marker.sh).
cat > "$stub_dir/ssh.marker-missing" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
last="${!#}"
case "$*" in *"-O exit"*) exit 0 ;; esac
case "$last" in true) exit 0 ;; esac
cat >/dev/null
exit 3
STUB
chmod 0755 "$stub_dir/ssh.marker-missing"
cp "$stub_dir/ssh" "$stub_dir/ssh.full"
cp "$stub_dir/ssh.marker-missing" "$stub_dir/ssh"
out=$( cd "$project" && env_cli deploy@vps ); rc=$?
assert '[ "$rc" = "4" ]' "env against an unprepared server exits 4, like deploy (rc $rc: $out)"
assert 'grep -qF "/apps/.kasbah/server.json" <<<"$out"' "naming the marker (said '$out')"
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" <<<"$out"' \
    "and never prints a runnable bare \`server init\` as the remedy (said '$out')"
assert '[ "$(grep -c "^rsync|" "$call_log")" = "0" ]' \
    "nothing was shipped to a server that is not prepared (calls: $(calls))"
cp "$stub_dir/ssh.full" "$stub_dir/ssh"

# --- Case 2b: a transfer that fails stops the run -------------------------------
# Both files have to be on the server before anything asks the server about
# them, so neither rsync may fail quietly into a probe that then reports on
# whatever was there from last time.
out=$( cd "$project" && RSYNC_FAIL=lib/env.sh env_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a failed setup-env.sh transfer stops the run (rc $rc: $out)"
assert 'grep -qF "could not ship setup-env.sh" <<<"$out"' "with this command's own message (said '$out')"
assert '! grep -qF -- "--drift" "$call_log"' \
    "and nothing was asked of the server afterwards (calls: $(calls))"
out=$( cd "$project" && RSYNC_FAIL=.env.prod.example env_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a failed template transfer stops it too (rc $rc: $out)"
assert 'grep -qF ".env.prod.example" <<<"$out"' "naming the file (said '$out')"
assert '! grep -qF -- "--drift" "$call_log"' "before any probe (calls: $(calls))"

# --- Case 3: headless, the setup cannot run -------------------------------------
# `kasbah env` exists to run the interactive generator, so with no terminal
# there is nothing for it to do but say so. Exit 5, the same code the deploy
# path uses for "the env step could not complete".
out=$( cd "$project" && env_cli deploy@vps ); rc=$?
assert '[ "$rc" = "5" ]' "env with no terminal exits 5 (rc $rc: $out)"
assert 'grep -qF "no terminal" <<<"$out"' "saying what is missing (said '$out')"
assert '! grep -qE "^ssh\|-t\|" "$call_log"' \
    "and never opened a session it could not drive ($(grep -E "^ssh\|-t" "$call_log"))"
assert '! grep -qF -- "--inject" "$call_log"' \
    "and wrote no block, because the .env it would go in was never rendered ($(calls))"
assert '[ ! -f "$project/.kasbah/state.json" ]' "a failed run records no last_server"
# The remedy has to be one that can reach this branch. `kasbah env` runs the
# setup whether or not there is drift, so --on-drift= is never consulted here:
# offering it would tell the operator to re-run the identical command for the
# identical exit 5 (docs/phases/02-spine.md — refusing safely while naming a
# remedy that cannot work).
assert '! grep -qF -- "--on-drift" <<<"$out"' \
    "the refusal offers no flag that cannot reach this branch (said '$out')"
assert 'grep -qF "already in sync" <<<"$out"' \
    "and says why nothing is required of the operator at all (said '$out')"

# stdin is the terminal; stdout is not. The generator's own prompts go to its
# stdout, so this one is genuinely unanswerable and the refusal is right.
TTY_ENV=(); env_cli_tty '' --redirect-stdout deploy@vps
assert '[ "$tty_rc" = "5" ]' \
    "a run whose stdout is a file cannot show the generator's prompts either (rc $tty_rc: $tty_out)"

# --- Case 4: headless with --on-drift=continue ----------------------------------
# The one scriptable shape: leave .env alone, refresh the managed block. This is
# what makes the injection half of the command usable from CI.
out=$( cd "$project" && ENV_MISSING=NEW_KEY env_cli deploy@vps --on-drift=continue ); rc=$?
assert '[ "$rc" = "0" ]' "--on-drift=continue needs no terminal (rc $rc: $out)"
assert 'grep -qF "has drifted" <<<"$out"' "and still reports the drift (said '$out')"
assert '! grep -qE "^ssh\|-t\|" "$call_log"' "without opening an interactive session"
assert 'grep -qF "setup-env.sh'\'' '\''--inject'\'' '\''/apps/demo'\'' '\''KASBAH_CPU_LIMIT=14.4'\'' '\''KASBAH_MEM_LIMIT=54g'\''" "$call_log"' \
    "the block carries the marker's own limits, unreformatted ($(grep -F -- "--inject" "$call_log"))"
assert '[ "$(jq -r .last_server "$project/.kasbah/state.json" 2>/dev/null)" = "deploy@vps" ]' \
    "and a run that worked records the server it went to"

# The order the two rsyncs and the probe have to be in: the generator prompts
# from the template and *is* the script, so both are on the server before
# anything asks the server a question about them.
n_template=$(grep -n "|-lpt|-s|.env.prod.example|" "$call_log" | head -1 | cut -d: -f1)
n_helper=$(grep -n "|$repo_dir/lib/env.sh|" "$call_log" | head -1 | cut -d: -f1)
n_drift=$(grep -n -- "--drift" "$call_log" | head -1 | cut -d: -f1)
n_inject=$(grep -n -- "--inject" "$call_log" | head -1 | cut -d: -f1)
assert '[ -n "$n_template" ] && [ -n "$n_helper" ] && [ -n "$n_drift" ] && [ -n "$n_inject" ]' \
    "the run made all four calls the order below is about (template $n_template, helper $n_helper, drift $n_drift, inject $n_inject)
        calls: $(calls)"
for n in n_template n_helper n_drift n_inject; do
    [ -n "${!n}" ] || printf -v "$n" '%s' 0
done
assert '[ "$n_drift" -gt "$n_template" ] && [ "$n_drift" -gt "$n_helper" ]' \
    "the template and the script are both on the server before it is asked about them"
assert '[ "$n_inject" -gt "$n_drift" ]' "and injection is last (drift $n_drift, inject $n_inject)"
assert 'grep -qF "|-pt|--chmod=F755|-s|$repo_dir/lib/env.sh|deploy@vps:/apps/demo/scripts/setup-env.sh" "$call_log"' \
    "setup-env.sh is lib/env.sh itself, shipped executable ($(grep -F "env.sh|" "$call_log"))"
rm -rf "$project/.kasbah"

out=$( cd "$project" && ENV_MISSING=NEW_KEY env_cli deploy@vps --on-drift=abort ); rc=$?
assert '[ "$rc" = "5" ]' "--on-drift=abort exits 5 (rc $rc: $out)"
assert '! grep -qF -- "--inject" "$call_log"' "changing nothing on the server ($(calls))"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and recording nothing locally"

# --- Case 5: behind a terminal, the setup runs ----------------------------------
# No drift, nothing passed: `kasbah env` runs the generator anyway, because
# that is what it is for — the generator's own "reconfigure anyway?" shortcut is
# the thing being reached (docs/env-template.md → Update modes).
env_cli_tty '' deploy@vps
assert '[ "$tty_rc" = "0" ]' "env behind a terminal exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qE "^ssh\|-t\|" "$call_log"' \
    "having asked ssh for a pty ($(grep -E "^ssh\|-t" "$call_log" | head -1))"
assert 'grep -qF "|'\''/apps/demo/scripts/setup-env.sh'\'' '\''/apps/demo'\''" "$call_log"' \
    "and run the shipped generator against the project directory ($(grep -E "^ssh\|-t" "$call_log" | head -1))"
n_setup=$(grep -n -- "-t|" "$call_log" | head -1 | cut -d: -f1)
n_inject=$(grep -n -- "--inject" "$call_log" | head -1 | cut -d: -f1)
assert '[ -n "$n_setup" ] && [ -n "$n_inject" ] && [ "$n_inject" -gt "$n_setup" ]' \
    "injection runs after setup, never before — setup rebuilds .env from a template with no reserved keys in it (setup $n_setup, inject $n_inject)"
rm -rf "$project/.kasbah"

# A generator that did not finish is not a .env to deploy against.
TTY_ENV=(SETUP_RC=1); env_cli_tty '' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "5" ]' "a setup that exits non-zero fails the command with 5 (rc $tty_rc: $tty_out)"
assert '! grep -qF -- "--inject" "$call_log"' "and no block is written after it ($(calls))"

# 5 is the step, not the cause: a setup-env.sh that could not be run at all
# (126 on a noexec mount, 127 with no interpreter) leaves the .env unwritten
# exactly as an aborted one does, and is the same code (lib/common.sh).
for setup_rc in 126 127; do
    TTY_ENV=(SETUP_RC=$setup_rc); env_cli_tty '' deploy@vps; TTY_ENV=()
    assert '[ "$tty_rc" = "5" ]' "a setup that could not run ($setup_rc) is exit 5 too (rc $tty_rc: $tty_out)"
    assert 'grep -qF "could not run at all" <<<"$tty_out"' \
        "and the refusal names that as one of the ways in (said '$tty_out')"
done

# The generator can also return 0 having written nothing — `q` at its menu, and
# the EOF path. Re-read rather than assumed.
TTY_ENV=(ENV_EXISTS=no); env_cli_tty '' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "5" ]' \
    "a setup that returns 0 leaving no .env still fails (rc $tty_rc: $tty_out)"
assert 'grep -qF "left no /apps/demo/.env" <<<"$tty_out"' "saying so (said '$tty_out')"
assert '! grep -qF -- "--inject" "$call_log"' "and writes no block into a file that is not there"

# --- Case 6: the tri-state prompt, which only exists behind a terminal ----------
TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty $'continue\n' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "0" ]' "answering continue at the drift prompt exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qF "setup/continue/abort" <<<"$tty_out"' "the prompt names its three answers (said '$tty_out')"
assert '! grep -qE "^ssh\|-t\|" "$call_log"' "and continue runs no setup ($(calls))"
assert 'grep -qF -- "--inject" "$call_log"' "but still refreshes the block"
rm -rf "$project/.kasbah"

TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty $'abort\n' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "5" ]' "answering abort exits 5 (rc $tty_rc: $tty_out)"
assert '! grep -qF -- "--inject" "$call_log"' "changing nothing ($(calls))"

TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty $'setup\n' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "0" ]' "answering setup exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qE "^ssh\|-t\|" "$call_log"' "and is the one answer that runs the generator ($(calls))"
rm -rf "$project/.kasbah"

# An answer that is none of the three is re-asked rather than taken for one of
# them — silently reading `yes` as `continue` would deploy against a .env the
# operator never approved.
TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty $'yes\nabort\n' deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "5" ]' "an unrecognised answer is not taken for one (rc $tty_rc: $tty_out)"
assert 'grep -qF "answer setup, continue or abort" <<<"$tty_out"' "it is re-asked (said '$tty_out')"
assert '[ "$(grep -c "setup/continue/abort" <<<"$tty_out")" = "2" ]' \
    "exactly once more (said '$tty_out')"

# Redirecting stdout does not take the question away. prompt_value asks on
# *stderr*, the way bash's own `read -p` does, and checks `[ -t 0 ]` and nothing
# else (lib/prompt.sh) — so `kasbah env user@vps > out.log` is answerable, and
# a guard here that also demanded `[ -t 1 ]` would refuse what
# `kasbah server init` accepts in the identical shape.
TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty $'continue\n' --redirect-stdout deploy@vps; TTY_ENV=()
assert '[ "$tty_rc" = "0" ]' \
    "the drift prompt is asked and answered with stdout on a file (rc $tty_rc: $tty_out)"
assert 'grep -qF "setup/continue/abort" <<<"$tty_out"' \
    "the question reached stderr, which is still the terminal (said '$tty_out')"
assert '! grep -qF "no terminal to ask on" <<<"$tty_out"' \
    "and nothing was refused for want of one (said '$tty_out')"
assert 'grep -qF -- "--inject" "$call_log"' "the run finished (calls: $(calls))"
rm -rf "$project/.kasbah"

# The flag still wins over the terminal: with one passed, nothing is asked.
TTY_ENV=(ENV_MISSING=NEW_KEY); env_cli_tty '' deploy@vps --on-drift=continue; TTY_ENV=()
assert '[ "$tty_rc" = "0" ]' "a flag answers the question a terminal would have asked (rc $tty_rc: $tty_out)"
assert '! grep -qF "setup/continue/abort" <<<"$tty_out"' "with no prompt at all (said '$tty_out')"
rm -rf "$project/.kasbah"

exit "$fail"
