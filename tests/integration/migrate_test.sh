#!/usr/bin/env bash
# Integration test: crossing a major (docs/server-setup.md → Server marker,
# compatibility rule) against the live rig, with the real binary and its
# steps: 0→1, and 1→2 from a kasbah of major 2.
#
# The server is prepared, then its marker is planted at kasbah 0.9.0 — an
# older major. Every prepared-server command must refuse *before* shipping its
# binary (the server's bin directory is emptied first, so a shipped binary
# would be visible), naming `kasbah migrate server`. `kasbah migrate server`
# is the one command allowed through: it prompts (no TTY and no --yes is a
# hard fail naming the flag), snapshots the marker into <apps>/.kasbah/migrate/
# and writes the marker last; --undo puts the snapshot back, and is refused
# once a project's versions.log carries an entry newer than the snapshot. A
# newer major keeps its refusal in both commands. `kasbah migrate` in a
# schema-1 project has nothing to do and says so.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
bin_dir=$apps/.kasbah/bin
bin=$bin_dir/kasbah
marker=$apps/.kasbah/server.json
snapdir=$apps/.kasbah/migrate

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
trap 'rm -rf "$tmpdir"' EXIT

if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh — is the rig up? tests/rig/rig.sh up" >&2
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

ours=$(kasbah_bin_version) || { echo "error: $KASBAH_BIN --version failed" >&2; exit 2; }
major=${ours%%.*}

run() { kasbah_cli "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
out() { tr -d '\r' <"$tmpdir/out"; }
err() { tr -d '\r' <"$tmpdir/err"; }
remote_cat() { rig_ssh "cat $1" 2>/dev/null | tr -d '\r'; }
remote_exists() { rig_ssh "[ -e $1 ] && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
marker_version() { remote_cat "$marker" | jq -r .kasbah_version; }
plant_marker() { printf '%s\n' "$1" | rig_ssh "cat > $marker" >/dev/null 2>&1; }
snapshots() { rig_ssh "ls $snapdir 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '\.tar$' || true; }
uploads_left() { rig_ssh "ls -A $bin_dir 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -F .kasbah. || true; }

# --- A prepared server, then its marker planted at an older major -------------
if ! run server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}"; then
    echo "error: server init failed on a cleaned rig:" >&2
    err >&2
    exit 2
fi
marker_json=$(remote_cat "$marker")
if ! jq -e .apps_path <<<"$marker_json" >/dev/null 2>&1; then
    echo "error: init left no readable marker at $marker" >&2
    exit 2
fi

plant_marker "$(jq '.kasbah_version = "0.9.0"' <<<"$marker_json")"
# Emptied, so that a binary shipped past the refusal would be visible.
rig_ssh "rm -rf $bin_dir" >/dev/null 2>&1

run server status "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ]' "server status refuses an older-major marker (exit $rc: $(err))"
assert 'grep -qF "kasbah migrate server $RIG_TARGET" <<<"$(err)"' "the refusal names the remedy (said '$(err)')"
assert 'grep -qF "0.9.0" <<<"$(err)"' "and the server's version (said '$(err)')"
assert '[ "$(remote_exists "$bin")" = no ]' "nothing was shipped to the refused server"
assert '[ -z "$(uploads_left)" ]' "and no upload is left behind ($(uploads_left))"

run server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
assert '[ "$rc" = 1 ]' "server init refuses an older-major marker too (exit $rc: $(err))"
assert 'grep -qF "kasbah migrate server $RIG_TARGET" <<<"$(err)"' "naming the same remedy (said '$(err)')"
assert '[ "$(remote_exists "$bin")" = no ]' "init shipped nothing either"
assert '[ "$(marker_version)" = "0.9.0" ]' "the marker is untouched ($(marker_version))"

# --- The prompt: no TTY, no --yes ----------------------------------------------
run migrate server "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ]' "without a terminal and --yes, migrate server stops (exit $rc: $(err))"
assert 'grep -qF -- "--yes" <<<"$(err)"' "naming --yes (said '$(err)')"
assert 'grep -qF "from major 0 (kasbah 0.9.0) to $major" <<<"$(out)"' "after printing the plan (said '$(out)')"
assert 'grep -qF "step 0->1" <<<"$(out)"' "with its one step (said '$(out)')"
assert 'grep -qF "$snapdir/0-to-$major-" <<<"$(out)"' "and the snapshot path (said '$(out)')"
assert '[ "$(marker_version)" = "0.9.0" ]' "and changed nothing ($(marker_version))"
assert '[ -z "$(snapshots)" ]' "no snapshot was written ($(snapshots))"

# --- Migrate ------------------------------------------------------------------
run migrate server "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "migrate server --yes succeeds (exit $rc: $(err))"
assert 'grep -qF "migrated $RIG_TARGET from major 0 to $major" <<<"$(out)"' "and reports it (said '$(out)')"
after=$(marker_version)
assert '[ "${after%%.*}" = "$major" ]' "the marker is at this kasbah's major (kasbah_version '$after')"
assert '[ "$(remote_cat "$marker" | jq -r .apps_path)" = "$apps" ]' "the rest of the marker is kept"
assert '[ "$(remote_exists "$bin")" = yes ]' "migrate server shipped this build"
snap=$(snapshots)
assert '[ "$(wc -l <<<"$snap")" = 1 ] && [[ $snap == 0-to-$major-*.tar ]]' "one snapshot, named for the move ('$snap')"
assert '[ "$(rig_ssh "tar -xOf $snapdir/$snap .kasbah/server.json" 2>/dev/null | tr -d "\r" | jq -r .kasbah_version)" = "0.9.0" ]' \
    "the snapshot holds the old marker"
assert '[ "$(rig_ssh "stat -c %a $snapdir/$snap" 2>/dev/null | tr -d "\r")" = 644 ]' "the snapshot is 644"
assert '[ "$(remote_exists "$apps/.kasbah/migrate.lock")" = yes ]' "the migration lock file exists"
assert '[ "$(remote_exists "$apps/traefik/.deploy.lock")" = no ]' "reserved directories are not projects, so traefik/ got no deploy lock"

run server status "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 0 ]' "server status runs again after the migration (exit $rc: $(err))"

run migrate server "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "a rerun at this major succeeds (exit $rc: $(err))"
assert 'grep -qF "nothing to migrate" <<<"$(out)"' "and says there is nothing to do (said '$(out)')"
assert '[ "$(snapshots)" = "$snap" ]' "writing no second snapshot ($(snapshots))"

# --- Undo ---------------------------------------------------------------------
run migrate server "$RIG_TARGET" --undo; rc=$?
assert '[ "$rc" = 1 ] && grep -qF -- "--yes" <<<"$(err)"' "undo prompts too (exit $rc: $(err))"
run migrate server "$RIG_TARGET" --undo --yes; rc=$?
assert '[ "$rc" = 0 ]' "undo --yes succeeds (exit $rc: $(err))"
assert '[ "$(marker_version)" = "0.9.0" ]' "the marker is back at 0.9.0 ($(marker_version))"
assert 'grep -qF "back at major 0" <<<"$(out)"' "and the report says so (said '$(out)')"
assert '[ "$(remote_exists "$snapdir/$snap.undone")" = yes ]' "and noted the snapshot undone"

sleep 1
run migrate server "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "migrating again succeeds (exit $rc: $(err))"
assert '[ "$(marker_version | cut -d. -f1)" = "$major" ]' "back at this major ($(marker_version))"
# The undone snapshot is history: a move after it takes a fresh one.
newest=$(snapshots | tail -n 1)
assert '[ "$(wc -l <<<"$(snapshots)")" = 2 ] && [ "$newest" != "$snap" ]' "a fresh snapshot beside the undone one ($(snapshots | tr '\n' ' '))"
assert '! grep -qF "an earlier run'"'"'s, kept" <<<"$(out)"' "and none is reported reused (said '$(out)')"

# A project deployed after the snapshot: its versions.log line (vlog.Line's
# format) stamped an hour from now.
stamp=$(date -u -d "@$(( $(date +%s) + 3600 ))" +%Y-%m-%dT%H:%M:%S+00:00)
rig_ssh "mkdir -p $apps/alpha && printf '%s deploy 1.0.0 - kasbah=$ours digest=-\n' '$stamp' > $apps/alpha/versions.log" >/dev/null 2>&1
run migrate server "$RIG_TARGET" --undo --yes; rc=$?
assert '[ "$rc" = 1 ]' "undo is refused once a project has deployed since the snapshot (exit $rc: $(err))"
assert 'grep -qF "alpha was deployed at $stamp" <<<"$(err)"' "naming the project (said '$(err)')"
assert 'grep -qF "$snapdir/$newest" <<<"$(err)"' "and the tarball for the manual path (said '$(err)')"
assert '[ "$(marker_version | cut -d. -f1)" = "$major" ]' "and the marker is unchanged ($(marker_version))"

# --- A newer major keeps its refusal ------------------------------------------
plant_marker "$(jq '.kasbah_version = "99.0.0"' <<<"$marker_json")"
run migrate server "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 1 ]' "migrate server refuses a newer major (exit $rc: $(err))"
assert 'grep -qF "99.0.0" <<<"$(err)"' "naming it (said '$(err)')"
run server status "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "99.0.0" <<<"$(err)"' "and so does server status (exit $rc: $(err))"
assert '[ "$(marker_version)" = "99.0.0" ]' "neither touched the marker ($(marker_version))"

# --- 1→2: scoped backends, Traefik off kasbah-net -----------------------------
# Only a kasbah of major 2 or later carries this step. A 1.x server is
# planted: a project with a bare backend, kasbah-net in Traefik's compose
# file, and Traefik created on it by that file, as 1.x started it, and on a
# project network too.
if [ "$major" -ge 2 ]; then
    rig_ssh "rm -rf $apps/alpha $snapdir" >/dev/null 2>&1
    plant_marker "$(jq '.kasbah_version = "1.9.0"' <<<"$marker_json")"
    frag=$apps/traefik/dynamic/zeta.yml
    rig_ssh "mkdir -p $apps/zeta" >/dev/null 2>&1
    printf 'http:\n  services:\n    zeta:\n      loadBalancer:\n        servers:\n          - url: "http://web:80"\n' |
        rig_ssh "cat > $frag" >/dev/null 2>&1
    rig_ssh "sed -i 's/^    container_name: traefik\$/&\\n    networks:\\n      - kasbah-net/' $apps/traefik/compose.yml && printf 'networks:\\n  kasbah-net:\\n    name: kasbah-net\\n' >> $apps/traefik/compose.yml" >/dev/null 2>&1
    rig_ssh "cd $apps/traefik && docker compose -p traefik up -d && docker network create zeta_kasbah >/dev/null && docker network connect zeta_kasbah traefik" >/dev/null 2>&1
    compose_v1=$(remote_cat "$apps/traefik/compose.yml")
    assert 'grep -qF -- "- kasbah-net" <<<"$compose_v1"' "the planted compose file names kasbah-net"
    assert '[ "$(rig_ssh "docker inspect -f {{.HostConfig.NetworkMode}} traefik" 2>/dev/null | tr -d "\r")" = kasbah-net ]' "Traefik was created on kasbah-net"

    run migrate server "$RIG_TARGET"; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "step 1->2" <<<"$(out)"' "the plan names step 1->2 (exit $rc: $(out))"
    assert 'grep -qF "zeta is unjudged" <<<"$(out)"' "and lists, before asking, a project whose compose cannot be read (said '$(out)')"
    assert '[ "$(remote_cat "$frag")" = "$(printf "http:\n  services:\n    zeta:\n      loadBalancer:\n        servers:\n          - url: \"http://web:80\"")" ]' "the unanswered prompt changed nothing"

    run migrate server "$RIG_TARGET" --yes; rc=$?
    assert '[ "$rc" = 0 ]' "migrate server 1->2 succeeds (exit $rc: $(err))"
    assert 'grep -qF "http://web.zeta_kasbah:80" <<<"$(remote_cat "$frag")"' "the fragment's backend is scoped ($(remote_cat "$frag"))"
    assert '! grep -qF kasbah-net <<<"$(remote_cat "$apps/traefik/compose.yml")"' "Traefik's compose file no longer names kasbah-net"
    assert 'rig_ssh "docker compose -f $apps/traefik/compose.yml config -q" >/dev/null 2>&1' "and still reads as compose"
    assert '! rig_ssh "docker inspect -f {{json .NetworkSettings.Networks}} traefik" 2>/dev/null | grep -qF "\"kasbah-net\""' "Traefik is off kasbah-net"
    assert 'rig_ssh "docker network inspect kasbah-net" >/dev/null 2>&1' "and kasbah-net, which Traefik was created on, is kept"
    assert 'grep -qF "traefik disconnected from kasbah-net, which is kept" <<<"$(out)"' "and the report says so (said '$(out)')"
    assert 'grep -qF "warning: zeta is unjudged" <<<"$(out)"' "the report repeats the warning (said '$(out)')"
    assert 'rig_ssh "docker restart traefik" >/dev/null 2>&1' "Traefik still starts after a restart"
    assert '[ "$(rig_ssh "docker inspect -f {{.State.Running}} traefik" 2>/dev/null | tr -d "\r")" = true ]' "and is running"

    run migrate server "$RIG_TARGET" --undo --yes; rc=$?
    assert '[ "$rc" = 0 ]' "undo of 1->2 succeeds (exit $rc: $(err))"
    assert 'grep -qF "http://web:80" <<<"$(remote_cat "$frag")"' "the fragment is put back"
    assert '[ "$(remote_cat "$apps/traefik/compose.yml")" = "$compose_v1" ]' "so is Traefik's compose file"
    assert 'grep -qF "docker network connect kasbah-net traefik" <<<"$(out)"' "and the report says how to put Traefik back on kasbah-net (said '$(out)')"
    assert 'grep -qF "$bin by hand" <<<"$(out)"' "and where an older major's binary goes (said '$(out)')"

    # Migrated again, a 2.x server init recreates Traefik off kasbah-net, and
    # the network, with nothing left on it, goes.
    sleep 1
    run migrate server "$RIG_TARGET" --yes; rc=$?
    assert '[ "$rc" = 0 ]' "migrating 1->2 again succeeds (exit $rc: $(err))"
    run server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
    assert '[ "$rc" = 0 ]' "server init after 1->2 succeeds (exit $rc: $(err))"
    assert '[ "$(rig_ssh "docker inspect -f {{.HostConfig.NetworkMode}} traefik" 2>/dev/null | tr -d "\r")" != kasbah-net ]' "Traefik is recreated off kasbah-net"
    assert '! rig_ssh "docker network inspect kasbah-net" >/dev/null 2>&1' "kasbah-net is removed"
    assert 'grep -qF "kasbah-net removed" <<<"$(err)"' "and init says so (said '$(err)')"
    rig_ssh "rm -rf $frag $apps/zeta; docker network rm zeta_kasbah" >/dev/null 2>&1
fi

# --- kasbah migrate in a schema-1 project ------------------------------------
cp -r "$repo_dir/tests/fixtures/demo" "$tmpdir/demo"
( cd "$tmpdir/demo" && kasbah_cli migrate >"$tmpdir/out" 2>"$tmpdir/err" </dev/null ); rc=$?
assert '[ "$rc" = 0 ]' "kasbah migrate in a schema-1 project exits 0 (exit $rc: $(err))"
assert 'grep -qF "nothing to migrate" <<<"$(out)"' "and says there is nothing to do (said '$(out)')"
assert 'grep -qxF "kasbah_version: 0.1.0" "$tmpdir/demo/kasbah.yml"' "leaving the manifest alone"

if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi
exit "$fail"
