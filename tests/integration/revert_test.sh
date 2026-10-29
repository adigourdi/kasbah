#!/usr/bin/env bash
# Integration test: a deploy that fails puts the server back. On the rig, the
# demo fixture runs v1.0.0, then:
#   * v2.0.0, whose container cannot start (compose up fails) and which adds a
#     synced file — reverted: v1's compose.yml and container, the new file gone,
#     no versions.log line, exit non-zero;
#   * v3.0.0, whose healthcheck never passes — reverted the same way;
#   * v4.0.0, whose post-deploy hook fails — not reverted: a deploy-failed line,
#     shown by `kasbah history`, and an implicit rollback that goes past it to
#     v1.0.0;
#   * built-app v5.2.0, whose worker cannot start — reverted with each built
#     image's :current back on v5.1.0's image id, read with docker image inspect.
# Every surface is read off the rig, not out of kasbah's narration.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
project=demo
pdir="$apps/$project"
marker="$apps/.kasbah/server.json"
traefik_flags=(--domain=rig.test --email=ops@rig.test --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
bimages="built-app-web:5.1.0 built-app-worker:5.1.0 built-app-web:5.2.0 built-app-worker:5.2.0 built-app-web:current built-app-worker:current"
cleanup() {
    rig_ssh "docker image rm -f $bimages" >/dev/null 2>&1
    # shellcheck disable=SC2086
    docker image rm -f $bimages >/dev/null 2>&1
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
init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
run() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        "$KASBAH_BIN" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
cli_err() { tr '\n' '|' <"$tmpdir/err"; }
remote()  { rig_ssh "$@" 2>/dev/null | tr -d '\r'; }
vlog()    { remote "cat $pdir/versions.log"; }
compose_sum() { remote "sha256sum < $pdir/compose.yml" | cut -d' ' -f1; }
commit_tag() (
    cd "$projdir" && git add -A && git commit -qm "$1" && git tag "v$1"
) >/dev/null 2>&1

init --no-mail --no-backup "${traefik_flags[@]}" || { echo "error: server init failed: $(cli_err)" >&2; exit 2; }

# The rig cannot always apply cgroup limits (spine_test.sh says why): 0/0 then.
marker_json=$(remote "cat $marker")
if ! rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true" >/dev/null 2>&1; then
    jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" | rig_ssh "cat > $marker" >/dev/null 2>&1 ||
        { echo "error: could not rewrite the marker's limits" >&2; exit 2; }
fi

if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" v1.0.0 2>"$tmpdir/git.log"; then
    echo "error: could not make the fixture repository" >&2
    exit 2
fi

# v1.0.0: the first deploy stops at the env step (no terminal), the operator
# renders .env on the server, the second goes through.
run deploy "$RIG_TARGET"
rig_setup_env "$pdir" >/dev/null 2>&1 </dev/null
run deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != 0 ]; then
    echo "error: v1.0.0 did not deploy (rc $rc): $(cli_err)" >&2
    exit 2
fi
v1_sum=$(compose_sum)
v1_log=$(vlog)
v1_env=$(remote "sha256sum < $pdir/.env" | cut -d' ' -f1)
assert '[ "$(wc -l <<<"$v1_log")" = 1 ] && grep -qF " deploy 1.0.0 " <<<"$v1_log"' "v1.0.0 is recorded ($v1_log)"
assert '[ "$(remote "[ -e $pdir/.kasbah-prev ] && echo yes || echo no")" = no ]' \
    "a successful deploy leaves no snapshot behind"

# --- (a)+(d) compose up fails, and the run had added a synced file ------------------
cd "$projdir" || exit 2
sed -i 's|^    image: nginx:alpine|    image: nginx:alpine\n    entrypoint: ["/kasbah-no-such-entrypoint"]|' compose.prod.yml
printf 'new in v2\n' > extra.txt
sed -i 's|^  - site/|  - site/\n  - extra.txt|' kasbah.yml
cd - >/dev/null || exit 2
commit_tag 2.0.0
run deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != 0 ]' "a v2.0.0 whose container cannot start fails the deploy (rc $rc)"
assert 'grep -qF "was reverted — the server is back on 1.0.0" "$tmpdir/err"' "saying the server is back on 1.0.0 ($(cli_err))"
assert 'grep -qF "it was reverted:" "$tmpdir/err"' "and the workstation says so too"
assert '[ "$(compose_sum)" = "$v1_sum" ]' "compose.yml on the server is v1.0.0's again"
assert '[ "$(remote "sha256sum < $pdir/.env" | cut -d" " -f1)" = "$v1_env" ]' ".env is what it was"
assert '[ "$(remote "[ -e $pdir/extra.txt ] && echo yes || echo no")" = no ]' "the file v2.0.0 added is gone"
assert '[ "$(vlog)" = "$v1_log" ]' "versions.log records nothing ($(vlog | tr '\n' '|'))"
state=$(remote "docker inspect -f '{{.State.Status}} {{json .Config.Entrypoint}}' demo-web")
assert '[[ "$state" == running* ]] && ! grep -qF "kasbah-no-such-entrypoint" <<<"$state"' \
    "demo-web runs v1.0.0's container again (got '$state')"
assert '[ "$(remote "[ -e $pdir/.kasbah-prev ] && echo yes || echo no")" = no ]' \
    "a revert that worked removes its snapshot — the files on disk are the live stack's again"

# --- (b) the health wait fails ------------------------------------------------------
cd "$projdir" || exit 2
sed -i '/kasbah-no-such-entrypoint/d' compose.prod.yml
sed -i 's|^    image: nginx:alpine|    image: nginx:alpine\n    healthcheck:\n      test: ["CMD", "false"]\n      interval: 1s\n      retries: 1|' compose.prod.yml
printf 'health:\n  container: demo-web\n  timeout: 10s\n' >> kasbah.yml
cd - >/dev/null || exit 2
commit_tag 3.0.0
run deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != 0 ] && grep -qF "failed (health) and was reverted — the server is back on 1.0.0" "$tmpdir/err"' \
    "an unhealthy v3.0.0 is reverted (rc $rc: $(cli_err))"
assert '[ "$(compose_sum)" = "$v1_sum" ] && [ "$(vlog)" = "$v1_log" ]' "to v1.0.0's compose.yml, with nothing recorded"
state=$(remote "docker inspect -f '{{.State.Status}} {{if .State.Health}}hc{{else}}none{{end}}' demo-web")
assert '[ "$state" = "running none" ]' "demo-web is v1.0.0's container, running, with no healthcheck (got '$state')"

# --- (c) a post-deploy hook fails ----------------------------------------------------
cd "$projdir" || exit 2
sed -i '/healthcheck:/,/retries: 1/d' compose.prod.yml
printf 'hooks:\n  post-deploy:\n    - demo-web false\n' >> kasbah.yml
cd - >/dev/null || exit 2
commit_tag 4.0.0
v4_sum=$(cd "$projdir" && sha256sum < compose.prod.yml | cut -d' ' -f1)
run deploy "$RIG_TARGET"; rc=$?
log=$(vlog)
assert '[ "$rc" != 0 ] && grep -qF "4.0.0 is live and was not reverted" "$tmpdir/err"' \
    "a failed post-deploy hook fails the deploy without reverting (rc $rc: $(cli_err))"
assert '[ "$(compose_sum)" = "$v4_sum" ]' "v4.0.0's compose.yml stays"
assert '[ "$(wc -l <<<"$log")" = 2 ] && grep -qE " deploy-failed 4\.0\.0 no-backup kasbah=[^ ]+ digest=- by=[^ ]+ reason=post-hook$" <<<"$log"' \
    "versions.log records deploy-failed (got '$(tr '\n' '|' <<<"$log")')"
run history "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 0 ] && grep -qE "deploy-failed +4\.0\.0" "$tmpdir/out"' "history shows it ($(tr '\n' '|' <"$tmpdir/out"))"
run rollback "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "rolling back to 1.0.0" "$tmpdir/err"' \
    "an implicit rollback goes past the failed version to 1.0.0 (rc $rc: $(cli_err))"
assert '[ "$(compose_sum)" = "$v1_sum" ] && grep -qF " rollback 1.0.0 " <<<"$(vlog)"' "and lands there"
run rollback "$RIG_TARGET" 4.0.0; rc=$?
assert '[ "$rc" != 0 ] && grep -qF "was never deployed to this VPS" "$tmpdir/err"' \
    "a version that only ever failed is not a rollback target (rc $rc: $(cli_err))"

# --- a built image: the revert puts each :current back on its old image id ---------
bdir="$tmpdir/built-app"
bremote="$apps/built-app"
image_id() { remote "docker image inspect -f '{{.Id}}' $1"; }
brun() (
    cd "$bdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-300}" env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        "$KASBAH_BIN" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
if ! fixture_repo_make "$bdir" "$repo_dir/tests/fixtures/built-app" v5.1.0 2>"$tmpdir/git.log"; then
    echo "error: could not make the built-app fixture repository" >&2
    exit 2
fi
brun build-push "$RIG_TARGET" || { echo "error: build-push of 5.1.0 failed: $(cli_err)" >&2; exit 2; }
brun deploy "$RIG_TARGET"
rig_setup_env "$bremote" >/dev/null 2>&1 </dev/null
brun deploy "$RIG_TARGET" || { echo "error: built-app 5.1.0 did not deploy: $(cli_err)" >&2; exit 2; }
web1=$(image_id built-app-web:5.1.0)
worker1=$(image_id built-app-worker:5.1.0)
assert '[[ "$web1" =~ ^sha256: ]] && [ "$(image_id built-app-web:current)" = "$web1" ]' \
    "built-app-web:current is 5.1.0's image ($web1)"
( cd "$bdir" &&
  sed -i 's|served-by-built-app-from-an-image-shipped-over-ssh|served-by-built-app-five-two|' Dockerfile &&
  sed -i 's|^    image: built-app-worker:current|&\n    entrypoint: ["/kasbah-no-such-entrypoint"]|' compose.prod.yml &&
  git add -A && git commit -qm 5.2.0 && git tag v5.2.0 ) >/dev/null 2>&1
brun build-push "$RIG_TARGET" || { echo "error: build-push of 5.2.0 failed: $(cli_err)" >&2; exit 2; }
web2=$(image_id built-app-web:5.2.0)
assert '[[ "$web2" =~ ^sha256: ]] && [ "$web2" != "$web1" ]' "5.2.0 ships a different web image ($web2)"
brun deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != 0 ] && grep -qF "was reverted — the server is back on 5.1.0" "$tmpdir/err"' \
    "a 5.2.0 whose worker cannot start is reverted (rc $rc: $(cli_err))"
assert 'grep -qF "retagged built-app-web:current back to $web1" "$tmpdir/err"' "saying which id :current went back to"
assert '[ "$(image_id built-app-web:current)" = "$web1" ] && [ "$(image_id built-app-worker:current)" = "$worker1" ]' \
    "each :current is 5.1.0's image again (web $(image_id built-app-web:current), worker $(image_id built-app-worker:current))"
state=$(remote "docker inspect -f '{{.State.Status}} {{.Image}}' built-app-web")
assert '[ "$state" = "running $web1" ]' "built-app-web runs 5.1.0's image (got '$state')"
assert '[ "$(remote "grep -c . $bremote/versions.log")" = 1 ]' "versions.log records nothing for 5.2.0"

[ "$fail" = 0 ] && rig_clean >/dev/null 2>&1
exit "$fail"
