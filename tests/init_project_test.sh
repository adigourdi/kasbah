#!/usr/bin/env bash
# Test: kasbah init-project scaffolds the expected files and refuses to overwrite.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"
version="$(kasbah_base_version)"

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

"$kasbah" init-project --name=demo --domain=demo.example.com >/dev/null

assert '[ -f kasbah.yml ]'           "kasbah.yml exists"
assert '[ -f .env.prod.example ]'     ".env.prod.example exists"
assert '[ -f .kasbah/state.json ]'   ".kasbah/state.json exists"
assert '[ -f .gitignore ]'            ".gitignore exists"

assert 'grep -qxF "schema: 1" kasbah.yml'                  "manifest has schema: 1"
assert 'grep -qxF "kasbah_version: $version" kasbah.yml'  "manifest has kasbah_version"
assert 'grep -qxF "name: demo" kasbah.yml'                 "manifest has name"
assert 'grep -qxF "domain: \"demo.example.com\"" kasbah.yml' "manifest has quoted domain"
assert 'grep -qF "compose.prod.yml -> compose.yml" kasbah.yml' "manifest has sync"

# The template is mandatory and declares nothing: the hostname is load-bearing
# in the manifest's domain: and in traefik-dynamic.yml, and seeding a key here
# would hand a project an environment it never asked for — and a first deploy
# that has to prompt for it. Comments only, which check's E01/E04/E05 all pass.
assert '! grep -qE "^[[:space:]]*[^#[:space:]]" .env.prod.example' \
    "env example declares no key (said: $(cat .env.prod.example))"
assert '[ -s .env.prod.example ]' "but is a real file with something in it"
assert '! grep -qF "DOMAIN" .env.prod.example' "and does not seed a DOMAIN nothing reads"

assert '[ "$(jq -r .kasbah_version .kasbah/state.json)" = "$version" ]' "state kasbah_version"
assert '[ "$(jq -r .last_server .kasbah/state.json)" = "null" ]'         "state last_server nulled"
assert '[ "$(jq -r ".schema_migrations_applied|length" .kasbah/state.json)" = "0" ]' "state migrations empty"

assert 'grep -qxF ".env" .gitignore'      "gitignore has .env"
assert 'grep -qxF ".kasbah/" .gitignore' "gitignore has .kasbah/"

# --- Case 1b: the starter snippet is a project `kasbah check` accepts ---------
# It is the first compose file most projects ever have, so what it teaches is
# what most compose files end up looking like. One routed service: named for
# the project, on the project's own kasbah network and nothing else because a
# lone routed service has nothing to keep off it, and behind both routers for
# the domain so plain HTTP redirects instead of 404ing (T08).
projs="$tmpdir/snippet"
mkdir -p "$projs"
cd "$projs"
snippet="$("$kasbah" init-project --name=snip --domain=snip.example.com 2>/dev/null)"
assert 'grep -qF "    snip-web:" <<<"$snippet"'            "the scaffolded service is named for the project (said '$snippet')"
assert '! grep -qE "^    (app|web):" <<<"$snippet"'        "and not with a name every other project would also pick"
assert 'grep -qF "networks: [kasbah]" <<<"$snippet"'       "the one routed service joins the project's kasbah network alone"
assert 'grep -qF "    kasbah: {}" <<<"$snippet"'            "which is the project's own, not external"
assert '! grep -qF "kasbah-net" <<<"$snippet"'              "and the shared kasbah-net is not offered"
assert '! grep -qF "internal: {}" <<<"$snippet"'           "with no second network it has nothing to put on"
assert 'grep -qF "entryPoints: [web]" <<<"$snippet"'       "the fragment carries the redirect router"
assert 'grep -qF "entryPoints: [websecure]" <<<"$snippet"' "and the TLS one"

# --- Case 1c: what it printed is a project `kasbah check` passes clean -------
# `cli.md` claims both snippets pass; grepping six strings out of them cannot
# tell whether the whole is coherent, and a claim in a doc that nothing runs is
# the shape that rots. So do what the operator is told to do: paste both blocks
# into the files they name, and run the check.
#
# The two blocks are indented two spaces inside the prose. Take everything from
# the block's opening key until the first line that is neither blank nor
# indented — and, for the compose block, until the prose paragraph that follows
# it, whose first line is the only one in either block starting with a capital
# at that indent. The two guards below fail loudly if that ever stops holding,
# rather than quietly checking an empty file.
extract() {
    awk -v start="$1" -v stop_prose="$2" '
        $0 == start { f = 1 }
        f {
            if ($0 !~ /^($|  )/) exit
            if (stop_prose == "1" && $0 ~ /^  [A-Z]/) exit
            print
        }
    ' <<<"$snippet" | sed 's/^  //'
}
extract "  services:" 1 > compose.prod.yml
extract "  http:"     0 > traefik-dynamic.yml
assert 'grep -qxF "    networks: [kasbah]" compose.prod.yml && ! grep -qF container_name compose.prod.yml' \
    "the compose block came out whole, with no container_name: the fragment targets the service (got: $(cat compose.prod.yml))"
assert 'grep -qxF "          - url: \"http://snip-web:80\"" traefik-dynamic.yml' \
    "and so did the fragment (got: $(cat traefik-dynamic.yml))"

check_out="$("$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "the scaffolded project passes kasbah check (exit $rc)"
assert 'grep -qF ", 0 warning, 0 failed" <<<"$check_out"' \
    "with nothing warned and nothing failed (said '$(tail -1 <<<"$check_out")')"
assert 'grep -qF "✓ All routed services join the project'"'"'s kasbah network" <<<"$check_out"' \
    "C03 among them, on the new shape"
assert 'grep -qF "✓ The kasbah network is the project'"'"'s own (snip_kasbah)" <<<"$check_out"' \
    "and C04 names the network deploy connects Traefik to"
assert 'grep -qF "✓ A router serves snip.example.com on the web entrypoint" <<<"$check_out"' \
    "and T08, which is why the fragment prints two routers"

# --- Case 2: refuses to overwrite existing manifest ---------------------------
if "$kasbah" init-project --name=demo >/dev/null 2>&1; then
    echo "  FAIL: second init-project should refuse to overwrite" >&2
    fail=1
fi

# --- Case 3: default name is directory basename -------------------------------
proj2="$tmpdir/mysite"
mkdir -p "$proj2"
cd "$proj2"
"$kasbah" init-project --domain=mysite.test >/dev/null
assert 'grep -qxF "name: mysite" kasbah.yml' "default name is directory basename"

# --- Case 4: invalid name rejected --------------------------------------------
proj3="$tmpdir/proj3"
mkdir -p "$proj3"
cd "$proj3"
if "$kasbah" init-project --name=BadName >/dev/null 2>&1; then
    echo "  FAIL: BadName should be rejected" >&2
    fail=1
fi

# --- Case 4b: the names kasbah owns on a server are refused ------------------
# `traefik` is the one with teeth: deploy would sync the project over the
# shared proxy's own stack and then `compose -p traefik up -d --remove-orphans`
# in that directory, removing the proxy. Refused at the moment the name is
# chosen, and again wherever a manifest is read (tests/manifest_test.sh).
for reserved in traefik mail data backups; do
    projr="$tmpdir/reserved-$reserved"
    mkdir -p "$projr"
    cd "$projr"
    out="$("$kasbah" init-project --name="$reserved" 2>&1)"; rc=$?
    assert '[ "$rc" != "0" ]' "init-project --name=$reserved is refused (rc $rc)"
    assert 'grep -qF "reserved" <<<"$out"' "and says why (said '$out')"
    assert '[ ! -f kasbah.yml ]' "and scaffolds nothing for $reserved"
done

# The default name is the directory's, so the refusal has to fire there too —
# `kasbah init-project` inside a directory called data is the likelier way in.
projd="$tmpdir/data"
mkdir -p "$projd"
cd "$projd"
out="$("$kasbah" init-project 2>&1)"; rc=$?
assert '[ "$rc" != "0" ]' "init-project in a directory called data is refused (rc $rc)"
assert 'grep -qF "reserved" <<<"$out"' "naming the rule (said '$out')"
assert '[ ! -f kasbah.yml ]' "and scaffolds nothing"

# --- Case 5: respects an existing .gitignore ----------------------------------
proj4="$tmpdir/proj4"
mkdir -p "$proj4"
cd "$proj4"
printf 'node_modules\n.env\n' > .gitignore
"$kasbah" init-project --name=proj4 >/dev/null
assert '[ "$(grep -cxF .env .gitignore)" = "1" ]' "does not duplicate .env in gitignore"
assert 'grep -qxF node_modules .gitignore'        "preserves existing entries"
assert 'grep -qxF ".kasbah/" .gitignore'         "adds .kasbah/ to existing gitignore"

# --- Case 6: empty --name= is rejected ----------------------------------------
proj6="$tmpdir/proj6"
mkdir -p "$proj6"
cd "$proj6"
if "$kasbah" init-project --name= >/dev/null 2>&1; then
    echo "  FAIL: empty --name= should be rejected" >&2
    fail=1
fi
assert '[ ! -e kasbah.yml ]' "rejected run leaves no kasbah.yml"

# --- Case 7: invalid --domain= is rejected ------------------------------------
proj7="$tmpdir/proj7"
mkdir -p "$proj7"
cd "$proj7"
if "$kasbah" init-project --name=proj7 --domain=not_a_domain >/dev/null 2>&1; then
    echo "  FAIL: invalid --domain should be rejected" >&2
    fail=1
fi
assert '[ ! -e kasbah.yml ]' "rejected domain leaves no kasbah.yml"

# --- Case 8: pre-existing .kasbah/state.json blocks init ---------------------
proj8="$tmpdir/proj8"
mkdir -p "$proj8/.kasbah"
cd "$proj8"
printf '{}\n' > .kasbah/state.json
if "$kasbah" init-project --name=proj8 >/dev/null 2>&1; then
    echo "  FAIL: existing state.json should block init" >&2
    fail=1
fi
assert '[ "$(cat .kasbah/state.json)" = "{}" ]' "pre-existing state.json untouched"

# --- Case 9: partial-failure cleanup ------------------------------------------
# Pre-create .kasbah as a FILE (not dir). init-project's pre-checks pass, but
# `mkdir .kasbah` fails mid-run and must trigger cleanup.
proj9="$tmpdir/proj9"
mkdir -p "$proj9"
cd "$proj9"
printf 'node_modules\ndist\n' > .gitignore
cp .gitignore "$tmpdir/proj9.gitignore.orig"
printf 'not a dir' > .kasbah   # block the mkdir later
if "$kasbah" init-project --name=proj9 --domain=proj9.test >/dev/null 2>&1; then
    echo "  FAIL: partial-failure case should have errored" >&2
    fail=1
fi
assert '[ ! -f kasbah.yml ]'           "cleanup removed kasbah.yml"
assert '[ ! -f .env.prod.example ]'     "cleanup removed .env.prod.example"
assert 'cmp -s .gitignore "$tmpdir/proj9.gitignore.orig"' "cleanup restored .gitignore byte-for-byte"
rm -f .kasbah

# --- Case 10: regression — --version and --help still work -------------------
cd "$tmpdir"
out="$("$kasbah" --version)"
assert '[ "$out" = "kasbah $(kasbah_bin_version) (schema 1)" ] && [[ "$out" == "kasbah $version"* ]]' \
    "--version prints the build and the schema (got '$out')"
assert '"$kasbah" --help    | grep -qF "init-project"' "--help lists init-project"
assert '"$kasbah"            | grep -qF "init-project"' "no-args prints help"
out="$("$kasbah" init-project --help)"; rc=$?
assert '[ "$rc" = "0" ] && grep -qF "Usage: kasbah init-project [--name=<name>] [--domain=<fqdn>]" <<<"$out"' \
    "init-project --help prints its usage (exit $rc)"

# --- Case 11: what init-project writes, the manifest reader accepts ------------
# With and without --domain: check's first rule is the manifest's own validation.
for args in "--name=integration --domain=i.example.com" "--name=nodomain"; do
    p="$tmpdir/accept-${args%% *}"; p="${p//[=-]/}"
    mkdir -p "$p"
    # shellcheck disable=SC2086
    (cd "$p" && "$kasbah" init-project $args >/dev/null 2>&1)
    out="$(cd "$p" && "$kasbah" check 2>&1)"
    assert 'grep -qF "kasbah.yml exists (schema 1)" <<<"$out"' \
        "init-project $args writes a manifest the reader accepts (got: $(head -5 <<<"$out"))"
done

exit "$fail"
