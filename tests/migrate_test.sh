#!/usr/bin/env bash
# Test: `kasbah migrate` in a project (internal/migrate) — everything that needs
# no server. Hermetic: a scratch project per case, no ssh, no docker. The server
# half, `kasbah migrate server`, is the rig's (tests/integration/migrate_test.sh).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

run() { "$KASBAH_BIN" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
out() { cat "$tmpdir/out"; }
err() { cat "$tmpdir/err"; }

# --- Help and the command line --------------------------------------------------
run migrate --help; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "Usage: kasbah migrate" "$tmpdir/out"' "--help prints the usage, exit 0 (exit $rc)"
run --help; rc=$?
assert 'grep -qF "  migrate server USER@HOST [--yes] [--undo]" "$tmpdir/out"' "the top-level usage lists migrate server"
assert 'grep -qF "  migrate " "$tmpdir/out"' "and migrate"

run migrate server; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "no server given" "$tmpdir/err"' "migrate server without a server (exit $rc: $(err))"
run migrate --yes; rc=$?
assert '[ "$rc" = 1 ] && grep -qF -- "--yes and --undo belong to" "$tmpdir/err"' "--yes outside migrate server (exit $rc: $(err))"
run migrate demo; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "unexpected argument" "$tmpdir/err"' "a stray argument (exit $rc: $(err))"
run migrate server a@b c@d; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "two servers" "$tmpdir/err"' "two servers (exit $rc: $(err))"

# --- Not a project ----------------------------------------------------------------
mkdir -p "$tmpdir/empty"
( cd "$tmpdir/empty" && run migrate ); rc=$?
assert '[ "$rc" = 2 ]' "no kasbah.yml is exit 2 (exit $rc: $(err))"

# --- A schema-1 project: nothing to do --------------------------------------------
mkdir -p "$tmpdir/one"
printf 'schema: 1\r\nkasbah_version: 0.1.0\r\nname: demo\r\ndomain: demo.test\r\n' >"$tmpdir/one/kasbah.yml"
( cd "$tmpdir/one" && run migrate ); rc=$?
assert '[ "$rc" = 0 ]' "a schema-1 manifest exits 0 (exit $rc: $(err))"
assert 'grep -qF "nothing to migrate: kasbah.yml is at schema 1" "$tmpdir/out"' "and says so (said '$(out)')"
assert '[ "$(cat "$tmpdir/one/kasbah.yml")" = "$(printf "schema: 1\r\nkasbah_version: 0.1.0\r\nname: demo\r\ndomain: demo.test\r")" ]' \
    "the manifest is untouched, CRLF included"
assert '[ ! -e "$tmpdir/one/.kasbah" ]' "and no state file is created"

# --- A newer schema: the manifest's own refusal ---------------------------------------
mkdir -p "$tmpdir/two"
printf 'schema: 2\nkasbah_version: 2.0.0\nname: demo\n' >"$tmpdir/two/kasbah.yml"
( cd "$tmpdir/two" && run migrate ); rc=$?
assert '[ "$rc" = 1 ]' "a newer schema is refused (exit $rc)"
assert 'grep -qF "schema 2 is newer than this kasbah" "$tmpdir/err"' "naming the schema (said '$(err)')"

# --- An older schema with no step: refused, nothing changed -------------------------------
mkdir -p "$tmpdir/zero"
printf 'schema: 0\nkasbah_version: 0.1.0\nname: demo\n' >"$tmpdir/zero/kasbah.yml"
( cd "$tmpdir/zero" && run migrate ); rc=$?
assert '[ "$rc" = 1 ]' "schema 0 with no step registered is refused (exit $rc: $(err))"
assert 'grep -qF "no migration step from major 0" "$tmpdir/err"' "naming the gap (said '$(err)')"
assert 'grep -qxF "schema: 0" "$tmpdir/zero/kasbah.yml"' "and the manifest is untouched"

exit "$fail"
