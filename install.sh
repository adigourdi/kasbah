#!/usr/bin/env bash
# Install kasbah. Override targets via KASBAH_BIN_DIR and KASBAH_LIB_DIR.
# KASBAH_LIB_DIR is the same variable kasbah reads at runtime, so a
# non-default install location stays consistent across install and run.
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

# Installing deletes things inside $lib_dir — the stale *.sh sweep and the
# whole templates tree — and $lib_dir comes from the environment. A typo
# (KASBAH_LIB_DIR=$HOME, KASBAH_LIB_DIR=/usr/local/lib) would aim a recursive
# delete at a directory full of somebody else's files, so a non-empty target
# has to look like a kasbah library directory before anything is removed. A
# fresh or absent one is the ordinary case and passes untouched.
if [ -d "$lib_dir" ] && [ -n "$(ls -A "$lib_dir" 2>/dev/null)" ] \
   && [ ! -f "$lib_dir/VERSION" ] && [ ! -f "$lib_dir/common.sh" ]; then
    echo "install: $lib_dir is not empty and is not a kasbah library directory" >&2
    echo "         (no VERSION, no common.sh) — refusing to remove anything there" >&2
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

install -d "$bin_dir" "$lib_dir"
install -m 0755 "$dist/kasbah"      "$bin_dir/kasbah"
install -m 0644 "$repo_dir/VERSION" "$lib_dir/VERSION"

# The Bash dispatcher the binary hands unported commands to, and the server
# binaries kasbah ships to a VPS. Replaced whole, like the templates below.
rm -rf "${lib_dir:?}/libexec" "${lib_dir:?}/server"
install -d "$lib_dir/libexec" "$lib_dir/server"
install -m 0755 "$repo_dir/libexec/kasbah-bash" "$lib_dir/libexec/kasbah-bash"
for arch in amd64 arm64; do
    install -m 0755 "$dist/server/kasbah-linux-$arch" "$lib_dir/server/kasbah-linux-$arch"
done

# Remove stale *.sh so a rename/deletion upstream doesn't leave orphans behind.
shopt -s nullglob
rm -f "$lib_dir"/*.sh
for f in "$repo_dir"/lib/*.sh; do
    install -m 0644 "$f" "$lib_dir/$(basename "$f")"
done

# Templates ship beside the libraries: kasbah looks for them there when it
# is not running from a checkout, so without this an installed kasbah has
# nothing to render onto a server. The whole tree is replaced rather than
# merged, for the same reason the *.sh copy is — a template deleted upstream
# must not survive an upgrade. Modes come from the repo, so a template that has
# to be runnable on the far side (scripts/remote-deploy.sh) lands executable.
rm -rf "${lib_dir:?}/templates"
# Created whether or not there is anything to put in it: KASBAH_TEMPLATE_DIR
# resolves to this path on an installed kasbah, and a resolved path that does
# not exist is a worse error message than an empty directory.
install -d "$lib_dir/templates"
if [ -d "$repo_dir/templates" ]; then
    while IFS= read -r -d '' f; do
        rel="${f#"$repo_dir"/templates/}"
        install -d "$lib_dir/templates/$(dirname "$rel")"
        if [ -x "$f" ]; then
            install -m 0755 "$f" "$lib_dir/templates/$rel"
        else
            install -m 0644 "$f" "$lib_dir/templates/$rel"
        fi
    done < <(find "$repo_dir/templates" -type f -print0)
fi

# Asked of the installed copy, so a layout it cannot run from fails here.
installed="$(KASBAH_LIB_DIR="$lib_dir" "$bin_dir/kasbah" --version)"
echo "installed $installed"
echo "  bin: $bin_dir/kasbah"
echo "  lib: $lib_dir"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not in PATH" >&2 ;;
esac
