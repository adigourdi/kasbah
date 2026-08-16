# hosting — the server marker, read once per run
# Sourced by bin/hosting and lib/*.sh. Do not execute directly.

[ -n "${_HOSTING_MARKER_LOADED:-}" ] && return 0
_HOSTING_MARKER_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/ssh.sh"

# `/apps/.hosting/server.json` is the one path a *project* command can know
# without being told, and everything else about the server's layout comes out of
# it. Two commands read it the same way — `hosting deploy` and `hosting env` —
# so the read, the refusal and the validation live here rather than in both.
#
# (`hosting server status` keeps its own: it takes `--apps-path`, so it is
# looking for a marker somewhere the caller named, and its refusal says
# something different. Phase 4 gives deploy that flag, and this is where the two
# would meet.)

MARKER_JSON=""
MARKER_APPS_PATH=""
MARKER_DATA_PATH=""
MARKER_CPU_LIMIT=""
MARKER_MEM_LIMIT=""

# marker_read TARGET_LABEL — ssh_connect must already have run. Exits 4 when
# there is no marker, and the refusal neither prints nor implies a bare
# `hosting server init <target>`: run against a server whose apps path is not
# /apps, that command renders a second Traefik stack under /apps and brings it
# up as compose project `traefik` — the frozen name the live one already has —
# so compose recreates the running proxy against the new file, off the old
# dynamic/ and acme.json, and every site on the server goes dark. An operator
# following hosting's own instruction must not be able to do that.
marker_read() {
    local target="$1"
    local marker_path="$HOSTING_DEFAULT_APPS_PATH/.hosting/server.json"
    local out rc=0

    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    out=$(ssh_script "$HOSTING_DEFAULT_APPS_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
marker="$1/.hosting/server.json"

if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$marker" >&2
    exit 1
fi
[ -f "$marker" ] || exit 3
cat "$marker"
REMOTE
    ) || rc=$?

    case $rc in
        0) ;;
        3)
            err "$target has no server marker at $marker_path"
            err_cont "That file is what \`hosting server init\` writes last, and this command looks"
            err_cont "for it there and nowhere else. So this is one of two situations, and they"
            err_cont "have different answers:"
            err_cont "  * the server was prepared with --apps-path=<dir> somewhere other than"
            err_cont "    $HOSTING_DEFAULT_APPS_PATH. Deploying to it is not wired up yet — check with"
            err_cont "    \`ssh $target ls <dir>/.hosting/server.json\` before doing anything else."
            err_cont "  * the server has never been prepared, and initialising it is the answer."
            err_cont "Do not re-run init until you know which. Pointed at the wrong apps path it"
            err_cont "renders a second Traefik stack under the frozen 'traefik' compose project,"
            err_cont "which recreates the running proxy against it and takes every site down."
            exit "$HOSTING_EXIT_NO_REMOTE_STATE"
            ;;
        *) die "could not read $marker_path on $target (the remote step exited $rc, see above)" ;;
    esac

    MARKER_JSON="$out"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$MARKER_JSON" \
        || die "$marker_path on $target is not a JSON object — re-run \`hosting server init $target\`"

    MARKER_APPS_PATH="$(jq -r '.apps_path // "" | tostring' <<<"$MARKER_JSON")"
    MARKER_DATA_PATH="$(jq -r '.data_path // "" | tostring' <<<"$MARKER_JSON")"
    local path
    for path in "$MARKER_APPS_PATH" "$MARKER_DATA_PATH"; do
        case $path in
            /?*) ;;
            *) die "$marker_path on $target records apps_path='$MARKER_APPS_PATH' data_path='$MARKER_DATA_PATH'; both must be absolute paths — re-run \`hosting server init\`" ;;
        esac
    done

    # The resource limits the HOSTING_* managed block is written from
    # (docs/env-template.md). Refused rather than defaulted when absent: a
    # `cpus:` of nothing is not a compose file that comes up, and guessing a
    # limit for somebody's server is not hosting's call. They are written
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
                err "$marker_path on $target records cpu_limit='$MARKER_CPU_LIMIT' mem_limit='$MARKER_MEM_LIMIT'"
                err_cont "both are required and neither may carry whitespace: hosting writes them"
                err_cont "into every project's .env as HOSTING_CPU_LIMIT / HOSTING_MEM_LIMIT, and"
                err_cont "the compose files read cpus: and mem_limit: from there"
                err_cont "(docs/env-template.md). Re-run \`hosting server init\` to rewrite it."
                exit 1
                ;;
        esac
    done
    return 0
}
