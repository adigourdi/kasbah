#!/usr/bin/env bash
# Test: `kasbah history`, `kasbah pending`, `kasbah changelog` (internal/history,
# reading the record through internal/vlog on both ends).
#
# Two layers, one driver: planted versions.log / versions.log.gz files in a
# scratch apps tree, read by the binary under test through a stub `ssh` that runs
# the server's half here.
#   * the rendering and the two changelogs, case by case. stdout and stderr are
#     captured apart, because which of the two a line lands on is part of the
#     contract (docs/cli.md: a report is stdout, everything else is stderr).
#   * the commands' edges — the argument rules, the state file's write rule,
#     exit 3 for a server that does not answer, and the fact that nothing these
#     three do reaches the server as a write.
#
# `git` is real throughout: `pending` and `changelog` are git ranges, and the
# fixture repository carries the tags they name.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kver="$(cat "$repo_dir/VERSION")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export NO_COLOR=1

# --- The fixture project ----------------------------------------------------------
# Four tagged commits. Every range these tests ask for is a range in here, and
# the subjects are distinct so a log printed for the wrong range is visible
# rather than plausible.
project="$tmpdir/demo"
mkdir -p "$project"
cat > "$project/kasbah.yml" <<'YML'
schema: 1
kasbah_version: 0.1.0
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
YML
printf '%s\n' 'name: demo' > "$project/compose.prod.yml"
(
    cd "$project" || exit 1
    git init -q .
    git config user.email kasbah-test@example.invalid
    git config user.name "kasbah test"
    git config commit.gpgsign false
    git add -A
    git commit -qm "what v0.9.0 tags"
    git tag v0.9.0
    printf '%s\n' one > a.txt; git add -A; git commit -qm "what v1.0.0 tags"; git tag v1.0.0
    printf '%s\n' two > b.txt; git add -A; git commit -qm "what v2.0.0 tags"; git tag v2.0.0
    printf '%s\n' three > c.txt; git add -A; git commit -qm "what v3.0.0 tags"; git tag v3.0.0
) >/dev/null 2>&1
assert '[ "$(cd "$project" && git rev-parse v3.0.0)" = "$(cd "$project" && git rev-parse HEAD)" ]' \
    "the fixture's HEAD is v3.0.0, which is what pending compares against"

# --- The server -------------------------------------------------------------------
# A scratch apps tree whose kasbah is the binary under test, and a stub ssh that
# runs each remote command here — so the record is read by the real
# `kasbah remote vlog` out of files planted for each case. The marker says /apps
# and the stub hands the scratch tree over for that argument, so every path a
# report prints is the one a real server's would.
FAKE_APPS="$tmpdir/srv/apps"
mkdir -p "$FAKE_APPS/.kasbah/bin" "$FAKE_APPS/demo"
printf '%s\n' '{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2.0","mem_limit":"4g"}' \
    > "$FAKE_APPS/.kasbah/server.json"
cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir" "$tmpdir/home" "$tmpdir/runtmp"
call_log="$tmpdir/calls.log"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
last="${!#}"
if [ "$last" = true ]; then
    if [ -n "${FAKE_UNREACHABLE:-}" ]; then
        printf 'ssh: connect to host vps port 22: Connection refused\n' >&2
        exit 255
    fi
    exit 0
fi
eval "set -- $last"
if [ "$1 $2" = "sh -s" ]; then
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7" "${8:-}"
fi
args=()
for a; do [ "$a" = /apps ] && a="$FAKE_APPS"; args+=("$a"); done
exec "${args[@]}"
STUB
chmod 0755 "$stub_dir/ssh"

arch="$tmpdir/arch.log"
act="$tmpdir/act.log"
rsn_cut='ends in a truncated gzip member: whatever is inside it could not be decoded'
rsn_notgz='is not gzip: no archived entry could be decoded'

# The two files, in the states H_ACT and H_ARC name. A cut archive is the
# whole record followed by a member that stops after its header, so what
# decodes is exactly $arch. noaccess is a directory's state and would take the
# active log with it; for the archive alone it is planted as unreadable.
plant() {
    local d="$FAKE_APPS/demo"
    chmod -R u+rwX "$d" 2>/dev/null
    rm -rf "$d"
    mkdir -p "$d"
    case "$H_ACT" in
        ok)    cp "$act" "$d/versions.log" ;;
        empty) : > "$d/versions.log" ;;
    esac
    # An archive with entries in it is planted whole unless the case says
    # otherwise: the default state is "no damage", not "no archive".
    [ "$H_ARC" != missing ] || [ ! -s "$arch" ] || H_ARC=ok
    case "$H_ARC/$H_DMG" in
        ok/no) gzip -c < "$arch" > "$d/versions.log.gz" ;;
        ok/yes)
            if [ "$H_RSN" = "$rsn_notgz" ]; then
                printf 'not gzip\n' > "$d/versions.log.gz"
            else
                { gzip -c < "$arch"; printf 'x\n' | gzip -c | head -c 10; } > "$d/versions.log.gz"
            fi ;;
        unreadable/*|noaccess/*)
            gzip -c < "$arch" > "$d/versions.log.gz"
            chmod 000 "$d/versions.log.gz" ;;
    esac
    return 0
}

H_ACT=ok; H_ARC=missing; H_DMG=no; H_RSN=""
DRIVE_DIR=""
DRC=0; OUT=""; ERR=""
drive() {
    local mode="$1" rc=0 dir="${DRIVE_DIR:-$project}" args=()
    shift
    case "$mode" in
        history)   args=(history deploy@vps); [ "${1:-no}" = yes ] && args+=(--all) ;;
        pending)   args=(pending deploy@vps ${1:+"$1"}) ;;
        changelog) args=(changelog deploy@vps) ;;
    esac
    plant
    : > "$call_log"
    ( cd "$dir" && env -u KASBAH_LIB_DIR \
          HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/runtmp" \
          CALL_LOG="$call_log" FAKE_APPS="$FAKE_APPS" FAKE_UNREACHABLE="${FAKE_UNREACHABLE:-}" \
          "$KASBAH_BIN" "${args[@]}" ) >"$tmpdir/o" 2>"$tmpdir/e" </dev/null || rc=$?
    DRC=$rc
    OUT="$(cat "$tmpdir/o")"
    ERR="$(cat "$tmpdir/e")"
    H_ACT=ok; H_ARC=missing; H_DMG=no; H_RSN=""
    DRIVE_DIR=""
    return 0
}
# What reached stderr that is not a warning about the record itself.
not_warned() { grep -v '^warning: ' <<<"$ERR" || true; }

# ==================================================================================
# history — the table
# ==================================================================================
# The columns are padded to the widest value each one actually holds, so the
# fixture makes every column hold two different widths: `deploy` against
# `rollback`, a five-character version against an eleven-character one, and
# `no-backup` against a real backup path. A table printed at fixed widths, or at
# the header labels' widths, disagrees with every expected line below.
backup_path=backups/pre-deploy-20260204-100000.sql.gz
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00
  printf '%s deploy 1.0.0 %s kasbah=0.1.0 digest=-\n' 2026-02-04T10:00:00+00:00 "$backup_path"; } > "$arch"
{ printf '%s deploy 1.10.0-rc.1 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s rollback 1.0.0 no-backup kasbah=0.2.0-dev digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"

assert '[ "${#backup_path}" = "41" ] && [ "${#backup_path}" -gt "$(printf %s no-backup | wc -c)" ]' \
    "the archive's backup column really is wider than the active log's (${#backup_path} vs 9)"

# Plain: the active log only, so the backup column is nine wide and not
# forty-one — the width comes from what is shown, not from what was fetched.
drive history
head_plain="$(printf '%-25s  %-8s  %-11s  %-9s  %s' TIMESTAMP ACTION VERSION BACKUP KASBAH)"
row_a1="$(printf '%-25s  %-8s  %-11s  %-9s  %s' 2026-08-01T00:00:00+00:00 deploy 1.10.0-rc.1 no-backup 0.1.0)"
row_a2="$(printf '%-25s  %-8s  %-11s  %-9s  %s' 2026-08-02T00:00:00+00:00 rollback 1.0.0 no-backup 0.2.0-dev)"
assert '[ "$DRC" = 0 ]'                         "plain history renders (rc $DRC: $OUT / $ERR)"
assert 'grep -qxF "$head_plain" <<<"$OUT"'      "the header names the five columns docs/cli.md lists, padded (got '$(head -1 "$tmpdir/o")')"
assert 'grep -qxF "$row_a1" <<<"$OUT"'          "a deploy row lines up under it (got '$(sed -n 2p "$tmpdir/o")')"
assert 'grep -qxF "$row_a2" <<<"$OUT"'          "and so does a rollback row, whose action is two characters wider (got '$(sed -n 3p "$tmpdir/o")')"
assert '! grep -qF "0.9.0" <<<"$OUT"'           "plain history shows no archived entry (got '$OUT')"
assert '! grep -qF "$backup_path" <<<"$OUT"'    "not even one whose backup path would widen the table (got '$OUT')"
assert 'grep -qxF "2 entries in /apps/demo/versions.log on deploy@vps" <<<"$OUT"' \
    "and says how many, and out of which file (got '$OUT')"
assert 'grep -qF "2 more entries archived in versions.log.gz" <<<"$OUT"' \
    "a record with an archive says so rather than reading as the whole of it (got '$OUT')"
assert 'grep -qF "\`kasbah history deploy@vps --all\`" <<<"$OUT"' \
    "naming, as a command that can be run, the flag that shows them (got '$OUT')"
assert '[ -z "$ERR" ]' "and nothing at all goes to stderr — the report is the whole output (stderr: '$ERR')"

# --all: the archive in front, the rotation point marked, and the columns
# re-measured against the wider data.
drive history yes
head_all="$(printf '%-25s  %-8s  %-11s  %-41s  %s' TIMESTAMP ACTION VERSION BACKUP KASBAH)"
row_g1="$(printf '%-25s  %-8s  %-11s  %-41s  %s' 2026-01-04T10:00:00+00:00 deploy 0.9.0 no-backup 0.1.0)"
row_g2="$(printf '%-25s  %-8s  %-11s  %-41s  %s' 2026-02-04T10:00:00+00:00 deploy 1.0.0 "$backup_path" 0.1.0)"
row_b1="$(printf '%-25s  %-8s  %-11s  %-41s  %s' 2026-08-01T00:00:00+00:00 deploy 1.10.0-rc.1 no-backup 0.1.0)"
assert '[ "$DRC" = 0 ]'                    "--all renders (rc $DRC: $OUT / $ERR)"
assert 'grep -qxF "$head_all" <<<"$OUT"'   "its header is measured against the archived backup path too (got '$(head -1 "$tmpdir/o")')"
assert 'grep -qxF "$row_g1" <<<"$OUT"'     "the archived deploy is a row (got '$OUT')"
assert 'grep -qxF "$row_g2" <<<"$OUT"'     "including the one carrying a real backup path (got '$OUT')"
assert 'grep -qxF "$row_b1" <<<"$OUT"'     "and the active rows are re-padded to match (got '$OUT')"
assert '! grep -qxF "$row_a1" <<<"$OUT"'   "so the plain table's narrower row is not what --all prints"
n_g1=$(grep -nxF "$row_g1" <<<"$OUT" | cut -d: -f1)
n_sep=$(grep -n -- "-- rotated into versions.log.gz above / versions.log below --" <<<"$OUT" | cut -d: -f1)
n_b1=$(grep -nxF "$row_b1" <<<"$OUT" | cut -d: -f1)
assert '[ -n "$n_g1" ] && [ -n "$n_sep" ] && [ -n "$n_b1" ]' \
    "the rotation point is drawn once, between the two halves (archive $n_g1, separator $n_sep, active $n_b1)"
assert '[ "$n_g1" -lt "$n_sep" ] && [ "$n_sep" -lt "$n_b1" ]' \
    "with the archive above it and the active log below — the record in one order (archive $n_g1, separator $n_sep, active $n_b1)"
assert '[ "$(grep -c -- "-- rotated into" <<<"$OUT")" = "1" ]' \
    "and drawn once, not once per entry (got $(grep -c -- "-- rotated into" <<<"$OUT"))"
assert 'grep -qxF "4 entries on deploy@vps — 2 archived in /apps/demo/versions.log.gz, 2 active in /apps/demo/versions.log" <<<"$OUT"' \
    "the count says which half is which, and which file each half is in (got '$OUT')"
assert '! grep -qF "more entries archived" <<<"$OUT"' \
    "and does not go on pointing at a flag that is already set (got '$OUT')"
assert '[ -z "$ERR" ]' "--all writes nothing to stderr either (stderr: '$ERR')"

# The separator is not drawn when there is no rotation point on screen.
: > "$arch"
drive history yes
assert '! grep -qF -- "-- rotated into" <<<"$OUT"' \
    "an empty archive draws no rotation line (got '$OUT')"

# A record of one entry. The plain footer has always counted in words; the --all
# footer is the one that can say "1 entries".
: > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
drive history yes
assert 'grep -qxF "1 entry on deploy@vps — 0 archived in /apps/demo/versions.log.gz, 1 active in /apps/demo/versions.log" <<<"$OUT"' \
    "--all counts one entry as an entry (got '$OUT')"
drive history
assert 'grep -qxF "1 entry in /apps/demo/versions.log on deploy@vps" <<<"$OUT"' \
    "and so does plain history (got '$OUT')"

# --- A line that did not parse ------------------------------------------------------
# A `printf >>` killed mid-append leaves a line no version can be read out of.
# It is still a deploy that ran, and dropping it or inventing four columns for it
# both hide that; the bytes are what the operator can act on.
: > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 1.1\r\n' 2026-08-02T00:00:00+00:00
  printf '%s deploy 1.2.0 no-backup\n' 2026-08-03T00:00:00+00:00; } > "$act"
drive history
row_c1="$(printf '%-25s  %-6s  %-7s  %-9s  %s' 2026-08-01T00:00:00+00:00 deploy 1.0.0 no-backup 0.1.0)"
row_c3="$(printf '%-25s  %-6s  %-7s  %-9s  %s' 2026-08-03T00:00:00+00:00 deploy 1.2.0 no-backup -)"
bad_line="!! entry 2 of versions.log is not a kasbah entry: 2026-08-02T00:00:00+00:00 deploy 1.1"
assert 'grep -qxF "$row_c1" <<<"$OUT"' "a table with one damaged line still renders the good ones (got '$OUT')"
assert 'grep -qxF "$bad_line" <<<"$OUT"' \
    "the damaged line is shown as the bytes the file holds, in its place (got '$(grep "^!!" "$tmpdir/o")')"
assert '[ "$(grep -nxF "$bad_line" <<<"$OUT" | cut -d: -f1)" = "3" ]' \
    "between the entries it sits between, not collected at the end (line $(grep -nxF "$bad_line" <<<"$OUT" | cut -d: -f1))"
assert '! grep -q $'"'"'\r'"'"' <<<"$OUT"' \
    "with the CR a CRLF log carries stripped from it (got '$(grep "^!!" "$tmpdir/o" | cat -A)')"
assert 'grep -qxF "$row_c3" <<<"$OUT"' \
    "a line carrying only the four frozen fields prints '-' for the kasbah it never had (got '$(sed -n 4p "$tmpdir/o")')"
assert 'grep -qxF "3 entries in /apps/demo/versions.log on deploy@vps" <<<"$OUT"' \
    "the count includes it — it is an entry, not a nothing (got '$OUT')"
assert 'grep -qF "1 of them could not be read as a kasbah entry" <<<"$OUT"' \
    "and the footer says how many the table could not read (got '$OUT')"

# --- An empty record ---------------------------------------------------------------
: > "$arch"; : > "$act"
H_ACT=missing; drive history
assert '[ "$DRC" = 0 ]' "a project that has never deployed is not an error (rc $DRC: $ERR)"
assert 'grep -qF "no deploy record for demo on deploy@vps" <<<"$OUT"' \
    "it says there is no record (got '$OUT')"
assert 'grep -qF "/apps/demo/versions.log" <<<"$OUT"' "naming the file that is not there (got '$OUT')"
assert '! grep -qF TIMESTAMP <<<"$OUT"' "and prints no header over nothing (got '$OUT')"
assert '[ -z "$ERR" ]' "on stdout, like every other answer this command gives (stderr: '$ERR')"

H_ACT=empty; drive history
assert 'grep -qF "/apps/demo/versions.log on deploy@vps is empty" <<<"$OUT"' \
    "a log that is there and empty is a different sentence from one that is not there (got '$OUT')"

# The active log empty while the archive holds entries. Rotation rewrites the
# active log with the retained entries and the entry it has just written is
# always one of them, so this is a log that was lost, not a rotation.
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
: > "$act"
H_ACT=empty; H_ARC=ok; drive history
assert 'grep -qF "1 archived entry in versions.log.gz" <<<"$OUT"' \
    "an empty active log with an archive behind it says what is archived (got '$OUT')"
assert 'grep -qF "lost or replaced" <<<"$OUT"' \
    "and does not call it a project that never deployed (got '$OUT')"

# --- An archive that could not be read -----------------------------------------------
# The reader has already warned on stderr with the diagnosis. What must also be
# true is that the *report* does not read as the whole record — a run redirected
# to a file is the case this is about.
: > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
H_ARC=unreadable; drive history yes
assert 'grep -qF "/apps/demo/versions.log.gz could not be read (the probe called it '\''unreadable'\'')" <<<"$OUT"' \
    "--all over an unreadable archive says so in the report itself (got '$OUT')"
assert 'grep -qF "not the whole record" <<<"$OUT"' \
    "in the words that stop it being read as complete (got '$OUT')"
H_ARC=unreadable; drive history
assert 'grep -qF "not the whole record" <<<"$OUT"' \
    "and plain history says it too, since its count of what --all would add is short by the same entries (got '$OUT')"

# Damaged, in its two shapes — which differ by whether anything was decoded, and
# the operator's next move differs with them. The clause comes with the record
# from internal/vlog, which is where the decode knows which shape it hit.
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive history yes
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "an archive that decoded partway says the entries inside the last member are missing (got '$OUT')"
assert 'grep -qF "not the whole record" <<<"$OUT"' \
    "and lands on the same clause the other two shapes do, since that is the part every caller needs (got '$OUT')"
assert 'grep -qF "0.9.0" <<<"$OUT"' "while still showing everything that did decode (got '$OUT')"
: > "$arch"
H_ARC=ok; H_DMG=yes; H_RSN="$rsn_notgz"; drive history yes
assert 'grep -qF "is not gzip" <<<"$OUT"' \
    "an archive nothing decoded from is a different sentence — gzip never started (got '$OUT')"
assert '! grep -qF "truncated gzip member" <<<"$OUT"' \
    "and not the one about a truncated member (got '$OUT')"

# Plain history over a damaged archive: the count of what --all would add is
# short by whatever the damage swallowed, so the sentence recommending --all
# must not promise the whole record while the note under it says otherwise.
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive history
assert 'grep -qF "1 more entry archived in versions.log.gz" <<<"$OUT"' \
    "plain history still counts what did decode (got '$OUT')"
assert '! grep -qF "shows the whole record" <<<"$OUT"' \
    "but does not offer a whole record the archive cannot give (got '$OUT')"
assert 'grep -qF "\`kasbah history deploy@vps --all\` shows what could be read of it" <<<"$OUT"' \
    "it offers what --all can actually show (got '$OUT')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "with the note saying why (got '$OUT')"
# The control: the same table with a whole archive says the opposite.
H_ARC=ok; drive history
assert 'grep -qF "shows the whole record" <<<"$OUT"' \
    "a whole archive is a whole record, and --all is offered as one (got '$OUT')"
assert '! grep -qF "could be read of it" <<<"$OUT"' "with no hedge on it (got '$OUT')"

# An empty active log beside a damaged archive — the branch that used to return
# before the note was reached, so the report claimed a record it did not have.
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
: > "$act"
H_ACT=empty; H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive history
assert 'grep -qF "1 archived entry in versions.log.gz" <<<"$OUT"' \
    "an empty active log still says what did decode (got '$OUT')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "and carries the note, like every other empty answer (got '$OUT')"
assert '! grep -qF "shows the whole record" <<<"$OUT"' \
    "without promising --all can show what is inside the truncated member (got '$OUT')"

# ==================================================================================
# pending
# ==================================================================================
# The deployed version comes out of the record. The fixture's HEAD is v3.0.0, so
# a server on 1.0.0 has v2.0.0 and v3.0.0 pending and nothing else.
: > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
drive pending
assert '[ "$DRC" = 0 ]' "pending against HEAD runs (rc $DRC: $ERR)"
assert 'grep -qxF "deploy@vps runs demo 1.0.0 (deploy, 2026-08-01T00:00:00+00:00)" <<<"$OUT"' \
    "it names the version the record says is deployed, and the entry it read it from (got '$OUT')"
assert 'grep -qxF "v1.0.0..HEAD — 2 commits" <<<"$OUT"' \
    "the range ends at HEAD and is counted (got '$OUT')"
assert 'grep -qF "what v2.0.0 tags" <<<"$OUT"'  "with the commits in it (got '$OUT')"
assert 'grep -qF "what v3.0.0 tags" <<<"$OUT"'  "all of them (got '$OUT')"
assert '! grep -qF "what v1.0.0 tags" <<<"$OUT"' "and nothing already deployed (got '$OUT')"
assert '[ -z "$ERR" ]' "the changelog is the report, so it is on stdout (stderr: '$ERR')"

drive pending 2.0.0
assert 'grep -qxF "v1.0.0..v2.0.0 — 1 commit" <<<"$OUT"' \
    "a named version ends the range instead of HEAD, and one commit is not 'commits' (got '$OUT')"
assert '! grep -qF "what v3.0.0 tags" <<<"$OUT"' \
    "so the commits after it are not in the answer (got '$OUT')"

# The record's last entry is a rollback: what is deployed is its target, and
# that is what pending compares against.
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00
  printf '%s rollback 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-03T00:00:00+00:00; } > "$act"
drive pending
assert 'grep -qxF "deploy@vps runs demo 1.0.0 (rollback, 2026-08-03T00:00:00+00:00)" <<<"$OUT"' \
    "after a rollback the deployed version is the rollback's target (got '$OUT')"
assert 'grep -qxF "v1.0.0..HEAD — 2 commits" <<<"$OUT"' \
    "so the pending range starts there, not at the deploy above it (got '$OUT')"

# Nothing pending, in the two directions it can be nothing.
{ printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
drive pending
assert 'grep -qF "nothing pending: HEAD is the commit deploy@vps is already running" <<<"$OUT"' \
    "HEAD at the deployed tag is nothing pending (got '$OUT')"
drive pending 1.0.0
assert 'grep -qF "v1.0.0 is not ahead of the 3.0.0 deploy@vps is running" <<<"$OUT"' \
    "a target behind the server is not a pending list, and says which way round it is (got '$OUT')"
assert 'grep -qF "\`git log v1.0.0..v3.0.0\`" <<<"$OUT"' \
    "naming the range that says what deploying it would give up (got '$OUT')"

# A project that has never deployed compares against nothing, and says so —
# without calling it an error.
: > "$act"; : > "$arch"
H_ACT=missing; drive pending
assert '[ "$DRC" = 0 ]' "pending on a server with no record is not a failure (rc $DRC: $ERR)"
assert 'grep -qF "deploy@vps has never deployed demo" <<<"$OUT"' "and says so (got '$OUT')"
assert '! grep -qF "commit" <<<"$OUT"' "with no range invented for it (got '$OUT')"

# "Never deployed here" is a claim about both files. With the archive in a state
# kasbah could not read, one of them was never looked at, and an operator who
# reads that sentence and stops has been told something the run does not know.
: > "$act"; : > "$arch"
H_ACT=missing; H_ARC=noaccess; drive pending
assert '[ "$DRC" = 0 ]' "an unreadable archive does not fail pending (rc $DRC: $ERR)"
assert '! grep -qF "deploy@vps has never deployed demo" <<<"$OUT"' \
    "and does not let it make the claim it makes when the archive is accounted for (got '$OUT')"
assert '! grep -qF "neither does its archive" <<<"$OUT"' \
    "least of all by asserting the archive is empty (got '$OUT')"
assert 'grep -qF "whether its archive holds one cannot be told" <<<"$OUT"' \
    "it says what is true instead (got '$OUT')"
assert 'grep -qF "could not be read (the probe called it '"'"'unreadable'"'"')" <<<"$OUT"' \
    "with the note naming the state the probe reported (got '$OUT')"

# The active log empty while the archive is a truncated gzip that gave up part
# of itself: the note has to pick its shape from what was decoded, and this
# branch used to hand it a hard-coded zero — so the report said "is not gzip"
# about an archive it had just read an entry out of.
{ printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
: > "$act"
H_ACT=empty; H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive pending
assert 'grep -qF "lost or replaced" <<<"$OUT"' \
    "the active log holds nothing and the archive does, so this is not a first deploy (got '$OUT')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "and the note is the one for an archive that decoded partway (got '$OUT')"
assert '! grep -qF "is not gzip" <<<"$OUT"' \
    "not the one for an archive nothing came out of, which the line above contradicts (got '$OUT')"
H_ACT=empty; H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive changelog
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "changelog reads the same record and says the same thing about it (got '$OUT')"
assert '! grep -qF "is not gzip" <<<"$OUT"' "and not the other one (got '$OUT')"

# A damaged last line is not the same thing as no history — calling it a first
# deploy is the defect this codebase has shipped once (docs/phases/05-undo.md).
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 1.1\n' 2026-08-02T00:00:00+00:00; } > "$act"
drive pending
assert 'grep -qF "has deployed demo" <<<"$OUT"' \
    "a truncated last line is still a history (got '$OUT')"
assert '! grep -qF "never deployed" <<<"$OUT"' "not a first deploy (got '$OUT')"
assert 'grep -qF "2026-08-02T00:00:00+00:00 deploy 1.1" <<<"$OUT"' \
    "showing the line it could not read (got '$OUT')"
assert '! grep -qF "commits" <<<"$OUT"' "and comparing against nothing (got '$OUT')"

# A tag this checkout has never fetched: a fact about the checkout, so a warning
# on stderr and not a failure — the same answer deploy's changelog gives.
{ printf '%s deploy 9.9.9 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
drive pending
assert '[ "$DRC" = 0 ]' "a missing tag does not fail the command (rc $DRC)"
assert 'grep -qF "this checkout has no tag v9.9.9" <<<"$ERR"' \
    "it warns, on stderr where warnings go (got stdout '$OUT' / stderr '$ERR')"
assert 'grep -qF "git fetch --tags" <<<"$ERR"' "naming what would fix it (got '$ERR')"
assert '! grep -qF "commit" <<<"$OUT"' "and the report carries no range (got '$OUT')"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
drive pending 8.8.8
assert 'grep -qF "v8.8.8 is not a tag in this checkout" <<<"$ERR"' \
    "and a version named on the command line gets its own sentence (got '$ERR')"

# A checkout whose HEAD is unborn while the deployed tag still resolves —
# `git checkout --orphan` leaves exactly that, and it is the one shape in which
# the range's far end is the half that cannot be read.
orphan="$tmpdir/orphan"
mkdir -p "$orphan"
(
    cd "$orphan" || exit 1
    git init -q .
    git config user.email kasbah-test@example.invalid
    git config user.name "kasbah test"
    git config commit.gpgsign false
    git commit -q --allow-empty -m "what v1.0.0 tags"
    git tag v1.0.0
    git checkout -q --orphan fresh
) >/dev/null 2>&1
cp "$project/kasbah.yml" "$orphan/"
assert '( cd "$orphan" && git rev-parse -q --verify "refs/tags/v1.0.0^{commit}" >/dev/null )' \
    "the orphan fixture still resolves v1.0.0"
assert '! ( cd "$orphan" && git rev-parse -q --verify "HEAD^{commit}" >/dev/null 2>&1 )' \
    "and has no HEAD commit — the state this branch exists for"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00; } > "$act"
DRIVE_DIR="$orphan"; drive pending
assert '[ "$DRC" = 0 ]' "pending in a checkout with no HEAD commit is not a failure (rc $DRC: $ERR)"
assert 'grep -qF "this checkout has no HEAD commit" <<<"$ERR"' \
    "it warns, naming the half that could not be read (got stdout '$OUT' / stderr '$ERR')"
assert 'grep -qF "runs demo 1.0.0" <<<"$OUT"' \
    "having already reported the version the server is on (got '$OUT')"
assert '! grep -qF "commit" <<<"$OUT"' "and no range (got '$OUT')"

# ==================================================================================
# changelog
# ==================================================================================
# **The last two entries of the record, whatever their action.** After a
# rollback, what is deployed is the rollback's target and the entry before it is
# the deploy it replaced — so the range runs backwards, and that is the answer
# rather than an error. A changelog reading the last two `deploy` entries would
# pair 1.0.0 with 1.0.0 here and call it a redeploy.
: > "$arch"
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00
  printf '%s rollback 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-03T00:00:00+00:00; } > "$act"
drive changelog
assert '[ "$DRC" = 0 ]' "changelog over a rollback runs (rc $DRC: $ERR)"
assert 'grep -qxF "deploy@vps runs demo 1.0.0 (rollback, 2026-08-03T00:00:00+00:00)" <<<"$OUT"' \
    "the version running is the rollback's target (got '$OUT')"
assert 'grep -qxF "after 3.0.0 (deploy, 2026-08-02T00:00:00+00:00)" <<<"$OUT"' \
    "and the entry before it is the deploy it replaced (got '$OUT')"
assert 'grep -qF "v3.0.0..v1.0.0 — none: 1.0.0 is not ahead of the 3.0.0 it replaced" <<<"$OUT"' \
    "the range runs backwards and is reported as that, not as an error (got '$OUT')"
assert 'grep -qF "\`git log v1.0.0..v3.0.0\`" <<<"$OUT"' \
    "with the range that says what the rollback gave up (got '$OUT')"
assert '! grep -qF "redeploy" <<<"$OUT"' \
    "and it is not read as a redeploy, which is what the last two *deploy* entries would have paired (got '$OUT')"

# The ordinary case: two deploys, the log of what the newer one shipped.
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
drive changelog
assert 'grep -qxF "v1.0.0..v3.0.0 — 2 commits" <<<"$OUT"' "two deploys give the range between them (got '$OUT')"
assert 'grep -qF "what v2.0.0 tags" <<<"$OUT"' "and the commits in it (got '$OUT')"
assert '[ -z "$ERR" ]' "on stdout (stderr: '$ERR')"

# The same version twice: the range is empty in a way that means something else.
{ printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
drive changelog
assert 'grep -qF "v3.0.0..v3.0.0 — none: 3.0.0 was already the version there" <<<"$OUT"' \
    "an empty range between equal versions is a redeploy (got '$OUT')"

# Spanning the rotation point: the entry before the active log's first is the
# archive's last, and the range crosses the two files without noticing.
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-01-04T10:00:00+00:00; } > "$arch"
{ printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
H_ARC=ok; drive changelog
assert 'grep -qxF "after 1.0.0 (deploy, 2026-01-04T10:00:00+00:00, archived)" <<<"$OUT"' \
    "the previous entry is read out of the archive, and said to be (got '$OUT')"
assert 'grep -qxF "v1.0.0..v3.0.0 — 2 commits" <<<"$OUT"' \
    "so the range spans the rotation point (got '$OUT')"

# The pair spans the rotation point *into* an archive that gave up part of
# itself. A truncated trailing member loses the newest archived entries — the
# ones sitting directly against the active log's first — so the entry named as
# "the entry before it" may not be, and the range built on it crosses a hole.
# `history` over this record says it is incomplete; the changelog used to build
# the range and say nothing, and its two dead-end branches carried the note
# while the one that actually spans the point did not.
H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive changelog
assert 'grep -qxF "after 1.0.0 (deploy, 2026-01-04T10:00:00+00:00, archived)" <<<"$OUT"' \
    "the previous entry still comes out of the archive (got '$OUT')"
assert 'grep -qF "an entry between it and 3.0.0 may be inside the part that could not be decoded" <<<"$OUT"' \
    "and the report says the pair may not be a pair (got '$OUT')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$OUT"' \
    "carrying the same note history gives for the same record (got '$OUT')"
assert 'grep -qF "not the whole record" <<<"$OUT"' "in the same words (got '$OUT')"
assert 'grep -qxF "v1.0.0..v3.0.0 — 2 commits" <<<"$OUT"' \
    "while still giving the range it could build, which is the useful half (got '$OUT')"
assert '[ -z "$(not_warned)" ]' "all of it on stdout, because all of it is the answer (stderr: '$ERR')"

# The control: the same pair over an archive that is whole says none of it.
H_ARC=ok; drive changelog
assert 'grep -qxF "after 1.0.0 (deploy, 2026-01-04T10:00:00+00:00, archived)" <<<"$OUT"' \
    "the same span (got '$OUT')"
assert '! grep -qF "not the whole record" <<<"$OUT"' \
    "with nothing said about a record it read all of (got '$OUT')"
assert '! grep -qF "may be inside the part that could not be decoded" <<<"$OUT"' \
    "and no hedge on the pair (got '$OUT')"

# And a pair that does not touch the archive at all takes no note, damaged
# archive or not: two adjacent entries of the active log have nothing between
# them for the archive to be short of.
{ printf '%s deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
H_ARC=ok; H_DMG=yes; H_RSN="$rsn_cut"; drive changelog
assert 'grep -qxF "after 1.0.0 (deploy, 2026-08-01T00:00:00+00:00)" <<<"$OUT"' \
    "the pair is entirely in the active log (got '$OUT')"
assert '! grep -qF "may be inside the part that could not be decoded" <<<"$OUT"' \
    "so the archive's hole cannot be between them, and is not raised (got '$OUT')"

# One entry in the whole record, with the archive accounted for: a first deploy.
{ printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
: > "$arch"
H_ARC=missing; drive changelog
assert 'grep -qF "3.0.0 is the first version deploy@vps ran here" <<<"$OUT"' \
    "one entry and a whole archive is a first deploy (got '$OUT')"

# The same shape with an archive kasbah could not read is the opposite answer:
# the entry before it may be in there.
H_ARC=noaccess; drive changelog
assert '! grep -qF "first version" <<<"$OUT"' \
    "an unreadable archive is not evidence that this is the first version (got '$OUT')"
assert 'grep -qF "nothing readable in the record before it" <<<"$OUT"' \
    "it says what is true instead (got '$OUT')"
assert 'grep -qF "not the whole record" <<<"$OUT"' "and why (got '$OUT')"

# The entry before the last is the damaged one.
: > "$arch"
{ printf '%s deploy 1.1\n' 2026-08-01T00:00:00+00:00
  printf '%s deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n' 2026-08-02T00:00:00+00:00; } > "$act"
drive changelog
assert 'grep -qF "the entry before it is not one a version can be read out of" <<<"$OUT"' \
    "a damaged previous entry is named rather than stepped over (got '$OUT')"
assert 'grep -qF "2026-08-01T00:00:00+00:00 deploy 1.1" <<<"$OUT"' "showing it (got '$OUT')"
assert '! grep -qF "commits" <<<"$OUT"' "with no range built past it (got '$OUT')"

# Nothing deployed at all.
: > "$act"
H_ACT=missing; drive changelog
assert '[ "$DRC" = 0 ]' "changelog with no record is not a failure (rc $DRC: $ERR)"
assert 'grep -qF "has never deployed demo" <<<"$OUT"' "and says there is no range (got '$OUT')"

# ==================================================================================
# The commands, end to end
# ==================================================================================
# The same stub and scratch tree; here the planted record is fixed and what is
# asserted is the command around it.
cli_log=$'2026-08-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n'
CRC=0; COUT=""; CERR=""
kasbah() {
    local rc=0
    printf '%s' "$cli_log" > "$act"
    printf '%s' "${CLI_ARCH:-}" > "$arch"
    H_ACT=ok; H_ARC="${CLI_ARCH:+ok}"; H_ARC="${H_ARC:-missing}"; plant
    H_ARC=missing; H_DMG=no; H_RSN=""
    : > "$call_log"
    ( cd "$project" && env -u KASBAH_LIB_DIR \
          HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/runtmp" \
          CALL_LOG="$call_log" FAKE_APPS="$FAKE_APPS" FAKE_UNREACHABLE="${FAKE_UNREACHABLE:-}" \
          "$KASBAH_BIN" "$@" ) >"$tmpdir/o" 2>"$tmpdir/e" </dev/null || rc=$?
    CRC=$rc; COUT="$(cat "$tmpdir/o")"; CERR="$(cat "$tmpdir/e")"
    return 0
}
state_of() { jq -r ".$1 // \"\"" "$project/.kasbah/state.json" 2>/dev/null; }

rm -rf "$project/.kasbah"
kasbah history deploy@vps
calls="$(<"$call_log")"
assert '[ "$CRC" = 0 ]' "kasbah history runs against a prepared server (rc $CRC: $CERR)"
assert 'grep -qF "TIMESTAMP" <<<"$COUT"' "printing its table on stdout (got '$COUT')"
assert '[ -z "$CERR" ]' "and nothing on stderr (stderr: '$CERR')"
assert '[ "$(state_of last_server)" = "deploy@vps" ]' \
    "a run that succeeded records the server (state: $(cat "$project/.kasbah/state.json" 2>/dev/null | tr -d '\n'))"
assert '[ "$(state_of last_version)" = "" ]' \
    "and touches nothing else — reading a record deploys nothing (state: $(cat "$project/.kasbah/state.json" 2>/dev/null | tr -d '\n'))"

# Read-only: the bootstrap probe (which brings the marker back), the record —
# and nothing that writes, ships or runs a deploy step.
assert '[ "$(grep -c "vlog" <<<"$calls")" = "1" ] && [ "$(grep -cF "'"'"'sh'"'"' '"'"'-s'"'"'" <<<"$calls")" = "1" ]' \
    "history reads the marker and the record once each (calls: $calls)"
assert '! grep -qE "'"'"'(setup-env|deploy|load|install-self)'"'"'|mkdir|rm |touch|tee|> " <<<"$calls"' \
    "and none of its calls writes to the server (calls: $calls)"
assert '! grep -qE "scp|rsync" <<<"$calls"' "nothing is shipped (calls: $calls)"

# The server is remembered, so the next run needs no argument.
kasbah history
assert '[ "$CRC" = 0 ]' "the next run defaults to it (rc $CRC: $CERR)"
assert 'grep -qF "TIMESTAMP" <<<"$COUT"' "and prints the same table (got '$COUT')"

kasbah pending deploy@vps
assert '[ "$CRC" = 0 ]' "kasbah pending runs (rc $CRC: $CERR)"
assert 'grep -qxF "v3.0.0..HEAD — nothing pending: HEAD is the commit deploy@vps is already running" <<<"$COUT"' \
    "resolving the deployed version from the server, not from state.json (got '$COUT')"

kasbah changelog deploy@vps
assert '[ "$CRC" = 0 ]' "kasbah changelog runs (rc $CRC: $CERR)"
assert 'grep -qxF "v1.0.0..v3.0.0 — 2 commits" <<<"$COUT"' "over the last two entries (got '$COUT')"

# state.json is a cache of what this workstation did and the record is what is
# running. A stale last_version must not be able to reach the answer.
jq '.last_version = "0.9.0"' "$project/.kasbah/state.json" > "$tmpdir/s.json" \
    && mv "$tmpdir/s.json" "$project/.kasbah/state.json"
kasbah pending deploy@vps
assert 'grep -qF "runs demo 3.0.0" <<<"$COUT"' \
    "a state file claiming another version does not change the answer (state said 0.9.0; got '$COUT')"

# An unreachable server: exit 3, and the state file is left exactly as it was.
state_before="$(cat "$project/.kasbah/state.json")"
FAKE_UNREACHABLE=1 kasbah pending deploy@other
assert '[ "$CRC" = "3" ]' "pending against a server that does not answer exits 3 (rc $CRC: $CERR)"
assert '[ -z "$COUT" ]' "with no report at all (stdout: '$COUT')"
assert 'grep -qF "cannot reach deploy@other" <<<"$CERR"' "and ssh's own failure on stderr (got '$CERR')"
assert '[ "$(cat "$project/.kasbah/state.json")" = "$state_before" ]' \
    "the state file is untouched by a run that failed (now: $(cat "$project/.kasbah/state.json" | tr -d '\n'))"
FAKE_UNREACHABLE=1 kasbah history deploy@other
assert '[ "$CRC" = "3" ]' "history exits 3 the same way (rc $CRC: $CERR)"
FAKE_UNREACHABLE=1 kasbah changelog deploy@other
assert '[ "$CRC" = "3" ]' "and so does changelog (rc $CRC: $CERR)"

# A project with no state file and no argument: there is nothing to guess at.
rm -rf "$project/.kasbah"
kasbah pending
assert '[ "$CRC" != "0" ]' "pending with no server and no memory of one stops (rc $CRC)"
assert 'grep -qF "never talked to one" <<<"$CERR"' "saying to pass it once (got '$CERR')"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and writes no state file"

# --all belongs to history alone, and the archive really does arrive only with it.
CLI_ARCH=$'2026-01-04T10:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n'
kasbah history deploy@vps --all
assert '[ "$CRC" = 0 ]' "history --all runs against a real gzip archive (rc $CRC: $CERR)"
assert 'grep -qF "0.9.0" <<<"$COUT"' "and the archived entry is in the table (got '$COUT')"
kasbah history deploy@vps
assert '! grep -qF "0.9.0" <<<"$COUT"' "while plain history leaves it out (got '$COUT')"
assert 'grep -qF "1 more entry archived" <<<"$COUT"' "and says it is there (got '$COUT')"
CLI_ARCH=""

kasbah pending deploy@vps --all
assert '[ "$CRC" != "0" ]' "pending has no --all (rc $CRC)"
assert 'grep -qF "unknown flag" <<<"$CERR"' "and says so (got '$CERR')"

# The argument rule: an '@' is the server, and these two take nothing else.
kasbah history vps
assert '[ "$CRC" != "0" ]' "history refuses an argument that is not a server (rc $CRC)"
assert 'grep -qF "'\''vps'\'' is not a server" <<<"$CERR"' "naming what it expected (got '$CERR')"
kasbah changelog 1.2.3
assert '[ "$CRC" != "0" ]' "changelog refuses a version (rc $CRC)"
assert 'grep -qF "takes no version" <<<"$CERR"' "pointing at the command that takes one (got '$CERR')"
kasbah pending deploy@vps deploy@other
assert '[ "$CRC" != "0" ]' "and two servers is one run too many (rc $CRC)"
assert 'grep -qF "two servers given" <<<"$CERR"' "the same refusal deploy and rollback make (got '$CERR')"
kasbah pending deploy@vps 2.0.0
assert '[ "$CRC" = "0" ]' "while a server and a version together are the ordinary call (rc $CRC: $CERR)"
assert 'grep -qF "v3.0.0..v2.0.0" <<<"$COUT"' "and the version ends the range (got '$COUT')"

exit "$fail"
