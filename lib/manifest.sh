# kasbah — project manifest (kasbah.yml) reader
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_MANIFEST_LOADED:-}" ] && return 0
_KASBAH_MANIFEST_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"

# Cwd-relative by design: every project command runs from the project root.
# Overridable only for tests that can't easily chdir.
KASBAH_MANIFEST_FILE="kasbah.yml"

# Highest schema version this tool can read. See docs/project-manifest.md.
KASBAH_MANIFEST_SCHEMA=1

# Directory names kasbah owns under <apps>/, which a project therefore may not
# take. `traefik` is the dangerous one: a project called that has deploy rsync
# its compose file over the shared proxy's own, and then run
# `docker compose -p traefik up -d --remove-orphans` in <apps>/traefik — where
# the new file has no traefik service, so --remove-orphans takes the reverse
# proxy down and every site on the host with it. `data` and `backups` are the
# same collision without the blast radius: the project would be deployed into
# the bind-mount root, or into the server's backup directory.
#
# Checked here rather than in deploy, so a project learns it from
# `kasbah check` and not from the deploy that ate the proxy.
KASBAH_RESERVED_NAMES=(traefik data backups)

# manifest_name_reserved <name> — true when the name is one kasbah owns.
manifest_name_reserved() {
    local _nr_name="$1" _nr_reserved
    for _nr_reserved in "${KASBAH_RESERVED_NAMES[@]}"; do
        [ "$_nr_name" != "$_nr_reserved" ] || return 0
    done
    return 1
}

# Populated by manifest_require.
MANIFEST_SCHEMA=""
MANIFEST_KASBAH_VERSION=""
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
    [ -f "$KASBAH_MANIFEST_FILE" ] \
        || die "$KASBAH_MANIFEST_FILE: not found (cwd=$PWD)"
    yq -r "$1" "$KASBAH_MANIFEST_FILE" \
        || die "$KASBAH_MANIFEST_FILE: yq filter failed: $1"
}

# Read $KASBAH_MANIFEST_FILE from cwd, validate it, and populate MANIFEST_*
# globals. Fails fast with a specific exit code when no manifest is present
# (docs/cli.md: exit 2), and with die() on any other validation error.
manifest_require() {
    _manifest_require_yq

    if [ ! -f "$KASBAH_MANIFEST_FILE" ]; then
        err "No $KASBAH_MANIFEST_FILE in current directory."
        err_cont "Run from the project root, or \`kasbah init-project\` to scaffold."
        exit "$KASBAH_EXIT_NO_PROJECT"
    fi

    # Let yq's stderr through — YAML parse errors are the #1 user-facing
    # failure here and the line/column info is what makes them fixable.
    # The trailing "__EOM__" sentinel survives `$(...)`-newline-stripping, so
    # a truly-empty last field (e.g. domain: "") isn't silently lost.
    local raw
    raw="$(yq -r '.schema // "", .kasbah_version // "", .name // "", .domain // "", "__EOM__"' "$KASBAH_MANIFEST_FILE")" \
        || die "$KASBAH_MANIFEST_FILE: could not parse YAML (see error above)"

    # One field per line — robust against empty values (unlike @tsv + IFS=\t,
    # which collapses leading tabs since tab is IFS whitespace).
    local fields
    readarray -t fields <<<"$raw"

    # Expect 4 field lines + 1 sentinel. More (or missing sentinel) ⇒ the
    # file is multi-document YAML, which we don't support in a manifest.
    if [ "${#fields[@]}" -ne 5 ] || [ "${fields[4]}" != "__EOM__" ]; then
        die "$KASBAH_MANIFEST_FILE: expected a single YAML document"
    fi

    # Strip trailing CR from CRLF-authored manifests. Otherwise a Windows
    # `name: demo<CR>` value would fail the regex with a bewildering error
    # (the CR renders as a cursor jump, hiding the real cause).
    local i
    for i in 0 1 2 3; do fields[$i]="${fields[$i]%$'\r'}"; done

    local schema="${fields[0]}"
    local kasbah_version="${fields[1]}"
    local name="${fields[2]}"
    local domain="${fields[3]}"

    [ -n "$schema" ] \
        || die "$KASBAH_MANIFEST_FILE: missing required field 'schema'"
    [[ "$schema" =~ ^[0-9]+$ ]] \
        || die "$KASBAH_MANIFEST_FILE: schema must be an integer (got '$schema')"
    if [ "$schema" -gt "$KASBAH_MANIFEST_SCHEMA" ]; then
        die "$KASBAH_MANIFEST_FILE: schema $schema is newer than this kasbah ($KASBAH_VERSION supports schema $KASBAH_MANIFEST_SCHEMA). Upgrade kasbah."
    fi

    [ -n "$name" ] && [ "$name" != "null" ] \
        || die "$KASBAH_MANIFEST_FILE: missing required field 'name'"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
        || die "$KASBAH_MANIFEST_FILE: invalid name '$name' (must match ^[a-z][a-z0-9-]*\$)"
    ! manifest_name_reserved "$name" \
        || die "$KASBAH_MANIFEST_FILE: '$name' is reserved — kasbah owns <apps>/$name on every server (reserved: ${KASBAH_RESERVED_NAMES[*]}). Rename the project."

    # domain is allowed to be empty: `kasbah init-project` without --domain
    # writes `domain: ""` and warns. Commands that need a domain (deploy,
    # check) enforce it themselves.

    MANIFEST_SCHEMA="$schema"
    MANIFEST_KASBAH_VERSION="$kasbah_version"
    MANIFEST_NAME="$name"
    MANIFEST_DOMAIN="$domain"
}
