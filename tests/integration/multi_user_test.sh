#!/usr/bin/env bash
# Test: two operators, each their own Unix user in the kasbah group, share one
# server — A deploys, B deploys, rolls back and runs env over A's files, A
# drops over B's — and a server-wide step holding server.lock makes a deploy
# fail fast, naming it.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
marker="$apps/.kasbah/server.json"
project=demo
op2=kasbahop2
op2_target="$op2@$RIG_SSH_ALIAS"
rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
holder_pid=""
cleanup() {
    { exec 7>&-; } 2>/dev/null
    [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null
    rig_ssh "sudo pkill -u $op2 >/dev/null 2>&1; sudo userdel -r $op2 >/dev/null 2>&1" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ] || ! rig_reachable; then
    echo "error: the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir" || ! rig_clean; then
    echo "error: could not prepare the scratch HOME or clean the rig" >&2
    exit 2
fi

init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
as() (   # as <checkout> kasbah-args…
    cd "$1" || return 2
    shift
    timeout 240 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
remote() { rig_ssh "$1" 2>/dev/null | tr -d '\r'; }
last_by() { remote "tail -1 $apps/$project/versions.log" | awk '{print $NF}'; }

# --- A prepared server, its tree the kasbah group's ------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
assert 'grep -qF "add an operator: ssh $RIG_TARGET '"'"'sudo usermod -aG kasbah <user>'"'"'" <<<"$(cli_out; cli_err)"' \
    "init says how to add an operator (got '$(cli_err)')"
assert '[ "$(remote "stat -c %G:%a $apps")" = "kasbah:2775" ]' \
    "$apps is the kasbah group's, setgid and group-writable (got '$(remote "stat -c %G:%a $apps")')"
assert '[ "$(remote "id -nG $RIG_SSH_USER" | tr " " "\n" | grep -cx kasbah)" = "1" ]' \
    "and $RIG_SSH_USER is in the group"
# The rig's cgroups cannot take limits: 0/0 as the other rig suites do.
mj=$(remote "cat $marker")
rig_ssh "cat > $marker" <<<"$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$mj")" >/dev/null 2>&1

# The second operator: their own user, in kasbah and docker, with the rig's key.
pub=$(cat "$repo_dir/tests/rig/id_ed25519.pub")
# A run killed before its cleanup leaves the user behind: it goes first.
rig_ssh "sudo pkill -u $op2 >/dev/null 2>&1; sudo userdel -r $op2 >/dev/null 2>&1; true" >/dev/null 2>&1
if ! rig_ssh "sudo useradd -m -s /bin/bash -G docker $op2 && sudo install -d -m 700 -o $op2 -g $op2 /home/$op2/.ssh &&
        printf '%s\n' '$pub' | sudo tee /home/$op2/.ssh/authorized_keys >/dev/null &&
        sudo chown $op2:$op2 /home/$op2/.ssh/authorized_keys && sudo chmod 600 /home/$op2/.ssh/authorized_keys" >/dev/null 2>&1; then
    echo "error: could not create the second operator $op2 on the rig" >&2
    exit 2
fi

# Not yet in the group: init points B at the group, never at taking the tree.
kasbah_cli server init "$op2_target" --no-mail --no-backup "${traefik_flags[@]}" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; rc=$?
assert '[ "$rc" != 0 ] && grep -qF "sudo usermod -aG kasbah $op2" "$tmpdir/err" && ! grep -qF "chown" "$tmpdir/err"' \
    "B outside the group is told to join it, not to chown A's tree (exit $rc: $(cli_err))"
rig_ssh "sudo usermod -aG kasbah $op2" >/dev/null 2>&1

dirA="$tmpdir/a/$project" dirB="$tmpdir/b/$project"
mkdir -p "$tmpdir/a" "$tmpdir/b"
if ! fixture_repo_make "$dirA" "$repo_dir/tests/fixtures/$project" v1.2.0 2>"$tmpdir/git.log" ||
   ! fixture_repo_make "$dirB" "$repo_dir/tests/fixtures/$project" v1.2.1 2>>"$tmpdir/git.log"; then
    echo "error: could not make the $project checkouts" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# --- A deploys -------------------------------------------------------------------
as "$dirA" deploy "$RIG_TARGET"
rig_setup_env "$apps/$project" </dev/null >/dev/null 2>&1
as "$dirA" deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "A deploys (exit $rc: $(cli_err))"
assert '[ "$(remote "stat -c %U:%G:%a $apps/$project/.env")" = "$RIG_SSH_USER:kasbah:660" ]' \
    ".env is A's, the group's, 660 (got '$(remote "stat -c %U:%G:%a $apps/$project/.env")')"
assert '[ "$(last_by)" = "by=$RIG_SSH_USER" ]' "versions.log names A (got '$(last_by)')"

# --- B deploys, rolls back and runs env over A's files -------------------------------
as "$dirB" deploy "$op2_target"; rc=$?
assert '[ "$rc" = "0" ]' "B deploys the same project over A's files (exit $rc: $(cli_err))"
assert '[ "$(last_by)" = "by=$op2" ]' "versions.log names B (got '$(last_by)')"
assert '[ "$(remote "stat -c %U:%G:%a $apps/$project/.env")" = "$op2:kasbah:660" ]' \
    ".env is renamed over by B, still the group's and 660 (got '$(remote "stat -c %U:%G:%a $apps/$project/.env")')"
assert '[ "$(remote "stat -c %G:%a $apps/$project/versions.log $apps/$project/.deploy.lock" | sort -u)" = "kasbah:664" ]' \
    "versions.log and .deploy.lock stay the group's, 664"
assert '[ "$(remote "stat -c %U:%G:%a $apps/$project/site")" = "$RIG_SSH_USER:kasbah:2775" ]' \
    "the synced site/ is still A's, setgid and group-writable after B's sync (got '$(remote "stat -c %U:%G:%a $apps/$project/site")')"
git -C "$dirB" tag v1.2.0 >/dev/null 2>&1
as "$dirB" rollback "$op2_target"; rc=$?
assert '[ "$rc" = "0" ]' "B rolls back to A's version (exit $rc: $(cli_err))"
assert '[ "$(remote "tail -1 $apps/$project/versions.log" | awk "{print \$2, \$3, \$NF}")" = "rollback 1.2.0 by=$op2" ]' \
    "the rollback is B's (got '$(remote "tail -1 $apps/$project/versions.log")')"
# kasbah env's setup, the server half it runs over ssh -t, as B (no terminal
# here: the menu answered, every default taken) — reading and rewriting the
# .env A owns.
rig_ssh "sudo chown $RIG_SSH_USER $apps/$project/.env" >/dev/null 2>&1
timeout 60 ssh -F "$RIG_SSH_CONFIG" -l "$op2" "$RIG_SSH_ALIAS" \
    "$apps/.kasbah/bin/kasbah remote setup-env setup $apps/$project" <<<$'y\n\n\n\n\n\n\n\n' >"$tmpdir/out" 2>"$tmpdir/err"; rc=$?
assert '[ "$rc" = "0" ]' "B runs the env setup on the .env A owns (exit $rc: $(cli_err))"
assert '[ "$(remote "stat -c %U:%G:%a $apps/$project/.env")" = "$op2:kasbah:660" ]' \
    "and renames its own over it, the group's and 660 (got '$(remote "stat -c %U:%G:%a $apps/$project/.env")')"
as "$dirA" history "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ] && grep -qE " $RIG_SSH_USER\$" "$tmpdir/out" && grep -qE " $op2\$" "$tmpdir/out"' \
    "history shows both operators in BY (got '$(cli_out)')"

git -C "$dirB" tag -d v1.2.0 >/dev/null 2>&1

# --- B re-runs server init on A's server --------------------------------------------
kasbah_cli server init "$op2_target" --no-mail --no-backup "${traefik_flags[@]}" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; rc=$?
assert '[ "$rc" = "0" ]' "B re-runs server init on the tree A prepared (exit $rc: $(cli_err))"
assert '[ "$(remote "stat -c %U:%G:%a $apps")" = "$RIG_SSH_USER:kasbah:2775" ]' \
    "and $apps stays A's, the group's (got '$(remote "stat -c %U:%G:%a $apps")')"
assert '[ "$(remote "stat -c %U:%a $apps/data/traefik/letsencrypt/acme.json")" = "$RIG_SSH_USER:600" ]' \
    "acme.json, A's at 600, is left as it is"

# --- A server-wide step holds server.lock: a deploy fails fast, naming it ------------
# The holder's stdin is a fifo this shell keeps open on fd 7: closing it is
# the release, exactly as a workstation run ends.
mkfifo "$tmpdir/hold"
exec 7<>"$tmpdir/hold"
timeout 90 ssh -F "$RIG_SSH_CONFIG" "$RIG_SSH_ALIAS" \
    "$apps/.kasbah/bin/kasbah remote lock $apps exclusive 'server init'" <"$tmpdir/hold" >"$tmpdir/lock.out" 2>"$tmpdir/lock.err" 7>&- &
holder_pid=$!
for _ in $(seq 1 40); do
    grep -qF "locked=exclusive" "$tmpdir/lock.out" 2>/dev/null && break
    sleep 0.25
done
assert 'grep -qF "locked=exclusive" "$tmpdir/lock.out"' "the holder took the lock (said '$(cat "$tmpdir/lock.err")')"
t0=$(date +%s)
as "$dirB" deploy "$op2_target"; rc=$?
took=$(( $(date +%s) - t0 ))
assert '[ "$rc" != "0" ] && [ "$took" -lt 50 ]' "B's deploy fails fast under it (exit $rc after ${took}s)"
assert 'grep -qF "server init by $RIG_SSH_USER" "$tmpdir/err"' \
    "naming what holds the lock and who (said '$(cli_err)')"
assert 'grep -qF "$apps/.kasbah/server.lock" "$tmpdir/err"' "and the lock file"
# Released by EOF alone: the holder never had fd 7, so closing it here is the
# fifo's last writer going away. Given 10 s; its own timeout is 90.
exec 7>&-
gone=no
for _ in $(seq 1 40); do
    kill -0 "$holder_pid" 2>/dev/null || { gone=yes; break; }
    sleep 0.25
done
assert '[ "$gone" = yes ]' "the holder exits within 10 s of its stdin closing"
wait "$holder_pid" 2>/dev/null; holder_pid=""
assert '[ -z "$(remote "pgrep -f \"remote lock $apps\"")" ]' "and its server side is gone with it"

# --- A drops over B's files --------------------------------------------------------
as "$dirA" drop "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = "0" ]' "A drops the project B last deployed (exit $rc: $(cli_err))"
assert '[ "$(remote "test -e $apps/traefik/dynamic/$project.yml && echo yes || echo no")" = "no" ]' \
    "B's fragment is gone"

[ "$fail" = 0 ] || exit 1
echo "ok - multi_user_test"
