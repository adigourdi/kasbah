# hosting — the SSH transport: one multiplexed connection per process
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
# ssh_connect, because the control path is not known until this process has a
# directory of its own to put it in.
_SSH_OPTS=()
_SSH_CONNECTED=""
_SSH_TRAP_INSTALLED=""

# The private directory this process's control sockets live in, and the counter
# that names them. Created on the first connect, removed on exit.
_SSH_CTL_DIR=""
_SSH_CTL_SEQ=0

# The longest ControlPath OpenSSH can actually bind. sun_path is 108 bytes, and
# the master listens on `<path>.<16 random chars>` and renames it into place, so
# the usable budget is 108 - 1 - 17 = 90. Measured on OpenSSH 9.6p1 against the
# rig: 90 connects, 91 fails with `unix_listener: path … too long for Unix
# domain socket`.
_SSH_CTL_PATH_MAX=90

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

# Closes this process's master and removes the directory it lived in — the whole
# of what this file leaves on disk, and the whole of the EXIT trap's handler.
_ssh_cleanup() {
    ssh_disconnect
    [ -n "$_SSH_CTL_DIR" ] || return 0
    rm -rf -- "$_SSH_CTL_DIR"
    _SSH_CTL_DIR=""
    return 0
}

# Appends _ssh_cleanup to whatever EXIT trap the caller already had, instead of
# replacing it. A command that renders templates into a temp directory and then
# connects would otherwise never clean that directory up — `trap … EXIT` is
# last-writer-wins, and the library must not be the last writer. `trap -p`
# re-emits the existing handler with its quoting intact, which is what makes it
# safe to eval back.
#
# Callers install their own EXIT trap *before* connecting. Chaining can only
# reach handlers that already exist; one installed afterwards is the last writer
# and drops both halves of the cleanup — the master lingers out its
# ControlPersist, and a 0700 directory holding one dead socket stays in TMPDIR.
# The ordering is free.
_ssh_install_exit_trap() {
    [ -z "$_SSH_TRAP_INSTALLED" ] || return 0
    _SSH_TRAP_INSTALLED=1

    local prev
    prev="$(trap -p EXIT)"
    prev="${prev#trap -- }"
    prev="${prev% EXIT}"
    if [ -z "$prev" ] || [ "$prev" = "''" ]; then
        trap '_ssh_cleanup' EXIT
    else
        eval "trap -- $prev'; _ssh_cleanup' EXIT"
    fi
}

# A directory of this process's own, made once and removed by the EXIT trap.
#
# The socket cannot live at a name another hosting process would compute. `ssh
# -O exit` closes a master *and every session multiplexed over it*, including
# sessions belonging to another process — so a shared path would make teardown a
# remote kill switch. It did: a read-only `hosting server status` exiting at the
# end of its run took a concurrent `hosting server init` down mid-step, which
# then reported a Traefik that was in fact healthy and left the server without
# its marker (docs/phases/02-spine.md). The name was `~/.ssh/cm-%C`, and `%C`
# hashes user, host and port — nothing about the process.
#
# TMPDIR rather than ~/.ssh, because the socket is worth exactly one run and
# nothing here is meant to be found again afterwards — and because the budget is
# 90 bytes, of which `/.ssh/cm-` plus a 40-character `%C` spent 49 before the
# home directory was counted.
_ssh_ctl_dir_create() {
    [ -z "$_SSH_CTL_DIR" ] || return 0

    local tmp="${TMPDIR:-/tmp}"
    [ "$tmp" = / ] || tmp="${tmp%/}"
    [ -n "$tmp" ] || tmp=/tmp

    # Both refused rather than escaped. rsync splits -e on spaces and does no
    # quoting of its own, and ssh reads `%` in a ControlPath as the start of a
    # token — so either character turns the transport into a puzzle several
    # layers from the value that caused it.
    case $tmp in
        *[[:space:]]*) die "TMPDIR ('$tmp') contains whitespace, and the ssh control socket goes there — rsync's -e option is split on spaces (set TMPDIR to a path without any)" ;;
        *%*)           die "TMPDIR ('$tmp') contains a '%', and the ssh control socket goes there — ssh reads '%' in a ControlPath as a token (set TMPDIR to a path without one)" ;;
    esac
    [ -d "$tmp" ] \
        || die "TMPDIR is '$tmp', which is not a directory — the ssh control socket has nowhere to live"

    local dir
    dir="$(mktemp -d "$tmp/hosting-ssh.XXXXXX")" \
        || die "could not create a directory under $tmp for the ssh control socket"
    # mktemp makes it 0700; stated rather than inherited, because that socket is
    # this process's whole authenticated access to the server.
    chmod 0700 "$dir" || die "could not restrict $dir to this user"

    _SSH_CTL_DIR="$dir"
    return 0
}

# The path for one master. Counted rather than hashed: a name derived from the
# target repeats when ssh_connect is called twice for the same one, and a stale
# socket left by a teardown that failed makes the next master fall back to no
# multiplexing at all — silently. A counter cannot repeat, and it spends two of
# the 90 characters where `cm-%C` spends forty-three.
_ssh_ctl_path() {
    local _cp_out="$1" _cp_path

    _SSH_CTL_SEQ=$((_SSH_CTL_SEQ + 1))
    _cp_path="$_SSH_CTL_DIR/m$_SSH_CTL_SEQ"

    [ "${#_cp_path}" -le "$_SSH_CTL_PATH_MAX" ] \
        || die "the ssh control socket path '$_cp_path' is ${#_cp_path} characters, over the $_SSH_CTL_PATH_MAX an ssh master can bind — point TMPDIR at a shorter directory"

    printf -v "$_cp_out" '%s' "$_cp_path"
    return 0
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
    # One master per process, as the header says: a second connect closes the
    # first rather than abandoning it to linger out its ControlPersist. Ordered
    # before the parse, because the teardown needs the target it is tearing down.
    ssh_disconnect

    ssh_target_parse "${1:-}"

    # One socket per process, in a directory this process owns. Neither `~` nor
    # `%d` would do: ssh expands both from the passwd entry rather than from the
    # environment, so a scratch HOME and ssh would disagree about where the
    # socket is.
    local ctl_path
    _ssh_ctl_dir_create
    _ssh_ctl_path ctl_path

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
        -o "ControlPath=$ctl_path"
        -o ControlPersist=60s
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=4
    )

    # Registered before the probe rather than after it, so the directory above
    # is removed even by a run that never gets a connection. The master
    # teardown inside it is guarded by _SSH_CONNECTED, so a failed probe still
    # sends no `-O exit` against a master that was never opened. Not a RETURN
    # trap — bash leaves one installed after the function that set it returns,
    # and it then fires against out-of-scope locals (docs/phases/01-rig.md).
    _ssh_install_exit_trap

    # ssh's own stderr is left alone: "Permission denied (publickey)" and
    # "Name or service not known" are the two things the reader needs, and no
    # wrapper message replaces them.
    if ! ssh -n "${_SSH_OPTS[@]}" "$SSH_TARGET" true; then
        err "cannot reach $SSH_TARGET over ssh (see ssh's own error above)"
        exit "$HOSTING_EXIT_SSH_UNREACHABLE"
    fi
    _SSH_CONNECTED=1
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
# its own, which is why _ssh_ctl_dir_create refuses a TMPDIR with a space in it
# rather than leaving this to break far from the cause.
ssh_rsync() {
    _ssh_require
    local IFS=' '
    rsync -e "ssh ${_SSH_OPTS[*]}" "$@"
}

# Explicit teardown, and idempotent: the EXIT trap ssh_connect installs reaches
# this too (through _ssh_cleanup), so a command that ends its remote work early
# can close the master without arranging for it to happen twice.
#
# `-O exit` closes the master *and every session riding it*. It is aimed at this
# process's own socket and can therefore only ever reach this process's own
# sessions — which is the entire reason the path is private (see
# _ssh_ctl_dir_create).
ssh_disconnect() {
    [ -n "$_SSH_CONNECTED" ] || return 0
    _SSH_CONNECTED=""
    ssh "${_SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
    return 0
}
