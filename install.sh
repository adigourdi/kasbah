#!/usr/bin/env bash
# Install kasbah: the binary, and beside it the two linux server binaries it
# ships to a VPS. Override targets via KASBAH_BIN_DIR and KASBAH_LIB_DIR.
# KASBAH_LIB_DIR is the same variable kasbah reads at runtime to find the
# server binaries, so a non-default location stays consistent across install
# and run.
#
# Builds first, through the toolchain container (docker compose run --rm
# build). KASBAH_SKIP_BUILD=1 installs the dist/ already there instead.

set -euo pipefail

case "${KASBAH_SKIP_BUILD:-}" in
    ''|0) skip_build=0 ;;
    1)    skip_build=1 ;;
    *)    echo "install: KASBAH_SKIP_BUILD='$KASBAH_SKIP_BUILD' is not a valid value" >&2
          echo "  1        install the dist/ already built" >&2
          echo "  0/empty  build first (docker compose run --rm build)" >&2
          exit 2 ;;
esac

repo_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${KASBAH_BIN_DIR:-}" ] && [ -z "${HOME:-}" ]; then
    echo "install: HOME is not set (pass KASBAH_BIN_DIR explicitly)" >&2
    exit 1
fi
if [ -z "${KASBAH_LIB_DIR:-}" ] && [ -z "${XDG_DATA_HOME:-}" ] && [ -z "${HOME:-}" ]; then
    echo "install: neither KASBAH_LIB_DIR, XDG_DATA_HOME, nor HOME is set" >&2
    exit 1
fi

bin_dir="${KASBAH_BIN_DIR:-${HOME}/.local/bin}"
lib_dir="${KASBAH_LIB_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/kasbah}"

# Installing deletes inside $lib_dir, which comes from the environment, so a
# non-empty one must be kasbah's: an install (server/kasbah-linux-*) or a
# pre-1.0 one (VERSION with common.sh or libexec/kasbah-bash).
has_server_binaries() {
    local f
    for f in "$1"/server/kasbah-linux-*; do
        [ -f "$f" ] && return 0
    done
    return 1
}
is_legacy() {
    [ -f "$1/VERSION" ] && { [ -f "$1/common.sh" ] || [ -f "$1/libexec/kasbah-bash" ]; }
}
if [ -d "$lib_dir" ] && [ -n "$(ls -A "$lib_dir" 2>/dev/null)" ] \
   && ! has_server_binaries "$lib_dir" && ! is_legacy "$lib_dir"; then
    echo "install: $lib_dir is not empty and is not a kasbah library directory — refusing to remove anything there" >&2
    echo "         kasbah's holds server/kasbah-linux-*, or (before 1.0) VERSION with common.sh or libexec/kasbah-bash" >&2
    echo "         set KASBAH_LIB_DIR to an empty or previously installed path" >&2
    exit 1
fi

dist="$repo_dir/dist"
if [ "$skip_build" = 0 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "install: docker is needed to build kasbah" >&2
        echo "         (or KASBAH_SKIP_BUILD=1 to install a dist/ built elsewhere)" >&2
        exit 1
    fi
    # UID is a read-only shell variable, never exported: without env the build
    # container falls back to uid 1000 and writes dist/ as somebody else. -p
    # because an exported COMPOSE_PROJECT_NAME outranks the file's `name:`, and
    # stdin from /dev/null because -T still forwards it.
    env UID="$(id -u)" GID="$(id -g)" \
        docker compose -p kasbah -f "$repo_dir/compose.yml" run --rm -T build >&2 </dev/null
fi
for f in kasbah server/kasbah-linux-amd64 server/kasbah-linux-arm64; do
    if [ ! -f "$dist/$f" ]; then
        echo "install: $dist/$f is missing — build it: docker compose run --rm build" >&2
        exit 1
    fi
done

# Installing from dist/ into dist/ would copy each server binary onto itself.
if [ -d "$lib_dir/server" ] && [ "$(cd -P "$lib_dir/server" && pwd)" = "$(cd -P "$dist/server" && pwd)" ]; then
    echo "install: $lib_dir/server is this build's own $dist/server — refusing to install over it" >&2
    echo "         set KASBAH_LIB_DIR to a directory outside $dist" >&2
    exit 1
fi

# Asked before anything is replaced: a binary that cannot run here fails the
# install and leaves the old one in place.
if ! built="$("$dist/kasbah" --version)"; then
    echo "install: $dist/kasbah does not run here — nothing was installed" >&2
    exit 1
fi

legacy=0
if is_legacy "$lib_dir"; then legacy=1; fi
install -d "$bin_dir" "$lib_dir"
install -m 0755 "$dist/kasbah" "$bin_dir/kasbah"

# Only kasbah's two files in server/, each renamed into place; anything else
# there is left alone.
install -d "$lib_dir/server"
for arch in amd64 arm64; do
    install -m 0755 "$dist/server/kasbah-linux-$arch" "$lib_dir/server/.kasbah-linux-$arch.new"
    mv -f "$lib_dir/server/.kasbah-linux-$arch.new" "$lib_dir/server/kasbah-linux-$arch"
done
# What a pre-1.0 install put beside it, which nothing reads any more.
if [ "$legacy" = 1 ]; then
    rm -rf "${lib_dir:?}/libexec" "${lib_dir:?}/templates" "${lib_dir:?}/VERSION"
    shopt -s nullglob
    rm -f "$lib_dir"/*.sh
fi

echo "installed $built"
echo "  bin: $bin_dir/kasbah"
echo "  lib: $lib_dir"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not in PATH" >&2 ;;
esac
