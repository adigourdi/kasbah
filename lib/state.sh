# hosting — project state file (.hosting/state.json)
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_STATE_LOADED:-}" ] && return 0
_HOSTING_STATE_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"

# Cwd-relative by design: every project command runs from the project root.
HOSTING_STATE_FILE=".hosting/state.json"

# Write a fresh state file at $HOSTING_STATE_FILE with current hosting_version
# and nulled defaults. See docs/project-manifest.md for field semantics.
state_init() {
    command -v jq >/dev/null || die "jq is required"
    mkdir -p "$(dirname "$HOSTING_STATE_FILE")"
    jq -n --arg v "$HOSTING_VERSION" '{
        hosting_version: $v,
        last_server: null,
        last_deploy: null,
        last_version: null,
        schema_migrations_applied: []
    }' > "$HOSTING_STATE_FILE"
}

# state_get <key> <outvar> — one field, empty when the file, the key or the
# value is absent. A state file that will not parse is an error rather than a
# silent empty: the field it holds is a default the user set by deploying once,
# and quietly forgetting it sends them hunting for a USER@HOST they already gave.
state_get() {
    local _sg_key="$1" _sg_out="$2" _sg_val=""

    printf -v "$_sg_out" '%s' ""
    [ -f "$HOSTING_STATE_FILE" ] || return 0
    command -v jq >/dev/null || die "jq is required"

    _sg_val="$(jq -r --arg k "$_sg_key" '.[$k] // "" | tostring' "$HOSTING_STATE_FILE" 2>/dev/null)" \
        || die "$HOSTING_STATE_FILE: not readable as JSON — delete it, or fix it by hand"
    printf -v "$_sg_out" '%s' "${_sg_val%$'\r'}"
    return 0
}

# state_record <key> <value>... — merge fields into the state file.
#
# Merged, never rewritten: the file carries fields other commands own
# (hosting_version, schema_migrations_applied) and, one day, fields written by a
# newer hosting. Rendered to a temp file and renamed, so a reader never catches
# a half-written one. Callers invoke this only after the operation succeeded —
# docs/project-manifest.md's write rule.
state_record() {
    local _sr_args=() _sr_filter="." _sr_key _sr_value _sr_tmp _sr_current _sr_defaults

    command -v jq >/dev/null || die "jq is required"
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || die "internal: state_record got an odd number of arguments (key '$1' has no value)"
        _sr_key="$1"; _sr_value="$2"; shift 2
        [[ "$_sr_key" =~ ^[a-z][a-z0-9_]*$ ]] \
            || die "internal: '$_sr_key' is not a state field name"
        _sr_args+=(--arg "$_sr_key" "$_sr_value")
        _sr_filter="$_sr_filter | .[\"$_sr_key\"] = \$$_sr_key"
    done

    mkdir -p "$(dirname "$HOSTING_STATE_FILE")" \
        || die "could not create $(dirname "$HOSTING_STATE_FILE")"

    # A project that never ran init-project still gets a well-shaped file, and
    # so does one whose state file has lost fields: the defaults go underneath
    # whatever is already there, so a field this call does not set is present
    # and null rather than missing, and one that is already set keeps its value.
    _sr_defaults="$(jq -n --arg v "$HOSTING_VERSION" '{
        hosting_version: $v,
        last_server: null,
        last_deploy: null,
        last_version: null,
        schema_migrations_applied: []
    }')"
    _sr_current="$_sr_defaults"
    if [ -f "$HOSTING_STATE_FILE" ]; then
        _sr_current="$(jq -e --argjson defaults "$_sr_defaults" \
            'if type == "object" then $defaults + . else error("not an object") end' \
            "$HOSTING_STATE_FILE" 2>/dev/null)" \
            || die "$HOSTING_STATE_FILE: not a JSON object — hosting will not overwrite it. Look at it, then delete it."
    fi

    _sr_tmp="$HOSTING_STATE_FILE.tmp.$$"
    printf '%s' "$_sr_current" \
        | jq "${_sr_args[@]}" "$_sr_filter" > "$_sr_tmp" \
        || { rm -f "$_sr_tmp"; die "could not write $_sr_tmp"; }
    mv -f "$_sr_tmp" "$HOSTING_STATE_FILE" \
        || { rm -f "$_sr_tmp"; die "could not install $HOSTING_STATE_FILE"; }
    return 0
}
