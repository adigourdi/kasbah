# kasbah — day-2 operations over the project's compose stack: logs, exec
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_OPS_LOADED:-}" ] && return 0
_KASBAH_OPS_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"

# Two thin wrappers around one `docker compose` on the far side (docs/cli.md →
# kasbah logs, kasbah exec). Both are read-only as far as the *server's* state
# goes — nothing here rsyncs, renders or restarts anything — and both write
# exactly one thing on this side: `last_server` in the state file
# (docs/project-manifest.md → write rule).
#
# They share three things, which is why they are one file:
#
#   * the positional-ambiguity rule. `logs` and `exec` both have a leading
#     optional USER@HOST followed by a service name, and there is no way to tell
#     `kasbah logs web` from `kasbah logs deploy@vps` by position. docs/cli.md
#     states the rule for `exec` — an argument carrying an `@` is the server —
#     and `logs` has the identical problem, so the rule is written once here
#     (_ops_classify_arg) and both commands call it. It is the same rule
#     lib/deploy.sh's _deploy_classify_arg applies to its server/version pair.
#   * where the stack is. The apps path comes from the server's own marker
#     (lib/marker.sh), never from a flag. `server init` takes `--apps-path`
#     because it is the command that *establishes* the path and writes the
#     pointer; among the commands that only ever read one, `server status` is
#     the sole holder of the flag, and it holds it as the escape hatch for a
#     server whose pointer is gone. Everything else — these two included —
#     discovers it, because a value repeated on every invocation is a belief
#     each caller holds separately (docs/cli.md).
#   * how compose is named. `-p <manifest name>`, exactly as
#     templates/remote-deploy.sh's `dc()` does it, because `name:` in the
#     compose file is the weakest source of the project name and
#     COMPOSE_PROJECT_NAME in the server's login shell outranks it.

# The server, the service, and each command's own flags. Reset by the parser on
# every run so a second call in one process cannot inherit the first's.
_OPS_TARGET=""
_OPS_SERVICE=""
_OPS_FOLLOW=no
_OPS_TAIL=100
# `--` and everything after it: exec's inner command, verbatim.
_OPS_DDASH=no
_OPS_CMD=()
# `docker compose -f <dir>/compose.yml -p <name>`, built once the server has
# said where its apps path is. An array, because every word of it is quoted for
# the far side one at a time (lib/ssh.sh → _ssh_quote).
_OPS_DC=()

# --- Usage ------------------------------------------------------------------------

_ops_usage() {
    case "$1" in
        logs)
            cat <<EOF
Usage: kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]

\`docker compose logs\` for this project on a server, run against
<apps>/<name>/compose.yml as \`docker compose -p <name>\`. Run from the project
root. USER@HOST defaults to the last server this project talked to
(.kasbah/state.json); with SERVICE omitted, every service in the project.

An argument carrying an '@' is the server and anything else is the service —
the same rule \`kasbah exec\` uses, because both commands take the two in that
order and neither can tell them apart by position.

Flags:
  -f           follow, until interrupted
  --tail=N     lines of history per service (default 100; --tail=all for all)

The output is compose's own, unaltered, on stdout: no terminal is allocated for
it, so \`kasbah logs | grep …\` gets the lines rather than a pty's CRs.

Reads the server and writes nothing to it. See docs/cli.md.
EOF
            ;;
        exec)
            cat <<EOF
Usage: kasbah exec [USER@HOST] SERVICE -- CMD…

\`docker compose exec SERVICE CMD…\` on a server, against
<apps>/<name>/compose.yml as \`docker compose -p <name>\`. Run from the project
root. USER@HOST defaults to the last server this project talked to
(.kasbah/state.json).

The '--' is mandatory: it is what makes a flag in CMD belong to CMD rather than
to kasbah, so \`kasbah exec web -- ls -la\` lists a directory instead of being
refused for an unknown '-la'.

SERVICE is required. An argument carrying an '@' is the server, so a service
name may not contain one.

A terminal is allocated only when this side has one at both ends — stdin and
stdout both a tty — so \`kasbah exec db -- pg_dump …\` redirected to a file
gets bytes rather than a pty's CRs. Without one, \`docker compose exec -T\` runs
the command with its stdin closed; feeding data to it is not something this
command does.

CMD's own exit status is this command's exit status — kasbah adds no verdict of
its own to it (docs/cli.md → exit codes).

See docs/cli.md.
EOF
            ;;
    esac
}

# --- Command line -----------------------------------------------------------------

# The rule docs/cli.md states for `exec` and `logs` needs just as much: an
# argument carrying an '@' is USER@HOST, anything else is the service. Written
# once and called from both, rather than twice — two copies of a disambiguation
# rule is how one command starts treating `deploy@vps` as a service name.
_ops_classify_arg() {
    local _ca_cmd="$1" _ca_arg="${2%$'\r'}"

    case $_ca_arg in
        *@*)
            [ -z "$_OPS_TARGET" ] \
                || die "$_ca_cmd: two servers given ('$_OPS_TARGET' and '$_ca_arg') — one run goes to one server"
            _OPS_TARGET="$_ca_arg" ;;
        *)
            # For `exec`, a second bare word is almost never a second service:
            # it is the command the operator meant to put after `--`. Saying
            # "two services given" there would be technically true and send them
            # looking for the wrong mistake, so exec answers with the separator.
            if [ -n "$_OPS_SERVICE" ] && [ "$_ca_cmd" = exec ]; then
                err "exec: '$_ca_arg' comes after the service '$_OPS_SERVICE', and there is no '--' between them"
                err_cont "the command to run goes after '--':"
                err_cont "  kasbah exec ${_OPS_TARGET:+$_OPS_TARGET }$_OPS_SERVICE -- $_ca_arg …"
                err_cont "without it kasbah would have to guess which of its own flags are yours."
                exit 1
            fi
            [ -z "$_OPS_SERVICE" ] \
                || die "$_ca_cmd: two services given ('$_OPS_SERVICE' and '$_ca_arg') — kasbah will not choose between them"
            _OPS_SERVICE="$_ca_arg" ;;
    esac
    return 0
}

# `--tail` reaches `docker compose logs` as it was written, so it is judged
# here: a count, or compose's own `all`. Anything else would arrive on the far
# side as a compose usage error several layers from the flag that caused it.
_ops_check_tail() {
    local _ct_v="${1%$'\r'}"

    case $_ct_v in
        all) return 0 ;;
        ''|*[!0-9]*)
            die "logs: --tail='$_ct_v' is not a number of lines — pass a count (\`--tail=50\`) or \`--tail=all\`" ;;
    esac
    return 0
}

# A flag exec does not know, answered by where the operator most likely meant
# to put it. Once a service has been named, everything left belongs to the
# command — and the command lives after `--`.
_ops_exec_unknown_flag() {
    local _uf_flag="${1%%=*}"

    err "exec: unknown flag '$_uf_flag'"
    if [ -n "$_OPS_SERVICE" ]; then
        err_cont "if it belongs to the command you want to run, it goes after '--':"
        err_cont "  kasbah exec ${_OPS_TARGET:+$_OPS_TARGET }$_OPS_SERVICE -- <cmd> $1 …"
    else
        err_cont "exec takes USER@HOST, SERVICE, then '--' and the command to run:"
        err_cont "  kasbah exec [USER@HOST] SERVICE -- CMD…"
    fi
    exit 1
}

_ops_parse_args() {
    local cmd="$1"; shift

    _OPS_TARGET=""
    _OPS_SERVICE=""
    _OPS_FOLLOW=no
    _OPS_TAIL=100
    _OPS_DDASH=no
    _OPS_CMD=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _ops_usage "$cmd"; exit 0 ;;
            --)
                [ "$cmd" = exec ] \
                    || die "logs: '--' separates kasbah's flags from a command to run, and logs runs none (\`kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]\`)"
                _OPS_DDASH=yes
                shift
                # Verbatim, including anything that looks like a flag: that is
                # the whole point of the separator.
                _OPS_CMD=("$@")
                break ;;
            -f|-f=*|--tail|--tail=*)
                [ "$cmd" = logs ] || _ops_exec_unknown_flag "$1"
                case "$1" in
                    -f) _OPS_FOLLOW=yes ;;
                    -f=*) die "logs: -f takes no value — pass it on its own (\`kasbah logs USER@HOST -f\`)" ;;
                    --tail) die "logs: --tail takes its value with '=' — \`kasbah logs --tail=100\`" ;;
                    --tail=*)
                        _OPS_TAIL="${1#*=}"
                        _OPS_TAIL="${_OPS_TAIL%$'\r'}"
                        _ops_check_tail "$_OPS_TAIL" ;;
                esac ;;
            -*)
                case "$cmd" in
                    logs) die "logs: unknown flag '${1%%=*}' (logs takes USER@HOST, SERVICE, -f and --tail=N)" ;;
                    *)    _ops_exec_unknown_flag "$1" ;;
                esac ;;
            *) _ops_classify_arg "$cmd" "$1" ;;
        esac
        shift
    done
    return 0
}

# Everything `exec` needs that the loop above cannot refuse as it goes: the
# separator and the two things it separates. Checked before the manifest is
# read and long before ssh, so a mistyped command line costs a sentence rather
# than a round trip.
_ops_require_exec_args() {
    if [ "$_OPS_DDASH" != yes ]; then
        err "exec: no '--' in the arguments, and the command to run goes after it"
        err_cont "\`kasbah exec [USER@HOST] SERVICE -- CMD…\`, for example:"
        err_cont "  kasbah exec ${_OPS_SERVICE:-web} -- sh -c 'ls -la /srv'"
        err_cont "the '--' is mandatory because it is what makes a flag in CMD belong to CMD"
        err_cont "rather than to kasbah (docs/cli.md → kasbah exec)."
        exit 1
    fi
    if [ -z "$_OPS_SERVICE" ]; then
        err "exec: no service given — \`kasbah exec [USER@HOST] SERVICE -- CMD…\`"
        err_cont "the service is the one \`docker compose exec\` runs the command in, named as"
        err_cont "compose.prod.yml spells it. An argument carrying an '@' is read as the server,"
        err_cont "so a service name cannot contain one."
        exit 1
    fi
    if [ "${#_OPS_CMD[@]}" -eq 0 ]; then
        err "exec: nothing after the '--' — there is no command to run"
        err_cont "\`kasbah exec $_OPS_SERVICE -- sh -c 'ls -la'\`. kasbah runs no default shell:"
        err_cont "which one an image has is the image's business, not kasbah's."
        exit 1
    fi
    return 0
}

# --- The server -------------------------------------------------------------------

# The positional, else the server this project last talked to. With neither
# there is nothing to guess at (docs/project-manifest.md). lib/env_cmd.sh keeps
# its own copy of this for the same reason this one does: sourcing lib/deploy.sh
# to reach _deploy_resolve_target would drag the whole build/ship/rollback
# surface into a command that reads logs.
_ops_resolve_target() {
    local _rt_cmd="$1" _rt_stored=""

    [ -z "$_OPS_TARGET" ] || return 0

    state_get last_server _rt_stored
    if [ -z "$_rt_stored" ] || [ "$_rt_stored" = null ]; then
        err "$_rt_cmd: no server given, and this project has never deployed to one"
        err_cont "pass it once — \`kasbah $_rt_cmd user@vps …\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        exit 1
    fi
    _OPS_TARGET="$_rt_stored"
    return 0
}

# Connect, read the marker, and leave `docker compose -f … -p …` in _OPS_DC for
# the caller to append its verb to.
#
# `-f <dir>/compose.yml` rather than a remote `cd`: ssh_run quotes every word,
# so there is no shell on the far side to `cd` in — and there does not need to
# be one, because compose takes the *project directory* from the base compose
# file's own directory, which is what makes `<dir>/.env` load exactly as it does
# for templates/remote-deploy.sh's `dc()`. The file is at that path by contract:
# lib/deploy.sh refuses a manifest whose sync: list does not land on
# `compose.yml`, because the server runs compose on that and nothing else.
_ops_compose_cmd() {
    local _cc_cmd="$1" _cc_dir

    manifest_require
    _ops_resolve_target "$_cc_cmd"

    ssh_connect "$_OPS_TARGET"
    marker_read "$_OPS_TARGET"
    _cc_dir="$MARKER_APPS_PATH/$MANIFEST_NAME"

    _OPS_DC=(docker compose -f "$_cc_dir/compose.yml" -p "$MANIFEST_NAME")
    return 0
}

# --- logs ---------------------------------------------------------------------------

# No pty, ever — the opposite answer from `exec` below, and for a reason that
# does not depend on who is watching. `ssh -t` cooks the far side's output
# through a terminal line discipline, so every `\n` arrives as `\r\n`; that is
# the trap templates/remote-deploy.sh names for its hooks, and a log is data.
# There is no input to carry either, `-f` included: following a log needs no
# keystroke, only an interrupt, and SIGINT reaches ssh through the terminal's
# foreground process group without a pty being involved.
#
# The cost is kasbah's own, and it accumulates. A session with no pty is not
# hung up when its client dies, so every interrupted `logs -f` leaves one
# `docker compose logs -f` resident on the server, holding an open stream from
# dockerd, until its next write to a now-closed pipe — for a quiet service,
# never (>80 s observed on the rig, and nothing bounds it). One per interrupted
# follow, on a box picked for being small. That is a consequence of the choice
# made here, not a fact about ssh, and docs/cli.md states it where an operator
# will meet it.
#
# The alternatives, and why none of them: a pty hangs the session up and costs
# CRs in every log anyone ever pipes; a pty guarded on `[ -t 1 ]` buys the
# cleanup back for the interactive case only, and makes one command behave two
# ways for the same words — and under `-t` the interrupt is delivered to the
# *remote* process rather than to this one, which is a different thing to
# reason about for no gain the CR cost does not already outweigh. An INT trap
# firing a remote `pkill` is ten lines and would work, and is
# the worst of the three: lib/ssh.sh's own header records a read-only `server
# status` tearing down a concurrent `server init`, and kill-by-pattern on a
# shared VPS is that mistake automated.
cmd_logs() {
    local rc=0

    _ops_parse_args logs "$@"
    _ops_compose_cmd logs

    _OPS_DC+=(logs "--tail=$_OPS_TAIL")
    [ "$_OPS_FOLLOW" = no ] || _OPS_DC+=(-f)
    [ -z "$_OPS_SERVICE" ] || _OPS_DC+=("$_OPS_SERVICE")

    ssh_run "${_OPS_DC[@]}" || rc=$?
    ssh_disconnect

    # 255 is the ordinary end of `kasbah logs | head`, and it is ssh's number,
    # not a signal: OpenSSH ignores SIGPIPE — it has a socket to look after —
    # so a write into a closed stdout is a write error it turns into
    # `fatal(): exit 255`. Measured against the rig, three ways:
    # `ssh -n rig 'seq 1 500000' | head -3` → 255, `| grep -q 1` → 255, and
    # `kasbah logs -f … | head -3` → 255. **Not 141**, which is what a producer
    # that dies of SIGPIPE would give and what this looks like it should be.
    # 130 is the same shape from the other direction: interrupted.
    #
    # Treating either as an error printed a paragraph blaming compose, with
    # `(see above)` pointing at nothing, on the exact use docs/cli.md
    # advertises. This is CLAUDE.md's SIGPIPE rule arriving at the CLI boundary
    # instead of inside a pipeline.
    #
    # 255 is also how ssh reports a session that broke for a real reason — a
    # link lost mid-stream. Swallowing kasbah's paragraph does not swallow the
    # diagnosis: ssh's own stderr is passed through untouched, which is
    # lib/ssh.sh's stated rule for exactly this ("no wrapper message replaces
    # it"). What is dropped is a kasbah sentence that would have been wrong far
    # more often than right — `ssh_connect` proved this host answers seconds
    # ago, so the common cause here is a reader that stopped reading.
    #
    # The status is passed through rather than flattened to 0. It is the honest
    # answer: the log was cut short, so a caller under `set -o pipefail` — or
    # reading `$?` at all — must not be told the whole of it arrived. `git log |
    # head` does the same with its own number. That also keeps `logs` and `exec`
    # coherent: `exec` already returns 255 here, having passed its command's
    # status through untouched.
    #
    # Anything else is a real failure. Unlike `exec`, the whole command line
    # here is kasbah's own — the operator contributed a service name and a line
    # count — so it is kasbah's to report, and it exits 1 like every other step
    # that could not do what it was asked. The statuses above are the exception,
    # and they are not a verdict about the logs at all — they say the reader
    # stopped, not that compose did (docs/cli.md → exit codes).
    case "$rc" in
        0|255|130) ;;
        *)
            err "could not read the logs of $MANIFEST_NAME on $_OPS_TARGET"
            err_cont "\`docker compose -p $MANIFEST_NAME logs\` exited $rc in $MARKER_APPS_PATH/$MANIFEST_NAME (see above)."
            [ -z "$_OPS_SERVICE" ] \
                || err_cont "'$_OPS_SERVICE' is the service as compose.prod.yml spells it — \`kasbah logs $_OPS_TARGET\` shows every one."
            exit 1 ;;
    esac

    # Recorded on 255 and 130 as well as on 0: the server was reached and it
    # answered, which is the whole of what last_server remembers. The state file
    # is a file, so writing it does not depend on the stdout that just went away.
    state_record last_server "$_OPS_TARGET"
    exit "$rc"
}

# --- exec ---------------------------------------------------------------------------

# The terminal, per invocation rather than per command, because both answers are
# right for different uses of the same verb: a shell wants a pty and a dump
# redirected into a file must not have one.
#
# Both `-t 0` and `-t 1` are required, the same pair lib/env_cmd.sh's
# _env_run_setup checks. stdin alone is not enough: run from a terminal with
# stdout redirected — `kasbah exec db -- pg_dump … > dump.sql` — a pty would put
# a CR before every LF in the file. So the pty is asked for only when there is
# nothing downstream to corrupt.
#
# Neither branch refuses: unlike the .env generator, `docker compose exec` has
# no prompt that would hang unanswered. Without a terminal it runs under `-T`,
# which is compose's own spelling of "no tty" (and is not a `docker exec` flag
# at all — see templates/remote-deploy.sh's hook runner, which uses the other
# one). ssh_run closes stdin with `-n` there, so a command that reads stdin sees
# EOF rather than swallowing the caller's; docs/cli.md promises no stdin path
# and this is why.
#
# `-T` is stated rather than relied on. Measured against the rig's docker
# (compose v2): dropping it changes nothing, because compose already declines to
# allocate a tty when its own stdin is not one — so the rig suite cannot tell the
# two apart and only tests/ops_test.sh pins the flag. It stays because the
# intent belongs in the command line rather than in a version's default, and
# because compose has not always had that default.
# Somebody piped data in, and it is going nowhere. `ssh -n` closes stdin, so the
# remote command reads EOF and usually exits 0 — `echo x | kasbah exec web -- cat`
# prints nothing and looks like it worked, which is the one shape this project
# refuses to leave silent (CLAUDE.md → interactive, never assume).
#
# A warning and not a refusal: `kasbah exec … < /dev/null` is an ordinary
# scripted call, and a hard failure would break it. So the test is what stdin
# *is* — a pipe or a regular file is somebody feeding it, a character device
# (/dev/null, a tty) is not.
_ops_warn_dropped_stdin() {
    if [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
        warn "exec: stdin is not forwarded, and this one is a pipe or a file — the command will read EOF"
        warn "  with no terminal here, exec runs \`docker compose exec -T\` over \`ssh -n\`, which"
        warn "  closes stdin (docs/cli.md → kasbah exec). Put the data inside the command instead:"
        warn "  kasbah exec $_OPS_SERVICE -- sh -c 'printf %s \"\$DATA\" | ${_OPS_CMD[0]} …'"
    fi
    return 0
}

_ops_exec_run() {
    local _er_rc=0

    if [ -t 0 ] && [ -t 1 ]; then
        ssh_run_tty "${_OPS_DC[@]}" exec "$_OPS_SERVICE" "${_OPS_CMD[@]}" || _er_rc=$?
    else
        _ops_warn_dropped_stdin
        ssh_run "${_OPS_DC[@]}" exec -T "$_OPS_SERVICE" "${_OPS_CMD[@]}" || _er_rc=$?
    fi
    return "$_er_rc"
}

cmd_exec() {
    local rc=0

    _ops_parse_args exec "$@"
    _ops_require_exec_args
    _ops_compose_cmd exec

    _ops_exec_run || rc=$?
    ssh_disconnect

    # Written whatever the command answered, and that is the point: kasbah's own
    # work — resolve the server, find the stack, run what was asked — succeeded
    # the moment the command ran at all. `kasbah exec web -- test -f /srv/x`
    # returning 1 is an answer about the container, not a failed run, and a
    # project that had to re-type USER@HOST after every such answer would be
    # remembering the wrong thing (docs/cli.md → Project commands).
    state_record last_server "$_OPS_TARGET"

    # CMD's status, verbatim. The alternative — collapsing it to 0 or 1 — makes
    # a wrapper that lies about the command it exists to run, and every layer
    # under it (ssh, docker compose, the command itself) already passes it
    # through. The cost is that exec is the one kasbah command whose exit code
    # is not from docs/cli.md's list, which is why that list says so.
    exit "$rc"
}
