#!/usr/bin/env bash
# Install kasbah from this checkout: build it through the toolchain container
# (docker compose run --rm build), then hand dist/ to `dist/kasbah __install`,
# which places the build in its own version directory <lib>/<build>/ — the
# binary, and beside it in server/ the two linux server binaries it ships to a
# VPS — removes every other dev build (releases stay), and points
# <bin>/kasbah at the newest installed version that runs.
#
# KASBAH_BIN_DIR and KASBAH_LIB_DIR override the targets; KASBAH_LIB_DIR is
# the same variable kasbah reads at runtime. KASBAH_SKIP_BUILD=1 installs the
# dist/ already there instead of building.

set -euo pipefail

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

if [ "$skip_build" = 0 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "install-dev: docker is needed to build kasbah" >&2
        echo "             (or KASBAH_SKIP_BUILD=1 to install a dist/ built elsewhere)" >&2
        exit 1
    fi
    # UID is a read-only shell variable, never exported: without env the build
    # container falls back to uid 1000 and writes dist/ as somebody else. -p
    # because an exported COMPOSE_PROJECT_NAME outranks the file's `name:`, and
    # stdin from /dev/null because -T still forwards it.
    env UID="$(id -u)" GID="$(id -g)" \
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
exec "$dist/kasbah" __install
