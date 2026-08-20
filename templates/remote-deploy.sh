#!/usr/bin/env bash
# kasbah — the VPS side of a deploy. Rendered from this template on every
# deploy and installed at <apps>/<project>/scripts/remote-deploy.sh, so it
# always matches both the kasbah that drives it and the manifest of the release
# it drives (docs/build-deploy.md → helper scripts on the VPS). Do not edit it
# on the server; edit this template, or the project's kasbah.yml.
#
#   remote-deploy.sh deploy   <version> [--skip-hooks] [--no-health-wait]
#                                       [--allow-stopped]
#   remote-deploy.sh rollback <version> [--skip-hooks] [--no-health-wait]
#                                       [--allow-stopped]
#
# The order is fixed, and it is the one docs/build-deploy.md step 8 spells out:
# backup → pre-deploy hooks → retag :current → compose up -d --remove-orphans →
# health wait → post-deploy hooks → one appended versions.log line, rotated.
# Then, on stdout and nowhere else, the `key=value` report `rd_report` describes.
#
# `rollback` is that order with the backup removed and the other hook pair run
# (docs/build-deploy.md → `kasbah rollback` → Flow, step 10). The version's own
# files have already been restored from git by the time it runs, so field 4 of
# a rollback entry is always `no-backup`.
#
# Runnable by hand on the server, with nothing of kasbah's installed: everything
# the manifest says about this project is pre-rendered into the generated block
# below, so this script never parses YAML and the server needs no yq, jq or
# python3 (docs/phases/04-ship.md → Findings). It takes no arguments beyond the
# ones above and derives everything else from where it is installed.
#
# Tool budget, the same rule lib/env.sh's header states: coreutils and bash
# builtins, plus `docker`, `flock` (util-linux) and `gzip` — the three a prepared
# server is guaranteed to have (docs/server-setup.md → prerequisites). No awk, no
# jq, no yq, no bc.

set -euo pipefail
# The same locale every payload kasbah sends over ssh runs under; this script
# is the one remote step that arrives as a file rather than a heredoc, and it
# had been left out. What it prints is read by machines — the versions.log line
# every kasbah version has to parse, and the `docker` output the image digests
# come out of, whose wording is otherwise the server's locale to choose.
export LC_ALL=C

# >>> kasbah generated block - rendered from kasbah.yml on every deploy, do not edit >>>
# Everything between the two markers is written by `kasbah deploy`
# (lib/remote_deploy.sh) out of the project's kasbah.yml. The manifest is
# deliberately never synced to a server — there would be nothing here that could
# read it — so the local side pre-renders it instead.
#
# What stands here in the template itself is what a project with no built
# images, no hooks, no backup and no health: block renders to, which is also
# what this file does when run straight from the checkout.
RD_IMAGES=( )            # image names, without a tag; :<version> is appended
RD_HOOKS_PRE_DEPLOY=( )  # each entry "<container> <shell command…>"
RD_HOOKS_POST_DEPLOY=( )
RD_HOOKS_PRE_ROLLBACK=( )
RD_HOOKS_POST_ROLLBACK=( )
RD_HEALTH_CONTAINER=''   # empty: wait on every container that has a healthcheck
RD_HEALTH_TIMEOUT=120    # seconds; health.timeout is parsed on the local side
RD_BACKUP_CHECK=''       # empty: this project declares no backup:
RD_BACKUP_CONTAINER=''
RD_BACKUP_COMMAND=''
RD_BACKUP_PIPE=''        # empty: the dump is written straight to the file
RD_BACKUP_EXTENSION=''
RD_BACKUP_RETAIN=10
# <<< kasbah generated block <<<

# Flags, not manifest data, so they live outside the generated block.
RD_SKIP_HOOKS=no
RD_NO_HEALTH_WAIT=no
RD_ALLOW_STOPPED=no

# The mode, and the half of the manifest it selects. main() fills these in once;
# everything below reads them and never asks again which mode it is running, so
# one order and one set of guards serve both.
RD_MODE=deploy
RD_HOOKS_PRE=( )
RD_HOOKS_POST=( )
RD_PRE_HOOK=pre-deploy
RD_POST_HOOK=post-deploy
RD_VERB=deploy           # for a message: "refusing to $RD_VERB over a stack…"

fail() { printf 'remote-deploy: %s\n' "$*" >&2; exit 1; }
# Progress goes to stderr. Stdout carries nothing but `rd_report`'s `key=value`
# lines, which is the shape every other remote step kasbah runs already has
# (lib/build_push.sh's payload).
note() { printf 'remote-deploy: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: remote-deploy.sh deploy   <version> [--skip-hooks] [--no-health-wait]
                                           [--allow-stopped]
       remote-deploy.sh rollback <version> [--skip-hooks] [--no-health-wait]
                                           [--allow-stopped]

Runs from <apps>/<project>/scripts/.

deploy, in order: backup, pre-deploy hooks, retag <image>:current, docker
compose up -d --remove-orphans, health wait, post-deploy hooks, and one appended
entry in ../versions.log.

rollback is the same order with the backup dropped and the pre-/post-rollback
hooks in place of the deploy pair. It takes no backup, so its entry always
records no-backup.

Either way the entry is followed by the log's 3-month rotation: anything older
moves into ../versions.log.gz, and nothing is ever deleted.

  --skip-hooks       skip the pre- and post- hooks of whichever mode is running.
                     In deploy the backup still runs: a flag for a dry-run-ish
                     deploy must not also throw away the data safety net.
  --no-health-wait   bring the stack up without blocking on its health.
  --allow-stopped    run over a stack whose containers are not running. On a
                     first deploy that is the normal state and needs no flag;
                     on a project that has deployed before, each step whose own
                     container is down is skipped — a pre-deploy or pre-rollback
                     hook if it is that hook's container, and in deploy the
                     backup if it is backup.container — so it is refused unless
                     you say here that the stack is meant to be down. It is not
                     the answer for a container that does not exist at all: that
                     is the manifest and the compose file disagreeing, and the
                     refusal says so.
EOF
}

# Where this script is installed decides everything: the project directory is
# its parent, and the compose project name is that directory's name — which is
# manifest.name, because that is the directory kasbah deploys into.
_rd_locate() {
    local here
    here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
        || fail "could not resolve the directory this script is installed in"
    PROJECT_DIR="$(cd -P "$here/.." && pwd)" \
        || fail "could not resolve the project directory above $here"
    PROJECT="$(basename "$PROJECT_DIR")"
    [ -n "$PROJECT" ] || fail "the project directory has no name: $PROJECT_DIR"
}

# Every compose invocation carries -p. `name:` in the compose file is the
# weakest source of the project name: COMPOSE_PROJECT_NAME in this login shell
# outranks it, and `down` removes by project label rather than by the services
# the file lists (docs/phases/01-rig.md — nine unrelated containers were once in
# range of exactly this).
dc() { docker compose -p "$PROJECT" "$@"; }

# The line docs/build-deploy.md freezes:
#
#   <iso-timestamp> <action> <version> <backup-or-no-backup> kasbah=<v> digest=<…|->
#
# The four positional fields are frozen forever — never reordered, never
# removed. Anything new is a key=value pair appended after digest=.
#
# `kasbah=` is the version of the kasbah that drove the deploy, passed in the
# environment. A hand-run of this script says `unknown` rather than claiming a
# version it cannot know.
#
# Every value is checked for emptiness and whitespace before any of them is
# written, because the line is space-delimited and its shape is frozen: one
# empty field or one embedded space does not produce a slightly-wrong entry, it
# produces one that every later reader parses into the wrong columns — in a file
# that must stay readable by every kasbah version there will ever be. A `date`
# that fails is the case that motivates it, and it is caught here rather than by
# `set -e`: written the obvious way, as a substitution inside the printf's own
# argument list, the failure is invisible to errexit.
versions_log_line() {
    local action="$1" version="$2" backup="$3" digest="$4"
    local kasbah="${KASBAH_VERSION:-unknown}"
    local ts pair what value

    ts="$(date -u -Iseconds)" || ts=""

    # Checked in a loop rather than inside the printf's own substitutions: a
    # `fail` in a command substitution exits the subshell, and the field would
    # be written empty regardless.
    for pair in "timestamp=$ts" "action=$action" "version=$version" \
                "backup path=$backup" "kasbah version=$kasbah" "digest=$digest"; do
        what="${pair%%=*}"
        value="${pair#*=}"
        [ -n "$value" ] \
            || fail "refusing to write versions.log: the $what is empty, which would shift every field after it"
        case "$value" in
            *[[:space:]]*) fail "refusing to write versions.log: the $what ('$value') contains whitespace, which would shift every field after it" ;;
        esac
    done

    printf '%s %s %s %s kasbah=%s digest=%s\n' \
        "$ts" "$action" "$version" "$backup" "$kasbah" "$digest"
}

# Appended, never rewritten: the log is the record of what ran on this server,
# and it outlives every version in it. `rd_rotate_log` below is the only thing
# that rewrites the file, and it moves entries into versions.log.gz rather than
# dropping any.
log_version() {
    local line tail_byte
    # Both terminators are this function's, because the file is space- and
    # newline-delimited and its fields are frozen. `$(…)` strips the trailing
    # newline the line was built with, so it is put back below; and the *leading*
    # one is restored first when the file's last line has none — a `printf >>`
    # killed mid-append leaves exactly that, and appending to it fuses the two
    # entries into one line that still has six fields, so every later reader
    # accepts it with the interrupted record's remains inside the frozen
    # timestamp.
    # The `|| fail` is not decoration: versions_log_line's own refusals run in
    # this substitution's subshell, so its exit status is the only thing that
    # reaches here.
    line="$(versions_log_line "$@")" || fail "the versions.log entry was refused (see above)"
    [ -n "$line" ] || fail "refusing to append an empty line to $PROJECT_DIR/versions.log"

    # `$(…)` strips trailing newlines, so an empty answer here *is* "the last
    # byte is a newline". Nothing is rewritten: the truncated line keeps
    # whatever it holds and simply becomes a line of its own.
    if [ -s "$PROJECT_DIR/versions.log" ]; then
        tail_byte="$(tail -c 1 "$PROJECT_DIR/versions.log")" \
            || fail "could not read the end of $PROJECT_DIR/versions.log"
        if [ -n "$tail_byte" ]; then
            printf '\n' >> "$PROJECT_DIR/versions.log" \
                || fail "could not terminate the last line of $PROJECT_DIR/versions.log"
            note "the last line of versions.log had no newline on it — an append that was interrupted. Terminated it rather than writing into it; it is left exactly as it stands."
        fi
    fi

    printf '%s\n' "$line" >> "$PROJECT_DIR/versions.log" \
        || fail "could not append to $PROJECT_DIR/versions.log"
}

# The month a timestamp falls in, as `year * 12 + month`. An integer index is
# what makes `now - 3` cross a year boundary by arithmetic instead of by string
# surgery, and it keeps `date -d` — GNU-only, and outside this script's tool
# budget — out of the one calculation that would otherwise want it.
#
# Refused for anything whose leading text is not `YYYY-MM-`: a line rotation
# cannot read a month out of is not an entry it gets to judge.
_rd_month_index() {
    local ts="$1"
    case "$ts" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-*) ;;
        *) return 1 ;;
    esac
    printf '%s' "$(( 10#${ts:0:4} * 12 + 10#${ts:5:2} ))"
    return 0
}

# `YYYY-MM` for a month index, for a message.
_rd_month_name() {
    local idx="$1" y
    y=$(( (idx - 1) / 12 ))
    printf '%04d-%02d' "$y" "$(( idx - y * 12 ))"
    return 0
}

# The 3-month rotation docs/build-deploy.md specifies: entries from months
# strictly older than (this month − 3) leave the active log for versions.log.gz.
# Writing in August prunes April and earlier; writing in January 2027 prunes
# September 2026 and earlier.
#
# Two orderings are load-bearing. The gz is appended to *before* the active log
# is rewritten, so a crash between the two duplicates entries — visible and
# recoverable — where the other order would lose them; nothing is ever deleted.
# And a retained line is carried through byte for byte rather than re-rendered
# from its fields, because those four fields are frozen and a reader has to see
# exactly what was written. Every retained line comes back with one trailing
# newline, which also repairs a last line that had none.
#
# Three failure shapes, and the caller has to tell them apart, because what the
# operator is left holding differs in each. Nothing reached either file: exit 1.
# The append to the archive failed partway, so it may end in a truncated gzip
# member while the active log is still whole: exit 3. The archive took the
# entries and the rewrite of the active log then failed, so both files hold them
# — the duplication decision 4 accepts, but only because it is visible — and
# every later run re-appends them until someone trims the active log: exit 2.
# rd_rotate_log_or_warn says which happened.
rd_rotate_log() {
    local log="$PROJECT_DIR/versions.log"
    local gz="$PROJECT_DIR/versions.log.gz"
    local keep="$PROJECT_DIR/.versions.log.keep"
    local drop="$PROJECT_DIR/.versions.log.drop"
    local part="$PROJECT_DIR/.versions.log.part"
    local now cut line ts idx perm n=0 rc=0

    [ -s "$log" ] || return 0
    now="$(date -u +%Y-%m)" || return 1
    idx="$(_rd_month_index "$now-01")" || return 1
    cut=$(( idx - 3 ))

    : > "$keep" || return 1
    : > "$drop" || { rm -f "$keep"; return 1; }

    # `|| [ -n "$line" ]` for a last line with no newline on it, the same reason
    # rd_last_log_line has it — and here it is also what puts the newline back.
    while IFS= read -r line || [ -n "$line" ]; do
        ts="${line%%[[:space:]]*}"
        if idx="$(_rd_month_index "$ts")" && [ "$idx" -lt "$cut" ]; then
            printf '%s\n' "$line" >> "$drop" || rc=1
            n=$(( n + 1 ))
        else
            printf '%s\n' "$line" >> "$keep" || rc=1
        fi
        [ "$rc" -eq 0 ] || break
    done < "$log"

    if [ "$rc" -eq 0 ] && [ "$n" -gt 0 ]; then
        # Compressed off to one side first, so a gzip that failed never touches
        # the archive at all. Concatenated gzip streams are valid gzip and
        # `zcat` reads them in order, which is what lets the archive grow by
        # appending rather than by being rebuilt.
        gzip -c < "$drop" > "$part" || rc=1
        [ "$rc" -ne 0 ] || cat "$part" >> "$gz" || rc=3
        # `mv` replaces the inode, so the mode of the file kasbah has been
        # appending to since the first deploy is carried across rather than
        # taken from this run's umask. A log that quietly became 0600 on a host
        # with more than one administrator is a record only one of them can
        # read. An unreadable mode is not worth failing a rotation over.
        if [ "$rc" -eq 0 ]; then
            perm="$(stat -c %a "$log" 2>/dev/null)" || perm=""
            if mv -f "$keep" "$log"; then
                [ -z "$perm" ] || chmod "$perm" "$log" 2>/dev/null || true
            else
                rc=2
            fi
        fi
    fi
    rm -f "$keep" "$drop" "$part" 2>/dev/null || true

    [ "$rc" -eq 0 ] || return "$rc"
    [ "$n" -gt 0 ] || return 0
    note "versions.log: $n entries older than $(_rd_month_name "$cut") moved to versions.log.gz"
    return 0
}

# Called after log_version in both modes. A rotation that cannot run is a
# warning and never the run's exit status: rd_report is this script's completion
# marker, and the local side refuses to ship the Traefik fragment when the report
# is missing — so a failed log *compaction* would cost the project its route.
rd_rotate_log_or_warn() {
    local rc=0
    rd_rotate_log || rc=$?
    case "$rc" in
        0) ;;
        2) note "versions.log was rotated into versions.log.gz but could not then be rewritten, so the entries older than three months are now in BOTH files — and every later run will append them to versions.log.gz again until versions.log is trimmed by hand. The run itself is unaffected; nothing was lost." ;;
        3) note "versions.log could not be rotated: the append to versions.log.gz stopped partway, so the archive may end in an incomplete gzip member. versions.log is untouched and still holds every entry, so nothing was lost — repair or truncate versions.log.gz before reading it." ;;
        *) note "versions.log could not be rotated — the entry is written and both files are exactly as they were, only its 3-month compaction into versions.log.gz did not run" ;;
    esac
    return 0
}

# One exclusive lock, on a dedicated fd, held for the whole run. Flocking the
# project directory's own path is not portable, and a lock taken per step would
# still let two operators interleave one's retag with the other's `compose up`.
# The second run fails fast and names the file rather than waiting on it: a
# deploy that silently queues behind another looks like a hung deploy.
#
# Whether flock is here at all is asked first, before the lock file is opened, so
# a server without it leaves nothing behind either: `flock -n 9` on such a host
# exits 127, and reading that as a failed lock turns "this server is missing a
# prerequisite" into a statement about a concurrent operator who does not exist.
# `server init` probes for it, so on a server kasbah prepared this never fires.
rd_lock() {
    command -v flock >/dev/null 2>&1 \
        || fail "flock is not installed on this server — it is the only thing keeping two deploys of $PROJECT from interleaving their hooks and retags, so this script will not run without it. Install util-linux (docs/server-setup.md → prerequisites). Nothing was changed."
    exec 9>"$PROJECT_DIR/.deploy.lock" \
        || fail "could not open the lock file $PROJECT_DIR/.deploy.lock"
    flock -n 9 \
        || fail "another deploy or rollback is already running in $PROJECT_DIR — it holds the lock on $PROJECT_DIR/.deploy.lock"
    return 0
}

# Before anything but the lock file is touched. An image that never reached this
# server would leave `docker tag` failing after the backup had run and the
# pre-deploy hooks had touched live state — or, worse, leave :current where it
# was and let `compose up` report success while running the previous version
# under this version's name in versions.log.
rd_preflight() {
    local version="$1" img
    local missing=()

    for img in ${RD_IMAGES[@]+"${RD_IMAGES[@]}"}; do
        docker image inspect "$img:$version" >/dev/null 2>&1 || missing+=("$img:$version")
    done
    [ "${#missing[@]}" -eq 0 ] \
        || fail "not on this server: ${missing[*]} — run \`kasbah build-push\` for $version first. Nothing was changed."
    return 0
}

# The last non-empty line of versions.log, or nothing when the file is absent or
# holds none.
#
# `|| [ -n "$line" ]` so a final line with no newline is not dropped: a log some
# editor saved without one would otherwise report the second-to-last deploy as
# the previous version.
rd_last_log_line() {
    local line last=""
    [ -f "$PROJECT_DIR/versions.log" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        last="$line"
    done < "$PROJECT_DIR/versions.log"
    printf '%s' "$last"
    return 0
}

# Whether this project has ever deployed to this server. A different question
# from "which version", and deliberately answered from a different fact: *any*
# entry counts, whatever shape it is in.
#
# The two must not be conflated, because they disagree exactly where it is worst
# to be wrong. A `printf >>` killed mid-append leaves a last line that field 3
# cannot be read out of, so the version comes back empty — and a guard that
# turned on the version would read a project with real history as one that has
# never deployed here, skip the backup, and deploy over the stack. Fails open,
# in the state that most wants it closed.
rd_deployed_before() {
    local last
    last="$(rd_last_log_line)"
    [ -n "$last" ]
}

# The version the last versions.log entry recorded — field 3 of a line whose
# four positional fields are frozen. Empty on a first deploy, and empty too when
# that last line is malformed, which is why it is not what decides whether there
# is history. Used for the message and for the hooks' $PREV_VERSION, both of
# which an empty value is an honest answer for.
rd_prev_version() {
    local last ts action ver
    last="$(rd_last_log_line)"
    [ -n "$last" ] || return 0
    read -r ts action ver _ <<<"$last" || true
    printf '%s' "$ver"
    return 0
}

# True when the container exists and is running.
#
# The two steps that come before `compose up` — the backup and the pre-deploy
# hooks — act on the *outgoing* state (docs/project-manifest.md → hooks: "the
# pre-* hooks exec against containers from the outgoing state"). On a first
# deploy there is no outgoing state: no container of this project has ever run.
# Refusing there would make a first deploy impossible for every project that
# declares a hook or a backup, so those two steps are skipped and say so. A hook
# naming a container that does not exist *at all* is a different mistake, and it
# is caught on the workstation by `kasbah check`'s HK01 rather than here.
_rd_running() {
    local state
    state="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" || return 1
    [ "$state" = true ]
}

# What docker calls the container's state — `exited`, `created`, `paused`, or
# `absent` when there is no such container. Only ever used in a message: "it is
# not running" is not something an operator can act on, and `exited` is.
_rd_state() {
    local s
    s="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" || s=absent
    [ -n "$s" ] || s=absent
    printf '%s' "$s"
}

# One container's state as a clause. `absent` is the one state that is not a
# state of a container at all, and "demo-web is absent" invites an operator to
# start something that cannot start, so it gets its own wording.
_rd_state_clause() {
    local s
    s="$(_rd_state "$1")"
    if [ "$s" = absent ]; then printf '%s does not exist on this server' "$1"
    else printf '%s is %s' "$1" "$s"; fi
}

# Whether this container is the first token of some pre-deploy hook. The outgoing
# skips are per container — rd_backup checks backup.container, rd_run_hooks
# checks each hook's own — so the message that announces them has to be too.
_rd_is_pre_hook() {
    local hook
    [ "$RD_SKIP_HOOKS" != yes ] || return 1
    for hook in ${RD_HOOKS_PRE[@]+"${RD_HOOKS_PRE[@]}"}; do
        [ "${hook%%[[:space:]]*}" != "$1" ] || return 0
    done
    return 1
}

# Whether a backup is part of the run in flight. A rollback takes none at all —
# docs/build-deploy.md's rollback flow has no backup step — so backup.container
# is neither waited on nor named by anything in that mode.
_rd_backup_in_play() {
    [ "$RD_MODE" = deploy ] && [ -n "$RD_BACKUP_CHECK" ]
}

# The containers the outgoing phase needs: backup.container when a backup is
# declared, and every pre-* hook's container unless --skip-hooks. Printed one
# per line, deduplicated.
rd_outgoing_containers() {
    local hook c
    local seen=""

    if [ "$RD_SKIP_HOOKS" != yes ]; then
        for hook in ${RD_HOOKS_PRE[@]+"${RD_HOOKS_PRE[@]}"}; do
            c="${hook%%[[:space:]]*}"
            case "$seen" in *"|$c|"*) continue ;; esac
            seen="$seen|$c|"
            printf '%s\n' "$c"
        done
    fi
    if _rd_backup_in_play; then
        c="$RD_BACKUP_CONTAINER"
        case "$seen" in *"|$c|"*) return 0 ;; esac
        printf '%s\n' "$c"
    fi
    return 0
}

# Judged before the first side effect, and the discriminator is whether
# versions.log holds any entry at all — not the container list, which cannot tell
# the two cases apart, and not the version parsed out of it, which a truncated
# last line makes empty.
#
# `.State.Running` is false for a container that has never existed and for one
# that crashed ten minutes ago alike, so treating "not running" as "first
# deploy" skips the backup precisely when a backup is most wanted, and then
# deploys over the wreck. So: no versions.log entry means this project has never
# deployed here, and the outgoing steps are skipped because there is genuinely
# nothing to run them against. An entry means there was a stack, and one that is
# down is a refusal — `--allow-stopped` is how an operator says it is meant to
# be down.
rd_outgoing_preflight() {
    local prev="$1" raw c clause list="" absent="" hooks_down="" backup_down=no
    local skipped recorded names

    raw="$(rd_outgoing_containers)" || fail "could not work out which containers the $RD_PRE_HOOK steps need"
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        _rd_running "$c" && continue
        clause="$(_rd_state_clause "$c")"
        # Comma-joined rather than space-joined: two containers run together
        # into "demo-web is exited demo-db is exited", which reads as one
        # sentence about neither of them.
        if [ -z "$list" ]; then list="$clause"; else list="$list, $clause"; fi
        case "$clause" in
            *"does not exist on this server")
                if [ -z "$absent" ]; then absent="$clause"; else absent="$absent, $clause"; fi ;;
        esac
        if _rd_backup_in_play && [ "$c" = "$RD_BACKUP_CONTAINER" ]; then backup_down=yes; fi
        if _rd_is_pre_hook "$c"; then
            if [ -z "$hooks_down" ]; then hooks_down="$c"; else hooks_down="$hooks_down, $c"; fi
        fi
    done <<<"$raw"

    [ -n "$list" ] || return 0

    # What these particular containers being down actually costs. Naming "the
    # backup and the pre-deploy hooks" whenever anything is down announces a
    # skip that does not happen: with backup.container up and one hook's
    # container down, the backup runs, writes its file, and lands in
    # versions.log field 4 under a sentence that just said it was skipped.
    skipped=""
    [ "$backup_down" != yes ] || skipped="the backup"
    if [ -n "$hooks_down" ]; then
        [ -z "$skipped" ] || skipped="$skipped and "
        skipped="${skipped}the $RD_PRE_HOOK hooks in $hooks_down"
    fi
    [ -n "$skipped" ] || skipped="the outgoing steps that need them"

    if ! rd_deployed_before; then
        if [ "$RD_MODE" = deploy ]; then
            note "first deploy — versions.log has no entry for this project, and $list, so $skipped will not run"
        else
            note "versions.log has no entry for this project, and $list, so $skipped will not run"
        fi
        return 0
    fi
    if [ "$RD_ALLOW_STOPPED" = yes ]; then
        note "--allow-stopped: $list, so $skipped will not run"
        return 0
    fi
    # There is history either way; what the message can say about it depends on
    # whether the last line is one this version can read a version out of.
    if [ -n "$prev" ]; then
        recorded="versions.log records $prev"
    else
        recorded="versions.log has entries for it, though its last line is not one a version can be read out of"
    fi
    # A container docker has never heard of is not a stopped stack, and "start
    # it" is advice about something that cannot start. It is the manifest and
    # the compose file naming different containers — a rename that reached one
    # and not the other — and the only way past it, --allow-stopped, would then
    # skip that step silently on every deploy after this one, which is the exact
    # thing this preflight exists to stop.
    if [ -n "$absent" ]; then
        if [ "$RD_MODE" = deploy ]; then
            names="backup.container, or the first word of a pre-deploy hook"
        else
            names="the first word of a pre-rollback hook"
        fi
        note "$list, and this project has deployed here before ($recorded)"
        note "$absent — the manifest names it ($names) and this server's compose file defines no container_name: that matches"
        note "\`kasbah check\`'s HK01 catches that on the workstation, before any deploy"
        fail "make kasbah.yml and the compose file agree on the name. --allow-stopped would $RD_VERB past this, and would go on skipping $skipped silently on every $RD_MODE after it. Nothing was changed."
    fi
    fail "$list, and this project has deployed here before ($recorded) — refusing to $RD_VERB over a stack that cannot run $skipped. Start it, or pass --allow-stopped if it is meant to be down. Nothing was changed."
}

# Newest `retain` kept, oldest removed, and only once the new file is on disk: a
# rotation that ran first could delete the last good backup to make room for one
# that never arrived. The names sort chronologically because the timestamp in
# them is fixed-width and LC_ALL=C makes the glob sort by byte.
rd_backup_rotate() {
    local f n drop
    local files=()

    for f in "$PROJECT_DIR"/backups/pre-deploy-*."$RD_BACKUP_EXTENSION"; do
        [ -f "$f" ] || continue
        files+=("$f")
    done
    n="${#files[@]}"
    [ "$n" -gt "$RD_BACKUP_RETAIN" ] || return 0

    drop=$(( n - RD_BACKUP_RETAIN ))
    for f in "${files[@]:0:$drop}"; do
        rm -f "$f" || fail "could not remove the rotated-out backup $f"
        note "rotated out $f (backup.retain is $RD_BACKUP_RETAIN)"
    done
    return 0
}

# The first step of the deploy that changes anything, and deliberately so: it
# runs against the still-running previous version, so a backup always exists
# before any hook touches live state (docs/project-manifest.md → backup). What
# comes before it is the lock — which creates and truncates `.deploy.lock`, the
# one file a refused run leaves behind — the image preflight, and the
# outgoing-state preflight below. None of the three touches the project.
#
# `check` runs in this server's own shell with cwd at the project directory —
# not inside a container. Exit 0 takes the backup; anything else is the
# project's decision that this deploy does not need one, and the deploy carries
# on. `command` runs inside backup.container through `sh -c`, with no TTY for
# the same reason the hooks have none; `pipe` runs out here, on the VPS.
#
# Prints the path the log line and $DEPLOY_BACKUP carry: relative to the project
# directory, or the literal `no-backup`.
rd_backup() {
    local ts file tmp rc=0

    if [ -z "$RD_BACKUP_CHECK" ]; then
        printf 'no-backup'
        return 0
    fi
    # Reached only in the two cases rd_outgoing_preflight permits: a first
    # deploy, or --allow-stopped. Any other stopped container has already
    # failed the run.
    if ! _rd_running "$RD_BACKUP_CONTAINER"; then
        note "no $RD_BACKUP_CONTAINER is running, so there is nothing to back up"
        printf 'no-backup'
        return 0
    fi

    # The check's own stdout is a diagnostic, not this function's report.
    if ! ( cd "$PROJECT_DIR" && sh -c "$RD_BACKUP_CHECK" ) >&2; then
        note "backup.check exited non-zero — no backup taken, the deploy continues"
        printf 'no-backup'
        return 0
    fi

    ts="$(date -u +%Y%m%d-%H%M%S)" || ts=""
    [ -n "$ts" ] || fail "date failed, so the backup file cannot be named"
    file="backups/pre-deploy-$ts.$RD_BACKUP_EXTENSION"
    mkdir -p "$PROJECT_DIR/backups" || fail "could not create $PROJECT_DIR/backups"

    # Written under a name the rotation glob cannot match and renamed into
    # place, so a dump that died halfway never counts as a backup — for
    # rotation, for versions.log, or for the operator reading the directory.
    tmp="$PROJECT_DIR/$file.partial"
    if [ -n "$RD_BACKUP_PIPE" ]; then
        docker exec "$RD_BACKUP_CONTAINER" sh -c "$RD_BACKUP_COMMAND" \
            | sh -c "$RD_BACKUP_PIPE" > "$tmp" || rc=$?
    else
        docker exec "$RD_BACKUP_CONTAINER" sh -c "$RD_BACKUP_COMMAND" > "$tmp" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp" || true
        fail "the backup failed in $RD_BACKUP_CONTAINER (exit $rc) — nothing has been deployed"
    fi
    mv -f "$tmp" "$PROJECT_DIR/$file" || fail "could not write $PROJECT_DIR/$file"
    note "backup written to $file"

    rd_backup_rotate
    printf '%s' "$file"
    return 0
}

# No TTY, ever: a hook's output is read by a human through ssh and its exit
# status by this script, and a pty would put CRs through both. `docker exec`
# allocates one only when asked with `-t`, so the flag to get right here is the
# one that is *not* present. `-T` is `docker compose exec`'s spelling of the
# same intent and is not a `docker exec` flag at all — measured on docker
# 29.7.2: `unknown shorthand flag: 'T' in -T`, exit 125 — which is nonetheless
# how docs/project-manifest.md and docs/build-deploy.md both write it.
#
# The first whitespace-delimited token of a hook string is the container;
# everything after it is a shell command run by that container's own /bin/sh, so
# a pipeline, a redirection, a quoted argument and $VERSION all mean what they
# look like (docs/project-manifest.md → hooks). The three variables are the ones
# that file names.
rd_run_hooks() {
    local what="$1" phase="$2" version="$3" prev="$4" backup="$5"; shift 5
    local hook container rest

    for hook in "$@"; do
        container="${hook%%[[:space:]]*}"
        rest="${hook#"$container"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        [ -n "$container" ] || fail "a $what hook has no container name in it: '$hook'"
        [ -n "$rest" ] || fail "the $what hook '$hook' names a container and no command"

        # `outgoing` hooks may have nothing to run against; `incoming` ones run
        # after `compose up` and the health wait, so a container that is not
        # there is a real failure and is reported as one.
        if [ "$phase" = outgoing ] && ! _rd_running "$container"; then
            note "$what hook skipped: no $container is running"
            continue
        fi

        note "$what hook: $container: $rest"
        docker exec \
            -e "VERSION=$version" -e "PREV_VERSION=$prev" -e "DEPLOY_BACKUP=$backup" \
            "$container" sh -c "$rest" >&2 \
            || fail "the $what hook failed in $container: $rest"
    done
    return 0
}

# The cutover itself. :current is the tag every built service's compose entry
# resolves to, so moving it is what makes `compose up` below start the new
# image; build-push never moves it (docs/build-deploy.md → image tags on the
# VPS).
rd_retag() {
    local version="$1" img

    for img in ${RD_IMAGES[@]+"${RD_IMAGES[@]}"}; do
        # >&2 like every other command on this path: stdout is the report's,
        # and `docker tag` is the one call here that writes to it at all (it is
        # silent on success today, which is not a promise docker made).
        docker tag "$img:$version" "$img:current" >&2 \
            || fail "could not retag $img:$version as $img:current"
        note "retagged $img:$version as $img:current"
    done
    return 0
}

# The `digest=` field: each built image's content id, comma-joined in the order
# RD_IMAGES lists them — the compose file's service names, sorted, since that is
# what `yq … | keys` yields — or `-` for a stock-only project. Deterministic is
# what matters: two deploys of one release must write the same field.
#
# Read on this server, and only after the retag. `docker save`/`load` does not
# preserve image ids — measured across the two daemons in
# docs/phases/04-ship.md — so the id computed on the workstation describes a
# different store, and the one here is the only one that names what ran.
rd_digests() {
    local img id out=""

    for img in ${RD_IMAGES[@]+"${RD_IMAGES[@]}"}; do
        id="$(docker image inspect -f '{{.Id}}' "$img:current")" \
            || fail "could not read the image id of $img:current"
        [ -n "$id" ] || fail "docker reported no image id for $img:current"
        case "$id" in
            *[[:space:]]*) fail "the image id of $img:current contains whitespace ('$id'), which versions.log cannot carry" ;;
        esac
        if [ -z "$out" ]; then out="$id"; else out="$out,$id"; fi
    done
    [ -n "$out" ] || out=-
    printf '%s' "$out"
    return 0
}

# Docker's own healthcheck state for one container. `none` when the container
# declares no healthcheck: the unguarded `{{.State.Health.Status}}` template
# does not print an empty string for that case, it exits 1 with
# `map has no entry for key "Health"` (measured, docker 29.7.2), and an empty
# string is exactly what must never be read as "not healthy yet".
_rd_health_status() {
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null
}

# The readable name of a container, for a message. The no-health-block branch
# below yields container ids, and an id in a timeout message is not something an
# operator can act on.
_rd_name() {
    local n
    n="$(docker inspect -f '{{.Name}}' "$1" 2>/dev/null)" || n=""
    n="${n#/}"
    [ -n "$n" ] || n="$1"
    printf '%s' "$n"
}

# health.container when the manifest names one, else every container in this
# compose project — which is what "defaults to waiting on all services with a
# compose healthcheck" means once containers with no healthcheck pass
# immediately (docs/project-manifest.md → health).
rd_health_targets() {
    if [ -n "$RD_HEALTH_CONTAINER" ]; then
        printf '%s\n' "$RD_HEALTH_CONTAINER"
        return 0
    fi
    dc ps -q || fail "could not list the containers of compose project $PROJECT"
    return 0
}

# The one thing this script writes to stdout, and the last thing it does: five
# `key=value` lines naming what the run ended up doing. Everything else it says
# goes to stderr (see `note`), so the caller reads this without filtering.
#
# Three of the five are facts only this server has — whether this project had
# deployed here at all, the version the previous deploy recorded, and the image
# ids the daemon here computed after the retag. `kasbah deploy` needs the first
# two to print the changelog for the range it just shipped
# (docs/build-deploy.md step 10), and it needs them as *two*: an empty
# prev_version is what both a genuine first deploy and a project whose last
# versions.log line is a truncated write look like, and the two get different
# sentences. The shape here is not frozen the way versions.log's is — this
# report is read only by the kasbah that shipped the script printing it — so a
# new fact is an added key.
#
# Printed after the versions.log entry rather than anywhere earlier, which makes
# it an end-of-run marker as well as a report: a caller that gets an exit status
# of 0 and no report knows the run did not reach its end.
rd_report() {
    printf 'version=%s\nprev_version=%s\ndeployed_before=%s\nbackup=%s\ndigest=%s\n' \
        "$1" "$2" "$3" "$4" "$5"
    return 0
}

# Polled, with one deadline for the whole wait. A container with no healthcheck
# is an immediate pass and never an infinite wait; a container that never
# reaches `healthy` is a failure that names it and its last state, because
# "deploy timed out" without either is not something anybody can act on.
rd_health_wait() {
    local raw t deadline now status rc
    local targets=()

    raw="$(rd_health_targets)" || fail "could not work out which containers to wait on"
    while IFS= read -r t; do
        t="${t%$'\r'}"
        [ -n "$t" ] || continue
        targets+=("$t")
    done <<<"$raw"

    if [ "${#targets[@]}" -eq 0 ]; then
        note "health: compose project $PROJECT has no containers to wait on"
        return 0
    fi

    deadline=$(( $(date +%s) + RD_HEALTH_TIMEOUT ))
    for t in "${targets[@]}"; do
        while :; do
            rc=0
            status="$(_rd_health_status "$t")" || rc=$?
            [ "$rc" -eq 0 ] || status=missing
            case "$status" in
                none)
                    note "health: $(_rd_name "$t") declares no healthcheck — nothing to wait for"
                    break ;;
                healthy)
                    note "health: $(_rd_name "$t") is healthy"
                    break ;;
            esac
            now="$(date +%s)" || fail "date failed while waiting on $(_rd_name "$t")"
            if [ "$now" -ge "$deadline" ]; then
                fail "$(_rd_name "$t") did not become healthy within ${RD_HEALTH_TIMEOUT}s — its last state was '$status'"
            fi
            sleep 1
        done
    done
    return 0
}

# Both modes, because only three things separate them: a deploy takes a backup
# and a rollback never does (docs/build-deploy.md → rollback flow), RD_HOOKS_PRE
# and RD_HOOKS_POST already hold whichever pair the mode selected, and the
# action goes into versions.log field 2. Everything else — the lock, the two
# preflights, the retag, the up, the health wait, the entry, the rotation and
# the report — is one order run once.
do_run() {
    local mode="$1" version="$2"
    local backup prev digest deployed_before

    # A backstop for a hand-run, not the first thing that notices: `kasbah
    # deploy` judges the sync: list on the workstation, before the rsync and
    # before the .env is rendered, because a list with no compose.yml
    # destination is a fact about that checkout (lib/deploy.sh).
    [ -f "$PROJECT_DIR/compose.yml" ] \
        || fail "$PROJECT_DIR/compose.yml is missing — the project's sync: list must map its compose file to compose.yml"
    [ -f "$PROJECT_DIR/.env" ] \
        || fail "$PROJECT_DIR/.env is missing — compose reads the project's values from it"

    cd "$PROJECT_DIR" || fail "could not enter $PROJECT_DIR"

    rd_lock
    rd_preflight "$version"

    prev="$(rd_prev_version)" || fail "could not read $PROJECT_DIR/versions.log"
    # Read here, before the append at the end of this function makes it true of
    # every run. It is the other half of the question `prev` answers, and the
    # report carries both for the same reason this script keeps them apart: an
    # empty version is what a first deploy and a truncated last line both look
    # like, and only one of them is a first deploy.
    if rd_deployed_before; then deployed_before=yes; else deployed_before=no; fi
    rd_outgoing_preflight "$prev"

    if [ "$mode" = deploy ]; then
        # `|| fail` because rd_backup's own refusals run in this substitution's
        # subshell, so its exit status is the only thing that reaches here.
        backup="$(rd_backup)" || fail "the backup step failed (see above)"
        [ -n "$backup" ] || fail "internal: the backup step reported no path"
    else
        # A rollback restores an image and the files git already put back; the
        # data is untouched, and there is nothing here a backup would protect
        # that the deploy before it did not already.
        backup=no-backup
    fi

    if [ "$RD_SKIP_HOOKS" = yes ]; then
        note "$RD_PRE_HOOK hooks skipped (--skip-hooks)"
    else
        rd_run_hooks "$RD_PRE_HOOK" outgoing "$version" "$prev" "$backup" \
            ${RD_HOOKS_PRE[@]+"${RD_HOOKS_PRE[@]}"}
    fi

    rd_retag "$version"
    # Read before anything else can move a tag, and after the retag, which is
    # the moment :current describes what is about to run.
    digest="$(rd_digests)" || fail "could not read the image ids of what went live (see above)"

    # Compose's progress goes to stderr with the rest of the narration, because
    # stdout is rd_report's. Not because a stray `key=value` could overwrite a
    # fact — kasbah's absorber takes the last value for a key, and the report is
    # last — but because stdout here is an interface: it is read whole, by a
    # caller with no absorber or by a person piping it, and neither should have
    # to filter compose out of it.
    dc up -d --remove-orphans >&2 \
        || fail "docker compose -p $PROJECT up -d --remove-orphans failed in $PROJECT_DIR"

    if [ "$RD_NO_HEALTH_WAIT" = yes ]; then
        note "health wait skipped (--no-health-wait)"
    else
        rd_health_wait
    fi

    if [ "$RD_SKIP_HOOKS" = yes ]; then
        note "$RD_POST_HOOK hooks skipped (--skip-hooks)"
    else
        rd_run_hooks "$RD_POST_HOOK" incoming "$version" "$prev" "$backup" \
            ${RD_HOOKS_POST[@]+"${RD_HOOKS_POST[@]}"}
    fi

    log_version "$mode" "$version" "$backup" "$digest"
    rd_rotate_log_or_warn
    rd_report "$version" "$prev" "$deployed_before" "$backup" "$digest"
    return 0
}

main() {
    local action="${1:-}" version=""

    case "$action" in
        deploy|rollback) ;;
        -h|--help) usage; exit 0 ;;
        '') usage; fail "no action given (expected: deploy or rollback)" ;;
        *) usage; fail "unknown action '$action' (expected: deploy or rollback)" ;;
    esac
    shift

    version="${1:-}"
    [ -n "$version" ] || fail "$action needs a version (remote-deploy.sh $action <version>)"
    case "$version" in
        -*) fail "$action needs its version before any flag (remote-deploy.sh $action <version> [--skip-hooks] [--no-health-wait] [--allow-stopped])" ;;
        # The log is space-delimited and its fields are frozen, so a version
        # with a space in it would silently shift every field after it.
        *[[:space:]]*) fail "the version '$version' contains whitespace, which versions.log cannot carry" ;;
    esac
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --skip-hooks)     RD_SKIP_HOOKS=yes ;;
            --no-health-wait) RD_NO_HEALTH_WAIT=yes ;;
            --allow-stopped)  RD_ALLOW_STOPPED=yes ;;
            *) usage; fail "unknown argument '$1' (remote-deploy.sh $action <version> [--skip-hooks] [--no-health-wait] [--allow-stopped])" ;;
        esac
        shift
    done

    # The mode picks one of the manifest's two hook pairs and the words that go
    # with it, once. `docs/project-manifest.md` → hooks: the pre-* hooks exec
    # against the outgoing state and the post-* ones against the incoming, which
    # is the same order in both modes.
    RD_MODE="$action"
    if [ "$RD_MODE" = rollback ]; then
        RD_HOOKS_PRE=(${RD_HOOKS_PRE_ROLLBACK[@]+"${RD_HOOKS_PRE_ROLLBACK[@]}"})
        RD_HOOKS_POST=(${RD_HOOKS_POST_ROLLBACK[@]+"${RD_HOOKS_POST_ROLLBACK[@]}"})
        RD_PRE_HOOK=pre-rollback
        RD_POST_HOOK=post-rollback
        RD_VERB='roll back'
    else
        RD_HOOKS_PRE=(${RD_HOOKS_PRE_DEPLOY[@]+"${RD_HOOKS_PRE_DEPLOY[@]}"})
        RD_HOOKS_POST=(${RD_HOOKS_POST_DEPLOY[@]+"${RD_HOOKS_POST_DEPLOY[@]}"})
    fi

    _rd_locate
    do_run "$action" "$version"
}

main "$@"
