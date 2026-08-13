# hosting — server init command
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_SERVER_INIT_LOADED:-}" ] && return 0
_HOSTING_SERVER_INIT_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/prompt.sh"
. "$HOSTING_LIB_DIR/ssh.sh"

# `hosting server init` lays out the directory tree every later command assumes
# and records what it found in the server marker. It checks prerequisites and
# never installs them (docs/server-setup.md), and it is safe to re-run: a second
# run against an unchanged host leaves the tree byte-identical.
#
# Four remote steps over one connection, and nothing is created until the first
# two have both been judged. The probe collects every fact the verdicts need in
# a single round trip, because a check that fetches its own value is a check
# that can silently read a fact that never arrived (docs/phases/01-rig.md, from
# 1.3). The second reads any marker already on the server. The third creates the
# layout. The fourth writes the marker, and is separate from the third so that
# it stays last.

# The parsed command line.
_SI_TARGET=""
_SI_APPS_PATH=""
_SI_DATA_PATH=""
_SI_MAIL=""
_SI_BACKUP=""

# What the probe brought back, and what was derived from it.
declare -A _SI_FACT=()
_SI_ELEVATE=""
_SI_CPU_LIMIT=""
_SI_MEM_LIMIT=""
_SI_MARKER_EXISTING=""
_SI_MARKER_PRESENT=no

_server_init_usage() {
    cat <<EOF
Usage: hosting server init USER@HOST [flags]

Prepares a VPS to host projects: checks the prerequisites, creates the
directory layout, and writes the server marker. Idempotent.

Flags:
  --apps-path=<dir>      root directory on the VPS (default /apps)
  --data-path=<dir>      bind-mount root (default <apps-path>/data)
  --with-mail|--no-mail      scaffold the mail stack, or skip it
  --with-backup|--no-backup  install restic backups, or skip them

Mail and backup are tri-state: leaving both flags off asks. See
docs/server-setup.md for the prerequisites table and the layout.
EOF
}

# --- Command line -------------------------------------------------------------

# Rejects a second, contradicting --with-x/--no-x rather than letting the last
# one win: the two spellings exist to make an intent explicit, and a command
# line that states both intents has none.
_server_init_set_bool() {
    local _sb_feature="$1" _sb_value="$2" _sb_name="_SI_${1^^}"
    if [ -n "${!_sb_name}" ] && [ "${!_sb_name}" != "$_sb_value" ]; then
        die "server init: --with-$_sb_feature and --no-$_sb_feature cannot both be given"
    fi
    printf -v "$_sb_name" '%s' "$_sb_value"
}

# Normalises a path flag into <outvar>: absolute, no trailing slash, no relative
# segment. Everything below the apps path is built from these two strings on the
# far side, so a surprise here becomes a surprise in mkdir.
_server_init_path() {
    local _sp_flag="$1" _sp_value="${2%$'\r'}" _sp_out="$3"

    [ -n "$_sp_value" ] || die "server init: --$_sp_flag= must not be empty"
    case $_sp_value in
        /*) ;;
        *)  die "server init: --$_sp_flag=$_sp_value must be an absolute path" ;;
    esac
    case $_sp_value in
        *$'\n'*) die "server init: --$_sp_flag= must not contain a newline" ;;
    esac
    case $_sp_value in
        *//*|*/./*|*/../*|*/..|*/.)
            die "server init: --$_sp_flag=$_sp_value must be a normalised path (no '.', '..' or empty segment)" ;;
    esac

    # A run of slashes is already out on the normalisation rule above, so the
    # only value that empties here is a single "/".
    while [ "${_sp_value: -1}" = / ]; do _sp_value="${_sp_value%/}"; done
    [ -n "$_sp_value" ] \
        || die "server init: --$_sp_flag=/ must not be the filesystem root"

    printf -v "$_sp_out" '%s' "$_sp_value"
}

_server_init_parse_args() {
    local apps="" data=""
    local apps_given=0 data_given=0

    _SI_TARGET=""
    _SI_MAIL=""
    _SI_BACKUP=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --apps-path=*) apps="${1#*=}"; apps_given=1 ;;
            --data-path=*) data="${1#*=}"; data_given=1 ;;
            --with-mail)   _server_init_set_bool mail yes ;;
            --no-mail)     _server_init_set_bool mail no ;;
            --with-backup) _server_init_set_bool backup yes ;;
            --no-backup)   _server_init_set_bool backup no ;;
            -h|--help)     _server_init_usage; exit 0 ;;
            -*)            die "server init: unknown flag '$1' (expected --apps-path=, --data-path=, --with-mail/--no-mail, --with-backup/--no-backup)" ;;
            *)
                [ -z "$_SI_TARGET" ] \
                    || die "server init: unexpected argument '$1' (USER@HOST is given once)"
                _SI_TARGET="$1"
                ;;
        esac
        shift
    done

    [ -n "$_SI_TARGET" ] \
        || die "server init: USER@HOST is required (the user hosting deploys as is not optional)"

    # An empty --apps-path= is a stated intent that cannot be honoured, so it
    # fails rather than falling back to the default the operator just overrode.
    [ "$apps_given" = 1 ] || apps=/apps
    _server_init_path apps-path "$apps" _SI_APPS_PATH
    [ "$data_given" = 1 ] || data="$_SI_APPS_PATH/data"
    _server_init_path data-path "$data" _SI_DATA_PATH

    return 0
}

# --- Resource limits ----------------------------------------------------------

# 90% of the host as anti-takeover ceilings (docs/server-setup.md). Integer
# arithmetic throughout, and that is the point: a float formatter renders 14,4
# under a comma locale, and a marker whose bytes depend on the operator's
# LC_NUMERIC cannot satisfy "a second run changes nothing".
#
#   cpu_limit  nproc x 0.9, one decimal — exact, since nproc x 9 is a count of
#              tenths and nothing is rounded away.
#   mem_limit  whole GiB (10485760 = 1 GiB in kB, x 10, so the x 0.9 and the
#              unit conversion floor in a single division), and whole MiB below
#              one GiB. The granularity changes rather than clamping: a floor of
#              1g on a 512 MiB host would be a ceiling above the machine's total
#              memory, which is the opposite of what a ceiling is for.
_server_limits() {
    local cores="$1" mem_kb="$2" tenths gib mib

    [[ "$cores" =~ ^[1-9][0-9]*$ ]] || die "internal: nproc '$cores' is not a core count"
    [[ "$mem_kb" =~ ^[1-9][0-9]*$ ]] || die "internal: MemTotal '$mem_kb' is not a size in kB"

    tenths=$((cores * 9))
    _SI_CPU_LIMIT="$((tenths / 10)).$((tenths % 10))"

    gib=$((mem_kb * 9 / 10485760))
    if [ "$gib" -ge 1 ]; then
        _SI_MEM_LIMIT="${gib}g"
    else
        mib=$((mem_kb * 9 / 10240))
        [ "$mib" -ge 1 ] || mib=1
        _SI_MEM_LIMIT="${mib}m"
    fi
}

# --- Server marker ------------------------------------------------------------

# The shape is docs/server-setup.md's. Built with jq so a path containing a
# quote is escaped rather than emitted as broken JSON, and so the key order is
# fixed — the file is compared byte for byte on every re-run.
#
# An existing marker is merged into, never replaced: this command owns five keys
# and knows nothing about the rest. `backup` is the one that matters today —
# Phase 8 puts a repo_base beside `enabled`, and a plain re-run of init must not
# take an operator's backup configuration with it. Same for any key a newer
# hosting wrote and this one has never heard of.
_server_marker_json() {
    local existing="${6:-}"
    jq -n \
        --argjson existing "${existing:-null}" \
        --arg version "$1" \
        --arg apps_path "$2" \
        --arg data_path "$3" \
        --arg cpu_limit "$4" \
        --arg mem_limit "$5" \
        '(($existing // {}) + {
            hosting_version: $version,
            apps_path: $apps_path,
            data_path: $data_path,
            cpu_limit: $cpu_limit,
            mem_limit: $mem_limit
        })
        | if has("backup") then . else . + { backup: { enabled: false } } end'
}

# --- Preflight ----------------------------------------------------------------

# Folds a remote step's key=value report into the fact table.
_si_absorb() {
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case $line in *=*) _SI_FACT[${line%%=*}]="${line#*=}" ;; esac
    done <<<"$1"
    return 0
}

# One session, every fact, reported as key=value. The script always exits 0: the
# verdicts are local, so a non-zero status can only mean the transport failed.
_server_init_probe() {
    local out rc=0 line key
    local missing=()

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2

# One line per value: the reader parses this output as a protocol, and a
# command's multi-line complaint would arrive as extra keys. The trailing space
# `flat` leaves behind is trimmed here rather than at every call site, because
# "16 " is not an integer to any test that later reads it.
kv() {
    local v="$2"
    while [ "${v: -1}" = " " ]; do v="${v% }"; done
    printf '%s=%s\n' "$1" "$v"
}
flat() { tr -d '\r' | tr '\n' ' '; }

kv user "$(id -un)"
kv group "$(id -gn)"

# `docker version` rather than `docker info`: the prerequisites table's ">= 24"
# is about the daemon, and this script never elevates, so a daemon that answers
# is also the "can run docker without sudo" row. Both halves are reported —
# which of the two rows failed depends on whether docker is there at all.
if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_server "$(printf '%s' "$docker_out" | flat)"
    kv docker_error ""
else
    kv docker_server ""
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi
kv compose_version "$(docker compose version --short 2>/dev/null | flat)"

for c in rsync openssl gzip; do
    if command -v "$c" >/dev/null 2>&1; then kv "have_$c" yes; else kv "have_$c" no; fi
done

# Asked, never assumed: a sudo that would prompt has nowhere to read a password
# from here, and the run must say so instead of hanging on it.
if sudo -n true >/dev/null 2>&1; then sudo_ok=yes; else sudo_ok=no; fi
kv sudo_nopasswd "$sudo_ok"

# One state per path rather than a spread of booleans, because the states are
# mutually exclusive and each one has its own verdict. `dangling` is a real
# case: a symlink with nothing behind it answers -e with "no" and then fails
# `mkdir -p` with "File exists".
path_state() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then printf dangling
    elif [ ! -e "$1" ];              then printf absent
    elif [ -d "$1" ];                then printf dir
    else                                  printf notdir
    fi
}

# The nearest ancestor this user can stat. Reached only when the path itself
# cannot be seen, and the difference between the two reasons for that is the
# whole point of the block below.
nearest_visible() {
    local p="$1"
    while [ ! -e "$p" ] && [ "$p" != / ]; do
        p=${p%/*}
        [ -n "$p" ] || p=/
    done
    printf '%s' "$p"
}

apps_state=$(path_state "$apps")
apps_base=$(nearest_visible "$apps")

# "The deploy user cannot see it" and "it is not there" are different facts, and
# only one of them may be elevated over. A directory behind a parent this user
# cannot traverse answers -e with false exactly like an absent one — and the
# chown that would follow runs as root, which can see it perfectly well. So the
# question is put a second time, with the eyes that would do the work.
apps_root_state=unknown
apps_root_owner=""
if [ "$apps_state" = absent ] && [ "$sudo_ok" = yes ]; then
    if sudo -n test -e "$apps" 2>/dev/null; then
        apps_root_state=exists
        apps_root_owner=$(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null | flat)
    else
        apps_root_state=absent
    fi
fi
# Either answer makes it unusable: hosting will not adopt what root can see and
# this user cannot, and it cannot work below a wall it cannot cross either,
# since everything under the apps path is written unelevated.
if [ "$apps_state" = absent ]; then
    if [ "$apps_root_state" = exists ]; then
        apps_state=unreachable
    elif [ "$apps_base" != "$apps" ] && [ ! -x "$apps_base" ]; then
        apps_state=unreachable
    fi
fi

kv apps_state "$apps_state"
kv apps_root_state "$apps_root_state"
kv apps_root_owner "$apps_root_owner"
kv apps_base "$apps_base"
kv apps_base_owner "$(stat -c '%U:%G' "$apps_base" 2>/dev/null | flat)"
kv apps_base_mode "$(stat -c '%a' "$apps_base" 2>/dev/null | flat)"

# -O asks the kernel whether this uid owns it — no stat parsing, no name
# lookup. The owner's *name* is only ever quoted back in a message.
if [ -O "$apps" ]; then kv apps_owned yes; else kv apps_owned no; fi
if [ -w "$apps" ] && [ -x "$apps" ]; then kv apps_writable yes; else kv apps_writable no; fi
kv apps_owner "$(stat -c '%U:%G' "$apps" 2>/dev/null | flat)"

# Why the write was refused, when the path is this user's own and still not
# writable: a read-only mount and a stripped mode are the same `-w` and want
# opposite advice. The errno is the only thing that tells them apart, so it is
# asked for directly. LC_ALL=C above keeps the wording stable.
apps_write_error=""
if [ "$apps_state" = dir ] && [ -O "$apps" ] && [ ! -w "$apps" ]; then
    apps_write_error=$(touch "$apps/.hosting-write-probe" 2>&1 | flat)
    rm -f "$apps/.hosting-write-probe" 2>/dev/null
fi
kv apps_write_error "$apps_write_error"

kv data_state "$(path_state "$data")"
if [ -w "$data" ] && [ -x "$data" ]; then kv data_writable yes; else kv data_writable no; fi
kv data_owner "$(stat -c '%U:%G' "$data" 2>/dev/null | flat)"

# A data path at or below the apps path needs no separate check: the apps path
# is either the deploy user's already or about to be, so everything from there
# down is creatable. One outside it has its own parent, which may belong to
# anyone. `--data-path` equal to `--apps-path` is inside, not outside — it is an
# odd configuration, not an error, and walking off to / for its parent produced
# a refusal that contradicted itself.
case $data in
    "$apps"|"$apps"/*) kv data_scope inside ;;
    *)                 kv data_scope outside ;;
esac
base=$(nearest_visible "$data")
kv data_base "$base"
if [ -w "$base" ] && [ -x "$base" ]; then kv data_base_writable yes; else kv data_base_writable no; fi

kv nproc "$(nproc 2>/dev/null | flat)"
# Read in the shell: awk is not on the prerequisites table, and this is the one
# fact the marker cannot be written without.
memtotal_kb=""
while read -r field value _; do
    if [ "$field" = "MemTotal:" ]; then memtotal_kb=$value; break; fi
done < /proc/meminfo
kv memtotal_kb "$memtotal_kb"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not collect prerequisites from $_SI_TARGET (the remote probe exited $rc)"
    [ -n "$out" ] \
        || die "the prerequisite probe on $_SI_TARGET succeeded and reported nothing (its output was lost, or the login shell swallowed it)"

    _SI_FACT=()
    _si_absorb "$out"

    # The key set is validated as a protocol before any verdict reads a value: a
    # fact that never arrived must not be absorbed into a passing check.
    for key in user group have_docker docker_server docker_error \
               compose_version have_rsync have_openssl have_gzip sudo_nopasswd \
               apps_state apps_owned apps_writable apps_owner apps_write_error \
               apps_root_state apps_root_owner apps_base apps_base_owner apps_base_mode \
               data_state data_writable data_owner data_scope data_base data_base_writable \
               nproc memtotal_kb; do
        [ -n "${_SI_FACT[$key]+set}" ] || missing+=("$key")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "the prerequisite probe on $_SI_TARGET reported no ${missing[*]}"
        err_cont "the probe was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
        exit 1
    fi
    return 0
}

# Elevation happens on exactly one condition: the apps path does not exist, so
# root has to create it and hand it over. Everything below it is then written
# unelevated, which is what keeps /apps/data free of mixed ownership
# (docs/server-setup.md).
#
# The state this deliberately does *not* elevate for is a path that exists and
# belongs to somebody else. Chowning it would be a seizure: `--apps-path=/var/www`
# on a real VPS would hand a live document root to the deploy user, with its
# contents left in mixed ownership. That is a refusal below, naming the one
# command an operator can run if they meant it.
#
# `absent` means absent to root as well, not merely invisible to the deploy user
# — see the probe. The layout asks once more before it creates anything, because
# between this decision and that chown there is a window, and the chown is the
# irreversible half.
_server_init_elevation() {
    if [ "${_SI_FACT[apps_state]}" = absent ]; then
        _SI_ELEVATE=yes
    else
        _SI_ELEVATE=no
    fi
}

# The leading component of a version, with the `v` some tools print stripped:
# `docker compose version --short` says 2.29.7 on one machine and v2.29.7 on the
# next, and a preflight that reads the second as "not a number" would fail a
# host that is fine.
_si_major() {
    local v="${1#v}"
    printf '%s' "${v%%.*}"
}

# Every row of docs/server-setup.md's prerequisites table, checked against the
# probe. All failures are reported together — a server three rows short should
# cost one round trip, not three.
_server_init_preflight() {
    local target="$1" apps="$2" needs_sudo="$3"
    local rows=() cmd have major row
    local user="${_SI_FACT[user]}" group="${_SI_FACT[group]}"
    local owner="$user:$group"

    if [ "${_SI_FACT[have_docker]}" != yes ]; then
        rows+=("Docker >= 24 — no docker command on the remote."
               "  Install Docker Engine: https://docs.docker.com/engine/install/")
    elif [ -z "${_SI_FACT[docker_server]}" ]; then
        rows+=("the SSH user can run docker without sudo — \`docker version\` failed as ${_SI_FACT[user]}."
               "  ${_SI_FACT[docker_error]}"
               "  sudo usermod -aG docker ${_SI_FACT[user]}   (then open a new session)")
    else
        major="$(_si_major "${_SI_FACT[docker_server]}")"
        if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 24 ]; then
            rows+=("Docker >= 24 — the daemon reports ${_SI_FACT[docker_server]}."
                   "  Upgrade Docker Engine: https://docs.docker.com/engine/install/")
        fi
    fi

    # Major >= 2, not == 2: v2 is a floor, not a version to match. The rig
    # already ships Compose 5.4.0 (docs/phases/01-rig.md).
    major="$(_si_major "${_SI_FACT[compose_version]}")"
    if [ -z "${_SI_FACT[compose_version]}" ]; then
        rows+=("Docker Compose v2 — \`docker compose version\` produced nothing."
               "  The compose plugin is missing: install docker-compose-plugin.")
    elif ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 2 ]; then
        rows+=("Docker Compose v2 — the plugin reports ${_SI_FACT[compose_version]}."
               "  hosting's compose files need include: and v2 syntax.")
    fi

    for cmd in rsync openssl gzip; do
        have="${_SI_FACT[have_$cmd]}"
        if [ "$have" != yes ]; then
            rows+=("rsync, openssl, gzip on the remote — $cmd is missing."
                   "  deploy and env setup both need it; install it with the distro's package manager.")
        fi
    done

    # The apps path, in the four states it can be in. Only the first is
    # elevated over; the rest are the operator's to resolve, because hosting
    # taking ownership of a directory it did not create is not a repair.
    case "${_SI_FACT[apps_state]}" in
        absent)
            if [ "${_SI_FACT[sudo_nopasswd]}" != yes ]; then
                rows+=("passwordless sudo — \`sudo -n true\` failed as $user."
                       "  $apps does not exist, and it lives outside the deploy user's home,"
                       "  so only root can create it. Grant NOPASSWD sudo, or run this once"
                       "  by hand and re-run init:"
                       "  ssh $target 'sudo mkdir -p $apps && sudo chown $owner $apps'")
            fi
            ;;
        dangling)
            rows+=("$apps is a symlink to nothing."
                   "  Point it somewhere or remove it — \`mkdir -p\` fails on it with"
                   "  \"File exists\", which is not a diagnosis anybody enjoys.")
            ;;
        unreachable)
            if [ "${_SI_FACT[apps_root_state]}" = exists ]; then
                rows+=("$apps exists and belongs to ${_SI_FACT[apps_root_owner]}, and $user cannot see it."
                       "  Only root can, which is why this is a refusal: hosting would have to take the"
                       "  directory over to use it, and it never takes over one it did not create.")
            else
                rows+=("$apps cannot be reached by $user."
                       "  ${_SI_FACT[apps_base]} is not traversable by them (owner ${_SI_FACT[apps_base_owner]}, mode ${_SI_FACT[apps_base_mode]}),"
                       "  so hosting cannot even tell whether $apps exists.")
            fi
            rows+=("  Everything below the apps path is written as $user, so a path they cannot"
                   "  enter is no use even once it exists. Pick one they can, with --apps-path=<dir>.")
            ;;
        notdir)
            rows+=("$apps exists and is not a directory."
                   "  Remove it, or point init elsewhere with --apps-path=<dir>.")
            ;;
        dir)
            if [ "${_SI_FACT[apps_owned]}" != yes ]; then
                rows+=("$apps already exists and belongs to ${_SI_FACT[apps_owner]}, not $user."
                       "  hosting only elevates to create the apps path; it never takes over one"
                       "  it did not create, because everything below would end up in mixed"
                       "  ownership. If this path really is meant for hosting, hand it over:"
                       "  ssh $target 'sudo chown $owner $apps'")
            elif [ "${_SI_FACT[apps_writable]}" != yes ]; then
                case "${_SI_FACT[apps_write_error]}" in
                    *"Read-only file system"*)
                        rows+=("$apps belongs to $user and is on a read-only filesystem."
                               "  ${_SI_FACT[apps_write_error]}"
                               "  No mode change fixes that: remount it read-write, or pick another"
                               "  path with --apps-path=<dir>.")
                        ;;
                    *)
                        rows+=("$apps belongs to $user but is not writable by them."
                               "  ssh $target 'chmod u+rwx $apps'")
                        ;;
                esac
            fi
            ;;
    esac

    # The data path is created unelevated like everything else, so what matters
    # is whether the deploy user can write where it is going. Below the apps
    # path that is settled by the row above; outside it, it is a question of its
    # own — and one worth asking here rather than half way through the layout.
    case "${_SI_FACT[data_state]}" in
        dangling)
            rows+=("the data path $_SI_DATA_PATH is a symlink to nothing."
                   "  Point it somewhere or remove it.")
            ;;
        notdir)
            rows+=("the data path $_SI_DATA_PATH exists and is not a directory."
                   "  Remove it, or point init elsewhere with --data-path=<dir>.")
            ;;
        dir)
            if [ "${_SI_FACT[data_writable]}" != yes ]; then
                rows+=("the data path $_SI_DATA_PATH exists and is not writable by $user (owner ${_SI_FACT[data_owner]})."
                       "  ssh $target 'sudo chown $owner $_SI_DATA_PATH'")
            fi
            ;;
        absent)
            if [ "${_SI_FACT[data_scope]}" = outside ] \
                && [ "${_SI_FACT[data_base_writable]}" != yes ]; then
                rows+=("the data path $_SI_DATA_PATH cannot be created: ${_SI_FACT[data_base]} is not writable by $user."
                       "  It sits outside $apps, so hosting cannot get there unelevated. Create it once:"
                       "  ssh $target 'sudo mkdir -p $_SI_DATA_PATH && sudo chown $owner $_SI_DATA_PATH'")
            fi
            ;;
    esac

    if ! [[ "${_SI_FACT[nproc]}" =~ ^[1-9][0-9]*$ ]]; then
        rows+=("resource limits — the remote reported nproc='${_SI_FACT[nproc]}'."
               "  The marker's cpu_limit is 90% of that and cannot be computed.")
    fi
    if ! [[ "${_SI_FACT[memtotal_kb]}" =~ ^[1-9][0-9]*$ ]]; then
        rows+=("resource limits — /proc/meminfo reported MemTotal='${_SI_FACT[memtotal_kb]}'."
               "  The marker's mem_limit is 90% of that and cannot be computed.")
    fi

    [ "${#rows[@]}" -gt 0 ] || return 0

    err "$target does not meet the prerequisites for hosting server init:"
    for row in "${rows[@]}"; do err_cont "$row"; done
    err_cont "hosting checks prerequisites and never installs them — see docs/server-setup.md"
    exit 1
}

# --- The marker already on the server -------------------------------------------

# Read before anything is created, because what it says can stop the run.
# Absence reports itself with exit 3 rather than with empty output, and the two
# are then treated differently: no marker is the ordinary first run, while a
# marker that exists and holds nothing usable is a refusal like any other
# unreadable one. A zero-byte file is not an invitation to overwrite.
_server_init_read_marker() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" <<'REMOTE'
set -uo pipefail
marker="$1/.hosting/server.json"

if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$marker" >&2
    exit 1
fi
[ -f "$marker" ] || exit 3
cat "$marker"
REMOTE
    ) || rc=$?

    case $rc in
        0) _SI_MARKER_PRESENT=yes; _SI_MARKER_EXISTING="$out" ;;
        3) _SI_MARKER_PRESENT=no;  _SI_MARKER_EXISTING="" ;;
        *) die "could not read $_SI_APPS_PATH/.hosting/server.json on $_SI_TARGET (the remote step exited $rc, see above)" ;;
    esac
    return 0
}

# docs/server-setup.md's compatibility rule, the half that has a remedy: a
# hosting binary operates on a VPS whose marker shares its major version, and an
# older tool facing a newer marker refuses rather than writing fields it does
# not understand. (The mirror case — newer tool, older-major marker — is
# specified as "refuse until `hosting migrate`", and that command does not exist
# yet; refusing with no way forward would be worse than the drift.)
_server_init_check_marker() {
    local path="$_SI_APPS_PATH/.hosting/server.json" version major ours

    [ "$_SI_MARKER_PRESENT" = yes ] || return 0

    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_SI_MARKER_EXISTING"; then
        err "$path on $_SI_TARGET is not a JSON object"
        err_cont "hosting will not overwrite a marker it cannot read — look at it, then remove"
        err_cont "it and re-run to start the server's record over"
        exit 1
    fi

    version="$(jq -r '.hosting_version // "" | tostring' <<<"$_SI_MARKER_EXISTING")"
    major="$(_si_major "$version")"
    ours="$(_si_major "$HOSTING_VERSION")"
    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$ours" =~ ^[0-9]+$ ]]; then
        warn "$path records hosting_version '$version'; this hosting is $HOSTING_VERSION"
        warn "the two cannot be compared, so no compatibility check was made"
        return 0
    fi
    if [ "$major" -gt "$ours" ]; then
        err "$path was written by hosting $version, and this is hosting $HOSTING_VERSION"
        err_cont "a newer major on the server means fields this binary does not know about"
        err_cont "upgrade hosting locally, or point at a server this version manages"
        exit 1
    fi
    return 0
}

# --- Remote layout ------------------------------------------------------------

# Creates everything except the marker, in the order docs/server-setup.md fixes:
# the apps path (elevated, once), the tree below it (unelevated), then acme.json
# as a file.
#
# The marker is a separate step on purpose. Its presence is the "init completed"
# signal, so whatever a later unit adds — rendering the Traefik stack, starting
# it — belongs between this function and _server_init_marker, never after it.
_server_init_layout() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" "$_SI_ELEVATE" \
                     "${_SI_FACT[user]}:${_SI_FACT[group]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
elevate=$3
owner=$4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

if [ "$elevate" = yes ]; then
    # Asked with root's eyes, immediately before acting on the answer. The
    # preflight decided this path was absent; if root disagrees now — a race, or
    # anything the earlier look got wrong — the chown below would be a seizure,
    # so it does not happen.
    if sudo -n test -e "$apps"; then
        fail "$apps exists after all (root sees it, owner $(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null)) — hosting creates the apps path, it never takes over one that is already there"
    fi
    # -p for the parents, and a bare mkdir for the component being taken
    # ownership of: an existing directory is then EEXIST and an error, instead
    # of a silent no-op followed by a chown of somebody else's directory.
    parent=${apps%/*}
    [ -n "$parent" ] || parent=/
    sudo -n mkdir -p "$parent" || fail "sudo mkdir -p $parent failed"
    sudo -n mkdir "$apps" || fail "sudo mkdir $apps failed — it exists already, and hosting only chowns what it created"
    sudo -n chown "$owner" "$apps" || fail "sudo chown $owner $apps failed"
    printf 'elevated=yes\n'
else
    printf 'elevated=no\n'
fi

for d in "$apps/.hosting" "$apps/backups" "$apps/traefik/dynamic" \
         "$data" "$data/traefik/letsencrypt"; do
    mkdir -p "$d" || fail "could not create $d"
done

# Docker materialises a missing bind-mount source as a *directory*, which breaks
# Traefik and later DMS, so the file exists before anything can mount it. The
# guard is -f: a directory answers -e and -r alike (docs/phases/01-rig.md).
acme="$data/traefik/letsencrypt/acme.json"
if [ -e "$acme" ] && [ ! -f "$acme" ]; then
    fail "$acme exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '$acme') and re-run."
fi
if [ -f "$acme" ]; then
    printf 'acme=existed\n'
else
    touch "$acme" || fail "could not create $acme"
    printf 'acme=created\n'
fi
chmod 600 "$acme" || fail "could not set mode 600 on $acme"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not lay out $_SI_APPS_PATH on $_SI_TARGET (the remote step exited $rc, see above)"

    _SI_FACT[elevated]=""
    _SI_FACT[acme]=""
    _si_absorb "$out"
}

# The last thing init does. Written only when its content differs, so a re-run
# does not even move the mtime.
_server_init_marker() {
    local marker_json="$1" out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$marker_json" <<'REMOTE'
set -uo pipefail
apps=$1
marker_json=$2

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

marker="$apps/.hosting/server.json"
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    fail "$marker exists and is not a regular file"
fi
current=""
[ ! -f "$marker" ] || current=$(cat "$marker") || fail "could not read $marker"
if [ "$current" = "$marker_json" ]; then
    printf 'marker=unchanged\n'
else
    # Rendered and renamed: another hosting run reading the marker must never
    # catch a half-written one.
    tmp="$marker.tmp.$$"
    printf '%s\n' "$marker_json" > "$tmp" || fail "could not write $tmp"
    chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
    mv -f "$tmp" "$marker" || fail "could not install $marker"
    printf 'marker=written\n'
fi

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not write the server marker on $_SI_TARGET (the remote step exited $rc, see above)"

    _SI_FACT[marker]=""
    _si_absorb "$out"
}

# --- Command ------------------------------------------------------------------

cmd_server_init() {
    _server_init_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    # Both questions are asked before anything is opened or created: a run that
    # cannot be answered must cost nothing, and a feature that would be a silent
    # no-op must not be accepted at all.
    if prompt_bool mail "Scaffold the mail stack (DMS + SnappyMail) on $_SI_TARGET?" "$_SI_MAIL"; then
        err "server init: mail is not implemented yet — it is scaffolded in Phase 7 (docs/mail.md)"
        err_cont "re-run with --no-mail; adding mail later is a re-run of init"
        exit 1
    fi
    if prompt_bool backup "Install restic backups on $_SI_TARGET?" "$_SI_BACKUP"; then
        err "server init: backup is not implemented yet — it is scaffolded in Phase 8 (docs/backup.md)"
        err_cont "re-run with --no-backup; adding backups later is a re-run of init"
        exit 1
    fi

    ssh_connect "$_SI_TARGET"

    _server_init_probe
    _server_init_read_marker
    _server_init_elevation
    _server_init_preflight "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_ELEVATE"
    _server_init_check_marker
    _server_limits "${_SI_FACT[nproc]}" "${_SI_FACT[memtotal_kb]}"

    local marker_json
    marker_json="$(_server_marker_json "$HOSTING_VERSION" "$_SI_APPS_PATH" \
        "$_SI_DATA_PATH" "$_SI_CPU_LIMIT" "$_SI_MEM_LIMIT" "$_SI_MARKER_EXISTING")"

    _server_init_layout
    _server_init_marker "$marker_json"

    info "Prepared $_SI_TARGET"
    # The one moment hosting elevates, and the one moment it creates the file
    # Docker would otherwise turn into a directory: both are worth saying out
    # loud, and both are silent on a re-run.
    [ "${_SI_FACT[elevated]}" != yes ] \
        || info "  created $_SI_APPS_PATH with sudo, owner ${_SI_FACT[user]}:${_SI_FACT[group]}"
    [ "${_SI_FACT[acme]}" != created ] \
        || info "  touched $_SI_DATA_PATH/traefik/letsencrypt/acme.json as a file, mode 600"
    info "  apps: $_SI_APPS_PATH   data: $_SI_DATA_PATH"
    info "  limits: cpu $_SI_CPU_LIMIT, mem $_SI_MEM_LIMIT (90% of ${_SI_FACT[nproc]} cores, ${_SI_FACT[memtotal_kb]} kB)"
    info "  marker: $_SI_APPS_PATH/.hosting/server.json (${_SI_FACT[marker]})"
}
