#!/usr/bin/env bash
# Install kasbah: this build into its own version directory
# <lib>/<build>/ — the binary, and beside it in server/ the two linux server
# binaries it ships to a VPS — and <bin>/kasbah as a symlink to the newest
# installed version. Other versions stay: the binary hands a command off to
# the one a server or a project wants. Override targets via KASBAH_BIN_DIR
# and KASBAH_LIB_DIR; KASBAH_LIB_DIR is the same variable kasbah reads at
# runtime, so a non-default location stays consistent across install and run.
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
# non-empty one must be kasbah's: version directories (*/kasbah with
# */server/kasbah-linux-*), the 1.0.x layout (server/kasbah-linux-* at the
# top), or a pre-1.0 one (VERSION with common.sh or libexec/kasbah-bash).
has_server_binaries() {
    local f d
    for f in "$1"/server/kasbah-linux-*; do
        [ -f "$f" ] && return 0
    done
    for f in "$1"/*/server/kasbah-linux-*; do
        d=${f%/server/*}
        [ -f "$f" ] && [[ ${d##*/} =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && return 0
    done
    return 1
}
is_legacy() {
    [ -f "$1/VERSION" ] && { [ -f "$1/common.sh" ] || [ -f "$1/libexec/kasbah-bash" ]; }
}
if [ -d "$lib_dir" ] && [ -n "$(ls -A "$lib_dir" 2>/dev/null)" ] \
   && ! has_server_binaries "$lib_dir" && ! is_legacy "$lib_dir"; then
    echo "install: $lib_dir is not empty and is not a kasbah library directory — refusing to remove anything there" >&2
    echo "         kasbah's holds <version>/server/kasbah-linux-* (or server/kasbah-linux-* before the launcher, or VERSION with common.sh or libexec/kasbah-bash before 1.0)" >&2
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
# install and leaves the old one in place. Its stamp names the version directory.
if ! built="$("$dist/kasbah" --version)"; then
    echo "install: $dist/kasbah does not run here — nothing was installed" >&2
    exit 1
fi
stamp=${built#kasbah }
stamp=${stamp%% (schema*}
case $stamp in
    ''|*/*|.*) echo "install: $dist/kasbah reports '$built', which does not name a version — nothing was installed" >&2; exit 1 ;;
esac

legacy=0
if is_legacy "$lib_dir"; then legacy=1; fi
ver_dir="$lib_dir/$stamp"
install -d "$bin_dir" "$ver_dir/server"

# Each file written beside its name and renamed into place, so a version
# directory never holds a half-written binary; anything else there is left alone.
install -m 0755 "$dist/kasbah" "$ver_dir/.kasbah.new"
mv -f "$ver_dir/.kasbah.new" "$ver_dir/kasbah"
for arch in amd64 arm64; do
    install -m 0755 "$dist/server/kasbah-linux-$arch" "$ver_dir/server/.kasbah-linux-$arch.new"
    mv -f "$ver_dir/server/.kasbah-linux-$arch.new" "$ver_dir/server/kasbah-linux-$arch"
done
if ! "$ver_dir/kasbah" --version >/dev/null; then
    echo "install: $ver_dir/kasbah does not run — $bin_dir/kasbah was not repointed" >&2
    exit 1
fi

# The layouts before the launcher, which nothing reads any more: the server
# binaries at the top of the library, and what a pre-1.0 install put beside them.
rm -f "$lib_dir"/server/kasbah-linux-amd64 "$lib_dir"/server/kasbah-linux-arm64
rmdir "$lib_dir/server" 2>/dev/null || :
if [ "$legacy" = 1 ]; then
    rm -rf "${lib_dir:?}/libexec" "${lib_dir:?}/templates" "${lib_dir:?}/VERSION"
    shopt -s nullglob
    rm -f "$lib_dir"/*.sh
    shopt -u nullglob
fi

# <bin>/kasbah points at the newest installed version whose kasbah runs; a
# 1.0.x install left a regular file there, which the symlink replaces.
if ! newest="$("$ver_dir/kasbah" __newest "$lib_dir")"; then
    echo "install: no installed kasbah runs under $lib_dir — $bin_dir/kasbah was not repointed" >&2
    exit 1
fi
if [ -e "$bin_dir/kasbah" ] && [ ! -L "$bin_dir/kasbah" ] && [ ! -f "$bin_dir/kasbah" ]; then
    echo "install: $bin_dir/kasbah exists and is not a regular file or a symlink — refusing to replace it" >&2
    exit 1
fi
ln -sfn "$lib_dir/$newest/kasbah" "$bin_dir/kasbah"

echo "installed $built"
echo "  bin: $bin_dir/kasbah -> $lib_dir/$newest/kasbah"
echo "  lib: $ver_dir"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not in PATH" >&2 ;;
esac
