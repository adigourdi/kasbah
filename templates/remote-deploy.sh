#!/usr/bin/env bash
# kasbah — the VPS side of a deploy. Rendered from this template on every
# deploy and installed at <apps>/<project>/scripts/remote-deploy.sh, so it
# always matches both the kasbah that drives it and the manifest of the release
# it drives (docs/build-deploy.md → helper scripts on the VPS). Do not edit it
# on the server; edit this template, or the project's kasbah.yml.
#
#   remote-deploy.sh deploy <version> [--skip-hooks] [--no-health-wait]
#                                     [--allow-stopped]
#
# The order is fixed, and it is the one docs/build-deploy.md step 8 spells out:
# backup → pre-deploy hooks → retag :current → compose up -d --remove-orphans →
# health wait → post-deploy hooks → one appended versions.log line.
#
# Runnable by hand on the server, with nothing of kasbah's installed: everything
# the manifest says about this project is pre-rendered into the generated block
# below, so this script never parses YAML and the server needs no yq, jq or
# python3 (docs/phases/04-ship.md → Findings). It takes no arguments beyond the
# ones above and derives everything else from where it is installed.
#
# Tool budget, the same rule lib/env.sh's header states: coreutils and bash
# builtins, plus `docker` and `flock` (util-linux). No awk, no jq, no yq, no bc.

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
RD_HOOKS_PRE=( )         # each entry "<container> <shell command…>"
RD_HOOKS_POST=( )
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

fail() { printf 'remote-deploy: %s\n' "$*" >&2; exit 1; }
# Progress goes to stderr. Stdout is left clean for the step's own report to a
# caller that parses it, which is the shape every other remote step kasbah runs
# already has (lib/build_push.sh's payload).
note() { printf 'remote-deploy: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: remote-deploy.sh deploy <version> [--skip-hooks] [--no-health-wait]
                                        [--allow-stopped]

Runs from <apps>/<project>/scripts/. In order: backup, pre-deploy hooks, retag
<image>:current, docker compose up -d --remove-orphans, health wait, post-deploy
hooks, and one appended entry in ../versions.log.

  --skip-hooks       skip the pre- and post-deploy hooks. The backup still runs:
                     a flag for a dry-run-ish deploy must not also throw away
                     the data safety net.
  --no-health-wait   bring the stack up without blocking on its health.
  --allow-stopped    deploy over a stack whose containers are not running. On a
                     first deploy that is the normal state and needs no flag;
                     on a project that has deployed before it means the backup
                     and the pre-deploy hooks cannot run, so it is refused
                     unless you say here that the stack is meant to be down.
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
# and it outlives every version in it. Rotation (docs/build-deploy.md) belongs
# to Phase 5, which reopens this file for `rollback` anyway; appending is what
# it will rotate.
log_version() {
    local line
    # `$(…)` strips the trailing newline the line was built with, so it is put
    # back here rather than assumed: an entry that ran into the next one would
    # break every reader of the file at once.
    # The `|| fail` is not decoration: versions_log_line's own refusals run in
    # this substitution's subshell, so its exit status is the only thing that
    # reaches here.
    line="$(versions_log_line "$@")" || fail "the versions.log entry was refused (see above)"
    [ -n "$line" ] || fail "refusing to append an empty line to $PROJECT_DIR/versions.log"
    printf '%s\n' "$line" >> "$PROJECT_DIR/versions.log" \
        || fail "could not append to $PROJECT_DIR/versions.log"
}

# One exclusive lock, on a dedicated fd, held for the whole run. Flocking the
# project directory's own path is not portable, and a lock taken per step would
# still let two operators interleave one's retag with the other's `compose up`.
# The second run fails fast and names the file rather than waiting on it: a
# deploy that silently queues behind another looks like a hung deploy.
rd_lock() {
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

# The containers the outgoing phase needs: backup.container when a backup is
# declared, and every pre-deploy hook's container unless --skip-hooks. Printed
# one per line, deduplicated.
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
    if [ -n "$RD_BACKUP_CHECK" ]; then
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
    local prev="$1" raw c list="" recorded

    raw="$(rd_outgoing_containers)" || fail "could not work out which containers the pre-deploy steps need"
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        _rd_running "$c" && continue
        # Comma-joined rather than space-joined: two containers run together
        # into "demo-web is exited demo-db is exited", which reads as one
        # sentence about neither of them.
        if [ -z "$list" ]; then list="$c is $(_rd_state "$c")"
        else list="$list, $c is $(_rd_state "$c")"; fi
    done <<<"$raw"

    [ -n "$list" ] || return 0

    if ! rd_deployed_before; then
        note "first deploy — versions.log has no entry for this project, so there is no previous version to back up or run pre-deploy hooks against"
        return 0
    fi
    if [ "$RD_ALLOW_STOPPED" = yes ]; then
        note "--allow-stopped: $list, so the backup and the pre-deploy hooks are skipped"
        return 0
    fi
    # There is history either way; what the message can say about it depends on
    # whether the last line is one this version can read a version out of.
    if [ -n "$prev" ]; then
        recorded="versions.log records $prev"
    else
        recorded="versions.log has entries for it, though its last line is not one a version can be read out of"
    fi
    fail "$list, and this project has deployed here before ($recorded) — refusing to deploy over a stack that cannot run its backup or its pre-deploy hooks. Start it, or pass --allow-stopped if it is meant to be down. Nothing was changed."
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
        docker tag "$img:$version" "$img:current" \
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

do_deploy() {
    local version="$1"
    local backup prev digest

    [ -f "$PROJECT_DIR/compose.yml" ] \
        || fail "$PROJECT_DIR/compose.yml is missing — the project's sync: list must map its compose file to compose.yml"
    [ -f "$PROJECT_DIR/.env" ] \
        || fail "$PROJECT_DIR/.env is missing — compose reads the project's values from it"

    cd "$PROJECT_DIR" || fail "could not enter $PROJECT_DIR"

    rd_lock
    rd_preflight "$version"

    prev="$(rd_prev_version)" || fail "could not read $PROJECT_DIR/versions.log"
    rd_outgoing_preflight "$prev"

    # `|| fail` because rd_backup's own refusals run in this substitution's
    # subshell, so its exit status is the only thing that reaches here.
    backup="$(rd_backup)" || fail "the backup step failed (see above)"
    [ -n "$backup" ] || fail "internal: the backup step reported no path"

    if [ "$RD_SKIP_HOOKS" = yes ]; then
        note "pre-deploy hooks skipped (--skip-hooks)"
    else
        rd_run_hooks pre-deploy outgoing "$version" "$prev" "$backup" \
            ${RD_HOOKS_PRE[@]+"${RD_HOOKS_PRE[@]}"}
    fi

    rd_retag "$version"
    # Read before anything else can move a tag, and after the retag, which is
    # the moment :current describes what is about to run.
    digest="$(rd_digests)" || fail "could not read the image ids of what went live (see above)"

    dc up -d --remove-orphans \
        || fail "docker compose -p $PROJECT up -d --remove-orphans failed in $PROJECT_DIR"

    if [ "$RD_NO_HEALTH_WAIT" = yes ]; then
        note "health wait skipped (--no-health-wait)"
    else
        rd_health_wait
    fi

    if [ "$RD_SKIP_HOOKS" = yes ]; then
        note "post-deploy hooks skipped (--skip-hooks)"
    else
        rd_run_hooks post-deploy incoming "$version" "$prev" "$backup" \
            ${RD_HOOKS_POST[@]+"${RD_HOOKS_POST[@]}"}
    fi

    log_version deploy "$version" "$backup" "$digest"
    return 0
}

main() {
    local action="${1:-}" version=""

    case "$action" in
        deploy) ;;
        -h|--help) usage; exit 0 ;;
        '') usage; fail "no action given (expected: deploy)" ;;
        # rollback lands in Phase 5, in this same file. Named, so a kasbah that
        # is ahead of the script on the server says so instead of "unknown".
        rollback) fail "rollback is not implemented in this version of remote-deploy.sh" ;;
        *) usage; fail "unknown action '$action' (expected: deploy)" ;;
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

    _rd_locate
    do_deploy "$version"
}

main "$@"
