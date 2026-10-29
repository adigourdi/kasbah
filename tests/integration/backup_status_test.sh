#!/usr/bin/env bash
# Integration test: what `kasbah server status` and `kasbah check --server` say
# about a real backup stack, against the live rig and 8.0's append-only endpoint.
#
# 8.3 built the stack and its last-run record; nothing read the record, so a
# backup that had silently stopped was visible only in `docker logs`. This suite
# is the rig half of the readers: three states of one real stack, reported
# **distinctly**, with `check --server` failing the last.
#
# What only the rig can show, and what the hermetic halves in
# tests/server_status_test.sh and tests/check_test.sh therefore cannot:
#
#   * the record read back is one the real runner (`kasbah remote backup`) wrote,
#     with the fields it really writes rather than the fields this suite thinks
#     it writes — the two hermetic suites craft their own bytes, and a writer
#     that changed would leave them both green;
#   * a run that really failed, through the real code path: a project whose
#     repository has no password is not backed up, and the run says so — and,
#     before that run, both readers naming that repository at the same moment
#     rather than a day apart;
#   * a scheduler container really stopped, whose still-valid record would
#     otherwise read as a working backup for about a day;
#   * that container started again, and the run it performed before the stop
#     still in the record the fresh process writes on its way back up;
#   * the repositories a real `server init --with-backup` created passwords for,
#     against the project tree a real server has;
#   * the container's own healthcheck verdict beside the record it reads;
#   * **that both readers write nothing**, digested off the rig.
#
# What it deliberately does not show: a scheduler past its own deadline. That
# needs a slot to come and go, which is a day away on a real stack; it is
# covered by crafted record bytes in both hermetic suites.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which establishes a known starting state.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
data=/apps/data
marker="$apps/.kasbah/server.json"
bdir="$apps/.kasbah/backup"
record="$bdir/state/status"
backup_container=kasbah-backup

# The project the manifest names, and a second one created later with no
# repository password — which is how a real run is made to fail.
project=demo
nopass=orphan
project_pass='rig-demo-repo-password'

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

# One prefix per run under the append-only endpoint: rest-server answers 405 to
# a DELETE on a repository path, so a repository cannot be removed over the wire
# and a second run of this suite must not read the first one's snapshots.
run_id="s$$-$(date +%s)"

nocr() { printf '%s' "${1//$'\r'/}"; }

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh" >&2
    echo "       is the rig up? tests/rig/rig.sh up" >&2
    exit 2
fi
if [ ! -f "$RIG_BACKUP_ENV" ]; then
    echo "error: no $RIG_BACKUP_ENV — the rig is up without its backup harness" >&2
    echo "       rig.sh writes it once both endpoints answer: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_backup_ready; then
    echo "error: the backup endpoints did not both answer from inside the rig" >&2
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
if ! rig_ssh "docker pull $RIG_RESTIC_IMAGE" >/dev/null 2>&1; then
    echo "error: the rig could not pull $RIG_RESTIC_IMAGE" >&2
    exit 2
fi

vps_base="${RIG_BACKUP_REPO_BASE}$run_id/"

init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
status()  { kasbah_cli server status "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
check() (
    cd "$projdir" || return 2
    kasbah_cli check --server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)

# The scheduled path, run on demand: the same function the sleep-until-02:00
# loop calls, in the same container, with the same environment. A documented
# operator command, not a hook this suite invented.
backup_now() { rig_ssh "docker exec $backup_container $apps/.kasbah/bin/kasbah remote backup once" 2>&1; }

# Type, mode, owner, mtime and content of the apps and data trees. Two files are
# left out for the reason tests/integration/check_server_test.sh leaves acme.json
# out: another process owns them and rewrites them on its own schedule, so a
# digest covering them would fail for something the readers never did. The
# scheduler rewrites its record on every state change, and Traefik its store.
tree_digest() {
    rig_ssh "{ find $apps $data ! -name acme.json ! -name status -printf '%y %m %u:%g %T@ %p\n' | sort;
               find $apps $data -type f ! -name acme.json ! -name status -exec sha256sum {} + | sort; } | sha256sum" 2>/dev/null
}

# --- A server with a project and a backup stack -----------------------------------
# The project directory is made by hand rather than by a deploy: what is under
# test is what the two readers say about the *backup stack*, and a full deploy
# would add the two-step env dance and a container pull for a tree the runner
# only ever reads. The runner's rule for "this is a project" is a directory
# under <apps> that is not one of kasbah's own, which is exactly what this is.
# `server init` refuses an apps path it did not create and does not own, so the
# two roots are handed over here rather than left root-owned by the mkdir.
rig_ssh "sudo mkdir -p $apps/$project $data/$project &&
         sudo chown stevedore:stevedore $apps $data &&
         sudo chown -R stevedore:stevedore $apps/$project $data/$project &&
         printf 'DOMAIN=demo.test\n' > $apps/$project/.env &&
         printf 'some data\n' > $data/$project/state.txt" >/dev/null 2>&1
present=$(rig_ssh "test -f $apps/$project/.env && echo yes || echo no" 2>/dev/null)
if [ "$(nocr "$present")" != yes ]; then
    echo "error: could not create the project tree on the rig — there is nothing to back up" >&2
    exit 2
fi

init "${traefik_flags[@]}" --no-mail --with-backup --no-backup-env \
     --backup-repo-base="$vps_base" --backup-at=04:17 --backup-jitter=42 \
     --backup-password="$project=$project_pass"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init --with-backup failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The scheduler writes `starting` as its first act and `sleeping` immediately
# after. Waited for rather than assumed: everything below reads that file, and a
# suite racing the container's first write would report "no record" for a stack
# that was about to have one.
waited=0
while [ "$waited" -lt 30 ]; do
    got=$(rig_ssh "test -f $record && echo yes || echo no" 2>/dev/null)
    [ "$(nocr "$got")" != yes ] || break
    sleep 1
    waited=$((waited + 1))
done
if [ "$(nocr "$got")" != yes ]; then
    echo "error: the backup scheduler wrote no record at $record in ${waited}s" >&2
    rig_ssh "docker logs $backup_container 2>&1 | tail -20" >&2
    exit 2
fi

# The local project `check --server` runs in. The fixture is compliant as it
# stands, so this run's exit status is the Server section's alone.
projdir="$tmpdir/$project"
cp -a "$repo_dir/tests/fixtures/$project" "$projdir" || exit 2

# ==================================================================================
# State 1 — a stack that has never fired
# ==================================================================================
# The record is there and no run has finished. This is the state the plan's
# watch-out is about: reporting it the same way as a stack that stopped a month
# ago is how the whole rule becomes decoration.
status; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "server status reports a fresh backup stack (exit $rc)
$out
$(cli_err)"
assert 'grep -qF "kasbah-backup    running" <<<"$out"' \
    "the scheduler container, found by the compose labels the template declares (said '$out')"
assert 'grep -qF "last run         none yet" <<<"$out"' \
    "a stack that has never fired says exactly that (said '$out')"
assert 'grep -qF "daily at 04:17 plus 42s jitter" <<<"$out"' \
    "with the schedule this init asked for (said '$out')"
assert 'grep -qF "repositories     $project" <<<"$out"' \
    "and the repository a real init created a password for (said '$out')"
assert '! grep -qF "no password" <<<"$out"' \
    "which is not reported as missing one (said '$out')"
# The base carries its credential in the URL, because that is what a `rest:`
# target is; the marker holding it is mode 644 on the server.
assert '! grep -qF "$RIG_BACKUP_PASSWORD" <<<"$out"' \
    "no credential in the repository base reaches the report (said '$out')"
assert 'grep -qF "$RIG_BACKUP_USER:***@" <<<"$out"' \
    "which is still named, redacted the way server init redacts it (said '$out')"

check; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "check --server does not fail a stack that has never fired (exit $rc)
$out
$(cli_err)"
assert 'grep -qF "⚠ backups are configured on $RIG_TARGET and no run has finished yet" <<<"$out"' \
    "it warns and says which fact this is (said '$out')"
assert '! grep -qF "✗ the last backup" <<<"$out"' \
    "and never reports a failure it has no evidence for (said '$out')"

# ==================================================================================
# State 2 — a healthy stack
# ==================================================================================
run_out=$(backup_now); run_rc=$?
if [ "$run_rc" != "0" ]; then
    echo "error: the scheduled backup path failed on a stack init had just accepted (exit $run_rc)" >&2
    sed 's/^/       | /' <<<"$run_out" >&2
    exit 2
fi

status; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "server status reports a stack that has run (exit $rc)
$out"
assert 'grep -qE "last run         ok [0-9]+s ago — repositories: $project" <<<"$out"' \
    "the run that just happened, its age off the server's own clock, and what it reached (said '$out')"
assert 'grep -qE "next run         in [0-9]+" <<<"$out"' \
    "and when the next one is due (said '$out')"
assert '! grep -qF "none yet" <<<"$out"' \
    "the never-fired sentence is gone, so the two states are told apart (said '$out')"

check; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "check --server passes a stack whose last run succeeded (exit $rc)
$out"
assert 'grep -qE "✓ the last backup on $RIG_TARGET finished [0-9]+s ago and succeeded \(repositories: $project\)" <<<"$out"' \
    "with what it reached (said '$out')"

# The record the two readers read is one the real runner wrote. Pinned against
# the file itself, so a writer that renamed a field takes this suite red rather
# than leaving both hermetic suites green on bytes they crafted themselves.
rec="$(rig_ssh "cat $record" 2>/dev/null)"
assert 'grep -qF "last_run_status=ok" <<<"$rec"' \
    "the runner really wrote a status field with that spelling (record: $rec)"
assert 'grep -q "^deadline=[0-9]" <<<"$rec"' \
    "and the deadline both readers judge staleness by (record: $rec)"
assert 'grep -q "^last_run_finished=[0-9]" <<<"$rec"' "and when the run finished (record: $rec)"

# The stack's own healthcheck reads the same file with the same question, and
# `docker inspect` is where that verdict shows. Two readers of one field, and
# they must agree — which is why there is one comparison and not two.
health=$(rig_ssh "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $backup_container" 2>/dev/null)
assert '[ "$(nocr "$health")" != "unhealthy" ]' \
    "the container's own healthcheck agrees the stack is fine (got '$health')"

# --- Neither reader writes anything ------------------------------------------------
digest_before=$(tree_digest)
status >/dev/null 2>&1
check  >/dev/null 2>&1
digest_after=$(tree_digest)
assert '[ -n "$digest_before" ] && [ "$digest_after" = "$digest_before" ]' \
    "server status and check --server change nothing on the server"
# The digest is only evidence if it can tell.
rig_ssh "touch $bdir/repos/.kasbah-digest-probe" >/dev/null 2>&1
assert '[ "$(tree_digest)" != "$digest_before" ]' \
    "the digest notices a bare touch inside the backup stack — else the assertion above proves nothing"
rig_ssh "rm -f $bdir/repos/.kasbah-digest-probe" >/dev/null 2>&1

# ==================================================================================
# State 3 — a run that failed
# ==================================================================================
# Through the real code path and not a crafted record: a repository with no
# password is not backed up (docs/backup.md → Scope), the runner returns
# non-zero for it, and the run it writes says `failed`. A project created after
# init has no password, which is the ordinary way a server arrives in this state.
rig_ssh "sudo mkdir -p $apps/$nopass && sudo chown -R stevedore:stevedore $apps/$nopass &&
         printf 'DOMAIN=orphan.test\n' > $apps/$nopass/.env" >/dev/null 2>&1
# **Before any run has seen it.** This is the window the two readers used to
# disagree in: the record still says the last backup worked, and a repository
# nothing can write to has appeared beside it. `server status` printed one fact
# and `check --server` printed the other, for however long it took the 02:00
# slot to come round.
status
out="$(cli_out)"
assert 'grep -qF "no password      $nopass" <<<"$out"' \
    "server status names the repository with no password at once (said '$out')"
check; rc=$?
cout="$(cli_out)"
assert 'grep -qF "⚠ backup repositories on $RIG_TARGET with no password: $nopass" <<<"$cout"' \
    "and so does check --server, on the same server at the same moment (said '$cout')"
assert 'grep -qF "✓ the last backup on $RIG_TARGET" <<<"$cout"' \
    "while the record still says the last run worked, because it did (said '$cout')"
assert '[ "$rc" = "0" ]' "which is a warning, not a failure (exit $rc)
$cout"

run_out=$(backup_now); run_rc=$?
assert '[ "$run_rc" != "0" ]' \
    "a repository with no password makes the run fail rather than skip quietly (exit $run_rc)
$run_out"
assert 'grep -qF "no password" <<<"$run_out"' "and the run says so (said '$run_out')"

status; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "server status reports a failed run and still exits 0 — it reports, check judges (exit $rc)
$out"
assert 'grep -qE "last run         FAILED [0-9]+s ago" <<<"$out"' \
    "the failed run is named as one (said '$out')"
assert 'grep -qF "repositories backed up: $project" <<<"$out"' \
    "with the repository it did reach, which is not the same as none (said '$out')"
assert 'grep -qF "repositories     $project $nopass" <<<"$out"' \
    "the new project is a repository of its own (said '$out')"
assert 'grep -qF "no password      $nopass" <<<"$out"' \
    "and it is the one with no password (said '$out')"

check; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "6" ]' "check --server fails a stack whose last run failed (exit $rc)
$out
$(cli_err)"
assert 'grep -qE "✗ the last backup on $RIG_TARGET FAILED [0-9]+s ago" <<<"$out"' \
    "saying so against a run that really failed (said '$out')"
assert 'grep -qF "docker logs $backup_container" <<<"$out"' \
    "and where the reason is (said '$out')"
assert 'grep -qF "with no password: $nopass" <<<"$out"' \
    "with the repository that caused it still named, now that a run has seen it (said '$out')"

# The three states produced three different sentences. Asserted together,
# because "reported distinctly" is the plan's word and each assertion above only
# proves one of them.
assert '! grep -qF "none yet" <<<"$out"' \
    "a failed run is not reported as a stack that has never fired (said '$out')"

# ==================================================================================
# State 4 — the scheduler container is not running
# ==================================================================================
# `docker compose -p kasbah-backup down` leaves the last `sleeping` record
# looking valid for about a day. The record is only current while something is
# maintaining it, and a container that is not running is an observation rather
# than an absence — which is why it is allowed to be a failure.
rig_ssh "docker stop $backup_container" >/dev/null 2>&1
stopped=$(rig_ssh "docker inspect -f '{{.State.Status}}' $backup_container" 2>/dev/null)
if [ "$(nocr "$stopped")" = running ]; then
    echo "error: could not stop $backup_container on the rig" >&2
    exit 2
fi

status; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "server status reports a stopped scheduler (exit $rc)
$out"
assert 'grep -qF "kasbah-backup    exited" <<<"$out"' \
    "as the container docker really reports (said '$out')"

check; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "6" ]' "check --server fails a server whose scheduler is not running (exit $rc)
$out
$(cli_err)"
assert 'grep -qF "✗ the backup scheduler on $RIG_TARGET is exited, so nothing is being shipped off-box" <<<"$out"' \
    "saying so against a container this suite really stopped (said '$out')"
assert '! grep -qF "✓ the last backup" <<<"$out"' \
    "and the still-valid record it left behind is not read as a working backup (said '$out')"

# The record the stopped scheduler left behind, so what happens next can be
# waited for rather than raced: `since` is the field the runner moves on every
# write, whatever else it says.
stopped_since=$(nocr "$(rig_ssh "sed -n 's/^since=//p' $record" 2>/dev/null)")
if [ -z "$stopped_since" ]; then
    echo "error: could not read since= out of $record while the scheduler was stopped" >&2
    exit 2
fi
rig_ssh "docker start $backup_container" >/dev/null 2>&1
restarted=$(rig_ssh "docker inspect -f '{{.State.Status}}' $backup_container" 2>/dev/null)
if [ "$(nocr "$restarted")" != running ]; then
    echo "error: could not start $backup_container again — the cases below need it" >&2
    exit 2
fi
# An ssh that answered nothing is not a record that moved, and breaking on one
# would race exactly what this loop exists to serialise. Counted in wall-clock
# seconds too: thirty round trips to the rig are not thirty seconds, and the
# message has to name the time that really passed.
wait_from=$(date +%s)
waited=0
fresh_since="$stopped_since"
while [ "$waited" -lt 30 ]; do
    fresh_since=$(nocr "$(rig_ssh "sed -n 's/^since=//p' $record" 2>/dev/null)")
    [ -z "$fresh_since" ] || [ "$fresh_since" = "$stopped_since" ] || break
    sleep 1
    waited=$((waited + 1))
done
if [ -z "$fresh_since" ] || [ "$fresh_since" = "$stopped_since" ]; then
    echo "error: the restarted scheduler rewrote no record in $(( $(date +%s) - wait_from ))s" >&2
    rig_ssh "docker logs $backup_container 2>&1 | tail -20" >&2
    exit 2
fi

# **A restart carries the last run forward.** The runner reads its own record
# back before it writes its first one, so a process that performed no run still
# reports the one the file remembers. The alternative is the four no-history
# placeholders, and `last_run_status=-` is what both readers turn into "no run
# has finished yet" — on a stack that ran minutes ago, and for however long it
# takes the next slot to come round. What is carried here is State 3's failed
# run, because that is the last run this stack really had; a restart is not an
# event that changes it.
rec="$(rig_ssh "cat $record" 2>/dev/null)"
assert 'grep -qE "^last_run_started=[0-9]{9,}" <<<"$rec"' \
    "a restarted scheduler still knows when the last run began (record: $rec)"
assert 'grep -qF "last_run_status=failed" <<<"$rec"' \
    "and how it went — State 3's run, still the last one this stack had (record: $rec)"
assert 'grep -qF "last_run_repos= $project" <<<"$rec"' \
    "and the repository it did reach before it failed (record: $rec)"

check; rc=$?
out="$(cli_out)"
assert '! grep -qF "is exited, so nothing is being shipped off-box" <<<"$out"' \
    "the scheduler being down stops being the failure once it is up (said '$out')"
assert '[ "$rc" = "6" ]' "and what is left is the run the record carried across the restart (exit $rc)
$out
$(cli_err)"
# `[0-9]+[smh]` and not `[0-9]+s`: backuprec.Ago switches to minutes at 60
# seconds, and the gap between State 3's run and this read is about half of that
# on a rig that is a container on this machine. A suite that goes red on a slow
# day pins the day, not the behaviour.
assert 'grep -qE "✗ the last backup on $RIG_TARGET FAILED [0-9]+[smh] ago" <<<"$out"' \
    "reported again rather than forgotten (said '$out')"
assert '! grep -qF "no run has finished yet" <<<"$out"' \
    "and never as a stack that has never fired (said '$out')"

# --- Done -------------------------------------------------------------------------------
rig_clean || fail=1
exit "$fail"
