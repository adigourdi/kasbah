#!/usr/bin/env bash
# Integration test: `kasbah server init --with-backup`, the scheduled backup it
# installs, and `kasbah server backup-prune`, against the live rig and 8.0's
# two rest-server endpoints.
#
# What the hermetic suite cannot show, and what this one has to:
#
#   * the credential probe **refuses an init** whose credentials can delete —
#     driven by pointing the same code path at the full-access endpoint, which
#     is what 8.0's second endpoint is for;
#   * a snapshot really taken, by the scheduled path, in the container the stack
#     installs — not by a restic this suite ran;
#   * the **VPS credential is refused a delete** of that snapshot, with the
#     operator credential succeeding against the same snapshot in the same
#     repository, so the refusal cannot be "restic never tried";
#   * a project's data, its backups/ and its .env are all in the snapshot, the
#     mail stack is in a repository of its own, and a project with no client
#     record is reported;
#   * `server backup-prune` prunes from *this* machine;
#   * and the restore drill of docs/backup.md, executed for real: snapshot,
#     rig_clean, server init, restore, `kasbah deploy`, project back with its
#     data. That is phase 8's exit criterion 3.
#
# Every repository is named under a per-run prefix, because rest-server answers
# 405 to a DELETE on a repository path and there is no way to remove one over
# the wire (measured in 8.0). The few-KB skeletons go with `tests/rig/rig.sh down`.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
data=/apps/data
marker="$apps/.kasbah/server.json"
bdir="$apps/.kasbah/backup"
# The names templates/backup/compose.yml declares. Read off the rig by these,
# never by a `docker ps` guess.
backup_container=kasbah-backup

project=demo
project_version=1.0.0
client=rig-client
# The passwords this run gives kasbah. Operator-supplied is the whole point (D2),
# so they are values this suite chooses and then uses to read the snapshots back.
client_pass='rig-client-repo-password'
mail_pass='rig-mail-repo-password'
orphan_pass='rig-orphan-repo-password'

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")

# One prefix per run, under both endpoints, so a second run of this suite is not
# reading the first one's snapshots.
run_id="b$$-$(date +%s)"

# Every value read back off the rig is CR-stripped through this: ssh's own
# output is line-based and a suite that compared against a stray carriage return
# would fail with a message that renders as a cursor jump.
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

# --- Preconditions ------------------------------------------------------------
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
    echo "       $RIG_BACKUP_URL (append-only) and $RIG_BACKUP_ADMIN_URL (full access)" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir"; then
    echo "error: could not build the scratch HOME and ssh wrapper under $tmpdir" >&2
    exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "error: no docker on this machine — server backup-prune runs restic here (D13)" >&2
    exit 2
fi
# The network the rig's endpoints are on. A container on docker's default bridge
# cannot reach another bridge (measured), and `backup-prune` runs restic on this
# machine — so the suite passes the same --docker-network an operator would use
# for storage that is only reachable from one network.
rig_network=kasbah-rig_default
if ! docker network inspect "$rig_network" >/dev/null 2>&1; then
    echo "error: no $rig_network docker network — the rig's compose project names it" >&2
    exit 2
fi
if ! docker image inspect "$RIG_RESTIC_IMAGE" >/dev/null 2>&1; then
    if ! docker pull "$RIG_RESTIC_IMAGE" >/dev/null 2>&1; then
        echo "error: could not pull $RIG_RESTIC_IMAGE on this machine" >&2
        exit 2
    fi
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi
# Pulled up front so a cold rig's download is not inside a timed step, and so
# "restic is not there" reads as an environment problem rather than a refusal.
if ! rig_ssh "docker pull $RIG_RESTIC_IMAGE" >/dev/null 2>&1; then
    echo "error: the rig could not pull $RIG_RESTIC_IMAGE" >&2
    exit 2
fi

vps_base="${RIG_BACKUP_REPO_BASE}$run_id/"
admin_base="${RIG_BACKUP_ADMIN_REPO_BASE}$run_id/"

init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
prune() { kasbah_cli server backup-prune "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
deploy() (
    cd "$projdir" || return 2
    kasbah_cli deploy "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)

# The rig cannot apply cgroup limits: its nested cgroup v2 root is in threaded
# mode, so any container started with --cpus or --memory fails to create
# (tests/rig/README.md). Nothing here special-cases kasbah — what changes is the
# *server marker*, rewritten to 0/0, which Docker reads as "no limit" and
# injection then carries into every .env end to end. Called after each init that
# a deploy follows; tests/integration/spine_test.sh does the same for the same
# reason.
relax_limits() {
    local probe rc=0 current new
    probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || return 0
    if ! grep -qF "threaded mode" <<<"$probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $rc)" >&2
        sed 's/^/       | /' <<<"$probe" >&2
        return 1
    fi
    current=$(rig_ssh "cat $marker" 2>/dev/null)
    new=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$current" 2>/dev/null)
    [ -n "$new" ] || return 1
    rig_ssh "cat > $marker" <<<"$new" >/dev/null 2>&1 || return 1
    return 0
}

backup_flags=(--with-backup --no-backup-env
              --backup-password="$client=$client_pass"
              --backup-password="mail=$mail_pass"
              --backup-password="orphan=$orphan_pass")

# The scheduled path, run on demand: the same function the sleep-until-02:00
# loop calls, in the same container, with the same environment. It is a
# documented operator command (`back up now`), not a hook this suite invented.
backup_now() {
    rig_ssh "docker exec $backup_container $apps/.kasbah/bin/kasbah remote backup once" 2>&1
}

# Snapshot ids in one repository, read with the repository's own password.
snapshot_ids() {
    local out
    out=$(RIG_RESTIC_PASSWORD="$2" rig_restic "$1" snapshots --json 2>/dev/null) || return 1
    jq -r '.[].short_id' <<<"$out" 2>/dev/null
}
snapshot_paths() {
    local out
    out=$(RIG_RESTIC_PASSWORD="$2" rig_restic "$1" snapshots --json 2>/dev/null) || return 1
    jq -r '.[].paths[]' <<<"$out" 2>/dev/null | sort -u
}

# ==================================================================================
# The credential probe refuses an init whose credentials can delete
# ==================================================================================
# The same code path, pointed at the full-access endpoint. If this passed, the
# probe would be decorative — and every "the VPS cannot delete" assertion below
# would rest on the rig's configuration rather than on kasbah's.
init "${traefik_flags[@]}" --no-mail --with-backup --no-backup-env \
     --backup-repo-base="$admin_base" \
     --backup-password="$client=$client_pass"; rc=$?
assert '[ "$rc" != "0" ]' \
    "server init refuses credentials that can delete their own snapshots (exit $rc)
        said: $(cli_err)"
assert 'grep -qF "can DELETE" "$tmpdir/err"' \
    "and says which property failed (said '$(cli_err)')"
state=$(rig_ssh "docker inspect $backup_container >/dev/null 2>&1 && echo present || echo absent" 2>/dev/null)
assert '[ "$(nocr "$state")" = "absent" ]' \
    "and no backup container was started with them (container: $state)"
present=$(rig_ssh "test -f $marker && echo yes || echo no" 2>/dev/null)
assert '[ "$(nocr "$present")" = "no" ]' \
    "and the run left no marker, so init did not complete (marker: $present)"

# The paired positive from the other side: the credentials it refused really do
# work — they were able to create the repository and write to it, which is the
# only reason there was anything to try deleting.
probe_snaps=$(snapshot_ids "${admin_base}kasbah.probe/" kasbah-probe | wc -l)
assert '[ "$probe_snaps" -ge 1 ]' \
    "the refused credentials had written to the probe repository first (snapshots: $probe_snaps)"

# ==================================================================================
# The golden path: the append-only credential is accepted
# ==================================================================================
# The mail directories are made by hand rather than by --with-mail: what is under
# test is that mail gets a repository of its own (D7), and the runner's rule is
# "<apps>/mail is a directory", not "DMS is healthy". A full mail stack would add
# two image pulls and a certificate that cannot issue on the rig.
rig_ssh "sudo mkdir -p $apps/mail $data/mail && sudo chown -R stevedore:stevedore $apps/mail $data/mail &&
         printf 'MAIL_HOSTNAME=mail.$rig_domain\n' > $apps/mail/.env &&
         printf 'a mailbox\n' > $data/mail/mailbox.txt" >/dev/null 2>&1

init "${traefik_flags[@]}" --no-mail "${backup_flags[@]}" \
     --backup-repo-base="$vps_base" --backup-at=04:17 --backup-jitter=42; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init --with-backup failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
assert 'grep -qF "credentials: append-only" "$tmpdir/err"' \
    "the run reports what the probe established (said '$(cli_err)')"

# The base this suite uses carries its credential in the URL, because that is
# what a `rest:` target is. restic redacts its own; kasbah printing the password
# beside it in the same output made kasbah the less careful of the two.
assert '! grep -qF "append-only-secret" "$tmpdir/err"' \
    "no credential is printed anywhere in a successful run (said '$(cli_err)')"
assert 'grep -qF "kasbah-vps:***@" "$tmpdir/err"' \
    "the repository is still named, with the userinfo redacted (said '$(cli_err)')"
assert 'grep -qF "repository base carries a credential" "$tmpdir/err"' \
    "and the run says so once (said '$(cli_err)')"
assert 'grep -qF "mode 644 by contract" "$tmpdir/err"' \
    "naming where that string then ends up"
marker_mode=$(rig_ssh "stat -c '%a' $marker" 2>/dev/null)
assert '[ "$(nocr "$marker_mode")" = "644" ]' \
    "which is true: the marker really is world-readable (got '$marker_mode')"

# Everything the stack leaves on the server, read off the rig rather than
# believed from kasbah's summary. This list is `server destroy`'s brief.
listing=$(rig_ssh "find $bdir -printf '%m %y %p\n' | sort" 2>/dev/null)
assert 'grep -qF "700 d $bdir" <<<"$listing"'        "the backup directory is 700 (got '$listing')"
assert 'grep -qF "700 d $bdir/repos" <<<"$listing"'  "and so is the password directory"
assert 'grep -qF "644 f $bdir/compose.yml" <<<"$listing"' "the compose file is 644 and carries no secret"
assert '! grep -qF "$bdir/backup.sh" <<<"$listing"'      "the runner is kasbah's own binary, not a script beside the stack (D2)"
assert 'grep -qF "600 f $bdir/env" <<<"$listing"'         "the env file is 600 — it holds the repository URL"
assert 'grep -qF "600 f $bdir/repos/$client.pass" <<<"$listing"' "each password file is 600"
assert 'grep -qF "600 f $bdir/repos/mail.pass" <<<"$listing"'    "mail included"

envfile=$(rig_ssh "cat $bdir/env" 2>/dev/null)
assert 'grep -qF "KASBAH_BACKUP_REPO_BASE=$vps_base" <<<"$envfile"' \
    "the repository base landed verbatim, unparsed (got '$(grep KASBAH_BACKUP <<<"$envfile")')"
composed=$(rig_ssh "cat $bdir/compose.yml" 2>/dev/null)
assert '! grep -qF "append-only-secret" <<<"$composed"' \
    "and the credential in it is nowhere in the 644 compose file"

marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
assert '[ "$(jq -r .backup.enabled <<<"$marker_json")" = "true" ]' \
    "the marker records that backups are on (got '$(jq -c .backup <<<"$marker_json")')"
assert '[ "$(jq -r .backup.repo_base <<<"$marker_json")" = "$vps_base" ]' "with the repository base"
assert '[ "$(jq -r .backup.at <<<"$marker_json")" = "04:17" ]' "the slot"
assert '[ "$(jq -r .backup.jitter <<<"$marker_json")" = "42" ]' "the jitter"
assert '[ "$(jq -r .backup.retention.daily <<<"$marker_json")" = "7" ]' "and the retention"

state=$(rig_ssh "docker inspect -f '{{.State.Status}}' $backup_container" 2>/dev/null)
assert '[ "$(nocr "$state")" = "running" ]' "the scheduler is running (got '$state')"
logs=$(rig_ssh "docker logs $backup_container 2>&1 | head -5" 2>/dev/null)
assert 'grep -qF "scheduled daily at 04:17 plus 42s jitter" <<<"$logs"' \
    "and says when it will next run (said '$logs')"

# ==================================================================================
# The probe cannot be pointed somewhere other than where the backups go
# ==================================================================================
# `docker --env-file` is last-wins, so an operator entry naming RESTIC_REPOSITORY
# would have aimed the credential probe at one repository while the scheduled
# backup wrote to another — and init would then have reported "append-only"
# about a URL nothing had contacted. Two ways in, and both are shut.
init "${traefik_flags[@]}" --no-mail --with-backup --backup-repo-base="$vps_base" \
     --backup-env="RESTIC_REPOSITORY=$admin_base/bypass.probe"; rc=$?
assert '[ "$rc" != "0" ]' \
    "--backup-env=RESTIC_REPOSITORY= is refused (exit $rc: $(cli_err))"
assert 'grep -qF "kasbah owns" "$tmpdir/err"' "as a key kasbah owns (said '$(cli_err)')"

# The same key already in the operator's half of the env file — written by hand,
# or by a kasbah too old to refuse the flag. The env merge copies that half
# through untouched, so nothing else would have caught it.
rig_ssh "printf 'RESTIC_REPOSITORY=%s\n' '${admin_base}bypass.probe' >> $bdir/env" >/dev/null 2>&1
init "${traefik_flags[@]}" --no-mail --with-backup --backup-repo-base="$vps_base"; rc=$?
assert '[ "$rc" != "0" ]' \
    "an env file that already sets RESTIC_REPOSITORY is refused (exit $rc: $(cli_err))"
assert 'grep -qF "which kasbah sets itself" "$tmpdir/err"' "and says why (said '$(cli_err)')"
assert 'grep -qF "Remove the line" "$tmpdir/err"' "and what to do about it"
rig_ssh "sed -i '/^RESTIC_REPOSITORY=/d' $bdir/env" >/dev/null 2>&1

# The check is not "no RESTIC_ key at all": the ones restic reads that are not
# about *which* repository or *what* key stay the operator's.
init "${traefik_flags[@]}" --no-mail --with-backup --backup-repo-base="$vps_base" \
     --backup-env=RESTIC_CACHE_DIR=/tmp/kasbah-rig-cache; rc=$?
assert '[ "$rc" = "0" ]' \
    "an operator's own RESTIC_ key is accepted (exit $rc: $(cli_err))"
envfile=$(rig_ssh "cat $bdir/env" 2>/dev/null)
assert 'grep -qF "RESTIC_CACHE_DIR=/tmp/kasbah-rig-cache" <<<"$envfile"' \
    "and lands in the env file (got '$(grep RESTIC <<<"$envfile")')"

# ==================================================================================
# A real project, and the two shapes D12 is about
# ==================================================================================
projdir="$tmpdir/$project"
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$project_version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
printf '\nclient: %s\n' "$client" >> "$projdir/kasbah.yml"
( cd "$projdir" && git -c user.email=f@k.test -c user.name=f -c commit.gpgsign=false \
    commit -aqm "declare a client" && git tag -f "v$project_version" >/dev/null ) 2>/dev/null

# The .env the deploy would otherwise stop to ask for. Written on the server, so
# the env step finds one and the drift check passes — and so the restore drill
# below has a secret with a value only this VPS knows.
rig_ssh "mkdir -p $apps/$project && printf 'DEMO_GREETING=only-on-this-vps\n' > $apps/$project/.env" >/dev/null 2>&1

# Immediately before the deploy, not merely after the first init: every init in
# this suite rewrites the marker, and the limits it recomputes are ones this rig
# cannot apply.
if ! relax_limits; then
    echo "error: could not make the rig's resource limits applicable" >&2
    exit 2
fi

deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: kasbah deploy failed (exit $rc) — there is nothing to back up" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
record=$(rig_ssh "cat $apps/$project/.kasbah-client" 2>/dev/null)
assert '[ "$(nocr "$record")" = "$client" ]' \
    "deploy rendered the effective client onto the server (got '$record')"

# Something under the data bind mount and something under backups/, so the scope
# assertions below have all three of docs/backup.md's paths to find.
rig_ssh "printf 'the database\n' > $data/$project/db.txt &&
         printf 'a dump\n' > $apps/$project/backups/pre-deploy-test.sql" >/dev/null 2>&1

# A project with no client record at all — what a project deployed before
# backups existed looks like, and the case D12 exists to make visible.
rig_ssh "mkdir -p $apps/orphan $data/orphan &&
         printf 'ORPHAN=1\n' > $apps/orphan/.env" >/dev/null 2>&1

# ==================================================================================
# The scheduled path takes a snapshot
# ==================================================================================
run_out=$(backup_now); rc=$?
assert '[ "$rc" = "0" ]' "the scheduled backup runs (exit $rc)
        output: $run_out"
assert 'grep -qF "$client: backing up" <<<"$run_out"' \
    "backing the project's client repository up (said '$run_out')"
assert 'grep -qF "mail: backing up" <<<"$run_out"' "and mail's, separately"

# D12's fallback, reported rather than silent: `orphan` has no record, so it is
# filed under its own name — correct, and named out loud, because a project whose
# manifest says otherwise is in the wrong repository until it is deployed again.
assert 'grep -qF "filed under their own name" <<<"$run_out"' \
    "a project with no client record is reported (said '$run_out')"
assert 'grep -qE "filed under their own name:.* orphan" <<<"$run_out"' "by name"
assert 'grep -qF "orphan: backing up" <<<"$run_out"' \
    "and is backed up all the same, under its own name — which is what client: defaults to"

client_repo="${vps_base}$client/"
mail_repo="${vps_base}mail/"
mapfile -t ids < <(snapshot_ids "$client_repo" "$client_pass")
assert '[ "${#ids[@]}" = "1" ]' \
    "one snapshot in ${client}'s repository (got ${#ids[@]}: ${ids[*]-})"
if [ "${#ids[@]}" -lt 1 ]; then
    echo "error: no snapshot — every assertion below would be vacuous" >&2
    exit 2
fi

paths=$(snapshot_paths "$client_repo" "$client_pass")
assert 'grep -qxF "$data/$project" <<<"$paths"'          "the data bind mount is in it (got '$paths')"
assert 'grep -qxF "$apps/$project/backups" <<<"$paths"'  "the hook-produced dumps are"
assert 'grep -qxF "$apps/$project/.env" <<<"$paths"'     "and the .env — the only copy of the project's secrets"
assert '! grep -qF "$data/mail" <<<"$paths"' \
    "and the mail stack's data is not (got '$paths')"

mail_paths=$(snapshot_paths "$mail_repo" "$mail_pass")
assert 'grep -qxF "$data/mail" <<<"$mail_paths"'      "mail's data is in mail's own repository (D7) (got '$mail_paths')"
assert 'grep -qxF "$apps/mail/.env" <<<"$mail_paths"' "with its .env"
assert '! grep -qF "$apps/$project" <<<"$mail_paths"' "and no client's files"

# The contents, not just the paths: a snapshot that recorded a path and stored
# nothing would satisfy everything above.
restored=$(RIG_RESTIC_PASSWORD="$client_pass" rig_restic "$client_repo" \
    dump "${ids[0]}" "$data/$project/db.txt" 2>/dev/null)
assert '[ "$(nocr "$restored")" = "the database" ]' \
    "and the bytes are really in it (got '$restored')"

# ==================================================================================
# The VPS credential cannot delete — and the operator's can
# ==================================================================================
# 8.0 proved the *harness* enforces this. What is proved here is that kasbah's
# own configuration hands the VPS a credential under that enforcement: the
# repository, the password and the URL are all the ones `server init` put on the
# server, read back out of its own env file.
server_base=$(rig_ssh "sed -n 's/^KASBAH_BACKUP_REPO_BASE=//p' $bdir/env" 2>/dev/null)
server_base="${server_base//$'\r'/}"
assert '[ "$server_base" = "$vps_base" ]' \
    "the repository the VPS writes to is the one on the server (got '$server_base')"

# A second snapshot, so `forget` has one to remove that is not the last: 8.0
# measured that every "delete everything" spelling of forget exits non-zero on
# restic's own argument check before reaching the server, which would read as a
# refusal.
backup_now >/dev/null 2>&1
mapfile -t ids < <(snapshot_ids "${server_base}$client/" "$client_pass")
assert '[ "${#ids[@]}" = "2" ]' "two snapshots to choose from (got ${#ids[@]}: ${ids[*]-})"
if [ "${#ids[@]}" != "2" ]; then
    echo "error: without two snapshots there is nothing to refuse a delete of" >&2
    exit 2
fi
victim="${ids[0]}"
survivor="${ids[1]}"

# The verdict is the repository, not restic's exit status. Measured here: with
# both probe snapshots holding identical content, removing one frees no pack, so
# `--prune` has nothing to delete, succeeds, and **restic exits 0** having
# printed `Remove(<snapshot/…>) failed: … 403` and `unable to remove`. 8.0 saw a
# non-zero exit for the same command because its two snapshots differed and the
# prune then tried to delete a pack. So the status is a property of the
# *content*, and the only thing that answers "was the history destroyed" is the
# history. `server init`'s credential probe reads it the same way, for the same
# reason.
out=$(RIG_RESTIC_PASSWORD="$client_pass" rig_restic "${server_base}$client/" \
        forget "$victim" --prune 2>&1); rc=$?
mapfile -t after < <(snapshot_ids "${server_base}$client/" "$client_pass")
assert '[ "${#after[@]}" = "2" ]' \
    "the credential kasbah gave the VPS is refused a delete: both snapshots are still
        there afterwards (got ${#after[@]}: ${after[*]-}, restic exit $rc)
        output: $out"
assert '[[ " ${after[*]-} " == *" $victim "* ]]' "$victim among them (got: ${after[*]-})"
assert 'grep -qF "403 Forbidden" <<<"$out"' \
    "and it was the server that refused it, not restic declining to try (output: $out)"
assert 'grep -qF "unable to remove" <<<"$out"' "which restic itself reports (output: $out)"

# The paired positive, from the other side of the same mechanism: the operator's
# credential removes that same snapshot from that same repository. Only the
# credential differs.
out=$(RIG_RESTIC_PASSWORD="$client_pass" rig_restic "${admin_base}$client/" \
        forget "$victim" --prune 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "the operator's credential removes it (exit $rc)
        output: $out"
mapfile -t after < <(snapshot_ids "${server_base}$client/" "$client_pass")
assert '[ "${after[*]-}" = "$survivor" ]' \
    "leaving $survivor, seen through the VPS's own endpoint (got: ${after[*]-})"

# ==================================================================================
# A repository with no password is named, not skipped in silence
# ==================================================================================
# Last of the backup runs, because it adds a snapshot: the counts above are
# exact, and a case that changed them would make them prove something else.
rig_ssh "mkdir -p $apps/stray && printf 'S=1\n' > $apps/stray/.env" >/dev/null 2>&1
stray_out=$(backup_now); stray_rc=$?
assert '[ "$stray_rc" != "0" ]' \
    "a repository with no password makes the run report failure (exit $stray_rc)
        output: $stray_out"
assert 'grep -qE "NOT backed up:.* stray" <<<"$stray_out"' \
    "naming what was not backed up (said '$stray_out')"
assert 'grep -qF "server init" <<<"$stray_out"' "and how to give it one"
rig_ssh "rm -rf $apps/stray" >/dev/null 2>&1

# ==================================================================================
# server backup-prune runs here, not on the VPS
# ==================================================================================
prune --repo-base="$admin_base" --no-env --docker-network="$rig_network" \
      --keep-daily=1 --keep-weekly=0 --keep-monthly=0 --dry-run; rc=$?
assert '[ "$rc" = "0" ]' "backup-prune plans (exit $rc: $(cli_err))"
# On **stdout**: this is the command that deletes backup history for good, so
# `backup-prune > prune.log` has to capture the plan and the outcome both
# (docs/cli.md — only warning: and error: lines go to stderr).
assert 'grep -qF "  $client — what would be removed" "$tmpdir/out"' \
    "and found the repositories from the server's own list (said '$(cli_out)')"
assert 'grep -qF "  mail — what would be removed" "$tmpdir/out"' "mail included"
assert 'grep -qF "  kasbah.probe — what would be removed" "$tmpdir/out"' "and the probe repository"
assert 'grep -qF "run here and not on the VPS" "$tmpdir/out"' "saying where restic ran"

# The proof that it really ran locally: the VPS was never asked to run restic.
# Its docker has no such container, and the only restic on the rig is the
# scheduler, which is not what a prune is.
restic_names=$(rig_ssh "docker ps -a --filter ancestor=$RIG_RESTIC_IMAGE --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | sort | tr '\n' ' ')
assert '[ "$restic_names" = "$backup_container " ]' \
    "the only restic container on the rig is the scheduler — a prune that ran there
        would have had to start one, and every other restic this feature runs is --rm
        (got '$restic_names')"

# Two snapshots of the same day, same host, same paths are one retention group,
# so `keep 1 daily` has exactly one to remove. Asserted as a *drop*, not as
# "no more than before": that would have been satisfied by a prune that did
# nothing at all, which is the shape a broken credential produces.
backup_now >/dev/null 2>&1
before=$(snapshot_ids "${server_base}$client/" "$client_pass" | wc -l)
if [ "$before" -lt 2 ]; then
    echo "error: only $before snapshot(s) before the prune — there would be nothing to remove" >&2
    exit 2
fi
prune --repo-base="$admin_base" --no-env --docker-network="$rig_network" \
      --repo="$client" --keep-daily=1 --keep-weekly=0 --keep-monthly=0 --yes; rc=$?
assert '[ "$rc" = "0" ]' "backup-prune prunes (exit $rc: $(cli_err))"
assert 'grep -qF "forgetting and pruning" "$tmpdir/out"' \
    "with the outcome on stdout beside the plan (said '$(cli_out)')"
assert 'grep -qF "Pruned 1 repositories" "$tmpdir/out"' \
    "counting only the repository --repo= named (said '$(cli_out)')"
after_prune=$(snapshot_ids "${server_base}$client/" "$client_pass" | wc -l)
assert '[ "$after_prune" -lt "$before" ]' \
    "and really removes something ($before before, $after_prune after) — a prune that
        did nothing would satisfy \"no more than before\""
assert '[ "$after_prune" = "1" ]' \
    "leaving exactly the one the policy keeps (got $after_prune)"

# Declining changes nothing, and says so rather than exiting in silence.
prune --repo-base="$admin_base" --no-env --docker-network="$rig_network" \
      --repo="$client" --keep-daily=1 --keep-weekly=0 --keep-monthly=0; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable confirmation stops the prune (exit $rc)"
assert 'grep -qF -- "--yes" "$tmpdir/err"' "naming the flag that would have answered (said '$(cli_err)')"
still=$(snapshot_ids "${server_base}$client/" "$client_pass" | wc -l)
assert '[ "$still" = "$after_prune" ]' "and removed nothing ($after_prune before, $still after)"

# ==================================================================================
# A silent endpoint is bounded, not waited on for ever
# ==================================================================================
# 10.77.29.99 is inside the rig's own subnet and assigned to nothing, so a
# connection to it is neither refused nor answered — the shape that left restic
# waiting and the scheduler never returning to `sleep`. Both halves are bounded
# now, and both are checked against the clock rather than against a message.
black_hole="rest:http://10.77.29.99:8000/wedge-$run_id/"

# First, a working run that gives the *container* the short bound. A refused init
# never reaches the start step — the credentials are written, the probe refuses,
# and nothing is shipped or restarted — so the scheduler would otherwise still be
# running under whatever bound the last successful run gave it.
init "${traefik_flags[@]}" --no-mail "${backup_flags[@]}" \
     --backup-repo-base="$vps_base" --backup-timeout=30; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: could not put the stack on a short bound (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
bound=$(rig_ssh "cat $bdir/state/status" 2>/dev/null | sed -n 's/^timeout=//p')
assert '[ "$(nocr "$bound")" = "30" ]' \
    "--backup-timeout reaches the container that runs restic (status says '$bound')"

started=$(date +%s)
init "${traefik_flags[@]}" --no-mail --with-backup --no-backup-env \
     --backup-repo-base="$black_hole" --backup-timeout=30; rc=$?
elapsed=$(( $(date +%s) - started ))
assert '[ "$rc" != "0" ]' "server init against a silent endpoint fails (exit $rc: $(cli_err))"
assert '[ "$elapsed" -lt 300 ]' \
    "and comes back inside its own bound rather than hanging (took ${elapsed}s)"
assert 'grep -qF "cannot reach" "$tmpdir/err"' "saying it could not reach the repository (said '$(cli_err)')"
assert 'grep -qF -- "--backup-timeout=" "$tmpdir/err"' \
    "and names the bound, because a silent address is the likeliest cause (said '$(cli_err)')"

# The credentials are written before the probe — it has to test the ones that
# will be in effect — so the stack that is already running now points at the
# black hole. That is the wedge, and it has to end in a failed run rather than
# in a container that is "running" for ever.
# The wrapper's own 120 s bound is raised for this one call: three repositories
# at two restic calls each, every one of them waiting out its 30 s, is longer
# than any other remote step in this suite — and being cut off by the harness is
# exactly the thing being distinguished from being cut off by kasbah.
started=$(date +%s)
wedge_out=$(RIG_WORK_TIMEOUT=420 backup_now); wedge_rc=$?
elapsed=$(( $(date +%s) - started ))
RIG_WORK_TIMEOUT=120
assert '[ "$wedge_rc" != "0" ]' "the scheduled path fails against it (exit $wedge_rc)"
assert '[ "$elapsed" -lt 300 ]' \
    "inside the bound rather than for ever (took ${elapsed}s)
        output: $wedge_out"
assert 'grep -qF "could not initialise the repository" <<<"$wedge_out"' \
    "naming the repository it gave up on (said '$wedge_out')"

# And the record the run left, which is what the healthcheck reads and what
# anything other than `docker logs` has to go on.
status=$(rig_ssh "cat $bdir/state/status" 2>/dev/null)
assert 'grep -qxF "state=sleeping" <<<"$status"' \
    "the wedged run went back to waiting rather than staying in it (got '$(tr "\n" " " <<<"$status")')"
assert 'grep -qE "^deadline=[0-9]+$" <<<"$status"' "with a deadline the healthcheck can read"
assert 'grep -qxF "timeout=30" <<<"$status"' "and the bound it ran under"
assert 'grep -qxF "last_run_status=failed" <<<"$status"' \
    "recorded as failed, which is what a reader other than \`docker logs\` needs (got '$(tr "\n" " " <<<"$status")')"
health=$(rig_ssh "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $backup_container" 2>/dev/null)
assert '[ "$(nocr "$health")" != "none" ]' \
    "and the container declares a healthcheck at all — without one a wedged
        scheduler is something restart: unless-stopped can never act on (got '$health')"

# Put the good credentials back: the drill below restores from the repository
# this suite has been filling, and the failed init above left the env file
# pointing at the black hole.
init "${traefik_flags[@]}" --no-mail "${backup_flags[@]}" \
     --backup-repo-base="$vps_base" --backup-at=04:17 --backup-jitter=42; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: could not restore the working backup configuration (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# ==================================================================================
# The restore drill — docs/backup.md → Restore, phase 8's exit criterion 3
# ==================================================================================
# rig_clean reaches the nested daemon and /apps and nothing else; the snapshot
# store is a volume on this machine's Docker. So what follows is a fresh VPS with
# the history intact, which is the disaster the whole feature exists for.
snapshot_before=$(snapshot_ids "${server_base}$client/" "$client_pass" | tail -1)
assert '[ -n "$snapshot_before" ]' "there is a snapshot to restore from (got '$snapshot_before')"

if ! rig_clean; then
    echo "error: rig_clean failed before the restore drill" >&2
    exit 2
fi
gone=$(rig_ssh "test -e $apps/$project && echo present || echo gone" 2>/dev/null)
assert '[ "$(nocr "$gone")" = "gone" ]' \
    "the project is really gone from the rig (got '$gone') — else the restore proves nothing"

init "${traefik_flags[@]}" --no-mail --no-backup; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on the fresh rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
if ! relax_limits; then
    echo "error: could not make the rig's resource limits applicable" >&2
    exit 2
fi

# `--target /` because the snapshot's paths *are* the server's paths: the backup
# container mounts <apps> and <data> at their own names, which makes this one
# command rather than a mapping exercise. Spelled out rather than run through
# rig_restic, which mounts nothing writable — /apps is bind-mounted into the
# restore container, and every path in the snapshot is under it.
restore_out=$(rig_ssh "docker run --rm -e RESTIC_PASSWORD='$client_pass' -v $apps:$apps \
    $RIG_RESTIC_IMAGE -r '${server_base}$client/' restore '$snapshot_before' --target /" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "the snapshot restores onto the fresh rig (exit $rc)
        output: $restore_out"

back=$(rig_ssh "cat $data/$project/db.txt 2>&1" 2>/dev/null)
assert '[ "$(nocr "$back")" = "the database" ]' "the data came back (got '$back')"
back=$(rig_ssh "cat $apps/$project/.env 2>&1" 2>/dev/null)
assert 'grep -qF "DEMO_GREETING=only-on-this-vps" <<<"$back"' \
    "and the .env, whose value existed nowhere but that VPS (got '$back')"
back=$(rig_ssh "cat $apps/$project/backups/pre-deploy-test.sql 2>&1" 2>/dev/null)
assert '[ "$(nocr "$back")" = "a dump" ]' "and the hook-produced dump (got '$back')"

# The restore is only worth anything if the project comes back up on it. The
# .env is what makes this deploy possible at all: without one, the env step has
# nothing to render from and no terminal to ask at, and exits 5.
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "and kasbah deploy brings the project back on it (exit $rc: $(cli_err))"
if [ "$rc" = "0" ]; then
    up=$(rig_ssh "docker inspect -f '{{.State.Status}}' $project-web" 2>/dev/null)
    assert '[ "$(nocr "$up")" = "running" ]' "with its container running (got '$up')"
    served=$(rig_ssh "docker exec $project-web cat /usr/share/nginx/html/index.html 2>&1 | head -1" 2>/dev/null)
    assert '[ -n "$served" ]' "and serving its site (got '$served')"
    greeting=$(rig_ssh "docker exec $project-web printenv DEMO_GREETING" 2>/dev/null)
    assert '[ "$(nocr "$greeting")" = "only-on-this-vps" ]' \
        "with the restored secret in its environment — the whole point of backing .env up (got '$greeting')"
fi

exit "$fail"
