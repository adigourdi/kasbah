#!/usr/bin/env bash
# Integration: `kasbah env` against the rig — the Go command on the workstation,
# `kasbah remote setup-env` in the server binary it ships, the interactive setup
# over a real `ssh -t`, the managed block, the .env's mode, last_server, and a
# Ctrl-C at a server prompt.
#
# The interactive runs sit behind script(1), which gives kasbah a terminal; its
# answers are typed ahead, which a pty buffers until something reads them.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
marker="$apps/.kasbah/server.json"
project=demo
pdir="$apps/$project"
traefik_flags=(--domain=rig.test --email=ops@rig.test --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
holder=""
cleanup() {
    [ -z "$holder" ] || kill "$holder" 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if ! command -v script >/dev/null 2>&1; then
    echo "error: script(1) is required to give kasbah a terminal" >&2
    exit 2
fi
if [ ! -f "$RIG_SSH_CONFIG" ] || ! rig_reachable; then
    echo "error: the rig did not answer ssh — is it up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir" || ! rig_clean; then
    echo "error: could not prepare the scratch HOME or clean the rig" >&2
    exit 2
fi
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}" \
        >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig:" >&2
    cat "$tmpdir/init.err" >&2
    exit 2
fi
marker_json=$(rig_ssh "cat $marker" 2>/dev/null | tr -d '\r')
cpu=$(jq -r .cpu_limit <<<"$marker_json")
mem=$(jq -r .mem_limit <<<"$marker_json")

proj="$tmpdir/$project"
cp -R "$repo_dir/tests/fixtures/$project" "$proj" || exit 2
cat > "$proj/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=demo
APP_PORT=8080 # the port
DB_PASSWORD=! echo generated-pw
API_SECRET=
MAIL_HOST=# smtp host
export EXPORTED=x
KASBAH_CPU_LIMIT=9
TMPL

nocr() { tr -d '\r'; }
remote() { rig_ssh "$1" 2>/dev/null | nocr; }
# True only when ssh worked and the command printed nothing.
remote_empty() { local out; out=$(remote "$1") || return 1; [ -z "$out" ]; }
no_staging() { remote_empty "ls -A $pdir | grep -F .kasbah- || true"; }
block="# >>> kasbah managed block - do not edit, rewritten on every deploy >>>
KASBAH_CPU_LIMIT=$cpu
KASBAH_MEM_LIMIT=$mem
# <<< kasbah managed block <<<"
last_server() { jq -r '.last_server // ""' "$proj/.kasbah/state.json" 2>/dev/null; }

headless() {
    (cd "$proj" && timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
        "$KASBAH_BIN" env "$@") >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}
err() { nocr <"$tmpdir/err"; }

# tty INPUT ARGS… — the command behind a pty, INPUT typed ahead.
tty_rc=0
tty_out=""
tty() {
    local input="$1"; shift
    printf '%s' "$input" >"$tmpdir/tty-in"
    timeout 120 script -qfec "cd $(printf '%q' "$proj") && $(printf '%q ' env HOME="$RIG_HOME" \
        PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 "$KASBAH_BIN" env "$@")" "$tmpdir/tty-out" \
        <"$tmpdir/tty-in" >/dev/null 2>&1
    tty_rc=$?
    tty_out=$(grep -v '^Script \(started\|done\) on ' "$tmpdir/tty-out" | nocr)
}

# --- Case 1: headless, no .env: exit 5, and nothing but the template --------------
headless "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 5 ]' "a first env with no terminal is exit 5 (rc $rc: $(err))"
assert 'grep -qF ".env does not exist yet" <<<"$(err)"' "naming why (said '$(err)')"
assert '[ "$(remote "[ -x $apps/.kasbah/bin/kasbah ] && echo yes")" = yes ]' "the server binary was shipped"
assert '[ "$(remote "cat $pdir/.env.prod.example" | head -1)" = "# --- App ---" ]' "the template was shipped"
assert '[ "$(remote "ls -A $pdir")" = ".env.prod.example" ]' \
    "and nothing else: no .env, no scripts/setup-env.sh (got '$(remote "ls -A $pdir")')"
assert '[ -z "$(last_server)" ]' "a failed run records no last_server"

# --- Case 2: on a terminal, the setup runs over ssh -t ----------------------------
# APP_NAME Enter, APP_PORT typed, DB_PASSWORD generated, API_SECRET typed
# (masked), MAIL_HOST typed, EXPORTED Enter.
tty $'\n9090\n\ns3cr3t-typed\nsmtp.test\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ]' "env on a terminal exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qF "→ generated" <<<"$tty_out"' "the generator ran on the server (said '$tty_out')"
want="# --- App ---
APP_NAME=demo
APP_PORT=9090
DB_PASSWORD=generated-pw
API_SECRET=s3cr3t-typed
MAIL_HOST=smtp.test
EXPORTED=x
$block"
got=$(remote "cat $pdir/.env")
assert '[ "$got" = "$want" ]' "the .env is the template answered, export dropped, block last
        got: $got"
assert '[ "$(remote "stat -c %a $pdir/.env")" = 600 ]' "a .env kasbah creates is 600 (got $(remote "stat -c %a $pdir/.env"))"
assert '[ "$(last_server)" = "$RIG_TARGET" ]' "a run that worked records last_server"
assert 'no_staging' "no staging file left"

# --- Case 3: in sync: declined, then reconfigured — the mode stays -----------------
remote "chmod 640 $pdir/.env" >/dev/null
tty 'n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF "up to date" <<<"$tty_out"' "declining the reconfigure exits 0 (rc $tty_rc: $tty_out)"
tty $'y\n\n\n\n\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF ".env written to" <<<"$tty_out"' "reconfiguring rewrites it (rc $tty_rc: $tty_out)"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "every live value kept through Enter"
assert '[ "$(remote "stat -c %a $pdir/.env")" = 640 ]' "an existing .env keeps its mode through the setup"
assert 'no_staging' "no staging file left"

# An existing .env the deploy user cannot read is never taken for a first run.
# Its keys read as missing, so the drift prompt comes first.
remote "chmod 200 $pdir/.env" >/dev/null
tty $'setup\n\n\n\n\n\n\n' "$RIG_TARGET"
remote "chmod 640 $pdir/.env" >/dev/null
assert '[ "$tty_rc" = 5 ] && grep -qF "cannot read" <<<"$tty_out"' "an unreadable .env stops the setup (rc $tty_rc: $tty_out)"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "and leaves it as it was"

# --- Case 4: drift, headless ---------------------------------------------------------
printf 'NEW_KEY=nk\n' >> "$proj/.env.prod.example"
headless "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 5 ] && grep -qF -- "--on-drift=continue" <<<"$(err)"' "drift with no terminal names the flag (rc $rc: $(err))"
headless "$RIG_TARGET" --on-drift=abort; rc=$?
assert '[ "$rc" = 5 ]' "--on-drift=abort is exit 5 (rc $rc)"
remote "sed -i 's/^KASBAH_CPU_LIMIT=.*/KASBAH_CPU_LIMIT=stale/' $pdir/.env" >/dev/null
headless "$RIG_TARGET" --on-drift=continue; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "has drifted" <<<"$(err)"' "--on-drift=continue goes through (rc $rc: $(err))"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "leaving .env as it stood, the block refreshed"

# --- Case 5: drift, on a terminal: setup, then the new key only ---------------------
tty $'setup\n\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ]' "answering setup exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qF "setup/continue/abort" <<<"$tty_out" && grep -qF "1 new" <<<"$tty_out"' "asked, then the menu (said '$tty_out')"
assert 'grep -qx "NEW_KEY=nk" <<<"$(remote "cat $pdir/.env")"' "the new key is in .env"
assert 'grep -qx "API_SECRET=s3cr3t-typed" <<<"$(remote "cat $pdir/.env")"' "the live values kept"

# --- Case 6: Ctrl-C at a server prompt ------------------------------------------------
# Typed through the pty, as an operator would: ssh carries it to the server's
# terminal, the server binary restores it and exits 130, and the run is exit 5.
before=$(remote "cat $pdir/.env")
mkfifo "$tmpdir/fifo"
sleep 300 >"$tmpdir/fifo" &
holder=$!
(cd "$proj" && timeout 120 script -qfec "$(printf '%q ' env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    NO_COLOR=1 "$KASBAH_BIN" env "$RIG_TARGET")" "$tmpdir/int-out" <"$tmpdir/fifo" >/dev/null 2>&1; \
    echo $? >"$tmpdir/int-rc") &
runner=$!
exec 3>"$tmpdir/fifo"
waiting=""
for _ in $(seq 1 40); do
    if [ -n "$(remote "pgrep -f 'remote setup-env [s]etup' || true")" ]; then waiting=yes; break; fi
    sleep 0.5
done
assert '[ "$waiting" = yes ]' "the server's setup started"
sleep 1
printf '\003' >&3
exec 3>&-
wait "$runner"
kill "$holder" 2>/dev/null; holder=""
int_rc=$(cat "$tmpdir/int-rc" 2>/dev/null)
assert '[ "$int_rc" = 5 ]' "Ctrl-C at the server's prompt ends the run with 5 (rc $int_rc: $(nocr <"$tmpdir/int-out"))"
assert 'remote_empty "pgrep -f '"'remote [s]etup-env'"' || true"' "nothing left running on the server"
assert '[ "$(remote "cat $pdir/.env")" = "$before" ]' "the .env untouched"
assert 'no_staging' "no staging file left"

exit "$fail"
