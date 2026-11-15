#!/usr/bin/env bash
# Test: the trace and the log a failure saves (docs/cli.md "Debugging a
# failure"). A stand-in ssh plays the server by running the remote command
# here — the bootstrap probe for real, and the binary under test as the
# server's, so `kasbah remote` arms run as they do on a VPS and send their
# trace back — and a stand-in docker fails the server's compose call with a
# line on stderr. Without --debug the output is the error and one line naming
# the log; --debug and KASBAH_DEBUG=1 stream the trace; the log is named for
# the command, 0600 in a 0700 directory, holds the workstation's and the
# server's halves and never a .env value, a value sent on stdin or a seed's;
# the newest 20 logs are kept; Ctrl-C leaves one; a child kasbah saves none.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir" "$tmpdir/home" "$tmpdir/tmp"
export XDG_STATE_HOME="$tmpdir/state"
logs="$XDG_STATE_HOME/kasbah/logs"
SSH_LOG="$tmpdir/ssh.log"
: >"$SSH_LOG"

# The server: an apps tree with a marker, this build's binary at the shared
# path (the same-build rule keeps it), and the project with a .env holding a
# secret of its own.
FAKE_APPS="$tmpdir/srv/apps"
mkdir -p "$FAKE_APPS/.kasbah/bin" "$FAKE_APPS/demo"
printf '{"kasbah_version":"1.0.0","apps_path":"%s","data_path":"%s/data","cpu_limit":"1","mem_limit":"1g"}\n' \
    "$FAKE_APPS" "$FAKE_APPS" >"$FAKE_APPS/.kasbah/server.json"
cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"
printf 'API_SECRET=\nDB_PASSWORD=\n' >"$FAKE_APPS/demo/.env.prod.example"
printf 'API_SECRET=old-api-value-17\nDB_PASSWORD=planted-env-secret-42\n' >"$FAKE_APPS/demo/.env"
printf 'services:\n  web:\n    image: nginx:alpine\n' >"$FAKE_APPS/demo/compose.yml"

cat >"$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
last="${!#}"
if [ "$last" = true ]; then
    [ -z "${SSH_HANG:-}" ] || { echo $$ > "$SSH_HANG"; exec sleep 30; }
    exit 0
fi
eval "set -- $last"
if [ "$1 $2" = "sh -s" ]; then
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7" "${8:-}"
fi
exec "$@"
STUB
# The server's compose call fails, echoing what it was given as compose can.
cat >"$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = compose ]; then
    echo "compose: service web failed to start: API_SECRET=$(sed -n 's/^API_SECRET=//p' .env)" >&2
    exit 1
fi
exit 0
STUB
chmod 0755 "$stub_dir/ssh" "$stub_dir/docker"

project="$tmpdir/demo"
mkdir -p "$project"
printf 'schema: 1\nkasbah_version: 0.1.0\nname: demo\ndomain: demo.test\nsync:\n  - .env.prod.example\n' >"$project/kasbah.yml"
printf 'API_SECRET=\nDB_PASSWORD=\n' >"$project/.env.prod.example"

# ks ARGS… — kasbah in the project, the stand-ins first on PATH, stdin from
# $IN, stdout and stderr apart.
ks() {
    (cd "$project" && printf '%s' "${IN:-}" | env PATH="$stub_dir:$PATH" HOME="$tmpdir/home" TMPDIR="$tmpdir/tmp" \
        SSH_LOG="$SSH_LOG" FAKE_APPS="$FAKE_APPS" NO_COLOR=1 "$KASBAH_BIN" "$@") >"$tmpdir/out" 2>"$tmpdir/err"
}
newest() { ls "$logs" 2>/dev/null | grep '\.log$' | tail -n 1; }
count() { ls "$logs" 2>/dev/null | grep -c '\.log$'; }
secrets='new-stdin-value-99|planted-env-secret-42|old-api-value-17|seeded-value-55'
leaks() { grep -aoE "$secrets" "$@" | sort -u | tr '\n' ' '; }

# --- Case 1: a failure without --debug: the error, then the log's line ------------
IN='new-stdin-value-99' ks env set API_SECRET deploy@vps --restart; rc=$?
err="$(cat "$tmpdir/err")"
last="$(tail -n 1 "$tmpdir/err")"
assert '[ "$rc" = 1 ]' "a compose failure on the server fails env set (rc $rc: $err)"
assert 'grep -qF "compose: service web failed to start" <<<"$err"' "the server's own stderr still reaches the operator ($err)"
assert '[[ $last == "       log: $logs/"*"-env-set.log" ]]' "the last line names the log, indented under the error (got '$last')"
assert '[ "$(grep -c "log: " <<<"$err")" = 1 ]' "one log line ($err)"
assert '! grep -qF "debug:" <<<"$err" && ! grep -qaF $'"'"'\x1e'"'"' "$tmpdir/err" && ! grep -qaF "kasbah-trace" "$tmpdir/err"' \
    "no trace line, and no server frame, reaches stderr without --debug ($err)"
assert '[ ! -s "$tmpdir/out" ]' "nothing on stdout ($(cat "$tmpdir/out"))"
log="${last#       log: }"
assert '[ -f "$log" ] && [ "$(newest)" = "$(basename "$log")" ]' "the log named is there ($(ls "$logs" 2>&1))"
assert '[[ $(basename "$log") =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{3}Z-env-set\.log$ ]]' "named <UTC time>-<command>.log ($(basename "$log"))"
assert '[ "$(stat -c %a "$log")" = 600 ] && [ "$(stat -c %a "$logs")" = 700 ] && [ "$(stat -c %a "$XDG_STATE_HOME/kasbah")" = 700 ]' \
    "the log 0600 in 0700 directories ($(stat -c %a "$log" "$logs" "$XDG_STATE_HOME/kasbah" | tr '\n' ' '))"
body="$(cat "$log")"
assert '[ "$(sed -n 1p "$log")" = "$("$KASBAH_BIN" --version)" ] && [ "$(sed -n 2p "$log")" = "command: kasbah env set API_SECRET deploy@vps --restart" ] &&
    grep -qE "^started: [0-9T:-]+Z$" "$log" && grep -qx "exit: 1" "$log"' "the header: version, command line, start, exit code ($(head -n 5 "$log"))"
for want in "ssh (connect) deploy@vps: true" "ssh (script on stdin) deploy@vps: sh -s --" \
    "note: server binary $FAKE_APPS/.kasbah/bin/kasbah kept" \
    "$FAKE_APPS/.kasbah/bin/kasbah remote setup-env set $FAKE_APPS/demo API_SECRET --up=demo" \
    "server: [1] run: docker compose -p demo up -d  (in $FAKE_APPS/demo)" \
    "] stderr: compose: service web failed to start: API_SECRET=***" "server: [1] exit 1 after "; do
    assert 'grep -qF -- "$want" <<<"$body"' "the log holds '$want'"
done
assert '[ -z "$(leaks "$log")" ]' "no secret in the log (found: $(leaks "$log"))"
assert 'grep -q "remote.*setup-env.*set.* --trace" "$SSH_LOG"' "the server arm was asked for its trace ($(grep setup-env "$SSH_LOG"))"
assert '! grep -q "sh -s.*--trace\|true --trace" "$SSH_LOG"' "the probe and the connect never were"

# --- Case 2: --debug streams the trace, and saves a log even on success ---------
IN='new-stdin-value-99' ks env set API_SECRET deploy@vps --restart --debug; rc=$?
assert '[ "$rc" = 1 ]' "--debug changes no exit code (rc $rc)"
dbg="$(grep "^debug: " "$tmpdir/err")"
assert 'grep -qF "] ssh deploy@vps: " <<<"$dbg" && grep -qF "server: [1] run: docker compose -p demo up -d" <<<"$dbg"' \
    "the workstation's and the server's lines stream as they happen ($dbg)"
assert '[ -z "$(leaks <<<"$dbg")" ]' "no secret in the stream (found: $(leaks <<<"$dbg"))"
assert '[[ $(tail -n 1 "$tmpdir/err") == "       log: $logs/"*"-env-set.log" ]]' "a failure still ends on the log line ($(tail -n 1 "$tmpdir/err"))"
assert '[ "$(grep -v "^debug: \|^       log: " "$tmpdir/err")" = "$(grep -v "^       log: " <<<"$err")" ]' \
    "less its debug: lines, stderr is the run without --debug's (got $(grep -v "^debug: " "$tmpdir/err"))"

n=$(count)
KASBAH_DEBUG=1 ks info; rc=$?
assert '[ "$rc" = 0 ] && grep -q "^debug: log: $logs/.*-info\.log$" "$tmpdir/err"' "KASBAH_DEBUG=1 is --debug, and a success saves a log too (rc $rc: $(cat "$tmpdir/err"))"
assert '[ "$(count)" = $((n + 1)) ]' "one log more ($(count), was $n)"
assert 'grep -qx "logs: $logs" "$tmpdir/out"' "info names the log directory ($(cat "$tmpdir/out"))"
ks info; rc=$?
assert '[ "$rc" = 0 ] && [ ! -s "$tmpdir/err" ] && [ "$(count)" = $((n + 1)) ]' "without it info writes nothing to stderr and no log (rc $rc: $(cat "$tmpdir/err"))"
assert 'grep -qx "logs.last: $logs/$(newest)" "$tmpdir/out"' "and names the newest log ($(grep logs.last "$tmpdir/out"))"
KASBAH_DEBUG=0 ks info; rc=$?
assert '[ "$rc" = 0 ] && [ ! -s "$tmpdir/err" ]' "KASBAH_DEBUG=0 is off ($(cat "$tmpdir/err"))"
# A child kasbah (here __install's --version probe of the dist it installs)
# does not inherit the debug run: one log, one line naming it.
mkdir -p "$tmpdir/dist"
cp "$KASBAH_BIN" "$tmpdir/dist/kasbah"
n=$(count)
KASBAH_LIB_DIR="$tmpdir/home/lib" KASBAH_BIN_DIR="$tmpdir/home/bin" XDG_DATA_HOME="$tmpdir/home/share" \
    KASBAH_DEBUG=1 ks __install "$tmpdir/dist"
assert 'grep -qF -- "--version" "$tmpdir/err" && [ "$(grep -c "log: " "$tmpdir/err")" = 1 ] && [ "$(count)" = $((n + 1)) ]' \
    "a --version probe saves no log of its own ($(count) logs, was $n: $(grep "log: \|--version" "$tmpdir/err"))"
ks --debug --version; rc=$?
assert '[ "$rc" = 0 ] && [ "$(cat "$tmpdir/out")" = "$("$KASBAH_BIN" --version)" ]' "--debug goes before any command ($(cat "$tmpdir/out"))"
ks --help; rc=$?
assert 'grep -qF -- "--debug" "$tmpdir/out" && grep -qF "KASBAH_DEBUG=1" "$tmpdir/out"' "kasbah --help documents --debug"
ks help debug; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "cli.md#debugging-a-failure" "$tmpdir/out"' "kasbah help debug ends on its doc (rc $rc)"

# --- Case 3: a seed's values stay out of the log ----------------------------------
printf 'API_SECRET=seeded-value-55\nDB_PASSWORD=planted-env-secret-42\n' >"$tmpdir/seed"
chmod 600 "$tmpdir/seed"
rm -f "$FAKE_APPS/demo/.env"
ks env deploy@vps --env-seed="$tmpdir/seed" --debug; rc=$?
log="$logs/$(newest)"
assert '[[ $log == *-env.log ]] && grep -qF "remote setup-env setup" "$log"' "kasbah env renders from the seed, traced ($log, rc $rc: $(grep -v '^debug' "$tmpdir/err"))"
assert 'grep -q "remote.*setup-env.*setup.* --trace" "$SSH_LOG"' "the headless setup, its stdout on stderr, still asked for the server's trace ($(grep setup-env "$SSH_LOG"))"
assert 'grep -qx "API_SECRET=seeded-value-55" "$FAKE_APPS/demo/.env"' "the server's .env holds the seed ($(cat "$FAKE_APPS/demo/.env" 2>&1))"
assert '[ -z "$(leaks "$log" "$tmpdir/err" "$tmpdir/out")" ]' "no seed value in the log or the output (found: $(leaks "$log" "$tmpdir/err" "$tmpdir/out"))"

# --- Case 4: the newest 20 are kept ---------------------------------------------
for i in $(seq -w 1 25); do : >"$logs/20200101T0000$i.000Z-old.log"; done
: >"$logs/notes.txt"
IN='x' ks env set API_SECRET deploy@vps --restart; rc=$?
assert '[ "$rc" = 1 ] && [ "$(count)" = 20 ] && [ -e "$logs/notes.txt" ]' "20 logs kept, a file that is no log left alone ($(count) logs)"
assert '[ ! -e "$logs/20200101T000001.000Z-old.log" ] && [[ $(newest) == *-env-set.log ]]' "the oldest went, the newest is this run's ($(ls "$logs" | head -n 2 | tr '\n' ' '))"

# --- Case 5: Ctrl-C leaves a log and names it ------------------------------------
hang="$tmpdir/hang.pid"
(cd "$project" && exec env PATH="$stub_dir:$PATH" HOME="$tmpdir/home" TMPDIR="$tmpdir/tmp" SSH_HANG="$hang" \
    SSH_LOG="$SSH_LOG" FAKE_APPS="$FAKE_APPS" NO_COLOR=1 "$KASBAH_BIN" env set API_SECRET deploy@vps --no-restart \
    <<<"x" >"$tmpdir/out" 2>"$tmpdir/err") &
pid=$!
for _ in $(seq 100); do [ -s "$hang" ] && break; sleep 0.1; done
kill -INT "$pid"
wait "$pid"; rc=$?
[ -s "$hang" ] && kill "$(cat "$hang")" 2>/dev/null
assert '[ "$rc" = 130 ]' "Ctrl-C exits 130 (rc $rc)"
assert 'grep -q "^log: $logs/.*-env-set\.log$" "$tmpdir/err"' "and names the log it saved ($(cat "$tmpdir/err"))"
log="$logs/$(newest)"
assert 'grep -qx "exit: 130" "$log" && grep -qF "ssh (connect) deploy@vps: true" "$log"' "which holds the call it stopped in ($(cat "$log"))"
assert '[ -z "$(ls "$tmpdir/tmp")" ]' "and nothing left in TMPDIR ($(ls "$tmpdir/tmp"))"

exit "$fail"
