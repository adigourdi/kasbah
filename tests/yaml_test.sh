#!/usr/bin/env bash
# Test: lib/common.sh — yaml_load / yaml_query / yaml_forget.
#
# These three replace a `yq` fork per rule with one conversion per file, and the
# whole claim rests on an identity: kislyuk's `yq` parses YAML and execs `jq`
# with the caller's filter, so `yq -r F file` and `jq -r F <<<"$(yq -c . file)"`
# are the same parser answering the same question. A test that only checked
# `kasbah check`'s report would confirm the identity for the dozen filters that
# linter happens to use, on the two files it happens to read.
#
# So the centre of this suite is an equivalence table: documents × filters, each
# cell asserting that yaml_query prints what `yq -r` prints and exits the way it
# exits. The documents are the ones that break readers — empty, comments-only,
# CRLF, multi-document, unparseable — and the filters include one that fails at
# runtime, because the fallbacks throughout lib/check.sh (`|| true`, `|| echo
# false`) are contracts about a non-zero exit.
#
# Around it, the four facts the cache adds that no filter can show: a reload
# replaces, a forget drops, a query after the file changed answers from the
# conversion (invalidation is explicit, never mtime-watched), and the parse
# diagnostic reaches stderr on *every* failed query rather than only the first.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export KASBAH_LIB_DIR="$repo_dir/lib"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export NO_COLOR=1

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

. "$KASBAH_LIB_DIR/common.sh"

# --- The documents ------------------------------------------------------------

# A compose file shaped like the ones `kasbah check` reads, carrying the value
# types the rules actually pull out: a string, a boolean, an integer, a null and
# a multi-line list.
cat > "$tmpdir/compose.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    replicas: 3
    read_only: true
    healthcheck:
    networks:
      - kasbah-net
      - internal
networks:
  kasbah-net:
    external: true
  internal: {}
YAML

: > "$tmpdir/empty.yml"

printf '# nothing but a comment\n# and another\n' > "$tmpdir/comments.yml"

# CRLF throughout, as a Windows editor leaves it.
printf 'services:\r\n  demo-web:\r\n    restart: unless-stopped\r\n' > "$tmpdir/crlf.yml"

# Two documents. `yq -c` emits one JSON document per line and jq runs the filter
# over the stream, which is what `yq -r` does today — this cell is what pins
# that the conversion did not quietly fuse them.
printf 'a: 1\n---\na: 2\n' > "$tmpdir/multidoc.yml"

# A tab where YAML forbids one: PyYAML refuses it with a line and column, which
# is the diagnostic the replay below is about.
printf 'a: 1\n\tb: 2\n' > "$tmpdir/broken.yml"

docs=(compose.yml empty.yml comments.yml crlf.yml multidoc.yml broken.yml)

# --- The filters ---------------------------------------------------------------
# `.` is the parse probe two sections of lib/check.sh use. The rest are the
# shapes the rules ask in: a keys listing, a `// ""` default, a `has()` presence
# test, an indexed scalar, a list splat.
#
# The last one is the cell that matters most: `has()` against the *scalar*
# multidoc.yml puts at `.a` is a jq runtime error, exit 5 — which is the status
# `_cf_has` turns into a false and the reason yaml_query hands jq's own status
# back rather than flattening it. `has()` on a null is not that case (jq answers
# false, exit 0), so a filter that only ever reaches a null would leave the
# fallbacks in lib/check.sh untested; the counter below refuses to let that
# happen again silently.
filters=(
    '.'
    '(.services // {}) | keys | .[]'
    '.services["demo-web"].restart // ""'
    '.services["demo-web"] | has("build")'
    '.services["demo-web"].replicas // ""'
    '.services["demo-web"].read_only // ""'
    '.services["demo-web"].healthcheck // "-"'
    '.services["demo-web"].networks[]?'
    '.networks["kasbah-net"].external // false'
    '.a // ""'
    '.a | has("x")'
)

runtime_errors=0
for d in "${docs[@]}"; do
    f="$tmpdir/$d"
    # Loaded up front, the way cmd_check loads the files it is about to
    # interrogate; the miss path gets its own case below.
    yaml_load "$f" >/dev/null 2>&1
    for filt in "${filters[@]}"; do
        got="$(yaml_query "$f" "$filt" 2>/dev/null)"; got_rc=$?
        want="$(yq -r "$filt" "$f" 2>/dev/null)"; want_rc=$?
        assert '[ "$got" = "$want" ]' \
            "$d {$filt}: same stdout (yaml_query said '$got', yq said '$want')"
        if [ "$d" = broken.yml ]; then
            # The one deliberate divergence, and it is in the *code*, not the
            # verdict: yq exits 1 on a parse error, yaml_query exits 2 —
            # yaml_get's contract, which this repo already reads as "the
            # document did not parse" as distinct from "the key is not there".
            # Every call site branches on zero versus non-zero, never on the
            # number, so this is asserted as such.
            assert '[ "$got_rc" != 0 ] && [ "$want_rc" != 0 ]' \
                "$d {$filt}: both fail (yaml_query $got_rc, yq $want_rc)"
        else
            assert '[ "$got_rc" = "$want_rc" ]' \
                "$d {$filt}: same exit status (yaml_query $got_rc, yq $want_rc)"
        fi
        # A jq runtime error is a status *and* a message, and both have to match
        # — a rule that logs what it could not answer prints what jq said.
        if [ "$want_rc" = 5 ]; then
            runtime_errors=$((runtime_errors + 1))
            got_e="$(yaml_query "$f" "$filt" 2>&1 >/dev/null)"
            want_e="$(yq -r "$filt" "$f" 2>&1 >/dev/null)"
            assert '[ "$got_e" = "$want_e" ]' \
                "$d {$filt}: same jq diagnostic (said '$got_e', yq said '$want_e')"
        fi
    done
done
assert '[ "$runtime_errors" -gt 0 ]' \
    "the table really does reach a jq runtime error (counted $runtime_errors)"

# A parse failure is exit 2 specifically, since that is the contract the header
# states and `yaml_get` already uses.
yaml_query "$tmpdir/broken.yml" '.' >/dev/null 2>&1; rc=$?
assert '[ "$rc" = "2" ]' "a document that does not parse is exit 2 (got $rc)"
yaml_load "$tmpdir/broken.yml" >/dev/null 2>&1; rc=$?
assert '[ "$rc" = "2" ]' "and so is yaml_load on it (got $rc)"
yaml_load "$tmpdir/does-not-exist.yml" >/dev/null 2>&1; rc=$?
assert '[ "$rc" = "2" ]' "a file that is not there is exit 2 as well (got $rc)"

# --- Convert on a miss ---------------------------------------------------------
# A caller nobody preloaded for still gets the right answer; it just pays the
# fork. Asserted in a subshell, because that is where the miss happens in real
# code — `x="$(yaml_query …)"` — and the conversion it makes there must not
# survive into this shell.
missfile="$tmpdir/miss.yml"
printf 'name: unloaded\n' > "$missfile"
out="$(yaml_query "$missfile" '.name')"; rc=$?
assert '[ "$out" = "unloaded" ] && [ "$rc" = "0" ]' \
    "a query against a file nobody loaded converts it (said '$out', rc $rc)"
assert '[ -z "${_KASBAH_YAML_RC[$missfile]+set}" ]' \
    "and the conversion made inside the subshell does not reach this shell"

# --- Reload replaces -----------------------------------------------------------
mut="$tmpdir/mutable.yml"
printf 'name: first\n' > "$mut"
yaml_load "$mut"
assert '[ "$(yaml_query "$mut" ".name")" = "first" ]' "the first conversion is what is answered"
printf 'name: second\n' > "$mut"
assert '[ "$(yaml_query "$mut" ".name")" = "first" ]' \
    "a query after the file changed on disk answers from the conversion — invalidation is explicit, never mtime-watched"
yaml_load "$mut"
assert '[ "$(yaml_query "$mut" ".name")" = "second" ]' "yaml_load replaces what was cached for that path"

# --- Forget drops --------------------------------------------------------------
printf 'name: third\n' > "$mut"
yaml_forget "$mut"
assert '[ -z "${_KASBAH_YAML_RC[$mut]+set}" ]' "yaml_forget drops the entry"
assert '[ "$(yaml_query "$mut" ".name")" = "third" ]' "so the next query reads the file again"
# Forgetting a path that was never loaded is a no-op, not an error — every
# `--fix` discard path calls it on a candidate that may never have parsed.
yaml_forget "$tmpdir/never-loaded.yml"; rc=$?
assert '[ "$rc" = "0" ]' "forgetting an unknown path is a no-op (rc $rc)"

# --- The diagnostic reaches stderr, every time ---------------------------------
# One conversion, many readers: the parse error is stored and replayed, because
# the rule that happens to ask first is not the only one that deserves it.
yaml_load "$tmpdir/broken.yml" >/dev/null 2>&1
for attempt in 1 2 3; do
    e="$(yaml_query "$tmpdir/broken.yml" '.services' 2>&1 >/dev/null)"
    assert 'grep -q "line 2" <<<"$e"' \
        "failed query $attempt still carries yq's diagnostic (said '$e')"
done
e="$(yaml_query "$tmpdir/broken.yml" '.services' 2>/dev/null; true)"
assert '[ -z "$e" ]' "and nothing goes to stdout on a failed query (said '$e')"
# `2>/dev/null` at the call site silences it, which is what the rules that
# already write it are relying on.
e="$( { yaml_query "$tmpdir/broken.yml" '.services' 2>/dev/null; } 2>&1 >/dev/null )"
assert '[ -z "$e" ]' "a call site's own 2>/dev/null silences the replay (said '$e')"
# Exactly one trailing newline is restored, so the replay is the diagnostic and
# not the diagnostic plus blank lines.
e="$(yaml_query "$tmpdir/broken.yml" '.' 2>&1 >/dev/null | wc -l)"
w="$(yq -r '.' "$tmpdir/broken.yml" 2>&1 >/dev/null | wc -l)"
assert '[ "$e" = "$w" ]' "the replay is the same number of lines yq wrote ($e vs $w)"

exit "$fail"
