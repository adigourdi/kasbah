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

Currently implemented: Structure (S01–S06). Compose / Traefik / Healthcheck /
Env / Hooks / Mail rule groups are not yet wired in.
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

    echo
    printf 'Summary: %d passed, %d warning, %d failed\n' \
        "$_CHECK_PASS" "$_CHECK_WARN" "$_CHECK_FAIL"

    [ "$_CHECK_FAIL" -eq 0 ] || exit "$HOSTING_EXIT_COMPLIANCE_FAIL"
}
