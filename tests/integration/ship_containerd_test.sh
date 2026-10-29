#!/usr/bin/env bash
# Integration test: `kasbah build-push` from a containerd-store workstation —
# whose `docker save` names every layer by its compressed digest — still
# leaves the layers the server holds out of the stream.
#
# The workstation is a throwaway Docker-in-Docker on this host, reached over
# DOCKER_HOST on a unix socket bind-mounted out of it, group-owned by this
# user's group; docker 29's dind runs the containerd store.
# The rig is seeded with the fixture's base images from that engine (under
# tags of this suite's own), so the first push has layers to skip and a map
# to learn. Proved: the first push runs one learning export and skips them;
# a re-push with one layer changed skips without a learning export; the
# rig's layers.map has entries, and shrinks once the old images are removed
# and `remote layers` runs.
#
# Removes only what it created, by name: the dind container (with its
# anonymous volume), the images it loaded or tagged on the rig.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker, no dind).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

dind=kasbah-ship-containerd-dind
dind_image="${KASBAH_DIND_IMAGE:-docker:29-dind}"
project=built-app
web=built-app-web:1.5.0
worker=built-app-worker:1.5.0
web2=built-app-web:1.5.1
worker2=built-app-worker:1.5.1
seed_web=kasbah-containerd-seed-nginx:1
seed_worker=kasbah-containerd-seed-alpine:1
apps=/apps
map="$apps/.kasbah/layers.map"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
started_dind=0
cleanup() {
    rig_ssh "docker image rm -f $web $worker $web2 $worker2 built-app-web:current built-app-worker:current $seed_web $seed_worker" >/dev/null 2>&1
    [ "$started_dind" = 1 ] && docker rm -f -v "$dind" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ] || ! command -v docker >/dev/null || ! rig_reachable; then
    echo "error: needs docker on PATH and a running rig (tests/rig/rig.sh up)" >&2
    exit 2
fi
if docker container inspect "$dind" >/dev/null 2>&1; then
    echo "error: a container named $dind already exists — not this run's to remove" >&2
    exit 2
fi
mkdir -p "$tmpdir/sock"
if ! docker run -d --privileged --name "$dind" -v "$tmpdir/sock:/kasbah-sock" -e DOCKER_TLS_CERTDIR= "$dind_image" \
        dockerd --host=unix:///kasbah-sock/docker.sock --group="$(id -g)" >/dev/null 2>"$tmpdir/dind.err"; then
    echo "error: could not start a Docker-in-Docker workstation ($dind_image)" >&2
    sed 's/^/       | /' "$tmpdir/dind.err" >&2
    docker rm -f -v "$dind" >/dev/null 2>&1
    exit 2
fi
started_dind=1
ws="unix://$tmpdir/sock/docker.sock"
# The one bounded readiness wait, 60 s in all: dind starts in a few seconds.
ready=0
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    v="$(DOCKER_HOST="$ws" timeout 2 docker version --format '{{.Server.Version}}' 2>/dev/null)"
    [ -n "$v" ] && { ready=1; break; }
    sleep 1
done
if [ "$ready" != 1 ]; then
    echo "error: the dind workstation's daemon did not answer on $ws within 60 s" >&2
    exit 2
fi
store="$(DOCKER_HOST="$ws" docker info --format '{{json .DriverStatus}}' 2>/dev/null)"
if ! grep -qF '["driver-type","io.containerd.snapshotter.v1"]' <<<"$store"; then
    echo "error: $dind_image does not run the containerd image store (DriverStatus $store)" >&2
    exit 2
fi
wsd() { DOCKER_HOST="$ws" docker "$@"; }

if ! rig_env_init "$tmpdir" || ! rig_clean; then
    echo "error: could not prepare the rig (rig_env_init / rig_clean)" >&2
    exit 2
fi
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup --domain=rig.test \
        --email=ops@rig.test --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw" \
        >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig" >&2
    sed 's/^/       | /' "$tmpdir/init.err" >&2
    exit 2
fi
rig_ssh "docker image rm -f $web $worker $web2 $worker2 $seed_web $seed_worker" >/dev/null 2>&1

# The rig holds the fixture's bases, as this engine stores them.
if ! wsd pull -q nginx:alpine >/dev/null 2>"$tmpdir/pull.err" || ! wsd pull -q alpine:3.20 >/dev/null 2>>"$tmpdir/pull.err" \
   || ! wsd tag nginx:alpine "$seed_web" || ! wsd tag alpine:3.20 "$seed_worker"; then
    echo "error: the dind workstation could not pull the fixture's base images" >&2
    sed 's/^/       | /' "$tmpdir/pull.err" >&2
    exit 2
fi
if ! wsd save "$seed_web" "$seed_worker" | rig_ssh "docker load" >/dev/null 2>"$tmpdir/seed.err"; then
    echo "error: could not seed the rig with the base images" >&2
    sed 's/^/       | /' "$tmpdir/seed.err" >&2
    exit 2
fi

projdir="$tmpdir/$project"
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v1.5.0" 2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    exit 2
fi
build_push() (
    cd "$projdir" || return 2
    DOCKER_HOST="$ws" kasbah_cli build-push "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
stream_line() { grep -m1 'stream:' "$tmpdir/err"; }
learned() { grep -cxF "learning this workstation's layer names: one extra local export, nothing sent" "$tmpdir/err"; }
map_lines() { rig_ssh "if [ -f $map ]; then grep -c . $map; else echo 0; fi" 2>/dev/null | tr -d '\r'; }

# --- The first push learns, and skips the bases ---------------------------------------
build_push; rc=$?
first="$(stream_line)"
echo "note: first push   $first" >&2
assert '[ "$rc" = "0" ]' "a containerd-store workstation ships to the rig (exit $rc: $(cat "$tmpdir/err"))"
assert '[ "$(learned)" = "1" ]' "announcing one learning export (said: $(cat "$tmpdir/err"))"
n1=$(sed -n 's/.*sent; \([0-9]*\) of \([0-9]*\) layers.*/\1/p' <<<"$first")
assert '[ -n "$n1" ] && [ "$n1" -gt 0 ]' "and leaving out the layers the rig holds (said '$first')"
assert '! grep -qF "saves compressed layers" "$tmpdir/err"' "not the nothing-could-be-left-out note (said '$first')"
page=$(rig_ssh "docker run --rm --entrypoint cat $web /usr/share/nginx/html/index.html" 2>&1 | tr -d '\r\n')
assert 'grep -qF "served-by-built-app" <<<"$page"' "the image runs on the rig on its own layers (read '$page')"
m1="$(map_lines)"
echo "note: layers.map after the first push: $m1 entries" >&2
assert '[ -n "$m1" ] && [ "$m1" -gt 0 ]' "the rig's layers.map has entries ($m1)"
mode=$(rig_ssh "stat -c %a $map" 2>/dev/null | tr -d '\r')
assert '[ "$mode" = "664" ]' "at mode 664 ($mode)"

# --- A re-push with one layer changed needs no learning ---------------------------------
sed -i 's|</body></html>|<p id="v2">re-pushed</p></body></html>|' "$projdir/Dockerfile"
if ! ( cd "$projdir" && git add -A && git -c user.name=t -c user.email=t@t commit -qm v2 && git tag v1.5.1 ) >/dev/null 2>&1; then
    echo "error: could not commit the re-push's edit" >&2
    exit 2
fi
build_push; rc=$?
second="$(stream_line)"
echo "note: re-push      $second" >&2
assert '[ "$rc" = "0" ] && [ "$(learned)" = "0" ]' "the re-push ships without a learning export (exit $rc: $(cat "$tmpdir/err"))"
skipped=$(sed -n 's/.*sent; \([0-9]*\) of \([0-9]*\) layers.*/\1 \2/p' <<<"$second")
assert '[ -n "$skipped" ] && [ "$(( ${skipped#* } - ${skipped% *} ))" = "1" ]' \
    "every layer but the changed one stayed home (said '$second')"
whole=$(wsd save "$web2" "$worker2" 2>/dev/null | gzip | wc -c)
echo "note: a whole save of the re-pushed images gzips to $whole bytes" >&2
page2=$(rig_ssh "docker run --rm --entrypoint cat $web2 /usr/share/nginx/html/index.html" 2>&1 | tr -d '\r\n')
assert 'grep -qF "re-pushed" <<<"$page2"' "and the new page runs on the rig (read '$page2')"

# --- The map follows the rig's images -----------------------------------------------------
m2="$(map_lines)"
rig_ssh "docker image rm -f $web $worker" >/dev/null 2>&1
rig_ssh "$apps/.kasbah/bin/kasbah remote layers $apps" >/dev/null 2>"$tmpdir/layers.err"
m3="$(map_lines)"
echo "note: layers.map $m2 entries, $m3 after $web and $worker were removed" >&2
assert '[ -n "$m2" ] && [ -n "$m3" ] && [ "$m3" -lt "$m2" ] && [ "$m3" -gt 0 ]' \
    "the map loses the names of the layers only the removed images held ($m2 -> $m3; $(cat "$tmpdir/layers.err"))"

if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi
exit "$fail"
