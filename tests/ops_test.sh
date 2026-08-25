#!/usr/bin/env bash
# Test: lib/ops.sh — `kasbah logs` and `kasbah exec`.
#
# Both commands are one `docker compose` on the far side, so what a unit suite
# can prove is the command line: the flags, the positional-ambiguity rule they
# share, which of lib/ssh.sh's three run-helpers carries each one, and the exit
# status each returns. Everything runs end to end through `bin/kasbah` against a
# stub `ssh` that answers as a prepared server does and records every argument
# it was given — the composed line is read back out of that log and compared
# **whole**, because an assertion that only looks for a substring cannot tell a
# missing flag from an extra one.
#
# The one branch a captured command line cannot show is the terminal: `ssh -t`
# is asked for only when this side has a tty at both ends. That case is driven
# under script(1), which supplies one.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export NO_COLOR=1

# --- The fixture project ----------------------------------------------------------
project="$tmpdir/demo"
mkdir -p "$project"
cat > "$project/kasbah.yml" <<'YML'
schema: 1
kasbah_version: 0.1.0
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
YML

# A directory that is not a kasbah project at all, for the exit-2 case.
notproject="$tmpdir/elsewhere"
mkdir -p "$notproject"

# --- The stub server ---------------------------------------------------------------
# Two payloads, told apart by their arguments exactly as the real ones are: the
# marker read (ssh_script, so `bash -s --`) and the compose command (ssh_run /
# ssh_run_tty, so the words themselves).
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir" "$tmpdir/home" "$tmpdir/runtmp"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
last="${!#}"
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
case "$last" in
    true)
        if [ -n "${FAKE_UNREACHABLE:-}" ]; then
            printf 'ssh: connect to host vps port 22: Connection refused\n' >&2
            exit 255
        fi
        exit 0 ;;
    "'bash' '-s'"*) cat >/dev/null ;;
esac
case "$last" in
    "'bash' '-s' '--' '/apps' '/etc/kasbah/apps-path'")
        printf 'apps=/apps\nsource=default\n'
        [ -n "${FAKE_MARKER:-}" ] || exit 3
        printf '%s\n' '{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2.0","mem_limit":"4g"}' ;;
    "'docker' 'compose'"*)
        # Long enough to outrun any reader's buffer. The `|| exit 255` is what
        # makes this stub faithful: real OpenSSH *ignores* SIGPIPE and turns the
        # failed write into `fatal(): exit 255`, so a stub that died of the
        # signal (141) would have tested a number kasbah never sees. Measured
        # against the rig — see lib/ops.sh's cmd_logs.
        if [ -n "${FAKE_DC_LINES:-}" ]; then
            seq 1 "$FAKE_DC_LINES" || exit 255
            exit 0
        fi
        printf '%s\n' "${FAKE_DC_OUT:-demo-web  | listening on :8080}"
        exit "${FAKE_DC_RC:-0}" ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

call_log="$tmpdir/calls.log"
CRC=0; COUT=""; CERR=""
# `dc` is the whole command handed to the far side, quoted the way _ssh_quote
# quotes it. Compared verbatim below, never grepped for a fragment.
DC=""; DCALL=""
kasbah() {
    local rc=0 dir="${KASBAH_TEST_CWD:-$project}"
    : > "$call_log"
    ( cd "$dir" && env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
          HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/runtmp" \
          CALL_LOG="$call_log" \
          FAKE_DC_RC="${FAKE_DC_RC:-0}" FAKE_DC_OUT="${FAKE_DC_OUT:-}" \
          FAKE_UNREACHABLE="${FAKE_UNREACHABLE:-}" FAKE_MARKER="${FAKE_MARKER-1}" \
          "$repo_dir/bin/kasbah" "$@" ) >"$tmpdir/o" 2>"$tmpdir/e" </dev/null || rc=$?
    CRC=$rc; COUT="$(cat "$tmpdir/o")"; CERR="$(cat "$tmpdir/e")"
    DCALL="$(grep -F "'docker' 'compose'" "$call_log" 2>/dev/null || true)"
    DC="${DCALL##*|}"
    return 0
}
state_of() { jq -r ".$1 // \"\"" "$project/.kasbah/state.json" 2>/dev/null; }

# The same run, but with kasbah's stdout going into a reader that stops early —
# the one shape neither suite could produce while both redirected stdout to a
# file, and the one `docker compose logs | head` actually is. kasbah's own exit
# status is written to a file, because $? of a pipeline is the reader's.
PRC=""; POUT=""; PERR=""
kasbah_piped() {
    local reader="$1"; shift
    : > "$call_log"; rm -f "$tmpdir/prc"
    ( cd "$project" && env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
          HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/runtmp" \
          CALL_LOG="$call_log" FAKE_MARKER=1 FAKE_DC_LINES="${FAKE_DC_LINES:-50000}" \
          "$repo_dir/bin/kasbah" "$@" 2>"$tmpdir/e" </dev/null
      echo "$?" > "$tmpdir/prc" ) | $reader >"$tmpdir/o" 2>/dev/null
    PRC="$(cat "$tmpdir/prc" 2>/dev/null)"
    POUT="$(cat "$tmpdir/o")"; PERR="$(cat "$tmpdir/e")"
    return 0
}

# Something feeding kasbah's stdin, which `ssh -n` then throws away.
kasbah_fed() {
    local src="$1"; shift
    : > "$call_log"
    ( cd "$project" && env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
          HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/runtmp" \
          CALL_LOG="$call_log" FAKE_MARKER=1 \
          "$repo_dir/bin/kasbah" "$@" ) >"$tmpdir/o" 2>"$tmpdir/e" <"$src"
    CRC=$?; COUT="$(cat "$tmpdir/o")"; CERR="$(cat "$tmpdir/e")"
    return 0
}

# lib/ops.sh sourced into a subshell. One rule cannot be reached from the command
# line at all — `_ops_check_tail` is always handed a value the parser has already
# stripped — and a strip nothing exercises is a convention, not a behaviour.
ops_eval() (
    export KASBAH_LIB_DIR="$repo_dir/lib"
    export KASBAH_VERSION="$(cat "$repo_dir/VERSION")"
    # shellcheck disable=SC1090
    . "$repo_dir/lib/ops.sh"
    eval "$1"
)

cr=$'\r'

base="'docker' 'compose' '-f' '/apps/demo/compose.yml' '-p' 'demo'"

# ==================================================================================
# The rules, driven straight
# ==================================================================================
ops_eval "_ops_check_tail '5$cr'" >/dev/null 2>&1; trc=$?
assert '[ "$trc" = 0 ]' \
    "_ops_check_tail strips a CR before judging the count — a CRLF-authored script
     passing --tail=5 must not be told 5 is not a number (rc $trc)"
ops_eval "_ops_check_tail 'all'" >/dev/null 2>&1; trc=$?
assert '[ "$trc" = 0 ]' "and accepts compose's own 'all' (rc $trc)"
ops_eval "_ops_check_tail '5x'" >/dev/null 2>&1; trc=$?
assert '[ "$trc" != 0 ]' "while a count with anything else in it is refused (rc $trc)"

# ==================================================================================
# --help
# ==================================================================================
# Both usages are ~25 lines that nothing else reads, and a usage that has drifted
# from the flags is worse than none. Asserted on the flags it must name and on
# the fact that it costs no connection.
KASBAH_TEST_CWD="$notproject" kasbah logs --help
assert '[ "$CRC" = 0 ]' "kasbah logs --help exits 0 (rc $CRC: $CERR)"
assert 'grep -qxF "Usage: kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]" <<<"$COUT"' \
    "with the shape bin/kasbah and docs/cli.md both spell (got: $(head -1 <<<"$COUT"))"
assert 'grep -qF -- "--tail=N" <<<"$COUT"' "naming --tail (got '$COUT')"
assert '[ -z "$CERR" ]' "and nothing on stderr (stderr: '$CERR')"
assert '[ "$(grep -c "^ssh|" "$call_log")" = "0" ]' \
    "a usage costs no connection, and no project either (calls: $(cat "$call_log"))"

KASBAH_TEST_CWD="$notproject" kasbah exec --help
assert '[ "$CRC" = 0 ]' "kasbah exec --help exits 0 (rc $CRC: $CERR)"
assert 'grep -qxF "Usage: kasbah exec [USER@HOST] SERVICE -- CMD…" <<<"$COUT"' \
    "with the shape docs/cli.md spells (got: $(head -1 <<<"$COUT"))"
assert 'grep -qF "mandatory" <<<"$COUT"' "saying the separator is not optional (got '$COUT')"
assert '[ -z "$CERR" ]' "and nothing on stderr (stderr: '$CERR')"

# ==================================================================================
# kasbah logs
# ==================================================================================
rm -rf "$project/.kasbah"
kasbah logs deploy@vps
assert '[ "$CRC" = 0 ]' "kasbah logs runs against a prepared server (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=100'\''" ]' \
    "one compose command, in the project directory the marker names, with the default 100 lines
        wanted: $base 'logs' '--tail=100'
        got:    $DC"
assert '[ "$COUT" = "demo-web  | listening on :8080" ]' \
    "compose's own output reaches stdout unaltered (got '$COUT')"
assert '[ -z "$CERR" ]' "and nothing of kasbah's is on stderr (stderr: '$CERR')"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' \
    "a run that succeeded records the server (state: $(tr -d '\n' < "$project/.kasbah/state.json" 2>/dev/null))"
assert '[ "$(state_of last_version)" = "" ]' \
    "and touches nothing else — reading logs deploys nothing"

calls="$(<"$call_log")"
assert '[ "$(grep -c "^ssh|" <<<"$calls")" = "4" ]' \
    "logs opens one connection and asks two questions down it (calls: $calls)"
assert '! grep -qE "\|-t\|" <<<"$DCALL"' \
    "and asks for no pty — a terminal would put a CR before every LF of the log (call: $DCALL)"
assert 'grep -qE "\|-n\|" <<<"$DCALL"' \
    "stdin is closed instead: following a log takes no keystroke (call: $DCALL)"
assert '[ "$(grep -c "^rsync|" <<<"$calls")" = "0" ]' "nothing is shipped (calls: $calls)"
assert '! grep -qE "mkdir|rm |touch|tee" <<<"$calls"' \
    "and nothing is written on the server (calls: $calls)"

kasbah logs deploy@vps built-app-web
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=100'\'' '\''built-app-web'\''" ]' \
    "a service argument becomes compose's last word
        got: $DC"

kasbah logs deploy@vps --tail=5
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=5'\''" ]' \
    "--tail=5 replaces the default rather than joining it
        got: $DC"

kasbah logs deploy@vps --tail=all
assert '[ "$CRC" = 0 ]' "--tail=all is compose's own spelling and is passed through (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=all'\''" ]' "got: $DC"

kasbah logs deploy@vps -f
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=100'\'' '\''-f'\''" ]' \
    "-f follows, and is still not a reason to allocate a terminal
        got: $DC"
assert '! grep -qE "\|-t\|" <<<"$DCALL"' "(call: $DCALL)"

kasbah logs deploy@vps -f --tail=20 worker
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=20'\'' '\''-f'\'' '\''worker'\''" ]' \
    "all three together, service last
        got: $DC"

# The server is remembered, so the next run needs no argument — and a bare word
# is then the service, not a server kasbah could not parse.
kasbah logs
assert '[ "$CRC" = 0 ]' "the next run defaults to the remembered server (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=100'\''" ]' "got: $DC"
kasbah logs worker
assert '[ "$CRC" = 0 ]' "and one bare argument is the service (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=100'\'' '\''worker'\''" ]' \
    "read on the remembered server, not sent to a host called 'worker'
        got: $DC"

# --- logs: the refusals -------------------------------------------------------------
kasbah logs deploy@vps deploy@other
assert '[ "$CRC" != 0 ]' "two servers is one run too many (rc $CRC)"
assert 'grep -qF "two servers given" <<<"$CERR"' "and says so (got '$CERR')"
assert '[ -z "$DC" ]' "with no compose command composed at all (got '$DC')"

kasbah logs deploy@vps web api
assert '[ "$CRC" != 0 ]' "and so are two services (rc $CRC)"
assert 'grep -qF "two services given" <<<"$CERR"' "(got '$CERR')"

kasbah logs deploy@vps --tail=abc
assert '[ "$CRC" != 0 ]' "--tail= takes a count (rc $CRC)"
assert 'grep -qF "is not a number of lines" <<<"$CERR"' \
    "refused here rather than by compose on the far side (got '$CERR')"
assert '[ -z "$DC" ]' "and nothing reaches the server (got '$DC')"

kasbah logs deploy@vps --tail 5
assert '[ "$CRC" != 0 ]' "--tail without '=' is refused (rc $CRC)"
assert 'grep -qF "takes its value with" <<<"$CERR"' "naming the spelling that works (got '$CERR')"

kasbah logs deploy@vps --follow
assert '[ "$CRC" != 0 ]' "logs has no --follow (rc $CRC)"
assert 'grep -qF "unknown flag" <<<"$CERR"' "(got '$CERR')"

kasbah logs deploy@vps -f=1
assert '[ "$CRC" != 0 ]' "-f takes no value (rc $CRC)"
assert 'grep -qF "takes no value" <<<"$CERR"' \
    "and says so rather than calling a flag it has unknown (got '$CERR')"

# CRLF tolerance, end to end: a manifest, a script or a shell on Windows can put
# a CR on any of these, and both values go straight into the remote command line.
kasbah logs "deploy@vps$cr" "worker$cr" "--tail=5$cr"
assert '[ "$CRC" = 0 ]' "a CRLF-authored invocation runs (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''logs'\'' '\''--tail=5'\'' '\''worker'\''" ]' \
    "with the CR off the service and off the count, not carried onto the server
        wanted: $base 'logs' '--tail=5' 'worker'
        got:    $DC"

kasbah logs deploy@vps -- ls
assert '[ "$CRC" != 0 ]' "logs refuses a '--' (rc $CRC)"
assert 'grep -qF "logs runs none" <<<"$CERR"' \
    "because it runs no command of the caller's (got '$CERR')"

# --- logs: a compose that failed ------------------------------------------------------
# Aimed at a *second* host on purpose. Pointed at the one already recorded, a
# spurious write would rewrite byte-identical JSON — state_record is
# deterministic and carries no timestamp — and the assertion below would pass
# whether or not the guard it exists for is there.
state_before="$(cat "$project/.kasbah/state.json")"
FAKE_DC_RC=1 kasbah logs deploy@second nosuch
assert '[ "$CRC" = 1 ]' \
    "a compose that failed is kasbah's own failure — the whole line was kasbah's (rc $CRC)"
assert 'grep -qF "could not read the logs of demo on deploy@second" <<<"$CERR"' "(got '$CERR')"
assert 'grep -qF "nosuch" <<<"$CERR"' "naming the service it was given (got '$CERR')"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' \
    "and the run that failed does not become the remembered server (state says '$(state_of last_server)')"
assert '[ "$(cat "$project/.kasbah/state.json")" = "$state_before" ]' \
    "the state file is left exactly as it was"

# --- logs: a reader that stopped reading is not a failure -------------------------------
# `kasbah logs | head` is what docs/cli.md advertises. ssh does not die of
# SIGPIPE when the pipe closes under it — it ignores the signal and turns the
# failed write into a fatal, so the status is 255, not the 141 a local producer
# would give (see the stub above). Read as "compose failed", that printed a
# paragraph blaming compose after correct log lines.
kasbah_piped "head -1" logs deploy@vps
assert '[ "$PRC" = "255" ]' \
    "a reader that closed the pipe leaves ssh's 255 — passed through, not flattened to 0, so \`set -o pipefail\` stays honest (rc $PRC)"
assert '[ -z "$PERR" ]' \
    "and nothing at all on stderr: there is nothing wrong to report (stderr: '$PERR')"
assert '[ "$POUT" = "1" ]' "the reader got its line (got '$POUT')"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' \
    "the server answered, so it is still recorded (state says '$(state_of last_server)')"

kasbah_piped "grep -q 1" logs deploy@vps
assert '[ "$PRC" = "255" ]' "\`| grep -q\` is the same shape and the same answer (rc $PRC)"
assert '! grep -qF "could not read the logs" <<<"$PERR"' \
    "with no error blaming compose for a reader's exit (stderr: '$PERR')"

# The reader that does *not* stop early still gets the whole log and a 0.
kasbah_piped "cat" logs deploy@vps
assert '[ "$PRC" = "0" ]' "a reader that reads it all gets 0 (rc $PRC: $PERR)"
assert '[ "$(grep -c . <<<"$POUT")" = "50000" ]' \
    "and all of it — 255 is about the pipe closing, not about long output (lines: $(grep -c . <<<"$POUT"))"

# An interrupted run is the same verdict from the other direction. Driven by the
# stub's status, because that is the whole of what the branch reads.
FAKE_DC_RC=130 kasbah logs deploy@vps
assert '[ "$CRC" = "130" ]' "an interrupted run comes back as 130 (rc $CRC)"
assert '! grep -qF "could not read the logs" <<<"$CERR"' \
    "with no error paragraph — interrupted is not failed (got '$CERR')"

# And a status that is neither still gets the full diagnosis, so the case above
# is a narrow exemption rather than a blanket one.
FAKE_DC_RC=125 kasbah logs deploy@vps
assert '[ "$CRC" = "1" ]' "any other status is a real failure, reported as exit 1 (rc $CRC)"
assert 'grep -qF "exited 125" <<<"$CERR"' "naming what compose answered (got '$CERR')"

# --- logs: the two remote-state exits ---------------------------------------------------
FAKE_UNREACHABLE=1 kasbah logs deploy@other
assert '[ "$CRC" = 3 ]' "a server that does not answer exits 3 (rc $CRC: $CERR)"
assert 'grep -qF "cannot reach deploy@other" <<<"$CERR"' "(got '$CERR')"
assert '[ "$(cat "$project/.kasbah/state.json")" = "$state_before" ]' \
    "leaving the state file untouched"

FAKE_MARKER= kasbah logs deploy@vps
assert '[ "$CRC" = 4 ]' "a server with no marker exits 4 (rc $CRC: $CERR)"
assert 'grep -qF "no server marker at /apps/.kasbah/server.json" <<<"$CERR"' "(got '$CERR')"

KASBAH_TEST_CWD="$notproject" kasbah logs deploy@vps
assert '[ "$CRC" = 2 ]' "and a directory that is not a kasbah project exits 2 (rc $CRC: $CERR)"
assert 'grep -qF "No kasbah.yml" <<<"$CERR"' "(got '$CERR')"

rm -rf "$project/.kasbah"
kasbah logs
assert '[ "$CRC" != 0 ]' "logs with no server and no memory of one stops (rc $CRC)"
assert 'grep -qF "never deployed to one" <<<"$CERR"' "saying to pass it once (got '$CERR')"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and writes no state file"

# ==================================================================================
# kasbah exec
# ==================================================================================
kasbah exec deploy@vps built-app-web -- sh -c 'echo hi'
assert '[ "$CRC" = 0 ]' "kasbah exec runs (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''exec'\'' '\''-T'\'' '\''built-app-web'\'' '\''sh'\'' '\''-c'\'' '\''echo hi'\''" ]' \
    "docker compose exec, with -T because this side has no terminal, and the
     command's words kept apart
        wanted: $base 'exec' '-T' 'built-app-web' 'sh' '-c' 'echo hi'
        got:    $DC"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' "and the server is recorded"

# The quoting case: one argument carrying spaces, quotes and a glob has to reach
# the far side as one argument. ssh re-joins its arguments with spaces before a
# login shell sees them, so this is the whole of what _ssh_quote is for.
payload='echo "a b" *.txt '"'"'q'"'"' > /tmp/x'
kasbah exec deploy@vps web -- sh -c "$payload"
assert '[ "$CRC" = 0 ]' "a command with spaces, quotes and a glob runs (rc $CRC: $CERR)"
want_dc="$base 'exec' '-T' 'web' 'sh' '-c' 'echo \"a b\" *.txt '\''q'\'' > /tmp/x'"
assert '[ "$DC" = "$want_dc" ]' \
    "and arrives as a single word, its quoting intact
        wanted: $want_dc
        got:    $DC"

# A flag after `--` belongs to the command. That is what the separator is for,
# and it is the one thing that cannot be tested by asserting on a success line.
kasbah exec deploy@vps web -- ls -la /srv
assert '[ "$CRC" = 0 ]' "a flag after -- does not reach kasbah's parser (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''exec'\'' '\''-T'\'' '\''web'\'' '\''ls'\'' '\''-la'\'' '\''/srv'\''" ]' \
    "got: $DC"

# The remembered server, and the ambiguity rule shared with logs.
kasbah exec web -- true
assert '[ "$CRC" = 0 ]' "exec defaults to the remembered server (rc $CRC: $CERR)"
assert '[ "$DC" = "$base '\''exec'\'' '\''-T'\'' '\''web'\'' '\''true'\''" ]' "got: $DC"
kasbah exec deploy@vps deploy@other web -- true
assert '[ "$CRC" != 0 ]' "two servers is still one too many (rc $CRC)"
assert 'grep -qF "two servers given" <<<"$CERR"' \
    "which is the same rule logs applies, from the same function (got '$CERR')"

# --- exec: the status of the command it ran ------------------------------------------
FAKE_DC_RC=42 kasbah exec deploy@vps web -- sh -c 'exit 42'
assert '[ "$CRC" = 42 ]' \
    "the command's own exit status is exec's exit status, not 0 and not 1 (rc $CRC: $CERR)"
assert '[ -z "$CERR" ]' \
    "and kasbah adds no error of its own to a command that simply answered (stderr: '$CERR')"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' \
    "the server is recorded anyway: kasbah's own work succeeded the moment the command ran"

# --- exec: stdin goes nowhere, and says so ---------------------------------------------
# `echo x | kasbah exec web -- cat` prints nothing and exits 0, which looks like
# it worked. A warning rather than a refusal, because `kasbah exec … < /dev/null`
# is an ordinary scripted call and must stay silent.
printf 'x\n' > "$tmpdir/feed"
kasbah_fed "$tmpdir/feed" exec deploy@vps web -- cat
assert '[ "$CRC" = 0 ]' "a fed exec still runs (rc $CRC: $CERR)"
assert 'grep -qF "stdin is not forwarded" <<<"$CERR"' \
    "and warns that what was fed to it went nowhere (got '$CERR')"
assert 'grep -qF "docker compose exec -T" <<<"$CERR"' \
    "naming why (got '$CERR')"

mkfifo "$tmpdir/fifo" 2>/dev/null || true
if [ -p "$tmpdir/fifo" ]; then
    ( printf 'x\n' > "$tmpdir/fifo" ) &
    kasbah_fed "$tmpdir/fifo" exec deploy@vps web -- cat
    wait $! 2>/dev/null
    assert 'grep -qF "stdin is not forwarded" <<<"$CERR"' \
        "a pipe is warned about as well as a file (got '$CERR')"
fi
rm -f "$tmpdir/fifo"

kasbah exec deploy@vps web -- cat
assert '[ -z "$CERR" ]' \
    "while </dev/null — the scripted call — says nothing at all (stderr: '$CERR')"

# --- exec: the mandatory separator -----------------------------------------------------
kasbah exec deploy@vps web
assert '[ "$CRC" != 0 ]' "exec with no -- at all stops (rc $CRC)"
assert 'grep -qF "no '\''--'\'' in the arguments" <<<"$CERR"' "naming the separator (got '$CERR')"
assert '[ -z "$DC" ]' "before any connection is made (got '$DC')"
assert '[ "$(grep -c "^ssh|" "$call_log")" = "0" ]' \
    "and before any ssh at all (calls: $(cat "$call_log"))"

kasbah exec deploy@vps web ls
assert '[ "$CRC" != 0 ]' "a command written without the -- stops (rc $CRC)"
assert 'grep -qF "comes after the service" <<<"$CERR"' \
    "and is answered as a missing separator, not as a second service (got '$CERR')"
assert 'grep -qF -- "-- ls" <<<"$CERR"' "showing where it belongs (got '$CERR')"

kasbah exec deploy@vps web ls -la
assert '[ "$CRC" != 0 ]' "so does a flag written without it (rc $CRC)"
assert 'grep -qF "comes after the service" <<<"$CERR"' "(got '$CERR')"

kasbah exec deploy@vps -la -- ls
assert '[ "$CRC" != 0 ]' "a flag exec does not know is refused (rc $CRC)"
assert 'grep -qF "unknown flag '\''-la'\''" <<<"$CERR"' "(got '$CERR')"
assert 'grep -qF -- "-- CMD" <<<"$CERR"' \
    "pointing at the shape that would have worked (got '$CERR')"

kasbah exec deploy@vps --tail=5 web -- ls
assert '[ "$CRC" != 0 ]' "exec has no --tail (rc $CRC)"
assert 'grep -qF "unknown flag '\''--tail'\''" <<<"$CERR"' "(got '$CERR')"

kasbah exec deploy@vps -- ls
assert '[ "$CRC" != 0 ]' "exec with no service stops (rc $CRC)"
assert 'grep -qF "no service given" <<<"$CERR"' "(got '$CERR')"
assert '[ -z "$DC" ]' "without connecting (got '$DC')"

kasbah exec deploy@vps web --
assert '[ "$CRC" != 0 ]' "and so does a -- with nothing after it (rc $CRC)"
assert 'grep -qF "nothing after the '\''--'\''" <<<"$CERR"' \
    "rather than opening a shell nobody asked for (got '$CERR')"

# ==================================================================================
# The terminal branch
# ==================================================================================
# `ssh -t` allocates a pty only when the local stdin is one, so this is the only
# way to reach the other half of _ops_exec_run: script(1) supplies a terminal at
# both ends. Under it exec asks ssh for `-t` and drops compose's `-T` — the two
# halves of one decision, which is why both are asserted.
if command -v script >/dev/null; then
    runner="$tmpdir/under-tty.sh"
    cat > "$runner" <<RUNNER
#!/usr/bin/env bash
cd "$project" || exit 9
exec env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \\
    HOME="$tmpdir/home" PATH="$stub_dir:\$PATH" TMPDIR="$tmpdir/runtmp" \\
    CALL_LOG="$call_log" FAKE_MARKER=1 NO_COLOR=1 \\
    "$repo_dir/bin/kasbah" "\$@"
RUNNER
    chmod 0755 "$runner"

    : > "$call_log"
    script -qec "$runner exec deploy@vps web -- sh -c 'echo hi'" /dev/null >"$tmpdir/o" 2>&1
    trc=$?
    tcall="$(grep -F "'docker' 'compose'" "$call_log" 2>/dev/null || true)"
    tdc="${tcall##*|}"
    assert '[ "$trc" = 0 ]' "exec runs with a terminal at both ends (rc $trc: $(cat "$tmpdir/o"))"
    assert 'grep -qE "\|-t\|" <<<"$tcall"' \
        "asking ssh for a pty, which is what an interactive command needs (call: $tcall)"
    assert '[ "$tdc" = "$base '\''exec'\'' '\''web'\'' '\''sh'\'' '\''-c'\'' '\''echo hi'\''" ]' \
        "and dropping compose's -T, which is the same decision spelled on the far side
        got: $tdc"

    # Stdout redirected is the case -T exists for: a pty would put a CR before
    # every LF of whatever the command writes into the file.
    : > "$call_log"
    script -qec "$runner exec deploy@vps web -- sh -c 'echo hi' > $tmpdir/redirected" /dev/null \
        >/dev/null 2>&1
    rcall="$(grep -F "'docker' 'compose'" "$call_log" 2>/dev/null || true)"
    rdc="${rcall##*|}"
    assert '! grep -qE "\|-t\|" <<<"$rcall"' \
        "a terminal on stdin alone is not enough: with stdout redirected there is no pty (call: $rcall)"
    assert '[ "$rdc" = "$base '\''exec'\'' '\''-T'\'' '\''web'\'' '\''sh'\'' '\''-c'\'' '\''echo hi'\''" ]' \
        "got: $rdc"
else
    echo "  note: script(1) is not installed — the pty branch of exec was not exercised" >&2
fi

exit "$fail"
