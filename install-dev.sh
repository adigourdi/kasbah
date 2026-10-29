#!/usr/bin/env bash
# Install kasbah from this checkout: build it through the toolchain container
# (docker compose run --rm build), then hand dist/ to `dist/kasbah __install`,
# which places the build in its own version directory <lib>/<build>/ — the
# binary, and beside it in server/ the two linux server binaries it ships to a
# VPS — removes every other dev build (releases stay), and points
# <bin>/kasbah at the newest installed version that runs.
#
#   install-dev.sh                   the working tree
#   install-dev.sh vN [--pre]        the newest local tag of major N
#   install-dev.sh vN.M [--pre]      the newest patch of N.M
#   install-dev.sh vN.M.P[-rc.K]     that tag exactly
#
# Pre-releases count for vN and vN.M only with --pre. A version argument points
# <bin>/kasbah at the tag it resolved to, as self-update does; the working tree
# leaves it at the newest installed.
#
# A tag is built in a temporary clone (the stamp reads .git, so not a
# worktree) with the tag's own compose.yml, sharing this checkout's Go caches,
# and its dist/ installed by this working tree's kasbah (`__install DIR`): a
# tag cut before 11.1 has no __install of its own.
#
# KASBAH_BIN_DIR and KASBAH_LIB_DIR override the targets; KASBAH_LIB_DIR is
# the same variable kasbah reads at runtime. KASBAH_SKIP_BUILD=1 uses the
# working tree's dist/ already there instead of building it.

set -euo pipefail

usage() {
    echo "usage: install-dev.sh [vN | vN.M | vN.M.P] [--pre]" >&2
    echo "  no argument  build and install this working tree" >&2
    echo "  a version    build and install that local tag (git fetch --tags first)" >&2
    echo "  --pre        let vN / vN.M pick a pre-release (-rc.N)" >&2
}

want="" pre=""
for arg in "$@"; do
    case "$arg" in
        --pre) pre=--pre ;;
        -h|--help) usage; exit 0 ;;
        v[0-9]*|[0-9]*)
            if [ -n "$want" ]; then
                echo "install-dev: one version at a time ('$want', then '$arg')" >&2; usage; exit 2
            fi
            want=$arg ;;
        *) echo "install-dev: unknown argument '$arg'" >&2; usage; exit 2 ;;
    esac
done
if [ -n "$pre" ] && [ -z "$want" ]; then
    echo "install-dev: --pre needs a version (vN or vN.M) — without one the working tree is installed" >&2
    usage; exit 2
fi

case "${KASBAH_SKIP_BUILD:-}" in
    ''|0) skip_build=0 ;;
    1)    skip_build=1 ;;
    *)    echo "install-dev: KASBAH_SKIP_BUILD='$KASBAH_SKIP_BUILD' is not a valid value" >&2
          echo "  1        install the dist/ already built" >&2
          echo "  0/empty  build first (docker compose run --rm build)" >&2
          exit 2 ;;
esac

repo_dir="$(cd "$(dirname "$0")" && pwd)"
dist="$repo_dir/dist"
# dist/kasbah must run here: darwin on a Mac (compose.yml, KASBAH_GOOS).
host_goos=linux
[ "$(uname -s)" != Darwin ] || host_goos=darwin

need_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "install-dev: docker is needed to build kasbah" >&2
        [ -n "$want" ] || echo "             (or KASBAH_SKIP_BUILD=1 to install a dist/ built elsewhere)" >&2
        exit 1
    fi
}

if [ "$skip_build" = 0 ]; then
    need_docker
    # UID is a read-only shell variable, never exported: without env the build
    # container falls back to uid 1000 and writes dist/ as somebody else. -p
    # because an exported COMPOSE_PROJECT_NAME outranks the file's `name:`, and
    # stdin from /dev/null because -T still forwards it.
    env UID="$(id -u)" GID="$(id -g)" KASBAH_GOOS="$host_goos" \
        docker compose -p kasbah -f "$repo_dir/compose.yml" run --rm -T build >&2 </dev/null
fi

if [ ! -f "$dist/kasbah" ]; then
    echo "install-dev: $dist/kasbah is missing — build it: docker compose run --rm build" >&2
    exit 1
fi
if ! "$dist/kasbah" --version >/dev/null; then
    echo "install-dev: $dist/kasbah does not run here — nothing was installed" >&2
    exit 1
fi
if [ -z "$want" ]; then
    exec "$dist/kasbah" __install
fi

if ! tags="$(git -C "$repo_dir" tag -l 'v*')"; then
    echo "install-dev: cannot list the tags of $repo_dir — a version needs a git checkout" >&2
    exit 1
fi
if ! tag="$("$dist/kasbah" __pick-tag "$want" $pre <<<"$tags")"; then
    exit 1
fi
need_docker

work="$(mktemp -d)"
project="kasbah-tag-$$"
cleanup() {
    if [ -f "$work/src/compose.yml" ]; then
        docker compose -p "$project" -f "$work/src/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "install-dev: building $tag in a temporary clone" >&2
git clone --quiet --no-checkout "$repo_dir" "$work/src" >&2 </dev/null
git -C "$work/src" -c advice.detachedHead=false checkout --quiet "refs/tags/$tag" >&2 </dev/null
# Made here, not by docker: a bind-mount point docker creates is root's, and
# the build user could then neither write .cache/ nor the cleanup remove it.
mkdir -p "$repo_dir/.cache/go-mod" "$repo_dir/.cache/go-build" \
         "$work/src/.cache/go-mod" "$work/src/.cache/go-build"
env UID="$(id -u)" GID="$(id -g)" KASBAH_GOOS="$host_goos" \
    docker compose -p "$project" -f "$work/src/compose.yml" run --rm -T \
        -v "$repo_dir/.cache/go-mod:/workspace/.cache/go-mod" \
        -v "$repo_dir/.cache/go-build:/workspace/.cache/go-build" \
        build >&2 </dev/null

reported="$("$work/src/dist/kasbah" --version)" || reported=""
read -r name ver _ <<<"$reported" || true
if [ "${name:-}" != kasbah ] || [ "${ver:-}" != "${tag#v}" ]; then
    echo "install-dev: the build of $tag reports '$reported', not kasbah ${tag#v} — nothing was installed" >&2
    if [ "$host_goos" = darwin ] && ! grep -q KASBAH_GOOS "$work/src/compose.yml"; then
        echo "  $tag predates macOS builds: its compose.yml builds a linux dist/kasbah, which cannot run here" >&2
        echo "  install a release instead: kasbah self-update $tag" >&2
    fi
    exit 1
fi
"$dist/kasbah" __install --pin "$work/src/dist"
