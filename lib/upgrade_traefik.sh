# kasbah — server upgrade-traefik: a managed Traefik version bump
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_UPGRADE_TRAEFIK_LOADED:-}" ] && return 0
_KASBAH_UPGRADE_TRAEFIK_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
# For the readers and the renderer, deliberately borrowed rather than copied.
# `server init` already recovers the four values a re-render must reproduce out
# of the two files that hold them, and already renders the three templates; an
# upgrade that re-derived either would be a second answer to "what is the
# dashboard hash" and a second renderer to keep in step. Sourcing it defines
# functions and sets defaults — nothing runs.
. "$KASBAH_LIB_DIR/server_init.sh"

# `kasbah server upgrade-traefik USER@HOST --version=<tag>` moves the shared
# proxy to another Traefik image, with the two halves docs/traefik.md →
# Upgrading Traefik describes:
#
#   1. **Backup before overwrite.** compose.yml, traefik.yml and
#      dynamic/_shared.yml are kasbah's outright (docs/traefik.md → Ownership)
#      and are re-rendered from this kasbah's templates on the way through, the
#      same as `server init` does. The bytes that were on the server are copied
#      to <apps>/traefik/backups/<UTC stamp>/ first. That copy is the whole of
#      the difference between this command and init: neither asks.
#   2. **The dry-run, which is the point of the command.** A throwaway Traefik
#      of the *target* version is booted with the live dynamic directory mounted
#      read-only, and the upgrade fails on a config error in its log — before
#      anything switches. It validates every fragment in that directory, not
#      just kasbah's: `_shared.yml`, `_mail.yml` and every project's
#      `<project>.yml`.
#
# **It upgrades a stack it can read whole, and repairs nothing.** The four
# values a re-render has to reproduce — the dashboard apex, its basic-auth
# entry, the ACME address and the `caServer` in effect — all come back off the
# server, and a stack that will not yield one of them is refused with a pointer
# at `server init`. Inventing any of them here would lock the operator out of
# the dashboard or move a server's CA as a side effect of a version bump.
#
# **One dependency on Traefik's log format, named so it is legible when it
# breaks.** Both the exemption and the anchor read the CA URL off the *same
# line* as "Unable to obtain ACME certificate for domains" — measured on
# v3.5-v3.7. A future tag that split that field onto another line, or dropped
# it, would make every ACME attempt read as a config error, and the run would
# fail **closed** with "traefik:vX rejects the configuration already on HOST"
# over a configuration that is perfectly healthy. The tell is the reported error
# lines: if every one of them is an ACME line naming this run's own
# 127.0.0.1:1 CA, the classifier has stopped recognising its own noise and the
# fragments are fine. `_UT_DRY_ACME_ERROR` and `_UT_DRY_CA` are what to adjust.
#
# **acme.json is never opened for writing.** The certificates are the thing that
# has to survive a version bump, and this command has no business touching the
# store: the run digests it before and after and reports whether the new Traefik
# wrote to it, which is an observation and never a failure — a renewal that
# lands during the restart is normal.
#
# Ordering, and what a failure at each step leaves behind. `server init`'s
# header states the invariant this holds to: nothing is created until every read
# has been judged.
#
#   read stack   → read-only. A failure leaves the old proxy running, untouched.
#   dry-run      → creates a temp directory under the server's TMPDIR and one
#                  container on `--network none`, both removed by its own trap.
#                  It also *pulls the target image*, which is why the pull
#                  cannot fail later, mid-switch. A failure leaves the old proxy
#                  running on the old version, and its own leftovers are swept
#                  by name and by label on the next run.
#   backup       → creates <apps>/traefik/backups/<stamp>/ and copies three
#                  files into it. A failure leaves a directory of copies and
#                  nothing live changed.
#   ship         → overwrites, dynamic/_shared.yml **last**, because that one is
#                  watched and takes effect the moment it lands. Everything
#                  shipped has been through the dry-run, so a live reload of it
#                  is a reload of validated configuration. A failure part-way
#                  leaves the old container running against files that are valid
#                  but newer than it — `server init` leaves exactly the same
#                  state, and the report names the backup.
#   start        → the one irreducible risk, and the only step that can take
#                  sites down. It recreates the container and waits for health;
#                  if that fails it copies the backup back **on the server**,
#                  brings the old version up again and says so. The restore is
#                  in the same remote script rather than a round trip later, so
#                  it does not depend on this end still being there.

_UT_TARGET=""
_UT_VERSION=""
_UT_APPS_PATH=""
_UT_DATA_PATH=""

declare -A _UT_FACT=()
# The three kasbah-owned files as they are on the server right now, keyed the
# way `server init` keys them, and the four values recovered out of two of them.
declare -A _UT_CURRENT=()
_UT_IMAGE_NOW=""
_UT_IMAGE_NEW=""
_UT_FRAGMENTS=()
_UT_TMPDIR=""
_UT_CHANGED=()
_UT_STAMP=""
_UT_BACKUP_DIR=""
_UT_DRY_ROUTERS=""

# The compose project name is frozen: the live stack is `docker compose -p
# traefik`, and anything else here would bring a *second* proxy up beside it.
_UT_PROJECT=traefik

# The throwaway's isolation, in four values.
#
# It runs on `--network none`, so it has no route to anything — not to the
# backends the fragments name, not to a CA, and nothing can reach it. It
# publishes no port: the live Traefik holds :80 and :443 and a second bind
# either fails or, worse, succeeds the moment the first dies. Its entrypoints
# are moved to :8080/:8443 inside its own namespace as well, so the isolation
# does not rest on remembering to leave `-p` off. Its own name carries a stamp,
# so a leftover can never be mistaken for this run's, and its label is what the
# next run sweeps by.
_UT_DRY_LABEL=kasbah.role=traefik-dry-run
# The CA the dry-run points at, and the string that identifies its own noise in
# the log. 127.0.0.1:1 refuses instantly on every host, so the throwaway
# registers no ACME account, answers no challenge and spends no rate-limit
# budget — and the one error family that produces is excluded from the verdict
# by a URL kasbah chose, which no genuine error can carry.
_UT_DRY_CA="https://127.0.0.1:1/kasbah-dry-run-no-ca"
_UT_DRY_ACME_ERROR="Unable to obtain ACME certificate for domains"
# What the dry-run must be seen to have loaded. Every TLS router the file
# provider builds produces exactly one excluded ACME line naming itself, so the
# lines filtered *out* of the verdict are the same lines that prove something
# was read — a dry-run that read nothing has none of them and cannot pass by
# silence (measured: an empty dynamic directory logs nothing at ERR at all).
#
# **Which router, though.** The throwaway mounts two things: the server's
# `dynamic/` directory, and kasbah's freshly rendered `_shared.yml` laid over
# its own copy inside it. `traefik-dashboard@file` comes from that overlay — a
# file this side wrote and shipped as an argument — so seeing it proves the file
# provider ran and read *kasbah's own file*, and nothing at all about the
# server's directory. A mount that silently resolved empty would still produce
# it, and the run would report "passed" having validated only what it brought
# with it.
#
# So the verdict asks for both, as a conjunction: `traefik-dashboard@file` for
# "the file provider ran", **and** a router that is not one of `_shared.yml`'s
# for "the server's directory applied" — the second can only have come off the
# server. The second is required whenever the directory read in step 2 holds a
# fragment besides `_shared.yml`, which is the only case where there is anything
# on the server's side to prove was read. A directory holding kasbah's overlay
# alone asks the first half only: there are no project fragments to validate, so
# "the file provider ran" is the strongest true statement, and the run says
# exactly that out loud rather than letting the pass line imply more.
#
# `_UT_SHARED_ROUTERS` is the router names `_shared.yml` itself declares — the
# only two the overlay can contribute. Only the TLS one ever reaches the log
# (the `web` half carries no `tls:`, so it asks for no certificate and names
# itself nowhere); it is listed anyway so that a future `tls:` on it cannot
# quietly become the anchor. Everything else counts as the server's, including
# kasbah's own `_mail.yml`: that file is *not* overlaid, so a router out of it
# is evidence the server's directory was read, which is the whole property.
_UT_DRY_ANCHOR='traefik-dashboard@file'
_UT_SHARED_ROUTERS=('traefik-dashboard@file' 'traefik-dashboard-http@file')
# The one name in dynamic/ that kasbah overlays, so a fragment list holding only
# this is a server with nothing of its own to read (_SI_TRAEFIK_FILES's
# `dynamic/_shared.yml`, basename).
_UT_SHARED_FRAGMENT='_shared.yml'

_server_upgrade_traefik_usage() {
    cat <<EOF
Usage: kasbah server upgrade-traefik USER@HOST --version=<tag>

Moves the shared Traefik proxy to another image tag. Two halves:

  * the three kasbah-owned files — compose.yml, traefik.yml and
    dynamic/_shared.yml — are re-rendered from this kasbah's templates and
    the bytes already on the server are copied to
    <apps>/traefik/backups/<UTC stamp>/ before anything is overwritten.
    They are kasbah's outright (docs/traefik.md), so nothing is asked;
    the backup is what \`server init\` does not do.

  * a throwaway Traefik of the target version is booted first, with the
    live dynamic directory mounted read-only, and the upgrade fails on a
    config error in its log. It validates every fragment in that
    directory — _shared.yml, _mail.yml and every project's own — before
    the live proxy is touched.

Flags:
  --version=<tag>   the Traefik image tag to move to, e.g. v3.7.10

The dashboard apex, its basic-auth entry, the ACME address and the ACME
endpoint are read back off the server and reproduced. A stack that will not
yield all four is refused: repairing one is \`kasbah server init\`'s job, and
this command must not move a server's CA or its dashboard credentials as a
side effect of a version bump. acme.json is never written.

There is no --apps-path: where the server was prepared is the server's own
answer ($KASBAH_APPS_POINTER, falling back to $KASBAH_DEFAULT_APPS_PATH).
EOF
}

# --- Command line -------------------------------------------------------------

# The tag reaches a compose file, a `docker run` argument and a `docker compose`
# pull, so it is checked against Docker's own tag grammar rather than trusted:
# 128 characters of [A-Za-z0-9_.-] that do not start with a period or a hyphen.
# That excludes every character that could end the YAML scalar it is substituted
# into, and `/` and `:` besides — so a value that names a whole image reference
# is refused here rather than rendered into `image: traefik:reg/x:y`.
_ut_check_version() {
    local _cv_tag="${1%$'\r'}"

    [ -n "$_cv_tag" ] || die "server upgrade-traefik: --version= must not be empty"
    case $_cv_tag in
        */*) die "server upgrade-traefik: --version=$_cv_tag looks like an image reference — give the tag alone (the repository is always 'traefik')" ;;
        *:*) die "server upgrade-traefik: --version=$_cv_tag looks like an image reference — give the tag alone (the repository is always 'traefik')" ;;
    esac
    [[ "$_cv_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
        || die "server upgrade-traefik: --version=$_cv_tag is not a Docker tag (letters, digits, '_', '.' and '-', up to 128 characters, not starting with '.' or '-')"
    _UT_VERSION="$_cv_tag"
    return 0
}

_server_upgrade_traefik_parse_args() {
    _UT_TARGET=""
    _UT_VERSION=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --version=*) _ut_check_version "${1#*=}" ;;
            --version)   die "server upgrade-traefik: --version needs a value (--version=v3.7.10)" ;;
            -h|--help)   _server_upgrade_traefik_usage; exit 0 ;;
            -*)          die "server upgrade-traefik: unknown flag '${1%%=*}' (expected --version=<tag>)" ;;
            *)
                [ -z "$_UT_TARGET" ] \
                    || die "server upgrade-traefik: unexpected argument '$1' (USER@HOST is given once)"
                _UT_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_UT_TARGET" ] \
        || die "server upgrade-traefik: USER@HOST is required (the user kasbah deploys as is not optional)"
    [ -n "$_UT_VERSION" ] \
        || die "server upgrade-traefik: --version=<tag> is required — this command exists to change it, and there is no default to fall back on"
    return 0
}

# --- The fact protocol ---------------------------------------------------------

# Folds a remote report into the fact table and checks the key set before any
# value is read: a truncated step must not be absorbed into a decision about the
# proxy that holds :80 for every site (docs/phases/01-rig.md, from 1.3).
#
# `_shared.yml` carries the dashboard's bcrypt hash, so its blob is never echoed
# back in the diagnostic — `server status` keeps the same list for the same
# reason.
_ut_absorb_checked() {
    local _ac_what="$1" _ac_out="$2"; shift 2
    local _ac_line _ac_key _ac_shown=0
    local _ac_missing=()
    local _ac_secret=" traefik_shared_b64 acme_digest "

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _UT_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_UT_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    [ "${#_ac_missing[@]}" -gt 0 ] || return 0

    err "$_ac_what on $_UT_TARGET reported no ${_ac_missing[*]}"
    err_cont "the step was truncated, or the remote shell rejected it — raw output:"
    while IFS= read -r _ac_line; do
        _ac_shown=$((_ac_shown + 1))
        if [ "$_ac_shown" -gt 20 ]; then
            err_cont "| … and more, not shown"
            break
        fi
        case $_ac_secret in
            *" ${_ac_line%%=*} "*) _ac_line="${_ac_line%%=*}=<redacted>" ;;
            *) [ "${#_ac_line}" -le 120 ] \
                   || _ac_line="${_ac_line:0:120}… (${#_ac_line} bytes in all)" ;;
        esac
        err_cont "| $_ac_line"
    done <<<"$_ac_out"
    exit 1
}

# base64 back to bytes, with the `printf x` sentinel that keeps a trailing
# newline $(…) would eat — the comparisons below are byte-for-byte.
_ut_b64_decode() {
    local _bd_enc="$1" _bd_out="$2" _bd_dec
    _bd_dec=$( { printf '%s' "$_bd_enc" | base64 -d 2>/dev/null; printf x; } )
    printf -v "$_bd_out" '%s' "${_bd_dec%x}"
    return 0
}

# --- Step 1: read the stack ----------------------------------------------------

# One round trip for every fact the verdicts need: the three kasbah-owned files,
# what is in the dynamic directory, what the live container is, and a digest of
# acme.json. Nothing is created and nothing is parsed on the far side — the VPS
# has no yq, jq or python3 and keeps needing none (docs/server-setup.md).
_ut_read_stack() {
    local out rc=0 rel enc

    out=$(ssh_script "$_UT_APPS_PATH" "$_UT_DATA_PATH" "$_UT_PROJECT" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
project=$3
dir="$apps/traefik"
acme="$data/traefik/letsencrypt/acme.json"

# One line of base64 per file, for the reason every other kasbah probe uses it:
# this output is a key=value protocol and a YAML file sent raw would arrive as a
# dozen keys. openssl is on the prerequisites table; `base64 -w0` is not.
emit() {
    local enc=""
    if [ -f "$2" ]; then enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""; fi
    printf '%s=%s\n' "$1" "$enc"
}

emit traefik_compose_b64 "$dir/compose.yml"
emit traefik_static_b64  "$dir/traefik.yml"
emit traefik_shared_b64  "$dir/dynamic/_shared.yml"

# Every file the file provider will actually read, by Traefik's own rule: it
# switches on the extension and skips anything that is not .yml, .yaml or .toml.
# Names only — the fragments are validated by booting Traefik against them, not
# by parsing them here.
frags=""
if [ -d "$dir/dynamic" ]; then
    for f in "$dir/dynamic"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.yml|*.yaml|*.toml) frags="$frags${f##*/}"$'\n' ;; esac
    done
fi
printf 'fragments_b64=%s\n' "$(printf '%s' "$frags" | openssl base64 -A)"

# The certificate store: its state and, when there is one, its digest. Read
# and never written — the digest exists so the run can say afterwards whether
# the new Traefik wrote to it.
if   [ ! -e "$acme" ]; then printf 'acme_state=absent\n';  printf 'acme_digest=\n'
elif [ ! -f "$acme" ]; then printf 'acme_state=notfile\n'; printf 'acme_digest=\n'
elif [ ! -s "$acme" ]; then printf 'acme_state=empty\n';   printf 'acme_digest=\n'
else
    printf 'acme_state=nonempty\n'
    d=$(openssl dgst -sha256 -r < "$acme" 2>/dev/null) || d=""
    printf 'acme_digest=%s\n' "${d%% *}"
fi

# The live container, through compose and its frozen project name, so that a
# container called `traefik` that this stack does not own is not mistaken for it.
state=absent; health=none; image=""; cid=""
if command -v docker >/dev/null 2>&1; then
    printf 'docker=yes\n'
    if [ -d "$dir" ]; then
        cid=$(cd "$dir" && docker compose -p "$project" ps -a -q traefik 2>/dev/null) || cid=""
    fi
    if [ -n "$cid" ]; then
        state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null) || state=unknown
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null) || health=none
        image=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null) || image=""
    fi
else
    printf 'docker=no\n'
fi
printf 'traefik_state=%s\n' "$state"
printf 'traefik_health=%s\n' "$health"
printf 'traefik_running_image=%s\n' "$image"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the Traefik stack on $_UT_TARGET (the remote step exited $rc, see above)"

    _ut_absorb_checked "the Traefik stack read" "$out" \
        traefik_compose_b64 traefik_static_b64 traefik_shared_b64 \
        fragments_b64 acme_state acme_digest docker \
        traefik_state traefik_health traefik_running_image

    [ "${_UT_FACT[docker]}" = yes ] \
        || die "docker is not on $_UT_TARGET's PATH — this host is not running a kasbah Traefik stack"

    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        enc="${_UT_FACT[${_SI_TRAEFIK_KEY[$rel]}]}"
        _ut_b64_decode "$enc" "_UT_CURRENT[$rel]"
        [ -n "${_UT_CURRENT[$rel]}" ] || _ut_no_stack "$rel"
    done

    local frags=""
    _ut_b64_decode "${_UT_FACT[fragments_b64]}" frags
    _UT_FRAGMENTS=()
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        _UT_FRAGMENTS+=("$line")
    done <<<"$frags"
    return 0
}

# The refusal that keeps this command an upgrade and not a repair. Deliberately
# not "re-run init for me": init at the wrong apps path renders a second stack
# under the frozen `traefik` project name and recreates the running proxy
# against it (docs/cli.md → exit 4), so the operator is told which file is
# missing and left to decide.
_ut_no_stack() {
    err "$_UT_APPS_PATH/traefik/$1 is missing or unreadable on $_UT_TARGET"
    err_cont "upgrade-traefik re-renders the three kasbah-owned files and needs the ones"
    err_cont "already there to recover the dashboard apex, its credentials, the ACME"
    err_cont "address and the endpoint in effect. It will not invent any of them."
    err_cont "Run \`kasbah server init $_UT_TARGET\` to lay the stack down first."
    exit 1
}

# --- Step 2: the four values, recovered ---------------------------------------

# Every one of them comes back off the server and is reproduced verbatim. The
# readers are `server init`'s, so there is one parser per fact.
_ut_recover_values() {
    local shared="${_UT_CURRENT[dynamic/_shared.yml]}"
    local static="${_UT_CURRENT[traefik.yml]}"
    local compose="${_UT_CURRENT[compose.yml]}"
    local rc=0

    traefik_dashboard_apex "$shared" _SI_DASHBOARD_DOMAIN || rc=$?
    [ "$rc" -eq 0 ] || _ut_unreadable dynamic/_shared.yml
    [ -n "$_SI_DASHBOARD_DOMAIN" ] \
        || _ut_missing_value "the dashboard router's rule" dynamic/_shared.yml \
               "--domain="

    _si_extract_auth "$shared" _SI_AUTH_ENTRY || rc=$?
    [ "$rc" -eq 0 ] || _ut_unreadable dynamic/_shared.yml
    [ -n "$_SI_AUTH_ENTRY" ] \
        || _ut_missing_value "the dashboard's basic-auth entry" dynamic/_shared.yml \
               "--traefik-auth=user:pass"

    _si_extract_email "$static" _SI_ACME_EMAIL || rc=$?
    [ "$rc" -eq 0 ] || _ut_unreadable traefik.yml
    [ -n "$_SI_ACME_EMAIL" ] \
        || _ut_missing_value "the ACME registration address" traefik.yml "--email="

    # The endpoint is recovered rather than decided, which is the one place this
    # command deliberately differs from init. Init decides the CA on every run
    # and archives acme.json when that moves it; a version bump that moved a
    # server's CA as a side effect would strand every certificate in the store
    # behind a resolver pointing somewhere else — and this command does not
    # touch the store, so it has no way to make that good.
    _si_extract_ca "$static" _SI_ACME_CA || rc=$?
    [ "$rc" -eq 0 ] || _ut_unreadable traefik.yml
    [ -n "$_SI_ACME_CA" ] \
        || _ut_missing_value "the ACME endpoint (caServer)" traefik.yml \
               "--acme-staging (or without it for production)"

    _si_extract_image "$compose" _UT_IMAGE_NOW || rc=$?
    [ "$rc" -eq 0 ] || _ut_unreadable compose.yml
    [ -n "$_UT_IMAGE_NOW" ] \
        || _ut_missing_value "the traefik service's image" compose.yml "--version="

    _UT_IMAGE_NEW="traefik:$_UT_VERSION"
    return 0
}

_ut_unreadable() {
    err "$_UT_APPS_PATH/traefik/$1 on $_UT_TARGET is not valid YAML"
    err_cont "kasbah reproduces the values already in effect rather than regenerating them,"
    err_cont "and it cannot read them out of this file. Fix it, or re-render the stack with"
    err_cont "\`kasbah server init $_UT_TARGET\`, which owns that file and will replace it."
    exit 1
}

_ut_missing_value() {
    err "$2 on $_UT_TARGET does not say what $1 is"
    err_cont "upgrade-traefik reproduces it verbatim and will not invent one — a bump that"
    err_cont "changed it would be a side effect nobody asked for."
    err_cont "\`kasbah server init $_UT_TARGET $3\` sets it; this command only moves the version."
    exit 1
}

# --- Step 3: render ------------------------------------------------------------

_ut_cleanup() {
    [ -n "$_UT_TMPDIR" ] || return 0
    rm -rf -- "$_UT_TMPDIR"
    _UT_TMPDIR=""
    return 0
}

# The three files, through `server init`'s own renderer and templates, plus the
# static configuration the throwaway boots on.
#
# That fourth file is the rendered traefik.yml with four values reassigned, not
# a second template: what the dry-run has to host the fragments under is the
# static config that is about to be shipped, and a hand-written stand-in would
# drift from it. The reassignments are the isolation — entrypoints moved off
# :80/:443, a CA that refuses on the loopback, and a storage path inside the
# throwaway that is not the real acme.json and is never mounted from it.
_ut_render() {
    local rel dst yq_err tpl="${KASBAH_TEMPLATE_DIR:-}"

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -d "$tpl/traefik" ] \
        || die "the Traefik templates are missing (looked in $tpl/traefik) — this kasbah installation is incomplete"

    _UT_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-upgrade.XXXXXX")" \
        || die "could not create a temp directory to render the Traefik stack in"

    _SI_SUBST=(
        [APPS_PATH]="$_UT_APPS_PATH"
        [DATA_PATH]="$_UT_DATA_PATH"
        [ACME_EMAIL]="$_SI_ACME_EMAIL"
        [ACME_CA]="$_SI_ACME_CA"
        [DASHBOARD_DOMAIN]="$_SI_DASHBOARD_DOMAIN"
        [DASHBOARD_AUTH]="$_SI_AUTH_ENTRY"
        [TRAEFIK_IMAGE]="$_UT_IMAGE_NEW"
    )

    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        dst="$_UT_TMPDIR/$rel"
        _si_render_template "$tpl/traefik/$rel" "$dst" "$rel"
        if ! yq_err="$(yq -e . "$dst" 2>&1 >/dev/null)"; then
            err "the rendered Traefik $rel is not valid YAML — refusing to ship it"
            err_cont "${yq_err:-yq rejected the file and said nothing}"
            err_cont "the values recovered from $_UT_TARGET were:"
            err_cont "  domain      $_SI_DASHBOARD_DOMAIN"
            err_cont "  acme email  $_SI_ACME_EMAIL"
            err_cont "  acme ca     $_SI_ACME_CA"
            err_cont "  image       $_UT_IMAGE_NEW"
            exit 1
        fi
    done

    yq -y --arg ca "$_UT_DRY_CA" \
        '.entryPoints.web.address = ":8080"
         | .entryPoints.websecure.address = ":8443"
         | .certificatesResolvers.letsencrypt.acme.caServer = $ca
         | .certificatesResolvers.letsencrypt.acme.storage = "/tmp/kasbah-dry-run-acme.json"
         | .log.level = "INFO"' \
        "$_UT_TMPDIR/traefik.yml" > "$_UT_TMPDIR/dry-run.yml" \
        || die "could not build the dry-run static configuration from the rendered traefik.yml"
    [ -s "$_UT_TMPDIR/dry-run.yml" ] \
        || die "the dry-run static configuration came out empty — yq produced nothing"

    _UT_CHANGED=()
    local rendered
    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        rendered="$(cat "$_UT_TMPDIR/$rel"; printf x)" || die "could not read $_UT_TMPDIR/$rel"
        rendered="${rendered%x}"
        [ "$rendered" != "${_UT_CURRENT[$rel]}" ] || continue
        _UT_CHANGED+=("$rel")
    done
    return 0
}

# --- Step 4: the dry-run -------------------------------------------------------

# A throwaway Traefik of the target version, booted on the live dynamic
# directory mounted read-only, with the freshly rendered `_shared.yml` laid over
# its own copy — so what is validated is the configuration that will be live
# after the switch, not the one being replaced.
#
# **What counts as a config error.** Every line Traefik logs at `ERR`, with one
# family excluded: the certificate it cannot obtain from the CA this run pointed
# it at. That exclusion is anchored on both the message and the loopback URL
# kasbah itself chose, so nothing a real configuration can produce falls into
# it. Measured against traefik:v3.7.10 on the rig, every one of these is an ERR
# line and every one of them fails the upgrade:
#
#   unparseable YAML   Cannot start the provider *file.Provider error="collecting
#                      file configs: …/p.yml: yaml: line 2: did not find …"
#   unknown field      … error="collecting file configs: …: field not found, node: x"
#   missing middleware error="middleware \"nope@file\" does not exist" routerName=a@file
#   unparseable rule   error="error while parsing rule Hostx(`a.test`…" routerName=a@file
#   unknown resolver   Router uses a nonexistent certificate resolver
#   unknown entrypoint EntryPoint doesn't exist / No valid entryPoint for this router
#
# Warnings are reported and never fatal: a version bump is exactly when Traefik
# starts announcing deprecations, and a command that refused on those could not
# be used for the thing it exists for.
#
# **And it cannot pass by reading nothing.** The excluded lines are the proof:
# the file provider emits one per TLS router it built out of the mounted
# fragments, naming it. The verdict requires the dashboard router *and*, when the
# server's directory holds any fragment besides `_shared.yml`, a router that is
# not `_shared.yml`'s — see `_UT_SHARED_ROUTERS`. The dashboard router comes from
# the copy this run rendered and laid over the mount, so it alone would still
# appear if the server's directory resolved empty. An empty dynamic directory
# produces no error either, and is a hard failure rather than a pass (measured:
# an empty directory logs nothing at ERR at all).
_ut_dry_run() {
    local out rc=0 shared_b64 static_b64

    shared_b64="$(openssl base64 -A -in "$_UT_TMPDIR/dynamic/_shared.yml")" \
        || die "internal: could not encode the rendered _shared.yml"
    static_b64="$(openssl base64 -A -in "$_UT_TMPDIR/dry-run.yml")" \
        || die "internal: could not encode the dry-run static configuration"

    info "Dry run: booting $_UT_IMAGE_NEW against ${#_UT_FRAGMENTS[@]} fragment(s) in $_UT_APPS_PATH/traefik/dynamic (read-only)"

    out=$(ssh_script "$_UT_APPS_PATH" "$_UT_IMAGE_NEW" "$shared_b64" "$static_b64" \
                     "$_UT_DRY_LABEL" "$_UT_STAMP" "$_UT_DRY_ACME_ERROR" "$_UT_DRY_CA" 120 <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
image=$2
shared_b64=$3
static_b64=$4
label=$5
stamp=$6
acme_msg=$7
dry_ca=$8
timeout_s=$9

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

name="kasbah-traefik-dry-run-$stamp"
work=""
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1
    [ -z "$work" ] || rm -rf -- "$work"
}
# HUP as well as EXIT: this end dies with the ssh session, and a throwaway that
# outlived a dropped connection would be the one thing this command leaves
# behind.
trap cleanup EXIT HUP INT TERM

# Anything a previous run left behind, swept by the label rather than by name —
# a crashed run's container carries its own stamp and nothing here can guess it.
# Inert either way: no published port, no network, read-only mounts.
swept=0
stale=$(docker ps -aq --filter "label=$label" 2>/dev/null) || stale=""
while IFS= read -r c; do
    [ -n "$c" ] || continue
    docker rm -f "$c" >/dev/null 2>&1 && swept=$((swept + 1))
done <<<"$stale"
printf 'dry_swept=%s\n' "$swept"

work=$(mktemp -d "${TMPDIR:-/tmp}/kasbah-dry-run.XXXXXX") || fail "could not create a temp directory"
printf '%s' "$static_b64" | openssl base64 -d -A > "$work/traefik.yml" || fail "could not write the dry-run static config"
printf '%s' "$shared_b64" | openssl base64 -d -A > "$work/_shared.yml" || fail "could not write the rendered _shared.yml"
chmod 644 "$work/traefik.yml" "$work/_shared.yml" || fail "could not set modes in $work"

# The pull happens here, before anything on the server has been overwritten: a
# tag that does not exist fails the run while the live proxy is untouched.
docker pull "$image" >/dev/null 2>&1 \
    || fail "could not pull $image — check the tag exists (docker pull $image)"

# --network none: no route to a CA, to a backend, or to this container from
# anywhere. No -p: the live Traefik holds :80 and :443. Both mounts read-only,
# and acme.json is not among them.
docker run -d --name "$name" --label "$label" --network none --restart no \
    -v "$work/traefik.yml:/etc/traefik/traefik.yml:ro" \
    -v "$apps/traefik/dynamic:/etc/traefik/dynamic:ro" \
    -v "$work/_shared.yml:/etc/traefik/dynamic/_shared.yml:ro" \
    "$image" >/dev/null 2>&1 \
    || fail "the throwaway $image container would not start at all (docker run refused it)"

# Traefik writes colour even when nothing is a terminal, and the level token is
# wrapped in it, so it has to come off before any line can be matched.
#
# One pattern substitution, not sed. Every other `<<'REMOTE'` payload in this
# repository is coreutils and bash builtins: `awk`, `sed` and `grep` are not on
# the prerequisites table (docs/server-setup.md), and lib/server_init.sh
# hand-rolls a read loop over /proc/meminfo rather than reach for one. A tool
# added here to serve one command would weaken a property every other command
# holds, and nothing would catch the regression — the rig and every real VPS
# have all three.
shopt -s extglob
esc=$'\033'
logs() {
    local raw
    raw=$(docker logs "$name" 2>&1)
    printf '%s' "${raw//$esc\[*([0-9;])m/}"
}

# The verdict is reached when Traefik has either said something at ERR or got as
# far as asking the CA for a certificate — the second is what a healthy load
# produces, and it comes after the routers are built. Waiting on a fixed sleep
# is how a dry-run ends up passing because it read nothing.
deadline=$((SECONDS + timeout_s))
verdict=waiting
while :; do
    text=$(logs)
    case $text in
        *" ERR "*)       verdict=spoke; break ;;
        *"$acme_msg"*)   verdict=spoke; break ;;
    esac
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) || running=false
    if [ "$running" != true ]; then verdict=exited; break; fi
    [ "$SECONDS" -lt "$deadline" ] || { verdict=timeout; break; }
    sleep 1
done

# A second of settle once it has spoken: the router errors and the ACME attempts
# are emitted from different goroutines within a few hundred milliseconds of
# each other, and a verdict taken at the first line would miss the rest.
[ "$verdict" != spoke ] || sleep 2

text=$(logs)
exitcode=$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null) || exitcode=""

# One pass over the log, classifying each line.
#
# Every ERR line is a config error, less the one family this run's own
# unreachable CA produces — and that exemption is a **conjunction**: the message
# *and* the loopback URL kasbah chose, on the same line. Nested `case`, because
# two matches in series would make it a disjunction, which is exactly the way
# this classifier was first written and wrong. 127.0.0.1:1 is nobody's CA, so an
# "unable to obtain a certificate" from anywhere else keeps its place.
#
# The exempted lines are also the evidence: the file provider emits one per TLS
# router it built out of the mounted fragments, naming it, so collecting their
# routerName is what tells the caller the directory was read at all. First-seen
# order, deduplicated against a seen-list — `sort -u` is not available here
# either, and the order a router was built in is at least as useful.
errs=""
warns=""
routers=""
while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in
        *" ERR "*)
            case $line in
                *"$acme_msg"*)
                    case $line in
                        *"$dry_ca"*)
                            case $line in
                                *routerName=*)
                                    router=${line#*routerName=}
                                    router=${router%% *}
                                    case " $routers " in
                                        *" $router "*) ;;
                                        *) routers="$routers$router " ;;
                                    esac
                                    ;;
                            esac
                            continue
                            ;;
                    esac
                    ;;
            esac
            errs="$errs$line"$'\n'
            ;;
        *" WRN "*) warns="$warns$line"$'\n' ;;
    esac
done <<<"$text"
errs=${errs%$'\n'}
warns=${warns%$'\n'}

# The tail of the log for a diagnostic. Spelled as a guarded substring rather
# than `tail -c`: bash returns the *empty* string for ${var: -N} when the string
# is shorter than N, which would silently drop the whole log in the common case.
clip=$text
[ "${#clip}" -le 8000 ] || clip=${clip: -8000}

printf 'dry_verdict=%s\n' "$verdict"
printf 'dry_exitcode=%s\n' "$exitcode"
printf 'dry_errors_b64=%s\n' "$(printf '%s' "$errs" | openssl base64 -A)"
printf 'dry_warns_b64=%s\n' "$(printf '%s' "$warns" | openssl base64 -A)"
printf 'dry_routers=%s\n' "$routers"
printf 'dry_log_b64=%s\n' "$(printf '%s' "$clip" | openssl base64 -A)"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "the dry run of $_UT_IMAGE_NEW on $_UT_TARGET could not be carried out (the remote step exited $rc, see above) — nothing was changed"

    _ut_absorb_checked "the dry run" "$out" \
        dry_swept dry_verdict dry_exitcode dry_errors_b64 dry_warns_b64 dry_routers dry_log_b64

    [ "${_UT_FACT[dry_swept]}" = 0 ] \
        || warn "swept ${_UT_FACT[dry_swept]} throwaway container(s) a previous dry run left behind"

    local errs="" warns="" log=""
    _ut_b64_decode "${_UT_FACT[dry_errors_b64]}" errs
    _ut_b64_decode "${_UT_FACT[dry_warns_b64]}" warns
    _ut_b64_decode "${_UT_FACT[dry_log_b64]}" log
    _UT_DRY_ROUTERS="${_UT_FACT[dry_routers]}"

    case "${_UT_FACT[dry_verdict]}" in
        spoke) ;;
        exited)
            err "the throwaway $_UT_IMAGE_NEW exited (code ${_UT_FACT[dry_exitcode]}) instead of loading the configuration"
            _ut_dry_fail "$log"
            ;;
        *)
            err "the throwaway $_UT_IMAGE_NEW said nothing in 120s — the dry run reached no verdict"
            err_cont "a dry run that reads nothing must not be read as a pass."
            _ut_dry_fail "$log"
            ;;
    esac

    if [ -n "$errs" ]; then
        err "$_UT_IMAGE_NEW rejects the configuration already on $_UT_TARGET — the upgrade is off"
        err_cont "nothing was backed up, shipped or restarted; ${_UT_FACT[traefik_running_image]} is still serving."
        err_cont "the throwaway logged, against $_UT_APPS_PATH/traefik/dynamic:"
        local line
        while IFS= read -r line; do err_cont "| $line"; done <<<"$errs"
        err_cont "fix the fragment it names and run this again."
        exit 1
    fi

    # The anti-vacuity anchor, in the shape the mounts make it — a conjunction,
    # because the throwaway mounts two things and each one is a separate claim.
    #
    # First: `traefik-dashboard@file`, out of the `_shared.yml` this run
    # rendered and laid over the mount. It proves the file provider ran at all.
    # It proves nothing about the server, which is the trap this used to sit in:
    # that file is kasbah's own, shipped as an argument, and it would be read
    # whatever the server's directory held — including nothing.
    #
    # Second, and only when step 2 found a fragment besides `_shared.yml`: a
    # router that is *not* one of `_shared.yml`'s. The server's directory is the
    # only place one can come from, so it is the evidence the read-only mount of
    # that directory applied.
    local frag router server_frags=0 off_server=""
    for frag in ${_UT_FRAGMENTS[@]+"${_UT_FRAGMENTS[@]}"}; do
        [ "$frag" != "$_UT_SHARED_FRAGMENT" ] || continue
        server_frags=$((server_frags + 1))
    done
    for router in $_UT_DRY_ROUTERS; do
        case " ${_UT_SHARED_ROUTERS[*]} " in
            *" $router "*) ;;
            *) off_server="$router"; break ;;
        esac
    done

    case " $_UT_DRY_ROUTERS " in
        *" $_UT_DRY_ANCHOR "*) ;;
        *)
            err "the dry run of $_UT_IMAGE_NEW loaded no $_UT_DRY_ANCHOR router — it validated nothing"
            err_cont "every TLS router the file provider builds asks this run's own unreachable CA"
            err_cont "for a certificate and names itself doing it, and the dashboard router is in"
            err_cont "the dynamic/_shared.yml this run rendered and mounted over the directory."
            err_cont "Seeing not even that one means the file provider read nothing at all, so the"
            err_cont "verdict is not evidence."
            err_cont "routers seen: ${_UT_DRY_ROUTERS:-<none>}"
            _ut_dry_fail "$log"
            ;;
    esac

    if [ "$server_frags" -gt 0 ] && [ -z "$off_server" ]; then
        err "the dry run of $_UT_IMAGE_NEW loaded no router out of $_UT_APPS_PATH/traefik/dynamic — it validated nothing"
        err_cont "that directory holds $server_frags fragment(s) besides _shared.yml —"
        err_cont "${_UT_FRAGMENTS[*]} — and not one router came out of them."
        err_cont "$_UT_DRY_ANCHOR is kasbah's own _shared.yml, rendered here and mounted over"
        err_cont "the directory, so it answers the same whether that directory was read or not."
        err_cont "Either the read-only mount of it did not apply, or nothing in it declares a"
        err_cont "router on websecure with certResolver: letsencrypt."
        err_cont "routers seen: ${_UT_DRY_ROUTERS:-<none>}"
        _ut_dry_fail "$log"
    fi

    if [ -n "$warns" ]; then
        warn "$_UT_IMAGE_NEW logged warnings against the current configuration (not fatal):"
        local line
        while IFS= read -r line; do err_cont "| $line"; done <<<"$warns"
    fi

    info "  dry run passed: $_UT_IMAGE_NEW built ${_UT_DRY_ROUTERS% } out of ${#_UT_FRAGMENTS[@]} fragment(s)"
    [ "$server_frags" -gt 0 ] \
        || info "  (that directory holds only kasbah's own _shared.yml — there were no project fragments to validate)"
    return 0
}

_ut_dry_fail() {
    err_cont "nothing was backed up, shipped or restarted; ${_UT_FACT[traefik_running_image]} is still serving."
    err_cont "the throwaway's log, last lines:"
    local line
    while IFS= read -r line; do err_cont "| $line"; done <<<"$1"
    exit 1
}

# --- Step 5: backup, ship, start ----------------------------------------------

# The three files as they are, copied whole before a byte of them is replaced.
# A directory per run rather than siblings: `dynamic/` is a watched directory
# and a copy left in it is one more file for the file provider to have an
# opinion about.
_ut_backup() {
    local out rc=0

    out=$(ssh_script "$_UT_APPS_PATH" "$_UT_STAMP" "$_UT_IMAGE_NOW" "$_UT_IMAGE_NEW" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
stamp=$2
from=$3
to=$4
dir="$apps/traefik"
dest="$dir/backups/$stamp"

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ ! -e "$dest" ] || fail "$dest is already there — kasbah will not write over a backup"
mkdir -p "$dest" || fail "could not create $dest"
for rel in compose.yml traefik.yml dynamic/_shared.yml; do
    cp -p "$dir/$rel" "$dest/${rel##*/}" || fail "could not copy $dir/$rel to $dest"
done
printf '%s -> %s\n' "$from" "$to" > "$dest/kasbah-upgrade" || fail "could not write $dest/kasbah-upgrade"
printf 'backup_dir=%s\n' "$dest"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not back up the Traefik stack on $_UT_TARGET (the remote step exited $rc, see above) — nothing was changed"

    _ut_absorb_checked "the backup" "$out" backup_dir
    _UT_BACKUP_DIR="${_UT_FACT[backup_dir]}"
    return 0
}

# dynamic/_shared.yml last, deliberately: it is the only one of the three the
# running Traefik picks up without being restarted, so it is the last thing to
# take effect and the first thing the restore below puts back.
_ut_ship() {
    local rel dest
    for rel in compose.yml traefik.yml dynamic/_shared.yml; do
        case " ${_UT_CHANGED[*]} " in *" $rel "*) ;; *) continue ;; esac
        dest="$_UT_APPS_PATH/traefik/$rel"
        ssh_rsync -pt --chmod=F644 "$_UT_TMPDIR/$rel" "$SSH_TARGET:$dest" >/dev/null \
            || die "could not ship the Traefik $rel to $_UT_TARGET:$dest — the backup is at $_UT_BACKUP_DIR"
    done
    return 0
}

# `up -d` recreates the container because the image changed, and the new one
# reads the new traefik.yml on its way up — so no separate restart, and no
# window where an old process is running against a new static config.
#
# The restore lives on the far side rather than in a round trip after this one:
# if it were here, a connection that dropped during the wait would leave the
# proxy down with the fix sitting on the wrong machine.
_ut_start() {
    local out rc=0

    out=$(ssh_script "$_UT_APPS_PATH" "$_UT_PROJECT" "$_UT_BACKUP_DIR" \
                     "$_UT_DATA_PATH/traefik/letsencrypt/acme.json" 180 <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
project=$2
backup=$3
acme=$4
timeout_s=$5

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

cd "$apps/traefik" || fail "could not enter $apps/traefik"
dc() { docker compose -p "$project" "$@"; }

# Every compose invocation carries -p: `name:` in the file is the weakest source
# of the project name and COMPOSE_PROJECT_NAME in this login shell outranks it.
wait_healthy() {
    local cid deadline health running
    cid=$(dc ps -a -q traefik 2>/dev/null) || cid=""
    [ -n "$cid" ] || return 1
    deadline=$((SECONDS + timeout_s))
    while :; do
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null) || health=gone
        [ "$health" != healthy ] || return 0
        [ "$health" != none ] || return 1
        running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null) || running=false
        [ "$running" = true ] || return 1
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 2
    done
}

rolled_back=no
if dc up -d >/dev/null 2>&1 && wait_healthy; then
    :
else
    # The proxy holds :80 and :443 for every site on the box, so a start that
    # did not come up is put back where it was rather than left half-switched.
    printf 'remote: the new Traefik did not come up healthy — restoring %s\n' "$backup" >&2
    dc logs --no-color --tail 40 >&2 || true
    rolled_back=failed
    if [ -d "$backup" ]; then
        cp -p "$backup/compose.yml"  "$apps/traefik/compose.yml"  \
            && cp -p "$backup/traefik.yml" "$apps/traefik/traefik.yml" \
            && cp -p "$backup/_shared.yml" "$apps/traefik/dynamic/_shared.yml" \
            && dc up -d >/dev/null 2>&1 && wait_healthy && rolled_back=yes
    fi
fi

cid=$(dc ps -a -q traefik 2>/dev/null) || cid=""
health=none; image=""; started=""; state=""
if [ -n "$cid" ]; then
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null) || health=gone
    image=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null) || image=""
    started=$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null) || started=""
    state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null) || state=""
fi

# Read, never written. The digest is how the run can say afterwards whether the
# new Traefik wrote to the store — which it may legitimately have done, if a
# certificate came up for renewal while this was happening.
digest=""
if [ -f "$acme" ] && [ -s "$acme" ]; then
    d=$(openssl dgst -sha256 -r < "$acme" 2>/dev/null) || d=""
    digest="${d%% *}"
fi

printf 'up_rolled_back=%s\n' "$rolled_back"
printf 'up_health=%s\n' "$health"
printf 'up_state=%s\n' "$state"
printf 'up_image=%s\n' "$image"
printf 'up_started_at=%s\n' "$started"
printf 'up_acme_digest=%s\n' "$digest"
[ "$rolled_back" = no ] || exit 3
exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        err "could not bring Traefik up on $_UT_TARGET (the remote step exited $rc, see above)"
        err_cont "the previous stack is backed up at $_UT_BACKUP_DIR — restore it with:"
        err_cont "  cp -p $_UT_BACKUP_DIR/compose.yml $_UT_APPS_PATH/traefik/compose.yml"
        err_cont "  cp -p $_UT_BACKUP_DIR/traefik.yml $_UT_APPS_PATH/traefik/traefik.yml"
        err_cont "  cp -p $_UT_BACKUP_DIR/_shared.yml $_UT_APPS_PATH/traefik/dynamic/_shared.yml"
        err_cont "  cd $_UT_APPS_PATH/traefik && docker compose -p $_UT_PROJECT up -d"
        exit 1
    fi

    _ut_absorb_checked "the Traefik start" "$out" \
        up_rolled_back up_health up_state up_image up_started_at up_acme_digest

    case "${_UT_FACT[up_rolled_back]}" in
        no) ;;
        yes)
            err "$_UT_IMAGE_NEW did not come up healthy on $_UT_TARGET — rolled back to $_UT_IMAGE_NOW"
            err_cont "the proxy is serving again on ${_UT_FACT[up_image]} (${_UT_FACT[up_health]});"
            err_cont "the backup it was restored from is at $_UT_BACKUP_DIR."
            err_cont "the failing stack's log is above."
            exit 1
            ;;
        *)
            err "$_UT_IMAGE_NEW did not come up on $_UT_TARGET and the rollback did not come up either"
            err_cont "the proxy is ${_UT_FACT[up_state]:-gone} (${_UT_FACT[up_health]}) — every site on this host is down."
            err_cont "the previous stack's files are at $_UT_BACKUP_DIR; restore them and run:"
            err_cont "  cd $_UT_APPS_PATH/traefik && docker compose -p $_UT_PROJECT up -d"
            exit 1
            ;;
    esac
    return 0
}

# --- The command ---------------------------------------------------------------

cmd_server_upgrade_traefik() {
    _server_upgrade_traefik_parse_args "$@"
    command -v yq >/dev/null || die "yq is required to render the Traefik stack (install yq and retry)"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    # Installed before ssh_connect, which chains onto whatever EXIT trap it
    # finds: one installed afterwards is the last writer and drops the ssh
    # master's own teardown (lib/ssh.sh).
    trap '_ut_cleanup' EXIT

    # One clock for both the backup directory and the throwaway's name, taken
    # here because the far side is bash and coreutils and nothing else.
    _UT_STAMP="$(date -u +%Y%m%dT%H%M%SZ)" || die "internal: could not read the clock"

    ssh_connect "$_UT_TARGET"
    marker_read "$_UT_TARGET"
    _UT_APPS_PATH="$MARKER_APPS_PATH"
    _UT_DATA_PATH="$MARKER_DATA_PATH"

    _ut_read_stack
    _ut_recover_values
    _ut_render

    info "Upgrading Traefik on $_UT_TARGET: $_UT_IMAGE_NOW -> $_UT_IMAGE_NEW"
    _ut_dry_run

    # Byte-identical files are not the same fact as a proxy on the target
    # version. A container that was never recreated after a hand edit, or a
    # half-finished intervention, leaves compose.yml naming a tag the running
    # container is not — and returning 0 there would report success over a proxy
    # that did not move, which docs/compliance.md calls the quietest failure
    # there is. So the early return turns on *both*, and when only the files
    # agree the run goes on and recreates the container.
    if [ "${#_UT_CHANGED[@]}" -eq 0 ] \
        && [ "${_UT_FACT[traefik_running_image]}" = "$_UT_IMAGE_NEW" ]; then
        info "  nothing to ship: $_UT_APPS_PATH/traefik already renders byte-for-byte to $_UT_IMAGE_NEW"
        info "  the proxy was not restarted (${_UT_FACT[traefik_running_image]}, ${_UT_FACT[traefik_health]})"
        return 0
    fi
    [ "${#_UT_CHANGED[@]}" -gt 0 ] \
        || warn "$_UT_APPS_PATH/traefik already renders byte-for-byte to $_UT_IMAGE_NEW, but the container is running ${_UT_FACT[traefik_running_image]:-nothing} — recreating it"

    _ut_backup
    info "  backed up compose.yml, traefik.yml and dynamic/_shared.yml to $_UT_BACKUP_DIR"
    _ut_ship
    _ut_start

    info "Upgraded Traefik on $_UT_TARGET"
    info "  image: $_UT_IMAGE_NOW -> ${_UT_FACT[up_image]} (${_UT_FACT[up_health]})"
    local shipped="nothing re-rendered"
    [ "${#_UT_CHANGED[@]}" -eq 0 ] || shipped="shipped ${_UT_CHANGED[*]}"
    info "  $shipped, previous bytes at $_UT_BACKUP_DIR"
    info "  validated ${#_UT_FRAGMENTS[@]} fragment(s): ${_UT_FRAGMENTS[*]}"
    case "${_UT_FACT[acme_state]}" in
        nonempty)
            if [ "${_UT_FACT[up_acme_digest]}" = "${_UT_FACT[acme_digest]}" ]; then
                info "  acme.json: unchanged (kasbah never writes it; the certificates carried over)"
            else
                info "  acme.json: written by the new Traefik — normal when a certificate came up for renewal"
            fi
            ;;
        *) info "  acme.json: ${_UT_FACT[acme_state]}, nothing to carry over" ;;
    esac
    return 0
}
