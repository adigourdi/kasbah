#!/usr/bin/env bash
# Test: versions.log's 3-month rotation, in templates/remote-deploy.sh.
#
# End-to-end and hermetic: the template is rendered through lib/remote_deploy.sh
# and then *run*, over a planted versions.log of synthetic timestamps, with a
# stub `docker` and a stub `date`. Exactly two questions are faked — what month
# it is, and what timestamp the new entry gets — because the month boundary is
# the whole subject here and a suite that could only ask about the month it
# happened to run in could never see a January write. Everything else, `gzip`
# and `mv` and the file itself, is real.
#
# The properties under test are the ones a later reader depends on: the cutoff
# (writing in August prunes April and earlier), that a retained line comes back
# byte for byte in its original order, that a line rotation cannot parse is
# never moved out, that the rewritten file ends in exactly one newline, that
# versions.log.gz is readable with `zcat` after more than one rotation, and that
# a rotation which cannot run costs the run neither its exit status nor its
# report — and, when it fails after the archive is written, says that the
# entries are now in both files rather than that nothing happened.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
template="$repo_dir/templates/remote-deploy.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

if ! command -v yq >/dev/null || ! command -v flock >/dev/null \
   || ! command -v gzip >/dev/null || ! command -v zcat >/dev/null; then
    echo "error: this suite needs yq (the render side), flock, gzip and zcat" >&2
    exit 2
fi
real_date="$(command -v date)"

# --- The stubs ---------------------------------------------------------------------
#
# A stock-only project asks docker for very little: one `compose up` and one
# `compose ps -q` for the health wait, which answers nothing so the wait has
# nothing to hold on to.

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"

cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = compose ] || { echo "docker stub: unhandled '$*'" >&2; exit 2; }
shift
[ "${1:-}" = -p ] || { echo "docker stub: a compose call with no -p: $*" >&2; exit 2; }
exit 0
STUB
chmod 0755 "$stub_dir/docker"

# The clock. `-u +%Y-%m` is the one question rotation asks and `-u -Iseconds` is
# the one the entry's frozen timestamp asks; both come from the case, so a run is
# reproducible in any month. Everything else — the health deadline's `+%s` — is
# the real date, so faking the month does not quietly fake a duration too.
cat > "$stub_dir/date" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ]; then
    case "\${2:-}" in
        +%Y-%m)    printf '%s\n' "\$FAKE_MONTH"; exit 0 ;;
        -Iseconds) printf '%s\n' "\$FAKE_MONTH-15T12:00:00+00:00"; exit 0 ;;
    esac
fi
exec "$real_date" "\$@"
STUB
chmod 0755 "$stub_dir/date"

# The stub is only evidence if it is really the one being used.
assert '[ "$(env PATH="$stub_dir:$PATH" FAKE_MONTH=2026-08 date -u +%Y-%m)" = "2026-08" ]' \
    "the date stub answers the month the case names"
assert '[ "$(env PATH="$stub_dir:$PATH" FAKE_MONTH=2026-08 date +%Y)" = "$("$real_date" +%Y)" ]' \
    "and passes every other question through to the real date"

# --- Rendering, the way `kasbah deploy` does it ------------------------------------

cat > "$tmpdir/render" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
cd "$1" || exit 2
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/remote_deploy.sh"
manifest_require
remote_deploy_read_manifest 1.0.0
remote_deploy_render "$KASBAH_TEMPLATE" "$2"
DRV

manifest='schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
'
compose='services:
  web:
    image: nginx:alpine
'

proj=""
run_out=""
run_err=""

# new_run <name> — a project directory holding a freshly rendered script and
# nothing in versions.log yet.
new_run() {
    local root="$tmpdir/run-$1" src="$tmpdir/src-$1"
    rm -rf "$root" "$src"
    proj="$root/demo"
    mkdir -p "$proj/scripts" "$src"
    printf '%s' "$manifest" > "$src/kasbah.yml"
    printf '%s' "$compose"  > "$src/compose.prod.yml"
    env KASBAH_LIB_DIR="$repo_dir/lib" KASBAH_TEMPLATE_DIR="$repo_dir/templates" \
        KASBAH_TEMPLATE="$template" KASBAH_VERSION=0.1.0-test \
        bash "$tmpdir/render" "$src" "$proj/scripts/remote-deploy.sh" \
        >/dev/null 2>"$tmpdir/render.err" \
        || { echo "error: could not render the script for case $1: $(cat "$tmpdir/render.err")" >&2; exit 2; }
    chmod 0755 "$proj/scripts/remote-deploy.sh"
    printf 'services: {}\n' > "$proj/compose.yml"
    printf 'DEMO=1\n' > "$proj/.env"
}

# run <month> <version> [extra PATH prefix] — one deploy, with the clock the
# case names.
run() {
    local month="$1" version="$2" prefix="${3:-}"
    env PATH="${prefix:+$prefix:}$stub_dir:$PATH" FAKE_MONTH="$month" \
        KASBAH_VERSION=0.1.0-test \
        "$proj/scripts/remote-deploy.sh" deploy "$version" \
        >"$tmpdir/run.out" 2>"$tmpdir/run.err" </dev/null
    local rc=$?
    run_out="$(cat "$tmpdir/run.out")"
    run_err="$(cat "$tmpdir/run.err")"
    return "$rc"
}

# entry <YYYY-MM> <version> — one frozen-shape line, for planting.
entry() {
    printf '%s-01T00:00:00+00:00 deploy %s no-backup kasbah=0.1.0-test digest=-' "$1" "$2"
}
# What `run <month> <version>` appends, so a case can name it.
appended() {
    printf '%s-15T12:00:00+00:00 deploy %s no-backup kasbah=0.1.0-test digest=-' "$1" "$2"
}

line_at() { sed -n "$2p" "$1"; }

# --- Case A: the worked example — a write in August ---------------------------------
# docs/build-deploy.md: entries from months strictly older than (this month − 3)
# move out. August − 3 is May, so April and earlier go and May onward stays. The
# boundary month itself being *retained* and the month one older being *pruned*
# is the whole off-by-one, and both are asserted below.
new_run a
{ entry 2026-02 1.0.0; printf '\n'
  entry 2026-03 1.1.0; printf '\n'
  printf '2026-04-30T23:59:59+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=-\n'
  printf '2026-05-01T00:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0-test digest=-\n'
  printf '2026-06-15T12:00:00+00:00 rollback 1.2.0 no-backup kasbah=0.1.0-test digest=-\n'
  printf '2026-07-31T23:59:59+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n'
} > "$proj/versions.log"
run 2026-08 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a deploy that rotates exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(wc -l < "$proj/versions.log")" = "4" ]' \
    "May onward plus the new entry stay in versions.log ($(wc -l < "$proj/versions.log") lines)
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(line_at "$proj/versions.log" 1)" = "2026-05-01T00:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "the boundary month itself is retained, byte for byte
        got: $(line_at "$proj/versions.log" 1)"
assert '[ "$(line_at "$proj/versions.log" 2)" = "2026-06-15T12:00:00+00:00 rollback 1.2.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "and so is the month after it, in its original order (got: $(line_at "$proj/versions.log" 2))"
assert '[ "$(line_at "$proj/versions.log" 3)" = "2026-07-31T23:59:59+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "and the month before the write (got: $(line_at "$proj/versions.log" 3))"
assert '[ "$(line_at "$proj/versions.log" 4)" = "$(appended 2026-08 1.5.0)" ]' \
    "with the entry this run appended last (got: $(line_at "$proj/versions.log" 4))"
assert '! grep -q "2026-04-30" "$proj/versions.log"' \
    "April 30th — one day older than the boundary month — is gone from the active log"

assert '[ -f "$proj/versions.log.gz" ]' "and versions.log.gz exists"
gz="$(zcat "$proj/versions.log.gz" 2>/dev/null)"; gzrc=$?
assert '[ "$gzrc" = "0" ]' "which zcat reads (exit $gzrc)"
assert '[ "$(grep -c . <<<"$gz")" = "3" ]' \
    "holding the three pruned entries (got: $(tr "\n" "/" <<<"$gz"))"
assert '[ "$(sed -n 1p <<<"$gz")" = "$(entry 2026-02 1.0.0)" ]' \
    "the oldest first, byte for byte (got: $(sed -n 1p <<<"$gz"))"
assert '[ "$(sed -n 2p <<<"$gz")" = "$(entry 2026-03 1.1.0)" ]' \
    "then the next (got: $(sed -n 2p <<<"$gz"))"
assert '[ "$(sed -n 3p <<<"$gz")" = "2026-04-30T23:59:59+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "and April last — the order they were written in (got: $(sed -n 3p <<<"$gz"))"
assert 'grep -qF "3 entries older than 2026-05 moved to versions.log.gz" <<<"$run_err"' \
    "the rotation says how many it moved and from which month, on stderr (said '$run_err')"
assert '[ "$(grep -c . <<<"$run_out")" = "5" ]' \
    "and stdout still carries nothing but the five-line report (stdout: $(tr "\n" "/" <<<"$run_out"))"

# --- Case B: a write in January, where the cutoff crosses the year -------------------
# January 2027 − 3 is October 2026, so September 2026 and earlier go. Computed as
# a month index rather than by string surgery, this is arithmetic; computed on
# the month number alone it underflows and prunes nothing, or everything.
new_run b
{ entry 2026-08 1.0.0; printf '\n'
  entry 2026-09 1.1.0; printf '\n'
  entry 2026-10 1.2.0; printf '\n'
  entry 2026-11 1.3.0; printf '\n'
  entry 2026-12 1.4.0; printf '\n'
  entry 2027-01 1.5.0; printf '\n'
} > "$proj/versions.log"
run 2027-01 1.6.0; rc=$?
assert '[ "$rc" = "0" ]' "a January write exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(wc -l < "$proj/versions.log")" = "5" ]' \
    "October 2026 onward plus the new entry stay ($(wc -l < "$proj/versions.log") lines)
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(line_at "$proj/versions.log" 1)" = "$(entry 2026-10 1.2.0)" ]' \
    "the boundary month is October of the *previous* year, and it is retained
        got: $(line_at "$proj/versions.log" 1)"
gz="$(zcat "$proj/versions.log.gz")"
assert '[ "$(grep -c . <<<"$gz")" = "2" ]' \
    "and only September and August moved out (got: $(tr "\n" "/" <<<"$gz"))"
assert '[ "$(sed -n 1p <<<"$gz")" = "$(entry 2026-08 1.0.0)" ]' "August 2026 (got: $(sed -n 1p <<<"$gz"))"
assert '[ "$(sed -n 2p <<<"$gz")" = "$(entry 2026-09 1.1.0)" ]' \
    "and September 2026 — the month one older than the boundary (got: $(sed -n 2p <<<"$gz"))"

# The other side of the same boundary: a March write, whose cutoff is December of
# the previous year. Three months back from March lands on the last month of the
# old year, which is where a `month - 3` that forgot to borrow lands too.
new_run b2
{ entry 2026-10 1.0.0; printf '\n'
  entry 2026-11 1.1.0; printf '\n'
  entry 2026-12 1.2.0; printf '\n'
  entry 2027-01 1.3.0; printf '\n'
  entry 2027-02 1.4.0; printf '\n'
} > "$proj/versions.log"
run 2027-03 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a March write exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(line_at "$proj/versions.log" 1)" = "$(entry 2026-12 1.2.0)" ]' \
    "December of the previous year is the boundary and is retained
        got: $(line_at "$proj/versions.log" 1)"
gz="$(zcat "$proj/versions.log.gz")"
assert '[ "$(grep -c . <<<"$gz")" = "2" ]' \
    "with October and November moved out and nothing else (got: $(tr "\n" "/" <<<"$gz"))"
assert '[ "$(sed -n 2p <<<"$gz")" = "$(entry 2026-11 1.1.0)" ]' \
    "November being the month one older than the boundary (got: $(sed -n 2p <<<"$gz"))"
# The cutoff the run announces, in the one case that can catch a month index
# converted back with the wrong borrow: only a December cutoff distinguishes
# `(idx - 1) / 12` from `idx / 12`, and the wrong one prints 2027-00.
assert 'grep -qF "older than 2026-12 moved to versions.log.gz" <<<"$run_err"' \
    "and the message names December 2026 as the cutoff (said '$run_err')"

# --- Case C: lines rotation cannot judge, and the file's last byte -------------------
# A line whose first field is not a YYYY-MM- timestamp is not an entry rotation
# gets to move: it stays in the active log, whatever it is. And the rewrite must
# hand every retained line back with exactly one newline on it — the file's
# frozen fields are useless if two entries can end up on one line.
new_run c
{ entry 2026-01 0.9.0; printf '\n'
  printf '# a note somebody left in the log by hand\n'
  printf '2026-04-01T00:00:00+00:00 deploy 1.0.0 backups/pre-deploy-20260401-000000.sql.gz kasbah=0.1.0-test digest=sha256:aaa\n'
  printf 'not-a-timestamp deploy 1.1.0 no-backup kasbah=0.1.0-test digest=-\n'
  printf '2026-06-01T00:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=- extra=1\n'
  printf '2026-07-02T00:00:00+0'; } > "$proj/versions.log"
assert '[ -n "$(tail -c 1 "$proj/versions.log")" ]' \
    "the planted log ends mid-line, with no newline — otherwise this case proves nothing"
run 2026-08 1.3.0; rc=$?
assert '[ "$rc" = "0" ]' "a deploy over it exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(wc -l < "$proj/versions.log")" = "5" ]' \
    "five lines remain: the two rotation could not judge, June, the truncated one, and the new entry
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(line_at "$proj/versions.log" 1)" = "# a note somebody left in the log by hand" ]' \
    "the hand-written note is kept, byte for byte (got: $(line_at "$proj/versions.log" 1))"
assert '[ "$(line_at "$proj/versions.log" 2)" = "not-a-timestamp deploy 1.1.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "and so is a line whose first field is not a timestamp at all (got: $(line_at "$proj/versions.log" 2))"
assert '[ "$(line_at "$proj/versions.log" 3)" = "2026-06-01T00:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=- extra=1" ]' \
    "an entry carrying an appended key=value pair survives it unchanged
        got: $(line_at "$proj/versions.log" 3)"
assert '[ "$(line_at "$proj/versions.log" 4)" = "2026-07-02T00:00:00+0" ]' \
    "the interrupted write is still a line of its own, holding exactly what it held
        got: $(line_at "$proj/versions.log" 4)"
assert '[ "$(line_at "$proj/versions.log" 5)" = "$(appended 2026-08 1.3.0)" ]' \
    "with the new entry below it, not fused onto it (got: $(line_at "$proj/versions.log" 5))"
assert '[ -z "$(tail -c 1 "$proj/versions.log")" ]' \
    "the rewritten file ends with a newline"
assert '[ -n "$(tail -n 1 "$proj/versions.log")" ]' \
    "and with exactly one — a second would make the last line empty"
gz="$(zcat "$proj/versions.log.gz")"
assert '[ "$(grep -c . <<<"$gz")" = "2" ]' \
    "and only the two datable old entries were moved out (got: $(tr "\n" "/" <<<"$gz"))"
assert '! grep -q "not-a-timestamp" <<<"$gz"' \
    "a line rotation cannot read a month out of is never moved to the gz"
assert '! grep -q "a note somebody left" <<<"$gz"' "nor a comment"

# --- Case C2: retained lines that a re-rendering would quietly tidy ------------------
# "Byte for byte" is only tested by lines that have something to lose. A CR, a
# trailing space, doubled internal spacing and a blank line are each what some
# plausible edit — the `${line%$'\r'}` rd_last_log_line does two functions away,
# a re-render from parsed fields, a `[ -n "$line" ] || continue` — would remove
# without changing anything a tidier fixture could see.
new_run c2
{ printf '2026-02-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-test digest=- \n'
  printf '2026-06-01T00:00:00+00:00  deploy  1.1.0  no-backup  kasbah=0.1.0-test  digest=-\n'
  printf '2026-06-02T00:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=-\r\n'
  printf '2026-06-03T00:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0-test digest=- \n'
  printf '\n'
  printf '2026-07-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n'
} > "$tmpdir/c2-plant"
cp "$tmpdir/c2-plant" "$proj/versions.log"
# What the active log must hold afterwards, built from the planted bytes rather
# than retyped: everything but the pruned first line, then this run's entry.
{ sed -n '2,$p' "$tmpdir/c2-plant"; appended 2026-08 1.5.0; printf '\n'; } > "$tmpdir/c2-expect"
run 2026-08 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a deploy over lines with odd spacing exits 0 (exit $rc)
        stderr: $run_err"
assert 'cmp -s "$tmpdir/c2-expect" "$proj/versions.log"' \
    "every retained line comes back byte for byte, in order, with nothing tidied
$(diff "$tmpdir/c2-expect" "$proj/versions.log" 2>&1 | sed "s/^/        | /" | head -20)"
# Named individually too, so a failure says which shape was lost rather than
# only that the files differ.
assert '[ "$(sed -n 2p "$proj/versions.log")" = "2026-06-02T00:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0-test digest=-'"$(printf '\r')"'" ]' \
    "a carriage return on a retained entry is not stripped"
assert '[ "$(sed -n 1p "$proj/versions.log")" = "2026-06-01T00:00:00+00:00  deploy  1.1.0  no-backup  kasbah=0.1.0-test  digest=-" ]' \
    "doubled spacing between fields is not collapsed (got: $(sed -n 1p "$proj/versions.log"))"
assert '[ "$(sed -n 3p "$proj/versions.log")" = "2026-06-03T00:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0-test digest=- " ]' \
    "and a trailing space is not trimmed (got: '"'"'$(sed -n 3p "$proj/versions.log")'"'"')"
assert '[ -z "$(sed -n 4p "$proj/versions.log")" ] && [ "$(wc -l < "$proj/versions.log")" = "6" ]' \
    "the blank line is still a line ($(wc -l < "$proj/versions.log") lines)"
# The pruned side too: the archive is the only copy of those bytes from here on.
assert '[ "$(zcat "$proj/versions.log.gz")" = "2026-02-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-test digest=- " ]' \
    "and the entry that moved out kept its own trailing space (got: '"'"'$(zcat "$proj/versions.log.gz")'"'"')"

# --- Case C3: scratch files a killed rotation left beside the record ------------------
# `.versions.log.keep`, `.drop` and `.part` live in <apps>/<name>/ and a rotation
# killed outright leaves them there (docs/build-deploy.md → Rotation). The claim
# the doc makes is that the next rotation cannot be corrupted by one, which rests
# on all three being truncated before use rather than appended to — so each is
# planted holding an entry that must not reach either file.
new_run c3
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
printf '%s\n' "$(entry 2026-01 9.9.9)" > "$proj/.versions.log.keep"
printf '%s\n' "$(entry 2026-01 8.8.8)" > "$proj/.versions.log.drop"
printf 'not gzip at all\n'             > "$proj/.versions.log.part"
run 2026-08 1.2.0; rc=$?
assert '[ "$rc" = "0" ]' "a rotation over stale scratch files exits 0 (exit $rc)
        stderr: $run_err"
assert '! grep -q "9.9.9" "$proj/versions.log"' \
    "the stale .keep did not become part of the rewritten log
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "which holds exactly the retained entry and the new one ($(wc -l < "$proj/versions.log") lines)"
gz="$(zcat "$proj/versions.log.gz" 2>/dev/null)"; gzrc=$?
assert '[ "$gzrc" = "0" ]' "the archive is whole gzip, so the stale .part was overwritten and not
        appended (exit $gzrc)"
assert '[ "$gz" = "$(entry 2026-01 1.0.0)" ]' \
    "and holds only the entry this rotation moved (got: '"'"'$gz'"'"')"
assert '! grep -qF "8.8.8" <<<"$gz"' "not the stale .drop's"
assert '[ -z "$(find "$proj" -maxdepth 1 -name ".versions.log.*" 2>/dev/null)" ]' \
    "and all three are gone afterwards (found: $(find "$proj" -maxdepth 1 -name ".versions.log.*" | tr "\n" " "))"

# --- Case D: two rotations, one gz ----------------------------------------------------
# Concatenated gzip streams are valid gzip and zcat reads them in order, which is
# what lets the archive be appended to rather than rebuilt. One rotation cannot
# tell an append from an overwrite, so the assertion is on the second.
new_run d
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-02 1.1.0; printf '\n'
  entry 2026-06 1.2.0; printf '\n'
  entry 2026-07 1.3.0; printf '\n'
} > "$proj/versions.log"
run 2026-08 1.4.0; rc=$?
assert '[ "$rc" = "0" ]' "the first rotation exits 0 (exit $rc)
        stderr: $run_err"
first_gz_bytes="$(wc -c < "$proj/versions.log.gz")"
run 2026-11 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "and so does the second, three months later (exit $rc)
        stderr: $run_err"
gz="$(zcat "$proj/versions.log.gz" 2>/dev/null)"; gzrc=$?
assert '[ "$gzrc" = "0" ]' "zcat reads the whole archive after two rotations (exit $gzrc)"
assert '[ "$(wc -c < "$proj/versions.log.gz")" -gt "$first_gz_bytes" ]' \
    "which grew rather than being replaced ($first_gz_bytes → $(wc -c < "$proj/versions.log.gz") bytes)"
assert '[ "$(grep -c . <<<"$gz")" = "4" ]' \
    "and holds both rotations' entries (got: $(tr "\n" "/" <<<"$gz"))"
assert '[ "$(sed -n 1p <<<"$gz")" = "$(entry 2026-01 1.0.0)" ]' \
    "the first rotation's entries first (got: $(sed -n 1p <<<"$gz"))"
assert '[ "$(sed -n 2p <<<"$gz")" = "$(entry 2026-02 1.1.0)" ]' "both of them (got: $(sed -n 2p <<<"$gz"))"
assert '[ "$(sed -n 3p <<<"$gz")" = "$(entry 2026-06 1.2.0)" ]' \
    "then the second rotation's, in order behind them (got: $(sed -n 3p <<<"$gz"))"
assert '[ "$(sed -n 4p <<<"$gz")" = "$(entry 2026-07 1.3.0)" ]' "and its second (got: $(sed -n 4p <<<"$gz"))"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "leaving the August entry and the November one in the active log ($(wc -l < "$proj/versions.log") lines)
        log: $(tr "\n" "/" < "$proj/versions.log")"

# --- Case E: nothing to prune ----------------------------------------------------------
# The active log is not rewritten at all — asserted by inode, because a rewrite
# that happened to produce identical bytes would be invisible any other way.
new_run e
{ entry 2026-06 1.0.0; printf '\n'
  entry 2026-07 1.1.0; printf '\n'
} > "$proj/versions.log"
ino_before="$(stat -c %i "$proj/versions.log")"
run 2026-08 1.2.0; rc=$?
assert '[ "$rc" = "0" ]' "a deploy with nothing to prune exits 0 (exit $rc)
        stderr: $run_err"
assert '[ ! -e "$proj/versions.log.gz" ]' \
    "no versions.log.gz is created (found: $(ls "$proj" | tr "\n" " "))"
assert '[ "$(stat -c %i "$proj/versions.log")" = "$ino_before" ]' \
    "and versions.log is the same file it was — appended to, never rewritten"
assert '[ "$(wc -l < "$proj/versions.log")" = "3" ]' \
    "holding both planted entries and the new one ($(wc -l < "$proj/versions.log") lines)"
assert '! grep -qF "moved to versions.log.gz" <<<"$run_err"' \
    "and nothing is announced (said '$run_err')"
assert '[ -z "$(find "$proj" -maxdepth 1 -name ".versions.log.*" 2>/dev/null)" ]' \
    "with no scratch file left beside it (found: $(find "$proj" -maxdepth 1 -name ".versions.log.*" | tr "\n" " "))"

# --- Case F: a rotation that cannot run ------------------------------------------------
# It is a warning and never the run's exit status: rd_report is the run's
# completion marker, and the local side refuses to ship the Traefik fragment
# without it — so a failed log compaction would cost the project its route.
# Nothing may be half-done either: the active log keeps every line.
nogzip="$tmpdir/nogzip"
mkdir -p "$nogzip"
printf '#!/usr/bin/env bash\necho "gzip: no\n" >&2\nexit 1\n' > "$nogzip/gzip"
chmod 0755 "$nogzip/gzip"
new_run f
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
run 2026-08 1.2.0 "$nogzip"; rc=$?
assert '[ "$rc" = "0" ]' "a rotation that cannot compress does not fail the deploy (exit $rc)
        stderr: $run_err"
assert '[ "$(grep -c . <<<"$run_out")" = "5" ]' \
    "the report is printed in full (stdout: $(tr "\n" "/" <<<"$run_out"))"
for k in version prev_version deployed_before backup digest; do
    assert "grep -q '^$k=' <<<\"\$run_out\"" \
        "with $k in it — the caller validates the whole key set before reading any of it
        stdout: $(tr "\n" "/" <<<"$run_out")"
done
assert 'grep -qF "versions.log could not be rotated" <<<"$run_err"' \
    "and the failure is said out loud on stderr (said '$run_err')"
assert '[ "$(wc -l < "$proj/versions.log")" = "3" ]' \
    "the active log keeps every line, including the one that was to be moved
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(line_at "$proj/versions.log" 1)" = "$(entry 2026-01 1.0.0)" ]' \
    "the entry rotation wanted is still first (got: $(line_at "$proj/versions.log" 1))"
assert '[ ! -e "$proj/versions.log.gz" ]' \
    "and no archive was started — nothing is half-written on either side"
assert '[ -z "$(find "$proj" -maxdepth 1 -name ".versions.log.*" 2>/dev/null)" ]' \
    "nor a scratch file left behind (found: $(find "$proj" -maxdepth 1 -name ".versions.log.*" | tr "\n" " "))"

# --- Case G: the archive is written and the rewrite then fails ------------------------
# The other failure shape, and the one the operator has to be told about. The
# entries are now in both files, and because the active log was never trimmed
# every later run appends them to the archive again — growth without end, under
# a message that would otherwise say nothing happened. Decision 4 accepts the
# duplication only because it is visible, so saying so is the whole point.
nomv="$tmpdir/nomv"
mkdir -p "$nomv"
printf '#!/usr/bin/env bash\necho "mv: no" >&2\nexit 1\n' > "$nomv/mv"
chmod 0755 "$nomv/mv"
new_run g
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
run 2026-08 1.2.0 "$nomv"; rc=$?
assert '[ "$rc" = "0" ]' "a rotation whose rewrite fails does not fail the deploy (exit $rc)
        stderr: $run_err"
assert '[ "$(grep -c . <<<"$run_out")" = "5" ]' \
    "the report is printed in full (stdout: $(tr "\n" "/" <<<"$run_out"))"
assert '[ -f "$proj/versions.log.gz" ] && [ "$(zcat "$proj/versions.log.gz")" = "$(entry 2026-01 1.0.0)" ]' \
    "the archive did get the pruned entry (got: '"'"'$(zcat "$proj/versions.log.gz" 2>/dev/null)'"'"')"
assert '[ "$(line_at "$proj/versions.log" 1)" = "$(entry 2026-01 1.0.0)" ]' \
    "and the active log still holds it too — that is the duplication, and it is real
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert 'grep -qF "BOTH files" <<<"$run_err"' \
    "which the warning says out loud (said '"'"'$run_err'"'"')"
assert 'grep -qF "until versions.log is trimmed by hand" <<<"$run_err"' \
    "along with what stops it repeating on every later run (said '"'"'$run_err'"'"')"
assert '! grep -qF "both files are exactly as they were" <<<"$run_err"' \
    "and never the other failure's message, which would deny it happened (said '"'"'$run_err'"'"')"
assert '[ -z "$(find "$proj" -maxdepth 1 -name ".versions.log.*" 2>/dev/null)" ]' \
    "with no scratch file left behind (found: $(find "$proj" -maxdepth 1 -name ".versions.log.*" | tr "\n" " "))"

# --- Case I: the archive append stops partway -------------------------------------------
# The third failure shape, and the one that used to hide inside the first. A
# `cat` that writes bytes and then fails — ENOSPC is the realistic producer —
# leaves a truncated gzip member permanently in the archive, so telling the
# operator that "both files are exactly as they were" is a claim the code cannot
# make. The active log is the half that is genuinely intact, and saying which
# half is which is what makes the archive repairable.
badcat="$tmpdir/badcat"
mkdir -p "$badcat"
printf '#!/usr/bin/env bash\nprintf "TRUNCATED\\n"\nexit 1\n' > "$badcat/cat"
chmod 0755 "$badcat/cat"
new_run i
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
run 2026-08 1.2.0 "$badcat"; rc=$?
assert '[ "$rc" = "0" ]' "a rotation whose archive append fails does not fail the deploy (exit $rc)
        stderr: $run_err"
assert '[ "$(grep -c . <<<"$run_out")" = "5" ]' \
    "the report is printed in full (stdout: $(tr "\n" "/" <<<"$run_out"))"
assert '[ "$(wc -l < "$proj/versions.log")" = "3" ]' \
    "the active log is untouched and still holds every entry ($(wc -l < "$proj/versions.log") lines)
        log: $(tr "\n" "/" < "$proj/versions.log")"
assert '[ "$(line_at "$proj/versions.log" 1)" = "$(entry 2026-01 1.0.0)" ]' \
    "including the one the rotation meant to move (got: $(line_at "$proj/versions.log" 1))"
assert '! zcat "$proj/versions.log.gz" >/dev/null 2>&1' \
    "the archive is the damaged half — zcat will not read it"
assert 'grep -qF "incomplete gzip member" <<<"$run_err"' \
    "which the warning names (said '"'"'$run_err'"'"')"
assert 'grep -qF "nothing was lost" <<<"$run_err"' \
    "together with the half that is intact (said '"'"'$run_err'"'"')"
assert '! grep -qF "both files are exactly as they were" <<<"$run_err"' \
    "and never the message that would deny the archive was touched (said '"'"'$run_err'"'"')"
assert '! grep -qF "BOTH files" <<<"$run_err"' \
    "nor the one for a failed rewrite, which did not happen here (said '"'"'$run_err'"'"')"
assert '[ -z "$(find "$proj" -maxdepth 1 -name ".versions.log.*" 2>/dev/null)" ]' \
    "with no scratch file left behind (found: $(find "$proj" -maxdepth 1 -name ".versions.log.*" | tr "\n" " "))"

# --- Case H: the active log keeps its mode across the rewrite ---------------------------
# `mv` replaces the inode, so without care the record inherits this run's umask.
# A deploy log that quietly turns 0600 on a host kasbah expects more than one
# person to administer is a record only one of them can read.
new_run h
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
chmod 0664 "$proj/versions.log"
( umask 077; run 2026-08 1.2.0 ); rc=$?
assert '[ "$rc" = "0" ]' "a rotation under a tight umask exits 0 (exit $rc)"
assert '[ "$(stat -c %a "$proj/versions.log")" = "664" ]' \
    "and versions.log keeps the mode it had, not the one the umask would give it
        (got $(stat -c %a "$proj/versions.log"))"
assert '[ -f "$proj/versions.log.gz" ]' "with the rotation itself having happened"

# --- Case H2: the archive is the same record and gets the same treatment -----------------
# `cat >> versions.log.gz` creates the file under this run's umask, so Case H's
# defect arrives again four lines later for the other half of the record — and an
# archive only the deploying user can read is what makes `kasbah rollback` draw
# conclusions from a file it never read (docs/phases/05-undo.md).
new_run h2
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
chmod 0644 "$proj/versions.log"
assert '[ ! -e "$proj/versions.log.gz" ]' \
    "there is no archive yet, so this rotation is the one that creates it — the case is about
        a file the append brings into existence"
( umask 077; run 2026-08 1.2.0 ); rc=$?
assert '[ "$rc" = "0" ]' "a first rotation under a tight umask exits 0 (exit $rc)
        stderr: $run_err"
assert '[ -f "$proj/versions.log.gz" ]' "and the archive is there"
assert '[ "$(stat -c %a "$proj/versions.log.gz")" = "644" ]' \
    "carrying the active log's mode and not the 600 the umask would have given it
        (got $(stat -c %a "$proj/versions.log.gz"))"
assert '[ "$(stat -c %a "$proj/versions.log")" = "644" ]' \
    "with the active log itself unchanged (got $(stat -c %a "$proj/versions.log"))"

# A second rotation appends to an archive that already exists, so the mode to
# keep is that file's own — whoever set it, and whatever the active log says.
chmod 0640 "$proj/versions.log.gz"
chmod 0600 "$proj/versions.log"
( umask 077; run 2026-11 1.3.0 ); rc=$?
assert '[ "$rc" = "0" ]' "the second rotation exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(zcat "$proj/versions.log.gz" | grep -c .)" = "2" ]' \
    "having appended to the archive rather than replaced it (got: $(zcat "$proj/versions.log.gz" | tr "\n" "/"))"
assert '[ "$(stat -c %a "$proj/versions.log.gz")" = "640" ]' \
    "the archive keeps its own mode, which is neither the umask's nor the active log's 600
        (got $(stat -c %a "$proj/versions.log.gz"))"

# The failure-tolerance rule, the same one Case H's mode preservation has, and it
# needs both halves reached separately. A `chmod` that fails is the half a
# missing `stat` hides: with no mode to apply, the chmod is never run at all, so
# a case that breaks both proves only the first.
nochmod="$tmpdir/nochmod"
mkdir -p "$nochmod"
printf '#!/usr/bin/env bash\nexit 1\n' > "$nochmod/chmod"
chmod 0755 "$nochmod/chmod"
new_run h3
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
chmod 0644 "$proj/versions.log"
run 2026-08 1.2.0 "$nochmod"; rc=$?
assert '[ "$rc" = "0" ]' "a host whose chmod refuses still rotates (exit $rc)
        stderr: $run_err"
assert '[ -f "$proj/versions.log.gz" ] && [ "$(zcat "$proj/versions.log.gz")" = "$(entry 2026-01 1.0.0)" ]' \
    "with the entry in the archive (got: '"'"'$(zcat "$proj/versions.log.gz" 2>/dev/null)'"'"')"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "and the active log rewritten ($(wc -l < "$proj/versions.log") lines)"
assert 'grep -qF "moved to versions.log.gz" <<<"$run_err"' \
    "announcing the rotation as the success it was (said '$run_err')"
assert '! grep -qF "could not be rotated" <<<"$run_err"' \
    "and the rotation is not reported as failed over a mode it could not set (said '$run_err')"
assert '! grep -qF "BOTH files" <<<"$run_err"' \
    "nor as the half-done rewrite, which a chmod folded into the rewrite's status would
        report (said '$run_err')"

# The other half: no GNU `stat`, so there is no mode to carry and the run loses
# that and nothing else.
nostat="$tmpdir/nostat"
mkdir -p "$nostat"
printf '#!/usr/bin/env bash\nexit 127\n' > "$nostat/stat"
chmod 0755 "$nostat/stat"
new_run h4
{ entry 2026-01 1.0.0; printf '\n'
  entry 2026-06 1.1.0; printf '\n'
} > "$proj/versions.log"
run 2026-08 1.2.0 "$nostat"; rc=$?
assert '[ "$rc" = "0" ]' "and so does a host with no GNU stat (exit $rc)
        stderr: $run_err"
assert '[ -f "$proj/versions.log.gz" ] && [ "$(zcat "$proj/versions.log.gz")" = "$(entry 2026-01 1.0.0)" ]' \
    "with the entry in the archive (got: '"'"'$(zcat "$proj/versions.log.gz" 2>/dev/null)'"'"')"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "and the active log rewritten ($(wc -l < "$proj/versions.log") lines)"
assert 'grep -qF "moved to versions.log.gz" <<<"$run_err"' \
    "announcing the rotation as the success it was (said '$run_err')"
assert '! grep -qF "could not be rotated" <<<"$run_err"' \
    "the rotation is not reported as failed over a mode it could not read (said '$run_err')"
assert '! grep -qF "BOTH files" <<<"$run_err"' \
    "nor as the half-done rewrite (said '$run_err')"

exit "$fail"
