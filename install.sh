#!/usr/bin/env bash
# Install hosting. Override targets via HOSTING_BIN_DIR and HOSTING_LIB_DIR.
# HOSTING_LIB_DIR is the same variable bin/hosting reads at runtime, so a
# non-default install location stays consistent across install and run.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${HOSTING_BIN_DIR:-}" ] && [ -z "${HOME:-}" ]; then
    echo "install: HOME is not set (pass HOSTING_BIN_DIR explicitly)" >&2
    exit 1
fi
if [ -z "${HOSTING_LIB_DIR:-}" ] && [ -z "${XDG_DATA_HOME:-}" ] && [ -z "${HOME:-}" ]; then
    echo "install: neither HOSTING_LIB_DIR, XDG_DATA_HOME, nor HOME is set" >&2
    exit 1
fi

bin_dir="${HOSTING_BIN_DIR:-${HOME}/.local/bin}"
lib_dir="${HOSTING_LIB_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/hosting}"

install -d "$bin_dir" "$lib_dir"
install -m 0755 "$repo_dir/bin/hosting" "$bin_dir/hosting"
install -m 0644 "$repo_dir/VERSION"     "$lib_dir/VERSION"

# Remove stale *.sh so a rename/deletion upstream doesn't leave orphans behind.
shopt -s nullglob
rm -f "$lib_dir"/*.sh
for f in "$repo_dir"/lib/*.sh; do
    install -m 0644 "$f" "$lib_dir/$(basename "$f")"
done

echo "installed hosting $(cat "$repo_dir/VERSION")"
echo "  bin: $bin_dir/hosting"
echo "  lib: $lib_dir"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not in PATH" >&2 ;;
esac
