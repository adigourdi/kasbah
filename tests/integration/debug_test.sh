#!/usr/bin/env bash
# Integration: the server half of the trace (docs/cli.md "Debugging a
# failure"), against the rig. A deploy whose .env comes from a seed and whose
# compose up fails on an image no registry has: the error names the saved log,
# and the log holds the server binary's own trace — the docker compose call
# `kasbah remote deploy run` made there, with docker's real stderr and exit
# status — and never a .env value. Without --debug no trace line or frame
# reaches the terminal; with it, the server's lines stream.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
project=demo
traefik_flags=(--domain=rig.test --email=ops@rig.test --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    rig_ssh "cd $apps/$project 2>/dev/null && docker compose -p $project down >/dev/null 2>&1" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

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

# The demo fixture with a template, its compose naming an image no registry has.
src="$tmpdir/src"
cp -R "$repo_dir/tests/fixtures/$project" "$src" || exit 2
printf 'API_SECRET=\nDB_PASSWORD=\n' >"$src/.env.prod.example"
projdir="$tmpdir/$project"
if ! fixture_repo_make "$projdir" "$src" v1.0.0 2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo" >&2
    cat "$tmpdir/git.log" >&2
    exit 2
fi
broken=nginx:no-such-tag-kasbah-debug
sed -i "s|image: nginx:alpine|image: $broken|" "$projdir/compose.prod.yml"
printf 'API_SECRET=rig-api-secret-31\nDB_PASSWORD=rig-db-password-77\n' >"$tmpdir/seed"
chmod 600 "$tmpdir/seed"
secrets='rig-api-secret-31|rig-db-password-77'
leaks() { grep -aoE "$secrets" "$@" | sort -u | tr '\n' ' '; }

export XDG_STATE_HOME="$tmpdir/state"
logs="$XDG_STATE_HOME/kasbah/logs"
deploy() (
    cd "$projdir" || exit 2
    timeout 300 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
        "$KASBAH_BIN" deploy "$RIG_TARGET" --dirty --env-seed="$tmpdir/seed" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)

# --- Case 1: the failure names its log, which holds the server's half ------------
deploy; rc=$?
err="$(tr -d '\r' <"$tmpdir/err")"
last="$(tail -n 1 <<<"$err")"
assert '[ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$rc" != 2 ]' "a deploy whose compose up fails fails (rc $rc: $err)"
assert 'grep -qF "up -d --remove-orphans failed in" <<<"$err"' "and it is compose up on the server that failed it ($err)"
assert '[[ $last == "       log: $logs/"*"-deploy.log" ]]' "the last line names the log (got '$last')"
assert '! grep -q "^debug: " <<<"$err" && ! grep -qaF $'"'"'\x1e'"'"' "$tmpdir/err"' "no trace line or frame on the terminal without --debug"
log="${last#       log: }"
assert '[ -f "$log" ] && [ "$(stat -c %a "$log")" = 600 ]' "the log is there, 0600 ($(ls -l "$log" 2>&1))"
assert 'grep -qx "API_SECRET=rig-api-secret-31" <<<"$(rig_ssh "cat $apps/$project/.env" 2>/dev/null | tr -d "\r")"' \
    "the server's .env holds the seed, so the values were there to leak"
assert 'grep -qE "\] ssh $RIG_TARGET: .*kasbah remote deploy run $apps/$project$" "$log"' "the log holds the ssh call of the deploy arm ($(grep -F "remote deploy" "$log" | head -n 3))"
assert 'grep -qE "server: \[[0-9]+\] run: docker compose .*up -d --remove-orphans" "$log"' \
    "and the server's own trace: the compose up it ran ($(grep -F "server: " "$log" | head -n 5))"
assert 'grep -qE "server: \[[0-9]+\] exit [1-9][0-9]* after" "$log"' "with its exit status ($(grep -E "server: .*exit" "$log" | head -n 3))"
# compose up writes stdout and stderr to one place, so the server records
# neither; its stderr comes back on the ssh call's, which the workstation keeps.
assert 'grep -qE "^ *[0-9.]+ \[[0-9]+\] stderr: .*no-such-tag-kasbah-debug" "$log"' \
    "and docker's own stderr naming the image ($(grep -E "\] stderr" "$log" | head -n 5))"
assert 'grep -qF "note: server binary $apps/.kasbah/bin/kasbah " "$log"' "and the decision on the server binary"
assert '[ -z "$(leaks "$log")" ]' "no .env value in the log (found: $(leaks "$log"))"

# --- Case 2: --debug streams the server's lines as they happen --------------------
deploy --debug; rc=$?
assert '[ "$rc" != 0 ] && grep -qE "^debug: .*server: \[[0-9]+\] run: docker compose" "$tmpdir/err"' \
    "--debug streams the server's trace (rc $rc: $(grep -c "^debug: " "$tmpdir/err") debug lines)"
assert '[ -z "$(leaks <(grep "^debug: " "$tmpdir/err") "$logs"/*)" ]' "and no .env value in the stream or any log"

exit "$fail"
