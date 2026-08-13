#!/usr/bin/env bash
# hosting — the VPS side of a deploy. Installed at
# <apps>/<project>/scripts/remote-deploy.sh and overwritten on every deploy, so
# it always matches the hosting that drives it (docs/build-deploy.md → helper
# scripts on the VPS). Do not edit it on the server; edit hosting's template.
#
#   remote-deploy.sh deploy <version>
#
# Today that is `compose up -d --remove-orphans` plus one versions.log line.
# Phase 4 adds the backup, the hooks, the health wait, the :current retag, the
# flock and the image digests — all inside this file, around the same two steps.
#
# Runnable by hand on the server for debugging: it takes no arguments beyond the
# two above and derives everything else from where it is installed.

set -euo pipefail

fail() { printf 'remote-deploy: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage: remote-deploy.sh deploy <version>

Runs from <apps>/<project>/scripts/. Brings the project's compose stack up and
appends an entry to ../versions.log.
EOF
}

# Where this script is installed decides everything: the project directory is
# its parent, and the compose project name is that directory's name — which is
# manifest.name, because that is the directory hosting deploys into.
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
#   <iso-timestamp> <action> <version> <backup-or-no-backup> hosting=<v> digest=<…|->
#
# The four positional fields are frozen forever — never reordered, never
# removed. Anything new is a key=value pair appended after digest=, which is
# where Phase 4's additions go.
#
# `hosting=` is the version of the hosting that drove the deploy, passed in the
# environment. A hand-run of this script says `unknown` rather than claiming a
# version it cannot know.
#
# Every value is checked for emptiness and whitespace before any of them is
# written, because the line is space-delimited and its shape is frozen: one
# empty field or one embedded space does not produce a slightly-wrong entry, it
# produces one that every later reader parses into the wrong columns — in a file
# that must stay readable by every hosting version there will ever be. A `date`
# that fails is the case that motivates it, and it is caught here rather than by
# `set -e`: written the obvious way, as a substitution inside the printf's own
# argument list, the failure is invisible to errexit.
versions_log_line() {
    local action="$1" version="$2" backup="$3" digest="$4"
    local hosting="${HOSTING_VERSION:-unknown}"
    local ts pair what value

    ts="$(date -u -Iseconds)" || ts=""

    # Checked in a loop rather than inside the printf's own substitutions: a
    # `fail` in a command substitution exits the subshell, and the field would
    # be written empty regardless.
    for pair in "timestamp=$ts" "action=$action" "version=$version" \
                "backup path=$backup" "hosting version=$hosting" "digest=$digest"; do
        what="${pair%%=*}"
        value="${pair#*=}"
        [ -n "$value" ] \
            || fail "refusing to write versions.log: the $what is empty, which would shift every field after it"
        case "$value" in
            *[[:space:]]*) fail "refusing to write versions.log: the $what ('$value') contains whitespace, which would shift every field after it" ;;
        esac
    done

    printf '%s %s %s %s hosting=%s digest=%s\n' \
        "$ts" "$action" "$version" "$backup" "$hosting" "$digest"
}

# Appended, never rewritten: the log is the record of what ran on this server,
# and it outlives every version in it. Rotation (docs/build-deploy.md) is Phase
# 4's, and appending is what it will rotate.
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

do_deploy() {
    local version="$1"
    # Stock-only today: nothing was built, so there is no image digest to
    # record, and no backup was taken. Both are literals rather than empty
    # fields — the log's four positional fields are frozen, and an empty one
    # would shift the rest for every reader (docs/build-deploy.md).
    local backup=no-backup digest=-

    [ -f "$PROJECT_DIR/compose.yml" ] \
        || fail "$PROJECT_DIR/compose.yml is missing — the project's sync: list must map its compose file to compose.yml"
    [ -f "$PROJECT_DIR/.env" ] \
        || fail "$PROJECT_DIR/.env is missing — compose reads the project's values from it"

    cd "$PROJECT_DIR" || fail "could not enter $PROJECT_DIR"
    dc up -d --remove-orphans \
        || fail "docker compose -p $PROJECT up -d --remove-orphans failed in $PROJECT_DIR"

    log_version deploy "$version" "$backup" "$digest"
}

main() {
    local action="${1:-}" version="${2:-}"

    case "$action" in
        deploy) ;;
        -h|--help) usage; exit 0 ;;
        '') usage; fail "no action given (expected: deploy)" ;;
        # rollback lands in Phase 5, in this same file. Named, so a hosting that
        # is ahead of the script on the server says so instead of "unknown".
        rollback) fail "rollback is not implemented in this version of remote-deploy.sh" ;;
        *) usage; fail "unknown action '$action' (expected: deploy)" ;;
    esac

    [ -n "$version" ] || fail "$action needs a version (remote-deploy.sh $action <version>)"
    # The log is space-delimited and its fields are frozen, so a version with a
    # space in it would silently shift every field after it.
    case "$version" in
        *[[:space:]]*) fail "the version '$version' contains whitespace, which versions.log cannot carry" ;;
    esac
    [ "$#" -le 2 ] || fail "too many arguments (remote-deploy.sh $action <version>)"

    _rd_locate
    do_deploy "$version"
}

main "$@"
