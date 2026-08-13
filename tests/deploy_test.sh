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
export HOSTING_LIB_DIR="$repo_dir/lib"
export HOSTING_TEMPLATE_DIR="$repo_dir/templates"
export HOSTING_VERSION="$(cat "$repo_dir/VERSION")"

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
        . "$HOSTING_LIB_DIR/deploy.sh"
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
out=$(env PATH="$stub_dir:$PATH" HOSTING_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
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
read -r ts action version backup hosting digest extra <<<"$log_line"
assert '[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' \
    "field 1 is a UTC ISO-8601 timestamp (got '$ts')"
assert '[ "$action" = "deploy" ]'      "field 2 is the action (got '$action')"
assert '[ "$version" = "1.2.3" ]'      "field 3 is the version (got '$version')"
assert '[ "$backup" = "no-backup" ]'   "field 4 is the backup path or no-backup (got '$backup')"
assert '[ "$hosting" = "hosting=9.9.9" ]' \
    "then hosting=<version>, from the environment hosting passed (got '$hosting')"
assert '[ "$digest" = "digest=-" ]'    "and digest=- for a stock-only project (got '$digest')"
assert '[ -z "$extra" ]'               "with nothing after it yet (got '$extra')"

# A second deploy appends; it never rewrites.
env PATH="$stub_dir:$PATH" HOSTING_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj/scripts/remote-deploy.sh" deploy 1.2.4 >/dev/null 2>&1
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "a second deploy appends rather than replacing ($(wc -l < "$proj/versions.log") lines)"
assert '[ "$(head -1 "$proj/versions.log")" = "$log_line" ]' \
    "and the first line is untouched"
assert 'grep -qF " deploy 1.2.4 " "$proj/versions.log"' "the second version is in the log"

# hosting= is honest when nobody said which hosting is driving.
proj2="$(new_project bare)"
env -u HOSTING_VERSION PATH="$stub_dir:$PATH" DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj2/scripts/remote-deploy.sh" deploy 2.0.0 >/dev/null 2>&1
assert 'grep -qF "hosting=unknown" "$proj2/versions.log"' \
    "a hand-run with no HOSTING_VERSION logs hosting=unknown rather than a guess (got '$(cat "$proj2/versions.log")')"

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
out=$(env PATH="$date_stub:$PATH" HOSTING_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj6/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a date that fails is a hard failure, not a line starting with a space (rc $rc: $out)"
assert 'grep -qF "timestamp is empty" <<<"$out"' "naming the field (said '$out')"
assert '[ ! -f "$proj6/versions.log" ]' "and nothing was appended"

proj7="$(new_project spacey)"
out=$(env PATH="$stub_dir:$PATH" HOSTING_VERSION='1.0 beta' DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj7/scripts/remote-deploy.sh" deploy 1.0.0 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a HOSTING_VERSION with a space is refused (rc $rc: $out)"
assert 'grep -qF "hosting version" <<<"$out"' "naming the field (said '$out')"
assert '[ ! -f "$proj7/versions.log" ]' "and nothing was appended"

# The control for both: the same script with both values sane writes its line,
# so the two refusals above are about the values and not about the stubs.
proj8="$(new_project sane)"
env PATH="$stub_dir:$PATH" HOSTING_VERSION='1.0-beta' DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj8/scripts/remote-deploy.sh" deploy 1.0.0 >/dev/null 2>&1
assert 'grep -qF "hosting=1.0-beta" "$proj8/versions.log"' \
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
    git config user.email hosting-test@example.invalid
    git config user.name  "hosting test"
    git add -A
    git commit -qm "fixture"
    git tag v1.0.0
) >/dev/null 2>&1

# `hosting`, as installed, with the stub first on PATH and a HOME of its own so
# the ssh control socket has somewhere harmless to live.
deploy_cli() {
    : > "$ssh_log"
    # The suite exports HOSTING_LIB_DIR for its own snippets; the CLI has to
    # resolve its own, the way an installed hosting does.
    env -u HOSTING_LIB_DIR -u HOSTING_TEMPLATE_DIR -u HOSTING_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        "$repo_dir/bin/hosting" deploy "$@" 2>&1
}
mkdir -p "$tmpdir/home"

out=$( cd "$tmpdir" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "2" ]' "deploy outside a project exits 2 (rc $rc: $out)"
assert 'grep -qF "No hosting.yml" <<<"$out"' "naming the file it wanted (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ]' "no target and no state is a plain failure (rc $rc: $out)"
assert 'grep -qF "last_server" <<<"$out"' "naming the field that would have answered (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "4" ]' "a server with no marker exits 4 (rc $rc: $out)"
assert 'grep -qF "/apps/.hosting/server.json" <<<"$out"' \
    "naming the file it looked for (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and naming the flag that makes a prepared server look unprepared (said '$out')"
# The message must not be followable into a disaster. A bare
# `hosting server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack there and brings it up as compose project
# `traefik` — the frozen name the live one already carries — so compose
# recreates the running proxy against the new file and every site goes dark.
assert '! grep -qE "hosting server init [A-Za-z0-9._-]+@" <<<"$out"' \
    "and never prints a runnable bare \`server init\` as the remedy (said '$out')"
assert '[ ! -f "$project/.hosting/state.json" ]' \
    "a failed deploy writes no state — last_server is only for servers that worked"

out=$( cd "$project" && SSH_STEP_RC=0 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "an empty marker is not accepted as one (rc $rc: $out)"
assert 'grep -qF "not a JSON object" <<<"$out"' "and says what it read (said '$out')"

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
        . "$HOSTING_LIB_DIR/state.sh"
        '"$1"'
    ' 2>&1 )
}

out="$(run_state 'state_record last_server deploy@vps last_version 1.2.3; cat .hosting/state.json')"; rc=$?
assert '[ "$rc" = "0" ]' "state_record creates the file when there is none (rc $rc: $out)"
assert '[ "$(jq -r .last_server <<<"$out")" = "deploy@vps" ]' "recording last_server (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]'     "and last_version"
assert '[ "$(jq -r .hosting_version <<<"$out")" = "$HOSTING_VERSION" ]' \
    "with the shape init-project would have written"

# Merged, never replaced: a field this command does not own has to survive.
run_state 'jq ".schema_migrations_applied = [\"m1\"] | .future_key = 7" .hosting/state.json > s && mv s .hosting/state.json' >/dev/null
out="$(run_state 'state_record last_server other@vps; cat .hosting/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "other@vps" ]' "a re-record updates the field (got '$out')"
assert '[ "$(jq -r .last_version <<<"$out")" = "1.2.3" ]' "leaves the fields it was not given alone"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[\"m1\"]" ]' "keeps another command's field"
assert '[ "$(jq -r .future_key <<<"$out")" = "7" ]' "and a key it has never heard of"

# A state file that exists but holds nothing gets the shape as well, which is
# what the merge is for: the fields this call did not set have to be present and
# null, not missing.
printf '{}\n' > "$state_dir/.hosting/state.json"
out="$(run_state 'state_record last_server thin@vps; cat .hosting/state.json')"
assert '[ "$(jq -r .last_server <<<"$out")" = "thin@vps" ]' "an empty object is filled in (got '$out')"
# `jq -r .last_version` prints "null" for an absent key just as it does for a
# null one, so presence is asserted rather than the rendered value.
assert 'jq -e "has(\"last_version\") and .last_version == null" >/dev/null <<<"$out"' \
    "with the untouched fields present and null rather than missing (got '$out')"
assert '[ "$(jq -r .hosting_version <<<"$out")" = "$HOSTING_VERSION" ]' "and the hosting version"
assert '[ "$(jq -c .schema_migrations_applied <<<"$out")" = "[]" ]' "and the migration list"
run_state 'state_record last_server other@vps last_version 1.2.3' >/dev/null

out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"
assert '[ "$out" = "other@vps" ]' "state_get reads it back (got '$out')"
out="$(run_state 'state_get last_deploy v; printf "[%s]\n" "$v"')"
assert '[ "$out" = "[]" ]' "and a null field reads as empty rather than the string null (got '$out')"

printf 'not json\n' > "$state_dir/.hosting/state.json"
out="$(run_state 'state_get last_server v; printf "%s\n" "$v"')"; rc=$?
assert '[ "$rc" != "0" ]' "an unparseable state file is an error, not an empty default (rc $rc: $out)"
out="$(run_state 'state_record last_server x@y')"; rc=$?
assert '[ "$rc" != "0" ]' "and it is never overwritten (rc $rc: $out)"
assert '[ "$(cat "$state_dir/.hosting/state.json")" = "not json" ]' "the file is left as it was"

exit "$fail"
