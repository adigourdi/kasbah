# kasbah — reading the deploy record: history, pending, changelog
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_HISTORY_LOADED:-}" ] && return 0
_KASBAH_HISTORY_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/deploy.sh"
. "$KASBAH_LIB_DIR/versions_log.sh"

# Three commands over one file. `<apps>/<name>/versions.log` — plus the
# `versions.log.gz` that rotation moved the entries older than three months into
# — is every deploy and rollback that ever ran on a server
# (docs/build-deploy.md → versions.log format, Rotation). These read it:
#
#   history    the record as a table; --all adds the archived half
#   pending    git log <deployed>..<HEAD, or a named version>
#   changelog  git log <the entry before the last>..<the last>
#
# Read-only on both sides. lib/versions_log.sh's remote step opens two files and
# base64s them and nothing here writes to the server at all; on this side the
# only write is `last_server` in the state file, on success, which
# docs/project-manifest.md names all three of these among the writers of.
#
# **The record is what says what is deployed, never state.json.** The state file
# carries a last_version and it is a cache of what this workstation last did — a
# colleague's deploy, or a rollback run from another checkout, leaves it saying
# something the server stopped agreeing with. So the deployed version comes out
# of the round trip these commands have already paid for
# (docs/project-manifest.md → State file).
#
# The report goes to stdout and everything else — progress, warnings, refusals —
# to stderr through info/warn/err, the way `kasbah server status` splits them.
# `kasbah history | column -t` has to get the table and nothing else.
#
# Nothing here fails over git. A tag this checkout has never fetched, an
# inverted range, an empty one: each is a fact about the checkout rather than
# about the server that was just read, and lib/deploy.sh's `_deploy_changelog`
# already answers all four without turning any of them into a failure.

# --all, and only `history` has one.
_HIST_ALL=no

_history_usage() {
    case "$1" in
        history)
            cat <<EOF
Usage: kasbah history [USER@HOST] [--all]

The deploy record on a server, as a table: timestamp, action, version, backup
file, kasbah version. Run from the project root. USER@HOST defaults to the last
server this project talked to (.kasbah/state.json).

By default the table is <apps>/<name>/versions.log — the active log. --all puts
the entries rotation moved into versions.log.gz in front of them, oldest first,
so the table spans the rotation point in one run.

A line the reader cannot get four fields out of is shown as it stands, marked
'!!': a write killed mid-append leaves exactly that, and it is still a deploy
that ran.

Reads the server and writes nothing to it. See docs/build-deploy.md.
EOF
            ;;
        pending)
            cat <<EOF
Usage: kasbah pending [USER@HOST] [VERSION]

The commits between the version a server is running and this checkout — the
answer to "what would deploying ship", asked before a tag is cut. Run from the
project root.

The deployed version is read out of the server's versions.log at run time, never
out of .kasbah/state.json: state is this workstation's cache of what it last
did, and the server is what is running.

With VERSION, the range ends at v<VERSION> instead of HEAD.
An argument containing '@' is the server, anything else is the version.

Reads the server and writes nothing to it. See docs/cli.md.
EOF
            ;;
        changelog)
            cat <<EOF
Usage: kasbah changelog [USER@HOST]

What changed in the version a server is running now: the commits between the
last two entries of its deploy record. Run from the project root.

The last two entries whatever their action — after a rollback the version
running is the rollback's target, and the range then runs backwards, which is
reported as what the rollback gave up rather than as an error.

Reads the server and writes nothing to it. See docs/cli.md.
EOF
            ;;
    esac
}

# --- Command line ---------------------------------------------------------------

_history_parse_args() {
    local cmd="$1"; shift

    _DEPLOY_TARGET=""
    _DEPLOY_VERSION_ARG=""
    _HIST_ALL=no

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _history_usage "$cmd"; exit 0 ;;
            --all)
                [ "$cmd" = history ] \
                    || die "$cmd: unknown flag '--all' — the archived half of the record is \`kasbah history ${_DEPLOY_TARGET:-USER@HOST} --all\`"
                _HIST_ALL=yes ;;
            --all=*)
                die "$cmd: --all takes no value — pass it on its own (\`kasbah history USER@HOST --all\`)" ;;
            -*)
                case "$cmd" in
                    history) die "history: unknown flag '${1%%=*}' (history takes USER@HOST and --all)" ;;
                    pending) die "pending: unknown flag '${1%%=*}' (pending takes USER@HOST and VERSION)" ;;
                    *)       die "$cmd: unknown flag '${1%%=*}' ($cmd takes USER@HOST)" ;;
                esac ;;
            *)
                case "$cmd" in
                    pending) _deploy_classify_arg pending "$1" ;;
                    *)       _history_target_arg "$cmd" "$1" ;;
                esac ;;
        esac
        shift
    done
    return 0
}

# history and changelog take one positional and it is the server. Which of the
# two an argument is stays _deploy_classify_arg's rule and is called through to;
# what is added here is the refusal, for the two commands that have no version
# to hand it to.
_history_target_arg() {
    local _ta_cmd="$1" _ta_arg="${2%$'\r'}"

    case $_ta_arg in
        *@*) _deploy_classify_arg "$_ta_cmd" "$_ta_arg" ;;
        *)   die "$_ta_cmd: '$_ta_arg' is not a server — USER@HOST carries an '@', and $_ta_cmd takes no version (\`kasbah pending [VERSION]\` is the one that does)" ;;
    esac
    return 0
}

# --- The record -----------------------------------------------------------------

# The one round trip all three make. The manifest names the project directory,
# the server's own marker names the tree it sits in (lib/marker.sh — the same
# discovery `deploy` and `env` use, so none of these has to be told an apps
# path), and both halves of the record come back together.
#
# The master is closed as soon as it has done its work: everything below this is
# git and printing, and a report the operator reads for a minute is not a reason
# to hold a connection open.
_history_read_record() {
    local _rr_cmd="$1"

    manifest_require
    _deploy_resolve_target "$_rr_cmd"

    ssh_connect "$_DEPLOY_TARGET"
    _deploy_read_marker
    vlog_fetch "$_DEPLOY_TARGET" "$_DEPLOY_APPS_PATH" "$MANIFEST_NAME"
    ssh_disconnect
    return 0
}

# Is the archived half of the record fully accounted for? Not the same question
# as "are there archived entries": an archive kasbah could not read, or one
# whose last gzip member is truncated, leaves entries this side cannot see, and
# every sentence that would otherwise claim to describe the whole record has to
# know that (docs/phases/05-undo.md — a message that under-describes a partial
# read is worse than no message).
_history_archive_whole() {
    [ "$VLOG_ARCHIVE_DAMAGED" = no ] || return 1
    case "$VLOG_ARCHIVE_STATE" in
        ok|missing|empty) return 0 ;;
        *) return 1 ;;
    esac
}

# The one line that says what is missing from the report above it, on stdout
# with the rest of it: `vlog_fetch` has already warned on stderr with the
# diagnosis, and a report redirected to a file must still not read as complete.
# Empty when the archive is whole.
#
# All three shapes end in the same clause and differ only in the cause, because
# three of the four callers have no table to be short of rows — what they share
# is a record they cannot claim to have read.
_history_archive_note() {
    local _an_out="$1" _an_seen="$2"

    printf -v "$_an_out" '%s' ""
    _history_archive_whole && return 0

    if [ "$VLOG_ARCHIVE_DAMAGED" = yes ] && [ "$_an_seen" -gt 0 ]; then
        printf -v "$_an_out" '%s' \
            "$VLOG_ARCHIVE_PATH ends in a truncated gzip member: whatever is inside it could not be decoded, so this is not the whole record"
    elif [ "$VLOG_ARCHIVE_DAMAGED" = yes ]; then
        printf -v "$_an_out" '%s' \
            "$VLOG_ARCHIVE_PATH is not gzip: no archived entry could be decoded, so this is not the whole record"
    else
        printf -v "$_an_out" '%s' \
            "$VLOG_ARCHIVE_PATH could not be read (the probe called it '$VLOG_ARCHIVE_STATE'), so this is not the whole record"
    fi
    return 0
}

# --- history --------------------------------------------------------------------

# The table. Five columns, the four frozen fields plus kasbah= — the order
# docs/cli.md names them in — padded to the widest value each actually holds, so
# a record whose backup paths are real paths does not push the last column off
# into the distance for the rest.
#
# An entry that did not parse is not a row: there is nothing to put in four of
# the five columns, and inventing a `?` for each would make a damaged line look
# like a deploy of unknown version. It is shown as the bytes the file holds,
# marked, in the place it occupies — the operator is the one who can tell what
# happened to it.
_history_render() {
    local i src ord file kasbah note sep=no
    local n_arch=0 n_act=0 n_bad=0
    local shown=() ordinal=()
    # The header labels' own widths: the table is never narrower than its
    # headings, whatever the data is.
    local w_ts=9 w_action=6 w_version=7 w_backup=6

    for i in "${!VLOG_SRC[@]}"; do
        src="${VLOG_SRC[$i]}"
        if [ "$src" = archive ]; then
            n_arch=$((n_arch + 1))
            ordinal[$i]=$n_arch
            [ "$_HIST_ALL" = yes ] || continue
        else
            n_act=$((n_act + 1))
            ordinal[$i]=$n_act
        fi
        shown+=("$i")
        if [ "${VLOG_OK[$i]}" != yes ]; then
            n_bad=$((n_bad + 1))
            continue
        fi
        [ "${#VLOG_TS[$i]}"      -le "$w_ts" ]      || w_ts="${#VLOG_TS[$i]}"
        [ "${#VLOG_ACTION[$i]}"  -le "$w_action" ]  || w_action="${#VLOG_ACTION[$i]}"
        [ "${#VLOG_VERSION[$i]}" -le "$w_version" ] || w_version="${#VLOG_VERSION[$i]}"
        [ "${#VLOG_BACKUP[$i]}"  -le "$w_backup" ]  || w_backup="${#VLOG_BACKUP[$i]}"
    done

    if [ "${#shown[@]}" -eq 0 ]; then
        _history_render_empty "$n_arch"
        return 0
    fi

    printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
        "$w_ts" TIMESTAMP "$w_action" ACTION "$w_version" VERSION "$w_backup" BACKUP KASBAH
    for i in "${shown[@]}"; do
        # The rotation point, drawn once and only where both halves are on
        # screen: the archive block comes first, so the first active entry after
        # an archived one is it.
        if [ "$sep" = no ] && [ "${VLOG_SRC[$i]}" = active ] && [ "$n_arch" -gt 0 ] \
           && [ "$_HIST_ALL" = yes ]; then
            sep=yes
            printf -- '-- rotated into %s above / %s below --\n' \
                "${VLOG_ARCHIVE_PATH##*/}" "${VLOG_ACTIVE_PATH##*/}"
        fi
        if [ "${VLOG_OK[$i]}" != yes ]; then
            ord="${ordinal[$i]}"
            [ "${VLOG_SRC[$i]}" = archive ] && file="${VLOG_ARCHIVE_PATH##*/}" || file="${VLOG_ACTIVE_PATH##*/}"
            printf '!! entry %s of %s is not a kasbah entry: %s\n' "$ord" "$file" "${VLOG_RAW[$i]%$'\r'}"
            continue
        fi
        # A line carrying only the four frozen fields is legal — kasbah= is one
        # of the appended pairs — and an empty last column would read as a
        # column that failed rather than one the line never had.
        kasbah="${VLOG_KASBAH[$i]}"
        [ -n "$kasbah" ] || kasbah="-"
        printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
            "$w_ts" "${VLOG_TS[$i]}" "$w_action" "${VLOG_ACTION[$i]}" \
            "$w_version" "${VLOG_VERSION[$i]}" "$w_backup" "${VLOG_BACKUP[$i]}" "$kasbah"
    done

    if [ "$_HIST_ALL" = yes ]; then
        printf '%s %s on %s — %s archived in %s, %s active in %s\n' \
            "${#shown[@]}" "$(_history_entry_word "${#shown[@]}")" "$_DEPLOY_TARGET" \
            "$n_arch" "$VLOG_ARCHIVE_PATH" "$n_act" "$VLOG_ACTIVE_PATH"
    else
        printf '%s %s in %s on %s\n' \
            "$n_act" "$(_history_entry_word "$n_act")" "$VLOG_ACTIVE_PATH" "$_DEPLOY_TARGET"
        if [ "$n_arch" -gt 0 ]; then
            # What --all would add, in the words the note below will or will not
            # contradict: an archive kasbah read only part of has no whole
            # record to offer, and two sentences arguing is how a reader stops
            # believing either.
            printf '%s more %s archived in %s — `kasbah history %s --all` %s\n' \
                "$n_arch" "$(_history_entry_word "$n_arch")" "${VLOG_ARCHIVE_PATH##*/}" \
                "$_DEPLOY_TARGET" "$(_history_all_offers)"
        fi
    fi
    [ "$n_bad" -eq 0 ] \
        || printf '%s of them could not be read as a kasbah entry and are shown above as !!\n' "$n_bad"

    # Said in both modes, and for different reasons: with --all the table is
    # short of the entries the archive was holding, and without it the count of
    # what --all would add is short by the same ones.
    _history_archive_note note "$n_arch"
    [ -z "$note" ] || printf '%s\n' "$note"
    return 0
}

# No row to draw. Which of the several reasons it is matters more here than
# anywhere else in this file: "never deployed to this server" and "the record is
# not where it should be" are the two answers an operator acts on differently.
_history_render_empty() {
    local _re_arch="$1" _re_note=""

    if [ "$_HIST_ALL" = no ] && [ "$_re_arch" -gt 0 ]; then
        printf 'no entry in %s on %s — %s archived %s in %s\n' \
            "$VLOG_ACTIVE_PATH" "$_DEPLOY_TARGET" "$_re_arch" \
            "$(_history_entry_word "$_re_arch")" "${VLOG_ARCHIVE_PATH##*/}"
        printf 'rotation never empties the active log, so this is a log that was lost or replaced — `kasbah history %s --all` %s\n' \
            "$_DEPLOY_TARGET" "$(_history_all_offers)"
    else
        case "$VLOG_ACTIVE_STATE" in
            empty) printf '%s on %s is empty — no deploy of %s is recorded there\n' \
                       "$VLOG_ACTIVE_PATH" "$_DEPLOY_TARGET" "$MANIFEST_NAME" ;;
            *)     printf 'no deploy record for %s on %s — there is no %s\n' \
                       "$MANIFEST_NAME" "$_DEPLOY_TARGET" "$VLOG_ACTIVE_PATH" ;;
        esac
    fi
    # Every branch above, not just the last: an empty active log beside an
    # archive kasbah could only half read is the case where the note matters
    # most, and it was the branch that returned before reaching it.
    _history_archive_note _re_note "$_re_arch"
    [ -z "$_re_note" ] || printf '%s\n' "$_re_note"
    return 0
}

# What `--all` can honestly promise, for the sentence that recommends it.
_history_all_offers() {
    if _history_archive_whole; then
        printf 'shows the whole record'
    else
        printf 'shows what could be read of it'
    fi
}

_history_entry_word() {
    [ "$1" = 1 ] && printf 'entry' || printf 'entries'
}

# --- The two changelogs ---------------------------------------------------------

# The entry the record says is deployed: the last line of the **active** log,
# whatever its action — after a rollback that is the rollback's target. Prints
# the one-line header both commands open with and returns the index, or prints
# the reason there is none and returns 1.
#
# "No entry" and "an entry that will not parse" are answered separately on
# purpose. They are the same emptiness to a caller that only asks for a version,
# and calling the second one a first deploy is a defect this codebase has
# shipped once already (docs/phases/05-undo.md).
_history_deployed() {
    local _hd_out="$1" _hd_idx="" _hd_note="" _hd_arch=0 _hd_i

    printf -v "$_hd_out" '%s' ""
    if ! vlog_last_entry _hd_idx; then
        # Counted rather than asked as a yes/no, because the note below picks
        # its sentence by whether anything was decoded — a truncated trailing
        # member and a payload that is not gzip at all are different repairs
        # (lib/versions_log.sh → _vlog_decode_archive).
        for _hd_i in "${!VLOG_SRC[@]}"; do
            [ "${VLOG_SRC[$_hd_i]}" != archive ] || _hd_arch=$((_hd_arch + 1))
        done
        if [ "$_hd_arch" -gt 0 ]; then
            printf '%s holds no entry for %s, and its archive does — so this is a record that was lost or replaced, not a first deploy\n' \
                "$VLOG_ACTIVE_PATH" "$MANIFEST_NAME"
        elif _history_archive_whole; then
            printf '%s has never deployed %s — %s holds no entry, and neither does its archive\n' \
                "$_DEPLOY_TARGET" "$MANIFEST_NAME" "$VLOG_ACTIVE_PATH"
        else
            # "Never deployed here" is a claim about both files, and one of them
            # could not be read. Asserting the absence anyway is the guard that
            # fails open, one layer up from where vlog_fetch refuses it.
            printf '%s holds no entry for %s, and whether its archive holds one cannot be told — this is not evidence that %s has never deployed it\n' \
                "$VLOG_ACTIVE_PATH" "$MANIFEST_NAME" "$_DEPLOY_TARGET"
        fi
        _history_archive_note _hd_note "$_hd_arch"
        [ -z "$_hd_note" ] || printf '%s\n' "$_hd_note"
        return 1
    fi

    if [ "${VLOG_OK[$_hd_idx]}" != yes ]; then
        printf '%s has deployed %s, and the last line of %s is not one a version can be read out of:\n' \
            "$_DEPLOY_TARGET" "$MANIFEST_NAME" "$VLOG_ACTIVE_PATH"
        printf '  %s\n' "${VLOG_RAW[$_hd_idx]%$'\r'}"
        printf 'a write killed mid-append leaves exactly that, and the deploy it recorded is still one that ran — so there is no version here to compare against\n'
        return 1
    fi

    printf '%s runs %s %s (%s, %s)\n' \
        "$_DEPLOY_TARGET" "$MANIFEST_NAME" "${VLOG_VERSION[$_hd_idx]}" \
        "${VLOG_ACTION[$_hd_idx]}" "${VLOG_TS[$_hd_idx]}"
    printf -v "$_hd_out" '%s' "$_hd_idx"
    return 0
}

# A ref this checkout can resolve to a commit.
_history_have_ref() {
    git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1
}

# Two refs naming the same commit — which is what separates "nothing to ship"
# from "the range runs the other way".
_history_same_commit() {
    local _sc_a _sc_b
    _sc_a="$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null)" || return 1
    _sc_b="$(git rev-parse -q --verify "$2^{commit}" 2>/dev/null)" || return 1
    [ "$_sc_a" = "$_sc_b" ]
}

# The commits in a range, on stdout, under a line saying how many. Never called
# with an empty log: each caller has its own sentence for that, and they are
# three different sentences.
_history_print_log() {
    local _pl_range="$1" _pl_log="$2" _pl_lines=() _pl_line

    readarray -t _pl_lines <<<"$_pl_log"
    printf '%s — %s commit%s\n' "$_pl_range" "${#_pl_lines[@]}" \
        "$([ "${#_pl_lines[@]}" = 1 ] || printf 's')"
    for _pl_line in "${_pl_lines[@]}"; do
        printf '  %s\n' "$_pl_line"
    done
    return 0
}

# git log for a range whose two ends are already known to resolve. A failure
# here is git's to explain — it has already said so on stderr — and it is not
# this command's to die over.
_history_git_log() {
    local _gl_range="$1" _gl_out="$2" _gl_log=""

    _gl_log="$(git log --no-color --format='%h %s' "$_gl_range" --)" || return 1
    printf -v "$_gl_out" '%s' "$_gl_log"
    return 0
}

# --- pending --------------------------------------------------------------------

_history_pending_report() {
    local idx="" deployed target_label target_ref range log=""

    _history_deployed idx || return 0
    deployed="${VLOG_VERSION[$idx]}"

    if [ -n "$_DEPLOY_VERSION_ARG" ]; then
        target_label="v$_DEPLOY_VERSION_ARG"
        target_ref="refs/tags/v$_DEPLOY_VERSION_ARG"
    else
        target_label=HEAD
        target_ref=HEAD
    fi
    range="v$deployed..$target_label"

    if ! _history_have_ref "refs/tags/v$deployed"; then
        warn "$_DEPLOY_TARGET is running $deployed and this checkout has no tag v$deployed — nothing to compare against"
        warn "\`git fetch --tags\`, then \`git log $range\`"
        return 0
    fi
    if ! _history_have_ref "$target_ref"; then
        if [ -n "$_DEPLOY_VERSION_ARG" ]; then
            warn "v$_DEPLOY_VERSION_ARG is not a tag in this checkout — \`git fetch --tags\`, or cut it first"
        else
            warn "this checkout has no HEAD commit — there is nothing yet to be pending"
        fi
        return 0
    fi
    if ! _history_git_log "$range" log; then
        warn "could not read \`git log $range\` (see git's error above) — nothing pending can be listed"
        return 0
    fi

    if [ -n "$log" ]; then
        _history_print_log "$range" "$log"
        return 0
    fi
    if _history_same_commit "refs/tags/v$deployed" "$target_ref"; then
        printf '%s — nothing pending: %s is the commit %s is already running\n' \
            "$range" "$target_label" "$_DEPLOY_TARGET"
        return 0
    fi
    # Empty in this direction means the target is not ahead of what is running:
    # the server is on something newer, and deploying would take it back. That
    # is `kasbah rollback`'s job, so the wording says which way round it is
    # rather than calling it a no-op.
    printf '%s — nothing pending: %s is not ahead of the %s %s is running\n' \
        "$range" "$target_label" "$deployed" "$_DEPLOY_TARGET"
    printf '`git log %s..v%s` is what deploying it would give up\n' "$target_label" "$deployed"
    return 0
}

# --- changelog ------------------------------------------------------------------

# The last two entries of the record, whatever their action. Not the last two
# `deploy` entries: "what changed in the version deployed now" has to read the
# version actually running, and after a rollback that is the rollback's target
# (docs/cli.md → kasbah changelog).
#
# The pair spans the rotation point without noticing it — the entry before the
# active log's first is the archive's last, and lib/versions_log.sh hands both
# files back in one set of arrays with the archive in front.
_history_changelog_report() {
    local idx="" prev_idx curr prev range log="" note=""

    _history_deployed idx || return 0
    curr="${VLOG_VERSION[$idx]}"

    if [ "$idx" -eq 0 ]; then
        # The record holds one entry — unless the archive is what the entry
        # before it was in, and that could not be read. Those are opposite
        # answers and only VLOG_ARCHIVE_STATE tells them apart.
        if _history_archive_whole; then
            printf 'nothing in the record before it — %s is the first version %s ran here\n' \
                "$curr" "$_DEPLOY_TARGET"
        else
            printf 'nothing readable in the record before it, so there is no range to compare against\n'
            _history_archive_note note 0
            [ -z "$note" ] || printf '%s\n' "$note"
        fi
        return 0
    fi

    prev_idx=$((idx - 1))
    if [ "${VLOG_OK[$prev_idx]}" != yes ]; then
        printf 'the entry before it is not one a version can be read out of:\n'
        printf '  %s\n' "${VLOG_RAW[$prev_idx]%$'\r'}"
        printf 'so there is no range to compare against — look at %s on %s\n' \
            "$VLOG_ACTIVE_PATH" "$_DEPLOY_TARGET"
        return 0
    fi
    prev="${VLOG_VERSION[$prev_idx]}"
    printf 'after %s (%s, %s%s)\n' "$prev" "${VLOG_ACTION[$prev_idx]}" "${VLOG_TS[$prev_idx]}" \
        "$([ "${VLOG_SRC[$prev_idx]}" = archive ] && printf ', archived' || printf '')"

    range="v$prev..v$curr"
    if ! _history_have_ref "refs/tags/v$prev"; then
        warn "this checkout has no tag v$prev — no changelog"
        warn "\`git fetch --tags\`, then \`git log $range\`"
        return 0
    fi
    if ! _history_have_ref "refs/tags/v$curr"; then
        warn "this checkout has no tag v$curr — no changelog"
        warn "\`git fetch --tags\`, then \`git log $range\`"
        return 0
    fi
    if ! _history_git_log "$range" log; then
        warn "could not read \`git log $range\` (see git's error above) — no changelog"
        return 0
    fi

    if [ -n "$log" ]; then
        _history_print_log "$range" "$log"
        return 0
    fi
    if [ "$prev" = "$curr" ]; then
        printf '%s — none: %s was already the version there, so the entry above it is a redeploy\n' \
            "$range" "$curr"
        return 0
    fi
    # The rollback case, and the reason this command reads the last two entries
    # rather than the last two deploys: v<curr> is behind v<prev>, so the range
    # is empty in this direction and the interesting log is the other one.
    printf '%s — none: %s is not ahead of the %s it replaced\n' "$range" "$curr" "$prev"
    printf '`git log v%s..v%s` is what that gave up\n' "$curr" "$prev"
    return 0
}

# --- Commands -------------------------------------------------------------------

# docs/project-manifest.md's write rule, in all three: last_server is written
# once the server has answered and the report has been printed, and a run that
# stopped anywhere earlier leaves the state file alone.
cmd_history() {
    _history_parse_args history "$@"
    _history_read_record history
    _history_render
    state_record last_server "$_DEPLOY_TARGET"
}

cmd_pending() {
    _history_parse_args pending "$@"
    _history_read_record pending
    _history_pending_report
    state_record last_server "$_DEPLOY_TARGET"
}

cmd_changelog() {
    _history_parse_args changelog "$@"
    _history_read_record changelog
    _history_changelog_report
    state_record last_server "$_DEPLOY_TARGET"
}
