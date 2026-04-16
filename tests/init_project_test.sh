#!/usr/bin/env bash
# Test: hosting init-project scaffolds the expected files and refuses to overwrite.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
hosting="$repo_dir/bin/hosting"
version="$(cat "$repo_dir/VERSION")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- Case 1: golden path with flags -------------------------------------------
proj="$tmpdir/demo"
mkdir -p "$proj"
cd "$proj"

"$hosting" init-project --name=demo --domain=demo.example.com >/dev/null

assert '[ -f hosting.yml ]'           "hosting.yml exists"
assert '[ -f .env.prod.example ]'     ".env.prod.example exists"
assert '[ -f .hosting/state.json ]'   ".hosting/state.json exists"
assert '[ -f .gitignore ]'            ".gitignore exists"

assert 'grep -qxF "schema: 1" hosting.yml'                  "manifest has schema: 1"
assert 'grep -qxF "hosting_version: $version" hosting.yml'  "manifest has hosting_version"
assert 'grep -qxF "name: demo" hosting.yml'                 "manifest has name"
assert 'grep -qxF "domain: \"demo.example.com\"" hosting.yml' "manifest has quoted domain"
assert 'grep -qF "compose.prod.yml -> compose.yml" hosting.yml' "manifest has sync"

assert 'grep -qxF "DOMAIN=demo.example.com" .env.prod.example' "env example seeds DOMAIN"

assert '[ "$(jq -r .hosting_version .hosting/state.json)" = "$version" ]' "state hosting_version"
assert '[ "$(jq -r .last_server .hosting/state.json)" = "null" ]'         "state last_server nulled"
assert '[ "$(jq -r ".schema_migrations_applied|length" .hosting/state.json)" = "0" ]' "state migrations empty"

assert 'grep -qxF ".env" .gitignore'      "gitignore has .env"
assert 'grep -qxF ".hosting/" .gitignore' "gitignore has .hosting/"

# --- Case 2: refuses to overwrite existing manifest ---------------------------
if "$hosting" init-project --name=demo >/dev/null 2>&1; then
    echo "  FAIL: second init-project should refuse to overwrite" >&2
    fail=1
fi

# --- Case 3: default name is directory basename -------------------------------
proj2="$tmpdir/mysite"
mkdir -p "$proj2"
cd "$proj2"
"$hosting" init-project --domain=mysite.test >/dev/null
assert 'grep -qxF "name: mysite" hosting.yml' "default name is directory basename"

# --- Case 4: invalid name rejected --------------------------------------------
proj3="$tmpdir/proj3"
mkdir -p "$proj3"
cd "$proj3"
if "$hosting" init-project --name=BadName >/dev/null 2>&1; then
    echo "  FAIL: BadName should be rejected" >&2
    fail=1
fi

# --- Case 5: respects an existing .gitignore ----------------------------------
proj4="$tmpdir/proj4"
mkdir -p "$proj4"
cd "$proj4"
printf 'node_modules\n.env\n' > .gitignore
"$hosting" init-project --name=proj4 >/dev/null
assert '[ "$(grep -cxF .env .gitignore)" = "1" ]' "does not duplicate .env in gitignore"
assert 'grep -qxF node_modules .gitignore'        "preserves existing entries"
assert 'grep -qxF ".hosting/" .gitignore'         "adds .hosting/ to existing gitignore"

# --- Case 6: empty --name= is rejected ----------------------------------------
proj6="$tmpdir/proj6"
mkdir -p "$proj6"
cd "$proj6"
if "$hosting" init-project --name= >/dev/null 2>&1; then
    echo "  FAIL: empty --name= should be rejected" >&2
    fail=1
fi
assert '[ ! -e hosting.yml ]' "rejected run leaves no hosting.yml"

# --- Case 7: invalid --domain= is rejected ------------------------------------
proj7="$tmpdir/proj7"
mkdir -p "$proj7"
cd "$proj7"
if "$hosting" init-project --name=proj7 --domain=not_a_domain >/dev/null 2>&1; then
    echo "  FAIL: invalid --domain should be rejected" >&2
    fail=1
fi
assert '[ ! -e hosting.yml ]' "rejected domain leaves no hosting.yml"

# --- Case 8: pre-existing .hosting/state.json blocks init ---------------------
proj8="$tmpdir/proj8"
mkdir -p "$proj8/.hosting"
cd "$proj8"
printf '{}\n' > .hosting/state.json
if "$hosting" init-project --name=proj8 >/dev/null 2>&1; then
    echo "  FAIL: existing state.json should block init" >&2
    fail=1
fi
assert '[ "$(cat .hosting/state.json)" = "{}" ]' "pre-existing state.json untouched"

# --- Case 9: partial-failure cleanup ------------------------------------------
# Pre-create .hosting as a FILE (not dir). init-project's pre-checks pass, but
# `mkdir .hosting` fails mid-run and must trigger cleanup.
proj9="$tmpdir/proj9"
mkdir -p "$proj9"
cd "$proj9"
printf 'node_modules\ndist\n' > .gitignore
cp .gitignore "$tmpdir/proj9.gitignore.orig"
printf 'not a dir' > .hosting   # block the mkdir later
if "$hosting" init-project --name=proj9 --domain=proj9.test >/dev/null 2>&1; then
    echo "  FAIL: partial-failure case should have errored" >&2
    fail=1
fi
assert '[ ! -f hosting.yml ]'           "cleanup removed hosting.yml"
assert '[ ! -f .env.prod.example ]'     "cleanup removed .env.prod.example"
assert 'cmp -s .gitignore "$tmpdir/proj9.gitignore.orig"' "cleanup restored .gitignore byte-for-byte"
rm -f .hosting

# --- Case 10: regression — --version and --help still work -------------------
cd "$tmpdir"
assert '"$hosting" --version | grep -qF "$version"' "--version prints version"
assert '"$hosting" --help    | grep -qF "init-project"' "--help lists init-project"
assert '"$hosting"            | grep -qF "init-project"' "no-args prints help"

exit "$fail"
