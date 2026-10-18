# kasbah — server destroy: take kasbah's management layer off a VPS
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_SERVER_DESTROY_LOADED:-}" ] && return 0
_KASBAH_SERVER_DESTROY_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
# For _vlog_b64_decode alone: every value the probes send that could carry a
# space or a newline comes back base64'd, and one decoder is what keeps two
# readers of the same wire format from disagreeing.
. "$KASBAH_LIB_DIR/versions_log.sh"
# For ENV_MANAGED_BEGIN / ENV_MANAGED_END alone. They are handed to both remote
# payloads as arguments rather than copied into their heredocs: the sentinels
# are frozen strings an older kasbah's block must still be recognised by
# (lib/env.sh), and a copy on the far side of ssh is a copy no suite can see
# drift in. lib/check.sh sources this file into kasbah's own shell for the same
# reason — one definition of what a managed block looks like.
. "$KASBAH_LIB_DIR/env.sh"

# `kasbah server destroy USER@HOST` — the handover verb (docs/cli.md → server
# destroy, docs/server-setup.md → Handover / teardown, as amended by
# docs/phases/08-keep.md D8).
#
# **Every container keeps running.** Projects and Traefik alike: the sites stay
# up through the whole operation and after the next restart. What leaves is
# kasbah's management layer — the marker, the discovery pointer, the backup
# stack and its credentials, the per-project deploy record and helpers, the
# `.env` managed-block sentinel comments, and the operator's mail relay block.
# The VPS passes to a client or another operator as a plain, working Docker
# Compose host, and no agency-owned secret goes with it.
#
# Three round trips: the marker read every server command makes (lib/marker.sh),
# one batched read of everything the plan is decided from, and one act after the
# operator has answered twice. Nothing structured is parsed on the far side —
# the VPS keeps needing no yq, jq or python3 (docs/server-setup.md).
#
# **The order the act runs in is the order the report prints**, and it is chosen
# so a run that dies half way can be re-run: the backup stack first (a schedule
# left running would go on pushing the new owner's data into the departing
# agency's storage, which is the sharpest form of "agency-owned secrets never
# transfer"), then each project, then mail, and the **marker and the discovery
# pointer last of all** — and only when everything before them succeeded. They
# are how a later run finds this server at all, so a failed run keeps them.

_SD_TARGET=""
# "yes" when --yes was passed, empty when it was not. Empty means *ask*
# (docs/overview.md → Interactivity); it never means no.
_SD_YES=""

_SD_APPS_PATH=""
_SD_DATA_PATH=""
# lib/marker.sh's own first line, when it refused. Empty on a run that found a
# marker.
_SD_MARKER_REASON=""
# The fallback probe's answers, for a server with no marker at all.
_SD_LEFT_POINTER=no
_SD_LEFT_KASBAH=""
_SD_LEFT_CREDS=""

declare -A _SD_FACT=()

# The projects on the server, in the order the act walks them, and the
# per-project verdicts the act reported. Parallel arrays keyed by index.
_SD_PROJECTS=()
_SD_ACT_PROJECTS=()
declare -A _SD_ACT_ROW=()

# The compose project, container, cache volume and default network the backup
# stack leaves behind (templates/backup/compose.yml). The volume carries an
# explicit `name:` in that template precisely so this command can name it: a
# compose project brought down without its file reaps anonymous volumes only.
_SD_BACKUP_PROJECT=kasbah-backup
_SD_BACKUP_CONTAINER=kasbah-backup
_SD_BACKUP_VOLUME=kasbah-backup-cache
_SD_BACKUP_NETWORK=kasbah-backup_default

# The two helpers `kasbah deploy` installs in <apps>/<project>/scripts/
# (lib/deploy.sh → _deploy_sync_helper). Named rather than the directory
# removed whole: the directory is kasbah's by convention, but a file in it that
# kasbah did not put there belongs to whoever did, and this command has no way
# to tell them apart except by name. The directory itself goes when those two
# were all it held.
_SD_HELPERS=(remote-deploy.sh setup-env.sh)

# The three keys of <apps>/mail/.env that are kasbah's (docs/server-setup.md →
# With mail; templates/mail/env). Compose and docker-mailserver interpolate all
# three, so they stay and the stack still starts. Every other line goes: the
# operator's relay block lives there, and a line kasbah did not write is a line
# it cannot prove is not a credential.
_SD_MAIL_KEYS=(MAIL_HOSTNAME DOMAIN DATA_PATH)

# The fixed names kasbah owns under the apps path, which are never projects —
# the same list `drop`, `server status` and `server prune` walk past.
_SD_RESERVED=(.kasbah "${KASBAH_RESERVED_NAMES[@]}")

_server_destroy_usage() {
    cat <<EOF
Usage: kasbah server destroy USER@HOST [--yes]

De-brands a VPS for handover. Every container keeps running — projects **and**
Traefik — so the sites stay up through the whole operation and after the next
restart. What leaves is kasbah's management layer:

  removed   <apps>/.kasbah/ (the server marker, the backup stack and its
            credentials), $KASBAH_APPS_POINTER, and per project:
            versions.log(.gz), the scripts/ helpers, .deploy.lock,
            .kasbah-client, and the .env managed-block sentinel comments
  mail      the operator's relay block in <apps>/mail/.env — every line that is
            not MAIL_HOSTNAME, DOMAIN or DATA_PATH — and <apps>/mail/kasbah.yml
  kept      every container, every compose.yml, every .env **value**, the
            Traefik stack and its fragments, <data>/, <apps>/<project>/backups/,
            named volumes, images, the postmaster account, and the off-VPS
            restic repositories (operator property — docs/backup.md)

The trade is explicit and permanent: deploy history, the mail domain registry
and env tooling leave with kasbah, and no later \`server init\` can reproduce
them.

  --yes     answer both confirmations, for scripts. Without it and without a
            terminal, destroy stops rather than assuming.

Confirmation is double: a yes/no question, then the hostname typed back.
EOF
}

# --- Command line -----------------------------------------------------------------

_sd_parse_args() {
    _SD_TARGET=""
    _SD_YES=""

    # Every argument meets the case with its CR already off, not only the
    # positional one: a command line that came through a CRLF-mangled script
    # otherwise reaches the unknown-flag branch holding a flag this command has
    # (docs/compliance.md — strip \r before matching anything user-authored).
    local arg
    while [ $# -gt 0 ]; do
        arg="${1%$'\r'}"
        case "$arg" in
            -h|--help) _server_destroy_usage; exit 0 ;;
            --yes)     _SD_YES=yes ;;
            # `--yes=yes` is a flag this command has, spelled wrong. Refusing it
            # as unknown while listing it as known is a message arguing with
            # itself.
            --yes=*)
                die "server destroy: --yes takes no value — pass it on its own (\`kasbah server destroy USER@HOST --yes\`)" ;;
            -*) die "server destroy: unknown flag '${arg%%=*}' (destroy takes USER@HOST and --yes)" ;;
            *)
                [ -z "$_SD_TARGET" ] \
                    || die "server destroy: two servers given ('$_SD_TARGET' and '$arg') — one run goes to one server"
                _SD_TARGET="$arg"
                ;;
        esac
        shift
    done
    [ -n "$_SD_TARGET" ] \
        || die "server destroy: no server given (expected \`kasbah server destroy USER@HOST\`)"
    return 0
}

# --- Discovery ----------------------------------------------------------------------

# lib/marker.sh's read, run where its refusals cannot end this command.
#
# `marker_read` exits 4 on a server that carries no marker where discovery
# leads — which is exactly the state a completed destroy leaves behind, and a
# second run must be able to say so rather than fail. In a subshell its exit is
# its own; the two paths come back on stdout and its first line comes back as
# the reason. (The same shape lib/drop.sh uses around `_sm_read_registry`.)
#
# Returns 0 with the paths set, 4 when there is no marker to work from, or the
# reader's own status for anything else.
_sd_marker_read() {
    local _sm_err _sm_body _sm_rc=0 _sm_lines=()

    _SD_MARKER_REASON=""
    _sm_err="$(mktemp "${TMPDIR:-/tmp}/kasbah-destroy-marker.XXXXXX")" \
        || die "could not create a temp file to read the server marker with"
    _sm_body=$( { marker_read "$_SD_TARGET" >/dev/null
                  printf '%s\n%s\n' "$MARKER_APPS_PATH" "$MARKER_DATA_PATH"
                } 2>"$_sm_err" ) || _sm_rc=$?

    if [ "$_sm_rc" -ne 0 ]; then
        # The reader's first line, without the `error:` prefix or the colour it
        # may have decided on from this process's own stderr.
        _SD_MARKER_REASON="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^error: //' -e 1q "$_sm_err")"
        _SD_MARKER_REASON="${_SD_MARKER_REASON%$'\r'}"
        if [ "$_sm_rc" -ne "$KASBAH_EXIT_NO_REMOTE_STATE" ]; then
            # Not "there is no marker": a pointer nobody can read, a marker that
            # is not JSON, limits the marker does not carry. Those are the
            # reader's to explain, in its own words.
            cat "$_sm_err" >&2
        fi
        rm -f "$_sm_err"
        return "$_sm_rc"
    fi
    rm -f "$_sm_err"

    readarray -t _sm_lines <<<"$_sm_body"
    [ "${#_sm_lines[@]}" -ge 2 ] \
        || die "internal: the marker read on $_SD_TARGET yielded no paths"
    _SD_APPS_PATH="${_sm_lines[0]}"
    _SD_DATA_PATH="${_sm_lines[1]}"
    return 0
}

# What a server with no marker may still be carrying. One extra round trip, on
# the one path where this command would otherwise hand out a clean bill of
# health it has not earned:
#
#   * the discovery pointer, root-owned in /etc — the state a first run leaves
#     whenever it had no passwordless sudo;
#   * `<apps>/.kasbah/` at the default apps path and at whatever the pointer
#     names, **`backup/` above all**. A marker removed by hand leaves the whole
#     of this command unable to enumerate anything, and the credentials are
#     still sitting there at mode 600 — saying "there is no marker, but there
#     are still credentials at X" is worth far more than calling that clean.
#
# The pointer's value is used exactly as it reads, unnormalised: kasbah's four
# `norm_path` copies are pinned byte-identical by tests/norm_path_test.sh and a
# fifth would be drift no suite can see. A spelling this does not recognise
# costs a probe of one directory, never a wrong verdict.
_sd_probe_leftovers() {
    local out rc=0 line

    _SD_LEFT_POINTER=no
    _SD_LEFT_KASBAH=""
    _SD_LEFT_CREDS=""
    out=$(ssh_script "$KASBAH_APPS_POINTER" "$KASBAH_DEFAULT_APPS_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
pointer=$1
default=$2

if [ -e "$pointer" ]; then printf 'pointer=yes\n'; else printf 'pointer=no\n'; fi

pointed=""
if [ -f "$pointer" ] && [ -r "$pointer" ]; then
    IFS= read -r pointed < "$pointer" || [ -n "$pointed" ] || pointed=""
    pointed=${pointed%$'\r'}
    case $pointed in /?*) ;; *) pointed="" ;; esac
fi
seen=" "
for dir in "$default" "$pointed"; do
    [ -n "$dir" ] || continue
    case $seen in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    [ -d "$dir/.kasbah" ] || continue
    printf 'kasbah=%s\n' "$dir/.kasbah"
    [ ! -d "$dir/.kasbah/backup" ] || printf 'creds=%s\n' "$dir/.kasbah/backup"
done
exit 0
REMOTE
    ) || rc=$?
    [ "$rc" -eq 0 ] || return 1

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case $line in
            pointer=yes) _SD_LEFT_POINTER=yes ;;
            kasbah=*)    _SD_LEFT_KASBAH="$_SD_LEFT_KASBAH${line#kasbah=} " ;;
            creds=*)     _SD_LEFT_CREDS="$_SD_LEFT_CREDS${line#creds=} " ;;
        esac
    done <<<"$out"
    return 0
}

# --- The batched read ----------------------------------------------------------------

# Folds the report into the fact table and checks the key set as a protocol
# before any value is read: a truncated step must not be absorbed into a plan
# that ends in a deletion. Clipped to twenty lines of 120 bytes, because two of
# these values are base64 blobs that grow with the server.
_sd_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_shown=0
    local _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _SD_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_SD_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the destroy probe on $_SD_TARGET reported no ${_ac_missing[*]}"
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

_sd_collect() {
    local out rc=0

    out=$(ssh_script "$_SD_APPS_PATH" "$KASBAH_APPS_POINTER" \
                     "${_SD_RESERVED[*]}" "$_SD_BACKUP_CONTAINER" \
                     "$_SD_BACKUP_VOLUME" "$_SD_BACKUP_NETWORK" \
                     "$ENV_MANAGED_BEGIN" "$ENV_MANAGED_END" \
                     "${_SD_HELPERS[*]}" "${_SD_MAIL_KEYS[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
pointer=$2
reserved=" $3 "
bcontainer=$4
bvolume=$5
bnetwork=$6
env_begin=$7
env_end=$8
helpers=$9
mail_keys=${10}

# One line per value: the reader parses this output as a protocol, so a
# command's multi-line complaint would arrive as extra keys. Anything that can
# carry a newline or a space of its own — a project name, a listing — is
# base64'd instead.
kv() {
    local v="$2"
    while [ "${v: -1}" = " " ]; do v="${v% }"; done
    printf '%s=%s\n' "$1" "$v"
}
flat() { tr -d '\r' | tr '\n' ' '; }
# openssl rather than coreutils' `base64 -w0`: openssl is on the prerequisites
# table (docs/server-setup.md) and base64 is not.
b64() { openssl base64 -A 2>/dev/null; }

# The same seven words `drop`, `server status`, `server prune` and
# lib/versions_log.sh report a file in. Two commands describing one server two
# ways is what the shared spelling exists to prevent.
state_of() {
    if [ -e "$1" ] && [ ! -f "$1" ]; then printf notfile;    return 0; fi
    if [ ! -f "$1" ]; then                printf missing;    return 0; fi
    if [ ! -r "$1" ]; then                printf unreadable; return 0; fi
    if [ ! -s "$1" ]; then                printf empty;      return 0; fi
    printf ok
}
dir_state() {
    if [ -d "$1" ]; then
        if [ -r "$1" ] && [ -x "$1" ]; then printf dir; else printf noaccess; fi
    elif [ -e "$1" ]; then printf notdir
    else printf absent
    fi
}
# Entries in a directory, dotfiles included, whether or not any of the names in
# $2 are among them. Two numbers: how many of those named are there, and how
# many other entries there are.
count_dir() {   # count_dir <dir> <name>... -> "<named> <other>"
    local d=$1 named=0 other=0 f base want n
    shift
    if [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ]; then
        shopt -s nullglob dotglob
        for f in "$d"/*; do
            base=${f##*/}
            want=no
            for n in "$@"; do [ "$base" != "$n" ] || want=yes; done
            if [ "$want" = yes ]; then named=$((named + 1)); else other=$((other + 1)); fi
        done
        shopt -u nullglob dotglob
    fi
    printf '%s %s' "$named" "$other"
}
# How many lines of a file are one of kasbah's managed-block sentinels. The two
# strings arrive as arguments, so this side owns no copy of them.
count_sentinels() {
    local f=$1 line n=0
    [ -f "$f" ] && [ -r "$f" ] || { printf 0; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        case ${line%$'\r'} in
            "$env_begin"|"$env_end") n=$((n + 1)) ;;
        esac
    done < "$f"
    printf '%s' "$n"
}
# How many lines of <apps>/mail/.env are not one of kasbah's three keys — the
# operator's relay block, every comment the template shipped, and anything hand
# added. Compose trims leading blanks and honours `export `, so this does too.
count_mail_extra() {
    local f=$1 line stripped n=0 k keep
    [ -f "$f" ] && [ -r "$f" ] || { printf 0; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        stripped=${line%$'\r'}
        while :; do
            case $stripped in
                " "*|"	"*) stripped=${stripped#?} ;;
                *) break ;;
            esac
        done
        case $stripped in export[" 	"]*) stripped=${stripped#export}
            while :; do
                case $stripped in " "*|"	"*) stripped=${stripped#?} ;; *) break ;; esac
            done ;;
        esac
        keep=no
        for k in $mail_keys; do
            case $stripped in "$k="*) keep=yes ;; esac
        done
        [ "$keep" = yes ] || n=$((n + 1))
    done < "$f"
    printf '%s' "$n"
}

if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_error ""
else
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi

kv apps_state "$(dir_state "$apps")"
kv marker_state "$(state_of "$apps/.kasbah/server.json")"
kv kasbah_dir "$(dir_state "$apps/.kasbah")"
# What else is under <apps>/.kasbah besides the two things this command removes.
# While there is one, the directory stays and the report says which — a newer
# kasbah's file is not this one's to delete.
extra=""
if [ -d "$apps/.kasbah" ] && [ -r "$apps/.kasbah" ] && [ -x "$apps/.kasbah" ]; then
    shopt -s nullglob dotglob
    for f in "$apps"/.kasbah/*; do
        case ${f##*/} in server.json|backup) continue ;; esac
        extra="$extra${f##*/} "
    done
    shopt -u nullglob dotglob
fi
kv kasbah_extra_b64 "$(printf '%s' "$extra" | b64)"

kv backup_dir "$(dir_state "$apps/.kasbah/backup")"
if [ "$docker_rc" -eq 0 ]; then
    if docker container inspect "$bcontainer" >/dev/null 2>&1; then
        kv backup_container "$(docker container inspect -f '{{.State.Status}}' "$bcontainer" 2>/dev/null | flat)"
    else
        kv backup_container absent
    fi
    if docker volume inspect "$bvolume" >/dev/null 2>&1; then kv backup_volume present; else kv backup_volume absent; fi
    if docker network inspect "$bnetwork" >/dev/null 2>&1; then kv backup_network present; else kv backup_network absent; fi
else
    kv backup_container unknown
    kv backup_volume unknown
    kv backup_network unknown
fi

# The discovery pointer. Root-owned and world-readable by contract, so reading
# it needs no elevation — only removing it does, and that is asked separately.
kv pointer_state "$(state_of "$pointer")"
kv pointer_dir "$(dir_state "${pointer%/*}")"
set -- $(count_dir "${pointer%/*}" "${pointer##*/}")
kv pointer_dir_other "$2"
if [ "$(id -u)" = 0 ]; then
    kv sudo_state root
elif sudo -n true >/dev/null 2>&1; then
    kv sudo_state yes
else
    kv sudo_state no
fi

kv mail_dir "$(dir_state "$apps/mail")"
kv mail_env_state "$(state_of "$apps/mail/.env")"
kv mail_env_extra "$(count_mail_extra "$apps/mail/.env")"
kv mail_registry_state "$(state_of "$apps/mail/kasbah.yml")"

# One row per project: everything under the apps path that is not one of
# kasbah's own directories, and the state of each artifact this command removes
# from it. dotglob is on because `.kasbah` is skipped by name rather than by
# being hidden.
#
# Eleven positional fields, whitespace-separated, none of them ever empty — the
# reader splits the row and a run of whitespace collapses, so an empty field in
# the middle would shift every field after it left by one.
rows=""
count=0
skipped=""
if [ -d "$apps" ]; then
    shopt -s nullglob dotglob
    for path in "$apps"/*; do
        pname=${path##*/}
        case $reserved in *" $pname "*) continue ;; esac
        # A project name is `^[a-z][a-z0-9-]*$` (docs/project-manifest.md), and
        # nothing else under the apps path is a project: `README.md`, `site.bak`
        # and `.DS_Store` are all plausible there, and they belong to whoever put
        # them there. Filtered here rather than refused in the act, where one of
        # them would `fail` the whole command *after* both confirmations — the
        # act's identical guard stays as the last word that trusts nothing this
        # side assembled, and simply stops being reachable in the ordinary case.
        case $pname in
            [a-z]*) ;;
            *) skipped="$skipped$pname "; continue ;;
        esac
        case $pname in
            *[!a-z0-9-]*) skipped="$skipped$pname "; continue ;;
        esac
        count=$((count + 1))
        dstate=$(dir_state "$path")
        set -- $(count_dir "$path/scripts" $helpers)
        rows="$rows$(printf '%s %s %s %s %s %s %s %s %s %s %s' \
            "$(printf '%s' "$pname" | b64)" \
            "$dstate" \
            "$(state_of "$path/versions.log")" \
            "$(state_of "$path/versions.log.gz")" \
            "$(dir_state "$path/scripts")" \
            "$1" "$2" \
            "$(state_of "$path/.deploy.lock")" \
            "$(state_of "$path/.kasbah-client")" \
            "$(state_of "$path/.env")" \
            "$(count_sentinels "$path/.env")")
"
    done
    shopt -u nullglob dotglob
fi
kv project_count "$count"
kv projects_b64 "$(printf '%s' "$rows" | b64)"
kv skipped_b64 "$(printf '%s' "$skipped" | b64)"

exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the destroy probe on $_SD_TARGET exited $rc"
        err_cont "nothing was removed — destroy reads the whole server before it changes anything"
        exit 1
    fi

    _sd_absorb_checked "$out" \
        have_docker docker_error apps_state marker_state kasbah_dir kasbah_extra_b64 \
        backup_dir backup_container backup_volume backup_network \
        pointer_state pointer_dir pointer_dir_other sudo_state \
        mail_dir mail_env_state mail_env_extra mail_registry_state \
        project_count projects_b64 skipped_b64
    return 0
}

# Docker and the apps path, in that order: the first makes the second's question
# meaningless. The marker has already been read.
_sd_check_server() {
    if [ "${_SD_FACT[have_docker]}" != yes ] || [ -n "${_SD_FACT[docker_error]}" ]; then
        err "docker did not answer on $_SD_TARGET"
        [ -z "${_SD_FACT[docker_error]}" ] || err_cont "${_SD_FACT[docker_error]}"
        err_cont "the backup stack cannot be stopped without it, and a de-branding that leaves"
        err_cont "the schedule running would go on pushing this server's data into the"
        err_cont "departing operator's storage — nothing was removed"
        exit 1
    fi
    case "${_SD_FACT[apps_state]}" in
        dir) ;;
        notdir) die "$_SD_APPS_PATH on $_SD_TARGET is not a directory" ;;
        noaccess) die "$_SD_APPS_PATH on $_SD_TARGET cannot be entered by this user — destroy walks every project there" ;;
        *)
            err "$_SD_APPS_PATH on $_SD_TARGET is not there"
            err_cont "the server marker names it, so this server's layout and its tree disagree"
            err_cont "— nothing was removed"
            exit "$KASBAH_EXIT_NO_REMOTE_STATE"
            ;;
    esac
    return 0
}

# A positional field of the project table, where `-` means "this value is
# empty". `-` is not in the base64 alphabet.
_sd_b64_field() {
    local _bf_out="$2"
    if [ "$1" = - ]; then
        printf -v "$_bf_out" '%s' ""
        return 0
    fi
    _vlog_b64_decode "$1" "$_bf_out" || return 1
    return 0
}

# The project table, decoded into one `name|field|field|…` string per project,
# in the order the far side walked them — which is the order the act walks them
# and the order the report prints them.
_sd_decode_projects() {
    local table row name described=0 data_dir=""

    _SD_PROJECTS=()

    # The bind-mount root is a directory under the apps path whenever
    # --data-path put it there, and it is not one of the fixed reserved names.
    # Counted as a project it would be walked for a versions.log it can never
    # have. `drop`, `server status` and `server prune` drop the same row from
    # the same fact.
    case "$_SD_DATA_PATH" in
        "$_SD_APPS_PATH"/?*)
            data_dir="${_SD_DATA_PATH#"$_SD_APPS_PATH"/}"
            case $data_dir in */*) data_dir="" ;; esac
            ;;
    esac

    _sd_b64_field "${_SD_FACT[projects_b64]:--}" table \
        || die "the destroy probe on $_SD_TARGET sent a project table that is not base64"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        # shellcheck disable=SC2086
        set -- $row
        if [ "$#" -ne 11 ]; then
            err "the destroy probe on $_SD_TARGET returned a project row it did not build: '$row'"
            err_cont "eleven fields were expected and $# arrived — the payload was truncated,"
            err_cont "and nothing was removed"
            exit 1
        fi
        described=$((described + 1))
        _vlog_b64_decode "$1" name \
            || die "the destroy probe on $_SD_TARGET sent a project name that is not base64: '$1'"
        # After `described`, because the far side counted it too.
        if [ -n "$data_dir" ] && [ "$name" = "$data_dir" ]; then
            continue
        fi
        shift
        # The rows are joined with `|` and split on it again by _sd_field, so a
        # name carrying one — or a space — would shift every field of the plan
        # line before the act's own guard ever saw it. The probe already refuses
        # to call such an entry a project, so one arriving here is a protocol
        # violation rather than a state, and it is said as one.
        case $name in
            [a-z]*) ;;
            *) die "the destroy probe on $_SD_TARGET described '$name' as a project, and that is not a project name" ;;
        esac
        case $name in
            *[!a-z0-9-]*) die "the destroy probe on $_SD_TARGET described '$name' as a project, and that is not a project name" ;;
        esac
        # Joined by hand rather than through `IFS='|'` and `${fields[*]}`: a
        # local IFS set inside this loop would still be in force at the next
        # iteration's `set -- $row`, which splits on whitespace.
        _SD_PROJECTS+=("$name|$1|$2|$3|$4|$5|$6|$7|$8|$9|${10}")
    done <<<"$table"

    # The count and the table are two statements about the same walk, so a
    # disagreement means one of them was truncated in transit.
    if [ "$described" != "${_SD_FACT[project_count]}" ]; then
        err "the destroy probe on $_SD_TARGET counted ${_SD_FACT[project_count]} projects and described $described"
        err_cont "the payload was truncated — nothing was removed"
        exit 1
    fi
    return 0
}

# _sd_field <row> <n> — the nth field of a decoded project row, 0 being the name.
# The index is taken *before* `set --`, which overwrites $2.
_sd_field() {
    local _f_row="$1" _f_n=$(( $2 + 1 ))
    local IFS='|'
    # shellcheck disable=SC2086
    set -- $_f_row
    printf '%s' "${!_f_n}"
    return 0
}

# --- The plan --------------------------------------------------------------------------

# Whether this run has anything left to do at all. A server already de-branded
# is not an error — but it must not print a confirmation about an empty plan
# either.
_sd_anything_to_do() {
    local row

    [ "${_SD_FACT[marker_state]}" = missing ] || return 0
    [ "${_SD_FACT[kasbah_dir]}" = absent ] || return 0
    [ "${_SD_FACT[backup_container]}" = absent ] || return 0
    [ "${_SD_FACT[backup_volume]}" = absent ] || return 0
    [ "${_SD_FACT[backup_network]}" = absent ] || return 0
    [ "${_SD_FACT[pointer_state]}" = missing ] || return 0
    [ "${_SD_FACT[mail_registry_state]}" = missing ] || return 0
    [ "${_SD_FACT[mail_env_extra]}" = 0 ] || return 0
    for row in ${_SD_PROJECTS[@]+"${_SD_PROJECTS[@]}"}; do
        _sd_project_has_work "$row" && return 0
    done
    return 1
}

# Whether one project still carries anything this command removes.
# The eleven fields of a decoded row, by index:
#   0 name  1 dir  2 versions.log  3 versions.log.gz  4 scripts/  5 helpers in
#   it  6 other files in it  7 .deploy.lock  8 .kasbah-client  9 .env
#   10 .env sentinel lines
_sd_project_has_work() {
    local row="$1"

    [ "$(_sd_field "$row" 2)" = missing ] || return 0   # versions.log
    [ "$(_sd_field "$row" 3)" = missing ] || return 0   # versions.log.gz
    [ "$(_sd_field "$row" 5)" = 0 ] || return 0         # kasbah helpers in scripts/
    [ "$(_sd_field "$row" 7)" = missing ] || return 0   # .deploy.lock
    [ "$(_sd_field "$row" 8)" = missing ] || return 0   # .kasbah-client
    [ "$(_sd_field "$row" 10)" = 0 ] || return 0        # .env sentinel lines
    return 1
}

_sd_report_plan() {
    local row name width=0 n extra="" skipped="" sudo_ok=no

    printf 'kasbah server destroy — %s (%s)\n\n' "$_SD_TARGET" "$_SD_APPS_PATH"

    printf 'to remove\n'

    # The backup stack first, because that is the order the act runs in: a
    # schedule left running pushes the new owner's data into the departing
    # operator's storage.
    case "${_SD_FACT[backup_dir]}${_SD_FACT[backup_container]}" in
        absentabsent)
            printf '  backups     none — no backup stack on this server\n' ;;
        *)
            printf '  backups     stop and remove the %s stack: container %s (%s),\n' \
                "$_SD_BACKUP_PROJECT" "$_SD_BACKUP_CONTAINER" "${_SD_FACT[backup_container]}"
            printf '              volume %s (%s), network %s (%s),\n' \
                "$_SD_BACKUP_VOLUME" "${_SD_FACT[backup_volume]}" \
                "$_SD_BACKUP_NETWORK" "${_SD_FACT[backup_network]}"
            printf '              and %s/.kasbah/backup/ (%s) — compose.yml, backup.sh, the\n' \
                "$_SD_APPS_PATH" "${_SD_FACT[backup_dir]}"
            printf '              credentials in env, and every repository password\n'
            ;;
    esac

    if [ "${#_SD_PROJECTS[@]}" -eq 0 ]; then
        printf '  projects    none under %s\n' "$_SD_APPS_PATH"
    else
        for row in "${_SD_PROJECTS[@]}"; do
            name="$(_sd_field "$row" 0)"
            [ "${#name}" -le "$width" ] || width="${#name}"
        done
        printf '  projects\n'
        for row in "${_SD_PROJECTS[@]}"; do
            name="$(_sd_field "$row" 0)"
            if _sd_project_has_work "$row"; then
                printf '    %-*s  %s\n' "$width" "$name" "$(_sd_plan_project "$row")"
            else
                printf '    %-*s  nothing of kasbah'"'"'s left here\n' "$width" "$name"
            fi
        done
    fi

    printf '\n  mail        '
    case "${_SD_FACT[mail_dir]}" in
        dir)
            n="${_SD_FACT[mail_env_extra]}"
            if [ "${_SD_FACT[mail_env_state]}" = ok ] && [ "$n" != 0 ]; then
                printf '%s line(s) of %s/mail/.env that are not %s\n' \
                    "$n" "$_SD_APPS_PATH" "${_SD_MAIL_KEYS[*]}"
                printf '              (those three stay, so the stack still starts)\n'
            else
                printf '%s/mail/.env is %s — nothing to strip out of it\n' \
                    "$_SD_APPS_PATH" "${_SD_FACT[mail_env_state]}"
            fi
            printf '              %s/mail/kasbah.yml (%s) — the domain registry\n' \
                "$_SD_APPS_PATH" "${_SD_FACT[mail_registry_state]}"
            ;;
        *) printf 'none — no mail stack at %s/mail\n' "$_SD_APPS_PATH" ;;
    esac

    printf '\n  marker      %s/.kasbah/server.json (%s)\n' "$_SD_APPS_PATH" "${_SD_FACT[marker_state]}"
    # And the directory holding it, but only when this command wrote everything
    # in it: a file a newer kasbah left there is not this one's to delete.
    _sd_b64_field "${_SD_FACT[kasbah_extra_b64]:--}" extra || extra=""
    extra="${extra%"${extra##*[![:space:]]}"}"
    if [ -n "$extra" ]; then
        printf '              %s/.kasbah/ itself stays — it also holds %s\n' "$_SD_APPS_PATH" "$extra"
    else
        printf '              and %s/.kasbah/ itself, which holds nothing else\n' "$_SD_APPS_PATH"
    fi

    printf '  pointer     %s (%s)' "$KASBAH_APPS_POINTER" "${_SD_FACT[pointer_state]}"
    case "${_SD_FACT[sudo_state]}" in
        root|yes) printf '\n' ;;
        *) printf ' — root-owned, and `sudo -n` is not available here,\n              so this one is warned about and skipped\n' ;;
    esac
    # Only when there is elevation to remove the file inside it: promising the
    # directory one line after saying the file cannot be touched is a plan
    # arguing with itself.
    case "${_SD_FACT[sudo_state]}" in root|yes) sudo_ok=yes ;; *) sudo_ok=no ;; esac
    if [ "$sudo_ok" != yes ] || [ "${_SD_FACT[pointer_dir]}" != dir ]; then
        :
    elif [ "${_SD_FACT[pointer_dir_other]}" = 0 ]; then
        printf '              and %s/ with it, which holds nothing else\n' "${KASBAH_APPS_POINTER%/*}"
    else
        printf '              %s/ itself stays — it holds %s other file(s)\n' \
            "${KASBAH_APPS_POINTER%/*}" "${_SD_FACT[pointer_dir_other]}"
    fi

    printf '\nleft alone\n'
    _sd_b64_field "${_SD_FACT[skipped_b64]:--}" skipped || skipped=""
    skipped="${skipped%"${skipped##*[![:space:]]}"}"
    [ -z "$skipped" ] \
        || printf '  %s under %s — not a project name, so not kasbah'"'"'s to touch\n' \
               "$skipped" "$_SD_APPS_PATH"
    printf '  every container, projects and Traefik alike — the sites stay up\n'
    printf '  every compose.yml, .env **value**, and Traefik fragment\n'
    printf '  %s/, %s/<project>/backups/, named volumes and images\n' "$_SD_DATA_PATH" "$_SD_APPS_PATH"
    [ "${_SD_FACT[mail_dir]}" != dir ] \
        || printf '  the postmaster account in %s/mail/dms/config/postfix-accounts.cf\n' "$_SD_DATA_PATH"
    printf '  the off-VPS restic repositories — operator property (docs/backup.md)\n'

    printf '\nthis is permanent: the deploy history in versions.log, and the mail domain\n'
    printf 'registry, exist nowhere else. A later `server init` cannot reproduce them.\n\n'
    return 0
}

# One project's line in the plan: what is there to remove, named.
_sd_plan_project() {
    local row="$1" parts=() n

    [ "$(_sd_field "$row" 2)" = missing ] || parts+=("versions.log")
    [ "$(_sd_field "$row" 3)" = missing ] || parts+=("versions.log.gz")
    n="$(_sd_field "$row" 5)"
    if [ "$n" != 0 ]; then
        if [ "$(_sd_field "$row" 6)" = 0 ]; then
            parts+=("scripts/ ($n helper(s), and nothing else)")
        else
            parts+=("$n helper(s) out of scripts/, keeping $(_sd_field "$row" 6) other file(s) and the directory")
        fi
    fi
    [ "$(_sd_field "$row" 7)" = missing ] || parts+=(".deploy.lock")
    [ "$(_sd_field "$row" 8)" = missing ] || parts+=(".kasbah-client")
    n="$(_sd_field "$row" 10)"
    [ "$n" = 0 ] || parts+=(".env: $n managed-block sentinel comment(s), values kept")

    # Joined by hand: `IFS=', '` joins on the *first* character of IFS alone,
    # so `${parts[*]}` under it produces a comma-run with no spaces.
    local out="" part
    for part in ${parts[@]+"${parts[@]}"}; do
        out="${out:+$out, }$part"
    done
    printf '%s' "$out"
    return 0
}

# --- The act ---------------------------------------------------------------------------

_sd_act() {
    local out rc=0 names=() row

    for row in ${_SD_PROJECTS[@]+"${_SD_PROJECTS[@]}"}; do
        names+=("$(_sd_field "$row" 0)")
    done

    out=$(ssh_script "$_SD_APPS_PATH" "$KASBAH_APPS_POINTER" "${_SD_RESERVED[*]}" \
                     "$_SD_BACKUP_PROJECT" "$_SD_BACKUP_CONTAINER" \
                     "$_SD_BACKUP_VOLUME" "$_SD_BACKUP_NETWORK" \
                     "$ENV_MANAGED_BEGIN" "$ENV_MANAGED_END" \
                     "${_SD_HELPERS[*]}" "${_SD_MAIL_KEYS[*]}" \
                     ${names[@]+"${names[@]}"} <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
pointer=$2
reserved=" $3 "
bproject=$4
bcontainer=$5
bvolume=$6
bnetwork=$7
env_begin=$8
env_end=$9
helpers=${10}
mail_keys=${11}
shift 11

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }
b64() { openssl base64 -A 2>/dev/null; }
flat() { tr -d '\r' | tr '\n' ' '; }

# The most dangerous shape in this file: every path below is built from
# arguments this payload did not assemble, and one of them is an `rm -rf`. A
# payload on the far side of ssh can source nothing and must not trust the
# caller, so the shapes are checked here and the run refuses rather than
# continuing.
case $apps in /?*) ;; *) fail "refusing to act: apps path '$apps' is not an absolute path" ;; esac
case $pointer in /?*) ;; *) fail "refusing to act: pointer path '$pointer' is not an absolute path" ;; esac
case $apps in */) fail "refusing to act: apps path '$apps' ends in a slash" ;; esac
# An empty sentinel would match every empty line of every project's .env and
# strip the file to nothing but its values' order. Both are frozen strings
# (lib/env.sh); neither may arrive empty or equal to the other.
[ -n "$env_begin" ] || fail "refusing to act: the managed-block begin sentinel is empty"
[ -n "$env_end" ] || fail "refusing to act: the managed-block end sentinel is empty"
[ "$env_begin" != "$env_end" ] || fail "refusing to act: the two managed-block sentinels are the same string"
[ -n "$helpers" ] || fail "refusing to act: no helper file names were given"
for h in $helpers; do
    case $h in
        .|..|*/*) fail "refusing to act: '$h' is not a file name inside scripts/" ;;
    esac
done
[ -n "$mail_keys" ] || fail "refusing to act: no mail .env keys were given"
for w in "$bproject" "$bcontainer" "$bvolume" "$bnetwork"; do
    case $w in
        ''|-*|*[[:space:]]*) fail "refusing to act: '$w' is not a docker object name" ;;
    esac
done
for name in "$@"; do
    case $name in
        [a-z]*) ;;
        *) fail "refusing to act: project name '$name' does not start with a lower-case letter, and every path this step touches is built from it" ;;
    esac
    case $name in
        *[!a-z0-9-]*) fail "refusing to act: project name '$name' is not letters, digits and hyphens, and every path this step touches is built from it" ;;
    esac
    case $reserved in
        *" $name "*) fail "refusing to act: '$name' is a directory kasbah owns under $apps, not a project" ;;
    esac
done

# Every guard is above this line and every one of them exits without touching
# anything, so a run that never printed this changed nothing — which is what
# separates the caller's two diagnoses for a non-zero status.
printf 'started=yes\n'

# Anything that did not do what it was asked. The marker and the pointer are
# removed only when this is still 0: they are how a later run finds this server,
# and a half-de-branded server nothing can find again is worse than one that
# still says kasbah was here.
bad=0

# --- The backup stack ------------------------------------------------------------
#
# Stopped, not merely unlinked. Left running it goes on pushing this server's
# data into the departing operator's storage on the next daily slot, which is
# the sharpest form of the thing this command exists to prevent.
#
# By project label with `cd /`, exactly as `kasbah drop` brings a project down:
# compose needs no file that way, so a stack whose compose.yml is unreadable
# still stops. Without -v — the volume below is named, and `-v` with no file in
# sight reaps only anonymous ones.
if docker container inspect "$bcontainer" >/dev/null 2>&1 || [ -d "$apps/.kasbah/backup" ]; then
    down_out=$(cd / && docker compose -p "$bproject" down --remove-orphans 2>&1); down_rc=$?
    if [ "$down_rc" -eq 0 ]; then printf 'bk_down=ok\n'; else printf 'bk_down=failed\n'; bad=1; fi
    printf 'bk_down_detail=%s\n' "$(printf '%s' "$down_out" | flat | b64)"
else
    printf 'bk_down=skipped\n'
    printf 'bk_down_detail=\n'
fi

# What `down` left, read back rather than assumed: `docker compose down` selects
# on `com.docker.compose.oneoff=False` as well as the project label, so a one-off
# survives it and exits 0.
if docker container inspect "$bcontainer" >/dev/null 2>&1; then
    if docker rm -f "$bcontainer" >/dev/null 2>&1; then
        printf 'bk_container=removed\n'
    else
        printf 'bk_container=failed\n'; bad=1
    fi
else
    printf 'bk_container=absent\n'
fi

if docker volume inspect "$bvolume" >/dev/null 2>&1; then
    if docker volume rm "$bvolume" >/dev/null 2>&1; then
        printf 'bk_volume=removed\n'
    else
        printf 'bk_volume=failed\n'; bad=1
    fi
else
    printf 'bk_volume=absent\n'
fi

if docker network inspect "$bnetwork" >/dev/null 2>&1; then
    if docker network rm "$bnetwork" >/dev/null 2>&1; then
        printf 'bk_network=removed\n'
    else
        printf 'bk_network=failed\n'; bad=1
    fi
else
    printf 'bk_network=absent\n'
fi

# The credentials: <apps>/.kasbah/backup/env at 600, one <repo>.pass per
# repository at 600, the runner and its compose file. The repositories the
# passwords open are **not** touched — operator property, and an append-only
# credential could not delete them anyway (docs/backup.md).
if [ -e "$apps/.kasbah/backup" ]; then
    if rm -rf "$apps/.kasbah/backup"; then
        printf 'bk_files=removed\n'
    else
        printf 'bk_files=failed\n'; bad=1
    fi
else
    printf 'bk_files=absent\n'
fi

# --- Every project ----------------------------------------------------------------
#
# One line per project, in the order the caller listed them, so the report reads
# in the order the server did the work.
rm_file() {   # rm_file <path> -> removed|absent|failed
    if [ -e "$1" ] || [ -L "$1" ]; then
        if rm -f "$1"; then printf removed; else printf failed; fi
    else
        printf absent
    fi
}

# The managed block's sentinel *comments* go; every other line survives byte for
# byte, in its original order, including the KASBAH_CPU_LIMIT and
# KASBAH_MEM_LIMIT lines between them. Compose interpolates those two into every
# service's `cpus:` and `mem_limit:`, so a strip that took them would stop the
# new owner's containers on their next `up` — while the comment claiming the
# block is "rewritten on every deploy" becomes false the moment this command
# runs, which is why it is the part that goes.
#
# This file holds the project's only copy of its secrets, so it is rewritten in
# place on the server and never travels: written to a temp file beside it with
# the same mode and renamed, so a reader sees the whole old file or the whole
# new one.
strip_env() {   # strip_env <path> -> stripped|noblock|absent|unreadable|failed
    local f=$1 target line n=0 tmp

    if [ -L "$f" ]; then
        target=$(readlink -f -- "$f" 2>/dev/null) || { printf unreadable; return 0; }
    else
        target=$f
    fi
    if [ -e "$target" ] && [ ! -f "$target" ]; then printf unreadable; return 0; fi
    [ -f "$target" ] || { printf absent; return 0; }
    [ -r "$target" ] && [ -w "$target" ] || { printf unreadable; return 0; }

    while IFS= read -r line || [ -n "$line" ]; do
        case ${line%$'\r'} in
            "$env_begin"|"$env_end") n=$((n + 1)) ;;
        esac
    done < "$target"
    if [ "$n" -eq 0 ]; then printf noblock; return 0; fi

    tmp="$target.kasbah-destroy.$$"
    rm -f "$tmp" 2>/dev/null
    (umask 077; : > "$tmp") 2>/dev/null || { printf failed; return 0; }
    chmod --reference="$target" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null
    # The loop and the tail are two cases, not one: a `read` that returns
    # non-zero has left a final fragment the file did not terminate with a
    # newline, and that fragment is data — docker compose reads it, and giving
    # it a newline it never had is as much a rewrite as dropping it.
    line=""
    if ! {
        while IFS= read -r line; do
            case ${line%$'\r'} in
                "$env_begin"|"$env_end") continue ;;
            esac
            printf '%s\n' "$line"
        done
        if [ -n "$line" ]; then
            case ${line%$'\r'} in
                "$env_begin"|"$env_end") ;;
                *) printf '%s' "$line" ;;
            esac
        fi
    } < "$target" > "$tmp"; then
        rm -f "$tmp"
        printf failed
        return 0
    fi
    if mv -f "$tmp" "$target"; then printf stripped; else rm -f "$tmp"; printf failed; fi
    return 0
}

for name in "$@"; do
    dir="$apps/$name"
    vlog=$(rm_file "$dir/versions.log")
    vloggz=$(rm_file "$dir/versions.log.gz")

    # kasbah's own two helpers by name, then the directory if that was all it
    # held. A file in scripts/ that kasbah did not put there belongs to whoever
    # did, and removing the directory whole would take it.
    scripts=absent
    if [ -d "$dir/scripts" ]; then
        scripts=removed
        for h in $helpers; do
            # `-L` as well as `-e`: a broken symlink is not `-e`, and leaving one
            # named remote-deploy.sh behind would be leaving a helper behind.
            if [ -e "$dir/scripts/$h" ] || [ -L "$dir/scripts/$h" ]; then
                rm -f "$dir/scripts/$h" || scripts=failed
            fi
        done
        # Only when it is empty: `rmdir` is the whole of that test, and a
        # directory still holding somebody else's file keeps it.
        if [ "$scripts" = removed ]; then
            rmdir "$dir/scripts" 2>/dev/null || scripts=kept
        fi
    elif [ -e "$dir/scripts" ] || [ -L "$dir/scripts" ]; then
        scripts=notdir
    fi
    [ "$scripts" != failed ] || bad=1

    lock=$(rm_file "$dir/.deploy.lock")
    client=$(rm_file "$dir/.kasbah-client")
    envv=$(strip_env "$dir/.env")

    for v in "$vlog" "$vloggz" "$lock" "$client"; do
        [ "$v" != failed ] || bad=1
    done
    # `unreadable` counts as a failure, not as a state to shrug at: a .env this
    # step could not rewrite still carries the comment claiming kasbah rewrites
    # it on every deploy, and — for the mail .env below, by the same rule — the
    # operator's relay credential. A de-branding that could not strip one has
    # not de-branded, so the marker and the pointer stay and the run exits 1.
    case $envv in failed|unreadable) bad=1 ;; esac

    printf 'project=%s %s %s %s %s %s %s\n' \
        "$name" "$vlog" "$vloggz" "$scripts" "$lock" "$client" "$envv"
done

# --- Mail ---------------------------------------------------------------------------
#
# The operator's relay block, and everything else in <apps>/mail/.env that is
# not one of kasbah's three keys: a line kasbah did not write is a line it
# cannot prove is not a credential. The three that stay are what compose and
# docker-mailserver interpolate, so the stack still starts.
#
# postfix-accounts.cf is deliberately untouched: removing the postmaster account
# would leave containers running that nobody can authenticate to, which is the
# opposite of this command's promise.
if [ -f "$apps/mail/.env" ] && [ -r "$apps/mail/.env" ] && [ -w "$apps/mail/.env" ]; then
    mail_removed=0
    tmp="$apps/mail/.env.kasbah-destroy.$$"
    rm -f "$tmp" 2>/dev/null
    if ! (umask 077; : > "$tmp") 2>/dev/null; then
        printf 'mail_env=failed\nmail_env_n=0\n'; bad=1
    else
        chmod 600 "$tmp" 2>/dev/null
        mail_keep_line() {   # mail_keep_line <line> -> 0 keep, 1 drop
            local stripped=${1%$'\r'} k
            while :; do
                case $stripped in " "*|"	"*) stripped=${stripped#?} ;; *) break ;; esac
            done
            case $stripped in
                export[" 	"]*)
                    stripped=${stripped#export}
                    while :; do
                        case $stripped in " "*|"	"*) stripped=${stripped#?} ;; *) break ;; esac
                    done ;;
            esac
            for k in $mail_keys; do
                case $stripped in "$k="*) return 0 ;; esac
            done
            return 1
        }
        line=""
        {
            while IFS= read -r line; do
                if mail_keep_line "$line"; then
                    printf '%s\n' "$line"
                else
                    mail_removed=$((mail_removed + 1))
                fi
            done
            # The final fragment of a file that does not end in a newline.
            if [ -n "$line" ]; then
                if mail_keep_line "$line"; then
                    printf '%s' "$line"
                else
                    mail_removed=$((mail_removed + 1))
                fi
            fi
        } < "$apps/mail/.env" > "$tmp"
        if [ "$mail_removed" -eq 0 ]; then
            rm -f "$tmp"
            printf 'mail_env=unchanged\nmail_env_n=0\n'
        elif mv -f "$tmp" "$apps/mail/.env"; then
            chmod 600 "$apps/mail/.env" 2>/dev/null
            printf 'mail_env=stripped\nmail_env_n=%s\n' "$mail_removed"
        else
            rm -f "$tmp"
            printf 'mail_env=failed\nmail_env_n=0\n'; bad=1
        fi
    fi
elif [ -e "$apps/mail/.env" ]; then
    # The sharpest case in the command: this file is where an operator's relay
    # password lives, so a run that could not rewrite it has left the one secret
    # the whole feature exists to keep off the handed-over machine.
    printf 'mail_env=unreadable\nmail_env_n=0\n'; bad=1
else
    printf 'mail_env=absent\nmail_env_n=0\n'
fi

# The registry. Read by kasbah and by nothing else, so it is branding — and it
# is also the only record of primary_domain and the domain list, which no later
# `server init --with-mail` can reproduce. The same trade as versions.log, made
# the same way.
mail_registry=$(rm_file "$apps/mail/kasbah.yml")
[ "$mail_registry" != failed ] || bad=1
printf 'mail_registry=%s\n' "$mail_registry"

# --- The marker and the pointer ------------------------------------------------------
#
# Last, and only on a run where everything else did what it was asked. These two
# are how every kasbah command finds this server; a run that removed them after
# failing half way would leave a server nobody can point a second run at.
if [ "$bad" -ne 0 ]; then
    printf 'marker=held\nkasbah_dir=held\npointer=held\npointer_dir=held\n'
    printf 'done=yes\n'
    exit 0
fi

marker=$(rm_file "$apps/.kasbah/server.json")
[ "$marker" != failed ] || bad=1
printf 'marker=%s\n' "$marker"

if [ -d "$apps/.kasbah" ]; then
    if rmdir "$apps/.kasbah" 2>/dev/null; then
        printf 'kasbah_dir=removed\n'
    else
        printf 'kasbah_dir=kept\n'
    fi
elif [ -e "$apps/.kasbah" ]; then
    printf 'kasbah_dir=notdir\n'
else
    printf 'kasbah_dir=absent\n'
fi

# Root-owned, so this needs elevation kasbah never assumes it has. Without
# passwordless sudo the run warns and carries on rather than failing: the file
# is a discovery pointer, and a de-branding that stopped over it would leave
# everything above undone as well.
if [ "$(id -u)" = 0 ]; then
    sudo_cmd=""
elif sudo -n true >/dev/null 2>&1; then
    sudo_cmd="sudo -n"
else
    printf 'pointer=nosudo\npointer_dir=nosudo\n'
    printf 'done=yes\n'
    exit 0
fi

if $sudo_cmd test -e "$pointer" 2>/dev/null; then
    if $sudo_cmd rm -f "$pointer"; then printf 'pointer=removed\n'; else printf 'pointer=failed\n'; fi
else
    printf 'pointer=absent\n'
fi
dir=${pointer%/*}
if $sudo_cmd test -d "$dir" 2>/dev/null; then
    if $sudo_cmd rmdir "$dir" 2>/dev/null; then
        printf 'pointer_dir=removed\n'
    else
        printf 'pointer_dir=kept\n'
    fi
else
    printf 'pointer_dir=absent\n'
fi

printf 'done=yes\n'
exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the destroy step on $_SD_TARGET exited $rc"
        # Every guard in that payload sits above its `started=yes`, and each of
        # them refuses without touching anything — so the two diagnoses are not
        # the same sentence, and guessing the worse one sends an operator
        # looking for damage that is not there.
        if grep -q '^started=yes' <<<"$out"; then
            err_cont "some of it may have run — \`kasbah server destroy $_SD_TARGET\` again to see what is left"
        else
            err_cont "it refused before changing anything — nothing was removed"
        fi
        return 1
    fi

    local keys=(started bk_down bk_down_detail bk_container bk_volume bk_network bk_files
                mail_env mail_env_n mail_registry marker kasbah_dir pointer pointer_dir done)
    _sd_absorb_checked "$out" "${keys[@]}"

    # The per-project rows, in the order the far side printed them — which is
    # the order it did the work, and the order _sd_report_act reads them back.
    local line name rest
    _SD_ACT_PROJECTS=()
    _SD_ACT_ROW=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case $line in project=*) ;; *) continue ;; esac
        line="${line#project=}"
        name="${line%% *}"
        rest="${line#* }"
        [ "$rest" != "$name" ] || rest=""
        _SD_ACT_PROJECTS+=("$name")
        _SD_ACT_ROW[$name]="$rest"
    done <<<"$out"

    # By name and in order, not by count: two rows for one project and none for
    # another is the same count, and the report below is keyed by name — it
    # would print one project's verdicts under another's heading.
    local i planned
    if [ "${#_SD_ACT_PROJECTS[@]}" -ne "${#_SD_PROJECTS[@]}" ]; then
        err "the destroy step on $_SD_TARGET reported ${#_SD_ACT_PROJECTS[@]} of ${#_SD_PROJECTS[@]} projects"
        err_cont "the step was truncated; run destroy again to see what is left"
        return 1
    fi
    for i in ${_SD_PROJECTS[@]+"${!_SD_PROJECTS[@]}"}; do
        planned="$(_sd_field "${_SD_PROJECTS[$i]}" 0)"
        [ "${_SD_ACT_PROJECTS[$i]}" = "$planned" ] && continue
        err "the destroy step on $_SD_TARGET reported '${_SD_ACT_PROJECTS[$i]}' where the plan named '$planned'"
        err_cont "the step and the plan disagree about which projects this server has —"
        err_cont "run destroy again to see what is left"
        return 1
    done

    _sd_report_act || return 1
    return 0
}

# --- The report ------------------------------------------------------------------------

# What the far side actually did, read out of its report rather than assumed
# from its exit status: every step there is failure-tolerant so that one that
# could not run does not strand the rest, which only works if each is read back.
#
# In the order the server did it — backup stack, projects, mail, marker, pointer
# — and on **stdout**, the same stream the plan went to, so
# `kasbah server destroy > log` holds what was planned *and* what happened. Only
# problems and follow-ups go to stderr, which is docs/cli.md's split.
#
# Returns 1 when any step could not do what it was asked.
_sd_report_act() {
    local bad=0 detail="" name row vlog vloggz scripts lock client envv

    case "${_SD_FACT[bk_down]}" in
        ok)      _sd_say "stopped the $_SD_BACKUP_PROJECT stack" ;;
        skipped) _sd_say "no backup stack to stop" ;;
        *)
            _sd_say "FAILED: docker compose -p $_SD_BACKUP_PROJECT down"
            err "the backup stack on $_SD_TARGET could not be stopped"
            _sd_b64_field "${_SD_FACT[bk_down_detail]:--}" detail || detail=""
            [ -z "$detail" ] || err_cont "$detail"
            err_cont "it is still scheduled to push this server's data to the operator's storage"
            bad=1
            ;;
    esac
    # The container and the network are what `down` takes with it, so "absent"
    # after a `down` that ran is that step working — not the state the plan
    # described a moment earlier. Said as the two different facts they are.
    _sd_stack_line bk_container \
        "removed the $_SD_BACKUP_CONTAINER container, which survived \`down\`" \
        "the $_SD_BACKUP_CONTAINER container went down with the stack" \
        "there was no $_SD_BACKUP_CONTAINER container" \
        "could not remove the $_SD_BACKUP_CONTAINER container on $_SD_TARGET" || bad=1
    # The volume is not: `down` reaps a named volume only when it is given the
    # compose file *and* -v, and this one is brought down by label from `/`.
    _sd_step_line bk_volume "removed the $_SD_BACKUP_VOLUME volume" \
        "there was no $_SD_BACKUP_VOLUME volume" \
        "could not remove the $_SD_BACKUP_VOLUME volume on $_SD_TARGET" || bad=1
    _sd_stack_line bk_network \
        "removed the $_SD_BACKUP_NETWORK network, which survived \`down\`" \
        "the $_SD_BACKUP_NETWORK network went with the stack" \
        "there was no $_SD_BACKUP_NETWORK network" \
        "could not remove the $_SD_BACKUP_NETWORK network on $_SD_TARGET" || bad=1
    _sd_step_line bk_files "removed $_SD_APPS_PATH/.kasbah/backup/ — the runner, the credentials and every repository password" \
        "there was no $_SD_APPS_PATH/.kasbah/backup/" \
        "could not remove $_SD_APPS_PATH/.kasbah/backup/ on $_SD_TARGET — it holds the operator's credentials" || bad=1

    for name in ${_SD_ACT_PROJECTS[@]+"${_SD_ACT_PROJECTS[@]}"}; do
        row="${_SD_ACT_ROW[$name]}"
        # shellcheck disable=SC2086
        set -- $row
        if [ "$#" -ne 6 ]; then
            _sd_say "FAILED: $name reported '$row'"
            err "the destroy step on $_SD_TARGET reported a row for $name it did not build: '$row'"
            bad=1
            continue
        fi
        vlog=$1; vloggz=$2; scripts=$3; lock=$4; client=$5; envv=$6
        _sd_say "$name:"
        _sd_file_line "$name" versions.log "$vlog" || bad=1
        _sd_file_line "$name" versions.log.gz "$vloggz" || bad=1
        case $scripts in
            removed) _sd_say "  removed scripts/ — kasbah's ${_SD_HELPERS[*]}" ;;
            kept)    _sd_say "  removed kasbah's ${_SD_HELPERS[*]} from scripts/, keeping the directory — it holds files kasbah did not write" ;;
            absent)  _sd_say "  no scripts/" ;;
            notdir)  _sd_say "  $_SD_APPS_PATH/$name/scripts is not a directory — left alone" ;;
            *)       _sd_say "  FAILED to remove scripts/ helpers"
                     err "could not remove $_SD_APPS_PATH/$name/scripts helpers on $_SD_TARGET"; bad=1 ;;
        esac
        _sd_file_line "$name" .deploy.lock "$lock" || bad=1
        _sd_file_line "$name" .kasbah-client "$client" || bad=1
        case $envv in
            stripped)   _sd_say "  removed the managed-block sentinel comments from .env — every value is untouched" ;;
            noblock)    _sd_say "  .env carries no managed block" ;;
            absent)     _sd_say "  no .env" ;;
            unreadable)
                _sd_say "  FAILED: .env could not be read or written"
                err "$_SD_APPS_PATH/$name/.env on $_SD_TARGET could not be rewritten"
                err_cont "it still carries the comment saying kasbah rewrites the block on every"
                err_cont "deploy, which stopped being true — fix the file's mode or owner and re-run"
                bad=1
                ;;
            *)          _sd_say "  FAILED to rewrite .env"
                        err "could not rewrite $_SD_APPS_PATH/$name/.env on $_SD_TARGET"
                        err_cont "the file is unchanged — no value was lost"; bad=1 ;;
        esac
    done

    case "${_SD_FACT[mail_env]}" in
        stripped)   _sd_say "removed ${_SD_FACT[mail_env_n]} line(s) from $_SD_APPS_PATH/mail/.env — ${_SD_MAIL_KEYS[*]} stay" ;;
        unchanged)  _sd_say "$_SD_APPS_PATH/mail/.env holds nothing but ${_SD_MAIL_KEYS[*]}" ;;
        absent)     _sd_say "no $_SD_APPS_PATH/mail/.env" ;;
        unreadable) _sd_say "FAILED: $_SD_APPS_PATH/mail/.env could not be read or written"
                    err "$_SD_APPS_PATH/mail/.env on $_SD_TARGET could not be rewritten"
                    err_cont "any relay credential in it is still on this server, which is the one thing"
                    err_cont "this command exists to prevent — fix the file's mode or owner and re-run"
                    bad=1 ;;
        *)          _sd_say "FAILED to rewrite $_SD_APPS_PATH/mail/.env"
                    err "could not rewrite $_SD_APPS_PATH/mail/.env on $_SD_TARGET"
                    err_cont "the file is unchanged, so the operator's relay credentials are still on this server"
                    bad=1 ;;
    esac
    _sd_step_line mail_registry "removed $_SD_APPS_PATH/mail/kasbah.yml — the domain registry" \
        "no $_SD_APPS_PATH/mail/kasbah.yml" \
        "could not remove $_SD_APPS_PATH/mail/kasbah.yml on $_SD_TARGET" || bad=1

    # The marker and the pointer, which the far side declined to touch when
    # anything above it failed. `held` is that decision, reported as what it is.
    if [ "${_SD_FACT[marker]}" = held ]; then
        _sd_say "kept the server marker and $KASBAH_APPS_POINTER — a step above failed"
    else
        _sd_step_line marker "removed the server marker $_SD_APPS_PATH/.kasbah/server.json" \
            "there was no server marker at $_SD_APPS_PATH/.kasbah/server.json" \
            "could not remove $_SD_APPS_PATH/.kasbah/server.json on $_SD_TARGET" || bad=1
        case "${_SD_FACT[kasbah_dir]}" in
            removed) _sd_say "removed $_SD_APPS_PATH/.kasbah/" ;;
            absent)  _sd_say "there was no $_SD_APPS_PATH/.kasbah/" ;;
            kept)
                _sd_say "kept $_SD_APPS_PATH/.kasbah/ — it still holds something kasbah did not write"
                warn "$_SD_APPS_PATH/.kasbah/ is not empty, so it stays: \`ssh $_SD_TARGET 'ls -a $_SD_APPS_PATH/.kasbah'\`"
                ;;
            notdir)  _sd_say "$_SD_APPS_PATH/.kasbah is not a directory — left alone" ;;
            *)       _sd_say "FAILED on $_SD_APPS_PATH/.kasbah/"
                     err "could not remove $_SD_APPS_PATH/.kasbah/ on $_SD_TARGET"; bad=1 ;;
        esac
        case "${_SD_FACT[pointer]}" in
            removed) _sd_say "removed $KASBAH_APPS_POINTER" ;;
            absent)  _sd_say "there was no $KASBAH_APPS_POINTER" ;;
            nosudo)
                # The follow-up is the closing paragraph's, not this line's: a
                # command to run by hand belongs at the end of the report, where
                # the operator is still reading, and not four steps up.
                _sd_say "could NOT remove $KASBAH_APPS_POINTER — it is root-owned and \`sudo -n\` is not available"
                warn "$KASBAH_APPS_POINTER on $_SD_TARGET is still there and names this server as one kasbah prepared"
                ;;
            *)  _sd_say "FAILED to remove $KASBAH_APPS_POINTER"
                err "could not remove $KASBAH_APPS_POINTER on $_SD_TARGET"; bad=1 ;;
        esac
        case "${_SD_FACT[pointer_dir]}" in
            removed) _sd_say "removed ${KASBAH_APPS_POINTER%/*}/" ;;
            absent)  _sd_say "there was no ${KASBAH_APPS_POINTER%/*}/" ;;
            kept)    _sd_say "kept ${KASBAH_APPS_POINTER%/*}/ — it still holds something kasbah did not write" ;;
            nosudo)  ;;
            *)       _sd_say "FAILED on ${KASBAH_APPS_POINTER%/*}/"
                     err "could not remove ${KASBAH_APPS_POINTER%/*}/ on $_SD_TARGET"; bad=1 ;;
        esac
    fi

    # The closing paragraph is a claim about the state this run leaves, so there
    # are three of them and not one. A run that left something of kasbah's on
    # the server must not end on the sentence that says it did not — and the
    # `nosudo` path leaves something on purpose, so it is neither a failure nor
    # a clean handover and gets a paragraph of its own.
    if [ "$bad" -ne 0 ]; then
        err "$_SD_TARGET was not fully de-branded — see the FAILED line(s) above"
        err_cont "the server marker and $KASBAH_APPS_POINTER were kept so a second run can find"
        err_cont "this server: fix what failed, then \`kasbah server destroy $_SD_TARGET\` again."
        return 1
    fi

    _sd_say ""
    if [ "${_SD_FACT[pointer]}" = nosudo ]; then
        _sd_say "$_SD_TARGET is one file short of a plain Docker Compose host. Every container is"
        _sd_say "still running, and the only thing kasbah installed that is still there is"
        _sd_say "$KASBAH_APPS_POINTER, which this user cannot remove:"
        _sd_say "  ssh $_SD_TARGET 'sudo rm -f $KASBAH_APPS_POINTER && sudo rmdir ${KASBAH_APPS_POINTER%/*}'"
        return 0
    fi
    _sd_say "$_SD_TARGET is a plain Docker Compose host now. Every container is still running,"
    _sd_say "and nothing kasbah installed is left to hand over with it."
    return 0
}

# One `<verb>|absent|failed` step, printed in the far side's own order.
_sd_step_line() {   # _sd_step_line <fact> <did> <absent> <failure>
    case "${_SD_FACT[$1]}" in
        removed) _sd_say "$2" ;;
        absent)  _sd_say "$3" ;;
        *)       _sd_say "FAILED: $4"; err "$4"; return 1 ;;
    esac
    return 0
}

# As _sd_step_line, for the two objects `docker compose down` removes itself:
# "absent" means one thing when the stack was brought down and another when
# there was no stack to bring down, and one sentence for both would describe a
# run that did not happen.
_sd_stack_line() {   # _sd_stack_line <fact> <removed> <went-with-down> <none> <failure>
    case "${_SD_FACT[$1]}" in
        removed) _sd_say "$2" ;;
        absent)
            if [ "${_SD_FACT[bk_down]}" = skipped ]; then _sd_say "$4"; else _sd_say "$3"; fi
            ;;
        *) _sd_say "FAILED: $5"; err "$5"; return 1 ;;
    esac
    return 0
}

_sd_file_line() {   # _sd_file_line <project> <file> <verdict>
    case "$3" in
        removed) _sd_say "  removed $2" ;;
        absent)  _sd_say "  no $2" ;;
        *)
            _sd_say "  FAILED to remove $2"
            err "could not remove $_SD_APPS_PATH/$1/$2 on $_SD_TARGET"
            return 1
            ;;
    esac
    return 0
}

# One outcome line, on stdout. The plan went there and so does what came of it:
# a command whose output is redirected must not lose half its own report
# (docs/cli.md — the sentence that answers the question asked is the report).
_sd_say() {
    if [ -z "$*" ]; then printf '\n'; else printf '  %s\n' "$*"; fi
    return 0
}

# --- The command ------------------------------------------------------------------------

cmd_server_destroy() {
    local rc=0 act_rc

    _sd_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    ssh_connect "$_SD_TARGET"
    _sd_marker_read || rc=$?
    if [ "$rc" -eq "$KASBAH_EXIT_NO_REMOTE_STATE" ]; then
        # Captured, never called bare: a server whose credentials outlived its
        # marker ends this run non-zero, and a bare call would put that status
        # on an errexit shell rather than returning it.
        local ntf_rc=0
        _sd_nothing_to_find || ntf_rc=$?
        return "$ntf_rc"
    fi
    [ "$rc" -eq 0 ] || exit "$rc"

    _sd_collect
    _sd_check_server
    _sd_decode_projects
    _sd_report_plan

    if ! _sd_anything_to_do; then
        # On stdout with the rest of the report: this is the answer to the
        # question the command was asked, and a redirected run must not lose it.
        printf 'nothing of kasbah is left on %s — nothing to remove\n' "$_SD_TARGET"
        return 0
    fi

    # Both declines end the run non-zero and having changed nothing. Declining
    # is a legitimate answer, and it is not a de-branding: a caller reading
    # exit 0 as "this server is handed over" would be wrong.
    prompt_confirm yes \
        "de-brand $_SD_TARGET? every container keeps running; the deploy history and the mail registry are gone for good" \
        "$_SD_YES" || {
        err "not confirmed — nothing was changed on $_SD_TARGET"
        exit 1
    }
    prompt_typed yes "$SSH_HOST" \
        "type the hostname ($SSH_HOST) to confirm:" "$_SD_YES" || {
        err "that is not $SSH_HOST — nothing was changed on $_SD_TARGET"
        exit 1
    }

    act_rc=0
    _sd_act || act_rc=$?
    [ "$act_rc" -eq 0 ] || exit "$act_rc"
    return 0
}

# A server kasbah cannot find a marker on. That is what a completed destroy
# leaves, so it is not an error — but "nothing to remove" would be a false
# statement while the root-owned discovery pointer is still in /etc, which is
# exactly what a first run leaves behind when it had no passwordless sudo. So
# the pointer is probed rather than assumed.
_sd_nothing_to_find() {
    local left=0

    printf 'kasbah server destroy — %s\n\n' "$_SD_TARGET"
    [ -z "$_SD_MARKER_REASON" ] || printf '  %s\n' "$_SD_MARKER_REASON"

    if ! _sd_probe_leftovers; then
        printf '  nothing was removed\n'
        warn "could not check what $_SD_TARGET is still carrying — re-run, or look by hand at"
        warn "  $KASBAH_APPS_POINTER and $KASBAH_DEFAULT_APPS_PATH/.kasbah"
        return 0
    fi

    if [ -n "$_SD_LEFT_CREDS" ]; then
        left=1
        printf '  %s is still there — the backup stack'"'"'s runner and its\n' "${_SD_LEFT_CREDS% }"
        printf '  credentials, which is the one thing this command exists to take away.\n'
        err "the marker is gone but ${_SD_LEFT_CREDS% } is not, so destroy cannot enumerate this"
        err_cont "server and cannot remove them. That directory holds the repository URL and one"
        err_cont "password per repository, at mode 600. Take the stack down and delete it:"
        err_cont "  ssh $_SD_TARGET 'docker compose -p $_SD_BACKUP_PROJECT down; docker volume rm $_SD_BACKUP_VOLUME'"
        err_cont "  ssh $_SD_TARGET 'rm -rf ${_SD_LEFT_CREDS% }'"
    elif [ -n "$_SD_LEFT_KASBAH" ]; then
        left=1
        printf '  %s is still there, with no marker in it.\n' "${_SD_LEFT_KASBAH% }"
        warn "${_SD_LEFT_KASBAH% } on $_SD_TARGET outlived the marker — look at what is in it:"
        warn "  ssh $_SD_TARGET 'ls -la ${_SD_LEFT_KASBAH% }'"
    fi

    if [ "$_SD_LEFT_POINTER" = yes ]; then
        left=1
        printf '  %s is still there, and it names this server as one kasbah prepared.\n' "$KASBAH_APPS_POINTER"
        warn "$KASBAH_APPS_POINTER on $_SD_TARGET outlived the marker — take it off by hand:"
        warn "  ssh $_SD_TARGET 'sudo rm -f $KASBAH_APPS_POINTER && sudo rmdir ${KASBAH_APPS_POINTER%/*}'"
    fi

    if [ "$left" -ne 0 ]; then
        printf '  nothing else can be enumerated without a marker, and nothing was removed\n'
        # The function graded the three leftovers above — `err` for the
        # credentials, `warn` for a stray .kasbah/ and `warn` for the pointer —
        # and the exit status carries that grading rather than discarding it.
        #
        # A pointer or an empty .kasbah/ is a world-readable discovery hint and
        # no secret, which is the same judgement `nosudo` already makes about the
        # same class of leftover at its spec'd exit 0 (docs/cli.md). Credentials
        # are the other thing: the repository URL and one password per
        # repository at mode 600, still pushing this server's data into the
        # departing operator's storage at the next 02:00 slot. A handover script
        # spelled `kasbah server destroy "$h" && mark_handed_over "$h"` must not
        # read that run as a de-branding — which is why _sd_report_act exits 1
        # and holds the marker on an unreadable `.env` for exactly this reason.
        [ -z "$_SD_LEFT_CREDS" ] || return 1
        return 0
    fi

    printf '  no server marker, no %s and no .kasbah directory — this server\n' "$KASBAH_APPS_POINTER"
    printf '  carries nothing of kasbah'"'"'s management layer, and nothing was removed\n'
    return 0
}
