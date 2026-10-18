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
helper_copy="$tmpdir/shipped-remote-deploy.sh"
run_tmp="$tmpdir/runtmp"
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
# The marker read reports where it looked before it reports anything else, and
# it does so whether or not it found a marker — so the two header lines come
# first here too, or every case below fails as a truncated step rather than as
# the state it means to be.
case "$last" in
    *"'/etc/kasbah/apps-path'") printf 'apps=/apps\nsource=default\n' ;;
esac
exit "${SSH_STEP_RC:-3}"
STUB
chmod 0755 "$stub_dir/ssh"

project="$tmpdir/project"
rm -rf "$project"
cp -R "$repo_dir/tests/fixtures/demo" "$project"
# Two tagged commits, because the changelog is a *range*: with one commit and
# one tag, `git log v<prev>..v<new>` is empty whatever the code computes, and
# every mutant of the range survives.
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
    # One more, tagged and then left behind: v1.1.0 exists in this checkout and
    # HEAD is not on it, which is the shape a *downgrade* needs — a server
    # running something this deploy is not ahead of. HEAD keeps exactly one
    # v-tag, which is what `kasbah deploy` requires of it.
    git commit -q --allow-empty -m "a commit this deploy does not ship"
    git tag v1.1.0
    git reset -q --hard v1.0.0
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
    # A TMPDIR of the suite's own. Both things a deploy puts there — lib/ssh.sh's
    # control-socket directory and the rendered remote-deploy.sh — are removed by
    # EXIT traps that have to *chain*, and a directory nothing else writes to is
    # what makes "it left nothing behind" a question with one answer.
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$run_tmp" \
        SSH_LOG="$ssh_log" CALL_LOG="$call_log" \
        RSYNC_HELPER_COPY="$helper_copy" \
        "$KASBAH_BIN" deploy "$@" </dev/null 2>&1
}
# The same run with the two streams kept apart. kasbah puts every line it prints
# on stderr (lib/common.sh), and the changelog's commit lines are the newest
# thing that could have drifted off it — deploy_cli merges 2>&1, so nothing else
# in this suite can tell.
split_err="$tmpdir/split.err"
deploy_cli_split() {
    : > "$ssh_log"; : > "$call_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$run_tmp" \
        SSH_LOG="$ssh_log" CALL_LOG="$call_log" \
        RSYNC_HELPER_COPY="$helper_copy" \
        "$KASBAH_BIN" deploy "$@" </dev/null 2>"$split_err"
}
mkdir -p "$tmpdir/home" "$run_tmp"

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
    # The marker read: the pointer path is its second argument, and the two
    # header lines are the discovery protocol — where it looked, and how it got
    # there. $POINTER puts the far side into the pointer state.
    "'bash' '-s' '--' '/apps' '/etc/kasbah/apps-path'")
        marker_default='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}'
        if [ -n "${POINTER:-}" ]; then
            printf 'apps=%s\nsource=pointer\n' "$POINTER"
        else
            printf 'apps=/apps\nsource=default\n'
        fi
        printf '%s\n' "${MARKER-$marker_default}" ;;
    # The marker read is matched exactly above, so anything else naming the
    # project is the prepare step — whatever apps path the marker steered it to.
    "'bash' '-s' '--' "*" 'demo'"*)
        [ -z "${PREPARE_OUT+set}" ] || { printf '%s' "$PREPARE_OUT"; exit 0; }
        # Two keys, because the prepare step also renders the effective
        # `client:` onto the server — the manifest never gets there, and the
        # backup runner that reads it runs there (docs/phases/08-keep.md D12).
        printf 'prepared=yes\nclient=%s\n' "${PREPARE_CLIENT:-written}" ;;
    *"setup-env.sh' '--drift' "*)
        [ -z "${DRIFT_OUT+set}" ] || { printf '%s' "$DRIFT_OUT"; exit "${DRIFT_RC:-0}"; }
        [ -z "${DRIFT_RC:-}" ] || exit "$DRIFT_RC"
        printf 'template_exists=%s\n' "${ENV_TEMPLATE:-yes}"
        printf 'env_exists=%s\n' "${ENV_EXISTS:-yes}"
        printf 'missing=%s\n' "${ENV_MISSING:-}"
        printf 'extra=%s\n' "${ENV_EXTRA:-}" ;;
    *"setup-env.sh' '--inject' "*) exit "${INJECT_RC:-0}" ;;
    # The SnappyMail seed, which is its own round trip and names the container
    # rather than a path under <apps>. Matched before the claim step below,
    # which is the looser pattern of the two.
    "'bash' '-s' '--' 'mail-snappymail' "*)
        printf 'mail_seed=%s\n' "${MAIL_SEED:-copied}" ;;
    # The mail claim's step, which names <apps>/mail first, the data path and
    # the claimed domain. Its status and its whole output are settable: an ssh
    # that failed here must not be indistinguishable from a server with no mail
    # stack.
    *"'bash' '-s' '--' '"*"/mail' "*)
        [ -z "${MAIL_OUT+set}" ] || { printf '%s' "$MAIL_OUT"; exit "${MAIL_RC:-0}"; }
        [ "${MAIL_RC:-0}" = 0 ] || exit "$MAIL_RC"
        printf 'mail_stack=%s\n' "${MAIL_STACK:-no}"
        printf 'mail_env=%s\n' "${MAIL_ENV:-no}"
        printf 'mail_registry_b64=%s\n' "${MAIL_REGISTRY_B64-}"
        printf 'mail_dms=%s\n' "${MAIL_DMS:-running}"
        printf 'mail_snappymail=%s\n' "${MAIL_SNAPPY:-running}" ;;
    # The deploy itself, and its report on stdout. Every key is settable and any
    # one of them is droppable with REPORT_OMIT, because "the report never
    # arrived" and "the deploy said nothing changed" must not be the same thing
    # to the side reading it.
    *"remote-deploy.sh' 'deploy' '1.0.0'"*)
        # REPORT_NOISE is whatever reached stdout *before* the report — a hook
        # or a backup.check on a far side whose redirects were not there. The
        # report is printed last, so the absorber's last-wins is what decides
        # which of the two the deploy believes.
        [ -z "${REPORT_NOISE:-}" ] || printf '%s\n' "$REPORT_NOISE"
        # `all` is the headline case docs/build-deploy.md's protocol rests on:
        # exit 0 and no report at all.
        [ "${REPORT_OMIT:-}" != all ] || exit 0
        [ "${REPORT_OMIT:-}" = version ]      || printf 'version=%s\n' "${REPORT_VERSION-1.0.0}"
        [ "${REPORT_OMIT:-}" = prev_version ] || printf 'prev_version=%s\n' "${REPORT_PREV-0.9.0}"
        # The other half of the same question. An empty prev_version is what a
        # first deploy and a versions.log whose last line is a truncated write
        # both look like, so the two facts are settable apart.
        [ "${REPORT_OMIT:-}" = deployed_before ] || printf 'deployed_before=%s\n' "${REPORT_HISTORY-yes}"
        [ "${REPORT_OMIT:-}" = backup ]       || printf 'backup=%s\n' "${REPORT_BACKUP-no-backup}"
        [ "${REPORT_OMIT:-}" = digest ]       || printf 'digest=%s\n' "${REPORT_DIGEST--}" ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB
# The helper is rendered into a temp file and removed when the run ends, so the
# only way to see what actually travelled is to catch it in flight.
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
{ printf 'rsync'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
case "${!#}" in
    *"/scripts/remote-deploy.sh") cp "${@:$#-1:1}" "$RSYNC_HELPER_COPY" ;;
esac
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
n_marker=$(grep -n -m1 -E "\|'bash' '-s' '--' '/apps' '/etc/kasbah/apps-path'\$" <<<"$calls" | cut -d: -f1)
n_prepare=$(line_of "|'bash' '-s' '--' '/apps' '/apps/data' 'demo'")
n_compose=$(line_of "|compose.prod.yml|")
n_helper=$(line_of "|deploy@vps:/apps/demo/scripts/remote-deploy.sh")
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
assert 'grep -qE "\|-pt\|--chmod=F755\|-s\|[^|]+\|deploy@vps:/apps/demo/scripts/remote-deploy.sh$" <<<"$calls"' \
    "the helper ships executable, stated rather than inherited from the checkout ($(grep -F "remote-deploy.sh" <<<"$calls"))"
# Unlike setup-env.sh, this one is *not* a repo file shipped verbatim: it is
# templates/remote-deploy.sh with the project's manifest rendered into it, since
# the manifest itself is never synced and a VPS has no yq to read it with. So the
# source is a temp file, and what matters is what was in it.
helper_src=$(grep -oE "\|-s\|[^|]+\|deploy@vps:/apps/demo/scripts/remote-deploy.sh$" <<<"$calls")
helper_src=${helper_src#|-s|}
helper_src=${helper_src%|deploy@vps:*}
assert '[ -n "$helper_src" ] && [ "$helper_src" != "$repo_dir/templates/remote-deploy.sh" ]' \
    "shipped from a rendered file rather than straight from the checkout (source '$helper_src')"
assert '[ ! -e "$helper_src" ]' \
    "which is removed when the run ends, not left in TMPDIR ('$helper_src')"
# Both traps, and the fact that they chain rather than replace one another.
# cmd_deploy installs its own *before* ssh_connect, which is what lets
# lib/ssh.sh append to it (`trap -- 'a; b' EXIT`); installed after, the second
# `trap … EXIT` is last-writer-wins and the control-socket directory outlives
# every run (docs/phases/02-spine.md — the same rule ssh.sh's header states).
leftover=$(find "$run_tmp" -mindepth 1 -maxdepth 1 2>/dev/null | sort | tr "\n" " ")
assert '[ -z "$leftover" ]' \
    "a finished deploy leaves nothing in TMPDIR — neither the rendered helper nor the ssh control directory (found: $leftover)"
assert 'grep -qF "# >>> kasbah generated block" "$helper_copy"' \
    "and the bytes that travelled carry the generated block"
assert 'grep -qE "^# Generated by kasbah [0-9]" "$helper_copy"' \
    "naming the kasbah that wrote it ($(grep -m1 "^# Generated by kasbah" "$helper_copy"))"
# The demo fixture declares no hooks, no backup and no health, so this is what
# those render to — and asserting the values rather than the block's presence is
# what makes a render that silently dropped them falsifiable.
assert 'grep -qxF "RD_IMAGES=( )" "$helper_copy"' \
    "with no built images for a stock-only project ($(grep -m1 "^RD_IMAGES=" "$helper_copy"))"
assert 'grep -qxF "RD_HOOKS_PRE_DEPLOY=( )" "$helper_copy"' "no pre-deploy hooks"
assert 'grep -qxF "RD_BACKUP_CHECK='"''"'" "$helper_copy"' "and no backup"
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

# --- The three flags --------------------------------------------------------------
# kasbah decides nothing about them: each is handed to scripts/remote-deploy.sh,
# whose own suite proves what it then does (tests/remote_deploy_test.sh). What is
# asserted here is that they arrive, and that nothing arrives when nothing was
# asked for — the default is the half an author's survey forgets.
rd_call() { grep -F "remote-deploy.sh' 'deploy'" <<<"$(<"$call_log")"; }

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a deploy with no flags succeeds (rc $rc: $out)"
assert '! grep -qE -- "--(skip-hooks|no-health-wait|allow-stopped)" <<<"$(rd_call)"' \
    "and passes none of the three flags on (ran: $(rd_call))"

for flag in --skip-hooks --no-health-wait --allow-stopped; do
    out=$( cd "$project" && deploy_cli deploy@vps "$flag" ); rc=$?
    assert '[ "$rc" = "0" ]' "\`kasbah deploy $flag\` succeeds (rc $rc: $out)"
    assert 'grep -qF "remote-deploy.sh'\'' '\''deploy'\'' '\''1.0.0'\'' '\''$flag'\''" <<<"$(rd_call)"' \
        "and $flag reaches the shipped script, after the version (ran: $(rd_call))"
done

out=$( cd "$project" && deploy_cli deploy@vps --skip-hooks --no-health-wait --allow-stopped ); rc=$?
assert '[ "$rc" = "0" ]' "all three together succeed (rc $rc: $out)"
assert 'grep -qF "'\''deploy'\'' '\''1.0.0'\'' '\''--skip-hooks'\'' '\''--no-health-wait'\'' '\''--allow-stopped'\''" <<<"$(rd_call)"' \
    "and all three travel in one command line (ran: $(rd_call))"
out=$( cd "$project" && deploy_cli --skip-hooks deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a flag ahead of the target parses as a flag (rc $rc: $out)"
assert 'grep -qF "'\''deploy'\'' '\''1.0.0'\'' '\''--skip-hooks'\''" <<<"$(rd_call)"' \
    "and still reaches the far side after the version (ran: $(rd_call))"

out=$( cd "$project" && deploy_cli deploy@vps --skip-hook ); rc=$?
assert '[ "$rc" != "0" ]' "a near-miss flag is refused rather than silently dropped (rc $rc: $out)"
assert 'grep -qF -- "--skip-hooks" <<<"$out"' "and the refusal lists the real one (said '$out')"

# A flag of this command's, spelled with a value. The catch-all refusal names all
# three flags, so it cannot also be the one that says a flag is unknown — the
# message would deny and confirm the same flag in one sentence.
for flag in --skip-hooks --no-health-wait --allow-stopped; do
    out=$( cd "$project" && deploy_cli deploy@vps "$flag=yes" ); rc=$?
    assert '[ "$rc" != "0" ]' "$flag=yes is refused (rc $rc: $out)"
    assert 'grep -qF -- "$flag takes no value" <<<"$out"' \
        "for the reason it is actually wrong (said '$out')"
    assert '! grep -qF "unknown flag" <<<"$out"' \
        "and not as an unknown flag it goes on to list as known (said '$out')"
done

# The three are in docs/cli.md as part of this command, so they are in its own
# --help too: a flag nobody can discover from the CLI is a flag that does not
# exist for the operator reading it.
out=$( cd "$project" && deploy_cli --help ); rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah deploy --help\` exits 0 (rc $rc)"
for flag in --skip-hooks --no-health-wait --allow-stopped --on-drift; do
    assert 'grep -qF -- "$flag" <<<"$out"' "and lists $flag (said '$out')"
done
rm -rf "$project/.kasbah"

# --- The report the far side sends back, and the changelog it makes possible -------
# remote-deploy.sh's last act is a key=value report on stdout. It is absorbed as
# a protocol — a fact that never arrived must not be read as a value — and the
# previous version in it is the only way this side can know what the server was
# running (docs/build-deploy.md step 10).
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "the deploy that reports prev=0.9.0 succeeds (rc $rc: $out)"
assert 'grep -qF "changes: v0.9.0..v1.0.0" <<<"$out"' \
    "the changelog names the range the server's own report defines (said '$out')"
assert 'grep -qF "the commit this deploy ships" <<<"$out"' \
    "and lists the commit inside it (said '$out')"
assert '! grep -qF "the commit before the one being deployed" <<<"$out"' \
    "and not the one before it — a range, not a log (said '$out')"
# The report is data for this side, not something to echo at the operator.
assert '! grep -qF "prev_version=" <<<"$out"' \
    "the raw report is absorbed rather than printed (said '$out')"

out=$( cd "$project" && REPORT_PREV= REPORT_HISTORY=no deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a first deploy — the server reports no previous version (rc $rc: $out)"
assert 'grep -qF "first deploy" <<<"$out"' "says so instead of a changelog (said '$out')"
assert '! grep -qF "v..v1.0.0" <<<"$out"' "and computes no range from an empty version (said '$out')"

# The other server that reports prev_version= — and it is not a first deploy.
# The far side has just refused to call it one (its versions.log holds entries;
# only their last line is a truncated write), so the local side must not say the
# opposite of the sentence the operator has read three lines above. The two
# halves travel as two keys because one key cannot carry them.
out=$( cd "$project" && REPORT_PREV= REPORT_HISTORY=yes deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a server with history and an unreadable last line still deploys (rc $rc: $out)"
assert '! grep -qF "first deploy" <<<"$out"' \
    "and is never called a first deploy — the server said it has deployed here (said '$out')"
assert 'grep -qF "has deployed demo before" <<<"$out"' \
    "the changelog says what is actually true of it (said '$out')"
assert 'grep -qF "versions.log" <<<"$out"' \
    "and points at the file to look at (said '$out')"

# A value the protocol does not define must not fall through to "no": that is
# the changelog calling a server with history a first deploy, which is the
# defect the key was added for.
out=$( cd "$project" && REPORT_HISTORY=maybe deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a deployed_before that is neither yes nor no fails the deploy (rc $rc: $out)"
assert 'grep -qF "deployed_before=" <<<"$out" && grep -qF "maybe" <<<"$out"' \
    "quoting what the server said (said '$out')"
rm -rf "$project/.kasbah"

out=$( cd "$project" && REPORT_PREV=1.0.0 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a redeploy of the version already there succeeds (rc $rc: $out)"
assert 'grep -qF "v1.0.0..v1.0.0 is empty" <<<"$out"' \
    "and says the range is empty rather than printing nothing at all (said '$out')"
assert 'grep -qF "redeploy of the version already there" <<<"$out"' \
    "calling it a redeploy (said '$out')"

# The other way an empty range happens, and it is not a no-op: the server was
# running 1.1.0 and this deploy takes it back to 1.0.0. Calling that "a redeploy
# of what was already there" describes the opposite of what just happened.
out=$( cd "$project" && REPORT_PREV=1.1.0 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "deploying a version the server is ahead of succeeds (rc $rc: $out)"
assert 'grep -qF "is not ahead of the 1.1.0 this server was running" <<<"$out"' \
    "and says the deploy goes backwards (said '$out')"
assert 'grep -qF "git log v1.0.0..v1.1.0" <<<"$out"' \
    "naming the range that says what it gives up (said '$out')"
assert '! grep -qF "redeploy of the version already there" <<<"$out"' \
    "and does not call a downgrade a redeploy (said '$out')"

# A version this checkout has never heard of. The deploy is already done by the
# time the changelog runs, so a missing tag is a warning and the run still ends 0.
out=$( cd "$project" && REPORT_PREV=9.9.9 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a previous version with no tag here does not fail the deploy (rc $rc: $out)"
assert 'grep -qF "no tag v9.9.9" <<<"$out"' "but is said out loud (said '$out')"
assert 'grep -qF "git fetch --tags" <<<"$out"' "with the way to get it (said '$out')"
assert 'grep -qF "Deployed demo 1.0.0" <<<"$out"' "and the deploy is still reported (said '$out')"
rm -rf "$project/.kasbah"

# Each key on its own: a report missing any one of the five is the step not
# having finished, because the report is the last thing the script writes.
#
# The assertion is the protocol *sentence*, not the bare key name. Dropping a key
# from the required set leaves the run failing either way — but on
# `${_DEPLOY_FACT[key]}: unbound variable` and a bash backtrace, which happens to
# contain the key name too. Grepping for the name alone calls that a pass.
for key in version prev_version deployed_before backup digest; do
    out=$( cd "$project" && REPORT_OMIT="$key" deploy_cli deploy@vps ); rc=$?
    calls=$(<"$call_log")
    assert '[ "$rc" != "0" ]' "a report with no $key fails the deploy (rc $rc: $out)"
    assert 'grep -qF "the deploy step on deploy@vps reported no $key" <<<"$out"' \
        "with the protocol's own sentence, not a bash error that mentions $key (said '$out')"
    assert '! grep -qF "unbound variable" <<<"$out"' \
        "and no unbound-variable crash (said '$out')"
    assert '! grep -qF "dynamic/demo.yml" <<<"$calls"' \
        "and no route was written for a deploy that cannot be shown to have finished"
    assert '[ ! -f "$project/.kasbah/state.json" ]' "and no state was recorded"
done

# The headline shape, which dropping one key at a time never produces: exit 0 and
# nothing on stdout at all.
out=$( cd "$project" && REPORT_OMIT=all deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a deploy that exits 0 and reports nothing at all fails (rc $rc: $out)"
assert 'grep -qF "reported no version prev_version deployed_before backup digest" <<<"$out"' \
    "naming all five in one sentence rather than the first one it missed (said '$out')"
assert '! grep -qF "dynamic/demo.yml" <<<"$calls"' "and no route was written"

# This is the one absorb whose failure is not "nothing happened", so it says so:
# the far side got at least as far as `compose up`, and the operator has a server
# to look at. The prepare step's identical failure must *not* carry that.
assert 'grep -qF "compose up" <<<"$out"' \
    "and says the far side may already have deployed (said '$out')"
assert 'grep -qF "safe to run again" <<<"$out"' "and that re-running is safe (said '$out')"
out=$( cd "$project" && PREPARE_OUT="" deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a truncated prepare report fails the same way (rc $rc: $out)"
assert 'grep -qF "the prepare step on deploy@vps reported no prepared" <<<"$out"' \
    "through the same absorber (said '$out')"
assert '! grep -qF "safe to run again" <<<"$out"' \
    "but without the deploy step's paragraph — at the prepare step nothing has run,
        and the advice is one caller's, not the absorber's (said '$out')"
assert '[ "$(grep -c "^rsync|" <<<"$calls")" = "0" ]' "and nothing was shipped"

# Contamination. A hook or a backup.check on a far side whose redirects were
# missing puts `key=value` lines on stdout ahead of the report; the report is
# printed last and the absorber keeps the last value, so the report wins. Under
# first-wins this is a wrong-version refusal and a changelog for the wrong range.
out=$( cd "$project" && REPORT_NOISE=$'version=9.9.9\nprev_version=9.9.9\nbackup=/tmp/not-a-backup' \
        deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a report preceded by stray key=value lines still deploys (rc $rc: $out)"
assert 'grep -qF "changes: v0.9.0..v1.0.0" <<<"$out"' \
    "with the range the report gave, not the one the noise claimed (said '$out')"
assert '! grep -qF "9.9.9" <<<"$out"' "and nothing of the noise reaches the operator (said '$out')"
rm -rf "$project/.kasbah"

# A report about some other version means the two sides are not talking about
# the same deploy — the shipped script is written by this same run, moments
# earlier, so there is no benign version skew for this to be.
out=$( cd "$project" && REPORT_VERSION=0.9.0 deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a report naming another version fails the deploy (rc $rc: $out)"
assert 'grep -qF "0.9.0" <<<"$out" && grep -qF "1.0.0" <<<"$out"' \
    "quoting both what it said and what it was asked for (said '$out')"
rm -rf "$project/.kasbah"

# Stdout is nobody's in a deploy: the report is consumed, and everything the
# operator reads is on stderr — the changelog's commit lines included.
split_out=$( cd "$project" && deploy_cli_split deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "the split-stream deploy succeeds (rc $rc: $(cat "$split_err"))"
assert '[ -z "$split_out" ]' "and writes nothing at all to stdout (stdout: '$split_out')"
assert 'grep -qF "changes: v0.9.0..v1.0.0" "$split_err"' \
    "the changelog is on stderr ($(grep -F "changes:" "$split_err"))"
assert 'grep -qF "the commit this deploy ships" "$split_err"' \
    "and so are the commit lines under it ($(grep -F "the commit" "$split_err"))"

# The two facts only the report brings back. Neither is on this side otherwise,
# and "was a backup taken" is the thing an operator most wants before the next
# command.
out=$( cd "$project" && REPORT_BACKUP=backups/pre-deploy-20260101-000000.sql.gz \
        REPORT_DIGEST=sha256:aa,sha256:bb deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a deploy whose server took a backup succeeds (rc $rc: $out)"
assert 'grep -qF "backup:  /apps/demo/backups/pre-deploy-20260101-000000.sql.gz" <<<"$out"' \
    "and the banner names the file the server wrote, under the project directory (said '$out')"
assert 'grep -qF "images:  sha256:aa,sha256:bb" <<<"$out"' \
    "and the ids that went live (said '$out')"

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert 'grep -qF "backup:  none taken" <<<"$out"' \
    "while no-backup is said in words rather than printed as a path (said '$out')"
assert '! grep -qF "images:" <<<"$out"' \
    "and a stock-only project's digest=- is left out entirely (said '$out')"
rm -rf "$project/.kasbah"

# --- The mail claim ----------------------------------------------------------------
# Reconciled now, not stubbed: the step reads <apps>/mail/kasbah.yml back as
# base64 and this side parses it with the workstation's yq, because the VPS has
# no YAML parser and keeping it that way is deliberate. What it must never do is
# stop the deploy — an unmet mail claim costs mail, not the site.
cp "$project/kasbah.yml" "$tmpdir/kasbah.yml.orig"
printf '\nmail:\n  domain: mail.demo.test\n' >> "$project/kasbah.yml"

# A registry that serves the claimed domain, and one that does not. The
# difference between them is the whole of what the reconciliation decides.
registry_with=$(printf 'name: mail\nprimary_domain: demo.test\ndomains:\n  - demo.test\n  - mail.demo.test\n' | openssl base64 -A)
registry_without=$(printf 'name: mail\nprimary_domain: demo.test\ndomains:\n  - demo.test\n  - other.test\n' | openssl base64 -A)
registry_broken=$(printf 'name: mail\ndomains:\n  - [unclosed\n' | openssl base64 -A)
# The registry a hand edit leaves behind: the primary is the MX target and is
# *not* duplicated under domains:. Both of these are that shape, and the pair is
# what keeps either assertion from going quiet — the first names the primary as
# the claimed domain, the second names a domain in neither field.
registry_primary_only=$(printf 'name: mail\nprimary_domain: mail.demo.test\ndomains:\n  - other.test\n' | openssl base64 -A)
registry_primary_other=$(printf 'name: mail\nprimary_domain: shop.demo.test\ndomains:\n  - other.test\n' | openssl base64 -A)

out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a project claiming a mail domain deploys against a server with no mail stack (rc $rc: $out)"
assert 'grep -qF "'\''bash'\'' '\''-s'\'' '\''--'\'' '\''/apps/mail'\''" <<<"$calls"' \
    "having actually looked for it ($(grep -F "/mail" <<<"$calls"))"
assert 'grep -qF "mail.demo.test" <<<"$out"' "the warning names the claimed domain (said '$out')"
assert 'grep -qF "/apps/mail" <<<"$out"' "and where it looked (said '$out')"
assert 'grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and the deploy ran anyway"
# Step 7 of docs/build-deploy.md's flow, and it is a step number rather than a
# preference: the claim is judged against the server the deploy is about to run
# on, after the .env that server will use is settled and before anything starts.
n_mail=$(line_of "'--' '/apps/mail'")
n_inject=$(line_of "setup-env.sh' '--inject'")
n_remote=$(line_of "remote-deploy.sh' 'deploy'")
for n in n_mail n_inject n_remote; do [ -n "${!n}" ] || printf -v "$n" '%s' 0; done
assert '[ "$n_mail" -gt "$n_inject" ] && [ "$n_mail" -lt "$n_remote" ]' \
    "and it looked between the env step and the deploy (inject $n_inject, mail $n_mail, deploy $n_remote)
        calls: $calls"

# The green path: the registry lists the domain, so the claim is met and there
# is nothing to warn about. Asserted on the *distinguishing* sentence and on the
# absence of the unmet one — a test that only checked rc 0 would pass against
# every branch here.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a claim the registry serves deploys (rc $rc: $out)"
assert 'grep -qF "mail.demo.test is served by the stack" <<<"$out"' \
    "and says the claim is met (said '$out')"
assert '! grep -qF "does not serve it" <<<"$out"' "and not the unmet sentence (said '$out')"
assert '! grep -qF "there is no mail stack" <<<"$out"' "and not the absent-stack one (said '$out')"

# The claim the stack does not know. A warning, never a failure, and it names
# the command that fixes it.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_without" \
       deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a claim the registry does not serve still deploys (rc $rc: $out)"
assert 'grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and the deploy ran (calls: $(grep -c . <<<"$calls") lines)"
assert 'grep -qF "does not serve it" <<<"$out"' "saying the stack does not serve it (said '$out')"
assert 'grep -qF "kasbah server add-mail-domain deploy@vps mail.demo.test" <<<"$out"' \
    "and naming the command that adds it (said '$out')"
assert 'grep -qF "lists: demo.test other.test" <<<"$out"' \
    "and what it does serve, read out of the registry (said '$out')"
assert '! grep -qF "is served by the stack" <<<"$out"' "and not the met sentence (said '$out')"

# The seam between this step and `kasbah check`'s M03. Three readers — M03,
# `server init` and `server add-mail-domain` — hold that the primary is served
# by the stack it is the MX for whether or not anyone wrote it under domains:,
# and the two writers normalise it in, so every registry kasbah wrote agrees
# either way. A **hand-edited** one need not, and templates/mail/kasbah.yml
# invites the hand edit ("a hand edit here survives"). On that file this step
# used to read .domains alone and warn "does not serve it" about the very
# registry check --server had just passed — two commands, one question,
# opposite answers in the same run.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_primary_only" \
       deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a claim on a primary_domain not repeated under domains: deploys (rc $rc: $out)"
assert 'grep -qF "mail.demo.test is served by the stack" <<<"$out"' \
    "and the claim is met — the primary is served by the stack it is the MX for (said '$out')"
assert '! grep -qF "does not serve it" <<<"$out"' \
    "not warned as unserved, which is what check --server would contradict (said '$out')"

# The other half of the pair, on the same mechanism and the same file shape: a
# domain in neither primary_domain nor domains: is still unserved. Without this
# the assertion above is satisfied by a step that calls everything served.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_primary_other" \
       deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a claim in neither field still deploys (rc $rc: $out)"
assert 'grep -qF "does not serve it" <<<"$out"' \
    "and is still reported unserved (said '$out')"
assert '! grep -qF "is served by the stack" <<<"$out"' "and not met (said '$out')"
assert 'grep -qF "lists: shop.demo.test other.test" <<<"$out"' \
    "with the primary at the head of what it does serve, as init renders it (said '$out')"

# A registry that is not there, and one that does not parse. Neither is "the
# stack does not serve this domain": kasbah could not read the file that would
# have answered, which is a different thing to tell an operator.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "an unreadable registry does not stop the deploy (rc $rc: $out)"
assert 'grep -qF "is missing or unreadable" <<<"$out"' "and is reported as that (said '$out')"
assert '! grep -qF "does not serve it" <<<"$out"' "not as an unserved domain (said '$out')"

out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_broken" \
       deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a registry that does not parse does not stop the deploy (rc $rc: $out)"
assert 'grep -qF "does not parse as YAML" <<<"$out"' "and is reported as that (said '$out')"
assert '! grep -qF "does not serve it" <<<"$out"' "not as an unserved domain (said '$out')"

# The stack is known to serve the domain and is not running. Two questions, two
# answers: the domain is met and the containers are not there.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       MAIL_DMS=absent deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a stopped mail stack does not stop the deploy (rc $rc: $out)"
assert 'grep -qF "there is no mail-dms container" <<<"$out"' "and is reported (said '$out')"
assert 'grep -qF "is served by the stack" <<<"$out"' \
    "while the domain is still reported as served (said '$out')"

out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       MAIL_DMS=restarting deploy_cli deploy@vps ); rc=$?
assert 'grep -qF "mail-dms on deploy@vps is '\''restarting'\'', not running" <<<"$out"' \
    "a crashlooping DMS is named as that rather than as absent (said '$out')"
assert 'grep -qF "acme.json" <<<"$out"' "with the reason it usually is (said '$out')"

# The third state, and the reason the step reads more than one fact: a mail
# directory with no .env in it is a stack that cannot be handling anybody's
# domain, which is a fact about the server rather than about kasbah's roadmap.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=no deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a mail stack with no .env does not stop the deploy either (rc $rc: $out)"
assert 'grep -qF "has no .env" <<<"$out"' "and is reported as its own thing (said '$out')"
assert '! grep -qF "does not serve it" <<<"$out"' \
    "not as an unserved domain — the registry was never reached (said '$out')"
assert '! grep -qF "there is no mail stack" <<<"$out"' "and not as the absent-stack one (said '$out')"

# The step's own failures. An ssh that could not run the payload must not be
# read as "there is no mail stack": the two are the same absent answer, and only
# one of them is a fact about the server.
out=$( cd "$project" && MAIL_RC=255 deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" != "0" ]' "a mail probe that could not run fails the deploy (rc $rc: $out)"
assert 'grep -qF "could not look for the mail stack" <<<"$out"' "saying so (said '$out')"
assert '! grep -qF "there is no mail stack" <<<"$out"' \
    "rather than reporting an absent stack it never managed to look for (said '$out')"
assert '! grep -qF "remote-deploy.sh'\'' '\''deploy'\''" <<<"$calls"' "and nothing was deployed"

out=$( cd "$project" && MAIL_OUT="mail_stack=yes"$'\n' deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a half-answered mail probe fails the deploy (rc $rc: $out)"
assert 'grep -qF "the mail claim step on deploy@vps reported no mail_env" <<<"$out"' \
    "naming the answer that never came (said '$out')"
assert '! grep -qF "safe to run again" <<<"$out"' \
    "and not the deploy step's paragraph — nothing had run yet (said '$out')"

# --- The SnappyMail pre-seed -------------------------------------------------------
# Copy-if-missing, and the file travels from the checkout because the far side
# has no way to fetch it. What is asserted is that it travelled: the fourth
# argument of the mail step is the base64, and it is empty when nothing is
# claimed.
mkdir -p "$project/mail"
printf '{"name":"mail.demo.test","imap":{"host":"mail.demo.test"}}\n' > "$project/mail/seed.json"
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nmail:\n  domain: mail.demo.test\n  snappymail_domain: ./mail/seed.json\n' >> "$project/kasbah.yml"

seed_b64=$(openssl base64 -A -in "$project/mail/seed.json")
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       MAIL_SEED=copied deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a project naming a snappymail pre-seed deploys (rc $rc: $out)"
assert 'grep -qF "'"'$seed_b64'"'" <<<"$calls"' \
    "and the file's bytes travelled with the claim ($(grep -F "/apps/mail" <<<"$calls"))"
assert 'grep -qF "seeded SnappyMail'\''s mail.demo.test.json" <<<"$out"' \
    "and the copy is reported (said '$out')"

out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       MAIL_SEED=present deploy_cli deploy@vps ); rc=$?
assert 'grep -qF "left as it is" <<<"$out"' \
    "an existing config is left alone and said so — never overwritten (said '$out')"
assert '! grep -qF "seeded SnappyMail" <<<"$out"' "and not reported as a copy (said '$out')"

out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       MAIL_SEED=failed deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a pre-seed that could not be written does not stop the deploy (rc $rc: $out)"
assert 'grep -qF "could not seed SnappyMail" <<<"$out"' "and warns (said '$out')"

# The gate. docs/mail.md step 3 is conditioned on step 2: a SnappyMail domain
# config for a domain the stack does not serve is configuration written on a
# premise this run has just reported false, and nothing in that directory
# afterwards tells the two cases apart.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_without" \
       deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "an unmet claim with a pre-seed still deploys (rc $rc: $out)"
assert '! grep -qF "mail-snappymail" <<<"$calls"' \
    "and the seed step never runs ($(grep -F "/apps/mail" <<<"$calls"))"
assert '! grep -qF "$seed_b64" <<<"$calls"' "so the file never travels"
assert 'grep -qF "it was NOT copied" <<<"$out"' "which is said out loud (said '$out')"
assert 'grep -qF "premise kasbah knows to be false" <<<"$out"' \
    "with the reason, not just the fact (said '$out')"
assert 'grep -qF "does not serve it" <<<"$out"' \
    "alongside the claim warning it follows from (said '$out')"

# And the control for it: the same manifest against a registry that does serve
# the domain seeds normally — otherwise the gate is indistinguishable from a
# seed step that never works.
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert 'grep -qF "mail-snappymail" <<<"$calls"' \
    "a met claim runs the seed step ($(grep -F "mail-snappymail" <<<"$calls"))"
assert '! grep -qF "it was NOT copied" <<<"$out"' "and says nothing about a gate (said '$out')"

# A named file that is not in the checkout. `kasbah check`'s M02 is where that
# is a failure; here it is a warning, because the claim never stops a deploy.
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nmail:\n  domain: mail.demo.test\n  snappymail_domain: ./mail/missing.json\n' >> "$project/kasbah.yml"
out=$( cd "$project" && MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
       deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a snappymail_domain naming no file does not stop the deploy (rc $rc: $out)"
assert 'grep -qF "there is no such file in this checkout" <<<"$out"' "and says so (said '$out')"
assert '! grep -qF "mail-snappymail" <<<"$calls"' \
    "and no seed step ran at all ($(grep -F "/apps/mail" <<<"$calls"))"

# The claim is the domain. A block without one is a mistake about this checkout,
# so it costs a sentence before the first connection.
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nmail:\n  snappymail_domain: ./mail/seed.json\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a mail: block with no domain: is refused (rc $rc: $out)"
assert 'grep -qF "mail" <<<"$out" && grep -qF "domain" <<<"$out"' "naming both (said '$out')"
assert '[ ! -s "$ssh_log" ]' "before any connection (ssh saw: $(cat "$ssh_log"))"

# And a mail: that is not a block at all. Without the shape check the operator
# gets jq's own type error and the name of kasbah's internal filter.
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nmail: mail.demo.test\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a scalar mail: is refused (rc $rc: $out)"
assert 'grep -qF "mail: has type '\''string'\''" <<<"$out"' "naming what it found (said '$out')"
assert '! grep -qF "yq filter failed" <<<"$out"' \
    "without leaking the filter kasbah ran (said '$out')"
assert '! grep -qF "Cannot index" <<<"$out"' "or jq's own error (said '$out')"
assert '[ ! -s "$ssh_log" ]' "before any connection (ssh saw: $(cat "$ssh_log"))"

# The control: with the block gone, no probe is made at all — otherwise the two
# warnings above prove only that a warning can be printed.
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
rm -rf "$project/mail"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a project with no mail: block deploys (rc $rc: $out)"
assert '! grep -qF "/apps/mail" <<<"$calls"' \
    "and nothing looks for a mail stack it never claimed ($(grep -F "/mail" <<<"$calls"))"
rm -rf "$project/.kasbah"

# --- The effective client, rendered onto the server (D12) --------------------------
# `client:` groups a project's off-VPS backups into one restic repository and
# defaults to `name`. The manifest never reaches a VPS, and the backup runner
# that needs the answer runs there — so deploy renders it, the way Phase 4
# established for hooks, backup and health. What is asserted is the value that
# crossed the wire, not kasbah's summary.
prepare_arg5() {
    # Field 5 of the prepare step's argument list: apps, data, name, client.
    grep -F "|'bash' '-s' '--' '/apps' '/apps/data' 'demo'" <<<"$(<"$call_log")" \
        | head -1 | sed "s|.*'--' '/apps' '/apps/data' 'demo' '\([^']*\)'.*|\1|"
}

cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a manifest with no client: deploys (rc $rc: $out)"
assert '[ "$(prepare_arg5)" = "demo" ]' \
    "and the record written to the server is the project name, which is what client: defaults to (got '$(prepare_arg5)')"
assert 'grep -qF ".kasbah-client" <<<"$out"' \
    "the run names the file it wrote (said '$out')"

cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nclient: acme-corp\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "a manifest with client: deploys (rc $rc: $out)"
assert '[ "$(prepare_arg5)" = "acme-corp" ]' \
    "and the manifest's client is what crosses the wire (got '$(prepare_arg5)')"
assert 'grep -qF "client:  acme-corp" <<<"$out"' \
    "and the run says which repository the project files into (said '$out')"

# The charset is `name`'s, because the value becomes a path segment of a
# repository URL nothing parses.
for bad in Acme "acme corp" "acme/corp" "9acme" "-acme"; do
    cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
    printf '\nclient: "%s"\n' "$bad" >> "$project/kasbah.yml"
    out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
    assert '[ "$rc" != "0" ]' "client '\''$bad'\'' is refused (rc $rc: $out)"
    assert 'grep -qF "client" <<<"$out"' "naming the field (said '\''$out'\'')"
    assert '[ ! -s "$ssh_log" ]' "before any connection (ssh saw: $(cat "$ssh_log"))"
done

# And the four names kasbah owns, `mail` above all: that repository holds every
# mailbox on the server (docs/phases/08-keep.md D7), and a project claiming it
# would put all of them into one client's handover.
for bad in mail traefik data backups; do
    cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
    printf '\nclient: %s\n' "$bad" >> "$project/kasbah.yml"
    out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
    assert '[ "$rc" != "0" ]' "client '\''$bad'\'' is refused as reserved (rc $rc: $out)"
    assert 'grep -qF "reserved" <<<"$out"' "and says why (said '\''$out'\'')"
done

# An explicitly empty value is the same as an absent one: `client:` is optional,
# and "" is how a scaffolder writes "not set".
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
printf '\nclient: ""\n' >> "$project/kasbah.yml"
out=$( cd "$project" && deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" = "0" ]' "an empty client: deploys (rc $rc: $out)"
assert '[ "$(prepare_arg5)" = "demo" ]' \
    "and falls back to the project name (got '$(prepare_arg5)')"

# The record is not written by kasbah's summary but by the far side, so a
# prepare step that did not report writing it is a failure and not a shrug.
cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
out=$( cd "$project" && PREPARE_OUT="prepared=yes" deploy_cli deploy@vps ); rc=$?
assert '[ "$rc" != "0" ]' "a prepare step that reports no client fails (rc $rc: $out)"
assert 'grep -qF "reported no client" <<<"$out"' "naming what was missing (said '$out')"

cp "$tmpdir/kasbah.yml.orig" "$project/kasbah.yml"
# The successful deploys above each recorded project state; the env cases below
# assert that a *refused* one records none.
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
