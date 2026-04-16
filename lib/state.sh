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
