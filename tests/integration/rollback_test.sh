#!/usr/bin/env bash
# Integration test: `kasbah rollback` against the live rig — deploy v1, deploy a
# materially different v2, roll back, and read all three surfaces back off the
# server.
#
# The three surfaces are the exit criterion, and each is read from the rig rather
# than inferred from what kasbah narrated:
#   * the compose file in <apps>/built-app/, compared byte for byte against
#     `git show v1:compose.prod.yml` — and the container it produced, which does
#     not carry the environment key v2's compose added;
#   * <apps>/traefik/dynamic/built-app.yml, against `git show v1:traefik-dynamic.yml`;
#   * `:current`, resolved with `docker image inspect` to the id of the v1 image
#     — and the page inside the running container, which is the v1 build's.
#
# What only the rig can show beyond that: the pre-/post-rollback hooks running in
# that order with $VERSION at the target and $PREV_VERSION at the version being
# left, read out of the file the hooks wrote inside a container; and the two
# refusals, against a real `docker image inspect` and a real versions.log.
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
kasbah_version="$(cat "$repo_dir/VERSION")"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")

project=built-app
# Two versions of the same project, one materially different from the other:
# a compose file with an extra environment key, a different Traefik fragment,
# and an image built from a different Dockerfile.
v1=2.1.0
v2=2.2.0
image_web=built-app-web
image_worker=built-app-worker
projdir_remote="$apps/$project"
frag_remote="$apps/traefik/dynamic/$project.yml"
crumbs_remote="$projdir_remote/state/breadcrumbs.log"
v1_page_marker=served-by-built-app-from-an-image-shipped-over-ssh
v2_page_marker=served-by-built-app-edition-two

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
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
cli_err() { cat "$tmpdir/err"; }
build_push() (
    cd "$projdir" || return 2
    kasbah_cli build-push "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
# Bounded, for the reason rig_env.sh gives: a wedged run must fail the suite
# rather than hang it.
kasbah_bounded() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy()   { kasbah_bounded deploy "$@"; }
rollback() { kasbah_bounded rollback "$@"; }

crumbs_reset() { rig_ssh "sudo rm -f $crumbs_remote" >/dev/null 2>&1; }
crumbs()       { rig_ssh "cat $crumbs_remote 2>/dev/null" 2>/dev/null | tr -d '\r'; }
versions_log() { rig_ssh "cat $projdir_remote/versions.log 2>/dev/null" 2>/dev/null | tr -d '\r'; }
# Hashed on the far side, so what is compared is the file the server holds
# rather than a copy that travelled back through this suite.
remote_sha()   { rig_ssh "sha256sum $1 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d '\r'; }
ref_sha()      { ( cd "$projdir" && git show "$1" | sha256sum | cut -d' ' -f1 ); }
image_id()     { rig_ssh "docker image inspect -f '{{.Id}}' $1 2>/dev/null" 2>/dev/null | tr -d '\r'; }

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — nothing to roll back on" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do (docs/phases/02-spine.md → Findings).
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

# --- v1, tagged ------------------------------------------------------------------
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
    echo "error: the $v1 deploy failed (exit $rc) — nothing below can be judged" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# What the rollback will have to restore, captured while it is true.
v1_compose_sha="$(ref_sha "v$v1:compose.prod.yml")"
v1_frag_sha="$(ref_sha "v$v1:traefik-dynamic.yml")"
v1_web_id="$(image_id "$image_web:$v1")"
v1_worker_id="$(image_id "$image_worker:$v1")"
assert '[[ "$v1_web_id" =~ ^sha256:[0-9a-f]{64}$ ]]' \
    "the $v1 web image is on the rig (docker said '$v1_web_id')"

# --- v2, materially different ------------------------------------------------------
# Three files, three surfaces: the compose file gains an environment key, the
# fragment gains a line, and the Dockerfile's page marker changes so the two
# versions' images cannot be confused for each other.
sed -i 's|^      BUILT_APP_GREETING: \${BUILT_APP_GREETING}$|&\n      BUILT_APP_EDITION: "two"|' \
    "$projdir/compose.prod.yml"
sed -i "s|$v1_page_marker|$v2_page_marker|" "$projdir/Dockerfile"
printf '%s\n' "# edition two — this line is in v$v2's fragment and not in v$v1's" \
    >> "$projdir/traefik-dynamic.yml"
assert 'grep -qF "BUILT_APP_EDITION" "$projdir/compose.prod.yml"' \
    "v$v2's compose declares an environment key v$v1's does not"
assert 'grep -qF "$v2_page_marker" "$projdir/Dockerfile"' \
    "and its image is built from a different page"

commit_subject="what $v2 changed and $v1 did not have"
if ! ( cd "$projdir" && git add -A && git commit -qm "$commit_subject" && git tag "v$v2" ) \
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
    echo "error: the $v2 deploy failed (exit $rc) — there is nothing to roll back from" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

v2_web_id="$(image_id "$image_web:$v2")"
assert '[ "$v2_web_id" != "$v1_web_id" ]' \
    "the two versions really are different images ($v1 $v1_web_id, $v2 $v2_web_id)"
assert '[ "$(remote_sha "$projdir_remote/compose.yml")" != "$v1_compose_sha" ]' \
    "and the server is running $v2's compose file, not $v1's"
assert '[ "$(image_id "$image_web:current")" = "$v2_web_id" ]' \
    "with :current on the $v2 image (docker said '$(image_id "$image_web:current")')"
edition=$(rig_ssh "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $image_web 2>/dev/null | grep -c BUILT_APP_EDITION" 2>/dev/null | tr -d '\r')
assert '[ "$edition" = "1" ]' \
    "and the running container carries $v2's environment key (found $edition)"

# ==================================================================================
# The rollback
# ==================================================================================
# No version named: the target is the second-most-recent `deploy` entry, which is
# $v1 — read off the server's own versions.log, since nothing in this checkout
# knows what this server has run.
crumbs_reset
rollback "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a rollback with no version named succeeds (exit $rc)
        stderr: $(cli_err)"
if [ "$rc" != "0" ]; then
    sed 's/^/       | /' "$tmpdir/err" >&2
    echo "error: the rollback failed — the three surfaces below cannot be judged" >&2
    exit 1
fi
assert 'grep -qF "rolling back to $v1" "$tmpdir/err"' \
    "having picked the deploy before the current one (said '$(cli_err)')"

# --- Surface 1: the compose file on the server -------------------------------------
server_compose_sha="$(remote_sha "$projdir_remote/compose.yml")"
assert '[ "$server_compose_sha" = "$v1_compose_sha" ]' \
    "the compose file on the server is v$v1's, byte for byte
        server: $server_compose_sha
        v$v1:   $v1_compose_sha"
edition=$(rig_ssh "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $image_web 2>/dev/null | grep -c BUILT_APP_EDITION" 2>/dev/null | tr -d '\r')
assert '[ "$edition" = "0" ]' \
    "and the container compose recreated from it no longer carries v$v2's environment key (found $edition)"

# --- Surface 2: the Traefik fragment ------------------------------------------------
server_frag_sha="$(remote_sha "$frag_remote")"
assert '[ "$server_frag_sha" = "$v1_frag_sha" ]' \
    "the Traefik fragment is v$v1's, byte for byte
        server: $server_frag_sha
        v$v1:   $v1_frag_sha"
assert '[ "$(rig_ssh "grep -c \"edition two\" $frag_remote" 2>/dev/null | tr -d "\r")" = "0" ]' \
    "with v$v2's line gone from it"

# --- Surface 3: :current, and what is actually serving --------------------------------
current_web="$(image_id "$image_web:current")"
current_worker="$(image_id "$image_worker:current")"
assert '[ "$current_web" = "$v1_web_id" ]' \
    "$image_web:current is back on the v$v1 image
        :current $current_web
        :$v1     $v1_web_id"
assert '[ "$current_worker" = "$v1_worker_id" ]' \
    "and so is $image_worker:current — the retag moved both
        :current $current_worker
        :$v1     $v1_worker_id"
page=$(rig_ssh "docker exec $image_web cat /usr/share/nginx/html/index.html 2>/dev/null" 2>/dev/null | tr -d '\r')
assert 'grep -qF "$v1_page_marker" <<<"$page"' \
    "and the container running now serves the v$v1 build's page"
assert '! grep -qF "$v2_page_marker" <<<"$page"' "not the v$v2 build's"
web_running=$(rig_ssh "docker inspect -f '{{.State.Running}}' $image_web" 2>/dev/null | tr -d '\r')
assert '[ "$web_running" = "true" ]' "with the stack running afterwards (docker said '$web_running')"

# --- The record, and the hooks --------------------------------------------------------
log="$(versions_log)"
assert '[ "$(wc -l <<<"$log")" = "3" ]' "two deploys and a rollback have appended three lines (log: $log)"
read -r r_ts r_action r_version r_backup r_kasbah r_digest r_extra <<<"$(sed -n 3p <<<"$log")"
assert '[ "$r_action" = "rollback" ]' "field 2 of the new entry is the action (got '$r_action')"
assert '[ "$r_version" = "$v1" ]'     "field 3 is the target version (got '$r_version')"
assert '[ "$r_backup" = "no-backup" ]' \
    "field 4 is always no-backup — a rollback takes none (got '$r_backup')"
assert '[ "$r_kasbah" = "kasbah=$kasbah_version" ]' \
    "and kasbah= is the kasbah that drove it (got '$r_kasbah')"
assert '[ "$r_digest" = "digest=$v1_web_id,$v1_worker_id" ]' \
    "digest= is what the rig's own daemon calls the two images after the retag
        log: $r_digest
        rig: digest=$v1_web_id,$v1_worker_id"
assert '[ -z "$r_extra" ]' "with nothing after it (got '$r_extra')"

crumb_text="$(crumbs)"
assert '[ "$(grep -c . <<<"$crumb_text")" = "2" ]' \
    "the rollback ran two hooks and no more (crumbs: $(tr '\n' '/' <<<"$crumb_text"))"
pre_line="$(sed -n 1p <<<"$crumb_text")"
post_line="$(sed -n 2p <<<"$crumb_text")"
assert '[[ "$pre_line" == pre-rollback\ * ]]' \
    "the pre-rollback hook ran first (line 1: '$pre_line')"
assert '[[ "$post_line" == post-rollback\ * ]]' \
    "and the post-rollback hook after it (line 2: '$post_line')"
assert '! grep -qF "pre-deploy" <<<"$crumb_text"' \
    "the deploy pair did not run — the mode picks one pair (crumbs: $(tr '\n' '/' <<<"$crumb_text"))"
assert '[[ "$pre_line" == *"version=$v1 "* ]]' \
    "\$VERSION is the version rolled back to (line: '$pre_line')"
assert '[[ "$pre_line" == *" prev=$v2 "* ]]' \
    "and \$PREV_VERSION the one being left behind (line: '$pre_line')"
assert '[[ "$post_line" == *"version=$v1 "* ]]' \
    "the post-rollback hook is handed the same \$VERSION (line: '$post_line')"
assert '[[ "$post_line" == *" prev=$v2 "* ]]' "and the same \$PREV_VERSION (line: '$post_line')"
assert '[[ "$pre_line" == *" backup=no-backup" ]]' \
    "with \$DEPLOY_BACKUP saying there is none (line: '$pre_line')"

assert '[ "$(jq -r .last_version "$projdir/.kasbah/state.json" 2>/dev/null)" = "$v1" ]' \
    "and the project's state file, in the project root, records the version rolled back to"

# ==================================================================================
# The two refusals
# ==================================================================================
log_before="$(versions_log)"

# Never deployed here. 9.9.9 is not a tag in this checkout either, and the
# message is still the record's — which is the order the flow specifies.
rollback "$RIG_TARGET" 9.9.9; rc=$?
assert '[ "$rc" != "0" ]' "rolling back to a version this server never ran is refused (exit $rc)"
assert 'grep -qF "Version 9.9.9 was never deployed to this VPS." "$tmpdir/err"' \
    "with the spec's own sentence (said '$(cli_err)')"
assert 'grep -qF "kasbah deploy $RIG_TARGET 9.9.9" "$tmpdir/err"' \
    "and the command that would do it instead (said '$(cli_err)')"
assert '[ "$(versions_log)" = "$log_before" ]' "and versions.log is untouched"

# A pruned image. `kasbah server prune` is roadmap v0.2 and does not exist, so
# the retention window is **simulated** by removing the version tag by hand —
# which is exactly what prune will do to a tag old enough. :current still holds
# the image itself, so only the name kasbah looks for goes away.
rig_ssh "docker image rm $image_web:$v1" >/dev/null 2>&1
gone=$(rig_ssh "docker image inspect $image_web:$v1 >/dev/null 2>&1 && echo present || echo absent" 2>/dev/null | tr -d '\r')
assert '[ "$gone" = "absent" ]' "the $v1 web image tag is off the rig (docker says '$gone')"

rollback "$RIG_TARGET" "$v1"; rc=$?
assert '[ "$rc" != "0" ]' "rolling back to a version whose image has been pruned is refused (exit $rc)"
assert 'grep -qF "Image $image_web:$v1 is no longer on the VPS" "$tmpdir/err"' \
    "naming the image that is gone (said '$(cli_err)')"
assert 'grep -qF "NOT byte-identical to the original" "$tmpdir/err"' \
    "saying plainly that a rebuild is not the bytes that shipped (said '$(cli_err)')"
assert 'grep -qF "git checkout v$v1 && kasbah build-push $RIG_TARGET" "$tmpdir/err"' \
    "with the escape hatch, which kasbah does not take by itself (said '$(cli_err)')"
assert '[ "$(versions_log)" = "$log_before" ]' "and nothing was written to versions.log"
assert '[ "$(image_id "$image_web:current")" = "$v1_web_id" ]' \
    "and :current is where the successful rollback left it"

# That refusal also stands on the record having a `rollback` entry as $v1's most
# recent mention: the image check is downstream of the existence check, so
# reaching it at all proves the entry counted.
assert '[[ "$(sed -n 3p <<<"$log_before")" == *" rollback $v1 "* ]]' \
    "$v1's most recent mention in the record is a rollback entry, and it still counts as proof
        it ran here (line: $(sed -n 3p <<<"$log_before"))"

# ==================================================================================
# `deploy X.Y.Z` — the same path, forward
# ==================================================================================
# Back to $v2 by naming it: a `deploy` entry this time, from v$v2's own tree, onto
# images that are still on the server.
log_before="$(versions_log)"
deploy "$RIG_TARGET" "$v2"; rc=$?
assert '[ "$rc" = "0" ]' "a deploy of a named version succeeds (exit $rc: $(cli_err))"
log="$(versions_log)"
read -r _ t_action t_version _ <<<"$(tail -n 1 <<<"$log")"
assert '[ "$(wc -l <<<"$log")" = "$(( $(wc -l <<<"$log_before") + 1 ))" ] && [ "$t_action" = deploy ] && [ "$t_version" = "$v2" ]' \
    "it appends one \`deploy $v2\` entry (log: $log)"
assert '[ "$(image_id "$image_web:current")" = "$(image_id "$image_web:$v2")" ]' \
    "and :current is $v2's image again"
assert '[ "$(remote_sha "$frag_remote")" = "$(ref_sha "v$v2:traefik-dynamic.yml")" ]' \
    "and the route is v$v2's own fragment, shipped out of the tag"
assert 'grep -qF "Deployed $project $v2 to $RIG_TARGET" "$tmpdir/err"' \
    "and says what it did (said '$(cli_err)')"

# --- Leave the rig as it was found, but only on success ---------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $image_web:$v1 $image_worker:$v1 $image_web:$v2 $image_worker:$v2 $image_web:current $image_worker:current" >/dev/null 2>&1
    rig_clean || fail=1
fi

exit "$fail"
