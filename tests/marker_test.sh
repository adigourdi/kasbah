#!/usr/bin/env bash
# Test: lib/marker.sh — the server marker, read once per run and shared by
# `kasbah deploy` and `kasbah env`.
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

# The far side, spoken as the protocol rather than as a marker: the step reports
# where it looked and how it got there before it reports anything else, so a
# case can be any of the states discovery has to tell apart.
#
#   $POINTER    the path the pointer names; unset means there is no pointer
#   $MARKER     the marker's bytes
#   $MARKER_RC  3 no marker where it looked, 5 a pointer naming nothing
#               absolute, 6 one nothing here can read, 7 a directory this user
#               cannot enter, anything else a transport failure
#   $NO_HEADER  the step answers without saying where it looked — a truncated
#               remote step, or a login shell exiting on its own account, which
#               must not read as any of the states above
#   $HDR_APPS / $HDR_SOURCE
#               either header line's *value* on its own, including one the
#               protocol does not have. The two are independent because a step
#               that reports one of them wrongly is not a step whose other half
#               can be trusted, and each check has to fail on its own.
#   $RAW_HEADER the two lines replaced verbatim, which is the only way to say
#               "the step answered something that is not this protocol at all" —
#               a login shell's own output, or a report whose keys are gone.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$STUB_LOG"
last="${!#}"
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in *"-O exit"*) exit 0 ;; esac
case "$last" in true) exit 0 ;; esac
cat >/dev/null
if [ -z "${NO_HEADER:-}" ]; then
    if [ -n "${POINTER+set}" ]; then
        hdr_apps="$POINTER"; hdr_source=pointer
    else
        hdr_apps=/apps; hdr_source=default
    fi
    if [ -n "${RAW_HEADER+set}" ]; then
        printf '%s\n' "$RAW_HEADER"
    else
        printf 'apps=%s\n' "${HDR_APPS-$hdr_apps}"
        printf 'source=%s\n' "${HDR_SOURCE-$hdr_source}"
    fi
fi
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
              KASBAH_LIB_DIR="$repo_dir/lib" STUB_LOG="$log" "$@" \
          bash -c '
        set -uo pipefail
        . "$KASBAH_LIB_DIR/marker.sh"
        ssh_connect deploy@vps
        marker_read deploy@vps
        printf "apps=%s data=%s cpu=%s mem=%s\n" \
            "$MARKER_APPS_PATH" "$MARKER_DATA_PATH" "$MARKER_CPU_LIMIT" "$MARKER_MEM_LIMIT"
        printf "path=%s source=%s\n" "$MARKER_PATH" "$MARKER_SOURCE"
        printf "json=%s\n" "$MARKER_JSON"
    ' 2>&1)
    rc=$?
}

good='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'
alt='{"apps_path":"/srv/apps","data_path":"/srv/store","cpu_limit":"1.0","mem_limit":"2g"}'

# --- The happy path, and where it looked ----------------------------------------
run_marker MARKER="$good"
assert '[ "$rc" = "0" ]' "a complete marker reads clean (rc $rc: $out)"
assert 'grep -qxF "apps=/apps data=/apps/data cpu=14.4 mem=54g" <<<"$out"' \
    "and every one of the four fields lands in its variable (got '$out')"
assert 'grep -qF "json=$good" <<<"$out"' "with the whole object kept for later readers (got '$out')"
# The path is kasbah's default, not the marker's own apps_path: the marker is
# what *tells* a command where the tree is, so looking for it anywhere the
# marker said would be circular.
assert 'grep -qF "|'\''bash'\'' '\''-s'\'' '\''--'\'' '\''/apps'\'' '\''/etc/kasbah/apps-path'\''" "$log"' \
    "the step is given both the default apps path and the pointer ($(grep -F "bash" "$log"))"
assert 'grep -qxF "path=/apps/.kasbah/server.json source=default" <<<"$out"' \
    "and with no pointer the marker is the default tree's (got '$out')"

# A marker naming another tree is followed, not second-guessed.
run_marker MARKER="$alt"
assert '[ "$rc" = "0" ]' "a marker naming another tree reads clean (rc $rc: $out)"
assert 'grep -qxF "apps=/srv/apps data=/srv/store cpu=1.0 mem=2g" <<<"$out"' \
    "and its own paths are what come back (got '$out')"

# --- The pointer ------------------------------------------------------------------
# The whole point of the file: a server prepared at /srv/apps is found without
# anybody telling this command so.
run_marker POINTER=/srv/apps MARKER="$alt"
assert '[ "$rc" = "0" ]' "a pointer names the tree the marker is read from (rc $rc: $out)"
assert 'grep -qxF "path=/srv/apps/.kasbah/server.json source=pointer" <<<"$out"' \
    "and that is where the marker was read (got '$out')"
assert 'grep -qxF "apps=/srv/apps data=/srv/store cpu=1.0 mem=2g" <<<"$out"' \
    "with the marker's own paths coming back (got '$out')"

# A pointer naming a tree with no marker in it. Falling back to /apps here would
# read a *different* server's marker and deploy against it, so kasbah does not —
# and says so. The code is 4, the same one every "no marker where the apps path
# says one should be" carries (docs/cli.md → exit codes): it is one server
# state, and `kasbah server status` reaches it through _ss_no_marker and answers
# 4 as well. What is particular to this case is the message, not the number.
run_marker POINTER=/srv/apps MARKER_RC=3
assert '[ "$rc" = "4" ]' \
    "a pointer naming a tree with no marker exits 4, like every other missing marker (rc $rc: $out)"
assert 'grep -qF "/srv/apps/.kasbah/server.json" <<<"$out"' \
    "naming the marker it looked for (said '$out')"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' "and the pointer that sent it there (said '$out')"
assert 'grep -qF "does not fall back" <<<"$out"' \
    "and saying it refused to read the default tree instead — which is what separates
        this from the two situations exit 4 usually means (said '$out')"
assert '! grep -qF "no server marker at /apps/" <<<"$out"' \
    "and it did not quietly look under /apps instead (said '$out')"

# A pointer naming the default is the one case where "no marker there" is not a
# refusal: the fallback would have read the same file, so there is nothing it
# could have been hiding. This is a server that looks unprepared.
run_marker POINTER=/apps MARKER_RC=3
assert '[ "$rc" = "4" ]' \
    "a pointer naming /apps with no marker is the unprepared server, not a conflict (rc $rc: $out)"
assert '! grep -qF "does not fall back" <<<"$out"' \
    "and the message does not claim it refused to look at /apps — /apps is where it looked (said '$out')"

# A pointer the deploy user cannot read. Reading /apps instead would be a guess
# about which server this is, so it is refused.
run_marker POINTER= MARKER_RC=6
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' "an unreadable pointer is refused (rc $rc: $out)"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' "naming the file (said '$out')"
assert 'grep -qF "chmod 644" <<<"$out"' "and how to make it readable (said '$out')"

# A pointer that names nothing usable: the remote step exits 5 having reported
# the content, so the refusal can quote it back.
run_marker POINTER=srv/apps MARKER_RC=5
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' "a relative pointer is refused (rc $rc: $out)"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' "naming the file (said '$out')"
assert 'grep -qF "srv/apps" <<<"$out"' "and quoting what it holds (said '$out')"

# A step that answers without saying where it looked is a truncated step, not a
# server in any of the states above.
run_marker NO_HEADER=1 MARKER_RC=3
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' \
    "a step that reports no apps path is a failure, not 'no marker' (rc $rc: $out)"
run_marker NO_HEADER=1 MARKER="$good"
assert '[ "$rc" != "0" ]' "and not a marker either, however well-formed (rc $rc: $out)"

# The status codes this protocol uses are also status codes a remote login shell
# can exit with on its own account — a `.bashrc` that ends in `exit 5` is not a
# pointer holding a relative path. The header is the only thing that tells them
# apart, which is why it is checked before the code is read.
for _rc in 5 6 7 3; do
    run_marker NO_HEADER=1 MARKER_RC=$_rc
    assert '[ "$rc" != "0" ]' "a headerless exit $_rc is a failure (rc $rc: $out)"
    assert 'grep -qF "did not report where it looked" <<<"$out"' \
        "diagnosed as a step that reported nothing, not as a pointer refusal (said '$out')"
done

# Each header on its own. A step that names a path but not how it got there, or
# the reverse, is a step whose answer cannot be acted on — and each of the two
# checks has to be the one that catches its own case.
run_marker HDR_SOURCE=elsewhere MARKER="$good"
assert '[ "$rc" != "0" ]' "a source this protocol does not have is refused (rc $rc: $out)"
assert 'grep -qF "did not report where it looked" <<<"$out"' "as a bad report (said '$out')"
# A first line that is a path but not a report. `${line#apps=}` leaves a value
# that looks perfectly usable, which is exactly why the key has to be checked
# rather than stripped: a step that stopped reporting where it looked would
# otherwise be read as one that looked in /apps.
run_marker RAW_HEADER="$(printf '/apps\nsource=default')" MARKER="$good"
assert '[ "$rc" != "0" ]' "a first line with no apps= key is refused (rc $rc: $out)"
assert 'grep -qF "did not report where it looked" <<<"$out"' "as a bad report (said '$out')"
run_marker RAW_HEADER="$(printf 'apps=/apps\ndefault')" MARKER="$good"
assert '[ "$rc" != "0" ]' "and a second line with no source= key (rc $rc: $out)"

run_marker HDR_APPS="not a header" MARKER="$good"
assert '[ "$rc" != "0" ]' "and so is a first line that is not the apps path (rc $rc: $out)"
assert 'grep -qF "did not report where it looked" <<<"$out"' "as a bad report (said '$out')"

# A pointer nothing here can enter: `[ -e ]` cannot tell that from "there is no
# pointer", and only one of the two makes /apps the right tree.
run_marker POINTER= MARKER_RC=7
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' \
    "a pointer directory this user cannot enter is refused (rc $rc: $out)"
assert 'grep -qF "/etc/kasbah" <<<"$out"' "naming the directory (said '$out')"
assert 'grep -qF "chmod 755" <<<"$out"' "and how to open it (said '$out')"

# Every spelling of the default tree is the default tree. The remote normalises
# what it reads, and so does this side: a pointer saying `/apps/` is not a
# second server, and the carve-out above must recognise it as the ordinary
# unprepared one rather than refuse with a message about not falling back to the
# very path it is looking at.
for _spelling in /apps/ //apps /apps/. /apps//; do
    run_marker POINTER="$_spelling" MARKER_RC=3
    assert '[ "$rc" = "4" ]' \
        "a pointer spelled '$_spelling' is still the default tree (rc $rc: $out)"
    assert '! grep -qF "does not fall back" <<<"$out"' \
        "and is not refused as another server (said '$out')"
    run_marker POINTER="$_spelling" MARKER="$good"
    assert 'grep -qxF "path=/apps/.kasbah/server.json source=pointer" <<<"$out"' \
        "and the marker path it prints carries no doubled or trailing slash (got '$out')"
done

# --- No marker, and no pointer -----------------------------------------------------
run_marker MARKER_RC=3
assert '[ "$rc" = "4" ]' "no marker and no pointer exits 4 (rc $rc: $out)"
assert 'grep -qF "/apps/.kasbah/server.json" <<<"$out"' "naming the file it looked for (said '$out')"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' \
    "and the pointer that would have said otherwise (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and the flag that restores it (said '$out')"
# The two situations that are left, now that a prepared server carries a
# pointer: never prepared, or prepared with the pointer lost.
assert 'grep -qF "never been prepared" <<<"$out"' "saying which two they are (said '$out')"
assert '! grep -qF "not wired up yet" <<<"$out"' \
    "and not that deploying elsewhere is unimplemented — it is what the pointer does (said '$out')"
# The remedy must not be followable into a disaster: a bare
# `kasbah server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack under the frozen `traefik` compose project and
# recreates the running proxy against it, taking every site down.
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" <<<"$out"' \
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

# The remedy a malformed marker prints has to be runnable against *this* server.
# On one the pointer led to, a bare `kasbah server init deploy@vps` prepares a
# second server under /apps and recreates the running proxy against it, so the
# apps path has to be in the command.
run_marker POINTER=/srv/apps MARKER='not json'
assert '[ "$rc" != "0" ]' "a malformed marker on a pointed-at server is refused (rc $rc: $out)"
assert 'grep -qF "/srv/apps/.kasbah/server.json on deploy@vps is not a JSON object" <<<"$out"' \
    "naming the file it read (said '$out')"
assert 'grep -qF -- "kasbah server init deploy@vps --apps-path=/srv/apps" <<<"$out"' \
    "and the remedy carries the apps path, so it repairs this server (said '$out')"
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@[A-Za-z0-9._-]+(\`|$| [^-])" <<<"$out"' \
    "and never the bare form, which would prepare a second one (said '$out')"
run_marker POINTER=/srv/apps MARKER='{"apps_path":"/srv/apps","data_path":"/srv/store","cpu_limit":"","mem_limit":"2g"}'
assert '[ "$rc" = "1" ]' "a marker missing a limit is refused there too (rc $rc: $out)"
assert 'grep -qF -- "--apps-path=/srv/apps" <<<"$out"' \
    "with the same repairable remedy (said '$out')"
# The control: with no pointer the bare form *is* the right command, and the
# assertion above must not be passing merely because nothing prints one.
run_marker MARKER='not json'
assert 'grep -qF "kasbah server init deploy@vps" <<<"$out"' \
    "on a default-path server the remedy is the plain init (said '$out')"
assert '! grep -qF -- "--apps-path" <<<"$out"' "with no flag to guess (said '$out')"

# --- The paths must be absolute --------------------------------------------------
# Every one of these becomes both a remote directory and half of an rsync
# destination. A relative one silently means "under the ssh user's home", which
# is not where anything kasbah wrote is.
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

# The positive control for all eight refusals above: values kasbah has no
# opinion about are written through, because the marker's spelling is the
# contract and reformatting `14.4` to `14.40` is a different cpus:.
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"0","mem_limit":"0"}'
assert '[ "$rc" = "0" ]' "a limit of 0 is not a missing one — it means 'no limit' to Docker (rc $rc: $out)"
assert 'grep -qxF "apps=/apps data=/apps/data cpu=0 mem=0" <<<"$out"' "and comes back as 0 (got '$out')"
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"0.50","mem_limit":"512m"}'
assert 'grep -qxF "apps=/apps data=/apps/data cpu=0.50 mem=512m" <<<"$out"' \
    "and a trailing zero is not normalised away (got '$out')"

# --- Forward compatibility --------------------------------------------------------
# A marker written by a later kasbah carries keys this one has never heard of,
# and they are ignored rather than choked on (docs/overview.md → compatibility).
run_marker MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.0","mem_limit":"2g","future":{"a":[1,2]}}'
assert '[ "$rc" = "0" ]' "a marker with unknown keys still reads (rc $rc: $out)"
assert 'grep -qF "\"future\"" <<<"$out"' "and they survive in MARKER_JSON for a later reader (got '$out')"

# --- The remote script, run locally --------------------------------------------------
# Extracted from its heredoc and run against fake trees, which is the only way
# to reach the discovery itself rather than a stub's imitation of it: what the
# pointer is read as, which tree the marker is then taken from, and the four
# states this file exists to tell apart. Every path it is given is an argument,
# so nothing here touches a real /apps or /etc.
payload="$tmpdir/remote.sh"
sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$repo_dir/lib/marker.sh" | sed '1d;$d' > "$payload"
assert '[ -s "$payload" ]' "the remote script was extracted from lib/marker.sh"
assert 'grep -qF "source=pointer" "$payload"' \
    "and it is the discovery block — every case below is empty theatre otherwise"

root="$tmpdir/fake"
mkdir -p "$root/apps/.kasbah" "$root/srv/apps/.kasbah" "$root/srv/empty" "$root/etc"
printf '%s\n' "$good" > "$root/apps/.kasbah/server.json"
printf '%s\n' "$alt" > "$root/srv/apps/.kasbah/server.json"
pointer="$root/etc/apps-path"

# run_payload — the step as marker_read invokes it: default apps path, pointer
# path. Leaves the raw output in $p_out and the status in $p_rc.
p_out=""; p_rc=0
run_payload() {
    p_rc=0
    p_out="$(bash "$payload" "$root/apps" "$pointer" 2>"$tmpdir/perr")" || p_rc=$?
}
p_line() { sed -n "s/^$1=//p" <<<"$p_out"; }
p_body() { tail -n +3 <<<"$p_out"; }

# No pointer: the default tree, exactly as before the pointer existed.
rm -f "$pointer"
run_payload
assert '[ "$p_rc" = "0" ]' "with no pointer the default tree is read (rc $p_rc: $(cat "$tmpdir/perr"))"
assert '[ "$(p_line apps)" = "$root/apps" ]' "reporting where it looked (got '$(p_line apps)')"
assert '[ "$(p_line source)" = "default" ]' "and that nothing told it to (got '$(p_line source)')"
assert '[ "$(p_body)" = "$good" ]' "with the marker's bytes after the two header lines (got '$(p_body)')"

# A pointer naming a second tree, which has a marker of its own.
printf '%s\n' "$root/srv/apps" > "$pointer"
run_payload
assert '[ "$p_rc" = "0" ]' "a pointer is followed (rc $p_rc: $(cat "$tmpdir/perr"))"
assert '[ "$(p_line apps)" = "$root/srv/apps" ]' "to the tree it names (got '$(p_line apps)')"
assert '[ "$(p_line source)" = "pointer" ]' "and says so (got '$(p_line source)')"
assert '[ "$(p_body)" = "$alt" ]' "the marker read is that tree's, not the default one's (got '$(p_body)')"

# The trap the pointer exists to catch, from the far side: a tree with no marker
# in it is exit 3 *with* source=pointer, so the caller can refuse rather than
# fall back to a different server.
printf '%s\n' "$root/srv/empty" > "$pointer"
run_payload
assert '[ "$p_rc" = "3" ]' "a pointer naming a tree with no marker is 'no marker' (rc $p_rc)"
assert '[ "$(p_line apps)" = "$root/srv/empty" ]' "reported against that tree (got '$(p_line apps)')"
assert '[ "$(p_line source)" = "pointer" ]' "and not as the default (got '$(p_line source)')"
assert '! grep -qF "$root/apps/.kasbah" <<<"$p_out"' \
    "the default tree was not read behind its back (got '$p_out')"

# A file a human edited: CRLF and trailing blanks are taken off, because
# "/srv/apps " is a directory nothing on the server can find.
printf '%s  \r\n' "$root/srv/apps" > "$pointer"
run_payload
assert '[ "$p_rc" = "0" ]' "a pointer written on Windows still resolves (rc $p_rc: $(cat "$tmpdir/perr"))"
assert '[ "$(p_line apps)" = "$root/srv/apps" ]' "with the CR and the blanks gone (got '$(p_line apps)')"

# Only the first line is the path: a second line is not a second server.
printf '%s\n/elsewhere\n' "$root/srv/apps" > "$pointer"
run_payload
assert '[ "$(p_line apps)" = "$root/srv/apps" ]' "only the first line is read (got '$(p_line apps)')"

# Nothing usable in it: exit 5, and the content is reported first so the refusal
# can quote it.
while IFS= read -r bad; do
    printf '%s\n' "$bad" > "$pointer"
    run_payload
    assert '[ "$p_rc" = "5" ]' "a pointer holding '$bad' is refused (rc $p_rc)"
    assert '[ "$(p_line source)" = "pointer" ]' "as a pointer, not as a default (got '$(p_line source)')"
    assert '[ "$(p_line apps)" = "$bad" ]' "quoting what it holds (got '$(p_line apps)')"
done <<CASES
srv/apps
.
CASES
: > "$pointer"
run_payload
assert '[ "$p_rc" = "5" ]' "an empty pointer is refused (rc $p_rc)"
# `/` alone would make the marker path //.kasbah/server.json — a pointer nobody
# wrote and a tree nobody prepared.
printf '/\n' > "$pointer"
run_payload
assert '[ "$p_rc" = "5" ]' "the filesystem root is not an apps path (rc $p_rc)"

# A pointer nobody but root can read is exit 6, not an empty one: an empty read
# would look exactly like a pointer holding nothing, and the answers differ.
printf '%s\n' "$root/srv/apps" > "$pointer"
chmod 000 "$pointer"
if [ ! -r "$pointer" ]; then
    run_payload
    assert '[ "$p_rc" = "6" ]' "an unreadable pointer is its own answer (rc $p_rc)"
    assert '[ "$(p_line source)" = "pointer" ]' "reported as a pointer (got '$(p_line source)')"
    assert '! grep -qF "$good" <<<"$p_out"' "and no marker was read (got '$p_out')"
else
    # Running as root, where every file is readable: the case cannot be built.
    assert 'true' "skipped: this user can read a mode-000 file"
fi
chmod 644 "$pointer"

# Every spelling of one tree is one tree: the value is normalised where it is
# read, so `//`, a trailing slash and a `.` segment never reach a comparison or
# a marker path.
while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    printf '%s\n' "$root$spelling" > "$pointer"
    run_payload
    assert '[ "$p_rc" = "0" ]' "a pointer spelled '$spelling' resolves (rc $p_rc: $(cat "$tmpdir/perr"))"
    assert '[ "$(p_line apps)" = "$root/srv/apps" ]' \
        "to the one path that names that tree (got '$(p_line apps)')"
    assert '[ "$(p_body)" = "$alt" ]' "and reads its marker (got '$(p_body)')"
done <<'CASES'
/srv/apps/
//srv/apps
/srv/./apps
/srv/apps/.
/srv//apps//
CASES
# A tab is not a space: `kv`-style trimming would leave this one behind, and a
# path ending in a tab is a directory nothing on the server can find.
printf '%s\t\n' "$root/srv/apps" > "$pointer"
run_payload
assert '[ "$(p_line apps)" = "$root/srv/apps" ]' \
    "a trailing tab is taken off as well as a space (got '$(p_line apps)')"

# A pointer behind a directory this user cannot enter. `[ -e ]` says "no" for
# it exactly as it does for a pointer that is not there, and the second means
# "read /apps" while the first may mean "read somebody else's server".
printf '%s\n' "$root/srv/apps" > "$pointer"
ptdir="$root/etc/locked"
mkdir -p "$ptdir"
mv "$pointer" "$ptdir/apps-path"
saved_pointer="$pointer"
pointer="$ptdir/apps-path"
chmod 000 "$ptdir"
if [ ! -x "$ptdir" ]; then
    run_payload
    assert '[ "$p_rc" = "7" ]' "an unenterable pointer directory is its own answer (rc $p_rc)"
    assert '[ "$(p_line source)" = "pointer" ]' "and not 'no pointer' (got '$(p_line source)')"
    assert '! grep -qF "$good" <<<"$p_out"' \
        "the default tree was not read on that answer (got '$p_out')"
else
    assert 'true' "skipped: this user can enter a mode-000 directory"
fi
chmod 755 "$ptdir"
pointer="$saved_pointer"
mv "$ptdir/apps-path" "$pointer"
rmdir "$ptdir"

# Neither file may be something other than a file.
rm -f "$pointer"; mkdir -p "$pointer"
run_payload
assert '[ "$p_rc" = "1" ]' "a directory where the pointer belongs is diagnosed (rc $p_rc)"
assert 'grep -qF "not a regular file" "$tmpdir/perr"' "saying so (said '$(cat "$tmpdir/perr")')"
rmdir "$pointer"
mv "$root/apps/.kasbah/server.json" "$tmpdir/keep.json"
mkdir -p "$root/apps/.kasbah/server.json"
run_payload
assert '[ "$p_rc" = "1" ]' "and so is a directory where the marker belongs (rc $p_rc)"
rmdir "$root/apps/.kasbah/server.json"
mv "$tmpdir/keep.json" "$root/apps/.kasbah/server.json"

# --- The remote step itself, on a pointer a hand edit left without a newline ----
# Run locally: the payload is plain bash over two paths it is given. `read`
# fails on a last line with no newline while still filling the variable, and
# the pointer must name its path either way.
sed -n "/<<'REMOTE'$/,/^REMOTE$/p" "$repo_dir/lib/marker.sh" | sed '1d;$d' > "$tmpdir/remote.sh"
assert 'grep -qF "read -r pointed" "$tmpdir/remote.sh"' "the remote step was extracted from lib/marker.sh"
mkdir -p "$tmpdir/etc-kasbah"
for body in '/srv/apps' $'/srv/apps\n'; do
    printf '%s' "$body" > "$tmpdir/etc-kasbah/apps-path"
    out=$(bash "$tmpdir/remote.sh" "$tmpdir/no-apps" "$tmpdir/etc-kasbah/apps-path" 2>&1); rc=$?
    assert '[ "$rc" = 3 ] && [ "$(head -n1 <<<"$out")" = "apps=/srv/apps" ]' \
        "a pointer holding $(printf '%q' "$body") names /srv/apps (rc $rc: $out)"
done
: > "$tmpdir/etc-kasbah/apps-path"
out=$(bash "$tmpdir/remote.sh" "$tmpdir/no-apps" "$tmpdir/etc-kasbah/apps-path" 2>&1); rc=$?
assert '[ "$rc" = 5 ]' "an empty pointer still names nothing (rc $rc: $out)"

exit "$fail"
