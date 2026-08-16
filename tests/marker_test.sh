#!/usr/bin/env bash
# Test: lib/marker.sh — the server marker, read once per run and shared by
# `hosting deploy` and `hosting env`.
#
# A unit suite: a recording stub `ssh` goes first on PATH and answers as a
# server would, so nothing here opens a socket. What it pins is the whole
# contract of the read — where it looks, what it refuses, what it exits with,
# and the five variables it leaves behind — because two commands now depend on
# all of it and neither of their suites can say which of them is wrong.

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

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir" "$tmpdir/home"
log="$tmpdir/calls.log"

# The marker payload comes from $MARKER, and $MARKER_RC lets a case be the
# "there is no marker" shape (exit 3) rather than a manufactured one.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$STUB_LOG"
last="${!#}"
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in *"-O exit"*) exit 0 ;; esac
case "$last" in true) exit 0 ;; esac
cat >/dev/null
[ "${MARKER_RC:-0}" = 0 ] || exit "$MARKER_RC"
printf '%s' "${MARKER-}"
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

# marker_read driven straight through the library, in a subshell of its own so
# an exit ends the case and not the suite. The five variables come back as one
# line so a whole read compares as one string.
run_marker() {
    : > "$log"
    out=$(env HOME="$tmpdir/home" TMPDIR="$tmpdir" PATH="$stub_dir:$PATH" \
              HOSTING_LIB_DIR="$repo_dir/lib" STUB_LOG="$log" "$@" \
          bash -c '
        set -uo pipefail
        . "$HOSTING_LIB_DIR/marker.sh"
        ssh_connect deploy@vps
        marker_read deploy@vps
        printf "apps=%s data=%s cpu=%s mem=%s\n" \
            "$MARKER_APPS_PATH" "$MARKER_DATA_PATH" "$MARKER_CPU_LIMIT" "$MARKER_MEM_LIMIT"
        printf "json=%s\n" "$MARKER_JSON"
    ' 2>&1)
    rc=$?
}

good='{"hosting_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'

# --- The happy path, and where it looked ----------------------------------------
run_marker MARKER="$good"
assert '[ "$rc" = "0" ]' "a complete marker reads clean (rc $rc: $out)"
assert 'grep -qxF "apps=/apps data=/apps/data cpu=14.4 mem=54g" <<<"$out"' \
    "and every one of the four fields lands in its variable (got '$out')"
assert 'grep -qF "json=$good" <<<"$out"' "with the whole object kept for later readers (got '$out')"
# The path is hosting's default, not the marker's own apps_path: the marker is
# what *tells* a command where the tree is, so looking for it anywhere the
# marker said would be circular.
assert 'grep -qF "|'\''bash'\'' '\''-s'\'' '\''--'\'' '\''/apps'\''" "$log"' \
    "the marker is looked for at the default apps path ($(grep -F "bash" "$log"))"

# A marker naming another tree is followed, not second-guessed — and it is still
# read from /apps.
alt='{"apps_path":"/srv/apps","data_path":"/srv/store","cpu_limit":"1.0","mem_limit":"2g"}'
run_marker MARKER="$alt"
assert '[ "$rc" = "0" ]' "a marker naming another tree reads clean (rc $rc: $out)"
assert 'grep -qxF "apps=/srv/apps data=/srv/store cpu=1.0 mem=2g" <<<"$out"' \
    "and its own paths are what come back (got '$out')"

# --- No marker ------------------------------------------------------------------
run_marker MARKER_RC=3
assert '[ "$rc" = "4" ]' "no marker exits 4 (rc $rc: $out)"
assert 'grep -qF "/apps/.hosting/server.json" <<<"$out"' "naming the file it looked for (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and the flag that makes a prepared server look unprepared (said '$out')"
# The remedy must not be followable into a disaster: a bare
# `hosting server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack under the frozen `traefik` compose project and
# recreates the running proxy against it, taking every site down.
assert '! grep -qE "hosting server init [A-Za-z0-9._-]+@" <<<"$out"' \
    "and never prints a runnable bare \`server init\` (said '$out')"

run_marker MARKER_RC=1
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' \
    "a remote step that failed for some other reason is not read as 'no marker' (rc $rc: $out)"

# --- A marker that is not one ----------------------------------------------------
for bad in '' 'not json' '[1,2]' '"a string"' '17'; do
    run_marker MARKER="$bad"
    assert '[ "$rc" != "0" ]' "a marker holding '$bad' is refused (rc $rc: $out)"
    assert 'grep -qF "not a JSON object" <<<"$out"' "and says what it read (said '$out')"
done

# --- The paths must be absolute --------------------------------------------------
# Every one of these becomes both a remote directory and half of an rsync
# destination. A relative one silently means "under the ssh user's home", which
# is not where anything hosting wrote is.
while read -r apps data desc; do
    [ -n "$apps" ] || continue
    run_marker MARKER="{\"apps_path\":\"$apps\",\"data_path\":\"$data\",\"cpu_limit\":\"1.0\",\"mem_limit\":\"2g\"}"
    assert '[ "$rc" != "0" ]' "$desc is refused (apps='$apps' data='$data', rc $rc: $out)"
    assert 'grep -qF "must be absolute paths" <<<"$out"' "saying why (said '$out')"
    assert 'grep -qF "$apps" <<<"$out" || [ -z "$apps" ]' "and quoting the pair back (said '$out')"
done <<'CASES'
apps /apps/data a relative apps_path
/apps data a relative data_path
. /apps/data a bare dot
/ /apps/data the root alone
CASES

run_marker MARKER='{"data_path":"/apps/data","cpu_limit":"1.0","mem_limit":"2g"}'
assert '[ "$rc" != "0" ]' "an absent apps_path is refused, not defaulted (rc $rc: $out)"
run_marker MARKER='{"apps_path":"/apps","cpu_limit":"1.0","mem_limit":"2g"}'
assert '[ "$rc" != "0" ]' "and so is an absent data_path (rc $rc: $out)"

# --- The two limits --------------------------------------------------------------
# There is no default for somebody else's server, and an empty `cpus:` is a
# compose file that does not parse. Each field is asserted on its own, in both
# shapes, so a check that only ever looked at one of them fails here.
# `|`-delimited, because two of these values are the empty string and one holds
# a space — the very things a whitespace-split reader cannot carry.
while IFS='|' read -r cpu mem desc; do
    [ -n "$desc" ] || continue
    run_marker MARKER="{\"apps_path\":\"/apps\",\"data_path\":\"/apps/data\",\"cpu_limit\":\"$cpu\",\"mem_limit\":\"$mem\"}"
    assert '[ "$rc" = "1" ]' "$desc is refused with 1 (cpu='$cpu' mem='$mem', rc $rc: $out)"
    assert 'grep -qF "cpu_limit" <<<"$out" && grep -qF "mem_limit" <<<"$out"' \
        "naming both fields, since either may be the bad one (said '$out')"
done <<'CASES'
|54g|an empty cpu_limit
14.4||an empty mem_limit
1 4|54g|a cpu_limit with a space
14.4|54 g|a mem_limit with a space
CASES

run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","mem_limit":"54g"}'
assert '[ "$rc" = "1" ]' "an absent cpu_limit is refused (rc $rc: $out)"
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4"}'
assert '[ "$rc" = "1" ]' "and an absent mem_limit (rc $rc: $out)"

# The positive control for all eight refusals above: values hosting has no
# opinion about are written through, because the marker's spelling is the
# contract and reformatting `14.4` to `14.40` is a different cpus:.
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"0","mem_limit":"0"}'
assert '[ "$rc" = "0" ]' "a limit of 0 is not a missing one — it means 'no limit' to Docker (rc $rc: $out)"
assert 'grep -qxF "apps=/apps data=/apps/data cpu=0 mem=0" <<<"$out"' "and comes back as 0 (got '$out')"
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"0.50","mem_limit":"512m"}'
assert 'grep -qxF "apps=/apps data=/apps/data cpu=0.50 mem=512m" <<<"$out"' \
    "and a trailing zero is not normalised away (got '$out')"

# --- Forward compatibility --------------------------------------------------------
# A marker written by a later hosting carries keys this one has never heard of,
# and they are ignored rather than choked on (docs/overview.md → compatibility).
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.0","mem_limit":"2g","future":{"a":[1,2]}}'
assert '[ "$rc" = "0" ]' "a marker with unknown keys still reads (rc $rc: $out)"
assert 'grep -qF "\"future\"" <<<"$out"' "and they survive in MARKER_JSON for a later reader (got '$out')"

exit "$fail"
