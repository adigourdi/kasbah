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
row() { printf '%s %s %s %s %s\n' "$(printf '%s' "$1" | base64 -w0)" "$2" "$3" "$4" "$(printf '%s' "$5" | base64 -w0)"; }

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

# The filter: six candidates, and not one of kasbah's own five directories —
# `mail` among them, so the far-side filter runs against the same list the
# workstation sends in production (pinned separately at the ssh log below).
assert '[ "$(fact project_count)" = "6" ]' \
    "six candidates under a tree of eleven entries (got '$(fact project_count)')"
decoded="$(printf '%s' "$(fact projects_b64)" | base64 -d)"
names=""
while IFS=' ' read -r nb total running logstate logb64; do
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
demo_log="$(while IFS=' ' read -r nb total running logstate logb64; do
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
    while IFS=' ' read -r nb total running logstate logb64; do
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
demo_log="$(while IFS=' ' read -r nb total running logstate logb64; do
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
write_payload() {
    local marker_state="${1:-ok}" marker_json="${2:-$marker_default}"
    local traefik_present="${3:-yes}" traefik_state="${4:-running}" traefik_health="${5:-healthy}"
    local rows="${6-$(row demo 1 1 ok '2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0-dev digest=-')}"
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
assert '[ "$rc" = "0" ]' "a prepared server reports and exits 0 (exit $rc: $out)"
assert 'grep -qF "Docker: 27.3.1, Compose: 2.29.7" <<<"$out"' "the two versions (said '$out')"
assert 'grep -qF "Traefik: running (healthy)" <<<"$out"'      "Traefik's state and health (said '$out')"
assert 'grep -qF "traefik:v3.7.10" <<<"$out"'                 "the image it runs (said '$out')"
assert 'grep -qE "^  demo +1/1 running +1\.0\.0 +deploy 2026-08-13T22:30:37\+00:00 \(kasbah 0\.1\.0-dev\)$" <<<"$out"' \
    "and the project row: name, state, version, last entry (said '$out')"
assert '[ "$(grep -c "bash. .-s" "$ssh_log")" = "1" ]' \
    "one remote step, not one per fact (ssh saw: $(cat "$ssh_log"))"
# The id is shortened the way docker shortens one, and the assertion is an exact
# line rather than a substring: an untruncated id *contains* the truncated one,
# so `grep -F` on the short form passes against the long one.
payload_set traefik_image_id=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
out=$(status_cli deploy@vps)
assert 'grep -qE "^  Image: traefik:v3\.7\.10 \(sha256:0123456789ab\)$" <<<"$out"' \
    "a 64-digit image id is cut to twelve, with nothing after it (said '$out')"

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
