# kasbah — common shell library
# Sourced by libexec/kasbah-bash and lib/*.sh. Do not execute directly.

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

# The Traefik image a first `server init` pins. Here rather than literal in
# templates/traefik/compose.yml because the template now carries a token: init
# renders this, `server upgrade-traefik` renders the tag it was given, and a
# later init renders whatever the server's own compose.yml already says. One
# constant, so "which Traefik does kasbah ship" has one answer.
KASBAH_TRAEFIK_IMAGE=traefik:v3.7.10

# The restic kasbah runs, everywhere it runs one. kasbah installs no packages
# (docs/phases/08-keep.md D1), so restic is always a container: the scheduled
# backup stack on the VPS, the credential probe `server init --with-backup`
# runs there, and `server backup-prune` on the workstation. One pin, so all
# three speak the same repository format.
KASBAH_RESTIC_IMAGE=restic/restic:0.18.0

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
# Four remote steps read /etc/kasbah/apps-path — lib/marker.sh, the `server
# init` probe, the `server status` probe and the `server prune` probe — and each
# carries its own `norm_path` copy, because a payload on the far side of ssh can
# source nothing. Five implementations of one rule:
# tests/norm_path_test.sh asserts the four copies are byte-identical and drives the same table through a copy and through this
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

# ----------------------------------------------------------------------------
# yaml_load / yaml_query / yaml_forget — one conversion per file, every rule
# ----------------------------------------------------------------------------
# `yq` here is the kislyuk wrapper: it parses YAML with PyYAML, writes the
# document out as JSON and execs `jq` with the caller's filter, exiting with
# jq's status. Which means `yq -r F file` and `jq -r F <<<"$(yq -c . file)"` are
# the same parser answering the same filter with the same exit code — the only
# difference is that the first pays ~180 ms of Python start-up and the second
# ~5 ms of jq. `kasbah check` asks one compose file thirty-odd questions, so
# converting once and querying the result is the whole rule set for the price of
# one rule.
#
# The one place the two spellings answer differently is a YAML infinity: `.inf`
# has no JSON literal, so the conversion already renders it as the largest
# double and a re-parse prints that with jq's own exponent spelling. Nothing
# kasbah reads is a float that large.
#
# **A subshell cannot fill this cache.** Nearly every reader is written
# `x="$(yaml_query …)"`, and a command substitution is a subshell: whatever it
# converts dies with it. So the conversion has to be started from the shell the
# rules run in — manifest_require loads kasbah.yml and cmd_check the two project
# files, and the substitutions below them inherit the variables. yaml_query
# still converts on a miss, so a caller nobody preloaded for gets a correct
# answer rather than an empty one; it just pays the fork.
#
# **Invalidation is explicit.** The cache is keyed by the path as given and is
# never checked against the file's mtime: a query after the file changed on disk
# answers from the conversion. Anything that writes a file it has read has to
# say so — `check --fix` calls yaml_forget on the path it renames over.
#
# Multi-document files stay multi-document: jq reads a stream of documents the
# same way yq does, so a filter still runs once per document. `-c` is not what
# makes that work — jq reads pretty-printed documents just as happily — it is
# there because the whole document is carried in a shell variable, and compact
# is a third to a half fewer bytes to hold and to feed back through a
# here-string (1.3-1.9x on this project's own files).
#
# **A document that does not parse yields nothing at all.** `yq -c` can write a
# document *and* exit non-zero, which is what a multi-document file with one
# broken document does; the JSON from a failed conversion is dropped rather than
# half-kept, so every rule downstream sees "this file did not parse" instead of
# the half of it that happened to survive. That is what cmd_check's own comment
# has always claimed — one parse error short-circuits the compose rules cleanly.
#
# A parse error is the one diagnostic a user needs (line and column), and it is
# produced once while many rules go on to ask — so a failed conversion is asked
# a second time for its stderr alone, and that text is replayed on every failed
# query for the file. A call site's own `2>/dev/null` still silences it. `$(…)`
# strips the trailing newline off what it captures, so the replay puts exactly
# one back. Stderr from a conversion that *succeeds* is dropped: a warning
# PyYAML emits about a document it went on to parse used to reach the terminal
# once per unsuppressed call site, and no rule reads one. Keeping it would mean
# either printing it on every query or separating the two streams by hand, and
# the second cost more in string handling than the forks it saved.
declare -A _KASBAH_YAML_JSON=()   # path → the JSON, one document per line
declare -A _KASBAH_YAML_RC=()     # path → 0 parsed, 2 did not; key present = loaded
declare -A _KASBAH_YAML_ERR=()    # path → yq's diagnostic, for the replay

# jq is not an extra dependency: it is what yq runs. Named anyway, because
# "kasbah check printed nothing" is a worse way to learn it is missing.
_yaml_require_jq() {
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
}

# yaml_load FILE — convert now, replacing anything cached for that path.
# Exit 2 when the file is missing or does not parse.
yaml_load() {
    local _yl_f="$1" _yl_json="" _yl_rc=0
    _yaml_require_jq

    _yl_json="$(yq -c '.' "$_yl_f" 2>/dev/null)" || _yl_rc=$?
    if [ "$_yl_rc" = 0 ]; then
        _KASBAH_YAML_JSON["$_yl_f"]="$_yl_json"
        _KASBAH_YAML_RC["$_yl_f"]=0
        _KASBAH_YAML_ERR["$_yl_f"]=""
        return 0
    fi

    # The second read is the whole cost of the failure path, and it buys the
    # diagnostic in the shape yq wrote it. Splitting the two streams out of one
    # fork means carrying the JSON through shell string operations, and those go
    # superlinear: ~30 s on a 1 MB document, against ~1.6 s of yq.
    _KASBAH_YAML_JSON["$_yl_f"]=""
    _KASBAH_YAML_RC["$_yl_f"]=2
    _KASBAH_YAML_ERR["$_yl_f"]="$(yq -c '.' "$_yl_f" 2>&1 >/dev/null)" || true
    return 2
}

# yaml_query FILE FILTER — print the filter's answer. Exit 2 when the document
# does not parse (with yq's diagnostic on stderr), or jq's own status when the
# filter fails at runtime — the same non-zero the `|| true` and `|| echo false`
# fallbacks throughout lib/check.sh are written for.
yaml_query() {
    local _yq_f="$1" _yq_filter="$2"
    if [ -z "${_KASBAH_YAML_RC[$_yq_f]+set}" ]; then
        yaml_load "$_yq_f" || true
    fi
    if [ "${_KASBAH_YAML_RC[$_yq_f]}" != 0 ]; then
        [ -z "${_KASBAH_YAML_ERR[$_yq_f]}" ] \
            || printf '%s\n' "${_KASBAH_YAML_ERR[$_yq_f]}" >&2
        return 2
    fi
    jq -r "$_yq_filter" <<<"${_KASBAH_YAML_JSON[$_yq_f]}"
}

# yaml_forget FILE — drop the entry, so the next query reads the file again.
yaml_forget() {
    local _yf_f="$1"
    unset "_KASBAH_YAML_JSON[$_yf_f]" "_KASBAH_YAML_RC[$_yf_f]" "_KASBAH_YAML_ERR[$_yf_f]"
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

# image_base REF OUTVAR — `<image>:current` → `<image>`. The last colon counts
# only when it is in the final path segment: a registry with a port
# (`reg.example:5000/app`) puts one earlier, and stripping that would ship an
# image nobody can name.
#
# Here rather than in one command's library because two of them reduce a compose
# `image:` to the repository it names, from opposite ends of the same fact:
# `build-push` to decide what to tag and save (`<base>:<version>`), and `server
# prune` to decide which repositories on a server belong to a project at all. A
# second copy of this rule is a second answer to "what is this image called",
# and prune's answer decides a deletion.
image_base() {
    local _ib_ref="$1" _ib_out="$2" _ib_base="$1"

    case "${_ib_ref##*/}" in
        *:*) _ib_base="${_ib_ref%:*}" ;;
    esac
    printf -v "$_ib_out" '%s' "$_ib_base"
    return 0
}
