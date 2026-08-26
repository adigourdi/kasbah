#!/usr/bin/env bash
# Integration test: `kasbah server destroy` against the live rig, over a server
# prepared with `--with-mail` and `--with-backup` and carrying a real deploy.
#
# What only the rig can show, and what the hermetic suite therefore cannot:
#
#   * **the sites never go down.** Not "were up afterwards" — a sample taken
#     only at the end cannot tell "never went down" from "went down and came
#     back". Two independent witnesses run here: a continuous HTTP sampler on
#     the rig for the whole of the destroy, and the container ids and start
#     times of Traefik and the project before and after;
#   * **a project still comes up after.** The .env strip is the dangerous
#     rewrite, and a lost KASBAH_MEM_LIMIT breaks nothing until the next
#     restart — which is exactly when the new owner would find it. So the
#     project is brought down and up again, from the server's own compose file,
#     and has to serve again;
#   * the backup stack really **stopped**, its container, volume and network
#     really gone from a real daemon — and the restic repository it wrote to
#     still holding its snapshot, because that is operator property;
#   * `docker-mailserver`'s postfix-accounts.cf surviving on a real mail stack.
#
# The rig is treated as given: this suite never starts, resets or stops it.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no backup harness).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
data=/apps/data
marker="$apps/.kasbah/server.json"
pointer=/etc/kasbah/apps-path
bdir="$apps/.kasbah/backup"
backup_container=kasbah-backup
backup_volume=kasbah-backup-cache
backup_network=kasbah-backup_default

project=demo
version=1.0.0
# The host the fixture's Traefik fragment claims, out of its own manifest —
# `rig.test` is the *server's* apex and this project's domain is not under it.
project_host=demo.test
projdir_remote="$apps/$project"
# A second project, planted rather than deployed: what is under test over it is
# the *walk* — that destroy visits every project under the apps path in order,
# not only the one this suite deployed — and that costs one directory rather
# than a second fixture and a second image.
planted=beta
planted_remote="$apps/$planted"

rig_domain=rig.test
postmaster_pw='rig-postmaster-pw'
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")
mail_pass='rig-mail-repo-password'
relay_password='agency-owned-smtp-key'

run_id="d$$-$(date +%s)"

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

projdir="$tmpdir/$project"
init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
kasbah_bounded() (
    cd "${KASBAH_CWD:-$projdir}" || return 2
    timeout "${DEPLOY_TIMEOUT:-300}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$RIG_REPO_DIR/bin/kasbah" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy()  { kasbah_bounded deploy "$@"; }
destroy() {
    timeout 300 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        "$RIG_REPO_DIR/bin/kasbah" server destroy "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}

remote_exists() { rig_ssh "test -e '$1' && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
labelled() {
    rig_ssh "docker ps -a --filter label=com.docker.compose.project=$1 --format '{{.Names}}'" \
        2>/dev/null | tr -d '\r' | LC_ALL=C sort | tr '\n' ' '
}
# What Traefik answers for a host, waited for rather than sampled: the file
# provider notices a fragment appearing "within a couple of seconds"
# (docs/traefik.md). The deadline lives on the far side — one session, not sixty.
wait_http() {   # wait_http <host> <expected-code>
    rig_ssh "c=; for i in \$(seq 1 30); do
                 c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $1' http://127.0.0.1/)
                 [ \"\$c\" != '$2' ] || break
                 sleep 1
             done
             printf '%s' \"\$c\"" 2>/dev/null | tr -d '\r'
}

# The uptime witness. One curl after another, on the rig, for the whole of the
# destroy — every answer appended to a file. `200` means Traefik answered *and*
# the project's container answered through it, so one stream witnesses both: a
# Traefik that went down gives 000, a container that went down gives 502, and a
# fragment that vanished gives 404.
sampler_file=/tmp/kasbah-destroy-samples
sampler_stop=/tmp/kasbah-destroy-stop
# Each answer carries the rig's own clock beside it. A floor on the *count* does
# not bound the *coverage*: measured here, the gap between samples is a few
# milliseconds, so twenty samples is a fifth of a second against a ten-second
# operation — a sampler that died just after starting would pass a count floor
# and produce a green "the site never went down".
sampler_start() {
    rig_ssh "rm -f $sampler_file $sampler_stop
             nohup sh -c 'while [ ! -f $sampler_stop ]; do
                 printf \"%s %s\n\" \
                     \"\$(curl -s -o /dev/null -w \"%{http_code}\" --max-time 3 \
                            -H \"Host: $project_host\" http://127.0.0.1/)\" \
                     \"\$(date +%s.%N)\" >> $sampler_file
             done' </dev/null >/dev/null 2>&1 &
             sleep 1" >/dev/null 2>&1
}
# The rig's clock, so the window and the samples are measured by one clock.
rig_now() { rig_ssh "date +%s.%N" 2>/dev/null | tr -d '\r'; }
sampler_stop_and_read() {
    rig_ssh "touch $sampler_stop; sleep 2; cat $sampler_file; rm -f $sampler_file $sampler_stop" \
        2>/dev/null | tr -d '\r'
}

# --- A prepared server, with mail and with backups --------------------------------
init "${traefik_flags[@]}" --with-mail --postmaster-password="$postmaster_pw" \
     --with-backup --no-backup-env --backup-repo-base="$vps_base" \
     --backup-password="$project=rig-$project-password" \
     --backup-password="mail=$mail_pass"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init --with-mail --with-backup failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do (docs/phases/02-spine.md → Findings). The **values still travel**
# into every .env, which is what this suite needs: `cpus: ${KASBAH_CPU_LIMIT}`
# with nothing behind it is a compose file that will not come up.
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

# --- The deployed project ---------------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the $project fixture a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
deploy "$RIG_TARGET" >/dev/null 2>&1
rig_ssh "cd $projdir_remote && ./scripts/setup-env.sh $projdir_remote" </dev/null >/dev/null 2>&1
deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: the $project deploy failed (exit $rc) — there is nothing to de-brand" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The second project, planted with exactly the footprint a deploy leaves plus
# one file kasbah did not write, so the scripts/ rule has something to protect.
rig_ssh "mkdir -p $planted_remote/scripts $planted_remote/backups
         printf 'deploy 0.9.0 2026-01-01T00:00:00Z 0.1.0\n' > $planted_remote/versions.log
         printf 'gz\n' > $planted_remote/versions.log.gz
         : > $planted_remote/.deploy.lock
         printf '$planted\n' > $planted_remote/.kasbah-client
         printf '#!/bin/sh\n' > $planted_remote/scripts/remote-deploy.sh
         printf '#!/bin/sh\n' > $planted_remote/scripts/setup-env.sh
         printf 'operator notes\n' > $planted_remote/scripts/operator-notes.txt
         printf 'x\n' > $planted_remote/backups/dump.sql.gz
         printf 'services: {}\n' > $planted_remote/compose.yml" >/dev/null 2>&1
rig_ssh "cat > $planted_remote/.env" <<'ENVFILE' >/dev/null 2>&1
BETA_SECRET=beta-only-secret
# >>> kasbah managed block - do not edit, rewritten on every deploy >>>
KASBAH_CPU_LIMIT=0
KASBAH_MEM_LIMIT=0
# <<< kasbah managed block <<<
BETA_TRAILING=yes
ENVFILE

# The operator's relay block, set by hand exactly as templates/mail/env tells an
# operator to set it. This is the agency-owned secret the whole command exists
# to keep off the handed-over machine.
rig_ssh "printf '%s\n%s\n%s\n' 'DEFAULT_RELAY_HOST=[smtp-relay.example.com]:587' \
             'RELAY_USER=agency-login' 'RELAY_PASSWORD=$relay_password' >> $apps/mail/.env" \
    >/dev/null 2>&1

# --- Everything the destroy is about to remove, proved to be there first --------------
#
# Every "X is gone" below is worth nothing without its "X was here". These are
# read off the rig, not believed from kasbah's own summary.
for path in "$marker" "$bdir/env" "$bdir/compose.yml" "$bdir/backup.sh" \
            "$bdir/repos/mail.pass" "$apps/mail/kasbah.yml" \
            "$projdir_remote/versions.log" "$projdir_remote/scripts/remote-deploy.sh" \
            "$projdir_remote/scripts/setup-env.sh" "$projdir_remote/.kasbah-client" \
            "$planted_remote/versions.log.gz" "$planted_remote/.deploy.lock"; do
    assert '[ "$(remote_exists "$path")" = yes ]' "before the destroy, $path is on the server"
done
assert '[ "$(remote_exists "$pointer")" = yes ]' "and so is the discovery pointer $pointer"
env_before=$(rig_ssh "cat $projdir_remote/.env" 2>/dev/null | tr -d '\r')
assert 'grep -qF "KASBAH_CPU_LIMIT=" <<<"$env_before"' \
    "the project's .env carries the injected limits (got: $(grep KASBAH <<<"$env_before" | tr '\n' ' '))"
assert 'grep -qF "kasbah managed block" <<<"$env_before"' "inside a managed block with its sentinels"
assert 'grep -qF "DEMO_GREETING=" <<<"$env_before"' "and the project's own value"
mail_env_before=$(rig_ssh "cat $apps/mail/.env" 2>/dev/null | tr -d '\r')
assert 'grep -qF "$relay_password" <<<"$mail_env_before"' \
    "the operator's relay password is on the server before the destroy"
accounts_before=$(rig_ssh "cat $data/mail/dms/config/postfix-accounts.cf" 2>/dev/null | tr -d '\r')
assert '[ -n "$accounts_before" ]' "and docker-mailserver has a postmaster account"
bstate=$(nocr "$(rig_ssh "docker inspect -f '{{.State.Status}}' $backup_container" 2>/dev/null)")
assert '[ "$bstate" = running ]' "the backup scheduler is running before the destroy (got '$bstate')"
# `docker volume inspect` prints `[]` on stdout as well as an error on stderr
# for a name that is not there, so the verdict is its exit status and not its
# output.
vol_state() { rig_ssh "docker volume inspect $1 >/dev/null 2>&1 && echo present || echo gone" 2>/dev/null | tr -d '\r'; }
net_state() { rig_ssh "docker network inspect $1 >/dev/null 2>&1 && echo present || echo gone" 2>/dev/null | tr -d '\r'; }
assert '[ "$(vol_state $backup_volume)" = present ]' "and its cache volume exists"
assert '[ "$(net_state $backup_network)" = present ]' "and its network"

# A real snapshot in a real repository, so "the repositories are not touched"
# below is a statement about something. The scheduled path, run on demand — the
# documented `back up now` command.
rig_ssh "docker exec $backup_container sh $bdir/backup.sh once" >/dev/null 2>&1
snaps_before=$(RIG_RESTIC_PASSWORD="$mail_pass" rig_restic "${vps_base}mail/" snapshots --json 2>/dev/null \
               | jq -r '.[].short_id' 2>/dev/null | wc -l)
assert '[ "$snaps_before" -ge 1 ]' \
    "the backup stack has pushed a snapshot to ${vps_base}mail (snapshots: $snaps_before)"

served=$(wait_http "$project_host" 200)
if [ "$served" != 200 ]; then
    echo "error: $project_host answers '$served' before any destroy — nothing to keep serving" >&2
    exit 2
fi

# The second uptime witness, immune to a sampler that missed its window: a
# container that was restarted has a different start time, and one that was
# recreated has a different id.
stamp() { rig_ssh "docker inspect -f '{{.Id}} {{.State.StartedAt}}' $1" 2>/dev/null | tr -d '\r'; }
traefik_before="$(stamp traefik)"
web_before="$(stamp $project-web)"
assert '[ -n "$traefik_before" ] && [ -n "$web_before" ]' \
    "both containers this suite reasons about have an id and a start time"

# --- A run nobody answered ----------------------------------------------------------
#
# No terminal and no --yes: the tri-state's give-up branch against a real
# server. It must stop, and it must have changed nothing at all.
destroy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ]' "with no terminal and no --yes, destroy stops rather than assuming (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF -- "--yes" "$tmpdir/err"' "naming the flag that would have answered (stderr: $(cli_err))"
assert 'grep -qF "to remove" "$tmpdir/out"' \
    "and it printed the plan first, so the question is about something (stdout: $(cli_out))"
assert '[ "$(remote_exists "$marker")" = yes ]' "a run nobody answered removed no marker"
assert '[ "$(remote_exists "$projdir_remote/versions.log")" = yes ]' "and no deploy record"
assert '[ "$(nocr "$(rig_ssh "docker inspect -f '{{.State.Status}}' $backup_container" 2>/dev/null)")" = running ]' \
    "and left the backup stack running"

# --- Entries under <apps> that are not project names do not block the command ------------
#
# Each of these is plausible on a server about to be handed over, and each used
# to stop the whole command dead **after** both confirmations had been answered.
for odd in "Notes.txt" "README.md" "Old-Site" ".DS_Store"; do
    rig_ssh "printf 'operator content\n' > '$apps/$odd'" >/dev/null 2>&1
done

# --- The destroy, with the sites sampled throughout ------------------------------------
sampler_start
t_start="$(rig_now)"
destroy "$RIG_TARGET" --yes; rc=$?
t_end="$(rig_now)"
samples="$(sampler_stop_and_read)"
destroy_out="$(cli_out)"
destroy_err="$(cli_err)"

assert '[ "$rc" = 0 ]' "the destroy exits 0 (exit $rc)
        stdout: $destroy_out
        stderr: $destroy_err"

sample_n=$(grep -c . <<<"$samples")
codes="$(awk '{print $1}' <<<"$samples")"
bad_samples=$(grep -v '^200$' <<<"$codes" | sort | uniq -c | tr '\n' ' ')
first_t="$(awk 'NR==1{print $2}' <<<"$samples")"
last_t="$(awk 'END{print $2}' <<<"$samples")"
assert '[ "$sample_n" -ge 20 ]' \
    "the uptime sampler really sampled through the destroy ($sample_n samples)"
# The floor above bounds nothing on its own. What has to hold is that the
# samples **bracket** the operation: the first was taken before the destroy
# started and the last after it returned, so there is no window it missed.
assert '[ -n "$first_t" ] && [ -n "$last_t" ] && [ -n "$t_start" ] && [ -n "$t_end" ]' \
    "the sampler and the destroy were both timed (first=$first_t last=$last_t start=$t_start end=$t_end)"
assert 'awk -v a="$first_t" -v b="$t_start" "BEGIN{exit !(a<=b)}"' \
    "the first sample was taken before the destroy started ($first_t vs $t_start)"
assert 'awk -v a="$last_t" -v b="$t_end" "BEGIN{exit !(a>=b)}"' \
    "and the last after it returned, so the whole operation is inside the window ($last_t vs $t_end)"
assert '[ -z "$(grep -v "^200$" <<<"$codes")" ]' \
    "and every one of the $sample_n samples in that window was 200: the site never went down,
        not merely came back — other answers: ${bad_samples:-none}"
assert '[ "$traefik_before" = "$(stamp traefik)" ]' \
    "Traefik was never restarted or recreated
        before: $traefik_before
        after:  $(stamp traefik)"
assert '[ "$web_before" = "$(stamp $project-web)" ]' \
    "and neither was $project-web
        before: $web_before
        after:  $(stamp $project-web)"

# --- Everything on the list is gone ------------------------------------------------------
for path in "$marker" "$apps/.kasbah" "$bdir" "$apps/mail/kasbah.yml" \
            "$projdir_remote/versions.log" "$projdir_remote/versions.log.gz" \
            "$projdir_remote/scripts" "$projdir_remote/.deploy.lock" \
            "$projdir_remote/.kasbah-client" \
            "$planted_remote/versions.log" "$planted_remote/versions.log.gz" \
            "$planted_remote/.deploy.lock" "$planted_remote/.kasbah-client" \
            "$planted_remote/scripts/remote-deploy.sh" "$planted_remote/scripts/setup-env.sh"; do
    assert '[ "$(remote_exists "$path")" = no ]' "after the destroy, $path is gone"
done
assert '[ "$(remote_exists "$pointer")" = no ]' "the discovery pointer is gone"
assert '[ "$(remote_exists /etc/kasbah)" = no ]' "and /etc/kasbah with it — it held nothing else"
assert '[ "$(remote_exists "$planted_remote/scripts/operator-notes.txt")" = yes ]' \
    "while a file in scripts/ that kasbah did not write stays, and the directory with it"
for odd in "Notes.txt" "README.md" "Old-Site" ".DS_Store"; do
    assert '[ "$(remote_exists "$apps/$odd")" = yes ]' \
        "and $apps/$odd — not a project name, so not kasbah's to touch"
done
assert 'grep -qF "not a project name" "$tmpdir/out"' \
    "and the plan said out loud that it walked past them (stdout: $(cli_out))"

# The backup stack: stopped, and every artifact of it gone from a real daemon.
assert '[ -z "$(labelled kasbah-backup)" ]' \
    "no container of the backup stack remains (left: '$(labelled kasbah-backup)')"
assert '[ "$(vol_state $backup_volume)" = gone ]' "the cache volume is gone"
assert '[ "$(net_state $backup_network)" = gone ]' "and the network"
# The paired positive from the other side: the repository the credentials opened
# is untouched and still holds the snapshot. Agency-owned secrets leave; the
# operator's property does not.
snaps_after=$(RIG_RESTIC_PASSWORD="$mail_pass" rig_restic "${vps_base}mail/" snapshots --json 2>/dev/null \
              | jq -r '.[].short_id' 2>/dev/null | wc -l)
assert '[ "$snaps_after" = "$snaps_before" ]' \
    "the restic repository still holds its $snaps_before snapshot(s) — it is operator property (got $snaps_after)"

# --- The .env, value by value ---------------------------------------------------------------
env_after=$(rig_ssh "cat $projdir_remote/.env" 2>/dev/null | tr -d '\r')
assert '! grep -qF "kasbah managed block" <<<"$env_after"' \
    "the managed-block sentinel comments are gone from $project's .env (got: $env_after)"
assert 'grep -qF "KASBAH_CPU_LIMIT=" <<<"$env_after"' \
    "but KASBAH_CPU_LIMIT stayed — compose interpolates it into cpus: (got: $env_after)"
assert 'grep -qF "KASBAH_MEM_LIMIT=" <<<"$env_after"' "and KASBAH_MEM_LIMIT into mem_limit:"
assert 'grep -qF "DEMO_GREETING=" <<<"$env_after"' "and the project's own value"
# Byte for byte, not "the keys I remembered to check": the whole file minus the
# two comment lines, and nothing else.
expected_env="$(grep -vF 'kasbah managed block' <<<"$env_before")"
assert '[ "$expected_env" = "$env_after" ]' \
    "the .env is its old self minus exactly the two sentinel lines
$(diff <(printf '%s\n' "$expected_env") <(printf '%s\n' "$env_after") | sed 's/^/        /')"

beta_env_after=$(rig_ssh "cat $planted_remote/.env" 2>/dev/null | tr -d '\r')
assert '[ "$beta_env_after" = "BETA_SECRET=beta-only-secret
KASBAH_CPU_LIMIT=0
KASBAH_MEM_LIMIT=0
BETA_TRAILING=yes" ]' \
    "and the planted project's .env is exactly its five kept lines (got: $beta_env_after)"

# --- Mail ------------------------------------------------------------------------------------
mail_env_after=$(rig_ssh "cat $apps/mail/.env" 2>/dev/null | tr -d '\r')
assert '! grep -qF "$relay_password" <<<"$mail_env_after"' \
    "the operator's relay password is off the server (got: $mail_env_after)"
assert '! grep -qF "RELAY_USER" <<<"$mail_env_after"' "and the relay user"
assert 'grep -qE "^MAIL_HOSTNAME=" <<<"$mail_env_after"' \
    "while MAIL_HOSTNAME stays — the stack does not start without it (got: $mail_env_after)"
assert 'grep -qE "^DOMAIN=" <<<"$mail_env_after"' "and DOMAIN"
assert 'grep -qE "^DATA_PATH=" <<<"$mail_env_after"' "and DATA_PATH"
assert '[ "$(nocr "$(rig_ssh "stat -c %a $apps/mail/.env" 2>/dev/null)")" = 600 ]' \
    "and the file is still 600"
accounts_after=$(rig_ssh "cat $data/mail/dms/config/postfix-accounts.cf" 2>/dev/null | tr -d '\r')
assert '[ "$accounts_before" = "$accounts_after" ]' \
    "the postmaster account is untouched — removing it would leave a stack nobody can log in to"

# --- What was left alone --------------------------------------------------------------------
for path in "$projdir_remote/compose.yml" "$projdir_remote/.env" "$projdir_remote/site/index.html" \
            "$apps/traefik/dynamic/$project.yml" "$apps/traefik/compose.yml" \
            "$apps/traefik/dynamic/_shared.yml" "$apps/mail/compose.yml" \
            "$planted_remote/backups/dump.sql.gz" "$planted_remote/compose.yml"; do
    assert '[ "$(remote_exists "$path")" = yes ]' "after the destroy, $path is still there"
done
assert '[ "$(labelled $project)" = "$project-web " ]' \
    "the project's containers are still up (got '$(labelled $project)')"
assert '[ -n "$(labelled traefik)" ]' "and Traefik's (got '$(labelled traefik)')"
assert '[ -n "$(labelled mail)" ]' "and the mail stack's (got '$(labelled mail)')"
serve=$(wait_http "$project_host" 200)
assert '[ "$serve" = 200 ]' "and the site still answers 200 (got '$serve')"

# --- The restart, which is when a stripped limit would bite ------------------------------------
#
# `cpus: ${KASBAH_CPU_LIMIT}` with nothing behind it is a compose file that will
# not come up. Down and up from the server's own files, so this is the new
# owner's first restart and not a kasbah code path.
restart_out=$(rig_ssh "cd $projdir_remote && docker compose -p $project down --remove-orphans && docker compose -p $project up -d" 2>&1)
restart_rc=$?
assert '[ "$restart_rc" = 0 ]' \
    "the project comes back up from its own compose.yml after the destroy (rc=$restart_rc)
        $(nocr "$restart_out")"
assert '[ "$(labelled $project)" = "$project-web " ]' \
    "with its container back (got '$(labelled $project)')"
restarted=$(wait_http "$project_host" 200)
assert '[ "$restarted" = 200 ]' "and Traefik routes to it again (got '$restarted')"
greeting=$(rig_ssh "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $project-web" 2>/dev/null | tr -d '\r')
assert 'grep -qF "DEMO_GREETING=hello from the demo fixture" <<<"$greeting"' \
    "and the project's own .env value reached the container (got: $(grep DEMO <<<"$greeting"))"

# The paired negative for the whole .env story: with the values really gone the
# same restart fails. Without this, "it came back up" would also pass on a
# server where compose never reads .env at all.
rig_ssh "sed -i '/^KASBAH_/d' $projdir_remote/.env" >/dev/null 2>&1
broken_out=$(rig_ssh "cd $projdir_remote && docker compose -p $project up -d --force-recreate" 2>&1)
broken_rc=$?
assert '[ "$broken_rc" != 0 ]' \
    "and with KASBAH_CPU_LIMIT taken out of the same .env it does not — so the values are load-bearing (rc=$broken_rc)
        $(nocr "$broken_out")"
rig_ssh "printf 'KASBAH_CPU_LIMIT=0\nKASBAH_MEM_LIMIT=0\n' >> $projdir_remote/.env
         cd $projdir_remote && docker compose -p $project up -d" >/dev/null 2>&1

# --- A second run ------------------------------------------------------------------------------
destroy "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "a second destroy exits 0 (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"
assert 'grep -qF "carries nothing of" "$tmpdir/out"' \
    "and says the server carries nothing of kasbah's (stdout: $(cli_out))"
assert '! grep -qF "type the hostname" "$tmpdir/out"' \
    "with no confirmation, since there is nothing to confirm"
assert '[ "$(remote_exists "$projdir_remote/compose.yml")" = yes ]' "and it removed nothing"
assert '[ "$(labelled $project)" = "$project-web " ]' "and the site is still up after it"


# --- An .env destroy cannot rewrite is a failed run, not a quiet one -----------------------------
#
# Last, and on a server re-prepared for it: run before the destroy above, it
# would take that run's whole subject away — the act removes the backup stack
# and the project artifacts *before* it reaches the mail .env, so a failed run
# is a mostly-destroyed server and every "is gone" assertion above it would pass
# for the wrong reason.
#
# The command's headline promise is that no agency-owned secret transfers, and
# <apps>/mail/.env is where the operator's relay password lives. A run that
# could not strip it must not print the handover sentence: the same run removes
# the marker, and a second destroy would then report the server clean while the
# password is still on it.
init "${traefik_flags[@]}" --with-mail --postmaster-password="$postmaster_pw" --no-backup; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: could not re-prepare the rig for the unwritable-.env case (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
rig_ssh "printf 'RELAY_PASSWORD=$relay_password\n' >> $apps/mail/.env
         chmod 000 $apps/mail/.env" >/dev/null 2>&1
destroy "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 1 ]' "a mail .env destroy cannot rewrite fails the run (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"
assert '! grep -qF "plain Docker Compose host now" "$tmpdir/out"' \
    "and the run does not claim the server is handed over (stdout: $(cli_out))"
assert 'grep -qF "relay credential in it is still on this server" "$tmpdir/err"' \
    "naming what is still there (stderr: $(cli_err))"
assert 'grep -qF "kept the server marker" "$tmpdir/out"' "and it kept the marker (stdout: $(cli_out))"
assert '[ "$(remote_exists "$marker")" = yes ]' "which really is still on the server"
assert '[ "$(remote_exists "$pointer")" = yes ]' "and so is the discovery pointer"
mail_still=$(rig_ssh "sudo cat $apps/mail/.env" 2>/dev/null | tr -d '\r')
assert 'grep -qF "$relay_password" <<<"$mail_still"' \
    "and the relay password the run could not strip is exactly what it said — still there"
serve=$(wait_http "$project_host" 200)
assert '[ "$serve" = 200 ]' "while the site kept serving through the failed run too (got '$serve')"

# The paired positive, one `chmod` apart: with the same file writable the same
# command finishes, strips the password and takes the marker. So the failure
# above is the unwritable file and not a run that can never succeed.
rig_ssh "chmod 600 $apps/mail/.env" >/dev/null 2>&1
destroy "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "with the file writable the same run exits 0 (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "plain Docker Compose host now" "$tmpdir/out"' "and claims the handover (stdout: $(cli_out))"
mail_after2=$(rig_ssh "cat $apps/mail/.env" 2>/dev/null | tr -d '\r')
assert '! grep -qF "$relay_password" <<<"$mail_after2"' "with the relay password gone (got: $mail_after2)"
assert '[ "$(remote_exists "$marker")" = no ]' "and the marker taken"

# --- Leave the rig as it was found, but only on success ------------------------------------------
if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi

exit "$fail"
