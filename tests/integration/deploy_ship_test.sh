#!/usr/bin/env bash
# Integration test: the VPS-side orchestrator — `kasbah deploy` of a project
# that builds its own images, against the live rig.
#
# A sibling of ship_test.sh rather than an extension of it, and deliberately:
# that suite's whole subject is that `build-push` moves images and *nothing
# else* — no container started, `:current` moved for neither image — which a
# deploy in the same run would contradict at every one of its assertions. This
# one needs what that one must not have: a server `kasbah server init` has
# prepared, a rendered `.env`, and containers running at the end.
#
# What only the rig can show, and what this suite is therefore about:
#   * the hook order and the three variables each hook was given, read back out
#     of the file the hooks wrote inside a container;
#   * the backup gate in both directions, against a real `docker exec` and a
#     real pipe;
#   * versions.log's `digest=` matching what the rig's own daemon calls the
#     images after the retag — an id computed on the workstation is a different
#     number entirely (docs/phases/04-ship.md → Findings);
#   * two concurrent runs of the shipped script over ssh, one flock;
#   * the script on the server being this kasbah's template, rendered.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which establishes a known starting state — and which
# leaves images alone, so the ones this suite loads are removed by name here.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
marker="$apps/.kasbah/server.json"
template="$repo_dir/templates/remote-deploy.sh"
kasbah_version="$(cat "$repo_dir/VERSION")"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")

project=built-app
project_version=1.5.0
# The version the changelog section cuts, so step 10 has a real range to print.
next_version=1.6.0
image_web=built-app-web
image_worker=built-app-worker
web="$image_web:$project_version"
worker="$image_worker:$project_version"
projdir_remote="$apps/$project"
script_remote="$projdir_remote/scripts/remote-deploy.sh"
# Bind-mounted at /var/kasbah in built-app-web (tests/fixtures/built-app), so the
# hooks write inside the container and this side reads the same bytes off disk.
crumbs_remote="$projdir_remote/state/breadcrumbs.log"
backup_payload=kasbah-built-app-backup-payload

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    rig_ssh "docker image rm -f $web $worker $image_web:$next_version $image_worker:$next_version $image_web:current $image_worker:current; rm -rf $apps/mail; rm -f /tmp/$project-*.tar.gz /tmp/rd-first.out /tmp/rd-first.rc" >/dev/null 2>&1
    docker image rm -f "$web" "$worker" "$image_web:$next_version" "$image_worker:$next_version" "$image_web:current" "$image_worker:current" >/dev/null 2>&1
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
init()   { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_err() { cat "$tmpdir/err"; }
build_push() (
    cd "$projdir" || return 2
    kasbah_cli build-push "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
# Bounded: the failure this replaces is not a wrong answer but a prompt nobody
# can answer, and a wedged deploy would hang the suite instead of failing it
# (tests/integration/rig_env.sh on timeout and stdin).
deploy() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$RIG_REPO_DIR/bin/kasbah" deploy "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)

# The hooks' breadcrumb file, which survives every deploy: _deploy_sync_project
# rsyncs without --delete, so a file a hook appends to inside a bind mount
# outlives the run that made it. Every assertion below therefore truncates first
# rather than assuming a fresh file — otherwise the suite's second run reads the
# first run's order (docs/phases/04-ship.md → carried into 4.2).
#
# It is written by root inside the container, so removing it needs the sudo the
# rig's ssh user has.
crumbs_reset() { rig_ssh "sudo rm -f $crumbs_remote" >/dev/null 2>&1; }
crumbs()       { rig_ssh "cat $crumbs_remote 2>/dev/null" 2>/dev/null | tr -d '\r'; }

versions_log() { rig_ssh "cat $projdir_remote/versions.log 2>/dev/null" 2>/dev/null | tr -d '\r'; }
backup_names() {
    rig_ssh "cd $projdir_remote/backups 2>/dev/null && ls -1 2>/dev/null | sort | tr '\n' ' '" 2>/dev/null | tr -d '\r'
}

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — the deploy has nothing to land on" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as spine_test.sh
# does. Nothing here special-cases kasbah: what changes is the server's own
# marker, and a rig that later grows cgroup nesting needs no edit
# (docs/phases/02-spine.md → Findings).
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    if ! grep -qF "threaded mode" <<<"$limit_probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
        sed 's/^/       | /' <<<"$limit_probe" >&2
        exit 2
    fi
    echo "note: this rig cannot apply cgroup limits (nested cgroup v2 is in threaded mode)," >&2
    echo "      so the server marker is rewritten to 0/0 — Docker reads that as no limit." >&2
    new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
    if [ "$(rig_ssh "cat $marker" 2>/dev/null | jq -r '.cpu_limit' 2>/dev/null)" != "0" ]; then
        echo "error: the rewritten marker does not carry cpu_limit=0" >&2
        exit 2
    fi
fi

# --- The project, with a git history of its own ---------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$project_version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# --- The images, on the rig ------------------------------------------------------
build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push failed (exit $rc) — the deploy has no images to retag" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# --- The first deploy has no .env to bring the stack up with ----------------------
# Not the subject here — spine_test.sh owns that refusal — but it is what puts
# the helpers on the server, and the operator's own render below is what the
# real deploy then runs against.
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "5" ]' "a deploy with no .env and no terminal exits 5 (exit $rc: $(cli_err))"
setup_rc=0
rig_ssh "cd $projdir_remote && ./scripts/setup-env.sh $projdir_remote" </dev/null >/dev/null 2>&1 || setup_rc=$?
rendered_env=$(rig_ssh "cat $projdir_remote/.env" 2>/dev/null)
if [ "$setup_rc" -ne 0 ] || ! grep -qF "BUILT_APP_GREETING=" <<<"$rendered_env"; then
    echo "error: the shipped setup-env.sh did not render an .env (exit $setup_rc)" >&2
    sed 's/^/       | /' <<<"$rendered_env" >&2
    exit 2
fi

# ==================================================================================
# The first deploy: nothing of this project is running yet
# ==================================================================================
# The backup and the pre-deploy hooks act on the *outgoing* state, and there is
# none — so both are skipped, out loud, and the deploy goes through. Refusing
# here would make a first deploy impossible for every project that declares a
# hook or a backup.
crumbs_reset
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a first deploy of a project with hooks and a backup succeeds (exit $rc)
        stderr: $(cli_err)"
if [ "$rc" != "0" ]; then
    sed 's/^/       | /' "$tmpdir/err" >&2
    echo "error: the first deploy failed — nothing below can be judged" >&2
    exit 1
fi
assert 'grep -qF "first deploy — versions.log has no entry" "$tmpdir/err"' \
    "and it says so on the evidence that distinguishes it — an empty versions.log,
        not a container list, which cannot tell a first deploy from a crashed one
        (said '$(cli_err)')"
assert 'grep -qF "nothing to back up" "$tmpdir/err"' \
    "saying why it took no backup (said '$(cli_err)')"
assert 'grep -qF "pre-deploy hook skipped" "$tmpdir/err"' \
    "and why the pre-deploy hook did not run (said '$(cli_err)')"
assert '[ "$(backup_names)" = "" ]' \
    "with no backup file written (found '$(backup_names)')"
first_crumbs="$(crumbs)"
assert '[ "$(grep -c . <<<"$first_crumbs")" = "1" ]' \
    "and exactly one breadcrumb — the post-deploy hook's, against what compose just started
        crumbs: $(tr '\n' '/' <<<"$first_crumbs")"
assert '[[ "$first_crumbs" == post-deploy\ * ]]' \
    "which is the post-deploy one (line: '$first_crumbs')"
assert '[[ "$first_crumbs" == *" prev= "* ]]' \
    "with \$PREV_VERSION empty on a first deploy rather than absent (line: '$first_crumbs')"
# The changelog (docs/build-deploy.md step 10) is driven by the previous version
# in the shipped script's report, which on a first deploy is empty — so there is
# no range to compute and the local side says that instead of inventing one.
assert 'grep -qF "changes: first deploy" "$tmpdir/err"' \
    "and the changelog says there is no previous version to compare against (said '$(cli_err)')"

# ==================================================================================
# The second deploy: the whole order, against a stack that is up
# ==================================================================================
crumbs_reset
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a redeploy over a running stack succeeds (exit $rc)
        stderr: $(cli_err)"
if [ "$rc" != "0" ]; then
    sed 's/^/       | /' "$tmpdir/err" >&2
fi
# The range is the server's answer, not this side's guess: nothing in the
# checkout knows that $project_version was already deployed here, and the only
# way this line can name it is the report the shipped script printed.
assert 'grep -qF "changes: none — v$project_version..v$project_version is empty" "$tmpdir/err"' \
    "the changelog names the version the server reported as previous (said '$(cli_err)')"

# --- The script on the server is this kasbah's template, rendered -------------------
# Two halves, because the deliverable has two: the parts kasbah owns are its own
# file byte for byte, and the generated block names the version that wrote it.
tpl_sans_block=$(sed '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/d' "$template" | sha256sum | cut -d' ' -f1)
rig_sans_block=$(rig_ssh "sed '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/d' $script_remote | sha256sum | cut -d' ' -f1" 2>/dev/null | tr -d '\r')
assert '[ "$rig_sans_block" = "$tpl_sans_block" ]' \
    "everything outside the generated block is templates/remote-deploy.sh itself
        rig:   $rig_sans_block
        local: $tpl_sans_block"
shipped_block=$(rig_ssh "sed -n '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/p' $script_remote" 2>/dev/null | tr -d '\r')
assert 'grep -qxF "# Generated by kasbah $kasbah_version from kasbah.yml. Edit the manifest, not this." <<<"$shipped_block"' \
    "and the block names the installed kasbah version ($kasbah_version)
        block: $shipped_block"
assert 'grep -qxF "RD_IMAGES=( '"'"'$image_web'"'"' '"'"'$image_worker'"'"' )" <<<"$shipped_block"' \
    "carrying both built images"
assert 'grep -qxF "RD_HEALTH_CONTAINER='"'"'$image_web'"'"'" <<<"$shipped_block"' \
    "the manifest's health.container"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'60'"'"'" <<<"$shipped_block"' \
    "its timeout, parsed from 60s into seconds"
assert 'grep -qxF "RD_BACKUP_COMMAND='"'"'echo $backup_payload'"'"'" <<<"$shipped_block"' \
    "and its backup command"
assert 'rig_ssh "$script_remote --help 2>&1" | grep -qF -- "--allow-stopped"' \
    "and the shipped script documents --allow-stopped, which is how an operator
        deploys over a stack that is meant to be down"
assert '[ "$(rig_ssh "stat -c %a $script_remote" 2>/dev/null | tr -d "\r")" = "755" ]' \
    "and it landed executable (got '$(rig_ssh "stat -c %a $script_remote" 2>/dev/null | tr -d "\r")')"
# The manifest itself is deliberately not synced: there is nothing on a VPS that
# could read it, which is the whole reason the block above exists.
assert '[ "$(rig_ssh "[ -e $projdir_remote/kasbah.yml ] && echo present || echo absent" 2>/dev/null | tr -d "\r")" = "absent" ]' \
    "and kasbah.yml was not shipped beside it"

# --- The hook order, and the three variables each hook was given ---------------------
crumb_text="$(crumbs)"
assert '[ "$(wc -l <<<"$crumb_text")" = "2" ]' \
    "the two hooks each left exactly one breadcrumb (got: $(tr '\n' '/' <<<"$crumb_text"))"
echo "note: the hooks left: $(tr '\n' '/' <<<"$crumb_text")" >&2
pre_line="$(sed -n 1p <<<"$crumb_text")"
post_line="$(sed -n 2p <<<"$crumb_text")"
assert '[[ "$pre_line" == pre-deploy\ * ]]' \
    "the pre-deploy hook ran first (line 1: '$pre_line')"
assert '[[ "$post_line" == post-deploy\ * ]]' \
    "and the post-deploy hook after it (line 2: '$post_line')"
assert '[[ "$pre_line" == *"version=$project_version "* ]]' \
    "\$VERSION reached the pre-deploy hook (line: '$pre_line')"
assert '[[ "$post_line" == *"version=$project_version "* ]]' \
    "and the post-deploy hook (line: '$post_line')"
assert '[[ "$pre_line" == *" prev=$project_version "* ]]' \
    "\$PREV_VERSION is the version the last versions.log entry recorded (line: '$pre_line')"
assert '[[ "$post_line" == *" prev=$project_version "* ]]' \
    "and the post-deploy hook is handed the same (line: '$post_line')"
assert '[[ "$pre_line" == *" backup=backups/pre-deploy-"*.txt.gz ]]' \
    "and \$DEPLOY_BACKUP already names the file the backup step wrote (line: '$pre_line')"
assert '[[ "$post_line" == *" backup=backups/pre-deploy-"*.txt.gz ]]' \
    "which the post-deploy hook is handed too (line: '$post_line')"

# --- The backup, taken because its check said so --------------------------------------
names="$(backup_names)"
assert '[[ "$names" =~ ^pre-deploy-[0-9]{8}-[0-9]{6}\.txt\.gz\ $ ]]' \
    "exactly one backup file, named as docs/project-manifest.md says (found '$names')"
backup_body=$(rig_ssh "gzip -dc $projdir_remote/backups/pre-deploy-*.txt.gz 2>/dev/null" 2>/dev/null | tr -d '\r\n')
assert '[ "$backup_body" = "$backup_payload" ]' \
    "carrying the payload backup.command emits, through the gzip pipe (got '$backup_body')"

# --- versions.log, and the digests the rig's own daemon computed -------------------------
log="$(versions_log)"
assert '[ "$(wc -l <<<"$log")" = "2" ]' "two deploys have appended two lines (log: $log)"
read -r f_ts f_action f_version f_backup f_kasbah f_digest f_extra <<<"$(sed -n 2p <<<"$log")"
assert '[[ "$f_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' \
    "field 1 is a UTC ISO-8601 timestamp (got '$f_ts')"
assert '[ "$f_action" = "deploy" ]'   "field 2 is the action (got '$f_action')"
assert '[ "$f_version" = "$project_version" ]' "field 3 is the version (got '$f_version')"
assert '[[ "$f_backup" =~ ^backups/pre-deploy-[0-9]{8}-[0-9]{6}\.txt\.gz$ ]]' \
    "field 4 is the backup path (got '$f_backup')"
assert '[ "$f_kasbah" = "kasbah=$kasbah_version" ]' \
    "then kasbah=<version>, which is the kasbah that drove it (got '$f_kasbah')"
assert '[ -z "$f_extra" ]' "and nothing after digest= yet (got '$f_extra')"

# One session, one line per fact, validated as a complete key set before any
# assertion reads a value. Each image is inspected on its own: `docker image
# inspect A B` exits 1 when *either* is missing, so a combined call collapses two
# facts into one (docs/phases/04-ship.md).
read_out=$(rig_ssh "bash -s '$image_web' '$image_worker' '$project'" 2>"$tmpdir/read.err" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
web=$1
worker=$2
project=$3

kv() { printf '%s=%s\n' "$1" "$2"; }
image_id() {
    if docker image inspect "$1" >/dev/null 2>&1; then
        docker image inspect -f '{{.Id}}' "$1"
    else
        printf 'absent\n'
    fi
}
health_of() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null \
        || printf 'missing\n'
}

kv web_current    "$(image_id "$web:current")"
kv worker_current "$(image_id "$worker:current")"
kv web_running    "$(docker inspect -f '{{.State.Running}}' "$web" 2>/dev/null || echo missing)"
kv worker_running "$(docker inspect -f '{{.State.Running}}' "$worker" 2>/dev/null || echo missing)"
kv web_health     "$(health_of "$web")"
kv containers     "$(docker compose -p "$project" ps -q | wc -l)"
exit 0
REMOTE
); read_rc=$?
if [ "$read_rc" -ne 0 ] || [ -z "$read_out" ]; then
    echo "error: could not read the deployed state back off the rig (ssh exit $read_rc)" >&2
    sed 's/^/       | /' "$tmpdir/read.err" >&2
    exit 2
fi
declare -A got=()
while IFS= read -r line; do
    line="${line%$'\r'}"
    case $line in *=*) got[${line%%=*}]=${line#*=} ;; esac
done <<<"$read_out"
missing=()
for key in web_current worker_current web_running worker_running web_health containers; do
    [ -n "${got[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$read_out" >&2
    exit 2
fi

# Shape first, then identity: `!= absent` passes on an empty value, and an
# arrived-but-empty fact is exactly what a readback can hand back
# (docs/phases/04-ship.md → a fix round is where unreviewed assertions get in).
assert '[[ "${got[web_current]}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
    "$image_web:current exists on the rig after the deploy (docker said '${got[web_current]}')"
assert '[[ "${got[worker_current]}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
    "and so does $image_worker:current — the retag moved both (docker said '${got[worker_current]}')"

want_digest="digest=${got[web_current]},${got[worker_current]}"
echo "note: versions.log digest= is $f_digest" >&2
assert '[ "$f_digest" = "$want_digest" ]' \
    "digest= is what the rig's own daemon calls the two images after the retag, comma-joined in the rendered order
        log:  $f_digest
        rig:  $want_digest"

assert '[ "${got[web_running]}" = "true" ]'    "the web container is running (docker said '${got[web_running]}')"
assert '[ "${got[worker_running]}" = "true" ]' "and the worker (docker said '${got[worker_running]}')"
assert '[ "${got[web_health]}" = "healthy" ]' \
    "and the container the health wait blocked on really is healthy (docker said '${got[web_health]}')"
assert '[ "${got[containers]}" = "3" ]' \
    "all three of the fixture's services are up (found ${got[containers]})"

# ==================================================================================
# The three flags, and what each one changes on the far side
# ==================================================================================
# `kasbah deploy` decides nothing about them — it hands them to the shipped
# script — so what is worth showing here is that they arrive and that the far
# side acts on each one differently.

# --skip-hooks skips the hooks and *keeps* the backup: a dry-run-ish deploy must
# not also throw away the data safety net (docs/build-deploy.md → helper scripts).
backups_before="$(backup_names)"
crumbs_reset
deploy "$RIG_TARGET" --skip-hooks; rc=$?
assert '[ "$rc" = "0" ]' "--skip-hooks deploys (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(crumbs)" = "" ]' \
    "and neither hook ran — nothing was written to the breadcrumb file (crumbs: $(tr '\n' '/' <<<"$(crumbs)"))"
assert 'grep -qF "pre-deploy hooks skipped (--skip-hooks)" "$tmpdir/err"' \
    "the far side says which flag skipped them (said '$(cli_err)')"
assert '[ "$(backup_names)" != "$backups_before" ]' \
    "while the backup still ran
        before: $backups_before
        after:  $(backup_names)"

# --no-health-wait brings the stack up without blocking on it. The control is the
# deploys above, which all reported the wait.
crumbs_reset
deploy "$RIG_TARGET" --no-health-wait; rc=$?
assert '[ "$rc" = "0" ]' "--no-health-wait deploys (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "health wait skipped (--no-health-wait)" "$tmpdir/err"' \
    "saying so (said '$(cli_err)')"
assert '! grep -qF "is healthy" "$tmpdir/err"' \
    "and nothing waited on health at all (said '$(cli_err)')"
assert '[ "$(grep -c . <<<"$(crumbs)")" = "2" ]' \
    "with the hooks still running, because this flag is not that one (crumbs: $(tr '\n' '/' <<<"$(crumbs)"))"

# --allow-stopped is the refusal's override, so the refusal is what makes it
# mean anything: built-app-web is both the backup container and the pre-deploy
# hook's, and a project that has deployed here before must not be deployed over
# while it is down (docs/build-deploy.md → the outgoing stack).
rig_ssh "docker stop $image_web" >/dev/null 2>&1
stopped_state=$(rig_ssh "docker inspect -f '{{.State.Status}}' $image_web" 2>/dev/null | tr -d '\r')
assert '[ "$stopped_state" = "exited" ]' \
    "the outgoing container is stopped (docker says '$stopped_state')"
log_before="$(versions_log)"
crumbs_reset
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != "0" ]' "a deploy over a stopped stack that has deployed here before is refused (exit $rc)"
assert 'grep -qF "$image_web is exited" "$tmpdir/err"' \
    "naming the container and the state docker reports for it (said '$(cli_err)')"
assert 'grep -qF -- "--allow-stopped" "$tmpdir/err"' "and the flag that overrides it (said '$(cli_err)')"
assert '[ "$(versions_log)" = "$log_before" ]' \
    "before any side effect — versions.log is untouched (log: $(versions_log))"
assert '[ "$(crumbs)" = "" ]' "and no hook ran (crumbs: $(tr '\n' '/' <<<"$(crumbs)"))"

backups_before="$(backup_names)"
deploy "$RIG_TARGET" --allow-stopped; rc=$?
assert '[ "$rc" = "0" ]' "--allow-stopped deploys over it (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF -- "--allow-stopped:" "$tmpdir/err"' \
    "saying which flag let it through (said '$(cli_err)')"
assert '[ "$(backup_names)" = "$backups_before" ]' \
    "and took no backup, because there was nothing running to take one from
        before: $backups_before
        after:  $(backup_names)"
allow_crumbs="$(crumbs)"
assert '[ "$(grep -c . <<<"$allow_crumbs")" = "1" ]' \
    "the pre-deploy hook had nothing to run against either, so exactly one breadcrumb
        was left (crumbs: $(tr '\n' '/' <<<"$allow_crumbs"))"
assert '[[ "$allow_crumbs" == post-deploy\ * ]]' \
    "and it is the post-deploy one, against what compose just started (line: '$allow_crumbs')"
web_after=$(rig_ssh "docker inspect -f '{{.State.Running}}' $image_web" 2>/dev/null | tr -d '\r')
assert '[ "$web_after" = "true" ]' "with the stack running again afterwards (docker says '$web_after')"
# The control for the --no-health-wait case above: this deploy passed no flag, so
# it did block on health and said so. Without it, "nothing waited on health" would
# pass just as well against a kasbah that never waits at all.
assert 'grep -qF "$image_web is healthy" "$tmpdir/err"' \
    "and this one, with no flag, did wait on health (said '$(cli_err)')"

# ==================================================================================
# The backup gate says no — and two runs race the lock
# ==================================================================================
# One redeploy carries both: the manifest's backup.check is flipped to a command
# that exits non-zero, and a second pre-deploy hook is added that sleeps. The
# first is the deliverable; the second is what makes the concurrency case a
# property of this fixture rather than a race against wall-clock.
#
# `kasbah deploy` with no version ships the *working tree* under HEAD's tag, so
# editing the manifest here needs no new commit and no new tag
# (docs/build-deploy.md → two modes).
hook_sleep=8
sed -i 's|^  check: test -f ./compose.yml$|  check: "false"|' "$projdir/kasbah.yml"
sed -i "/^  post-deploy:\$/i\\    - 'built-app-web sleep $hook_sleep'" "$projdir/kasbah.yml"
assert 'grep -qF "check: \"false\"" "$projdir/kasbah.yml"' \
    "the fixture copy's backup.check now exits non-zero"
assert 'grep -qF "built-app-web sleep $hook_sleep" "$projdir/kasbah.yml"' \
    "and its pre-deploy hooks end with one that sleeps"

backups_before="$(backup_names)"
crumbs_reset
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a deploy whose backup.check exits non-zero still succeeds (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(backup_names)" = "$backups_before" ]' \
    "and takes no backup at all
        before: $backups_before
        after:  $(backup_names)"
gate_crumbs="$(crumbs)"
assert 'grep -qF "backup=no-backup" <<<"$gate_crumbs"' \
    "the hooks are told there is none, through \$DEPLOY_BACKUP
        crumbs: $(tr '\n' '/' <<<"$gate_crumbs")"
# Two deploys here, three in the flag section above, and one refused that wrote
# nothing: six lines, of which this is the sixth.
log2="$(versions_log)"
assert '[ "$(wc -l <<<"$log2")" = "6" ]' "a sixth line was appended (log: $log2)"
assert '[[ "$(sed -n 6p <<<"$log2")" == *" $project_version no-backup kasbah="* ]]' \
    "recording no-backup in the frozen fourth field (line: $(sed -n 6p <<<"$log2"))"
assert '[ "$(sed -n "1,2p" <<<"$log2")" = "$log" ]' \
    "and the earlier entries are untouched — the log is appended to, never rewritten"

# --- Two concurrent runs of the shipped script, one flock ----------------------------
# Driven by running the script itself over ssh rather than by racing two
# `kasbah deploy` invocations: the flag parsing that would let a deploy do this
# arrives in the next unit, and the lock is the shipped script's own.
crumbs_reset
launch_rc=0
launch_out=$(rig_ssh "bash -s '$projdir_remote' '$kasbah_version' '$project_version'" <<'REMOTE'
set -uo pipefail
dir=$1; kv=$2; ver=$3
rm -f /tmp/rd-first.out /tmp/rd-first.rc
nohup bash -c '
    cd "$1" || exit 2
    env KASBAH_VERSION="$2" ./scripts/remote-deploy.sh deploy "$3" > /tmp/rd-first.out 2>&1
    printf "%s\n" "$?" > /tmp/rd-first.rc
' _ "$dir" "$kv" "$ver" >/dev/null 2>&1 </dev/null &
printf 'launched=yes\n'
exit 0
REMOTE
) || launch_rc=$?
if [ "$launch_rc" -ne 0 ] || ! grep -qF 'launched=yes' <<<"$launch_out"; then
    echo "error: could not launch the first remote-deploy run in the background (exit $launch_rc)" >&2
    sed 's/^/       | /' <<<"$launch_out" >&2
    exit 2
fi

# Wait until the first run is *inside* the sleeping hook: its earlier hook wrote
# a breadcrumb, so the file appearing is the signal. A fixed sleep here would be
# the race this design exists to avoid.
inside=no
deadline=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -qF "pre-deploy version=$project_version" <<<"$(crumbs)"; then
        inside=yes
        break
    fi
    sleep 1
done
assert '[ "$inside" = "yes" ]' \
    "the first run reached its pre-deploy hooks and is holding the lock (crumbs: $(tr '\n' '/' <<<"$(crumbs)"))"

started=$(date +%s%3N)
second_out=$(rig_ssh "cd $projdir_remote && env KASBAH_VERSION='$kasbah_version' ./scripts/remote-deploy.sh deploy $project_version 2>&1"); second_rc=$?
second_ms=$(( $(date +%s%3N) - started ))
assert '[ "$second_rc" != "0" ]' "the second concurrent run fails (exit $second_rc)
        said: $second_out"
assert 'grep -qF "$projdir_remote/.deploy.lock" <<<"$second_out"' \
    "naming the lock it could not take (said '$second_out')"
assert 'grep -qF "already running" <<<"$second_out"' "and why (said '$second_out')"
assert '[ "$second_ms" -lt $(( hook_sleep * 1000 )) ]' \
    "fast, rather than queued behind the ${hook_sleep}s hook (took ${second_ms}ms)"
echo "note: the second concurrent run was refused in ${second_ms}ms" >&2

first_rc=""
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    first_rc=$(rig_ssh "cat /tmp/rd-first.rc 2>/dev/null" 2>/dev/null | tr -d '\r')
    [ -z "$first_rc" ] || break
    sleep 1
done
assert '[ "$first_rc" = "0" ]' \
    "while the first run finishes untouched (exit '$first_rc')
        said: $(rig_ssh "cat /tmp/rd-first.out 2>/dev/null" 2>/dev/null)"
log3="$(versions_log)"
assert '[ "$(wc -l <<<"$log3")" = "7" ]' \
    "and exactly one of the two wrote a versions.log entry ($(wc -l <<<"$log3") lines in all)
        log: $log3"

# ==================================================================================
# Step 10, with a range in it — and the mail claim's own payload, run
# ==================================================================================
# Everything above deployed 1.5.0 over 1.5.0, so the changelog had an empty range
# to report every time. Cutting a second version here is what makes step 10
# observable end to end: the previous version comes off this server's own
# versions.log, the commits come out of this checkout, and neither side can
# produce the line alone.
#
# The sleeping hook goes first — it was the concurrency section's instrument and
# costs every later deploy eight seconds.
sed -i "/- 'built-app-web sleep $hook_sleep'/d" "$projdir/kasbah.yml"
assert '! grep -qF "built-app-web sleep" "$projdir/kasbah.yml"' \
    "the concurrency section's sleeping hook is out of the manifest again"

# The mail claim rides the same deploy: this server has no $apps/mail yet, which
# is the state every server is in today, and the branch the suite has never run
# the real payload against.
printf '\nmail:\n  domain: mail.built-app.test\n' >> "$projdir/kasbah.yml"

commit_subject="what $next_version ships and $project_version did not"
if ! ( cd "$projdir" && git add -A && git commit -qm "$commit_subject" && git tag "v$next_version" ) >"$tmpdir/git.log" 2>&1; then
    echo "error: could not cut v$next_version in the fixture copy" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push of $next_version failed (exit $rc) — the deploy has no images to retag" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "the $next_version deploy succeeds (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "changes: v$project_version..v$next_version" "$tmpdir/err"' \
    "and the changelog names the range from what this server was running to what it runs now
        (said '$(cli_err)')"
assert 'grep -qF "$commit_subject" "$tmpdir/err"' \
    "listing the commit inside it (said '$(cli_err)')"
assert '! grep -qF "the built-app fixture" "$tmpdir/err"' \
    "and not the commit before the range began (said '$(cli_err)')"
assert 'grep -qF "there is no mail stack at $apps/mail" "$tmpdir/err"' \
    "the mail claim looked, on this server, and found none (said '$(cli_err)')"

# The other three states of $apps/mail, against the real payload. The code looks
# for a *directory* and a file in it, so a plain file at that path is a server
# with no mail stack — and `[ -d ]` relaxed to `[ -e ]` is exactly the mutant a
# suite that never runs the payload cannot see.
rig_ssh "rm -rf $apps/mail && : > $apps/mail" >/dev/null 2>&1
mail_kind=$(rig_ssh "[ -f $apps/mail ] && echo file || echo other" 2>/dev/null | tr -d '\r')
assert '[ "$mail_kind" = "file" ]' "a plain file stands where the mail stack would be (found '$mail_kind')"
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a file at $apps/mail does not stop the deploy (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "there is no mail stack at $apps/mail" "$tmpdir/err"' \
    "and is not a mail stack (said '$(cli_err)')"

rig_ssh "rm -f $apps/mail && mkdir -p $apps/mail" >/dev/null 2>&1
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a mail directory with no .env does not stop the deploy (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "$apps/mail on $RIG_TARGET has no .env" "$tmpdir/err"' \
    "and is reported as its own state (said '$(cli_err)')"
assert '! grep -qF "there is no mail stack" "$tmpdir/err"' \
    "not as an absent one (said '$(cli_err)')"

rig_ssh "touch $apps/mail/.env" >/dev/null 2>&1
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a mail stack with an .env does not stop the deploy either (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "does not yet check that $apps/mail/.env names it" "$tmpdir/err"' \
    "and kasbah says plainly that it cannot reconcile the claim yet (said '$(cli_err)')"
assert '! grep -qF "has no .env" "$tmpdir/err"' "not the state below it (said '$(cli_err)')"

rig_ssh "rm -rf $apps/mail" >/dev/null 2>&1
sed -i '/^mail:$/,$d' "$projdir/kasbah.yml"
assert '! grep -qF "mail:" "$projdir/kasbah.yml"' "the mail claim is out of the manifest again"

# ==================================================================================
# The exit codes docs/cli.md promises, out of a real `kasbah deploy`
# ==================================================================================
# 5 is pinned at the top of this suite: the first deploy, against a project with
# no .env and no terminal to render one on. The other two need a server that does
# not answer, and one that answers but was never prepared.
#
# The scratch ssh config fences every host but the rig (tests/integration/
# rig_env.sh), so this name is unreachable in the way ssh itself reports.
deploy nobody@unreachable.invalid; rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server exits 3 (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "cannot reach nobody@unreachable.invalid" "$tmpdir/err"' \
    "naming the host (said '$(cli_err)')"

# The marker is moved rather than deleted, and put back straight away: everything
# after this point still needs a prepared server.
if ! rig_ssh "sudo mv $marker $marker.held" >/dev/null 2>&1; then
    echo "error: could not move the server marker aside on the rig" >&2
    exit 2
fi
deploy "$RIG_TARGET"; rc=$?
marker_back=0
rig_ssh "sudo mv $marker.held $marker" >/dev/null 2>&1 || marker_back=1
assert '[ "$rc" = "4" ]' "a server with no marker exits 4 (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF "$marker" "$tmpdir/err"' "naming the file it looked for (said '$(cli_err)')"
assert '[ "$marker_back" = "0" ]' "and the marker was put back for the cleanup below"
assert '[ "$(rig_ssh "[ -f $marker ] && echo present || echo absent" 2>/dev/null | tr -d "\r")" = "present" ]' \
    "which the server agrees with"

# --- Leave the rig as it was found, but only on success ---------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $web $worker $image_web:$next_version $image_worker:$next_version $image_web:current $image_worker:current" >/dev/null 2>&1
    rig_clean || fail=1
fi

exit "$fail"
