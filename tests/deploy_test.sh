#!/usr/bin/env bash
# Test: lib/deploy.sh and templates/remote-deploy.sh — everything about a deploy
# that does not need a server.
#
# The pure parts (the sync: list, the version tag, the exit-code choices) are
# driven straight through the library. The versions.log line is driven through
# the real remote-deploy.sh with a stub docker on PATH, because the line is only
# worth anything in the file the script actually appends to.
#
# The ssh stub is the other half: it records every invocation, so a case can
# assert that a local failure never reached the network at all.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="$(cat "$repo_dir/VERSION")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# A bash snippet with the library sourced, in a subshell of its own so a die()
# ends the snippet and not the suite.
run_snippet() {
    bash -c '
        set -uo pipefail
        . "$KASBAH_LIB_DIR/deploy.sh"
        '"$1"'
    '
}

# --- The sync: list -------------------------------------------------------------
# One entry per line, exactly as yq hands them over. Printed back as
# src|dst|recurse so a parse can be compared as one string.
parse_sync() {
    run_snippet '
        _deploy_parse_sync_lines "$(printf '"'"'%b'"'"' "'"$1"'")"
        for i in "${!_DEPLOY_SRC[@]}"; do
            printf "%s|%s|%s\n" "${_DEPLOY_SRC[$i]}" "${_DEPLOY_DST[$i]}" "${_DEPLOY_RECURSE[$i]}"
        done
    ' 2>&1
}

out="$(parse_sync 'compose.prod.yml -> compose.yml\n.env.prod.example\nsite/\n')"; rc=$?
assert '[ "$rc" = "0" ]' "the three documented sync forms parse (rc $rc: $out)"
assert '[ "$(sed -n 1p <<<"$out")" = "compose.prod.yml|compose.yml|no" ]' \
    "'a -> b' renames on arrival (got '$(sed -n 1p <<<"$out")')"
assert '[ "$(sed -n 2p <<<"$out")" = ".env.prod.example|.env.prod.example|no" ]' \
    "a bare entry keeps its path (got '$(sed -n 2p <<<"$out")')"
assert '[ "$(sed -n 3p <<<"$out")" = "site|site|yes" ]' \
    "a trailing slash means recurse, and is not kept in the path (got '$(sed -n 3p <<<"$out")')"

out="$(parse_sync 'docker/pg/   ->   etc/pg\n')"
assert '[ "$out" = "docker/pg|etc/pg|yes" ]' \
    "whitespace around the arrow is trimmed and either side may carry the slash (got '$out')"
out="$(parse_sync 'a -> b/\n')"
assert '[ "$out" = "a|b|yes" ]' \
    "a trailing slash on the destination alone also means recurse (got '$out')"

# CRLF: a manifest authored on Windows must not ship a path ending in \r, which
# creates a remote file nobody can name.
out="$(parse_sync 'compose.prod.yml -> compose.yml\r\nsite/\r\n')"
assert '[ "$(sed -n 1p <<<"$out")" = "compose.prod.yml|compose.yml|no" ]' \
    "a CRLF entry loses the carriage return (got '$(sed -n 1p <<<"$out")')"
assert '[ "$(sed -n 2p <<<"$out")" = "site|site|yes" ]' \
    "including one that ends in a slash (got '$(sed -n 2p <<<"$out")')"

# An empty list is refused rather than deploying nothing at all.
out="$(parse_sync '\n')"; rc=$?
assert '[ "$rc" != "0" ]' "an empty sync: list is refused (rc $rc)"
assert 'grep -qF "sync: list is empty" <<<"$out"' "and says so (said '$out')"

# Shapes that would mean something else on the far side.
for bad in '/etc/passwd' '../../etc/passwd' 'a/../../b' 'host:path' '-e' 'a//b'; do
    out="$(parse_sync "$bad\\n")"; rc=$?
    assert '[ "$rc" != "0" ]' "sync entry '$bad' is refused (rc $rc, said '$out')"
    assert 'grep -qF -- "$bad" <<<"$out"' "and the refusal quotes it back (said '$out')"
done
# The same checks apply to the destination half, not only the source.
out="$(parse_sync 'ok.txt -> /etc/passwd\n')"; rc=$?
assert '[ "$rc" != "0" ]' "an absolute destination is refused too (rc $rc, said '$out')"
assert 'grep -qF "destination" <<<"$out"' "and names which side was wrong (said '$out')"

# The positive control for the six refusals above: a plain nested path is fine.
out="$(parse_sync 'docker/postgres/init.sql\n')"
assert '[ "$out" = "docker/postgres/init.sql|docker/postgres/init.sql|no" ]' \
    "a nested path is accepted — else the refusals above prove nothing (got '$out')"

# --- Sync sources must exist ----------------------------------------------------
srcdir="$tmpdir/sources"
mkdir -p "$srcdir/site"
: > "$srcdir/compose.prod.yml"
: > "$srcdir/site/index.html"

check_sources() {
    ( cd "$srcdir" && run_snippet '
        _deploy_parse_sync_lines "$(printf '"'"'%b'"'"' "'"$1"'")"
        _deploy_check_sources
        echo ok
    ' 2>&1 )
}

out="$(check_sources 'compose.prod.yml\nsite/\n')"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "ok" ]' \
    "a sync list whose paths all exist passes (rc $rc: $out)"

out="$(check_sources 'compose.prod.yml\nmissing.yml\nalso-missing/\n')"; rc=$?
assert '[ "$rc" != "0" ]' "a sync entry naming a path that is not there fails (rc $rc)"
assert 'grep -qF "missing.yml" <<<"$out"' "the failure names the missing file (said '$out')"
assert 'grep -qF "also-missing" <<<"$out"' \
    "and reports every bad entry in one run, not just the first (said '$out')"

out="$(check_sources 'site\n')"; rc=$?
assert '[ "$rc" != "0" ]' "a directory listed without a trailing slash fails (rc $rc)"
assert 'grep -qF "site/" <<<"$out"' "and says to add the slash (said '$out')"

out="$(check_sources 'compose.prod.yml/\n')"; rc=$?
assert '[ "$rc" != "0" ]' "a file listed with a trailing slash fails (rc $rc)"
assert 'grep -qF "but it is a file" <<<"$out"' "and says why (said '$out')"

# --- Version resolution ---------------------------------------------------------
pick_version() {
    run_snippet '
        _deploy_pick_version "$(printf '"'"'%b'"'"' "'"$1"'")" v
        printf "%s\n" "$v"
    ' 2>&1
}

out="$(pick_version 'v1.2.3\n')"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "1.2.3" ]' \
    "one v-tag yields the version without its v (rc $rc: '$out')"
out="$(pick_version 'v0.1.0-rc.1\n')"
assert '[ "$out" = "0.1.0-rc.1" ]' "a pre-release suffix survives (got '$out')"

out="$(pick_version '\n')"; rc=$?
assert '[ "$rc" != "0" ]' "no tag on HEAD is a failure (rc $rc)"
assert 'grep -qF "no version tag" <<<"$out"' "and says the tag is missing (said '$out')"
assert 'grep -qF "git tag v1.0.0" <<<"$out"' "and shows how to make one (said '$out')"

out="$(pick_version 'release-7\nnightly\n')"; rc=$?
assert '[ "$rc" != "0" ]' "tags that are not v-tags do not count as a version (rc $rc)"
assert 'grep -qF "release-7 nightly" <<<"$out"' \
    "and the message names what HEAD does carry (said '$out')"
# The branch, not just the failure: without this the case passes just as well
# against a version picker that counted `release-7` as a v-tag and then
# complained about there being two of them.
assert 'grep -qF "no version tag" <<<"$out"' \
    "and it is the no-tag branch that fired (said '$out')"
out="$(pick_version 'release-7\n')"; rc=$?
assert '[ "$rc" != "0" ] && grep -qF "no version tag" <<<"$out"' \
    "one tag that is not a v-tag is still no version at all (rc $rc, said '$out')"

out="$(pick_version 'v1.2.3\nv1.3.0\n')"; rc=$?
assert '[ "$rc" != "0" ]' "two v-tags on HEAD is a failure (rc $rc)"
assert 'grep -qF "2 version tags" <<<"$out"' "and counts them (said '$out')"
assert 'grep -qF "v1.2.3 v1.3.0" <<<"$out"' "and names both (said '$out')"

out="$(pick_version 'v1.2\n')"; rc=$?
assert '[ "$rc" != "0" ]' "a v-tag that is not semver is refused (rc $rc)"
assert 'grep -qF "v1.2" <<<"$out"' "and quotes it (said '$out')"

# --- The versions.log line, written by the real script --------------------------
# A stub docker on PATH records what it was asked to do and says yes. The line
# is then read back out of the file remote-deploy.sh appended to.
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit "${DOCKER_RC:-0}"
STUB
chmod 0755 "$stub_dir/docker"

new_project() {
    local dir="$tmpdir/$1"
    rm -rf "$dir"
    mkdir -p "$dir/scripts"
    cp "$repo_dir/templates/remote-deploy.sh" "$dir/scripts/remote-deploy.sh"
    chmod 0755 "$dir/scripts/remote-deploy.sh"
    : > "$dir/compose.yml"
    : > "$dir/.env"
    printf '%s' "$dir"
}

proj="$(new_project demo)"
export DOCKER_LOG="$tmpdir/docker.log"
: > "$DOCKER_LOG"
out=$(env PATH="$stub_dir:$PATH" KASBAH_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
        COMPOSE_PROJECT_NAME=hostile-project \
        bash "$proj/scripts/remote-deploy.sh" deploy 1.2.3 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "remote-deploy.sh deploy succeeds against a stub docker (rc $rc: $out)"
assert 'grep -qF "compose -p demo up -d --remove-orphans" "$DOCKER_LOG"' \
    "it runs compose up with -p <project> (docker saw: $(cat "$DOCKER_LOG"))"
assert '! grep -qF "hostile-project" "$DOCKER_LOG"' \
    "and a COMPOSE_PROJECT_NAME in the environment does not reach it (docker saw: $(cat "$DOCKER_LOG"))"

log_line="$(cat "$proj/versions.log" 2>/dev/null)"
assert '[ "$(wc -l < "$proj/versions.log")" = "1" ]' \
    "one deploy appends exactly one line (got '$log_line')"
read -r ts action version backup kasbah digest extra <<<"$log_line"
assert '[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' \
    "field 1 is a UTC ISO-8601 timestamp (got '$ts')"
assert '[ "$action" = "deploy" ]'      "field 2 is the action (got '$action')"
assert '[ "$version" = "1.2.3" ]'      "field 3 is the version (got '$version')"
assert '[ "$backup" = "no-backup" ]'   "field 4 is the backup path or no-backup (got '$backup')"
assert '[ "$kasbah" = "kasbah=9.9.9" ]' \
    "then kasbah=<version>, from the environment kasbah passed (got '$kasbah')"
assert '[ "$digest" = "digest=-" ]'    "and digest=- for a stock-only project (got '$digest')"
assert '[ -z "$extra" ]'               "with nothing after it yet (got '$extra')"

# A second deploy appends; it never rewrites.
env PATH="$stub_dir:$PATH" KASBAH_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj/scripts/remote-deploy.sh" deploy 1.2.4 >/dev/null 2>&1
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "a second deploy appends rather than replacing ($(wc -l < "$proj/versions.log") lines)"
assert '[ "$(head -1 "$proj/versions.log")" = "$log_line" ]' \
    "and the first line is untouched"
assert 'grep -qF " deploy 1.2.4 " "$proj/versions.log"' "the second version is in the log"

# kasbah= is honest when nobody said which kasbah is driving.
proj2="$(new_project bare)"
env -u KASBAH_VERSION PATH="$stub_dir:$PATH" DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj2/scripts/remote-deploy.sh" deploy 2.0.0 >/dev/null 2>&1
assert 'grep -qF "kasbah=unknown" "$proj2/versions.log"' \
    "a hand-run with no KASBAH_VERSION logs kasbah=unknown rather than a guess (got '$(cat "$proj2/versions.log")')"

# A failed compose writes no line: versions.log records what ran, and nothing ran.
proj3="$(new_project failing)"
out=$(env PATH="$stub_dir:$PATH" DOCKER_RC=1 DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj3/scripts/remote-deploy.sh" deploy 3.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a failed compose up fails the deploy (rc $rc: $out)"
assert 'grep -qF "up -d --remove-orphans failed" <<<"$out"' "naming the step (said '$out')"
assert '[ ! -f "$proj3/versions.log" ]' \
    "and appends nothing to versions.log — the log is what ran, not what was attempted"

# The preconditions the script checks for itself, so a hand-run on the server
# fails with a sentence rather than a compose stack trace.
proj4="$(new_project noenv)"
rm -f "$proj4/.env"
out=$(env PATH="$stub_dir:$PATH" DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj4/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "no .env on the server is a failure (rc $rc)"
assert 'grep -qF ".env is missing" <<<"$out"' "naming the file (said '$out')"

proj5="$(new_project nocompose)"
rm -f "$proj5/compose.yml"
out=$(env PATH="$stub_dir:$PATH" DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj5/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "no compose.yml on the server is a failure (rc $rc)"
assert 'grep -qF "sync: list" <<<"$out"' "and points at the sync list that should have shipped it (said '$out')"

# --- Nothing may shift the frozen fields ----------------------------------------
# The line is space-delimited and its first four fields are frozen forever, so
# an empty or space-bearing value does not produce a slightly-wrong entry — it
# produces one that every later reader parses into the wrong columns.
date_stub="$tmpdir/datestub"
mkdir -p "$date_stub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$date_stub/date"
chmod 0755 "$date_stub/date"
cp "$stub_dir/docker" "$date_stub/docker"

proj6="$(new_project nodate)"
out=$(env PATH="$date_stub:$PATH" KASBAH_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj6/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a date that fails is a hard failure, not a line starting with a space (rc $rc: $out)"
assert 'grep -qF "timestamp is empty" <<<"$out"' "naming the field (said '$out')"
assert '[ ! -f "$proj6/versions.log" ]' "and nothing was appended"

proj7="$(new_project spacey)"
out=$(env PATH="$stub_dir:$PATH" KASBAH_VERSION='1.0 beta' DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj7/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a KASBAH_VERSION with a space is refused (rc $rc: $out)"
assert 'grep -qF "kasbah version" <<<"$out"' "naming the field (said '$out')"
assert '[ ! -f "$proj7/versions.log" ]' "and nothing was appended"

# The control for both: the same script with both values sane writes its line,
# so the two refusals above are about the values and not about the stubs.
proj8="$(new_project sane)"
env PATH="$stub_dir:$PATH" KASBAH_VERSION='1.0-beta' DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj8/scripts/remote-deploy.sh" deploy 1.0.0 >/dev/null 2>&1
assert 'grep -qF "kasbah=1.0-beta" "$proj8/versions.log"' \
    "a hyphenated version writes normally (got '$(cat "$proj8/versions.log" 2>/dev/null)')"

out=$(env PATH="$stub_dir:$PATH" bash "$proj/scripts/remote-deploy.sh" rollback 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "rollback is refused by name, not silently accepted (rc $rc)"
assert 'grep -qF "rollback is not implemented" <<<"$out"' "saying so (said '$out')"

out=$(env PATH="$stub_dir:$PATH" bash "$proj/scripts/remote-deploy.sh" deploy '1.0.0 oops' 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a version with whitespace is refused — versions.log is space-delimited (rc $rc)"
out=$(env PATH="$stub_dir:$PATH" bash "$proj/scripts/remote-deploy.sh" deploy 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "deploy with no version is refused (rc $rc)"
assert 'grep -qF "needs a version" <<<"$out"' "saying what is missing (said '$out')"

# --- Exit codes, with a stub ssh ------------------------------------------------
# The stub answers the reachability probe and reports "no marker" (exit 3) for
# every remote script, which is the shape lib/deploy.sh turns into exit 4. Every
# invocation is recorded, so a case can assert that ssh was never called.
ssh_log="$tmpdir/ssh.log"
# Every ssh *and* rsync invocation of one run, in the order they were made, one
# line per call with the arguments |-separated so a flag can be matched as a
# whole field. The ordering is the point: which of the remote deploy and the
# fragment goes first is the defect this phase exists to have caught.
call_log="$tmpdir/calls.log"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
# The last argument is the remote command. `true` is ssh_connect's probe; a
# `bash -s` payload is a remote step, and this stub has no marker to give it.
last="${!#}"
case "$last" in
    true) exit 0 ;;
esac
# ssh_disconnect: `-O exit` closes the master and its status is ignored anyway.
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
exit "${SSH_STEP_RC:-3}"
STUB
chmod 0755 "$stub_dir/ssh"

project="$tmpdir/project"
rm -rf "$project"
cp -R "$repo_dir/tests/fixtures/demo" "$project"
(
    cd "$project" || exit 1
    git init -q .
    git config user.email kasbah-test@example.invalid
    git config user.name  "kasbah test"
    git add -A
    git commit -qm "fixture"
    git tag v1.0.0
) >/dev/null 2>&1

# `kasbah`, as installed, with the stub first on PATH and a HOME of its own so
# the ssh control socket has somewhere harmless to live.
deploy_cli() {
    : > "$ssh_log"; : > "$call_log"
    # The suite exports KASBAH_LIB_DIR for its own snippets; the CLI has to
    # resolve its own, the way an installed kasbah does.
    # stdin from /dev/null, not from whatever the suite was started with: the
    # env step asks what to do about drift when there is a terminal to ask on,
    # and a run by hand in a real shell would otherwise stop at a prompt. The
    # refusal that replaces it is asserted below.
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" \
        SSH_LOG="$ssh_log" CALL_LOG="$call_log" \
        "$repo_dir/bin/kasbah" deploy "$@" </dev/null 2>&1
}
mkdir -p "$tmpdir/home"

out=$( cd "$tmpdir" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "2" ]' "deploy outside a project exits 2 (rc $rc: $out)"
assert 'grep -qF "No kasbah.yml" <<<"$out"' "naming the file it wanted (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ]' "no target and no state is a plain failure (rc $rc: $out)"
assert 'grep -qF "last_server" <<<"$out"' "naming the field that would have answered (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "4" ]' "a server with no marker exits 4 (rc $rc: $out)"
assert 'grep -qF "/apps/.kasbah/server.json" <<<"$out"' \
    "naming the file it looked for (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and naming the flag that makes a prepared server look unprepared (said '$out')"
# The message must not be followable into a disaster. A bare
# `kasbah server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack there and brings it up as compose project
# `traefik` — the frozen name the live one already carries — so compose
# recreates the running proxy against the new file and every site goes dark.
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" <<<"$out"' \
    "and never prints a runnable bare \`server init\` as the remedy (said '$out')"
assert '[ ! -f "$project/.kasbah/state.json" ]' \
    "a failed deploy writes no state — last_server is only for servers that worked"

out=$( cd "$project" && SSH_STEP_RC=0 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "an empty marker is not accepted as one (rc $rc: $out)"
assert 'grep -qF "not a JSON object" <<<"$out"' "and says what it read (said '$out')"

# --- The whole path, against a server that is prepared --------------------------
# The stub above answers "no marker" to every remote step, so everything after
# _deploy_read_marker — the three syncs, the helper, the env step, the remote
# step, the fragment — was unreachable from this suite and pinned only by the
# rig. This one answers as a prepared server does, so cmd_deploy runs to the end
# and every call it makes lands in $call_log in order.
#
# The env step's two remote calls are answered from the environment, so a case
# can put the far side into any of the four states the step branches on: no
# .env, no template, drift, in sync. MARKER is settable for the same reason.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
# ssh -n reads no stdin; emulated so a step that lost its payload looks lost.
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
case "$last" in
    true) exit 0 ;;
    # A remote step. The script itself arrives on stdin and this stub never runs
    # it, so what the real step would have printed is written out here instead.
    "'bash' '-s'"*) cat >/dev/null ;;
esac
case "$last" in
    "'bash' '-s' '--' '/apps'")
        marker_default='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'
        printf '%s\n' "${MARKER-$marker_default}" ;;
    # The marker read is matched exactly above, so anything else naming the
    # project is the prepare step — whatever apps path the marker steered it to.
    "'bash' '-s' '--' "*" 'demo'"*)
        printf 'prepared=yes\n' ;;
    *"setup-env.sh' '--drift' "*)
        [ -z "${DRIFT_OUT+set}" ] || { printf '%s' "$DRIFT_OUT"; exit "${DRIFT_RC:-0}"; }
        [ -z "${DRIFT_RC:-}" ] || exit "$DRIFT_RC"
        printf 'template_exists=%s\n' "${ENV_TEMPLATE:-yes}"
        printf 'env_exists=%s\n' "${ENV_EXISTS:-yes}"
        printf 'missing=%s\n' "${ENV_MISSING:-}"
        printf 'extra=%s\n' "${ENV_EXTRA:-}" ;;
    *"setup-env.sh' '--inject' "*) exit "${INJECT_RC:-0}" ;;
    *"remote-deploy.sh' 'deploy' '1.0.0'") ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
{ printf 'rsync'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
exit 0
STUB
chmod 0755 "$stub_dir/ssh" "$stub_dir/rsync"

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a prepared server deploys (rc $rc: $out)"
assert 'grep -qF "Deployed demo 1.0.0 to deploy@vps" <<<"$out"' "and says so (said '$out')"

line_of() { grep -n -m1 -F -- "$1" <<<"$calls" | cut -d: -f1; }
# Anchored: the prepare step's argument list starts with the marker read's, so
# an unanchored match would find whichever came first and call it the marker.
n_marker=$(grep -n -m1 -E "\|'bash' '-s' '--' '/apps'\$" <<<"$calls" | cut -d: -f1)
n_prepare=$(line_of "|'bash' '-s' '--' '/apps' '/apps/data' 'demo'")
n_compose=$(line_of "|compose.prod.yml|")
n_helper=$(line_of "|$repo_dir/templates/remote-deploy.sh|")
n_envhelper=$(line_of "|$repo_dir/lib/env.sh|")
n_drift=$(line_of "setup-env.sh' '--drift'")
n_inject=$(line_of "setup-env.sh' '--inject'")
n_remote=$(line_of "remote-deploy.sh' 'deploy' '1.0.0'")
n_fragment=$(line_of "|traefik-dynamic.yml|")
assert '[ -n "$n_marker" ] && [ -n "$n_prepare" ] && [ -n "$n_compose" ] &&
        [ -n "$n_helper" ] && [ -n "$n_envhelper" ] && [ -n "$n_drift" ] &&
        [ -n "$n_inject" ] && [ -n "$n_remote" ] && [ -n "$n_fragment" ]' \
    "the run made all nine calls the order below is about (marker $n_marker, prepare $n_prepare, sync $n_compose, helper $n_helper, env helper $n_envhelper, drift $n_drift, inject $n_inject, remote $n_remote, fragment $n_fragment)
        calls: $calls"
# A call that never happened orders as 0 rather than as an empty string: the
# assertion above is the one that reports it, and the ones below should then
# fail on their own terms instead of on `[: integer expression expected`.
for n in n_marker n_prepare n_compose n_helper n_envhelper n_drift n_inject n_remote n_fragment; do
    [ -n "${!n}" ] || printf -v "$n" '%s' 0
done

# **The ordering this phase exists to have caught.** A Traefik fragment
# registers a router the moment the file lands, whether or not anything is
# behind it — so shipping it before `compose up` turns any failed deploy into a
# live route to a container that never started, and the host serves 502 until
# some later deploy succeeds. On a first deploy that is an honest 404 turned
# permanent (docs/phases/02-spine.md → 2.4, docs/build-deploy.md).
assert '[ "$n_fragment" -gt "$n_remote" ]' \
    "the fragment ships after the remote deploy returns, never before it (fragment on line $n_fragment, remote step on $n_remote)"
assert '[ "$n_compose" -gt "$n_prepare" ] && [ "$n_prepare" -gt "$n_marker" ]' \
    "nothing is written before the server has been read and judged (marker $n_marker, prepare $n_prepare, first sync $n_compose)"
assert '[ "$n_remote" -gt "$n_helper" ]' \
    "the helper is on the server before the step that runs it (helper $n_helper, remote step $n_remote)"

# The env step, at the one place in the run where it works. After the project
# rsync, because the interactive setup prompts from the .env.prod.example that
# rsync ships; after the helper, because it is the helper it runs; and before
# the remote deploy, because `compose up` reads the .env it writes — an
# injection after `compose up` refreshes a limit nothing will read until the
# next deploy.
assert '[ "$n_drift" -gt "$n_compose" ] && [ "$n_drift" -gt "$n_envhelper" ]' \
    "the env check runs after the template and the script it needs are both there (sync $n_compose, env helper $n_envhelper, drift $n_drift)"
assert '[ "$n_inject" -gt "$n_drift" ]' \
    "injection runs after the drift check, never before (drift $n_drift, inject $n_inject)"
assert '[ "$n_remote" -gt "$n_inject" ]' \
    "and before compose up reads the file it wrote (inject $n_inject, remote step $n_remote)"
# The values are the marker's own, spelled as the marker spells them: `14.4`
# reformatted to `14.40` is a different cpus: and `54g` to `54G` a different
# mem_limit.
assert 'grep -qF "setup-env.sh'\'' '\''--inject'\'' '\''/apps/demo'\'' '\''KASBAH_CPU_LIMIT=14.4'\'' '\''KASBAH_MEM_LIMIT=54g'\''" <<<"$calls"' \
    "injection carries the marker's two limits, unreformatted ($(grep -F -- "--inject" <<<"$calls"))"
assert 'grep -qF "|-pt|--chmod=F755|-s|$repo_dir/lib/env.sh|deploy@vps:/apps/demo/scripts/setup-env.sh" <<<"$calls"' \
    "and setup-env.sh is lib/env.sh itself, shipped executable — not a generated copy ($(grep -F "env.sh|" <<<"$calls"))"

# The rsync flag sets, whole, and each of them ends its line: -a would carry
# ownership and times a deploy has no business asserting, and -s is what stops
# the far side re-splitting a path with a space in it on the remote shell. The
# fields ahead of the flags are the `-e ssh …` ssh_rsync builds, asserted
# separately below because the control path in it changes every run.
assert 'grep -qF "|-lpt|-s|compose.prod.yml|deploy@vps:/apps/demo/compose.yml" <<<"$calls"' \
    "a renamed file syncs as one file to its new name ($(grep -F "compose.prod.yml" <<<"$calls"))"
assert 'grep -qF "|-lpt|-s|.env.prod.example|deploy@vps:/apps/demo/.env.prod.example" <<<"$calls"' \
    "a plain file keeps its path ($(grep -F ".env.prod.example" <<<"$calls"))"
assert 'grep -qF "|-rlpt|-s|site/|deploy@vps:/apps/demo/site/" <<<"$calls"' \
    "a directory entry recurses, with the trailing slashes rsync reads as contents-of ($(grep -F "site/" <<<"$calls"))"
assert 'grep -qF "|-pt|--chmod=F755|-s|$repo_dir/templates/remote-deploy.sh|deploy@vps:/apps/demo/scripts/remote-deploy.sh" <<<"$calls"' \
    "the helper ships executable, stated rather than inherited from the checkout ($(grep -F "remote-deploy.sh|" <<<"$calls"))"
assert 'grep -qF "|-pt|--chmod=F644|-s|traefik-dynamic.yml|deploy@vps:/apps/traefik/dynamic/demo.yml" <<<"$calls"' \
    "the fragment ships 644 to the name kasbah owns ($(grep -F "traefik-dynamic.yml" <<<"$calls"))"

rsync_calls=$(grep -c '^rsync|' <<<"$calls")
rsync_with_s=$(grep -c '^rsync|.*|-s|' <<<"$calls")
rsync_with_e=$(grep -c '^rsync|-e|ssh -o ControlMaster=auto -o ControlPath=' <<<"$calls")
assert '[ "$rsync_calls" = "$rsync_with_e" ]' \
    "every rsync rides the run's own ssh master through -e ($rsync_with_e of $rsync_calls)"
assert '[ "$rsync_calls" = "6" ]'            "six rsync calls in a deploy (got $rsync_calls)"
assert '[ "$rsync_calls" = "$rsync_with_s" ]' "every one of them passes -s ($rsync_with_s of $rsync_calls)"
# --inplace would write through the file Traefik is watching instead of renaming
# a complete one over it, so the watcher would see a truncated fragment and stop
# routing the site until the next deploy.
assert '! grep -qF -- "--inplace" <<<"$calls"' \
    "no rsync in a deploy uses --inplace — the fragment must arrive as an atomic rename ($(grep -F -- "--inplace" <<<"$calls"))"

assert '[ "$(jq -r .last_server "$project/.kasbah/state.json")" = "deploy@vps" ]' \
    "a deploy that worked records the server it went to"
assert '[ "$(jq -r .last_version "$project/.kasbah/state.json")" = "1.0.0" ]' \
    "and the version it shipped"
rm -rf "$project/.kasbah"

# A project with no fragment deploys anyway, and is warned about: T01 is a
# warning, and a worker with no HTTP surface is a real project shape. What must
# not happen is the previous fragment being deleted — taking a site off the
# internet is `kasbah drop`'s decision.
mv "$project/traefik-dynamic.yml" "$tmpdir/held-fragment.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a project with no traefik-dynamic.yml still deploys (rc $rc: $out)"
assert 'grep -qF "no traefik-dynamic.yml" <<<"$out"' "and says the route was not written (said '$out')"
assert '[ "$(grep -c "dynamic/demo.yml" <<<"$calls")" = "0" ]' \
    "nothing at all was sent to the dynamic directory (sent: $(grep -F "dynamic/" <<<"$calls"))"
mv "$tmpdir/held-fragment.yml" "$project/traefik-dynamic.yml"
rm -rf "$project/.kasbah"

# --- The env step ---------------------------------------------------------------
# Everything below runs against the prepared-server stub, which answers the two
# remote env calls from the environment. `deploy_cli` feeds /dev/null to stdin,
# so every one of these is the headless shape a CI runner produces — which is
# the one that must never stop at a prompt.
env_calls() { grep -F "setup-env.sh" <<<"$(<"$call_log")"; }

# Drift, nothing said, nobody to ask. The exit code is 5 and not 1, because
# "the env step could not complete" is a distinct thing a script can branch on
# (docs/cli.md → exit codes).
out=$( cd "$project" && ENV_MISSING=NEW_KEY ENV_EXTRA=OLD_KEY deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "5" ]' "drift with no terminal and no flag exits 5 (rc $rc: $out)"
assert 'grep -qF -- "--on-drift" <<<"$out"' \
    "naming the flag that would have answered (said '$out')"
assert 'grep -qF "NEW_KEY" <<<"$out" && grep -qF "OLD_KEY" <<<"$out"' \
    "and both sides of the drift, so the reader knows which keys (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' \
    "nothing was deployed ($(grep -F "remote-deploy.sh' 'deploy'" <<<"$calls"))"
assert '! grep -qF "dynamic/demo.yml" <<<"$calls"' \
    "and no route was written — the fragment is downstream of a step that refused"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and no project state was recorded"

# Drift is two lists and either one alone is drift: a .env holding a key the
# template dropped is as much a reason to stop as one missing a key it gained.
out=$( cd "$project" && ENV_EXTRA=STALE_KEY deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "5" ]' "an extra key on its own is drift too (rc $rc: $out)"
assert 'grep -qF "STALE_KEY" <<<"$out"' "and is named (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "nothing was deployed"

# The same drift, answered three ways.
out=$( cd "$project" && ENV_MISSING=NEW_KEY deploy_cli deploy@vps --on-drift=abort ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "5" ]' "--on-drift=abort exits 5 (rc $rc: $out)"
assert 'grep -qF "aborted" <<<"$out"' "saying it aborted (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and deployed nothing"
assert '! grep -qF -- "--inject" <<<"$calls"' \
    "not even the managed block: an aborted deploy touches the server's .env not at all ($(env_calls))"

out=$( cd "$project" && ENV_MISSING=NEW_KEY deploy_cli deploy@vps --on-drift=continue ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "--on-drift=continue deploys anyway (rc $rc: $out)"
assert 'grep -qF "has drifted" <<<"$out"' "having said the .env drifted (said '$out')"
assert 'grep -qF -- "--inject" <<<"$calls"' "and still refreshed the managed block ($(env_calls))"
assert 'grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and ran the deploy"
rm -rf "$project/.kasbah"

# `setup` is the answer that needs a terminal, so headless it is the refusal —
# and a different one from "nobody said": the flag *was* passed.
out=$( cd "$project" && ENV_MISSING=NEW_KEY deploy_cli deploy@vps --on-drift=setup ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "5" ]' "--on-drift=setup with no terminal exits 5 (rc $rc: $out)"
assert 'grep -qF "no terminal" <<<"$out"' "saying what is missing (said '$out')"
assert 'grep -qF "kasbah env" <<<"$out"' "and where to get one (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and deployed nothing"
# The whole reason for the refusal: run headless, the generator reads EOF at
# every prompt and its `|| true` accepts every default silently, secrets and all.
assert '! grep -qE "^ssh\|-t\|" <<<"$calls"' \
    "and asked for no pty it could not use ($(grep -E "^ssh\|-t" <<<"$calls"))"

# A .env that is not there at all. The branch the old `.env must already exist`
# precondition used to hold, one step later in the run.
out=$( cd "$project" && ENV_EXISTS=no ENV_MISSING=DEMO_GREETING deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "5" ]' "a missing .env with no terminal exits 5 (rc $rc: $out)"
assert 'grep -qF "does not exist yet" <<<"$out"' "saying the file is not there (said '$out')"
assert 'grep -qF "kasbah env deploy@vps" <<<"$out"' \
    "and naming the command that renders it (said '$out')"
# The remedies have to be ones that can reach this branch. A missing .env sets
# action=setup before --on-drift= is ever consulted, so offering that flag here
# would tell the operator to re-run the identical command for the identical exit
# 5 — refusing safely while naming a remedy that cannot work is the class Phase
# 2 named, and Phase 2's own refusal for this situation gave a working recipe.
assert '! grep -qF -- "--on-drift=continue" <<<"$out"' \
    "and offering no flag that cannot reach it (said '$out')"
assert 'grep -qF "does not reach this" <<<"$out"' \
    "saying so outright, since the flag is in the command's own --help (said '$out')"
assert 'grep -qF "cp /apps/demo/.env.prod.example /apps/demo/.env" <<<"$out"' \
    "and giving the by-hand recipe that does work (said '$out')"
# The drift branch is where the flag does reach, and its remedy list says so —
# without this the assertion above passes against a kasbah that never mentions
# the flag anywhere.
out=$( cd "$project" && ENV_MISSING=NEW_KEY deploy_cli deploy@vps --on-drift=setup ); rc=$?
assert 'grep -qF -- "--on-drift=continue" <<<"$out"' \
    "the drift refusal does offer it, because there it is consulted (said '$out')"
assert '! grep -qF "does not reach this" <<<"$out"' \
    "and does not say otherwise (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "nothing was deployed"
assert '! grep -qF "dynamic/demo.yml" <<<"$calls"' "and no route was written"
assert '! grep -qF -- "--inject" <<<"$calls"' \
    "and no block was written into a .env that does not exist ($(env_calls))"
# The template and the helper *are* shipped first, on purpose: they are what the
# `kasbah env` the message recommends will run against.
assert 'grep -qF "/apps/demo/scripts/setup-env.sh" <<<"$calls"' \
    "the helper reached the server before the step gave up ($(grep -F "scripts/" <<<"$calls"))"

# Neither file. There is nothing to render from, and the message says which file
# the project is missing rather than which the server is.
out=$( cd "$project" && ENV_EXISTS=no ENV_TEMPLATE=no deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "5" ]' "no .env and no template exits 5 (rc $rc: $out)"
assert 'grep -qF "/apps/demo/.env" <<<"$out"' "naming the file that is not there (said '$out')"
assert 'grep -qF ".env.prod.example" <<<"$out"' "and the template it would come from (said '$out')"
assert 'grep -qF "sync:" <<<"$out"' "and the list that would have shipped it (said '$out')"

# A .env with no template beside it is not drift, however different the key sets
# are: every key would read as `extra` against an empty template, so the deploy
# warns about the missing file and gets on with it.
out=$( cd "$project" && ENV_TEMPLATE=no ENV_EXTRA="A B C" deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a .env with no template on the server still deploys (rc $rc: $out)"
assert 'grep -qF "cannot be checked for drift" <<<"$out"' "with a warning (said '$out')"
assert '! grep -qF -- "--on-drift" <<<"$out"' \
    "and no drift prompt for keys an absent template cannot have (said '$out')"
assert 'grep -qF -- "--inject" <<<"$calls"' "the block is still refreshed ($(env_calls))"
rm -rf "$project/.kasbah"

# The flag is validated where it is parsed: a typo costs one sentence before the
# first connection, not a refusal at the bottom of a deploy.
out=$( cd "$project" && deploy_cli deploy@vps --on-drift=maybe ); rc=$?
assert '[ "$rc" != "0" ]' "--on-drift=maybe is refused (rc $rc: $out)"
assert 'grep -qF "setup, continue or abort" <<<"$out"' "listing the three answers (said '$out')"
assert '[ ! -s "$ssh_log" ]' "before any connection (ssh saw: $(cat "$ssh_log"))"
out=$( cd "$project" && deploy_cli deploy@vps --on-drift= ); rc=$?
assert '[ "$rc" != "0" ]' "an empty --on-drift= is refused rather than read as unset (rc $rc: $out)"
out=$( cd "$project" && deploy_cli deploy@vps --on-drift setup ); rc=$?
assert '[ "$rc" != "0" ]' "--on-drift without '=' is refused (rc $rc: $out)"
assert 'grep -qF -- "--on-drift=setup" <<<"$out"' "showing the form that works (said '$out')"

# The far side answering something else is a failure, not a fact. "no drift" and
# "the report never arrived" are the same empty string once absorbed.
out=$( cd "$project" && DRIFT_OUT="env_exists=yes"$'\n' deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a truncated env report fails the deploy (rc $rc: $out)"
assert 'grep -qF "template_exists" <<<"$out" && grep -qF "missing" <<<"$out"' \
    "naming the answers that never came (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and nothing was deployed"

out=$( cd "$project" && DRIFT_RC=7 deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a setup-env.sh that will not run fails the deploy (rc $rc: $out)"
assert 'grep -qF "exited 7" <<<"$out"' "quoting its status (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and nothing was deployed"

# Injection is a precondition of `compose up`, not a finishing touch: without
# the block, KASBAH_CPU_LIMIT is unset and the compose file fails outright.
out=$( cd "$project" && INJECT_RC=5 deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
# Exit 1, deliberately, and pinned so the two families cannot quietly merge: 5
# is for a *choice* the operator can revisit (drift declined, a question nobody
# was there to answer), and re-running with a flag or a terminal clears it. A
# refused injection is the far side breaking, like the probe above or the helper
# rsync, and nothing the operator answers will change it. The remote status is
# deliberately 5 here, so a kasbah that passed it through would look right.
assert '[ "$rc" = "1" ]' "an injection that fails fails the deploy with 1, not 5 (rc $rc: $out)"
assert 'grep -qF "KASBAH_CPU_LIMIT" <<<"$out"' "saying what would have broken (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and nothing was deployed"
assert '! grep -qF "dynamic/demo.yml" <<<"$calls"' "and no route was written"

# A marker with no limits is not a marker this kasbah can deploy from: there is
# no default for someone else's server, and an empty `cpus:` is a compose file
# that does not parse.
out=$( cd "$project" && MARKER='{"apps_path":"/apps","data_path":"/apps/data"}' deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a marker without the two limits is refused (rc $rc: $out)"
assert 'grep -qF "cpu_limit" <<<"$out"' "naming the field (said '$out')"
assert '[ "$(grep -c "^rsync|" <<<"$calls")" = "0" ]' \
    "before anything is shipped (rsync saw: $(grep "^rsync|" <<<"$calls"))"
out=$( cd "$project" && MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1 4","mem_limit":"4g"}' deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "so is a limit with a space in it (rc $rc: $out)"
# Each limit on its own, both ways round: a check that only ever looked at
# cpu_limit would pass every case above and let an empty mem_limit through into
# `mem_limit:` on the far side.
out=$( cd "$project" && MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.0"}' deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a marker with cpu_limit but no mem_limit is refused (rc $rc: $out)"
assert 'grep -qF "mem_limit" <<<"$out"' "naming the field (said '$out')"
out=$( cd "$project" && MARKER='{"apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.0","mem_limit":"4 g"}' deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "and so is a mem_limit with a space in it (rc $rc: $out)"

# The marker's paths steer the whole run, and the marker is looked for at the
# default path whatever it then says: a server laid out somewhere else is
# followed rather than second-guessed. Every path below is the marker's, and
# none of them is /apps.
out=$( cd "$project" && MARKER='{"apps_path":"/srv/apps","data_path":"/srv/store","cpu_limit":"1.0","mem_limit":"2g"}' deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a marker naming another apps path deploys (rc $rc: $out)"
assert 'grep -qF "|'\''bash'\'' '\''-s'\'' '\''--'\'' '\''/apps'\''" <<<"$calls"' \
    "the marker itself is still read at the default path ($(grep -F "'--' '/apps'" <<<"$calls"))"
assert 'grep -qF "deploy@vps:/srv/apps/demo/compose.yml" <<<"$calls"' \
    "but the project lands under the marker's apps path ($(grep -F "compose.prod.yml" <<<"$calls"))"
assert 'grep -qF "'\''/srv/store'\''" <<<"$calls"' \
    "the bind-mount root is the marker's data path ($(grep -F "prepare" <<<"$calls"))"
assert 'grep -qF "'\''/srv/apps/demo/scripts/setup-env.sh'\'' '\''--drift'\'' '\''/srv/apps/demo'\''" <<<"$calls"' \
    "the env check runs the script that is there and asks about the directory the project is in ($(grep -F -- "--drift" <<<"$calls"))"
assert 'grep -qF "'\''/srv/apps/demo/scripts/setup-env.sh'\'' '\''--inject'\'' '\''/srv/apps/demo'\''" <<<"$calls"' \
    "and injection writes into that same directory's .env, not the default path's ($(grep -F -- "--inject" <<<"$calls"))"
assert 'grep -qF "deploy@vps:/srv/apps/traefik/dynamic/demo.yml" <<<"$calls"' \
    "and the fragment goes to that tree's Traefik ($(grep -F "dynamic/" <<<"$calls"))"
rm -rf "$project/.kasbah"

# The control for all of the above: the same stub, nothing set, deploys.
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' \
    "an in-sync .env deploys with no prompt and no flag (rc $rc: $out) — else the refusals above prove nothing"
assert '! grep -qF "has drifted" <<<"$out"' "and says nothing about drift (said '$out')"
rm -rf "$project/.kasbah"

# The recording rsync stub stays on PATH for the cases below. None of them
# reaches a sync, and each asserts that; the stub is what makes "it never
# reached rsync" a fact about a log rather than about a machine that happens to
# have no rsync.

# Unreachable: the stub fails the probe itself, which is lib/ssh.sh's exit 3.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
echo "ssh: connect to host vps port 22: Connection refused" >&2
exit 255
STUB
chmod 0755 "$stub_dir/ssh"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server exits 3 (rc $rc: $out)"
assert 'grep -qF "cannot reach deploy@vps" <<<"$out"' "saying which host (said '$out')"

# A local failure still costs no connection, even with a reachable-looking host.
rm -f "$project/site/index.html"
rmdir "$project/site"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "1" ]' "a sync path that is gone fails before anything remote (rc $rc: $out)"
assert 'grep -qF "site" <<<"$out"' "naming the entry (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and ssh was never called (ssh saw: $(cat "$ssh_log"))"

# --- state.sh: the fields a deploy writes ---------------------------------------
state_dir="$tmpdir/state"
mkdir -p "$state_dir"
run_state() {
    ( cd "$state_dir" && bash -c '
        set -uo pipefail
        . "$KASBAH_LIB_DIR/state.sh"
        '"$1"'
    ' 2>&1 )
}

out="$(run_state 'state_record last_server deploy@vps last_version 1.2.3; cat .kasbah/state.json')"; rc=$?
assert '[ "$rc" = "0" ]' "state_record creates the file when there is none (rc $rc: $out)"
assert '[ "$(jq -r .last_server <<<"$out")" = "deploy@vps" ]' "recording last_server (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]'     "and last_version"
assert '[ "$(jq -r .kasbah_version <<<"$out")" = "$KASBAH_VERSION" ]' \
    "with the shape init-project would have written"

# Merged, never replaced: a field this command does not own has to survive.
run_state 'jq ".schema_migrations_applied = [\"m1\"] | .future_key = 7" .kasbah/state.json > s && mv s .kasbah/state.json' >/dev/null
out="$(run_state 'state_record last_server other@vps; cat .kasbah/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "other@vps" ]' "a re-record updates the field (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]' "leaves the fields it was not given alone"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[\"m1\"]" ]' "keeps another command's field"
assert '[ "$(jq -r .future_key <<<"$out")" = "7" ]' "and a key it has never heard of"

# A state file that exists but holds nothing gets the shape as well, which is
# what the merge is for: the fields this call did not set have to be present and
# null, not missing.
printf '{}\n' > "$state_dir/.kasbah/state.json"
out="$(run_state 'state_record last_server thin@vps; cat .kasbah/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "thin@vps" ]' "an empty object is filled in (got '$out')"
# `jq -r .last_version` prints "null" for an absent key just as it does for a
# null one, so presence is asserted rather than the rendered value.
assert 'jq -e "has(\"last_version\") and .last_version == null" >/dev/null <<<"$out"' \
    "with the untouched fields present and null rather than missing (got '$out')"
assert '[ "$(jq -r .kasbah_version <<<"$out")" = "$KASBAH_VERSION" ]' "and the kasbah version"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[]" ]' "and the migration list"
run_state 'state_record last_server other@vps last_version 1.2.3' >/dev/null

out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"
assert '[ "$out" = "other@vps" ]' "state_get reads it back (got '$out')"
out="$(run_state 'state_get last_deploy v; printf "[%s]\n" "$v"')"
assert '[ "$out" = "[]" ]' "and a null field reads as empty rather than the string null (got '$out')"

printf 'not json\n' > "$state_dir/.kasbah/state.json"
out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"; rc=$?
assert '[ "$rc" != "0" ]' "an unparseable state file is an error, not an empty default (rc $rc: $out)"
out="$(run_state 'state_record last_server x@y')"; rc=$?
assert '[ "$rc" != "0" ]' "and it is never overwritten (rc $rc: $out)"
assert '[ "$(cat "$state_dir/.kasbah/state.json")" = "not json" ]' "the file is left as it was"

exit "$fail"
