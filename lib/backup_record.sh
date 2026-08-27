# kasbah — the backup scheduler's last-run record, read
# Sourced by lib/server_status.sh and lib/check_server.sh. Do not execute directly.

[ -n "${_KASBAH_BACKUP_RECORD_LOADED:-}" ] && return 0
_KASBAH_BACKUP_RECORD_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"

# templates/backup/backup.sh writes <apps>/.kasbah/backup/state/status on every
# state change, and the container's healthcheck reads it back there with the
# runner's `health` verb. This is the same file read from a workstation, asking
# the same question — has the state the scheduler last recorded outlived its own
# deadline? — so the comparison is spelled once, here, and `server status` and
# `check --server` both call it. Two parsers of one file is how a report and a
# healthcheck come to disagree about whether backups are happening.
#
# **The runner is the third reader and has a parser of its own.** It has to: it
# is POSIX sh inside the restic image and a script in a container can source
# nothing, so there is one *rule* and two *implementations* — `_bkr_epoch` below
# and `is_epoch` in templates/backup/backup.sh, kept in step by
# tests/backup_test.sh, which drives both over the same values. That pairing was
# not free: the runner admitted any digit string long after this file stopped
# doing so, and one record then yielded three verdicts — `unhealthy` from
# `docker ps`, `unknown` from `server status`, `warn` from `check --server`.
#
# A file of its own rather than a home in either command: **share the question,
# not the command.** `server status` does source lib/backup.sh, for the one
# answer to "how is a repository URL printed" and the one answer to "which
# repositories does this server have" — both of them questions `server init`
# already owns. Nothing owns "what does this record say" yet, so it is put where
# both readers can reach it without either becoming a dependency of the other.
#
# Nothing here reads a server. The caller brings the state of the stack
# directory, the state of the record file, the record's bytes and the *server's*
# clock: every epoch in the record is the server's own, and judging them against
# a workstation's would make the verdict a function of the skew between two
# machines.
#
# Absence is not a value, and this is where that is kept true. A server with no
# stack, a stack that has never written a record, a record nobody can read, a
# record with no completed run in it and a record saying the last run failed are
# five different facts with five different remedies, and BKR_VERDICT keeps them
# apart rather than collapsing them into "no backup".

# One of:
#   nostack     the stack directory is not there, or is not a directory
#   norecord    no record file — the scheduler writes one as its first act
#   unreadable  the file is there and its bytes did not arrive (BKR_REASON says why)
#   unparsed    the bytes arrived and carry no state, or no deadline this kasbah
#               can compare (BKR_REASON says which)
#   never       a record, and no run has *finished* yet
#   failed      the last run that finished reported failure
#   overdue     the recorded state has outlived its own deadline
#   ok          the last run finished and succeeded, inside the deadline
#
# The first four are "no record to judge" and come with a non-zero return; the
# last four are verdicts and come with zero. Callers capture that status rather
# than calling bare, so a reader added later cannot be killed by errexit halfway
# through its own report.
BKR_VERDICT=""
# The clause a reader puts after the path, for the states that have one. Chosen
# where the failure was seen rather than re-derived by each reader.
BKR_REASON=""
# The record's own fields, empty when the record did not carry them or carried
# something no arithmetic can be done on.
BKR_STATE=""
BKR_SINCE=""
BKR_DEADLINE=""
BKR_NEXT_RUN=""
BKR_STARTED=""
BKR_FINISHED=""
BKR_STATUS=""
BKR_REPOS=""
# Seconds past the deadline (0 when inside it) and seconds since the last run
# finished (empty when none has). Both against the clock below.
BKR_OVERDUE=0
BKR_AGE=""
BKR_NOW=""
# `server` when the epochs were judged against the clock that wrote them, and
# `local` when the probe's answer was not a usable one and this machine's was
# used instead. Both readers print a clause for `local`: a verdict measured on
# the wrong clock is worth a sentence even though it is nearly always right.
BKR_CLOCK=""

# _bkr_epoch VALUE OUTVAR — one epoch field, admitted only when bash can do
# arithmetic on it. Exit 1 otherwise, with OUTVAR emptied.
#
# A digits-only test is not enough, twice over, and both shapes were reachable
# from a record a hand edit or a truncated write produces. A leading zero makes
# `01999000009` an invalid *octal* literal, which is a fatal arithmetic error:
# `kasbah server status` died mid-report with `value too great for base` and exit
# 1, having printed neither the last-run line nor the whole Projects section
# under it. A digit string past 2^63 makes `[ -gt ]` answer `integer expression
# expected` and be silently false, so the record came out as a passing backup.
# Eighteen digits is the cap because 999999999999999999 < 2^63-1, which makes
# every value that gets through safe for both `$(( ))` and `[ -gt ]`.
_bkr_epoch() {
    local _be_v="$1" _be_out="$2"
    printf -v "$_be_out" '%s' ""
    case $_be_v in
        0|[1-9]*) ;;
        *)        return 1 ;;
    esac
    case $_be_v in
        *[!0-9]*) return 1 ;;
    esac
    [ "${#_be_v}" -le 18 ] || return 1
    printf -v "$_be_out" '%s' "$_be_v"
    return 0
}

# backup_record_read DIR_STATE FILE_STATE CONTENT NOW
#
# DIR_STATE is `dir`, `notdir` or anything else for absent. FILE_STATE is the
# spelling both probes use — `file`, `absent`, `empty`, `unreadable`, `notfile`,
# `dir`, and `server status` has a seventh, `nopath`, which cannot reach here
# because the path is always non-empty and which the unknown arm would name
# anyway. CONTENT is the record's bytes, already base64-decoded on the
# workstation: the VPS has no jq, yq or python3 and keeping it that way is
# deliberate. NOW is the server's `date +%s`.
#
# Exit 0 when a record was read and judged, 1 when there was none to judge.
backup_record_read() {
    local _br_dir="$1" _br_file="$2" _br_content="$3" _br_now="$4"
    local _br_line _br_raw_deadline=""

    BKR_VERDICT=""
    BKR_REASON=""
    BKR_STATE=""
    BKR_SINCE=""
    BKR_DEADLINE=""
    BKR_NEXT_RUN=""
    BKR_STARTED=""
    BKR_FINISHED=""
    BKR_STATUS=""
    BKR_REPOS=""
    BKR_OVERDUE=0
    BKR_AGE=""
    BKR_CLOCK=server

    # The probe answers with the server's clock. A probe that answered with
    # something no arithmetic can be done on is a payload this kasbah did not
    # build; the two clocks are the same clock plus skew, so this machine's is
    # used and said out loud, rather than declining to judge at all — which
    # would make every wedged scheduler unreportable over one bad field.
    if ! _bkr_epoch "$_br_now" BKR_NOW; then
        BKR_NOW="$(date +%s)"
        BKR_CLOCK=local
    fi

    case $_br_dir in
        dir)    ;;
        notdir) BKR_VERDICT=nostack; BKR_REASON="exists and is not a directory"; return 1 ;;
        *)      BKR_VERDICT=nostack; BKR_REASON="is not there"; return 1 ;;
    esac
    case $_br_file in
        file)       ;;
        absent)     BKR_VERDICT=norecord; return 1 ;;
        empty)      BKR_VERDICT=unreadable; BKR_REASON="is empty"; return 1 ;;
        unreadable) BKR_VERDICT=unreadable; BKR_REASON="cannot be read by the ssh user"; return 1 ;;
        notfile)    BKR_VERDICT=unreadable; BKR_REASON="exists and is not a regular file"; return 1 ;;
        dir)        BKR_VERDICT=unreadable; BKR_REASON="is a directory"; return 1 ;;
        *)          BKR_VERDICT=unreadable
                    BKR_REASON="is in a state this kasbah does not know ('$_br_file')"
                    return 1 ;;
    esac
    if [ -z "$_br_content" ]; then
        BKR_VERDICT=unreadable
        BKR_REASON="did not come back as readable bytes"
        return 1
    fi

    # Read rather than sourced, exactly as the runner reads it and for the same
    # reason: it is a record, not a shell script, and a key this kasbah does not
    # know is a field a later one added.
    while IFS= read -r _br_line || [ -n "$_br_line" ]; do
        _br_line="${_br_line%$'\r'}"
        case $_br_line in
            state=*)             BKR_STATE="${_br_line#*=}" ;;
            since=*)             BKR_SINCE="${_br_line#*=}" ;;
            deadline=*)          BKR_DEADLINE="${_br_line#*=}" ;;
            next_run=*)          BKR_NEXT_RUN="${_br_line#*=}" ;;
            last_run_started=*)  BKR_STARTED="${_br_line#*=}" ;;
            last_run_finished=*) BKR_FINISHED="${_br_line#*=}" ;;
            last_run_status=*)   BKR_STATUS="${_br_line#*=}" ;;
            last_run_repos=*)    BKR_REPOS="${_br_line#*=}" ;;
        esac
    done <<<"$_br_content"

    _br_raw_deadline="$BKR_DEADLINE"
    _bkr_epoch "$_br_raw_deadline" BKR_DEADLINE || BKR_DEADLINE=""
    _bkr_epoch "$BKR_SINCE"    BKR_SINCE    || BKR_SINCE=""
    _bkr_epoch "$BKR_NEXT_RUN" BKR_NEXT_RUN || BKR_NEXT_RUN=""
    _bkr_epoch "$BKR_STARTED"  BKR_STARTED  || BKR_STARTED=""
    _bkr_epoch "$BKR_FINISHED" BKR_FINISHED || BKR_FINISHED=""

    # The deadline is the one field the healthcheck asks about, so a record
    # without a usable one is a record this kasbah cannot judge — reported as
    # that rather than as a passing backup.
    if [ -z "$BKR_STATE" ] || [ -z "$BKR_DEADLINE" ]; then
        BKR_VERDICT=unparsed
        if [ -z "$BKR_STATE" ]; then
            BKR_REASON="carries no scheduler state"
        elif [ -z "$_br_raw_deadline" ]; then
            BKR_REASON="carries no deadline, which is the one field a verdict rests on"
        else
            BKR_REASON="records deadline='$_br_raw_deadline', which is not a unix time this kasbah can compare"
        fi
        return 1
    fi

    [ "$BKR_NOW" -le "$BKR_DEADLINE" ] || BKR_OVERDUE=$(( BKR_NOW - BKR_DEADLINE ))
    if [ -n "$BKR_FINISHED" ] && [ "$BKR_FINISHED" != 0 ]; then
        BKR_AGE=$(( BKR_NOW - BKR_FINISHED ))
        # Both epochs come off the server's own clock, so a negative age means
        # that clock moved backwards between the run and this read.
        [ "$BKR_AGE" -ge 0 ] || BKR_AGE=0
    fi

    # A failed run is the concrete thing and is named first. An overdue state
    # comes next and outranks the two below it, because "the slot came and went"
    # is true whether or not a run has ever finished.
    if [ "$BKR_STATUS" = failed ]; then
        BKR_VERDICT=failed
    elif [ "$BKR_OVERDUE" -gt 0 ]; then
        BKR_VERDICT=overdue
    elif [ "$BKR_STATUS" = ok ]; then
        BKR_VERDICT=ok
    elif [ -z "$BKR_STATUS" ] || [ "$BKR_STATUS" = - ]; then
        # The writer's own placeholder: the scheduler has reported in and no run
        # has finished. A first run may be in progress — BKR_STATE says which.
        BKR_VERDICT=never
    else
        BKR_VERDICT=unparsed
        BKR_REASON="records last_run_status='$BKR_STATUS', which this kasbah does not know"
        return 1
    fi
    return 0
}

# backup_record_ago SECONDS OUTVAR — a duration as a reader reads it, in one
# unit. `unknown` for anything that is not a count of seconds, so a caller
# printing a field the record did not carry says so rather than printing 0.
backup_record_ago() {
    local _ba_s="$1" _ba_out="$2"
    case $_ba_s in ''|*[!0-9]*) printf -v "$_ba_out" '%s' unknown; return 0 ;; esac
    if   [ "$_ba_s" -lt 60 ];     then printf -v "$_ba_out" '%ss' "$_ba_s"
    elif [ "$_ba_s" -lt 3600 ];   then printf -v "$_ba_out" '%sm' "$(( _ba_s / 60 ))"
    elif [ "$_ba_s" -lt 172800 ]; then printf -v "$_ba_out" '%sh' "$(( _ba_s / 3600 ))"
    else                               printf -v "$_ba_out" '%s day(s)' "$(( _ba_s / 86400 ))"
    fi
    return 0
}
