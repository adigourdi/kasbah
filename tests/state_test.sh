#!/usr/bin/env bash
# Test: lib/state.sh — the state file as the Bash commands still write it
# (drop, logs, exec, check --server, server status): merged, never replaced; null reads as empty;
# an unparseable file is an error and is never overwritten.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_VERSION="$(cat "$repo_dir/VERSION")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

state_dir="$tmpdir/state"
mkdir -p "$state_dir"
run_state() {
    ( cd "$state_dir" && bash -c '
        set -uo pipefail
        . "$KASBAH_LIB_DIR/state.sh"
        '"$1"'
    ' 2>&1 )
}

out="$(run_state 'state_record last_server deploy@vps last_version 1.2.3; cat .kasbah/state.json')"; rc=$?
assert '[ "$rc" = "0" ]' "state_record creates the file when there is none (rc $rc: $out)"
assert '[ "$(jq -r .last_server <<<"$out")" = "deploy@vps" ]' "recording last_server (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]'     "and last_version"
assert '[ "$(jq -r .kasbah_version <<<"$out")" = "$KASBAH_VERSION" ]' \
    "with the shape init-project would have written"

# Merged, never replaced: a field this command does not own has to survive.
run_state 'jq ".schema_migrations_applied = [\"m1\"] | .future_key = 7" .kasbah/state.json > s && mv s .kasbah/state.json' >/dev/null
out="$(run_state 'state_record last_server other@vps; cat .kasbah/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "other@vps" ]' "a re-record updates the field (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]' "leaves the fields it was not given alone"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[\"m1\"]" ]' "keeps another command's field"
assert '[ "$(jq -r .future_key <<<"$out")" = "7" ]' "and a key it has never heard of"

# A state file that exists but holds nothing gets the shape as well, which is
# what the merge is for: the fields this call did not set have to be present and
# null, not missing.
printf '{}\n' > "$state_dir/.kasbah/state.json"
out="$(run_state 'state_record last_server thin@vps; cat .kasbah/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "thin@vps" ]' "an empty object is filled in (got '$out')"
# `jq -r .last_version` prints "null" for an absent key just as it does for a
# null one, so presence is asserted rather than the rendered value.
assert 'jq -e "has(\"last_version\") and .last_version == null" >/dev/null <<<"$out"' \
    "with the untouched fields present and null rather than missing (got '$out')"
assert '[ "$(jq -r .kasbah_version <<<"$out")" = "$KASBAH_VERSION" ]' "and the kasbah version"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[]" ]' "and the migration list"
run_state 'state_record last_server other@vps last_version 1.2.3' >/dev/null

out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"
assert '[ "$out" = "other@vps" ]' "state_get reads it back (got '$out')"
out="$(run_state 'state_get last_deploy v; printf "[%s]\n" "$v"')"
assert '[ "$out" = "[]" ]' "and a null field reads as empty rather than the string null (got '$out')"

printf 'not json\n' > "$state_dir/.kasbah/state.json"
out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"; rc=$?
assert '[ "$rc" != "0" ]' "an unparseable state file is an error, not an empty default (rc $rc: $out)"
out="$(run_state 'state_record last_server x@y')"; rc=$?
assert '[ "$rc" != "0" ]' "and it is never overwritten (rc $rc: $out)"
assert '[ "$(cat "$state_dir/.kasbah/state.json")" = "not json" ]' "the file is left as it was"

exit "$fail"
