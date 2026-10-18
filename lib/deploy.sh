# kasbah — deploy command
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_DEPLOY_LOADED:-}" ] && return 0
_KASBAH_DEPLOY_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
. "$KASBAH_LIB_DIR/env_cmd.sh"
. "$KASBAH_LIB_DIR/remote_deploy.sh"

# `kasbah deploy [USER@HOST]` ships the working tree, labelled with HEAD's
# version tag, to a server `kasbah server init` has already prepared, and runs
# the project's compose stack there (docs/build-deploy.md, the no-args path).
# Named a version instead, it ships that tag and nothing off disk — the same
# code as `kasbah rollback`, in lib/rollback.sh, which this file's shipping,
# env, remote and banner steps are all shared with.
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
# Thin on purpose. The backup, the hooks, the `:current` retag, the health wait
# and the image digests all live on the far side, in templates/remote-deploy.sh,
# which this command renders per deploy out of the project's manifest and ships
# to <apps>/<name>/scripts/. What is here is the local half: sync, env, the one
# remote invocation, the fragment — and the changelog, which needs both sides at
# once: the version the server was running comes back in that invocation's
# report, and the commits are in this checkout.

_DEPLOY_TARGET=""
_DEPLOY_TARGET_SOURCE=""
_DEPLOY_VERSION=""
# The version named on the command line, which turns this into the tagged path
# (lib/rollback.sh). Empty is the everyday no-args deploy of the working tree.
_DEPLOY_VERSION_ARG=""
# Which of the two runs this is. Everything below that speaks to the operator
# reads it, because the wrong noun here is not a wrong noun: "re-run \`kasbah
# deploy\`" told to someone who has just rolled a server back is a runnable
# instruction that ships the working tree and undoes the rollback.
_DEPLOY_MODE=deploy
_DEPLOY_APPS_PATH=""
_DEPLOY_DATA_PATH=""
_DEPLOY_CPU_LIMIT=""
_DEPLOY_MEM_LIMIT=""
_DEPLOY_MARKER=""
_DEPLOY_ON_DRIFT=""
# The manifest's mail claim, or empty when it has none (docs/project-manifest.md).
_DEPLOY_MAIL_DOMAIN=""
# The `snappymail_domain:` path from the same block, relative to the project
# root, or empty. Pre-seed, not configuration: it is copied only when the
# target is not already there.
_DEPLOY_MAIL_SNAPPY=""
# <apps>/mail/kasbah.yml as it came back off the server — the registry, and the
# only thing asked whether the stack serves the claimed domain (docs/mail.md).
_DEPLOY_MAIL_REGISTRY=""
# The three switches the shipped script takes. Plain opt-in flags rather than
# tri-state pairs: each one turns a step of the remote run off, and "unset" has
# one obvious meaning — run everything (docs/cli.md → kasbah deploy).
_DEPLOY_SKIP_HOOKS=no
_DEPLOY_NO_HEALTH_WAIT=no
_DEPLOY_ALLOW_STOPPED=no
# The rendered remote-deploy.sh, on this side. Set the moment the path is
# decided rather than once the file is complete, because a half-written one is
# exactly what the cleanup exists for.
_DEPLOY_RENDERED=""
# The effective `client:` — the manifest's, defaulting to the project name. Read
# with the other local checks and written onto the server by _deploy_prepare.
_DEPLOY_CLIENT=""

# The manifest's sync: list, split into three parallel arrays by
# _deploy_parse_sync_lines.
_DEPLOY_SRC=()
_DEPLOY_DST=()
_DEPLOY_RECURSE=()

# The project fragment, which never appears in the sync list: kasbah owns the
# path it lands on (docs/traefik.md).
_DEPLOY_FRAGMENT=traefik-dynamic.yml

declare -A _DEPLOY_FACT=()

# Lines _deploy_absorb prints after the raw output. A global rather than an
# argument because the key list is variadic — a trailing option there would be
# ambiguous with a key — and because exactly one caller needs it: the remote
# deploy, whose far side has already changed the server by the time its report
# is read. Set immediately before the call, cleared immediately after.
_DEPLOY_ABSORB_ADVICE=()

_deploy_usage() {
    cat <<EOF
Usage: kasbah deploy [USER@HOST] [VERSION] [--on-drift=setup|continue|abort]
                     [--skip-hooks] [--no-health-wait] [--allow-stopped]

Ships the working tree to a prepared server and brings the project up there.
Run from the project root. The version is HEAD's v-tag; USER@HOST defaults to
the last server this project deployed to (.kasbah/state.json).

With a VERSION, it ships that tag instead — every file out of \`git archive
v<VERSION>\`, the working tree neither read nor touched. That is the rollback
path with a \`deploy\` log entry and the pre-/post-deploy hooks, and it is
allowed to be the first time that version reaches this server.
An argument containing '@' is the server, anything else is the version.

What it does:
  * rsyncs every path in the manifest's sync: list to <apps>/<name>/
  * renders <apps>/<name>/.env when it is missing, checks it for drift against
    .env.prod.example otherwise, and refreshes the KASBAH_* block in it from
    the server marker's resource limits
  * runs scripts/remote-deploy.sh deploy <version> on the server: backup,
    pre-deploy hooks, retag <image>:current, docker compose -p <name> up -d
    --remove-orphans, health wait, post-deploy hooks, one versions.log entry
  * rsyncs traefik-dynamic.yml to <apps>/traefik/dynamic/<name>.yml, last
  * prints the commits between the version the server was running and this one

Flags:
  --on-drift=setup      re-run the interactive setup when .env has drifted
  --on-drift=continue   deploy against the .env as it stands
  --on-drift=abort      stop, changing nothing
Unset, a drifting .env asks; with no terminal to ask on, the run stops (exit 5).

Passed straight through to scripts/remote-deploy.sh on the server:
  --skip-hooks          skip the pre- and post-deploy hooks. The backup still
                        runs — a dry-run-ish deploy must not also throw away
                        the data safety net
  --no-health-wait      bring the stack up without blocking on its health
  --allow-stopped       deploy over a stack that has deployed here before and
                        is not running, which is otherwise refused. Each step
                        whose own container is down is then skipped — the backup
                        if that is backup.container, a pre-deploy hook if it is
                        that hook's — and the run says which

See docs/build-deploy.md and docs/env-template.md.
EOF
}

# --- Command line ---------------------------------------------------------------

# An argument with an `@` in it is the server and anything else is the version,
# each accepted once and in either order — the same rule `kasbah exec` uses to
# tell a target from a service name (docs/cli.md). Shared with `kasbah
# rollback`, whose two positionals are the same two things.
_deploy_classify_arg() {
    local _ca_cmd="$1" _ca_arg="${2%$'\r'}"

    case $_ca_arg in
        *@*)
            [ -z "$_DEPLOY_TARGET" ] \
                || die "$_ca_cmd: two servers given ('$_DEPLOY_TARGET' and '$_ca_arg') — one run goes to one server"
            _DEPLOY_TARGET="$_ca_arg" ;;
        *)
            [ -z "$_DEPLOY_VERSION_ARG" ] \
                || die "$_ca_cmd: two versions given ('$_DEPLOY_VERSION_ARG' and '$_ca_arg') — kasbah will not choose between them"
            _deploy_check_semver "$_ca_cmd" "$_ca_arg"
            _DEPLOY_VERSION_ARG="$_ca_arg" ;;
    esac
    return 0
}

# The version as versions.log carries it and as `v<version>` names a tag: bare
# semver. A leading `v` is the tag rather than the version and gets its own
# sentence, since it is the spelling the operator has just read off `git tag`.
_deploy_check_semver() {
    local _cs_cmd="$1" _cs_v="$2"

    if [[ "$_cs_v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        die "$_cs_cmd: write the version without the 'v' — \`kasbah $_cs_cmd ${_cs_v#v}\` (the tag is v${_cs_v#v}, the version is ${_cs_v#v})"
    fi
    [[ "$_cs_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
        || die "$_cs_cmd: '$_cs_v' is not a version kasbah can use — expected <major>.<minor>.<patch> (docs/build-deploy.md → versioning contract)"
    return 0
}

_deploy_parse_args() {
    _DEPLOY_MODE=deploy
    _DEPLOY_TARGET=""
    _DEPLOY_VERSION_ARG=""
    _DEPLOY_ON_DRIFT=""
    _DEPLOY_SKIP_HOOKS=no
    _DEPLOY_NO_HEALTH_WAIT=no
    _DEPLOY_ALLOW_STOPPED=no

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _deploy_usage; exit 0 ;;
            # Nothing is decided here: all three are handed to
            # scripts/remote-deploy.sh, which owns what each one turns off
            # (docs/build-deploy.md → helper scripts on the VPS).
            --skip-hooks)     _DEPLOY_SKIP_HOOKS=yes ;;
            --no-health-wait) _DEPLOY_NO_HEALTH_WAIT=yes ;;
            --allow-stopped)  _DEPLOY_ALLOW_STOPPED=yes ;;
            # `--skip-hooks=yes` is a flag this command has, spelled wrong. The
            # catch-all below would refuse it as unknown *and* list it as known
            # in the same sentence, which is a message arguing with itself.
            --skip-hooks=*|--no-health-wait=*|--allow-stopped=*)
                die "deploy: ${1%%=*} takes no value — pass it on its own (\`kasbah deploy USER@HOST ${1%%=*}\`)" ;;
            --on-drift=*)
                _DEPLOY_ON_DRIFT="${1#*=}"
                env_on_drift_check deploy "$_DEPLOY_ON_DRIFT"
                ;;
            --on-drift)
                die "deploy: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort" ;;
            -*) die "deploy: unknown flag '${1%%=*}' (deploy takes USER@HOST, VERSION, --on-drift=, --skip-hooks, --no-health-wait and --allow-stopped)" ;;
            *)  _deploy_classify_arg deploy "$1" ;;
        esac
        shift
    done
    return 0
}

# The positional argument, else the server this project last deployed to. With
# neither there is nothing to guess at: the whole point of last_server is that
# the *first* deploy names the host (docs/project-manifest.md).
_deploy_resolve_target() {
    local cmd="${1:-deploy}" stored=""

    if [ -n "$_DEPLOY_TARGET" ]; then
        _DEPLOY_TARGET_SOURCE=argument
        return 0
    fi

    state_get last_server stored
    if [ -z "$stored" ] || [ "$stored" = null ]; then
        err "$cmd: no server given, and this project has never deployed to one"
        err_cont "pass it once — \`kasbah $cmd user@vps\` — and it is remembered in"
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

# The server runs `docker compose` on <apps>/<name>/compose.yml and on nothing
# else, so a sync: list that lands on no such destination cannot produce a
# runnable project. Judged here with the other local checks: the list is a fact
# about this checkout, and the shipped script's own check for the file only
# comes after the rsync has run and the .env has been rendered on the server.
_deploy_check_compose_dst() {
    local i

    for i in "${!_DEPLOY_DST[@]}"; do
        [ "${_DEPLOY_DST[$i]}" != compose.yml ] || return 0
    done
    err "kasbah.yml: no sync: entry lands on compose.yml"
    err_cont "the server runs \`docker compose\` on $MANIFEST_NAME/compose.yml, so the list has to"
    err_cont "put the project's compose file there:  compose.prod.yml -> compose.yml"
    exit 1
}

# The manifest's `client:`, which groups this project's off-VPS backups into one
# restic repository per client and defaults to the project name
# (docs/project-manifest.md, docs/backup.md). Read here with the other local
# checks, and *rendered* onto the server rather than synced, because the
# manifest never reaches a VPS and the backup runner runs there.
#
# The rule itself is lib/manifest.sh's `manifest_client_check`, so `kasbah check`
# (S08), this, and rollback's read of a *tag's* manifest all judge the field the
# same way and only differ in what they do about it.
#
# _deploy_read_client [historical] — with `historical`, a value this kasbah
# refuses is a **warning** and the fallback is the project's directory name,
# which is `client:`'s documented default. That is for a manifest out of
# v<target>: the tag was cut before this field was checked anywhere, its bytes
# cannot be edited, and dying would turn a previously-working rollback into an
# unrecoverable one over a field that has a default. A deploy of the working
# tree has a file the operator can fix, so it still refuses.
_deploy_read_client() {
    local raw why="" historical="${1:-}"

    raw="$(manifest_get '.client // "" | tostring')"
    raw="${raw%$'\r'}"
    [ "$raw" != null ] || raw=""
    if [ -z "$raw" ]; then
        _DEPLOY_CLIENT="$MANIFEST_NAME"
        return 0
    fi
    if ! manifest_client_check "$raw" why; then
        [ -n "$historical" ] || die "kasbah.yml: $why"
        warn "the manifest in this version says $why"
        warn "falling back to '$MANIFEST_NAME', which is client:'s documented default — a"
        warn "version tagged before kasbah checked this field still has to roll back"
        _DEPLOY_CLIENT="$MANIFEST_NAME"
        return 0
    fi
    _DEPLOY_CLIENT="$raw"
    return 0
}

# The manifest's mail claim, read with the rest of the local checks. `domain` is
# the whole of what a claim says (docs/project-manifest.md → mail), so a `mail:`
# block without one claims nothing and is a mistake about this checkout — worth
# a sentence here rather than a shrug on the server.
_deploy_read_mail() {
    local raw kind

    _DEPLOY_MAIL_DOMAIN=""
    _DEPLOY_MAIL_SNAPPY=""
    raw="$(manifest_get '.mail // null')"
    [ "$raw" != null ] && [ -n "$raw" ] || return 0

    # Shape before contents: `.mail.domain` on a `mail: example.com` is a jq
    # type error, and what reaches the operator is then kasbah's internal filter
    # rather than the mistake in their manifest.
    kind="$(manifest_get '.mail | type')"
    kind="${kind%$'\r'}"
    [ "$kind" = object ] \
        || die "kasbah.yml: mail: has type '$kind' — it has to be a block with a domain: under it (docs/project-manifest.md → mail)"

    raw="$(manifest_get '.mail.domain // ""')"
    raw="${raw%$'\r'}"
    [ "$raw" != null ] || raw=""
    _deploy_trim "$raw" raw
    [ -n "$raw" ] \
        || die "kasbah.yml: mail: has no domain: — the claim is that the VPS mail stack handles that domain, and there is nothing else in the block for kasbah to check (docs/project-manifest.md)"
    _DEPLOY_MAIL_DOMAIN="$raw"

    # The optional pre-seed. Read here with the domain because it is part of the
    # same claim, and checked for existence rather than assumed: `kasbah check`'s
    # M02 fails on a missing or unparseable one, and a deploy that skips the
    # check would ship an empty file into SnappyMail's data tree — which is
    # copy-if-missing, so it would be the version that stays.
    raw="$(manifest_get '.mail.snappymail_domain // ""')"
    raw="${raw%$'\r'}"
    [ "$raw" != null ] || raw=""
    _deploy_trim "$raw" raw
    _DEPLOY_MAIL_SNAPPY="$raw"
    return 0
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

# The command line that repeats this run, for the two messages that ask an
# operator to. A tagged run has to name its version: `kasbah deploy` without one
# is a different command — it ships the working tree — and `kasbah rollback`
# without one re-resolves the target against a record this run has just written.
_deploy_rerun_cmd() {
    if [ "$_DEPLOY_MODE" = rollback ] || [ -n "$_DEPLOY_VERSION_ARG" ]; then
        printf 'kasbah %s %s %s' "$_DEPLOY_MODE" "$_DEPLOY_TARGET" "$_DEPLOY_VERSION"
    else
        printf 'kasbah deploy %s' "$_DEPLOY_TARGET"
    fi
}

# --- The server -------------------------------------------------------------------

# Folds a remote step's key=value report into the fact table, and checks the key
# set as a protocol before any verdict reads a value: a fact that never arrived
# must not be absorbed into a passing check (docs/phases/01-rig.md, from 1.3).
#
# A repeated key keeps the **last** value, which is what makes the report robust
# against anything that reached stdout ahead of it: remote-deploy.sh prints its
# report as its last act, so the report wins over a line some project-authored
# hook leaked. First-wins would hand the leak the verdict instead.
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
        for _da_line in ${_DEPLOY_ABSORB_ADVICE[@]+"${_DEPLOY_ABSORB_ADVICE[@]}"}; do
            err_cont "$_da_line"
        done
        exit 1
    fi
    return 0
}

# base64 back into a variable, keeping trailing newlines: the `printf x`
# sentinel is there because $(…) strips them, and a truncated payload must not
# be fatal here — `local x=$(… | base64 -d)` under errexit would kill the run
# before the caller could say what it could not read.
_deploy_b64_into() {
    local _bi_out="$2" _bi_dec
    _bi_dec=$( { printf '%s' "$1" | base64 -d 2>/dev/null; printf x; } )
    printf -v "$_bi_out" '%s' "${_bi_dec%x}"
    return 0
}

# The server marker, found the way every project command finds it: the server's
# own pointer at /etc/kasbah/apps-path names the tree it was prepared in, and
# /apps is the fallback for a server that carries none (lib/marker.sh — `kasbah
# env` reads it the same way, and the refusals live there). Its contents are
# where the apps and data paths come from, so a server whose layout is not under
# /apps is followed rather than second-guessed.
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
                     "$_DEPLOY_CLIENT" ${parents[@]+"${parents[@]}"} <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
name=$3
client=$4
shift 4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ -d "$apps" ] || fail "$apps is not a directory"
[ -d "$apps/traefik/dynamic" ] || fail "$apps/traefik/dynamic is not a directory"

for d in "$apps/$name" "$apps/$name/scripts" "$apps/$name/backups" "$data/$name" "$@"; do
    mkdir -p "$d" || fail "could not create $d"
done

# The effective `client:`, rendered here because the manifest is never synced to
# a server and the backup runner — which reads this file to decide which restic
# repository the project belongs in — runs on the server (08-keep.md D12).
# Written through a temp file and a rename: the runner may be reading it.
record="$apps/$name/.kasbah-client"
if [ -e "$record" ] && [ ! -f "$record" ]; then
    fail "$record exists and is not a regular file"
fi
current=""
[ ! -f "$record" ] || IFS= read -r current < "$record" || current=""
if [ "$current" = "$client" ]; then
    printf 'client=unchanged\n'
else
    tmp="$record.tmp.$$"
    printf '%s\n' "$client" > "$tmp" || fail "could not write $tmp"
    chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
    mv -f "$tmp" "$record" || fail "could not install $record"
    printf 'client=written\n'
fi

printf 'prepared=yes\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not prepare $_DEPLOY_APPS_PATH/$MANIFEST_NAME on $_DEPLOY_TARGET (the remote step exited $rc, see above)"

    _deploy_absorb "the prepare step" "$out" prepared client
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

# The sync: list, entry by entry, out of whatever directory the caller is
# standing in: the working tree for the no-args deploy, and the extracted
# v<target> for a rollback or a tagged deploy (lib/rollback.sh). The paths are
# relative for exactly that reason — one shipping step, two sources.
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
# remote-deploy.sh is a template rendered per deploy — the manifest's hooks,
# backup and health blocks are written into it here, because the manifest is
# never synced and a VPS has no yq to read it with (lib/remote_deploy.sh) —
# while setup-env.sh *is* lib/env.sh, the same bytes `kasbah check` sources
# locally, shipped verbatim so that the drift question has one implementation
# rather than two copies that agree today (env_ship_helper, lib/env_cmd.sh).
_deploy_sync_helper() {
    local tpl="${KASBAH_TEMPLATE_DIR:-}"
    local src="$tpl/remote-deploy.sh"
    local dest="$_DEPLOY_APPS_PATH/$MANIFEST_NAME/scripts/remote-deploy.sh"
    local tmp="${TMPDIR:-/tmp}"

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -f "$src" ] \
        || die "the remote-deploy helper is missing (looked in $src) — this kasbah installation is incomplete"

    [ "$tmp" = / ] || tmp="${tmp%/}"
    _DEPLOY_RENDERED="$(mktemp "$tmp/kasbah-remote-deploy.XXXXXX")" \
        || die "could not create a temporary file to render remote-deploy.sh into"
    remote_deploy_render "$src" "$_DEPLOY_RENDERED"

    ssh_rsync -pt --chmod=F755 -s "$_DEPLOY_RENDERED" "$SSH_TARGET:$dest" >/dev/null \
        || die "could not ship remote-deploy.sh to $_DEPLOY_TARGET:$dest"

    env_ship_helper "$_DEPLOY_APPS_PATH" "$MANIFEST_NAME"
    return 0
}

# The rendered helper, from a trap rather than a closing line: every way the run
# can end after it exists — a refused env step, a deploy the server rejected, a
# Ctrl-C — would otherwise leave it in TMPDIR.
_deploy_cleanup() {
    [ -n "$_DEPLOY_RENDERED" ] || return 0
    rm -f "$_DEPLOY_RENDERED" || true
    _DEPLOY_RENDERED=""
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
        err_cont "the $_DEPLOY_MODE itself succeeded — the new containers are up and versions.log"
        err_cont "already records $_DEPLOY_VERSION. Only the Traefik route is missing, so this"
        # A first deploy is impossible on the rollback path — the version had to
        # be in the record to get here — so the 404 that fits one mode is a
        # sentence about a run nobody made in the other.
        if [ "$_DEPLOY_MODE" = rollback ]; then
            err_cont "host still serves the route the run before this one left, which points at the"
            err_cont "containers this rollback replaced, so it 502s for any of them v$_DEPLOY_VERSION renamed."
        else
            err_cont "host serves whatever it served before (404 if it is a first deploy)."
        fi
        err_cont "re-run \`$(_deploy_rerun_cmd)\` once the server is reachable again."
        exit 1
    fi
    _DEPLOY_FACT[fragment]=shipped
    return 0
}

# Step 7: the mail claim, reconciled (docs/mail.md -> Per-app mail claims). A
# project claiming `mail:` says it expects mail.<domain> and SMTP to be there,
# and three things are checked — that the stack is up, that
# <apps>/mail/kasbah.yml lists the domain, and, when the manifest names a
# SnappyMail pre-seed, that the file is in the container or gets put there.
#
# The registry is read the way every reader of it reads it: base64 back and
# parse with the workstation's yq. The VPS has no yq, jq or python3 and keeping
# it that way is deliberate.
#
# Two round trips at most, and the second one only when there is a pre-seed to
# copy *and* the claim it derives from was met. Whether the domain is served is
# decided here, from bytes the first step brought back, so the copy cannot be
# folded into it — and it must not be: writing SnappyMail a configuration for a
# domain kasbah has just reported the stack does not serve is state written on a
# premise this run knows to be false, and nothing in that directory afterwards
# tells the two cases apart.
#
# **The claim never stops a deploy.** Every outcome here is a warning: an unmet
# claim costs mail, not the site, and a site that will not deploy because
# somebody has not published an MX record yet is a worse failure than the one
# being reported.
_deploy_mail_claim() {
    local dir="$_DEPLOY_APPS_PATH/mail"
    local out rc=0 seed_b64="" domains="" count="" d="" i=0 claim=unmet
    local primary="" primary_listed=no

    [ -n "$_DEPLOY_MAIL_DOMAIN" ] || return 0

    # Read on this side, shipped as an argument: the file is in the checkout, so
    # the far side has no way to fetch it. A claim naming a file that is not
    # there is reported and the deploy goes on — `kasbah check`'s M02 is where
    # that is a failure.
    if [ -n "$_DEPLOY_MAIL_SNAPPY" ]; then
        if [ ! -f "$_DEPLOY_MAIL_SNAPPY" ]; then
            warn "kasbah.yml names snappymail_domain: $_DEPLOY_MAIL_SNAPPY, and there is no such file in this checkout"
            warn "nothing is seeded — run kasbah check (M02); the $_DEPLOY_MODE continues"
            _DEPLOY_MAIL_SNAPPY=""
        else
            seed_b64="$(openssl base64 -A -in "$_DEPLOY_MAIL_SNAPPY" 2>/dev/null)" || seed_b64=""
            [ -n "$seed_b64" ] || {
                warn "could not read $_DEPLOY_MAIL_SNAPPY — nothing is seeded; the $_DEPLOY_MODE continues"
                _DEPLOY_MAIL_SNAPPY=""
            }
        fi
    fi

    out=$(ssh_script "$dir" "$_DEPLOY_DATA_PATH" "$_DEPLOY_MAIL_DOMAIN" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir=$1
data=$2
domain=$3

if [ -d "$dir" ]; then printf 'mail_stack=yes\n'; else printf 'mail_stack=no\n'; fi
if [ -f "$dir/.env" ]; then printf 'mail_env=yes\n'; else printf 'mail_env=no\n'; fi

# The registry, as bytes. This output is a key=value protocol and a YAML file
# sent raw would arrive as a dozen keys.
enc=""
if [ -f "$dir/kasbah.yml" ] && [ -r "$dir/kasbah.yml" ]; then
    enc=$(openssl base64 -A -in "$dir/kasbah.yml" 2>/dev/null) || enc=""
fi
printf 'mail_registry_b64=%s\n' "$enc"

# Container state, not health: a crashlooping DMS is `restarting`, and that is
# the documented first-run state while Traefik finishes the certificate — a
# different thing to say than "there is no container".
state() {
    local s=""
    s=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) || s=""
    [ -n "$s" ] || s=absent
    printf '%s' "$s"
}
if command -v docker >/dev/null 2>&1; then
    printf 'mail_dms=%s\n' "$(state mail-dms)"
    printf 'mail_snappymail=%s\n' "$(state mail-snappymail)"
else
    printf 'mail_dms=nodocker\n'
    printf 'mail_snappymail=nodocker\n'
fi
# Read by nothing above: the data path is in the argument list because it is
# where SnappyMail's bind mount lives, and the seed step names it in its own
# diagnostics.
: "$data" "$domain"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not look for the mail stack at $dir on $_DEPLOY_TARGET (the remote step exited $rc, see above)"
    _deploy_absorb "the mail claim step" "$out" \
        mail_stack mail_env mail_registry_b64 mail_dms mail_snappymail

    # Four different things to say, because they are four different states of
    # the server, and only the last one is about the domain.
    if [ "${_DEPLOY_FACT[mail_stack]}" != yes ]; then
        warn "$MANIFEST_NAME claims the mail domain $_DEPLOY_MAIL_DOMAIN, and there is no mail stack at $dir on $_DEPLOY_TARGET"
        warn "enable it with: kasbah server init $_DEPLOY_TARGET --with-mail — the $_DEPLOY_MODE continues"
    elif [ "${_DEPLOY_FACT[mail_env]}" != yes ]; then
        warn "$MANIFEST_NAME claims the mail domain $_DEPLOY_MAIL_DOMAIN, and $dir on $_DEPLOY_TARGET has no .env"
        warn "the stack there looks half-made, so the claim is unmet as far as anything here"
        warn "can tell — re-run server init --with-mail; the $_DEPLOY_MODE continues"
    else
        _deploy_b64_into "${_DEPLOY_FACT[mail_registry_b64]}" _DEPLOY_MAIL_REGISTRY
        if [ -z "$_DEPLOY_MAIL_REGISTRY" ]; then
            warn "$MANIFEST_NAME claims the mail domain $_DEPLOY_MAIL_DOMAIN, and $dir/kasbah.yml on $_DEPLOY_TARGET is missing or unreadable"
            warn "that file is the registry — the only thing that answers whether this stack serves"
            warn "a domain — so the claim cannot be checked; the $_DEPLOY_MODE continues"
        else
            # One key at a time, exactly as `server init` reads it: a newline
            # inside a domain value cannot then smuggle an extra list entry into
            # the answer.
            yaml_get "$_DEPLOY_MAIL_REGISTRY" '(.domains // []) | length' count || rc=$?
            if [ "$rc" -ne 0 ]; then
                warn "$MANIFEST_NAME claims the mail domain $_DEPLOY_MAIL_DOMAIN, and $dir/kasbah.yml on $_DEPLOY_TARGET does not parse as YAML"
                warn "the claim cannot be checked against a registry kasbah cannot read; the $_DEPLOY_MODE continues"
            else
                case $count in ''|*[!0-9]*) count=0 ;; esac

                # The primary is served by the stack it is the MX for whether or
                # not anyone wrote it under domains:. Four readers ask this one
                # question — check --server's M03, `server init`, `server
                # add-mail-domain` and this step — and they have to give the one
                # answer. init and add-mail-domain normalise the primary into
                # the list as they write, so every registry *kasbah* wrote
                # already carries it; a hand-edited one need not, and
                # templates/mail/kasbah.yml invites the hand edit in as many
                # words. Reading .domains alone made `deploy` warn "does not
                # serve it" about exactly the registry `check --server` had just
                # passed. Normalised the same way the writers do — prepended, so
                # the `lists:` line below reads in the order init renders.
                yaml_get "$_DEPLOY_MAIL_REGISTRY" '.primary_domain // ""' primary || primary=""
                while [ "$i" -lt "$count" ]; do
                    yaml_get "$_DEPLOY_MAIL_REGISTRY" "(.domains // [])[$i] // \"\"" d || d=""
                    i=$((i + 1))
                    [ -n "$d" ] || continue
                    [ "$d" != "$primary" ] || primary_listed=yes
                    domains+="${domains:+ }$d"
                    [ "$d" != "$_DEPLOY_MAIL_DOMAIN" ] || claim=met
                done
                if [ -n "$primary" ] && [ "$primary_listed" != yes ]; then
                    domains="$primary${domains:+ }$domains"
                    [ "$primary" != "$_DEPLOY_MAIL_DOMAIN" ] || claim=met
                fi
                if [ "$claim" = met ]; then
                    info "  mail: $_DEPLOY_MAIL_DOMAIN is served by the stack at $dir (dms ${_DEPLOY_FACT[mail_dms]}, snappymail ${_DEPLOY_FACT[mail_snappymail]})"
                else
                    warn "$MANIFEST_NAME claims the mail domain $_DEPLOY_MAIL_DOMAIN, and the stack at $dir does not serve it"
                    warn "$dir/kasbah.yml lists: ${domains:-nothing}"
                    warn "add it with: kasbah server add-mail-domain $_DEPLOY_TARGET $_DEPLOY_MAIL_DOMAIN"
                    warn "mail for $_DEPLOY_MAIL_DOMAIN is not accepted until then; the $_DEPLOY_MODE continues"
                fi
            fi
        fi

        # Whether the stack is *up* is a separate question from whether it knows
        # the domain, and both matter to a project that expects to send mail.
        case "${_DEPLOY_FACT[mail_dms]}" in
            running|nodocker) ;;
            absent)
                warn "$MANIFEST_NAME claims mail, and there is no mail-dms container on $_DEPLOY_TARGET"
                warn "bring the stack up: ssh $_DEPLOY_TARGET 'cd $dir && docker compose -p mail up -d'" ;;
            *)
                warn "$MANIFEST_NAME claims mail, and mail-dms on $_DEPLOY_TARGET is '${_DEPLOY_FACT[mail_dms]}', not running"
                warn "a restarting DMS is usually the certificate for mail.<primary> not being in acme.json yet"
                warn "  ssh $_DEPLOY_TARGET 'docker logs --tail 40 mail-dms'" ;;
        esac
    fi

    _deploy_mail_seed "$seed_b64" "$claim"
    return 0
}

# The SnappyMail pre-seed, copy-if-missing and gated on the claim (docs/mail.md
# -> Per-app mail claims, step 3). Its own round trip, because whether the claim
# was met is decided on this side.
#
# It goes through the container because it has to: SnappyMail chowns its whole
# data tree to its own uid at mode 750 on first boot, so
# <data>/mail/snappymail/_data_ is not readable, writable or even traversable by
# the deploy user. `docker cp` works on a stopped container too, which a
# `docker exec` writing the file would not.
_deploy_mail_seed() {
    local seed_b64="$1" claim="$2" out rc=0
    local target="/var/lib/snappymail/_data_/_default_/domains/$_DEPLOY_MAIL_DOMAIN.json"

    [ -n "$seed_b64" ] || return 0

    # The gate, and the operator is told both halves: that the seed was skipped,
    # and that the reason is the claim above rather than anything about the file.
    if [ "$claim" != met ]; then
        warn "kasbah.yml names snappymail_domain: $_DEPLOY_MAIL_SNAPPY, and it was NOT copied"
        warn "the claim on $_DEPLOY_MAIL_DOMAIN is unmet (see above), and a SnappyMail domain"
        warn "config for a domain this stack does not serve is configuration written on a"
        warn "premise kasbah knows to be false — fix the claim and re-$_DEPLOY_MODE"
        return 0
    fi

    out=$(ssh_script mail-snappymail "$target" "$seed_b64" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
container=$1
target=$2
seed=$3

seed_state=nocontainer
if docker inspect "$container" >/dev/null 2>&1; then
    tmp=$(mktemp -d 2>/dev/null) || tmp=""
    if [ -z "$tmp" ]; then
        seed_state=failed
    elif docker cp "$container:$target" "$tmp/probe" >/dev/null 2>&1; then
        seed_state=present
    elif ! printf '%s' "$seed" | openssl base64 -d -A > "$tmp/domain.json" 2>/dev/null; then
        seed_state=failed
    elif docker cp "$tmp/domain.json" "$container:$target" >/dev/null 2>&1; then
        seed_state=copied
    else
        seed_state=failed
    fi
    [ -z "$tmp" ] || rm -rf "$tmp"
fi
printf 'mail_seed=%s\n' "$seed_state"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not seed SnappyMail's config on $_DEPLOY_TARGET (the remote step exited $rc, see above)"
    _deploy_absorb "the SnappyMail seed step" "$out" mail_seed

    case "${_DEPLOY_FACT[mail_seed]}" in
        copied)  info "  mail: seeded SnappyMail's $_DEPLOY_MAIL_DOMAIN.json from $_DEPLOY_MAIL_SNAPPY" ;;
        present) info "  mail: SnappyMail already has a config for $_DEPLOY_MAIL_DOMAIN — left as it is" ;;
        nocontainer)
            warn "kasbah.yml names snappymail_domain: $_DEPLOY_MAIL_SNAPPY, and there is no mail-snappymail container on $_DEPLOY_TARGET"
            warn "nothing was seeded; the $_DEPLOY_MODE continues" ;;
        *)
            warn "could not seed SnappyMail's config for $_DEPLOY_MAIL_DOMAIN from $_DEPLOY_MAIL_SNAPPY"
            warn "SnappyMail builds _data_/_default_/domains/ on its first boot; if the container has"
            warn "never come up, that directory is not there yet. The $_DEPLOY_MODE continues." ;;
    esac
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
#
# Its stdout is captured because it carries the report, and only that: the
# progress an operator watches is on stderr and still streams live. The report
# is the script's last act, so a run that exits 0 without one did not finish —
# absorbed as a protocol before the changelog reads a value out of it.
#
# One function for both modes, because the shipped script is one script:
# _DEPLOY_MODE is its first argument, and everything this side does with the
# result — the protocol, the version check, the advice a truncated report
# carries — is the same either way (lib/rollback.sh).
_deploy_remote_run() {
    local mode="$_DEPLOY_MODE"
    local script="$_DEPLOY_APPS_PATH/$MANIFEST_NAME/scripts/remote-deploy.sh"
    local out rc=0
    local flags=()

    [ "$_DEPLOY_SKIP_HOOKS" != yes ]     || flags+=(--skip-hooks)
    [ "$_DEPLOY_NO_HEALTH_WAIT" != yes ] || flags+=(--no-health-wait)
    [ "$_DEPLOY_ALLOW_STOPPED" != yes ]  || flags+=(--allow-stopped)

    out=$(ssh_run env "KASBAH_VERSION=$KASBAH_VERSION" "$script" "$mode" "$_DEPLOY_VERSION" \
                  ${flags[@]+"${flags[@]}"}) || rc=$?
    [ "$rc" -eq 0 ] || {
        err "the $mode failed on $_DEPLOY_TARGET (remote-deploy.sh exited $rc, see above)"
        err_cont "the files are already there — fix what it reported and re-run \`$(_deploy_rerun_cmd)\`."
        # The retag runs before `compose up`, so a run that died at the `up` has
        # already moved the tag, and versions.log — written only by a run that
        # finished — has no entry saying so. `:current` is a pointer, not a
        # record (docs/build-deploy.md), and rollback is what points it back.
        err_cont "$MANIFEST_NAME's images on $_DEPLOY_TARGET may already carry :current for"
        err_cont "$_DEPLOY_VERSION even though its containers did not start — the retag runs"
        err_cont "before \`compose up\`, and nothing on the server records that it moved."
        if [ "$mode" = deploy ]; then
            err_cont "\`kasbah rollback $_DEPLOY_TARGET\` is what puts it back."
        fi
        exit 1
    }

    # The one absorb whose failure is not "nothing happened": remote-deploy.sh
    # prints its report last, so a missing one means the run stopped somewhere
    # after `compose up` — the stack may well be running, versions.log may
    # already say so, and the Traefik fragment below has not shipped. Saying only
    # "the step was truncated" would leave the operator to work that out.
    _DEPLOY_ABSORB_ADVICE=(
        "That report is the last thing remote-deploy.sh writes, so this run got"
        "at least as far as \`compose up\`: the new containers may be up and"
        "$_DEPLOY_APPS_PATH/$MANIFEST_NAME/versions.log may already record"
        "$_DEPLOY_VERSION. What did *not* happen is the Traefik fragment, so this"
        "host still serves whatever it served before. Check the server, then"
        "re-run \`$(_deploy_rerun_cmd)\` — it is safe to run again."
    )
    _deploy_absorb "the $mode step" "$out" version prev_version deployed_before backup digest
    _DEPLOY_ABSORB_ADVICE=()
    # The one value that can be checked rather than believed: the script on the
    # server is shipped by this same run, moments earlier, and a report about
    # some other version means the two are not talking about the same deploy.
    [ "${_DEPLOY_FACT[version]}" = "$_DEPLOY_VERSION" ] \
        || die "the $mode step on $_DEPLOY_TARGET reported version '${_DEPLOY_FACT[version]}', not the $_DEPLOY_VERSION it was asked for"
    # A value outside the two the protocol defines must not read as one of them:
    # anything-but-yes silently becomes "no", which is the changelog calling a
    # server with history a first deploy — the defect this key exists to fix.
    case "${_DEPLOY_FACT[deployed_before]}" in
        yes|no) ;;
        *) die "the $mode step on $_DEPLOY_TARGET reported deployed_before='${_DEPLOY_FACT[deployed_before]}', which is neither yes nor no" ;;
    esac
    return 0
}

# Step 10 of docs/build-deploy.md: the commits this deploy shipped, from the
# version the server was running to the one it is running now.
#
# The two halves come from different machines and neither can supply the other's:
# the previous version is whatever this server's versions.log recorded, which is
# why remote-deploy.sh reports it, and the commits are in this checkout, which is
# why the log is read here. A range that cannot be resolved is a warning and
# never a failure — the deploy is already done, and its own success is not a
# question about git.
_deploy_changelog() {
    local prev="${_DEPLOY_FACT[prev_version]}"
    local range line log=""

    if [ -z "$prev" ]; then
        # Two servers produce an empty prev_version and they are not the same
        # server, which is why the report carries both halves: no versions.log
        # entry at all is a first deploy, while entries whose last line is a
        # truncated write are a history this side cannot name. Calling the
        # second one a first deploy says something the far side has just
        # refused to say.
        if [ "${_DEPLOY_FACT[deployed_before]}" = yes ]; then
            warn "$_DEPLOY_TARGET has deployed $MANIFEST_NAME before, but the last line of its"
            warn "versions.log is not one a version can be read out of — so there is no range to"
            warn "compare against and no changelog. The deploy itself is done."
            warn "look at $_DEPLOY_APPS_PATH/$MANIFEST_NAME/versions.log, then \`git log v<prev>..v$_DEPLOY_VERSION\`"
            return 0
        fi
        info "  changes: first deploy to $_DEPLOY_TARGET — no previous version to compare against"
        return 0
    fi

    range="v$prev..v$_DEPLOY_VERSION"
    if ! git rev-parse -q --verify "refs/tags/v$prev^{commit}" >/dev/null 2>&1; then
        warn "$_DEPLOY_TARGET was running $prev, and this checkout has no tag v$prev — no changelog"
        warn "\`git fetch --tags\`, then \`git log $range\`"
        return 0
    fi
    if ! log="$(git log --no-color --format='%h %s' "$range" --)"; then
        warn "could not read \`git log $range\` (see git's error above) — no changelog"
        return 0
    fi
    if [ -z "$log" ] && [ "$prev" = "$_DEPLOY_VERSION" ]; then
        info "  changes: none — $range is empty, so this is a redeploy of the version already there"
        return 0
    fi
    if [ -z "$log" ]; then
        # Empty in this direction means v<version> is not ahead of v<prev>: the
        # server was running something newer, and this deploy takes it back.
        # `kasbah rollback` is the command for that (Phase 5), so the wording
        # says what happened rather than calling it a no-op.
        info "  changes: none in $range — $_DEPLOY_VERSION is not ahead of the $prev this server was running"
        info "           this deploy takes it back to $_DEPLOY_VERSION; \`git log v$_DEPLOY_VERSION..v$prev\` is what it gives up"
        return 0
    fi

    info "  changes: $range"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '    %s\n' "$line" >&2
    done <<<"$log"
    return 0
}

# What the run leaves behind, under a headline the caller supplies — the one
# line a deploy and a rollback do not share. Everything under it is read off the
# report, and two of the facts are nowhere else on this side: whether a backup
# was taken is what an operator most wants to know before the next command, and
# the digests are what actually went live.
_deploy_banner() {
    info "$1"
    info "  project: $_DEPLOY_APPS_PATH/$MANIFEST_NAME   data: $_DEPLOY_DATA_PATH/$MANIFEST_NAME"
    info "  limits:  KASBAH_CPU_LIMIT=$_DEPLOY_CPU_LIMIT KASBAH_MEM_LIMIT=$_DEPLOY_MEM_LIMIT (from the server marker)"
    if [ "${_DEPLOY_FACT[fragment]}" = shipped ]; then
        info "  routing: $_DEPLOY_APPS_PATH/traefik/dynamic/$MANIFEST_NAME.yml (Traefik reloads within a couple of seconds)"
    fi
    info "  logged:  $_DEPLOY_APPS_PATH/$MANIFEST_NAME/versions.log"
    # The off-VPS backup repository this project files into, said out loud on
    # the run that decided it: the record is the only thing on the server that
    # knows, and an operator who changed `client:` should see where the next
    # snapshot goes rather than find out at the next handover.
    info "  client:  $_DEPLOY_CLIENT (${_DEPLOY_FACT[client]}, at $_DEPLOY_APPS_PATH/$MANIFEST_NAME/.kasbah-client — the backup repository this project files into)"
    if [ "${_DEPLOY_FACT[backup]}" = no-backup ]; then
        info "  backup:  none taken"
    else
        info "  backup:  $_DEPLOY_APPS_PATH/$MANIFEST_NAME/${_DEPLOY_FACT[backup]}"
    fi
    [ "${_DEPLOY_FACT[digest]}" = - ] \
        || info "  images:  ${_DEPLOY_FACT[digest]} (read on the server after the retag)"
    return 0
}

# --- Command ----------------------------------------------------------------------

cmd_deploy() {
    _deploy_parse_args "$@"
    # `kasbah deploy USER@HOST X.Y.Z` is the rollback path with a `deploy` log
    # entry and the pre-/post-deploy hooks — one implementation, not two
    # (docs/build-deploy.md → deploy's two modes). Sourced here rather than at
    # the top of this file: the everyday path never needs it.
    if [ -n "$_DEPLOY_VERSION_ARG" ]; then
        . "$KASBAH_LIB_DIR/rollback.sh"
        rollback_tagged_run deploy "$_DEPLOY_VERSION_ARG"
        return
    fi
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    command -v rsync >/dev/null || die "rsync is required (install rsync and retry)"

    # Everything local first: no manifest, no tag, a sync list naming files that
    # are not there — all of it is a fact about this checkout, and none of it is
    # worth a round trip to find out.
    manifest_require
    _deploy_resolve_target
    _deploy_resolve_version
    _deploy_read_sync
    _deploy_check_compose_dst
    _deploy_check_sources
    _deploy_read_mail
    _deploy_read_client
    # The hooks, backup and health blocks that get rendered into the helper. Read
    # and judged here, with the rest of the local checks: a manifest that names a
    # hook with no command, or a backup: block missing half its fields, is a fact
    # about this checkout, and the worst place to discover it is on the server
    # after the backup has run.
    remote_deploy_read_manifest "$_DEPLOY_VERSION"

    # Installed before ssh_connect, which is what lets lib/ssh.sh chain its own
    # teardown after this one instead of replacing it.
    trap '_deploy_cleanup' EXIT
    ssh_connect "$_DEPLOY_TARGET"

    _deploy_read_marker
    _deploy_prepare

    _deploy_sync_project
    _deploy_sync_helper
    # Between the two: the setup prompts from a template that has to be on the
    # server already, and `compose up` reads the .env it writes.
    _deploy_env_step
    # Step 7, between the env step and the deploy it cannot stop, exactly where
    # docs/build-deploy.md's flow puts it.
    _deploy_mail_claim
    _deploy_remote_run
    # Last, and only now: see the header. A route must never point at a
    # container the deploy failed to start.
    _deploy_sync_fragment

    # Only now: docs/project-manifest.md's write rule is that a failed command
    # leaves the state file untouched.
    state_record \
        last_server  "$_DEPLOY_TARGET" \
        last_deploy  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        last_version "$_DEPLOY_VERSION"

    _deploy_banner "Deployed $MANIFEST_NAME $_DEPLOY_VERSION to $_DEPLOY_TARGET"
    _deploy_changelog
}
