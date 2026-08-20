# kasbah — the deploy record: versions.log and its rotation archive
# Sourced by bin/kasbah and lib/*.sh. Do not execute directly.

[ -n "${_KASBAH_VERSIONS_LOG_LOADED:-}" ] && return 0
_KASBAH_VERSIONS_LOG_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

# Every project on a server carries `<apps>/<name>/versions.log` — every deploy
# and rollback that ever ran there, one line each — and, once rotation has had
# something to move, `versions.log.gz` beside it, holding the entries older than
# three months (docs/build-deploy.md → Rotation).
#
# This reads both and answers the four questions its callers have. Read-only on
# both sides: the remote step opens two files with `openssl base64 -in`, and
# nothing here writes to the server at all.
#
# The gzip is decoded *here*, not on the far side. The archive grows by
# appending complete gzip members, and an append killed partway — ENOSPC is the
# realistic producer — leaves a truncated trailing member: `zcat` writes every
# complete member it read and *then* exits non-zero. Decoding locally is what
# lets that be a warning naming the file rather than a remote step's exit code,
# and `history` stays usable on the server whose record most needs reading.
#
# Nothing is deduplicated between the two files. A rotation whose archive append
# succeeded and whose rewrite of the active log failed leaves the same entries
# in both, and remote-deploy.sh warns loudly about exactly that; a reader that
# quietly folded them together would hide the state the warning exists to
# expose. What the files hold is what comes back.

VLOG_TARGET=""
VLOG_ACTIVE_PATH=""
VLOG_ARCHIVE_PATH=""
# Per file, one of: ok missing empty notfile unreadable noaccess notdir — the
# same seven words, for the same seven situations, that `kasbah server status`
# reports a project's log in. Two commands describing one server two ways is
# the thing the shared spelling exists to prevent.
VLOG_ACTIVE_STATE=""
VLOG_ARCHIVE_STATE=""
# yes when the archive did not read as whole gzip: a truncated trailing member,
# bytes that are not gzip at all, or a workstation that cannot decode it.
# Whatever was decoded before it gave up is in the arrays below.
VLOG_ARCHIVE_DAMAGED=no
# Why, as the clause a report puts after the archive's path; empty otherwise.
# Chosen where the failure happened rather than re-derived by each reader from
# what it can see, because a reader counting decoded entries cannot tell a
# truncated member from a payload that is not gzip from a missing zcat.
VLOG_ARCHIVE_REASON=""

# One entry per non-blank line, archive first (older) then active, each file in
# its own order. Parallel arrays, indexed together.
#   VLOG_SRC     archive | active
#   VLOG_RAW     the line as the file holds it, CR and all
#   VLOG_OK      yes when the four frozen fields were there, no when they were not
# The parsed fields are empty for an entry with VLOG_OK=no.
VLOG_SRC=()
VLOG_RAW=()
VLOG_OK=()
VLOG_TS=()
VLOG_ACTION=()
VLOG_VERSION=()
VLOG_BACKUP=()
VLOG_KASBAH=()
VLOG_DIGEST=()

# How many VLOG_OK=no entries the last vlog_prev_deploy or vlog_find_version
# walked past to reach its answer. A line a truncated write left behind is not
# the same thing as no history, and a query that stepped over one has to be able
# to say so — otherwise a damaged latest deploy silently makes the deploy before
# it the rollback target.
VLOG_SKIPPED_DAMAGED=0

# --- The frozen line ------------------------------------------------------------

# One line of docs/build-deploy.md's frozen format:
#
#   <iso-timestamp> <action> <version> <backup-or-no-backup> kasbah=<v> digest=<…|->
#
# The four positional fields are frozen forever; everything after them is
# key=value pairs, and a line written by a newer kasbah carries pairs this one
# has never heard of. So the tail is scanned for the keys worth reporting and
# every other pair is ignored rather than rejected — the alternative is a reader
# that stops working the first time a later phase appends a field.
#
# Returns 1 for a line that does not carry the four fields, which is a real
# state: a truncated write, or somebody's note in the file.
#
# The digest out-variable is optional; the six before it are not.
vlog_parse_line() {
    local _pl_line="${1%$'\r'}"
    local _pl_ts_out="$2" _pl_action_out="$3" _pl_version_out="$4" _pl_backup_out="$5" _pl_kasbah_out="$6"
    local _pl_digest_out="${7:-}"
    local _pl_ts="" _pl_action="" _pl_version="" _pl_backup="" _pl_rest="" _pl_tok
    local _pl_kasbah="" _pl_digest=""
    local _pl_pairs=()

    printf -v "$_pl_ts_out" '%s' ""
    printf -v "$_pl_action_out" '%s' ""
    printf -v "$_pl_version_out" '%s' ""
    printf -v "$_pl_backup_out" '%s' ""
    printf -v "$_pl_kasbah_out" '%s' ""
    [ -z "$_pl_digest_out" ] || printf -v "$_pl_digest_out" '%s' ""

    read -r _pl_ts _pl_action _pl_version _pl_backup _pl_rest <<<"$_pl_line"
    [ -n "$_pl_ts" ] && [ -n "$_pl_action" ] && [ -n "$_pl_version" ] && [ -n "$_pl_backup" ] \
        || return 1
    # The timestamp's leading date, which is the one part of field 1 the format
    # fixes. It separates a kasbah entry from a line of prose without pinning
    # anything a later kasbah might legitimately change.
    [[ "$_pl_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 1

    # `read -ra` and not `for tok in $rest`: the tail is the part a later kasbah
    # gets to invent, so a pair holding `*`, `?` or `[…]` would be expanded
    # against whatever directory the operator happens to be standing in. Measured:
    # in a directory containing a file named `kasbah=EVIL`, a line ending in `*`
    # reported that file's name as the kasbah version.
    read -ra _pl_pairs <<<"$_pl_rest"
    for _pl_tok in ${_pl_pairs[@]+"${_pl_pairs[@]}"}; do
        case $_pl_tok in
            kasbah=*) _pl_kasbah="${_pl_tok#kasbah=}" ;;
            digest=*) _pl_digest="${_pl_tok#digest=}" ;;
        esac
    done

    printf -v "$_pl_ts_out" '%s' "$_pl_ts"
    printf -v "$_pl_action_out" '%s' "$_pl_action"
    printf -v "$_pl_version_out" '%s' "$_pl_version"
    printf -v "$_pl_backup_out" '%s' "$_pl_backup"
    printf -v "$_pl_kasbah_out" '%s' "$_pl_kasbah"
    [ -z "$_pl_digest_out" ] || printf -v "$_pl_digest_out" '%s' "$_pl_digest"
    return 0
}

# --- Loading --------------------------------------------------------------------

# vlog_load <archive-text> <active-text> — fills the entry arrays from two
# already-decoded blobs. Everything below reads only the arrays, so a caller
# with logs from somewhere other than a server (a test, a file on disk) gets the
# same answers.
vlog_load() {
    # Reset here too, not only in the two queries that count it: a caller that
    # reads it after vlog_last_entry would otherwise see the previous load's.
    VLOG_SKIPPED_DAMAGED=0
    VLOG_SRC=()
    VLOG_RAW=()
    VLOG_OK=()
    VLOG_TS=()
    VLOG_ACTION=()
    VLOG_VERSION=()
    VLOG_BACKUP=()
    VLOG_KASBAH=()
    VLOG_DIGEST=()

    # Archive first: its entries are the older ones (docs/build-deploy.md —
    # rotation moves out, never in).
    _vlog_absorb archive "$1"
    _vlog_absorb active "$2"
    return 0
}

_vlog_absorb() {
    local _va_src="$1" _va_text="$2"
    local _va_line _va_ts _va_action _va_version _va_backup _va_kasbah _va_digest _va_ok

    [ -n "$_va_text" ] || return 0
    # The herestring is what carries a file whose last line has no newline after
    # it — a `printf >>` killed mid-append leaves exactly that, and a reader that
    # drops it reports the second-to-last deploy as the current one.
    while IFS= read -r _va_line; do
        [ -n "${_va_line//[[:space:]]/}" ] || continue
        _va_ts=""; _va_action=""; _va_version=""; _va_backup=""; _va_kasbah=""; _va_digest=""
        if vlog_parse_line "$_va_line" \
               _va_ts _va_action _va_version _va_backup _va_kasbah _va_digest; then
            _va_ok=yes
        else
            _va_ok=no
        fi
        VLOG_SRC+=("$_va_src")
        VLOG_RAW+=("$_va_line")
        VLOG_OK+=("$_va_ok")
        VLOG_TS+=("$_va_ts")
        VLOG_ACTION+=("$_va_action")
        VLOG_VERSION+=("$_va_version")
        VLOG_BACKUP+=("$_va_backup")
        VLOG_KASBAH+=("$_va_kasbah")
        VLOG_DIGEST+=("$_va_digest")
    done <<<"$_va_text"
    return 0
}

# --- The server -----------------------------------------------------------------

# base64 -d into <outvar>, without letting a bad payload end the run silently.
# A plain `x="$(… | base64 -d)"` is fatal under errexit, so the process dies
# before the caller's message about a corrupt payload can run. Written as a `||`
# list, which errexit exempts, so the caller decides what a failure means.
# The trailing `x`, removed again on the way out, is what keeps a log whose last
# line has no newline distinct from one whose has: `$( )` strips trailing
# newlines, and a `printf >>` killed mid-append leaves exactly that file.
_vlog_b64_decode() {
    local _bd_out="$2" _bd_val=""
    _bd_val="$( { printf '%s' "$1" | base64 -d 2>/dev/null || exit 1; printf x; } )" \
        || return 1
    printf -v "$_bd_out" '%s' "${_bd_val%x}"
    return 0
}

# vlog_fetch TARGET APPS_PATH PROJECT — one round trip, ssh_connect already run.
#
# Sets VLOG_ACTIVE_STATE / VLOG_ARCHIVE_STATE, VLOG_ARCHIVE_DAMAGED and the
# entry arrays. Exits 1 when the active log is in a state that means kasbah
# cannot read it — notfile, unreadable, noaccess, notdir — because an empty
# answer there is indistinguishable from a project that has never deployed here.
# Everything about the archive is a warning instead: a damaged or unreadable
# archive still leaves the active log worth reading, and dying over it would
# make `history` unusable on the server whose record most needs reading.
vlog_fetch() {
    VLOG_TARGET="$1"
    local _vf_apps="$2" _vf_name="$3"
    local _vf_out _vf_rc=0 _vf_line _vf_key
    local _vf_active_b64="" _vf_archive_b64=""
    local _vf_active="" _vf_archive=""
    local -A _vf_fact=()
    local _vf_missing=()

    VLOG_ACTIVE_PATH="$_vf_apps/$_vf_name/versions.log"
    VLOG_ARCHIVE_PATH="$VLOG_ACTIVE_PATH.gz"
    VLOG_ACTIVE_STATE=""
    VLOG_ARCHIVE_STATE=""
    VLOG_ARCHIVE_DAMAGED=no
    VLOG_ARCHIVE_REASON=""

    _vf_out=$(ssh_script "$_vf_apps" "$_vf_name" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps="$1"
dir="$1/$2"
active="$dir/versions.log"
archive="$dir/versions.log.gz"

# openssl rather than coreutils' `base64 -w0`: openssl is on the prerequisites
# table (docs/server-setup.md) and base64 is not. `-in` rather than a pipe, so
# the archive's bytes never pass through this shell.
b64() { openssl base64 -A -in "$1" 2>/dev/null; }

# Every "cannot" is its own state, and none of them is "missing": a deploy that
# ran under sudo leaves a project directory this user cannot enter, and `[ -f ]`
# answers no for a file behind it exactly as it does for one that is not there
# — the same answer a project that has never been deployed gives.
#
# The apps path is asked before the project directory, because `[ -e ]` on a
# path *through* a regular file answers no as well: an occupied or unenterable
# apps path would otherwise read as "never deployed here", and the advice that
# follows from that ("deploy it for the first time") cannot work.
state_of() {
    if [ -e "$apps" ] && [ ! -d "$apps" ]; then printf notdir;   return 0; fi
    if [ -d "$apps" ] && { [ ! -r "$apps" ] || [ ! -x "$apps" ]; }; then
        printf noaccess; return 0
    fi
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then printf notdir;     return 0; fi
    if [ -d "$dir" ] && { [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
        printf noaccess; return 0
    fi
    if [ -e "$1" ] && [ ! -f "$1" ]; then printf notfile;    return 0; fi
    if [ ! -f "$1" ]; then                printf missing;    return 0; fi
    if [ ! -r "$1" ]; then                printf unreadable; return 0; fi
    if [ ! -s "$1" ]; then                printf empty;      return 0; fi
    printf ok
}

# One file, into $STATE and $DATA. A read that fails anyway — an I/O error, a
# race with a chmod — is unreadable rather than an empty file.
read_file() {
    STATE=$(state_of "$1")
    DATA=""
    if [ "$STATE" = ok ]; then
        if ! DATA=$(b64 "$1") || [ -z "$DATA" ]; then
            STATE=unreadable
            DATA=""
        fi
    fi
}

read_file "$active"
printf 'active_state=%s\nactive_b64=%s\n' "$STATE" "$DATA"
read_file "$archive"
printf 'archive_state=%s\narchive_b64=%s\n' "$STATE" "$DATA"
exit 0
REMOTE
    ) || _vf_rc=$?

    [ "$_vf_rc" -eq 0 ] \
        || die "could not read $VLOG_ACTIVE_PATH on $VLOG_TARGET (the remote step exited $_vf_rc, see above)"

    # The key set is checked as a protocol before any value is read: a fact that
    # never arrived must not be absorbed as an empty log, which is the shape of
    # "this project has never been deployed here".
    while IFS= read -r _vf_line; do
        _vf_line="${_vf_line%$'\r'}"
        case $_vf_line in *=*) _vf_fact[${_vf_line%%=*}]="${_vf_line#*=}" ;; esac
    done <<<"$_vf_out"
    for _vf_key in active_state active_b64 archive_state archive_b64; do
        [ -n "${_vf_fact[$_vf_key]+set}" ] || _vf_missing+=("$_vf_key")
    done
    if [ "${#_vf_missing[@]}" -gt 0 ]; then
        err "reading the deploy record on $VLOG_TARGET reported no ${_vf_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _vf_line; do err_cont "| $_vf_line"; done <<<"$_vf_out"
        exit 1
    fi

    VLOG_ACTIVE_STATE="${_vf_fact[active_state]}"
    VLOG_ARCHIVE_STATE="${_vf_fact[archive_state]}"
    _vf_active_b64="${_vf_fact[active_b64]}"
    _vf_archive_b64="${_vf_fact[archive_b64]}"

    # The two files are judged in opposite directions, on purpose. The active
    # log is authoritative for what is deployed, so a state that means "kasbah
    # cannot read it" stops the run: returning zero entries would hand every
    # caller the exact shape of "this project has never been deployed here",
    # which is the guard that fails open (docs/phases/05-undo.md). The archive
    # is history, and losing it must not stop the record being read at all — so
    # the same states are a warning there.
    case "$VLOG_ACTIVE_STATE" in
        ok|missing|empty) ;;
        *)
            err "$VLOG_ACTIVE_PATH on $VLOG_TARGET cannot be read — the probe called it '$VLOG_ACTIVE_STATE'"
            case "$VLOG_ACTIVE_STATE" in
                notfile)    err_cont "something that is not a regular file is where the deploy record should be" ;;
                unreadable) err_cont "the file is there and this ssh user cannot read it — a deploy that ran under sudo leaves that" ;;
                noaccess)   err_cont "the directory holding it cannot be entered by this ssh user — a deploy that ran under sudo leaves that" ;;
                notdir)     err_cont "a path above it is occupied by something that is not a directory" ;;
                *)          err_cont "which is a state this kasbah does not know" ;;
            esac
            err_cont "kasbah will not read this as an empty record: 'the record cannot be read' and 'this"
            err_cont "project has never been deployed here' are different answers, and rollback acts on"
            err_cont "the difference."
            exit 1
            ;;
    esac
    case "$VLOG_ARCHIVE_STATE" in
        ok|missing|empty) ;;
        *)
            warn "$VLOG_ARCHIVE_PATH on $VLOG_TARGET cannot be read — the probe called it '$VLOG_ARCHIVE_STATE'"
            warn "  the rotated history is not in the record below; the active log is"
            ;;
    esac

    if [ "$VLOG_ACTIVE_STATE" = ok ]; then
        _vlog_b64_decode "$_vf_active_b64" _vf_active \
            || die "the deploy record read on $VLOG_TARGET sent $VLOG_ACTIVE_PATH back as something that is not base64"
        # A file of nothing but blank lines is empty in the only sense a reader
        # cares about, and `kasbah server status` already calls it that.
        [ -n "${_vf_active//[[:space:]]/}" ] || { VLOG_ACTIVE_STATE=empty; _vf_active=""; }
    fi

    [ "$VLOG_ARCHIVE_STATE" != ok ] || _vlog_decode_archive "$_vf_archive_b64" _vf_archive

    vlog_load "$_vf_archive" "$_vf_active"
    return 0
}

# The archive, unpacked on this side. Concatenated gzip members are valid gzip
# and zcat reads them in order; a truncated trailing member is what an append
# killed partway leaves, and zcat reports it *after* writing every complete
# member — so the output is kept and the failure is a warning.
#
# **Every way this can fail is a warning**, which is the promise the header
# makes. A missing zcat and a payload that is not base64 are archive-only
# conditions like any other, and dying over one kills `history`, `pending`,
# `changelog` and `rollback` even when the target is in the active log.
#
# Decoded twice rather than through a temporary file: gzip is binary and a shell
# variable cannot hold a NUL, and a file created here is a file to leak if this
# process is signalled. The first pass is only asking whether the payload is
# base64 at all.
_vlog_decode_archive() {
    local _da_b64="$1" _da_out="$2"
    local _da_text="" _da_rc=0

    if ! command -v zcat >/dev/null; then
        VLOG_ARCHIVE_DAMAGED=yes
        VLOG_ARCHIVE_REASON="could not be decoded on this workstation: zcat is not on its PATH"
        warn "$VLOG_ARCHIVE_PATH on $VLOG_TARGET came back and could not be decoded here — zcat is not installed"
        warn "  the file on the server is untouched and may be perfectly whole; install gzip to read it"
        warn "  no archived entry is in the record below; the active log is"
        printf -v "$_da_out" '%s' ""
        return 0
    fi

    if ! printf '%s' "$_da_b64" | base64 -d >/dev/null 2>&1; then
        VLOG_ARCHIVE_DAMAGED=yes
        VLOG_ARCHIVE_REASON="did not arrive as base64 from $VLOG_TARGET"
        warn "$VLOG_ARCHIVE_PATH on $VLOG_TARGET did not come back as base64 — the transport was cut, not the file"
        warn "  the file on the server is untouched; this says nothing about whether it is whole"
        warn "  no archived entry is in the record below; the active log is"
        printf -v "$_da_out" '%s' ""
        return 0
    fi

    _da_text="$(printf '%s' "$_da_b64" | base64 -d 2>/dev/null | zcat 2>/dev/null)" || _da_rc=$?

    # One exit code over two failures whose next move differs: nothing decoded
    # means the file is not gzip at all — a rotation that wrote plain text, or a
    # name reused for something else — while a partial decode is the truncated
    # trailing member an append killed partway leaves. A warning that describes
    # the wrong one is the thing that stops anyone looking
    # (docs/phases/05-undo.md).
    if [ "$_da_rc" -ne 0 ]; then
        VLOG_ARCHIVE_DAMAGED=yes
        if [ -z "$_da_text" ]; then
            VLOG_ARCHIVE_REASON="is not gzip: no archived entry could be decoded"
            warn "$VLOG_ARCHIVE_PATH on $VLOG_TARGET is not gzip — nothing could be decoded from it"
            warn "  no archived entry is in the record below; look at the file itself"
        else
            VLOG_ARCHIVE_REASON="ends in a truncated gzip member: whatever is inside it could not be decoded"
            warn "$VLOG_ARCHIVE_PATH on $VLOG_TARGET ends in a truncated gzip member"
            warn "  every entry before it is read; anything inside it is not"
            warn "  the likely cause is a rotation that ran out of disk while appending"
        fi
    fi

    printf -v "$_da_out" '%s' "$_da_text"
    return 0
}

# --- What the archive is short of -----------------------------------------------

# Is the archived half of the record fully accounted for? Not the same question
# as "are there archived entries": an archive kasbah could not read, or one
# whose last gzip member is truncated, leaves entries this side cannot see, and
# every sentence that would otherwise claim to describe the whole record has to
# know that (docs/phases/05-undo.md — a message that under-describes a partial
# read is worse than no message).
vlog_archive_whole() {
    [ "$VLOG_ARCHIVE_DAMAGED" = no ] || return 1
    case "$VLOG_ARCHIVE_STATE" in
        ok|missing|empty) return 0 ;;
        *) return 1 ;;
    esac
}

# vlog_archive_note <outvar> — the one line that says what is missing from the
# report above it, for a caller to print with the rest of its own output:
# `vlog_fetch` has already warned on stderr with the diagnosis, and a report
# redirected to a file must still not read as complete. Empty when the archive
# is whole.
#
# Every shape ends in the same clause and differs only in the cause, because
# most callers have no table to be short of rows — what they share is a record
# they cannot claim to have read.
vlog_archive_note() {
    local _an_out="$1"

    printf -v "$_an_out" '%s' ""
    vlog_archive_whole && return 0

    if [ -n "$VLOG_ARCHIVE_REASON" ]; then
        printf -v "$_an_out" '%s' \
            "$VLOG_ARCHIVE_PATH $VLOG_ARCHIVE_REASON, so this is not the whole record"
    else
        printf -v "$_an_out" '%s' \
            "$VLOG_ARCHIVE_PATH could not be read (the probe called it '$VLOG_ARCHIVE_STATE'), so this is not the whole record"
    fi
    return 0
}

# --- The queries ----------------------------------------------------------------

# vlog_has_entries active|archive|all — is there a record here at all? Deliberately not
# the same question as "what version is deployed": collapsing the two has
# already produced a guard that failed open and a changelog that called a server
# with history a first deploy (docs/phases/05-undo.md). An entry counts here
# whether or not it parsed.
#
# `active` is exact — an unreadable active log never reaches here, vlog_fetch
# refuses it. `archive` and `all` are best-effort in one direction: an archive
# kasbah could not read was warned about and left out, so a false answer means
# "none that could be read". VLOG_ARCHIVE_STATE is where that shows, and a
# caller naming the archive in a message should ask this first — saying "and
# its archive hold entries" about one that decoded nothing is the same sentence
# arguing with the note beneath it.
vlog_has_entries() {
    local _he_scope="$1" _he_i

    case $_he_scope in
        active|archive|all) ;;
        *) die "internal: vlog_has_entries takes 'active', 'archive' or 'all', not '$_he_scope'" ;;
    esac
    for _he_i in "${!VLOG_SRC[@]}"; do
        if [ "$_he_scope" = all ] || [ "${VLOG_SRC[$_he_i]}" = "$_he_scope" ]; then
            return 0
        fi
    done
    return 1
}

# vlog_last_entry <outvar> — the index of the last entry in the **active** log,
# whatever its action, parsed or not. Returns 1 when the active log holds none.
#
# The active log is authoritative for what is deployed right now: after a
# rollback that is the rollback's target. Whether the entry parsed is a separate
# question the caller asks of VLOG_OK — a damaged last line is not the same
# thing as no history.
vlog_last_entry() {
    local _le_out="$1" _le_i

    printf -v "$_le_out" '%s' ""
    for _le_i in "${!VLOG_SRC[@]}"; do
        [ "${VLOG_SRC[$_le_i]}" = active ] || continue
        printf -v "$_le_out" '%s' "$_le_i"
    done
    [ -n "${!_le_out}" ] || return 1
    return 0
}

# vlog_prev_deploy <outvar> — the index of the second-latest entry with
# action=deploy, which is what `rollback` targets when the operator names no
# version (docs/build-deploy.md → rollback flow). Returns 1 when the record does
# not hold two.
#
# Over the whole record, archive included: rotation is meant to be transparent,
# and a project that deploys rarely has its previous deploy in the archive
# rather than nowhere.
#
# A line that did not parse is stepped over and counted in VLOG_SKIPPED_DAMAGED:
# a truncated latest deploy would otherwise make the deploy before it the
# rollback target with nothing said about why.
vlog_prev_deploy() {
    local _pd_out="$1" _pd_i
    local _pd_seen=0

    VLOG_SKIPPED_DAMAGED=0
    printf -v "$_pd_out" '%s' ""
    for (( _pd_i = ${#VLOG_SRC[@]} - 1; _pd_i >= 0; _pd_i-- )); do
        if [ "${VLOG_OK[$_pd_i]}" != yes ]; then
            VLOG_SKIPPED_DAMAGED=$((VLOG_SKIPPED_DAMAGED + 1))
            continue
        fi
        [ "${VLOG_ACTION[$_pd_i]}" = deploy ] || continue
        _pd_seen=$((_pd_seen + 1))
        if [ "$_pd_seen" -eq 2 ]; then
            printf -v "$_pd_out" '%s' "$_pd_i"
            return 0
        fi
    done
    return 1
}

# vlog_find_version <version> <outvar> — the index of the most recent entry for
# that version anywhere in the record, active log or archive. Returns 1 when
# there is none.
#
# `rollback` refuses a target that was never deployed to this server, and the
# archive is where a target old enough to be worth rolling back to has aged to —
# so a search of the active log alone would refuse a version the server really
# did run. The caller reads VLOG_ACTION and VLOG_SRC off the index for which.
#
# The match is on the version whatever the entry's action, and that is the
# answer: **a rollback entry naming a version is proof that version ran on this
# server, exactly as a deploy entry is.** A consumer that read VLOG_ACTION off
# the index and demanded `deploy` would refuse a version the record shows ran.
#
# Unparsed lines are stepped over and counted in VLOG_SKIPPED_DAMAGED — a
# refusal built on this must be able to say the record had a line it could not
# read.
vlog_find_version() {
    local _fv_want="$1" _fv_out="$2" _fv_i

    VLOG_SKIPPED_DAMAGED=0
    printf -v "$_fv_out" '%s' ""
    for (( _fv_i = ${#VLOG_SRC[@]} - 1; _fv_i >= 0; _fv_i-- )); do
        if [ "${VLOG_OK[$_fv_i]}" != yes ]; then
            VLOG_SKIPPED_DAMAGED=$((VLOG_SKIPPED_DAMAGED + 1))
            continue
        fi
        [ "${VLOG_VERSION[$_fv_i]}" = "$_fv_want" ] || continue
        printf -v "$_fv_out" '%s' "$_fv_i"
        return 0
    done
    return 1
}
