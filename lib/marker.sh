# kasbah — the server marker, read once per run
# Sourced by bin/kasbah and lib/*.sh. Do not execute directly.

[ -n "${_KASBAH_MARKER_LOADED:-}" ] && return 0
_KASBAH_MARKER_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

# The server marker is where everything about a server's layout comes from, and
# the apps path holding it is a property of the *server*, not of a project's
# memory of one — so the server carries it: `kasbah server init` writes
# /etc/kasbah/apps-path, and this reads it before falling back to /apps.
#
# Discovery, in one round trip: read the pointer, then read
# <that>/.kasbah/server.json.
#
#   * no pointer            — /apps, exactly as before the pointer existed, so
#                             every server prepared without one keeps working;
#   * pointer, marker       — that tree, whatever it is;
#   * pointer, no marker    — a hard failure naming both paths, because falling
#                             back to /apps would read a *different* server's
#                             marker and deploy against it. Unless the pointer
#                             names /apps itself: the fallback would have read
#                             the same file, so that is the ordinary "this
#                             server looks unprepared" exit 4;
#   * a pointer that cannot be read, that sits behind a directory this user
#     cannot enter, or that holds something other than an absolute path
#                            — refused rather than guessed. Both the file and
#                              its directory are world-readable on a server
#                              kasbah prepared, and an empty read is not
#                              evidence that the server is at /apps.
#
# Two commands read all this the same way — `kasbah deploy` and `kasbah env` —
# so the read, the refusals and the validation live here rather than in both.
#
# (`kasbah server status` keeps its own: it takes `--apps-path`, so it can be
# pointed at a tree no pointer names, and its refusal says something different.)

MARKER_JSON=""
MARKER_APPS_PATH=""
MARKER_DATA_PATH=""
MARKER_CPU_LIMIT=""
MARKER_MEM_LIMIT=""
# Where the marker was found, and how that path was arrived at — `pointer` or
# `default`. Set before any refusal, so every message below can name it.
MARKER_PATH=""
MARKER_SOURCE=""

# marker_read TARGET_LABEL — ssh_connect must already have run. Exits 4 when the
# server looks unprepared, and the refusal neither prints nor implies a bare
# `kasbah server init <target>`: run against a server whose apps path is not
# /apps, that command renders a second Traefik stack under /apps and brings it
# up as compose project `traefik` — the frozen name the live one already has —
# so compose recreates the running proxy against the new file, off the old
# dynamic/ and acme.json, and every site on the server goes dark. An operator
# following kasbah's own instruction must not be able to do that.
marker_read() {
    local target="$1"
    local out rc=0

    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    out=$(ssh_script "$KASBAH_DEFAULT_APPS_PATH" "$KASBAH_APPS_POINTER" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
pointer=$2
dir=${pointer%/*}
source=default
pointed=""

# The pointer's own spelling, reduced to the one every other path in kasbah is
# written in: CR and trailing blanks off, empty and `.` segments dropped, no
# trailing slash. `/apps/`, `//apps` and `/apps/.` all name the tree `/apps`,
# and a comparison against the normalised form is the difference between
# recognising that and refusing it. `..` is left as a segment: kasbah's own
# flags reject one, so a pointer carrying it compares unequal, which is the
# safe direction.
norm_path() {
    local p="$1" out="" seg IFS=/
    set -f
    p=${p%$'\r'}
    while [ -n "$p" ]; do
        case ${p: -1} in
            ' '|$'\t') p=${p%?} ;;
            *) break ;;
        esac
    done
    case $p in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    for seg in $p; do
        [ -n "$seg" ] && [ "$seg" != . ] || continue
        out="$out/$seg"
    done
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}

if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$pointer" >&2
    exit 1
fi
readable=yes
reachable=yes
if [ -f "$pointer" ]; then
    source=pointer
    if [ -r "$pointer" ]; then
        # The first line only: this is a file a human may have edited.
        IFS= read -r pointed < "$pointer" || pointed=""
        pointed=$(norm_path "$pointed")
    else
        # World-readable is the contract, and this command deploys as whatever
        # user it is given: a pointer only root can read is reported as such,
        # never as an empty one.
        readable=no
    fi
elif [ -d "$dir" ] && [ ! -x "$dir" ]; then
    # `[ -e ]` answers "no" for a file behind a directory this user cannot
    # traverse, exactly as it does for one that is not there — and the two have
    # opposite verdicts. Falling through as "absent" would read $1 without a
    # word, which is the one thing this file exists to prevent.
    source=pointer
    reachable=no
fi

# Reported before the path is judged, so the caller can quote the pointer's own
# content back in its refusal.
if [ "$source" = pointer ]; then
    printf 'apps=%s\n' "$pointed"
else
    printf 'apps=%s\n' "$apps"
fi
printf 'source=%s\n' "$source"

if [ "$source" = pointer ]; then
    [ "$reachable" = yes ] || exit 7
    [ "$readable" = yes ] || exit 6
    case $pointed in
        /?*) apps=$pointed ;;
        *)   exit 5 ;;
    esac
fi

marker="$apps/.kasbah/server.json"
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$marker" >&2
    exit 1
fi
[ -f "$marker" ] || exit 3
cat "$marker"
REMOTE
    ) || rc=$?

    case $rc in
        0|3|5|6|7) ;;
        *) die "could not read the server marker on $target (the remote step exited $rc, see above)" ;;
    esac

    # The two header lines, then whatever is left. Checked as a protocol before
    # anything is read out of it: a truncated step must not be absorbed into a
    # discovered path.
    local apps_line="" source_line="" body="" line header=ok
    {
        IFS= read -r apps_line || apps_line=""
        IFS= read -r source_line || source_line=""
        body="$(cat)"
    } <<<"$out"
    apps_line="${apps_line%$'\r'}"
    source_line="${source_line%$'\r'}"
    case $apps_line in apps=*) ;; *) header=bad ;; esac
    case $source_line in source=pointer|source=default) ;; *) header=bad ;; esac
    if [ "$header" != ok ]; then
        err "the marker read on $target did not report where it looked"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
        exit 1
    fi

    # Normalised on this side as well as on the far side: the two spellings of
    # a path are the same tree, and every judgement below — the marker path, the
    # comparison with the default, the remedy printed — has to see it that way
    # whichever of them arrives.
    local apps=""
    kasbah_norm_path apps "${apps_line#apps=}"
    MARKER_SOURCE="${source_line#source=}"

    # An `apps=` line is not the same thing as a path. The two statuses that
    # report a value which deliberately is not one are 5 — a pointer holding
    # something that is not a path, quoted back so the refusal can show it — and
    # 6/7, where there was nothing to read in the first place. A marker read or
    # a missing marker has to have named a directory, because the marker path
    # and the messages are built from it.
    if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then
        case $apps in
            /?*) ;;
            *)
                err "the marker read on $target did not report where it looked"
                err_cont "it named '$apps', which is not an absolute path — the step was truncated,"
                err_cont "or the remote shell rejected it. Raw output:"
                while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
                exit 1
                ;;
        esac
    fi

    MARKER_PATH="$apps/.kasbah/server.json"

    if [ "$rc" = 7 ]; then
        err "${KASBAH_APPS_POINTER%/*} on $target cannot be entered by this deploy user"
        err_cont "whether this server carries a pointer cannot be told from outside that"
        err_cont "directory, and $KASBAH_DEFAULT_APPS_PATH is only the right tree if it does not — so"
        err_cont "reading it now could be a different server entirely."
        err_cont "The directory is traversable by everyone on a server kasbah prepared"
        err_cont "(ssh $target 'sudo chmod 755 ${KASBAH_APPS_POINTER%/*}')."
        exit 1
    fi

    if [ "$rc" = 6 ]; then
        err "$KASBAH_APPS_POINTER on $target cannot be read by this deploy user"
        err_cont "that file is the server's record of where it was prepared, and every project"
        err_cont "command reads it as whatever user it deploys as — so it is world-readable by"
        err_cont "contract. Reading $KASBAH_DEFAULT_APPS_PATH instead is not the answer: the pointer may"
        err_cont "name another tree, and that would be a different server."
        err_cont "Fix the mode (ssh $target 'sudo chmod 644 $KASBAH_APPS_POINTER'), or re-run init"
        err_cont "at the apps path this server was prepared at, which rewrites the file."
        exit 1
    fi

    if [ "$rc" = 5 ]; then
        err "$KASBAH_APPS_POINTER on $target does not name an absolute path"
        err_cont "it holds '$apps', and that file is the whole of what says where this"
        err_cont "server was prepared. \`kasbah server init\` writes one absolute path there;"
        err_cont "correct it, or re-run init with --apps-path=<dir> set to the directory the"
        err_cont "server was actually prepared at, which rewrites it."
        exit 1
    fi

    if [ "$rc" = 3 ] && [ "$MARKER_SOURCE" = pointer ] \
       && [ "$apps" != "$KASBAH_DEFAULT_APPS_PATH" ]; then
        err "$target has no server marker at $MARKER_PATH"
        err_cont "$KASBAH_APPS_POINTER says this server was prepared at $apps, and there is no"
        err_cont "marker there. kasbah does not fall back to $KASBAH_DEFAULT_APPS_PATH when the pointer"
        err_cont "names a tree: a marker found somewhere else describes a different server,"
        err_cont "and deploying against that is worse than stopping."
        err_cont "So either $apps was removed, or the pointer names the wrong tree — look at"
        err_cont "both before doing anything else."
        exit 1
    fi

    # What is left is a server that looks unprepared: either nothing has ever
    # prepared it, or it was prepared elsewhere and the pointer is gone. A
    # pointer naming the default is this case too — the fallback would have read
    # the same tree, so there is nothing it could have been hiding.
    if [ "$rc" = 3 ]; then
        err "$target has no server marker at $MARKER_PATH"
        if [ "$MARKER_SOURCE" = pointer ]; then
            err_cont "That file is what \`kasbah server init\` writes last. $KASBAH_APPS_POINTER names"
            err_cont "$apps, which is where this command looks anyway. So this is one of two"
            err_cont "situations, and they have different answers:"
        else
            err_cont "That file is what \`kasbah server init\` writes last, and $KASBAH_APPS_POINTER"
            err_cont "— the server's own record of where it was prepared, which is what points this"
            err_cont "command anywhere else — is not there either. So this is one of two"
            err_cont "situations, and they have different answers:"
        fi
        err_cont "  * the server has never been prepared, and initialising it is the answer."
        err_cont "  * it was prepared at another apps path and the pointer has been lost. Find"
        err_cont "    that tree (its marker is at <dir>/.kasbah/server.json), then re-run init"
        err_cont "    with --apps-path=<dir> set to it — that restores the pointer."
        err_cont "Do not guess the path. Pointed at the wrong one, init renders a second Traefik"
        err_cont "stack under the frozen 'traefik' compose project, which recreates the running"
        err_cont "proxy against it and takes every site down."
        exit "$KASBAH_EXIT_NO_REMOTE_STATE"
    fi

    MARKER_JSON="$body"

    # The command that repairs this server, spelled for *this* server: bare, it
    # would prepare a second one under /apps and take the first one's Traefik
    # with it.
    local init_cmd="kasbah server init $target"
    [ "$MARKER_SOURCE" != pointer ] || init_cmd="$init_cmd --apps-path=$apps"

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$MARKER_JSON" \
        || die "$MARKER_PATH on $target is not a JSON object — re-run \`$init_cmd\`"

    MARKER_APPS_PATH="$(jq -r '.apps_path // "" | tostring' <<<"$MARKER_JSON")"
    MARKER_DATA_PATH="$(jq -r '.data_path // "" | tostring' <<<"$MARKER_JSON")"
    local path
    for path in "$MARKER_APPS_PATH" "$MARKER_DATA_PATH"; do
        case $path in
            /?*) ;;
            *) die "$MARKER_PATH on $target records apps_path='$MARKER_APPS_PATH' data_path='$MARKER_DATA_PATH'; both must be absolute paths — re-run \`$init_cmd\`" ;;
        esac
    done

    # The resource limits the KASBAH_* managed block is written from
    # (docs/env-template.md). Refused rather than defaulted when absent: a
    # `cpus:` of nothing is not a compose file that comes up, and guessing a
    # limit for somebody's server is not kasbah's call. They are written
    # through exactly as spelled — `14.4`, `54g` — never reformatted.
    MARKER_CPU_LIMIT="$(jq -r '.cpu_limit // "" | tostring' <<<"$MARKER_JSON")"
    MARKER_MEM_LIMIT="$(jq -r '.mem_limit // "" | tostring' <<<"$MARKER_JSON")"
    #
    # Whitespace is refused for the same reason versions.log refuses it: the
    # value goes into a `KEY=value` line that `docker compose` re-reads, and a
    # limit with a space in it is a compose file that fails to parse rather than
    # one that runs unlimited.
    local limit
    for limit in "$MARKER_CPU_LIMIT" "$MARKER_MEM_LIMIT"; do
        case $limit in
            ''|*[[:space:]]*)
                err "$MARKER_PATH on $target records cpu_limit='$MARKER_CPU_LIMIT' mem_limit='$MARKER_MEM_LIMIT'"
                err_cont "both are required and neither may carry whitespace: kasbah writes them"
                err_cont "into every project's .env as KASBAH_CPU_LIMIT / KASBAH_MEM_LIMIT, and"
                err_cont "the compose files read cpus: and mem_limit: from there"
                err_cont "(docs/env-template.md). Re-run \`$init_cmd\` to rewrite it."
                exit 1
                ;;
        esac
    done
    return 0
}
