#!/usr/bin/env bash
# Integration test: a first deploy onto a server that already runs compose
# stacks outside the project, from a directory outside the apps path — one
# publishing the host port the project publishes, one using the project's
# compose project name — and `check --server` reporting both, and passing a
# host range for one container port that still has a free port.
#
# What only the rig can show: real `docker ps` labels and Ports column, read by
# the deploy's pre-flight before compose up; compose never treating the foreign
# container as the project's (it is left running, untouched); the deploy going
# through once the foreign stacks are down, and again over its own containers.
#
# The rig is treated as given: this suite never starts, resets or stops it. The
# foreign stacks, their directories and the project are removed on the way out.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
marker="$apps/.kasbah/server.json"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

project=squat
squatter=squatter
port=18080
v1=1.0.0
projdir_remote="$apps/$project"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
foreign_home=""
cleanup() {
    if [ -n "$foreign_home" ]; then
        rig_ssh "docker compose -p $squatter down --remove-orphans >/dev/null 2>&1
                 docker compose -p $project down --remove-orphans >/dev/null 2>&1
                 rm -rf '$foreign_home/foreign-port' '$foreign_home/foreign-name'" >/dev/null 2>&1
    fi
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh" >&2
    echo "       is the rig up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir"; then
    echo "error: could not build the scratch HOME and ssh wrapper under $tmpdir" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi
foreign_home=$(rig_ssh 'printf %s "$HOME"' 2>/dev/null | tr -d '\r')
if [ -z "$foreign_home" ] || [ "${foreign_home#"$apps"}" != "$foreign_home" ]; then
    echo "error: the rig user's home ('$foreign_home') is not a directory outside $apps" >&2
    exit 2
fi

# --- Helpers --------------------------------------------------------------------
projdir="$tmpdir/$project"
init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
kasbah_bounded() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy() { kasbah_bounded deploy "$@"; }
check()  { kasbah_bounded check "$@"; }
drop()   { kasbah_bounded drop "$@"; }

# The containers compose would count as the project's, with their working dir.
labelled() {
    rig_ssh "docker ps -a --filter label=com.docker.compose.project=$project --format '{{.Names}} {{.State}} {{.Label \"com.docker.compose.project.working_dir\"}}'" \
        2>/dev/null | tr -d '\r' | sort
}
versions_log() { rig_ssh "cat $projdir_remote/versions.log 2>/dev/null" 2>/dev/null | tr -d '\r'; }
# foreign_up <dir> <compose project> <compose file> — `docker compose up` by
# hand from a directory outside the apps path, as an operator once did.
foreign_up() {
    rig_ssh "mkdir -p '$foreign_home/$1' && cat > '$foreign_home/$1/compose.yml' &&
             cd '$foreign_home/$1' && docker compose -p $2 up -d --quiet-pull" <"$3" >"$tmpdir/fup.log" 2>&1
}
foreign_down() {
    rig_ssh "cd '$foreign_home/$1' && docker compose -p $2 down --remove-orphans" >"$tmpdir/fdown.log" 2>&1
}

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
# The rig cannot apply cgroup limits; the marker is rewritten to 0/0 as the
# other rig suites do.
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
    echo "error: could not rewrite the server marker's limits on the rig" >&2
    exit 2
fi

# --- The project: one nginx publishing $port, from the redirect fixture -----------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/redirect" "v$v1" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
sed -i "s/^name: redirect$/name: $project/; s/^domain: redirect.test$/domain: $project.test/" "$projdir/kasbah.yml"
sed -i "s/redirect\.test/$project.test/g; s/redirect-http:/$project-http:/; s/^    redirect:$/    $project:/" \
    "$projdir/traefik-dynamic.yml"
cat > "$projdir/compose.prod.yml" <<YAML
name: $project

services:
  $project-web:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "$port:80"
    cpus: \${KASBAH_CPU_LIMIT}
    mem_limit: \${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
if ! ( cd "$projdir" && git add -A && git commit -qm "$project" && git tag -f "v$v1" ) \
        >"$tmpdir/git.log" 2>&1; then
    echo "error: could not retag v$v1 in the fixture copy" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

cat > "$tmpdir/port.yml" <<YAML
services:
  web:
    image: nginx:alpine
    ports:
      - "$port:80"
YAML
cat > "$tmpdir/name.yml" <<YAML
services:
  other:
    image: nginx:alpine
YAML

# The .env, rendered once by the operator's own hand, as every rig suite does;
# the throwaway deploy that ships the template starts nothing.
deploy "$RIG_TARGET" >/dev/null 2>&1
rig_setup_env "$projdir_remote" </dev/null >/dev/null 2>&1
if [ -n "$(labelled)" ]; then
    drop "$RIG_TARGET" --yes >/dev/null 2>&1
    rig_ssh "rm -f $projdir_remote/versions.log" >/dev/null 2>&1
fi

# --- A foreign stack holding the port ---------------------------------------------
if ! foreign_up foreign-port "$squatter" "$tmpdir/port.yml"; then
    echo "error: could not start the foreign stack holding :$port on the rig" >&2
    sed 's/^/       | /' "$tmpdir/fup.log" >&2
    exit 2
fi
# Docker binds a port with no address on both wildcards when the host has IPv6,
# which reads as every address; on 0.0.0.0 alone otherwise.
held="0.0.0.0:$port/tcp"
case "$(rig_ssh "docker ps --filter name=$squatter-web-1 --format '{{.Ports}}'" 2>/dev/null)" in
    *"[::]:$port->"*) held="$port/tcp" ;;
esac
deploy "$RIG_TARGET"; rc=$?
err=$(cli_err)
assert '[ "$rc" = "1" ]' "a deploy onto a port a foreign container publishes is refused (exit $rc)
$(sed 's/^/      | /' <<<"$err")"
assert 'grep -qF "container $squatter-web-1 (compose project $squatter) publishes $held, which service $project-web of this project publishes too — stop or move that container, or change the port $project-web publishes" <<<"$err"' \
    "the refusal names the container, the port and the way out
$(sed 's/^/      | /' <<<"$err")"
assert '[ -z "$(labelled)" ]' "nothing of $project is up (got '$(labelled)')"
assert '! grep -q " deploy " <<<"$(versions_log)"' "versions.log records no deploy (log: $(versions_log))"

# --- And one using the project's compose project name ---------------------------------
if ! foreign_up foreign-name "$project" "$tmpdir/name.yml"; then
    echo "error: could not start the foreign stack named $project on the rig" >&2
    sed 's/^/       | /' "$tmpdir/fup.log" >&2
    exit 2
fi
theirs="$project-other-1 running $foreign_home/foreign-name"
name_msg="a compose project named $project already exists outside $projdir_remote: $project-other-1, started from $foreign_home/foreign-name ($foreign_home/foreign-name/compose.yml) — Docker keys compose projects by name, so this project's up would take its containers for its own; run \`docker compose -p $project down\` in $foreign_home/foreign-name, or rename this project"

check --server "$RIG_TARGET"; rc=$?
out=$(cli_out; cli_err)
assert '[ "$rc" = "6" ]' "check --server fails with both foreign stacks up (exit $rc)
$(sed 's/^/      | /' <<<"$out")"
assert 'grep -qF "✗ C13 on $RIG_TARGET, $name_msg — a deploy refuses this" <<<"$out"' \
    "check --server reports the compose project name
$(sed 's/^/      | /' <<<"$out")"
assert 'grep -qF "✗ C12 on $RIG_TARGET, container $squatter-web-1 (compose project $squatter) publishes $held" <<<"$out"' \
    "check --server reports the port
$(sed 's/^/      | /' <<<"$out")"

# A range for one container port takes a free one: :$port held is no collision.
sed -i "s/- \"$port:80\"/- \"$port-$((port + 1)):80\"/" "$projdir/compose.prod.yml"
check --server "$RIG_TARGET"; out=$(cli_out; cli_err)
git -C "$projdir" checkout -q -- compose.prod.yml
assert 'grep -qF "✗ C13 on $RIG_TARGET, $name_msg" <<<"$out" && ! grep -qF "publishes $held" <<<"$out"' \
    "check --server passes a range with a free port over the held one
$(sed 's/^/      | /' <<<"$out")"

deploy "$RIG_TARGET"; rc=$?
err=$(cli_err)
assert '[ "$rc" = "1" ]' "a deploy with both foreign stacks up is refused (exit $rc)"
assert 'grep -qF "$name_msg" <<<"$err" && grep -qF "publishes $held" <<<"$err"' "the refusal names both
$(sed 's/^/      | /' <<<"$err")"
assert '[ "$(labelled)" = "$theirs" ]' "only the foreign container carries the name, still running (got '$(labelled)')"

if ! foreign_down foreign-port "$squatter"; then
    echo "error: could not take the foreign stack holding :$port down" >&2
    sed 's/^/       | /' "$tmpdir/fdown.log" >&2
    exit 2
fi
deploy "$RIG_TARGET"; rc=$?
err=$(cli_err)
assert '[ "$rc" = "1" ]' "a deploy with the foreign compose project of its name up is refused (exit $rc)"
assert 'grep -qF "$name_msg" <<<"$err"' "the refusal names its working dir, its config files and docker compose down
$(sed 's/^/      | /' <<<"$err")"
assert '! grep -qF "publishes $held" <<<"$err"' "and no longer the port"
assert '[ "$(labelled)" = "$theirs" ]' "the foreign container is left as it was (got '$(labelled)')"

# --- Both gone: the deploy goes through, and again over its own containers ---------------
if ! foreign_down foreign-name "$project"; then
    echo "error: could not take the foreign stack named $project down" >&2
    sed 's/^/       | /' "$tmpdir/fdown.log" >&2
    exit 2
fi
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "with the foreign stacks down the deploy succeeds (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[ "$(labelled)" = "$project-$project-web-1 running $projdir_remote" ]' "the project runs from $projdir_remote (got '$(labelled)')"
got=$(rig_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$port/" 2>/dev/null | tr -d '\r')
assert '[ "$got" = "200" ]' "and answers on :$port (got '$got')"

check --server "$RIG_TARGET"; out=$(cli_out; cli_err)
assert 'grep -qF "✓ C12,C13 no container outside $projdir_remote on $RIG_TARGET publishes a port it publishes or runs under its compose project name" <<<"$out"' \
    "check --server passes over the project's own container
$(sed 's/^/      | /' <<<"$out")"

deploy "$RIG_TARGET" "$v1"; rc=$?
assert '[ "$rc" = "0" ]' "a redeploy over its own container publishing :$port succeeds (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"

drop "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = "0" ]' "drop removes the project (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"

exit "$fail"
