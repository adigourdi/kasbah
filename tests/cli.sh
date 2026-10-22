# Shared test helper: the kasbah binary under test. Sourced by every suite that
# runs the CLI, and by tests/integration/rig_env.sh. Never executed.
#
# KASBAH_BIN names it; unset, it is this checkout's own build, dist/kasbah
# (`docker compose run --rm build`). A relative path is taken from the current
# directory now, before a suite cd's anywhere. A suite with no binary to run
# cannot say anything about the code, so it exits 2 — the runner's "could not
# run".

[ -n "${_KASBAH_CLI_LOADED:-}" ] && return 0
_KASBAH_CLI_LOADED=1

KASBAH_BIN="${KASBAH_BIN:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist/kasbah}"
[[ $KASBAH_BIN == /* ]] || KASBAH_BIN="$PWD/$KASBAH_BIN"
export KASBAH_BIN

if [ ! -x "$KASBAH_BIN" ]; then
    echo "no kasbah binary at $KASBAH_BIN — build it: docker compose run --rm build" >&2
    exit 2
fi

# kasbah_bin_version — the build stamp of the binary under test, from its
# `kasbah <build> (schema N)` --version line. Files kasbah writes record
# VERSION, not this.
kasbah_bin_version() {
    local out
    out="$("$KASBAH_BIN" --version)" || return 1
    out="${out#kasbah }"
    printf '%s\n' "${out%% *}"
}

# kasbah_base_version — the version files written by the binary under test
# record (internal/version.Base): its stamp without the build metadata and,
# on a stamped pre-release, without the commit count and build time.
kasbah_base_version() {
    local s
    s="$(kasbah_bin_version)" || return 1
    s=${s%%+*}
    if [[ $s =~ ^(.*-.+)\.[0-9]+\.[0-9]+$ ]]; then
        s=${BASH_REMATCH[1]}
    fi
    printf '%s\n' "$s"
}
