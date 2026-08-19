# kasbah — deploy command
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_DEPLOY_LOADED:-}" ] && return 0
_KASBAH_DEPLOY_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
. "$KASBAH_LIB_DIR/env_cmd.sh"

# `kasbah deploy [USER@HOST]` ships the working tree, labelled with HEAD's
# version tag, to a server `kasbah server init` has already prepared, and runs
# the project's compose stack there (docs/build-deploy.md, the no-args path).
#
# Everything remote rides one ssh master. The order is: read, judge, then write
# — the marker and the project's .env are read before a single directory is
# created or a single file shipped.
#
# Nothing reaches <apps>/traefik/dynamic/ until the deploy is known to have
# finished. The fragment is the last thing shipped, after `compose up` has
# returned 0, because the two failure shapes are not symmetrical: routing a host
# at a container that never started is a 502 that stays until someone deploys
# again, while shipping the fragment last leaves the container unrouted for the
# time Traefik takes to notice one new file — 44 ms measured on an idle Traefik
# (docs/phases/02-spine.md).
#
# The env step sits between the two: after the project rsync, because the
# interactive setup prompts from the .env.prod.example that rsync put there, and
# before the remote deploy, because `compose up` reads the file it writes. See
# lib/env_cmd.sh.
#
# Thin on purpose. Hooks, backup, the health wait, image digests and versions.log
# rotation belong to templates/remote-deploy.sh and arrive in Phase 4. What is
# here is the stock-image path: sync, env, `compose up -d`, one log line,
# fragment.

_DEPLOY_TARGET=""
_DEPLOY_TARGET_SOURCE=""
_DEPLOY_VERSION=""
_DEPLOY_APPS_PATH=""
_DEPLOY_DATA_PATH=""
_DEPLOY_CPU_LIMIT=""
_DEPLOY_MEM_LIMIT=""
_DEPLOY_MARKER=""
_DEPLOY_ON_DRIFT=""

# The manifest's sync: list, split into three parallel arrays by
# _deploy_parse_sync_lines.
_DEPLOY_SRC=()
_DEPLOY_DST=()
_DEPLOY_RECURSE=()

# The project fragment, which never appears in the sync list: kasbah owns the
# path it lands on (docs/traefik.md).
_DEPLOY_FRAGMENT=traefik-dynamic.yml

declare -A _DEPLOY_FACT=()

_deploy_usage() {
    cat <<EOF
Usage: kasbah deploy [USER@HOST] [--on-drift=setup|continue|abort]

Ships the working tree to a prepared server and brings the project up there.
Run from the project root. The version is HEAD's v-tag; USER@HOST defaults to
the last server this project deployed to (.kasbah/state.json).

What it does:
  * rsyncs every path in the manifest's sync: list to <apps>/<name>/
  * renders <apps>/<name>/.env when it is missing, checks it for drift against
    .env.prod.example otherwise, and refreshes the KASBAH_* block in it from
    the server marker's resource limits
  * runs scripts/remote-deploy.sh deploy <version> on the server, which does
    docker compose -p <name> up -d --remove-orphans and appends versions.log
  * rsyncs traefik-dynamic.yml to <apps>/traefik/dynamic/<name>.yml, last

Flags:
  --on-drift=setup      re-run the interactive setup when .env has drifted
  --on-drift=continue   deploy against the .env as it stands
  --on-drift=abort      stop, changing nothing
Unset, a drifting .env asks; with no terminal to ask on, the run stops (exit 5).

See docs/build-deploy.md and docs/env-template.md.
EOF
}

# --- Command line ---------------------------------------------------------------

_deploy_parse_args() {
    _DEPLOY_TARGET=""
    _DEPLOY_ON_DRIFT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _deploy_usage; exit 0 ;;
            # Named rather than lumped into "unknown flag": all three are
            # written down in docs/cli.md as part of this command, and a user
            # who read that page deserves to know which phase brings them.
            --skip-hooks|--no-health-wait)
                die "deploy: $1 is not implemented yet — hooks and the health wait arrive in Phase 4 (docs/build-deploy.md)" ;;
            --on-drift=*)
                _DEPLOY_ON_DRIFT="${1#*=}"
                env_on_drift_check deploy "$_DEPLOY_ON_DRIFT"
                ;;
            --on-drift)
                die "deploy: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort" ;;
            -*) die "deploy: unknown flag '${1%%=*}' (deploy takes USER@HOST and --on-drift=)" ;;
            *)
                if [ -z "$_DEPLOY_TARGET" ]; then
                    _DEPLOY_TARGET="${1%$'\r'}"
                else
                    # `kasbah deploy user@host 1.2.3` is a documented mode, so
                    # it is refused by name rather than as a stray argument.
                    die "deploy: deploying an explicit version ('$1') is not implemented yet — it ships from git archive in Phase 4/5. Today's deploy labels the working tree with HEAD's tag."
                fi
                ;;
        esac
        shift
    done
    return 0
}

# The positional argument, else the server this project last deployed to. With
# neither there is nothing to guess at: the whole point of last_server is that
# the *first* deploy names the host (docs/project-manifest.md).
_deploy_resolve_target() {
    local stored=""

    if [ -n "$_DEPLOY_TARGET" ]; then
        _DEPLOY_TARGET_SOURCE=argument
        return 0
    fi

    state_get last_server stored
    if [ -z "$stored" ] || [ "$stored" = null ]; then
        err "deploy: no server given, and this project has never deployed to one"
        err_cont "pass it once — \`kasbah deploy user@vps\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        exit 1
    fi
    _DEPLOY_TARGET="$stored"
    _DEPLOY_TARGET_SOURCE=state
    return 0
}

# --- Version --------------------------------------------------------------------

# Exactly one v-tag on HEAD, or the run stops. Zero and two are different
# mistakes and get different messages: nothing is tagged yet, versus kasbah
# cannot know which of two labels this deploy is called.
#
# Pure so it can be tested without a repository — the caller feeds it whatever
# `git tag --points-at HEAD` printed.
_deploy_pick_version() {
    local _pv_tags="$1" _pv_out="$2"
    local _pv_line _pv_tag
    local _pv_v=() _pv_other=()

    while IFS= read -r _pv_line; do
        _pv_line="${_pv_line%$'\r'}"
        [ -n "$_pv_line" ] || continue
        case $_pv_line in
            v?*) _pv_v+=("$_pv_line") ;;
            *)   _pv_other+=("$_pv_line") ;;
        esac
    done <<<"$_pv_tags"

    if [ "${#_pv_v[@]}" -eq 0 ]; then
        err "HEAD carries no version tag, so this release has nothing to label itself with"
        if [ "${#_pv_other[@]}" -gt 0 ]; then
            err_cont "HEAD is tagged ${_pv_other[*]}, and kasbah versions are v-prefixed semver"
        fi
        err_cont "tag the commit and retry:  git tag v1.0.0"
        exit 1
    fi
    if [ "${#_pv_v[@]}" -gt 1 ]; then
        err "HEAD carries ${#_pv_v[@]} version tags — ${_pv_v[*]}"
        err_cont "exactly one is required: the tag is the version that goes into versions.log"
        err_cont "and onto the images, and kasbah will not choose between them"
        exit 1
    fi

    _pv_tag="${_pv_v[0]}"
    # Semver, as docs/build-deploy.md's versioning contract has it. A pre-release
    # or build suffix is allowed through; the shape that matters is X.Y.Z, since
    # `kasbah history` sorts on it. A space would also break versions.log, whose
    # fields are space-delimited.
    if ! [[ "$_pv_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
        err "HEAD's tag '$_pv_tag' is not a version kasbah can use"
        err_cont "expected v<major>.<minor>.<patch> (docs/build-deploy.md → versioning contract)"
        exit 1
    fi
    printf -v "$_pv_out" '%s' "${_pv_tag#v}"
    return 0
}

_deploy_resolve_version() {
    local tags=""

    command -v git >/dev/null \
        || die "git is required — kasbah resolves the version from HEAD's tag"
    git rev-parse --git-dir >/dev/null 2>&1 \
        || die "$PWD is not a git repository — kasbah resolves the version from HEAD's tag"
    git rev-parse -q --verify HEAD >/dev/null 2>&1 \
        || die "this repository has no commits yet, so there is no HEAD to read a version tag from"

    tags="$(git tag --points-at HEAD)" \
        || die "could not list the tags on HEAD (see git's error above)"
    _deploy_pick_version "$tags" _DEPLOY_VERSION
    return 0
}

# --- The sync list ----------------------------------------------------------------

# One side of a sync entry. Everything here is refused rather than escaped: each
# value becomes both a local path and a remote one, and rsync's `host:path`
# splitting plus the remote shell would each read some of these differently.
_deploy_check_sync_path() {
    local _cp_path="$1" _cp_side="$2" _cp_entry="$3"

    [ -n "$_cp_path" ] \
        || die "kasbah.yml: sync entry '$_cp_entry' has no $_cp_side"
    case $_cp_path in
        /*) die "kasbah.yml: sync entry '$_cp_entry' names an absolute $_cp_side ('$_cp_path') — entries are relative to the project root" ;;
        -*) die "kasbah.yml: sync entry '$_cp_entry' has a $_cp_side starting with '-' ('$_cp_path'), which rsync would read as an option" ;;
    esac
    case $_cp_path in
        *:*) die "kasbah.yml: sync entry '$_cp_entry' has a ':' in its $_cp_side ('$_cp_path') — rsync splits host from path on it" ;;
        *[[:cntrl:]]*) die "kasbah.yml: sync entry '$_cp_entry' has a control character in its $_cp_side" ;;
    esac
    case "/$_cp_path/" in
        *//*|*/./*|*/../*)
            die "kasbah.yml: sync entry '$_cp_entry' has a '.', '..' or empty segment in its $_cp_side ('$_cp_path')" ;;
    esac
    return 0
}

_deploy_trim() {
    local _t_value="$1" _t_out="$2"
    _t_value="${_t_value#"${_t_value%%[![:space:]]*}"}"
    _t_value="${_t_value%"${_t_value##*[![:space:]]}"}"
    printf -v "$_t_out" '%s' "$_t_value"
    return 0
}

# `src` or `src -> dst`, one per line, exactly as the manifest lists them. A
# trailing slash means the entry is a directory whose contents are synced
# recursively; without one the entry is a single file (docs/project-manifest.md).
_deploy_parse_sync_lines() {
    local raw="$1"
    local line entry src dst recurse

    _DEPLOY_SRC=()
    _DEPLOY_DST=()
    _DEPLOY_RECURSE=()

    while IFS= read -r line; do
        line="${line%$'\r'}"
        _deploy_trim "$line" entry
        [ -n "$entry" ] || continue
        [ "$entry" != null ] || continue

        if [[ "$entry" == *"->"* ]]; then
            _deploy_trim "${entry%%->*}" src
            _deploy_trim "${entry#*->}" dst
        else
            src="$entry"
            dst="$entry"
        fi

        # Either side may carry it: `docker/ -> etc/docker` is as clear an
        # intent as `docker/ -> etc/docker/`, and both mean recurse.
        recurse=no
        case $src in */) recurse=yes ;; esac
        case $dst in */) recurse=yes ;; esac
        while [ "${src: -1}" = / ]; do src="${src%/}"; done
        while [ "${dst: -1}" = / ]; do dst="${dst%/}"; done

        _deploy_check_sync_path "$src" source "$entry"
        _deploy_check_sync_path "$dst" destination "$entry"

        _DEPLOY_SRC+=("$src")
        _DEPLOY_DST+=("$dst")
        _DEPLOY_RECURSE+=("$recurse")
    done <<<"$raw"

    [ "${#_DEPLOY_SRC[@]}" -gt 0 ] \
        || die "kasbah.yml: the sync: list is empty — a deploy would ship no compose file and nothing to run"
    return 0
}

_deploy_read_sync() {
    local raw
    raw="$(manifest_get '.sync // [] | .[] | tostring')"
    _deploy_parse_sync_lines "$raw"
}

# Every source is checked before the first one is shipped, and all the bad ones
# are reported together: a manifest listing three files that were renamed should
# cost one run, not three. A path that is not there is a hard failure — a silent
# skip ships a project missing the file its compose mounts.
_deploy_check_sources() {
    local i src recurse
    local rows=()

    for i in "${!_DEPLOY_SRC[@]}"; do
        src="${_DEPLOY_SRC[$i]}"
        recurse="${_DEPLOY_RECURSE[$i]}"
        if [ ! -e "$src" ]; then
            rows+=("$src — no such file or directory")
        elif [ "$recurse" = yes ] && [ ! -d "$src" ]; then
            rows+=("$src/ — listed with a trailing slash, which means a directory, but it is a file")
        elif [ "$recurse" = no ] && [ -d "$src" ]; then
            rows+=("$src — is a directory; add a trailing slash ('$src/') to sync it recursively")
        fi
    done

    [ "${#rows[@]}" -gt 0 ] || return 0
    err "kasbah.yml lists paths in sync: that this working tree does not have:"
    for src in "${rows[@]}"; do err_cont "$src"; done
    err_cont "every sync: entry is shipped on every deploy — fix the list or the tree"
    exit 1
}

# --- The server -------------------------------------------------------------------

# Folds a remote step's key=value report into the fact table, and checks the key
# set as a protocol before any verdict reads a value: a fact that never arrived
# must not be absorbed into a passing check (docs/phases/01-rig.md, from 1.3).
_deploy_absorb() {
    local _da_what="$1" _da_out="$2"; shift 2
    local _da_line _da_key
    local _da_missing=()

    while IFS= read -r _da_line; do
        _da_line="${_da_line%$'\r'}"
        case $_da_line in *=*) _DEPLOY_FACT[${_da_line%%=*}]="${_da_line#*=}" ;; esac
    done <<<"$_da_out"

    for _da_key in "$@"; do
        [ -n "${_DEPLOY_FACT[$_da_key]+set}" ] || _da_missing+=("$_da_key")
    done
    if [ "${#_da_missing[@]}" -gt 0 ]; then
        err "$_da_what on $_DEPLOY_TARGET reported no ${_da_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _da_line; do err_cont "| $_da_line"; done <<<"$_da_out"
        exit 1
    fi
    return 0
}

# The server marker, at the one path a project command can know without being
# told (lib/marker.sh — `kasbah env` reads it the same way, and the refusal for
# a server that has none lives there). Its contents are where the apps and data
# paths come from, so a server whose layout is not under /apps is followed
# rather than second-guessed — once it has been found. Finding it is the part
# that is missing: deploy looks at the default path only, so a server prepared
# with --apps-path elsewhere reads as unprepared here (carried to Phase 4).
#
# The two resource limits come out of the same read, and go straight into the
# project's .env as the KASBAH_* managed block (docs/env-template.md).
_deploy_read_marker() {
    marker_read "$_DEPLOY_TARGET"

    _DEPLOY_MARKER="$MARKER_JSON"
    _DEPLOY_APPS_PATH="$MARKER_APPS_PATH"
    _DEPLOY_DATA_PATH="$MARKER_DATA_PATH"
    _DEPLOY_CPU_LIMIT="$MARKER_CPU_LIMIT"
    _DEPLOY_MEM_LIMIT="$MARKER_MEM_LIMIT"
    return 0
}

# The directories a deploy writes into, and the two facts about the server that
# have to hold before anything is written: the apps path is a directory, and
# Traefik's dynamic directory is there — a server that is not prepared is worth
# finding out about before the first rsync, not after it.
#
# `<data>/<name>` is made here too: it is the bind-mount root a project's
# compose file points at, and Docker would otherwise materialise it as a
# root-owned directory on first use.
#
# The .env is deliberately *not* judged here any more. It used to be, because
# nothing rendered one — and the ordering was load-bearing, since a refusal
# after the rsyncs had already put a fragment in traefik/dynamic and left a live
# route to a container that never started (docs/phases/02-spine.md). The env
# step replaces that judgement and runs later on purpose, since the interactive
# setup prompts from the .env.prod.example the rsync ships; the ordering rule it
# has to keep is the fragment's, and the fragment is still the last thing any
# deploy sends.
_deploy_prepare() {
    local out rc=0
    local parents=()

    # Every remote directory an rsync below writes into. rsync creates the last
    # component of a destination path but not the ones above it.
    readarray -t parents < <(_deploy_remote_parents)

    out=$(ssh_script "$_DEPLOY_APPS_PATH" "$_DEPLOY_DATA_PATH" "$MANIFEST_NAME" \
                     ${parents[@]+"${parents[@]}"} <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
name=$3
shift 3

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ -d "$apps" ] || fail "$apps is not a directory"
[ -d "$apps/traefik/dynamic" ] || fail "$apps/traefik/dynamic is not a directory"

for d in "$apps/$name" "$apps/$name/scripts" "$apps/$name/backups" "$data/$name" "$@"; do
    mkdir -p "$d" || fail "could not create $d"
done

printf 'prepared=yes\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not prepare $_DEPLOY_APPS_PATH/$MANIFEST_NAME on $_DEPLOY_TARGET (the remote step exited $rc, see above)"

    _deploy_absorb "the prepare step" "$out" prepared
    return 0
}

# The remote directories the sync list needs above what _deploy_prepare creates
# anyway — the parent of every file entry, and every recursive entry's own
# destination. Printed one per line, deduplicated, and never the project root
# itself.
_deploy_remote_parents() {
    local i dst recurse dir
    local seen=""

    for i in "${!_DEPLOY_DST[@]}"; do
        dst="${_DEPLOY_DST[$i]}"
        recurse="${_DEPLOY_RECURSE[$i]}"
        if [ "$recurse" = yes ]; then
            dir="$dst"
        else
            dir="${dst%/*}"
            [ "$dir" != "$dst" ] || continue
        fi
        case "$seen" in
            *"|$dir|"*) continue ;;
        esac
        seen="$seen|$dir|"
        printf '%s/%s\n' "$_DEPLOY_APPS_PATH/$MANIFEST_NAME" "$dir"
    done
    return 0
}

# --- Shipping ---------------------------------------------------------------------

# The working tree as it stands, entry by entry (docs/build-deploy.md: the
# no-args path labels the tree with HEAD's tag rather than reading git).
#
# -s so the remote side never re-splits a path: without it rsync hands the
# destination to a remote shell, which would take a space in the apps path as an
# argument boundary.
_deploy_sync_project() {
    local base="$_DEPLOY_APPS_PATH/$MANIFEST_NAME"
    local i src dst

    for i in "${!_DEPLOY_SRC[@]}"; do
        src="${_DEPLOY_SRC[$i]}"
        dst="${_DEPLOY_DST[$i]}"
        if [ "${_DEPLOY_RECURSE[$i]}" = yes ]; then
            ssh_rsync -rlpt -s "$src/" "$SSH_TARGET:$base/$dst/" >/dev/null \
                || die "could not sync $src/ to $_DEPLOY_TARGET:$base/$dst/"
        else
            ssh_rsync -lpt -s "$src" "$SSH_TARGET:$base/$dst" >/dev/null \
                || die "could not sync $src to $_DEPLOY_TARGET:$base/$dst"
        fi
    done
    return 0
}

# kasbah's own two helpers, overwritten on every deploy so the scripts on the
# server are the ones this kasbah version drives (docs/build-deploy.md → helper
# scripts). Executable is stated here rather than inherited: a checkout on a
# filesystem that lost the mode bit would otherwise ship a script nothing can
# run.
#
# They come from different places, and that is not an accident:
# remote-deploy.sh is a template kasbah renders onto servers, while
# setup-env.sh *is* lib/env.sh — the same bytes `kasbah check` sources locally,
# shipped verbatim so that the drift question has one implementation rather than
# two copies that agree today (env_ship_helper, lib/env_cmd.sh).
_deploy_sync_helper() {
    local tpl="${KASBAH_TEMPLATE_DIR:-}"
    local src="$tpl/remote-deploy.sh"
    local dest="$_DEPLOY_APPS_PATH/$MANIFEST_NAME/scripts/remote-deploy.sh"

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -f "$src" ] \
        || die "the remote-deploy helper is missing (looked in $src) — this kasbah installation is incomplete"

    ssh_rsync -pt --chmod=F755 -s "$src" "$SSH_TARGET:$dest" >/dev/null \
        || die "could not ship remote-deploy.sh to $_DEPLOY_TARGET:$dest"

    env_ship_helper "$_DEPLOY_APPS_PATH" "$MANIFEST_NAME"
    return 0
}

# Step 6 of docs/build-deploy.md, in lib/env_cmd.sh because `kasbah env` is the
# same step with the setup always run. After the project rsync (the setup
# prompts from the .env.prod.example it ships) and before the remote deploy
# (`compose up` reads what it writes).
_deploy_env_step() {
    env_step_run "$_DEPLOY_APPS_PATH" "$MANIFEST_NAME" \
        "$_DEPLOY_CPU_LIMIT" "$_DEPLOY_MEM_LIMIT" "$_DEPLOY_ON_DRIFT" no
    return 0
}

# The Traefik fragment, out of band: kasbah owns the destination path, so the
# project never lists it in sync: (docs/project-manifest.md, docs/traefik.md).
# rsync writes a temp file and renames, so Traefik's watcher sees one atomic
# replace rather than a truncated file — which is why --inplace must never
# appear here.
#
# Shipped last, once the stack is up. Anything that can make `compose up` fail —
# an image that will not pull, a port already bound, a value the compose file
# cannot use — would otherwise leave a live route to a container that does not
# exist, and 502 there until the next successful deploy. The same ordering
# covers the redeploy case where a project renames its container_name: the old
# fragment keeps serving the old container right up to the moment the new one is
# running.
#
# A project with no fragment is deployed anyway and warned about: T01 in
# docs/compliance.md is a warning, and a worker with no HTTP surface is a real
# project shape. What is not done is deleting whatever fragment is already
# there; taking a site off the internet is `kasbah drop`'s decision, not a
# side effect of a missing file.
_deploy_sync_fragment() {
    local dest="$_DEPLOY_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml"

    if [ ! -f "$_DEPLOY_FRAGMENT" ]; then
        warn "no $_DEPLOY_FRAGMENT in $PWD — nothing was written to $dest"
        warn "this project routes through Traefik only if that file exists (docs/traefik.md)"
        _DEPLOY_FACT[fragment]=absent
        return 0
    fi

    # The last step, and the only one that fails with the deploy already
    # counted: the stack is up and versions.log says so, but the route is
    # missing. Saying just "could not ship" would send the reader looking for
    # a broken deploy instead of a missing fragment.
    if ! ssh_rsync -pt --chmod=F644 -s "$_DEPLOY_FRAGMENT" "$SSH_TARGET:$dest" >/dev/null; then
        err "could not ship $_DEPLOY_FRAGMENT to $_DEPLOY_TARGET:$dest"
        err_cont "the deploy itself succeeded — the new containers are up and versions.log"
        err_cont "already records $_DEPLOY_VERSION. Only the Traefik route is missing, so this"
        err_cont "host serves whatever it served before (404 if it is a first deploy)."
        err_cont "re-run \`kasbah deploy\` once the server is reachable again."
        exit 1
    fi
    _DEPLOY_FACT[fragment]=shipped
    return 0
}

# The VPS side of the deploy, run through the helper rather than inlined, so
# Phase 4 grows one script instead of rewriting this function
# (docs/phases/02-spine.md → Decisions).
#
# KASBAH_VERSION travels in the environment: it is what the helper writes into
# versions.log's `kasbah=` field, and the alternative — a positional argument —
# would fix the shape of a command line docs/build-deploy.md spells out as
# `remote-deploy.sh deploy <version>`.
_deploy_remote_deploy() {
    local script="$_DEPLOY_APPS_PATH/$MANIFEST_NAME/scripts/remote-deploy.sh"
    local rc=0

    ssh_run env "KASBAH_VERSION=$KASBAH_VERSION" "$script" deploy "$_DEPLOY_VERSION" \
        || rc=$?
    [ "$rc" -eq 0 ] || {
        err "the deploy failed on $_DEPLOY_TARGET (remote-deploy.sh exited $rc, see above)"
        err_cont "the files are already there — fix what it reported and re-run \`kasbah deploy\`"
        exit 1
    }
    return 0
}

# --- Command ----------------------------------------------------------------------

cmd_deploy() {
    _deploy_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    command -v rsync >/dev/null || die "rsync is required (install rsync and retry)"

    # Everything local first: no manifest, no tag, a sync list naming files that
    # are not there — all of it is a fact about this checkout, and none of it is
    # worth a round trip to find out.
    manifest_require
    _deploy_resolve_target
    _deploy_resolve_version
    _deploy_read_sync
    _deploy_check_sources

    ssh_connect "$_DEPLOY_TARGET"

    _deploy_read_marker
    _deploy_prepare

    _deploy_sync_project
    _deploy_sync_helper
    # Between the two: the setup prompts from a template that has to be on the
    # server already, and `compose up` reads the .env it writes.
    _deploy_env_step
    _deploy_remote_deploy
    # Last, and only now: see the header. A route must never point at a
    # container the deploy failed to start.
    _deploy_sync_fragment

    # Only now: docs/project-manifest.md's write rule is that a failed command
    # leaves the state file untouched.
    state_record \
        last_server  "$_DEPLOY_TARGET" \
        last_deploy  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        last_version "$_DEPLOY_VERSION"

    info "Deployed $MANIFEST_NAME $_DEPLOY_VERSION to $_DEPLOY_TARGET"
    info "  project: $_DEPLOY_APPS_PATH/$MANIFEST_NAME   data: $_DEPLOY_DATA_PATH/$MANIFEST_NAME"
    info "  limits:  KASBAH_CPU_LIMIT=$_DEPLOY_CPU_LIMIT KASBAH_MEM_LIMIT=$_DEPLOY_MEM_LIMIT (from the server marker)"
    if [ "${_DEPLOY_FACT[fragment]}" = shipped ]; then
        info "  routing: $_DEPLOY_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml (Traefik reloads within a couple of seconds)"
    fi
    info "  logged:  $_DEPLOY_APPS_PATH/$MANIFEST_NAME/versions.log"
}
