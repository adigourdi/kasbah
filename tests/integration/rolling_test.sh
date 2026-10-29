#!/usr/bin/env bash
# Integration test: the rolling recreate of a routed service. The built-app
# fixture deploys on the rig, then four redeploys run under a request loop
# against built-app.test through Traefik, each loop's non-200s counted:
#   * v1.1.0 — built-app-web keeps its container_name: recreated in place, the
#     502 window recorded and not asserted;
#   * v1.2.0 — container_name dropped, the fragment still targets the service
#     name: rolled, since the old container already answers that name;
#   * v1.3.0 — rolled again: a second replica beside the first, the old one
#     removed by id, one left, and at most a couple of non-200s;
#   * v1.4.0 — the new replica never turns healthy: removed, the old one still
#     running untouched, the deploy reverted;
#   * v1.5.0 — built-app-web waits on a one-shot migrate that fails: recreated
#     in place, so compose's up sees the failure and the deploy reverts.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
project=built-app
pdir="$apps/$project"
marker="$apps/.kasbah/server.json"
traefik_flags=(--domain=rig.test --email=ops@rig.test --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")
# The roll's bound: Traefik may hold a pooled connection the old container
# closes as it stops; anything above this is a real window.
max_rolling_errors=2

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
images=""
for v in 1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 current; do images+=" built-app-web:$v built-app-worker:$v"; done
probe_pid=""
cleanup() {
    if [ -n "$probe_pid" ]; then
        rig_ssh "touch /tmp/kasbah-roll-stop" >/dev/null 2>&1
        wait "$probe_pid" 2>/dev/null
    fi
    rig_ssh "docker image rm -f $images; rm -f /tmp/kasbah-roll-*" >/dev/null 2>&1
    # shellcheck disable=SC2086
    docker image rm -f $images >/dev/null 2>&1
    rm -f "${TMPDIR:-/tmp}/$project-"*.tar.gz
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if [ ! -f "$RIG_SSH_CONFIG" ] || ! rig_reachable; then
    echo "error: the rig did not answer ssh — tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir" || ! rig_clean; then
    echo "error: could not put the rig into a known state" >&2
    exit 2
fi

projdir="$tmpdir/$project"
run() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-300}" env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        "$KASBAH_BIN" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
cli_err() { tr '\n' '|' <"$tmpdir/err"; }
remote()  { rig_ssh "$@" 2>/dev/null | tr -d '\r'; }
web_ids() { remote "docker ps -q --no-trunc --filter label=com.docker.compose.project=$project --filter label=com.docker.compose.service=built-app-web"; }
release() (
    cd "$projdir" && git add -A && git commit -qm "$1" && git tag "v$1"
) >/dev/null 2>&1
page() { sed -i "s|<p id=\"marker\">[^<]*</p>|<p id=\"marker\">$1</p>|" "$projdir/Dockerfile"; }

kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null ||
    { echo "error: server init failed: $(cli_err)" >&2; exit 2; }
marker_json=$(remote "cat $marker")
if ! rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true" >/dev/null 2>&1; then
    jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" | rig_ssh "cat > $marker" >/dev/null 2>&1 ||
        { echo "error: could not rewrite the marker's limits" >&2; exit 2; }
fi
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" v1.0.0 2>"$tmpdir/git.log"; then
    echo "error: could not make the fixture repository" >&2
    exit 2
fi
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.0.0 failed: $(cli_err)" >&2; exit 2; }
run deploy "$RIG_TARGET"
rig_setup_env "$pdir" >/dev/null 2>&1 </dev/null
run deploy "$RIG_TARGET" || { echo "error: 1.0.0 did not deploy: $(cli_err)" >&2; exit 2; }

# probe starts a request loop capped at probe_cap requests on the rig — Traefik on :80, one
# connection per request, ~20 a second — that a stop file ends early; the
# sampler beside it records how many built-app-web containers run.
probe_cap=1500
probe_start() {
    rig_ssh "rm -f /tmp/kasbah-roll-*; i=0
        while [ \$i -lt $probe_cap ] && [ ! -e /tmp/kasbah-roll-stop ]; do
            curl -s -o /dev/null -m 2 -w '%{http_code}\n' -H 'Host: built-app.test' http://127.0.0.1/ >> /tmp/kasbah-roll-codes
            if [ \$((i % 4)) = 0 ]; then
                docker ps -q --filter label=com.docker.compose.project=$project --filter label=com.docker.compose.service=built-app-web | wc -l >> /tmp/kasbah-roll-count
            fi
            i=\$((i + 1)); sleep 0.05
        done" >/dev/null 2>&1 &
    probe_pid=$!
    # The loop is running once it has answered: a deploy started before that
    # would not be measured.
    for _ in $(seq 50); do
        [ "$(remote "wc -l < /tmp/kasbah-roll-codes 2>/dev/null")" -gt 5 ] 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}
# probe_stop ends the loop and sets probe_result to "<non-200s> <requests> <most built-app-web containers>
# <each non-200 code:count>".
probe_stop() {
    remote "touch /tmp/kasbah-roll-stop" >/dev/null
    wait "$probe_pid"
    probe_pid=""
    probe_result=$(remote "echo \$(grep -vxc 200 /tmp/kasbah-roll-codes) \$(grep -c . /tmp/kasbah-roll-codes) \$(sort -n /tmp/kasbah-roll-count | tail -n1) \$(grep -vx 200 /tmp/kasbah-roll-codes | sort | uniq -c | awk '{printf \"%s%s:%s\", s, \$2, \$1; s=\",\"}')")
}

# --- v1.1.0: container_name kept — recreated in place -----------------------------
page served-by-built-app-one-one
release 1.1.0
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.1.0 failed: $(cli_err)" >&2; exit 2; }
probe_start || { echo "error: the request loop never started on the rig" >&2; exit 2; }
run deploy "$RIG_TARGET"; rc=$?
probe_stop
read -r inplace_bad inplace_total inplace_max inplace_codes <<<"$probe_result"
assert '[ "$rc" = 0 ]' "1.1.0 deploys (rc $rc: $(cli_err))"
assert 'grep -qF "built-app-web is recreated in place, as the fragment targets its container_name" "$tmpdir/err"' \
    "a container_name target is recreated in place, and the deploy says so ($(cli_err))"
assert '[ "${inplace_total:-0}" -lt "$probe_cap" ]' "the stop file, not the cap, ended the in-place loop ($inplace_total)"
echo "  measured: in-place recreate — $inplace_bad of $inplace_total requests not 200 (${inplace_codes:-none}; at most $inplace_max built-app-web running)" >&2

# --- v1.2.0: container_name dropped — the service name answers on both sides ---
sed -i '/^    container_name: built-app-web$/d' "$projdir/compose.prod.yml"
page served-by-built-app-one-two
release 1.2.0
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.2.0 failed: $(cli_err)" >&2; exit 2; }
run deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "built-app-web: starting 1 new replica(s) beside the running one(s)" "$tmpdir/err"' \
    "dropping container_name rolls, as the old container answers the service name too (rc $rc: $(cli_err))"
ids=$(web_ids)
assert '[ "$(grep -c . <<<"$ids")" = 1 ]' "one built-app-web is left ($ids)"
name=$(remote "docker inspect -f '{{.Name}}' $ids")
assert '[ "$name" != /built-app-web ]' "and it is compose's replica, not the old container_name ($name)"
assert 'grep -qF "post-deploy hook: built-app-web (${name#/}): " "$tmpdir/err"' \
    "the post-deploy hook ran in the new replica, named by its service ($(cli_err))"

# --- v1.3.0: rolled — two replicas, the old one removed by id -------------------
old=$(web_ids)
page served-by-built-app-one-three
release 1.3.0
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.3.0 failed: $(cli_err)" >&2; exit 2; }
probe_start || { echo "error: the request loop never started on the rig" >&2; exit 2; }
run deploy "$RIG_TARGET"; rc=$?
probe_stop
read -r roll_bad roll_total roll_max roll_codes <<<"$probe_result"
assert '[ "$rc" = 0 ]' "1.3.0 deploys (rc $rc: $(cli_err))"
assert 'grep -qF "built-app-web: stopped and removed the old container ${old:0:12}" "$tmpdir/err"' \
    "the old container is removed by its id (${old:0:12}: $(cli_err))"
ids=$(web_ids)
assert '[ "$(grep -c . <<<"$ids")" = 1 ] && [ "$ids" != "$old" ]' "one built-app-web is left, and not the old one ($ids)"
assert '[ "${roll_max:-0}" = 2 ]' "two ran side by side during the roll (most seen: ${roll_max:-none})"
assert '[ "${roll_bad:-99}" -le "$max_rolling_errors" ] && [ "${roll_total:-0}" -gt 50 ]' \
    "the roll answers 200 throughout: $roll_bad of $roll_total requests were not (bound $max_rolling_errors)"
assert '[ "${roll_total:-0}" -lt "$probe_cap" ]' "the stop file, not the cap, ended the rolling loop ($roll_total)"
echo "  measured: rolling recreate — $roll_bad of $roll_total requests not 200 (${roll_codes:-none}; at most $roll_max built-app-web running)" >&2
served=$(remote "curl -s -m 5 -H 'Host: built-app.test' http://127.0.0.1/")
assert 'grep -qF served-by-built-app-one-three <<<"$served"' "1.3.0's page is served"

# --- v1.4.0: the new replica never turns healthy ---------------------------------
old=$(web_ids)
sed -i 's|^    image: built-app-web:current|&\n    healthcheck:\n      test: ["CMD", "false"]\n      interval: 1s\n      retries: 2|' "$projdir/compose.prod.yml"
sed -i 's|^  timeout: 60s|  timeout: 8s|' "$projdir/kasbah.yml"
page served-by-built-app-one-four
release 1.4.0
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.4.0 failed: $(cli_err)" >&2; exit 2; }
probe_start || { echo "error: the request loop never started on the rig" >&2; exit 2; }
run deploy "$RIG_TARGET"; rc=$?
probe_stop
read -r bad_bad bad_total _ bad_codes <<<"$probe_result"
assert '[ "$rc" != 0 ] && grep -qF "failed (health) and was reverted — the server is back on 1.3.0" "$tmpdir/err"' \
    "an unhealthy new replica fails the deploy into the revert (rc $rc: $(cli_err))"
assert 'grep -qF "built-app-web: removed the new replica" "$tmpdir/err"' "the new replica is removed"
assert '[ "$(web_ids)" = "$old" ]' "the old container is the one left, untouched ($(web_ids) vs $old)"
started=$(remote "docker inspect -f '{{.State.Running}} {{.RestartCount}}' $old")
assert '[ "$started" = "true 0" ]' "and it never stopped ($started)"
served=$(remote "curl -s -m 5 -H 'Host: built-app.test' http://127.0.0.1/")
assert 'grep -qF served-by-built-app-one-three <<<"$served"' "1.3.0's page is still served"
# The revert put state/ back in place: the surviving container's bind mount of
# it sees the restored files, not an emptied directory.
inside=$(remote "docker exec $old ls -A /var/kasbah | sort | tr '\n' ' '")
ondisk=$(remote "ls -A $pdir/state | sort | tr '\n' ' '")
assert '[ -n "$ondisk" ] && [ "$inside" = "$ondisk" ] && grep -qw .gitkeep <<<"$inside"' \
    "the surviving container's /var/kasbah holds what state/ was put back as ('$inside' vs '$ondisk')"
assert '[ "$(remote "docker exec $old sha256sum /var/kasbah/.gitkeep" | cut -d" " -f1)" = "$(remote "sha256sum $pdir/state/.gitkeep" | cut -d" " -f1)" ]' \
    "and its files are the restored ones"
assert '[ "${bad_total:-0}" -lt "$probe_cap" ]' "the stop file, not the cap, ended the failed-roll loop ($bad_total)"
echo "  measured: failed roll — $bad_bad of $bad_total requests not 200 (${bad_codes:-none})" >&2
assert '[ "${bad_bad:-99}" -le "$max_rolling_errors" ]' "and was throughout: $bad_bad of $bad_total requests were not 200 (${bad_codes:-none})"

# --- v1.5.0: a gated depends_on keeps compose's own up -------------------------
( cd "$projdir" && git checkout -q v1.3.0 -- compose.prod.yml kasbah.yml ) || exit 2
sed -i 's|^  cache:|  migrate:\n    image: redis:7-alpine\n    restart: "no"\n    command: ["sh", "-c", "exit 3"]\n    networks: [internal]\n\n&|' "$projdir/compose.prod.yml"
sed -i 's|^    image: built-app-web:current|&\n    depends_on:\n      migrate:\n        condition: service_completed_successfully|' "$projdir/compose.prod.yml"
page served-by-built-app-one-five
release 1.5.0
run build-push "$RIG_TARGET" || { echo "error: build-push of 1.5.0 failed: $(cli_err)" >&2; exit 2; }
run deploy "$RIG_TARGET"; rc=$?
assert 'grep -qF "built-app-web is recreated in place, as it depends_on migrate (service_completed_successfully), a condition only a plain up waits for" "$tmpdir/err"' \
    "a service gated on a one-shot is not rolled ($(cli_err))"
assert '[ "$rc" != 0 ] && grep -qF "failed (up) and was reverted — the server is back on 1.3.0" "$tmpdir/err"' \
    "and the failed migrate fails the deploy (rc $rc: $(cli_err))"
served=$(remote "curl -s -m 5 -H 'Host: built-app.test' http://127.0.0.1/")
assert 'grep -qF served-by-built-app-one-three <<<"$served"' "1.3.0's page is served after the revert"

[ "$fail" = 0 ] && rig_clean >/dev/null 2>&1
exit "$fail"
