#!/usr/bin/env bash
# Test: lib/versions_log.sh — the deploy record, read off a server and parsed.
#
# Four layers, because the library has four:
#   * the frozen line parser, driven straight through the library;
#   * the loader and the four queries, against planted logs — no server, no
#     base64, just the two blobs the fetch would have produced;
#   * the remote step, extracted from its heredoc and run against a fake apps
#     tree, which is where the five file states are reachable and where
#     "reading a log writes nothing" is proved by digesting the tree;
#   * vlog_fetch itself, through a stub ssh that hands back a crafted protocol
#     block — a truncated report, a payload that is not base64, and a
#     versions.log.gz whose last member was cut off mid-write.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

tmpdir="$(mktemp -d)"
trap 'chmod -R u+rwX "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

# --- Driver ---------------------------------------------------------------------
# The library's own functions, called the way a command would call them.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like bin/kasbah: a query or a decode that dies under errexit before
# its own message runs is a defect this driver has to be able to reproduce.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/versions_log.sh"

# Everything a consumer can see, in one block. The queries are asked here rather
# than in each mode, so every fixture answers all four.
dump() {
    local i idx=""
    printf 'active_state=%s\narchive_state=%s\ndamaged=%s\nreason=%s\n' \
        "$VLOG_ACTIVE_STATE" "$VLOG_ARCHIVE_STATE" "$VLOG_ARCHIVE_DAMAGED" \
        "$VLOG_ARCHIVE_REASON"
    printf 'entries=%s\n' "${#VLOG_RAW[@]}"
    for i in "${!VLOG_RAW[@]}"; do
        printf 'entry=%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$i" "${VLOG_SRC[$i]}" "${VLOG_OK[$i]}" "${VLOG_TS[$i]}" \
            "${VLOG_ACTION[$i]}" "${VLOG_VERSION[$i]}" "${VLOG_BACKUP[$i]}" \
            "${VLOG_KASBAH[$i]}" "${VLOG_DIGEST[$i]}"
        printf 'raw=%s|%s\n' "$i" "${VLOG_RAW[$i]}"
    done
    if vlog_has_entries active; then printf 'has_active=yes\n'; else printf 'has_active=no\n'; fi
    if vlog_has_entries all;    then printf 'has_all=yes\n';    else printf 'has_all=no\n'; fi
    if vlog_last_entry idx;  then printf 'last=%s\n' "$idx";        else printf 'last=none\n'; fi
    if vlog_prev_deploy idx; then printf 'prev_deploy=%s\n' "$idx"; else printf 'prev_deploy=none\n'; fi
    printf 'prev_deploy_skipped=%s\n' "$VLOG_SKIPPED_DAMAGED"
    for i in "$@"; do
        if vlog_find_version "$i" idx; then
            printf 'find=%s|%s|%s|%s\n' "$i" "$idx" "${VLOG_SRC[$idx]}" "${VLOG_ACTION[$idx]}"
        else
            printf 'find=%s|none\n' "$i"
        fi
        printf 'find_skipped=%s|%s\n' "$i" "$VLOG_SKIPPED_DAMAGED"
    done
    return 0
}

# `$(cat f)` strips trailing newlines, which would hand vlog_load the same blob
# for a file that ends in one and a file that does not — the very distinction
# these fixtures exist to carry. The `x` marks the end and is removed again.
readraw() {
    local _v=""
    _v="$( { [ -f "$2" ] && cat "$2"; printf x; } )"
    printf -v "$1" '%s' "${_v%x}"
}

mode="$1"; shift
case "$mode" in
    logline)
        # The line arrives on stdin so a fixture can carry a CR or leading
        # spaces without the shell getting a vote.
        line="$(cat)"
        ts="" action="" version="" backup="" kasbah="" digest=""
        if vlog_parse_line "$line" ts action version backup kasbah digest; then
            printf 'parsed=yes\n'
        else
            printf 'parsed=no\n'
        fi
        printf 'ts=%s\naction=%s\nversion=%s\nbackup=%s\nkasbah=%s\ndigest=%s\n' \
            "$ts" "$action" "$version" "$backup" "$kasbah" "$digest"
        ;;
    load)
        # The two blobs the fetch would have handed over, from files so a
        # fixture can hold a CR, a trailing space or no final newline at all.
        readraw ARCH "$1"; readraw ACT "$2"; shift 2
        vlog_load "$ARCH" "$ACT"
        dump "$@"
        ;;
    loadtwice)
        # Two loads in one process: the second must answer for its own logs
        # only. A command reading a second project inherits the first otherwise.
        readraw ARCH "$1"; readraw ACT "$2"
        vlog_load "$ARCH" "$ACT"
        readraw ARCH "$3"; readraw ACT "$4"
        vlog_load "$ARCH" "$ACT"
        shift 4
        dump "$@"
        ;;
    fetch)
        target="$1" apps="$2" name="$3"; shift 3
        ssh_connect "$target"
        vlog_fetch "$SSH_TARGET" "$apps" "$name"
        dump "$@"
        ;;
    b64decode)
        # The decoded blob straight into a file: a `$( )` anywhere between the
        # decode and the comparison would strip the one byte under test.
        blob=""
        _vlog_b64_decode "$(base64 -w0 < "$1")" blob || exit 1
        printf '%s' "$blob" > "$2"
        ;;
    badscope)
        vlog_load '' ''
        vlog_has_entries "$1"
        ;;
    *) echo "unknown driver mode: $mode" >&2; exit 99 ;;
esac
DRV

drive()       { bash "$driver" "$@" 2>"$tmpdir/err"; }
drive_stdin() { bash "$driver" "$@" 2>"$tmpdir/err"; }
drive_err()   { cat "$tmpdir/err"; }

# --- The frozen line ------------------------------------------------------------
# docs/build-deploy.md's frozen format: four positional fields, then key=value
# pairs. A line from a later kasbah carries pairs this one has never heard of,
# and reading it must not depend on knowing them.
logline() { drive_stdin logline <<<"$1"; }

out=$(logline '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-')
assert 'grep -qxF "parsed=yes" <<<"$out"'                    "the line deploy writes today parses (got '$out')"
assert 'grep -qxF "ts=2026-08-13T22:30:37+00:00" <<<"$out"'  "field 1 is the timestamp (got '$out')"
assert 'grep -qxF "action=deploy" <<<"$out"'                 "field 2 is the action (got '$out')"
assert 'grep -qxF "version=1.0.0" <<<"$out"'                 "field 3 is the version (got '$out')"
assert 'grep -qxF "backup=no-backup" <<<"$out"'              "field 4 is the backup path (got '$out')"
assert 'grep -qxF "kasbah=0.1.0-dev" <<<"$out"'              "and kasbah= comes off the pairs (got '$out')"
assert 'grep -qxF "digest=-" <<<"$out"'                      "as does digest= (got '$out')"

out=$(logline '2026-04-17T09:15:00+00:00 rollback 1.2.0 backups/pre-deploy.sql.gz kasbah=0.1.0 digest=app@sha256:9f2a')
assert 'grep -qxF "action=rollback" <<<"$out"'               "a rollback entry parses the same way (got '$out')"
assert 'grep -qxF "backup=backups/pre-deploy.sql.gz" <<<"$out"' "with a real backup path in field 4 (got '$out')"
assert 'grep -qxF "digest=app@sha256:9f2a" <<<"$out"'        "and a real digest (got '$out')"

# The forward-compatibility case: pairs in another order, and three keys this
# version has never seen. Nothing may choke, and kasbah= must still be found by
# name rather than by position.
out=$(logline '2027-01-02T03:04:05+00:00 deploy 9.9.9 no-backup digest=- flock=held kasbah=2.0.0 lease=17')
assert 'grep -qxF "parsed=yes" <<<"$out"'      "a line with unknown trailing pairs still parses (got '$out')"
assert 'grep -qxF "version=9.9.9" <<<"$out"'   "its frozen fields read normally (got '$out')"
assert 'grep -qxF "kasbah=2.0.0" <<<"$out"'    "and kasbah= is found by key, not by position (got '$out')"
assert 'grep -qxF "digest=-" <<<"$out"'        "and so is digest= (got '$out')"

out=$(logline '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup')
assert 'grep -qxF "parsed=yes" <<<"$out"' "the four frozen fields alone are a valid line (got '$out')"
assert 'grep -qxF "kasbah=" <<<"$out"'    "with no kasbah= to report (got '$out')"
assert 'grep -qxF "digest=" <<<"$out"'    "and no digest= (got '$out')"

# The CR is put on the field that would carry it: the last one. A fixture with
# the CR after digest= leaves kasbah= untouched and proves nothing.
out=$(logline "$(printf '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup digest=- kasbah=0.1.0\r')")
assert 'grep -qxF "parsed=yes" <<<"$out"'     "a CRLF line parses (got '$out')"
assert 'grep -qxF "kasbah=0.1.0" <<<"$out"'   "and the CR is not carried into the last field (got '$out')"

# The tail is the part a later kasbah invents, so it must not be expanded
# against the filesystem. The fixture stands in a directory that would answer
# the glob — without the fix the pair is read as the file's name.
globdir="$tmpdir/globcwd"
mkdir -p "$globdir"
: > "$globdir/kasbah=EVIL"
: > "$globdir/digest=EVIL"
logline_in() { (cd "$1" && bash "$driver" logline 2>"$tmpdir/err") <<<"$2"; }
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 *')
assert 'grep -qxF "parsed=yes" <<<"$out"'    "a trailing pair that is a glob does not stop the line parsing (got '$out')"
assert 'grep -qxF "kasbah=0.1.0" <<<"$out"'  "and the real kasbah= is what is read, not a filename the cwd happens to hold (got '$out')"
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=- *')
assert 'grep -qxF "digest=-" <<<"$out"'      "and the real digest= likewise (got '$out')"
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup *')
assert 'grep -qxF "kasbah=" <<<"$out"' \
    "a line with no kasbah= at all reports none, whatever files the cwd holds (got '$out')"
assert 'grep -qxF "digest=" <<<"$out"' \
    "and none for digest= either (got '$out')"
# The control: the same glob character in the same cwd, where it *is* the value.
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=2.*')
assert 'grep -qxF "kasbah=2.*" <<<"$out"' \
    "a pair whose value contains a glob is reported verbatim (got '$out')"

# Malformed, in the shapes a real file produces: a truncated write, a blank
# line, something that was never a kasbah entry, and a timestamp that is not one.
for bad in '2026-08-13T22:30:37+00:00 deploy 1.0.0' '' 'just a note someone left' \
           'yesterday deploy 1.0.0 no-backup kasbah=0.1.0'; do
    out=$(logline "$bad")
    assert 'grep -qxF "parsed=no" <<<"$out"' "'$bad' is not a kasbah entry (got '$out')"
    assert 'grep -qxF "version=" <<<"$out"'  "and yields no version to print (got '$out')"
done

# --- The loader: ordering, no dedup, the raw line -------------------------------
# docs/phases/05-undo.md: the archive holds the older entries, so it comes
# first; and nothing is deduplicated against the active log, because a rotation
# whose archive append landed and whose rewrite did not leaves the same entries
# in both — the state remote-deploy.sh warns about, which a quiet dedup would
# hide.
e() { printf '%s %s %s %s kasbah=0.1.0 digest=-\n' "$1" "$2" "$3" "${4:-no-backup}"; }

arch="$tmpdir/arch.log"
act="$tmpdir/act.log"
{ e 2026-01-04T10:00:00+00:00 deploy 1.0.0
  e 2026-02-04T10:00:00+00:00 deploy 1.1.0; } > "$arch"
{ e 2026-02-04T10:00:00+00:00 deploy 1.1.0
  e 2026-03-04T10:00:00+00:00 deploy 1.2.0; } > "$act"
out=$(drive load "$arch" "$act" 1.1.0)
assert 'grep -qxF "entries=4" <<<"$out"' \
    "the entry in both files is two entries, not one — nothing is deduplicated (got '$out')"
assert 'grep -qF "entry=0|archive|yes|2026-01-04T10:00:00+00:00|deploy|1.0.0|" <<<"$out"' \
    "the archive's oldest entry comes first (got '$out')"
assert 'grep -qF "entry=1|archive|yes|2026-02-04T10:00:00+00:00|deploy|1.1.0|" <<<"$out"' \
    "then the rest of the archive, in the file's own order (got '$out')"
assert 'grep -qF "entry=2|active|yes|2026-02-04T10:00:00+00:00|deploy|1.1.0|" <<<"$out"' \
    "then the active log, and the duplicate is visible as its own entry (got '$out')"
assert 'grep -qF "entry=3|active|yes|2026-03-04T10:00:00+00:00|deploy|1.2.0|" <<<"$out"' \
    "ending with the newest line of the active log (got '$out')"
assert 'grep -qxF "last=3" <<<"$out"'        "the last entry is the active log's last (got '$out')"
assert 'grep -qxF "prev_deploy=2" <<<"$out"' "and the second-latest deploy is the one before it (got '$out')"
assert 'grep -qxF "find=1.1.0|2|active|deploy" <<<"$out"' \
    "a version in both files resolves to the active one, which is the record of what ran (got '$out')"

# The raw line, byte for byte: a CR, a doubled internal space and a trailing
# space, all in one line, because a fixture without them cannot tell whether the
# reader kept the bytes or a normalised copy of them.
raw_line=$(printf '2026-05-01T00:00:00+00:00  deploy  1.4.0 no-backup  kasbah=0.1.0 digest=- \r')
: > "$arch"
printf '%s\n' "$raw_line" > "$act"
out=$(drive load "$arch" "$act")
want=$(printf 'raw=0|%s' "$raw_line")
assert 'grep -qxF "$want" <<<"$out"' \
    "the line comes back exactly as the file holds it, CR and spacing included (got '$(cat -A <<<"$out" | grep ^raw)')"
assert 'grep -qF "entry=0|active|yes|2026-05-01T00:00:00+00:00|deploy|1.4.0|no-backup|0.1.0|-" <<<"$out"' \
    "while the parsed fields see past the CR and the doubled spaces (got '$out')"

# Blank lines are not entries, and a last line with no newline after it is —
# a `printf >>` killed mid-append leaves exactly that, and dropping it reports
# the second-to-last deploy as the current one.
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.4.0
  printf '\n   \n'
  printf '2026-05-09T00:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-'; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "entries=2" <<<"$out"'  "two blank lines are not two entries (got '$out')"
assert 'grep -qxF "last=1" <<<"$out"'     "a final line with no newline is still an entry (got '$out')"
assert 'grep -qF "entry=1|active|yes|2026-05-09T00:00:00+00:00|deploy|1.5.0|" <<<"$out"' \
    "and it is the one reported as the deployed version (got '$out')"

# A damaged last line is not the same thing as no history: "is there a record
# here" must answer yes while "what version is it" answers nothing
# (docs/phases/05-undo.md — collapsing the two has already cost two defects).
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.4.0
  printf '2026-05-09T00:00:00+00:00 deploy 1.5\n'; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "has_active=yes" <<<"$out"' "a project whose last line is truncated still has history (got '$out')"
assert 'grep -qxF "last=1" <<<"$out"'         "and the truncated line is the last entry (got '$out')"
assert 'grep -qF "entry=1|active|no|||||" <<<"$out"' \
    "reported as unparsed rather than as a version (got '$out')"

# Nothing at all: both questions answer no, and neither query invents an index.
: > "$arch"; : > "$act"
out=$(drive load "$arch" "$act" 1.0.0)
assert 'grep -qxF "entries=0" <<<"$out"'      "an empty pair of logs holds no entries (got '$out')"
assert 'grep -qxF "has_active=no" <<<"$out"'  "and no active history (got '$out')"
assert 'grep -qxF "has_all=no" <<<"$out"'     "and none anywhere (got '$out')"
assert 'grep -qxF "last=none" <<<"$out"'      "with no last entry (got '$out')"
assert 'grep -qxF "prev_deploy=none" <<<"$out"' "no previous deploy (got '$out')"
assert 'grep -qxF "find=1.0.0|none" <<<"$out"'  "and no version found (got '$out')"

# History that is entirely in the archive: the active log has not been written
# since a rotation moved everything out. "Is there a record" is scoped, because
# `history` shows the active half and `rollback` searches all of it.
{ e 2026-01-04T10:00:00+00:00 deploy 1.0.0; } > "$arch"
: > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "has_active=no" <<<"$out"' "an empty active log has no active history (got '$out')"
assert 'grep -qxF "has_all=yes" <<<"$out"'   "while the archive still holds a record (got '$out')"
assert 'grep -qxF "last=none" <<<"$out"'     "and the archive is not what says what is deployed (got '$out')"

# --- The queries ----------------------------------------------------------------

# Rollback's implicit target: the second-latest deploy, past however many
# rollbacks sit on top of it.
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.0.0
  e 2026-05-02T00:00:00+00:00 deploy 1.1.0
  e 2026-05-03T00:00:00+00:00 deploy 1.2.0
  e 2026-05-04T00:00:00+00:00 rollback 1.1.0
  e 2026-05-05T00:00:00+00:00 rollback 1.0.0; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "last=4" <<<"$out"' \
    "the last entry is the last line whatever its action — after a rollback, the rollback (got '$out')"
assert 'grep -qxF "prev_deploy=1" <<<"$out"' \
    "and the second-latest deploy skips the rollbacks above it (got '$out')"

# Exactly one deploy, and none at all: neither is a target.
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.0.0
  e 2026-05-04T00:00:00+00:00 rollback 1.0.0; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "prev_deploy=none" <<<"$out"' "one deploy is not a second-latest one (got '$out')"
: > "$arch"
{ e 2026-05-04T00:00:00+00:00 rollback 1.0.0; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "prev_deploy=none" <<<"$out"' "and neither is none (got '$out')"

# The previous deploy that has aged into the archive. Rotation is meant to be
# transparent (docs/build-deploy.md), so a project that deploys rarely has a
# rollback target rather than nothing.
{ e 2026-01-04T10:00:00+00:00 deploy 0.9.0; } > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.0.0; } > "$act"
out=$(drive load "$arch" "$act")
assert 'grep -qxF "prev_deploy=0" <<<"$out"' \
    "the second-latest deploy is found in the archive when the active log holds one (got '$out')"

# The aged-out rollback target: `rollback` refuses a version that was never
# deployed here, and that refusal must not be fooled by rotation.
{ e 2026-01-04T10:00:00+00:00 deploy 0.9.0
  e 2026-01-05T10:00:00+00:00 rollback 0.8.0; } > "$arch"
{ e 2026-05-01T10:00:00+00:00 deploy 1.0.0; } > "$act"
out=$(drive load "$arch" "$act" 0.9.0 0.8.0 1.0.0 2.0.0)
assert 'grep -qxF "find=0.9.0|0|archive|deploy" <<<"$out"' \
    "a version only the archive remembers is still found, with its action (got '$out')"
assert 'grep -qxF "find=0.8.0|1|archive|rollback" <<<"$out"' \
    "and the action reported is the entry's own, not an assumed deploy (got '$out')"
assert 'grep -qxF "find=1.0.0|2|active|deploy" <<<"$out"' \
    "the active log answers for its own versions (got '$out')"
assert 'grep -qxF "find=2.0.0|none" <<<"$out"' \
    "and a version nothing ran is not found (got '$out')"

# A query that stepped over a line it could not read has to be able to say so:
# a truncated latest deploy otherwise makes the deploy before it the rollback
# target with nothing said about why.
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.0.0
  e 2026-05-02T00:00:00+00:00 deploy 1.1.0
  printf '2026-05-03T00:00:00+00:00 deploy 1.2\n'; } > "$act"
out=$(drive load "$arch" "$act" 1.1.0)
assert 'grep -qxF "prev_deploy=0" <<<"$out"' \
    "the truncated latest line is not a deploy, so the target is the one before it (got '$out')"
assert 'grep -qxF "prev_deploy_skipped=1" <<<"$out"' \
    "and the query reports the line it stepped over to get there (got '$out')"
assert 'grep -qxF "find=1.1.0|1|active|deploy" <<<"$out"' \
    "a version search past the same line finds its answer (got '$out')"
assert 'grep -qxF "find_skipped=1.1.0|1" <<<"$out"' \
    "and reports the same (got '$out')"

# The control: the same record with nothing damaged in it reports none.
: > "$arch"
{ e 2026-05-01T00:00:00+00:00 deploy 1.0.0
  e 2026-05-02T00:00:00+00:00 deploy 1.1.0
  e 2026-05-03T00:00:00+00:00 deploy 1.2.0; } > "$act"
out=$(drive load "$arch" "$act" 1.1.0)
assert 'grep -qxF "prev_deploy_skipped=0" <<<"$out"' \
    "a whole record steps over nothing (got '$out')"
assert 'grep -qxF "find_skipped=1.1.0|0" <<<"$out"' \
    "for either query (got '$out')"

# A line that did not parse carries no version, so it cannot answer for one.
: > "$arch"
printf 'a note about 3.0.0 someone left\n' > "$act"
out=$(drive load "$arch" "$act" 3.0.0)
assert 'grep -qxF "find=3.0.0|none" <<<"$out"' \
    "a version named in a line that is not an entry was never deployed (got '$out')"
assert 'grep -qxF "has_active=yes" <<<"$out"' \
    "though the line is still an entry of the record (got '$out')"

# A second load answers for its own logs and nothing the first one held.
{ e 2026-01-04T10:00:00+00:00 deploy 0.9.0
  e 2026-01-05T10:00:00+00:00 deploy 0.9.1; } > "$arch"
{ e 2026-05-01T10:00:00+00:00 deploy 1.0.0; } > "$act"
arch2="$tmpdir/arch2.log"; act2="$tmpdir/act2.log"
: > "$arch2"
{ e 2026-06-01T10:00:00+00:00 deploy 2.0.0; } > "$act2"
out=$(drive loadtwice "$arch" "$act" "$arch2" "$act2" 0.9.0 2.0.0)
assert 'grep -qxF "entries=1" <<<"$out"' \
    "a second load holds only the second project's record (got '$out')"
assert 'grep -qxF "find=0.9.0|none" <<<"$out"' \
    "the first project's versions are gone with it (got '$out')"
assert 'grep -qxF "find=2.0.0|0|active|deploy" <<<"$out"' \
    "and the second's are all that answer (got '$out')"

rc=0; drive badscope sideways >/dev/null || rc=$?
assert '[ "$rc" != "0" ]' "vlog_has_entries refuses a scope it does not know (exit $rc)"

# --- The remote step, run locally -----------------------------------------------
# Extracted from its heredoc and run against a fake apps tree — the only way to
# reach the seven file states without a server, and where "reading a log writes
# nothing" is checked hermetically.
payload="$tmpdir/remote.sh"
sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$repo_dir/lib/versions_log.sh" | sed '1d;$d' > "$payload"
assert '[ -s "$payload" ]' "the remote script was extracted from lib/versions_log.sh"
assert 'grep -qF "active_state=%s" "$payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

apps="$tmpdir/apps"
mkdir -p "$apps/demo" "$apps/young" "$apps/emptylog" "$apps/notfile/versions.log" \
         "$apps/notfile/versions.log.gz" "$apps/never"
# Every normalisation a line-based shipper would quietly apply, planted in the
# one file the transport is asserted byte for byte against: a doubled internal
# space, a trailing space and a CR on the first line, and no final newline at
# all on the second. Without them the byte-for-byte claim is untestable, and a
# `b64` that stripped CRs and trailing blanks would ship green.
printf '2026-05-01T00:00:00+00:00 deploy 1.4.0 no-backup  kasbah=0.1.0 digest=- \r\n' \
    > "$apps/demo/versions.log"
printf '2026-05-09T00:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-' \
    >> "$apps/demo/versions.log"
{ e 2026-01-04T10:00:00+00:00 deploy 1.0.0; } | gzip > "$apps/demo/versions.log.gz"
# A regular file where a project directory would be, and an apps path that is
# one: `[ -e ]` answers no for a path *through* a file exactly as it does for a
# path that is not there, so both would otherwise read as "never deployed here".
: > "$apps/fileproj"
appsfile="$tmpdir/appsfile"
: > "$appsfile"
{ e 2026-05-01T00:00:00+00:00 deploy 1.4.0; } > "$apps/young/versions.log"
: > "$apps/emptylog/versions.log"
: > "$apps/emptylog/versions.log.gz"

tree_digest() {
    { find "$1" -printf '%y %m %s %T@ %p\n' | sort
      find "$1" -type f -exec sha256sum {} + | sort; } | sha256sum
}
before="$(tree_digest "$apps")"

run_payload() { bash "$payload" "${2:-$apps}" "$1"; }
pfact() { sed -n "s/^$1=//p" <<<"$2"; }

probe="$(run_payload demo 2>"$tmpdir/perr")"; probe_rc=$?
assert '[ "$probe_rc" = "0" ]' "the remote step exits 0 on a deployed project (exit $probe_rc: $(cat "$tmpdir/perr"))"
assert '[ "$(tree_digest "$apps")" = "$before" ]' \
    "and changed nothing — no file created, removed, rewritten or touched"
# The digest is only evidence if it can tell. One touch on one file must break it.
touch "$apps/demo/versions.log"
assert '[ "$(tree_digest "$apps")" != "$before" ]' \
    "the tree digest notices a bare touch — else the read-only assertion above proves nothing"
before="$(tree_digest "$apps")"

assert '[ "$(pfact active_state "$probe")" = "ok" ]'  "a readable log is ok (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "ok" ]' "as is its archive (got '$(pfact archive_state "$probe")')"
assert 'printf "%s" "$(pfact active_b64 "$probe")" | base64 -d | cmp -s - "$apps/demo/versions.log"' \
    "and the log comes back byte for byte — CR, doubled space, trailing space and missing final newline included"
assert '[ "$(printf "%s" "$(pfact archive_b64 "$probe")" | base64 -d | zcat)" = "$(zcat "$apps/demo/versions.log.gz")" ]' \
    "the archive travels as the raw gzip it is — decoding it is this side's job"

# The ordinary case for a project younger than the three-month rotation: a log
# that is fine and no archive beside it at all.
probe="$(run_payload young)"
assert '[ "$(pfact active_state "$probe")" = "ok" ]' \
    "a project with no rotation yet has a readable log (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "missing" ]' \
    "and a missing archive, which is not a failure (got '$(pfact archive_state "$probe")')"
assert '[ -z "$(pfact archive_b64 "$probe")" ]' \
    "with no bytes to go with it (got '$(pfact archive_b64 "$probe")')"

probe="$(run_payload fileproj)"
assert '[ "$(pfact active_state "$probe")" = "notdir" ]' \
    "a regular file where the project directory belongs is notdir, not missing (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "notdir" ]' \
    "for the archive too (got '$(pfact archive_state "$probe")')"
probe="$(run_payload demo "$appsfile")"
assert '[ "$(pfact active_state "$probe")" = "notdir" ]' \
    "and an apps path that is a regular file is notdir, not a project that was never deployed (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "notdir" ]' \
    "for the archive too (got '$(pfact archive_state "$probe")')"

probe="$(run_payload never)"
assert '[ "$(pfact active_state "$probe")" = "missing" ]' \
    "a project directory with no log has neither file (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "missing" ]' \
    "nor an archive (got '$(pfact archive_state "$probe")')"
probe="$(run_payload no-such-project)"
assert '[ "$(pfact active_state "$probe")" = "missing" ]' \
    "and neither does a project directory that is not there (got '$(pfact active_state "$probe")')"

probe="$(run_payload emptylog)"
assert '[ "$(pfact active_state "$probe")" = "empty" ]' \
    "a zero-byte log is empty, not ok (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "empty" ]' \
    "and so is a zero-byte archive — a gzip with no members (got '$(pfact archive_state "$probe")')"

probe="$(run_payload notfile)"
assert '[ "$(pfact active_state "$probe")" = "notfile" ]' \
    "a directory where the log should be says so (got '$(pfact active_state "$probe")')"
assert '[ "$(pfact archive_state "$probe")" = "notfile" ]' \
    "and so does one where the archive should be (got '$(pfact archive_state "$probe")')"

# What a mixed-ownership deploy leaves behind: files this user cannot read, and
# a directory this user cannot enter. Both answer "is there a versions.log" with
# "no" — the same answer a project that has never been deployed gives — so each
# has to be a state of its own.
if [ "$(id -u)" = 0 ]; then
    echo "note: running as root, so the unreadable cases are skipped (mode 000 does not stop root)" >&2
else
    mkdir -p "$apps/locked" "$apps/lockeddir"
    { e 2026-05-01T00:00:00+00:00 deploy 1.4.0; } > "$apps/locked/versions.log"
    { e 2026-01-01T00:00:00+00:00 deploy 1.0.0; } | gzip > "$apps/locked/versions.log.gz"
    chmod 000 "$apps/locked/versions.log" "$apps/locked/versions.log.gz"
    { e 2026-05-01T00:00:00+00:00 deploy 1.4.0; } > "$apps/lockeddir/versions.log"
    chmod 000 "$apps/lockeddir"
    # Size is the last thing asked, because a zero-byte log this user cannot
    # read is unreadable and not empty — the two send an operator different ways.
    mkdir -p "$apps/lockedempty"
    : > "$apps/lockedempty/versions.log"
    chmod 000 "$apps/lockedempty/versions.log"

    probe="$(run_payload locked 2>"$tmpdir/perr")"; probe_rc=$?
    assert '[ "$probe_rc" = "0" ]' "an unreadable log is not fatal to the remote step (exit $probe_rc)"
    assert '[ "$(pfact active_state "$probe")" = "unreadable" ]' \
        "a log this user cannot read is unreadable, never empty or missing (got '$(pfact active_state "$probe")')"
    assert '[ "$(pfact archive_state "$probe")" = "unreadable" ]' \
        "and so is an archive it cannot read (got '$(pfact archive_state "$probe")')"

    probe="$(run_payload lockeddir 2>>"$tmpdir/perr")"
    assert '[ "$(pfact active_state "$probe")" = "noaccess" ]' \
        "a project directory this user cannot enter is noaccess, the word server status uses (got '$(pfact active_state "$probe")')"
    assert '[ "$(pfact archive_state "$probe")" = "noaccess" ]' \
        "for either file (got '$(pfact archive_state "$probe")')"

    appsdir="$tmpdir/appsnoaccess"
    mkdir -p "$appsdir/demo"
    chmod 000 "$appsdir"
    probe="$(run_payload demo "$appsdir" 2>>"$tmpdir/perr")"
    assert '[ "$(pfact active_state "$probe")" = "noaccess" ]' \
        "and so is an apps path this user cannot enter (got '$(pfact active_state "$probe")')"
    chmod 755 "$appsdir"
    probe="$(run_payload lockedempty 2>>"$tmpdir/perr")"
    assert '[ "$(pfact active_state "$probe")" = "unreadable" ]' \
        "a zero-byte log this user cannot read is unreadable, not empty (got '$(pfact active_state "$probe")')"

    assert '[ ! -s "$tmpdir/perr" ]' \
        "and none of it leaks the shell's own complaint into the operator's stderr (said '$(cat "$tmpdir/perr")')"
    chmod 755 "$apps/lockeddir"
fi

# --- vlog_fetch, with a stub ssh -------------------------------------------------
# The stub answers the reachability probe and hands the one remote step whatever
# protocol block the case wrote, so a truncated report, a payload that is not
# base64 and a half-written archive are all reachable without a server.
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir" "$tmpdir/home"
ssh_log="$tmpdir/ssh.log"
payload_file="$tmpdir/payload"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
case "$last" in
    true) exit 0 ;;
esac
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
# The payload goes out either way: a step that failed *after* writing its
# report is what makes the exit-code check load-bearing rather than a second
# spelling of the protocol check below it.
cat "$SSH_PAYLOAD"
exit "${SSH_STEP_RC:-0}"
STUB
chmod 0755 "$stub_dir/ssh"

fetch() {
    : > "$ssh_log"
    env HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_PAYLOAD="$payload_file" \
        bash "$driver" fetch deploy@vps /apps demo "$@" 2>"$tmpdir/err"
}

# The report as the remote step writes it, from two blobs on disk.
write_payload() {
    local active_state="$1" active_file="$2" archive_state="$3" archive_file="$4"
    {
        printf 'active_state=%s\n' "$active_state"
        printf 'active_b64=%s\n' "$([ -n "$active_file" ] && base64 -w0 < "$active_file" || printf '')"
        printf 'archive_state=%s\n' "$archive_state"
        printf 'archive_b64=%s\n' "$([ -n "$archive_file" ] && base64 -w0 < "$archive_file" || printf '')"
    } > "$payload_file"
}

{ e 2026-05-01T00:00:00+00:00 deploy 1.4.0
  e 2026-05-09T00:00:00+00:00 deploy 1.5.0; } > "$act"
{ e 2026-01-04T10:00:00+00:00 deploy 1.0.0; } | gzip > "$tmpdir/arch.gz"
write_payload ok "$act" ok "$tmpdir/arch.gz"
out=$(fetch 1.0.0); rc=$?
assert '[ "$rc" = "0" ]' "a whole record is fetched without complaint (exit $rc: $(drive_err))"
assert 'grep -qxF "entries=3" <<<"$out"' "the archive's entry and the active log's two (got '$out')"
assert 'grep -qxF "damaged=no" <<<"$out"'  "an intact archive is not damaged (got '$out')"
assert 'grep -qxF "reason=" <<<"$out"' "and carries no clause for a report to print (got '$out')"
assert 'grep -qxF "find=1.0.0|0|archive|deploy" <<<"$out"' \
    "and the gz is decoded on this side, entries and all (got '$out')"
assert 'grep -qxF "last=2" <<<"$out"' "with the active log's last line as the deployed version (got '$out')"
assert "grep -qF \"'bash' '-s' '--' '/apps' 'demo'\" \"\$ssh_log\"" \
    "the remote step is handed the apps path and the project, and nothing else (log: $(cat "$ssh_log"))"
# One round trip is the contract, not an implementation detail: the stub logs a
# line per invocation, so a second step added later has to show up here.
assert '[ "$(grep -c "bash...-s" "$ssh_log")" = "1" ]' \
    "and it runs exactly once — one round trip for both files (log: $(cat "$ssh_log"))"

# A last line with no newline after it, all the way through the transport: the
# far side base64s the file's bytes, so the missing newline arrives as such.
printf '%s' "$(e 2026-05-01T00:00:00+00:00 deploy 1.4.0)
2026-05-09T00:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-" > "$tmpdir/nonl.log"
assert '[ "$(stat -c%s "$tmpdir/nonl.log")" != "$(stat -c%s "$act")" ]' \
    "the fixture really is a byte short of the same log with its newline"
assert '[ -n "$(tail -c1 "$tmpdir/nonl.log")" ]' "and its last byte is not the newline"
write_payload ok "$tmpdir/nonl.log" missing ""
out=$(fetch)
assert 'grep -qxF "entries=2" <<<"$out"' "a log whose last line has no newline yields both entries (got '$out')"
assert 'grep -qF "entry=1|active|yes|2026-05-09T00:00:00+00:00|deploy|1.5.0|" <<<"$out"' \
    "and the last one is the deploy that was cut off mid-write (got '$out')"
# The decode itself, byte for byte in both directions: this is the step where a
# `$( )` would quietly make the two fixtures the same blob, and the loader is
# tolerant enough that nothing downstream would ever notice.
drive b64decode "$tmpdir/nonl.log" "$tmpdir/nonl.out" || true
assert 'cmp -s "$tmpdir/nonl.log" "$tmpdir/nonl.out"' \
    "the decode leaves a missing final newline missing"
drive b64decode "$act" "$tmpdir/act.out" || true
assert 'cmp -s "$act" "$tmpdir/act.out"' \
    "and leaves a present one present, so nothing is added or trimmed either way"

# The control: the same two lines with the newline the other fixture lacks.
write_payload ok "$act" missing ""
out=$(fetch)
assert 'grep -qxF "entries=2" <<<"$out"' \
    "the same log ending in a newline reads the same, so the case above is the missing byte and nothing else (got '$out')"

# A log of nothing but blank lines is empty in the only sense a reader cares
# about, whatever the far side called it.
printf '\n  \n\n' > "$tmpdir/blank.log"
write_payload ok "$tmpdir/blank.log" missing ""
out=$(fetch)
assert 'grep -qxF "active_state=empty" <<<"$out"' "a log of blank lines is empty (got '$out')"
assert 'grep -qxF "entries=0" <<<"$out"'          "and holds no entries (got '$out')"

# The states travel: a missing archive beside a good log is the ordinary shape
# of a project younger than the rotation window, and neither is a failure.
write_payload ok "$act" missing ""
out=$(fetch); rc=$?
assert '[ "$rc" = "0" ]' "a project with no archive fetches cleanly (exit $rc: $(drive_err))"
assert 'grep -qxF "archive_state=missing" <<<"$out"' "with the archive reported missing (got '$out')"
assert 'grep -qxF "entries=2" <<<"$out"'             "and only the active log's entries (got '$out')"
# An empty log is an honest "no record yet", and reads as one.
write_payload empty "" ok "$tmpdir/arch.gz"
out=$(fetch); rc=$?
assert '[ "$rc" = "0" ]' "an empty active log is not a failure (exit $rc: $(drive_err))"
assert 'grep -qxF "active_state=empty" <<<"$out"' "and the state is carried through (got '$out')"
assert 'grep -qxF "has_active=no" <<<"$out"'      "with no active history (got '$out')"
assert 'grep -qxF "has_all=yes" <<<"$out"'        "while the archive still answers (got '$out')"

# The four states that mean "kasbah cannot read this file" are fatal for the
# active log and a warning for the archive, and the asymmetry is the point: a
# record that cannot be read must not answer with the same silence as a project
# that has never been deployed here, while losing the rotated history must not
# stop the record being read at all.
for state in notfile unreadable noaccess notdir; do
    write_payload "$state" "" ok "$tmpdir/arch.gz"
    rc=0; fetch >/dev/null || rc=$?
    assert '[ "$rc" != "0" ]' "an active log the server called $state stops the run (exit $rc)"
    assert 'grep -qF "/apps/demo/versions.log on deploy@vps cannot be read" <<<"$(drive_err)"' \
        "naming the path and the host (said '$(drive_err)')"
    assert 'grep -qF "called it '"'"'$state'"'"'" <<<"$(drive_err)"' \
        "and the state itself (said '$(drive_err)')"
    assert 'grep -qF "never been deployed" <<<"$(drive_err)"' \
        "and why it is not being read as an empty record (said '$(drive_err)')"

    write_payload ok "$act" "$state" ""
    out=$(fetch); rc=$?
    assert '[ "$rc" = "0" ]' "an archive the server called $state is a warning, not a failure (exit $rc: $(drive_err))"
    assert 'grep -qxF "archive_state=$state" <<<"$out"' "with the state carried through (got '$out')"
    assert 'grep -qxF "entries=2" <<<"$out"'            "leaving the active log's entries alone (got '$out')"
    assert 'grep -qF "versions.log.gz on deploy@vps cannot be read" <<<"$(drive_err)"' \
        "and the operator told the rotated history is not in what follows (said '$(drive_err)')"
done

# The half-written archive: rotation appends complete gzip members, and an
# append killed partway (ENOSPC) leaves a truncated trailing one. zcat writes
# every complete member and *then* fails, so the entries it did read are kept,
# the operator is warned, and the command carries on.
{ e 2026-01-04T10:00:00+00:00 deploy 1.0.0
  e 2026-01-05T10:00:00+00:00 deploy 1.0.1; } | gzip > "$tmpdir/m1.gz"
{ e 2026-02-04T10:00:00+00:00 deploy 1.1.0; } | gzip > "$tmpdir/m2.gz"
cat "$tmpdir/m1.gz" "$tmpdir/m2.gz" > "$tmpdir/two.gz"
assert '[ "$(zcat "$tmpdir/two.gz" | wc -l)" = "3" ]' \
    "two appended gzip members read as one stream — the control for the case below"
head -c "$(( $(stat -c%s "$tmpdir/m1.gz") + 10 ))" "$tmpdir/two.gz" > "$tmpdir/cut.gz"
write_payload ok "$act" ok "$tmpdir/cut.gz"
out=$(fetch 1.0.0 1.1.0); rc=$?
assert '[ "$rc" = "0" ]' "a damaged archive is a warning, never a failure (exit $rc: $(drive_err))"
assert 'grep -qxF "damaged=yes" <<<"$out"' "and it is reported as damaged (got '$out')"
assert 'grep -qF "/apps/demo/versions.log.gz on deploy@vps" <<<"$(drive_err)"' \
    "the warning names the file and the host (said '$(drive_err)')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$(drive_err)"' \
    "and says which of the two gzip failures this is (said '$(drive_err)')"
assert 'grep -qF "every entry before it is read" <<<"$(drive_err)"' \
    "and that what came before it was kept (said '$(drive_err)')"
assert 'grep -qxF "reason=ends in a truncated gzip member: whatever is inside it could not be decoded" <<<"$out"' \
    "and the same shape travels to the readers as a clause, chosen here where the decode knows
        which of the four it hit (got '$out')"
assert 'grep -qxF "entries=4" <<<"$out"' \
    "every complete member is still read — two archived entries plus the active log's two (got '$out')"
assert 'grep -qxF "find=1.0.0|0|archive|deploy" <<<"$out"' \
    "the entries before the damage are usable (got '$out')"
assert 'grep -qxF "find=1.1.0|none" <<<"$out"' \
    "and the ones inside the truncated member are simply not there (got '$out')"

# The other gzip failure, which the same exit code covers and which the same
# sentence would describe untruthfully: an archive that is not gzip at all.
# Nothing was decoded, so nothing was "read before the damage" and no partial
# append happened — a warning saying otherwise is what stops anyone looking.
printf 'a b c d\n' > "$tmpdir/notgz"
write_payload ok "$act" ok "$tmpdir/notgz"
out=$(fetch); rc=$?
assert '[ "$rc" = "0" ]' "an archive that is not gzip is a warning too (exit $rc: $(drive_err))"
assert 'grep -qxF "damaged=yes" <<<"$out"' "and is flagged (got '$out')"
assert 'grep -qF "is not gzip — nothing could be decoded from it" <<<"$(drive_err)"' \
    "said as what it is, not as a truncated tail (said '$(drive_err)')"
assert '! grep -qF "ran out of disk" <<<"$(drive_err)"' \
    "with no partial-append story attached to it (said '$(drive_err)')"
assert '! grep -qF "every entry before it is read" <<<"$(drive_err)"' \
    "and no claim that anything was read (said '$(drive_err)')"
assert 'grep -qxF "entries=2" <<<"$out"' \
    "the active log is all that is left of the record (got '$out')"
assert 'grep -qxF "reason=is not gzip: no archived entry could be decoded" <<<"$out"' \
    "with its own clause for the readers (got '$out')"

# A report the far side could not have written. A fact that never arrived must
# not be absorbed as an empty log — which is the shape of "never deployed here".
printf 'active_state=ok\nactive_b64=\n' > "$payload_file"
rc=0; fetch >/dev/null || rc=$?
assert '[ "$rc" != "0" ]' "a truncated report is refused (exit $rc)"
assert 'grep -qF "reported no archive_state archive_b64" <<<"$(drive_err)"' \
    "naming the keys that never arrived, in kasbah's own words rather than the shell's (said '$(drive_err)')"

# Not base64 at all — the transport was cut, not the file. Under errexit a bare
# `x="$(… | base64 -d)"` ends the process before the message about it can run.
write_payload ok "$act" missing ""
sed -i 's/^active_b64=.*/active_b64=@@@notbase64@@@/' "$payload_file"
rc=0; fetch >/dev/null || rc=$?
assert '[ "$rc" != "0" ]' "an active log that is not base64 fails (exit $rc)"
assert 'grep -qF "not base64" <<<"$(drive_err)"' \
    "and says so rather than dying mute (said '$(drive_err)')"
# The archive is the opposite: **everything** about it is a warning, which is
# the promise the library's header makes. A workstation that dies here loses
# `history`, `pending`, `changelog` and `rollback` over a file none of them
# needs when the target is in the active log.
write_payload ok "$act" ok "$tmpdir/arch.gz"
sed -i 's/^archive_b64=.*/archive_b64=@@@notbase64@@@/' "$payload_file"
out=$(fetch 1.4.0); rc=$?
assert '[ "$rc" = "0" ]' "an archive that is not base64 is a warning, not a failure (exit $rc: $(drive_err))"
assert 'grep -qxF "damaged=yes" <<<"$out"' "and reaches the readers as a damaged archive (got '$out')"
assert 'grep -qxF "reason=did not arrive as base64 from deploy@vps" <<<"$out"' \
    "carrying a clause that blames the transport, which no reader could have derived (got '$out')"
# Every reason is a clause, never a sentence: vlog_archive_note appends
# ", so this is not the whole record", and a reason ending in its own ", so …"
# would double the conjunction. Checked against this shape and the two above it.
assert '! grep -E "^reason=.*, so " <<<"$out"' \
    "the reason is a clause and supplies no ', so' of its own (got '$(grep "^reason=" <<<"$out")')"
assert 'grep -qF "did not come back as base64" <<<"$(drive_err)"' \
    "saying the transport was cut rather than blaming the file (said '$(drive_err)')"
assert '! grep -qF "is not gzip" <<<"$(drive_err)"' \
    "and never the sentence for a file that arrived and would not decode (said '$(drive_err)')"
assert 'grep -qxF "entries=2" <<<"$out"' \
    "the active log is read in full regardless (got '$out')"
assert 'grep -qxF "find=1.4.0|0|active|deploy" <<<"$out"' \
    "and a target that is in it is still found — the archive is not what the answer rests on (got '$out')"

# A workstation with no gzip. Same rule, and the one shape no count of decoded
# entries could ever distinguish: the file never reached a decoder at all.
#
# The PATH is rebuilt out of symlinks to everything the real one holds, minus
# zcat — shadowing it with a stub that exits 127 would not do, because the code
# asks `command -v` and a stub answers yes.
nozcat="$tmpdir/nozcat-path"
mkdir -p "$nozcat"
while IFS= read -r p; do
    [ -d "$p" ] || continue
    for f in "$p"/*; do
        [ -x "$f" ] && [ ! -d "$f" ] || continue
        [ "${f##*/}" = zcat ] && continue
        [ -e "$nozcat/${f##*/}" ] || ln -s "$f" "$nozcat/${f##*/}"
    done
done <<<"${PATH//:/$'\n'}"
assert '[ ! -e "$nozcat/zcat" ] && [ -x "$nozcat/base64" ]' \
    "the zcat-less PATH has everything but zcat — otherwise the case below proves nothing"

write_payload ok "$act" ok "$tmpdir/arch.gz"
: > "$ssh_log"
out=$(env -i HOME="$tmpdir/home" PATH="$stub_dir:$nozcat" SSH_LOG="$ssh_log" \
        SSH_PAYLOAD="$payload_file" KASBAH_LIB_DIR="$repo_dir/lib" \
        KASBAH_VERSION=0.1.0-test NO_COLOR=1 \
        bash "$driver" fetch deploy@vps /apps demo 1.4.0 2>"$tmpdir/err"); rc=$?
assert '[ "$rc" = "0" ]' \
    "an archive kasbah has no zcat for is a warning too, not a dead run (exit $rc: $(drive_err))"
assert 'grep -qxF "damaged=yes" <<<"$out"' "and is flagged as damaged (got '$out')"
assert 'grep -qxF "reason=could not be decoded on this workstation: zcat is not on its PATH" <<<"$out"' \
    "with the fourth clause, which is about this machine and not about the file (got '$out')"
assert 'grep -qF "zcat is not installed" <<<"$(drive_err)"' \
    "naming what is missing on *this* side (said '$(drive_err)')"
assert 'grep -qF "may be perfectly whole" <<<"$(drive_err)"' \
    "and refusing to blame the file on the server for it (said '$(drive_err)')"
assert '! grep -qF "is not gzip" <<<"$(drive_err)"' \
    "which is what saying 'is not gzip' here would do (said '$(drive_err)')"
assert 'grep -qxF "entries=2" <<<"$out"' \
    "the active log is still read, so history stays usable (got '$out')"

# The remote step itself failing is the caller's problem, not a silent no-history.
write_payload ok "$act" missing ""
export SSH_STEP_RC=1
rc=0; fetch >/dev/null || rc=$?
unset SSH_STEP_RC
assert '[ "$rc" != "0" ]' "a remote step that exits non-zero fails the read (exit $rc)"
assert 'grep -qF "the remote step exited 1" <<<"$(drive_err)"' \
    "even though it wrote a whole report before it died (said '$(drive_err)')"

exit "$fail"
