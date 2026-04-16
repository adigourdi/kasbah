# hosting — project manifest (hosting.yml) reader
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_MANIFEST_LOADED:-}" ] && return 0
_HOSTING_MANIFEST_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"

# Cwd-relative by design: every project command runs from the project root.
# Overridable only for tests that can't easily chdir.
HOSTING_MANIFEST_FILE="hosting.yml"

# Highest schema version this tool can read. See docs/project-manifest.md.
HOSTING_MANIFEST_SCHEMA=1

# Populated by manifest_require.
MANIFEST_SCHEMA=""
MANIFEST_HOSTING_VERSION=""
MANIFEST_NAME=""
MANIFEST_DOMAIN=""

_manifest_require_yq() {
    command -v yq >/dev/null || die "yq is required (install python3-yq and retry)"
}

# Run a jq filter against the manifest and print the result. Dies on yq
# error (letting yq's own stderr through) so callers get a real diagnostic
# instead of silent emptiness.
manifest_get() {
    _manifest_require_yq
    [ -f "$HOSTING_MANIFEST_FILE" ] \
        || die "$HOSTING_MANIFEST_FILE: not found (cwd=$PWD)"
    yq -r "$1" "$HOSTING_MANIFEST_FILE" \
        || die "$HOSTING_MANIFEST_FILE: yq filter failed: $1"
}

# Read $HOSTING_MANIFEST_FILE from cwd, validate it, and populate MANIFEST_*
# globals. Fails fast with a specific exit code when no manifest is present
# (docs/cli.md: exit 2), and with die() on any other validation error.
manifest_require() {
    _manifest_require_yq

    if [ ! -f "$HOSTING_MANIFEST_FILE" ]; then
        err "No $HOSTING_MANIFEST_FILE in current directory."
        err_cont "Run from the project root, or \`hosting init-project\` to scaffold."
        exit "$HOSTING_EXIT_NO_PROJECT"
    fi

    # Let yq's stderr through — YAML parse errors are the #1 user-facing
    # failure here and the line/column info is what makes them fixable.
    # The trailing "__EOM__" sentinel survives `$(...)`-newline-stripping, so
    # a truly-empty last field (e.g. domain: "") isn't silently lost.
    local raw
    raw="$(yq -r '.schema // "", .hosting_version // "", .name // "", .domain // "", "__EOM__"' "$HOSTING_MANIFEST_FILE")" \
        || die "$HOSTING_MANIFEST_FILE: could not parse YAML (see error above)"

    # One field per line — robust against empty values (unlike @tsv + IFS=\t,
    # which collapses leading tabs since tab is IFS whitespace).
    local fields
    readarray -t fields <<<"$raw"

    # Expect 4 field lines + 1 sentinel. More (or missing sentinel) ⇒ the
    # file is multi-document YAML, which we don't support in a manifest.
    if [ "${#fields[@]}" -ne 5 ] || [ "${fields[4]}" != "__EOM__" ]; then
        die "$HOSTING_MANIFEST_FILE: expected a single YAML document"
    fi

    # Strip trailing CR from CRLF-authored manifests. Otherwise a Windows
    # `name: demo<CR>` value would fail the regex with a bewildering error
    # (the CR renders as a cursor jump, hiding the real cause).
    local i
    for i in 0 1 2 3; do fields[$i]="${fields[$i]%$'\r'}"; done

    local schema="${fields[0]}"
    local hosting_version="${fields[1]}"
    local name="${fields[2]}"
    local domain="${fields[3]}"

    [ -n "$schema" ] \
        || die "$HOSTING_MANIFEST_FILE: missing required field 'schema'"
    [[ "$schema" =~ ^[0-9]+$ ]] \
        || die "$HOSTING_MANIFEST_FILE: schema must be an integer (got '$schema')"
    if [ "$schema" -gt "$HOSTING_MANIFEST_SCHEMA" ]; then
        die "$HOSTING_MANIFEST_FILE: schema $schema is newer than this hosting ($HOSTING_VERSION supports schema $HOSTING_MANIFEST_SCHEMA). Upgrade hosting."
    fi

    [ -n "$name" ] && [ "$name" != "null" ] \
        || die "$HOSTING_MANIFEST_FILE: missing required field 'name'"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
        || die "$HOSTING_MANIFEST_FILE: invalid name '$name' (must match ^[a-z][a-z0-9-]*\$)"

    # domain is allowed to be empty: `hosting init-project` without --domain
    # writes `domain: ""` and warns. Commands that need a domain (deploy,
    # check) enforce it themselves.

    MANIFEST_SCHEMA="$schema"
    MANIFEST_HOSTING_VERSION="$hosting_version"
    MANIFEST_NAME="$name"
    MANIFEST_DOMAIN="$domain"
}
