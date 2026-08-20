# kasbah — renders templates/remote-deploy.sh for one project
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_REMOTE_DEPLOY_LOADED:-}" ] && return 0
_KASBAH_REMOTE_DEPLOY_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
# One definition of "which images this project builds", and it is build-push's:
# what deploy retags has to be exactly what build-push tagged, down to the
# registry-with-a-port case in an image name (_bp_image_base). The load guards
# make the cycle through deploy.sh a no-op, and build_push.sh already sources
# deploy.sh for the same kind of reason — one version contract.
. "$KASBAH_LIB_DIR/build_push.sh"

# The VPS side of a deploy or a rollback needs the manifest's hooks, backup and
# health blocks, and a server has no yq: kasbah's is the kislyuk wrapper, a
# Python package, and the manifest is deliberately not in any project's sync:
# list — "a second copy to drift" (docs/project-manifest.md). So there is
# nothing on the far side to parse and nothing to parse it with.
#
# The local side therefore pre-renders the manifest's data into the script it
# ships, as a block of plain bash assignments between two frozen markers. The
# rest of templates/remote-deploy.sh travels byte for byte, which is what keeps
# the shipped file readable — and runnable — by a person debugging on the server
# with no kasbah installed (docs/phases/04-ship.md → Findings).

# Frozen strings: the renderer finds the block by them, and a person reading the
# script on a server has to be able to tell generated lines from kasbah's own.
REMOTE_DEPLOY_BEGIN='# >>> kasbah generated block - rendered from kasbah.yml on every deploy, do not edit >>>'
REMOTE_DEPLOY_END='# <<< kasbah generated block <<<'

# Filled by remote_deploy_read_manifest, consumed by remote_deploy_render. At
# file scope because `declare` inside a function is local (docs/phases/03-env.md).
_RD_IMAGES=()
_RD_HOOKS_PRE_DEPLOY=()
_RD_HOOKS_POST_DEPLOY=()
_RD_HOOKS_PRE_ROLLBACK=()
_RD_HOOKS_POST_ROLLBACK=()
_RD_HOOKS=()             # scratch, one hook list at a time
_RD_HEALTH_CONTAINER=""
_RD_HEALTH_TIMEOUT=120
_RD_BACKUP_CHECK=""
_RD_BACKUP_CONTAINER=""
_RD_BACKUP_COMMAND=""
_RD_BACKUP_PIPE=""
_RD_BACKUP_EXTENSION=""
_RD_BACKUP_RETAIN=10

# --- Reading the manifest ---------------------------------------------------------

# No manifest value may carry either marker. It would still parse — every value
# is rendered inside single quotes — but the whole pre-rendering decision rests
# on a reader being able to tell generated lines from kasbah's own, and a marker
# at column 0 inside the block also breaks every reader that takes the block as
# a sed range, this repo's own rig suite included.
_rd_guard_markers() {
    local _gm_what="$1" _gm_v="$2"
    case "$_gm_v" in
        *"# >>> kasbah generated block"*|*"# <<< kasbah generated block"*)
            die "kasbah.yml: $_gm_what contains one of remote-deploy.sh's generated-block markers, which would make the shipped script unreadable — remove it" ;;
    esac
    return 0
}

# One manifest scalar, trimmed, with yq's `null` folded to the empty string —
# an absent key and an explicitly-null one mean the same thing here.
_rd_str() {
    local _s_path="$1" _s_out="$2" _s_v
    _s_v="$(manifest_get "$_s_path // \"\"")"
    _s_v="${_s_v%$'\r'}"
    [ "$_s_v" != null ] || _s_v=""
    _s_v="${_s_v#"${_s_v%%[![:space:]]*}"}"
    _s_v="${_s_v%"${_s_v##*[![:space:]]}"}"
    _rd_guard_markers "$_s_path" "$_s_v"
    printf -v "$_s_out" '%s' "$_s_v"
    return 0
}

# One hook list into _RD_HOOKS. Each entry is validated here rather than on the
# server: a hook naming no command is a manifest mistake, and finding it out
# after the backup has run and the images have been retagged is finding it out
# in the worst possible place.
#
# Read one entry at a time rather than as one newline-separated dump, which is
# the only way to see an entry that *contains* a newline. A block scalar, or a
# quoted value with an embedded newline, otherwise splits into several hooks and
# every continuation line's first word is taken as a container name — so
# `php artisan down && php artisan migrate` written across two lines runs the
# `down`, discards the `migrate` as a hook for a container called `php`, and
# exits 0. A hook is one line whose first word is the container.
_rd_read_hooks() {
    local which="$1" count i line container rest

    _RD_HOOKS=()
    count="$(manifest_get ".hooks[\"$which\"] // [] | length")"
    count="${count%$'\r'}"
    case "$count" in
        ''|*[!0-9]*) die "kasbah.yml: hooks.$which is not a list of strings (yq read its length as '$count')" ;;
    esac

    for (( i = 0; i < count; i++ )); do
        line="$(manifest_get ".hooks[\"$which\"][$i] | tostring")"
        # `$( )` has already stripped any trailing newlines, so one that is left
        # is embedded — the case this loop exists to catch.
        case "$line" in
            *$'\n'*)
                die "kasbah.yml: the $which hook '${line%%$'\n'*}…' spans more than one line — a hook is one line whose first word is the container name, and a multi-line value would be run as several hooks (docs/project-manifest.md)" ;;
        esac
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        [ "$line" != null ] || continue
        _rd_guard_markers "the $which hook '$line'" "$line"

        container="${line%%[[:space:]]*}"
        rest="${line#"$container"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        [ -n "$rest" ] \
            || die "kasbah.yml: the $which hook '$line' names a container and no command — each entry is \"<container> <command…>\" (docs/project-manifest.md)"
        _RD_HOOKS+=("$line")
    done
    return 0
}

# `120s`, `5m`, `2h` or a bare number of seconds. Parsed here rather than on the
# server, so the shipped script carries an integer and a manifest typo stops the
# deploy before anything is shipped instead of during it.
_rd_seconds() {
    local _sec_raw="$1" _sec_out="$2" _sec_n="$1" _sec_mul=1

    case "$_sec_raw" in
        *s) _sec_n="${_sec_raw%s}" ;;
        *m) _sec_n="${_sec_raw%m}"; _sec_mul=60 ;;
        *h) _sec_n="${_sec_raw%h}"; _sec_mul=3600 ;;
    esac
    case "$_sec_n" in
        ''|*[!0-9]*)
            die "kasbah.yml: health.timeout '$_sec_raw' is not a duration kasbah can use — write it as 120s, 5m or 2h" ;;
    esac
    [ "$_sec_n" -gt 0 ] \
        || die "kasbah.yml: health.timeout '$_sec_raw' is zero — a wait of no time at all cannot gate the deploy on health"
    printf -v "$_sec_out" '%s' "$(( _sec_n * _sec_mul ))"
    return 0
}

# The images this project builds, named the way build-push named them: the
# compose `image:` with its tag stripped. The version is appended on the server,
# so the shipped script can be re-run by hand for another version — which is
# what `rollback` mode needs of it too.
#
# `version` is only what _bp_read_built_services labels its own array with; what
# is rendered is the untagged base.
_rd_read_images() {
    local version="$1" i base

    _RD_IMAGES=()
    [ -f "$_BP_COMPOSE" ] \
        || die "$_BP_COMPOSE: not found (cwd=$PWD) — deploy reads the images to retag from the same file \`kasbah build-push\` builds (docs/build-deploy.md)"

    _BP_VERSION="$version"
    _bp_read_built_services

    for i in "${!_BP_SOURCE[@]}"; do
        _bp_image_base "${_BP_SOURCE[$i]}" base
        _RD_IMAGES+=("$base")
    done
    return 0
}

_rd_read_backup() {
    local raw

    _RD_BACKUP_CHECK=""
    _RD_BACKUP_CONTAINER=""
    _RD_BACKUP_COMMAND=""
    _RD_BACKUP_PIPE=""
    _RD_BACKUP_EXTENSION=""
    _RD_BACKUP_RETAIN=10

    raw="$(manifest_get '.backup // null')"
    [ "$raw" != null ] && [ -n "$raw" ] || return 0

    _rd_str '.backup.check'     _RD_BACKUP_CHECK
    _rd_str '.backup.container' _RD_BACKUP_CONTAINER
    _rd_str '.backup.command'   _RD_BACKUP_COMMAND
    _rd_str '.backup.pipe'      _RD_BACKUP_PIPE
    _rd_str '.backup.extension' _RD_BACKUP_EXTENSION
    _rd_str '.backup.retain'    raw

    # The same three fields HK02 requires. Checked again here because a deploy
    # does not run `kasbah check`, and a half-declared backup: block is a
    # promise of a safety net that would not be there.
    [ -n "$_RD_BACKUP_CHECK" ] \
        || die "kasbah.yml: backup: has no check: — it is the command whose exit status decides whether a backup is taken (docs/project-manifest.md)"
    [ -n "$_RD_BACKUP_COMMAND" ] \
        || die "kasbah.yml: backup: has no command: — it is what writes the backup to stdout"
    [ -n "$_RD_BACKUP_EXTENSION" ] \
        || die "kasbah.yml: backup: has no extension: — it names the file backups/pre-deploy-<timestamp>.<extension>"
    [ -n "$_RD_BACKUP_CONTAINER" ] \
        || die "kasbah.yml: backup: has no container: — backup.command runs inside it, as \`docker exec <container> sh -c\`"

    # An extension with a slash or whitespace in it would put the backup
    # somewhere other than backups/, and versions.log carries the path.
    case "$_RD_BACKUP_EXTENSION" in
        */*|*[[:space:]]*)
            die "kasbah.yml: backup.extension '$_RD_BACKUP_EXTENSION' must be a plain filename extension — it lands in backups/pre-deploy-<timestamp>.<extension>, and versions.log's fields are space-delimited" ;;
    esac

    [ -n "$raw" ] || raw=10
    case "$raw" in
        ''|*[!0-9]*) die "kasbah.yml: backup.retain '$raw' is not a whole number of backups to keep" ;;
    esac
    [ "$raw" -gt 0 ] \
        || die "kasbah.yml: backup.retain is 0 — rotation would delete the backup it just took"
    _RD_BACKUP_RETAIN="$raw"
    return 0
}

# Everything the shipped script needs to know about this project, read and
# judged before a single byte is shipped. Run from the project root, after
# manifest_require.
remote_deploy_read_manifest() {
    local version="$1" raw

    _rd_read_images "$version"

    # All four lists, because the shipped script serves both modes and the
    # manifest is the only place any of them exists — it never reaches the
    # server (docs/project-manifest.md → the hook table).
    _rd_read_hooks pre-deploy
    _RD_HOOKS_PRE_DEPLOY=(${_RD_HOOKS[@]+"${_RD_HOOKS[@]}"})
    _rd_read_hooks post-deploy
    _RD_HOOKS_POST_DEPLOY=(${_RD_HOOKS[@]+"${_RD_HOOKS[@]}"})
    _rd_read_hooks pre-rollback
    _RD_HOOKS_PRE_ROLLBACK=(${_RD_HOOKS[@]+"${_RD_HOOKS[@]}"})
    _rd_read_hooks post-rollback
    _RD_HOOKS_POST_ROLLBACK=(${_RD_HOOKS[@]+"${_RD_HOOKS[@]}"})

    _RD_HEALTH_CONTAINER=""
    _RD_HEALTH_TIMEOUT=120
    raw="$(manifest_get '.health // null')"
    if [ "$raw" != null ] && [ -n "$raw" ]; then
        # `container:` is optional. Absent, the wait falls back to every
        # container in the compose project — which is what
        # docs/project-manifest.md already promises `health:` defaults to — so a
        # block carrying only `timeout:` is the way to raise the budget for that
        # path. Refusing it made the documented default unreachable.
        _rd_str '.health.container' _RD_HEALTH_CONTAINER
        _rd_str '.health.timeout' raw
        [ -n "$raw" ] || raw=120s
        _rd_seconds "$raw" _RD_HEALTH_TIMEOUT
    fi

    _rd_read_backup
    return 0
}

# --- Rendering ---------------------------------------------------------------------

# Single-quoted, with embedded quotes closed and reopened. A value with a space,
# a quote, a `$` or a newline in it survives into a bash assignment unchanged,
# and — unlike `printf %q` — the result stays readable to the person who opened
# this file on the server at 2am, which is the property the whole pre-rendering
# decision rests on. Deterministic and locale-independent by construction: the
# only transformation is on the quote character itself.
_rd_quote() {
    local _q_v="$1" _q_out="$2"
    _q_v="${_q_v//\'/\'\\\'\'}"
    printf -v "$_q_out" "'%s'" "$_q_v"
    return 0
}

_rd_emit_scalar() {
    local q
    _rd_quote "$2" q
    printf '%s=%s\n' "$1" "$q"
    return 0
}

_rd_emit_array() {
    local name="$1" v q; shift
    printf '%s=(' "$name"
    for v in "$@"; do
        _rd_quote "$v" q
        printf ' %s' "$q"
    done
    printf ' )\n'
    return 0
}

_rd_emit_block() {
    printf '%s\n' "# Generated by kasbah $KASBAH_VERSION from kasbah.yml. Edit the manifest, not this."
    _rd_emit_array  RD_IMAGES              ${_RD_IMAGES[@]+"${_RD_IMAGES[@]}"}
    _rd_emit_array  RD_HOOKS_PRE_DEPLOY    ${_RD_HOOKS_PRE_DEPLOY[@]+"${_RD_HOOKS_PRE_DEPLOY[@]}"}
    _rd_emit_array  RD_HOOKS_POST_DEPLOY   ${_RD_HOOKS_POST_DEPLOY[@]+"${_RD_HOOKS_POST_DEPLOY[@]}"}
    _rd_emit_array  RD_HOOKS_PRE_ROLLBACK  ${_RD_HOOKS_PRE_ROLLBACK[@]+"${_RD_HOOKS_PRE_ROLLBACK[@]}"}
    _rd_emit_array  RD_HOOKS_POST_ROLLBACK ${_RD_HOOKS_POST_ROLLBACK[@]+"${_RD_HOOKS_POST_ROLLBACK[@]}"}
    _rd_emit_scalar RD_HEALTH_CONTAINER    "$_RD_HEALTH_CONTAINER"
    _rd_emit_scalar RD_HEALTH_TIMEOUT      "$_RD_HEALTH_TIMEOUT"
    _rd_emit_scalar RD_BACKUP_CHECK        "$_RD_BACKUP_CHECK"
    _rd_emit_scalar RD_BACKUP_CONTAINER    "$_RD_BACKUP_CONTAINER"
    _rd_emit_scalar RD_BACKUP_COMMAND      "$_RD_BACKUP_COMMAND"
    _rd_emit_scalar RD_BACKUP_PIPE         "$_RD_BACKUP_PIPE"
    _rd_emit_scalar RD_BACKUP_EXTENSION    "$_RD_BACKUP_EXTENSION"
    _rd_emit_scalar RD_BACKUP_RETAIN       "$_RD_BACKUP_RETAIN"
    return 0
}

# remote_deploy_render <template> <dest> — the template with its generated block
# replaced, everything else byte for byte.
remote_deploy_render() {
    local _rr_src="$1" _rr_dest="$2"
    local _rr_line _rr_begin=0 _rr_end=0

    [ -f "$_rr_src" ] \
        || die "the remote-deploy template is missing (looked in $_rr_src) — this kasbah installation is incomplete"

    # Truncated first, and with a message of its own, because a destination that
    # cannot be written is the ordinary failure here. The group below then
    # carries no `|| die`: a compound command on the left of `||` runs with
    # errexit switched off for its whole body, and a `printf` that failed
    # halfway through would be swallowed into a truncated script that still
    # looks like a successful render (docs/phases/03-env.md).
    : > "$_rr_dest" || die "could not write $_rr_dest"
    {
        while IFS= read -r _rr_line || [ -n "$_rr_line" ]; do
            if [ "$_rr_line" = "$REMOTE_DEPLOY_BEGIN" ]; then
                [ "$_rr_begin" -eq 0 ] \
                    || die "internal: $_rr_src carries more than one generated block"
                _rr_begin=1
                printf '%s\n' "$_rr_line"
                _rd_emit_block
                continue
            fi
            if [ "$_rr_begin" -eq 1 ] && [ "$_rr_end" -eq 0 ]; then
                # The template's own default block, dropped in favour of the one
                # just emitted.
                if [ "$_rr_line" = "$REMOTE_DEPLOY_END" ]; then
                    _rr_end=1
                    printf '%s\n' "$_rr_line"
                fi
                continue
            fi
            printf '%s\n' "$_rr_line"
        done < "$_rr_src"
    } > "$_rr_dest"

    [ "$_rr_begin" -eq 1 ] \
        || die "internal: $_rr_src has no generated-block marker — kasbah cannot render it"
    [ "$_rr_end" -eq 1 ] \
        || die "internal: $_rr_src opens a generated block and never closes it"
    return 0
}
