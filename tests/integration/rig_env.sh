# Shared environment for the rig-driven suites. Sourced, never executed.
#
# ## How kasbah is pointed at the rig
#
# kasbah takes no ssh-options flag: it runs `ssh USER@HOST` and inherits the
# user's own ssh config, the way git does. The rig answers only through the
# generated tests/rig/ssh_config (loopback, port 5022, per-checkout key), which
# is the single copy of that contract — suites Include it, never restate it.
#
# Handing it to kasbah takes two pieces, because $HOME is not enough on its
# own. Measured on OpenSSH 9.6p1: with HOME pointed at a scratch directory,
# `ssh -G rig` still read /home/<user>/.ssh/config and ignored the scratch one
# — ssh takes the per-user config path from the passwd entry, not from the
# environment. So:
#
#   * A scratch HOME to hold the config the wrapper below names, and to keep
#     `known_hosts` and anything else ssh writes out of the owner's. The control
#     socket is not among them: lib/ssh.sh puts that in a private directory
#     under TMPDIR that it removes on exit, so that no two kasbah processes can
#     compute the same path and tear down each other's master.
#   * A one-line `ssh` wrapper first on PATH, adding `-F "$HOME/.ssh/config"`.
#     That is the only interposition point left that does not put a flag on
#     kasbah, and it is honest: the file it names is the scratch HOME's own
#     config, which Includes the rig contract and nothing else.
#
# `-F` makes ssh skip the per-user and system-wide config files entirely, so
# the repo owner's real ~/.ssh/config is neither read nor written and no `Host`
# block in it applies. It does **not** isolate the rest of ~/.ssh: an alias the
# scratch config does not cover still falls back to the built-in defaults,
# which tilde-expand `~/.ssh/id_*` and `~/.ssh/known_hosts` from the passwd
# entry — the same trap as the ControlPath above, and the reason `ssh -F
# tests/rig/ssh_config -G <anything else>` offers the owner's real keys. So the
# scratch config also carries a `Host * !rig` fence that makes every host but
# the rig unconnectable, with no key and no agent. Measured: under the fence,
# the rig's own published endpoint reached by IP — a listener that genuinely
# answers ssh — dies in the ProxyCommand instead. ssh_test.sh asserts all of
# it against ssh's own output rather than trusting this paragraph.

[ -n "${_KASBAH_RIG_ENV_LOADED:-}" ] && return 0
_KASBAH_RIG_ENV_LOADED=1

RIG_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$RIG_REPO_DIR/tests/cli.sh"
. "$RIG_REPO_DIR/tests/integration/rig_files.sh"
RIG_SSH_CONFIG="$RIG_REPO_DIR/tests/rig/ssh_config"
# A constant, deliberately not an environment knob. It is the only thing that
# decides where rig_clean's payload lands, and an overridable one turns
# `RIG_SSH_ALIAS=<anything the owner can ssh to> ./test.sh` into a remote wipe.
# A suite that needs an unreachable rig points RIG_SSH_CONFIG at a stand-in
# config whose own `Host rig` block goes nowhere.
RIG_SSH_ALIAS=rig
RIG_SSH_USER=stevedore
RIG_TARGET="$RIG_SSH_USER@$RIG_SSH_ALIAS"

# The far side of the same guard: /etc/kasbah-rig is baked into the rig image
# (tests/rig/Dockerfile) and holds exactly this string. The cleanup payload
# checks it on the host that actually answered, so the protection survives any
# mistake made on this side.
RIG_MARKER_FILE=/etc/kasbah-rig
RIG_MARKER_VALUE=kasbah-rig-disposable-fake-vps
# The payload's own exit status for "this is not the rig" — distinct from a
# cleanup that ran and failed.
RIG_NOT_THE_RIG=9

# ssh_config's ConnectTimeout bounds connection setup only; an established
# session that stalls is unbounded (docs/phases/01-rig.md). Everything remote
# here is wrapped in timeout(1) so a wedged rig fails a suite instead of
# hanging it.
RIG_PROBE_TIMEOUT="${RIG_PROBE_TIMEOUT:-20}"
RIG_WORK_TIMEOUT="${RIG_WORK_TIMEOUT:-120}"

RIG_HOME=""
RIG_SHIM_DIR=""

# The rig's backup harness: two restic/rest-server endpoints over one store, one
# started `--append-only` (what a VPS is given) and one not (what the operator
# prunes with). `rig.sh up` writes the addresses and credentials here after both
# answer, and `rig.sh down` removes the file, so its absence means "no usable
# harness" and never "stale credentials". Absent is not fatal on its own: only a
# suite that asks for a backup endpoint needs one.
#
# Defines: RIG_BACKUP_{URL,USER,PASSWORD,REPO_BASE} and the ADMIN_ four.
# REPO_BASE is a restic `rest:` URL with the credential in it and a trailing
# slash, so `$RIG_BACKUP_REPO_BASE<repo>` is a repository — kasbah never parses
# it (08-keep.md, D5).
RIG_BACKUP_ENV="$RIG_REPO_DIR/tests/rig/backup_env.sh"
# shellcheck source=/dev/null
[ ! -f "$RIG_BACKUP_ENV" ] || . "$RIG_BACKUP_ENV"

# Pinned, like every other image a suite depends on: restic's own output is what
# the append-only assertion is read from, and a version moving underneath it is
# a failure nobody would diagnose. Backups run as a container per 08-keep.md D1,
# so this is also the shape production uses.
RIG_RESTIC_IMAGE="${RIG_RESTIC_IMAGE:-restic/restic:0.18.0}"
RIG_RESTIC_PASSWORD="${RIG_RESTIC_PASSWORD:-rig-repo-password}"

# Builds the scratch HOME and the ssh wrapper under a directory the caller
# owns, so the suite's own cleanup removes them.
rig_env_init() {
    local root="$1" real_ssh tmp
    real_ssh="$(command -v ssh)" || return 1

    RIG_HOME="$root/home"
    RIG_SHIM_DIR="$root/shim"
    mkdir -p "$RIG_HOME/.ssh" "$RIG_SHIM_DIR" || return 1
    chmod 0700 "$RIG_HOME/.ssh" || return 1

    # Rendered and renamed rather than truncated in place: these are files
    # another process reads, and a reader that catches the empty window sees a
    # config with no rig in it and blames DNS (docs/phases/01-rig.md).
    tmp="$(mktemp "$RIG_HOME/.ssh/config.XXXXXX")" || return 1
    {
        printf '# Generated by tests/integration/rig_env.sh for this run only.\n'
        printf '# The rig contract lives in one file and is included, never copied.\n'
        printf 'Include %s\n' "$RIG_SSH_CONFIG"
        printf '\n'
        printf '# Everything that is not the rig is unreachable from a suite: no proxy\n'
        printf '# to connect through, no key, no agent. Without this, an alias the\n'
        printf '# Include does not cover falls through to the built-in defaults and\n'
        printf "# offers the owner's real ~/.ssh keys to a real host.\n"
        printf '#\n'
        printf '# `Host * !rig`, not `Match host *,!rig` — the Match form looks\n'
        printf "# equivalent and breaks the rig too, because its IdentityFile appends\n"
        printf "# to the rig's list instead of replacing it (measured: rig login rc 255).\n"
        printf 'Host * !%s\n' "$RIG_SSH_ALIAS"
        printf '    ProxyCommand /bin/false\n'
        printf '    IdentityFile /dev/null\n'
        printf '    IdentityAgent none\n'
        printf '    BatchMode yes\n'
    } > "$tmp" || return 1
    chmod 0600 "$tmp" && mv -f "$tmp" "$RIG_HOME/.ssh/config" || return 1

    tmp="$(mktemp "$RIG_SHIM_DIR/ssh.XXXXXX")" || return 1
    printf '#!/usr/bin/env bash\n# See rig_env.sh: ssh reads its per-user config from the passwd entry,\n# not from $HOME, so the scratch config has to be named explicitly.\nexec %q -F "$HOME/.ssh/config" "$@"\n' \
        "$real_ssh" > "$tmp" || return 1
    chmod 0755 "$tmp" && mv -f "$tmp" "$RIG_SHIM_DIR/ssh" || return 1
}

# kasbah — the binary under test (tests/cli.sh) — under the scratch HOME and
# the wrapper.
kasbah_cli() {
    env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        "$KASBAH_BIN" "$@"
}

# Nothing below is ever handed the terminal as stdin.
#
# `timeout` runs its child in a process group of its own so it can signal the
# whole group. That group is not the foreground group of the terminal, so a
# child that reads stdin gets SIGTTIN from the kernel and *stops* — and a
# stopped process never runs long enough to handle the SIGTERM timeout then
# sends, which turns a bounded wait into a permanent hang. Measured under
# `script -qec 'KASBAH_RIG_TESTS=1 ./test.sh'`, which is how the suite is run
# in a real terminal: integration/server_init_test.sh stopped dead at its first
# reachability probe, ssh in state T and timeout in sigsuspend, still there ten
# minutes later. With stdin piped — the way CI runs it — the same call returns
# instantly, which is why it survived three units.
#
# Redirected here rather than at every call site: a caller that really does
# feed the far side feeds it from a heredoc, a pipe or a file, never from a
# tty, so the guard cannot take a payload away from one.

# The same environment for a script that drives the libraries directly — the
# only way to exercise lib/ssh.sh until a command uses it. Bounded, because a
# driver that hangs would hang the suite.
rig_env_bash() {
    if [ -t 0 ]; then
        timeout "$RIG_WORK_TIMEOUT" \
            env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
                KASBAH_LIB_DIR="$RIG_REPO_DIR/lib" bash "$@" </dev/null
    else
        timeout "$RIG_WORK_TIMEOUT" \
            env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
                KASBAH_LIB_DIR="$RIG_REPO_DIR/lib" bash "$@"
    fi
}

# Suite-side access to the rig, straight down the rig's own contract: what a
# test asserts about the rig must not depend on the wrapper it is testing.
#
# Spelled as two branches rather than one redirect from /dev/stdin: reopening
# the caller's stdin through /proc is a subtlety this file does not need, and
# the thing being guarded against is a hang that costs a suite run to notice.
rig_ssh() {
    if [ -t 0 ]; then
        timeout "$RIG_WORK_TIMEOUT" ssh -F "$RIG_SSH_CONFIG" "$RIG_SSH_ALIAS" "$@" </dev/null
    else
        timeout "$RIG_WORK_TIMEOUT" ssh -F "$RIG_SSH_CONFIG" "$RIG_SSH_ALIAS" "$@"
    fi
}

# The env setup an operator would run on the server by hand, answered by EOF so
# every default is taken: the server binary's own `remote setup-env setup`,
# found from the project directory, which is always <apps>/<project>.
rig_setup_env() {
    local dir="$1"
    rig_ssh "${dir%/*}/.kasbah/bin/kasbah remote setup-env setup $dir" </dev/null
}

# -n rather than the redirect above: a probe has no payload to protect, and
# ssh's own flag says so at the point of use.
rig_reachable() {
    timeout "$RIG_PROBE_TIMEOUT" ssh -n -F "$RIG_SSH_CONFIG" "$RIG_SSH_ALIAS" true >/dev/null 2>&1
}

# Both backup endpoints, probed from the rig itself in one session. Two answers
# each, because neither alone says anything: 404 to the real credential on a
# path that is no repository (an empty htpasswd would answer 401), and 401 to a
# bogus one — a server started `--no-auth` answers 404 to any credential at all.
rig_backup_ready() {
    [ -n "${RIG_BACKUP_REPO_BASE:-}" ] && [ -n "${RIG_BACKUP_ADMIN_REPO_BASE:-}" ] || return 1
    local codes probe='curl -s -o /dev/null -w "%{http_code} " --max-time 5 -u' path=kasbah-rig-readiness/config
    codes=$(rig_ssh "$probe '$RIG_BACKUP_USER:$RIG_BACKUP_PASSWORD' '$RIG_BACKUP_URL$path'; \
                     $probe 'kasbah-rig-no-such-user:wrong' '$RIG_BACKUP_URL$path'; \
                     $probe '$RIG_BACKUP_ADMIN_USER:$RIG_BACKUP_ADMIN_PASSWORD' '$RIG_BACKUP_ADMIN_URL$path'; \
                     $probe 'kasbah-rig-no-such-user:wrong' '$RIG_BACKUP_ADMIN_URL$path'" 2>/dev/null) || return 1
    [ "${codes//$'\r'/}" = "404 401 404 401 " ]
}

# restic the way a VPS runs it (08-keep.md, D1): a container on the rig's *own*
# daemon, two network namespaces from the endpoint. $1 is the repository, the
# rest are restic's own arguments; RIG_RESTIC_MOUNT, when set, is bind-mounted
# at /src for `backup /src`. The streams are left unmerged: restic puts its
# Fatal lines on stderr, so a caller asserting on the server's own 403 has to
# ask for it.
rig_restic() {
    local repo=$1 arg cmd
    shift
    printf -v cmd 'docker run --rm -e RESTIC_PASSWORD=%q' "$RIG_RESTIC_PASSWORD"
    [ -z "${RIG_RESTIC_MOUNT:-}" ] || printf -v cmd '%s -v %q:/src' "$cmd" "$RIG_RESTIC_MOUNT"
    printf -v cmd '%s %q -r %q' "$cmd" "$RIG_RESTIC_IMAGE" "$repo"
    for arg in "$@"; do printf -v cmd '%s %q' "$cmd" "$arg"; done
    rig_ssh "$cmd"
}

# Returns the rig to the state kasbah has never touched — no compose projects,
# no kasbah-net, no /apps — while leaving every image in place. That is the
# whole reason it exists: `rig.sh reset` drops the /var/lib/docker volume, so a
# reset per suite re-pulls Traefik and nginx every run.
#
# Read the shape before the contents. This is a **sweep, not an enumeration**:
# it tears down every compose project the daemon reports, whoever created it,
# plus /apps. That is correct on a disposable fake VPS and catastrophic
# anywhere else — the workstation this repo is developed on runs unrelated
# production stacks, which is what the rig README's "never run a global prune"
# rule is about. So the whole design question is not what the payload deletes
# but how it knows where it is, and there are three independent answers:
#
#   1. Every destructive line lives inside the one quoted heredoc below and
#      runs on the far side of ssh. No local code path can execute any of it,
#      and there is no fallback: an unreachable rig is a refusal, not a retry.
#   2. The only target is the constant `rig`, resolved through the generated
#      rig contract, and the scratch config fences every other host off.
#   3. The payload itself checks the marker baked into the rig image before it
#      touches anything, and exits changing nothing when it is absent. This is
#      the one that holds even if 1 and 2 are both wrong, because it is
#      evaluated on the machine that actually answered.
rig_clean() {
    if [ ! -f "$RIG_SSH_CONFIG" ]; then
        echo "rig_clean: no $RIG_SSH_CONFIG — the rig has never been started (tests/rig/rig.sh up)" >&2
        return 1
    fi
    if ! rig_reachable; then
        echo "rig_clean: the rig did not answer ssh — refusing to clean anything" >&2
        return 1
    fi

    # One quoted string, because ssh re-joins its arguments with spaces before
    # the login shell sees them (docs/phases/01-rig.md).
    local rc=0
    rig_ssh "bash -s '$RIG_MARKER_FILE' '$RIG_MARKER_VALUE' '$RIG_NOT_THE_RIG'" <<'REMOTE' || rc=$?
set -uo pipefail
marker_file=$1
marker_value=$2
not_the_rig=$3
status=0

# Before anything is removed: is this the disposable rig, or somebody's server?
# The marker is baked into tests/rig/Dockerfile and cannot be on a real host by
# accident. Read with the CR stripped, so a file that ever gets authored on
# Windows does not silently fail open — it fails closed either way, but the
# diagnosis would be baffling.
marker=""
[ ! -f "$marker_file" ] || read -r marker < "$marker_file" || marker=""
marker=${marker%$'\r'}
if [ "$marker" != "$marker_value" ]; then
    printf 'rig_clean: %s does not say %s — this is not the rig, nothing was touched\n' \
        "$marker_file" "$marker_value" >&2
    exit "$not_the_rig"
fi

# Every compose project on the rig, not a list of names kasbah knows: a deploy
# that half-failed leaves a project this side cannot predict, and the point of
# clean is a known starting state. Safe only because of the marker above.
# `down` removes by project label, so it needs no compose file.
projects=$(docker compose ls --all -q 2>/dev/null) || projects=""
while IFS= read -r project; do
    [ -n "$project" ] || continue
    docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || status=1
done <<<"$projects"

# The one network kasbah creates outside any compose project. The built-in
# bridge/host/none are never named, here or anywhere.
if docker network inspect kasbah-net >/dev/null 2>&1; then
    docker network rm kasbah-net >/dev/null 2>&1 || status=1
fi

# Orphaned project networks. `down` above takes a project's networks with it,
# but a deploy that failed after creating the network and before creating a
# container leaves a project with nothing for `compose ls` to report — and the
# network outlives every clean, until a later suite asserting on the network
# list fails for something an earlier one did. Filtered on compose's own label,
# so the built-ins and anything hand-made are never candidates; by this point
# every compose project has been downed, so a labelled survivor is an orphan.
orphans=$(docker network ls --filter label=com.docker.compose.project -q 2>/dev/null) || orphans=""
while IFS= read -r net; do
    [ -n "$net" ] || continue
    docker network rm "$net" >/dev/null 2>&1 || status=1
done <<<"$orphans"

# Every volume nothing references any more. `--filter dangling=true` is docker's
# own predicate for that, and it is wider than "anonymous": a named volume no
# container holds is selected too. On a marker-verified disposable rig, one
# sweep after every compose project has been downed, that is the same set and
# the right one — but the predicate is unreferenced, not anonymous, and a reader
# deciding whether this is safe elsewhere needs the wider statement.
#
# The anonymous ones are why it is here. `docker compose down -v` reaps a
# project's anonymous volumes only when it can read the compose file, and the
# loop above downs by project label with no file in sight — so an image that
# declares VOLUME leaves one per container, outliving every clean. Measured with
# redis:7-alpine (VOLUME /data), which the built-app fixture runs: an aborted
# suite left one behind, and the next run of ssh_test.sh failed on a volume
# count it had not created.
dangling=$(docker volume ls -q --filter dangling=true 2>/dev/null) || dangling=""
while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    docker volume rm "$vol" >/dev/null 2>&1 || status=1
done <<<"$dangling"

# /apps is root-owned on a rig where the ssh user is unprivileged; stevedore
# has passwordless sudo.
sudo rm -rf /apps || status=1

# The server's record of where it was prepared. Left behind, a non-default apps
# path written by one suite steers every later one — `kasbah deploy` reads this
# file before it falls back to /apps.
#
# The exact directory, never a glob: /etc/kasbah-rig is the disposability marker
# this payload has already checked, one character away, and removing it would
# make every later rig_clean refuse.
sudo rm -rf /etc/kasbah || status=1

# Images are deliberately untouched.
exit "$status"
REMOTE

    if [ "$rc" = "$RIG_NOT_THE_RIG" ]; then
        echo "rig_clean: refused — the host that answered is not the kasbah rig" >&2
        echo "           (no $RIG_MARKER_FILE; rebuild it with tests/rig/rig.sh up)" >&2
    fi
    return "$rc"
}
