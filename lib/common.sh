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
# No server marker where the discovery below leads. Deliberately not "run
# init": the apps path may be one nobody has told this command about, and
# re-running init at the wrong one would render a second Traefik under the
# frozen `traefik` compose project and recreate the running proxy against it.
# Callers say which situation it is.
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

# The server's own record of where it was prepared: root-owned, world-readable,
# one absolute apps path on a line. `server init` writes it and every command
# reads it before falling back to KASBAH_DEFAULT_APPS_PATH, which is what makes
# a server prepared with --apps-path discoverable without being told. In /etc
# rather than a home directory because more than one user administers a server,
# and a per-user pointer is two operators holding different beliefs about one
# machine.
KASBAH_APPS_POINTER=/etc/kasbah/apps-path

# kasbah_norm_path OUTVAR VALUE — a path reduced to the one spelling kasbah
# compares: CR and trailing blanks off, empty and `.` segments dropped, no
# trailing slash. `/apps/`, `//apps` and `/apps/.` all name `/apps`, and every
# path flag is stored this way (`_server_init_path`, `_ss_apps_path`), so a
# value read back off a server has to be reduced the same way before it can be
# compared with one. `..` is kept as a segment: the flags reject one outright,
# so a value carrying it compares unequal, which is the safe direction.
#
# Three remote steps read /etc/kasbah/apps-path — lib/marker.sh, the `server
# init` probe and the `server status` probe — and each carries its own `norm_path`
# copy, because a payload on the far side of ssh can source nothing. Four
# implementations of one rule: tests/norm_path_test.sh asserts the three copies
# are byte-identical and drives the same table through a copy and through this
# function, which is the only thing standing between them and drift.
kasbah_norm_path() {
    local _np_out="$1" _np_p="${2%$'\r'}" _np_acc="" _np_seg
    while [ -n "$_np_p" ]; do
        case ${_np_p: -1} in
            ' '|$'\t') _np_p=${_np_p%?} ;;
            *) break ;;
        esac
    done
    case $_np_p in
        /*) ;;
        *) printf -v "$_np_out" '%s' "$_np_p"; return 0 ;;
    esac
    # Split on `/`, with globbing off for the duration and put back the way it
    # was found: a path holding `*` is a path, not a pattern, and this function
    # is not the place a caller's own `set -f` gets changed.
    local IFS=/ _np_glob=+f
    case $- in *f*) _np_glob=-f ;; esac
    set -f
    for _np_seg in $_np_p; do
        [ -n "$_np_seg" ] && [ "$_np_seg" != . ] || continue
        _np_acc="$_np_acc/$_np_seg"
    done
    set "$_np_glob"
    [ -n "$_np_acc" ] || _np_acc=/
    printf -v "$_np_out" '%s' "$_np_acc"
    return 0
}
