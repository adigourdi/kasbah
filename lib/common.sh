# kasbah — common shell library
# Sourced by bin/kasbah and lib/*.sh. Do not execute directly.

[ -n "${_KASBAH_COMMON_LOADED:-}" ] && return 0
_KASBAH_COMMON_LOADED=1

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
KASBAH_EXIT_NO_PROJECT=2       # no kasbah.yml in cwd
KASBAH_EXIT_SSH_UNREACHABLE=3  # the target host did not answer ssh
# No server marker at the apps path. Deliberately not "run init": on a server
# prepared with --apps-path the marker is elsewhere, and re-running init would
# render a second Traefik under the frozen `traefik` compose project and
# recreate the running proxy against it. Callers say which situation it is.
KASBAH_EXIT_NO_REMOTE_STATE=4
# The env setup did not leave a .env kasbah will deploy against, for any
# reason: drift the user declined to fix, a .env that is not there with no
# terminal to render one on, or setup-env.sh not finishing on the far side —
# including when it could not be run at all. One code, because it is one
# sentence from the operator's side and nothing was deployed. Injection is a
# different step and fails with 1 (docs/cli.md, docs/phases/03-env.md).
KASBAH_EXIT_ENV_SETUP=5
KASBAH_EXIT_COMPLIANCE_FAIL=6  # `kasbah check` recorded one or more failures

# Where the server marker lives when nobody said otherwise. `server init`
# defaults its --apps-path to this, and every project command finds the marker
# there and reads the real paths back out of it.
KASBAH_DEFAULT_APPS_PATH=/apps
