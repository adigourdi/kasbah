# kasbah — drop: remove one project's footprint from a VPS
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_DROP_LOADED:-}" ] && return 0
_KASBAH_DROP_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
# For _prune_project_repos alone: "which image repositories does this project
# build?" is `server prune`'s question over every project on a server, and this
# command's over one. Two implementations of it are two answers to the question
# that decides a deletion (docs/phases/07-operate.md → the phase close).
. "$KASBAH_LIB_DIR/prune.sh"
# lib/server_mail.sh is **not** sourced here: it pulls in lib/server_init.sh for
# the registry template, which is two thousand lines a drop of a project with no
# mail claim never touches — the same reason lib/deploy.sh is not sourced for
# _deploy_read_mail. _drop_mail_plan sources it at the one moment it is needed.

# `kasbah drop [USER@HOST] [--prune]` takes one project off a server
# (docs/cli.md → kasbah drop). Plain drop is the reversible verb: the route
# goes, the containers go, the project's own images go, and everything a later
# `kasbah deploy` needs to resurrect it — <apps>/<name>, <data>/<name>, the
# backups — stays. `--prune` deletes those too.
#
# Three round trips: the marker read every project command makes (lib/marker.sh),
# one batched read of everything the plan is decided from, and one act after the
# operator has answered. The marker is not folded into the read because the
# alternative is a fifth copy of `norm_path` on the far side of ssh —
# tests/norm_path_test.sh holds the four that exist byte-identical, and a copy it
# does not know about is drift nothing would catch.
#
# Nothing structured is parsed on the far side: compose.yml and the mail
# registry come back as bytes and meet the workstation's yq. The VPS keeps
# needing no yq, jq or python3 (docs/server-setup.md → prerequisites).
#
# **What it will not remove is the point.** A repository a second project also
# declares, and every repository on a server where some project's declared
# images cannot be read at all, are left alone — the ownership rule
# `lib/prune.sh` establishes, applied to one project. And `--prune` refuses
# outright when that leaves the image set unknown, because it is about to delete
# the compose.yml that is the only record of what this project built: after it,
# nobody can ever answer the question again.

_DROP_TARGET=""
_DROP_TARGET_SOURCE=""
# The flag as it would be typed again, for the messages that tell an operator to
# re-run this exact command. Empty on a plain drop.
_DROP_PRUNE_ARG=""
# "yes" when --prune was passed, "no" when it was not. A plain opt-in flag
# rather than a tri-state pair, for the reason deploy's --skip-hooks is one:
# unset has an obvious meaning that docs/cli.md states — the reversible drop.
_DROP_PRUNE=no
# "yes" when --yes was passed, empty when it was not. Empty means *ask*
# (docs/overview.md → Interactivity); it never means no.
_DROP_YES=""

_DROP_APPS_PATH=""
_DROP_DATA_PATH=""
# The manifest's mail claim, or empty when it has none (docs/project-manifest.md).
_DROP_MAIL_DOMAIN=""
# "yes" when a redeploy after this drop will need --allow-stopped. Read from the
# manifest rather than hedged in the message: it is decided by two fields, and a
# sentence that says "pass this flag if your manifest looks like X" makes the
# operator do the reading kasbah has already done.
_DROP_NEEDS_ALLOW_STOPPED=no

declare -A _DROP_FACT=()

# The image table, keyed by image id: every tag it carries, and the id behind
# each tag. A tag is `<repo>:<version>`; the id is what says whether removing one
# frees an image or only drops a name.
declare -A _DROP_ID_TAGS=()
declare -A _DROP_TAG_ID=()

# This project's own containers as compose labelled them, ready to print, and
# whether there were any: `docker compose -p <name> down` is a step worth
# skipping the whole confirmation over when there is nothing labelled.
_DROP_CONTAINERS=""
_DROP_CONTAINERS_SEEN=no

# The repositories this project builds, as a space-fenced word list (" a b "),
# whether that list could be established at all, and the state the probe
# reported this project's own compose.yml in — `ok` there with the list still
# unestablished means the file opened and yq refused it, which is a different
# thing to tell the operator.
_DROP_REPOS=" "
_DROP_REPOS_OK=no
_DROP_COMPOSE_STATE=absent
# The projects claiming each repository, and the ones whose declared images
# kasbah could not enumerate. While there is one of the latter, no repository on
# the server is provably single-owner and nothing is removed — lib/prune.sh's
# rule, and its reasoning.
declare -A _DROP_REPO_OWNER=()
_DROP_UNKNOWN_OWNER=()
# The unknown owners that are **not** this project. The distinction decides what
# --prune does: a record of this project's own that kasbah cannot read is one
# --prune would destroy, while a neighbour's is one it would not.
_DROP_UNKNOWN_OTHERS=()
# Tags of repositories that carry a `:current` and that no project kasbah could
# read declares. `:current` is kasbah's own pointer — `build-push` writes
# `<image>:<version>` and `deploy` moves `:current`, and nothing else on a
# kasbah server sets it — so a repository carrying one was built by some project
# here. Claimed by nobody readable, it is an image no record now attributes.
_DROP_ORPHAN=()

# The plan: the tags to remove, and the per-tag lines the report prints. The
# refs the act really removed — and the ones it could not, with docker's own
# reason — come back in these three.
_DROP_REMOVE=()
_DROP_REMOVED_REFS=()
_DROP_FAILED_REFS=()
_DROP_FAILED_WHY=()
_DROP_LINE_TAG=()
_DROP_LINE_VERDICT=()
_DROP_LINE_WHY=()

# The mail registry as it came back, and the re-rendered one that releases the
# claim. Empty when there is nothing to release.
_DROP_MAIL_REGISTRY=""
_DROP_MAIL_RENDERED=""
_DROP_MAIL_VERDICT=""
# The stack's primary_domain, kept here rather than read back out of
# lib/server_mail.sh's globals: that file is sourced only when a claim is in
# play, and the follow-up line naming it is printed long after.
_DROP_MAIL_PRIMARY=""
_DROP_TMPDIR=""

# The fixed names kasbah owns under the apps path, which are never projects —
# the same list `server status` and `server prune` walk past.
_DROP_RESERVED=(.kasbah "${KASBAH_RESERVED_NAMES[@]}")

_drop_usage() {
    cat <<EOF
Usage: kasbah drop [USER@HOST] [--prune] [--yes]

Removes this project from a server. Run from the project root. USER@HOST
defaults to the last server this project talked to (.kasbah/state.json).

Plain drop is reversible — a later \`kasbah deploy\` resurrects the project with
its data, once its images have been re-shipped with \`kasbah build-push\`:

  removed   the Traefik fragment, the containers (\`docker compose down\`), and
            every tag of the images this project builds
  kept      <apps>/<name>/ (compose.yml, .env, versions.log, scripts, backups),
            <data>/<name>/, and the project's mail-domain claim

  --prune   delete the kept things too: <apps>/<name>/ with the on-VPS backups
            inside it, <data>/<name>/, and the project's entry in the mail
            registry. The off-VPS restic repository is never touched — it is
            operator property (docs/backup.md).
  --yes     answer both confirmations, for scripts. Without it and without a
            terminal, drop stops rather than assuming.

Confirmation is double: a yes/no question, then the project name typed back.

An image repository a second project on the server also declares is left alone,
and so is every repository on a server where some project's compose.yml cannot
be read: a deletion is not decided on a partial reading of what is deployed.
EOF
}

# --- Command line -----------------------------------------------------------------

_drop_parse_args() {
    _DROP_TARGET=""
    _DROP_TARGET_SOURCE=""
    _DROP_PRUNE=no
    _DROP_PRUNE_ARG=""
    _DROP_YES=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)  _drop_usage; exit 0 ;;
            --prune)    _DROP_PRUNE=yes; _DROP_PRUNE_ARG=" --prune" ;;
            --yes)      _DROP_YES=yes ;;
            # `--prune=yes` is a flag this command has, spelled wrong. Refusing
            # it as unknown while listing it as known is a message arguing with
            # itself.
            --prune=*|--yes=*)
                die "drop: ${1%%=*} takes no value — pass it on its own (\`kasbah drop USER@HOST ${1%%=*}\`)" ;;
            -*) die "drop: unknown flag '${1%%=*}' (drop takes USER@HOST, --prune and --yes)" ;;
            *)
                [ -z "$_DROP_TARGET" ] \
                    || die "drop: two servers given ('$_DROP_TARGET' and '$1') — one run goes to one server"
                case "${1%$'\r'}" in
                    *@*) ;;
                    # There is no second positional to confuse it with, so a
                    # bare word is a mistyped target rather than something drop
                    # should try to classify.
                    *) die "drop: '${1%$'\r'}' is not a USER@HOST — drop takes the server and nothing else positionally" ;;
                esac
                _DROP_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done
    return 0
}

# The positional argument, else the server this project last talked to. With
# neither there is nothing to guess at (docs/project-manifest.md).
_drop_resolve_target() {
    local stored=""

    if [ -n "$_DROP_TARGET" ]; then
        _DROP_TARGET_SOURCE=argument
        return 0
    fi

    state_get last_server stored
    if [ -z "$stored" ] || [ "$stored" = null ]; then
        err "drop: no server given, and this project has never deployed to one"
        err_cont "pass it once — \`kasbah drop user@vps\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        exit 1
    fi
    _DROP_TARGET="$stored"
    _DROP_TARGET_SOURCE=state
    return 0
}

# --- The batched read ----------------------------------------------------------------

# Folds the report into the fact table and checks the key set as a protocol
# before any value is read: a truncated step must not be absorbed into a plan
# that ends in a deletion. Clipped to twenty lines of 120 bytes, because several
# of these values are base64 blobs that grow with the server.
_drop_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_shown=0
    local _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _DROP_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_DROP_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the drop probe on $_DROP_TARGET reported no ${_ac_missing[*]}"
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

# A positional field of the project table, where `-` means "this value is
# empty": the row is split on whitespace and a run of it collapses, so an empty
# field in the middle would shift every field after it left by one. `-` is not
# in the base64 alphabet.
_drop_b64_field() {
    local _bf_out="$2"
    if [ "$1" = - ]; then
        printf -v "$_bf_out" '%s' ""
        return 0
    fi
    _vlog_b64_decode "$1" "$_bf_out" || return 1
    return 0
}

_drop_collect() {
    local out rc=0

    out=$(ssh_script "$_DROP_APPS_PATH" "$_DROP_DATA_PATH" "$MANIFEST_NAME" \
                     "${_DROP_RESERVED[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
name=$3
reserved=" $4 "

# One line per value: the reader parses this output as a protocol, so a
# command's multi-line complaint would arrive as extra keys. Anything that can
# carry a newline or a space of its own — a project name, a whole file — is
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

# The same seven words `server status`, `server prune` and lib/versions_log.sh
# report a file in. Two commands describing one server two ways is what the
# shared spelling exists to prevent.
state_of() {
    if [ -e "$1" ] && [ ! -f "$1" ]; then printf notfile;    return 0; fi
    if [ ! -f "$1" ]; then                printf missing;    return 0; fi
    if [ ! -r "$1" ]; then                printf unreadable; return 0; fi
    if [ ! -s "$1" ]; then                printf empty;      return 0; fi
    printf ok
}
read_file() {
    STATE=$(state_of "$1")
    DATA=""
    if [ "$STATE" = ok ]; then
        if ! DATA=$(openssl base64 -A -in "$1" 2>/dev/null) || [ -z "$DATA" ]; then
            STATE=unreadable
            DATA=""
        fi
    fi
}
dir_state() {
    if [ -d "$1" ]; then
        if [ -r "$1" ] && [ -x "$1" ]; then printf dir; else printf noaccess; fi
    elif [ -e "$1" ]; then printf notdir
    else printf absent
    fi
}

if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_error ""
else
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi

kv apps_state "$(dir_state "$apps")"

dir="$apps/$name"
kv project_state "$(dir_state "$dir")"
kv data_state    "$(dir_state "$data/$name")"
kv backups_state "$(dir_state "$dir/backups")"

# How many hook-produced dumps --prune would take with the project directory.
# Counted rather than sized: `du` on a tree of database dumps is the one thing
# here that scales with the server.
count=0
if [ -d "$dir/backups" ] && [ -r "$dir/backups" ]; then
    for f in "$dir/backups"/*; do
        [ -e "$f" ] || continue
        count=$((count + 1))
    done
fi
kv backups_count "$count"

kv fragment_state "$(state_of "$apps/traefik/dynamic/$name.yml")"

# Whether a deploy of this project is running right now. `.deploy.lock` is
# created by templates/remote-deploy.sh and by nothing else, so a file that is
# not there is a project nothing holds — probed rather than created, because a
# read step must not write into the tree it is reading.
lock="$dir/.deploy.lock"
if ! command -v flock >/dev/null 2>&1; then
    kv lock_state noflock
elif [ ! -e "$lock" ]; then
    kv lock_state free
elif flock -n "$lock" true 2>/dev/null; then
    kv lock_state free
else
    kv lock_state held
fi

# This project's containers as compose labelled them, which needs no compose
# file and no .env. **Both** labels, because both are what `docker compose down`
# selects on: a container carrying only the project label — a `compose run`
# one-off, or anything hand-started with `--label` — survives `down` with a
# status of 0, so listing it here would put something in the confirmation that
# the act does not touch.
containers=""
if [ "$docker_rc" -eq 0 ]; then
    containers=$(docker ps -a --filter "label=com.docker.compose.project=$name" \
                     --filter "label=com.docker.compose.oneoff=False" \
                     --format '{{.Names}} {{.State}}' 2>/dev/null) || containers=""
fi
kv containers_b64 "$(printf '%s' "$containers" | b64)"

# Every image, with every tag it carries. The id is what says whether removing
# a tag frees the image or only drops one of its names.
images=""
if [ "$docker_rc" -eq 0 ]; then
    ids=$(docker images -q 2>/dev/null | sort -u) || ids=""
    if [ -n "$ids" ]; then
        images=$(docker image inspect \
                     --format '{{.Id}}{{range .RepoTags}} {{.}}{{end}}' \
                     $ids 2>/dev/null) || images=""
    fi
fi
kv images_b64 "$(printf '%s' "$images" | b64)"

# The mail registry, as bytes. Only --prune reads it, and only for a project
# that claims a domain — but it costs one file read and folding it in here is
# what keeps the claim in the confirmation summary (docs/phases/08-keep.md, D11).
kv mail_dir "$(dir_state "$apps/mail")"
read_file "$apps/mail/kasbah.yml"; kv mail_registry_state "$STATE"; kv mail_registry_b64 "${DATA:--}"

# One row per project: everything under the apps path that is not one of
# kasbah's own directories, with the compose.yml that says which images it
# builds. dotglob is on because `.kasbah` is skipped by name rather than by
# being hidden.
rows=""
count=0
if [ -d "$apps" ]; then
    shopt -s nullglob dotglob
    for path in "$apps"/*; do
        pname=${path##*/}
        case $reserved in *" $pname "*) continue ;; esac
        count=$((count + 1))
        dstate=$(dir_state "$path")
        cstate=missing; cdata=""
        case $dstate in
            dir) read_file "$path/compose.yml"; cstate=$STATE; cdata=$DATA ;;
            *)   cstate=$dstate ;;
        esac
        [ -n "$cdata" ] || cdata=-
        rows="$rows$(printf '%s %s %s %s' \
            "$(printf '%s' "$pname" | b64)" "$dstate" "$cstate" "$cdata")
"
    done
fi
kv project_count "$count"
kv projects_b64 "$(printf '%s' "$rows" | b64)"

exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the drop probe on $_DROP_TARGET exited $rc"
        err_cont "nothing was removed — drop reads the whole server before it deletes anything"
        exit 1
    fi

    _drop_absorb_checked "$out" \
        have_docker docker_error apps_state project_state data_state \
        backups_state backups_count fragment_state lock_state \
        containers_b64 images_b64 mail_dir mail_registry_state mail_registry_b64 \
        project_count projects_b64
    return 0
}

# Docker and the apps path, in that order: the first makes the second's question
# meaningless. The marker has already been read — lib/marker.sh reaches exit 4
# for "this is not a prepared server" before this probe runs at all.
_drop_check_server() {
    if [ "${_DROP_FACT[have_docker]}" != yes ] || [ -n "${_DROP_FACT[docker_error]}" ]; then
        err "docker did not answer on $_DROP_TARGET"
        [ -z "${_DROP_FACT[docker_error]}" ] || err_cont "${_DROP_FACT[docker_error]}"
        err_cont "drop has nothing to read and has removed nothing"
        exit 1
    fi
    case "${_DROP_FACT[apps_state]}" in
        dir) ;;
        notdir) die "$_DROP_APPS_PATH on $_DROP_TARGET is not a directory" ;;
        noaccess) die "$_DROP_APPS_PATH on $_DROP_TARGET cannot be entered by this user — drop reads every project there to decide which images are this one's alone" ;;
        *)
            err "$_DROP_APPS_PATH on $_DROP_TARGET is not there"
            err_cont "the server marker names it, so this server's layout and its tree disagree"
            err_cont "— nothing was removed"
            exit "$KASBAH_EXIT_NO_REMOTE_STATE"
            ;;
    esac

    # A deploy holding the lock is the one state where every step below would
    # interleave with somebody else's run: hooks against containers this drop is
    # about to take down, a `:current` retag against images it is about to
    # remove. Refused before the operator is asked, since the answer would be
    # about a plan that is already stale.
    case "${_DROP_FACT[lock_state]}" in
        free) ;;
        held)
            err "a deploy or rollback of $MANIFEST_NAME is running on $_DROP_TARGET"
            err_cont "it holds the lock on $_DROP_APPS_PATH/$MANIFEST_NAME/.deploy.lock, which drop takes"
            err_cont "for the same reason: nothing was changed. Wait for it and run drop again."
            exit 1
            ;;
        noflock)
            err "flock is not installed on $_DROP_TARGET"
            err_cont "it is the only thing keeping this drop from interleaving with a deploy's hooks"
            err_cont "and retags, so drop will not run without it. Install util-linux"
            err_cont "(docs/server-setup.md → prerequisites). Nothing was changed."
            exit 1
            ;;
        *) die "the drop probe on $_DROP_TARGET reported lock_state='${_DROP_FACT[lock_state]}', which this kasbah does not know" ;;
    esac
    return 0
}

_drop_decode_images() {
    local table row id tag rest

    _DROP_ID_TAGS=()
    _DROP_TAG_ID=()

    _drop_b64_field "${_DROP_FACT[images_b64]:--}" table \
        || die "the drop probe on $_DROP_TARGET sent an image table that is not base64"
    while IFS= read -r row; do
        row="${row%$'\r'}"
        [ -n "$row" ] || continue
        read -r id rest <<<"$row"
        [ -n "$id" ] \
            || die "the drop probe on $_DROP_TARGET returned an image row it did not build: '$row'"
        _DROP_ID_TAGS[$id]=" "
        for tag in $rest; do
            _DROP_ID_TAGS[$id]="${_DROP_ID_TAGS[$id]}$tag "
            # A tag names one image. Docker cannot hold the same tag twice, so a
            # repeat here is a truncated read, not a state.
            _DROP_TAG_ID[$tag]="$id"
        done
    done <<<"$table"
    return 0
}

_drop_decode_containers() {
    local list name state

    _DROP_CONTAINERS=""
    _DROP_CONTAINERS_SEEN=no

    _drop_b64_field "${_DROP_FACT[containers_b64]:--}" list \
        || die "the drop probe on $_DROP_TARGET sent a container list that is not base64"
    while IFS= read -r name; do
        name="${name%$'\r'}"
        [ -n "$name" ] || continue
        state="${name#* }"; name="${name%% *}"
        [ "$state" != "$name" ] || state=unknown
        _DROP_CONTAINERS+="${_DROP_CONTAINERS:+, }$name($state)"
        _DROP_CONTAINERS_SEEN=yes
    done <<<"$list"
    return 0
}

# Which repositories this project builds, and which of them a second project
# also claims. The walk covers every project on the server including this one,
# because a repository two projects declare is one no single project's compose
# file is evidence about.
#
# **A project whose compose.yml kasbah cannot read, or cannot parse, is not a
# project that claims nothing.** Reading it that way would defeat the guard with
# the very condition that should trigger it: the project vanishes from the
# ownership map, this project's repository looks single-owner, and a tag the
# unreadable project was holding is deleted. There is no way to narrow what it
# might have claimed — the file that would say is the file kasbah could not read
# — so while there is one, no repository on the server is provably single-owner.
_drop_ownership() {
    local table row name_b64 dstate cstate cdata rest
    local name compose repos repo described=0 data_dir=""

    # The bind-mount root is a directory under the apps path whenever
    # --data-path put it there, and it is not one of the fixed reserved names.
    # Counted as a project it would have no compose.yml, which would stop drop
    # removing anything anywhere — permanently, on every run. `server status`
    # and `server prune` drop the same row from the same fact.
    case "$_DROP_DATA_PATH" in
        "$_DROP_APPS_PATH"/?*)
            data_dir="${_DROP_DATA_PATH#"$_DROP_APPS_PATH"/}"
            case $data_dir in */*) data_dir="" ;; esac
            ;;
    esac

    _DROP_REPOS=" "
    _DROP_REPOS_OK=no
    _DROP_COMPOSE_STATE=absent
    _DROP_REPO_OWNER=()
    _DROP_UNKNOWN_OWNER=()
    _DROP_UNKNOWN_OTHERS=()

    _drop_b64_field "${_DROP_FACT[projects_b64]:--}" table \
        || die "the drop probe on $_DROP_TARGET sent a project table that is not base64"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read -r name_b64 dstate cstate cdata rest <<<"$row"
        if [ -z "$name_b64" ] || [ -z "$dstate" ] || [ -z "$cstate" ] \
           || [ -z "$cdata" ] || [ -n "$rest" ]; then
            err "the drop probe on $_DROP_TARGET returned a project row it did not build: '$row'"
            exit 1
        fi
        described=$((described + 1))
        _vlog_b64_decode "$name_b64" name \
            || die "the drop probe on $_DROP_TARGET sent a project name that is not base64: '$name_b64'"
        _drop_b64_field "$cdata" compose \
            || die "the drop probe on $_DROP_TARGET sent $name's compose.yml as something that is not base64"
        # After `described`, because the far side counted it too.
        if [ -n "$data_dir" ] && [ "$name" = "$data_dir" ]; then
            continue
        fi

        [ "$name" != "$MANIFEST_NAME" ] || _DROP_COMPOSE_STATE="$cstate"
        repos=" "
        if [ "$cstate" = ok ] && _prune_project_repos "$compose" repos; then
            [ "$name" != "$MANIFEST_NAME" ] || { _DROP_REPOS="$repos"; _DROP_REPOS_OK=yes; }
        else
            repos=" "
            _DROP_UNKNOWN_OWNER+=("$name")
            [ "$name" = "$MANIFEST_NAME" ] || _DROP_UNKNOWN_OTHERS+=("$name")
        fi
        for repo in $repos; do
            _DROP_REPO_OWNER[$repo]="${_DROP_REPO_OWNER[$repo]:- }$name "
        done
    done <<<"$table"

    # The count and the table are two statements about the same walk, so a
    # disagreement means one of them was truncated in transit.
    if [ "$described" != "${_DROP_FACT[project_count]}" ]; then
        err "the drop probe on $_DROP_TARGET counted ${_DROP_FACT[project_count]} projects and described $described"
        err_cont "the payload was truncated — nothing was removed"
        exit 1
    fi
    return 0
}

# --- The plan --------------------------------------------------------------------------

_drop_plan() {
    local repo tag id other j owners owners_show verdict why unknown_show

    _DROP_REMOVE=()
    _DROP_LINE_TAG=()
    _DROP_LINE_VERDICT=()
    _DROP_LINE_WHY=()

    unknown_show="${_DROP_UNKNOWN_OWNER[*]-}"
    [ "$_DROP_REPOS_OK" = yes ] || return 0

    for repo in $_DROP_REPOS; do
        owners="${_DROP_REPO_OWNER[$repo]:- }"
        owners_show="${owners# }"; owners_show="${owners_show% }"
        for tag in "${!_DROP_TAG_ID[@]}"; do
            case $tag in
                "$repo":*) ;;
                *) continue ;;
            esac
            id="${_DROP_TAG_ID[$tag]}"
            verdict=remove
            why=""

            if [ "$owners" != " $MANIFEST_NAME " ]; then
                verdict=keep
                why="$repo is claimed by more than one project ($owners_show)"
            elif [ "${#_DROP_UNKNOWN_OWNER[@]}" -gt 0 ]; then
                verdict=keep
                why="ownership cannot be established: $unknown_show declare(s) images kasbah could not read, and such a file could name any repository"
            else
                # Honest about what the removal costs: an image carrying another
                # repository's tag loses only this name.
                other=""
                for j in ${_DROP_ID_TAGS[$id]}; do
                    case $j in "$repo":*) continue ;; esac
                    other="$other$j "
                done
                if [ -n "$other" ]; then
                    why="untags only, the image also carries ${other% }"
                else
                    why="built by $MANIFEST_NAME, claimed by no other project"
                fi
            fi

            _DROP_LINE_TAG+=("$tag")
            _DROP_LINE_VERDICT+=("$verdict")
            _DROP_LINE_WHY+=("$why")
            [ "$verdict" != remove ] || _DROP_REMOVE+=("$tag")
        done
    done
    return 0
}

# Tags that no readable project can be shown to own, on repositories that some
# project on this server plainly built: `:current` is written by `kasbah deploy`
# and by nothing else (docs/build-deploy.md → image tags), so a repository
# carrying one is a kasbah project's own image, and one no readable compose file
# declares is an image the server no longer attributes to anybody.
#
# Only --prune has a use for this, and only on the run that goes ahead without
# an image set: it is the honest answer to "what are you leaving behind".
_drop_orphans() {
    local tag repo

    _DROP_ORPHAN=()
    for tag in "${!_DROP_TAG_ID[@]}"; do
        repo="${tag%:*}"
        [ -n "${_DROP_TAG_ID[$repo:current]+set}" ] || continue
        [ -z "${_DROP_REPO_OWNER[$repo]+set}" ] || continue
        _DROP_ORPHAN+=("$tag")
    done
    if [ "${#_DROP_ORPHAN[@]}" -gt 0 ]; then
        readarray -t _DROP_ORPHAN < <(printf '%s\n' "${_DROP_ORPHAN[@]}" | LC_ALL=C sort)
    fi
    return 0
}

# The mail claim, and only under --prune (docs/phases/08-keep.md, D11): plain
# drop is the reversible verb and the claim is what makes a redeploy whole.
#
# The registry is read through `server add-mail-domain`'s own reader, which
# normalises `primary_domain` into the domain list the way every writer of the
# file renders it, and re-rendered through the same template — appending or
# deleting a line by hand would be a second writer for a file docs/mail.md says
# has one.
_drop_mail_plan() {
    local d found=no keep=() primary="" domains=() reason=""

    _DROP_MAIL_RENDERED=""
    _DROP_MAIL_VERDICT=""
    [ -n "$_DROP_MAIL_DOMAIN" ] || return 0
    if [ "$_DROP_PRUNE" != yes ]; then
        _DROP_MAIL_VERDICT="kept: plain drop leaves the claim, so a redeploy resurrects the project whole"
        return 0
    fi

    case "${_DROP_FACT[mail_dir]}" in
        dir) ;;
        *)
            _DROP_MAIL_VERDICT="nothing to release: there is no mail stack at $_DROP_APPS_PATH/mail"
            return 0
            ;;
    esac
    _drop_b64_field "${_DROP_FACT[mail_registry_b64]}" _DROP_MAIL_REGISTRY \
        || die "the drop probe on $_DROP_TARGET sent $_DROP_APPS_PATH/mail/kasbah.yml as something that is not base64"
    if [ "${_DROP_FACT[mail_registry_state]}" != ok ] || [ -z "$_DROP_MAIL_REGISTRY" ]; then
        _DROP_MAIL_VERDICT="nothing to release: $_DROP_APPS_PATH/mail/kasbah.yml is ${_DROP_FACT[mail_registry_state]}"
        return 0
    fi

    # lib/server_mail.sh, at the one moment it is wanted. It brings
    # lib/server_init.sh with it for the registry template, and a drop of a
    # project with no mail claim has no business loading either.
    . "$KASBAH_LIB_DIR/server_mail.sh"

    # `server add-mail-domain`'s own reader, run where its refusals cannot end
    # this command. It is the copy that normalises `primary_domain` into the
    # domain list the way every writer of the file renders it, so using it is
    # what stops drop being a fifth answer to "does this stack serve X?" — but
    # it `die`s on a registry it will not rewrite, and *no* shape of somebody
    # else's mail stack is a reason to stop a drop. In a subshell its exit is
    # its own; what it said comes back as the verdict.
    _drop_mail_normalise primary domains reason || {
        _DROP_MAIL_VERDICT="NOT released: ${reason:-$_DROP_APPS_PATH/mail/kasbah.yml is not a registry kasbah will rewrite}"
        return 0
    }
    _DROP_MAIL_PRIMARY="$primary"
    _SM_PRIMARY="$primary"
    _SM_DOMAINS=("${domains[@]}")

    if [ "$_DROP_MAIL_DOMAIN" = "$_DROP_MAIL_PRIMARY" ]; then
        # The primary is the MX target and the name both of the stack's
        # certificates are issued for. Removing it is not releasing a claim, it
        # is unmaking the mail stack for every other project on the host.
        _DROP_MAIL_VERDICT="NOT released: $_DROP_MAIL_DOMAIN is the stack's primary_domain — its MX target and certificate name — and no project's drop takes that away"
        return 0
    fi

    keep=()
    found=no
    for d in ${_SM_DOMAINS[@]+"${_SM_DOMAINS[@]}"}; do
        if [ "$d" = "$_DROP_MAIL_DOMAIN" ]; then
            found=yes
            continue
        fi
        keep+=("$d")
    done
    if [ "$found" != yes ]; then
        _DROP_MAIL_VERDICT="nothing to release: $_DROP_APPS_PATH/mail/kasbah.yml does not list $_DROP_MAIL_DOMAIN"
        return 0
    fi
    _SM_DOMAINS=(${keep[@]+"${keep[@]}"})

    _DROP_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-drop.XXXXXX")" \
        || die "could not create a temp directory to render the mail registry in"
    _sm_render_registry "$_DROP_TMPDIR/kasbah.yml"
    _DROP_MAIL_RENDERED="$(cat "$_DROP_TMPDIR/kasbah.yml"; printf x)" \
        || die "could not read the rendered mail registry"
    _DROP_MAIL_RENDERED="${_DROP_MAIL_RENDERED%x}"
    _DROP_MAIL_VERDICT="released: $_DROP_MAIL_DOMAIN is removed from $_DROP_APPS_PATH/mail/kasbah.yml"
    return 0
}

# _drop_mail_normalise <primary-outvar> <domains-outvar> <reason-outvar> — the
# registry's primary domain, and every domain it serves in the order the writers
# render them; or 1 with the reader's own first sentence as the reason.
#
# The two are returned separately because they are two facts: the primary leads
# the list only on a registry `_sm_read_registry` had to prepend it to, and a
# hand-edited one that already names it under `domains:` keeps it where it is.
#
# A subshell, because `_sm_read_registry` ends the process on a registry it will
# not rewrite and this command has already printed a plan by then. One line per
# value: a domain that passed `_is_fqdn` carries neither a space nor a newline.
_drop_mail_normalise() {
    local _mn_primary="$1" _mn_out="$2" _mn_reason="$3" _mn_err _mn_body _mn_rc=0
    local _mn_lines=()

    printf -v "$_mn_reason" '%s' ""
    printf -v "$_mn_primary" '%s' ""
    _mn_err="$(mktemp "${TMPDIR:-/tmp}/kasbah-drop-mail.XXXXXX")" \
        || die "could not create a temp file to read $_DROP_APPS_PATH/mail/kasbah.yml with"
    _mn_body=$( { _SM_TARGET="$_DROP_TARGET"; _SM_APPS_PATH="$_DROP_APPS_PATH"
                  _SM_REGISTRY="$_DROP_MAIL_REGISTRY"
                  _sm_read_registry >/dev/null
                  printf '%s\n' "$_SM_PRIMARY" ${_SM_DOMAINS[@]+"${_SM_DOMAINS[@]}"}
                } 2>"$_mn_err" ) || _mn_rc=$?

    if [ "$_mn_rc" -ne 0 ]; then
        # The reader's first line, without the `error:` prefix or the colour it
        # may have decided on from this process's own stderr.
        local _mn_first
        _mn_first="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^error: //' -e 1q "$_mn_err")"
        printf -v "$_mn_reason" '%s' "${_mn_first%$'\r'}"
        rm -f "$_mn_err"
        return 1
    fi
    rm -f "$_mn_err"

    readarray -t _mn_lines <<<"$_mn_body"
    [ "${#_mn_lines[@]}" -ge 2 ] \
        || { printf -v "$_mn_reason" '%s' "$_DROP_APPS_PATH/mail/kasbah.yml yielded no domains"; return 1; }
    printf -v "$_mn_primary" '%s' "${_mn_lines[0]}"
    eval "$_mn_out=(\"\${_mn_lines[@]:1}\")"
    return 0
}

# --- The report ------------------------------------------------------------------------

_drop_report() {
    local i line lines=() width=0 verb keep_verb name state repos_show

    if [ "$_DROP_PRUNE" = yes ]; then verb="drop --prune"; else verb=drop; fi
    # Where the server came from, said out loud: this command deletes, and a
    # target resolved from a cache rather than typed is the one an operator
    # most needs to see before answering.
    if [ "$_DROP_TARGET_SOURCE" = state ]; then
        printf 'kasbah %s — %s on %s (%s), from %s\n\n' \
            "$verb" "$MANIFEST_NAME" "$_DROP_TARGET" "$_DROP_APPS_PATH" \
            "$KASBAH_STATE_FILE last_server"
    else
        printf 'kasbah %s — %s on %s (%s)\n\n' \
            "$verb" "$MANIFEST_NAME" "$_DROP_TARGET" "$_DROP_APPS_PATH"
    fi

    printf 'to remove\n'
    case "${_DROP_FACT[fragment_state]}" in
        ok|empty) printf '  route       %s/traefik/dynamic/%s.yml\n' "$_DROP_APPS_PATH" "$MANIFEST_NAME" ;;
        missing)  printf '  route       none — %s/traefik/dynamic/%s.yml is not there\n' "$_DROP_APPS_PATH" "$MANIFEST_NAME" ;;
        *)        printf '  route       %s/traefik/dynamic/%s.yml (%s)\n' "$_DROP_APPS_PATH" "$MANIFEST_NAME" "${_DROP_FACT[fragment_state]}" ;;
    esac

    printf '  containers  %s\n' "${_DROP_CONTAINERS:-none labelled $MANIFEST_NAME}"

    if [ "${#_DROP_LINE_TAG[@]}" -eq 0 ]; then
        if [ "$_DROP_REPOS_OK" != yes ]; then
            printf '  images      none — %s/%s/compose.yml is %s, so which images this project builds is unknown\n' \
                "$_DROP_APPS_PATH" "$MANIFEST_NAME" "$(_drop_compose_word)"
        elif [ "$_DROP_REPOS" = " " ]; then
            printf '  images      none — this project builds none of its own (stock images only)\n'
        else
            repos_show="${_DROP_REPOS# }"
            printf '  images      none of %s is on this server\n' "${repos_show% }"
        fi
    else
        for i in "${!_DROP_LINE_TAG[@]}"; do
            [ "${#_DROP_LINE_TAG[$i]}" -le "$width" ] || width="${#_DROP_LINE_TAG[$i]}"
            lines+=("$(printf '%s\t%s\t%s' \
                "${_DROP_LINE_TAG[$i]}" "${_DROP_LINE_VERDICT[$i]}" "${_DROP_LINE_WHY[$i]}")")
        done
        # Two groups, because a `keep` row under a heading that reads "to
        # remove" says the opposite of what it means. Sorted by tag within each,
        # so two runs against one server print the same order: the plan is
        # walked out of an associative array, whose order bash does not define.
        if [ "${#_DROP_REMOVE[@]}" -eq 0 ]; then
            printf '  images      none — every tag of this project is left alone, below\n'
        else
            printf '  images\n'
        fi
        while IFS=$'\t' read -r name state line; do
            [ "$state" = remove ] || continue
            printf '    %-*s  %s\n' "$width" "$name" "$line"
        done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -t$'\t' -k1,1)
        if [ "${#_DROP_REMOVE[@]}" -ne "${#_DROP_LINE_TAG[@]}" ]; then
            printf '\nleft alone\n  images\n'
            while IFS=$'\t' read -r name state line; do
                [ "$state" = keep ] || continue
                printf '    %-*s  %s\n' "$width" "$name" "$line"
            done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -t$'\t' -k1,1)
        fi
    fi

    if [ "$_DROP_PRUNE" = yes ]; then keep_verb='to delete'; else keep_verb='to keep'; fi
    printf '\n%s\n' "$keep_verb"
    printf '  config      %s/%s/ (%s)\n' "$_DROP_APPS_PATH" "$MANIFEST_NAME" "${_DROP_FACT[project_state]}"
    printf '  data        %s/%s/ (%s)\n' "$_DROP_DATA_PATH" "$MANIFEST_NAME" "${_DROP_FACT[data_state]}"
    printf '  backups     %s/%s/backups/ (%s, %s file(s))\n' \
        "$_DROP_APPS_PATH" "$MANIFEST_NAME" "${_DROP_FACT[backups_state]}" "${_DROP_FACT[backups_count]}"
    [ -z "$_DROP_MAIL_VERDICT" ] \
        || printf '  mail        %s — %s\n' "$_DROP_MAIL_DOMAIN" "$_DROP_MAIL_VERDICT"

    if [ "$_DROP_PRUNE" = yes ]; then
        printf '\nthe off-VPS restic repository is not touched: it is operator property (docs/backup.md).\n'
    else
        printf '\na later `kasbah deploy` resurrects this project, once `kasbah build-push` has\nre-shipped its images.\n'
    fi
    printf '\n'
    return 0
}

# Why the project's own images could not be enumerated, in the words the probe
# used. `ok` means the file opened and yq refused it, which is a different fact
# from a file that could not be opened at all.
_drop_compose_word() {
    case "$_DROP_COMPOSE_STATE" in
        ok) printf 'not YAML kasbah can parse' ;;
        *)  printf '%s' "$_DROP_COMPOSE_STATE" ;;
    esac
    return 0
}

# --- The act ---------------------------------------------------------------------------

_drop_act() {
    local out rc=0 line key ref reason tag
    local removed=0 failed=0

    _DROP_REMOVED_REFS=()
    _DROP_FAILED_REFS=()
    _DROP_FAILED_WHY=()

    # The tags came off the server's own image table, so a name that could be
    # read as a flag or that carries whitespace is a truncated read rather than
    # a state — and this is the last moment before `docker image rm` sees it.
    for tag in ${_DROP_REMOVE[@]+"${_DROP_REMOVE[@]}"}; do
        case $tag in
            -*|*[[:space:]]*)
                die "refusing to remove '$tag' on $_DROP_TARGET: that is not an image tag docker gave back" ;;
        esac
    done
    # Before the round trip, so a refusal above is a run that changed nothing.

    out=$(ssh_script "$_DROP_APPS_PATH" "$_DROP_DATA_PATH" "$MANIFEST_NAME" \
                     "$_DROP_PRUNE" "$_DROP_MAIL_RENDERED" \
                     ${_DROP_REMOVE[@]+"${_DROP_REMOVE[@]}"} <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
name=$3
prune=$4
registry=$5
shift 5

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }
b64() { openssl base64 -A 2>/dev/null; }
flat() { tr -d '\r' | tr '\n' ' '; }

# The single most dangerous shape in this file: two of the steps below are
# `rm -rf` against a path built from $name, and this payload assembled none of
# its arguments. An empty name, `.`, `..`, or anything carrying a slash would
# make `rm -rf "$apps/$name"` a different command entirely, so the shape is
# checked here and the run refuses rather than continuing.
case $apps in /?*) ;; *) fail "refusing to act: apps path '$apps' is not an absolute path" ;; esac
case $data in /?*) ;; *) fail "refusing to act: data path '$data' is not an absolute path" ;; esac
case $name in
    [a-z]*) ;;
    *) fail "refusing to act: project name '$name' does not start with a lower-case letter, and every path this step removes is built from it" ;;
esac
case $name in
    *[!a-z0-9-]*) fail "refusing to act: project name '$name' is not letters, digits and hyphens, and every path this step removes is built from it" ;;
esac
case " traefik mail data backups .kasbah " in
    *" $name "*) fail "refusing to act: '$name' is a directory kasbah owns under $apps, not a project" ;;
esac
case $prune in yes|no) ;; *) fail "refusing to act: prune='$prune' is neither yes nor no" ;; esac

dir="$apps/$name"

# The same lock templates/remote-deploy.sh holds for the whole of a deploy, and
# taken for the same reason: a drop interleaved with one tears containers down
# under its hooks and removes the images it is retagging. `-n` so a second run
# fails fast and legibly instead of looking hung — and whether flock exists at
# all is asked first, because `flock -n 9` on a host without it exits 127 and
# reading that as a failed lock turns a missing prerequisite into a statement
# about a concurrent operator who does not exist.
command -v flock >/dev/null 2>&1 \
    || fail "flock is not installed on this server — it is the only thing keeping this drop from interleaving with a deploy of $name. Install util-linux (docs/server-setup.md). Nothing was changed."
if [ -d "$dir" ]; then
    exec 9>"$dir/.deploy.lock" || fail "could not open the lock file $dir/.deploy.lock"
    flock -n 9 \
        || fail "another deploy or rollback is already running in $dir — it holds the lock on $dir/.deploy.lock. Nothing was changed."
fi

# Every guard is above this line: the name and path checks, the missing-flock
# refusal and the lock another operator holds all exit without removing a route,
# a container or an image. So a run that never printed this changed nothing —
# which is what separates the caller's two diagnoses for a non-zero status. The
# one thing above it that touches the filesystem is `$dir/.deploy.lock` coming
# into existence, which is the file a deploy creates anyway and which `--prune`
# removes with the directory.
printf 'started=yes\n'

# The route first, containers second — the mirror of the order a deploy ships
# them in (docs/build-deploy.md → why the fragment ships last). Either order
# leaves a window; this one's failure mode is a running stack nobody can reach,
# which a redeploy fixes, and the other's is a live route to containers that no
# longer exist, which 502s until someone deploys again.
fragment="$apps/traefik/dynamic/$name.yml"
if [ -e "$fragment" ]; then
    if rm -f "$fragment"; then fstate=removed; else fstate=failed; fi
else
    fstate=absent
fi
printf 'fragment=%s\n' "$fstate"

# By label, not by file: `docker compose -p <name> down` needs no compose.yml
# and no .env, so a project whose .env was never rendered — or whose compose
# file interpolates a KASBAH_* value that is not there — comes down anyway. The
# `cd /` is what keeps it that way: compose reads a compose.yml out of the
# working directory if it finds one. Without -v, because named volumes are data
# and drop keeps data (docs/cli.md).
down_out=$(cd / && docker compose -p "$name" down --remove-orphans 2>&1); down_rc=$?
if [ "$down_rc" -eq 0 ]; then
    printf 'down=ok\n'
else
    printf 'down=failed\n'
fi
printf 'down_detail=%s\n' "$(printf '%s' "$down_out" | flat | b64)"

# What is still wearing the project label afterwards. `down` selects on the
# project label *and* `oneoff=False`, so a `compose run` leftover or a
# hand-started container survives it and exits 0 — and a run that said "brought
# down" over one of those would be describing something that did not happen.
# Deliberately unfiltered by oneoff: the question here is what is left, not what
# down was aiming at.
left=$(docker ps -a --filter "label=com.docker.compose.project=$name" \
           --format '{{.Names}}' 2>/dev/null | tr -d '\r' | tr '\n' ' ') || left=""
printf 'down_left=%s\n' "$(printf '%s' "$left" | b64)"

for ref in "$@"; do
    if out=$(docker image rm "$ref" 2>&1); then
        printf 'removed=%s\n' "$(printf '%s' "$ref" | b64)"
    else
        printf 'failed=%s %s\n' "$(printf '%s' "$ref" | b64)" \
               "$(printf '%s' "$out" | flat | b64)"
    fi
done

if [ "$prune" = yes ]; then
    # The registry, replaced whole through a temp file and a rename, so a run
    # that dies mid-write cannot leave half a registry. Empty means there was
    # nothing to release, which the caller decided and said.
    if [ -n "$registry" ]; then
        tmp="$apps/mail/.kasbah.yml.$$"
        if printf '%s' "$registry" > "$tmp" 2>/dev/null; then
            chmod 644 "$tmp" 2>/dev/null || true
            if mv -f "$tmp" "$apps/mail/kasbah.yml" 2>/dev/null; then
                printf 'mail=written\n'
            else
                rm -f "$tmp"
                printf 'mail=failed\n'
            fi
        else
            rm -f "$tmp" 2>/dev/null || true
            printf 'mail=failed\n'
        fi
    else
        printf 'mail=skipped\n'
    fi

    if [ -e "$data/$name" ]; then
        if rm -rf "$data/$name"; then printf 'data=removed\n'; else printf 'data=failed\n'; fi
    else
        printf 'data=absent\n'
    fi

    # Last, because the lock this run holds is a file inside it. Unlinking an
    # open file releases nothing early: fd 9 keeps the lock until this shell
    # exits, so the directory is gone and no concurrent deploy ever got in.
    if [ -e "$dir" ]; then
        if rm -rf "$dir"; then printf 'config=removed\n'; else printf 'config=failed\n'; fi
    else
        printf 'config=absent\n'
    fi
fi
printf 'done=yes\n'
exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the drop step on $_DROP_TARGET exited $rc"
        # Every guard in that payload sits above its `started=yes` and each of
        # them refuses without removing anything — so the two diagnoses are not
        # the same sentence, and guessing the worse one sends an operator
        # looking for damage that is not there. `server destroy` answers this
        # question the same way, for the same reason.
        if grep -q '^started=yes' <<<"$out"; then
            err_cont "some of it may have run — \`kasbah drop $_DROP_TARGET$_DROP_PRUNE_ARG\` again to see what is left"
        else
            err_cont "it refused before changing anything — nothing was removed"
        fi
        return 1
    fi

    local keys=(started fragment down down_detail down_left done)
    [ "$_DROP_PRUNE" != yes ] || keys+=(mail data config)
    _drop_absorb_checked "$out" "${keys[@]}"

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        key="${line%%=*}"
        case $key in
            removed)
                _vlog_b64_decode "${line#*=}" ref || ref="?"
                removed=$((removed + 1))
                # Both branches collect and neither prints. The far side did the
                # route, then the containers, then the images, and _drop_report_act
                # is the one place that order is reproduced — an `err` from here
                # would land above the route line that preceded it on the server.
                _DROP_REMOVED_REFS+=("$ref")
                ;;
            failed)
                line="${line#*=}"
                _vlog_b64_decode "${line%% *}" ref || ref="?"
                _vlog_b64_decode "${line#* }" reason || reason="(no reason given)"
                failed=$((failed + 1))
                _DROP_FAILED_REFS+=("$ref")
                _DROP_FAILED_WHY+=("$reason")
                ;;
        esac
    done <<<"$out"

    if [ "$(( removed + failed ))" -ne "${#_DROP_REMOVE[@]}" ]; then
        err "the drop step on $_DROP_TARGET accounted for $(( removed + failed )) of ${#_DROP_REMOVE[@]} image tags"
        err_cont "the step was truncated; run drop again to see what is left"
        return 1
    fi

    # The status, not an exit: the run reached the server and changed it, so
    # cmd_drop still has last_server to write before it ends.
    _drop_report_act "$removed" "$failed" || return 1
    return 0
}

# What the far side actually did, read out of the report rather than assumed
# from its exit status: every step there is failure-tolerant so that one that
# could not run does not strand the rest, which only works if each is read back.
#
# In the order the server did it — route, containers, images, then --prune's
# deletions — and on **stdout**, the same stream the plan went to, so
# `kasbah drop > log` holds what was planned *and* what happened. Only problems
# and follow-ups go to stderr, which is docs/cli.md's split.
#
# Returns 1 when any step could not do what it was asked. The caller decides
# what that costs; it is not an exit from here, because last_server is still
# owed to a run that reached the server.
_drop_report_act() {
    local removed="$1" failed="$2" detail="" bad=0 ref i left=""

    case "${_DROP_FACT[fragment]}" in
        removed) _drop_say "removed route $_DROP_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml" ;;
        absent)  _drop_say "route $_DROP_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml was not there" ;;
        *)
            _drop_say "FAILED to remove route $_DROP_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml"
            err "could not remove $_DROP_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml on $_DROP_TARGET"
            err_cont "the site is still routed at a stack this run has taken down — remove the file"
            err_cont "by hand, or re-deploy the project"
            bad=1
            ;;
    esac

    _drop_b64_field "${_DROP_FACT[down_detail]:--}" detail || detail=""
    _drop_b64_field "${_DROP_FACT[down_left]:--}" left || left=""
    left="${left%"${left##*[![:space:]]}"}"
    case "${_DROP_FACT[down]}" in
        ok)
            if [ -n "$left" ]; then
                # `down` selects on the project label *and* `oneoff=False`, so a
                # one-off or a hand-labelled container is left running and the
                # command still exits 0. Saying "brought down" over that would
                # be describing something that did not happen.
                _drop_say "docker compose -p $MANIFEST_NAME down returned 0, and $left is still there"
                warn "$left carries $MANIFEST_NAME's compose label and \`docker compose down\` does not remove it"
                warn "  (it selects on com.docker.compose.oneoff=False as well) — \`docker rm -f\` is the only way it goes"
            else
                _drop_say "brought down docker compose -p $MANIFEST_NAME"
            fi
            ;;
        *)
            _drop_say "FAILED: docker compose -p $MANIFEST_NAME down"
            err "\`docker compose -p $MANIFEST_NAME down\` failed on $_DROP_TARGET"
            [ -z "$detail" ] || err_cont "$detail"
            bad=1
            ;;
    esac

    for ref in ${_DROP_REMOVED_REFS[@]+"${_DROP_REMOVED_REFS[@]}"}; do
        _drop_say "removed image $ref"
    done
    for i in ${_DROP_FAILED_REFS[@]+"${!_DROP_FAILED_REFS[@]}"}; do
        _drop_say "FAILED to remove image ${_DROP_FAILED_REFS[$i]}"
        err "could not remove ${_DROP_FAILED_REFS[$i]} on $_DROP_TARGET: ${_DROP_FAILED_WHY[$i]}"
        bad=1
    done
    _drop_say "removed $removed of ${#_DROP_REMOVE[@]} image tag(s)"

    if [ "$_DROP_PRUNE" = yes ]; then
        case "${_DROP_FACT[data]}" in
            removed) _drop_say "deleted $_DROP_DATA_PATH/$MANIFEST_NAME" ;;
            absent)  _drop_say "$_DROP_DATA_PATH/$MANIFEST_NAME was not there" ;;
            *)       _drop_say "FAILED to delete $_DROP_DATA_PATH/$MANIFEST_NAME"
                     err "could not delete $_DROP_DATA_PATH/$MANIFEST_NAME on $_DROP_TARGET"; bad=1 ;;
        esac
        case "${_DROP_FACT[config]}" in
            removed) _drop_say "deleted $_DROP_APPS_PATH/$MANIFEST_NAME (the on-VPS backups with it)" ;;
            absent)  _drop_say "$_DROP_APPS_PATH/$MANIFEST_NAME was not there" ;;
            *)       _drop_say "FAILED to delete $_DROP_APPS_PATH/$MANIFEST_NAME"
                     err "could not delete $_DROP_APPS_PATH/$MANIFEST_NAME on $_DROP_TARGET"; bad=1 ;;
        esac
        # Bind mounts under <data>/<name> are what kasbah's model puts a
        # project's state in, and those are gone. A named volume is not: `down`
        # runs without -v, on purpose, and nothing here removes one.
        _drop_say "named docker volumes are not removed — \`docker volume ls\` on the server, then \`docker volume rm\`"
        case "${_DROP_FACT[mail]}" in
            written)
                _drop_say "released $_DROP_MAIL_DOMAIN from $_DROP_APPS_PATH/mail/kasbah.yml"
                # docker-mailserver owns postfix-virtual.cf and kasbah only ever
                # appends to it (lib/server_mail.sh). Leaving the alias is what
                # makes `add-mail-domain` an exact reversal of this.
                warn "postmaster@$_DROP_MAIL_DOMAIN is still aliased in docker-mailserver's postfix-virtual.cf"
                warn "  ssh $_DROP_TARGET 'docker exec mail-dms setup alias del postmaster@$_DROP_MAIL_DOMAIN postmaster@$_DROP_MAIL_PRIMARY'"
                warn "  reverse the whole release with: kasbah server add-mail-domain $_DROP_TARGET $_DROP_MAIL_DOMAIN"
                ;;
            skipped) ;;
            *)
                _drop_say "FAILED to rewrite $_DROP_APPS_PATH/mail/kasbah.yml"
                err "could not rewrite $_DROP_APPS_PATH/mail/kasbah.yml on $_DROP_TARGET"
                err_cont "$_DROP_MAIL_DOMAIN is still claimed there; everything else was dropped"
                bad=1
                ;;
        esac
    fi

    # The closing paragraph is a claim about the state this run leaves, so it is
    # only true of a run where every step did what it was asked. On a failed one
    # the last thing the operator reads must be the failure.
    if [ "$bad" -ne 0 ]; then
        err "$MANIFEST_NAME was not fully dropped from $_DROP_TARGET — see the FAILED line(s) above"
        err_cont "nothing here is undone by running it again: \`kasbah drop $_DROP_TARGET${_DROP_PRUNE_ARG}\` picks up what is left"
        return 1
    fi

    if [ "$_DROP_PRUNE" != yes ]; then
        _drop_say ""
        _drop_say "$MANIFEST_NAME is off $_DROP_TARGET, and everything a redeploy needs is still there"
        # Named only when this run really did remove them: in the ownership-cliff
        # case it removed none and they are all still on the server, and telling
        # the operator to re-ship them would be describing a different run.
        if [ "$removed" -gt 0 ]; then
            _drop_say "  kasbah build-push $_DROP_TARGET   # the images this run removed"
        else
            _drop_say "  kasbah build-push $_DROP_TARGET   # if this project's images are not on the server"
        fi
        # versions.log survived, so the far side knows this project has deployed
        # here — and templates/remote-deploy.sh refuses to deploy over a stack
        # with history whose pre-deploy-hook or backup containers do not exist,
        # which is exactly the state this drop leaves. --allow-stopped is how
        # the operator says they are meant to be gone, and whether they will
        # need it is a property of their manifest, already read.
        if [ "$_DROP_NEEDS_ALLOW_STOPPED" = yes ]; then
            _drop_say "  kasbah deploy $_DROP_TARGET --allow-stopped"
            _drop_say "     --allow-stopped because versions.log still records the deploys, and this"
            _drop_say "     project's backup: / pre-deploy hooks name containers this drop removed"
        else
            _drop_say "  kasbah deploy $_DROP_TARGET"
        fi
    fi
    return 0
}

# One outcome line, on stdout. The plan went there and so does what came of it:
# a command whose output is redirected must not lose half its own report
# (docs/cli.md — the sentence that answers the question asked is the report).
_drop_say() {
    if [ -z "$*" ]; then printf '\n'; else printf '  %s\n' "$*"; fi
    return 0
}

_drop_cleanup() {
    [ -n "$_DROP_TMPDIR" ] || return 0
    rm -rf "$_DROP_TMPDIR"
    _DROP_TMPDIR=""
    return 0
}

# --- The command ------------------------------------------------------------------------

cmd_drop() {
    local question act_rc

    _drop_parse_args "$@"
    # manifest_require is the whole of the name check on this side: lib/manifest.sh
    # already refuses anything but `^[a-z][a-z0-9-]*$` and every name kasbah owns
    # under <apps>/, which is exactly the shape `rm -rf "$apps/$name"` needs. The
    # copy that matters is in the act payload, which can source nothing and must
    # not trust an argument this side assembled.
    manifest_require
    _drop_read_mail
    _drop_read_return_needs
    _drop_resolve_target
    command -v yq >/dev/null \
        || die "yq is required (every project's compose.yml is parsed here, never on the server)"

    # Installed before ssh_connect, because lib/ssh.sh chains its master
    # teardown onto whatever EXIT trap it finds and one installed afterwards is
    # the last writer.
    trap '_drop_cleanup' EXIT

    ssh_connect "$_DROP_TARGET"
    marker_read "$_DROP_TARGET"
    _DROP_APPS_PATH="$MARKER_APPS_PATH"
    _DROP_DATA_PATH="$MARKER_DATA_PATH"

    _drop_collect
    _drop_check_server
    _drop_decode_images
    _drop_decode_containers
    _drop_ownership
    _drop_plan
    _drop_orphans
    _drop_mail_plan
    _drop_report

    if [ "${#_DROP_UNKNOWN_OWNER[@]}" -gt 0 ]; then
        warn "no image repository on $_DROP_TARGET is provably single-owner: kasbah could not read"
        warn "  what images ${_DROP_UNKNOWN_OWNER[*]} declare(s), and such a file could name any"
        warn "  repository on this host — so no image is removed"
        [ "$_DROP_PRUNE" != yes ] || _drop_prune_cliff
    fi

    if ! _drop_anything_to_do; then
        # On stdout with the rest of the report: this is the answer to the
        # question the command was asked, and a redirected run must not lose it
        # (docs/cli.md — the sentence that answers goes to stdout).
        printf '%s is not on %s — nothing to drop\n' "$MANIFEST_NAME" "$_DROP_TARGET"
        state_record last_server "$_DROP_TARGET"
        return 0
    fi

    question="drop $MANIFEST_NAME from $_DROP_TARGET?"
    [ "$_DROP_PRUNE" != yes ] \
        || question="drop $MANIFEST_NAME from $_DROP_TARGET and delete its config, data and on-VPS backups?"
    # Both declines end the run non-zero and having changed nothing. Declining
    # is a legitimate answer to the question, and it is not a drop: a caller
    # that reads exit 0 as "this project is off that server" would be wrong.
    prompt_confirm yes "$question" "$_DROP_YES" || {
        err "not confirmed — nothing was changed on $_DROP_TARGET"
        exit 1
    }
    prompt_typed yes "$MANIFEST_NAME" \
        "type the project name ($MANIFEST_NAME) to confirm:" "$_DROP_YES" || {
        err "that is not $MANIFEST_NAME — nothing was changed on $_DROP_TARGET"
        exit 1
    }

    act_rc=0
    _drop_act || act_rc=$?
    # Written whatever the far side managed. This run reached the server and
    # changed it; a project that had to re-type USER@HOST to finish clearing up
    # after a half-done drop would be remembering the wrong thing
    # (docs/project-manifest.md → write rule).
    state_record last_server "$_DROP_TARGET"
    [ "$act_rc" -eq 0 ] || exit "$act_rc"
    return 0
}

# What --prune does when no repository on the server is provably single-owner.
# Three situations, and they do not have one answer, because what --prune
# destroys differs in each.
#
#   * this project's own compose.yml is unreadable or does not parse — the file
#     that says which images it built is the file kasbah could not read, and
#     --prune deletes it. Refused: the question becomes unanswerable forever.
#   * some *other* project's is — this project's own declarations were read
#     fine, and deleting its directory destroys no unknown record. Still
#     refused, for the other half of the rule: while a neighbour's declarations
#     are unknown, a repository with one known claimant may have a second, so
#     none of this project's tags can be removed — and once it stops being a
#     project here, no later run can attribute them to it either.
#   * this project's directory is there with **no compose.yml at all** — there
#     is no record to destroy, no file to fix, and refusing would leave a
#     hand-run `rm -rf` on somebody's server as the only way out, which is the
#     thing --prune exists to spare them. It goes ahead, removes no image, and
#     names what it is leaving behind. A deploy that died between the `mkdir`
#     and the compose rsync leaves exactly this.
_drop_prune_cliff() {
    local tag

    if [ "${#_DROP_UNKNOWN_OTHERS[@]}" -gt 0 ]; then
        err "--prune is refused: ${_DROP_UNKNOWN_OTHERS[*]} declare(s) images kasbah could not read"
        err_cont "while that is true no repository on this host is provably single-owner, so not one"
        err_cont "of $MANIFEST_NAME's tags can be removed — and --prune would stop it being a project"
        err_cont "here, after which nothing can attribute those tags to it again."
        err_cont "Fix the compose.yml of ${_DROP_UNKNOWN_OTHERS[*]}, or run"
        err_cont "\`kasbah drop $_DROP_TARGET\` without --prune, which changes nothing a redeploy"
        err_cont "cannot undo."
        exit 1
    fi
    if [ "$_DROP_COMPOSE_STATE" != missing ]; then
        err "--prune is refused: $_DROP_APPS_PATH/$MANIFEST_NAME/compose.yml is $(_drop_compose_word)"
        err_cont "that file is the only record of which images this project builds, and --prune"
        err_cont "deletes it — after that nobody can ever answer the question. Fix it, or run"
        err_cont "\`kasbah drop $_DROP_TARGET\` without --prune, which changes nothing a redeploy"
        err_cont "cannot undo."
        exit 1
    fi

    warn "$_DROP_APPS_PATH/$MANIFEST_NAME has no compose.yml, so no image on $_DROP_TARGET can be"
    warn "  attributed to $MANIFEST_NAME — --prune goes ahead and removes none of them, because"
    warn "  there is no record here for it to destroy and nothing for you to fix"
    if [ "${#_DROP_ORPHAN[@]}" -gt 0 ]; then
        warn "  these tags are on the server, built by some kasbah project and claimed by none"
        warn "  that kasbah could read — any of them may be $MANIFEST_NAME's:"
        for tag in "${_DROP_ORPHAN[@]}"; do
            warn "    $tag"
        done
        warn "  \`docker image rm\` on $_DROP_TARGET is the only thing that removes them"
    else
        warn "  no tag on $_DROP_TARGET is unclaimed, so there is likely nothing of it left"
    fi
    return 0
}

# Whether this run has anything left to do at all. A project already dropped,
# or one that never reached this server, is not an error — but it must not
# print a confirmation about an empty plan either.
_drop_anything_to_do() {
    [ "${#_DROP_REMOVE[@]}" -eq 0 ] || return 0
    [ "${_DROP_FACT[fragment_state]}" = missing ] || return 0
    [ "$_DROP_CONTAINERS_SEEN" = no ] || return 0
    if [ "$_DROP_PRUNE" = yes ]; then
        [ "${_DROP_FACT[project_state]}" = absent ] || return 0
        [ "${_DROP_FACT[data_state]}" = absent ] || return 0
        [ -z "$_DROP_MAIL_RENDERED" ] || return 0
    fi
    return 1
}

# The manifest's mail claim, read the way lib/deploy.sh reads it — one field of
# one block, and the whole of what a claim says (docs/project-manifest.md →
# mail). Sourcing lib/deploy.sh for _deploy_read_mail would drag the whole
# build/ship/rollback surface into a command that removes things, so the two
# fields are read here and validated the same way.
# Whether the manifest names a container the outgoing steps of a deploy would
# need: `backup:`'s container, or the first word of a pre-deploy hook. Those are
# the containers templates/remote-deploy.sh's rd_outgoing_preflight looks for,
# and a drop removes every one of them.
_drop_read_return_needs() {
    local raw

    _DROP_NEEDS_ALLOW_STOPPED=no
    raw="$(manifest_get '.backup.container // ""')"
    raw="${raw%$'\r'}"
    [ "$raw" = null ] || [ -z "$raw" ] || _DROP_NEEDS_ALLOW_STOPPED=yes
    raw="$(manifest_get '(.hooks["pre-deploy"] // []) | length')"
    raw="${raw%$'\r'}"
    case $raw in ''|0|null) ;; *) _DROP_NEEDS_ALLOW_STOPPED=yes ;; esac
    return 0
}

_drop_read_mail() {
    local raw kind

    _DROP_MAIL_DOMAIN=""
    raw="$(manifest_get '.mail // null')"
    [ "$raw" != null ] && [ -n "$raw" ] || return 0

    kind="$(manifest_get '.mail | type')"
    kind="${kind%$'\r'}"
    [ "$kind" = object ] \
        || die "kasbah.yml: mail: has type '$kind' — it has to be a block with a domain: under it (docs/project-manifest.md → mail)"

    raw="$(manifest_get '.mail.domain // ""')"
    raw="${raw%$'\r'}"
    [ "$raw" != null ] || raw=""
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [ -n "$raw" ] \
        || die "kasbah.yml: mail: has no domain: — the claim is that the VPS mail stack handles that domain, and there is nothing else in the block for kasbah to check (docs/project-manifest.md)"
    _DROP_MAIL_DOMAIN="$raw"
    return 0
}
