# hosting — common shell library
# Sourced by bin/hosting and lib/*.sh. Do not execute directly.

[ -n "${_HOSTING_COMMON_LOADED:-}" ] && return 0
_HOSTING_COMMON_LOADED=1

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RED=$'\033[31m'
    _C_YEL=$'\033[33m'
    _C_CYA=$'\033[36m'
    _C_RST=$'\033[0m'
else
    _C_RED=""
    _C_YEL=""
    _C_CYA=""
    _C_RST=""
fi

info() { printf '%s%s%s\n' "$_C_CYA" "$*" "$_C_RST" >&2; }
warn() { printf '%swarning:%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
# err_cont — continuation line for a multi-line error: no prefix, indented
# to align under `err`'s first-line content. See docs/cli.md for the style.
err_cont() { printf '       %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# A hostname a certificate could be issued for. At least one dot; labels are
# 1-63 chars of [A-Za-z0-9-], not starting or ending with a hyphen; the final
# label is alphabetic (any length — `a.b` and `app.co.uk` both accepted).
# Shared: `init-project` validates a project domain with it, `server init` the
# apex the dashboard hangs off.
_is_fqdn() {
    local d="$1"
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]+$ ]]
}

# Exit codes — shared contract, see docs/cli.md "Exit codes".
HOSTING_EXIT_NO_PROJECT=2       # no hosting.yml in cwd
HOSTING_EXIT_SSH_UNREACHABLE=3  # the target host did not answer ssh
HOSTING_EXIT_COMPLIANCE_FAIL=6  # `hosting check` recorded one or more failures
