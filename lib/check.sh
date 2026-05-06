# hosting — check command (compliance linter)
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_CHECK_LOADED:-}" ] && return 0
_HOSTING_CHECK_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/manifest.sh"

_check_usage() {
    cat <<EOF
Usage: hosting check

Runs structural checks against the current project. Exit 0 if no failures
(warnings are informational). See docs/compliance.md for the full rule set.

Currently implemented: Structure (S01–S06), Compose (C01–C05). Traefik /
Healthcheck / Env / Hooks / Mail rule groups are not yet wired in.
EOF
}

# Counters and per-line buffer; cmd_check resets them each run.
_CHECK_PASS=0
_CHECK_WARN=0
_CHECK_FAIL=0

_check_pass() { _CHECK_PASS=$((_CHECK_PASS + 1)); printf '  ✓ %s\n' "$1"; }
_check_warn() { _CHECK_WARN=$((_CHECK_WARN + 1)); printf '  ⚠ %s\n' "$1"; }
_check_fail() { _CHECK_FAIL=$((_CHECK_FAIL + 1)); printf '  ✗ %s\n' "$1"; }

# .gitignore-excludes-PATTERN: true iff a line matches PATTERN exactly. We
# don't try to interpret negations or globs here — `init-project` writes
# literal lines, and the rule is "is this line present", not "would git
# actually ignore the path" (which would need `git check-ignore`). The `tr`
# strips trailing CR so a CRLF-authored .gitignore (Windows editors) doesn't
# false-warn — same parity as manifest.sh's CR stripping.
_gitignore_has() {
    [ -f .gitignore ] && tr -d '\r' < .gitignore | grep -qxF "$1"
}

cmd_check() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _check_usage; return 0 ;;
            *)         die "check: unknown argument '$1'" ;;
        esac
    done

    _CHECK_PASS=0
    _CHECK_WARN=0
    _CHECK_FAIL=0

    # Report goes to stdout (the ✓/⚠/✗ lines do, too) so `hosting check >
    # report.txt` captures the whole thing. Diagnostics from helpers (info/
    # warn/err) keep going to stderr.
    printf 'Checking %s\n\n' "$PWD"

    echo "Structure:"

    # S01 + S02: manifest_require enforces hosting.yml exists, parses, and
    # validates schema. On failure it exits non-zero (2 if missing, 1 if
    # invalid) — that matches the docs' intent: structural failure should
    # short-circuit the whole check.
    manifest_require
    _check_pass "hosting.yml exists (schema $MANIFEST_SCHEMA)"

    # S03
    if [ -f compose.prod.yml ]; then
        _check_pass "compose.prod.yml exists"
    else
        _check_fail "compose.prod.yml missing"
    fi

    # S04
    if [ -f .env.prod.example ]; then
        _check_pass ".env.prod.example exists"
    else
        _check_fail ".env.prod.example missing"
    fi

    # S05
    if _gitignore_has '.env'; then
        _check_pass ".gitignore excludes .env"
    else
        _check_warn ".gitignore does not exclude .env"
    fi

    # S06
    if _gitignore_has '.hosting/'; then
        _check_pass ".gitignore excludes .hosting/"
    else
        _check_warn ".gitignore does not exclude .hosting/"
    fi

    _check_compose_section

    echo
    printf 'Summary: %d passed, %d warning, %d failed\n' \
        "$_CHECK_PASS" "$_CHECK_WARN" "$_CHECK_FAIL"

    [ "$_CHECK_FAIL" -eq 0 ] || exit "$HOSTING_EXIT_COMPLIANCE_FAIL"
}

# Compose rules (C01–C05). Skipped quietly when compose.prod.yml is missing —
# S03 has already failed for that case and shouting twice adds noise.
_check_compose_section() {
    [ -f compose.prod.yml ] || return 0

    echo
    echo "Compose:"

    # Preflight: ensure compose.prod.yml parses, then list services. yq's
    # stderr is suppressed here only to avoid double-reporting the parse
    # error — we re-emit a clean ✗ line ourselves.
    local services
    if ! services="$(yq -r '(.services // {}) | keys | .[]' compose.prod.yml 2>/dev/null)"; then
        _check_fail "compose.prod.yml does not parse as YAML"
        return 0
    fi

    if [ -z "$services" ]; then
        _check_warn "compose.prod.yml declares no services — skipping Compose checks"
        # C05 is independent of services — still run it.
        _check_c05_version
        return 0
    fi

    _check_c01_restart "$services"
    _check_c02_logging "$services"
    _check_c03_c04_hostingnet "$services"
    _check_c05_version
}

# C01: every service sets restart: unless-stopped (or stronger).
# Compose's default is "no", which we treat as missing. on-failure[:N] is
# accepted because some services (e.g. one-shot init helpers) legitimately
# don't want unconditional restarts.
_check_c01_restart() {
    local services="$1" svc r
    local valid='^(unless-stopped|always|on-failure(:[0-9]+)?)$'
    local bad=()
    while IFS= read -r svc; do
        r="$(yq -r ".services[\"$svc\"].restart // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        [[ "$r" =~ $valid ]] || bad+=("$svc")
    done <<<"$services"

    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All services set restart policy"
    else
        _check_fail "Services missing restart policy: ${bad[*]}"
    fi
}

# C02: every service sets logging.driver=json-file with both max-size and
# max-file. Without rotation a runaway container can fill the VPS disk.
_check_c02_logging() {
    local services="$1" svc drv ms mf
    local bad=()
    while IFS= read -r svc; do
        drv="$(yq -r ".services[\"$svc\"].logging.driver // \"\""              compose.prod.yml 2>/dev/null || echo "")"
        ms="$(yq  -r ".services[\"$svc\"].logging.options[\"max-size\"] // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        mf="$(yq  -r ".services[\"$svc\"].logging.options[\"max-file\"] // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        if [ "$drv" != "json-file" ] || [ -z "$ms" ] || [ -z "$mf" ]; then
            bad+=("$svc")
        fi
    done <<<"$services"

    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All services set json-file logging with rotation"
    else
        _check_fail "Services missing json-file logging with max-size/max-file: ${bad[*]}"
    fi
}

# C03 + C04: every service joins hosting-net, and hosting-net is declared
# external. Two equivalent shapes are supported:
#   1) Top-level `networks: { hosting-net: { external: true } }` and each
#      service references it explicitly under `networks:`.
#   2) Top-level `networks: { default: { name: hosting-net, external: true } }`
#      — services with no explicit networks key inherit it via the default.
# Anything else (mixed, missing, internal-only) fails.
_check_c03_c04_hostingnet() {
    local services="$1" svc
    local default_name default_ext hn_ext
    default_name="$(yq -r '.networks.default.name // ""'                compose.prod.yml)"
    default_ext="$(yq  -r '.networks.default.external // false'         compose.prod.yml)"
    hn_ext="$(yq       -r '.networks["hosting-net"].external // false'  compose.prod.yml)"

    local default_aliases_hn=0
    [ "$default_name" = "hosting-net" ] && default_aliases_hn=1

    # C03 — per-service join check.
    local missing_net=()
    local any_uses_hn=0
    while IFS= read -r svc; do
        local has_hn
        # `.networks` may be a list (["a", "b"]) or a dict ({a: {…}, b: {…}}).
        # Normalize to a list of names, then check membership.
        has_hn="$(yq -r "
            .services[\"$svc\"].networks
            | if . == null then []
              elif type == \"object\" then keys
              else .
              end
            | any(. == \"hosting-net\")
        " compose.prod.yml 2>/dev/null || echo "false")"

        if [ "$has_hn" = "true" ]; then
            any_uses_hn=1
        else
            # No explicit reference — service falls back to the default network.
            if [ "$default_aliases_hn" = 1 ]; then
                any_uses_hn=1
            else
                missing_net+=("$svc")
            fi
        fi
    done <<<"$services"

    if [ "${#missing_net[@]}" -eq 0 ]; then
        _check_pass "All services join hosting-net"
    else
        _check_fail "Services not on hosting-net: ${missing_net[*]}"
    fi

    # C04 — only meaningful if a service actually uses hosting-net. If nothing
    # references it, C03 has already failed and the external-flag question is
    # moot.
    if [ "$any_uses_hn" = 0 ]; then
        return 0
    fi
    if [ "$hn_ext" = "true" ] || { [ "$default_aliases_hn" = 1 ] && [ "$default_ext" = "true" ]; }; then
        _check_pass "hosting-net declared external"
    else
        _check_fail "hosting-net not declared external: true"
    fi
}

# C05: a top-level `version:` field is deprecated by modern Compose and
# silently ignored. Warn rather than fail — the file still works.
_check_c05_version() {
    local v
    v="$(yq -r '.version // ""' compose.prod.yml)"
    if [ -n "$v" ]; then
        _check_warn "compose.prod.yml uses deprecated 'version:' field"
    else
        _check_pass "No deprecated 'version:' field"
    fi
}
