# kasbah — build-push command
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_BUILD_PUSH_LOADED:-}" ] && return 0
_KASBAH_BUILD_PUSH_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
# There is one version contract, and it is deploy's: HEAD's single v-tag is
# what both commands call this release, refused the same way for the same
# reasons (_deploy_pick_version).
. "$KASBAH_LIB_DIR/deploy.sh"

# `kasbah build-push [USER@HOST]` builds the images this project's compose file
# declares, tags them with HEAD's version, and moves them to a server without a
# registry: one gzipped `docker save` over ssh, `docker load` on the far side
# (docs/build-deploy.md → kasbah build-push).
#
# What it deliberately does not do is deploy. `:current` — the tag every built
# service's compose entry resolves to — is never moved here, and no container is
# started or replaced. That decoupling is what lets an image be staged ahead of
# the deploy that cuts over to it.
#
# The project shape is derived, not declared: any service with a `build:` key is
# an image to ship, and a project with none is a stock-image project that exits
# 0 having done nothing. There is no `type` field in the manifest.

_BP_TARGET=""
_BP_VERSION=""
_BP_BUILD_ONLY=""
_BP_GIT_PUSH=yes
# What _bp_git_push did with the tag, printed under the `Shipped …` headline.
_BP_GIT_RESULT=""

# The tarball, on each end. Set the moment the path is decided rather than once
# the file is complete, because a half-written one is exactly what the cleanup
# exists for.
_BP_TARBALL=""
_BP_REMOTE_TARBALL=""

_BP_COMPOSE=compose.prod.yml

# The built services and their images, three parallel arrays filled by
# _bp_read_built_services. At file scope because `declare` inside a function is
# local (docs/phases/03-env.md).
_BP_SERVICE=()
_BP_SOURCE=()   # the image: compose names, which is what the build tags
_BP_IMAGE=()    # <image>:<version>, which is what is tagged, saved and loaded

_bp_usage() {
    cat <<EOF
Usage: kasbah build-push [USER@HOST] [--build-only] [--no-git-push]

Builds this project's images, tags them with HEAD's version, and loads them onto
a server over ssh — no registry involved. Run from the project root. USER@HOST
defaults to the last server this project talked to (.kasbah/state.json).

What it does:
  * resolves the version from HEAD's single v-tag
  * builds every service in $_BP_COMPOSE that has a build: key, and tags
    each one <image>:<version> from the image: that service names
  * docker save (one tarball, all images) | gzip, rsync to the server's /tmp,
    docker load there, and removes the tarball from both ends
  * git push origin v<version>, when the tag is not on origin yet

A project whose compose file builds nothing exits 0 having done nothing: stock
images are pulled on the server by \`kasbah deploy\`.

It does not move :current and does not run \`compose up\`. Both are \`kasbah deploy\`'s.

Flags:
  --build-only    build and tag locally; ship nothing, push nothing
  --no-git-push   ship the images, leave the git tag where it is

See docs/build-deploy.md and docs/cli.md.
EOF
}

# --- Command line ---------------------------------------------------------------

_bp_parse_args() {
    _BP_TARGET=""
    _BP_BUILD_ONLY=""
    _BP_GIT_PUSH=yes

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)     _bp_usage; exit 0 ;;
            --build-only)  _BP_BUILD_ONLY=yes ;;
            --no-git-push) _BP_GIT_PUSH=no ;;
            --build-only=*|--no-git-push=*)
                die "build-push: ${1%%=*} takes no value — pass it on its own" ;;
            -*) die "build-push: unknown flag '${1%%=*}' (build-push takes USER@HOST, --build-only and --no-git-push)" ;;
            *)
                if [ -z "$_BP_TARGET" ]; then
                    _BP_TARGET="${1%$'\r'}"
                else
                    # `kasbah build-push user@host 1.2.3` reads as a version, and
                    # there is no such mode: the version is HEAD's tag or nothing.
                    die "build-push: too many arguments ('$1') — it takes one USER@HOST, and the version comes from HEAD's tag"
                fi
                ;;
        esac
        shift
    done
    return 0
}

# The positional argument, else the server this project last talked to. With
# neither there is nothing to guess at (docs/project-manifest.md) — but unlike
# deploy, this command has a mode that needs no server at all, so the refusal
# says so.
_bp_resolve_target() {
    local stored=""

    [ -z "$_BP_TARGET" ] || return 0

    state_get last_server stored
    if [ -z "$stored" ] || [ "$stored" = null ]; then
        err "build-push: no server given, and this project has never shipped to one"
        err_cont "pass it once — \`kasbah build-push user@vps\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        err_cont "to build and tag here without shipping anything, use --build-only"
        exit 1
    fi
    _BP_TARGET="$stored"
    return 0
}

_bp_resolve_version() {
    _deploy_resolve_version
    _BP_VERSION="$_DEPLOY_VERSION"
    return 0
}

# --- What the compose file says to build ------------------------------------------

# `<image>:current` → `<image>` is `image_base` in lib/common.sh: `server prune`
# reduces a compose `image:` to the same repository from the other end — what it
# may delete — and one rule with two spellings is two answers to what an image
# is called.

# Every service with a `build:` key, and the image each one names. That is the
# whole definition of "this project builds something" (docs/build-deploy.md →
# project shape is derived from compose).
_bp_read_built_services() {
    local services svc has_build image base

    _BP_SERVICE=()
    _BP_SOURCE=()
    _BP_IMAGE=()

    [ -f "$_BP_COMPOSE" ] \
        || die "$_BP_COMPOSE: not found (cwd=$PWD) — build-push derives the images to ship from it"
    yq -r '.' "$_BP_COMPOSE" >/dev/null \
        || die "$_BP_COMPOSE: could not parse YAML (see the error above)"
    services="$(yq -r '(.services // {}) | keys | .[]' "$_BP_COMPOSE")" \
        || die "$_BP_COMPOSE: could not read its services (see the error above)"

    while IFS= read -r svc; do
        svc="${svc%$'\r'}"
        [ -n "$svc" ] || continue

        has_build="$(yq -r ".services[\"$svc\"] | has(\"build\")" "$_BP_COMPOSE")" \
            || die "$_BP_COMPOSE: could not read service '$svc' (see the error above)"
        [ "${has_build%$'\r'}" = true ] || continue

        image="$(yq -r ".services[\"$svc\"].image // \"\"" "$_BP_COMPOSE")" \
            || die "$_BP_COMPOSE: could not read the image: of service '$svc' (see the error above)"
        image="${image%$'\r'}"
        if [ -z "$image" ] || [ "$image" = null ]; then
            err "$_BP_COMPOSE: service '$svc' builds an image but does not name one"
            err_cont "kasbah tags what it builds <image>:<version>, and deploy moves"
            err_cont "<image>:current onto it — compose's own generated name is not one it can"
            err_cont "move. Give the service an image: key:"
            err_cont "    image: $MANIFEST_NAME-$svc:current"
            exit 1
        fi

        image_base "$image" base
        _BP_SERVICE+=("$svc")
        _BP_SOURCE+=("$image")
        _BP_IMAGE+=("$base:$_BP_VERSION")
    done <<<"$services"
    return 0
}

# --- Building -----------------------------------------------------------------------

# `compose build`, never `up --build`: a service with both `build:` and `image:`
# is never rebuilt by `up` while an image of that name exists, so an edited
# Dockerfile goes silently unshipped (docs/phases/01-rig.md).
#
# -p, as on every compose invocation kasbah makes anywhere: `name:` in the file
# is the weakest source of the project name and COMPOSE_PROJECT_NAME in this
# shell outranks it.
#
# The two KASBAH_* limits belong to a server and a build has no server. They are
# placeholders only so that interpolation resolves — compose refuses to cast an
# empty string to `cpus:` and the build fails outright without them — and 0 is
# what Docker reads as "no limit" in any case.
_bp_build() {
    env KASBAH_CPU_LIMIT=0 KASBAH_MEM_LIMIT=0 \
        docker compose -p "$MANIFEST_NAME" -f "$_BP_COMPOSE" build \
        || die "docker compose -p $MANIFEST_NAME -f $_BP_COMPOSE build failed (see the error above)"
    return 0
}

# The permanent tag, one per built image. `:current` is left exactly where the
# build put it: moving it is the deploy's decision, on the server, and no
# `:latest` is written anywhere (docs/build-deploy.md → image tags on the VPS).
_bp_tag() {
    local i

    for i in "${!_BP_SERVICE[@]}"; do
        docker tag "${_BP_SOURCE[$i]}" "${_BP_IMAGE[$i]}" \
            || die "could not tag ${_BP_SOURCE[$i]} as ${_BP_IMAGE[$i]} (see docker's error above)"
    done
    return 0
}

# --- Shipping -------------------------------------------------------------------------

# One `docker save` carrying every image, not one per image: inside a single
# tarball each layer is written once, and images built from the same base share
# nearly all of them.
_bp_save() {
    local tmp="${TMPDIR:-/tmp}"

    # Trailing slash off, root left alone — the same shape lib/ssh.sh applies to
    # the directory it puts the control socket in, so both land on one spelling
    # of the same path.
    [ "$tmp" = / ] || tmp="${tmp%/}"

    _BP_TARBALL="$tmp/$MANIFEST_NAME-$_BP_VERSION.tar.gz"
    docker save "${_BP_IMAGE[@]}" | gzip > "$_BP_TARBALL" \
        || die "could not write $_BP_TARBALL (see docker's error above)"
    return 0
}

# rsync rather than scp, because everything remote in this codebase goes through
# lib/ssh.sh and that is where the ControlMaster lives — one handshake for the
# transfer and the load together.
#
# The far side removes the tarball itself, the moment `docker load` has read it:
# it is the largest thing this command puts on a server, and it is worth nothing
# afterwards. What is left to _bp_cleanup is every path where the far side never
# got that far.
_bp_ship() {
    local out line rc=0

    _BP_REMOTE_TARBALL="/tmp/$MANIFEST_NAME-$_BP_VERSION.tar.gz"

    ssh_rsync -pt -s "$_BP_TARBALL" "$SSH_TARGET:$_BP_REMOTE_TARBALL" >/dev/null \
        || die "could not send $_BP_TARBALL to $_BP_TARGET:$_BP_REMOTE_TARBALL"

    out=$(ssh_script "$_BP_REMOTE_TARBALL" "${_BP_IMAGE[@]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
tar=$1
shift

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ -f "$tar" ] || fail "$tar is not there — the transfer did not finish"

# `docker load` narrates onto stdout; stdout here carries the report this step
# is read by, so the narration goes to stderr with every other diagnostic.
load_rc=0
docker load -i "$tar" >&2 || load_rc=$?
rm -f "$tar"
[ "$load_rc" -eq 0 ] || fail "docker load -i $tar exited $load_rc"

# Asked of the daemon rather than inferred from load's exit status: what the
# next deploy retags is the tag, so the tag is what has to be there.
for img; do
    docker image inspect "$img" >/dev/null 2>&1 \
        || fail "$img is not on this server after docker load"
done

printf 'loaded=%s\n' "$#"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not load the images onto $_BP_TARGET (the remote step exited $rc, see above)"

    # Checked as a protocol before anything is believed about the far side: a
    # report that never arrived must not read as a successful load
    # (docs/phases/01-rig.md, from 1.3).
    if ! grep -qx "loaded=${#_BP_IMAGE[@]}" <<<"$out"; then
        err "loading the images onto $_BP_TARGET reported no loaded=${#_BP_IMAGE[@]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
        exit 1
    fi

    _BP_REMOTE_TARBALL=""
    return 0
}

# Both ends, from a trap rather than a closing line. The tarball is the biggest
# thing this command creates, and every way the run can end after it exists — a
# transfer that dies halfway, a load the server refuses, a Ctrl-C — would
# otherwise leave it in /tmp here, there, or both.
_bp_cleanup() {
    if [ -n "$_BP_TARBALL" ]; then
        rm -f "$_BP_TARBALL" || true
        _BP_TARBALL=""
    fi
    # Only ever set once ssh_connect has returned, so the master is up and this
    # runs before lib/ssh.sh's own cleanup closes it (its EXIT handler chains
    # after the one installed here).
    if [ -n "$_BP_REMOTE_TARBALL" ]; then
        ssh_run rm -f "$_BP_REMOTE_TARBALL" >/dev/null 2>&1 || true
        _BP_REMOTE_TARBALL=""
    fi
    return 0
}

# --- The git tag ------------------------------------------------------------------------

# A version that exists on one workstation is not a release: the tag is the only
# record of what these images were built from, and rollback reads the repository
# for it (docs/build-deploy.md → rollback, step 4).
#
# Last, after the images are on the server, and a repository with no origin at
# all is a warning rather than a failure — by that point the shipping has
# happened and there is nothing to undo.
#
# What it did goes into _BP_GIT_RESULT rather than straight to the operator: the
# line is an indented continuation of the `Shipped …` headline, and every other
# command in kasbah prints the headline before what hangs off it. The push has
# to run before that headline (a failure here is a failure of the command), so
# the doing and the saying are split.
_bp_git_push() {
    local tag="v$_BP_VERSION"

    _BP_GIT_RESULT="$tag left where it is (--no-git-push)"
    [ "$_BP_GIT_PUSH" != no ] || return 0

    if ! git remote get-url origin >/dev/null 2>&1; then
        warn "this repository has no 'origin' remote, so $tag was not pushed"
        warn "the images are on $_BP_TARGET regardless — push the tag wherever this project lives"
        _BP_GIT_RESULT="$tag not pushed — this repository has no 'origin' remote"
        return 0
    fi
    if git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1; then
        _BP_GIT_RESULT="$tag is already on origin"
        return 0
    fi
    if ! git push origin "$tag"; then
        err "could not push $tag to origin (see git's error above)"
        err_cont "the images are already on $_BP_TARGET and none of that needs redoing —"
        err_cont "push the tag once the remote is reachable:  git push origin $tag"
        exit 1
    fi
    _BP_GIT_RESULT="pushed $tag to origin"
    return 0
}

# --- Command ------------------------------------------------------------------------------

cmd_build_push() {
    local i

    _bp_parse_args "$@"
    command -v docker >/dev/null || die "docker is required (install docker and retry)"

    # Everything local first, as deploy does: no manifest, no tag, a compose file
    # that names no image for something it builds — all of it is a fact about this
    # checkout, and none of it is worth a round trip or a build to find out.
    manifest_require
    _bp_resolve_version
    _bp_read_built_services

    if [ "${#_BP_SERVICE[@]}" -eq 0 ]; then
        info "$MANIFEST_NAME builds nothing — no service in $_BP_COMPOSE has a build: key"
        info "  stock images are pulled on the server by \`kasbah deploy\`; nothing to ship"
        return 0
    fi

    if [ -z "$_BP_BUILD_ONLY" ]; then
        command -v jq >/dev/null || die "jq is required (install jq and retry)"
        command -v rsync >/dev/null || die "rsync is required (install rsync and retry)"
        # Before the build rather than after it: "which server?" is answerable in
        # a millisecond, and asking it afterwards means asking it at the end of
        # however long the build took.
        _bp_resolve_target
    fi

    _bp_build
    _bp_tag

    if [ -n "$_BP_BUILD_ONLY" ]; then
        info "Built and tagged $MANIFEST_NAME $_BP_VERSION — nothing was shipped (--build-only)"
        for i in "${!_BP_SERVICE[@]}"; do
            info "  image:   ${_BP_IMAGE[$i]} (service ${_BP_SERVICE[$i]})"
        done
        return 0
    fi

    # Installed before ssh_connect, which is what lets lib/ssh.sh chain its own
    # teardown after this one instead of replacing it.
    trap '_bp_cleanup' EXIT
    ssh_connect "$_BP_TARGET"

    _bp_save
    _bp_ship
    _bp_git_push

    # Only now: docs/project-manifest.md's write rule is that a failed command
    # leaves the state file untouched.
    state_record last_server "$_BP_TARGET"

    info "Shipped $MANIFEST_NAME $_BP_VERSION to $_BP_TARGET"
    for i in "${!_BP_SERVICE[@]}"; do
        info "  image:   ${_BP_IMAGE[$i]} (service ${_BP_SERVICE[$i]})"
    done
    info "  current: unmoved — \`kasbah deploy\` is what cuts over to $_BP_VERSION"
    info "  git:     $_BP_GIT_RESULT"
}
