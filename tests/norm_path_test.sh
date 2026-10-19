#!/usr/bin/env bash
# Test: the one path-normalising rule, in the Bash places it is implemented.
#
# `/etc/kasbah/apps-path` is read by one Bash remote step — lib/marker.sh's —
# and a payload on the far side of ssh can source nothing, so it carries its
# own `norm_path`. The other implementation is `kasbah_norm_path` in
# lib/common.sh, which reduces what comes back over the wire on this side.
# One table, driven through both, fails on any divergence between them.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

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

# --- The payload copy -------------------------------------------------------------
# Extracted from its heredoc the way the other suites extract a whole step.
base="$tmpdir/marker.sh.norm"
sed -n '/^norm_path() {/,/^}/p' "$repo_dir/lib/marker.sh" > "$base"
assert '[ -s "$base" ]' "lib/marker.sh carries a norm_path to drive"
assert '[ "$(grep -c "^norm_path() {" "$repo_dir/lib/marker.sh")" = "1" ]' \
    "and exactly one of them, so the extraction is unambiguous"

# --- The table ---------------------------------------------------------------------
# One case list, run through the payload copy and through lib/common.sh's
# function. Anything either of them does differently is a failure here, whether
# or not any command notices today.
#
# The glob case is run from a directory whose entries would match, because that
# is the only way the difference shows: without `set -f`, the `for seg in $p`
# split expands `*` against the *working directory* of whoever is running the
# step — the ssh user's home on the server — so the same pointer normalises to
# a different path on two machines.
globdir="$tmpdir/glob"
mkdir -p "$globdir/aaa/apps" "$globdir/bbb"

runner="$tmpdir/runner.sh"
cat > "$runner" <<'RUN'
#!/usr/bin/env bash
set -uo pipefail
. "$1"                       # the extracted payload copy
. "$KASBAH_LIB_DIR/common.sh"
shift
value="$1"
# Globbing is left exactly as this process found it, and both spellings are
# asked the same question in the same state.
payload="$(norm_path "$value")"
shared=""
kasbah_norm_path shared "$value"
printf 'payload=%s\n' "$payload"
printf 'shared=%s\n' "$shared"
# The caller's own glob state, which neither implementation may leave changed.
case $- in *f*) printf 'glob=off\n' ;; *) printf 'glob=on\n' ;; esac
RUN

check() {
    local desc="$1" value="$2" want="$3" out
    out=$(cd "$globdir" && env KASBAH_LIB_DIR="$repo_dir/lib" \
              bash "$runner" "$base" "$value" 2>&1)
    assert '[ "$(sed -n "s/^payload=//p" <<<"$out")" = "$want" ]' \
        "$desc — the remote copy (wanted '$want', got '$(sed -n "s/^payload=//p" <<<"$out")')"
    assert '[ "$(sed -n "s/^shared=//p" <<<"$out")" = "$want" ]' \
        "$desc — kasbah_norm_path (wanted '$want', got '$(sed -n "s/^shared=//p" <<<"$out")')"
    assert '[ "$(sed -n "s/^glob=//p" <<<"$out")" = "on" ]' \
        "$desc — and globbing is put back the way it was found (got '$(sed -n "s/^glob=//p" <<<"$out")')"
}

check "a plain path is left alone"        "/srv/apps"        "/srv/apps"
check "a trailing slash goes"             "/srv/apps/"       "/srv/apps"
check "several trailing slashes go"       "/srv/apps///"     "/srv/apps"
check "a doubled slash collapses"         "/srv//apps"       "/srv/apps"
check "a leading doubled slash too"       "//srv/apps"       "/srv/apps"
check "a '.' segment is dropped"          "/srv/./apps"      "/srv/apps"
check "a trailing '.' segment too"        "/srv/apps/."      "/srv/apps"
check "every one of them at once"         "//srv/././apps//" "/srv/apps"
check "the root stays the root"           "/"                "/"
check "and so does a root with dots"      "/./"              "/"
# `..` is kept rather than resolved: kasbah's own flags reject a path carrying
# one, so a pointer that spells the tree this way compares unequal and the
# refusal fires — which is the safe direction. Resolving it here would make the
# two spellings compare *equal* and skip the refusal.
check "'..' is kept, never resolved"      "/srv/x/../apps"   "/srv/x/../apps"
check "a trailing '..' as well"           "/srv/apps/.."     "/srv/apps/.."
# A trailing blank is not part of a path. This is the case the payload copy
# strips before anything else, so a header value carrying one never reaches
# kasbah_norm_path from a live run — which is exactly why it is asserted here.
check "a trailing space goes"             "/srv/apps "       "/srv/apps"
check "a trailing tab goes"               "/srv/apps	"      "/srv/apps"
check "several blanks go"                 "/srv/apps 	 "    "/srv/apps"
check "a CR goes — CRLF tolerance"        "$(printf '/srv/apps\r')" "/srv/apps"
check "blanks and a CR together"          "$(printf '/srv/apps \r')" "/srv/apps"
# A path is a path, not a pattern. Run from $globdir, where `aaa` and `bbb`
# would both match, an implementation that lets the shell expand the segment
# answers with a directory listing.
check "a '*' segment is a name, not a glob" "$globdir/*/apps" "$globdir/*/apps"
check "a '?' segment too"                 "/srv/?/apps"      "/srv/?/apps"
check "and a bracket expression"          "/srv/[ab]/apps"   "/srv/[ab]/apps"
# Not absolute: handed back untouched for the caller to refuse, because the
# refusal quotes what the file actually held.
check "a relative path is returned as it stands" "srv/apps"  "srv/apps"
check "a bare dot too"                    "."                "."
check "and the empty string"              ""                 ""
check "a relative path keeps its blanks stripped" "srv/apps "  "srv/apps"

exit "$fail"
