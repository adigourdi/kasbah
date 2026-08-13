# hosting — the SSH transport: one multiplexed connection per run
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_SSH_LOADED:-}" ] && return 0
_HOSTING_SSH_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"

# Every remote operation hosting performs goes through this file — no command
# calls ssh, rsync or scp itself. That is what keeps the connection options in
# one place and lets a whole deploy ride a single handshake.
#
# hosting takes no ssh options of its own: it runs `ssh USER@HOST` and inherits
# the user's own ssh config, the way git does. A jump host, a non-standard
# port, a per-host key are all things ssh already knows how to be told.

# Populated by ssh_target_parse.
SSH_USER=""
SSH_HOST=""
SSH_TARGET=""

# The options every ssh, rsync and teardown call of a run shares. Built by
# ssh_connect, because the control path is derived from $HOME.
_SSH_OPTS=()
_SSH_CONNECTED=""
_SSH_TRAP_INSTALLED=""

# Quotes a command word by word for the remote shell. `ssh host cmd args`
# re-joins its arguments with spaces before handing them to a login shell, so
# `docker ps --format {{.Names}} {{.Status}}` arrives as five words with the
# quoting gone; doing it here makes the correct form the default rather than
# every caller's problem.
_ssh_quote() {
    local out="" a
    for a in "$@"; do
        out+=" '${a//\'/\'\\\'\'}'"
    done
    printf '%s' "${out# }"
}

_ssh_require() {
    [ -n "$_SSH_CONNECTED" ] \
        || die "internal: ssh_connect must run before any remote operation"
}

# Appends ssh_disconnect to whatever EXIT trap the caller already had, instead
# of replacing it. A command that renders templates into a temp directory and
# then connects would otherwise never clean that directory up — `trap … EXIT`
# is last-writer-wins, and the library must not be the last writer. `trap -p`
# re-emits the existing handler with its quoting intact, which is what makes it
# safe to eval back.
#
# Callers install their own EXIT trap *before* connecting. Chaining can only
# reach handlers that already exist; one installed afterwards is the last
# writer and drops the master teardown. The leak is bounded by ControlPersist,
# but the ordering is free.
_ssh_install_exit_trap() {
    [ -z "$_SSH_TRAP_INSTALLED" ] || return 0
    _SSH_TRAP_INSTALLED=1

    local prev
    prev="$(trap -p EXIT)"
    prev="${prev#trap -- }"
    prev="${prev% EXIT}"
    if [ -z "$prev" ] || [ "$prev" = "''" ]; then
        trap 'ssh_disconnect' EXIT
    else
        eval "trap -- $prev'; ssh_disconnect' EXIT"
    fi
}

# Splits USER@HOST into SSH_USER / SSH_HOST / SSH_TARGET. The host may be
# anything the user's ssh config resolves, including a bare alias, so the shape
# check is deliberately loose — but a port suffix or an IPv6 literal is
# rejected rather than passed on, because ssh would report `deploy@vps:2222` as
# a failed lookup for a host named "vps:2222" and send the reader hunting DNS.
ssh_target_parse() {
    local target="${1:-}"
    target="${target%$'\r'}"

    [ -n "$target" ] || die "no target given (expected USER@HOST)"
    case $target in
        *@*) ;;
        *)   die "invalid target '$target' (expected USER@HOST — the user hosting deploys as is not optional)" ;;
    esac

    local user="${target%%@*}" host="${target#*@}"
    [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "invalid ssh user '$user' in '$target'"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] \
        || die "invalid ssh host '$host' in '$target' (expected a hostname, ssh alias or IPv4 address — no port, no IPv6 literal)"

    SSH_USER="$user"
    SSH_HOST="$host"
    SSH_TARGET="$user@$host"
}

# Opens the ControlMaster and proves the host answers, once, before any real
# work — so an unreachable VPS costs seconds at the top of a deploy instead of
# a half-finished one, and every later ssh/rsync reuses the socket.
ssh_connect() {
    # One master per run, as the header says: a second connect closes the first
    # rather than abandoning it to linger out its ControlPersist. Ordered before
    # the parse, because the teardown needs the target it is tearing down.
    ssh_disconnect

    ssh_target_parse "${1:-}"

    [ -n "${HOME:-}" ] || die "HOME is not set — the ssh control socket has nowhere to live"

    # %C hashes user+host+port into a fixed-length name. A literal %r@%h:%p
    # overruns the ~104-byte limit on a unix socket path for a long hostname,
    # and multiplexing then fails silently. $HOME is spelled out rather than
    # left as `~`: ssh expands a leading tilde from the passwd entry, not from
    # the environment, so under a scratch HOME the two point at different
    # directories and the socket lands in the wrong one.
    mkdir -p -m 0700 "$HOME/.ssh" \
        || die "could not create $HOME/.ssh for the ssh control socket"

    # ConnectTimeout goes on the command line so it outranks whatever the
    # user's config says: an unreachable host must fail in seconds, not in the
    # kernel's TCP default. No BatchMode — a passphrase-protected key with an
    # agent is an ordinary setup, and hosting must not be what breaks it.
    #
    # ConnectTimeout bounds setting the connection up, not using it
    # (docs/phases/01-rig.md): a session that stalls once established — a
    # wedged remote command, a laptop that changes network mid-deploy — would
    # otherwise hang until someone noticed. The keepalives bound that at
    # ~60 s of silence *from the transport*, which a slow-but-alive `docker
    # pull` never trips, because the far end keeps answering at the protocol
    # level while it works.
    _SSH_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=$HOME/.ssh/cm-%C"
        -o ControlPersist=60s
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=4
    )

    # ssh's own stderr is left alone: "Permission denied (publickey)" and
    # "Name or service not known" are the two things the reader needs, and no
    # wrapper message replaces them.
    if ! ssh -n "${_SSH_OPTS[@]}" "$SSH_TARGET" true; then
        err "cannot reach $SSH_TARGET over ssh (see ssh's own error above)"
        exit "$HOSTING_EXIT_SSH_UNREACHABLE"
    fi
    _SSH_CONNECTED=1

    # Registering teardown here is what makes it impossible to forget: a run
    # that dies half way still takes its master down. Not a RETURN trap —
    # bash leaves one installed after the function that set it returns, and it
    # then fires against out-of-scope locals (docs/phases/01-rig.md).
    _ssh_install_exit_trap
}

# ssh_run <word>... — one remote command, quoted as given.
#
# Words, not shell syntax: every argument is quoted, so `ssh_run 'a | b'` asks
# the far side for a command whose name is "a | b". Pipelines, redirection,
# `&&` and variable expansion belong in ssh_script, which is a shell script by
# construction. That is the trade — a caller cannot forget to quote a value,
# and in exchange it cannot smuggle in syntax either.
#
# stdin is closed: a caller looping over a list would otherwise watch the
# remote command swallow it. Feeding data to the far side is ssh_script's job.
ssh_run() {
    _ssh_require
    ssh -n "${_SSH_OPTS[@]}" "$SSH_TARGET" "$(_ssh_quote "$@")"
}

# ssh_script [arg]... — run a bash script read from stdin, with the arguments
# as its $1... The heredoc is the ergonomic path, and a quoted delimiter keeps
# the payload verbatim all the way to the far side:
#
#     ssh_script "$name" <<'REMOTE'
#     set -euo pipefail
#     …
#     REMOTE
ssh_script() {
    _ssh_require
    ssh "${_SSH_OPTS[@]}" "$SSH_TARGET" "$(_ssh_quote bash -s -- "$@")"
}

# rsync over the same master. rsync splits -e on spaces and does no quoting of
# its own, so a $HOME containing spaces breaks this — the same accepted limit
# the rig's `rsync -e "ssh -F …"` recipe carries.
ssh_rsync() {
    _ssh_require
    local IFS=' '
    rsync -e "ssh ${_SSH_OPTS[*]}" "$@"
}

# Explicit teardown, and idempotent: the EXIT trap ssh_connect installs calls
# this too, so a command that ends its remote work early can close the master
# without arranging for it to happen twice.
ssh_disconnect() {
    [ -n "$_SSH_CONNECTED" ] || return 0
    _SSH_CONNECTED=""
    ssh "${_SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
    return 0
}
