#!/usr/bin/env bash
# Integration test: `kasbah history`, `kasbah pending` and `kasbah changelog`
# against the live rig, reading the record a real deploy/rollback sequence wrote.
#
# What only the rig can show:
#   * the three commands run against a record kasbah itself appended, on a
#     server they discovered through /etc/kasbah/apps-path rather than through a
#     flag — the hermetic suite plants its logs and stubs the transport;
#   * **`--all` spanning a real rotation point.** Entries old enough to be
#     pruned are planted in the active log, and the next deploy's own rotation
#     is what moves them into versions.log.gz. Nothing here compresses anything:
#     the archive is the one the deploy engine wrote, read back through
#     zcat on the workstation.
#   * `changelog` over a rollback the rig actually performed, where the version
#     running is the rollback's target and the range therefore runs backwards.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which leaves images alone, so the ones it loads are
# removed by name here.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
marker="$apps/.kasbah/server.json"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

project=built-app
v1=2.1.0
v2=2.2.0
image_web=built-app-web
image_worker=built-app-worker
projdir_remote="$apps/$project"
log_remote="$projdir_remote/versions.log"
gz_remote="$projdir_remote/versions.log.gz"
v2_subject="what $v2 changed and $v1 did not have"

# The two planted entries: old enough that the next deploy's rotation prunes
# them, whatever month this suite is run in (the cutoff is this month minus
# three). The second carries a real backup path, so the archived half of the
# record is wider than the active half and `--all` has to re-measure the table.
plant_ts1="$(date -u -d '10 months ago' +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null)"
plant_ts2="$(date -u -d '9 months ago' +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null)"
plant_v1=0.0.1
plant_v2=0.0.2
plant_backup=backups/pre-deploy-00000000-000000.sql.gz
# A truncated append, which is what a `printf >>` killed partway leaves. Dated
# this month so rotation keeps it in the active log — a line no version can be
# read out of has to be visible in the table plain `history` prints.
plant_bad="$(date -u +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null) deploy 9.9"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    # The archive's mode is restored here as well as inline: the unreadable-archive
    # case chmods it 000, and a signal landing between the two statements would
    # otherwise leave a file this suite made unreadable behind for the next one.
    rig_ssh "chmod 644 $gz_remote" >/dev/null 2>&1
    rig_ssh "docker image rm -f $image_web:$v1 $image_worker:$v1 $image_web:$v2 $image_worker:$v2 $image_web:current $image_worker:current; rm -f /tmp/$project-*.tar.gz" >/dev/null 2>&1
    docker image rm -f "$image_web:$v1" "$image_worker:$v1" "$image_web:$v2" "$image_worker:$v2" \
        "$image_web:current" "$image_worker:current" >/dev/null 2>&1
    rm -f "${TMPDIR:-/tmp}/$project-"*.tar.gz
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! command -v docker >/dev/null; then
    echo "error: this suite builds images on this workstation, and docker is not on PATH" >&2
    exit 2
fi
if [ -z "$plant_ts1" ] || [ -z "$plant_ts2" ]; then
    echo "error: \`date -u -d '10 months ago'\` did not answer — the rotation fixture needs GNU date" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh" >&2
    echo "       is the rig up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir"; then
    echo "error: could not build the scratch HOME and ssh wrapper under $tmpdir" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi

# --- Helpers --------------------------------------------------------------------
projdir="$tmpdir/$project"
init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
build_push() (
    cd "$projdir" || return 2
    kasbah_cli build-push "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
# Bounded, for the reason rig_env.sh gives: a wedged run must fail the suite
# rather than hang it. stdout and stderr land in separate files, because which
# of the two a line goes to is part of what these three commands promise.
kasbah_bounded() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy()    { kasbah_bounded deploy "$@"; }
rollback()  { kasbah_bounded rollback "$@"; }
history()   { kasbah_bounded history "$@"; }
pending()   { kasbah_bounded pending "$@"; }
changelog() { kasbah_bounded changelog "$@"; }

versions_log() { rig_ssh "cat $log_remote 2>/dev/null" 2>/dev/null | tr -d '\r'; }

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — nothing to read a record from" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do (plan/roadmap/02-spine.md → Findings).
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    if ! grep -qF "threaded mode" <<<"$limit_probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
        sed 's/^/       | /' <<<"$limit_probe" >&2
        exit 2
    fi
    new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
fi

# --- Two deploys ------------------------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$v1" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push of $v1 failed (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The .env, rendered once by the operator's own hand: the first deploy has none
# and no terminal to make one on, which is spine_test.sh's subject and this
# suite's precondition.
deploy "$RIG_TARGET" >/dev/null 2>&1
setup_rc=0
rig_setup_env "$projdir_remote" </dev/null >/dev/null 2>&1 || setup_rc=$?
if [ "$setup_rc" -ne 0 ]; then
    echo "error: the server's env setup did not render an .env (exit $setup_rc)" >&2
    exit 2
fi

deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the $v1 deploy failed (exit $rc) — there is no record to read" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

sed -i 's|^      BUILT_APP_GREETING: \${BUILT_APP_GREETING}$|&\n      BUILT_APP_EDITION: "two"|' \
    "$projdir/compose.prod.yml"
if ! ( cd "$projdir" && git add -A && git commit -qm "$v2_subject" && git tag "v$v2" ) \
        >"$tmpdir/git.log" 2>&1; then
    echo "error: could not cut v$v2 in the fixture copy" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push of $v2 failed (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the $v2 deploy failed (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# ==================================================================================
# The three commands over a record kasbah wrote
# ==================================================================================
log="$(versions_log)"
assert '[ "$(grep -c . <<<"$log")" = "2" ]' "two deploys have written two lines (log: $log)"

history "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "kasbah history reads the record it wrote (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(head -1 <<<"$out" | awk "{print \$1, \$2, \$3, \$4, \$5}")" = "TIMESTAMP ACTION VERSION BACKUP KASBAH" ]' \
    "with the five columns docs/cli.md names, in that order (header: '$(head -1 <<<"$out")')"
assert '[ "$(head -1 <<<"$out" | awk "{print \$6}")" = "BY" ]' \
    "and BY last: the ssh user each line was written as (header: '$(head -1 <<<"$out")')"
assert '[ "$(grep -c " stevedore$" <<<"$out")" = "2" ]' \
    "both rows name the rig user who deployed them (got '$out')"
assert '[ "$(cli_err)" = "" ]' "and nothing on stderr — a piped history is the table (stderr: $(cli_err))"
assert '[ "$(grep -c "^20" <<<"$out")" = "2" ]' \
    "two rows for two deploys (got '$out')"
assert 'grep -qE "^[0-9T:+-]+  deploy +$v1 +no-backup +[0-9]" <<<"$out"' \
    "the $v1 row carries its action, version, backup and kasbah version (got '$out')"
assert 'grep -qE "^[0-9T:+-]+  deploy +$v2 +backups/[^ ]+ +[0-9]" <<<"$out"' \
    "and so does the $v2 row, whose backup column is the file that deploy took rather than \"no-backup\" (got '$out')"
assert 'grep -qxF "2 entries in $log_remote on $RIG_TARGET" <<<"$out"' \
    "the footer names the file it read, on the server it read it from (got '$out')"
assert '! grep -qF "archived" <<<"$out"' \
    "and says nothing about an archive, because rotation has had nothing to move (got '$out')"

history "$RIG_TARGET" --all; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "--all runs against a server with no archive yet (exit $rc: $(cli_err))"
assert 'grep -qxF "2 entries on $RIG_TARGET — 0 archived in $gz_remote, 2 active in $log_remote" <<<"$out"' \
    "and says the archive is empty rather than pretending it is not there (got '$out')"
assert '! grep -qF -- "-- rotated into" <<<"$out"' \
    "with no rotation line to draw (got '$out')"

changelog "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "kasbah changelog runs (exit $rc: $(cli_err))"
assert 'grep -qF "$RIG_TARGET runs $project $v2 (deploy," <<<"$out"' \
    "reading the deployed version out of the server's own record (got '$out')"
assert 'grep -qxF "v$v1..v$v2 — 1 commit" <<<"$out"' \
    "the range is the last two entries (got '$out')"
assert 'grep -qF "$v2_subject" <<<"$out"' "with the commit v$v2 tagged in it (got '$out')"

pending "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "kasbah pending runs (exit $rc: $(cli_err))"
assert 'grep -qF "nothing pending" <<<"$out"' \
    "HEAD at the deployed tag has nothing pending (got '$out')"

# --- After a rollback the rig really performed --------------------------------------
rollback "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the rollback failed (exit $rc) — the changelog case below cannot be judged" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 1
fi

changelog "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "changelog over a rollback runs (exit $rc: $(cli_err))"
assert 'grep -qF "$RIG_TARGET runs $project $v1 (rollback," <<<"$out"' \
    "what is running is the rollback's target, not the deploy above it (got '$out')"
assert 'grep -qF "after $v2 (deploy," <<<"$out"' \
    "and the entry before it is the deploy it replaced (got '$out')"
assert 'grep -qF "v$v2..v$v1 — none: $v1 is not ahead of the $v2 it replaced" <<<"$out"' \
    "so the range runs backwards, and is reported as that (got '$out')"
assert 'grep -qF "\`git log v$v1..v$v2\`" <<<"$out"' \
    "with the range that says what the rollback gave up (got '$out')"

pending "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert 'grep -qF "$RIG_TARGET runs $project $v1 (rollback," <<<"$out"' \
    "pending reads the same deployed version (got '$out')"
assert 'grep -qxF "v$v1..HEAD — 1 commit" <<<"$out"' \
    "and the commit the rollback left behind is pending again (got '$out')"
assert 'grep -qF "$v2_subject" <<<"$out"' "named (got '$out')"

# With VERSION the range ends at that tag, not HEAD: what deploying it would add.
pending "$RIG_TARGET" "$v2"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "kasbah pending VERSION runs (exit $rc: $(cli_err))"
assert 'grep -qxF "v$v1..v$v2 — 1 commit" <<<"$out"' \
    "the range ends at v$v2 rather than HEAD (got '$out')"
assert 'grep -qF "$v2_subject" <<<"$out"' "with the commit v$v2 tagged in it (got '$out')"
pending "$RIG_TARGET" "$v1"; rc=$?
out="$(cli_out)"
assert 'grep -qF "v$v1..v$v1 — nothing pending: v$v1 is the commit $RIG_TARGET is already running" <<<"$out"' \
    "the running version itself has nothing pending (got '$out')"
pending "$RIG_TARGET" 9.9.9; rc=$?
assert '[ "$rc" = "0" ]' "a VERSION with no tag is a warning, not a failure (exit $rc: $(cli_err))"
assert 'grep -qF "v9.9.9 is not a tag in this checkout" <<<"$(cli_err)"' \
    "saying the tag is missing here (got '$(cli_err)')"

# ==================================================================================
# A real rotation point
# ==================================================================================
# Two entries old enough for the cutoff, planted in the active log. Nothing here
# compresses them: the next deploy's own rd_rotate_log is what moves them, and
# what `--all` reads back is the archive that step wrote.
plant="$plant_ts1 deploy $plant_v1 no-backup kasbah=0.0.1 digest=-
$plant_ts2 rollback $plant_v2 $plant_backup kasbah=0.0.1 digest=-
$plant_bad"
if ! rig_ssh "cat > /tmp/kasbah-plant.log" <<<"$plant" >/dev/null 2>&1 \
   || ! rig_ssh "cd $projdir_remote && cat /tmp/kasbah-plant.log versions.log > versions.log.new && mv versions.log.new versions.log && rm -f /tmp/kasbah-plant.log" >/dev/null 2>&1; then
    echo "error: could not plant the pre-rotation entries in $log_remote" >&2
    exit 2
fi
gz_before=$(rig_ssh "[ -f $gz_remote ] && echo present || echo absent" 2>/dev/null | tr -d '\r')
assert '[ "$gz_before" = "absent" ]' \
    "there is no archive before the rotation runs (rig says '$gz_before')"

history "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert 'grep -qF "$plant_v1" <<<"$out"' \
    "the planted entries are in the active log while they are still there (got '$out')"
assert 'grep -qxF "6 entries in $log_remote on $RIG_TARGET" <<<"$out"' \
    "all six of them (got '$out')"
assert 'grep -qxF "!! entry 3 of versions.log is not a kasbah entry: $plant_bad" <<<"$out"' \
    "including the truncated one, shown as the bytes the file holds (got '$out')"
assert 'grep -qF "1 of them could not be read as a kasbah entry" <<<"$out"' \
    "and counted as one the table could not read (got '$out')"

# The deploy whose rotation moves them. HEAD is still v$v2, so this is the
# ordinary working-tree deploy.
deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the deploy that was to rotate the log failed (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 1
fi

gz_after=$(rig_ssh "[ -f $gz_remote ] && echo present || echo absent" 2>/dev/null | tr -d '\r')
assert '[ "$gz_after" = "present" ]' \
    "the deploy's rotation wrote $gz_remote (rig says '$gz_after')"
log="$(versions_log)"
assert '! grep -qF "$plant_ts1" <<<"$log"' \
    "and took the planted entries out of the active log (log: $log)"
archived=$(rig_ssh "zcat $gz_remote 2>/dev/null" 2>/dev/null | tr -d '\r')
assert '[ "$(grep -c . <<<"$archived")" = "2" ]' \
    "putting both of them in the archive (zcat said: $archived)"
assert 'grep -qF "$plant_bad" <<<"$log"' \
    "while the truncated line, which is this month's, stays in the active log (log: $log)"

# --- history without --all: the active log, and honest about the rest ---------------
history "$RIG_TARGET"; rc=$?
out_plain="$(cli_out)"
assert '[ "$rc" = "0" ]' "history runs against a rotated record (exit $rc: $(cli_err))"
assert '! grep -qF "$plant_v1" <<<"$out_plain"' \
    "plain history shows nothing that has been rotated out (got '$out_plain')"
assert '! grep -qF "$plant_backup" <<<"$out_plain"' \
    "not even the archived backup path that would widen its table (got '$out_plain')"
assert 'grep -qxF "5 entries in $log_remote on $RIG_TARGET" <<<"$out_plain"' \
    "it counts the active log (got '$out_plain')"
assert 'grep -qxF "!! entry 1 of versions.log is not a kasbah entry: $plant_bad" <<<"$out_plain"' \
    "the truncated line is still a row, now first (got '$out_plain')"
assert 'grep -qF "2 more entries archived in versions.log.gz" <<<"$out_plain"' \
    "and says how many it is not showing, so it does not read as the whole record (got '$out_plain')"

# --- history --all: the same table with the rotation point in it ---------------------
history "$RIG_TARGET" --all; rc=$?
out_all="$(cli_out)"
assert '[ "$rc" = "0" ]' "history --all runs against a rotated record (exit $rc: $(cli_err))"
assert '[ "$(cli_err)" = "" ]' "still with nothing on stderr (stderr: $(cli_err))"
assert 'grep -qF "$plant_v1" <<<"$out_all"' \
    "--all shows the archived entries (got '$out_all')"
assert 'grep -qF "$plant_backup" <<<"$out_all"' \
    "including the backup path only they carry (got '$out_all')"
assert 'grep -qxF "7 entries on $RIG_TARGET — 2 archived in $gz_remote, 5 active in $log_remote" <<<"$out_all"' \
    "counting both halves, and naming the file each is in (got '$out_all')"
n_arch=$(grep -nF "$plant_ts1" <<<"$out_all" | head -1 | cut -d: -f1)
n_sep=$(grep -n -- "-- rotated into versions.log.gz above / versions.log below --" <<<"$out_all" | cut -d: -f1)
n_act=$(grep -nE "^[0-9T:+-]+  deploy +$v1 " <<<"$out_all" | head -1 | cut -d: -f1)
assert '[ -n "$n_arch" ] && [ -n "$n_sep" ] && [ -n "$n_act" ]' \
    "the rotation point is drawn between the two halves (archived $n_arch, separator $n_sep, active $n_act)
        $out_all"
assert '[ "$n_arch" -lt "$n_sep" ] && [ "$n_sep" -lt "$n_act" ]' \
    "with the archive above it and the active log below — one record, oldest first
        (archived $n_arch, separator $n_sep, active $n_act)"

# The two tables are the same table plus the archive: every row plain history
# printed is in --all's, re-padded, and the extra rows are exactly the archived
# entries. Compared on the version column so the padding difference does not
# make every line differ.
plain_versions="$(grep "^20" <<<"$out_plain" | awk '{print $2, $3}')"
all_versions="$(grep "^20" <<<"$out_all" | awk '{print $2, $3}')"
assert '[ "$(grep -c . <<<"$plain_versions")" = "4" ] && [ "$(grep -c . <<<"$all_versions")" = "6" ]' \
    "--all has the two extra rows and nothing else (plain: $(tr "\n" "/" <<<"$plain_versions"), all: $(tr "\n" "/" <<<"$all_versions"))"
assert '[ "$(tail -4 <<<"$all_versions")" = "$plain_versions" ]' \
    "and its last four rows are the plain table, in the same order
        plain: $(tr "\n" "/" <<<"$plain_versions")
        all:   $(tr "\n" "/" <<<"$all_versions")"

# --- An archive this ssh user cannot read -------------------------------------------
# The rig's ssh user owns the files a deploy wrote (it is not root), so the mode
# is the one thing a suite can take away. Losing the archive must not stop the
# record being read — and the report must not read as the whole of it.
rig_ssh "chmod 000 $gz_remote" >/dev/null 2>&1
gz_mode=$(rig_ssh "stat -c %a $gz_remote" 2>/dev/null | tr -d '\r')
assert '[ "$gz_mode" = "0" ]' "the archive is unreadable to the ssh user (mode '$gz_mode')"

history "$RIG_TARGET" --all; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' \
    "an archive kasbah cannot read does not stop history (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "$gz_remote could not be read (the probe called it '"'"'unreadable'"'"')" <<<"$out"' \
    "the report says so, on stdout with the table (got '$out')"
assert 'grep -qF "not the whole record" <<<"$out"' \
    "in the words that stop it being read as complete (got '$out')"
assert '! grep -qF "$plant_v1" <<<"$out"' \
    "and none of the archived entries is in the table (got '$out')"
assert 'grep -qF "$gz_remote on $RIG_TARGET cannot be read" "$tmpdir/err"' \
    "with the transport's own warning on stderr, where the diagnosis goes (said '$(cli_err)')"
rig_ssh "chmod 644 $gz_remote" >/dev/null 2>&1

# --- An unreachable server ----------------------------------------------------------
# The scratch ssh config fences every host but the rig off with a ProxyCommand
# that fails, so this is a target ssh really cannot reach.
pending nobody@nowhere; rc=$?
assert '[ "$rc" = "3" ]' \
    "pending against a server that does not answer exits 3, not garbage (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(cli_out)" = "" ]' "with no report at all (stdout: $(cli_out))"
assert 'grep -qF "cannot reach nobody@nowhere" "$tmpdir/err"' \
    "and ssh's own failure named (said '$(cli_err)')"
history nobody@nowhere; rc=$?
assert '[ "$rc" = "3" ]' "history exits 3 the same way (exit $rc)"
changelog nobody@nowhere; rc=$?
assert '[ "$rc" = "3" ]' "and so does changelog (exit $rc)"

# --- Leave the rig as it was found, but only on success ---------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $image_web:$v1 $image_worker:$v1 $image_web:$v2 $image_worker:$v2 $image_web:current $image_worker:current" >/dev/null 2>&1
    rig_clean || fail=1
fi

exit "$fail"
