#!/usr/bin/env bash
# Integration test: a redirect-only project — `services: {}` in its compose
# file, a fragment whose routers all end on noop@internal — through deploy,
# server status, `env set --restart`, rollback, `deploy <version>`, a version
# with a service and back, and drop on the live rig.
#
# What only the rig can show: real `docker compose` refusing a service-less up
# ("no service selected") is never reached; the fragment lands and Traefik
# answers the redirect with nothing behind it; `server status` reads the
# project as having no services; moving from a version with a container to one
# without removes the container and the project's network, Traefik detached
# from it first and left healthy on the rest; drop's label-based down works on
# a project with no container.
#
# The rig is treated as given: this suite never starts, resets or stops it. The
# project builds no image (its one service runs the stock nginx:alpine other
# suites use), so there is nothing to remove by name afterwards.
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

project=redirect
host=redirect.test
v1=1.0.0
v2=1.1.0
projdir_remote="$apps/$project"
frag_remote="$apps/traefik/dynamic/$project.yml"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
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

# --- Helpers --------------------------------------------------------------------
projdir="$tmpdir/$project"
init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
kasbah_bounded() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy()   { kasbah_bounded deploy "$@"; }
rollback() { kasbah_bounded rollback "$@"; }
drop()     { kasbah_bounded drop "$@"; }
status()   { kasbah_bounded server status "$RIG_TARGET"; }

versions_log() { rig_ssh "cat $projdir_remote/versions.log 2>/dev/null" 2>/dev/null | tr -d '\r'; }
labelled() {
    rig_ssh "docker ps -a --filter label=com.docker.compose.project=$project --format '{{.Names}}'" \
        2>/dev/null | tr -d '\r'
}
remote_exists() { rig_ssh "test -e '$1' && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
# "<code> <location>" for http://$host/<path>, waited for on the far side until
# the code and location are the expected ones: the file provider notices a
# fragment change within a couple of seconds (docs/traefik.md).
wait_redirect() {   # wait_redirect <path> <expected "code location">
    rig_ssh "r=; for i in \$(seq 1 30); do
                 r=\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 -H 'Host: $host' http://127.0.0.1/$1)
                 [ \"\$r\" != '$2' ] || break
                 sleep 1
             done
             printf '%s' \"\$r\"" 2>/dev/null | tr -d '\r'
}
# The status code for http://$whost/, waited for until it is the expected one.
wait_www() {   # wait_www <expected-code>
    rig_ssh "c=; for i in \$(seq 1 30); do
                 c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $whost' http://127.0.0.1/)
                 [ \"\$c\" != '$1' ] || break
                 sleep 1
             done
             printf '%s' \"\$c\"" 2>/dev/null | tr -d '\r'
}
traefik_nets() {
    rig_ssh "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' traefik" \
        2>/dev/null | tr -d '\r' | tr ' ' '\n' | sed '/^$/d' | sort
}
traefik_health() { rig_ssh "docker inspect -f '{{.State.Health.Status}}' traefik" 2>/dev/null | tr -d '\r'; }
net_exists() { rig_ssh "docker network inspect '$1' >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
# set_env INPUT ARGS… — `kasbah env set ARGS…` with INPUT on stdin, no terminal.
set_env() (
    cd "$projdir" || return 2
    printf '%s' "$1" | timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
        "$KASBAH_BIN" env set "${@:2}" >"$tmpdir/out" 2>"$tmpdir/err"
)
cut_version() {   # cut_version <version> <message>
    if ! ( cd "$projdir" && git add -A && git commit -qm "$2" && git tag "v$1" ) \
            >"$tmpdir/git.log" 2>&1; then
        echo "error: could not cut v$1 in the fixture copy" >&2
        sed 's/^/       | /' "$tmpdir/git.log" >&2
        exit 2
    fi
}
wait_code() {   # wait_code <expected-code>
    rig_ssh "c=; for i in \$(seq 1 30); do
                 c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $host' http://127.0.0.1/)
                 [ \"\$c\" != '$1' ] || break
                 sleep 1
             done
             printf '%s' \"\$c\"" 2>/dev/null | tr -d '\r'
}
# The websecure router: curl -k against Traefik's default certificate.
tls_redirect() {
    rig_ssh "curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 --resolve '$host:443:127.0.0.1' https://$host/$1" \
        2>/dev/null | tr -d '\r'
}

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode); the
# marker is rewritten to 0/0 as the other rig suites do. Nothing here runs a
# container, but the KASBAH_* block is rendered from it all the same.
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
    echo "error: could not rewrite the server marker's limits on the rig" >&2
    exit 2
fi

# --- v1 ---------------------------------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$v1" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
# The .env, rendered once by the operator's own hand, as every rig suite does.
deploy "$RIG_TARGET" >/dev/null 2>&1
rig_setup_env "$projdir_remote" </dev/null >/dev/null 2>&1

deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a redirect-only project deploys (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
if [ "$rc" != "0" ]; then
    echo "error: the $v1 deploy failed — nothing below can be judged" >&2
    exit 1
fi
err=$(cli_err)
assert 'grep -qF "no services" <<<"$err"' "the deploy says there is nothing to start
$(sed 's/^/      | /' <<<"$err")"
assert '! grep -qF "no service selected" <<<"$err"' "compose up was not run on a service-less file"
assert '[ "$(remote_exists "$frag_remote")" = "yes" ]' "the fragment shipped to $frag_remote"
assert '[ -z "$(labelled)" ]' "no container carries the project's label (got '$(labelled)')"
log=$(versions_log)
assert '[ "$(cut -d" " -f2-3 <<<"$log")" = "deploy $v1" ]' "versions.log records the deploy (log: $log)"

got=$(wait_redirect "some/path" "301 https://target.example/some/path")
assert '[ "$got" = "301 https://target.example/some/path" ]' \
    "the web router answers the redirect (got '$got')"
got=$(tls_redirect "x")
assert '[ "$got" = "301 https://target.example/x" ]' \
    "and so does the websecure one (got '$got')"

status; rc=$?
out=$(cli_out)
line=$(grep -E "^  $project +" <<<"$out")
assert '[ "$rc" = "0" ]' "server status exits 0 with a redirect-only project on the server (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[[ "$line" =~ ^\ \ $project\ +no\ services\ +$v1\ +deploy\  ]]' \
    "server status reads the project as having no services (line: '$line')"

# --- env set --restart: written, nothing to restart -------------------------------
set_env 'set-by-env-set' REDIRECT_NOTE "$RIG_TARGET" --restart; rc=$?
said=$(cli_out; cli_err)
assert '[ "$rc" = "0" ]' "env set --restart on a service-less project exits 0 (exit $rc)
$(sed 's/^/      | /' <<<"$said")"
assert 'grep -qF "nothing to restart" <<<"$said"' "env set says there is nothing to restart
$(sed 's/^/      | /' <<<"$said")"
assert '! grep -qF "no service selected" <<<"$said"' "env set ran no compose up"
got=$(rig_ssh "grep '^REDIRECT_NOTE=' $projdir_remote/.env" 2>/dev/null | tr -d '\r')
assert 'grep -qF "set-by-env-set" <<<"$got"' "the key was written to .env (got '$got')"

# --- v2, then back --------------------------------------------------------------------
sed -i 's|https://target.example/|https://target-two.example/|' "$projdir/traefik-dynamic.yml"
if ! ( cd "$projdir" && git add -A && git commit -qm "redirect elsewhere" && git tag "v$v2" ) \
        >"$tmpdir/git.log" 2>&1; then
    echo "error: could not cut v$v2 in the fixture copy" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a second redirect-only version deploys (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
got=$(wait_redirect "a" "301 https://target-two.example/a")
assert '[ "$got" = "301 https://target-two.example/a" ]' "v$v2's redirect answers (got '$got')"

rollback "$RIG_TARGET" --no-env --no-data; rc=$?
assert '[ "$rc" = "0" ]' "the rollback of a redirect-only project succeeds (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
got=$(wait_redirect "a" "301 https://target.example/a")
assert '[ "$got" = "301 https://target.example/a" ]' "v$v1's redirect answers again (got '$got')"
log=$(versions_log)
assert '[ "$(tail -n1 <<<"$log" | cut -d" " -f2-3)" = "rollback $v1" ]' \
    "versions.log records the rollback (log: $log)"

deploy "$RIG_TARGET" "$v2"; rc=$?
assert '[ "$rc" = "0" ]' "deploy $v2 of a redirect-only project succeeds (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
got=$(wait_redirect "b" "301 https://target-two.example/b")
assert '[ "$got" = "301 https://target-two.example/b" ]' "deploy $v2 put its redirect back (got '$got')"

# --- a version with a service, then none again, then back ----------------------------
v3=1.2.0
v4=1.3.0
whost=www.redirect.test
cat > "$projdir/compose.prod.yml" <<'YAML'
name: redirect

services:
  redirect-web:
    image: nginx:alpine
    container_name: redirect-web
    restart: unless-stopped
    networks:
      - kasbah
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah: {}
YAML
sed -i '/^  routers:$/a\    redirect-www:\n      rule: "Host(`www.redirect.test`)"\n      entryPoints: [web]\n      service: redirect-www' \
    "$projdir/traefik-dynamic.yml"
printf '  services:\n    redirect-www:\n      loadBalancer:\n        servers:\n          - url: "http://redirect-web:80"\n' \
    >> "$projdir/traefik-dynamic.yml"
cut_version "$v3" "a service"
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a version with a service deploys after a service-less one (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[ "$(labelled)" = "redirect-web" ]' "its container runs (got '$(labelled)')"
assert 'grep -qx redirect_kasbah <<<"$(traefik_nets)"' "Traefik is on redirect_kasbah (on: $(traefik_nets | tr '\n' ' '))"
got=$(wait_www 200)
assert '[ "$got" = "200" ]' "the service answers through Traefik (got '$got')"
got=$(wait_redirect "c" "301 https://target-two.example/c")
assert '[ "$got" = "301 https://target-two.example/c" ]' "the redirect still answers (got '$got')"

before=$(traefik_nets)
( cd "$projdir" && git checkout -q "v$v2" -- compose.prod.yml traefik-dynamic.yml )
cut_version "$v4" "no service again"
deploy "$RIG_TARGET"; rc=$?
err=$(cli_err)
assert '[ "$rc" = "0" ]' "a service-less version deploys over one with a container (exit $rc)
$(sed 's/^/      | /' <<<"$err")"
assert 'grep -qF "disconnected traefik from redirect_kasbah" <<<"$err"' "the deploy detached Traefik first
$(sed 's/^/      | /' <<<"$err")"
assert '[ -z "$(labelled)" ]' "the old container is gone (got '$(labelled)')"
assert '[ "$(net_exists redirect_kasbah)" = "no" ]' "redirect_kasbah is gone"
assert '[ "$(traefik_health)" = "healthy" ]' "Traefik is healthy (got '$(traefik_health)')"
after=$(traefik_nets)
assert '[ "$after" = "$(grep -vx redirect_kasbah <<<"$before")" ]' \
    "Traefik keeps every other network (before: $(tr '\n' ' ' <<<"$before"); after: $(tr '\n' ' ' <<<"$after"))"
got=$(wait_redirect "d" "301 https://target-two.example/d")
assert '[ "$got" = "301 https://target-two.example/d" ]' "the redirect answers (got '$got')"
got=$(wait_www 404)
assert '[ "$got" = "404" ]' "nothing routes the service's host any more (got '$got')"

deploy "$RIG_TARGET" "$v3"; rc=$?
assert '[ "$rc" = "0" ]' "deploy $v3 brings the service back (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[ "$(labelled)" = "redirect-web" ]' "its container runs again (got '$(labelled)')"
assert 'grep -qx redirect_kasbah <<<"$(traefik_nets)"' "Traefik is on redirect_kasbah again"
got=$(wait_www 200)
assert '[ "$got" = "200" ]' "the service is routed again (got '$got')"

deploy "$RIG_TARGET" "$v4"; rc=$?
assert '[ "$rc" = "0" ]' "deploy $v4 goes service-less again (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[ -z "$(labelled)" ] && [ "$(net_exists redirect_kasbah)" = "no" ]' \
    "and leaves no container nor redirect_kasbah (containers: '$(labelled)')"

# --- drop -----------------------------------------------------------------------------
drop "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = "0" ]' "drop removes a redirect-only project (exit $rc)
$(sed 's/^/      | /' "$tmpdir/err")"
assert '[ "$(remote_exists "$frag_remote")" = "no" ]' "drop removed the fragment"
assert '[ "$(remote_exists "$projdir_remote/versions.log")" = "yes" ]' "and kept versions.log, as a plain drop does"
got=$(wait_code 404)
assert '[ "$got" = "404" ]' "the host no longer redirects once dropped (got '$got')"

exit "$fail"
