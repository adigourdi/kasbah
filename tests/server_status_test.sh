#!/usr/bin/env bash
# Test: lib/server_status.sh — everything about `kasbah server status` that
# does not need a server.
#
# Three layers, because the command has three:
#   * the pure parts (flag parsing, the versions.log line parser), driven
#     straight through the library;
#   * the remote script, extracted from its heredoc and run against a fake apps
#     tree with a stub docker on PATH — which is also where "read-only" is
#     proved, by digesting the tree before and after;
#   * the command itself, through bin/kasbah with a stub ssh that hands back a
#     crafted protocol block, which is what fixes the exit codes and the output
#     for states no rig can be put into on demand.
#
# The rig-driven half — that the numbers match a real server — is in
# tests/integration/spine_test.sh.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

# --- Driver ---------------------------------------------------------------------
# The library's own functions, called the way cmd_server_status calls them.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like bin/kasbah: a decode that dies under errexit before its own
# error message runs is a defect this driver has to be able to reproduce.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/server_status.sh"

mode="$1"; shift
case "$mode" in
    parse)
        # The flag, not the path: without --apps-path the path is not known
        # until the probe has read the server's own pointer.
        _server_status_parse_args "$@"
        printf 'target=%s\nflag=%s\n' "$_SS_TARGET" "$_SS_APPS_FLAG"
        ;;
    resolve)
        # The probe's answer turned into the path everything downstream reads.
        _SS_TARGET=deploy@vps
        _SS_FACT=([pointer_state]="$1" [pointer_value]="$2" [apps_path]="$3" [apps_source]="$4")
        _ss_resolve_apps_path
        printf 'apps=%s\nsource=%s\n' "$_SS_APPS_PATH" "$_SS_APPS_SOURCE"
        ;;
    logline)
        # The line arrives on stdin so a fixture can carry a CR or leading
        # spaces without the shell getting a vote.
        line="$(cat)"
        ts="" action="" version="" backup="" kasbah=""
        if vlog_parse_line "$line" ts action version backup kasbah; then
            printf 'parsed=yes\n'
        else
            printf 'parsed=no\n'
        fi
        printf 'ts=%s\naction=%s\nversion=%s\nbackup=%s\nkasbah=%s\n' \
            "$ts" "$action" "$version" "$backup" "$kasbah"
        ;;
    rawrows)
        # The same, with the payload passed through verbatim rather than
        # base64'd here: the only way to hand the decoder something that is not
        # base64 at all.
        _SS_TARGET=deploy@vps
        _SS_APPS_PATH=/apps
        _SS_MARKER_DATA=/apps/data
        _SS_FACT=([projects_b64]="$1" [project_count]="$2")
        _ss_decode_projects
        printf 'rows=%s\n' "${#_SS_P_NAME[@]}"
        ;;
    record)
        # The backup last-run record's reader, on its own: the two file states
        # and the server's clock as arguments, the record's bytes on stdin. This
        # is the only way to reach a stack that stopped a month ago without
        # waiting a month, and it is the reader `check --server` calls too.
        content="$(cat)"
        # Captured, not called bare: the driver runs under `set -e` like
        # bin/kasbah, and the reader answers 1 when there was no record to judge.
        rc=0
        backup_record_read "$1" "$2" "$content" "$3" || rc=$?
        printf 'rc=%s\nverdict=%s\nreason=%s\nstate=%s\nstatus=%s\nrepos=%s\noverdue=%s\nage=%s\nnext=%s\nclock=%s\n' \
            "$rc" "$BKR_VERDICT" "$BKR_REASON" "$BKR_STATE" "$BKR_STATUS" "$BKR_REPOS" \
            "$BKR_OVERDUE" "$BKR_AGE" "$BKR_NEXT_RUN" "$BKR_CLOCK"
        ;;
    ago)
        # The humaniser, which every one of those lines is printed through.
        said=""
        backup_record_ago "$1" said
        printf 'ago=%s\n' "$said"
        ;;
    printbackup)
        # The backup section's printer with the record reader stubbed, which is
        # the only way to hand it a verdict the reader cannot produce. `ok` is
        # not the catch-all arm, so a verdict this kasbah does not know has to
        # come out as one.
        _SS_TARGET=deploy@vps
        _SS_APPS_PATH=/apps
        _SS_MARKER_BK_ENABLED=true
        _SS_MARKER_BK_BASE=rest:http://u:p@h/base/
        _SS_MARKER_BK_AT=02:00
        _SS_MARKER_BK_JITTER=42
        _SS_FACT=([backup_dir_state]=dir [backup_status_state]=file
                  [backup_status_b64]="$(printf 'x' | base64 -w0)"
                  [backup_c_state]=running [backup_c_health]=healthy [backup_c_restarts]=0
                  [backup_haspass]="demo" [backup_projects]="demo=" [mail_dir_state]=absent
                  [now]=2000000000)
        eval "backup_record_read() { BKR_VERDICT=$1; BKR_REASON=''; BKR_STATE=sleeping;
              BKR_SINCE=1999990000; BKR_DEADLINE=2000086400; BKR_NEXT_RUN=2000082800;
              BKR_STARTED=1999980000; BKR_FINISHED=1999983600; BKR_STATUS=ok;
              BKR_REPOS=' demo'; BKR_OVERDUE=0; BKR_AGE=16400; BKR_NOW=2000000000;
              BKR_CLOCK=server; return ${2:-0}; }"
        _ss_print_backup
        ;;
    hosts)
        # The fragment parser on its own: content on stdin, one hostname per
        # line out, exit 2 when the document is not YAML.
        frag="$(cat)"
        hosts=""
        rc=0
        _ss_fragment_hosts "$frag" hosts || rc=$?
        printf 'rc=%s\n' "$rc"
        while IFS= read -r h; do
            [ -n "$h" ] || continue
            printf 'host=%s\n' "$h"
        done <<<"$hosts"
        ;;
    disk)
        # One df line, base64'd on the way in exactly as the probe sends it.
        line="" fs=""
        rc=0
        _ss_disk_sentence "$(printf '%s' "$1" | base64 -w0)" line fs || rc=$?
        printf 'rc=%s\nline=%s\nfs=%s\n' "$rc" "$line" "$fs"
        ;;
    rows)
        # The project table as it arrives from the far side: one base64 blob,
        # decoded into the parallel arrays the printer walks. $3/$4 are the two
        # paths the bind-mount-root filter reads.
        _SS_TARGET=deploy@vps
        _SS_APPS_PATH="${3:-/apps}"
        _SS_MARKER_DATA="${4:-/apps/data}"
        _SS_FACT=([projects_b64]="$(printf '%s' "$1" | base64 -w0)" [project_count]="$2")
        _ss_decode_projects
        for i in "${!_SS_P_NAME[@]}"; do
            printf 'row=%s|%s|%s|%s|%s\n' "${_SS_P_NAME[$i]}" "${_SS_P_TOTAL[$i]}" \
                "${_SS_P_RUNNING[$i]}" "${_SS_P_LOGSTATE[$i]}" "${_SS_P_LOG[$i]}"
            printf 'frag=%s|%s|%s\n' "${_SS_P_NAME[$i]}" "${_SS_P_FRAGSTATE[$i]}" \
                "$(printf '%s' "${_SS_P_FRAG[$i]}" | tr '\n' '~')"
            printf 'cont=%s|%s\n' "${_SS_P_NAME[$i]}" \
                "$(printf '%s' "${_SS_P_CONT[$i]}" | tr '\n' '~')"
        done
        printf 'rows=%s\n' "${#_SS_P_NAME[@]}"
        ;;
esac
DRV

drive() { bash "$driver" "$@" 2>"$tmpdir/err" </dev/null; }
drive_stdin() { bash "$driver" "$@" 2>"$tmpdir/err"; }
drive_err() { cat "$tmpdir/err"; }

# --- Flag parsing ------------------------------------------------------------------
out=$(drive parse deploy@vps); rc=$?
assert '[ "$rc" = "0" ]'                         "a bare target parses (exit $rc: $(drive_err))"
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is kept as given (got '$out')"
assert 'grep -qxF "flag=" <<<"$out"' \
    "without --apps-path nothing is decided here — the pointer answers later (got '$out')"

# The flag `deploy` cannot take, and the reason status must: a server prepared
# elsewhere is exactly the one whose state is hardest to inspect by hand.
out=$(drive parse deploy@vps --apps-path=/srv/apps); rc=$?
assert '[ "$rc" = "0" ]'                         "--apps-path is accepted (exit $rc: $(drive_err))"
assert 'grep -qxF "flag=/srv/apps" <<<"$out"'    "and honoured (got '$out')"
out=$(drive parse --apps-path=/srv/apps/ deploy@vps)
assert 'grep -qxF "flag=/srv/apps" <<<"$out"'    "a trailing slash is normalised away (got '$out')"

# --- Which path the run reads --------------------------------------------------------
# The flag wins; without it the server's own record does; without that, /apps.
# The whole reason the pointer exists is the middle row: a server prepared at
# /srv/apps is found by a command nobody told where to look.
out=$(drive resolve absent "" /srv/apps flag); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "apps=/srv/apps" <<<"$out" && grep -qxF "source=flag" <<<"$out"' \
    "--apps-path is what was read (exit $rc, got '$out': $(drive_err))"
out=$(drive resolve present /srv/apps /srv/apps pointer); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "apps=/srv/apps" <<<"$out"' \
    "a pointer steers a run that carried no flag (exit $rc, got '$out': $(drive_err))"
out=$(drive resolve absent "" /apps default); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "apps=/apps" <<<"$out"' \
    "and with neither, /apps as before (exit $rc, got '$out': $(drive_err))"

# A pointer that exists and names nothing usable is refused rather than replaced
# by the default: reading /apps instead would report a different server as this
# one. Under --apps-path it is not consulted at all.
drive resolve present srv/apps /apps default >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer holding a relative path is refused (exit $rc, said '$out')"
assert 'grep -qF "srv/apps" <<<"$out"' "quoting it (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' "and offering the escape hatch (said '$out')"
drive resolve notfile "" /apps default >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer that is not a regular file is refused (exit $rc, said '$out')"
# status never elevates, so a pointer it cannot read is a refusal with the flag
# as the way through — not a silent read of /apps, which may be another server.
drive resolve unreadable "" /apps default >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "an unreadable pointer is refused (exit $rc, said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' "offering the escape hatch (said '$out')"
# A pointer behind a directory this user cannot enter: whether the server
# records an apps path cannot be told, and reading /apps on that answer could
# describe a different server.
drive resolve unreachable "" /apps default >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "an unenterable pointer directory is refused (exit $rc, said '$out')"
assert 'grep -qF "/etc/kasbah" <<<"$out"' "naming it (said '$out')"

# Every one of those refusals is about a record status was going to *use*. Under
# --apps-path it uses none of them — that is what the escape hatch is: the way
# through a server whose pointer is damaged. A refusal there would prescribe the
# flag the operator has just passed.
for _state in unreadable notfile unreachable present; do
    _val=""
    [ "$_state" != present ] || _val=srv/broken
    out=$(drive resolve "$_state" "$_val" /srv/other flag); rc=$?
    assert '[ "$rc" = "0" ] && grep -qxF "apps=/srv/other" <<<"$out"' \
        "--apps-path reads its own tree with the pointer in state '$_state' (exit $rc, got '$out': $(drive_err))"
    assert 'grep -qxF "source=flag" <<<"$out"' "and says the flag is why (got '$out')"
done
out=$(drive resolve present srv/apps /srv/other flag); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "apps=/srv/other" <<<"$out"' \
    "but --apps-path does not care what the pointer says (exit $rc, got '$out': $(drive_err))"
drive resolve absent "" apps default >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "a probe reporting a relative apps path is a failure (exit $rc: $(drive_err))"
drive resolve absent "" /apps guessed >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "and so is one reporting a source this kasbah does not know (exit $rc: $(drive_err))"

reject() {
    local desc="$1" want="$2"; shift 2
    local out rc=0
    # drive() sends the library's stderr to a file of its own, so the message is
    # fetched from there rather than merged at the call site.
    drive parse "$@" >/dev/null || rc=$?
    out=$(drive_err)
    assert '[ "$rc" != "0" ]' "$desc (exit $rc, said '$out')"
    assert 'grep -qF -- "$want" <<<"$out"' "$desc — the message names '$want' (said '$out')"
}
reject "a missing target is refused"          "USER@HOST is required"
reject "a second target is refused"           "given once"        deploy@vps other@vps
reject "an unknown flag is refused"           "unknown flag"      deploy@vps --with-certs
reject "an empty --apps-path= is refused"     "must not be empty" deploy@vps --apps-path=
reject "a relative --apps-path= is refused"   "absolute path"     deploy@vps --apps-path=apps
reject "the filesystem root is refused"       "filesystem root"   deploy@vps --apps-path=/
reject "a '..' segment is refused"            "normalised path"   deploy@vps --apps-path=/srv/../apps

# --- The versions.log line ------------------------------------------------------------
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
assert 'grep -qxF "kasbah=0.1.0-dev" <<<"$out"'             "and kasbah= comes off the pairs (got '$out')"

out=$(logline '2026-04-17T09:15:00+00:00 rollback 1.2.0 backups/pre-deploy.sql.gz kasbah=0.1.0 digest=app@sha256:9f2a')
assert 'grep -qxF "action=rollback" <<<"$out"'               "a rollback entry parses the same way (got '$out')"
assert 'grep -qxF "backup=backups/pre-deploy.sql.gz" <<<"$out"' "with a real backup path in field 4 (got '$out')"

# The forward-compatibility case: pairs in another order, and three keys this
# version has never seen. Nothing may choke, and kasbah= must still be found by
# name rather than by position.
out=$(logline '2027-01-02T03:04:05+00:00 deploy 9.9.9 no-backup digest=- flock=held kasbah=2.0.0 lease=17')
assert 'grep -qxF "parsed=yes" <<<"$out"'      "a line with unknown trailing pairs still parses (got '$out')"
assert 'grep -qxF "version=9.9.9" <<<"$out"'   "its frozen fields read normally (got '$out')"
assert 'grep -qxF "kasbah=2.0.0" <<<"$out"'   "and kasbah= is found by key, not by position (got '$out')"

out=$(logline '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup')
assert 'grep -qxF "parsed=yes" <<<"$out"' "the four frozen fields alone are a valid line (got '$out')"
assert 'grep -qxF "kasbah=" <<<"$out"'   "with no kasbah= to report (got '$out')"

# The CR is put on the field that would carry it: the last one. A fixture with
# the CR after digest= leaves kasbah= untouched and proves nothing.
out=$(logline "$(printf '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup digest=- kasbah=0.1.0\r')")
assert 'grep -qxF "parsed=yes" <<<"$out"'        "a CRLF line parses (got '$out')"
assert 'grep -qxF "kasbah=0.1.0" <<<"$out"'     "and the CR is not carried into the last field (got '$out')"

# The tail is the part a later kasbah invents, so it must not be expanded
# against the filesystem. The fixture stands in a directory that would answer
# the glob — without the fix the pair is read as the file's name.
globdir="$tmpdir/globcwd"
mkdir -p "$globdir"
: > "$globdir/kasbah=EVIL"
: > "$globdir/digest=EVIL"
logline_in() { (cd "$1" && bash "$driver" logline 2>"$tmpdir/err") <<<"$2"; }
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 *')
assert 'grep -qxF "parsed=yes" <<<"$out"'      "a trailing pair that is a glob does not stop the line parsing (got '$out')"
assert 'grep -qxF "kasbah=0.1.0" <<<"$out"'   "and the real kasbah= is what is read, not a filename the cwd happens to hold (got '$out')"
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup digest=- *')
assert 'grep -qxF "kasbah=" <<<"$out"' \
    "a line with no kasbah= at all reports none, whatever files the cwd holds (got '$out')"
# The control: the same glob character in the same cwd, where it *is* the value.
out=$(logline_in "$globdir" '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=2.*')
assert 'grep -qxF "kasbah=2.*" <<<"$out"' \
    "a pair whose value contains a glob is reported verbatim (got '$out')"

# Malformed, in the three shapes a real file produces: a truncated write, a
# blank line, and something that was never a kasbah entry.
for bad in '2026-08-13T22:30:37+00:00 deploy 1.0.0' '' 'just a note someone left'; do
    out=$(logline "$bad")
    assert 'grep -qxF "parsed=no" <<<"$out"' "'$bad' is not a kasbah entry (got '$out')"
    assert 'grep -qxF "version=" <<<"$out"'  "and yields no version to print (got '$out')"
done

# --- The project table -------------------------------------------------------------
# `row <name> <total> <running> <logstate> <log> [fragstate] [fragment] [containers]`
# — the eight positional fields the far side builds, with `-` where a base64
# field is empty. The sentinel is not decoration: the reader splits on
# whitespace, so an empty field in the middle would shift every field after it.
row() {
    local logb=- fragb=- contb=-
    [ -z "$5" ]      || logb="$(printf '%s' "$5" | base64 -w0)"
    [ -z "${7:-}" ]  || fragb="$(printf '%s' "$7" | base64 -w0)"
    [ -z "${8:-}" ]  || contb="$(printf '%s' "$8" | base64 -w0)"
    printf '%s %s %s %s %s %s %s %s\n' "$(printf '%s' "$1" | base64 -w0)" \
        "$2" "$3" "$4" "$logb" "${6:-absent}" "$fragb" "$contb"
}
# One container line as the probe builds it, for the rows above.
cont() { printf '%s %s %s\n' "$(printf '%s' "$1" | base64 -w0)" "$2" "$3"; }

table="$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-')
$(row 'two words' 0 0 missing '')"
out=$(drive rows "$table" 2)
assert 'grep -qxF "rows=2" <<<"$out"' "both rows decode (got '$out')"
assert 'grep -qF "row=demo|1|1|ok|2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup" <<<"$out"' \
    "a row carries its whole versions.log line through the transport (got '$out')"
assert 'grep -qF "row=two words|0|0|missing|" <<<"$out"' \
    "and a project name with a space stays one field (got '$out')"

# A payload that is not base64 must say so. Under errexit a bare
# `x="$(… | base64 -d)"` ends the process on the spot, and the caller's message
# never runs — the run then fails with no output at all.
rc=0; drive rawrows 'ZGVtbw@@@notbase64' 1 >/dev/null || rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a project table that is not base64 fails (exit $rc)"
assert '[ -n "$out" ]' "and says something rather than dying mute (said '$out')"
assert 'grep -qF "not base64" <<<"$out"' "naming what was wrong with it (said '$out')"

# The same one level down: the row survives, its two encoded fields do not.
rc=0; drive rows "$(printf 'bm90IGJhc2U2NA== 1 1 ok @@@notbase64@@@\n')" 1 >/dev/null || rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a versions.log line that is not base64 fails (exit $rc)"
assert '[ -n "$out" ]' "and says so (said '$out')"

# A row the far side could not have built — five fields is the shape, and this
# is not it.
rc=0; drive rows 'onlyonefield' 1 >/dev/null || rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a malformed project row is refused (exit $rc)"
assert 'grep -qF "did not build" <<<"$out"' "saying the row is not one of its own (said '$out')"
rc=0; drive rows "$(row demo 1 1 ok 'x') extra" 1 >/dev/null || rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "and so is a row with a sixth field (exit $rc: $out)"

# The bind-mount root, when --data-path put it inside the apps path under a name
# no static list could hold. It is kasbah's own directory, not an undeployed
# project.
table_store="$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-')
$(row store 0 0 missing '')"
out=$(drive rows "$table_store" 2 /apps /apps/store)
assert 'grep -qxF "rows=1" <<<"$out"' "the --data-path directory is not a project (got '$out')"
assert 'grep -qF "row=demo|" <<<"$out"' "and the real one still is (got '$out')"
out=$(drive rows "$table_store" 2 /apps /srv/data)
assert 'grep -qxF "rows=2" <<<"$out"' \
    "a data path outside the apps path drops nothing — 'store' is then a project (got '$out')"
out=$(drive rows "$table_store" 2 /apps /apps/store/inner)
assert 'grep -qxF "rows=2" <<<"$out"' \
    "and neither does one nested deeper than a direct child (got '$out')"

# The count and the table are two statements about the same walk on the server.
rc=0; drive rows "$table" 3 >/dev/null || rc=$?; out=$(drive_err)
assert '[ "$rc" != "0" ]' "a table shorter than the count it came with is refused (exit $rc: $out)"
assert 'grep -qF "counted 3 projects and described 2" <<<"$out"' "saying so (said '$out')"

# --- The domain, out of a project's Traefik fragment -----------------------------------
# Parsed here rather than on the server: the VPS has no yq, jq or python3 and
# keeping it that way is deliberate, so the fragment travels back as bytes.
hosts() { drive_stdin hosts <<<"$1"; }

out=$(hosts 'http:
  routers:
    demo-http:
      rule: "Host(`demo.example.com`)"
    demo:
      rule: "Host(`demo.example.com`) || Host(`www.demo.example.com`)"
      tls:
        certResolver: letsencrypt')
assert 'grep -qxF "rc=0" <<<"$out"'                     "a fragment kasbah rendered parses (got '$out')"
assert 'grep -qxF "host=demo.example.com" <<<"$out"'    "its domain is read (got '$out')"
assert 'grep -qxF "host=www.demo.example.com" <<<"$out"' "and a second Host() in the same rule (got '$out')"
assert '[ "$(grep -c "^host=" <<<"$out")" = "2" ]' \
    "with the domain two routers share reported once, not twice (got '$out')"

# A router *key* carrying a newline. The routers are counted and then indexed
# through to_entries — never listed with `keys | .[]`, which would arrive as one
# line per line of the key and turn one router into two, the second of them a
# lookup that finds nothing.
out=$(hosts 'http:
  routers:
    "first\nsecond":
      rule: "Host(`smuggled.example.com`)"
    real:
      rule: "Host(`real.example.com`)"')
assert 'grep -qxF "rc=0" <<<"$out"' "a fragment with a newline in a router name still parses (got '$out')"
assert '[ "$(grep -c "^host=" <<<"$out")" = "2" ]' \
    "two routers are two routers however their names are spelled (got '$out')"
assert 'grep -qxF "host=real.example.com" <<<"$out"' \
    "and the router after the odd one is still read (got '$out')"

out=$(hosts 'http:
  routers:
    demo:
      rule: "PathPrefix(`/`)"')
assert 'grep -qxF "rc=0" <<<"$out"'        "a router with no Host() parses (got '$out')"
assert '! grep -q "^host=" <<<"$out"'      "and claims no domain (got '$out')"
out=$(hosts 'http:
  services:
    demo: {}')
assert '! grep -q "^host=" <<<"$out"'      "a fragment with no routers claims none either (got '$out')"
out=$(hosts 'http: [not: a mapping')
assert 'grep -qxF "rc=2" <<<"$out"'        "a fragment that is not YAML is its own answer (got '$out')"

# --- df's line, turned into a sentence -------------------------------------------------
out=$(drive disk '/dev/sda1 41152812 12345678 26906134 32% /')
assert 'grep -qxF "rc=0" <<<"$out"' "a df -Pk line reads (got '$out')"
assert 'grep -qF "11.7G of 39.2G used (32%), 25.6G free" <<<"$out"' \
    "in the units df -h would have printed (got '$out')"
assert 'grep -qxF "fs=/dev/sda1 on /" <<<"$out"' \
    "and the filesystem it is about, which is how two paths are known to share one (got '$out')"
out=$(drive disk 'Filesystem 1024-blocks Used Available Capacity Mounted on')
assert 'grep -qxF "rc=1" <<<"$out"' "a header line is not a figure (got '$out')"
out=$(drive disk '')
assert 'grep -qxF "rc=1" <<<"$out"' "and neither is nothing (got '$out')"
out=$(drive disk '/dev/sda1 4096 2048 2048 50% /mnt/my disk')
assert 'grep -qxF "fs=/dev/sda1 on /mnt/my disk" <<<"$out"' \
    "a mount point with a space in it is one field, not two (got '$out')"

# --- The backup stack's last-run record ------------------------------------------------
# The five states the plan names, and the three more the record can be in, fed
# to the reader as bytes. Absence is not a value here: a server with no stack, a
# stack that has never written a record, a record nobody can read and a record
# saying the last run failed are four different facts, and a status that
# reported them identically would be the decoration this rule exists not to be.
rec_now=2000000000
# state deadline next_run since started finished status repos
rec() {
    printf 'state=%s\nsince=%s\ndeadline=%s\nnext_run=%s\nlast_run_started=%s\nlast_run_finished=%s\nlast_run_status=%s\nlast_run_repos=%s\ntimeout=900\nat=02:00\njitter=42\n' \
        "$1" "$4" "$2" "$3" "$5" "$6" "$7" "$8"
}
record() { drive_stdin record "$1" "$2" "$rec_now"; }

# The healthy stack: a run that finished, said ok, and a scheduler still inside
# the deadline it wrote for itself.
ok_rec="$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' demo mail')"
out=$(record dir file <<<"$ok_rec")
assert 'grep -qxF "verdict=ok" <<<"$out"'          "a run that finished and succeeded reads ok (got '$out')"
assert 'grep -qxF "age=16400" <<<"$out"'           "with its age off the server's own clock (got '$out')"
assert 'grep -qxF "overdue=0" <<<"$out"'           "and nothing overdue (got '$out')"
assert 'grep -qxF "repos= demo mail" <<<"$out"'    "carrying which repositories it reached (got '$out')"

# The stack that has never fired. `last_run_started=0` and `last_run_status=-`
# are what templates/backup/backup.sh writes before any run — a different fact
# from a stack that stopped a month ago, and the plan's own watch-out.
out=$(record dir file <<<"$(rec sleeping 2000086400 2000082800 1999999000 0 0 - -)")
assert 'grep -qxF "verdict=never" <<<"$out"' \
    "a scheduler that has reported in and never run is 'never', not 'ok' and not 'failed' (got '$out')"
assert 'grep -qxF "age=" <<<"$out"' "with no age, because there is no run to date (got '$out')"

# A first run in progress is still 'never' — nothing has *finished* — and the
# state says one is under way.
out=$(record dir file <<<"$(rec running 2000003000 0 1999999900 1999999900 0 - -)")
assert 'grep -qxF "verdict=never" <<<"$out"'  "a first run in progress has no finished run yet (got '$out')"
assert 'grep -qxF "state=running" <<<"$out"'  "and says one is running (got '$out')"

# The failed run: the case check --server fails on.
out=$(record dir file <<<"$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 failed ' none')")
assert 'grep -qxF "verdict=failed" <<<"$out"' "a run that reported failure reads failed (got '$out')"
assert 'grep -qxF "overdue=0" <<<"$out"'      "inside its deadline, which is a different fact (got '$out')"

# The stack that stopped: the state it last recorded has outlived its own
# deadline. This is the question templates/backup/backup.sh's `health` verb asks
# of the same field, which is why there is one reader and not two.
out=$(record dir file <<<"$(rec sleeping 1999900000 1999896000 1999800000 1999780000 1999783600 ok ' demo')")
assert 'grep -qxF "verdict=overdue" <<<"$out"' \
    "a deadline in the past is a stack that stopped, however well its last run went (got '$out')"
assert 'grep -qxF "overdue=100000" <<<"$out"'  "with how far past (got '$out')"

# A wedged run: `running` that never came back. Same verdict, different state,
# and the state is what tells an operator which of the two it is.
out=$(record dir file <<<"$(rec running 1999990000 0 1999980000 1999980000 0 - -)")
assert 'grep -qxF "verdict=overdue" <<<"$out"' "a run that never returned is overdue too (got '$out')"
assert 'grep -qxF "state=running" <<<"$out"'   "and says so (got '$out')"

# Both at once: a failure is the concrete thing and is named first, with the
# deadline still reported so the message can carry both.
out=$(record dir file <<<"$(rec sleeping 1999900000 1999896000 1999800000 1999780000 1999783600 failed ' none')")
assert 'grep -qxF "verdict=failed" <<<"$out"'  "a failed run outranks the deadline (got '$out')"
assert 'grep -qxF "overdue=100000" <<<"$out"'  "which is still reported (got '$out')"

# Nothing to read, in the four shapes it comes in. None of them may be reported
# as a backup that ran, and none as one that failed.
out=$(record absent absent </dev/null)
assert 'grep -qxF "verdict=nostack" <<<"$out"' "no stack directory is its own state (got '$out')"
assert 'grep -qF "reason=is not there" <<<"$out"' "with the clause a reader prints (got '$out')"
out=$(record notdir absent </dev/null)
assert 'grep -qF "reason=exists and is not a directory" <<<"$out"' \
    "and a file where the stack belongs is a different one (got '$out')"
out=$(record dir absent </dev/null)
assert 'grep -qxF "verdict=norecord" <<<"$out"' \
    "a stack with no record has not started — not the same as one that stopped (got '$out')"
for fstate in empty unreadable notfile dir; do
    out=$(record dir "$fstate" </dev/null)
    assert 'grep -qxF "verdict=unreadable" <<<"$out"' \
        "a record that is $fstate is unreadable, never absent (got '$out')"
    assert '! grep -qxF "reason=" <<<"$out"' "and says which (got '$out')"
done
out=$(record dir file </dev/null)
assert 'grep -qxF "verdict=unreadable" <<<"$out"' \
    "a record whose bytes did not arrive is unreadable (got '$out')"

# Bytes that are not this record. A deadline is the one field the verdict rests
# on, so a record without a usable one is refused rather than judged.
out=$(record dir file <<<"nothing to see here")
assert 'grep -qxF "verdict=unparsed" <<<"$out"' "bytes that are not a record read as unparsed (got '$out')"
out=$(record dir file <<<"$(printf 'state=sleeping\ndeadline=soon\n')")
assert 'grep -qxF "verdict=unparsed" <<<"$out"' "and so does a deadline that is not a number (got '$out')"
out=$(record dir file <<<"$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 sideways ' demo')")
assert 'grep -qxF "verdict=unparsed" <<<"$out"' \
    "a last_run_status this kasbah does not know is not read as success (got '$out')"
assert 'grep -qF "sideways" <<<"$out"' "and is quoted back (got '$out')"

# A record a later kasbah wrote: fields this one has never heard of, and the
# frozen ones still read.
out=$(record dir file <<<"$(printf '%s\nlast_run_bytes=12345\nnew_field=whatever\n' "$ok_rec")")
assert 'grep -qxF "verdict=ok" <<<"$out"' "keys this kasbah does not know are ignored (got '$out')"
# CRLF, on the field that would carry it.
out=$(record dir file <<<"$(printf 'state=sleeping\r\ndeadline=2000086400\r\nlast_run_started=1999980000\r\nlast_run_finished=1999983600\r\nlast_run_status=ok\r\n')")
assert 'grep -qxF "verdict=ok" <<<"$out"' "a record with CRLF line endings still reads (got '$out')"

# The clock the record is judged by is the server's. A probe that answered with
# something that is not one falls back to this machine's rather than declining
# to judge — a deadline in 2033 is not overdue on either.
out=$(drive_stdin record dir file "not-a-clock" <<<"$ok_rec")
assert 'grep -qxF "verdict=ok" <<<"$out"' "a clock this kasbah cannot read does not stop the verdict (got '$out')"
assert 'grep -qxF "clock=local" <<<"$out"' \
    "but it is not silent about whose clock the verdict was measured on (got '$out')"
out=$(record dir file <<<"$ok_rec")
assert 'grep -qxF "clock=server" <<<"$out"' \
    "and the ordinary case says the server's, which is the one that wrote the record (got '$out')"
out=$(drive_stdin record dir file "not-a-clock" <<<"$(rec sleeping 1000000000 0 999000000 999000000 999003600 ok ' demo')")
assert 'grep -qxF "verdict=overdue" <<<"$out"' "and a 2001 deadline is still past (got '$out')"

# A deadline bash arithmetic refuses. `case $v in *[!0-9]*)` admits both of
# these and `$(( ))` then dies on them: `01999000009` is an invalid *octal*
# literal, which is a fatal arithmetic error that took `server status` down
# mid-report with exit 1 and no Projects section at all, and a digit string past
# 2^63 makes `[ -gt ]` answer "integer expression expected" and be silently
# false — so the record came out as a passing backup. `unparsed` is for exactly
# these, and the reader answers 1 for it.
for bad in 01999000009 999999999999999999999999 12x 1e9 -1 ' 2000086400'; do
    out=$(record dir file <<<"$(rec sleeping "$bad" 2000082800 1999990000 1999980000 1999983600 ok ' demo')" 2>&1)
    assert 'grep -qxF "verdict=unparsed" <<<"$out"' \
        "a deadline of '$bad' is refused, not judged (got '$out')"
    assert 'grep -qF "not a unix time this kasbah can compare" <<<"$out"' \
        "with the reason (deadline '$bad', got '$out')"
    assert '! grep -q "arithmetic\|integer expression\|value too great" <<<"$out"' \
        "and no shell arithmetic complaint escapes (deadline '$bad', got '$out')"
done
# The control, twice: the same record with a deadline bash can read is judged,
# and `0` is a real epoch the writer uses for "no next run yet".
out=$(record dir file <<<"$ok_rec")
assert 'grep -qxF "verdict=ok" <<<"$out"' "a usable deadline is still judged (got '$out')"
out=$(record dir file <<<"$(rec sleeping 2000086400 0 1999990000 1999980000 1999983600 ok ' demo')")
assert 'grep -qxF "verdict=ok" <<<"$out"' "and next_run=0 is a value, not a refusal (got '$out')"
# The other epoch fields go the same way, and a bad one there is not a verdict:
# only the deadline decides whether the record can be judged at all.
out=$(record dir file <<<"$(rec sleeping 2000086400 2000082800 1999990000 1999980000 007 ok ' demo')")
assert 'grep -qxF "verdict=ok" <<<"$out"' "a bad last_run_finished does not refuse the record (got '$out')"
assert 'grep -qxF "age=" <<<"$out"' "it just yields no age to print (got '$out')"

# The reader's exit status, which both callers capture. Bare, it would put a
# non-zero status on a `set -e` shell in the middle of a report.
out=$(record dir file <<<"$ok_rec")
assert 'grep -qxF "rc=0" <<<"$out"' "a record that was judged answers 0 (got '$out')"
for pair in "absent absent" "dir absent" "dir unreadable"; do
    out=$(record $pair </dev/null)
    assert 'grep -qxF "rc=1" <<<"$out"' "and one that could not be answers 1 ($pair, got '$out')"
done
out=$(record dir file <<<"$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 sideways ' demo')")
assert 'grep -qxF "rc=1" <<<"$out"' "as does a last_run_status this kasbah does not know (got '$out')"

# The humaniser every one of those lines is printed through.
assert 'grep -qxF "ago=45s" <<<"$(drive ago 45)"'          "seconds under a minute"
assert 'grep -qxF "ago=25m" <<<"$(drive ago 1500)"'        "minutes under an hour"
assert 'grep -qxF "ago=4h" <<<"$(drive ago 16400)"'        "hours under two days"
assert 'grep -qxF "ago=3 day(s)" <<<"$(drive ago 300000)"' "and days above that"
assert 'grep -qxF "ago=unknown" <<<"$(drive ago "")"' \
    "a field the record did not carry is 'unknown', never 0"

# --- The remote script, run locally ---------------------------------------------------
# Extracted from its heredoc and run against a fake apps tree — the only way to
# reach the project filter and the versions.log states without a server, and
# where "status changes nothing" is checked hermetically. The integration suite
# asks the same question of the rig.
payload="$tmpdir/remote.sh"
sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$repo_dir/lib/server_status.sh" | sed '1d;$d' > "$payload"
assert '[ -s "$payload" ]' "the remote script was extracted from lib/server_status.sh"
assert 'grep -qF "kv project_count" "$payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
# Enough docker to answer the status probe. Container counts come from the
# environment, one variable per project, so a case can put a project in any
# running/total state without a daemon.
case "$1 $2" in
    "version --format") printf '27.3.1\n'; exit 0 ;;
    "compose version")  printf '2.29.7\n'; exit 0 ;;
esac
if [ "$1" = inspect ]; then
    # Two compound formats first, by their shape: the per-project container list
    # (one line per id, however many ids it was given) and the mail stack's
    # three-facts-in-one-line. A container id ending in `-stopped` is down, and
    # one ending in `-sick` is up and unhealthy, so a case can put a project in
    # any per-container state without a daemon.
    case "$3" in
        *'{{.Name}} {{.State.Status}}'*)
            shift 3
            for cid in "$@"; do
                st=running; hl=healthy
                case "$cid" in
                    *-stopped) st=exited;  hl=none ;;
                    *-sick)    st=running; hl=unhealthy ;;
                esac
                printf '/%s %s %s\n' "$cid" "$st" "$hl"
            done
            exit 0 ;;
        *'{{.State.Status}} {{if .State.Health}}'*)
            # The mail containers and the backup scheduler come back through the
            # same compound format; the id says which stack is being asked
            # about, so a case can move one without moving the other.
            case "${!#}" in
                cid-kasbah-backup) printf '%s\n' "${STUB_BACKUP_INSPECT-running healthy 0}" ;;
                *)                 printf '%s\n' "${STUB_MAIL_INSPECT-running healthy 0}" ;;
            esac
            exit 0 ;;
    esac
    # Answers per container, not per question: the traefik project holds a
    # sidecar as well, and a probe that stopped filtering on the service label
    # would inspect that one instead.
    cid="${!#}"
    case "$3" in
        *'.State.Status'*) printf 'running\n' ;;
        *'.State.Health'*) printf 'healthy\n' ;;
        *'.Config.Image'*)
            case "$cid" in
                cid-traefik) printf 'traefik:v3.7.10\n' ;;
                *)           printf 'whoami:latest\n' ;;
            esac ;;
        *'.Image'*)        printf 'sha256:1111111111112222222222223333333333334444444444445555555555556666\n' ;;
        *'.Name'*)
            case "$cid" in
                cid-traefik) printf '/traefik\n' ;;
                *)           printf '/traefik-sidecar\n' ;;
            esac ;;
    esac
    exit 0
fi
if [ "$1" = ps ]; then
    project=""
    service=""
    all=no
    for a in "$@"; do
        case "$a" in
            -a) all=yes ;;
            label=com.docker.compose.project=*) project="${a#*project=}" ;;
            label=com.docker.compose.service=*) service="${a#*service=}" ;;
        esac
    done
    if [ "$project" = mail ]; then
        case "$service" in
            mail-dms)        printf '%s\n' "${STUB_MAIL_DMS-cid-mail-dms}" ;;
            mail-snappymail) printf '%s\n' "${STUB_MAIL_WEB-cid-mail-snappymail}" ;;
        esac
        exit 0
    fi
    if [ "$project" = kasbah-backup ]; then
        # The compose project and service templates/backup/compose.yml declares.
        # A probe that stopped filtering on the service label would find nothing
        # here, which is what the `absent` assertions are about.
        [ "$service" != backup ] || printf '%s\n' "${STUB_BACKUP_ID-cid-kasbah-backup}"
        exit 0
    fi
    if [ "$project" = traefik ]; then
        # Sidecar first, so the id a probe takes without the service filter is
        # the wrong one rather than the right one by luck.
        [ "$service" = traefik ] || printf 'cid-sidecar\n'
        printf '%s\n' "${STUB_TRAEFIK_ID-cid-traefik}"
        exit 0
    fi
    var="STUB_RUNNING_$project"
    [ "$all" = no ] || var="STUB_TOTAL_$project"
    n="${!var:-0}"
    i=0
    while [ "$i" -lt "$n" ]; do printf 'cid-%s-%s\n' "$project" "$i"; i=$((i + 1)); done
    exit 0
fi
exit 0
STUB
chmod 0755 "$stub_dir/docker"

# A prepared server with one deployed project, one project that has never been
# deployed, one whose log is empty, one whose last line is not an entry, a file
# where a directory would be, and every directory kasbah owns.
apps="$tmpdir/apps"
mkdir -p "$apps/.kasbah" "$apps/data/demo" "$apps/backups" "$apps/traefik/dynamic" \
         "$apps/mail" \
         "$apps/demo" "$apps/dropped" "$apps/emptylog" "$apps/badlog" "$apps/.git"
printf '{"kasbah_version":"0.1.0","apps_path":"%s","data_path":"%s/data","cpu_limit":"14.4","mem_limit":"54g"}\n' \
    "$apps" "$apps" > "$apps/.kasbah/server.json"
printf '2026-08-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n\n' \
    > "$apps/demo/versions.log"
: > "$apps/emptylog/versions.log"
printf 'just a note someone left\n' > "$apps/badlog/versions.log"
touch "$apps/not-a-dir"

# What the five additions are read out of: the dashboard fragment (the only
# record of the server's apex), one project fragment, the mail registry, and
# Traefik's certificate store under the *data* path the marker names.
cat > "$apps/traefik/dynamic/_shared.yml" <<'YML'
http:
  routers:
    traefik-dashboard:
      rule: "Host(`traefik.example.com`)"
      entryPoints: [websecure]
YML
cat > "$apps/traefik/dynamic/demo.yml" <<'YML'
http:
  routers:
    demo-http:
      rule: "Host(`demo.example.com`)"
      entryPoints: [web]
    demo:
      rule: "Host(`demo.example.com`) || Host(`www.demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
YML
cat > "$apps/mail/kasbah.yml" <<'YML'
name: mail
primary_domain: example.com
domains:
  - example.com
  - other.example
YML
mkdir -p "$apps/data/traefik/letsencrypt"
printf '{"letsencrypt":{"Account":{"PrivateKey":"c3VwZXItc2VjcmV0"},"Certificates":[]}}' \
    > "$apps/data/traefik/letsencrypt/acme.json"

# The backup stack as `server init --with-backup` leaves it: the runner's
# last-run record, one password file per repository, and the client record
# `kasbah deploy` writes beside a project. The password *file* is here rather
# than only its name, because the probe must be seen reporting the name and not
# the contents.
mkdir -p "$apps/.kasbah/backup/state" "$apps/.kasbah/backup/repos"
printf 'state=sleeping\nsince=1756180000\ndeadline=1756270000\nnext_run=1756268000\nlast_run_started=1756179000\nlast_run_finished=1756179600\nlast_run_status=ok\nlast_run_repos= demo mail\ntimeout=900\nat=02:00\njitter=42\n' \
    > "$apps/.kasbah/backup/state/status"
printf 'THIS-IS-A-REPOSITORY-PASSWORD\n' > "$apps/.kasbah/backup/repos/demo.pass"
printf 'demo\n' > "$apps/demo/.kasbah-client"

# Type, mode, size and mtime of everything, plus the bytes of every file: the
# probe below must move none of it.
tree_digest() {
    { find "$1" -printf '%y %m %s %T@ %p\n' | sort
      find "$1" -type f -exec sha256sum {} + | sort; } | sha256sum
}
before="$(tree_digest "$apps")"

# run_payload <apps-path-flag> [VAR=value ...] — the four arguments the step
# takes: what --apps-path said (empty when it was not given), the default, the
# pointer, and the reserved names. $POINTER_FILE overrides the third, so a case
# can put a pointer anywhere but /etc.
run_payload() {
    local apps_path="$1"; shift
    env PATH="$stub_dir:$PATH" STUB_TOTAL_demo=2 STUB_RUNNING_demo=1 "$@" \
        bash "$payload" "$apps_path" "$apps" "${POINTER_FILE:-$tmpdir/no-such-pointer}" \
             " .kasbah mail data backups traefik "
}
probe_out="$(run_payload "$apps" 2>"$tmpdir/perr")"; probe_rc=$?
assert '[ "$probe_rc" = "0" ]' "the remote script exits 0 on a prepared tree (exit $probe_rc: $(cat "$tmpdir/perr"))"
assert '[ "$(tree_digest "$apps")" = "$before" ]' \
    "and changed nothing — no file created, removed, rewritten or touched"

# The digest is only evidence if it can tell. One touch on one file must break it.
touch "$apps/demo/versions.log"
assert '[ "$(tree_digest "$apps")" != "$before" ]' \
    "the tree digest notices a bare touch — else the read-only assertion above proves nothing"
before="$(tree_digest "$apps")"

fact() { sed -n "s/^$1=//p" <<<"$probe_out"; }
assert '[ "$(fact have_docker)" = "yes" ]'      "have_docker (got '$(fact have_docker)')"
assert '[ "$(fact docker_server)" = "27.3.1" ]' "the daemon version (got '$(fact docker_server)')"
assert '[ "$(fact compose_version)" = "2.29.7" ]' "the compose version (got '$(fact compose_version)')"
assert '[ "$(fact apps_state)" = "dir" ]'       "the apps path is a directory (got '$(fact apps_state)')"
assert '[ "$(fact marker_state)" = "ok" ]'      "the marker is readable (got '$(fact marker_state)')"
assert '[ "$(printf "%s" "$(fact marker_b64)" | base64 -d)" = "$(cat "$apps/.kasbah/server.json")" ]' \
    "and comes back byte for byte, so the parsing happens on this side"
assert '[ "$(fact traefik_present)" = "yes" ]'  "Traefik is found by its compose labels (got '$(fact traefik_present)')"
assert '[ "$(fact traefik_health)" = "healthy" ]' "with its health (got '$(fact traefik_health)')"
# Both labels, not just the project: the stub's traefik project also holds a
# sidecar, and it is the one a probe filtering on the project alone would pick.
assert '[ "$(fact traefik_image)" = "traefik:v3.7.10" ]' \
    "the container found is the traefik *service*, not the first one in the project (got '$(fact traefik_image)')"
assert '[ "$(fact traefik_container)" = "traefik" ]' \
    "and it is named for it (got '$(fact traefik_container)')"

# --- what the one probe brings back for the five additions --------------------
# The data path first: there is no jq on the far side, so the probe scrapes it
# out of the marker's bytes and the caller checks the scrape against jq. Every
# read below that is not under the apps path hangs off this one value.
assert '[ "$(fact probe_data_path)" = "$apps/data" ]' \
    "the data path is scraped out of the marker without a JSON parser (got '$(fact probe_data_path)')"
assert '[ "$(fact acme_state)" = "file" ]' "the certificate store is found under it (got '$(fact acme_state)')"
assert '[ "$(printf "%s" "$(fact acme_b64)" | base64 -d)" = "$(cat "$apps/data/traefik/letsencrypt/acme.json")" ]' \
    "and comes back byte for byte — there is no jq on the VPS to read it there"
assert '[ "$(fact shared_state)" = "file" ]' "the dashboard fragment is read (got '$(fact shared_state)')"
assert '[ "$(fact mail_dir_state)" = "dir" ]' "the mail stack is found (got '$(fact mail_dir_state)')"
assert '[ "$(fact mail_registry_state)" = "file" ]' "with its registry (got '$(fact mail_registry_state)')"
assert '[ "$(fact mail_dms_state)" = "running" ]' \
    "mail-dms is found by its compose labels, not by container name (got '$(fact mail_dms_state)')"
assert '[ "$(fact mail_dms_health)" = "healthy" ]' "with its health (got '$(fact mail_dms_health)')"
assert '[ "$(fact mail_dms_restarts)" = "0" ]' \
    "and its restart count — a DMS with no certificate restarts forever (got '$(fact mail_dms_restarts)')"
assert '[ "$(fact mail_web_state)" = "running" ]' "and so is mail-snappymail (got '$(fact mail_web_state)')"
# The backup stack, in the same one probe. The password file's *name* travels
# and its bytes never do — a probe that shipped the repository passwords back
# would be shipping the only thing standing between a stolen snapshot and its
# contents.
assert '[ "$(fact backup_dir_state)" = "dir" ]' "the backup stack directory is found (got '$(fact backup_dir_state)')"
assert '[ "$(fact backup_status_state)" = "file" ]' "with its last-run record (got '$(fact backup_status_state)')"
assert '[ "$(printf "%s" "$(fact backup_status_b64)" | base64 -d)" = "$(cat "$apps/.kasbah/backup/state/status")" ]' \
    "which comes back byte for byte — the VPS has no parser and none is wanted there"
assert '[ "$(fact backup_haspass)" = "demo" ]' \
    "the repositories holding a password are named (got '$(fact backup_haspass)')"
assert '! grep -q "THIS-IS-A-REPOSITORY-PASSWORD" <<<"$probe_out"' \
    "and no password itself is in the payload"
assert 'grep -qF "demo=demo" <<<"$(fact backup_projects)"' \
    "the project/client list carries the .kasbah-client record kasbah deploy writes (got '$(fact backup_projects)')"
assert 'grep -qF "dropped=" <<<"$(fact backup_projects)"' \
    "and a project with no record is listed with an empty client, not dropped (got '$(fact backup_projects)')"
assert '[ "$(fact backup_c_state)" = "running" ]' \
    "the scheduler is found by its compose labels (got '$(fact backup_c_state)')"
assert '[ "$(fact backup_c_health)" = "healthy" ]' \
    "with the health its own healthcheck reports (got '$(fact backup_c_health)')"
assert '[ -n "$(fact now)" ] && [ "$(fact now)" -gt 1700000000 ] 2>/dev/null' \
    "and the server's own clock, which every epoch in the record is written by (got '$(fact now)')"
assert '[ "$(fact apps_df_state)" = "ok" ]' "df answered for the apps path (got '$(fact apps_df_state)')"
apps_df_line="$(printf '%s' "$(fact apps_df_b64)" | base64 -d)"
assert '[ -n "$apps_df_line" ]' "and its line came back (got '$apps_df_line')"
assert '[ "$(set -- $apps_df_line; printf %s "$2")" -gt 0 ] 2>/dev/null' \
    "with a block count in it, so it is a df line and not a header (got '$apps_df_line')"
assert '[ "$(fact data_df_state)" = "ok" ]' "and for the data path (got '$(fact data_df_state)')"

# The list of projects and their effective clients decides which repositories
# this server has — the question `server init --with-backup` asks the same tree
# when it decides how many passwords to prompt for. Two payloads answering it
# two ways is how a status would name a repository init never created, so the
# two are run against one tree and their answers compared.
#
# `buf ~ /backup_projects=/` picks the block out of each file by what it emits:
# lib/backup.sh has five REMOTE heredocs and only one of them is this read.
bk_read_payload="$tmpdir/bk_read.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /backup_projects=/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/backup.sh" > "$bk_read_payload"
assert '[ -s "$bk_read_payload" ]' "lib/backup.sh's own read payload was found"
bk_out=$(bash "$bk_read_payload" "$apps" "$apps/data" " .kasbah mail data backups traefik " 2>&1)
bk_projects=$(sed -n 's/^backup_projects=//p' <<<"$bk_out")
assert '[ -n "$bk_projects" ]' "and it lists this tree's projects (got '$bk_projects')"
assert '[ "$(fact backup_projects)" = "$bk_projects" ]' \
    "status and server init read one tree the same way
        status:      '$(fact backup_projects)'
        server init: '$bk_projects'"
# The pin is only evidence if it can tell: a client record neither reads the
# same way as one nobody wrote.
printf 'MAIL\n' > "$apps/demo/.kasbah-client"
bk_out=$(bash "$bk_read_payload" "$apps" "$apps/data" " .kasbah mail data backups traefik " 2>&1)
probe_out="$(run_payload "$apps" 2>/dev/null)"
assert '[ "$(fact backup_projects)" = "$(sed -n "s/^backup_projects=//p" <<<"$bk_out")" ]' \
    "including a record that is not a repository name, which both refuse as '?'
        status:      '$(fact backup_projects)'
        server init: '$(sed -n "s/^backup_projects=//p" <<<"$bk_out")'"
assert 'grep -qF "demo=?" <<<"$(fact backup_projects)"' \
    "and it really is refused rather than passed on (got '$(fact backup_projects)')"
# The other half of the same rule, and the half a charset mutation cannot reach:
# a record naming a directory kasbah owns is a valid *name* and still refused,
# because filing a project into the mail repository puts one client's data in
# with every mailbox on the server. Both payloads carry the reserved list as an
# argument, and this is what pins them to agreeing about it.
printf 'mail\n' > "$apps/demo/.kasbah-client"
bk_out=$(bash "$bk_read_payload" "$apps" "$apps/data" " .kasbah mail data backups traefik " 2>&1)
probe_out="$(run_payload "$apps" 2>/dev/null)"
assert 'grep -qF "demo=?" <<<"$(fact backup_projects)"' \
    "a client naming a reserved directory is refused (got '$(fact backup_projects)')"
assert '[ "$(fact backup_projects)" = "$(sed -n "s/^backup_projects=//p" <<<"$bk_out")" ]' \
    "by both payloads, out of the one reserved list they are both handed
        status:      '$(fact backup_projects)'
        server init: '$(sed -n "s/^backup_projects=//p" <<<"$bk_out")'"
printf 'demo\n' > "$apps/demo/.kasbah-client"
probe_out="$(run_payload "$apps" 2>/dev/null)"
before="$(tree_digest "$apps")"

# A mail stack that is scaffolded and not running, and one that was never
# scaffolded: both ordinary states, neither a fault.
probe_out="$(run_payload "$apps" STUB_MAIL_DMS= 2>/dev/null)"
assert '[ "$(fact mail_dms_state)" = "absent" ]' \
    "a mail stack whose DMS is not running says absent (got '$(fact mail_dms_state)')"
assert '[ "$(fact mail_web_state)" = "running" ]' \
    "and the other container is still reported (got '$(fact mail_web_state)')"
probe_out="$(run_payload "$tmpdir/nowhere" 2>/dev/null)"
assert '[ "$(fact mail_dir_state)" = "absent" ]' \
    "a server with no mail directory reports absent, not an error (got '$(fact mail_dir_state)')"
assert '[ "$(fact acme_state)" = "nopath" ]' \
    "and with no marker there is no data path to look for a store under (got '$(fact acme_state)')"
assert '[ "$(fact apps_df_state)" = "absent" ]' \
    "df is not asked about a path that is not there (got '$(fact apps_df_state)')"
probe_out="$(run_payload "$apps" 2>/dev/null)"

# The fragment and the container list travel per project, in the same row.
decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
demo_row="$(grep -F "$(printf %s demo | base64 -w0) " <<<"$decoded")"
assert '[ -n "$demo_row" ]' "demo has a row (rows: $decoded)"
assert '[ "$(set -- $demo_row; printf %s "$6")" = "ok" ]' \
    "carrying the state of its Traefik fragment (row: $demo_row)"
assert '[ "$(set -- $demo_row; printf %s "$7" | base64 -d)" = "$(cat "$apps/traefik/dynamic/demo.yml")" ]' \
    "and the fragment itself, byte for byte — yq stays off the VPS"
demo_conts="$(set -- $demo_row; printf %s "$8" | base64 -d)"
assert '[ "$(wc -l <<<"$demo_conts")" = "2" ]' \
    "with one line per container of the project (got '$demo_conts')"
assert 'grep -q " running healthy$" <<<"$demo_conts"' \
    "each carrying its state and health (got '$demo_conts')"
# A project with no fragment: the field is a `-`, not an empty column. An empty
# one would collapse under the reader's whitespace split and shift every field
# after it.
dropped_row="$(grep -F "$(printf %s dropped | base64 -w0) " <<<"$decoded")"
assert '[ "$(set -- $dropped_row; printf %s "$6")" = "absent" ]' \
    "a project with no fragment says absent (row: $dropped_row)"
assert '[ "$(set -- $dropped_row; printf %s "$7")" = "-" ]' \
    "and its empty fields are sentinels, not blanks (row: $dropped_row)"
assert '[ "$(set -- $dropped_row; printf %s "$#")" = "8" ]' \
    "so every row is eight fields wide whatever is missing (row: $dropped_row)"

# The filter: six candidates, and not one of kasbah's own five directories —
# `mail` among them, so the far-side filter runs against the same list the
# workstation sends in production (pinned separately at the ssh log below).
assert '[ "$(fact project_count)" = "6" ]' \
    "six candidates under a tree of eleven entries (got '$(fact project_count)')"
decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
names=""
while IFS=' ' read -r nb total running logstate logb64 fragstate fragb64 contb64; do
    [ -n "$nb" ] || continue
    names="$names$(printf '%s' "$nb" | base64 -d) $total/$running/$logstate
"
done <<<"$decoded"
for reserved in data backups traefik mail .kasbah; do
    assert '! grep -q "^$reserved " <<<"$names"' \
        "$reserved is kasbah's own directory, not a project (rows: $(tr '\n' ' ' <<<"$names"))"
done
assert 'grep -q "^demo 2/1/ok" <<<"$names"' \
    "demo is listed with its container counts and a readable log (rows: $(tr '\n' ' ' <<<"$names"))"
assert 'grep -q "^dropped 0/0/missing" <<<"$names"' \
    "a directory with no versions.log is a state, not a crash (rows: $(tr '\n' ' ' <<<"$names"))"
assert 'grep -q "^emptylog 0/0/empty" <<<"$names"' \
    "an empty versions.log is its own state (rows: $(tr '\n' ' ' <<<"$names"))"
assert 'grep -q "^badlog 0/0/ok" <<<"$names"' \
    "a log with an unparseable last line still reports as read (rows: $(tr '\n' ' ' <<<"$names"))"
assert 'grep -q "^not-a-dir 0/0/notdir" <<<"$names"' \
    "a file where a project directory belongs is reported as one (rows: $(tr '\n' ' ' <<<"$names"))"
# Everything under the apps path that is not kasbah's own is listed, including
# a directory no deploy could have made: a name rule cannot tell a stray from a
# project deployed by a kasbah whose rules differ, and a status that hides
# what it does not recognise is the one thing worse than noise.
assert 'grep -q "^.git 0/0/missing" <<<"$names"' \
    "a directory kasbah did not create is shown, not hidden (rows: $(tr '\n' ' ' <<<"$names"))"

# The last *entry*, not the last byte: demo's log ends in a blank line.
demo_log="$(while IFS=' ' read -r nb total running logstate logb64 fragstate fragb64 contb64; do
    [ "$(printf '%s' "$nb" | base64 -d)" = demo ] || continue
    printf '%s' "$logb64" | base64 -d
done <<<"$decoded")"
assert '[ "$demo_log" = "2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-" ]' \
    "the newest entry is the one reported, past a trailing blank line (got '$demo_log')"

# What a mixed-ownership deploy leaves behind: a log this user cannot read, and
# a directory this user cannot enter. Both answer "is there a versions.log" with
# "no" — the same answer a project that has never been deployed gives — so each
# has to be a state of its own.
if [ "$(id -u)" = 0 ]; then
    echo "note: running as root, so the unreadable-log cases are skipped (mode 000 does not stop root)" >&2
else
    mkdir -p "$apps/lockedlog" "$apps/lockeddir"
    printf '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' > "$apps/lockedlog/versions.log"
    chmod 000 "$apps/lockedlog/versions.log"
    printf '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' > "$apps/lockeddir/versions.log"
    chmod 000 "$apps/lockeddir"
    probe_out="$(run_payload "$apps" 2>"$tmpdir/perr")"; probe_rc=$?
    decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
    states=""
    while IFS=' ' read -r nb total running logstate logb64 fragstate fragb64 contb64; do
        [ -n "$nb" ] || continue
        states="$states$(printf '%s' "$nb" | base64 -d) $logstate
"
    done <<<"$decoded"
    assert '[ "$probe_rc" = "0" ]' "an unreadable log is not fatal to the probe (exit $probe_rc)"
    assert 'grep -q "^lockedlog unreadable$" <<<"$states"' \
        "a versions.log this user cannot read is 'unreadable', never 'empty' (states: $(tr '\n' ' ' <<<"$states"))"
    assert 'grep -q "^lockeddir noaccess$" <<<"$states"' \
        "a project directory this user cannot enter says so (states: $(tr '\n' ' ' <<<"$states"))"
    assert '[ ! -s "$tmpdir/perr" ]' \
        "and neither leaks the shell's own complaint into the operator's stderr (said '$(cat "$tmpdir/perr")')"
    chmod 755 "$apps/lockeddir"
    chmod 644 "$apps/lockedlog/versions.log"
    rm -rf "$apps/lockedlog" "$apps/lockeddir"
fi
before="$(tree_digest "$apps")"

# A log whose last line has no newline after it — what a killed write leaves.
printf '2026-08-14T00:00:00+00:00 deploy 1.1.0 no-backup kasbah=0.1.0 digest=-' >> "$apps/demo/versions.log"
probe_out="$(run_payload "$apps" 2>/dev/null)"
decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
demo_log="$(while IFS=' ' read -r nb total running logstate logb64 fragstate fragb64 contb64; do
    [ "$(printf '%s' "$nb" | base64 -d)" = demo ] || continue
    printf '%s' "$logb64" | base64 -d
done <<<"$decoded")"
assert '[ "$demo_log" = "2026-08-14T00:00:00+00:00 deploy 1.1.0 no-backup kasbah=0.1.0 digest=-" ]' \
    "a final line with no trailing newline is still read (got '$demo_log')"
# The fixture just changed on purpose; the read-only baseline moves with it.
before="$(tree_digest "$apps")"

# An apps path that is not there at all, and a Traefik that is not running:
# neither is a crash, and neither may be created on the way past.
probe_out="$(run_payload "$tmpdir/nowhere" STUB_TRAEFIK_ID= 2>/dev/null)"; probe_rc=$?
assert '[ "$probe_rc" = "0" ]'                    "a missing apps path is reported, not fatal (exit $probe_rc)"
assert '[ "$(fact apps_state)" = "absent" ]'      "as apps_state=absent (got '$(fact apps_state)')"
assert '[ "$(fact marker_state)" = "absent" ]'    "with no marker (got '$(fact marker_state)')"
assert '[ "$(fact project_count)" = "0" ]'        "and no projects (got '$(fact project_count)')"
assert '[ "$(fact traefik_present)" = "no" ]'     "Traefik absent is a value, not an error (got '$(fact traefik_present)')"
assert '[ ! -e "$tmpdir/nowhere" ]'               "and looking at a path that does not exist did not create it"

# No docker at all: every key still arrives, so the caller's protocol check
# passes and the *output* is what says docker did not answer. The PATH below
# carries only the two binaries the script pipes data through, so a missing
# docker is the single difference from the run above.
nodocker="$tmpdir/nodocker"
mkdir -p "$nodocker"
for bin in tr openssl; do ln -sf "$(command -v "$bin")" "$nodocker/$bin"; done
probe_out="$(env PATH="$nodocker" "$BASH" "$payload" "$apps" "$apps" "$tmpdir/no-such-pointer" " .kasbah mail data backups traefik " 2>/dev/null)"
assert '[ "$(fact have_docker)" = "no" ]'      "no docker on the remote is reported (got '$(fact have_docker)')"
assert '[ -n "$(fact docker_error)" ]'         "with the error it gave (got '$(fact docker_error)')"
assert '[ "$(fact traefik_present)" = "no" ]'  "and Traefik unknown rather than assumed (got '$(fact traefik_present)')"
assert '[ "$(fact project_count)" = "6" ]'     "the projects are still listed — they are directories, not containers (got '$(fact project_count)')"
assert '[ "$(tree_digest "$apps")" = "$before" ]' "and still nothing was written"

# --- Where the remote script decides to look ------------------------------------------
# The resolution itself, in the script that does it: one round trip covers the
# pointer and everything read out of the tree it names, so the choice is made on
# the far side and reported back. The second tree below is a *different* server
# — reading the wrong one is the failure this exists to prevent.
alt_apps="$tmpdir/altapps"
mkdir -p "$alt_apps/.kasbah" "$alt_apps/altproj"
printf '{"kasbah_version":"0.1.0","apps_path":"%s","data_path":"%s/store","cpu_limit":"1.0","mem_limit":"2g"}\n' \
    "$alt_apps" "$alt_apps" > "$alt_apps/.kasbah/server.json"
POINTER_FILE="$tmpdir/pointer"

rm -f "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact apps_path)" = "$apps" ]'      "with no flag and no pointer, the default (got '$(fact apps_path)')"
assert '[ "$(fact apps_source)" = "default" ]'  "reported as such (got '$(fact apps_source)')"
assert '[ "$(fact pointer_state)" = "absent" ]' "and the pointer as absent (got '$(fact pointer_state)')"

printf '%s\n' "$alt_apps" > "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact apps_path)" = "$alt_apps" ]'  "a pointer steers the whole read (got '$(fact apps_path)')"
assert '[ "$(fact apps_source)" = "pointer" ]'  "reported as such (got '$(fact apps_source)')"
assert '[ "$(fact pointer_value)" = "$alt_apps" ]' "with what it holds (got '$(fact pointer_value)')"
assert '[ "$(printf "%s" "$(fact marker_b64)" | base64 -d)" = "$(cat "$alt_apps/.kasbah/server.json")" ]' \
    "the marker read is the pointed-at tree's, not the default one's"
decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
assert 'grep -qF "$(printf %s altproj | base64 -w0)" <<<"$decoded"' \
    "and so is the project list (rows: $decoded)"

# The flag outranks it, and is the escape hatch for a pointer that is wrong.
probe_out="$(run_payload "$apps" 2>/dev/null)"
assert '[ "$(fact apps_path)" = "$apps" ]'   "--apps-path outranks the pointer (got '$(fact apps_path)')"
assert '[ "$(fact apps_source)" = "flag" ]'  "reported as such (got '$(fact apps_source)')"
assert '[ "$(fact pointer_value)" = "$alt_apps" ]' \
    "and the pointer is still reported, so the caller can say the two disagree (got '$(fact pointer_value)')"

# A file a human edited, and one that holds nothing usable. The second is
# reported rather than resolved: falling back to the default here would describe
# a different server, and only the caller can refuse.
printf '%s  \r\n' "$alt_apps" > "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact apps_path)" = "$alt_apps" ]' \
    "a CRLF pointer with trailing blanks still resolves (got '$(fact apps_path)')"
printf 'srv/apps\n' > "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact pointer_value)" = "srv/apps" ]' "a relative pointer is reported (got '$(fact pointer_value)')"
assert '[ "$(fact apps_source)" = "default" ]'    "and not resolved (got '$(fact apps_source)')"
# Exactly `/` is not an apps path: it would make the marker path /.kasbah/…,
# a tree nothing prepared. The probe resolves nothing and reports what it holds,
# and the refusal happens on the caller's side.
printf '/\n' > "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact pointer_value)" = "/" ]' "a pointer of '/' is reported (got '$(fact pointer_value)')"
assert '[ "$(fact apps_source)" = "default" ]' "and resolves nothing (got '$(fact apps_source)')"
assert '[ "$(fact apps_path)" = "$apps" ]' "the read stays on the default (got '$(fact apps_path)')"

# Every spelling of one tree is one tree, and a trailing tab is not part of a
# path — `kv` trims trailing spaces off what it reports, which is not the same
# thing as the value the comparison uses.
while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    printf '%s\n' "$alt_apps$spelling" > "$POINTER_FILE"
    probe_out="$(run_payload "" 2>/dev/null)"
    assert '[ "$(fact apps_path)" = "$alt_apps" ]' \
        "a pointer spelled with '$spelling' resolves to the one path (got '$(fact apps_path)')"
    assert '[ "$(fact pointer_value)" = "$alt_apps" ]' \
        "and is reported normalised, which is what init's value is compared against (got '$(fact pointer_value)')"
done <<'CASES'
/
/.
//
CASES
printf '%s\t\n' "$alt_apps" > "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact pointer_value)" = "$alt_apps" ]' \
    "a trailing tab is taken off, not merely hidden by the reporter (got '$(fact pointer_value)')"

# A pointer behind a directory this user cannot enter reads as absent to
# `[ -e ]`, and absent means "read /apps" — which may be a different server.
locked_dir="$tmpdir/lockedetc"
mkdir -p "$locked_dir"
printf '%s\n' "$alt_apps" > "$locked_dir/apps-path"
chmod 000 "$locked_dir"
if [ ! -x "$locked_dir" ]; then
    probe_out="$(POINTER_FILE="$locked_dir/apps-path" run_payload "" 2>/dev/null)"
    assert '[ "$(fact pointer_state)" = "unreachable" ]' \
        "an unenterable pointer directory is its own state, not 'absent' (got '$(fact pointer_state)')"
else
    assert 'true' "skipped: this user can enter a mode-000 directory"
fi
chmod 755 "$locked_dir"; rm -rf "$locked_dir"

printf '%s\n' "$alt_apps" > "$POINTER_FILE"
chmod 000 "$POINTER_FILE"
if [ ! -r "$POINTER_FILE" ]; then
    probe_out="$(run_payload "" 2>/dev/null)"
    assert '[ "$(fact pointer_state)" = "unreadable" ]' \
        "a pointer this user cannot read is its own state, not an empty one (got '$(fact pointer_state)')"
    assert '[ "$(fact apps_source)" = "default" ]' "and it resolved nothing (got '$(fact apps_source)')"
else
    assert 'true' "skipped: this user can read a mode-000 file"
fi
chmod 644 "$POINTER_FILE"
rm -f "$POINTER_FILE"; mkdir -p "$POINTER_FILE"
probe_out="$(run_payload "" 2>/dev/null)"
assert '[ "$(fact pointer_state)" = "notfile" ]' \
    "a directory where the pointer belongs is its own state (got '$(fact pointer_state)')"
rmdir "$POINTER_FILE"
unset POINTER_FILE

# --- The command, with a stub ssh --------------------------------------------------
# The stub answers the reachability probe and hands the one remote step whatever
# protocol block the case wrote, so every state below — an unhealthy Traefik, a
# marker that is not JSON, a truncated report — is reachable without a server.
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
[ -z "${SSH_STEP_RC:-}" ] || exit "$SSH_STEP_RC"
cat "$SSH_PAYLOAD"
STUB
chmod 0755 "$stub_dir/ssh"

mkdir -p "$tmpdir/home"
status_cli() {
    : > "$ssh_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_PAYLOAD="$payload_file" \
        "$repo_dir/bin/kasbah" server status "$@" 2>&1
}

# A server with one project, written as the remote step writes it.
marker_default='{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'

# A real certificate, because the certificate lines are read out of one:
# lib/acme.sh base64-decodes the store's entry and hands the PEM to
# `openssl x509`, so a fixture that is not a certificate would exercise the
# refusals and never the verdict.
cert_dir="$tmpdir/cert"
mkdir -p "$cert_dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
    -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
    -subj "/CN=demo.example.com" \
    -addext "subjectAltName=DNS:demo.example.com,DNS:www.demo.example.com" >/dev/null 2>&1
cert_b64="$(base64 -w0 < "$cert_dir/cert.pem")"
assert '[ -n "$cert_b64" ]' "openssl made a certificate for the store fixture"
# The store as Traefik writes it, private key material included: the account
# key and the entry's own `.key` are here precisely so the redaction assertions
# below have something real to fail against.
acme_json="$(jq -cn --arg c "$cert_b64" '{letsencrypt:{Account:{Email:"a@example.com",PrivateKey:"TUlHSEFnRUFNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VI"},Certificates:[{domain:{main:"demo.example.com",sans:["www.demo.example.com"]},certificate:$c,key:"TUlHSEFnRUFNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VI"}]}}')"
assert '[ -n "$acme_json" ] && jq -e . >/dev/null 2>&1 <<<"$acme_json"' "the certificate store fixture is JSON"
acme_b64_default="$(printf '%s' "$acme_json" | base64 -w0)"

shared_yml='http:
  routers:
    traefik-dashboard:
      rule: "Host(`traefik.example.com`)"'
demo_frag='http:
  routers:
    demo-http:
      rule: "Host(`demo.example.com`)"
    demo:
      rule: "Host(`demo.example.com`) || Host(`www.demo.example.com`)"'
registry_yml='name: mail
primary_domain: example.com
domains:
  - example.com
  - other.example'
df_apps='/dev/sda1 41152812 12345678 26906134 32% /'
write_payload() {
    local marker_state="${1:-ok}" marker_json="${2:-$marker_default}"
    local traefik_present="${3:-yes}" traefik_state="${4:-running}" traefik_health="${5:-healthy}"
    local rows="${6-$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-' ok "$demo_frag" "$(cont demo-web running healthy)")}"
    local count="${7-1}"
    {
        # Where the step looked, and how it got there: a server with no pointer,
        # read at the default. `payload_set` puts a case into any other state.
        printf 'pointer_state=absent\npointer_value=\n'
        printf 'apps_path=/apps\napps_source=default\n'
        printf 'have_docker=yes\ndocker_server=27.3.1\ndocker_error=\ncompose_version=2.29.7\n'
        printf 'apps_state=dir\n'
        printf 'marker_state=%s\n' "$marker_state"
        printf 'marker_b64=%s\n' "$(printf '%s' "$marker_json" | base64 -w0)"
        # The five additions, in the same one payload: the data path the probe
        # scraped, the two df lines, the certificate store, the dashboard
        # fragment and the mail stack.
        printf 'probe_data_path=/apps/data\n'
        printf 'apps_df_state=ok\napps_df_b64=%s\n' "$(printf '%s' "$df_apps" | base64 -w0)"
        printf 'data_df_state=ok\ndata_df_b64=%s\n' "$(printf '%s' "$df_apps" | base64 -w0)"
        printf 'acme_state=file\nacme_b64=%s\n' "$acme_b64_default"
        printf 'shared_state=file\nshared_b64=%s\n' "$(printf '%s' "$shared_yml" | base64 -w0)"
        printf 'mail_dir_state=dir\n'
        printf 'mail_registry_state=file\nmail_registry_b64=%s\n' "$(printf '%s' "$registry_yml" | base64 -w0)"
        printf 'mail_dms_state=running\nmail_dms_health=healthy\nmail_dms_restarts=0\n'
        printf 'mail_web_state=running\nmail_web_health=healthy\nmail_web_restarts=0\n'
        # The backup stack, and by default a server that has none: `Backup: not
        # configured` is what the default marker above describes, and every
        # other state is reached by moving these keys and the marker together.
        # Written *after* shared_b64 on purpose — the protocol diagnostic clips
        # at twenty lines, and a key inserted above acme_b64 would push it out
        # of that window and make the redaction assertions below vacuous.
        printf 'backup_dir_state=%s\n' "${BK_DIR_STATE:-absent}"
        printf 'backup_status_state=%s\n' "${BK_STATUS_STATE:-absent}"
        printf 'backup_status_b64=%s\n' "$(printf '%s' "${BK_RECORD:-}" | base64 -w0)"
        printf 'backup_c_state=%s\nbackup_c_health=%s\nbackup_c_restarts=%s\n' \
            "${BK_C_STATE:-absent}" "${BK_C_HEALTH:-}" "${BK_C_RESTARTS:-}"
        printf 'backup_haspass=%s\n' "${BK_HASPASS-demo}"
        printf 'backup_projects=%s\n' "${BK_PROJECTS-demo=}"
        printf 'now=%s\n' "${BK_NOW:-2000000000}"
        printf 'traefik_present=%s\ntraefik_state=%s\ntraefik_health=%s\n' \
            "$traefik_present" "$traefik_state" "$traefik_health"
        printf 'traefik_image=traefik:v3.7.10\ntraefik_image_id=sha256:abcdef0123456789\ntraefik_container=traefik\n'
        printf 'project_count=%s\n' "$count"
        printf 'projects_b64=%s\n' "$(printf '%s' "$rows" | base64 -w0)"
    } > "$payload_file"
}

# One key of the last-written payload, replaced. Everything the remote step can
# report but a rig cannot be put into on demand is reached this way.
payload_set() {
    local key="${1%%=*}"
    grep -v "^$key=" "$payload_file" > "$payload_file.next"
    printf '%s\n' "$1" >> "$payload_file.next"
    mv "$payload_file.next" "$payload_file"
}

write_payload
out=$(status_cli deploy@vps); rc=$?
[ -z "${SS_DUMP:-}" ] || printf '%s\n' "$out" > "$SS_DUMP"
assert '[ "$rc" = "0" ]' "a prepared server reports and exits 0 (exit $rc: $out)"
assert 'grep -qF "Docker: 27.3.1, Compose: 2.29.7" <<<"$out"' "the two versions (said '$out')"
assert 'grep -qF "Traefik: running (healthy)" <<<"$out"'      "Traefik's state and health (said '$out')"
assert 'grep -qF "traefik:v3.7.10" <<<"$out"'                 "the image it runs (said '$out')"
assert 'grep -qE "^  demo +1/1 running +1\.0\.0 +deploy 2026-08-13T22:30:37\+00:00 \(kasbah 0\.1\.0-dev\)$" <<<"$out"' \
    "and the project row: name, state, version, last entry (said '$out')"
assert '[ "$(grep -c "bash. .-s" "$ssh_log")" = "1" ]' \
    "one remote step, not one per fact (ssh saw: $(cat "$ssh_log"))"
# Still one, with five more things reported than the minimal status had. This is
# the assertion the whole shape of the payload exists to keep true: the domain,
# the certificate store, the two df lines, the mail stack and the per-container
# health ride the same session as everything else.
assert '[ "$(grep -c "bash. .-s" "$ssh_log")" = "1" ]' \
    "the domain, certs, disk, mail and container health did not each cost a session (ssh saw: $(cat "$ssh_log"))"

# --- The five additions, as lines a reader sees ---------------------------------------
assert 'grep -qF "Disk: /apps  11.7G of 39.2G used (32%), 25.6G free — /dev/sda1 on /" <<<"$out"' \
    "df's figures for the apps path, in the units df -h would print (said '$out')"
assert 'grep -qF "/apps/data  the same filesystem" <<<"$out"' \
    "and the data path is not counted twice when it shares one (said '$out')"
assert 'grep -qF "Certificates: 1 in /apps/data/traefik/letsencrypt/acme.json" <<<"$out"' \
    "the certificate store's shape and count (said '$out')"
assert 'grep -qE "^      demo\.example\.com$" <<<"$out"' \
    "the project's domain, parsed out of its fragment with the workstation's yq (said '$out')"
# 89 *or* 90: the fixture is `-days 90` and the days remaining are
# (notAfter - now) / 86400 off two `date +%s` reads. A run landing in the same
# wall-clock second as `openssl req` gets 90 and one a second later gets 89 —
# both have been seen inside a single report.
assert 'grep -qE "certificate valid for (89|90) more day\(s\) \(until .*, CN ?= ?demo\.example\.com\)" <<<"$out"' \
    "with its expiry and issuer out of the store (said '$out')"
assert 'grep -qF "www.demo.example.com" <<<"$out"' \
    "a second Host() in the same rule is a second domain (said '$out')"
assert 'grep -qF "(as a SAN of demo.example.com)" <<<"$out"' \
    "and a SAN match says which certificate answered for it (said '$out')"
assert 'grep -qF "Dashboard: traefik.example.com" <<<"$out"' \
    "the dashboard hostname, out of _shared.yml — the only record of the apex (said '$out')"
assert 'grep -qF "mail-dms         running (healthy)" <<<"$out"' \
    "the mail stack's containers (said '$out')"
assert 'grep -qF "Primary: example.com   Domains: example.com other.example" <<<"$out"' \
    "and the registry's primary and domains (said '$out')"
assert 'grep -qF "1 container(s), all running and none unhealthy" <<<"$out"' \
    "a project whose containers are all well says so in one line (said '$out')"
# The store'"'"'s bytes are private key material and never reach the report.
assert '! grep -qF "PrivateKey" <<<"$out"' "the account key is not printed (said '"'"'$out'"'"')"
assert '! grep -qF "BEGIN CERTIFICATE" <<<"$out"' "nor the PEM it decoded (said '"'"'$out'"'"')"

# Per-container health is the point of the list: a project reporting 2/3 must
# say which one, and an unhealthy container that is *running* is the case the
# count cannot show at all.
write_payload ok "$marker_default" yes running healthy \
    "$(row demo 3 2 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-' ok "$demo_frag" \
        "$(cont demo-web running healthy)
$(cont demo-worker running unhealthy)
$(cont demo-db exited none)")" 1
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a project with a sick container still reports (exit $rc: $out)"
assert 'grep -qE "^      demo-worker +running \(unhealthy\)$" <<<"$out"' \
    "a running-but-unhealthy container is named — the count cannot show it (said '$out')"
assert 'grep -qE "^      demo-db +exited \(none\)$" <<<"$out"' \
    "and so is the stopped one (said '$out')"
assert '! grep -qF "all running and none unhealthy" <<<"$out"' \
    "the one-line summary is not printed when there is something to say (said '$out')"

# A project with no fragment: silent for a stray directory, said out loud for a
# project kasbah deployed — that one has nothing routing to it.
write_payload ok "$marker_default" yes running healthy \
    "$(row deployed 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-')
$(row stray 0 0 missing '')" 2
out=$(status_cli deploy@vps)
assert 'grep -qF "no Traefik fragment at /apps/traefik/dynamic/deployed.yml" <<<"$out"' \
    "a deployed project with no fragment is news (said '$out')"
assert '! grep -qF "stray.yml" <<<"$out"' \
    "a directory nobody deployed is not (said '$out')"

# A fragment that does not parse, and one that routes nothing.
write_payload ok "$marker_default" yes running healthy \
    "$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-' ok 'http: [this is not: a mapping')" 1
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a fragment that is not YAML does not fail the report (exit $rc: $out)"
assert 'grep -qF "does not parse as YAML" <<<"$out"' "it says so (said '"'"'$out'"'"')"
write_payload ok "$marker_default" yes running healthy \
    "$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-' ok 'http:
  routers:
    demo:
      rule: "PathPrefix(`/`)"')" 1
out=$(status_cli deploy@vps)
assert 'grep -qF "declares no Host() rule" <<<"$out"' \
    "a router with no Host() claims no domain, and that is a state (said '$out')"

# --- The certificate store, in the states a rig cannot be put into ---------------------
write_payload
payload_set acme_state=empty
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "an empty store still reports (exit $rc: $out)"
assert 'grep -qF "is empty — nothing has been issued yet" <<<"$out"' "saying so (said '"'"'$out'"'"')"
assert '! grep -qF "certificate valid" <<<"$out"' "and no hostname claims a certificate (said '"'"'$out'"'"')"

write_payload
payload_set acme_state=unreadable
out=$(status_cli deploy@vps)
assert 'grep -qF "cannot be read by deploy@vps" <<<"$out"' \
    "a store this user cannot read is its own state — it is mode 600 (said '$out')"

write_payload
payload_set "acme_b64=$(printf '%s' 'not json at all' | base64 -w0)"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a store that is not JSON does not fail the report (exit $rc: $out)"
assert 'grep -qF "does not parse as JSON" <<<"$out"' "it says so (said '"'"'$out'"'"')"
assert 'grep -qF "not shown" <<<"$out"' \
    "and says the bytes are withheld rather than showing them (said '$out')"
assert '! grep -qF "not json at all" <<<"$out"' \
    "the store's content never reaches a message, whatever is in it (said '$out')"

write_payload
payload_set "acme_b64=$(printf '%s' '{"other":{}}' | base64 -w0)"
out=$(status_cli deploy@vps)
assert 'grep -qF "no '"'"'letsencrypt'"'"' store" <<<"$out"' \
    "a store keyed by another resolver is a schema shift, not zero certificates (said '$out')"

# The data path the two data-side reads hang off. The probe scraped it out of
# the marker with no JSON parser; jq has now read the same bytes. A disagreement
# means both reads describe a tree nobody asked about.
write_payload
payload_set probe_data_path=/somewhere/else
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a scrape that disagrees with the parser still reports (exit $rc: $out)"
assert 'grep -qF "Certificates: not read — the probe and the marker disagree about the data path" <<<"$out"' \
    "and refuses to read a certificate store it cannot place (said '$out')"
assert 'grep -qF "not read — the probe and the marker disagree" <<<"$out"' \
    "the disk figure for the data path goes the same way (said '$out')"
assert '! grep -qF "certificate valid" <<<"$out"' \
    "no certificate line is printed off a store read from the wrong tree (said '$out')"

# --- Disk, in the shapes df can answer in ---------------------------------------------
write_payload
payload_set "data_df_b64=$(printf '%s' '/dev/sdb1 10485760 1048576 9437184 10% /srv/data' | base64 -w0)"
out=$(status_cli deploy@vps)
assert 'grep -qF "1.0G of 10.0G used (10%), 9.0G free — /dev/sdb1 on /srv/data" <<<"$out"' \
    "a data path on its own filesystem gets its own figures (said '$out')"
assert '! grep -qF "the same filesystem" <<<"$out"' "and is not called the same one (said '"'"'$out'"'"')"

write_payload
payload_set "apps_df_b64=$(printf '%s' 'Filesystem 1024-blocks Used Available Capacity Mounted on' | base64 -w0)"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a df answer this reader does not understand is not fatal (exit $rc: $out)"
assert 'grep -qF "df answered in a shape this kasbah does not read" <<<"$out"' \
    "and is reported as unread rather than as a figure (said '$out')"

write_payload
payload_set apps_df_state=absent
out=$(status_cli deploy@vps)
assert 'grep -qF "Disk: /apps  unknown — the path is not there" <<<"$out"' \
    "a path df was never asked about says so (said '$out')"

# --- The mail stack --------------------------------------------------------------------
write_payload
payload_set mail_dir_state=absent
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a server without mail reports and exits 0 (exit $rc: $out)"
assert 'grep -qF "Mail: not installed — no /apps/mail" <<<"$out"' \
    "an absent mail stack is an ordinary state, not a fault (said '$out')"
assert 'grep -qF -- "--with-mail" <<<"$out"' "and the flag that scaffolds one (said '"'"'$out'"'"')"

write_payload
payload_set mail_dms_state=restarting
payload_set mail_dms_health=starting
payload_set mail_dms_restarts=17
out=$(status_cli deploy@vps)
assert 'grep -qF "mail-dms         restarting (starting), 17 restart(s)" <<<"$out"' \
    "a DMS that cannot find its certificate restarts, and the count is what says so (said '$out')"

write_payload
payload_set mail_dms_state=absent
out=$(status_cli deploy@vps)
assert 'grep -qF "mail-dms         absent — the stack is scaffolded and not running" <<<"$out"' \
    "a scaffolded stack that is down is not the same as no stack (said '$out')"

write_payload
payload_set mail_registry_state=absent
out=$(status_cli deploy@vps)
assert 'grep -qF "registry /apps/mail/kasbah.yml: absent" <<<"$out"' \
    "a mail directory with no registry says which file is missing (said '$out')"
assert '! grep -qF "mail.example.com" <<<"$out"' \
    "and claims no hostnames, since the registry is what names them (said '$out')"
# The id is shortened the way docker shortens one, and the assertion is an exact
# line rather than a substring: an untruncated id *contains* the truncated one,
# so `grep -F` on the short form passes against the long one.
payload_set traefik_image_id=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
out=$(status_cli deploy@vps)
assert 'grep -qE "^  Image: traefik:v3\.7\.10 \(sha256:0123456789ab\)$" <<<"$out"' \
    "a 64-digit image id is cut to twelve, with nothing after it (said '$out')"

# --- The backup stack, as lines a reader sees -------------------------------------------
# Three sources and they are kept apart: the marker says what was configured,
# the record says what the scheduler has done, and docker says what the
# container is doing now. Every state below is one a rig cannot be put into on
# demand — a stack that stopped a month ago most of all.
bk_reset() {
    BK_DIR_STATE=absent BK_STATUS_STATE=absent BK_RECORD=""
    BK_C_STATE=absent BK_C_HEALTH="" BK_C_RESTARTS=""
    BK_HASPASS=demo BK_PROJECTS="demo=" BK_NOW=2000000000
}
bk_reset
# The base carries userinfo, which is what a `rest:` target is and what the rig's
# own harness hands kasbah. The marker holding it is mode 644 by contract.
bk_secret=append-only-secret
marker_backup="$(jq -cn --arg b "rest:http://kasbah-vps:$bk_secret@10.0.0.2:8000/" \
    '{kasbah_version:"0.1.0-test",apps_path:"/apps",data_path:"/apps/data",
      cpu_limit:"14.4",mem_limit:"54g",
      backup:{enabled:true,repo_base:$b,at:"02:00",jitter:42,timeout:900,
              retention:{daily:7,weekly:4,monthly:3}}}')"
assert '[ -n "$marker_backup" ]' "the backup-enabled marker fixture is JSON"

# A server that was never asked to back anything up. Not a fault, and not the
# same sentence as a stack that has stopped.
write_payload
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a server with no backups reports and exits 0 (exit $rc: $out)"
assert 'grep -qF "Backup: not configured" <<<"$out"' \
    "an absent backup stack is an ordinary state, not a fault (said '$out')"
assert 'grep -qF -- "--with-backup" <<<"$out"' "and the flag that scaffolds one (said '"'"'$out'"'"')"
assert '! grep -qF "last run" <<<"$out"' \
    "with nothing claimed about a run on a server that was never asked for one (said '$out')"

# A stack the marker does not describe: `server destroy` removes the two
# together, so one without the other is a hand edit and is said out loud.
BK_DIR_STATE=dir
write_payload
out=$(status_cli deploy@vps)
assert 'grep -qF "/apps/.kasbah/backup is dir, and no marker entry describes it" <<<"$out"' \
    "a stack with no marker entry is reported, not hidden (said '$out')"
bk_reset

# The healthy stack.
BK_DIR_STATE=dir BK_STATUS_STATE=file BK_C_STATE=running BK_C_HEALTH=healthy BK_C_RESTARTS=0
BK_RECORD="$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' demo mail')"
BK_PROJECTS="demo=" BK_HASPASS="demo mail"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a backed-up server reports and exits 0 (exit $rc: $out)"
assert 'grep -qF "daily at 02:00 plus 42s jitter" <<<"$out"' \
    "the schedule the marker records (said '$out')"
assert 'grep -qF "kasbah-backup    running (healthy)" <<<"$out"' \
    "the scheduler container, found by its compose labels (said '$out')"
assert 'grep -qF "last run         ok 4h ago — repositories: demo mail" <<<"$out"' \
    "the last run, its age off the server's own clock, and what it reached (said '$out')"
assert 'grep -qF "next run         in 23h" <<<"$out"' "and when the next one is due (said '$out')"
assert 'grep -qF "repositories     demo mail" <<<"$out"' \
    "the repositories this server has: one per client, plus mail (said '$out')"
assert '! grep -qF "no password" <<<"$out"' \
    "and nothing about a missing password when every repository has one (said '$out')"
# The credential, which is the reason there is one redactor and not two.
assert '! grep -qF "$bk_secret" <<<"$out"' \
    "no credential in the repository base reaches the report (said '$out')"
assert 'grep -qF "rest:http://kasbah-vps:***@10.0.0.2:8000/" <<<"$out"' \
    "which is still named, redacted the way lib/backup.sh redacts it (said '$out')"
# Still one round trip, with the backup stack folded into the same probe.
assert '[ "$(grep -c "bash. .-s" "$ssh_log")" = "1" ]' \
    "the backup record did not cost a second ssh session (ssh saw: $(cat "$ssh_log"))"

# A repository with no password is not backed up at all, and the run says so in
# a log nobody reads — which is why this line exists.
BK_PROJECTS="demo= other=" BK_HASPASS="demo"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "repositories     demo other mail" <<<"$out"' \
    "a second project is a second repository (said '$out')"
assert 'grep -qF "no password      other" <<<"$out"' \
    "and the one with no password is named (said '$out')"
assert 'grep -qF "kasbah server init deploy@vps --with-backup" <<<"$out"' \
    "with the command that supplies one (said '$out')"
# Projects sharing a client share a repository — the offboarding unit.
BK_PROJECTS="demo=acme other=acme" BK_HASPASS="acme mail"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "repositories     acme mail" <<<"$out"' \
    "two projects declaring one client are one repository (said '$out')"
assert '! grep -qF "no password" <<<"$out"' "which has its password (said '"'"'$out'"'"')"
BK_PROJECTS="demo=" BK_HASPASS="demo mail"

# The stack that has never fired once. The plan's own watch-out: this is not the
# same fact as a stack that stopped a month ago, and it must not read like one.
BK_RECORD="$(rec sleeping 2000086400 2000082800 1999999000 0 0 - -)"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a stack that has never run still reports (exit $rc: $out)"
assert 'grep -qF "last run         none yet — the scheduler is sleeping" <<<"$out"' \
    "a stack that has never fired says exactly that (said '$out')"
assert '! grep -qF "FAILED" <<<"$out"'  "and is not reported as a failure (said '"'"'$out'"'"')"
assert '! grep -qF "ok " <<<"$(grep "last run" <<<"$out")"' \
    "nor as a run that went fine (said '$out')"

# A stack with no record at all: the container writes one as its first act, so
# this is a stack that has not started — a third fact again.
BK_STATUS_STATE=absent BK_RECORD="" BK_C_STATE=exited BK_C_HEALTH=none
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "last run         none — /apps/.kasbah/backup/state/status is not there" <<<"$out"' \
    "no record is its own state, naming the file (said '$out')"
assert 'grep -qF "kasbah-backup    exited (none)" <<<"$out"' \
    "with the container that would have written it (said '$out')"

# A record that is there and cannot be read. Nothing may be concluded from it.
BK_STATUS_STATE=unreadable BK_C_STATE=running BK_C_HEALTH=healthy
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "last run         unknown — /apps/.kasbah/backup/state/status cannot be read" <<<"$out"' \
    "an unreadable record is unknown, never absent and never ok (said '$out')"

# The failed run.
BK_STATUS_STATE=file
BK_RECORD="$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 failed ' none')"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a failed backup does not fail the report — status reports, check judges (exit $rc)"
assert 'grep -qF "last run         FAILED 4h ago — repositories backed up: none" <<<"$out"' \
    "a failed run is named as one, with what it did reach (said '$out')"
assert 'grep -qF "docker logs kasbah-backup" <<<"$out"' "and where the reason is (said '$out')"
assert 'grep -qF "next run         in 23h" <<<"$out"' \
    "with when the next attempt is — a failed run is slept off, not exited (said '$out')"

# The stack that stopped: the state it last recorded has outlived its own
# deadline, which is the question the container's healthcheck asks of the same
# field. A container `docker ps` still calls running is exactly the case.
BK_RECORD="$(rec sleeping 1999900000 1999896000 1999800000 1999780000 1999783600 ok ' demo')"
BK_C_HEALTH=unhealthy BK_C_RESTARTS=3
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "scheduler        27h past its own deadline in state '"'"'sleeping'"'"'" <<<"$out"' \
    "a sleep that never woke is reported as that (said '$out')"
assert 'grep -qF "last run         ok 2 day(s) ago" <<<"$out"' \
    "with the last run that did work, which is not a contradiction (said '$out')"
assert 'grep -qF "kasbah-backup    running (unhealthy), 3 restart(s)" <<<"$out"' \
    "and the container's own verdict beside it (said '$out')"

# The stack the marker enables and the server does not have.
BK_DIR_STATE=absent BK_C_STATE=absent BK_C_HEALTH="" BK_C_RESTARTS=""
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "last run         none — /apps/.kasbah/backup is not there" <<<"$out"' \
    "a marker naming a stack the server does not have says so (said '$out')"
assert 'grep -qF "kasbah-backup    absent" <<<"$out"' "and no container is running it (said '$out')"

# A run that succeeded and shipped nothing. `back_up_repo` returns 0 for a
# repository with no paths, so `ok` with `last_run_repos= none` is a real record
# — and a server where nothing left the box is not what "ok, repositories: none"
# reads like at a glance.
BK_DIR_STATE=dir BK_STATUS_STATE=file BK_C_STATE=running BK_C_HEALTH=healthy BK_C_RESTARTS=0
BK_RECORD="$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' none')"
BK_PROJECTS="" BK_HASPASS=""
write_payload ok "$marker_backup"
# No mail stack either, so this is the whole of the ordinary instance: backups
# on, nothing on the server to back up yet.
payload_set mail_dir_state=absent
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a run that shipped nothing still reports (exit $rc: $out)"
assert 'grep -qF "last run         ok 4h ago, and shipped nothing — no repository had anything to back up" <<<"$out"' \
    "and says so rather than listing a repository it did not write (said '$out')"
assert 'grep -qF "repositories     none — nothing under /apps to back up yet" <<<"$out"' \
    "with the reason there was nothing (said '$out')"
BK_PROJECTS="demo=" BK_HASPASS="demo mail"

# A scheduler past its deadline whose container is *not running*. It did not
# wedge and it did not oversleep — it was taken down, and saying otherwise would
# send an operator looking at restic.
BK_RECORD="$(rec sleeping 1999900000 1999896000 1999800000 1999780000 1999783600 ok ' demo')"
BK_C_STATE=exited BK_C_HEALTH=none
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "the container is exited, so nothing has moved it on" <<<"$out"' \
    "a stopped scheduler is not called a run that never returned (said '$out')"
assert '! grep -qF "never woke" <<<"$out"' "which is what it is not (said '"'"'$out'"'"')"
# The control: the same record with the container up keeps the other sentence,
# so the line above is about the container and not about the wording changing.
BK_C_STATE=running BK_C_HEALTH=unhealthy
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert 'grep -qF "a run that never returned, or a sleep that never woke" <<<"$out"' \
    "a scheduler that is up and past its deadline did one of those two (said '$out')"
BK_C_HEALTH=healthy

# A record with no usable `since`: the duration clauses are left out rather than
# printed empty. "(for )" is not a duration.
BK_RECORD="$(printf 'state=sleeping\ndeadline=1999900000\nlast_run_started=0\nlast_run_finished=0\nlast_run_status=-\n')"
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a record carrying no since still reports (exit $rc: $out)"
assert '! grep -qF "(for )" <<<"$out"' "with no empty duration in the line (said '$out')"
assert 'grep -qF "past its own deadline in state '"'"'sleeping'"'"'" <<<"$out"' \
    "and the verdict is still printed (said '$out')"
# Both spellings of that line — the container up and the container down — since
# the two branches carry the clause separately.
BK_C_STATE=exited BK_C_HEALTH=none
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert '! grep -qF "(for )" <<<"$out"' \
    "and the stopped-container spelling of the same line leaves it out too (said '$out')"
assert 'grep -qF "the container is exited, so nothing has moved it on" <<<"$out"' \
    "while still saying what it does know (said '$out')"
BK_C_STATE=running BK_C_HEALTH=healthy

# The clock the record is judged on, said out loud when it is not the server's.
BK_RECORD="$(rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' demo')"
BK_NOW=not-a-clock
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a probe that did not report the server's clock still reports (exit $rc)"
assert 'grep -qF "judged against this machine'"'"'s clock" <<<"$out"' \
    "and the report says which clock the ages below it came off (said '$out')"
BK_NOW=2000000000
write_payload ok "$marker_backup"
out=$(status_cli deploy@vps)
assert '! grep -qF "judged against this machine" <<<"$out"' \
    "the ordinary case says nothing, because the server's own clock is the expected one (said '$out')"

# A verdict the reader cannot produce, driven through the printer with the
# reader stubbed. `ok` is not the catch-all arm: on a command whose subject is
# that absence is not a value, the success sentence must never be what a verdict
# falls into by not matching.
out=$(drive printbackup ok)
assert 'grep -qF "last run         ok 4h ago" <<<"$out"' \
    "the stub reaches the printer at all — else every line below is theatre (said '$out')"
for bogus in '' sideways; do
    out=$(drive printbackup "$bogus")
    assert 'grep -qF "the record reader returned" <<<"$out"' \
        "a verdict of '${bogus:-<empty>}' is reported as unknown (said '$out')"
    assert '! grep -qF "last run         ok" <<<"$out"' \
        "and never as a backup that worked (said '$out')"
done
out=$(drive printbackup '' 1)
assert 'grep -qF "(exit 1)" <<<"$out"' \
    "with the reader's own exit status, which the caller captured (said '$out')"

# A marker whose backup object is not an object at all. jq would make that a
# type error rather than a null, and an unguarded read would end the run with no
# report printed.
bk_reset
write_payload ok '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g","backup":"yes please"}'
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a marker with a backup field that is not an object still reports (exit $rc: $out)"
assert 'grep -qF "Backup: not configured" <<<"$out"' \
    "and is read as no backups rather than dying mid-report (said '$out')"
# Backups on, and the marker records nowhere to put them.
write_payload ok '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g","backup":{"enabled":true}}'
out=$(status_cli deploy@vps)
assert 'grep -qF "the marker records no repository base" <<<"$out"' \
    "an enabled backup with no repository base says nothing says where the snapshots go (said '$out')"
bk_reset

# --- The apps path reaches the far side ------------------------------------------------
# The one thing status has that deploy does not. Without this, --apps-path could
# be parsed perfectly and never leave the workstation.
write_payload
payload_set apps_path=/srv/apps
payload_set apps_source=flag
out=$(status_cli deploy@vps --apps-path=/srv/apps)
assert 'grep -qF "'"'"'bash'"'"' '"'"'-s'"'"' '"'"'--'"'"' '"'"'/srv/apps'"'"'" "$ssh_log"' \
    "the remote step is given the apps path that was asked for (ssh saw: $(cat "$ssh_log"))"
assert 'grep -qF "Root: /srv/apps" <<<"$out"' "and the report says which path it read (said '$out')"
# The reserved list travels with it: the far side filters on names this side
# owns, so a shortened list would silently start reporting kasbah's own
# directories as projects.
assert 'grep -qF ".kasbah traefik mail data backups" "$ssh_log"' \
    "the directories kasbah owns are the ones the far side is told to skip (ssh saw: $(cat "$ssh_log"))"

# The marker recording a different apps path than the one that was read: not an
# error — the reader is looking at a real marker — but not silent either.
write_payload ok '{"kasbah_version":"0.1.0-test","apps_path":"/elsewhere","data_path":"/elsewhere/data","cpu_limit":"1.0","mem_limit":"1g"}'
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a marker that names another apps path still reports (exit $rc)"
assert 'grep -qF "the marker records apps_path=/elsewhere, and this status read /apps" <<<"$out"' \
    "with a warning that the two disagree (said '$out')"

# --- Every row the printer can produce -------------------------------------------------
# The remote layer's states are asserted above as facts; these are the lines a
# reader actually sees. One row per shape of answer — the first is the happy
# path, and every row under it is a state the happy path never reaches.
rows_all="$(row deployed 2 2 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-')
$(row halfup 3 1 ok '2026-08-13T22:30:37+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-')
$(row allstopped 2 0 ok '2026-08-13T22:30:37+00:00 rollback 1.9.0 backups/x.sql.gz kasbah=0.1.0 digest=-')
$(row nocontainers 0 0 ok '2026-08-13T22:30:37+00:00 deploy 3.0.0 no-backup kasbah=0.1.0 digest=-')
$(row dropped 0 0 missing '')
$(row emptylog 0 0 empty '')
$(row weirdlog 0 0 notfile '')
$(row lockedlog 0 0 unreadable '')
$(row lockeddir 0 0 noaccess '')
$(row notadir 0 0 notdir '')
$(row garbled 0 0 ok 'just a note someone left')"
write_payload ok "$marker_default" yes running healthy "$rows_all" 11
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "eleven projects, one per shape of answer, all report (exit $rc: $out)"
row_of() { grep -E "^  $1 " <<<"$out"; }
assert '[[ "$(row_of deployed)"     =~ ^"  deployed       2/2 running    "" "*"1.0.0" ]]' \
    "all containers up reads 'running' (said '$(row_of deployed)')"
assert '[[ "$(row_of halfup)"       =~ "1/3 partial" ]]' \
    "some up and some not is 'partial', not 'running' (said '$(row_of halfup)')"
assert '[[ "$(row_of allstopped)"   =~ "0/2 stopped" ]]' \
    "none up is 'stopped' — '0/2 running' was the small lie (said '$(row_of allstopped)')"
assert '[[ "$(row_of allstopped)"   =~ "rollback 2026-08-13" ]]' \
    "and the action is the log's own word, not 'deploy' (said '$(row_of allstopped)')"
assert '[[ "$(row_of nocontainers)" =~ "no containers" ]]' \
    "a project with a log and nothing running says so (said '$(row_of nocontainers)')"
# Two rows pinned whole — state, version column and note together — so a change
# to any one of the three columns has somewhere to fail.
assert '[[ "$(row_of dropped)"      =~ ^"  dropped        no containers  -          no versions.log" ]]' \
    "no log: no containers, no version, and the reason (said '$(row_of dropped)')"
assert '[[ "$(row_of emptylog)"     =~ "versions.log is empty" ]]' "empty log (said '$(row_of emptylog)')"
assert '[[ "$(row_of weirdlog)"     =~ "not a regular file" ]]' "log that is not a file (said '$(row_of weirdlog)')"
assert '[[ "$(row_of lockedlog)"    =~ "cannot be read" ]]'    "unreadable log (said '$(row_of lockedlog)')"
assert '[[ "$(row_of lockeddir)"    =~ "as root leaves this" ]]' "unreadable directory (said '$(row_of lockeddir)')"
assert '[[ "$(row_of notadir)"      =~ ^"  notadir        -              -          not a directory" ]]' \
    "a file where a directory belongs: no state to report, and why (said '$(row_of notadir)')"
assert '[[ "$(row_of garbled)"      =~ "not a kasbah entry: just a note someone left" ]]' \
    "a last line that is not an entry is quoted back (said '$(row_of garbled)')"
assert '[[ "$(row_of garbled)"      =~ \?" " ]]' \
    "with '?' where the version would be (said '$(row_of garbled)')"

# Docker itself unreachable: the projects are directories and are still listed,
# but nothing may claim to know whether they are running.
payload_set have_docker=no
payload_set docker_server=
payload_set docker_error='docker: command not found'
payload_set traefik_present=no
payload_set traefik_state=
payload_set traefik_health=
payload_set traefik_image=
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a server whose docker does not answer still reports (exit $rc: $out)"
assert 'grep -qF "Docker: unavailable — docker: command not found" <<<"$out"' \
    "saying what docker said (said '$out')"
assert 'grep -qF "Traefik: unknown — docker did not answer" <<<"$out"' \
    "and refusing to call Traefik absent on that evidence (said '$out')"
assert '[[ "$(row_of deployed)" =~ ^"  deployed       ?" ]]' \
    "every project's state is '?' rather than a count of nothing (said '$(row_of deployed)')"

# A project name wider than the column. `gallery-website` is fifteen characters
# on the real host, and a fixed `%-14s` pushed every field on its row one place
# right of every other row's — the one shape a single-project report cannot
# show. Two rows, and the second field of each must begin at the same offset.
write_payload ok "$marker_default" yes running healthy \
    "$(row gallery-website 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-')
$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-')" 2
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a project name wider than the column reports (exit $rc: $out)"
col_of() { local l; l="$(grep -E "^  $1 " <<<"$out")"; l="${l%%1/1 running*}"; printf '%s' "${#l}"; }
assert '[ "$(col_of gallery-website)" = "$(col_of demo)" ]' \
    "the state column starts at one offset for every row, whatever the names are
        gallery-website at $(col_of gallery-website), demo at $(col_of demo)
        said: $(grep -E "^  (gallery-website|demo) " <<<"$out")"
assert '[ "$(col_of demo)" -gt 16 ]' \
    "and the column grew to fit the wider name rather than the name overflowing it (offset $(col_of demo))"

# A container that docker named and then would not describe.
write_payload
payload_set traefik_state=
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a half-answered inspect does not fail the report (exit $rc)"
assert 'grep -qF "Traefik: unknown — docker named a container and then did not describe it" <<<"$out"' \
    "it says the inspect came back empty (said '$out')"
assert '! grep -qE "^Traefik: +\(" <<<"$out"' \
    "rather than printing a state with nothing in it (said '$out')"

# --- The Traefik line, in the states a rig cannot be put into on demand ---------------
write_payload ok "$marker_default" no "" ""
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a server with no Traefik container still reports (exit $rc: $out)"
assert 'grep -qF "Traefik: absent" <<<"$out"' "saying Traefik is absent (said '$out')"

write_payload ok "$marker_default" yes running unhealthy
out=$(status_cli deploy@vps)
assert 'grep -qF "Traefik: running (unhealthy)" <<<"$out"' \
    "an unhealthy Traefik is reported as running and unhealthy, not as up (said '$out')"

write_payload ok "$marker_default" yes exited none
out=$(status_cli deploy@vps)
assert 'grep -qF "Traefik: exited (no healthcheck)" <<<"$out"' \
    "a stopped container with no healthcheck reports both facts (said '$out')"

# Zero projects: a prepared server nobody has deployed to.
write_payload ok "$marker_default" yes running healthy '' 0
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "an initialised server with nothing deployed exits 0 (exit $rc: $out)"
assert 'grep -qF "none — no project directory under /apps" <<<"$out"' \
    "and says so rather than printing an empty list (said '$out')"

# A marker from another major: a warning and a report, not a refusal. `server
# init` refuses there because it is about to write; status only reads, and the
# moment a server is ahead of the reader is the moment its state is most worth
# printing.
write_payload ok '{"kasbah_version":"9.0.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.8","mem_limit":"7g"}'
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a marker from another major still reports (exit $rc: $out)"
assert 'grep -qF "written by kasbah 9.0.0" <<<"$out"' "with a warning that says so (said '$out')"
assert 'grep -qF "Marker: kasbah 9.0.0, cpu 1.8, mem 7g" <<<"$out"' \
    "and the marker's own values, whoever wrote them (said '$out')"

# --- Exit codes ----------------------------------------------------------------------
write_payload absent
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "4" ]' "a server with no marker exits 4, like deploy (exit $rc: $out)"
assert 'grep -qF "/apps/.kasbah/server.json" <<<"$out"' "naming the file it looked for (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and the flag that makes a prepared server look unprepared (said '$out')"
# The remedy must not be followable into a disaster: a bare
# `kasbah server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack there under the frozen `traefik` project name
# and takes every site on the host down.
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" <<<"$out"' \
    "and never prints a runnable bare \`server init\` (said '$out')"
assert 'grep -qF "kasbah server status deploy@vps --apps-path=" <<<"$out"' \
    "what it does offer is the read-only command with the flag (said '$out')"

write_payload absent
payload_set apps_path=/srv/apps
payload_set apps_source=flag
out=$(status_cli deploy@vps --apps-path=/srv/apps); rc=$?
assert '[ "$rc" = "4" ]' "the same verdict under --apps-path (exit $rc: $out)"
assert 'grep -qF "/srv/apps/.kasbah/server.json" <<<"$out"' \
    "naming the path that was actually searched (said '$out')"
assert 'grep -qF "the one --apps-path named" <<<"$out"' \
    "and saying that is where the flag sent it (said '$out')"

# The operator who reached for the escape hatch and guessed: the server's own
# record is right there, and it is the answer to their next question.
write_payload absent
payload_set pointer_state=present
payload_set pointer_value=/srv/elsewhere
payload_set apps_path=/srv/apps
payload_set apps_source=flag
out=$(status_cli deploy@vps --apps-path=/srv/apps); rc=$?
assert '[ "$rc" = "4" ]' "a wrong --apps-path still exits 4 (exit $rc: $out)"
assert 'grep -qF "records /srv/elsewhere" <<<"$out"' \
    "and the message says what the server's own record holds (said '$out')"

# The third shape of exit 4, and the one the pointer introduces: the server's
# own record names a tree with no marker in it. The reader must not be told the
# server was never prepared — something prepared it and wrote that file.
write_payload absent
payload_set pointer_state=present
payload_set pointer_value=/srv/apps
payload_set apps_path=/srv/apps
payload_set apps_source=pointer
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "4" ]' "a pointer naming a tree with no marker exits 4 (exit $rc: $out)"
assert 'grep -qF "/srv/apps/.kasbah/server.json" <<<"$out"' \
    "naming the marker it looked for (said '$out')"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' \
    "and the record that sent it there (said '$out')"
assert '! grep -qF "is not there either" <<<"$out"' \
    "and it does not claim the pointer is missing when it is what steered the read (said '$out')"

# A pointer that holds something that is not a path: refused before anything is
# reported, because /apps would be a different server.
write_payload
payload_set pointer_state=present
payload_set pointer_value=srv/apps
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" != "0" ] && [ "$rc" != "4" ]' \
    "a pointer holding a relative path stops the run (exit $rc: $out)"
assert 'grep -qF "srv/apps" <<<"$out"' "quoting what it holds (said '$out')"
assert '! grep -qF "Root:" <<<"$out"' "and nothing is reported about the wrong tree (said '$out')"

# The same file, under --apps-path: not consulted, because the operator said
# where to look. This is the escape hatch for a server whose pointer is gone or
# damaged, and it has to work while it is damaged.
write_payload
payload_set pointer_state=present
payload_set pointer_value=srv/apps
payload_set apps_path=/srv/other
payload_set apps_source=flag
out=$(status_cli deploy@vps --apps-path=/srv/other); rc=$?
assert '[ "$rc" = "0" ]' "--apps-path reports a server whose pointer is damaged (exit $rc: $out)"
assert 'grep -qF "Root: /srv/other (flag)" <<<"$out"' "reading where it was told (said '$out')"

# Where the root came from is printed, because "status read the wrong tree" and
# "the server records another one" are different problems.
write_payload
payload_set pointer_state=present
payload_set pointer_value=/apps
payload_set apps_source=pointer
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a pointer-steered read reports (exit $rc: $out)"
assert 'grep -qF "Root: /apps (pointer)" <<<"$out"' \
    "and says the server's own record is what named it (said '$out')"

write_payload empty
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" != "0" ]' "a zero-byte marker is a failure, not an unprepared server (exit $rc: $out)"
assert '[ "$rc" != "4" ]' "and not exit 4 — the file is there (exit $rc)"

write_payload notfile
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a marker that is not a regular file is a plain failure (exit $rc: $out)"
assert '[ "$rc" != "4" ]' "and not exit 4 — something is at that path (exit $rc)"
assert 'grep -qF "is not a regular file" <<<"$out"' "saying what is wrong with it (said '$out')"

# The apps path itself. The probe collects its state and the two answers are
# different servers: nothing there at all, versus a file where the tree should
# be. Reporting the second as "never prepared" sends the reader to init.
write_payload absent
payload_set apps_state=notdir
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a file where the apps path should be is a plain failure (exit $rc: $out)"
assert 'grep -qF "/apps on deploy@vps exists and is not a directory" <<<"$out"' \
    "naming what it found (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' "and how to look elsewhere (said '$out')"

write_payload absent
payload_set apps_state=absent
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "4" ]' "an apps path that is not there at all is the unprepared server (exit $rc)"
assert 'grep -qF "/apps is not there either" <<<"$out"' \
    "and the message says the directory is missing too, not just the marker (said '$out')"

write_payload ok 'not json at all'
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a marker that is not JSON is a plain failure (exit $rc: $out)"
assert 'grep -qF "not a JSON object" <<<"$out"' "saying what it read (said '$out')"

# A fact that never arrived must not be absorbed into a passing report.
write_payload
grep -v '^traefik_health=' "$payload_file" > "$payload_file.trimmed"
mv "$payload_file.trimmed" "$payload_file"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a truncated report is a failure (exit $rc: $out)"
assert 'grep -qF "reported no traefik_health" <<<"$out"' "naming the missing fact (said '$out')"

: > "$payload_file"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a report with nothing in it is a failure (exit $rc: $out)"

# The raw output is echoed back on a protocol failure, and two of its values are
# base64 blobs that grow with the server. A diagnostic that scrolls a megabyte
# of base64 past the reader diagnoses nothing.
write_payload
payload_set "projects_b64=$(head -c 4000 /dev/zero | tr '\0' 'A')"
grep -v '^traefik_health=' "$payload_file" > "$payload_file.trimmed"
mv "$payload_file.trimmed" "$payload_file"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "still a failure with a large payload (exit $rc)"
assert 'grep -qF "reported no traefik_health" <<<"$out"' "naming the missing fact (said '$(head -c 200 <<<"$out")')"
assert '[ "$(wc -c <<<"$out")" -lt 3000 ]' \
    "and the echoed payload is clipped rather than dumped whole ($(wc -c <<<"$out") bytes)"
assert 'grep -qF "bytes in all" <<<"$out"' "saying how much was left out (said '$(head -c 300 <<<"$out")')"

# --- The diagnostic must not print the certificate store ------------------------------
# acme.json travels in the same payload — it has to, or the report costs a
# second ssh session — and it holds the ACME account key and every
# certificate's private key. The echo above clips to 120 bytes and prints, and
# 120 bytes of a private key on stderr is 120 bytes of a private key on stderr.
#
# The assertions below grep for the *blob as it travels*, base64'd, not for the
# plaintext: a mutant echoing the whole payload would not contain the decoded
# bytes, so an assertion looking for those cannot fail (7.3's Findings — that
# exact test scored zero).
write_payload
# 100 bytes, not 120. The clip is 120 bytes *of the whole line* and the line
# begins `acme_b64=`, so at most 111 blob bytes are ever printed: a 120-byte
# needle could never appear and the assertion below could never fail. Fourth
# variant of this family in the phase — by wording, by encoding, by position,
# and now by arithmetic.
acme_head="${acme_b64_default:0:100}"
assert '[ "${#acme_b64_default}" -gt 200 ]' \
    "the store fixture is big enough that a clip would show part of it (${#acme_b64_default} bytes)"
grep -v '^traefik_health=' "$payload_file" > "$payload_file.trimmed"
mv "$payload_file.trimmed" "$payload_file"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a truncated report carrying the store is still a failure (exit $rc)"
assert 'grep -qF "reported no traefik_health" <<<"$out"' \
    "and still names the missing fact (said '$(head -c 200 <<<"$out")')"
assert '! grep -qF "$acme_head" <<<"$out"' \
    "the store's bytes are not echoed back (said '$(head -c 400 <<<"$out")')"
# This one and the next are *position* assertions as much as output ones. The
# diagnostic stops after twenty lines, so a payload key added ahead of
# `acme_b64` pushes it past the window, where nothing is printed about it at all
# and the negative assertion above becomes vacuous. Both fail loudly when that
# happens — verified by inserting three filler keys before `acme_state`.
# `acme_b64` must stay inside the clip window.
assert 'grep -qF "acme_b64= (" <<<"$out"' \
    "the line is reported by name and length instead (said '$(head -c 400 <<<"$out")')"
assert 'grep -qF "private key material" <<<"$out"' \
    "saying why it is withheld (said '$(head -c 400 <<<"$out")')"
# Other long values are still clipped and shown: the diagnostic exists to tell a
# truncated step from a rejected one, and a redaction that swallowed everything
# would diagnose nothing.
assert 'grep -qF "marker_b64=" <<<"$out"' \
    "a payload key that is not secret is still shown, clipped (said '$(head -c 400 <<<"$out")')"
assert 'grep -qF "bytes in all" <<<"$out"' \
    "with how much of it was left out (said '$(head -c 400 <<<"$out")')"

# The hazard is a *truncated* read, which is where the clip fires: the store's
# line arrives cut off mid-blob. It still begins with its key, which is what the
# redaction matches on.
#
# Replaced **in place**, not through payload_set: that one rebuilds the file as
# grep -v plus append, which moves the key to the end and past the twenty-line
# window — where the diagnostic prints `… and more, not shown` and never reaches
# it, and every assertion about it then passes for the wrong reason.
payload_set_here() {
    local key="${1%%=*}" line
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$key" ]; then printf '%s\n' "$1"; else printf '%s\n' "$line"; fi
    done < "$payload_file" > "$payload_file.next"
    mv "$payload_file.next" "$payload_file"
}
write_payload
payload_set_here "acme_b64=${acme_b64_default:0:400}"
grep -v '^traefik_health=' "$payload_file" > "$payload_file.trimmed"
mv "$payload_file.trimmed" "$payload_file"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "1" ]' "a payload cut mid-store is a failure (exit $rc)"
assert '! grep -qF "${acme_b64_default:0:100}" <<<"$out"' \
    "and a half-arrived store is redacted exactly as a whole one is (said '$(head -c 400 <<<"$out")')"
# The positive counterpart, which is what keeps the line above honest: it says
# the redaction ran on this line, in this position — not that the line was
# never printed at all.
assert 'grep -qF "acme_b64= (400 bytes, not shown" <<<"$out"' \
    "the half-arrived line is redacted by name and length, in the window where the clip fires (said '$(head -c 400 <<<"$out")')"

# The other path a store can reach a message from: a blob that is not base64.
# The complaint says the store could not be read and never quotes it.
write_payload
payload_set "acme_b64=@@@not base64@@@"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a store that is not base64 does not fail the report (exit $rc: $out)"
assert 'grep -qF "did not come back as readable bytes" <<<"$out"' "it says so (said '$out')"
assert '! grep -qF "@@@not base64@@@" <<<"$out"' \
    "without quoting the blob back, which is what every other decode failure does (said '$out')"

write_payload
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
echo "ssh: connect to host vps port 22: Connection refused" >&2
exit 255
STUB
chmod 0755 "$stub_dir/ssh"
out=$(status_cli deploy@vps); rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server exits 3 (exit $rc: $out)"
assert 'grep -qF "cannot reach deploy@vps" <<<"$out"' "saying which host (said '$out')"

# --- Dispatch --------------------------------------------------------------------------
out=$(env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION HOME="$tmpdir/home" "$repo_dir/bin/kasbah" server bogus 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "an unknown server subcommand fails (exit $rc: $out)"
assert 'grep -qF "unknown subcommand" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "init, status" <<<"$out"' "and naming what exists (said '$out')"
out=$(env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION HOME="$tmpdir/home" "$repo_dir/bin/kasbah" server 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a missing server subcommand fails (exit $rc: $out)"
assert 'grep -qF "init, status" <<<"$out"' "naming what exists (said '$out')"
out=$(env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION HOME="$tmpdir/home" "$repo_dir/bin/kasbah" --help 2>&1)
assert 'grep -qF "server status" <<<"$out"' "the top-level usage lists server status (said '$out')"
out=$(env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION HOME="$tmpdir/home" "$repo_dir/bin/kasbah" server --help 2>&1)
assert 'grep -qF "status USER@HOST" <<<"$out"' "and so does the server usage (said '$out')"
out=$(env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION HOME="$tmpdir/home" "$repo_dir/bin/kasbah" server status --help 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "server status --help exits 0 (exit $rc)"
assert 'grep -qF -- "--apps-path" <<<"$out"' "and documents the one flag it takes (said '$out')"

exit "$fail"
