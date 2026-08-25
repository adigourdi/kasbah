#!/usr/bin/env bash
# Test: lib/manifest.sh — manifest_require validates + populates globals.

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

# Run a bash snippet in a clean subshell with the module sourced. Prints
# stdout; caller checks exit status with $?.
run_snippet() {
    bash -c '
        set -uo pipefail
        . "$KASBAH_LIB_DIR/manifest.sh"
        '"$1"'
    '
}

# --- Case 1: no manifest -> exit 2 --------------------------------------------
proj1="$tmpdir/empty"
mkdir -p "$proj1"
cd "$proj1"
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "2" ]' "missing manifest exits 2 (got $rc)"
assert 'grep -qF "No kasbah.yml" <<<"$out"' "missing manifest message mentions kasbah.yml"
# Continuation line should not carry a second `error:` prefix.
assert '[ "$(grep -c "^error:" <<<"$out")" = "1" ]' "missing manifest has one error: prefix, not two"

# --- Case 2: valid manifest populates globals ---------------------------------
proj2="$tmpdir/ok"
mkdir -p "$proj2"
cd "$proj2"
cat > kasbah.yml <<EOF
schema: 1
kasbah_version: $KASBAH_VERSION
name: demo
domain: "demo.example.com"
sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
EOF

out="$(run_snippet 'manifest_require; printf "%s\t%s\t%s\t%s\n" "$MANIFEST_SCHEMA" "$MANIFEST_KASBAH_VERSION" "$MANIFEST_NAME" "$MANIFEST_DOMAIN"')"
rc=$?
assert '[ "$rc" = "0" ]' "valid manifest returns 0 (got $rc)"
IFS=$'\t' read -r s hv n d <<<"$out"
assert '[ "$s" = "1" ]'               "MANIFEST_SCHEMA is 1"
assert '[ "$hv" = "$KASBAH_VERSION" ]' "MANIFEST_KASBAH_VERSION matches VERSION"
assert '[ "$n" = "demo" ]'            "MANIFEST_NAME is demo"
assert '[ "$d" = "demo.example.com" ]' "MANIFEST_DOMAIN is parsed (quotes stripped)"

# manifest_get reads arbitrary fields.
sync_first="$(run_snippet 'manifest_require >/dev/null; manifest_get ".sync[0]"')"
assert '[ "$sync_first" = "compose.prod.yml -> compose.yml" ]' "manifest_get returns sync[0]"

# --- Case 3: schema newer than tool -> die ------------------------------------
proj3="$tmpdir/future"
mkdir -p "$proj3"
cd "$proj3"
cat > kasbah.yml <<EOF
schema: 99
kasbah_version: 0.1.0
name: future
domain: "x.test"
sync: []
EOF
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "future schema exits 1 (got $rc)"
assert 'grep -qF "newer than this kasbah" <<<"$out"' "future schema message mentions upgrade"

# --- Case 4: missing schema field ---------------------------------------------
proj4="$tmpdir/noschema"
mkdir -p "$proj4"
cd "$proj4"
cat > kasbah.yml <<EOF
name: noschema
domain: "x.test"
sync: []
EOF
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "missing schema exits 1 (got $rc)"
assert 'grep -qF "missing required field" <<<"$out"' "missing field message"

# --- Case 5: invalid name -----------------------------------------------------
proj5="$tmpdir/badname"
mkdir -p "$proj5"
cd "$proj5"
cat > kasbah.yml <<EOF
schema: 1
kasbah_version: 0.1.0
name: BadName
domain: "x.test"
sync: []
EOF
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "invalid name exits 1 (got $rc)"
assert 'grep -qF "invalid name" <<<"$out"' "invalid name message"

# --- Case 6: malformed YAML ---------------------------------------------------
proj6="$tmpdir/bad"
mkdir -p "$proj6"
cd "$proj6"
printf 'schema: 1\nname: [unterminated\n' > kasbah.yml
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "malformed YAML exits 1 (got $rc)"
assert 'grep -qF "could not parse YAML" <<<"$out"' "malformed YAML message"

# --- Case 7: integration — init-project output passes manifest_require --------
proj7="$tmpdir/integration"
mkdir -p "$proj7"
cd "$proj7"
# Unset KASBAH_LIB_DIR so bin/kasbah auto-detects VERSION via its repo-checkout path.
env -u KASBAH_LIB_DIR "$repo_dir/bin/kasbah" init-project --name=integration --domain=i.example.com >/dev/null
out="$(run_snippet 'manifest_require; echo "$MANIFEST_NAME"')"; rc=$?
assert '[ "$rc" = "0" ]'          "init-project output passes manifest_require"
assert '[ "$out" = "integration" ]' "init-project output parses to name=integration"

# --- Case 8: init-project without --domain still parses -----------------------
# init-project warns but writes `domain: ""`; manifest_require must accept it.
proj8="$tmpdir/nodomain"
mkdir -p "$proj8"
cd "$proj8"
env -u KASBAH_LIB_DIR "$repo_dir/bin/kasbah" init-project --name=nodomain >/dev/null 2>&1
out="$(run_snippet 'manifest_require; printf "%s|%s\n" "$MANIFEST_NAME" "$MANIFEST_DOMAIN"')"; rc=$?
assert '[ "$rc" = "0" ]'             "init-project (no --domain) output passes manifest_require"
assert '[ "$out" = "nodomain|" ]'     "empty domain parses as empty string"

# --- Case 9: quoted schema string is accepted --------------------------------
proj9="$tmpdir/quotedschema"
mkdir -p "$proj9"
cd "$proj9"
cat > kasbah.yml <<EOF
schema: "1"
kasbah_version: 0.1.0
name: quoted
domain: "q.test"
sync: []
EOF
out="$(run_snippet 'manifest_require; echo "$MANIFEST_SCHEMA"')"; rc=$?
assert '[ "$rc" = "0" ]'  "quoted schema \"1\" is accepted"
assert '[ "$out" = "1" ]' "quoted schema parses as 1"

# --- Case 10: multi-document YAML is rejected --------------------------------
proj10="$tmpdir/multidoc"
mkdir -p "$proj10"
cd "$proj10"
cat > kasbah.yml <<EOF
schema: 1
kasbah_version: 0.1.0
name: multi
domain: "m.test"
---
schema: 2
name: other
domain: "o.test"
EOF
out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                                   "multi-document YAML exits 1 (got $rc)"
assert 'grep -qF "single YAML document" <<<"$out"'         "multi-document message"

# --- Case 11a: CRLF-authored manifest parses cleanly --------------------------
proj11a="$tmpdir/crlf"
mkdir -p "$proj11a"
cd "$proj11a"
# Write the manifest with CRLF line endings (Windows-style).
printf 'schema: 1\r\nkasbah_version: 0.1.0\r\nname: crlf\r\ndomain: "c.test"\r\nsync: []\r\n' > kasbah.yml
out="$(run_snippet 'manifest_require; printf "%s|%s\n" "$MANIFEST_NAME" "$MANIFEST_DOMAIN"')"; rc=$?
assert '[ "$rc" = "0" ]'            "CRLF manifest parses successfully"
assert '[ "$out" = "crlf|c.test" ]' "CRLF CR is stripped from field values"

# --- Case 11b: names kasbah owns under <apps>/ -------------------------------
# A project called `traefik` would have deploy write over the shared proxy's
# stack and then remove it with --remove-orphans. Refused here, so every command
# that reads a manifest refuses it — `check` included.
for reserved in traefik mail data backups; do
    projr="$tmpdir/reserved-$reserved"
    mkdir -p "$projr"
    cd "$projr"
    printf 'schema: 1\nkasbah_version: 0.1.0\nname: %s\ndomain: "r.test"\nsync: []\n' "$reserved" > kasbah.yml
    out="$(run_snippet 'manifest_require' 2>&1)"; rc=$?
    assert '[ "$rc" = "1" ]' "manifest_require refuses the reserved name $reserved (got $rc)"
    assert 'grep -qF "is reserved" <<<"$out"' "and says so (said '$out')"
    assert 'grep -qF "traefik mail data backups" <<<"$out"' "listing every reserved name (said '$out')"
done

# The control: a name that merely contains a reserved one is fine, so the rule
# is an exact match rather than a substring.
projok="$tmpdir/reserved-ok"
mkdir -p "$projok"
cd "$projok"
printf 'schema: 1\nkasbah_version: 0.1.0\nname: %s\ndomain: "r.test"\nsync: []\n' traefik-mirror > kasbah.yml
out="$(run_snippet 'manifest_require; printf "%s\n" "$MANIFEST_NAME"' 2>&1)"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "traefik-mirror" ]' \
    "a name containing a reserved one is accepted (rc $rc, got '$out')"

# --- Case 11: manifest_get dies when no manifest ------------------------------
proj11="$tmpdir/noyml"
mkdir -p "$proj11"
cd "$proj11"
out="$(run_snippet 'manifest_get ".name"' 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                       "manifest_get dies when no manifest (got $rc)"
assert 'grep -qF "not found" <<<"$out"'        "manifest_get error mentions not found"

exit "$fail"
