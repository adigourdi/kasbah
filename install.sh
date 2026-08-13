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

# Installing deletes things inside $lib_dir — the stale *.sh sweep and the
# whole templates tree — and $lib_dir comes from the environment. A typo
# (HOSTING_LIB_DIR=$HOME, HOSTING_LIB_DIR=/usr/local/lib) would aim a recursive
# delete at a directory full of somebody else's files, so a non-empty target
# has to look like a hosting library directory before anything is removed. A
# fresh or absent one is the ordinary case and passes untouched.
if [ -d "$lib_dir" ] && [ -n "$(ls -A "$lib_dir" 2>/dev/null)" ] \
   && [ ! -f "$lib_dir/VERSION" ] && [ ! -f "$lib_dir/common.sh" ]; then
    echo "install: $lib_dir is not empty and is not a hosting library directory" >&2
    echo "         (no VERSION, no common.sh) — refusing to remove anything there" >&2
    echo "         set HOSTING_LIB_DIR to an empty or previously installed path" >&2
    exit 1
fi

install -d "$bin_dir" "$lib_dir"
install -m 0755 "$repo_dir/bin/hosting" "$bin_dir/hosting"
install -m 0644 "$repo_dir/VERSION"     "$lib_dir/VERSION"

# Remove stale *.sh so a rename/deletion upstream doesn't leave orphans behind.
shopt -s nullglob
rm -f "$lib_dir"/*.sh
for f in "$repo_dir"/lib/*.sh; do
    install -m 0644 "$f" "$lib_dir/$(basename "$f")"
done

# Templates ship beside the libraries: bin/hosting looks for them there when it
# is not running from a checkout, so without this an installed hosting has
# nothing to render onto a server. The whole tree is replaced rather than
# merged, for the same reason the *.sh copy is — a template deleted upstream
# must not survive an upgrade. Modes come from the repo, so a template that has
# to be runnable on the far side (scripts/remote-deploy.sh) lands executable.
rm -rf "${lib_dir:?}/templates"
# Created whether or not there is anything to put in it: HOSTING_TEMPLATE_DIR
# resolves to this path on an installed hosting, and a resolved path that does
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

echo "installed hosting $(cat "$repo_dir/VERSION")"
echo "  bin: $bin_dir/hosting"
echo "  lib: $lib_dir"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not in PATH" >&2 ;;
esac
