# hosting — server status command
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_SERVER_STATUS_LOADED:-}" ] && return 0
_HOSTING_SERVER_STATUS_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/ssh.sh"
# For HOSTING_RESERVED_NAMES alone — a server command has no manifest to read.
# The list is what a project may not be called *because* those directories are
# hosting's own under <apps>/, which is the same question status asks when it
# decides what is a project, so the two must not drift apart.
. "$HOSTING_LIB_DIR/manifest.sh"

# `hosting server status USER@HOST` reports what a prepared VPS is running: the
# docker and compose versions, the shared Traefik stack, and every project under
# the apps path with the last line of its versions.log.
#
# Read-only. The remote script asks docker four questions — `version`,
# `compose version`, `ps`, `inspect`, all of them reads — opens files for
# reading, and pipes what it read through `tr` and `openssl base64`. There is no
# mkdir, no touch, and no redirection onto the server's filesystem. The
# integration suite digests the whole apps tree, mtimes included, across a
# status run rather than taking this paragraph's word for it.
#
# One round trip. Every fact comes back from a single ssh session as key=value
# lines, and the key set is checked as a protocol before any line of output
# reads a value: a fact that never arrived must not be printed as a verdict
# (docs/phases/01-rig.md, from 1.3). The remote side never assumes jq or yq —
# the prerequisites table promises rsync, openssl, gzip and bash — so the marker
# travels back as bytes and is parsed here.
#
# The rest of docs/server-setup.md's sketch — certificates and ACME expiry, the
# dashboard URL and its ACME address, the mail stack, disk usage, per-container
# health — arrives with the full `status` in Phase 7. What is here is what
# verifies the spine by hand.

_SS_TARGET=""
_SS_APPS_PATH=""

# What the one remote step brought back, and what was read out of the marker.
declare -A _SS_FACT=()
_SS_MARKER=""
_SS_MARKER_APPS=""
_SS_MARKER_DATA=""
_SS_MARKER_VERSION=""
_SS_MARKER_CPU=""
_SS_MARKER_MEM=""

# The project table, decoded from the remote payload into parallel arrays.
_SS_P_NAME=()
_SS_P_TOTAL=()
_SS_P_RUNNING=()
_SS_P_LOGSTATE=()
_SS_P_LOG=()

# The fixed names hosting owns under the apps path (docs/server-setup.md → What
# init creates). The bind-mount root is not always among them — `--data-path`
# can put it inside the apps path under any name — so that one is dropped later,
# from the marker, in _ss_decode_projects.
#
# Everything else is reported as a project, including a name no deploy of this
# hosting could have made: a name rule cannot tell a stray directory from one a
# different hosting deployed, and a status that hides what it does not recognise
# is worse than one that shows it.
_SS_RESERVED=(.hosting "${HOSTING_RESERVED_NAMES[@]}")

_server_status_usage() {
    cat <<EOF
Usage: hosting server status USER@HOST [--apps-path=<dir>]

Prints what a prepared server is running: docker and compose versions, the
shared Traefik stack, and every project under the apps path with its last
versions.log entry. Read-only — it changes nothing on the server.

Flags:
  --apps-path=<dir>   where the server was prepared (default $HOSTING_DEFAULT_APPS_PATH)

Certs, mail and disk usage are not reported yet; see docs/server-setup.md.
EOF
}

# --- Command line ---------------------------------------------------------------

# Absolute and normalised, because everything read on the far side hangs off it
# and a surprise here becomes a surprise in a path that does not exist. The
# stricter bans `server init` puts on the same flag — `$` and `:` — are about
# the value being written into a compose bind mount, which status never does.
_ss_apps_path() {
    local _ap_value="${1%$'\r'}"

    [ -n "$_ap_value" ] || die "server status: --apps-path= must not be empty"
    case $_ap_value in
        /*) ;;
        *)  die "server status: --apps-path=$_ap_value must be an absolute path" ;;
    esac
    case $_ap_value in
        *$'\n'*) die "server status: --apps-path= must not contain a newline" ;;
    esac
    case $_ap_value in
        *//*|*/./*|*/../*|*/..|*/.)
            die "server status: --apps-path=$_ap_value must be a normalised path (no '.', '..' or empty segment)" ;;
    esac

    while [ "${_ap_value: -1}" = / ]; do _ap_value="${_ap_value%/}"; done
    [ -n "$_ap_value" ] \
        || die "server status: --apps-path=/ must not be the filesystem root"

    printf -v _SS_APPS_PATH '%s' "$_ap_value"
}

_server_status_parse_args() {
    local apps="" apps_given=0

    _SS_TARGET=""
    _SS_APPS_PATH=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --apps-path=*) apps="${1#*=}"; apps_given=1 ;;
            -h|--help)     _server_status_usage; exit 0 ;;
            -*)            die "server status: unknown flag '${1%%=*}' (expected --apps-path=)" ;;
            *)
                [ -z "$_SS_TARGET" ] \
                    || die "server status: unexpected argument '$1' (USER@HOST is given once)"
                _SS_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_SS_TARGET" ] \
        || die "server status: USER@HOST is required (the user hosting deploys as is not optional)"

    # An empty --apps-path= is a stated intent that cannot be honoured, so it
    # fails rather than falling back to the default the operator just overrode.
    [ "$apps_given" = 1 ] || apps="$HOSTING_DEFAULT_APPS_PATH"
    _ss_apps_path "$apps"
    return 0
}

# --- The one remote step ----------------------------------------------------------

# Folds the report into the fact table and checks the key set before any of it
# is read: a truncated step must not be absorbed into a passing verdict.
#
# The raw output is echoed back on failure, clipped to twenty lines of 120
# bytes: two of these values are base64 blobs that grow with the server, and a
# diagnostic that scrolls a megabyte of them past the reader diagnoses nothing.
_ss_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_shown=0
    local _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _SS_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_SS_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the status probe on $_SS_TARGET reported no ${_ac_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _ac_line; do
            _ac_shown=$((_ac_shown + 1))
            if [ "$_ac_shown" -gt 20 ]; then
                err_cont "| … and more, not shown"
                break
            fi
            [ "${#_ac_line}" -le 120 ] \
                || _ac_line="${_ac_line:0:120}… (${#_ac_line} bytes in all)"
            err_cont "| $_ac_line"
        done <<<"$_ac_out"
        exit 1
    fi
    return 0
}

# base64 -d into <outvar>, without letting a bad payload end the run silently.
# A plain `x="$(… | base64 -d)"` is fatal under errexit, so the process dies
# before the caller's message about a corrupt payload can run — a status that
# exits 1 having printed nothing at all, which is worse than a wrong line.
# Written as a `||` list, which errexit exempts, so the caller decides what a
# failure means.
#
# The command substitution drops trailing newlines. The row table ends with one
# and does not need it — it is read line by line — while a project name and a
# versions.log line carry none, and jq does not care how the marker ends.
_ss_b64_decode() {
    local _bd_out="$2" _bd_val=""
    _bd_val="$(printf '%s' "$1" | base64 -d 2>/dev/null)" || return 1
    printf -v "$_bd_out" '%s' "$_bd_val"
    return 0
}

_server_status_collect() {
    local out rc=0

    out=$(ssh_script "$_SS_APPS_PATH" "${_SS_RESERVED[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
reserved=" $2 "

# One line per value: the reader parses this output as a protocol, so a
# command's multi-line complaint would arrive as extra keys. Anything that can
# carry a newline or a space of its own — the marker, a project name, a
# versions.log line — is base64'd instead.
kv() {
    local v="$2"
    while [ "${v: -1}" = " " ]; do v="${v% }"; done
    printf '%s=%s\n' "$1" "$v"
}
flat() { tr -d '\r' | tr '\n' ' '; }
# openssl rather than coreutils' `base64 -w0`: openssl is on the prerequisites
# table and base64 is not.
b64() { openssl base64 -A 2>/dev/null; }

# Non-empty lines in a string, counted without a subprocess.
count_lines() {
    local n=0 l
    if [ -n "$1" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            n=$((n + 1))
        done <<<"$1"
    fi
    printf '%s' "$n"
}

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

apps_state=absent
if [ -d "$apps" ]; then apps_state=dir
elif [ -e "$apps" ]; then apps_state=notdir
fi
kv apps_state "$apps_state"

# The marker's bytes, not its meaning: no jq on the far side, so the caller
# parses it. A zero-byte file is reported as such rather than as an absent one —
# absence is an unprepared server, emptiness is a broken marker.
marker="$apps/.hosting/server.json"
marker_state=absent
marker_b64=""
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    marker_state=notfile
elif [ -f "$marker" ]; then
    if [ ! -s "$marker" ]; then
        marker_state=empty
    else
        marker_b64=$(openssl base64 -A -in "$marker" 2>/dev/null) || marker_b64=""
        if [ -n "$marker_b64" ]; then marker_state=ok; else marker_state=unreadable; fi
    fi
fi
kv marker_state "$marker_state"
kv marker_b64 "$marker_b64"

# Traefik by its compose labels, which is the frozen contract: the project name
# is `traefik` wherever the stack was rendered. A container merely *named*
# traefik did not come from hosting's stack, and reporting it as the proxy would
# be worse than reporting none.
cid=""
if [ "$docker_rc" -eq 0 ]; then
    ids=$(docker ps -a --filter label=com.docker.compose.project=traefik \
                      --filter label=com.docker.compose.service=traefik \
                      --format '{{.ID}}' 2>/dev/null) || ids=""
    cid=${ids%%$'\n'*}
fi
if [ -n "$cid" ]; then
    name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | flat)
    kv traefik_present yes
    kv traefik_state    "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null | flat)"
    kv traefik_health   "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null | flat)"
    kv traefik_image    "$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null | flat)"
    kv traefik_image_id "$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null | flat)"
    kv traefik_container "${name#/}"
else
    kv traefik_present no
    kv traefik_state ""
    kv traefik_health ""
    kv traefik_image ""
    kv traefik_image_id ""
    kv traefik_container ""
fi

# One row per project: everything under the apps path that is not one of
# hosting's own directories. dotglob is on because `.hosting` is skipped by name
# rather than by being hidden, and a project that is not a directory at all is
# reported as that rather than skipped.
rows=""
count=0
if [ "$apps_state" = dir ]; then
    shopt -s nullglob dotglob
    for path in "$apps"/*; do
        name=${path##*/}
        case $reserved in *" $name "*) continue ;; esac
        count=$((count + 1))

        total=0
        running=0
        logstate=missing
        last=""

        if [ ! -d "$path" ]; then
            logstate=notdir
        else
            if [ "$docker_rc" -eq 0 ]; then
                ids=$(docker ps -a --filter "label=com.docker.compose.project=$name" -q 2>/dev/null) || ids=""
                total=$(count_lines "$ids")
                ids=$(docker ps --filter "label=com.docker.compose.project=$name" -q 2>/dev/null) || ids=""
                running=$(count_lines "$ids")
            fi

            log="$path/versions.log"
            # Every "cannot" is its own state. A deploy that ran under sudo
            # leaves directories this user cannot enter (docs/server-setup.md
            # warns about exactly that ownership mix), and both of the cases
            # below otherwise read as "there is no log here" — which is the same
            # answer a project that has never been deployed gives.
            if [ ! -r "$path" ] || [ ! -x "$path" ]; then
                logstate=noaccess
            elif [ -e "$log" ] && [ ! -f "$log" ]; then
                logstate=notfile
            elif [ -f "$log" ] && [ ! -r "$log" ]; then
                logstate=unreadable
            elif [ -f "$log" ]; then
                # The last line that carries anything. `|| [ -n "$line" ]` keeps
                # a final line with no newline after it, and blank lines are
                # skipped so a log ending in one still reports its last entry.
                # A read that fails anyway — an I/O error, a race with a chmod —
                # reports unreadable rather than a short log, and its complaint
                # is dropped so it cannot arrive as extra protocol keys.
                if { while IFS= read -r line || [ -n "$line" ]; do
                         line=${line%$'\r'}
                         [ -n "${line//[[:space:]]/}" ] || continue
                         last=$line
                     done < "$log"; } 2>/dev/null; then
                    if [ -n "$last" ]; then logstate=ok; else logstate=empty; fi
                else
                    logstate=unreadable
                    last=""
                fi
            fi
        fi

        rows="$rows$(printf '%s %s %s %s %s' \
            "$(printf '%s' "$name" | b64)" "$total" "$running" "$logstate" \
            "$(printf '%s' "$last" | b64)")
"
    done
fi
kv project_count "$count"
kv projects_b64 "$(printf '%s' "$rows" | b64)"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the state of $_SS_TARGET (the remote step exited $rc, see above)"
    [ -n "$out" ] \
        || die "the status probe on $_SS_TARGET succeeded and reported nothing (its output was lost, or the login shell swallowed it)"

    _SS_FACT=()
    _ss_absorb_checked "$out" \
        have_docker docker_server docker_error compose_version \
        apps_state marker_state marker_b64 \
        traefik_present traefik_state traefik_health traefik_image \
        traefik_image_id traefik_container \
        project_count projects_b64
    return 0
}

# --- The marker -------------------------------------------------------------------

# Exit 4 is the same verdict `hosting deploy` reaches, and the remedy is worded
# the same way, for the same reason: a bare `hosting server init <target>` run
# against a server prepared with --apps-path elsewhere renders a second Traefik
# stack under the frozen `traefik` compose project, recreates the running proxy
# against it, and takes every site on the host down. hosting must not print an
# instruction that can do that. What status can offer instead — and deploy
# cannot, because it is a project command — is the flag that looks elsewhere.
_ss_no_marker() {
    local marker_path="$_SS_APPS_PATH/.hosting/server.json"

    err "$_SS_TARGET has no server marker at $marker_path"
    [ "${_SS_FACT[apps_state]}" != absent ] \
        || err_cont "($_SS_APPS_PATH is not there either — the probe found nothing at that path.)"
    err_cont "That file is what \`hosting server init\` writes last, and status looked for it"
    err_cont "there and nowhere else. So this is one of two situations, and they have"
    err_cont "different answers:"
    err_cont "  * the server was prepared with --apps-path=<dir> somewhere other than"
    err_cont "    $_SS_APPS_PATH. Point status at it:"
    err_cont "      hosting server status $_SS_TARGET --apps-path=<dir>"
    err_cont "  * the server has never been prepared, and initialising it is the answer."
    err_cont "Do not re-run init until you know which. Pointed at the wrong apps path it"
    err_cont "renders a second Traefik stack under the frozen 'traefik' compose project,"
    err_cont "which recreates the running proxy against it and takes every site down."
    exit "$HOSTING_EXIT_NO_REMOTE_STATE"
}

_server_status_read_marker() {
    local path="$_SS_APPS_PATH/.hosting/server.json"

    # The apps path itself, before the file inside it: "there is no marker" and
    # "that is not a directory" are different servers, and the probe already
    # knows which one this is.
    case "${_SS_FACT[apps_state]}" in
        dir|absent) ;;
        notdir) die "$_SS_APPS_PATH on $_SS_TARGET exists and is not a directory — point status elsewhere with --apps-path=<dir>" ;;
        *)      die "$_SS_APPS_PATH on $_SS_TARGET is in a state the probe called '${_SS_FACT[apps_state]}', which this hosting does not know" ;;
    esac

    case "${_SS_FACT[marker_state]}" in
        ok) ;;
        absent) _ss_no_marker ;;
        notfile) die "$path on $_SS_TARGET exists and is not a regular file" ;;
        empty)   die "$path on $_SS_TARGET is empty — hosting server init did not finish, or something truncated it" ;;
        *)       die "$path on $_SS_TARGET could not be read" ;;
    esac

    _ss_b64_decode "${_SS_FACT[marker_b64]}" _SS_MARKER \
        || die "the status probe on $_SS_TARGET sent $path back as something that is not base64"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_SS_MARKER" \
        || die "$path on $_SS_TARGET is not a JSON object — look at it before running anything else against this server"

    _SS_MARKER_APPS="$(jq -r '.apps_path // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_DATA="$(jq -r '.data_path // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_VERSION="$(jq -r '.hosting_version // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_CPU="$(jq -r '.cpu_limit // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_MEM="$(jq -r '.mem_limit // "" | tostring' <<<"$_SS_MARKER")"
    return 0
}

# --- versions.log -------------------------------------------------------------------

# One line of docs/build-deploy.md's frozen format:
#
#   <iso-timestamp> <action> <version> <backup-or-no-backup> hosting=<v> digest=<…|->
#
# The four positional fields are frozen forever; everything after them is
# key=value pairs, and a line written by a newer hosting carries pairs this one
# has never heard of. So the tail is scanned for the one key worth printing and
# every other pair is ignored rather than rejected — the alternative is a status
# command that stops working the first time a later phase appends a field.
#
# Returns 1 for a line that does not carry the four fields, which is a real
# state: a truncated write, or somebody's note in the file.
_ss_parse_log_line() {
    local _pl_line="${1%$'\r'}"
    local _pl_ts_out="$2" _pl_action_out="$3" _pl_version_out="$4" _pl_backup_out="$5" _pl_hosting_out="$6"
    local _pl_ts="" _pl_action="" _pl_version="" _pl_backup="" _pl_rest="" _pl_tok
    local _pl_hosting=""
    local _pl_pairs=()

    printf -v "$_pl_ts_out" '%s' ""
    printf -v "$_pl_action_out" '%s' ""
    printf -v "$_pl_version_out" '%s' ""
    printf -v "$_pl_backup_out" '%s' ""
    printf -v "$_pl_hosting_out" '%s' ""

    read -r _pl_ts _pl_action _pl_version _pl_backup _pl_rest <<<"$_pl_line"
    [ -n "$_pl_ts" ] && [ -n "$_pl_action" ] && [ -n "$_pl_version" ] && [ -n "$_pl_backup" ] \
        || return 1
    # The timestamp's leading date, which is the one part of field 1 the format
    # fixes. It separates a hosting entry from a line of prose without pinning
    # anything a later hosting might legitimately change.
    [[ "$_pl_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 1

    # `read -ra` and not `for tok in $rest`: the tail is the part a later hosting
    # gets to invent, so a pair holding `*`, `?` or `[…]` would be expanded
    # against whatever directory the operator happens to be standing in. Measured:
    # in a directory containing a file named `hosting=EVIL`, a line ending in `*`
    # reported that file's name as the hosting version.
    read -ra _pl_pairs <<<"$_pl_rest"
    for _pl_tok in ${_pl_pairs[@]+"${_pl_pairs[@]}"}; do
        case $_pl_tok in
            hosting=*) _pl_hosting="${_pl_tok#hosting=}" ;;
        esac
    done

    printf -v "$_pl_ts_out" '%s' "$_pl_ts"
    printf -v "$_pl_action_out" '%s' "$_pl_action"
    printf -v "$_pl_version_out" '%s' "$_pl_version"
    printf -v "$_pl_backup_out" '%s' "$_pl_backup"
    printf -v "$_pl_hosting_out" '%s' "$_pl_hosting"
    return 0
}

# --- The project table ------------------------------------------------------------

# `<name-b64> <total> <running> <logstate> <log-b64>`, one row per project. The
# two free-form values travel base64'd, so a project directory whose name
# carries a space — or a versions.log line, which always does — cannot be
# mistaken for another column.
#
# One row is dropped here rather than on the far side: the bind-mount root, when
# `--data-path` put it inside the apps path under a name the remote step could
# not know. The static list it filters with is hosting's three reserved names,
# and `--data-path=<apps>/store` is neither reserved nor a project — it is
# hosting's own directory, and the marker is the only thing that says so.
_ss_decode_projects() {
    local table row name_b64 total running logstate log_b64 rest name log
    local data_dir="" described=0

    _SS_P_NAME=()
    _SS_P_TOTAL=()
    _SS_P_RUNNING=()
    _SS_P_LOGSTATE=()
    _SS_P_LOG=()

    case "$_SS_MARKER_DATA" in
        "$_SS_APPS_PATH"/?*)
            data_dir="${_SS_MARKER_DATA#"$_SS_APPS_PATH"/}"
            # Only a direct child is one of the entries the walk saw.
            case $data_dir in */*) data_dir="" ;; esac
            ;;
    esac

    _ss_b64_decode "${_SS_FACT[projects_b64]}" table \
        || die "the status probe on $_SS_TARGET sent a project table that is not base64"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read -r name_b64 total running logstate log_b64 rest <<<"$row"
        if [ -z "$name_b64" ] || [ -z "$logstate" ] || [ -n "$rest" ]; then
            err "the status probe on $_SS_TARGET returned a project row it did not build: '$row'"
            exit 1
        fi
        described=$((described + 1))
        _ss_b64_decode "$name_b64" name \
            || die "the status probe on $_SS_TARGET sent a project name that is not base64: '$name_b64'"
        _ss_b64_decode "$log_b64" log \
            || die "the status probe on $_SS_TARGET sent $name's versions.log line as something that is not base64"
        [ "$name" != "$data_dir" ] || continue

        _SS_P_NAME+=("$name")
        _SS_P_TOTAL+=("$total")
        _SS_P_RUNNING+=("$running")
        _SS_P_LOGSTATE+=("$logstate")
        _SS_P_LOG+=("$log")
    done <<<"$table"

    # The count and the table are two statements about the same walk, so a
    # disagreement means one of them was truncated in transit. Counted before
    # the data directory is dropped, since the far side counted it too.
    if [ "$described" != "${_SS_FACT[project_count]}" ]; then
        err "the status probe on $_SS_TARGET counted ${_SS_FACT[project_count]} projects and described $described"
        err_cont "the payload was truncated — nothing below it can be trusted"
        exit 1
    fi
    return 0
}

# --- Output --------------------------------------------------------------------------

# Whatever the container itself says, rather than a state hosting infers: a
# stopped Traefik and a running-but-unhealthy one are different problems.
_ss_print_traefik() {
    local health

    if [ "${_SS_FACT[traefik_present]}" != yes ]; then
        if [ "${_SS_FACT[have_docker]}" != yes ] || [ -n "${_SS_FACT[docker_error]}" ]; then
            printf 'Traefik: unknown — docker did not answer\n'
        else
            printf "Traefik: absent — no container in compose project 'traefik'\n"
        fi
        return 0
    fi

    # A container was found, so an empty value here is an inspect that did not
    # answer — a race with a `docker rm`, or a daemon that went away between two
    # calls. The key arrived, which is all the protocol check can see; printing
    # `Traefik:  (healthy)` off it would be the plausible-looking line this
    # command exists not to produce.
    if [ -z "${_SS_FACT[traefik_state]}" ] || [ -z "${_SS_FACT[traefik_health]}" ] \
       || [ -z "${_SS_FACT[traefik_image]}" ]; then
        printf 'Traefik: unknown — docker named a container and then did not describe it\n'
        printf '  state %s / health %s / image %s\n' \
            "${_SS_FACT[traefik_state]:-<none>}" "${_SS_FACT[traefik_health]:-<none>}" \
            "${_SS_FACT[traefik_image]:-<none>}"
        return 0
    fi

    health="${_SS_FACT[traefik_health]}"
    case $health in
        none) printf 'Traefik: %s (no healthcheck)\n' "${_SS_FACT[traefik_state]}" ;;
        *)    printf 'Traefik: %s (%s)\n' "${_SS_FACT[traefik_state]}" "$health" ;;
    esac
    # The tag it was created from and the image that tag resolved to. The second
    # is what says whether two servers on `traefik:v3.7.10` are running the same
    # bytes: a tag can be re-pushed, an id cannot. Shortened the way docker's own
    # output shortens it — 12 hex digits after the algorithm.
    printf '  Image: %s (%s)\n' \
        "${_SS_FACT[traefik_image]}" "${_SS_FACT[traefik_image_id]:0:19}"
    printf '  Container: %s\n' "${_SS_FACT[traefik_container]}"
    return 0
}

_ss_print_projects() {
    local i name state version deployed detail ts action backup hosting note

    printf 'Projects:\n'
    if [ "${#_SS_P_NAME[@]}" -eq 0 ]; then
        printf '  none — no project directory under %s\n' "$_SS_APPS_PATH"
        return 0
    fi

    for i in "${!_SS_P_NAME[@]}"; do
        name="${_SS_P_NAME[$i]}"
        version="-"
        deployed=""
        note=""

        case "${_SS_P_LOGSTATE[$i]}" in
            ok)
                if _ss_parse_log_line "${_SS_P_LOG[$i]}" ts action version backup hosting; then
                    deployed="$action $ts"
                    [ -z "$hosting" ] || deployed="$deployed (hosting $hosting)"
                else
                    version="?"
                    note="versions.log's last line is not a hosting entry: ${_SS_P_LOG[$i]}"
                fi
                ;;
            missing)    note="no versions.log — never deployed by hosting, or dropped" ;;
            empty)      note="versions.log is empty" ;;
            notfile)    note="versions.log exists and is not a regular file" ;;
            unreadable) note="versions.log cannot be read by the ssh user" ;;
            noaccess)   note="the directory cannot be read by the ssh user — a deploy that ran as root leaves this" ;;
            notdir)     note="not a directory — hosting deploys into directories only" ;;
            *)          note="unknown versions.log state '${_SS_P_LOGSTATE[$i]}'" ;;
        esac

        # The counts say what docker reports and the word says what it means:
        # `1/1 running`, `0/2 stopped`, `1/3 partial` (docs/server-setup.md's
        # sample). The word is not decoration — `0/1 running` is a small lie,
        # and "is this site up" is the question the column is read for.
        if [ "${_SS_P_LOGSTATE[$i]}" = notdir ]; then
            state="-"
        elif [ "${_SS_FACT[have_docker]}" != yes ] || [ -n "${_SS_FACT[docker_error]}" ]; then
            state="?"
        elif [ "${_SS_P_TOTAL[$i]}" = 0 ]; then
            state="no containers"
        elif [ "${_SS_P_RUNNING[$i]}" = "${_SS_P_TOTAL[$i]}" ]; then
            state="${_SS_P_RUNNING[$i]}/${_SS_P_TOTAL[$i]} running"
        elif [ "${_SS_P_RUNNING[$i]}" = 0 ]; then
            state="0/${_SS_P_TOTAL[$i]} stopped"
        else
            state="${_SS_P_RUNNING[$i]}/${_SS_P_TOTAL[$i]} partial"
        fi

        # One row per project, and the last column is either the deploy it last
        # recorded or why there is none — never both, since a line that parsed
        # is not a line to explain.
        detail="$deployed"
        [ -n "$detail" ] || detail="$note"
        printf '  %-14s %-14s %-10s %s\n' "$name" "$state" "$version" "$detail"
    done
    return 0
}

_server_status_print() {
    printf 'VPS: %s (connected)\n' "$_SS_TARGET"
    if [ -n "${_SS_FACT[docker_server]}" ]; then
        printf 'Docker: %s, Compose: %s\n' \
            "${_SS_FACT[docker_server]}" "${_SS_FACT[compose_version]:-unknown}"
    else
        printf 'Docker: unavailable — %s\n' "${_SS_FACT[docker_error]:-no docker command on the remote}"
    fi
    printf 'Root: %s  Data: %s\n' "$_SS_APPS_PATH" "${_SS_MARKER_DATA:-unknown}"
    printf 'Marker: hosting %s, cpu %s, mem %s\n' \
        "${_SS_MARKER_VERSION:-unknown}" "${_SS_MARKER_CPU:-unknown}" "${_SS_MARKER_MEM:-unknown}"

    # The marker is the record of where init put things; the apps path is where
    # this run looked. They disagree when a prepared tree was moved, and every
    # path printed above the line is the one that was actually read.
    if [ -n "$_SS_MARKER_APPS" ] && [ "$_SS_MARKER_APPS" != "$_SS_APPS_PATH" ]; then
        warn "the marker records apps_path=$_SS_MARKER_APPS, and this status read $_SS_APPS_PATH"
    fi

    printf '\n'
    _ss_print_traefik
    printf '\n'
    _ss_print_projects
    printf '\nCerts, mail and disk usage are not reported yet (Phase 7).\n'
    return 0
}

# --- Command ----------------------------------------------------------------------

cmd_server_status() {
    _server_status_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    ssh_connect "$_SS_TARGET"

    _server_status_collect
    _server_status_read_marker
    _ss_decode_projects

    # Only a difference in majors is worth a word: within one, docs/overview.md's
    # compatibility policy says everything interoperates. Unlike `server init`
    # this is a warning rather than a refusal — a read-only report that will not
    # print because the server is ahead of the reader is missing at the moment it
    # is most wanted. Versions that cannot be compared add nothing here; the
    # Marker line prints what the file says either way.
    local marker_major="${_SS_MARKER_VERSION%%.*}" ours="${HOSTING_VERSION%%.*}"
    if [[ "$marker_major" =~ ^[0-9]+$ ]] && [[ "$ours" =~ ^[0-9]+$ ]] \
       && [ "$marker_major" != "$ours" ]; then
        warn "the marker was written by hosting $_SS_MARKER_VERSION and this is hosting $HOSTING_VERSION"
        warn "different majors — fields this version does not know about are not shown"
    fi

    _server_status_print
}
