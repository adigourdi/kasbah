#!/usr/bin/env bash
# Integration test: `kasbah drop` and `kasbah drop --prune` against the live rig,
# over two real projects a real deploy brought up.
#
# What only the rig can show, and what the hermetic suite therefore cannot:
#   * `docker compose -p <name> down` really stopping and removing a stack it
#     was given no compose file for — a stub ssh agrees with any spelling;
#   * `docker image rm` really taking the image out of the daemon once its last
#     tag goes, and a stock image another project's *running container* holds
#     surviving that in a daemon that would have refused to delete it;
#   * a redeploy after a plain drop coming back with the bind-mounted data the
#     drop left in place — the whole claim of "drop is the reversible verb";
#   * Traefik still serving the neighbouring project through the whole thing;
#   * the mail registry rewrite landing as a file on a server, parsed back by
#     the same reader the four other commands use.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which leaves images alone, so every image it loads is
# removed by name here.
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

# The project being dropped, and the neighbour that must survive it. built-app
# builds two images and pulls one stock one; demo builds nothing and runs
# nginx:alpine, so every image on the rig after a drop of built-app is either a
# stock image or somebody else's.
project=built-app
version=3.4.0
image_web=built-app-web
image_worker=built-app-worker
projdir_remote="$apps/$project"
neighbour=demo
neighbour_version=1.2.0

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    rig_ssh "docker image rm -f $image_web:$version $image_worker:$version $image_web:current $image_worker:current; rm -f /tmp/$project-*.tar.gz" >/dev/null 2>&1
    docker image rm -f "$image_web:$version" "$image_worker:$version" \
        "$image_web:current" "$image_worker:current" >/dev/null 2>&1
    rm -f "${TMPDIR:-/tmp}/$project-"*.tar.gz
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! command -v docker >/dev/null; then
    echo "error: this suite builds images on this workstation, and docker is not on PATH" >&2
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
neighbourdir="$tmpdir/$neighbour"
init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
kasbah_bounded() (
    cd "${KASBAH_CWD:-$projdir}" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
build_push() { kasbah_bounded build-push "$@"; }
deploy()     { kasbah_bounded deploy "$@"; }
drop()       { kasbah_bounded drop "$@"; }

# Every tag on the rig right now, one per line.
rig_tags() { rig_ssh "docker images --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | tr -d '\r'; }
has_tag()  { local t; t="$(rig_tags)"; grep -qxF "$1" <<<"$t"; }
remote_exists() { rig_ssh "test -e '$1' && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
# What Traefik answers for a host, waited for rather than sampled: the file
# provider notices a fragment appearing or vanishing "within a couple of
# seconds" (docs/traefik.md), and a single curl the instant a deploy returns
# reads the state before that. The deadline lives on the far side, which is the
# idiom every other probe here uses — one session, not thirty.
wait_http() {   # wait_http <host> <expected-code>
    rig_ssh "c=; for i in \$(seq 1 30); do
                 c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $1' http://127.0.0.1/)
                 [ \"\$c\" != '$2' ] || break
                 sleep 1
             done
             printf '%s' \"\$c\"" 2>/dev/null | tr -d '\r'
}

# Containers compose labelled for a project, running or not.
labelled() {
    rig_ssh "docker ps -a --filter label=com.docker.compose.project=$1 --format '{{.Names}}'" \
        2>/dev/null | tr -d '\r' | LC_ALL=C sort | tr '\n' ' '
}

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — nothing to drop" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do (docs/phases/02-spine.md → Findings).
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    if ! grep -qF "threaded mode" <<<"$limit_probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
        sed 's/^/       | /' <<<"$limit_probe" >&2
        exit 2
    fi
    new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
fi

# --- The neighbour, deployed first so it is running through everything ------------
if ! fixture_repo_make "$neighbourdir" "$repo_dir/tests/fixtures/$neighbour" "v$neighbour_version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the $neighbour fixture a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
KASBAH_CWD="$neighbourdir" deploy "$RIG_TARGET" >/dev/null 2>&1
rig_setup_env "$apps/$neighbour" </dev/null >/dev/null 2>&1
KASBAH_CWD="$neighbourdir" deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the $neighbour deploy failed (exit $rc) — there is no neighbour to survive the drop" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# --- The project being dropped ----------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push of $version failed (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
deploy "$RIG_TARGET" >/dev/null 2>&1
rig_setup_env "$projdir_remote" </dev/null >/dev/null 2>&1
deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the $version deploy failed (exit $rc) — there is nothing to drop" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# Two pieces of state a drop must keep, in the two places kasbah puts data. The
# hooks' breadcrumb file is a real bind mount the fixture declares; the data-path
# file is planted, because this fixture's mounts all live under the project
# directory and <data>/<name> is the other half of the promise.
rig_ssh "mkdir -p $apps/data/$project && printf 'kasbah-drop-data-marker\n' > $apps/data/$project/keepme" \
    >/dev/null 2>&1
crumbs_before="$(rig_ssh "cat $projdir_remote/state/breadcrumbs.log" 2>/dev/null | tr -d '\r')"
if ! grep -qF "post-deploy version=$version" <<<"$crumbs_before"; then
    echo "error: the deploy left no breadcrumbs to prove data survives a drop" >&2
    exit 2
fi

# The positive that makes every "unrouted" assertion below mean something: this
# host really is served right now, through the fragment the drop is about to
# remove.
served=$(wait_http "$project.test" 200)
if [ "$served" != 200 ]; then
    echo "error: $project.test answers '$served' before any drop — there is no route for a drop to remove" >&2
    exit 2
fi

# The neighbour's whole footprint — every path under its project and data
# directories with its size, mtime and mode. `/apps/demo` is never dropped, so
# asserting it still exists proves nothing; what has to hold is that neither
# drop reached into it.
neighbour_digest() {
    rig_ssh "find $apps/$neighbour $apps/data/$neighbour -printf '%p %s %T@ %m\n' 2>/dev/null | LC_ALL=C sort | md5sum" \
        2>/dev/null | tr -d '\r'
}
neighbour_before="$(neighbour_digest)"
if [ -z "$neighbour_before" ]; then
    echo "error: could not digest the neighbour's tree — the survival assertions would prove nothing" >&2
    exit 2
fi

before_tags="$(rig_tags | LC_ALL=C sort)"
web_id="$(rig_ssh "docker image inspect --format '{{.Id}}' $image_web:$version" 2>/dev/null | tr -d '\r')"
nginx_id="$(rig_ssh "docker image inspect --format '{{.Id}}' nginx:alpine" 2>/dev/null | tr -d '\r')"
assert '[ -n "$web_id" ] && [ -n "$nginx_id" ]' "the two images this suite reasons about have ids"

# --- A run nobody answered --------------------------------------------------------
#
# kasbah_bounded gives the command no terminal, so this is the tri-state's
# give-up branch against a real server: it must stop, and it must have changed
# nothing at all.
drop "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ]' "with no terminal and no --yes, drop stops rather than assuming (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF -- "--yes" "$tmpdir/err"' "naming the flag that would have answered (stderr: $(cli_err))"
assert 'grep -qE "^    $image_web:$version +built by $project" "$tmpdir/out"' \
    "and it printed the plan first, so the question is about something (stdout: $(cli_out))"
assert '[ "$before_tags" = "$(rig_tags | LC_ALL=C sort)" ]' "a run nobody answered removed no image"
assert '[ "$(labelled $project)" = "built-app-cache built-app-web built-app-worker " ]' \
    "and took no container down (got '$(labelled $project)')"

# --- Plain drop -------------------------------------------------------------------
drop "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "the drop exits 0 (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"

assert '[ -z "$(labelled $project)" ]' \
    "every container of the project is gone (left: '$(labelled $project)')"
assert '[ "$(remote_exists $apps/traefik/dynamic/$project.yml)" = no ]' "and its Traefik route"
assert '! has_tag $image_web:$version'   "the built image's version tag is gone"
assert '! has_tag $image_web:current'    "and its :current — every tag of it, unlike prune"
assert '! has_tag $image_worker:$version' "and the second built image's"
assert '! has_tag $image_worker:current'  "and that one's :current too"
still="$(rig_ssh "docker image inspect --format '{{.Id}}' $web_id" 2>/dev/null | tr -d '\r')"
assert '[ -z "$still" ]' \
    "the image behind them is out of the daemon, not merely untagged (got '$still')"

# The kept half, which is the whole claim of the reversible verb.
assert '[ "$(remote_exists $projdir_remote/compose.yml)" = yes ]' "the project directory stays"
assert '[ "$(remote_exists $projdir_remote/.env)" = yes ]'        "with its .env"
assert '[ "$(remote_exists $projdir_remote/versions.log)" = yes ]' "and its deploy record"
assert '[ "$(remote_exists $projdir_remote/state/breadcrumbs.log)" = yes ]' "and its bind-mounted data"
assert '[ "$(remote_exists $apps/data/$project/keepme)" = yes ]'  "and <data>/<name>"

# The neighbour, and the stock images. A stock image is in nobody's `build:`, so
# it is never a candidate — and nginx:alpine is held by a running container of
# another project, which a daemon would refuse to delete anyway.
assert 'has_tag redis:7-alpine' "the stock image this project itself pulled survives — it is in nobody's build:"
assert 'has_tag nginx:alpine'   "and so does the one the neighbouring project is running on"
assert '[ "$(rig_ssh "docker image inspect --format \{\{.Id\}\} nginx:alpine" 2>/dev/null | tr -d "\r")" = "$nginx_id" ]' \
    "the same image, not a re-pull"
assert '[ "$(labelled $neighbour)" = "demo-web " ]' \
    "the neighbour is still up (got '$(labelled $neighbour)')"
assert '[ "$(remote_exists $apps/traefik/dynamic/$neighbour.yml)" = yes ]' "with its route"
serve=$(wait_http "$neighbour.test" 200)
assert '[ "$serve" = 200 ]' "and Traefik still serves it (got '$serve')"
gone_serve=$(wait_http "$project.test" 404)
assert '[ "$gone_serve" = 404 ]' \
    "while the dropped host is unrouted rather than 502 — it served 200 before this drop (got '$gone_serve')"

# --- The redeploy that resurrects it ----------------------------------------------
# built-app declares both a backup: container and pre-deploy hooks, so the drop
# above has to have named the flag the return trip needs — read off the
# manifest, not hedged.
assert 'grep -qF "kasbah deploy $RIG_TARGET --allow-stopped" "$tmpdir/out"' \
    "the drop printed the return command with --allow-stopped (stdout: $(cli_out))"

build_push "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 0 ]' "the images ship again (exit $rc: $(cli_err))"
# --allow-stopped, because versions.log survived the drop and the containers its
# pre-deploy hooks and backup would run against did not: the deploy engine
# refuses to deploy over a stack with history and no containers unless told they
# are meant to be down. It is the command drop printed, asserted above.
deploy "$RIG_TARGET" --allow-stopped; rc=$?
assert '[ "$rc" = 0 ]' "and the redeploy succeeds (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(labelled $project)" = "built-app-cache built-app-web built-app-worker " ]' \
    "the containers are back (got '$(labelled $project)')"
crumbs_after="$(rig_ssh "cat $projdir_remote/state/breadcrumbs.log" 2>/dev/null | tr -d '\r')"
assert 'grep -qF "$crumbs_before" <<<"$crumbs_after"' \
    "and every breadcrumb written before the drop is still in the file — data intact
        before: $crumbs_before
        after:  $crumbs_after"
assert '[ "$(rig_ssh "cat $apps/data/$project/keepme" 2>/dev/null | tr -d "\r")" = kasbah-drop-data-marker ]' \
    "and so is the file under <data>/<name>"
resurrected=$(wait_http "$project.test" 200)
assert '[ "$resurrected" = 200 ]' "and the route is back (got '$resurrected')"

# --- drop --prune -----------------------------------------------------------------
#
# The mail claim, which only --prune releases (08-keep.md, D11). The registry is
# planted rather than installed: this suite runs against `server init --no-mail`,
# and what is under test is the rewrite of that one file, which is the only thing
# asked whether the stack serves a domain.
rig_ssh "mkdir -p $apps/mail && cat > $apps/mail/kasbah.yml" <<'REG' >/dev/null 2>&1
name: mail
primary_domain: mail.rig.test
domains:
  - mail.rig.test
  - built-app.test
  - other.rig.test
REG
cat >> "$projdir/kasbah.yml" <<'YML'

mail:
  domain: built-app.test
YML

drop "$RIG_TARGET" --prune --yes; rc=$?
assert '[ "$rc" = 0 ]' "--prune exits 0 (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"
assert '[ "$(remote_exists $projdir_remote)" = no ]' "nothing is left under $projdir_remote"
assert '[ "$(remote_exists $apps/data/$project)" = no ]' "or under $apps/data/$project"
assert '[ -z "$(labelled $project)" ]' "no container of it remains (left: '$(labelled $project)')"
assert '! has_tag $image_web:current && ! has_tag $image_worker:current' "and no image of it"
registry="$(rig_ssh "cat $apps/mail/kasbah.yml" 2>/dev/null | tr -d '\r')"
assert '! grep -qF "built-app.test" <<<"$registry"' \
    "the mail claim is released from the registry (got: $registry)"
assert 'grep -qF "other.rig.test" <<<"$registry"' "the other domain stays (got: $registry)"
assert 'grep -qF "primary_domain: mail.rig.test" <<<"$registry"' "and the primary (got: $registry)"
assert 'grep -qF "add-mail-domain $RIG_TARGET built-app.test" "$tmpdir/err"' \
    "and the run names the command that reverses it (stderr: $(cli_err))"

# The neighbour, through the whole thing.
assert '[ "$(labelled $neighbour)" = "demo-web " ]' "the neighbour is still up (got '$(labelled $neighbour)')"
serve=$(wait_http "$neighbour.test" 200)
assert '[ "$serve" = 200 ]' "and still served (got '$serve')"
assert 'has_tag nginx:alpine' "the stock image it runs on survived both drops"
assert 'has_tag redis:7-alpine' "and so did the one the dropped project pulled"
assert '[ "$neighbour_before" = "$(neighbour_digest)" ]' \
    "and its own tree is byte for byte as it was before either drop
        before: $neighbour_before
        after:  $(neighbour_digest)"

# --- Idempotence -------------------------------------------------------------------
drop "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "a second drop exits 0 (exit $rc: $(cli_err))"
assert 'grep -qF "nothing to drop" "$tmpdir/out"' "and has nothing left to do (stdout: $(cli_out))"

# --- --prune on a project that is not there ------------------------------------------
#
# After the run above there is nothing of built-app on this server, so this is
# the never-deployed shape, reached the only way a rig can reach it honestly.
# Both spellings, because the interesting one is the flag that does nothing: a
# run with no terminal and no --yes must still be 0 when there was nothing to
# ask about.
sed -i '/^mail:$/,$d' "$projdir/kasbah.yml"
for flags in "--prune --yes" "--prune"; do
    drop "$RIG_TARGET" $flags; rc=$?
    assert '[ "$rc" = 0 ]' "--prune on a project that is not on the server exits 0 with '$flags' (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"
    assert 'grep -qF "nothing to drop" "$tmpdir/out"' "and says so (stdout: $(cli_out))"
    assert '! grep -qF "type the project name" "$tmpdir/out"' \
        "with no confirmation, since there is nothing to confirm (stdout: $(cli_out))"
    assert '[ "$(remote_exists $projdir_remote)" = no ]' "and creates nothing where the project was"
done
assert '[ "$neighbour_before" = "$(neighbour_digest)" ]' "the neighbour is still untouched"

# --- Leave the rig as it was found, but only on success ------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $image_web:$version $image_worker:$version $image_web:current $image_worker:current >/dev/null 2>&1; true" >/dev/null 2>&1
    left="$(rig_tags | grep -E '^built-app-' | tr '\n' ' ')"
    assert '[ -z "$left" ]' "every tag this suite made is gone from the rig (left: $left)"
    rig_clean || fail=1
fi

exit "$fail"
