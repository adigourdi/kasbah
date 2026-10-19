#!/usr/bin/env bash
# Test: `kasbah deploy` — the working-tree deploy is internal/deploy on both
# ends; lib/deploy.sh and templates/remote-deploy.sh still serve `rollback` and
# `deploy VERSION`, so their pure parts are tested here too.
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
. "$repo_dir/tests/cli.sh"
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

# A sync list that lands on no compose.yml. The shipped script refuses it too,
# but only on the server — after the rsync and after the .env has been rendered
# there. Which entry maps where is a fact about this checkout, so it costs no
# round trip to find out.
compose_dst() {
    run_snippet '
        MANIFEST_NAME=demo
        _deploy_parse_sync_lines "$(printf '"'"'%b'"'"' "'"$1"'")"
        _deploy_check_compose_dst
        echo ok
    ' 2>&1
}

out="$(compose_dst 'compose.prod.yml -> compose.yml\nsite/\n')"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "ok" ]' \
    "a list that maps a compose file onto compose.yml passes (rc $rc: $out)"
out="$(compose_dst 'compose.yml\n')"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "ok" ]' \
    "and so does a bare compose.yml, which is its own destination (rc $rc: $out)"

out="$(compose_dst 'compose.prod.yml\n.env.prod.example\n')"; rc=$?
assert '[ "$rc" != "0" ]' \
    "a list with no compose.yml destination is refused here, not on the server (rc $rc: $out)"
assert 'grep -qF "no sync: entry lands on compose.yml" <<<"$out"' \
    "naming what is missing (said '$out')"
assert 'grep -qF "compose.prod.yml -> compose.yml" <<<"$out"' \
    "and the line that fixes it (said '$out')"

# The call site, not only the function. This suite drives functions, so a check
# wired to nothing passes every case above (docs/phases/04-ship.md → a function
# can be exhaustively tested and called by nothing) — and the whole point of
# moving this one off the server is where it runs, which is a fact about
# cmd_deploy's order rather than about the function.
cmd_body="$(sed -n '/^cmd_deploy()/,/^}/p' "$repo_dir/lib/deploy.sh")"
n_composechk="$(grep -n -m1 -F '_deploy_check_compose_dst' <<<"$cmd_body" | cut -d: -f1)"
n_sshconn="$(grep -n -m1 -F 'ssh_connect' <<<"$cmd_body" | cut -d: -f1)"
assert '[ -n "$n_composechk" ]' \
    "cmd_deploy calls _deploy_check_compose_dst — a refusal nothing reaches is not a refusal"
assert '[ -n "$n_sshconn" ] && [ "$n_composechk" -lt "$n_sshconn" ]' \
    "and calls it before ssh_connect, which is the difference between this check and the
        shipped script's own (check on line ${n_composechk:-none}, ssh_connect on ${n_sshconn:-none})"

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
# The two streams apart, because the report on stdout is what a caller reads as
# "the run reached its end": it is printed after the versions.log entry, so a
# refusal that never wrote one must leave stdout empty.
out=$(env PATH="$stub_dir:$PATH" KASBAH_VERSION='1.0 beta' DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj7/scripts/remote-deploy.sh" deploy 1.0.0 2>"$tmpdir/spacey.err"); rc=$?
spacey_err="$(cat "$tmpdir/spacey.err")"
assert '[ "$rc" != "0" ]' "a KASBAH_VERSION with a space is refused (rc $rc: $spacey_err)"
assert 'grep -qF "kasbah version" <<<"$spacey_err"' "naming the field (said '$spacey_err')"
assert '[ ! -f "$proj7/versions.log" ]' "and nothing was appended"
assert '[ -z "$out" ]' \
    "and no report was printed for a deploy that never finished (stdout: '$out')"

# The control for both: the same script with both values sane writes its line,
# so the two refusals above are about the values and not about the stubs.
proj8="$(new_project sane)"
env PATH="$stub_dir:$PATH" KASBAH_VERSION='1.0-beta' DOCKER_LOG="$DOCKER_LOG" \
    bash "$proj8/scripts/remote-deploy.sh" deploy 1.0.0 >/dev/null 2>&1
assert 'grep -qF "kasbah=1.0-beta" "$proj8/versions.log"' \
    "a hyphenated version writes normally (got '$(cat "$proj8/versions.log" 2>/dev/null)')"

# The rollback mode writes the same frozen line with a different action in
# field 2 — and never a backup path, because docs/build-deploy.md's rollback
# flow has no backup step at all.
out=$(env PATH="$stub_dir:$PATH" KASBAH_VERSION=9.9.9 DOCKER_LOG="$DOCKER_LOG" \
        bash "$proj/scripts/remote-deploy.sh" rollback 1.2.3 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "remote-deploy.sh rollback succeeds against a stub docker (rc $rc: $out)"
read -r _ rb_action rb_version rb_backup _ <<<"$(tail -1 "$proj/versions.log")"
assert '[ "$rb_action" = "rollback" ]' "field 2 of its entry is rollback (got '$rb_action')"
assert '[ "$rb_version" = "1.2.3" ]'   "field 3 is the target version (got '$rb_version')"
assert '[ "$rb_backup" = "no-backup" ]' \
    "and field 4 is always no-backup (got '$rb_backup')"

out=$(env PATH="$stub_dir:$PATH" bash "$proj/scripts/remote-deploy.sh" deploy '1.0.0 oops' 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "a version with whitespace is refused — versions.log is space-delimited (rc $rc)"
out=$(env PATH="$stub_dir:$PATH" bash "$proj/scripts/remote-deploy.sh" deploy 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "deploy with no version is refused (rc $rc)"
assert 'grep -qF "needs a version" <<<"$out"' "saying what is missing (said '$out')"

# --- The working-tree deploy, end to end against a scratch server ----------------
# `kasbah deploy` with no VERSION is the Go binary on both ends
# (internal/deploy). The stubs play the server the way tests/build_push_test.sh
# does: ssh runs the remote command here, against a scratch apps tree whose
# kasbah binary is a copy of the one under test, so `kasbah remote deploy` runs
# for real; rsync is the real one with the host stripped off; docker is a stub
# that keeps its images and containers in two files. Every ssh and rsync call
# lands in one ordered log, because the order is what most of this is about.
srv="$tmpdir/srv"
FAKE_APPS="$srv/apps"
FAKE_DATA="$srv/data"
ssh_log="$tmpdir/ssh.log"
call_log="$tmpdir/calls.log"
docker_log="$tmpdir/docker-cli.log"
images="$tmpdir/images"
containers="$tmpdir/containers"
run_tmp="$tmpdir/runtmp"
seeds="$tmpdir/seeds"
mkdir -p "$seeds"
REAL_RSYNC="$(command -v rsync)"
mkdir -p "$FAKE_APPS/.kasbah/bin" "$FAKE_APPS/traefik/dynamic" "$FAKE_DATA" "$run_tmp" "$tmpdir/home"
cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"
write_marker() {
    printf '{"kasbah_version":"%s","apps_path":"%s","data_path":"%s","cpu_limit":"1.5","mem_limit":"512m"}\n' \
        "$KASBAH_VERSION" "$FAKE_APPS" "$FAKE_DATA" > "$FAKE_APPS/.kasbah/server.json"
}
write_marker

cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
[ "${SSH_RC:-0}" = 0 ] || { echo "ssh: connect to host vps port 22: Connection refused" >&2; exit "$SSH_RC"; }
last="${!#}"
[ "$last" = true ] && exit 0
eval "set -- $last"
printf 'ssh|%s\n' "$*" >> "$CALL_LOG"
if [ "$1 $2" = "sh -s" ]; then
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7"
fi
case "$*" in
    *"remote deploy run"*) [ -z "${SSH_NO_REPORT:-}" ] || { cat >/dev/null; exit 0; } ;;
esac
exec "$@"
STUB
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
printf 'rsync|%s\n' "$*" >> "$CALL_LOG"
if [ -n "${RSYNC_FAIL_ON:-}" ]; then case "$*" in *"$RSYNC_FAIL_ON"*) exit 23 ;; esac; fi
args=(); skip=0
for a; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in -e) skip=1; continue ;; *@*:*) a="${a#*:}" ;; esac
    args+=("$a")
done
exec "$REAL_RSYNC" "${args[@]}"
STUB
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
last="${!#}"
case "$1" in
    image)
        grep -qxF "$last" "$IMAGES" 2>/dev/null || exit 1
        [ "${3:-}" != -f ] || printf 'sha256:%s\n' "$(printf %s "$last" | sha256sum | cut -c1-64)"
        exit 0 ;;
    tag) printf '%s\n' "$3" >> "$IMAGES"; exit 0 ;;
    inspect)
        st=$(sed -n "s/^$last=//p" "$CONTAINERS" 2>/dev/null)
        [ -n "$st" ] || exit 1
        case "$3" in
            *Running*) [ "$st" = running ] && echo true || echo false ;;
            *Health*) echo "${HEALTH:-none}" ;;
            *Status*) echo "$st" ;;
            *Name*) echo "/$last" ;;
        esac
        exit 0 ;;
    compose)
        case "$*" in *" up "*) exit "${UP_RC:-0}" ;; *" ps "*) exit 0 ;; esac ;;
    exec) exit "${EXEC_RC:-0}" ;;
    # The SnappyMail seed: the container's file tree is $SEEDS, flat.
    cp)
        case "$2" in *:*) [ -f "$SEEDS/${2##*/}" ] && cp "$SEEDS/${2##*/}" "$3"; exit $? ;; esac
        [ -z "${CP_FAIL:-}" ] || exit 1
        cp "$2" "$SEEDS/${3##*/}"; exit $? ;;
esac
exit 0
STUB
chmod 0755 "$stub_dir/ssh" "$stub_dir/rsync" "$stub_dir/docker"
: > "$images"; : > "$containers"

project="$tmpdir/project"
rm -rf "$project"
cp -R "$repo_dir/tests/fixtures/demo" "$project"
# Two tagged commits, because the changelog is a *range*; and a third, tagged
# and left behind, so HEAD keeps exactly one v-tag.
(
    cd "$project" || exit 1
    git init -q .
    git config user.email kasbah-test@example.invalid
    git config user.name  "kasbah test"
    git config commit.gpgsign false
    git add -A
    git commit -qm "the commit before the one being deployed"
    git tag v0.9.0
    git commit -q --allow-empty -m "the commit this deploy ships"
    git tag v1.0.0
    git commit -q --allow-empty -m "a commit this deploy does not ship"
    git tag v1.1.0
    git reset -q --hard v1.0.0
) >/dev/null 2>&1
pdir="$FAKE_APPS/demo"

deploy_cli() {
    : > "$ssh_log"; : > "$call_log"; : > "$docker_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$run_tmp" \
        SSH_LOG="$ssh_log" CALL_LOG="$call_log" DOCKER_LOG="$docker_log" \
        FAKE_APPS="$FAKE_APPS" REAL_RSYNC="$REAL_RSYNC" IMAGES="$images" CONTAINERS="$containers" SEEDS="$seeds" \
        "$KASBAH_BIN" deploy "$@" </dev/null 2>&1
}
# The line number of the first call matching a pattern, 0 when there is none.
call_at() { local n; n=$(grep -nF -- "$1" "$call_log" | head -1 | cut -d: -f1); printf '%s' "${n:-0}"; }

out=$( cd "$tmpdir" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "2" ]' "deploy outside a project exits 2 (rc $rc: $out)"
assert 'grep -qF "No kasbah.yml" <<<"$out"' "naming the file it wanted (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ]' "no target and no state is a plain failure (rc $rc: $out)"
assert 'grep -qF "last_server" <<<"$out"' "naming the field that would have answered (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

for bad in --skip-hooks=yes --on-drift --on-drift=maybe --frobnicate; do
    out=$( cd "$project" && deploy_cli deploy@vps "$bad" ); rc=$?
    assert '[ "$rc" = "1" ] && [ ! -s "$ssh_log" ]' "$bad is refused before any connection (rc $rc: $out)"
done
out=$( cd "$project" && deploy_cli a@vps b@vps ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "two servers" <<<"$out"' "two servers are refused (rc $rc: $out)"

out=$( cd "$project" && deploy_cli --help ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF -- "--allow-stopped" <<<"$out"' "\`kasbah deploy --help\` exits 0 and documents the flags (rc $rc)"
# A VERSION is the tagged path, still the Bash tool's — and its argument rules.
out=$( cd "$project" && deploy_cli deploy@vps v1.0.0 ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "without the '"'"'v'"'"'" <<<"$out"' \
    "a VERSION argument reaches the tagged path's own checks (rc $rc: $out)"

out=$( cd "$project" && SSH_RC=255 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server exits 3 (rc $rc: $out)"
assert 'grep -qF "cannot reach deploy@vps" <<<"$out"' "saying which host (said '$out')"

rm -f "$FAKE_APPS/.kasbah/server.json"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "4" ]' "a server with no marker exits 4 (rc $rc: $out)"
assert 'grep -qF "$FAKE_APPS/.kasbah/server.json" <<<"$out"' "naming the file it looked for (said '$out')"
assert '[ ! -e "$pdir" ]' "and nothing was created on the server"
write_marker

# --- No .env, and no terminal to render one on: exit 5 ---------------------------
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "5" ]' "a deploy with no .env and no terminal exits 5 (rc $rc: $out)"
assert 'grep -qF "$pdir/.env" <<<"$out"' "naming the file (said '$out')"
assert '[ -f "$pdir/.env.prod.example" ] && [ -f "$pdir/compose.yml" ]' \
    "after the project rsync, which put the template there for the setup"
assert '[ ! -e "$FAKE_APPS/traefik/dynamic/demo.yml" ]' "and no Traefik fragment was shipped"
assert '[ ! -e "$pdir/versions.log" ]' "nor anything deployed"
assert '[ ! -e "$project/.kasbah/state.json" ]' "and no project state written"
assert '[ ! -e "$pdir/scripts" ]' "no scripts/ directory: nothing is shipped into one any more"

# The operator renders it, as on a server.
printf 'DEMO_GREETING=hello\n' > "$pdir/.env"

# --- A deploy that goes through ---------------------------------------------------
# Dated this month, or rotation would move it into the archive.
printf '%s deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n' "$(date -u +%Y-%m-%dT00:00:00+00:00)" > "$pdir/versions.log"
rm -f "$pdir/.kasbah-client"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a prepared server deploys (rc $rc: $out)"
assert 'grep -qF "Deployed demo 1.0.0 to deploy@vps" <<<"$out"' "and says so (said '$out')"
prep=$(call_at "remote deploy prepare"); sync=$(call_at "rsync|-e"); drift=$(call_at "setup-env drift")
inject=$(call_at "setup-env inject"); runat=$(call_at "remote deploy run"); frag=$(call_at "traefik/dynamic/demo.yml")
assert '[ "$prep" -gt 0 ] && [ "$prep" -lt "$sync" ] && [ "$sync" -lt "$drift" ] && [ "$drift" -lt "$inject" ] && [ "$inject" -lt "$runat" ] && [ "$runat" -lt "$frag" ]' \
    "prepare, sync, drift, inject, the engine and then the fragment — in that order
        (prepare $prep, sync $sync, drift $drift, inject $inject, run $runat, fragment $frag)"
assert '! grep -q "remote deploy run" <<<"$(grep -F "timeout" "$call_log")"' \
    "the engine is not under the 30 s bound every other server call has"
assert 'grep -qF "setup-env inject $pdir KASBAH_CPU_LIMIT=1.5 KASBAH_MEM_LIMIT=512m" "$call_log"' \
    "injection carries the marker's two limits, unreformatted"
assert '[ "$(stat -c %a "$FAKE_APPS/traefik/dynamic/demo.yml" 2>/dev/null)" = "644" ]' "the fragment landed 644 under the project's name"
assert 'grep -qF -- "--chmod=F644" <<<"$(grep -F "traefik/dynamic/demo.yml" "$call_log")"' "stated, not inherited"
assert '[ -f "$pdir/site/index.html" ] && [ ! -e "$pdir/compose.prod.yml" ] && [ ! -e "$pdir/kasbah.yml" ]' \
    "the sync list renamed, recursed, and shipped nothing it does not name"
assert '[ "$(cat "$pdir/.kasbah-client" 2>/dev/null)" = "demo" ] && [ "$(stat -c %a "$pdir/.kasbah-client")" = "644" ]' \
    "the effective client is recorded, 644, defaulting to the project name"
assert 'grep -qF "client:  demo (written" <<<"$out"' "and the banner says it was written (said '$out')"
assert '[ -d "$pdir/backups" ] && [ -d "$FAKE_DATA/demo" ]' "backups/ and the data directory exist"
assert 'grep -qF "compose -p demo up -d --remove-orphans" "$docker_log"' "compose up ran under -p (docker saw: $(cat "$docker_log"))"
last_line=$(tail -1 "$pdir/versions.log")
assert '[[ "$last_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00\ deploy\ 1\.0\.0\ no-backup\ kasbah=$KASBAH_VERSION\ digest=-$ ]]' \
    "one frozen versions.log line, with kasbah= and digest= for a stock-only project (got '$last_line')"
assert '[ "$(wc -l < "$pdir/versions.log")" = "2" ]' "appended, never rewritten"
assert 'grep -qF "changes: v0.9.0..v1.0.0" <<<"$out" && grep -qF "the commit this deploy ships" <<<"$out"' \
    "the changelog is the range the server's own record defines (said '$out')"
assert '! grep -qF "the commit before the one being deployed" <<<"$out"' \
    "and not v0.9.0's own commit, which the range starts after (said '$out')"
assert '[ "$(jq -r .last_server "$project/.kasbah/state.json")" = "deploy@vps" ] && [ "$(jq -r .last_version "$project/.kasbah/state.json")" = "1.0.0" ]' \
    "a deploy that worked records the server and the version"
assert '[ -z "$(ls -A "$run_tmp")" ]' "and leaves nothing in TMPDIR ($(ls -A "$run_tmp"))"
assert '[ "$(grep -c "KASBAH_CPU_LIMIT=1.5" "$pdir/.env")" = "1" ]' "the managed block is in .env"

# A redeploy, by last_server: the range is empty, and the client is unchanged.
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ]' "a redeploy with no target uses last_server (rc $rc: $out)"
assert 'grep -qF "changes: none — v1.0.0..v1.0.0 is empty" <<<"$out"' "and calls itself a redeploy (said '$out')"
assert 'grep -qF "client:  demo (unchanged" <<<"$out"' "the client record is left alone (said '$out')"

# The three flags reach the engine.
out=$( cd "$project" && deploy_cli --skip-hooks --no-health-wait deploy@vps --allow-stopped ); rc=$?
assert '[ "$rc" = "0" ]' "all three flags together, in any order, deploy (rc $rc: $out)"
assert 'grep -qF "pre-deploy hooks skipped (--skip-hooks)" <<<"$out" && grep -qF "health wait skipped (--no-health-wait)" <<<"$out"' \
    "and the server acts on them (said '$out')"

# --allow-stopped, end to end: a pre-deploy hook whose container is down, on a
# project with history, is refused — and the flag lets it through, skipping it.
printf "hooks:\n  pre-deploy:\n    - 'demo-web echo pre'\n" >> "$project/kasbah.yml"
printf 'demo-web=exited\n' > "$containers"
log_before=$(cat "$pdir/versions.log")
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "demo-web is exited" <<<"$out" && grep -qF -- "--allow-stopped" <<<"$out"' \
    "a down hook container on a project with history is refused, naming the flag (rc $rc: $out)"
assert '[ "$(cat "$pdir/versions.log")" = "$log_before" ]' "before anything is written"
out=$( cd "$project" && deploy_cli --allow-stopped ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF -- "--allow-stopped: demo-web is exited" <<<"$out"' \
    "--allow-stopped deploys over it, saying so (rc $rc: $out)"
assert 'grep -qF "pre-deploy hook skipped: no demo-web is running" <<<"$out" && ! grep -q "^exec" "$docker_log"' \
    "and the hook it could not run was skipped, not run (docker saw: $(cat "$docker_log"))"
git -C "$project" checkout -q kasbah.yml
: > "$containers"

# A last line no version can be read out of: history, but no range.
printf '2026-10-01T00:00:00+00:00 dep' >> "$pdir/versions.log"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ]' "a server whose last line is truncated still deploys (rc $rc: $out)"
assert 'grep -qF "is not one a version can be read out of" <<<"$out"' "and says that rather than 'first deploy' (said '$out')"
assert 'grep -qF "had no newline on it" <<<"$out"' "the truncated line was terminated, not written into"
assert '[ "$(tail -2 "$pdir/versions.log" | head -1)" = "2026-10-01T00:00:00+00:00 dep" ]' "and left exactly as it stood"

# A first deploy.
rm -f "$pdir/versions.log"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "changes: first deploy to deploy@vps" <<<"$out"' "a first deploy says so (rc $rc: $out)"

# --- What stops before the fragment ----------------------------------------------
rm -f "$FAKE_APPS/traefik/dynamic/demo.yml"
out=$( cd "$project" && UP_RC=1 deploy_cli ); rc=$?
assert '[ "$rc" = "1" ]' "a compose up that fails fails the deploy (rc $rc: $out)"
assert 'grep -qF "may already carry :current" <<<"$out" && grep -qF "kasbah rollback deploy@vps" <<<"$out"' \
    "saying the retag may have moved and what puts it back (said '$out')"
assert '[ ! -e "$FAKE_APPS/traefik/dynamic/demo.yml" ]' "and the fragment never shipped"

out=$( cd "$project" && SSH_NO_REPORT=1 deploy_cli ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "reported no report" <<<"$out"' "an engine that exits 0 with no report is a failed deploy (rc $rc: $out)"
assert 'grep -qF "the Traefik fragment" <<<"$out" && [ ! -e "$FAKE_APPS/traefik/dynamic/demo.yml" ]' \
    "refused before the fragment, and saying so (said '$out')"

out=$( cd "$project" && RSYNC_FAIL_ON=traefik/dynamic deploy_cli ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "the deploy itself succeeded" <<<"$out"' \
    "a fragment that cannot ship is named as the only thing missing (rc $rc: $out)"

# The lock: a second deploy while one holds it fails fast, naming the file.
exec 9>"$pdir/.deploy.lock"
flock -n 9
out=$( cd "$project" && deploy_cli ); rc=$?
exec 9>&-
assert '[ "$rc" = "1" ] && grep -qF "already running" <<<"$out" && grep -qF "$pdir/.deploy.lock" <<<"$out"' \
    "a held .deploy.lock refuses the run (rc $rc: $out)"

# The image preflight: an image build-push never shipped stops the run first.
cp "$project/compose.prod.yml" "$tmpdir/compose.keep"
sed -i 's|^services:$|&\n  app:\n    build: .\n    image: demo-app:current|' "$project/compose.prod.yml"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "not on this server: demo-app:1.0.0" <<<"$out"' \
    "a built image that is not on the server is refused before anything changes (rc $rc: $out)"
printf 'demo-app:1.0.0\n' >> "$images"
out=$( cd "$project" && deploy_cli ); rc=$?
id=$(printf %s demo-app:current | sha256sum | cut -c1-64)
assert '[ "$rc" = "0" ] && [[ "$(tail -1 "$pdir/versions.log")" == *" digest=sha256:$id" ]]' \
    "once it is, :current is retagged and its id is digest= (rc $rc: $(tail -1 "$pdir/versions.log"))"
assert 'grep -qxF "tag demo-app:1.0.0 demo-app:current" "$docker_log"' "the retag is exactly build-push's tag"
cp "$tmpdir/compose.keep" "$project/compose.prod.yml"

# --- The mail claim -----------------------------------------------------------------
printf 'mail:\n  domain: demo.test\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "there is no mail stack at $FAKE_APPS/mail" <<<"$out"' \
    "a claim on a server with no mail stack warns and deploys (rc $rc: $out)"
mkdir -p "$FAKE_APPS/mail"; : > "$FAKE_APPS/mail/.env"
printf 'mail-dms=running\nmail-snappymail=running\n' >> "$containers"
printf 'name: mail\nprimary_domain: demo.test\ndomains:\n  - other.test\n' > "$FAKE_APPS/mail/kasbah.yml"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "demo.test is served by the stack" <<<"$out"' \
    "the primary is served whether or not domains: lists it (rc $rc: $out)"
# The SnappyMail pre-seed: copied only on a met claim, and only when absent.
printf '{"domain":"demo.test"}\n' > "$project/seed.json"
printf '  snappymail_domain: seed.json\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "seeded SnappyMail'"'"'s demo.test.json from seed.json" <<<"$out"' \
    "a met claim seeds SnappyMail (rc $rc: $out)"
assert 'cmp -s "$project/seed.json" "$seeds/demo.test.json"' "with the checkout's bytes"
printf 'operator edit\n' > "$seeds/demo.test.json"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "left as it is" <<<"$out" && [ "$(cat "$seeds/demo.test.json")" = "operator edit" ]' \
    "an existing config is left as it is (rc $rc: $out)"
rm -f "$seeds/demo.test.json"
out=$( cd "$project" && CP_FAIL=1 deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "could not seed SnappyMail'"'"'s config for demo.test" <<<"$out"' \
    "a seed that fails is a warning, and the deploy goes on (rc $rc: $out)"
printf 'name: mail\nprimary_domain: other.test\n' > "$FAKE_APPS/mail/kasbah.yml"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "0" ] && grep -qF "lists: other.test" <<<"$out"' "an unmet claim warns, listing what is served (rc $rc: $out)"
assert 'grep -qF "it was NOT copied" <<<"$out" && ! grep -q "^cp " "$docker_log" && [ ! -e "$seeds/demo.test.json" ]' \
    "and the seed step never runs (docker saw: $(cat "$docker_log"))"
printf 'name: mail\ndomains:\n  - demo.test\n' > "$FAKE_APPS/mail/kasbah.yml"
before_log=$(cat "$pdir/versions.log")
: > "$call_log"
out=$( cd "$project" && deploy_cli ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "$FAKE_APPS/mail/kasbah.yml on deploy@vps has no primary_domain:" <<<"$out"' \
    "a registry with no primary_domain is refused, naming file and key (rc $rc: $out)"
assert '[ "$(call_at "remote deploy prepare")" = 0 ] && [ "$(cat "$pdir/versions.log")" = "$before_log" ]' \
    "before anything is written"
rm -rf "$FAKE_APPS/mail"
rm -f "$project/seed.json"
git -C "$project" checkout -q kasbah.yml

# --- A local failure still costs no connection --------------------------------------
rm -rf "$project/site"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "site" <<<"$out"' "a sync path that is gone fails first (rc $rc: $out)"
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
