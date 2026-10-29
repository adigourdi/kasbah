#!/usr/bin/env bash
# Integration test: `kasbah logs` and `kasbah exec` against the live rig, over a
# real project that a real deploy brought up.
#
# What only the rig can show, and what the hermetic suite therefore cannot:
#   * the command line kasbah composes is one `docker compose` actually accepts
#     — `-f <apps>/<name>/compose.yml -p <name>` against a real daemon, with the
#     project's real `.env` interpolated out of the file's own directory. A stub
#     ssh will agree with any spelling;
#   * `--tail=N` counted against a service whose log really is longer than N,
#     and a named service excluding the others;
#   * `-f` still streaming after the plain run has long returned;
#   * a command with spaces, quotes, a glob and a redirection arriving inside
#     the container intact — ssh re-joins its arguments with spaces before a
#     login shell sees them, so this is the only place _ssh_quote is proved
#     end to end;
#   * the exit status of the command travelling back through docker, ssh and
#     kasbah unchanged, and `last_server` being written even when it is not 0.
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
version=3.4.0
image_web=built-app-web
image_worker=built-app-worker
projdir_remote="$apps/$project"
# The three containers the fixture runs. `docker compose logs` prefixes each
# line with the container name where compose.prod.yml sets one, so these are
# what the output is read by. `worker` sleeps and never writes, which is why the
# quiet third service is not what any count below is taken from.
c_web=built-app-web
c_cache=built-app-cache

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    # A follower interrupted on this side leaves `docker compose logs -f` running
    # on the far side: an ssh session with no pty is not hung up when its client
    # dies, so the remote command survives until its next write to a closed pipe
    # — which for an idle service is never (measured on this rig, >80 s). That is
    # ssh's behaviour and not kasbah's (plain `ssh -n rig 'docker compose logs
    # -f'` leaks identically), but a suite that starts one has to take it back.
    rig_ssh "pkill -f 'compose -f $projdir_remote' >/dev/null 2>&1; true" >/dev/null 2>&1
    rig_ssh "docker image rm -f $image_web:$version $image_worker:$version $image_web:current $image_worker:current; rm -f /tmp/$project-*.tar.gz" >/dev/null 2>&1
    docker image rm -f "$image_web:$version" "$image_worker:$version" \
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
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
build_push() (
    cd "$projdir" || return 2
    kasbah_cli build-push "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
# Bounded, for the reason rig_env.sh gives: a wedged run must fail the suite
# rather than hang it. stdout and stderr land in separate files — compose's log
# lines are the answer and belong on stdout, kasbah's own words on stderr.
kasbah_bounded() (
    cd "${KASBAH_CWD:-$projdir}" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy() { kasbah_bounded deploy "$@"; }
logs()   { kasbah_bounded logs "$@"; }
kexec()  { kasbah_bounded exec "$@"; }

state_of() { jq -r ".$1 // \"\"" "$projdir/.kasbah/state.json" 2>/dev/null; }

# --- A prepared server ----------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — nothing to read logs from" >&2
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

# --- A deployed project ------------------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

build_push "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: build-push of $version failed (exit $rc)" >&2
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
    echo "error: the $version deploy failed (exit $rc) — there are no containers to read" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# Redis writes its startup banner and then goes quiet, which is what makes it the
# service every count below is taken from: a log that does not grow under the
# suite's feet. Nine lines on redis:7-alpine at the time of writing, and the
# assertions ask only that it is comfortably more than the tails they request.
cache_lines=$(rig_ssh "docker logs $c_cache 2>&1 | wc -l" 2>/dev/null | tr -d '\r')
if [ -z "$cache_lines" ] || [ "$cache_lines" -lt 6 ]; then
    echo "error: $c_cache has only '$cache_lines' log lines — --tail=N cannot be counted against it" >&2
    exit 2
fi

# ==================================================================================
# kasbah logs
# ==================================================================================
rm -f "$projdir/.kasbah/state.json"
logs "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "0" ]' "kasbah logs runs against a project it deployed (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(cli_err)" = "" ]' "with nothing of kasbah's on stderr (stderr: $(cli_err))"
assert 'grep -q "^$c_web  *|" <<<"$out"' \
    "the web container's lines are there (got: $(head -3 <<<"$out"))"
assert 'grep -q "^$c_cache  *|" <<<"$out"' \
    "and the cache container's, because no service was named (got: $(head -3 <<<"$out"))"
assert '[ "$(grep -c $'\''\r'\'' <<<"$out")" = "0" ]' \
    "and not one carriage return in any of them — no pty was allocated for a log"
assert '[ "$(state_of last_server)" = "$RIG_TARGET" ]' \
    "a run that succeeded records the server (state: $(tr -d '\n' < "$projdir/.kasbah/state.json" 2>/dev/null))"

logs cache; rc=$?
out_one="$(cli_out)"
assert '[ "$rc" = "0" ]' "a bare argument is the service, on the remembered server (exit $rc: $(cli_err))"
assert 'grep -q "^$c_cache  *|" <<<"$out_one"' "whose lines are shown (got: $(head -2 <<<"$out_one"))"
assert '! grep -q "^$c_web  *|" <<<"$out_one"' \
    "and the other services' are not (got: $(head -5 <<<"$out_one"))"

n_default="$(grep -c . <<<"$out_one")"
logs cache --tail=1
n_one="$(grep -c . <<<"$(cli_out)")"
logs cache --tail=3
n_three="$(grep -c . <<<"$(cli_out)")"
assert '[ "$n_one" = "1" ] && [ "$n_three" = "3" ]' \
    "--tail=N is N lines of one service's history (--tail=1 gave $n_one, --tail=3 gave $n_three)"
assert '[ "$n_default" -gt "$n_three" ]' \
    "and the default is not the same number — it is 100, so it shows the lot ($n_default without the flag, $n_three with --tail=3)"

logs "$RIG_TARGET" nosuch; rc=$?
assert '[ "$rc" = "1" ]' "logs for a service the project does not have fails (exit $rc)"
assert 'grep -qF "could not read the logs of $project on $RIG_TARGET" "$tmpdir/err"' \
    "naming the project and the server (stderr: $(cli_err))"
assert 'grep -qF "nosuch" "$tmpdir/err"' "and the service it was given (stderr: $(cli_err))"

# --- a reader that stops reading -------------------------------------------------------
# `kasbah logs | head` is what docs/cli.md advertises. The hermetic suite proves
# the handling; only this one proves the number real ssh returns — **255, not
# 141**: OpenSSH ignores SIGPIPE (it has a socket to look after) and turns the
# failed write into fatal()/255. The stub was corrected to match this, so this
# assertion is what stands between the two of them and a shared wrong guess.
#
# `-f`, and against the web container specifically, because SIGPIPE needs a
# *write* after the reader has gone: this project's whole log is a few kilobytes
# and fits inside the pipe buffer, so a finite `logs | head -3` completes and
# exits 0 — measured. Under `-f` the container's own healthcheck writes an
# access-log line every five seconds, which is the write that lands on the
# closed pipe. Bounded, so a case that never gets one fails the suite instead of
# hanging it.
( cd "$projdir" && timeout 60 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" logs "$RIG_TARGET" -f --tail=all "$c_web" \
    2>"$tmpdir/err" </dev/null
  echo "$?" > "$tmpdir/prc" ) | head -3 > "$tmpdir/out"
prc="$(cat "$tmpdir/prc" 2>/dev/null)"
rig_ssh "pkill -f '$projdir_remote/compose.yml logs' >/dev/null 2>&1; true" >/dev/null 2>&1
assert '[ "$prc" = "255" ]' \
    "real ssh writing into a closed pipe leaves 255, and kasbah passes it through (rc '$prc')
        stderr: $(cli_err)"
assert '! grep -qF "could not read the logs" "$tmpdir/err"' \
    "with no paragraph blaming compose for the reader's exit (stderr: $(cli_err))"
assert '[ "$(cli_err)" = "" ]' \
    "and nothing at all on stderr (stderr: $(cli_err))"
assert '[ "$(grep -c . "$tmpdir/out")" = "3" ]' \
    "while the reader got its three lines (got $(grep -c . "$tmpdir/out"))"

# The same pipeline without `-f`, its reader draining after the three lines: no
# write ever lands on a closed pipe, so the run is an ordinary 0. Recorded so
# the 255 above reads as "the pipe closed under a write", not "piping is 255".
( cd "$projdir" && env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" logs "$RIG_TARGET" "$c_web" 2>"$tmpdir/err" </dev/null
  echo "$?" > "$tmpdir/prc" ) | { head -3; cat >/dev/null; } > "$tmpdir/out"
prc="$(cat "$tmpdir/prc" 2>/dev/null)"
assert '[ "$prc" = "0" ]' \
    "a finite log read through \`| head -3\` by a draining reader exits 0 (rc '$prc')"

# --- -f really follows ----------------------------------------------------------------
# The distinguishing fact is not that it printed something — the plain run above
# does that and returns — but that it is *still running* long after the plain run
# would have finished. Cleaned up on both sides; see cleanup() on why the far
# side needs taking back explicitly.
follow_out="$tmpdir/follow.out"
( cd "$projdir" && env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" logs -f cache >"$follow_out" 2>"$tmpdir/follow.err" </dev/null ) &
follow_pid=$!
sleep 8
if kill -0 "$follow_pid" 2>/dev/null; then follow_alive=yes; else follow_alive=no; fi
follow_lines="$(grep -c . "$follow_out" 2>/dev/null)"
[ -n "$follow_lines" ] || follow_lines=0
pkill -TERM -P "$follow_pid" >/dev/null 2>&1
kill -TERM "$follow_pid" >/dev/null 2>&1
wait "$follow_pid" 2>/dev/null
rig_ssh "pkill -f 'compose -f $projdir_remote' >/dev/null 2>&1; true" >/dev/null 2>&1

assert '[ "$follow_alive" = "yes" ]' \
    "kasbah logs -f is still streaming eight seconds in, where the same command without -f had returned (alive: $follow_alive)"
assert '[ "$follow_lines" -ge 1 ]' \
    "having printed the history first (lines: $follow_lines)"

# ==================================================================================
# kasbah exec
# ==================================================================================
kexec "$c_web" -- sh -c 'echo hi'; rc=$?
assert '[ "$rc" = "0" ]' "kasbah exec runs a command in a container (exit $rc: $(cli_err))"
assert '[ "$(cli_out)" = "hi" ]' "and its output is the whole of stdout (got: '$(cli_out)')"

# The quoting case, end to end: spaces, both kinds of quote, a glob and a
# redirection, all of which have to be interpreted by the container's own /bin/sh
# and by nothing between here and there. ssh re-joins its arguments with spaces
# before the login shell sees them, so an unquoted word would arrive as several.
kexec "$c_web" -- sh -c 'cd /etc && echo "a b" host* > /tmp/kasbah-exec.txt; echo "it'\''s" >> /tmp/kasbah-exec.txt'; rc=$?
assert '[ "$rc" = "0" ]' "a command carrying spaces, both quotes, a glob and a redirection runs (exit $rc: $(cli_err))"
kexec "$c_web" -- cat /tmp/kasbah-exec.txt
assert '[ "$(cli_out)" = "a b hostname hosts
it'\''s" ]' \
    "the redirection happened inside the container, the glob expanded there, and the quote survived (file holds: '$(cli_out)')"

# `-T` is not a flag anyone can see from here, so this is what it means: no
# terminal on the far side, because there is none on this one.
kexec "$c_web" -- sh -c 'test -t 0 && echo TTY || echo NOTTY'
assert '[ "$(cli_out)" = "NOTTY" ]' \
    "a suite with no terminal gets no pty in the container either (got: '$(cli_out)')"

# A flag after `--` is the command's. Without the separator kasbah would refuse
# it as its own unknown flag, which is the case below.
kexec "$c_web" -- ls -1 /etc/hostname; rc=$?
assert '[ "$rc" = "0" ] && [ "$(cli_out)" = "/etc/hostname" ]' \
    "a flag after -- reaches the command rather than kasbah's parser (exit $rc, got: '$(cli_out)')"

# --- stdin goes nowhere, and is not silent about it -------------------------------------
( cd "$projdir" && env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" exec "$c_web" -- cat ) \
    >"$tmpdir/out" 2>"$tmpdir/err" <<<"fed-into-kasbah"
rc=$?
assert '[ "$rc" = "0" ]' "a fed exec runs (exit $rc: $(cli_err))"
assert '[ "$(cli_out)" = "" ]' \
    "and prints nothing — ssh -n closed stdin, so cat read EOF (got: '$(cli_out)')"
assert 'grep -qF "stdin is not forwarded" "$tmpdir/err"' \
    "which is warned about rather than left to look like success (stderr: $(cli_err))"

# --- two runs against one server do not touch each other's ssh master -------------------
# Each run has its own control master; a second run's teardown must not cut a
# session the first is still in.
( cd "$projdir" && timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" exec "$c_web" -- sh -c 'echo started; sleep 6; echo survived' ) \
    >"$tmpdir/holder.out" 2>"$tmpdir/holder.err" </dev/null &
holder_pid=$!
started=no
for _ in $(seq 1 100); do
    if grep -qF started "$tmpdir/holder.out" 2>/dev/null; then started=yes; break; fi
    sleep 0.1
done
timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" "$KASBAH_BIN" server status "$RIG_TARGET" \
    >"$tmpdir/visitor.out" 2>"$tmpdir/visitor.err" </dev/null; visitor_rc=$?
if kill -0 "$holder_pid" 2>/dev/null; then holder_alive=yes; else holder_alive=no; fi
if grep -qF survived "$tmpdir/holder.out" 2>/dev/null; then early=yes; else early=no; fi
wait "$holder_pid"; holder_rc=$?
assert '[ "$started" = yes ]' "the first run was mid-command within 10 s (got: $(cat "$tmpdir/holder.out" "$tmpdir/holder.err"))"
assert '[ "$holder_alive" = yes ] && [ "$early" = no ]' \
    "and still mid-command when the second run finished (alive: $holder_alive, survived already: $early)"
assert '[ "$visitor_rc" = "0" ]' "a second run works meanwhile (exit $visitor_rc: $(cat "$tmpdir/visitor.err"))"
assert '[ "$holder_rc" = "0" ] && grep -qxF survived "$tmpdir/holder.out"' \
    "and the first run's session survived its teardown (exit $holder_rc: $(cat "$tmpdir/holder.out" "$tmpdir/holder.err"))"

# --- the status, and what is recorded with it -----------------------------------------
rm -f "$projdir/.kasbah/state.json"
kexec "$RIG_TARGET" "$c_web" -- sh -c 'exit 7'; rc=$?
assert '[ "$rc" = "7" ]' \
    "the command's own exit status comes back through docker, ssh and kasbah unchanged (exit $rc)"
assert '[ "$(cli_err)" = "" ]' \
    "with no error of kasbah's added to a command that simply answered (stderr: $(cli_err))"
assert '[ "$(state_of last_server)" = "$RIG_TARGET" ]' \
    "and the server is recorded anyway — kasbah's own work succeeded the moment the command ran
        (state: $(tr -d '\n' < "$projdir/.kasbah/state.json" 2>/dev/null))"

kexec "$c_web" -- false; rc=$?
assert '[ "$rc" = "1" ]' "a plain false is 1, not 0 (exit $rc)"

kexec nosuch -- true; rc=$?
assert '[ "$rc" != "0" ]' "exec into a service the project does not have fails (exit $rc)"
assert 'grep -qiF "nosuch" "$tmpdir/err"' "naming it (stderr: $(cli_err))"

# --- the refusals, against a server that is right there ---------------------------------
kexec "$c_web" ls; rc=$?
assert '[ "$rc" = "1" ]' "a command written without the -- is refused (exit $rc)"
assert 'grep -qF "comes after the service" "$tmpdir/err"' \
    "as a missing separator rather than as a second service (stderr: $(cli_err))"
assert '[ "$(cli_out)" = "" ]' "and nothing ran (stdout: $(cli_out))"

kexec "$c_web"; rc=$?
assert '[ "$rc" = "1" ]' "so is exec with no -- at all (exit $rc)"
assert 'grep -qF "no '\''--'\'' in the arguments" "$tmpdir/err"' "(stderr: $(cli_err))"

kexec "$RIG_TARGET" -- true; rc=$?
assert '[ "$rc" = "1" ]' "and exec with no service (exit $rc)"
assert 'grep -qF "no service given" "$tmpdir/err"' "(stderr: $(cli_err))"

# --- the two ways there is nothing to talk to ---------------------------------------------
KASBAH_CWD="$tmpdir" logs "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "2" ]' "logs outside a kasbah project exits 2 (exit $rc: $(cli_err))"
assert 'grep -qF "No kasbah.yml" "$tmpdir/err"' "(stderr: $(cli_err))"
KASBAH_CWD="$tmpdir" kexec "$RIG_TARGET" web -- true; rc=$?
assert '[ "$rc" = "2" ]' "and so does exec (exit $rc: $(cli_err))"

# The scratch ssh config fences every host but the rig off with a ProxyCommand
# that fails, so this is a target ssh really cannot reach.
logs nobody@nowhere; rc=$?
assert '[ "$rc" = "3" ]' "logs against a server that does not answer exits 3 (exit $rc)
        stderr: $(cli_err)"
assert '[ "$(cli_out)" = "" ]' "with no output at all (stdout: $(cli_out))"
assert 'grep -qF "cannot reach nobody@nowhere" "$tmpdir/err"' "(stderr: $(cli_err))"
kexec nobody@nowhere web -- true; rc=$?
assert '[ "$rc" = "3" ]' "and so does exec — the connection is made before the command is (exit $rc)"

# --- Leave the rig as it was found, but only on success ---------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $image_web:$version $image_worker:$version $image_web:current $image_worker:current" >/dev/null 2>&1
    rig_clean || fail=1
fi

exit "$fail"
