# kasbah — server prune: image retention across every project on a VPS
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_PRUNE_LOADED:-}" ] && return 0
_KASBAH_PRUNE_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
# For KASBAH_RESERVED_NAMES alone — a server command has no manifest to read.
# The same list `server status` uses to decide what under <apps>/ is a project,
# for the same reason: two commands walking one tree two ways is drift.
. "$KASBAH_LIB_DIR/manifest.sh"
# The deploy record's reader. `prune` decides what to delete from what a project
# has deployed, so it reads the record through the same parser `history` and
# `rollback` do — including its archive states, which are what stop this command
# concluding a deletion from a record it could not read.
. "$KASBAH_LIB_DIR/versions_log.sh"
. "$KASBAH_LIB_DIR/prompt.sh"

# `kasbah server prune USER@HOST [--yes]` removes `:<version>` image tags that
# are **both** older than three months **and** not among the project's last three
# deployed versions — the version `:current` points at counting as the first of
# the three, and `:current` itself never pruned (docs/build-deploy.md →
# Retention). The time window mirrors versions.log's rotation cutoff and the
# count floor is what guarantees a rollback target exists on a project that
# deploys once a year.
#
# Two round trips, and only ever two:
#
#   1. One batched read — the apps pointer, the marker's presence, every
#      project's compose.yml and versions.log(.gz), the image table and the
#      containers holding images. Batched for the reason `server status` and
#      `server init` batch theirs: a probe per project is a session per project,
#      and the rig's `maxstartups 10` refuses the eleventh.
#   2. One `docker image rm`, after the operator has answered. That one cannot
#      be folded into the read — the answer happens between them — and a run
#      that removes nothing (nothing to remove, or an answer of no) makes it not
#      at all.
#
# Nothing structured is parsed on the far side. compose.yml comes back as bytes
# and meets the workstation's yq, the deploy record comes back as bytes and
# meets lib/versions_log.sh: the VPS keeps needing no yq, jq or python3
# (docs/mail.md, docs/server-setup.md → prerequisites).
#
# **What it refuses to do is the point.** A project whose versions.log cannot be
# read, whose archive did not decode whole, whose record holds a line the parser
# could not read within the span it had to walk, or that has no record at all is
# **skipped entire** with a warning — not one tag of it is removed. Phase 5's
# finding is that a command concluding something from the *absence* of a record
# must consult the archive state before it speaks; this command concludes
# deletion, so it consults it and then declines.

_PR_TARGET=""
_PR_APPS_PATH=""
_PR_APPS_SOURCE=""
# "yes" when --yes was passed, empty when it was not. Empty means *ask*
# (docs/overview.md → Interactivity); it never means no.
_PR_YES=""

declare -A _PR_FACT=()
# The bind-mount root as the server marker records it. Not a project, and the
# only way to know that is to read the marker: --data-path can put it under the
# apps path with any name at all.
_PR_MARKER_DATA=""

# The image table, keyed by image id: when it was created, and every tag it
# carries. A tag is `<repo>:<version>`; the id behind it is what says whether
# two tags are one image.
declare -A _PR_CREATED=()
declare -A _PR_ID_TAGS=()
declare -A _PR_TAG_ID=()
# Image id → the containers created from it, as `name(state)` words. Any tag on
# such an image is out of bounds, whatever its age.
declare -A _PR_HELD=()

# One entry per project directory under the apps path.
_PR_P_NAME=()
_PR_P_COMPOSE_STATE=()
_PR_P_COMPOSE=()
_PR_P_ACTIVE_STATE=()
_PR_P_ACTIVE_B64=()
_PR_P_ARCHIVE_STATE=()
_PR_P_ARCHIVE_B64=()
# Its built-image repositories, as a space-fenced word list (" a b "), whether
# that list could be established at all, and the projects claiming each
# repository, likewise.
_PR_P_REPOS=()
_PR_P_REPOS_OK=()
declare -A _PR_REPO_OWNER=()
# The projects whose declared images kasbah could not enumerate — an unopenable
# compose.yml, or one yq refuses. While there is one of these, **no** repository
# on the server is provably single-owner, and nothing is removed anywhere: see
# _prune_plan.
_PR_UNKNOWN_OWNER=()

# The plan, one entry per candidate tag, in project order. VERDICT is `remove`
# or `keep`; WHY is the clause the report prints after the tag.
_PR_LINE_PROJ=()
_PR_LINE_TAG=()
_PR_LINE_VERDICT=()
_PR_LINE_WHY=()
# The removal set alone, in the order the report printed it.
_PR_REMOVE=()
# Projects left alone, and why. Their tags never reach the plan at all.
_PR_SKIP_NAME=()
_PR_SKIP_WHY=()

# The fixed names kasbah owns under the apps path — the same set `server status`
# walks past (docs/server-setup.md → What init creates).
_PR_RESERVED=(.kasbah "${KASBAH_RESERVED_NAMES[@]}")

_server_prune_usage() {
    cat <<EOF
Usage: kasbah server prune USER@HOST [--yes]

Image retention cleanup across every project on the server. Removes
<image>:<version> tags that are both older than 3 months and not among the
project's last 3 deployed versions — the version :current points at counts as
the first of the 3, and :current itself is never pruned. The time window is the
same one versions.log rotation uses.

Prints the plan and asks once before removing anything.

Flags:
  --yes   answer that question yes, for scripts. Without it and without a
          terminal, prune stops rather than assuming.

Where the server was prepared is the server's own answer: $KASBAH_APPS_POINTER,
falling back to $KASBAH_DEFAULT_APPS_PATH. There is no flag to override it —
aiming a destructive command at a tree the server does not consider its own is
not a recovery path (docs/cli.md).

A project whose deploy record cannot be read whole is skipped entirely, with a
warning: kasbah does not delete images on incomplete evidence.
EOF
}

# --- Command line -----------------------------------------------------------------

# There is deliberately no --apps-path here. Among the commands that only *read*
# an apps path, `server status` is the sole holder of that escape hatch
# (`server init` has one because it establishes the path, not because it reads
# one) — docs/cli.md: a value repeated on every
# invocation is a belief each caller holds separately, and the apps path is a
# property of the server. On a command that deletes, an operator-supplied path
# is worse than redundant — it aims the deletion at a tree the server does not
# consider its own. Every refusal below therefore sends the operator to
# `server status --apps-path=<dir>` to *find* the tree and to `server init` to
# repair the pointer, which is the recovery docs/cli.md prescribes.
_server_prune_parse_args() {
    _PR_TARGET=""
    _PR_APPS_PATH=""
    _PR_APPS_SOURCE=""
    _PR_YES=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)         _PR_YES=yes ;;
            -h|--help)     _server_prune_usage; exit 0 ;;
            -*)            die "server prune: unknown flag '${1%%=*}' (expected --yes)" ;;
            *)
                [ -z "$_PR_TARGET" ] \
                    || die "server prune: unexpected argument '$1' (USER@HOST is given once)"
                _PR_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_PR_TARGET" ] \
        || die "server prune: USER@HOST is required (the user kasbah deploys as is not optional)"
    return 0
}

# --- The month, reckoned the way rotation reckons it ---------------------------------

# The month a timestamp falls in, as `year * 12 + month`, which is what makes
# `now - 3` cross a year boundary by arithmetic rather than by string surgery.
#
# **This is deliberately the same reckoning as `_rd_month_index` in
# templates/remote-deploy.sh**, down to the loose leading-`YYYY-MM-` test: the
# retention window and the rotation window are one window (docs/build-deploy.md
# → Retention), and two implementations of "older than three months" is the
# drift this repository keeps writing findings about. Phase 5 measured that
# tightening the predicate there stops rotation entirely; tightening it here
# would stop prune. tests/prune_test.sh drives one table through both copies.
#
# The month is read off the timestamp's own leading `YYYY-MM`, offset and all —
# a `docker load`ed image keeps the offset of the machine that built it, and the
# rig has produced `2026-08-23T01:00:06+01:00`. The parallel with rotation stops
# at the reckoning: `templates/remote-deploy.sh` writes `date -u -Iseconds`, so
# rotation's inputs are always `+00:00` and it never meets a real offset, while
# `.Created` may. The exposure that leaves, stated plainly: an image built under
# a negative offset within hours of a month boundary reads as one month early,
# so such a tag can be removed at about 2 months 30 days rather than 3 — and
# only if it is also not among the last 3 deployed, not the image `:current`
# points at, and held by no container. A `date -d` conversion buys nothing at
# month granularity and would put a GNU-only dependency in the one calculation
# both sides have to agree on.
_prune_month_index() {
    local _mi_ts="$1" _mi_out="$2"
    case "$_mi_ts" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-*) ;;
        *) return 1 ;;
    esac
    printf -v "$_mi_out" '%s' "$(( 10#${_mi_ts:0:4} * 12 + 10#${_mi_ts:5:2} ))"
    return 0
}

# --- The one remote read -------------------------------------------------------------

# Folds the report into the fact table and checks the key set as a protocol
# before any value is read: a truncated step must not be absorbed into a plan.
# Clipped to twenty lines of 120 bytes, because several of these values are
# base64 blobs that grow with the server. Nothing prune reads is a credential —
# compose.yml is on the server precisely so the operator can read it, and the
# deploy record is a log — so there is no redaction list here; if this probe ever
# grows one, it needs `server status`'s.
_prune_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_shown=0
    local _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _PR_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_PR_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the prune probe on $_PR_TARGET reported no ${_ac_missing[*]}"
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
# in the base64 alphabet. The decode itself is versions_log.sh's, which this
# file already loads for the record reader — it is the copy that keeps a payload
# whose last byte is not a newline distinct from one whose is.
_prune_b64_field() {
    local _bf_out="$2"
    if [ "$1" = - ]; then
        printf -v "$_bf_out" '%s' ""
        return 0
    fi
    _vlog_b64_decode "$1" "$_bf_out" || return 1
    return 0
}

_prune_collect() {
    local out rc=0

    out=$(ssh_script "$KASBAH_DEFAULT_APPS_PATH" \
                     "$KASBAH_APPS_POINTER" "${_PR_RESERVED[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
default=$1
pointer=$2
reserved=" $3 "

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

# The pointer's own spelling, reduced to the form every kasbah path flag is
# normalised into: CR and trailing blanks off, empty and `.` segments dropped,
# no trailing slash. `/apps/`, `//apps` and `/apps/.` all name `/apps`, and only
# the normalised form compares equal to what init recorded.
norm_path() {
    local p="$1" out="" seg IFS=/
    set -f
    p=${p%$'\r'}
    while [ -n "$p" ]; do
        case ${p: -1} in
            ' '|$'\t') p=${p%?} ;;
            *) break ;;
        esac
    done
    case $p in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    for seg in $p; do
        [ -n "$seg" ] && [ "$seg" != . ] || continue
        out="$out/$seg"
    done
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}

# Called in a command substitution, which is a subshell — `set -f` above must
# not reach the project glob below it.
pointer_dir=${pointer%/*}
pointer_state=absent
pointer_value=""
if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    pointer_state=notfile
elif [ -f "$pointer" ] && [ ! -r "$pointer" ]; then
    pointer_state=unreadable
elif [ -f "$pointer" ]; then
    pointer_state=present
    IFS= read -r pointer_value < "$pointer" || pointer_value=""
    pointer_value=$(norm_path "$pointer_value")
elif [ -d "$pointer_dir" ] && [ ! -x "$pointer_dir" ]; then
    pointer_state=unreachable
fi
case $pointer_value in
    /?*) apps=$pointer_value; apps_source=pointer ;;
    *)   apps=$default;       apps_source=default ;;
esac
kv pointer_state "$pointer_state"
kv pointer_value "$pointer_value"
kv apps_path "$apps"
kv apps_source "$apps_source"

# The month, from the server's clock and in UTC, exactly as rotation asks it
# (templates/remote-deploy.sh → rd_rotate_log). One clock decides both windows.
kv now_month "$(date -u +%Y-%m)"

if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_error ""
else
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi

apps_state=absent
if [ -d "$apps" ]; then apps_state=dir
elif [ -e "$apps" ]; then apps_state=notdir
fi
kv apps_state "$apps_state"

# The marker: its presence, because a server without one is one this command has
# no business deleting from, and its bytes, because the bind-mount root is not
# always among the fixed names kasbah owns under the apps path — `--data-path`
# can put it inside, under any name — and the marker is the only record of which
# directory that is. Parsed on the caller's side; there is no jq here.
marker="$apps/.kasbah/server.json"
marker_state=absent
marker_b64=""
if [ -f "$marker" ]; then
    marker_b64=$(openssl base64 -A -in "$marker" 2>/dev/null) || marker_b64=""
    if [ -n "$marker_b64" ]; then marker_state=present; else marker_state=unreadable; fi
elif [ -e "$marker" ]; then
    marker_state=notfile
fi
kv marker_state "$marker_state"
kv marker_b64 "$marker_b64"

# Every image, with the time it was **created** and every tag it carries. The
# created time is the image's own — a `docker load`ed image keeps the time it
# was built, which is the honest number; a tag's mtime is the time somebody
# last pointed a name at it, and re-tagging one would make it look new.
images=""
containers=""
if [ "$docker_rc" -eq 0 ]; then
    ids=$(docker images -q 2>/dev/null | sort -u) || ids=""
    if [ -n "$ids" ]; then
        images=$(docker image inspect \
                     --format '{{.Id}} {{.Created}}{{range .RepoTags}} {{.}}{{end}}' \
                     $ids 2>/dev/null) || images=""
    fi
    # Every container, running or not, and the image id it was created from. A
    # tag on an image a container holds is not a candidate: docker would refuse
    # to delete it, and attempting it would turn a report into an error.
    cids=$(docker ps -a -q 2>/dev/null) || cids=""
    if [ -n "$cids" ]; then
        containers=$(docker inspect \
                         --format '{{.Image}} {{.State.Status}} {{.Name}}' \
                         $cids 2>/dev/null) || containers=""
    fi
fi
kv images_b64 "$(printf '%s' "$images" | b64)"
kv containers_b64 "$(printf '%s' "$containers" | b64)"

# The same seven words `server status` and lib/versions_log.sh report a file in.
# Two commands describing one server two ways is what the shared spelling exists
# to prevent.
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

# One row per project: everything under the apps path that is not one of
# kasbah's own directories. dotglob is on because `.kasbah` is skipped by name
# rather than by being hidden.
rows=""
count=0
if [ "$apps_state" = dir ]; then
    shopt -s nullglob dotglob
    for path in "$apps"/*; do
        name=${path##*/}
        case $reserved in *" $name "*) continue ;; esac
        count=$((count + 1))

        cstate=missing; cdata=""
        astate=missing; adata=""
        gstate=missing; gdata=""
        if [ ! -d "$path" ]; then
            cstate=notdir; astate=notdir; gstate=notdir
        elif [ ! -r "$path" ] || [ ! -x "$path" ]; then
            # A deploy that ran under sudo leaves a directory this user cannot
            # enter, and `[ -f ]` answers no for a file behind it exactly as it
            # does for one that is not there.
            cstate=noaccess; astate=noaccess; gstate=noaccess
        else
            read_file "$path/compose.yml";      cstate=$STATE; cdata=$DATA
            read_file "$path/versions.log";     astate=$STATE; adata=$DATA
            read_file "$path/versions.log.gz";  gstate=$STATE; gdata=$DATA
        fi

        [ -n "$cdata" ] || cdata=-
        [ -n "$adata" ] || adata=-
        [ -n "$gdata" ] || gdata=-
        rows="$rows$(printf '%s %s %s %s %s %s %s' \
            "$(printf '%s' "$name" | b64)" \
            "$cstate" "$cdata" "$astate" "$adata" "$gstate" "$gdata")
"
    done
fi
kv project_count "$count"
kv projects_b64 "$(printf '%s' "$rows" | b64)"

exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the prune probe on $_PR_TARGET exited $rc"
        err_cont "nothing was removed — prune reads the whole server before it deletes anything"
        exit 1
    fi

    _prune_absorb_checked "$out" \
        pointer_state pointer_value apps_path apps_source now_month \
        have_docker docker_error apps_state marker_state marker_b64 \
        images_b64 containers_b64 project_count projects_b64
    return 0
}

# --- What the probe said -------------------------------------------------------------

_prune_resolve_apps_path() {
    local apps="${_PR_FACT[apps_path]}" source="${_PR_FACT[apps_source]}"

    # Every refusal below is about a record prune was going to *use*, and none of
    # them guesses $KASBAH_DEFAULT_APPS_PATH instead: reading the default tree on a pointer
    # kasbah could not read would aim a deletion at a server that lives
    # elsewhere. The recovery is the one docs/cli.md prescribes for exit 4 —
    # find the tree read-only, then repair the pointer.
    case "${_PR_FACT[pointer_state]}" in
        notfile|unreadable|unreachable)
            err "$KASBAH_APPS_POINTER on $_PR_TARGET cannot be read — the probe called it '${_PR_FACT[pointer_state]}'"
            err_cont "that path is the server's record of where it was prepared, and it is what prune"
            err_cont "reads. Reading $KASBAH_DEFAULT_APPS_PATH on that answer could delete images belonging to a"
            err_cont "different server's layout, so prune stops here."
            err_cont "Find the tree with \`kasbah server status $_PR_TARGET --apps-path=<dir>\`, which changes"
            err_cont "nothing, then repair the pointer — it is world-readable by contract and"
            err_cont "\`kasbah server init\` rewrites it as root."
            exit 1
            ;;
        present)
            case "${_PR_FACT[pointer_value]}" in
                /?*) ;;
                *)
                    err "$KASBAH_APPS_POINTER on $_PR_TARGET holds '${_PR_FACT[pointer_value]}', which is not an absolute path"
                    err_cont "prune will not fall back to $KASBAH_DEFAULT_APPS_PATH on a pointer it cannot believe."
                    err_cont "Find the tree with \`kasbah server status $_PR_TARGET --apps-path=<dir>\`, then repair the"
                    err_cont "pointer with \`kasbah server init\`."
                    exit 1
                    ;;
            esac
            ;;
    esac

    case $apps in
        /?*) ;;
        *) die "the prune probe on $_PR_TARGET reported apps_path='$apps', which is not an absolute path" ;;
    esac
    case $source in
        pointer|default) ;;
        *) die "the prune probe on $_PR_TARGET reported apps_source='$source', which this kasbah does not know" ;;
    esac

    _PR_APPS_PATH="$apps"
    _PR_APPS_SOURCE="$source"
    return 0
}

# Docker, the apps path and the marker, in that order: each one makes the next
# question meaningless. Exit 4 for "this is not a prepared server" is the same
# verdict `server status` and `deploy` reach, and for the same reason it never
# prints a bare `kasbah server init` — pointed at the wrong apps path that
# command recreates the running proxy and takes every site down.
_prune_check_server() {
    local _pr_marker=""
    if [ "${_PR_FACT[have_docker]}" != yes ] || [ -n "${_PR_FACT[docker_error]}" ]; then
        err "docker did not answer on $_PR_TARGET"
        [ -z "${_PR_FACT[docker_error]}" ] || err_cont "${_PR_FACT[docker_error]}"
        err_cont "prune has nothing to read and has removed nothing"
        exit 1
    fi
    case "${_PR_FACT[apps_state]}" in
        dir) ;;
        notdir) die "$_PR_APPS_PATH on $_PR_TARGET is not a directory" ;;
        *)
            err "$_PR_APPS_PATH on $_PR_TARGET is not there"
            err_cont "that is where prune looked for projects (${_PR_APPS_SOURCE}); nothing was removed"
            exit "$KASBAH_EXIT_NO_REMOTE_STATE"
            ;;
    esac
    if [ "${_PR_FACT[marker_state]}" != present ]; then
        err "$_PR_TARGET has no readable server marker at $_PR_APPS_PATH/.kasbah/server.json"
        err_cont "(the probe called it '${_PR_FACT[marker_state]}'.) prune deletes images, and it will not"
        err_cont "do that on a host it cannot tell is a kasbah server. Two situations with"
        err_cont "different answers:"
        err_cont "  * the server has never been prepared — there is nothing here to prune."
        err_cont "  * it is prepared somewhere else, and $KASBAH_APPS_POINTER does not say so."
        err_cont "    Find the tree with \`kasbah server status $_PR_TARGET --apps-path=<dir>\`, which"
        err_cont "    changes nothing, then repair the pointer with \`kasbah server init\`."
        exit "$KASBAH_EXIT_NO_REMOTE_STATE"
    fi

    # The bind-mount root, which is a directory under the apps path whenever
    # --data-path put it there and is *not* one of the fixed reserved names. It
    # is dropped from the project list in _prune_decode_projects — reported as a
    # project it would be skipped on every run, which prints the "skipped whole"
    # warning permanently and trains the operator to ignore the one signal this
    # command has. `server status` drops the same row from the same fact; two
    # commands walking one tree two ways is the drift the shared reserved list
    # exists to prevent, and the marker is the other half of that list.
    _PR_MARKER_DATA=""
    _prune_b64_field "${_PR_FACT[marker_b64]:--}" _pr_marker \
        || die "the prune probe on $_PR_TARGET sent the server marker as something that is not base64"
    yaml_get "$_pr_marker" '.data_path // ""' _PR_MARKER_DATA \
        || die "$_PR_APPS_PATH/.kasbah/server.json on $_PR_TARGET does not parse — prune will not decide a deletion against a marker it cannot read"
    return 0
}

_prune_decode_images() {
    local table row id created tag rest line state name

    _PR_CREATED=()
    _PR_ID_TAGS=()
    _PR_TAG_ID=()
    _PR_HELD=()

    _prune_b64_field "${_PR_FACT[images_b64]:--}" table \
        || die "the prune probe on $_PR_TARGET sent an image table that is not base64"
    while IFS= read -r row; do
        row="${row%$'\r'}"
        [ -n "$row" ] || continue
        read -r id created rest <<<"$row"
        [ -n "$id" ] && [ -n "$created" ] \
            || die "the prune probe on $_PR_TARGET returned an image row it did not build: '$row'"
        _PR_CREATED[$id]="$created"
        _PR_ID_TAGS[$id]=" "
        for tag in $rest; do
            _PR_ID_TAGS[$id]="${_PR_ID_TAGS[$id]}$tag "
            # A tag names one image. Docker cannot hold the same tag twice, so a
            # repeat here is a truncated read, not a state.
            _PR_TAG_ID[$tag]="$id"
        done
    done <<<"$table"

    _prune_b64_field "${_PR_FACT[containers_b64]:--}" table \
        || die "the prune probe on $_PR_TARGET sent a container table that is not base64"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        read -r id state name rest <<<"$line"
        [ -n "$id" ] || continue
        [ -n "$state" ] || state=unknown
        _PR_HELD[$id]="${_PR_HELD[$id]:-}${name#/}($state) "
    done <<<"$table"
    return 0
}

_prune_decode_projects() {
    local table row name_b64 cstate cdata astate adata gstate gdata rest
    local name compose described=0 data_dir=""

    # Only a direct child of the apps path is one of the entries the walk saw,
    # which is the same test `server status` applies to the same value.
    case "$_PR_MARKER_DATA" in
        "$_PR_APPS_PATH"/?*)
            data_dir="${_PR_MARKER_DATA#"$_PR_APPS_PATH"/}"
            case $data_dir in */*) data_dir="" ;; esac
            ;;
    esac

    _PR_P_NAME=()
    _PR_P_COMPOSE_STATE=()
    _PR_P_COMPOSE=()
    _PR_P_ACTIVE_STATE=()
    _PR_P_ACTIVE_B64=()
    _PR_P_ARCHIVE_STATE=()
    _PR_P_ARCHIVE_B64=()

    _prune_b64_field "${_PR_FACT[projects_b64]:--}" table \
        || die "the prune probe on $_PR_TARGET sent a project table that is not base64"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read -r name_b64 cstate cdata astate adata gstate gdata rest <<<"$row"
        if [ -z "$name_b64" ] || [ -z "$cstate" ] || [ -z "$cdata" ] || [ -z "$astate" ] \
           || [ -z "$adata" ] || [ -z "$gstate" ] || [ -z "$gdata" ] || [ -n "$rest" ]; then
            err "the prune probe on $_PR_TARGET returned a project row it did not build: '$row'"
            exit 1
        fi
        described=$((described + 1))
        _vlog_b64_decode "$name_b64" name \
            || die "the prune probe on $_PR_TARGET sent a project name that is not base64: '$name_b64'"
        _prune_b64_field "$cdata" compose \
            || die "the prune probe on $_PR_TARGET sent $name's compose.yml as something that is not base64"
        # After `described`, because the far side counted it too.
        if [ -n "$data_dir" ] && [ "$name" = "$data_dir" ]; then
            continue
        fi

        _PR_P_NAME+=("$name")
        _PR_P_COMPOSE_STATE+=("$cstate")
        _PR_P_COMPOSE+=("$compose")
        _PR_P_ACTIVE_STATE+=("$astate")
        _PR_P_ACTIVE_B64+=("$adata")
        _PR_P_ARCHIVE_STATE+=("$gstate")
        _PR_P_ARCHIVE_B64+=("$gdata")
    done <<<"$table"

    # The count and the table are two statements about the same walk, so a
    # disagreement means one of them was truncated in transit.
    if [ "$described" != "${_PR_FACT[project_count]}" ]; then
        err "the prune probe on $_PR_TARGET counted ${_PR_FACT[project_count]} projects and described $described"
        err_cont "the payload was truncated — nothing was removed"
        exit 1
    fi
    return 0
}

# --- What a project's images are ------------------------------------------------------

# The image repositories a project builds, out of the compose.yml the server
# holds: every service with a `build:` key, and the `image:` it names with its
# tag stripped. That is the same definition `build-push` uses to decide what to
# tag and ship (docs/build-deploy.md → project shape is derived from compose),
# and it is what keeps a stock image out of the candidate set by construction —
# `redis:7-alpine` has no `build:`, so `redis` is nobody's repository and no tag
# of it can ever be a candidate.
#
# Returns 1 when the file does not parse, which is a skip and not an empty set.
_prune_project_repos() {
    local _pr_content="$1" _pr_out="$2" _pr_val="" _pr_rc=0 _pr_image _pr_base
    local _pr_acc=" "

    printf -v "$_pr_out" '%s' " "
    [ -n "$_pr_content" ] || return 1
    yaml_get "$_pr_content" \
        '[ (.services // {}) | to_entries[]
           | select(.value | type == "object")
           | select(.value | has("build"))
           | (.value.image // "") ]
         | map(select(. != "" and . != null)) | .[]' _pr_val || _pr_rc=$?
    [ "$_pr_rc" -eq 0 ] || return 1

    while IFS= read -r _pr_image; do
        _pr_image="${_pr_image%$'\r'}"
        [ -n "$_pr_image" ] || continue
        image_base "$_pr_image" _pr_base
        case $_pr_acc in *" $_pr_base "*) continue ;; esac
        _pr_acc="$_pr_acc$_pr_base "
    done <<<"$_pr_val"

    printf -v "$_pr_out" '%s' "$_pr_acc"
    return 0
}

# The last three distinct versions this project deployed, newest first, out of
# the record already loaded into the VLOG_* arrays. Every entry counts, deploy
# and rollback alike: a rollback entry naming a version is proof that version
# ran here, exactly as a deploy entry is (lib/versions_log.sh → vlog_find_version).
#
# Returns 1 when the walk had to step over a line the parser could not read
# before it had its three — a truncated line may name a version that belongs in
# the keep set, and there is no way to tell from here. Returns 1 too when the
# record holds nothing at all: "this project has never deployed here" and "the
# three newest versions are these" are different answers, and deleting on the
# first is deleting on the absence of a record.
_prune_keep_versions() {
    local _kv_out="$1" _kv_i _kv_v _kv_acc=" " _kv_n=0

    printf -v "$_kv_out" '%s' " "
    for (( _kv_i = ${#VLOG_SRC[@]} - 1; _kv_i >= 0; _kv_i-- )); do
        [ "$_kv_n" -lt 3 ] || break
        [ "${VLOG_OK[$_kv_i]}" = yes ] || return 1
        _kv_v="${VLOG_VERSION[$_kv_i]}"
        [ -n "$_kv_v" ] || return 1
        case $_kv_acc in *" $_kv_v "*) continue ;; esac
        _kv_acc="$_kv_acc$_kv_v "
        _kv_n=$((_kv_n + 1))
    done
    [ "$_kv_n" -gt 0 ] || return 1
    printf -v "$_kv_out" '%s' "$_kv_acc"
    return 0
}

# --- The plan --------------------------------------------------------------------------

_prune_plan() {
    local i j name repos repo cutoff nowidx keep tags tag version id
    local created idx why other owners owners_show keep_show verdict cur_id note
    local unknown_show=

    _PR_LINE_PROJ=()
    _PR_LINE_TAG=()
    _PR_LINE_VERDICT=()
    _PR_LINE_WHY=()
    _PR_REMOVE=()
    _PR_SKIP_NAME=()
    _PR_SKIP_WHY=()
    _PR_P_REPOS=()
    _PR_P_REPOS_OK=()
    _PR_REPO_OWNER=()
    _PR_UNKNOWN_OWNER=()

    _prune_month_index "${_PR_FACT[now_month]}-01" nowidx \
        || die "the prune probe on $_PR_TARGET reported now_month='${_PR_FACT[now_month]}', which is not YYYY-MM"
    cutoff=$(( nowidx - 3 ))

    # Ownership first, over every project including the ones about to be
    # skipped: a repository two projects claim is one no single project's record
    # is evidence about.
    #
    # **A project whose compose.yml kasbah cannot read, or cannot parse, is not
    # a project that claims nothing.** Reading it that way would defeat the
    # multi-owner guard with the very condition that triggers the skip: the
    # project vanishes from the ownership map, its neighbour's repository looks
    # single-owner, and that neighbour's record then authorises a deletion of a
    # tag the unreadable project may well have been holding for a rollback. It
    # cost the review a reproduction where prune printed "omega: its compose.yml
    # cannot be read" and removed `shared-web:1.0.0` four lines later.
    #
    # There is no way to narrow "what it might have claimed": the file that
    # would say is the file kasbah could not read, and image names are not
    # derivable from the project's name (docs/build-deploy.md — the image is
    # whatever `image:` says). So the honest reading is the whole server —
    # while one project's declarations are unknown, a repository with one known
    # claimant may have a second, and nothing is provably single-owner. Prune
    # removes nothing anywhere, says so in its own sentence, and names the
    # project to fix. That is deliberately a cliff rather than a heuristic: the
    # alternative is a guess about which repositories a file kasbah never read
    # might have named.
    for i in "${!_PR_P_NAME[@]}"; do
        name="${_PR_P_NAME[$i]}"
        repos=" "
        if [ "${_PR_P_COMPOSE_STATE[$i]}" = ok ] \
           && _prune_project_repos "${_PR_P_COMPOSE[$i]}" repos; then
            _PR_P_REPOS_OK+=(yes)
        else
            _PR_P_REPOS_OK+=(no)
            repos=" "
            _PR_UNKNOWN_OWNER+=("$name")
        fi
        _PR_P_REPOS+=("$repos")
        for repo in $repos; do
            _PR_REPO_OWNER[$repo]="${_PR_REPO_OWNER[$repo]:- }$name "
        done
    done
    unknown_show="${_PR_UNKNOWN_OWNER[*]-}"

    for i in "${!_PR_P_NAME[@]}"; do
        name="${_PR_P_NAME[$i]}"

        # The record, read through the same parser and judged by the same
        # states `history` judges it by — then declined on anything short of
        # whole. Order matters only in what the operator is told; every branch
        # here leaves the project untouched.
        if ! vlog_active_usable "${_PR_P_ACTIVE_STATE[$i]}"; then
            _prune_skip "$name" "its versions.log cannot be read (the probe called it '${_PR_P_ACTIVE_STATE[$i]}')"
            continue
        fi
        if ! vlog_adopt "$_PR_TARGET" "$_PR_APPS_PATH/$name/versions.log" \
                "${_PR_P_ACTIVE_STATE[$i]}" "${_PR_P_ARCHIVE_STATE[$i]}" \
                "${_PR_P_ACTIVE_B64[$i]}" "${_PR_P_ARCHIVE_B64[$i]}"; then
            _prune_skip "$name" "its versions.log did not come back as base64 from $_PR_TARGET"
            continue
        fi
        if ! vlog_archive_whole; then
            vlog_archive_note note
            _prune_skip "$name" "${note:-$VLOG_ARCHIVE_PATH could not be read}"
            continue
        fi
        if ! _prune_keep_versions keep; then
            _prune_skip "$name" "its deploy record does not yield a keep set — a line the parser could not read among the newest entries, or no entry at all"
            continue
        fi
        # Two different facts, and until the review they were one test on the
        # file's *state*: a compose.yml that opens perfectly and that yq refuses
        # fell through this branch, through the stock-images-only branch below
        # it, and out of the report altogether — no skip line, no count in the
        # warning, and its ownership claim lost as well.
        if [ "${_PR_P_REPOS_OK[$i]}" != yes ]; then
            if [ "${_PR_P_COMPOSE_STATE[$i]}" != ok ]; then
                _prune_skip "$name" "its compose.yml cannot be read (the probe called it '${_PR_P_COMPOSE_STATE[$i]}'), so which images it builds is unknown"
            else
                _prune_skip "$name" "its compose.yml does not parse as YAML, so which images it builds is unknown"
            fi
            continue
        fi
        if [ "${_PR_P_REPOS[$i]}" = " " ]; then
            # Nothing to prune, and nothing wrong: a project of stock images
            # only. Not a skip — there is no evidence missing.
            continue
        fi

        keep_show="${keep# }"; keep_show="${keep_show% }"
        for repo in ${_PR_P_REPOS[$i]}; do
            owners="${_PR_REPO_OWNER[$repo]}"
            owners_show="${owners# }"; owners_show="${owners_show% }"
            cur_id="${_PR_TAG_ID[$repo:current]:-}"
            for tag in "${!_PR_TAG_ID[@]}"; do
                case $tag in
                    "$repo":*) ;;
                    *) continue ;;
                esac
                version="${tag#"$repo":}"
                # `:current` is a pointer, not a version, and it is never a
                # candidate — removing it is removing the project's deployed
                # image by another name.
                [ "$version" != current ] || continue

                id="${_PR_TAG_ID[$tag]}"
                created="${_PR_CREATED[$id]:-}"
                verdict=keep
                why=""

                if [ -n "$cur_id" ] && [ "$id" = "$cur_id" ]; then
                    why=":current points at this image"
                elif [ "$owners" != " $name " ]; then
                    why="$repo is claimed by more than one project ($owners_show)"
                elif [ "${#_PR_UNKNOWN_OWNER[@]}" -gt 0 ]; then
                    why="ownership cannot be established: $unknown_show declare(s) images kasbah could not read, and such a file could name any repository"
                elif [[ "$keep" == *" $version "* ]]; then
                    why="among the last 3 deployed ($keep_show)"
                elif [ -n "${_PR_HELD[$id]:-}" ]; then
                    why="held by container ${_PR_HELD[$id]% }"
                elif [ -z "$created" ]; then
                    why="the probe reported no creation time for it"
                elif ! _prune_month_index "$created" idx; then
                    why="its creation time '$created' is not a date prune can read"
                elif [ "$idx" -ge "$cutoff" ]; then
                    why="built ${created:0:10}, inside the 3-month window"
                else
                    verdict=remove
                    why="built ${created:0:10}, older than 3 months and not among the last 3 deployed ($keep_show)"
                    # Honest about what the removal costs: an image carrying
                    # another tag loses only this name.
                    other=""
                    for j in ${_PR_ID_TAGS[$id]}; do
                        [ "$j" != "$tag" ] || continue
                        other="$other$j "
                    done
                    [ -z "$other" ] || why="$why — untags only, the image also carries ${other% }"
                fi

                _PR_LINE_PROJ+=("$name")
                _PR_LINE_TAG+=("$tag")
                _PR_LINE_VERDICT+=("$verdict")
                _PR_LINE_WHY+=("$why")
                [ "$verdict" != remove ] || _PR_REMOVE+=("$tag")
            done
        done
    done
    return 0
}

_prune_skip() {
    _PR_SKIP_NAME+=("$1")
    _PR_SKIP_WHY+=("$2")
    return 0
}

# --- The report -------------------------------------------------------------------------

# Sorted by tag within a project, so two runs against one server print the same
# order: the plan is walked out of an associative array, whose order bash does
# not define.
_prune_report() {
    local i proj tag verdict why last="" lines=() width=0

    printf 'kasbah server prune — %s (%s)\n' "$_PR_TARGET" "$_PR_APPS_PATH"

    for i in "${!_PR_LINE_TAG[@]}"; do
        [ "${#_PR_LINE_TAG[$i]}" -le "$width" ] || width="${#_PR_LINE_TAG[$i]}"
        lines+=("$(printf '%s\t%s\t%s\t%s' \
            "${_PR_LINE_PROJ[$i]}" "${_PR_LINE_TAG[$i]}" \
            "${_PR_LINE_VERDICT[$i]}" "${_PR_LINE_WHY[$i]}")")
    done
    if [ "${#lines[@]}" -gt 0 ]; then
        while IFS=$'\t' read -r proj tag verdict why; do
            [ -n "$proj" ] || continue
            if [ "$proj" != "$last" ]; then
                printf '\n%s\n' "$proj"
                last="$proj"
            fi
            printf '  %-6s %-*s  %s\n' "$verdict" "$width" "$tag" "$why"
        done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2)
    fi

    if [ "${#_PR_SKIP_NAME[@]}" -gt 0 ]; then
        printf '\nskipped — nothing of these was removed\n'
        for i in "${!_PR_SKIP_NAME[@]}"; do
            printf '  %s: %s\n' "${_PR_SKIP_NAME[$i]}" "${_PR_SKIP_WHY[$i]}"
        done
    fi

    if [ "${#_PR_UNKNOWN_OWNER[@]}" -gt 0 ]; then
        printf '\nno repository on %s is provably single-owner: kasbah could not read what\n' "$_PR_TARGET"
        printf 'images %s project(s) declare (%s), and such a file could name any\n' \
            "${#_PR_UNKNOWN_OWNER[@]}" "${_PR_UNKNOWN_OWNER[*]}"
        printf 'repository on this host. Nothing is removed anywhere until that is fixed.\n'
    fi

    printf '\n'
    if [ "${#_PR_REMOVE[@]}" -eq 0 ]; then
        printf 'nothing to remove: every version tag on %s is inside the retention window.\n' \
            "$_PR_TARGET"
    else
        printf '%s tag(s) to remove on %s.\n' "${#_PR_REMOVE[@]}" "$_PR_TARGET"
    fi
    return 0
}

# --- The removal --------------------------------------------------------------------------

_prune_remove() {
    local out rc=0 line key ref reason removed=0 failed=0 tag

    # The tags came off the server's own image table, so a name that could be
    # read as a flag or that carries whitespace is a truncated read rather than
    # a state — and this is the last moment before `docker image rm` sees it.
    for tag in "${_PR_REMOVE[@]}"; do
        case $tag in
            -*|*[[:space:]]*)
                die "refusing to remove '$tag' on $_PR_TARGET: that is not an image tag docker gave back" ;;
        esac
    done

    out=$(ssh_script "${_PR_REMOVE[@]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
b64() { openssl base64 -A 2>/dev/null; }
for ref in "$@"; do
    if out=$(docker image rm "$ref" 2>&1); then
        printf 'removed=%s\n' "$(printf '%s' "$ref" | b64)"
    else
        printf 'failed=%s %s\n' "$(printf '%s' "$ref" | b64)" \
               "$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | b64)"
    fi
done
exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "the removal step on $_PR_TARGET exited $rc"
        err_cont "some of the ${#_PR_REMOVE[@]} tags may have been removed — \`kasbah server prune $_PR_TARGET\` again to see"
        exit 1
    fi

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        key="${line%%=*}"
        case $key in
            removed)
                _vlog_b64_decode "${line#*=}" ref || ref="?"
                removed=$((removed + 1))
                printf '  removed %s\n' "$ref"
                ;;
            failed)
                line="${line#*=}"
                _vlog_b64_decode "${line%% *}" ref || ref="?"
                _vlog_b64_decode "${line#* }" reason || reason="(no reason given)"
                failed=$((failed + 1))
                err "could not remove $ref on $_PR_TARGET: $reason"
                ;;
        esac
    done <<<"$out"

    if [ "$(( removed + failed ))" -ne "${#_PR_REMOVE[@]}" ]; then
        err "the removal step on $_PR_TARGET accounted for $(( removed + failed )) of ${#_PR_REMOVE[@]} tags"
        err_cont "the step was truncated; run prune again to see what is left"
        exit 1
    fi
    info "removed $removed of ${#_PR_REMOVE[@]} tag(s) on $_PR_TARGET"
    [ "$failed" -eq 0 ] || exit 1
    return 0
}

# --- The command ---------------------------------------------------------------------------

cmd_server_prune() {
    _server_prune_parse_args "$@"
    command -v yq >/dev/null \
        || die "yq is required (each project's compose.yml is parsed here, never on the server)"

    ssh_connect "$_PR_TARGET"

    _prune_collect
    _prune_resolve_apps_path
    _prune_check_server
    _prune_decode_images
    _prune_decode_projects
    _prune_plan
    _prune_report

    if [ "${#_PR_SKIP_NAME[@]}" -gt 0 ]; then
        warn "${#_PR_SKIP_NAME[@]} project(s) were skipped whole — see the report above"
        warn "  kasbah does not remove images on a record it could not read"
    fi
    if [ "${#_PR_UNKNOWN_OWNER[@]}" -gt 0 ]; then
        warn "nothing was removed anywhere: ${_PR_UNKNOWN_OWNER[*]} declare images kasbah could"
        warn "  not read, so no repository on this server is provably single-owner"
    fi
    [ "${#_PR_REMOVE[@]}" -gt 0 ] || return 0

    prompt_confirm yes \
        "remove ${#_PR_REMOVE[@]} image tag(s) from $_PR_TARGET?" "$_PR_YES"

    _prune_remove
    return 0
}
