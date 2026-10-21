#!/usr/bin/env bash
# Integration test: crossing a major (docs/server-setup.md → Server marker,
# compatibility rule) against the live rig, with the real binary and its one
# real step, 0→1.
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
               --traefik-auth="dashadmin:rig-dashboard-pw")

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

sleep 1
run migrate server "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "migrating again succeeds (exit $rc: $(err))"
assert '[ "$(marker_version | cut -d. -f1)" = "$major" ]' "back at this major ($(marker_version))"
# The undo put the originals back, so the first snapshot still holds them:
# a move from the same major reuses it rather than snapshotting over it.
assert '[ "$(snapshots)" = "$snap" ]' "the first snapshot is reused, not rewritten ($(snapshots | tr '\n' ' '))"
assert 'grep -qF "an earlier run'"'"'s, kept" <<<"$(out)"' "and the report says so (said '$(out)')"
newest=$snap

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
