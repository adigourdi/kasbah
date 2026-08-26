# kasbah — off-VPS backups: the `--with-backup` half of server init, and
# `server backup-prune`
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_BACKUP_LOADED:-}" ] && return 0
_KASBAH_BACKUP_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
# For KASBAH_RESERVED_NAMES and manifest_name_reserved: the names kasbah owns
# under <apps> are the names a `client:` may not take either, and one list is
# what keeps the repository rule and the project rule from drifting apart.
. "$KASBAH_LIB_DIR/manifest.sh"

# docs/backup.md, as amended by docs/phases/08-keep.md D1-D7 and D12-D13.
#
# Each VPS pushes restic snapshots to storage it can write and not delete. Three
# consequences shape everything here:
#
#   * restic is a **container** (D1). kasbah installs no packages, so the
#     scheduled backup, the credential probe and `backup-prune` all run
#     `docker run --rm <KASBAH_RESTIC_IMAGE>` — on the VPS for the first two, on
#     the workstation for the third (D13), because the full-access credential
#     must never sit on the box the threat model assumes is compromised.
#   * the schedule is a **compose stack** (D3) at <apps>/.kasbah/backup, not
#     cron: cron is not on the prerequisites table and kasbah adds nothing to it.
#   * kasbah **never parses the repository URL** (D5). It stores an opaque
#     base, appends a repository name, and hands the result to restic with an
#     operator-supplied environment block. `s3:`, `rest:`, `sftp:` and a plain
#     path are all the same to this file, which is what lets the rig prove the
#     append-only property against something that really enforces it.
#
# The property the feature rests on — the VPS cannot delete its own history — is
# a property of the *credential*, and kasbah cannot create one: the operator
# makes it at their provider. So init writes a probe object with the credentials
# in effect, tries to delete it again, and refuses to start the stack when the
# delete works (D6).
#
# This file is sourced by lib/server_init.sh for the init half and stands alone
# for `backup-prune`, which renders nothing and needs none of init's helpers.

# The compose project and its container — the names templates/backup/compose.yml
# declares, repeated here because the start step, the report and the
# already-installed notice name them without reading that file. The cache volume
# it also declares is not here: nothing on this side names it, and a constant
# with no reader is one that can drift from the template unnoticed.
KASBAH_BACKUP_PROJECT=kasbah-backup
KASBAH_BACKUP_CONTAINER=kasbah-backup

# The repository the credential probe writes to. The `.` is load-bearing: a
# project name and a `client:` are `^[a-z][a-z0-9-]*$`, so no project can ever
# claim this one and no reserved-name list has to say so.
KASBAH_BACKUP_PROBE_REPO='kasbah.probe'
# Its password, which is a constant and not a secret: the repository holds one
# short probe file and exists so that a credential can be tested against real
# storage. Every client repository's password is operator-supplied (D2); this
# one is not a client repository.
KASBAH_BACKUP_PROBE_PASSWORD='kasbah-probe'

# docs/backup.md → Cadence and retention. Defaults on a first run; a re-run
# reproduces whatever the marker records, exactly as the dashboard credentials
# are reproduced rather than regenerated.
KASBAH_BACKUP_AT_DEFAULT=02:00
# The bound on any single restic invocation — one repository's backup, and each
# of the credential probe's calls. Not a bound on a whole run: a run of five
# repositories may take five of these. It exists because a repository whose
# endpoint accepts a connection and then answers nothing leaves restic waiting
# for ever, and a scheduler that never returns to `sleep` is a scheduler that
# backs nothing up while `docker ps` says it is running (measured on the rig
# against a black-holed address).
KASBAH_BACKUP_TIMEOUT_DEFAULT=900

# The environment variables that decide *which* repository restic opens and
# *what* key opens it. kasbah sets all five itself, so an operator entry naming
# one is refused rather than merged: `docker --env-file` is last-wins, and a
# RESTIC_REPOSITORY in the operator's half would point the credential probe at
# one repository while the scheduled backup wrote to another — the probe would
# then report a URL it had never contacted. Everything else restic reads —
# AWS_*, RESTIC_REST_*, RESTIC_CACHE_DIR — stays the operator's.
KASBAH_BACKUP_OWNED_ENV=(RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE
                         RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND)
KASBAH_BACKUP_KEEP_DAILY_DEFAULT=7
KASBAH_BACKUP_KEEP_WEEKLY_DEFAULT=4
KASBAH_BACKUP_KEEP_MONTHLY_DEFAULT=3

# Which command is speaking. Every checker below is shared between `server init`
# and `server backup-prune`, and a message that named the wrong command — or a
# flag the command does not have — is a message that sends the reader to the
# wrong manual page.
_BK_CMD="server init"

# The parsed command line, shared with lib/server_init.sh's parser.
_BK_ENABLED=no
_BK_TIMEOUT=""
_BK_REPO_BASE=""
_BK_AT=""
_BK_JITTER=""
_BK_KEEP_DAILY=""
_BK_KEEP_WEEKLY=""
_BK_KEEP_MONTHLY=""
_BK_ENV_GIVEN=()
_BK_ENV_NONE=""
_BK_PASS_GIVEN=()

# What was settled, and where each value came from.
_BK_REPO_BASE_ORIGIN=""
_BK_ENV_ORIGIN=""
_BK_ENV_CONTENT=""
_BK_REPOS=()
_BK_REPOS_NEW=()
declare -A _BK_PASS=()
declare -A _BK_FACT=()
_BK_FILES=(compose.yml backup.sh)
declare -A _BK_KEY=(
    [compose.yml]=backup_compose_b64
    [backup.sh]=backup_runner_b64
)
declare -A _BK_CURRENT=()
_BK_CHANGED=()
_BK_TMPDIR=""
_BK_PROJECT_FALLBACKS=()
# The names kasbah owns under <apps>, handed to the read payload as an argument
# rather than written out inside it. Every neighbour that walks <apps> does the
# same — prune.sh, drop.sh and server_status.sh all build this exact array — and
# a payload on the far side of ssh can source nothing, so an argument is the only
# way one list stays one list.
_BK_RESERVED=(.kasbah "${KASBAH_RESERVED_NAMES[@]}")

# --- Printing a repository URL ----------------------------------------------------

# The userinfo of a repository URL, replaced with `***` for display only — the
# value kasbah stores, ships and hands to restic is never touched. restic prints
# `user:***@` in its own output, and kasbah printing the password beside it in
# the same paragraph made kasbah less careful than the tool it wraps.
#
# This is not the URL-parsing D5 forbids: nothing here branches on a scheme, and
# a string with no `://` or no `@` comes back exactly as it went in. What it
# looks at is the authority, which every URL that has one spells the same way.
_bk_redact_url() {
    local _ru_in="$1" _ru_out="$2" _ru_scheme _ru_auth_host _ru_tail _ru_auth
    case $_ru_in in
        *"://"*) ;;
        *) printf -v "$_ru_out" '%s' "$_ru_in"; return 0 ;;
    esac
    _ru_scheme="${_ru_in%%://*}://"
    _ru_auth_host="${_ru_in#*://}"
    _ru_tail=""
    case $_ru_auth_host in
        */*) _ru_tail="/${_ru_auth_host#*/}"; _ru_auth_host="${_ru_auth_host%%/*}" ;;
    esac
    case $_ru_auth_host in
        *@*)
            # The last `@` separates userinfo from host: a `@` inside the
            # userinfo is legal where a second one in the host is not.
            _ru_auth="${_ru_auth_host%@*}"
            case $_ru_auth in
                *:*) _ru_auth_host="${_ru_auth%%:*}:***@${_ru_auth_host##*@}" ;;
            esac
            ;;
    esac
    printf -v "$_ru_out" '%s' "$_ru_scheme$_ru_auth_host$_ru_tail"
}

# The same, as a value to interpolate. Every message in this file that names a
# repository goes through one of the two, so there is one answer to "does kasbah
# print credentials" rather than nine.
_bk_shown() {
    local _sh_v=""
    _bk_redact_url "$1" _sh_v
    printf '%s' "$_sh_v"
}

# --- Value checks ---------------------------------------------------------------

# The repository base is opaque and stays opaque: it is appended to, never
# parsed. What is checked is only what would break the file it is written into —
# it becomes one KEY=VALUE line of <apps>/.kasbah/backup/env, which the runner
# reads a line at a time.
#
# The trailing separator is required rather than added. Appending one would be a
# judgement about the URL's shape, and getting it wrong for a scheme kasbah has
# never seen is exactly what D5 exists to prevent; refusing says what is wrong
# and lets the operator spell it.
_bk_check_repo_base() {
    local flag="$1" v="$2"
    [ -n "$v" ] \
        || die "$_BK_CMD: $flag must not be empty (it is where the snapshots go, and kasbah never invents one)"
    case $v in
        *[[:cntrl:]]*) die "$_BK_CMD: $flag must not contain control characters — it is one line of <apps>/.kasbah/backup/env" ;;
        *[[:space:]]*) die "$_BK_CMD: $flag must not contain whitespace" ;;
    esac
    case $v in
        */) ;;
        *)  die "$_BK_CMD: $flag$(_bk_shown "$v") must end in '/' — kasbah appends the repository name to it and never edits the URL, so the separator has to be in the value" ;;
    esac
    return 0
}

_bk_check_at() {
    local v="$1"
    [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
        || die "$_BK_CMD: --backup-at=$v is not a time of day (expected HH:MM in 24-hour form, e.g. 02:00)"
    return 0
}

# Under a day, because the slot is computed as seconds past local midnight: a
# jitter of 90000 would silently be the same as one of 3600.
_bk_check_jitter() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] \
        || die "$_BK_CMD: --backup-jitter=$v is not a whole number of seconds"
    [ "$v" -lt 86400 ] \
        || die "$_BK_CMD: --backup-jitter=$v is a day or more — the slot is a time of day, so anything from 86400 wraps"
    return 0
}

_bk_check_keep() {
    local flag="$1" v="$2"
    [[ "$v" =~ ^[0-9]+$ ]] \
        || die "$_BK_CMD: $flag$v is not a whole number of snapshots to keep"
    return 0
}

# The bound on one restic invocation. A floor rather than a bare integer check:
# a timeout of zero means "kill it immediately" to timeout(1), which would make
# every backup fail in a way nothing about the value explains.
_bk_check_timeout() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] \
        || die "$_BK_CMD: --backup-timeout=$v is not a whole number of seconds"
    [ "$v" -ge 30 ] \
        || die "$_BK_CMD: --backup-timeout=$v is under 30 seconds — that is a bound restic could not finish an empty repository inside, and timeout(1) reads 0 as \"kill it now\""
    return 0
}

# A repository name is a path segment of a URL nothing here parses, so the
# charset is the manifest's own for `name` and `client`.
#
# The names kasbah owns under <apps> are refused, **except `mail`**: that one is
# a repository, and kasbah's own (D7), so an operator has to be able to give it
# a password. The other three name no repository that can exist — they are not
# projects, so no `client:` can be them. Derived from KASBAH_RESERVED_NAMES
# rather than written out again, so the exception is the only thing this
# function states about that list.
_bk_check_repo_name() {
    local flag="$1" v="$2" reserved
    [[ "$v" =~ ^[a-z][a-z0-9-]*$ ]] \
        || die "$_BK_CMD: $flag$v is not a repository name (expected ^[a-z][a-z0-9-]*\$, the same charset as a project name)"
    for reserved in "${KASBAH_RESERVED_NAMES[@]}"; do
        [ "$reserved" != mail ] || continue
        [ "$v" != "$reserved" ] \
            || die "$_BK_CMD: $flag$v is a directory kasbah owns under <apps>, and no repository of that name exists (kasbah's own is 'mail')"
    done
    return 0
}

# One KEY=VALUE for the restic environment. The key has to be a variable name
# because the runner exports it; the value may be anything that fits on a line,
# because it is a credential and kasbah has no business narrowing it.
_bk_check_env_entry() {
    local flag="$1" entry="$2" key owned
    case $entry in
        *=*) ;;
        *)   die "$_BK_CMD: $flag must be KEY=VALUE (only the name is quoted back — the value is a credential)" ;;
    esac
    key="${entry%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "$_BK_CMD: the key of $flag is '$key', which is not a variable name"
    case $key in
        KASBAH_BACKUP_*) die "$_BK_CMD: $flag$key= is a key kasbah owns and rewrites on every run (the repository base is --backup-repo-base=)" ;;
    esac
    for owned in "${KASBAH_BACKUP_OWNED_ENV[@]}"; do
        [ "$key" != "$owned" ] \
            || die "$_BK_CMD: $flag$key= is a key kasbah owns — it is what says which repository restic opens and what key opens it, and an entry naming one would point the credential probe somewhere other than where the backups go. The repository is --backup-repo-base=; the password is --backup-password=<repo>=<password>."
    done
    case ${entry#*=} in
        *[$'\n'$'\r']*) die "$_BK_CMD: the value of $flag$key= must not contain a newline — it is one line of <apps>/.kasbah/backup/env" ;;
    esac
    return 0
}

# Whether a key is one kasbah sets itself. Read by the env-file guard and by the
# report, so "which keys are kasbah's" has one answer.
_bk_env_key_owned() {
    local k="$1" owned
    case $k in KASBAH_BACKUP_*) return 0 ;; esac
    for owned in "${KASBAH_BACKUP_OWNED_ENV[@]}"; do
        [ "$k" != "$owned" ] || return 0
    done
    return 1
}

# `--backup-password=<repo>=<password>`. The repository name is checked; the
# password is checked only for the newline that would silently truncate it,
# because RESTIC_PASSWORD_FILE is read as one line.
_bk_split_password() {
    local _sp_given="$1" _sp_repo_out="$2" _sp_pass_out="$3" _sp_repo _sp_pass
    case $_sp_given in
        *=*) ;;
        *)   die "$_BK_CMD: --backup-password= must be <repo>=<password> — repositories are per client, so a password is too (only the repository name is ever quoted back)" ;;
    esac
    _sp_repo="${_sp_given%%=*}"
    _sp_pass="${_sp_given#*=}"
    _bk_check_repo_name "--backup-password=" "$_sp_repo"
    _bk_check_password "$_sp_repo" "$_sp_pass"
    printf -v "$_sp_repo_out" '%s' "$_sp_repo"
    printf -v "$_sp_pass_out" '%s' "$_sp_pass"
    return 0
}

_bk_check_password() {
    local repo="$1" pass="$2"
    [ -n "$pass" ] \
        || die "$_BK_CMD: the restic password for '$repo' must not be empty — it is what encrypts that client's snapshots, and kasbah never generates one"
    case $pass in
        *[$'\n'$'\r']*) die "$_BK_CMD: the restic password for '$repo' must not contain a newline — restic reads the password file's first line, so only the part before it would be used" ;;
    esac
    return 0
}

# The per-VPS jitter of docs/backup.md → Cadence, derived rather than drawn: the
# rendered compose file is compared byte for byte on every re-run, so a random
# value would restart the stack every time init ran. Derived from the target, so
# two servers an operator prepares from one workstation do not share a slot.
_bk_jitter_for() {
    local _jf_target="$1" _jf_out="$2" _jf_sum
    _jf_sum="$(cksum <<<"$_jf_target")" \
        || die "internal: could not derive the backup jitter (cksum failed)"
    printf -v "$_jf_out" '%s' "$(( ${_jf_sum%% *} % 3600 ))"
    return 0
}

# --- The marker ---------------------------------------------------------------

# What this run wants recorded under `backup`, as JSON, or nothing when backups
# are not enabled — in which case _server_marker_json leaves whatever is already
# there exactly as it found it. That is `--no-backup`'s documented behaviour:
# init scaffolds backups and never removes them, the same way it treats mail.
_bk_marker_json() {
    [ "$_BK_ENABLED" = yes ] || return 0
    jq -n \
        --arg repo_base "$_BK_REPO_BASE" \
        --arg at "$_BK_AT" \
        --argjson jitter "$_BK_JITTER" \
        --argjson timeout "$_BK_TIMEOUT" \
        --argjson daily "$_BK_KEEP_DAILY" \
        --argjson weekly "$_BK_KEEP_WEEKLY" \
        --argjson monthly "$_BK_KEEP_MONTHLY" \
        '{ enabled: true, repo_base: $repo_base, at: $at, jitter: $jitter,
           timeout: $timeout,
           retention: { daily: $daily, weekly: $weekly, monthly: $monthly } }'
}

# The `backup` object already on the server, field by field. A re-run reproduces
# it rather than re-deciding it — the rule the dashboard domain and the ACME
# address follow — so `kasbah server init --with-backup` with no backup flags at
# all is a no-op against a server that already has them.
_bk_from_marker() {
    local marker="$1" v
    [ -n "$marker" ] || return 0
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$marker" || return 0

    if [ -z "$_BK_REPO_BASE" ]; then
        v="$(jq -r '.backup.repo_base // "" | tostring' <<<"$marker")"
        [ -z "$v" ] || { _BK_REPO_BASE="$v"; _BK_REPO_BASE_ORIGIN=marker; }
    fi
    [ -n "$_BK_AT" ] || _BK_AT="$(jq -r '.backup.at // "" | tostring' <<<"$marker")"
    [ -n "$_BK_JITTER" ] || _BK_JITTER="$(jq -r '.backup.jitter // "" | tostring' <<<"$marker")"
    [ -n "$_BK_TIMEOUT" ] || _BK_TIMEOUT="$(jq -r '.backup.timeout // "" | tostring' <<<"$marker")"
    [ -n "$_BK_KEEP_DAILY" ] || _BK_KEEP_DAILY="$(jq -r '.backup.retention.daily // "" | tostring' <<<"$marker")"
    [ -n "$_BK_KEEP_WEEKLY" ] || _BK_KEEP_WEEKLY="$(jq -r '.backup.retention.weekly // "" | tostring' <<<"$marker")"
    [ -n "$_BK_KEEP_MONTHLY" ] || _BK_KEEP_MONTHLY="$(jq -r '.backup.retention.monthly // "" | tostring' <<<"$marker")"
    return 0
}

# --- Reading the server ---------------------------------------------------------

_bk_absorb() {
    local _ba_what="$1" _ba_out="$2"; shift 2
    local _ba_line _ba_key
    local _ba_missing=()

    while IFS= read -r _ba_line; do
        _ba_line="${_ba_line%$'\r'}"
        case $_ba_line in *=*) _BK_FACT[${_ba_line%%=*}]="${_ba_line#*=}" ;; esac
    done <<<"$_ba_out"

    for _ba_key in "$@"; do
        [ -n "${_BK_FACT[$_ba_key]+set}" ] || _ba_missing+=("$_ba_key")
    done
    if [ "${#_ba_missing[@]}" -gt 0 ]; then
        err "$_ba_what reported no ${_ba_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _ba_line; do err_cont "| $_ba_line"; done <<<"$_ba_out"
        exit 1
    fi
    return 0
}

# Everything the backup half needs to know about the server, in one round trip
# and before anything is decided: the two kasbah-owned files as they stand, the
# operator's env file, which repositories already hold a password, and which
# projects are here with which effective client.
#
# The project list is what decides how many passwords this run asks for, so it
# is read rather than guessed. The client comes from <apps>/<project>/.kasbah-client,
# which `kasbah deploy` writes (D12) — an empty value means no record, and `?`
# means a record that is not a repository name. Both fall back to the project's
# own directory name, which is `client:`'s documented default.
_bk_read() {
    local target="$1" apps="$2" data="$3" out rc=0 rel enc dec

    [ "$_BK_ENABLED" = yes ] || return 0

    out=$(ssh_script "$apps" "$data" "${_BK_RESERVED[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
reserved=" $3 "
dir="$apps/.kasbah/backup"

emit() {
    local enc=""
    if [ -f "$2" ]; then enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""; fi
    printf '%s=%s\n' "$1" "$enc"
}

if [ -e "$dir" ] && [ ! -d "$dir" ]; then printf 'backup_dir=notdir\n'
elif [ -d "$dir" ];                  then printf 'backup_dir=dir\n'
else                                      printf 'backup_dir=absent\n'
fi

emit backup_compose_b64 "$dir/compose.yml"
emit backup_runner_b64  "$dir/backup.sh"
emit backup_env_b64     "$dir/env"

# Which repositories already hold a password. Only their names travel; the
# passwords themselves stay on the server, and init never rewrites one — a
# rotated password is a repository nobody can read.
have=""
for f in "$dir"/repos/*.pass; do
    [ -f "$f" ] || continue
    b=${f##*/}
    have="$have ${b%.pass}"
done
printf 'backup_haspass=%s\n' "${have# }"

if [ -d "$apps/mail" ]; then printf 'backup_mail=yes\n'; else printf 'backup_mail=no\n'; fi

# One `<name>=<client>` per project, space separated. Names and clients are
# [a-z0-9-] by construction, so nothing here needs quoting — and a record that
# is not is reported as `?` rather than passed on, because it is about to be
# offered as a repository name.
# The data path is excluded by **path**, not by the name `data`: with
# --data-path=<apps>/vol the directory beside the projects is called `vol`, and
# excluding by name would offer it as a repository — one this run would ask for a
# password for and the runner would never write to. templates/backup/backup.sh
# excludes it the same way, which is what keeps the two answers one answer.
list=""
for d in "$apps"/*; do
    [ -d "$d" ] || continue
    [ "$d" != "$data" ] || continue
    n=${d##*/}
    case $reserved in *" $n "*) continue ;; esac
    c=""
    if [ -f "$d/.kasbah-client" ]; then
        IFS= read -r c < "$d/.kasbah-client" || c=""
        c=${c%$'\r'}
        case $c in
            '') ;;
            *[!a-z0-9-]*|[!a-z]*) c='?' ;;
            *) case $reserved in *" $c "*) c='?' ;; esac ;;
        esac
    fi
    list="$list $n=$c"
done
printf 'backup_projects=%s\n' "${list# }"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the backup stack on $target (the remote step exited $rc, see above)"

    _bk_absorb "the backup stack read on $target" "$out" \
        backup_dir backup_compose_b64 backup_runner_b64 backup_env_b64 \
        backup_haspass backup_mail backup_projects

    case "${_BK_FACT[backup_dir]}" in
        absent|dir) ;;
        notdir)
            err "$apps/.kasbah/backup on $target exists and is not a directory"
            err_cont "that is where the backup stack lives — its compose file, its runner, the"
            err_cont "repository base and the per-repository passwords. Look at it, remove it,"
            err_cont "and re-run. Nothing has been changed."
            exit 1
            ;;
        *) die "the backup stack read on $target reported backup_dir='${_BK_FACT[backup_dir]}', which this kasbah does not know" ;;
    esac

    _BK_CURRENT=()
    for rel in "${_BK_FILES[@]}"; do
        enc="${_BK_FACT[${_BK_KEY[$rel]}]}"
        # The `printf x` sentinel keeps trailing newlines, which $(…) strips.
        dec=$( { printf '%s' "$enc" | base64 -d 2>/dev/null; printf x; } )
        _BK_CURRENT[$rel]="${dec%x}"
    done
    dec=$( { printf '%s' "${_BK_FACT[backup_env_b64]}" | base64 -d 2>/dev/null; printf x; } )
    _BK_FACT[env_current]="${dec%x}"
    return 0
}

# The repositories this server needs, in the order they are asked about: the
# effective client of every project, then mail. The probe repository is not
# among them — it is kasbah's own and carries a constant password.
_bk_repo_set() {
    local entry name client seen=""

    _BK_REPOS=()
    _BK_PROJECT_FALLBACKS=()
    for entry in ${_BK_FACT[backup_projects]}; do
        name="${entry%%=*}"
        client="${entry#*=}"
        case $client in
            ''|'?') _BK_PROJECT_FALLBACKS+=("$name"); client="$name" ;;
        esac
        case " $seen " in
            *" $client "*) continue ;;
        esac
        seen="$seen $client"
        _BK_REPOS+=("$client")
    done
    if [ "${_BK_FACT[backup_mail]}" = yes ]; then
        case " $seen " in
            *" mail "*) ;;
            *) _BK_REPOS+=(mail) ;;
        esac
    fi
    return 0
}

# --- Settling the values ---------------------------------------------------------

_bk_values() {
    local target="$1" repo have entry key pass
    local answer="" name=""

    [ "$_BK_ENABLED" = yes ] || return 0

    if [ -z "$_BK_REPO_BASE" ]; then
        prompt_value backup-repo-base \
            "Restic repository base for $target — snapshots go to <base><client>, with a trailing '/'" \
            "" _BK_REPO_BASE
        _BK_REPO_BASE_ORIGIN=prompt
    fi
    _bk_check_repo_base --backup-repo-base= "$_BK_REPO_BASE"
    # Said once, and not refused: a `rest:` target carries its credential in the
    # URL and has nowhere else to put it — the rig's own harness is one — so
    # refusing would be a constraint shaped by one backend. What the operator
    # has to know is where that string then ends up.
    if [ "$(_bk_shown "$_BK_REPO_BASE")" != "$_BK_REPO_BASE" ]; then
        warn "the repository base carries a credential: $(_bk_shown "$_BK_REPO_BASE")"
        warn "it is recorded in $target's server marker, which is mode 644 by contract, and"
        warn "printed (redacted) by every command that names it. Where the backend allows it,"
        warn "put the credential in the environment block instead — --backup-env=KEY=VALUE."
    fi

    [ -n "$_BK_AT" ] || _BK_AT="$KASBAH_BACKUP_AT_DEFAULT"
    _bk_check_at "$_BK_AT"
    [ -n "$_BK_JITTER" ] || _bk_jitter_for "$target" _BK_JITTER
    _bk_check_jitter "$_BK_JITTER"
    [ -n "$_BK_TIMEOUT" ] || _BK_TIMEOUT="$KASBAH_BACKUP_TIMEOUT_DEFAULT"
    _bk_check_timeout "$_BK_TIMEOUT"
    [ -n "$_BK_KEEP_DAILY" ]   || _BK_KEEP_DAILY="$KASBAH_BACKUP_KEEP_DAILY_DEFAULT"
    [ -n "$_BK_KEEP_WEEKLY" ]  || _BK_KEEP_WEEKLY="$KASBAH_BACKUP_KEEP_WEEKLY_DEFAULT"
    [ -n "$_BK_KEEP_MONTHLY" ] || _BK_KEEP_MONTHLY="$KASBAH_BACKUP_KEEP_MONTHLY_DEFAULT"
    _bk_check_keep --backup-keep-daily=   "$_BK_KEEP_DAILY"
    _bk_check_keep --backup-keep-weekly=  "$_BK_KEEP_WEEKLY"
    _bk_check_keep --backup-keep-monthly= "$_BK_KEEP_MONTHLY"

    # The environment block, asked about exactly once: on the run that creates
    # the env file. After that the file is the operator's — kasbah rewrites the
    # one key it owns and copies every other line through, the same split
    # <apps>/mail/.env has — so a `rest:` target that legitimately needs no
    # environment is not asked again on every re-run.
    _BK_ENV_ORIGIN=file
    if [ "${#_BK_ENV_GIVEN[@]}" -gt 0 ]; then
        _BK_ENV_ORIGIN=flag
    elif [ -n "$_BK_ENV_NONE" ]; then
        _BK_ENV_ORIGIN=none
    elif [ -z "${_BK_FACT[env_current]}" ]; then
        if prompt_choice 'backup-env=KEY=VALUE' no-backup-env \
            "Does restic need environment variables to reach $(_bk_shown "$_BK_REPO_BASE") (an S3 key pair, for example)?" \
            ""; then
            _BK_ENV_ORIGIN=prompt
            while :; do
                prompt_value backup-env \
                    "Variable name, or 'done' to finish" "" name done
                [ "$name" != done ] || break
                prompt_secret backup-env "Value for $name (not echoed)" "" pass
                _bk_check_env_entry --backup-env= "$name=$pass"
                _BK_ENV_GIVEN+=("$name=$pass")
            done
        else
            _BK_ENV_ORIGIN=none
        fi
    fi

    # One password per repository (D2), asked only for a repository that has
    # none. A password already on the server is never rewritten, for the reason
    # postfix-accounts.cf is never rewritten: this one decrypts that client's
    # entire snapshot history, and a re-run that rotated it would be a re-run
    # that threw the history away.
    _bk_repo_set
    _BK_PASS=()
    _BK_REPOS_NEW=()
    have=" ${_BK_FACT[backup_haspass]} "
    for entry in ${_BK_PASS_GIVEN[@]+"${_BK_PASS_GIVEN[@]}"}; do
        _bk_split_password "$entry" key pass
        case $have in
            *" $key "*)
                warn "--backup-password=$key= had no effect: $key already has a password on $target,"
                warn "and init never rewrites one — that would leave the repository unreadable."
                continue
                ;;
        esac
        _BK_PASS[$key]="$pass"
        # A password may be supplied for a repository no project claims yet, so
        # a client can be seeded before its first deploy.
        case " ${_BK_REPOS[*]-} " in
            *" $key "*) ;;
            *) _BK_REPOS+=("$key") ;;
        esac
    done

    for repo in ${_BK_REPOS[@]+"${_BK_REPOS[@]}"}; do
        case $have in *" $repo "*) continue ;; esac
        [ -z "${_BK_PASS[$repo]+set}" ] || continue
        prompt_secret "backup-password=$repo" \
            "Restic password for the '$repo' repository (encrypts its snapshots; kasbah never generates one and cannot recover it)" \
            "" pass
        _bk_check_password "$repo" "$pass"
        _BK_PASS[$repo]="$pass"
    done
    for repo in ${_BK_REPOS[@]+"${_BK_REPOS[@]}"}; do
        [ -z "${_BK_PASS[$repo]+set}" ] || _BK_REPOS_NEW+=("$repo")
    done
    return 0
}

# --- Rendering ------------------------------------------------------------------

# The env file, merged the way <apps>/mail/.env is merged: kasbah's own key and
# any key named on this command line are rewritten by name, and every other line
# is copied through untouched, so an operator's credential block survives a
# re-run without ever being read back and re-sent.
_bk_merge_env() {
    local default="$1" current="$2" out_var="$3"
    local line stripped key merged="" entry
    local -A want=()
    local -A seen=()

    want[KASBAH_BACKUP_REPO_BASE]="$_BK_REPO_BASE"
    for entry in ${_BK_ENV_GIVEN[@]+"${_BK_ENV_GIVEN[@]}"}; do
        want[${entry%%=*}]="${entry#*=}"
    done

    if [ -z "$current" ]; then
        printf -v "$out_var" '%s' "$default"
        # The rendered default already carries the repository base; anything
        # else named on the command line is appended to it.
        for entry in ${_BK_ENV_GIVEN[@]+"${_BK_ENV_GIVEN[@]}"}; do
            printf -v "$out_var" '%s%s\n' "${!out_var}" "$entry"
        done
        return 0
    fi

    # One trailing newline is taken off before the loop and put back by it: a
    # here-string appends a newline of its own, so a file that already ends in
    # one would gain a blank line on every run — and a file that grows by a byte
    # per run is a file that is re-shipped for ever, which is the one thing an
    # idempotent init must not do. A file that ends without a newline is
    # normalised to one and is then stable.
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line%$'\r'}"
        case $stripped in
            *=*) key="${stripped%%=*}" ;;
            *)   key="" ;;
        esac
        if [ -n "$key" ] && [ -n "${want[$key]+set}" ]; then
            line="$key=${want[$key]}"
            seen[$key]=1
        fi
        merged="$merged$line"$'\n'
    done <<<"${current%$'\n'}"

    # A key kasbah owns that the file does not carry is appended rather than
    # silently dropped, in a fixed order: the repository base first, then the
    # command line's own, so two runs with the same flags render the same bytes.
    for key in KASBAH_BACKUP_REPO_BASE ${_BK_ENV_GIVEN[@]+"${_BK_ENV_GIVEN[@]%%=*}"}; do
        [ -z "${seen[$key]+set}" ] || continue
        merged="$merged$key=${want[$key]}"$'\n'
        seen[$key]=1
    done
    printf -v "$out_var" '%s' "$merged"
    return 0
}

# An env file already carrying a key kasbah sets itself. Refused rather than
# copied through, and rather than stripped in silence: the file is the operator's
# half of a split they were told they own, and a line vanishing from it without a
# word is worse than a run that stops. It is reachable only from a file written
# by hand or by a kasbah too old to refuse the flag.
_bk_guard_env_file() {
    local apps="$1" current="$2" line key
    [ -n "$current" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case $line in
            ''|'#'*) continue ;;
            *=*) key="${line%%=*}" ;;
            *) continue ;;
        esac
        case $key in KASBAH_BACKUP_*) continue ;; esac
        _bk_env_key_owned "$key" || continue
        err "$apps/.kasbah/backup/env sets $key, which kasbah sets itself"
        err_cont "that variable decides which repository restic opens and what key opens it,"
        err_cont "so a value there would point the credential probe at one repository while the"
        err_cont "scheduled backup wrote to another — and the probe would report a URL it had"
        err_cont "never contacted. Remove the line from that file and re-run."
        err_cont "The repository is --backup-repo-base=; the password is --backup-password=<repo>=<password>."
        exit 1
    done <<<"$current"
    return 0
}

# Renders the stack into <tmpdir>/backup: the compose file, the runner, the env
# file and one password file per repository this run has a new password for.
# Everything that carries a secret is written at mode 600 and shipped by rsync,
# never handed to a remote step as an argument — argv is readable in the process
# table for as long as the step runs.
_bk_render() {
    local tmpdir="$1" apps="$2" data="$3" repo yq_err default data_mount
    local tpl="${KASBAH_TEMPLATE_DIR:-}"

    [ "$_BK_ENABLED" = yes ] || return 0
    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -d "$tpl/backup" ] \
        || die "the backup templates are missing (looked in $tpl/backup) — this kasbah installation is incomplete"
    command -v yq >/dev/null \
        || die "yq is required to render the backup stack (install yq and retry)"

    _BK_TMPDIR="$tmpdir/backup"
    mkdir -p "$_BK_TMPDIR/repos" || die "could not create $_BK_TMPDIR/repos"
    chmod 700 "$_BK_TMPDIR/repos" || die "could not restrict $_BK_TMPDIR/repos"

    # The data path is mounted at its own name so a snapshot's paths are the
    # server's real paths. Rendered as a whole line and left out when the two
    # paths are the same, which Docker refuses as a duplicate mount point; a
    # data path merely *below* the apps path is a second, narrower read-only
    # bind and is fine.
    data_mount=""
    [ "$data" = "$apps" ] \
        || data_mount="      - \"$data:$data:ro\""

    _SI_SUBST=(
        [APPS_PATH]="$apps"
        [DATA_PATH]="$data"
        [RESTIC_IMAGE]="$KASBAH_RESTIC_IMAGE"
        [BACKUP_AT]="$_BK_AT"
        [BACKUP_JITTER]="$_BK_JITTER"
        [BACKUP_TIMEOUT]="$_BK_TIMEOUT"
        [BACKUP_DATA_MOUNT]="$data_mount"
    )
    _si_render_template "$tpl/backup/compose.yml" "$_BK_TMPDIR/compose.yml" "backup compose.yml"
    if ! yq_err="$(yq -e . "$_BK_TMPDIR/compose.yml" 2>&1 >/dev/null)"; then
        err "the rendered backup compose.yml is not valid YAML — refusing to ship it"
        err_cont "${yq_err:-yq rejected the file and said nothing}"
        err_cont "rendered with apps $apps, data $data, at $_BK_AT, jitter $_BK_JITTER"
        exit 1
    fi

    # The runner carries no substitution token at all: every value it needs
    # arrives in the container's environment from the compose file above, so the
    # script on the server is byte-identical on every VPS and can be diffed
    # against this checkout.
    _SI_SUBST=()
    _si_render_template "$tpl/backup/backup.sh" "$_BK_TMPDIR/backup.sh" "backup runner"
    chmod 755 "$_BK_TMPDIR/backup.sh" || die "could not make $_BK_TMPDIR/backup.sh executable"

    _SI_SUBST=([BACKUP_REPO_BASE]="$_BK_REPO_BASE")
    _si_render_template "$tpl/backup/env" "$_BK_TMPDIR/env.default" "backup env"
    default="$(cat "$_BK_TMPDIR/env.default"; printf x)" || die "could not read the rendered backup env"
    default="${default%x}"
    _bk_guard_env_file "$apps" "${_BK_FACT[env_current]}"
    _bk_merge_env "$default" "${_BK_FACT[env_current]}" _BK_ENV_CONTENT
    printf '%s' "$_BK_ENV_CONTENT" > "$_BK_TMPDIR/env" || die "could not write $_BK_TMPDIR/env"
    chmod 600 "$_BK_TMPDIR/env" || die "could not restrict $_BK_TMPDIR/env"
    rm -f "$_BK_TMPDIR/env.default"

    for repo in ${_BK_REPOS_NEW[@]+"${_BK_REPOS_NEW[@]}"}; do
        printf '%s\n' "${_BK_PASS[$repo]}" > "$_BK_TMPDIR/repos/$repo.pass" \
            || die "could not write the password file for $repo"
        chmod 600 "$_BK_TMPDIR/repos/$repo.pass" \
            || die "could not restrict the password file for $repo"
    done
    return 0
}

# --- Landing it on the server -----------------------------------------------------

# The tree, and nothing in it. Modes are stated on every run rather than left to
# whichever run created the directory: <apps>/.kasbah/backup/repos holds one
# password per client repository, and a mode is a fact about the directory, not
# about the run that happened to make it.
_bk_layout() {
    local target="$1" apps="$2" out rc=0

    [ "$_BK_ENABLED" = yes ] || return 0

    out=$(ssh_script "$apps" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/.kasbah/backup"

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

mkdir -p "$dir/repos" "$dir/state" || fail "could not create $dir/repos and $dir/state"
# state/ is the one directory in here the container writes to, and the only
# place a last-run record could live: everything else is mounted read-only.
chmod 700 "$dir" "$dir/repos" "$dir/state" || fail "could not restrict $dir"
printf 'backup_layout=done\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not lay out $apps/.kasbah/backup on $target (the remote step exited $rc, see above)"
    _bk_absorb "the backup layout step on $target" "$out" backup_layout
    return 0
}

# The env file and the new password files, by rsync. rsync writes a temp file
# and renames, so the runner never reads half a credential; --chmod fixes the
# mode on the far side whatever the operator's umask is.
_bk_ship_secrets() {
    local target="$1" apps="$2" repo dest

    [ "$_BK_ENABLED" = yes ] || return 0

    if [ "$_BK_ENV_CONTENT" != "${_BK_FACT[env_current]}" ]; then
        ssh_rsync -pt --chmod=F600 -s "$_BK_TMPDIR/env" "$SSH_TARGET:$apps/.kasbah/backup/env" >/dev/null \
            || die "could not ship the backup env to $target:$apps/.kasbah/backup/env"
        _BK_FACT[env_state]=written
    else
        _BK_FACT[env_state]=unchanged
    fi

    for repo in ${_BK_REPOS_NEW[@]+"${_BK_REPOS_NEW[@]}"}; do
        dest="$apps/.kasbah/backup/repos/$repo.pass"
        ssh_rsync -pt --chmod=F600 -s "$_BK_TMPDIR/repos/$repo.pass" "$SSH_TARGET:$dest" >/dev/null \
            || die "could not ship the $repo repository password to $target:$dest"
    done
    return 0
}

# --- The credential probe (D6) -----------------------------------------------------

# kasbah cannot *create* an append-only credential — the operator makes one at
# their provider — so it proves the one it was given behaves like one, against
# the real storage, before a stack that trusts it is ever started.
#
# One code path, both backends, and no exit status is trusted: the run writes two
# snapshots, asks restic to forget **a named one of them**, and then counts the
# snapshots again. Fewer than before means the credential deleted one, and the
# run is refused. Wording, HTTP codes and restic's own argument checking are all
# beside the point — the question is whether the history shrank.
#
# A named snapshot rather than a retention policy, which is the spelling 8.0
# measured. `forget --keep-last 1` looked equivalent and is not: restic groups
# snapshots by host and paths before applying a policy, and two `docker run`
# containers have two random hostnames — so the two probe snapshots land in two
# groups, each keeps its last, and **nothing is removed however much access the
# credential has**. That version of this probe passed against the full-access
# endpoint; the rig test is what caught it.
#
# The second snapshot is what stops the named-id form being vacuous in the other
# direction: forgetting the only snapshot in a repository is the "remove
# everything" case restic refuses on its own argument check, without contacting
# the server at all. The write half is the paired positive — a credential that
# cannot even reach the repository fails earlier, with a different message.
# What a refusal has to say about the stack, which is not the same on a first run
# as on a re-run. The credentials are written before the probe — it has to test
# the ones that will actually be in effect, and they live on the server — so a
# server that already had a backup stack still has one, now holding credentials
# this run has just refused. Saying "no backup stack was started" there would be
# false, and it is the sentence an operator would act on.
_bk_probe_stack_note() {
    local apps="$1"
    if [ -z "${_BK_CURRENT[compose.yml]:-}" ]; then
        err_cont "No backup stack was started."
    else
        err_cont "The backup stack already on this server is still running, and now holds the"
        err_cont "credentials this run refused: it will keep failing until they are fixed. Take"
        err_cont "it down with \`docker compose -p $KASBAH_BACKUP_PROJECT down\` in $apps/.kasbah/backup"
        err_cont "if it must not run at all meanwhile."
    fi
    return 0
}

_bk_probe() {
    local target="$1" apps="$2" out rc=0 detail line probed

    [ "$_BK_ENABLED" = yes ] || return 0

    out=$(ssh_script "$KASBAH_RESTIC_IMAGE" "$apps" \
                     "$KASBAH_BACKUP_PROBE_REPO" "$KASBAH_BACKUP_PROBE_PASSWORD" \
                     "$_BK_TIMEOUT" "${KASBAH_BACKUP_OWNED_ENV[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
image=$1
apps=$2
repo=$3
probe_pass=$4
timeout_s=$5
owned=" $6 "

envfile="$apps/.kasbah/backup/env"
fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ -f "$envfile" ] || fail "$envfile is not there — the probe has no credentials to test"

base=""
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in KASBAH_BACKUP_REPO_BASE=*) base=${line#*=} ;; esac
done < "$envfile"
[ -n "$base" ] || fail "$envfile sets no KASBAH_BACKUP_REPO_BASE"

d=$(mktemp -d) || fail "could not create a temp directory for the probe"
cleanup() { rm -rf "$d"; }
trap cleanup EXIT
chmod 700 "$d" || fail "could not restrict $d"
mkdir -p "$d/src" || fail "could not create $d/src"
printf 'kasbah backup credential probe\n' > "$d/src/probe.txt" || fail "could not write the probe object"
printf '%s\n' "$probe_pass" > "$d/pass" || fail "could not write the probe password"
chmod 600 "$d/pass" || fail "could not restrict the probe password"

# Every credential reaches restic through --env-file and none through argv: the
# repository URL carries the credential for a `rest:` target, and the process
# table is readable by every user of the machine for as long as the run lasts.
#
# The operator's lines go in **first** and kasbah's last, because
# `docker --env-file` is last-wins (measured). The workstation already refuses a
# RESTIC_REPOSITORY in either the flag or the file; writing kasbah's keys last
# means that even if one ever got through, it could not point this probe at a
# repository other than the one the scheduled backup writes to — which is the
# one shape of this bug that is invisible, because the probe would then pass and
# report a URL it never contacted.
{
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case $line in
            ''|'#'*|KASBAH_BACKUP_*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        case $owned in *" ${line%%=*} "*) continue ;; esac
        printf '%s\n' "$line"
    done < "$envfile"
    printf 'RESTIC_REPOSITORY=%s%s\n' "$base" "$repo"
    printf 'RESTIC_PASSWORD_FILE=/probe/pass\n'
} > "$d/env" || fail "could not write the probe environment"
chmod 600 "$d/env" || fail "could not restrict the probe environment"

# --hostname, and it is not cosmetic: restic groups snapshots by host before
# applying a retention policy, and `docker run` gives every container a random
# one. Without this each probe snapshot is a group of its own, `keep N daily`
# keeps one from each, and the probe repository grows by a snapshot per init run
# that `server backup-prune` can never collapse (seen on the rig).
#
# `timeout` around the docker client, not inside the container: an attached
# `docker run` proxies signals to the process it started, so the TERM the bound
# delivers reaches restic and --rm then cleans up. Without it, an endpoint that
# accepts a connection and answers nothing leaves `server init` waiting with
# nothing printed — this is the first remote step in kasbah that dials a third
# party, and every other one talks to the server itself.
r() { timeout -k 10 "$timeout_s" \
          docker run --rm --hostname kasbah-probe --env-file "$d/env" \
          -v "$d:/probe:ro" -v "$d/src:/probe-src:ro" "$image" --no-cache "$@"; }
# The snapshot ids restic listed, counted and named without jq: the far side has
# none, and `restic list snapshots` is one id per line precisely so it does not
# need one.
PROBE_COUNT=0
PROBE_FIRST=""
scan() {
    local l
    PROBE_COUNT=0
    PROBE_FIRST=""
    while IFS= read -r l; do
        l=${l%$'\r'}
        case $l in
            [0-9a-f][0-9a-f]*)
                PROBE_COUNT=$((PROBE_COUNT + 1))
                [ -n "$PROBE_FIRST" ] || PROBE_FIRST="$l"
                ;;
        esac
    done <<EOF
$1
EOF
}
b64() { printf '%s' "$1" | openssl base64 -A; }

# The repository this run actually opened, taken from the same string the
# --env-file was built from. Reported so the summary names what was probed
# rather than what a flag said.
printf 'probe_repo=%s%s\n' "$base" "$repo"

log=""
out=$(r cat config 2>&1); rc=$?
log="$log$out
"
if [ "$rc" -ne 0 ]; then
    out=$(r init 2>&1); rc=$?
    log="$log$out
"
    if [ "$rc" -ne 0 ]; then
        printf 'probe_stage=reach\nprobe_mid=0\nprobe_after=0\nprobe_rc=%s\nprobe_when=-\n' "$rc"
        printf 'probe_log_b64=%s\n' "$(b64 "$log")"
        exit 0
    fi
fi

for _ in 1 2; do
    out=$(r backup --tag kasbah-probe /probe-src 2>&1); rc=$?
    log="$log$out
"
    if [ "$rc" -ne 0 ]; then
        printf 'probe_stage=write\nprobe_mid=0\nprobe_after=0\nprobe_rc=%s\nprobe_when=-\n' "$rc"
        printf 'probe_log_b64=%s\n' "$(b64 "$log")"
        exit 0
    fi
done

# Both listings are judged on their own exit status before their output is
# counted. "Listed zero" and "could not list" are the same number and opposite
# facts: reading the second as the first would refuse a credential that was
# fine, and send the operator to replace it.
out=$(r list snapshots 2>&1); lrc=$?
log="$log$out
"
if [ "$lrc" -ne 0 ]; then
    printf 'probe_stage=unlisted\nprobe_mid=0\nprobe_after=0\nprobe_rc=%s\nprobe_when=before\n' "$lrc"
    printf 'probe_log_b64=%s\n' "$(b64 "$log")"
    exit 0
fi
scan "$out"
mid=$PROBE_COUNT
victim=$PROBE_FIRST

out=$(r forget "$victim" --prune 2>&1); frc=$?
log="$log$out
"
out=$(r list snapshots 2>&1); lrc=$?
log="$log$out
"
if [ "$lrc" -ne 0 ]; then
    printf 'probe_stage=unlisted\nprobe_mid=%s\nprobe_after=0\nprobe_rc=%s\nprobe_when=after\n' "$mid" "$lrc"
    printf 'probe_log_b64=%s\n' "$(b64 "$log")"
    exit 0
fi
scan "$out"
after=$PROBE_COUNT

printf 'probe_stage=deleted\nprobe_mid=%s\nprobe_after=%s\nprobe_rc=%s\nprobe_when=-\n' "$mid" "$after" "$frc"
printf 'probe_log_b64=%s\n' "$(b64 "$log")"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not run the backup credential probe on $target (the remote step exited $rc, see above)"

    _bk_absorb "the backup credential probe on $target" "$out" \
        probe_repo probe_stage probe_mid probe_after probe_rc probe_when probe_log_b64
    # The URL the probe opened, from the string its own --env-file was built
    # from — not from the flag, which is what made a bypass reportable as a pass.
    probed="$(_bk_shown "${_BK_FACT[probe_repo]}")"
    [ "${_BK_FACT[probe_repo]}" = "$_BK_REPO_BASE$KASBAH_BACKUP_PROBE_REPO" ] \
        || die "internal: the credential probe on $target opened $probed, and this run configured $(_bk_shown "$_BK_REPO_BASE$KASBAH_BACKUP_PROBE_REPO") — what was tested and what will be written are not the same repository"
    detail=$( { printf '%s' "${_BK_FACT[probe_log_b64]}" | base64 -d 2>/dev/null; printf x; } )
    detail="${detail%x}"

    case "${_BK_FACT[probe_stage]}" in
        reach)
            err "the backup credentials on $target cannot reach $probed"
            err_cont "restic could neither open nor create the probe repository, so nothing about"
            err_cont "this credential has been established."
            err_cont "The repository base is --backup-repo-base=; anything restic needs besides"
            err_cont "it — an S3 key pair, for instance — is --backup-env=KEY=VALUE, and lands in"
            err_cont "$apps/.kasbah/backup/env, which you can also edit there directly."
            err_cont "An address that accepts a connection and then answers nothing looks the same"
            err_cont "from here as a wrong one: each restic call was given ${_BK_TIMEOUT}s (--backup-timeout=)."
            _bk_probe_stack_note "$apps"
            while IFS= read -r line; do err_cont "| $line"; done <<<"$detail"
            exit 1
            ;;
        write)
            err "the backup credentials on $target cannot write to $probed"
            err_cont "the repository opened and the snapshot did not go in, so this credential"
            err_cont "cannot take a backup at all."
            _bk_probe_stack_note "$apps"
            while IFS= read -r line; do err_cont "| $line"; done <<<"$detail"
            exit 1
            ;;
        unlisted)
            err "the backup credentials on $target could not list $probed"
            err_cont "restic reached the repository and then failed to read its snapshots back"
            err_cont "(${_BK_FACT[probe_when]} the delete attempt), so whether this credential can delete its own"
            err_cont "history is unknown — and unknown is not a state a backup stack may start in."
            err_cont "A timeout is the likeliest cause: the bound on one restic call is"
            err_cont "--backup-timeout=, currently ${_BK_TIMEOUT}s."
            _bk_probe_stack_note "$apps"
            while IFS= read -r line; do err_cont "| $line"; done <<<"$detail"
            exit 1
            ;;
        deleted) ;;
        *) die "the backup credential probe on $target reported probe_stage='${_BK_FACT[probe_stage]}', which this kasbah does not know" ;;
    esac

    [ "${_BK_FACT[probe_mid]}" -ge 2 ] \
        || die "internal: the credential probe wrote two snapshots and counted ${_BK_FACT[probe_mid]} — forgetting the only snapshot in a repository is the case restic refuses on its own argument check, so the delete it then attempted would have proved nothing"

    if [ "${_BK_FACT[probe_after]}" -lt "${_BK_FACT[probe_mid]}" ]; then
        err "the backup credentials on $target can DELETE snapshots — refusing to install backups"
        err_cont "the probe wrote ${_BK_FACT[probe_mid]} snapshots to $probed, asked restic to forget"
        err_cont "one of them by name, and ${_BK_FACT[probe_after]} were left. A VPS that can delete its own history is"
        err_cont "a VPS whose history a compromise destroys, which is the whole point of the"
        err_cont "credential split (docs/backup.md → Credentials)."
        err_cont "Give this server an append-only key — write and list, no delete, no overwrite —"
        err_cont "and keep the full-access one on your own machine, where"
        err_cont "\`kasbah server backup-prune\` uses it."
        err_cont "The credentials are already at $apps/.kasbah/backup/env; edit them there, or"
        err_cont "re-run with --backup-repo-base= / --backup-env=."
        _bk_probe_stack_note "$apps"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$detail"
        exit 1
    fi

    _BK_FACT[probe]=append-only
    return 0
}

# --- The stack --------------------------------------------------------------------

# The two kasbah-owned files, shipped only when their bytes differ — the same
# rule the Traefik and mail stacks follow. A changed runner sets the restart
# flag: it is bind-mounted and read by the `sh` that is already running it, so
# compose sees no change in the service definition and would leave the container
# reading the old script.
_bk_sync() {
    local target="$1" apps="$2" rel rendered dest
    local changed=()

    [ "$_BK_ENABLED" = yes ] || return 0

    _BK_FACT[restart]=no
    for rel in "${_BK_FILES[@]}"; do
        rendered="$(cat "$_BK_TMPDIR/$rel"; printf x)" || die "could not read $_BK_TMPDIR/$rel"
        rendered="${rendered%x}"
        [ "$rendered" != "${_BK_CURRENT[$rel]}" ] || continue
        changed+=("$rel")
        [ "$rel" != backup.sh ] || _BK_FACT[restart]=yes
    done

    _BK_CHANGED=(${changed[@]+"${changed[@]}"})
    [ "${#changed[@]}" -gt 0 ] || return 0

    for rel in "${changed[@]}"; do
        dest="$apps/.kasbah/backup/$rel"
        case $rel in
            backup.sh) ssh_rsync -pt --chmod=F755 -s "$_BK_TMPDIR/$rel" "$SSH_TARGET:$dest" >/dev/null ;;
            *)         ssh_rsync -pt --chmod=F644 -s "$_BK_TMPDIR/$rel" "$SSH_TARGET:$dest" >/dev/null ;;
        esac || die "could not ship the backup $rel to $target:$dest"
    done
    return 0
}

# Starts the stack and reports what it became. There is no health wait: the
# container's whole job is to sleep until the slot, so "running" is the only
# state there is to see and a healthcheck would have nothing to ask.
_bk_start() {
    local target="$1" apps="$2" out rc=0

    [ "$_BK_ENABLED" = yes ] || return 0

    out=$(ssh_script "$apps" "$KASBAH_BACKUP_PROJECT" "$KASBAH_BACKUP_CONTAINER" \
                     "${_BK_FACT[restart]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
project=$2
container=$3
restart=$4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

cd "$apps/.kasbah/backup" || fail "could not enter $apps/.kasbah/backup"

# -p on every call, for the reason templates/backup/compose.yml gives: `name:`
# in the file is the weakest source of the project name and COMPOSE_PROJECT_NAME
# in this login shell outranks it.
dc() { docker compose -p "$project" "$@"; }

started_at() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || printf ''; }

before=""
cid=$(dc ps -a -q backup 2>/dev/null) || cid=""
[ -z "$cid" ] || before=$(started_at "$cid")

dc up -d || fail "docker compose -p $project up -d failed in $apps/.kasbah/backup"

cid=$(dc ps -a -q backup 2>/dev/null) || cid=""
[ -n "$cid" ] || fail "compose reported no backup container after up -d"

# The runner is bind-mounted, so a new one does not change the service
# definition and `up -d` leaves the container alone — but the shell inside it
# has the old script open. Skipped when this same `up -d` created or recreated
# the container, which read the new file on its way up.
mid=$(started_at "$cid")
if [ "$restart" = yes ] && [ -n "$before" ] && [ "$before" = "$mid" ]; then
    dc restart backup || fail "docker compose -p $project restart backup failed"
fi

printf 'backup_state=%s\n' "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
printf 'backup_restarts=%s\n' "$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)"
printf 'backup_image=%s\n' "$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null) || name=""
printf 'backup_container=%s\n' "${name#/}"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not start the backup stack on $target (the remote step exited $rc, see above)"

    _bk_absorb "the backup start on $target" "$out" \
        backup_state backup_restarts backup_image backup_container
    return 0
}

# What the run ended up with, and the two things an operator has to know that no
# other line says: which repositories the server can still not write, and that a
# project with no client record is filing under its own name.
_bk_report() {
    local target="$1" apps="$2" shipped="nothing re-rendered" repo missing=""

    if [ "$_BK_ENABLED" != yes ]; then
        return 0
    fi

    [ "${#_BK_CHANGED[@]}" -eq 0 ] || shipped="shipped ${_BK_CHANGED[*]}"
    info "  backup: $apps/.kasbah/backup ($shipped, env ${_BK_FACT[env_state]})"
    info "          repo base $(_bk_shown "$_BK_REPO_BASE") ($_BK_REPO_BASE_ORIGIN), daily at $_BK_AT plus ${_BK_JITTER}s jitter, ${_BK_TIMEOUT}s per restic call"
    case $_BK_ENV_ORIGIN in
        none) info "          restic environment: none, as stated" ;;
        flag) info "          restic environment: the keys named on this command line, merged into $apps/.kasbah/backup/env" ;;
        *)    info "          restic environment: whatever $apps/.kasbah/backup/env holds — kasbah copies it through untouched" ;;
    esac
    info "          retention $_BK_KEEP_DAILY daily / $_BK_KEEP_WEEKLY weekly / $_BK_KEEP_MONTHLY monthly, applied by \`kasbah server backup-prune $target\`"
    info "          credentials: ${_BK_FACT[probe]} (probed against $(_bk_shown "${_BK_FACT[probe_repo]}"))"
    info "          ${_BK_FACT[backup_container]} ${_BK_FACT[backup_state]} (${_BK_FACT[backup_restarts]} restarts, ${_BK_FACT[backup_image]})"
    info "          back up now: ssh $target 'docker exec $KASBAH_BACKUP_CONTAINER sh $apps/.kasbah/backup/backup.sh once'"
    info "          last run:     $apps/.kasbah/backup/state/status (what the healthcheck reads)"

    for repo in ${_BK_REPOS[@]+"${_BK_REPOS[@]}"}; do
        case " ${_BK_FACT[backup_haspass]} " in *" $repo "*) continue ;; esac
        [ -z "${_BK_PASS[$repo]+set}" ] || continue
        missing="$missing $repo"
    done
    if [ -n "$missing" ]; then
        warn "no restic password for:$missing — those repositories are NOT backed up"
        warn "re-run init with --with-backup to be asked, or --backup-password=<repo>=<password>"
    fi
    if [ "${#_BK_PROJECT_FALLBACKS[@]}" -gt 0 ]; then
        warn "no client record for: ${_BK_PROJECT_FALLBACKS[*]} — each is filed under its own name"
        warn "that is what \`client:\` defaults to, and \`kasbah deploy\` writes the record — so a"
        warn "project deployed by an older kasbah, or one whose manifest names a different"
        warn "client, is in the wrong repository until it is deployed again"
    fi
    return 0
}

# A backup flag on a run that is not installing backups. A warning rather than a
# refusal, for the reason a spare --reset-acme is one: a fleet script sets the
# repository base once and meets servers the operator chose not to back up.
_bk_flags_unused() {
    local named=()
    [ "$_BK_ENABLED" != yes ] || return 0
    [ -z "$_BK_REPO_BASE" ]   || named+=(--backup-repo-base=)
    [ -z "$_BK_AT" ]          || named+=(--backup-at=)
    [ -z "$_BK_JITTER" ]      || named+=(--backup-jitter=)
    [ -z "$_BK_KEEP_DAILY" ]  || named+=(--backup-keep-daily=)
    [ -z "$_BK_KEEP_WEEKLY" ] || named+=(--backup-keep-weekly=)
    [ -z "$_BK_KEEP_MONTHLY" ] || named+=(--backup-keep-monthly=)
    [ "${#_BK_ENV_GIVEN[@]}" -eq 0 ]  || named+=(--backup-env=)
    [ "${#_BK_PASS_GIVEN[@]}" -eq 0 ] || named+=(--backup-password=)
    [ -z "$_BK_ENV_NONE" ]    || named+=(--no-backup-env)
    [ "${#named[@]}" -gt 0 ] || return 0
    warn "${named[*]} had no effect: this run is not installing backups"
    return 0
}

# `--no-backup` against a server that already has the stack. Init scaffolds
# backups and never removes them, exactly as it treats mail, and saying so is
# the difference between a re-run that left them alone and a re-run that was
# believed to have taken them away.
_bk_note_left_alone() {
    local target="$1" apps="$2" marker="$3"
    [ "$_BK_ENABLED" != yes ] || return 0
    [ -n "$marker" ] || return 0
    [ "$(jq -r '.backup.enabled // false | tostring' <<<"$marker" 2>/dev/null)" = true ] || return 0
    warn "$target already has a backup stack at $apps/.kasbah/backup and this run is not"
    warn "touching it: init scaffolds backups, it never removes them. To take it down:"
    warn "  ssh $target 'cd $apps/.kasbah/backup && docker compose -p $KASBAH_BACKUP_PROJECT down'"
    return 0
}

# --- server backup-prune ----------------------------------------------------------

# Retention, applied with the **full-access** credential, from the operator's own
# machine (docs/phases/08-keep.md D13). The VPS's credential cannot delete — that
# is the whole design — so something has to, and it is not the VPS: shipping a
# key that can destroy the history to the box the threat model assumes is
# compromised would undo the split it exists to make.
#
# USER@HOST is therefore for **discovery**, not for execution. What comes off the
# server is which repositories exist and their encryption passwords, which the
# server must hold anyway to write to them; what stays here is the credential
# that reaches the storage. restic runs in a container on this machine, the same
# pin the VPS runs (D1).
#
# It can forget and prune inside a repository and it cannot remove one:
# rest-server answers 405 to a DELETE on a repository path, and an S3 prefix is
# not a thing restic deletes either. An empty repository is the end state.

_BP_TARGET=""
_BP_REPO_BASE=""
_BP_ENV_GIVEN=()
_BP_ENV_NONE=""
_BP_ONLY=()
_BP_KEEP_DAILY=""
_BP_KEEP_WEEKLY=""
_BP_KEEP_MONTHLY=""
_BP_DRY_RUN=""
_BP_YES=""
_BP_NETWORK=""
_BP_TMPDIR=""
_BP_REPOS=()

_bp_usage() {
    cat <<EOF
Usage: kasbah server backup-prune USER@HOST [flags]

Applies the retention policy to this server's restic repositories, with the
full-access credentials — which stay on this machine. USER@HOST says which
repositories exist and hands over their encryption passwords; restic itself
runs here, in a container, and talks to the storage directly.

Prints what would be removed and asks once before removing anything.

Flags:
  --repo-base=<url>      the repository base to prune against. Defaults to the
                         one in the server marker, which for a target whose
                         credential lives in the URL is the VPS's append-only
                         one — pass the full-access spelling here.
  --env=KEY=VALUE        environment for restic; repeatable. This is where an
                         S3 full-access key pair goes.
  --no-env               state that restic needs no environment for this target
  --repo=<name>          prune only this repository; repeatable. Default: every
                         repository the server has a password for, plus
                         $KASBAH_BACKUP_PROBE_REPO.
  --keep-daily=N         retention. Each defaults to the server marker's, which
  --keep-weekly=N        \`server init --with-backup\` recorded.
  --keep-monthly=N
  --dry-run              print the plan and stop, asking nothing
  --yes                  answer the confirmation, for scripts
  --docker-network=<net> run restic on this Docker network. The default is
                         docker's own, which reaches the internet and so reaches
                         object storage; pass this when the repository is only
                         reachable from a particular network on this machine —
                         a MinIO beside it, a VPN sidecar, a test rig.

Repositories are never removed, only emptied: there is no way to delete one
over the wire (docs/backup.md → Handover).
EOF
}

_bp_parse_args() {
    # Every checker below is shared with `server init`, and each one names the
    # command and the flag it was given rather than init's spelling of either.
    _BK_CMD="server backup-prune"
    _BP_TARGET=""
    _BP_REPO_BASE=""
    _BP_ENV_GIVEN=()
    _BP_ENV_NONE=""
    _BP_ONLY=()
    _BP_KEEP_DAILY=""
    _BP_KEEP_WEEKLY=""
    _BP_KEEP_MONTHLY=""
    _BP_DRY_RUN=""
    _BP_YES=""
    _BP_NETWORK=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --repo-base=*) _BP_REPO_BASE="${1#*=}"; _BP_REPO_BASE="${_BP_REPO_BASE%$'\r'}"
                           # Checked here rather than after the connection: a
                           # typo in the one flag that decides where deletions
                           # land should cost no round trip.
                           _bk_check_repo_base --repo-base= "$_BP_REPO_BASE" ;;
            # Validated, never echoed: the value carries a credential, and an
            # error message is the one place it would end up on a terminal.
            --env=*)       _bk_check_env_entry --env= "${1#*=}"; _BP_ENV_GIVEN+=("${1#*=}") ;;
            --no-env)      _BP_ENV_NONE=yes ;;
            --repo=*)      _bk_check_repo_name --repo= "${1#*=}"; _BP_ONLY+=("${1#*=}") ;;
            --keep-daily=*)   _BP_KEEP_DAILY="${1#*=}";   _bk_check_keep --keep-daily= "$_BP_KEEP_DAILY" ;;
            --keep-weekly=*)  _BP_KEEP_WEEKLY="${1#*=}";  _bk_check_keep --keep-weekly= "$_BP_KEEP_WEEKLY" ;;
            --keep-monthly=*) _BP_KEEP_MONTHLY="${1#*=}"; _bk_check_keep --keep-monthly= "$_BP_KEEP_MONTHLY" ;;
            --dry-run)     _BP_DRY_RUN=yes ;;
            --yes)         _BP_YES=yes ;;
            --docker-network=*)
                           _BP_NETWORK="${1#*=}"; _BP_NETWORK="${_BP_NETWORK%$'\r'}"
                           [[ "$_BP_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
                               || die "server backup-prune: --docker-network=$_BP_NETWORK is not a docker network name" ;;
            -h|--help)     _bp_usage; exit 0 ;;
            -*)            die "server backup-prune: unknown flag '${1%%=*}' (expected --repo-base=, --env=/--no-env, --repo=, --keep-daily=, --keep-weekly=, --keep-monthly=, --docker-network=, --dry-run, --yes)" ;;
            *)
                [ -z "$_BP_TARGET" ] \
                    || die "server backup-prune: unexpected argument '$1' (USER@HOST is given once)"
                _BP_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_BP_TARGET" ] \
        || die "server backup-prune: USER@HOST is required (it is what says which repositories this server has)"
    return 0
}

# The repositories, and the passwords that decrypt them. The passwords live on
# the server because the server must hold them to write at all, so fetching them
# is not a widening of anything; the *credential* that reaches the storage is
# what never goes the other way.
_bp_discover() {
    local apps="$1" out rc=0 line name enc

    out=$(ssh_script "$apps" "$KASBAH_BACKUP_PROBE_REPO" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/.kasbah/backup/repos"
probe=$2

[ -d "$dir" ] || { printf 'repos=\n'; exit 0; }

names=""
for f in "$dir"/*.pass; do
    [ -f "$f" ] || continue
    b=${f##*/}
    n=${b%.pass}
    names="$names $n"
    printf 'pass_%s=%s\n' "$n" "$(openssl base64 -A -in "$f" 2>/dev/null)"
done
printf 'repos=%s\n' "${names# }"
# The probe repository has no password file: its password is a kasbah constant,
# and it is named here only so the caller knows the repository is there to prune.
printf 'probe=%s\n' "$probe"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read $apps/.kasbah/backup/repos on $_BP_TARGET (the remote step exited $rc, see above)"
    _bk_absorb "the backup repository read on $_BP_TARGET" "$out" repos
    return 0
}

# One directory this process owns, holding one password file per repository and
# one env file per repository. Nothing here reaches a command line: `docker run
# --env-file` and a mounted password file are what keep the repository URL and
# the password out of the process table.
_bp_stage() {
    local repo pass enc entry

    _BP_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-backup-prune.XXXXXX")" \
        || die "could not create a temp directory for the prune credentials"
    chmod 700 "$_BP_TMPDIR" || die "could not restrict $_BP_TMPDIR"
    mkdir -p "$_BP_TMPDIR/pw" "$_BP_TMPDIR/env" || die "could not create $_BP_TMPDIR/pw"
    chmod 700 "$_BP_TMPDIR/pw" "$_BP_TMPDIR/env" || die "could not restrict $_BP_TMPDIR/pw"

    for repo in "${_BP_REPOS[@]}"; do
        if [ "$repo" = "$KASBAH_BACKUP_PROBE_REPO" ]; then
            pass="$KASBAH_BACKUP_PROBE_PASSWORD"
        else
            enc="${_BK_FACT[pass_$repo]:-}"
            [ -n "$enc" ] \
                || die "internal: $_BP_TARGET listed the '$repo' repository and sent no password for it"
            pass=$( { printf '%s' "$enc" | base64 -d 2>/dev/null; printf x; } )
            pass="${pass%x}"
            pass="${pass%$'\n'}"
        fi
        printf '%s\n' "$pass" > "$_BP_TMPDIR/pw/$repo.pass" \
            || die "could not stage the password for $repo"
        chmod 600 "$_BP_TMPDIR/pw/$repo.pass" || die "could not restrict the password for $repo"
        # The operator's entries first and kasbah's last, because
        # `docker --env-file` is last-wins: the two keys that decide which
        # repository is opened and what opens it are kasbah's, and writing them
        # last is what makes that true of the file rather than of a check.
        # Written one at a time, so an empty list contributes no line at all —
        # `printf '%s\n' "${arr[@]}"` on an empty array emits a bare newline.
        {
            for entry in ${_BP_ENV_GIVEN[@]+"${_BP_ENV_GIVEN[@]}"}; do
                printf '%s\n' "$entry"
            done
            printf 'RESTIC_REPOSITORY=%s%s\n' "$_BP_REPO_BASE" "$repo"
            printf 'RESTIC_PASSWORD_FILE=/pw/%s.pass\n' "$repo"
        } > "$_BP_TMPDIR/env/$repo.env" || die "could not stage the environment for $repo"
        chmod 600 "$_BP_TMPDIR/env/$repo.env" || die "could not restrict the environment for $repo"
    done
    return 0
}

_bp_cleanup() {
    [ -n "$_BP_TMPDIR" ] || return 0
    rm -rf "$_BP_TMPDIR"
    _BP_TMPDIR=""
    return 0
}

# restic, here, against one repository. --no-cache because this machine is not
# the one that takes the backups and a cache of somebody else's repository is
# not something a prune should leave behind.
_bp_restic() {
    local repo="$1"; shift
    local net=()
    [ -z "$_BP_NETWORK" ] || net=(--network "$_BP_NETWORK")
    docker run --rm \
        ${net[@]+"${net[@]}"} \
        --env-file "$_BP_TMPDIR/env/$repo.env" \
        -v "$_BP_TMPDIR/pw:/pw:ro" \
        "$KASBAH_RESTIC_IMAGE" --no-cache "$@" 2>&1
}

cmd_server_backup_prune() {
    local repo out rc=0 apps enabled line planned=0

    _bp_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    command -v docker >/dev/null \
        || die "docker is required: kasbah installs no packages, so restic runs as a container here exactly as it does on the VPS (docs/phases/08-keep.md D1)"

    trap '_bp_cleanup' EXIT
    ssh_connect "$_BP_TARGET"
    marker_read "$_BP_TARGET"
    apps="$MARKER_APPS_PATH"

    enabled="$(jq -r '.backup.enabled // false | tostring' <<<"$MARKER_JSON" 2>/dev/null)" || enabled=false
    if [ "$enabled" != true ]; then
        err "$_BP_TARGET has no backups: $MARKER_PATH says backup.enabled is $enabled"
        err_cont "there is nothing to prune. Install them with:"
        err_cont "  kasbah server init $_BP_TARGET --with-backup"
        exit 1
    fi

    if [ -z "$_BP_REPO_BASE" ]; then
        _BP_REPO_BASE="$(jq -r '.backup.repo_base // "" | tostring' <<<"$MARKER_JSON")"
        [ -n "$_BP_REPO_BASE" ] \
            || die "$MARKER_PATH on $_BP_TARGET records no backup.repo_base — pass --repo-base= to say which storage to prune"
        warn "using the repository base the server records: $(_bk_shown "$_BP_REPO_BASE")"
        warn "that is the base the VPS writes with. Where the credential is in the URL, the"
        warn "full-access spelling is a different one — pass it with --repo-base=."
    fi
    # The flag's value was checked at parse time; this one is the marker's, whose
    # spelling is the server's and not this command line's — so the message says
    # where the value came from rather than naming a flag nobody passed.
    _bk_check_repo_base "the backup.repo_base recorded on $_BP_TARGET, " "$_BP_REPO_BASE"

    [ -n "$_BP_KEEP_DAILY" ]   || _BP_KEEP_DAILY="$(jq -r '.backup.retention.daily // "" | tostring' <<<"$MARKER_JSON")"
    [ -n "$_BP_KEEP_WEEKLY" ]  || _BP_KEEP_WEEKLY="$(jq -r '.backup.retention.weekly // "" | tostring' <<<"$MARKER_JSON")"
    [ -n "$_BP_KEEP_MONTHLY" ] || _BP_KEEP_MONTHLY="$(jq -r '.backup.retention.monthly // "" | tostring' <<<"$MARKER_JSON")"
    [ -n "$_BP_KEEP_DAILY" ]   || _BP_KEEP_DAILY="$KASBAH_BACKUP_KEEP_DAILY_DEFAULT"
    [ -n "$_BP_KEEP_WEEKLY" ]  || _BP_KEEP_WEEKLY="$KASBAH_BACKUP_KEEP_WEEKLY_DEFAULT"
    [ -n "$_BP_KEEP_MONTHLY" ] || _BP_KEEP_MONTHLY="$KASBAH_BACKUP_KEEP_MONTHLY_DEFAULT"
    _bk_check_keep --keep-daily=   "$_BP_KEEP_DAILY"
    _bk_check_keep --keep-weekly=  "$_BP_KEEP_WEEKLY"
    _bk_check_keep --keep-monthly= "$_BP_KEEP_MONTHLY"

    if [ "${#_BP_ENV_GIVEN[@]}" -eq 0 ] && [ -z "$_BP_ENV_NONE" ]; then
        local name="" pass=""
        if prompt_choice 'env=KEY=VALUE' no-env \
            "Does restic need environment variables to reach $(_bk_shown "$_BP_REPO_BASE") with full access (an S3 key pair, for example)?" \
            ""; then
            while :; do
                prompt_value env "Variable name, or 'done' to finish" "" name done
                [ "$name" != done ] || break
                prompt_secret env "Value for $name (not echoed)" "" pass
                _bk_check_env_entry --env= "$name=$pass"
                _BP_ENV_GIVEN+=("$name=$pass")
            done
        fi
    fi

    _bp_discover "$apps"
    _BP_REPOS=()
    for repo in ${_BK_FACT[repos]}; do _BP_REPOS+=("$repo"); done
    _BP_REPOS+=("$KASBAH_BACKUP_PROBE_REPO")
    if [ "${#_BP_ONLY[@]}" -gt 0 ]; then
        local kept=()
        for repo in "${_BP_ONLY[@]}"; do
            case " ${_BP_REPOS[*]} " in
                *" $repo "*) kept+=("$repo") ;;
                *) die "server backup-prune: $_BP_TARGET has no '$repo' repository (it has: ${_BP_REPOS[*]})" ;;
            esac
        done
        _BP_REPOS=("${kept[@]}")
    fi
    [ "${#_BP_REPOS[@]}" -gt 0 ] \
        || die "server backup-prune: $_BP_TARGET has no repositories to prune"

    _bp_stage
    ssh_disconnect

    info "Retention on $_BP_TARGET: keep $_BP_KEEP_DAILY daily, $_BP_KEEP_WEEKLY weekly, $_BP_KEEP_MONTHLY monthly"
    info "  base: $(_bk_shown "$_BP_REPO_BASE")   restic: $KASBAH_RESTIC_IMAGE, run here and not on the VPS${_BP_NETWORK:+, on the $_BP_NETWORK network}"
    for repo in "${_BP_REPOS[@]}"; do
        info "  $repo — what would be removed:"
        out=$(_bp_restic "$repo" forget --dry-run \
                --keep-daily "$_BP_KEEP_DAILY" --keep-weekly "$_BP_KEEP_WEEKLY" \
                --keep-monthly "$_BP_KEEP_MONTHLY") || rc=$?
        while IFS= read -r line; do info "    $line"; done <<<"$out"
        if [ "$rc" -ne 0 ]; then
            warn "  $repo — restic exited $rc above; this repository is skipped"
            rc=0
            continue
        fi
        planned=$((planned + 1))
    done

    [ "$planned" -gt 0 ] \
        || die "server backup-prune: no repository could be read with these credentials — nothing was changed"

    if [ -n "$_BP_DRY_RUN" ]; then
        info "--dry-run: nothing was removed"
        return 0
    fi

    if ! prompt_confirm yes \
        "Apply this retention to $_BP_TARGET's repositories? Snapshots outside it are removed permanently." \
        "$_BP_YES"; then
        err "server backup-prune: declined — nothing was removed"
        exit 1
    fi

    local failed=0
    for repo in "${_BP_REPOS[@]}"; do
        info "  $repo — forgetting and pruning:"
        out=$(_bp_restic "$repo" forget --prune \
                --keep-daily "$_BP_KEEP_DAILY" --keep-weekly "$_BP_KEEP_WEEKLY" \
                --keep-monthly "$_BP_KEEP_MONTHLY") || rc=$?
        while IFS= read -r line; do info "    $line"; done <<<"$out"
        if [ "$rc" -ne 0 ]; then
            err "  $repo — restic exited $rc"
            failed=$((failed + 1))
            rc=0
        fi
    done

    [ "$failed" -eq 0 ] \
        || die "server backup-prune: $failed of ${#_BP_REPOS[@]} repositories were not pruned (see above)"
    info "Pruned ${#_BP_REPOS[@]} repositories on $_BP_TARGET"
    info "  the repositories themselves stay: there is no way to remove one over the wire"
    return 0
}
