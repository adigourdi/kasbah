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

# yaml_get CONTENT FILTER OUTVAR — one keyed lookup against a YAML document
# held in a variable. Exit 2 means the document did not parse, which every
# caller keeps distinct from "the key is not there": kasbah reuses what is on
# the server rather than regenerating it, and a file it cannot read is a file it
# cannot reuse from.
#
# Here rather than in one command's library because four of them ask the same
# question of the same file. `server init` reads <apps>/mail/kasbah.yml back to
# reproduce it, `server add-mail-domain` to append to it, `deploy` to answer a
# project's mail claim against it, and `check --server` to answer M03 and to
# learn which mail hostnames T05 must reserve — one registry, one reader. The VPS has no
# yq, jq or python3 and keeping it that way is deliberate (docs/mail.md), so
# every one of those reads base64s the file back and parses it here.
yaml_get() {
    local _yg_content="$1" _yg_filter="$2" _yg_out="$3" _yg_val=""

    printf -v "$_yg_out" '%s' ""
    [ -n "$_yg_content" ] || return 0
    _yg_val=$(printf '%s' "$_yg_content" | yq -r "$_yg_filter" 2>/dev/null) || return 2
    case $_yg_val in null) _yg_val="" ;; esac
    printf -v "$_yg_out" '%s' "${_yg_val%$'\r'}"
    return 0
}

# traefik_dashboard_apex CONTENT OUTVAR — the apex the dashboard router hangs
# off, read out of <apps>/traefik/dynamic/_shared.yml. Empty when the rule is
# not the shape kasbah renders; exit 2 when the document does not parse
# (yaml_get's contract).
#
# Here rather than in `server init`'s library because two commands ask the same
# question of the same file, and the answer is the server's apex: init recovers
# the domain it must not regenerate, and `check --server` needs it to tighten
# T05 from a first-label heuristic to the exact `traefik.<apex>` the dashboard
# actually claims. The file in effect stays the single source of truth for it —
# it is deliberately not in the server marker — so a rule an operator rewrote
# into some other shape yields nothing here, and the caller says so rather than
# guessing.
traefik_dashboard_apex() {
    local _xd_content="$1" _xd_out="$2" _xd_rule="" _xd_rc=0
    local _xd_re='^Host\(`traefik\.([^`]+)`\)$'

    yaml_get "$_xd_content" '.http.routers["traefik-dashboard"].rule // ""' _xd_rule \
        || _xd_rc=$?
    [ "$_xd_rc" -eq 0 ] || return "$_xd_rc"

    printf -v "$_xd_out" '%s' ""
    if [[ "$_xd_rule" =~ $_xd_re ]]; then
        printf -v "$_xd_out" '%s' "${BASH_REMATCH[1]}"
    fi
    return 0
}
