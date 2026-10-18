# The written-file set of a run, as a listing two runs can be diffed by — the
# parity check between two kasbah binaries, and the check of either against
# docs/files.md. Sourced by rig_env.sh, never executed.
#
# One line per entry, `path mode owner:group type` (find's %m and %y), sorted
# under LC_ALL=C. No times and no sizes, and every run-varying name is
# normalized (rig_files_normalize), so two runs of the same steps print the same.

[ -n "${_KASBAH_RIG_FILES_LOADED:-}" ] && return 0
_KASBAH_RIG_FILES_LOADED=1

RIG_SNAPSHOT_ROOTS=(/apps /etc/kasbah)

# Run-varying names in the path field, as the placeholders docs/files.md uses:
# backup and ACME-archive stamps, upgrade-traefik's backup directory, mktemp
# suffixes (XXXXXX), pid suffixes (`.tmp.<pid>`, `.kasbah-inject.<pid>`) and the
# build ids docker's buildx files its refs under.
rig_files_normalize() {
    sed -E \
        -e 's#^([^ ]*/backups/pre-deploy-)[0-9]{8}-[0-9]{6}#\1<stamp>#' \
        -e 's#^([^ ]*/acme\.json\.)[0-9]{8}T[0-9]{6}Z#\1<stamp>#' \
        -e 's#^([^ ]*/traefik/backups/)[^/ ]+#\1<stamp>#' \
        -e 's#^([^ ]*/(kasbah-[a-z-]+|tmp))\.[A-Za-z0-9]{6,10}([/ ])#\1.XXXXXX\3#' \
        -e 's#^([^ ]*\.)[0-9]{3,}( )#\1<pid>\2#' \
        -e 's#^([^ ]*/\.docker/buildx/refs/[^ ]*/)[a-z0-9]{25}( )#\1<ref>\2#'
}

# rig_files_snapshot [-r] [-x PATH]... [ROOT...] — every entry under the roots on
# the rig (default RIG_SNAPSHOT_ROOTS), read with sudo because parts are root- or
# container-owned. `-r` prints raw names, for rig_files_new. `-x PATH` lists PATH
# itself but nothing below it: the place for trees a container fills, which are
# the container's and not kasbah's. A root that does not exist contributes nothing.
rig_files_snapshot() {
    local prune=() roots=() cmd p norm=rig_files_normalize
    while [ $# -gt 0 ]; do
        case $1 in
            -r) norm=cat; shift ;;
            -x) prune+=("$2"); shift 2 ;;
            *)  roots+=("$1"); shift ;;
        esac
    done
    [ ${#roots[@]} -gt 0 ] || roots=("${RIG_SNAPSHOT_ROOTS[@]}")
    cmd='sudo find'
    for p in "${roots[@]}"; do
        printf -v cmd '%s %q' "$cmd" "$p"
    done
    if [ ${#prune[@]} -gt 0 ]; then
        cmd+=' \('
        for p in "${prune[@]}"; do
            printf -v cmd '%s -path %q -o' "$cmd" "$p"
        done
        cmd="${cmd% -o} \\) -prune -printf '%p %m %u:%g %y\\n' -o"
    fi
    cmd+=" -printf '%p %m %u:%g %y\\n' 2>/dev/null"
    local out rc=0
    out=$(rig_ssh "$cmd") || rc=$?
    # find's 1 is a missing root or an unreadable leaf, and the rest is still
    # listed; anything else (ssh's 255, timeout's 124) is a read that failed.
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return 1
    "$norm" <<<"${out//$'\r'/}" | LC_ALL=C sort
}

# rig_files_local [-r] ROOT [LABEL] — the workstation counterpart, for a project
# directory, a scratch HOME or TMPDIR. Paths are printed relative to ROOT under
# LABEL (default ROOT's basename), so two runs in different scratch directories
# diff clean. `.git` is the project's, never kasbah's, and skipped.
rig_files_local() {
    local norm=rig_files_normalize
    [ "${1:-}" != -r ] || { norm=cat; shift; }
    local root=${1%/} label=${2:-} out
    [ -n "$label" ] || label=$(basename "$root")
    [ -d "$root" ] || return 1
    out=$(cd "$root" && find . -path ./.git -prune -o -printf '%p %m %u:%g %y\n') || return 1
    sed "s|^\.|$label|" <<<"$out" | "$norm" | LC_ALL=C sort
}

# rig_files_new BEFORE AFTER — the lines of snapshot AFTER whose path is absent
# from snapshot BEFORE: what a run added under a root kasbah shares with others
# (the rig's /tmp, the deploy user's home, the project tree). Both must be raw
# (-r): normalized, a new /tmp/tmp.XXXXXX would hide behind an old one. The
# result is normalized.
rig_files_new() {
    awk 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' "$1" "$2" |
        rig_files_normalize | LC_ALL=C sort
}

# rig_docker_snapshot — the docker objects on the rig a diff should see:
# `network <name>`, `volume <name>`, `image <repo:tag>`, `project <name>`,
# sorted; anonymous volumes (64 hex digits) print as `volume <anonymous>`.
# Containers are compose's, and listed by the compose projects that own them.
rig_docker_snapshot() {
    local out
    out=$(rig_ssh "docker network ls --format 'network {{.Name}}' && \
                   docker volume ls --format 'volume {{.Name}}' && \
                   docker image ls --format 'image {{.Repository}}:{{.Tag}}' && \
                   docker compose ls --all -q | sed 's/^/project /'") || return 1
    sed -E 's/^volume [0-9a-f]{64}$/volume <anonymous>/' <<<"${out//$'\r'/}" | LC_ALL=C sort
}
