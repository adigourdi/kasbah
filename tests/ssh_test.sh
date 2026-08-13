#!/usr/bin/env bash
# Test: lib/ssh.sh — target validation, the control options every call carries,
# quoting, and teardown. A unit suite: no rig, no network, no Docker.
#
# Hermetic the same way tests/rig_test.sh is: recording stubs for `ssh` and
# `rsync` go first on PATH, so nothing here can open a socket and the suite
# passes on a machine with neither a rig nor Docker. What the stubs record is
# the whole point — the argv hosting builds is the contract with the far side.

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

# --- Stubs --------------------------------------------------------------------
stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir"
log="$tmpdir/calls.log"
log_all="$tmpdir/calls.all.log"
payload="$tmpdir/payload.in"
: > "$log"; : > "$log_all"

# One block per call, one line per argument: an argument that contains spaces
# (the whole quoted remote command is one) stays a single line, so assertions
# can match it whole instead of guessing where a field ended.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'BEGIN ssh\n'
  for a in "$@"; do printf 'ARG:%s\n' "$a"; done
  printf 'END\n'
} | tee -a "$SSH_STUB_LOG_ALL" >> "$SSH_STUB_LOG"
# Only the script runner feeds stdin; reading it unconditionally would also
# capture the empty stdin of the teardown call and overwrite the payload.
case "$*" in
    *bash*-s*) cat > "$SSH_STUB_STDIN" ;;
esac
if [ -n "${SSH_STUB_RC:-}" ] && [ "$SSH_STUB_RC" != 0 ]; then
    echo "ssh: connect to host ${*: -2:1} port 22: Connection refused" >&2
    exit "$SSH_STUB_RC"
fi
exit 0
STUB

cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
{ printf 'BEGIN rsync\n'
  for a in "$@"; do printf 'ARG:%s\n' "$a"; done
  printf 'END\n'
} | tee -a "$SSH_STUB_LOG_ALL" >> "$SSH_STUB_LOG"
exit 0
STUB
chmod 0755 "$stub_dir/ssh" "$stub_dir/rsync"
# In front for the suite itself as well as for the driver: an assertion that
# reached a real ssh would be a test opening a socket.
export PATH="$stub_dir:$PATH"

fakehome="$tmpdir/home"

# Runs a snippet against the real lib with the stubs in front. Arguments before
# `--` are env assignments for that run. $HOME is rebuilt empty each time, so
# "ssh_connect creates ~/.ssh" is asserted against a directory that was not
# there a moment ago. Sets: rc, out, err.
run_driver() {
    local env_args=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_args+=("$1"); shift; done
    [ $# -eq 0 ] || shift

    { printf '%s\n' 'set -euo pipefail' \
                    '. "$HOSTING_LIB_DIR/common.sh"' \
                    '. "$HOSTING_LIB_DIR/ssh.sh"'
      cat; } > "$tmpdir/case.sh"

    : > "$log"
    rm -f "$payload"
    rm -rf "$fakehome"; mkdir -p "$fakehome"

    out=$(env -u SSH_STUB_RC \
              HOME="$fakehome" PATH="$stub_dir:$PATH" \
              HOSTING_LIB_DIR="$repo_dir/lib" \
              SSH_STUB_LOG="$log" SSH_STUB_LOG_ALL="$log_all" SSH_STUB_STDIN="$payload" \
              "${env_args[@]+"${env_args[@]}"}" \
              bash "$tmpdir/case.sh" 2>"$tmpdir/err")
    rc=$?
    err=$(<"$tmpdir/err")
}

# The nth recorded call, BEGIN..END. Per-call scoping matters where an option
# also appears on a neighbouring call: ssh_connect passes -n too, so "ssh_run
# passes -n" is only a real assertion when it is asked of ssh_run's own block.
call_block() { awk -v n="$1" '/^BEGIN /{c++} c==n' "$log"; }

assert '[ "$(command -v ssh)" = "$stub_dir/ssh" ]' \
    "the stub ssh shadows any real one (command -v ssh gives $(command -v ssh))"

# --- Case 1: target validation ------------------------------------------------
# A target that ssh would reject is rejected here first, where the message can
# say what shape was expected instead of surfacing as a DNS failure.
while read -r target want_user want_host; do
    [ -n "$target" ] || continue
    run_driver -- <<EOS
ssh_target_parse '$target'
printf 'user=%s host=%s target=%s\n' "\$SSH_USER" "\$SSH_HOST" "\$SSH_TARGET"
EOS
    assert '[ "$rc" = "0" ]' "'$target' is accepted (exit $rc: $err)"
    assert '[ "$out" = "user=$want_user host=$want_host target=$target" ]' \
        "'$target' parses into user and host (got '$out')"
done <<'TARGETS'
deploy@vps.example.com deploy vps.example.com
stevedore@rig stevedore rig
root@10.0.0.1 root 10.0.0.1
deploy-user_1.x@host-1 deploy-user_1.x host-1
TARGETS

for target in '' 'vps.example.com' 'deploy@' '@vps.example.com' 'deploy@vps:2222' \
              'deploy@a@b' 'deploy@[::1]' 'deploy@-vps.example.com'; do
    run_driver -- <<EOS
ssh_target_parse '$target'
echo "parsed=\$SSH_TARGET"
EOS
    assert '[ "$rc" != "0" ]'                  "'$target' is rejected (exit $rc, out '$out')"
    assert 'grep -qF "error:" <<<"$err"'       "'$target' is rejected with an error line (got '$err')"
    assert '[ ! -s "$log" ]'                   "'$target' is rejected before any ssh call (calls: $(cat "$log"))"
done

# A target with a Windows line ending — a value read out of a file or a CRLF
# manifest — is the same target.
run_driver -- <<'EOS'
ssh_target_parse "$(printf 'deploy@vps.example.com\r')"
printf 'target=%s\n' "$SSH_TARGET"
EOS
assert '[ "$out" = "target=deploy@vps.example.com" ]' "a trailing CR is stripped from the target (got '$out')"

# --- Case 2: the control options, on every call -------------------------------
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_run docker ps
ssh_rsync -a /tmp/x/ 'deploy@vps.example.com:/apps/x/'
ssh_disconnect
EOS
assert '[ "$rc" = "0" ]' "a connect/run/rsync/disconnect sequence succeeds (exit $rc: $err)"

calls=$(<"$log")
assert 'grep -qxF "ARG:ControlMaster=auto" <<<"$calls"'          "ControlMaster=auto is passed"
assert 'grep -qxF "ARG:ControlPath=$fakehome/.ssh/cm-%C" <<<"$calls"' \
    "the control path is the %C hash under \$HOME, not a ~ ssh would expand elsewhere"
assert 'grep -qxF "ARG:ControlPersist=60s" <<<"$calls"'          "ControlPersist=60s is passed"
assert 'grep -qxF "ARG:ConnectTimeout=10" <<<"$calls"'           "ConnectTimeout=10 is on the command line"
# ConnectTimeout bounds setup only; these bound an established session that
# goes quiet, which is the unbounded hang docs/phases/01-rig.md records.
assert 'grep -qxF "ARG:ServerAliveInterval=15" <<<"$calls"'      "ServerAliveInterval bounds a stalled session"
assert 'grep -qxF "ARG:ServerAliveCountMax=4" <<<"$calls"'       "ServerAliveCountMax bounds a stalled session"
# Substring, not "ARG:BatchMode": the stub logs one argument per line, so
# "ARG:-o BatchMode" could never match whatever the code did, and the check
# would pass with -o BatchMode=yes right there in the options.
assert '! grep -qiF "BatchMode" <<<"$calls"' \
    "BatchMode is not forced anywhere — a passphrase-protected key with an agent must keep working"
assert '! grep -qF "%r@%h:%p" <<<"$calls"' \
    "the control path never uses %r@%h:%p (a long hostname overruns the socket path limit)"

# Every ssh call, not just the first: a later one that lost the options would
# open a second connection and defeat the whole point.
ssh_calls=$(grep -c '^BEGIN ssh$' <<<"$calls")
ssh_with_path=$(grep -c "^ARG:ControlPath=$fakehome/\.ssh/cm-%C$" <<<"$calls")
assert '[ "$ssh_calls" -gt 1 ]'                  "several ssh calls were made (else the check below is vacuous)"
assert '[ "$ssh_calls" = "$ssh_with_path" ]'     "every ssh call carries the control path ($ssh_with_path of $ssh_calls)"

expected_e="ARG:ssh -o ControlMaster=auto -o ControlPath=$fakehome/.ssh/cm-%C -o ControlPersist=60s -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
rsync_e=$(grep -cxF "$expected_e" <<<"$calls")
assert '[ "$rsync_e" = "1" ]' \
    "rsync reuses the same master through -e (got: $(grep '^ARG:ssh ' <<<"$calls"))"
assert 'grep -qxF "ARG:-a" <<<"$calls"'                             "rsync's own arguments are passed through"
assert 'grep -qxF "ARG:deploy@vps.example.com:/apps/x/" <<<"$calls"' "rsync's destination is passed through"

assert '[ -d "$fakehome/.ssh" ]'                              "~/.ssh is created for the control socket"
assert '[ "$(stat -c %a "$fakehome/.ssh")" = "700" ]'         "~/.ssh is created 0700 (got $(stat -c %a "$fakehome/.ssh" 2>/dev/null))"

# --- Case 3: an unreachable host exits 3, with ssh's own words ----------------
run_driver SSH_STUB_RC=255 -- <<'EOS'
ssh_connect deploy@vps.example.com
echo "reached=yes"
EOS
assert '[ "$rc" = "3" ]'                        "an unreachable host exits 3 per docs/cli.md (got $rc)"
assert '[ -z "$out" ]'                          "nothing runs after an unreachable host (got '$out')"
assert 'grep -qF "Connection refused" <<<"$err"' "ssh's own diagnosis is surfaced, not swallowed (got '$err')"
assert 'grep -qF "deploy@vps.example.com" <<<"$err"' "the unreachable target is named (got '$err')"
assert '[ "$(grep -c "^BEGIN ssh$" "$log")" = "1" ]' \
    "a failed connect does not go on to tear down a master it never opened (calls: $(grep -c '^BEGIN ssh$' "$log"))"

# --- Case 4: quoting is the transport's job, not the caller's -----------------
# `ssh host cmd args` re-joins argv with spaces, so an unquoted remote command
# arrives as separate words with its quoting gone (docs/phases/01-rig.md).
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_run docker ps --format '{{.Names}} {{.Status}}' --filter "label=a b"
EOS
assert '[ "$rc" = "0" ]' "a command with spaces inside its arguments runs (exit $rc: $err)"
run_block="$(call_block 2)"
assert $'grep -qxF "ARG:\'docker\' \'ps\' \'--format\' \'{{.Names}} {{.Status}}\' \'--filter\' \'label=a b\'" <<<"$run_block"' \
    "each word is quoted for the remote shell (got: $(grep '^ARG:.docker' "$log"))"
assert 'grep -qxF "ARG:-n" <<<"$run_block"' \
    "ssh_run closes stdin, so a caller looping over a list keeps its list"

# The other half of quoting everything: shell syntax handed to ssh_run is not
# syntax any more. Pinned deliberately — Units B-E reach for ssh_script when
# they want a pipeline, and a runner that sometimes interpreted its argument
# would be the worse surprise.
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_run 'docker ps | wc -l'
EOS
assert $'grep -qxF "ARG:\'docker ps | wc -l\'" <<<"$(call_block 2)"' \
    "a whole command line given as one argument stays one quoted word (got: $(call_block 2 | grep '^ARG:.docker'))"

# --- Case 5: a script payload survives the trip -------------------------------
# Quotes, $, backticks, newlines and a nested heredoc are exactly what a remote
# deploy script is made of; anything that mangles them shows up as a syntax
# error on the far side, hours later.
cat > "$tmpdir/expected.sh" <<'PAYLOAD'
set -euo pipefail
name='it'"'"'s "quoted"'
printf '%s\n' "$name" | tr -d '\n'
value=`echo backtick`
cost='$100 & 50%'
cat <<'INNER'
untouched $HOME `date` "quotes"
INNER
echo "done ${value} ${cost}"
PAYLOAD

run_driver -- <<EOS
ssh_connect deploy@vps.example.com
ssh_script one 'two three' < '$tmpdir/expected.sh'
EOS
assert '[ "$rc" = "0" ]' "a script payload runs (exit $rc: $err)"
assert '[ -f "$payload" ]' "the payload reached the remote shell's stdin"
assert 'cmp -s "$tmpdir/expected.sh" "$payload"' \
    "the payload arrives byte for byte ($(diff "$tmpdir/expected.sh" "$payload" 2>&1 | head -3))"
assert $'grep -qxF "ARG:\'bash\' \'-s\' \'--\' \'one\' \'two three\'" "$log"' \
    "the script runner feeds bash -s and quotes its arguments (got: $(grep "^ARG:'bash'" "$log"))"

# The heredoc form is the one Units B-E will use; it must be the same bytes.
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_script <<'REMOTE'
echo 'single' "double" `backtick` $VAR
REMOTE
EOS
assert '[ "$(cat "$payload")" = "echo '"'"'single'"'"' \"double\" \`backtick\` \$VAR" ]' \
    "a quoted heredoc travels unexpanded (got '$(cat "$payload" 2>/dev/null)')"

# --- Case 6: teardown ---------------------------------------------------------
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_disconnect
EOS
# Asserted as a sequence. "no line says '-O exit'" could never fail: the stub
# logs one argument per line, so the two can never share one whatever the code
# passes.
o_seq=$(grep -xF -A1 "ARG:-O" "$log")
assert '[ "$o_seq" = "ARG:-O
ARG:exit" ]' \
    "an explicit disconnect issues -O immediately followed by exit (got '$o_seq')"
assert '[ "$(grep -c "^ARG:-O$" "$log")" = "1" ]' "exactly one teardown was issued (got $(grep -c '^ARG:-O$' "$log"))"

# A run that dies half way must not leave a master behind. No RETURN trap is
# involved: bash leaves those installed past the function that set them, which
# under set -u aborts an unrelated later call (docs/phases/01-rig.md).
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
die "something went wrong mid-deploy"
EOS
assert '[ "$rc" != "0" ]'                         "a failing run still fails (exit $rc)"
assert '[ "$(grep -c "^ARG:-O$" "$log")" = "1" ]' "a failing run tears its master down (got $(grep -c '^ARG:-O$' "$log"))"

run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_disconnect
ssh_disconnect
EOS
assert '[ "$(grep -c "^ARG:-O$" "$log")" = "1" ]' \
    "teardown is idempotent — the exit trap does not repeat an explicit disconnect (got $(grep -c '^ARG:-O$' "$log"))"

# The caller's own EXIT trap survives. `trap … EXIT` is last-writer-wins, and
# Unit B is "render templates into a temp dir, then ship them" — a library that
# quietly took the slot would leak that directory on every run.
run_driver -- <<'EOS'
marker="$HOME/caller-cleanup-ran"
trap 'printf "caller cleanup\n" > "$marker"' EXIT
ssh_connect deploy@vps.example.com
EOS
assert '[ -f "$fakehome/caller-cleanup-ran" ]' \
    "a caller's existing EXIT trap still runs after ssh_connect"
assert '[ "$(grep -c "^ARG:-O$" "$log")" = "1" ]' \
    "chaining onto the caller's trap still tears the master down (got $(grep -c '^ARG:-O$' "$log"))"

# The awkward half: a handler containing quotes must come back out of `trap -p`
# and be re-installed unmangled.
run_driver -- <<'EOS'
marker="$HOME/quoted cleanup"
trap 'printf "%s\n" "it'"'"'s done" > "$marker"' EXIT
ssh_connect deploy@vps.example.com
EOS
assert '[ "$(cat "$fakehome/quoted cleanup" 2>/dev/null)" = "it'"'"'s done" ]' \
    "a caller trap containing quotes is chained intact (got '$(cat "$fakehome/quoted cleanup" 2>/dev/null)')"

# A second connect replaces the first instead of abandoning it: an orphaned
# master lingers for ControlPersist, which contradicts one-connection-per-run.
run_driver -- <<'EOS'
ssh_connect deploy@vps.example.com
ssh_connect deploy@other.example.com
EOS
assert '[ "$(grep -c "^ARG:-O$" "$log")" = "2" ]' \
    "reconnecting tears the first master down, and the exit trap the second (got $(grep -c '^ARG:-O$' "$log"))"
first_teardown=$(grep -xF -A2 "ARG:-O" "$log" | grep -c '^ARG:deploy@vps.example.com$')
assert '[ "$first_teardown" = "1" ]' \
    "the first master is torn down against its own target, not the new one"

# --- Case 7: nothing remote happens before the master is open -----------------
for op in 'ssh_run true' 'ssh_script </dev/null' 'ssh_rsync -a /tmp/x/ host:/tmp/y/'; do
    run_driver -- <<EOS
$op
EOS
    assert '[ "$rc" != "0" ]'                    "'$op' before ssh_connect fails (exit $rc)"
    assert 'grep -qF "ssh_connect" <<<"$err"'    "'$op' says what was skipped (got '$err')"
    assert '[ ! -s "$log" ]'                     "'$op' reached neither ssh nor rsync (calls: $(cat "$log"))"
done

# --- Hermeticity --------------------------------------------------------------
all=$(<"$log_all")
assert '[ -s "$log_all" ]' "the stubs were the ones that ran"
assert '! grep -qiF "BatchMode" <<<"$all"' "no call in the whole suite forced BatchMode"

exit "$fail"
