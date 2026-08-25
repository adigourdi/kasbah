# kasbah — rollback, and the tagged half of deploy
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_ROLLBACK_LOADED:-}" ] && return 0
_KASBAH_ROLLBACK_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/deploy.sh"
. "$KASBAH_LIB_DIR/versions_log.sh"

# `kasbah rollback [USER@HOST] [VERSION]` puts a server back on a version it
# has already run, and `kasbah deploy USER@HOST X.Y.Z` puts one on a tagged
# version for the first time. They are one command with two modes
# (docs/build-deploy.md → `kasbah rollback`, and → deploy's two modes): the log
# entry is `deploy` or `rollback`, the shipped script runs that mode's hook
# pair, and only a rollback insists the target already appears in the record.
#
# **The invariant is the whole point.** Manifest, compose file, sync list, image
# set and Traefik fragment all come from the `v<target>` ref — never from HEAD,
# whose compose may build a service that version never had. So the ref is
# extracted into a temp directory first, and everything downstream reads from
# there: `KASBAH_MANIFEST_FILE` and `_BP_COMPOSE` are pointed at the extracted
# copies, and the sync itself runs with the extraction as the working directory.
#
# What is *not* the ref's: the two helper scripts, which belong to the installed
# kasbah rather than to the project's history, and `.env`, which is not in git
# at all — v<target>'s template may declare different keys, and the ordinary
# drift detection is what asks about them.
#
# Shipping goes through deploy's own functions rather than `git archive |
# ssh tar -x`, which the spec's earlier drafts called for: `git archive` has no
# rename, and `compose.prod.yml -> compose.yml` is in every kasbah project's
# sync list by necessity. A tar stream would leave the previous deploy's
# compose.yml in place and bring the stack up on HEAD-era compose against
# v<target>'s images — silently.

# The mode, and the version this run is about. `_DEPLOY_VERSION` carries the
# same value, because every function borrowed from lib/deploy.sh reads it.
_ROLLBACK_MODE=""
_ROLLBACK_VERSION=""
# Where v<target> is unpacked, and the project root it must never be confused
# with: state and git both belong to the root, the sync list to the extraction.
_ROLLBACK_LSTREE=""
_ROLLBACK_EXTRACT=""
_ROLLBACK_ROOT=""

# The fragment's name in a project tree, taken from _DEPLOY_FRAGMENT before that
# is repointed at the extracted copy: kasbah owns the path it lands on, so it is
# never in the sync list and has to be extracted by name (docs/traefik.md).
_ROLLBACK_FRAGMENT_NAME=""
_ROLLBACK_HAS_FRAGMENT=no
# Every sync: source at the ref, deduplicated — the pathspec list `git archive`
# is given, and the list checked against what it produced.
_ROLLBACK_PATHS=()

_rollback_usage() {
    cat <<EOF
Usage: kasbah rollback [USER@HOST] [VERSION] [--on-drift=setup|continue|abort]
                       [--skip-hooks] [--no-health-wait] [--allow-stopped]

Puts a server back on a version it has already run. Run from the project root.
An argument containing '@' is the server, anything else is the version.

VERSION defaults to the second-most-recent deploy in the server's versions.log
(the archive included). USER@HOST defaults to the last server this project
deployed to (.kasbah/state.json).

Everything shipped comes from the v<VERSION> git tag, never from the working
tree, which is neither read nor touched:
  * <VERSION>'s own manifest decides what is synced, and its compose file which
    images are retagged — a service HEAD builds and <VERSION> did not is not
    part of this rollback
  * each of those images must still be on the server as :<VERSION>; kasbah
    never re-ships one (docs/build-deploy.md → Retention)
  * scripts/remote-deploy.sh rollback <VERSION> on the server: pre-rollback
    hooks, retag <image>:current, docker compose -p <name> up -d
    --remove-orphans, health wait, post-rollback hooks, one versions.log entry
  * <VERSION>'s traefik-dynamic.yml, last, once the stack is up

Not restored: .env values (not in git — drift is prompted for as usual), data
bind mounts, and anything provisioned outside this project.

Flags:
  --on-drift=setup      re-run the interactive setup when .env has drifted
  --on-drift=continue   roll back against the .env as it stands
  --on-drift=abort      stop, changing nothing
Unset, a drifting .env asks; with no terminal to ask on, the run stops (exit 5).

Passed straight through to scripts/remote-deploy.sh on the server:
  --skip-hooks          skip the pre- and post-rollback hooks
  --no-health-wait      bring the stack up without blocking on its health
  --allow-stopped       roll back over a stack that is not running, which is
                        otherwise refused

See docs/build-deploy.md.
EOF
}

# --- Command line ---------------------------------------------------------------

_rollback_parse_args() {
    _DEPLOY_TARGET=""
    _DEPLOY_ON_DRIFT=""
    _DEPLOY_SKIP_HOOKS=no
    _DEPLOY_NO_HEALTH_WAIT=no
    _DEPLOY_ALLOW_STOPPED=no
    _DEPLOY_VERSION_ARG=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _rollback_usage; exit 0 ;;
            --skip-hooks)     _DEPLOY_SKIP_HOOKS=yes ;;
            --no-health-wait) _DEPLOY_NO_HEALTH_WAIT=yes ;;
            --allow-stopped)  _DEPLOY_ALLOW_STOPPED=yes ;;
            --skip-hooks=*|--no-health-wait=*|--allow-stopped=*)
                die "rollback: ${1%%=*} takes no value — pass it on its own (\`kasbah rollback USER@HOST ${1%%=*}\`)" ;;
            --on-drift=*)
                _DEPLOY_ON_DRIFT="${1#*=}"
                env_on_drift_check rollback "$_DEPLOY_ON_DRIFT"
                ;;
            --on-drift)
                die "rollback: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort" ;;
            -*) die "rollback: unknown flag '${1%%=*}' (rollback takes USER@HOST, VERSION, --on-drift=, --skip-hooks, --no-health-wait and --allow-stopped)" ;;
            *)  _deploy_classify_arg rollback "$1" ;;
        esac
        shift
    done
    return 0
}

# --- The target version -----------------------------------------------------------

# The second-latest `action=deploy` entry, across the active log and the
# archive: a project that deploys less often than the three-month rotation would
# otherwise have no implicit target at all (docs/build-deploy.md → rollback
# flow, step 2). The image check further down is what refuses a target too old
# to still be on the server.
#
# Described as what it is rather than as where it sits: when the newest entry is
# itself a rollback, the second-most-recent deploy can be the version running
# now, and calling that "the deploy before the current one" would be wrong.
_rollback_implicit_target() {
    local idx="" damaged=0 note=""

    if vlog_prev_deploy idx; then
        damaged="$VLOG_SKIPPED_DAMAGED"
        _ROLLBACK_VERSION="${VLOG_VERSION[$idx]}"
        info "rolling back to $_ROLLBACK_VERSION — the second-most-recent \`deploy\` entry in $_DEPLOY_TARGET's record (${VLOG_TS[$idx]})"
        # A line no version can be read out of is what a `printf >>` killed
        # mid-append leaves, and it is still a deploy that ran: stepped over, it
        # makes the deploy before it the target — one version too far back,
        # chosen silently. The count is the only thing that can say so, and it
        # is a count over the whole record, so it names both files.
        if [ "$damaged" != 0 ]; then
            warn "$MANIFEST_NAME's record on $_DEPLOY_TARGET has $damaged line(s) no version can be read"
            warn "  out of — counted across $VLOG_ACTIVE_PATH and $VLOG_ARCHIVE_PATH — and they were"
            warn "  stepped over to reach $_ROLLBACK_VERSION. A truncated write leaves exactly that, and the"
            warn "  deploy it recorded is still a deploy that ran, so"
            warn "  this target may be one version further back than it should be"
            warn "  read both files before letting this rollback stand"
        fi
        # Only when the walk had to reach the archive to find this target, and
        # then only if the archive is short: rotation moves entries out and
        # never in, so a target found in the active log cannot be displaced by
        # anything the archive is missing. Found *in* a half-read archive, it
        # can — the entries a truncated member swallows are the newest archived
        # ones, which are exactly the ones that would have come first.
        if [ "${VLOG_SRC[$idx]}" = archive ]; then
            vlog_archive_note note
            [ -z "$note" ] || {
                warn "$note"
                warn "  and $_ROLLBACK_VERSION was read out of it, so a nearer deploy may be among the"
                warn "  entries that could not be decoded"
            }
        fi
        return 0
    fi
    damaged="$VLOG_SKIPPED_DAMAGED"

    # The headline stops short of the whole record whenever part of it was not
    # read: "there is none" and "there is none in what I could read" are the two
    # answers an operator acts on differently.
    if [ "$damaged" = 0 ] && vlog_archive_whole; then
        err "there is no earlier deploy of $MANIFEST_NAME on $_DEPLOY_TARGET to roll back to"
    else
        err "there is no earlier deploy of $MANIFEST_NAME on $_DEPLOY_TARGET in what kasbah could read of its record"
    fi
    [ "$damaged" = 0 ] \
        || err_cont "$damaged line(s) of that record could not be read, and any of them may be one"
    # Which files "the record" turned out to mean: naming the archive when
    # nothing came out of it is the same sentence arguing with the note below.
    if vlog_has_entries all; then
        if vlog_has_entries archive; then
            err_cont "$VLOG_ACTIVE_PATH and its archive hold entries, but not two \`deploy\` ones —"
        else
            err_cont "$VLOG_ACTIVE_PATH holds entries, but not two \`deploy\` ones —"
        fi
        err_cont "a rollback needs a version this server ran before the one it runs now"
    elif vlog_archive_whole; then
        err_cont "$VLOG_ACTIVE_PATH holds no entry for this project at all, so nothing was ever"
        err_cont "deployed here to go back to"
    else
        # "Nothing was ever deployed here" is a claim about both files, and one
        # of them was never read. Asserting it anyway is the guard that fails
        # open, one layer up from where vlog_fetch refuses it.
        err_cont "$VLOG_ACTIVE_PATH holds no entry for this project, and"
        err_cont "whether its archive holds one cannot be told — this is not evidence that"
        err_cont "$_DEPLOY_TARGET has never deployed it"
    fi
    vlog_archive_note note
    [ -z "$note" ] || err_cont "$note"
    err_cont "name a version if you know one:  kasbah rollback $_DEPLOY_TARGET <X.Y.Z>"
    exit 1
}

# Step 3, and the refusal that separates a rollback from a first-time deploy.
#
# *Any* entry naming the version counts, whatever its action: a version deployed
# once and rolled back to twice has a `rollback` line as its most recent
# mention, and refusing that would refuse the commonest rollback there is.
_rollback_require_deployed() {
    local idx="" damaged=0 note=""

    vlog_find_version "$_ROLLBACK_VERSION" idx && return 0
    damaged="$VLOG_SKIPPED_DAMAGED"

    # "Never deployed here" is a claim about the whole record, and two things
    # leave part of it unseen: a line this side could not read, and an archive
    # that did not come back whole — which is where a target old enough to be
    # worth rolling back to has aged to. Asserting the absence anyway
    # recommends a *deploy*, which takes a backup and runs the deploy hooks over
    # a version that has already run here.
    if [ "$damaged" != 0 ] || ! vlog_archive_whole; then
        err "Version $_ROLLBACK_VERSION is not in what kasbah could read of this VPS's deploy record,"
        err_cont "and part of that record could not be read."
        [ "$damaged" = 0 ] || {
            err_cont "$damaged line(s) of it could not be read: a truncated write leaves a line no version"
            err_cont "can be read out of, and any of them may be the one naming $_ROLLBACK_VERSION."
        }
        vlog_archive_whole || {
            err_cont "$VLOG_ARCHIVE_PATH did not come back whole, and rotation moves the oldest entries"
            err_cont "into it — which is where an entry naming $_ROLLBACK_VERSION would be by now."
        }
        err_cont "So this is not the same thing as never having deployed it here."
        err_cont "Look at $VLOG_ACTIVE_PATH and $VLOG_ARCHIVE_PATH on $_DEPLOY_TARGET. If $_ROLLBACK_VERSION"
        err_cont "really has never run there, \`kasbah deploy $_DEPLOY_TARGET $_ROLLBACK_VERSION\` is a"
        err_cont "first-time deploy."
        vlog_archive_note note
        [ -z "$note" ] || err_cont "$note"
        exit 1
    fi
    err "Version $_ROLLBACK_VERSION was never deployed to this VPS."
    err_cont "Use \`kasbah deploy $_DEPLOY_TARGET $_ROLLBACK_VERSION\` for a first-time deploy."
    err_cont "(read from $VLOG_ACTIVE_PATH and its rotation archive on $_DEPLOY_TARGET)"
    exit 1
}

# Step 4. The tag may simply not have been fetched yet, so one `git fetch
# --tags` is spent on it unprompted before giving up — announced, because it
# writes to the repository.
_rollback_require_tag() {
    local ref="v$_ROLLBACK_VERSION"

    git rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null 2>&1 && return 0

    warn "this checkout has no tag $ref — fetching tags from the remote"
    if git fetch --tags >&2; then
        git rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null 2>&1 && return 0
    fi

    err "$ref is not a tag in this repository, and \`git fetch --tags\` did not bring it"
    err_cont "$_DEPLOY_TARGET ran $_ROLLBACK_VERSION, so the tag exists somewhere — every file this"
    err_cont "run would ship comes out of it, and there is nothing to ship without it."
    err_cont "fetch it from wherever that version was tagged, then retry."
    exit 1
}

# --- Reading the ref ---------------------------------------------------------------

# One path at the ref, as `blob`, `tree` or empty. `git ls-tree` exits 0 with no
# output for a path it does not have, so the answer is the output and never the
# status — a `git ls-tree … || die` is a check that can never fire.
_rollback_ref_type() {
    local _rt_ref="$1" _rt_path="$2" _rt_out="$3" _rt_line _rt_type=""

    _rt_line="$(git ls-tree "$_rt_ref" -- "$_rt_path")" \
        || die "could not read $_rt_path at $_rt_ref (see git's error above)"
    [ -z "$_rt_line" ] || read -r _ _rt_type _ <<<"$_rt_line"
    printf -v "$_rt_out" '%s' "$_rt_type"
    return 0
}

# One file out of the ref, into the extraction. `git show <ref>:<dir>` prints a
# directory listing and exits 0, so the type is checked rather than the status.
_rollback_extract_blob() {
    local _eb_ref="$1" _eb_path="$2" _eb_dest="$3" _eb_what="$4" _eb_type=""

    _rollback_ref_type "$_eb_ref" "$_eb_path" _eb_type
    case "$_eb_type" in
        blob) ;;
        '')   die "$_eb_ref has no $_eb_path — $_eb_what" ;;
        *)    die "$_eb_path is a $_eb_type at $_eb_ref, not a file" ;;
    esac

    mkdir -p "$(dirname "$_eb_dest")" \
        || die "could not create $(dirname "$_eb_dest")"
    git show "$_eb_ref:$_eb_path" > "$_eb_dest" \
        || die "could not read $_eb_path out of $_eb_ref (see git's error above)"
    return 0
}

# Every sync: entry, against the tree the tag actually holds — before `git
# archive` is asked for any of them, because one pathspec it cannot match exits
# 128 and produces *nothing at all*: the whole extraction dies rather than the
# entry. All the bad ones are reported together, and a type mismatch counts, so
# a directory that became a file between then and now is not extracted as one.
_rollback_check_ref_paths() {
    local ref="$1"
    local i src recurse type
    local seen="" rows=()

    for i in "${!_DEPLOY_SRC[@]}"; do
        src="${_DEPLOY_SRC[$i]}"
        recurse="${_DEPLOY_RECURSE[$i]}"
        case "$seen" in *"|$src|"*) continue ;; esac
        seen="$seen|$src|"

        _rollback_ref_type "$ref" "$src" type
        if [ -z "$type" ]; then
            rows+=("$src — no such path at $ref")
        elif [ "$recurse" = yes ] && [ "$type" != tree ]; then
            rows+=("$src/ — listed with a trailing slash, which means a directory, and at $ref it is a file")
        elif [ "$recurse" = no ] && [ "$type" = tree ]; then
            rows+=("$src — is a directory at $ref; the entry needs a trailing slash to sync one")
        fi
    done

    [ "${#rows[@]}" -gt 0 ] || return 0
    err "$ref's own kasbah.yml lists paths in sync: that are not in $ref:"
    for src in "${rows[@]}"; do err_cont "$src"; done
    err_cont "that tag is internally inconsistent — its manifest names files it does not carry,"
    err_cont "so there is no complete copy of $_ROLLBACK_VERSION to ship. Roll forward instead."
    exit 1
}

# What `git archive` actually produced, against every blob the ref holds under
# the sync: list. The two checks are different predicates — `git ls-tree` says
# what is *in the tree*, `git archive` says what gets *exported* — and
# `.gitattributes export-ignore` separates them. Measured: an export-ignored
# path comes back from `ls-tree`, and `git archive <ref> -- <that path>` exits 0
# having written a tar with nothing in it but the pax header. Which of the two
# shapes that produces is worth knowing: a whole *file* entry then fails the
# rsync loudly, at code 23, blaming a transport that is working fine, while a
# file dropped from *inside* a directory entry ships silently short — and the
# run stops at the first failing entry, so the loud one can hide the quiet one
# behind it. The extraction is the only
# artefact that reflects every decision the archive made, so it is what the
# guarantee rests on; the ls-tree pre-check keeps its own job of producing a
# good message before the archive dies at 128 on a path that is genuinely absent.
_rollback_check_extraction() {
    local ref="$1" src path
    local paths=() missing=()
    local tmp="${TMPDIR:-/tmp}"

    [ "$tmp" = / ] || tmp="${tmp%/}"
    _ROLLBACK_LSTREE="$(mktemp "$tmp/kasbah-lstree.XXXXXX")" \
        || die "could not create a temporary file to list $ref's blobs into"

    for src in "${_ROLLBACK_PATHS[@]}"; do
        # -z, because `git ls-tree` C-quotes a name with a quote or a control
        # character in it and a quoted name compares unequal to the file on disk.
        paths=()
        # Through a file, not `< <(…)`: the names are NUL-separated, so a
        # command substitution cannot carry them, and a process substitution
        # would swallow a `git ls-tree` failure into an empty array — which
        # reads here as "nothing missing", a guard failing open inside the
        # function written to close one.
        git ls-tree -r -z --name-only "$ref" -- "$src" > "$_ROLLBACK_LSTREE" \
            || die "could not list $src at $ref (see git's error above)"
        readarray -d '' -t paths < "$_ROLLBACK_LSTREE"

        for path in ${paths[@]+"${paths[@]}"}; do
            [ -n "$path" ] || continue
            # -L as well as -e: a symlink the ref carries is a blob, and a
            # dangling one is exactly what a project's sync list may hold.
            [ -e "$_ROLLBACK_EXTRACT/$path" ] || [ -L "$_ROLLBACK_EXTRACT/$path" ] \
                || missing+=("$path")
        done
    done

    [ "${#missing[@]}" -gt 0 ] || return 0
    err "$ref's sync: list did not come out of \`git archive\` whole:"
    for path in "${missing[@]}"; do err_cont "$path — in the tag's tree, not in the archive"; done
    err_cont "\`git ls-tree\` finds those paths at $ref, so they are committed — something told"
    err_cont "\`git archive\` to leave them out, and export-ignore in .gitattributes is what does"
    err_cont "that. A $_ROLLBACK_MODE ships what the archive produced, so it would put an"
    err_cont "incomplete $_ROLLBACK_VERSION on the server."
    exit 1
}

# v<target>, on this workstation, without touching the working tree or the
# index. The manifest comes first because it is what says which paths follow,
# and the compose file with it — both are read from here on, which is what makes
# "read the ref, never HEAD" cheap enough to be the default.
_rollback_extract() {
    local ref="v$_ROLLBACK_VERSION"
    local tmp="${TMPDIR:-/tmp}" compose_rel="$_BP_COMPOSE" type="" head_name="$MANIFEST_NAME"
    local frag_rel="$_DEPLOY_FRAGMENT"
    local seen="" i src

    [ "$tmp" = / ] || tmp="${tmp%/}"
    _ROLLBACK_EXTRACT="$(mktemp -d "$tmp/kasbah-$_ROLLBACK_MODE.XXXXXX")" \
        || die "could not create a temporary directory to extract $ref into"

    _rollback_extract_blob "$ref" "$KASBAH_MANIFEST_FILE" \
        "$_ROLLBACK_EXTRACT/$KASBAH_MANIFEST_FILE" \
        "that version predates this project's kasbah metadata, so there is no sync: list to ship. Roll forward instead."
    _rollback_extract_blob "$ref" "$compose_rel" "$_ROLLBACK_EXTRACT/$compose_rel" \
        "the images to retag are read from it (docs/build-deploy.md → the invariant)"

    # From here on every read of either file is the ref's. Both variables are
    # consumed as plain paths — `yq … "$file"`, `[ -f "$file" ]` — so absolute
    # ones point the manifest reader, `kasbah check`'s image list and the
    # shipped script's renderer at the tag in one assignment each.
    KASBAH_MANIFEST_FILE="$_ROLLBACK_EXTRACT/$KASBAH_MANIFEST_FILE"
    _BP_COMPOSE="$_ROLLBACK_EXTRACT/$compose_rel"

    manifest_require
    [ "$MANIFEST_NAME" = "$head_name" ] \
        || die "this project is called $head_name today and was called $MANIFEST_NAME at $ref — the server's directory is <apps>/<name>, so kasbah cannot tell which of the two this run is about"

    _deploy_read_sync
    _deploy_check_compose_dst
    _rollback_check_ref_paths "$ref"

    _ROLLBACK_PATHS=()
    for i in "${!_DEPLOY_SRC[@]}"; do
        src="${_DEPLOY_SRC[$i]}"
        case "$seen" in *"|$src|"*) continue ;; esac
        seen="$seen|$src|"
        _ROLLBACK_PATHS+=("$src")
    done
    # `if !` rather than `|| die`: the pipeline's status is git's under pipefail,
    # and errexit would otherwise end the run before the message.
    if ! git archive --format=tar "$ref" -- "${_ROLLBACK_PATHS[@]}" | tar -xf - -C "$_ROLLBACK_EXTRACT"; then
        die "could not extract $ref's sync: list into $_ROLLBACK_EXTRACT (see the error above)"
    fi
    _rollback_check_extraction "$ref"

    # The fragment is not in the sync list and never is — kasbah owns the path
    # it lands on. Absent at the ref is a project shape, not a failure: a worker
    # with no HTTP surface has none, and nothing already on the server is
    # removed either way.
    _ROLLBACK_FRAGMENT_NAME="$frag_rel"
    _rollback_ref_type "$ref" "$frag_rel" type
    if [ "$type" = blob ]; then
        git show "$ref:$frag_rel" > "$_ROLLBACK_EXTRACT/$frag_rel" \
            || die "could not read $frag_rel out of $ref (see git's error above)"
        _DEPLOY_FRAGMENT="$_ROLLBACK_EXTRACT/$frag_rel"
        _ROLLBACK_HAS_FRAGMENT=yes
    fi
    return 0
}

# The sync list's relative paths mean what they say only in the extraction, and
# the state file and git belong to the project root. The one step that needs the
# other working directory borrows it and gives it back; a die() inside ends the
# run anyway, and the cleanup below takes absolute paths.
_rollback_in_extract() {
    local rc=0
    cd "$_ROLLBACK_EXTRACT" || die "could not enter $_ROLLBACK_EXTRACT"
    "$@" || rc=$?
    cd "$_ROLLBACK_ROOT" || die "could not return to $_ROLLBACK_ROOT"
    return "$rc"
}

# Both temporary trees, from one trap: the rendered helper is lib/deploy.sh's
# and the extraction is this file's, and either can outlive a run that a refused
# env step or a Ctrl-C ends.
_rollback_cleanup() {
    _deploy_cleanup
    if [ -n "$_ROLLBACK_LSTREE" ]; then
        rm -f -- "$_ROLLBACK_LSTREE" || true
        _ROLLBACK_LSTREE=""
    fi
    [ -n "$_ROLLBACK_EXTRACT" ] || return 0
    rm -rf -- "$_ROLLBACK_EXTRACT" || true
    _ROLLBACK_EXTRACT=""
    return 0
}

# --- The server ---------------------------------------------------------------------

# Step 6: every image v<target>'s compose builds has to still be on the server
# as `:<target>`. Within the retention window it always is; outside it, the
# answer is to roll forward, and kasbah will not quietly re-ship an image built
# now and claim it is the one that ran then (docs/build-deploy.md → Retention).
_rollback_check_images() {
    local out rc=0 img
    local missing=()

    [ "${#_RD_IMAGES[@]}" -gt 0 ] || return 0

    out=$(ssh_script "$_ROLLBACK_VERSION" "${_RD_IMAGES[@]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
version=$1
shift

missing=""
for img in "$@"; do
    docker image inspect "$img:$version" >/dev/null 2>&1 && continue
    if [ -z "$missing" ]; then missing="$img"; else missing="$missing,$img"; fi
done
printf 'checked=%s\nmissing=%s\n' "$#" "$missing"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not look for $MANIFEST_NAME's $_ROLLBACK_VERSION images on $_DEPLOY_TARGET (the remote step exited $rc, see above)"
    _deploy_absorb "the image check" "$out" checked missing
    # The count is the half of the report that says the check ran at all: a
    # `missing=` computed over fewer images than were asked about is an empty
    # answer that looks like a pass.
    [ "${_DEPLOY_FACT[checked]}" = "${#_RD_IMAGES[@]}" ] \
        || die "the image check on $_DEPLOY_TARGET looked at ${_DEPLOY_FACT[checked]} of $MANIFEST_NAME's ${#_RD_IMAGES[@]} built images, so its answer is about the wrong set"

    [ -n "${_DEPLOY_FACT[missing]}" ] || return 0
    readarray -t missing < <(tr ',' '\n' <<<"${_DEPLOY_FACT[missing]}")

    # Two states, and only a rollback can tell them apart: it has just proved
    # the version is in the record, so an absent image is one retention let go.
    # A tagged deploy reads no record at all, and its commonest way here is a
    # version that was never built — so naming that "outside the retention
    # window" states a history kasbah never looked for.
    for img in "${missing[@]}"; do
        if [ "$_ROLLBACK_MODE" = rollback ]; then
            err "Image $img:$_ROLLBACK_VERSION is no longer on the VPS (outside the"
            err_cont "retention window)."
        else
            err "Image $img:$_ROLLBACK_VERSION is not on $_DEPLOY_TARGET — either it was never built"
            err_cont "and shipped for this version, or it was and the retention window has let it go."
            err_cont "A tagged deploy does not read the deploy record, so kasbah cannot tell which;"
            err_cont "\`kasbah history $_DEPLOY_TARGET --all\` is what answers it."
        fi
    done
    if [ "$_ROLLBACK_MODE" = rollback ]; then
        err_cont "Prefer deploying a fix forward. To force a rollback anyway, rebuild from the"
        err_cont "tag (NOT byte-identical to the original — compare versions.log digests):"
        err_cont "  git checkout v$_ROLLBACK_VERSION && kasbah build-push $_DEPLOY_TARGET"
        err_cont "Then retry:"
        err_cont "  kasbah rollback $_DEPLOY_TARGET $_ROLLBACK_VERSION"
    else
        err_cont "Nothing was deployed. Build that version and ship it first:"
        err_cont "  git checkout v$_ROLLBACK_VERSION && kasbah build-push $_DEPLOY_TARGET"
        err_cont "Then retry:"
        err_cont "  kasbah deploy $_DEPLOY_TARGET $_ROLLBACK_VERSION"
    fi
    exit 1
}

# The fragment, in the same position a deploy puts it: last, once the remote
# step has returned 0. A rollback that dies at `compose up` must not already
# have pointed the live route at v<target>'s container names — and the reverse
# ordering costs a 502 that lasts until someone deploys again
# (docs/build-deploy.md → why the fragment ships last).
_rollback_sync_fragment() {
    local dest="$_DEPLOY_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml"

    if [ "$_ROLLBACK_HAS_FRAGMENT" != yes ]; then
        warn "v$_ROLLBACK_VERSION carries no $_ROLLBACK_FRAGMENT_NAME — nothing was written to $dest"
        warn "whatever is there now is left as it is: removing a route is \`kasbah drop\`'s decision"
        _DEPLOY_FACT[fragment]=absent
        return 0
    fi
    # No `cd` here, unlike the project sync: _DEPLOY_FRAGMENT is the extracted
    # copy's absolute path, which is what makes the ordinary deploy function ship
    # the ref's fragment from anywhere.
    _deploy_sync_fragment
    return 0
}

# Step 10 of a rollback, which is not step 10 of a deploy: the range runs the
# other way. The commits between the version the server was running and the one
# it runs now are what this rollback gave up, and naming them is the point —
# a fix that has to be rolled forward again is somewhere in that list.
_rollback_changelog() {
    local prev="${_DEPLOY_FACT[prev_version]}"
    local range line log=""

    if [ -z "$prev" ]; then
        if [ "${_DEPLOY_FACT[deployed_before]}" = yes ]; then
            warn "$_DEPLOY_TARGET has deployed $MANIFEST_NAME before, but the last line of its"
            warn "versions.log is not one a version can be read out of — so there is nothing to"
            warn "say what this rollback gave up. The rollback itself is done."
            return 0
        fi
        # Two facts from the same run, and they cannot both be true: this
        # rollback's target came out of that server's record, and the server has
        # just said it holds no entry for this project.
        warn "$_DEPLOY_TARGET reports no history for $MANIFEST_NAME, while $_ROLLBACK_VERSION was"
        warn "chosen because its record names it — the two disagree, and one of them was read"
        warn "wrong. The rollback itself is done; look at $VLOG_ACTIVE_PATH."
        return 0
    fi
    if [ "$prev" = "$_ROLLBACK_VERSION" ]; then
        info "  gave up: nothing — $_DEPLOY_TARGET was already running $_ROLLBACK_VERSION"
        return 0
    fi

    range="v$_ROLLBACK_VERSION..v$prev"
    if ! git rev-parse -q --verify "refs/tags/v$prev^{commit}" >/dev/null 2>&1; then
        warn "$_DEPLOY_TARGET was running $prev, and this checkout has no tag v$prev — so there"
        warn "is no list of what the rollback gave up. \`git fetch --tags\`, then \`git log $range\`"
        return 0
    fi
    if ! log="$(git log --no-color --format='%h %s' "$range" --)"; then
        warn "could not read \`git log $range\` (see git's error above) — no changelog"
        return 0
    fi
    if [ -z "$log" ]; then
        info "  gave up: nothing — $range is empty, so $prev carried no commit $_ROLLBACK_VERSION does not"
        return 0
    fi

    info "  gave up: $range — no longer deployed"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '    %s\n' "$line" >&2
    done <<<"$log"
    return 0
}

# Everything this run reads out of the checkout: the tag, and then v<target>'s
# own manifest, compose file, sync list and fragment. One step, because a deploy
# of a named version runs all of it before the first connection and a rollback
# cannot run any of it until the server has named the target.
_rollback_read_ref() {
    _DEPLOY_VERSION="$_ROLLBACK_VERSION"
    _rollback_require_tag
    _rollback_extract
    _deploy_read_mail
    _rollback_extract_mail_seed
    # The hooks, the health block, the backup block and the built-image list, all
    # read out of v<target>'s manifest: they are what that version expects of the
    # script it is brought up by.
    remote_deploy_read_manifest "$_ROLLBACK_VERSION"
    return 0
}

# The SnappyMail pre-seed named by v<target>'s manifest, taken out of v<target>.
#
# Everything else this run reads has already been repointed into the extraction
# — the manifest and the compose file by _rollback_extract, the fragment beside
# them — and this is the one path that reaches lib/deploy.sh as a *file to open*
# rather than as a value. `_deploy_mail_claim` runs outside _rollback_in_extract,
# with the working directory back at the project root, so a relative
# snappymail_domain: would otherwise resolve against the checkout: a rollback
# would ship today's bytes for a version that declared different ones, and
# report "there is no such file in this checkout" for one whose file has since
# been deleted. Both measured before this existed.
#
# Copy-if-missing is what keeps that latent — the wrong bytes only land on a
# server that has none yet — and is exactly why it needs pinning: when it bites,
# the wrong version is the one that stays.
#
# Not in the sync list and not required to be: like the fragment, it is fetched
# from the ref by name. Absent at the ref is a warning and not a failure, for
# the reason every mail claim is one — an unmet claim costs mail, not the site.
_rollback_extract_mail_seed() {
    local ref="v$_ROLLBACK_VERSION" rel type=""

    [ -n "$_DEPLOY_MAIL_SNAPPY" ] || return 0

    # `./mail/x.json` and `mail/x.json` name one blob; git ls-tree wants the
    # second spelling.
    rel="${_DEPLOY_MAIL_SNAPPY#./}"
    _rollback_ref_type "$ref" "$rel" type
    if [ "$type" != blob ]; then
        warn "$ref's kasbah.yml names snappymail_domain: $rel, and $ref does not carry that file"
        warn "nothing is seeded — the checkout's copy is deliberately not used here; the $_ROLLBACK_MODE continues"
        _DEPLOY_MAIL_SNAPPY=""
        return 0
    fi

    # Only when there is one to make: `${rel%/*}` on a path with no slash is the
    # path itself, and a directory created under that name is what `git show`
    # would then try to write the blob over.
    case $rel in
        */*) mkdir -p "$_ROLLBACK_EXTRACT/${rel%/*}" \
                 || die "could not create a directory for $rel under $_ROLLBACK_EXTRACT" ;;
    esac
    git show "$ref:$rel" > "$_ROLLBACK_EXTRACT/$rel" \
        || die "could not read $rel out of $ref (see git's error above)"
    _DEPLOY_MAIL_SNAPPY="$_ROLLBACK_EXTRACT/$rel"
    return 0
}

# --- The run --------------------------------------------------------------------------

# The shared path, and the only place the two modes differ is named here: the
# version the operator must give a deploy and may leave off a rollback, and the
# `versions.log` precondition a rollback has (docs/build-deploy.md → deploy's
# two modes: "no 'must be in versions.log' precondition — you're allowed to
# deploy a version for the first time").
#
# The working directory stays the project root, where git and the state file
# are. One step borrows the extraction — the project rsync, whose sync: paths are
# relative to it; the fragment ships from an absolute path and needs no `cd`.
rollback_tagged_run() {
    _ROLLBACK_MODE="$1"
    _DEPLOY_MODE="$1"
    _ROLLBACK_VERSION="${2:-}"

    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    command -v rsync >/dev/null || die "rsync is required (install rsync and retry)"
    command -v git >/dev/null \
        || die "git is required — every file a $_ROLLBACK_MODE of a tagged version ships comes out of the tag"
    command -v tar >/dev/null \
        || die "tar is required — v<version> is unpacked from \`git archive\` before it is shipped"

    manifest_require
    _ROLLBACK_ROOT="$PWD"
    git rev-parse --git-dir >/dev/null 2>&1 \
        || die "$PWD is not a git repository — the version to $_ROLLBACK_MODE comes from a git tag"
    _deploy_resolve_target "$_ROLLBACK_MODE"

    # Installed before the extraction it removes, and before ssh_connect, which
    # is what lets lib/ssh.sh chain its own teardown after this one rather than
    # replacing it.
    trap '_rollback_cleanup' EXIT

    # A deploy of a named version can be judged against this checkout before
    # anything is connected to, which is the rule the no-args deploy keeps
    # (cmd_deploy): a missing tag, a manifest listing files its own tag does not
    # carry, a rename since — all facts about this checkout, none worth a round
    # trip. A rollback keeps the spec's order instead, even with the version
    # named: when the tag is missing too, "never deployed to this VPS" is the
    # more useful of the two answers, and it is the record that knows it.
    [ "$_ROLLBACK_MODE" != deploy ] || _rollback_read_ref

    ssh_connect "$_DEPLOY_TARGET"
    _deploy_read_marker

    # The record, and both questions asked of it, are a rollback's alone: a
    # first-time deploy of a tagged version is exactly what the second refusal
    # would stop, and the round trip is not spent when nothing reads it. It is
    # also why an unnamed target inverts the order above — the version itself is
    # a fact only the server has, so nothing local can be judged before it.
    if [ "$_ROLLBACK_MODE" = rollback ]; then
        vlog_fetch "$_DEPLOY_TARGET" "$_DEPLOY_APPS_PATH" "$MANIFEST_NAME"
        [ -n "$_ROLLBACK_VERSION" ] || _rollback_implicit_target
        _rollback_require_deployed
    fi
    [ -n "$_ROLLBACK_EXTRACT" ] || _rollback_read_ref
    _rollback_check_images

    _deploy_prepare
    _rollback_in_extract _deploy_sync_project
    _deploy_sync_helper
    _deploy_env_step
    _deploy_mail_claim
    _deploy_remote_run
    _rollback_sync_fragment

    state_record \
        last_server  "$_DEPLOY_TARGET" \
        last_deploy  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        last_version "$_ROLLBACK_VERSION"

    if [ "$_ROLLBACK_MODE" = rollback ]; then
        _deploy_banner "Rolled $MANIFEST_NAME back to $_ROLLBACK_VERSION on $_DEPLOY_TARGET"
        _rollback_changelog
    else
        _deploy_banner "Deployed $MANIFEST_NAME $_ROLLBACK_VERSION to $_DEPLOY_TARGET"
        _deploy_changelog
    fi
    return 0
}

cmd_rollback() {
    _rollback_parse_args "$@"
    rollback_tagged_run rollback "$_DEPLOY_VERSION_ARG"
}
