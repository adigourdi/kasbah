#!/bin/sh
# kasbah — the VPS's backup runner. Rendered from this template and installed at
# <apps>/.kasbah/backup/backup.sh by `kasbah server init --with-backup`. It runs
# as the only process of the `kasbah-backup` container, whose image is restic's
# own (docs/phases/08-keep.md D1: kasbah installs no packages).
#
#   backup.sh              sleep until the daily slot, back up, repeat — the
#                          container's entrypoint, and nothing else runs it
#   backup.sh once         back up now and exit
#   backup.sh plan         print what a run would back up, and exit. Contacts
#                          no repository and needs no credentials
#   backup.sh next [EPOCH] print when the next scheduled run is due, now or as
#                          of a given unix time
#   backup.sh health       what the container's healthcheck asks: is this
#                          scheduler sleeping, or running inside its own bound?
#                          Exit 0 healthy, 1 not, and it says which
#
# The last three are for an operator with a stack that is already up, and `once`
# is how you take a snapshot before doing something risky:
#
#   ssh you@vps 'docker exec kasbah-backup sh /apps/.kasbah/backup/backup.sh once'
#
# **This is the one kasbah script that is not bash.** The restic image is Alpine
# with busybox: /bin/sh is ash, there is no bash, and `date`, `sed` and `grep`
# are busybox applets. So: POSIX shell only, no arrays, no `[[ ]]`, no
# `${x//y/z}`. `set -o pipefail` is supported by ash and set here for the day
# something does pipe; nothing does yet. Everything it reads is on read-only bind
# mounts. What it writes: snapshots, restic's own cache (a named volume), and the
# status file below — <apps>/.kasbah/backup/state is the one writable window in
# an otherwise read-only tree.
#
# Scope, per docs/backup.md as amended by D7: for each project, its data bind
# mount, its hook-produced dumps and its .env; and the mail stack's data and
# .env, in a repository of their own. Projects are grouped into one repository
# per `client` — read from <apps>/<project>/.kasbah-client, which `kasbah
# deploy` writes, because the manifest is never synced to a server and nothing
# here could read it if it were (D12). A project with no record falls back to
# its own directory name, which is `client`'s documented default, and every
# fallback is named in the report so a project deployed before backups existed
# is visible rather than silent.

set -eu
set -o pipefail

apps="${KASBAH_BACKUP_APPS:-}"
data="${KASBAH_BACKUP_DATA:-}"
at="${KASBAH_BACKUP_AT:-02:00}"
jitter="${KASBAH_BACKUP_JITTER:-0}"
# The bound on one restic invocation. Not on a run: a run of five repositories
# may take five of these. It is what stops an endpoint that accepts a connection
# and then answers nothing from leaving this container "running" for ever and
# backing nothing up. `kasbah server init --backup-timeout=` sets it.
timeout_s="${KASBAH_BACKUP_TIMEOUT:-900}"
# Grace on top of the bound before the healthcheck calls a state stale. One
# minute covers a container that was stopped and started across the slot.
grace=300

envfile="$apps/.kasbah/backup/env"
passdir="$apps/.kasbah/backup/repos"
statedir="$apps/.kasbah/backup/state"
statefile="$statedir/status"

# The directories under <apps> that belong to kasbah rather than to a project,
# and the names a `client:` record may therefore not take. The same four as
# KASBAH_RESERVED_NAMES in lib/manifest.sh, which tests/backup_test.sh pins this
# copy to — a payload inside a container can source nothing, so the list is here
# in full and drift is the risk. `.kasbah` needs no entry: the glob below does
# not match a leading dot.
RESERVED="traefik mail data backups"

# Stripped from every line read out of a file an operator may have authored.
CR=$(printf '\r')

say()  { printf 'kasbah-backup: %s\n' "$*"; }
warn() { printf 'kasbah-backup: %s\n' "$*" >&2; }

# The one thing this container writes that outlives it, and the only record of a
# backup that anything other than `docker logs` can read. Written through a temp
# file and renamed, because the healthcheck reads it from another process.
#
#   state     starting | sleeping | running
#   deadline  the epoch by which that state must have changed. The healthcheck
#             asks exactly one question of this file, and this is it: a run that
#             wedged and a sleep that never woke are the same failure to an
#             operator, and one field answers both.
LAST_STARTED=0
LAST_FINISHED=0
LAST_STATUS=-
LAST_REPOS=-
write_status() {
    [ -d "$statedir" ] || return 0
    _ws_tmp="$statefile.tmp.$$"
    {
        printf 'state=%s\n' "$1"
        printf 'since=%s\n' "$(date +%s)"
        printf 'deadline=%s\n' "$2"
        printf 'next_run=%s\n' "${3:-0}"
        printf 'last_run_started=%s\n' "$LAST_STARTED"
        printf 'last_run_finished=%s\n' "$LAST_FINISHED"
        printf 'last_run_status=%s\n' "$LAST_STATUS"
        printf 'last_run_repos=%s\n' "$LAST_REPOS"
        printf 'timeout=%s\n' "$timeout_s"
        printf 'at=%s\n' "$at"
        printf 'jitter=%s\n' "$jitter"
    } > "$_ws_tmp" 2>/dev/null || { warn "could not write $statefile"; return 0; }
    mv -f "$_ws_tmp" "$statefile" 2>/dev/null || warn "could not install $statefile"
    return 0
}

# A repository name is a path segment in a URL kasbah never parses, so nothing
# downstream can escape it. The charset is the manifest's own for `name` and
# `client` (docs/project-manifest.md), narrow enough that a value passing this
# cannot carry a slash, a space, a quote or a newline.
valid_repo() {
    case "$1" in
        ''|*[!a-z0-9-]*) return 1 ;;
        [!a-z]*)         return 1 ;;
    esac
    for _vr in $RESERVED; do
        [ "$1" != "$_vr" ] || return 1
    done
    return 0
}

# The env file, read rather than sourced: it is operator-authored and its values
# are credentials, not shell. Everything after the first `=` is the value,
# verbatim to the end of the line.
load_env() {
    [ -f "$envfile" ] || { warn "no $envfile — nothing says where the repository is"; return 1; }
    while IFS= read -r _le || [ -n "$_le" ]; do
        _le="${_le%$CR}"
        case "$_le" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _k="${_le%%=*}"
        case "$_k" in
            ''|*[!A-Za-z0-9_]*|[0-9]*)
                warn "$envfile: ignoring '$_k=' — not a variable name"; continue ;;
            RESTIC_REPOSITORY|RESTIC_REPOSITORY_FILE|RESTIC_PASSWORD|RESTIC_PASSWORD_FILE|RESTIC_PASSWORD_COMMAND)
                # kasbah sets these itself, per repository, after this function
                # returns. RESTIC_PASSWORD in particular *outranks*
                # RESTIC_PASSWORD_FILE in restic, so a value here would decide
                # the key rather than be overridden by one. `server init`
                # refuses to write them; this is the second lock, on the file
                # rather than on the flag.
                warn "$envfile: ignoring $_k= — kasbah sets it per repository"; continue ;;
        esac
        export "$_k=${_le#*=}"
    done < "$envfile"
    return 0
}

# --- The schedule ---------------------------------------------------------------

# Seconds since local midnight, for now or for a given epoch. Integer arithmetic
# on three fields rather than date parsing, so it needs nothing but `date`'s own
# formatting — and /etc/localtime is mounted, so the slot below is the server's
# local time and not UTC's.
secs_of_day() {
    if [ $# -gt 0 ] && [ -n "$1" ]; then
        set -- $(date -d "@$1" '+%H %M %S')
    else
        set -- $(date '+%H %M %S')
    fi
    printf '%s' "$(( ${1#0} * 3600 + ${2#0} * 60 + ${3#0} ))"
}

# The slot, as seconds since local midnight: the configured time plus this VPS's
# own jitter. The jitter is fixed per server — kasbah derives it from the target
# and records it in the marker — so a fleet does not stampede one endpoint at
# 02:00:00 and one server does not move its slot on every re-run.
slot_secs() {
    _h="${at%%:*}"
    _m="${at#*:}"
    printf '%s' "$(( (${_h#0} * 3600 + ${_m#0} * 60 + jitter) % 86400 ))"
}

# Seconds to wait. Never zero: a run that finished inside its own slot second
# would otherwise start again immediately.
delay_secs() {
    _now=$(secs_of_day "${1:-}")
    _d=$(( $(slot_secs) - _now ))
    [ "$_d" -gt 0 ] || _d=$(( _d + 86400 ))
    printf '%s' "$_d"
}

# --- What to back up ------------------------------------------------------------

# Every project directory under <apps>, one per line: not reserved, not the data
# path, and a directory. The same rule `kasbah server status` walks —
# "everything under <apps> that is not one of kasbah's own".
projects() {
    for _p in "$apps"/*; do
        [ -d "$_p" ] || continue
        [ "$_p" != "$data" ] || continue
        _n="${_p##*/}"
        _skip=no
        for _r in $RESERVED; do
            [ "$_n" != "$_r" ] || _skip=yes
        done
        [ "$_skip" = no ] || continue
        printf '%s\n' "$_n"
    done
    return 0
}

# The effective client of one project, and where it came from. `record` is what
# `kasbah deploy` wrote; `fallback` is the project's own name, which is what
# `client:` defaults to (docs/project-manifest.md) — correct, but named out
# loud, because it is also what a project deployed by a kasbah too old to write
# the record looks like. `invalid` is a record that is not a repository name,
# which also falls back rather than filing a project somewhere unnameable.
client_of() {
    _c=""
    if [ -f "$apps/$1/.kasbah-client" ]; then
        IFS= read -r _c < "$apps/$1/.kasbah-client" || _c=""
        _c="${_c%$CR}"
    fi
    if [ -z "$_c" ]; then
        printf '%s fallback\n' "$1"
    elif valid_repo "$_c"; then
        printf '%s record\n' "$_c"
    else
        printf '%s invalid\n' "$1"
    fi
    return 0
}

# The plan, as a line protocol: one `project` line per project, then one `repo`
# line per repository followed by one `path` line for each path its snapshot
# covers. One path per line because an apps path may contain a space and a
# snapshot that quietly lost half a project is worse than a long report.
#
# `plan` and the run read the same thing, so the command an operator runs to see
# what would happen is the command that decides what happens.
plan() {
    _repos=""
    # The mail stack is its own repository rather than the primary domain's
    # client (D7): folding every mailbox on the VPS into one client's repo is
    # what the per-client split exists to prevent.
    [ ! -d "$apps/mail" ] || _repos=" mail"

    for _n in $(projects); do
        set -- $(client_of "$_n")
        printf 'project %s %s %s\n' "$_n" "$1" "$2"
        [ "$2" != invalid ] \
            || warn "$apps/$_n/.kasbah-client is not a repository name — $_n is filed under '$1'"
        case " $_repos " in
            *" $1 "*) ;;
            *) _repos="$_repos $1" ;;
        esac
    done

    for _r in $_repos; do
        _have=no
        [ ! -f "$passdir/$_r.pass" ] || _have=yes
        printf 'repo %s %s\n' "$_r" "$_have"
        if [ "$_r" = mail ]; then
            for _p in "$data/mail" "$apps/mail/.env"; do
                [ ! -e "$_p" ] || printf 'path %s\n' "$_p"
            done
            continue
        fi
        for _n in $(projects); do
            set -- $(client_of "$_n")
            [ "$1" = "$_r" ] || continue
            # docs/backup.md → Scope, and only what is there. A project with no
            # data directory and no dumps still has its .env, which is the one
            # thing a redeploy cannot rebuild.
            for _p in "$data/$_n" "$apps/$_n/backups" "$apps/$_n/.env"; do
                [ ! -e "$_p" ] || printf 'path %s\n' "$_p"
            done
        done
    done
    return 0
}

# --- The run --------------------------------------------------------------------

# restic, with the repository and the password named through the environment and
# never on the command line: argv is readable in the process table for as long as
# the process runs, and RESTIC_REPOSITORY carries the credential when the target
# is a `rest:` URL.
restic_repo() {
    RESTIC_REPOSITORY="$KASBAH_BACKUP_REPO_BASE$1"
    RESTIC_PASSWORD_FILE="$passdir/$1.pass"
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    shift
    # Bounded, every time. An endpoint that completes a TCP handshake and then
    # says nothing leaves restic waiting for ever, and the loop below never gets
    # back to `sleep` — the container stays "running" and backs nothing up.
    # busybox timeout exits 143 where GNU's exits 124; both are non-zero, which
    # is all any caller here reads.
    timeout -k 10 "$timeout_s" restic "$@"
}

# One repository's snapshot. Called with the repository's paths as arguments, so
# a path with a space in it survives; returns non-zero without ending the run,
# because one unreachable repository must not stop the others.
back_up_repo() {
    if [ "$repo_have" != yes ]; then
        nopass="$nopass $repo_name"
        return 1
    fi
    if [ $# -eq 0 ]; then
        say "$repo_name: nothing to back up yet"
        return 0
    fi
    # A repository that is not there yet is created by the VPS's own credential.
    # That is a write, which append-only allows; it is also the first thing the
    # credential probe at init does, so a credential that cannot do it never
    # reaches a server.
    if ! restic_repo "$repo_name" cat config >/dev/null 2>&1; then
        say "$repo_name: initialising the repository"
        restic_repo "$repo_name" init || { warn "$repo_name: could not initialise the repository"; return 1; }
    fi
    say "$repo_name: backing up $*"
    restic_repo "$repo_name" backup --tag kasbah "$@" || { warn "$repo_name: restic backup failed"; return 1; }
    done_repos="$done_repos $repo_name"
    return 0
}

# How long a whole run may take before the healthcheck calls it wedged: one bound
# per repository, plus one for the repository-existence check, plus the grace.
# Computed from the plan rather than assumed, so a server with ten repositories
# is not called wedged at the bound for one.
run_deadline() {
    _rd_n=0
    while IFS= read -r _rd_l; do
        case "$_rd_l" in 'repo '*) _rd_n=$((_rd_n + 1)) ;; esac
    done <<EOF
$1
EOF
    printf '%s' "$(( $(date +%s) + timeout_s * (_rd_n * 2 + 1) + grace ))"
}

run_once() {
    # The record, not this process's memory: the loop and a hand-driven
    # `docker exec … once` are two processes writing one file, and whichever
    # writes next must carry the other's finished run rather than overwrite it
    # with a copy taken before it happened. Three of the four survive that far —
    # `last_run_started` is reclaimed on the next line, because for as long as
    # this run is in flight it is this run that started.
    load_last_run
    LAST_STARTED=$(date +%s)
    say "run started $(date '+%Y-%m-%dT%H:%M:%S%z')"

    load_env || { LAST_FINISHED=$(date +%s); LAST_STATUS=failed; LAST_REPOS=-; write_sleeping; return 1; }
    if [ -z "${KASBAH_BACKUP_REPO_BASE:-}" ]; then
        warn "$envfile sets no KASBAH_BACKUP_REPO_BASE — re-run kasbah server init --with-backup"
        LAST_FINISHED=$(date +%s); LAST_STATUS=failed; LAST_REPOS=-
        write_sleeping
        return 1
    fi

    status=0
    fallbacks=""
    nopass=""
    done_repos=""
    repo_name=""
    repo_have=""
    set --

    plan_out=$(plan)
    write_status running "$(run_deadline "$plan_out")"

    while IFS= read -r _line; do
        case "$_line" in
            'project '*)
                set -- $_line
                [ "$4" = record ] || fallbacks="$fallbacks $2"
                set --
                ;;
            'repo '*)
                [ -z "$repo_name" ] || back_up_repo "$@" || status=1
                set -- $_line
                repo_name=$2
                repo_have=$3
                set --
                ;;
            'path '*)
                set -- "$@" "${_line#path }"
                ;;
        esac
    done <<EOF
$plan_out
EOF
    [ -z "$repo_name" ] || back_up_repo "$@" || status=1

    [ -z "$fallbacks" ] || say "no .kasbah-client record, filed under their own name:$fallbacks"
    if [ -n "$nopass" ]; then
        warn "no password in $passdir, NOT backed up:$nopass"
        warn "  supply one: kasbah server init USER@HOST --with-backup"
    fi
    say "run finished, repositories backed up:${done_repos:- none}"
    LAST_FINISHED=$(date +%s)
    LAST_REPOS="${done_repos:- none}"
    if [ "$status" -eq 0 ]; then LAST_STATUS=ok; else LAST_STATUS=failed; fi
    # Written by the run rather than by the loop around it, so a run driven by
    # `docker exec … once` leaves the same record — and leaves the file saying
    # what is true of the scheduler either way, which is that it is waiting for
    # the next slot. The loop writes the same thing a moment later.
    write_sleeping
    return "$status"
}

# The sleeping record: when the next run is due, and the latest moment by which
# this state must have changed. One writer for both, so the loop and a hand-run
# `once` cannot leave the healthcheck two different beliefs.
write_sleeping() {
    _wsl_d=$(delay_secs)
    _wsl_now=$(date +%s)
    write_status sleeping "$(( _wsl_now + _wsl_d + timeout_s + grace ))" "$(( _wsl_now + _wsl_d ))"
}

# One epoch field of the status file, admitted only when this shell can do
# arithmetic on it. **This is lib/backup_record.sh's `_bkr_epoch` rule, written
# out a second time**, because there is one rule and there have to be two
# implementations: that one is bash on a workstation, this one is POSIX sh
# inside the restic image, and a script in a container can source nothing. The
# workstation copy carries the same note.
#
# A digits-only gate is not a type check, and it fails at three points. A
# leading zero makes `01999000009` an invalid octal literal — a fatal error on
# the reader's side. A 24-digit value makes `[ -gt ]` answer `Illegal number`
# here, and a *false* comparison reads as **inside** the deadline, so the record
# the workstation calls `unparsed` came back healthy from this check. And in the
# middle it does not fail at all: `01700000000` is a valid octal that silently
# means a different number. Eighteen digits is the cap because
# 999999999999999999 < 2^63-1, which makes everything that gets through safe for
# both `$(( ))` and `[ -gt ]`.
is_epoch() {
    case "$1" in
        0|[1-9]*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 18 ] || return 1
    return 0
}

# One field of the status file, or empty. Read rather than sourced, like the env
# file and for the same reason: this one is kasbah's, but one reader is one rule.
status_field() {
    _sf_v=""
    [ -f "$statefile" ] || { printf ''; return 0; }
    while IFS= read -r _sf_l || [ -n "$_sf_l" ]; do
        case "$_sf_l" in "$1="*) _sf_v="${_sf_l#*=}" ;; esac
    done < "$statefile"
    printf '%s' "$_sf_v"
}

# The last run's facts, read back out of the record this script itself wrote.
# They live in shell variables between one write_status and the next, so a
# process that did not perform that run holds none of them: a scheduler brought
# up by a reboot, a `docker compose up` or a re-ship of this script, and equally
# a `docker exec … once` running beside a scheduler asleep on an older copy.
# `last_run_status=-` is the placeholder every reader turns into "no run has
# finished yet", and a stack that has backed up faithfully for months is not
# that — a reader can only report what is written, so the writer is where the
# fact has to survive.
#
# **All four, or none.** Each field is judged on its own — the epochs by
# `is_epoch`, the one gate this script has for them; the status against the two
# spellings a run writes; the repository list for presence only, because `-` is
# a value a real run leaves (a run that could not read its env file records
# `failed` having reached nothing). But they are carried *together*, because a
# record is a file and a file can be truncated mid-write: one cut after
# `last_run_status=ok` would otherwise be carried on as `ok` beside the
# no-history placeholder for the repository list, which is a pair no run ever
# writes and which lib/check_server.sh reads as a backup that succeeded. Short
# of four good fields, this process starts where a runner with no history does.
#
# No CR stripping, and the gate is why none is needed. This is a
# read-modify-write and not a read: a `\r` admitted here would be written back
# into a file this script authored and re-carried on every start after that. A
# CRLF record fails `is_epoch` on its very first field, so nothing is carried at
# all — which is the same answer this function gives every other record it
# cannot believe.
load_last_run() {
    _llr_started=$(status_field last_run_started)
    _llr_finished=$(status_field last_run_finished)
    _llr_status=$(status_field last_run_status)
    _llr_repos=$(status_field last_run_repos)
    LAST_STARTED=0
    LAST_FINISHED=0
    LAST_STATUS=-
    LAST_REPOS=-
    if is_epoch "$_llr_started" \
        && is_epoch "$_llr_finished" \
        && { [ "$_llr_status" = ok ] || [ "$_llr_status" = failed ]; } \
        && [ -n "$_llr_repos" ]
    then
        LAST_STARTED=$_llr_started
        LAST_FINISHED=$_llr_finished
        LAST_STATUS=$_llr_status
        # Verbatim: it is the list of repository names the run built, and its
        # leading space is part of what was written.
        LAST_REPOS=$_llr_repos
    fi
    return 0
}

# The healthcheck, and `docker inspect`'s answer to "is this thing working".
# One question: has the state this scheduler last recorded outlived its own
# deadline? A wedged run and a sleep that never woke both fail it; a container
# that has only just started has written `starting` and has not.
health() {
    _h_state=$(status_field state)
    _h_deadline=$(status_field deadline)
    if [ -z "$_h_state" ]; then
        warn "no $statefile — the scheduler has not reported in"
        return 1
    fi
    if [ -z "$_h_deadline" ]; then
        warn "$statefile carries no deadline, which is the one field this check rests on"
        return 1
    fi
    if ! is_epoch "$_h_deadline"; then
        warn "$statefile records deadline='$_h_deadline', which is not a unix time this check can compare"
        return 1
    fi
    _h_now=$(date +%s)
    if [ "$_h_now" -gt "$_h_deadline" ]; then
        warn "state '$_h_state' has outlived its deadline by $((_h_now - _h_deadline))s"
        warn "  a run that never returned, or a sleep that never woke — see docker logs"
        return 1
    fi
    say "$_h_state, $((_h_deadline - _h_now))s of its budget left"
    return 0
}

# --- Entry ----------------------------------------------------------------------

mode="${1:-schedule}"

case "$mode" in
    plan)
        [ -n "$apps" ] || { warn "KASBAH_BACKUP_APPS is not set"; exit 1; }
        plan
        ;;
    next)
        d=$(delay_secs "${2:-}")
        printf 'next run in %ss (%02d:%02d:%02d from now), slot %s plus %ss jitter\n' \
            "$d" "$((d / 3600))" "$((d % 3600 / 60))" "$((d % 60))" "$at" "$jitter"
        ;;
    once)
        # Bounded and recorded exactly as the scheduled run is: this is the same
        # function on the same clock, and an operator taking a snapshot before
        # something risky should leave the same trace behind.
        run_once
        ;;
    health)
        health
        ;;
    schedule)
        say "scheduled daily at $at plus ${jitter}s jitter; apps $apps, data $data"
        say "one restic call may take ${timeout_s}s (kasbah server init --backup-timeout=)"
        # Before the first record this process writes, so a scheduler that has
        # only just started reports the stack's history and not its own age.
        load_last_run
        write_status starting "$(( $(date +%s) + grace ))"
        while :; do
            d=$(delay_secs)
            say "sleeping ${d}s until the next run"
            write_sleeping
            sleep "$d"
            # A failed run is reported and slept off rather than exited: the
            # container carries `restart: unless-stopped`, so exiting would turn
            # one unreachable endpoint into a restart loop that backs up nothing
            # and fills the log.
            run_once || warn "the run did not finish cleanly — the next one is still scheduled"
        done
        ;;
    *)
        warn "unknown mode '$mode' (expected: schedule, once, plan, next, health)"
        exit 1
        ;;
esac
