#!/usr/bin/env bash
# Test: lib/remote_deploy.sh and templates/remote-deploy.sh — the VPS-side
# orchestrator, both halves of it.
#
# Hermetic, and unusually so for a remote step: what kasbah ships is a bash
# script, so this suite renders it and then *runs* it, against a project
# directory under a temp root with a recording `docker` stub first on PATH. The
# hook order, the hook environment, the backup gate, backup rotation, the health
# wait's three branches, the image preflight, the digest field and the
# versions.log line are therefore all pinned here rather than only on the rig.
#
# What it cannot see is the transport: nothing here proves the rendered file
# reaches a server or that the server's docker behaves like the stub. That is
# tests/integration/deploy_ship_test.sh's, and the two are meant to be read
# together (docs/phases/04-ship.md → Findings: a unit suite that stubs the
# transport cannot see the payload it hands over).
#
# The stub log is read both ways: a case asserts what was asked for, and the
# refusal cases assert the log is *empty past a point*, which is only evidence
# because other cases in the same run prove the stub is really being used.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
template="$repo_dir/templates/remote-deploy.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

if ! command -v yq >/dev/null || ! command -v flock >/dev/null; then
    echo "error: this suite needs yq (the render side) and flock (the shipped script)" >&2
    exit 2
fi

# --- The docker stub ---------------------------------------------------------------
#
# Answers from files under $STUB_STATE so a case sets up the daemon it wants:
#
#   images      "<ref>=<id>" per line — `image inspect` and `tag` read and write it
#   containers  one container name per line — what `exec` can reach, and what
#               `inspect {{.State.Running}}` answers `true` for
#   stopped     "<container>=<status>" per line — a container that exists and is
#               not running. Without it the daemon can only be asked to say
#               "running" or "no such object", and the whole crashed-stack
#               branch is unreachable from a test
#   starts      names appended to `containers` by `compose up`, so a case can be
#               a *first* deploy: nothing running until the stack comes up
#   health      "<container>=<status|none>" — the steady-state health answer
#   seq-<c>     one status per line, popped per poll, the last one sticking:
#               what makes "the wait actually polls" falsifiable
#   psq         container ids for `compose ps -q`
#
# `compose` without `-p` exits 2 rather than answering. Every compose call kasbah
# makes anywhere carries it (docs/phases/01-rig.md), and a suite that let one
# through would be asserting on a different project than the one under test.

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
DOCKER_LOG="$tmpdir/docker.log"

cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
{ printf 'docker'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$DOCKER_LOG"

images="$STUB_STATE/images"
health="$STUB_STATE/health"

lookup() {
    local line
    line="$(grep -m1 "^$2=" "$1" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

case "${1:-}" in
    image)
        [ "${2:-}" = inspect ] || { echo "docker stub: unhandled 'image $2'" >&2; exit 2; }
        shift 2
        fmt=""
        case "${1:-}" in
            -f|--format) fmt="$2"; shift 2 ;;
        esac
        rc=0
        for ref; do
            if id="$(lookup "$images" "$ref")"; then
                [ -z "$fmt" ] || printf '%s\n' "$id"
            else
                printf 'Error: No such image: %s\n' "$ref" >&2
                rc=1
            fi
        done
        exit "$rc"
        ;;
    tag)
        # Narrates on stdout. Today's `docker tag` is silent on success, so this
        # models a daemon rather than reports one — deliberately: the property
        # under test belongs to the script, not to docker. Every command on the
        # path to the report must be redirected, and a stub that says nothing
        # makes that guarantee unfalsifiable one command at a time.
        printf 'tagged %s as %s\n' "$2" "$3"
        if id="$(lookup "$images" "$2")"; then
            # A retag is a second name for one image: the id follows the source,
            # which is what makes the digest field readable after the retag.
            printf '%s=%s\n' "$3" "$id" >> "$images"
            exit 0
        fi
        printf 'Error response from daemon: No such image: %s\n' "$2" >&2
        exit 1
        ;;
    inspect)
        shift
        fmt=""
        case "${1:-}" in
            -f|--format) fmt="$2"; shift 2 ;;
        esac
        target="${1:-}"
        case "$fmt" in
            *Name*) printf '/%s\n' "$target"; exit 0 ;;
            *State.Running*)
                if grep -qxF "$target" "$STUB_STATE/containers" 2>/dev/null; then
                    printf 'true\n'; exit 0
                fi
                if lookup "$STUB_STATE/stopped" "$target" >/dev/null; then
                    printf 'false\n'; exit 0
                fi
                printf 'Error: No such object: %s\n' "$target" >&2
                exit 1 ;;
            *State.Status*)
                if grep -qxF "$target" "$STUB_STATE/containers" 2>/dev/null; then
                    printf 'running\n'; exit 0
                fi
                if st="$(lookup "$STUB_STATE/stopped" "$target")"; then
                    printf '%s\n' "$st"; exit 0
                fi
                printf 'Error: No such object: %s\n' "$target" >&2
                exit 1 ;;
        esac
        st=""
        seq="$STUB_STATE/seq-$target"
        if [ -f "$seq" ]; then
            st="$(head -n 1 "$seq")"
            if [ "$(wc -l < "$seq")" -gt 1 ]; then
                tail -n +2 "$seq" > "$seq.next" && mv "$seq.next" "$seq"
            fi
        elif ! st="$(lookup "$health" "$target")"; then
            printf 'Error: No such object: %s\n' "$target" >&2
            exit 1
        fi
        # The daemon is modelled, not the template: `none` in the state file
        # means the container declares no healthcheck, so `{{if .State.Health}}`
        # is false and what comes out is whatever the caller's `{{else}}…{{end}}`
        # branch holds — nothing at all when there is none. Answering a constant
        # here would make the two format strings indistinguishable, and telling
        # them apart is the whole question: an empty status must never read as
        # "not healthy yet" (docs/phases/04-ship.md).
        if [ "$st" = none ]; then
            case "$fmt" in
                *"{{else}}"*)
                    alt="${fmt#*\{\{else\}\}}"
                    printf '%s\n' "${alt%%\{\{end\}\}*}" ;;
                *) printf '\n' ;;
            esac
            exit 0
        fi
        printf '%s\n' "$st"
        exit 0
        ;;
    exec)
        shift
        envs=()
        while [ $# -gt 0 ]; do
            case "$1" in
                # A pty would put CRs through every hook's output and through the
                # backup stream. `docker exec` allocates one only on -t, so the
                # stub refuses to answer a call that asks for one — and `-T`,
                # which the docs write, is not a `docker exec` flag at all.
                -t|--tty|-T) echo "docker stub: exec asked for a TTY ($1)" >&2; exit 2 ;;
                -i|--interactive) shift ;;
                -e) envs+=("$2"); shift 2 ;;
                *) break ;;
            esac
        done
        container="${1:-}"; shift
        [ "${1:-}" = sh ] && [ "${2:-}" = -c ] \
            || { echo "docker stub: exec is not 'sh -c <command>': $*" >&2; exit 2; }
        grep -qxF "$container" "$STUB_STATE/containers" 2>/dev/null \
            || { printf 'Error: No such container: %s\n' "$container" >&2; exit 1; }
        env ${envs[@]+"${envs[@]}"} sh -c "$3"
        exit $?
        ;;
    compose)
        shift
        [ "${1:-}" = -p ] || { echo "docker stub: a compose call with no -p: $*" >&2; exit 2; }
        shift 2
        case "${1:-}" in
            ps) cat "$STUB_STATE/psq" 2>/dev/null; exit 0 ;;
            up)
                # `up` starts containers: a case that wants a first deploy leaves
                # `containers` empty and names in `starts` what comes up here.
                [ ! -f "$STUB_STATE/starts" ] || cat "$STUB_STATE/starts" >> "$STUB_STATE/containers"
                # And it narrates on *stdout*, which some compose versions do.
                # The script's stdout is a machine-readable report, so this is
                # what makes "compose's output must not land in it" falsifiable
                # rather than a defensive redirect nothing can test.
                printf 'Container demo-web  Started\n'
                exit "${DOCKER_UP_RC:-0}" ;;
        esac
        exit 0
        ;;
esac
echo "docker stub: unhandled '$*'" >&2
exit 2
STUB
chmod 0755 "$stub_dir/docker"

# --- Rendering: a driver that calls the library the way `kasbah deploy` does -------

cat > "$tmpdir/render" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
cd "$1" || exit 2
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/remote_deploy.sh"
manifest_require
remote_deploy_read_manifest "${3:-1.5.0}"
remote_deploy_render "$KASBAH_TEMPLATE" "$2"
DRV

render_err=""
render() {
    local dir="$1" out="$2" version="${3:-1.5.0}"
    env KASBAH_LIB_DIR="$repo_dir/lib" KASBAH_TEMPLATE_DIR="$repo_dir/templates" \
        KASBAH_TEMPLATE="$template" KASBAH_VERSION=0.1.0-test \
        bash "$tmpdir/render" "$dir" "$out" "$version" \
        >"$tmpdir/render.out" 2>"$tmpdir/render.err"
    local rc=$?
    render_err="$(cat "$tmpdir/render.err")"
    return "$rc"
}

# The generated block on its own, so a case asserts on what was rendered rather
# than on the template's own text around it.
block_of() {
    sed -n '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/p' "$1"
}

# A project directory with a manifest and a compose file, and nothing else the
# render needs.
make_render_project() {
    local dir="$1" manifest="$2" compose="$3"
    mkdir -p "$dir"
    printf '%s' "$manifest" > "$dir/kasbah.yml"
    printf '%s' "$compose" > "$dir/compose.prod.yml"
}

stock_compose='services:
  web:
    image: nginx:alpine
'
built_compose='services:
  web:
    build: .
    image: demo-web:current
  worker:
    build: .
    image: demo-worker:current
'

# --- Case R1: a manifest with all three blocks -------------------------------------
r1="$tmpdir/r1"
make_render_project "$r1" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 60s
hooks:
  pre-deploy:
    - demo-web echo pre >> /tmp/b
  post-deploy:
    - demo-web echo post >> /tmp/b
    - demo-worker echo post2 >> /tmp/b
backup:
  container: demo-db
  check: test -f ./compose.yml
  command: pg_dump -U u d
  extension: sql.gz
  pipe: gzip
  retain: 4
' "$built_compose"
render "$r1" "$tmpdir/r1.sh"; rc=$?
assert '[ "$rc" = "0" ]' "a manifest with hooks, backup and health renders (exit $rc: $render_err)"
r1b="$(block_of "$tmpdir/r1.sh")"
assert 'grep -qxF "RD_IMAGES=( '"'"'demo-web'"'"' '"'"'demo-worker'"'"' )" <<<"$r1b"' \
    "both built images are rendered, untagged, in sorted service order
        block: $r1b"
assert 'grep -qxF "RD_HOOKS_PRE=( '"'"'demo-web echo pre >> /tmp/b'"'"' )" <<<"$r1b"' \
    "the pre-deploy hook is rendered verbatim"
assert 'grep -qxF "RD_HOOKS_POST=( '"'"'demo-web echo post >> /tmp/b'"'"' '"'"'demo-worker echo post2 >> /tmp/b'"'"' )" <<<"$r1b"' \
    "and both post-deploy hooks, in manifest order"
assert 'grep -qxF "RD_HEALTH_CONTAINER='"'"'demo-web'"'"'" <<<"$r1b"'   "health.container is rendered"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'60'"'"'" <<<"$r1b"'           "health.timeout 60s is rendered as seconds"
assert 'grep -qxF "RD_BACKUP_CHECK='"'"'test -f ./compose.yml'"'"'" <<<"$r1b"' "backup.check is rendered"
assert 'grep -qxF "RD_BACKUP_CONTAINER='"'"'demo-db'"'"'" <<<"$r1b"'    "backup.container is rendered"
assert 'grep -qxF "RD_BACKUP_COMMAND='"'"'pg_dump -U u d'"'"'" <<<"$r1b"' "backup.command is rendered"
assert 'grep -qxF "RD_BACKUP_PIPE='"'"'gzip'"'"'" <<<"$r1b"'            "backup.pipe is rendered"
assert 'grep -qxF "RD_BACKUP_EXTENSION='"'"'sql.gz'"'"'" <<<"$r1b"'     "backup.extension is rendered"
assert 'grep -qxF "RD_BACKUP_RETAIN='"'"'4'"'"'" <<<"$r1b"'             "backup.retain is rendered"
assert 'grep -qF "Generated by kasbah 0.1.0-test" <<<"$r1b"' \
    "the block says which kasbah wrote it"
assert 'bash -n "$tmpdir/r1.sh"' "and the rendered script parses as bash"

# The template outside the block travels byte for byte: everything a reader
# debugging on the server relies on is kasbah's own file, not a re-emission.
tpl_outside="$(sed '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/d' "$template")"
r1_outside="$(sed '/^# >>> kasbah generated block/,/^# <<< kasbah generated block/d' "$tmpdir/r1.sh")"
assert '[ "$tpl_outside" = "$r1_outside" ]' \
    "the rest of the template is copied unchanged (only the block differs)"

# --- Case R2: a manifest with none of the three ------------------------------------
r2="$tmpdir/r2"
make_render_project "$r2" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' "$stock_compose"
render "$r2" "$tmpdir/r2.sh"; rc=$?
assert '[ "$rc" = "0" ]' "a stock manifest with no hooks, backup or health renders (exit $rc: $render_err)"
r2b="$(block_of "$tmpdir/r2.sh")"
assert 'grep -qxF "RD_IMAGES=( )" <<<"$r2b"'            "a stock-only project renders no images"
assert 'grep -qxF "RD_HOOKS_PRE=( )" <<<"$r2b"'         "no pre-deploy hooks"
assert 'grep -qxF "RD_HOOKS_POST=( )" <<<"$r2b"'        "no post-deploy hooks"
assert 'grep -qxF "RD_HEALTH_CONTAINER='"''"'" <<<"$r2b"' "no health.container — the wait falls back to the whole project"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'120'"'"'" <<<"$r2b"' "the default timeout is 120s"
assert 'grep -qxF "RD_BACKUP_CHECK='"''"'" <<<"$r2b"'   "an empty backup.check is what 'no backup:' renders to"
assert 'grep -qxF "RD_BACKUP_RETAIN='"'"'10'"'"'" <<<"$r2b"' "and retain defaults to 10"

# --- Case R3: values carrying spaces and quotes ------------------------------------
r3="$tmpdir/r3"
make_render_project "$r3" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-web sh -c \"echo '"'"'a  b'"'"' > /tmp/x\""
backup:
  container: demo-db
  check: "test -f \"./a b\""
  command: "echo \"it'"'"'s fine\""
  extension: txt
' "$stock_compose"
render "$r3" "$tmpdir/r3.sh"; rc=$?
assert '[ "$rc" = "0" ]' "a manifest whose values carry spaces and quotes renders (exit $rc: $render_err)"
assert 'bash -n "$tmpdir/r3.sh"' "and the result still parses as bash"
# Read the block back through bash and compare with what the manifest holds:
# an assertion on the rendered text alone would pass on a value that escaped
# into something else that happens to look right.
readback="$(bash -c '
    RD_HOOKS_PRE=(); RD_BACKUP_CHECK=; RD_BACKUP_COMMAND=
    '"$(block_of "$tmpdir/r3.sh")"'
    printf "hook=%s\n" "${RD_HOOKS_PRE[0]}"
    printf "check=%s\n" "$RD_BACKUP_CHECK"
    printf "command=%s\n" "$RD_BACKUP_COMMAND"
')"
assert '[ "$(sed -n "s/^hook=//p" <<<"$readback")" = "demo-web sh -c \"echo '"'"'a  b'"'"' > /tmp/x\"" ]' \
    "the hook survives quoting round-trip byte for byte (got '$(sed -n "s/^hook=//p" <<<"$readback")')"
assert '[ "$(sed -n "s/^check=//p" <<<"$readback")" = "test -f \"./a b\"" ]' \
    "and so does backup.check (got '$(sed -n "s/^check=//p" <<<"$readback")')"
assert '[ "$(sed -n "s/^command=//p" <<<"$readback")" = "echo \"it'"'"'s fine\"" ]' \
    "and a backup.command holding a single quote (got '$(sed -n "s/^command=//p" <<<"$readback")')"

# --- Case R4: the render is deterministic ------------------------------------------
render "$r1" "$tmpdir/r1-again.sh"
assert 'cmp -s "$tmpdir/r1.sh" "$tmpdir/r1-again.sh"' \
    "rendering the same project twice gives the same bytes"

# --- Case R5: an image name carrying a registry port -------------------------------
r5="$tmpdir/r5"
make_render_project "$r5" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' 'services:
  web:
    build: .
    image: reg.example:5000/demo-web:current
'
render "$r5" "$tmpdir/r5.sh"; rc=$?
assert '[ "$rc" = "0" ]' "a registry-with-a-port image renders (exit $rc: $render_err)"
assert 'grep -qxF "RD_IMAGES=( '"'"'reg.example:5000/demo-web'"'"' )" <<<"$(block_of "$tmpdir/r5.sh")"' \
    "with only the trailing tag stripped, not the registry port
        block: $(block_of "$tmpdir/r5.sh")"

# --- Cases R6–R10: manifests the render refuses ------------------------------------
refuse() {
    local name="$1" manifest="$2" compose="$3" needle="$4" what="$5"
    local dir="$tmpdir/$name"
    make_render_project "$dir" "$manifest" "$compose"
    render "$dir" "$tmpdir/$name.sh"; local rc=$?
    assert "[ \"$rc\" != \"0\" ]" "$what — the render refuses it (exit $rc)"
    assert "grep -qF -- \"$needle\" <<<\"\$render_err\"" \
        "$what — naming $needle (said '$render_err')"
    assert "[ ! -s \"$tmpdir/$name.sh\" ]" "$what — and writes no script"
}

refuse hooknocmd 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - demo-web
' "$stock_compose" 'names a container and no command' "a hook that is only a container name"

refuse badtimeout 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: soon
' "$stock_compose" 'is not a duration kasbah can use' "a health.timeout that is not a duration"

refuse noext 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: demo-db
  check: "true"
  command: echo hi
' "$stock_compose" 'backup: has no extension:' "a backup: block with no extension"

refuse retain0 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: demo-db
  check: "true"
  command: echo hi
  extension: txt
  retain: 0
' "$stock_compose" 'backup.retain is 0' "a backup.retain of zero"

refuse nobackupcontainer 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  check: "true"
  command: echo hi
  extension: txt
' "$stock_compose" 'backup: has no container:' "a backup: block naming no container"
# The refusal must not recommend a flag docker does not have: `-T` is
# `docker compose exec`'s, and `docker exec -T` exits 125.
assert '! grep -qF -- "exec -T" <<<"$render_err"' \
    "and does not tell the reader to run \`docker exec -T\` (said '$render_err')"

refuse extpath 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: demo-db
  check: "true"
  command: echo hi
  extension: ../outside
' "$stock_compose" 'must be a plain filename extension' \
  "a backup.extension that climbs out of backups/"

refuse timeout0 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 0s
' "$stock_compose" 'is zero' "a health.timeout of zero"

# F1: a hook that spans two lines. Split on newlines it becomes two hooks, the
# second of which names a container called `echo` — so half the command is
# discarded and the deploy still exits 0.
refuse multilinehook 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-web php artisan down &&\nphp artisan migrate"
' "$stock_compose" 'spans more than one line' "a hook value carrying a newline"

# The same thing written as a YAML block scalar, which is the shape a project
# author reaches for and which no amount of quoting makes one line.
refuse blockhook 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  post-deploy:
    - |
      demo-web php artisan migrate --force
      demo-web php artisan config:cache
' "$stock_compose" 'spans more than one line' "a hook written as a block scalar"

# F4: a value carrying the generated block's end marker would land at column 0
# inside the block. It still parses — every value is single-quoted — but it
# breaks every reader that takes the block as a range, this suite included.
refuse markerhook 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-web echo # <<< kasbah generated block <<<"
' "$stock_compose" 'generated-block markers' "a hook carrying the block end marker"

refuse markercheck 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: demo-db
  check: "echo # >>> kasbah generated block - rendered from kasbah.yml on every deploy, do not edit >>>"
  command: echo hi
  extension: txt
' "$stock_compose" 'generated-block markers' "a backup.check carrying the block begin marker"

# --- Case R12: a health: block with only a timeout is the all-services path ---------
# docs/project-manifest.md says health: defaults to waiting on every service with
# a compose healthcheck. Refusing a block with no container: made that default's
# timeout unreachable, even though the shipped script supports it exactly.
r12="$tmpdir/r12"
make_render_project "$r12" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  timeout: 5m
' "$stock_compose"
render "$r12" "$tmpdir/r12.sh"; rc=$?
assert '[ "$rc" = "0" ]' "a health: block with only a timeout renders (exit $rc: $render_err)"
r12b="$(block_of "$tmpdir/r12.sh")"
assert 'grep -qxF "RD_HEALTH_CONTAINER='"''"'" <<<"$r12b"' \
    "with no container, which is the all-services path
        block: $r12b"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'300'"'"'" <<<"$r12b"' \
    "and the block's own budget rather than the 120s default"

# --- Case R13: a health: block naming a container and no timeout ---------------------
# The default *inside* a present block, which is a different code path from the
# default when there is no block at all.
r13="$tmpdir/r13"
make_render_project "$r13" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
' "$stock_compose"
render "$r13" "$tmpdir/r13.sh"
r13b="$(block_of "$tmpdir/r13.sh")"
assert 'grep -qxF "RD_HEALTH_CONTAINER='"'"'demo-web'"'"'" <<<"$r13b"' \
    "a health: block with no timeout keeps its container
        block: $r13b"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'120'"'"'" <<<"$r13b"' \
    "and falls back to 120s"

# --- Case R14: a quoted scalar's surrounding whitespace is trimmed --------------------
# yq hands back exactly what the quotes hold, and an untrimmed value becomes a
# `sh -c "  true  "` on the server and a leading blank in the rendered block.
r14="$tmpdir/r14"
make_render_project "$r14" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: "  demo-db  "
  check: "  test -f ./x  "
  command: "  echo hi  "
  extension: "  txt  "
' "$stock_compose"
render "$r14" "$tmpdir/r14.sh"
r14b="$(block_of "$tmpdir/r14.sh")"
assert 'grep -qxF "RD_BACKUP_CHECK='"'"'test -f ./x'"'"'" <<<"$r14b"' \
    "a quoted backup.check is trimmed, inside the quotes as well as outside
        block: $r14b"
assert 'grep -qxF "RD_BACKUP_CONTAINER='"'"'demo-db'"'"'" <<<"$r14b"' \
    "and so is the container name, which is a docker argument"
assert 'grep -qxF "RD_BACKUP_EXTENSION='"'"'txt'"'"'" <<<"$r14b"' \
    "and the extension, which is part of a filename"

# health.timeout in minutes, which the same parser has to accept.
r11="$tmpdir/r11"
make_render_project "$r11" 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 2m
' "$stock_compose"
render "$r11" "$tmpdir/r11.sh"
assert 'grep -qxF "RD_HEALTH_TIMEOUT='"'"'120'"'"'" <<<"$(block_of "$tmpdir/r11.sh")"' \
    "health.timeout 2m renders as 120 seconds"

# ==================================================================================
# The shipped script, run
# ==================================================================================

# Every run gets its own project directory, its own stub state and its own log.
# `deploy` is invoked exactly as `kasbah deploy` invokes it: the script's own
# path, one action, one version, and KASBAH_VERSION in the environment.

run_out=""
run_err=""
STUB_STATE=""
proj=""

# setup_run <name> <manifest> <compose> — a project directory holding a rendered
# remote-deploy.sh, a compose.yml, a .env, and a stub daemon with nothing on it.
setup_run() {
    local name="$1" manifest="$2" compose="${3:-$stock_compose}"
    local root="$tmpdir/run-$name"

    rm -rf "$root"
    # The directory name *is* the compose project name — that is how the shipped
    # script derives it — so every case runs as `demo`, and the case name only
    # keeps the roots apart.
    proj="$root/demo"
    STUB_STATE="$root/state"
    mkdir -p "$proj/scripts" "$STUB_STATE"
    : > "$STUB_STATE/images"
    : > "$STUB_STATE/containers"
    : > "$STUB_STATE/health"
    : > "$STUB_STATE/psq"
    : > "$STUB_STATE/stopped"

    make_render_project "$root/src" "$manifest" "$compose"
    render "$root/src" "$proj/scripts/remote-deploy.sh" \
        || { echo "error: could not render the script for case $name: $render_err" >&2; exit 2; }
    chmod 0755 "$proj/scripts/remote-deploy.sh"

    printf 'services: {}\n' > "$proj/compose.yml"
    printf 'DEMO=1\n' > "$proj/.env"
    : > "$DOCKER_LOG"
}

deploy() {
    env PATH="$stub_dir:$PATH" STUB_STATE="$STUB_STATE" DOCKER_LOG="$DOCKER_LOG" \
        KASBAH_VERSION=0.1.0-test \
        "$proj/scripts/remote-deploy.sh" "$@" \
        >"$tmpdir/run.out" 2>"$tmpdir/run.err" </dev/null
    local rc=$?
    run_out="$(cat "$tmpdir/run.out")"
    run_err="$(cat "$tmpdir/run.err")"
    return "$rc"
}

log_line() { cat "$proj/versions.log" 2>/dev/null; }

# The manifest every execution case starts from: two built images, a hook at
# each end that leaves a breadcrumb naming the three variables it was given, a
# backup gated on a sentinel file, and a health container.
# A hook is project-authored shell and may print anything at all; the script
# redirects its output to stderr so stdout stays the report's. The pre-deploy
# hook here therefore writes a `key=value` line to **stdout** before it writes
# its breadcrumb — with the redirect gone, that line lands in the report and the
# four-line assertion in X1 fails. A fixture whose every hook tidily redirects
# its own output into a file cannot see that guard at all.
run_manifest() {
    local check="$1"
    printf 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 5s
hooks:
  pre-deploy:
    - "demo-web echo version=9.9.9-from-the-hook; echo \\"pre v=$VERSION prev=$PREV_VERSION backup=$DEPLOY_BACKUP\\" >> %s"
  post-deploy:
    - "demo-web echo \\"post v=$VERSION prev=$PREV_VERSION backup=$DEPLOY_BACKUP\\" >> %s"
backup:
  container: demo-db
  check: "%s"
  command: echo kasbah-backup-payload
  extension: txt.gz
  pipe: gzip
  retain: 3
' "$tmpdir/crumbs" "$tmpdir/crumbs" "$check"
}

# --- Case X1: the whole order, on the happy path ------------------------------------
: > "$tmpdir/crumbs"
# backup.check is project-authored too, and it runs in the server's own shell
# rather than in a container — so it is the second thing whose stdout has to be
# kept off the report. It prints a `key=value` line here for the same reason the
# hook above does.
setup_run x1 "$(run_manifest "printf 'backup-check\\n' >> $tmpdir/crumbs; echo backup=leaked-from-the-check")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "the happy path exits 0 (exit $rc)
        stderr: $run_err"

# Order, from one trace: the breadcrumbs the check and the two hooks wrote,
# interleaved with what the stub recorded. Read as a sequence of line numbers so
# a reordering fails rather than a "both happened" check passing.
crumbs="$(cat "$tmpdir/crumbs")"
assert '[ "$(sed -n 1p <<<"$crumbs")" = "backup-check" ]' \
    "backup.check runs first (crumbs: $(tr "\n" "/" <<<"$crumbs"))"
assert '[[ "$(sed -n 2p <<<"$crumbs")" == "pre v=1.5.0 prev= backup=backups/pre-deploy-"*.txt.gz ]]' \
    "then the pre-deploy hook, with VERSION set, PREV_VERSION empty on a first deploy, and the
        backup it can already name (got '$(sed -n 2p <<<"$crumbs")')"
assert '[[ "$(sed -n 3p <<<"$crumbs")" == "post v=1.5.0 prev= backup=backups/pre-deploy-"*.txt.gz ]]' \
    "and last the post-deploy hook, with the same three (got '$(sed -n 3p <<<"$crumbs")')"
assert '[ "$(wc -l <<<"$crumbs")" = "3" ]' \
    "and nothing else ran a hook (crumbs: $(tr "\n" "/" <<<"$crumbs"))"

# The docker calls, in order. grep -n gives the line numbers the comparison needs.
n_of() { local l; l="$(grep -n -m1 -- "$1" "$DOCKER_LOG")" || return 1; printf '%s' "${l%%:*}"; }
n_preflight="$(n_of 'docker|image|inspect|demo-web:1.5.0')"
n_backup="$(n_of 'docker|exec|demo-db|sh|-c|echo kasbah-backup-payload')"
n_prehook="$(n_of 'demo-web|sh|-c|echo version=9.9.9-from-the-hook')"
n_tag="$(n_of 'docker|tag|demo-web:1.5.0|demo-web:current')"
n_up="$(n_of 'docker|compose|-p|demo|up|-d|--remove-orphans')"
n_health="$(n_of 'docker|inspect|--format|{{if .State.Health}}')"
n_posthook="$(n_of 'demo-web|sh|-c|echo "post ')"
assert '[ -n "$n_preflight" ] && [ -n "$n_backup" ] && [ -n "$n_prehook" ] && [ -n "$n_tag" ] && [ -n "$n_up" ] && [ -n "$n_health" ] && [ -n "$n_posthook" ]' \
    "every step of the order shows up in the docker log
$(sed "s/^/        | /" "$DOCKER_LOG")"
assert '[ "$n_preflight" -lt "$n_backup" ] && [ "$n_backup" -lt "$n_prehook" ]' \
    "the preflight precedes the backup, and the backup precedes the pre-deploy hook ($n_preflight < $n_backup < $n_prehook)"
assert '[ "$n_prehook" -lt "$n_tag" ]' \
    "and the pre-deploy hook precedes the retag ($n_prehook < $n_tag)"
assert '[ "$n_tag" -lt "$n_up" ]' "the retag precedes compose up ($n_tag < $n_up)"
assert '[ "$n_up" -lt "$n_health" ]' "compose up precedes the health wait ($n_up < $n_health)"
assert '[ "$n_health" -lt "$n_posthook" ]' "the health wait precedes the post-deploy hook ($n_health < $n_posthook)"

# Both images retagged, each asserted on its own: one combined check would pass
# with either half missing.
assert 'grep -qxF "docker|tag|demo-web:1.5.0|demo-web:current" "$DOCKER_LOG"' \
    "demo-web:1.5.0 is retagged :current"
assert 'grep -qxF "docker|tag|demo-worker:1.5.0|demo-worker:current" "$DOCKER_LOG"' \
    "and demo-worker:1.5.0 too"

# The backup file, by its contents rather than its existence.
backup_file="$(find "$proj/backups" -name 'pre-deploy-*.txt.gz' 2>/dev/null | head -1)"
assert '[ -n "$backup_file" ]' "a backup file was written (found '$backup_file')"
assert '[ "$(gzip -dc "$backup_file" 2>/dev/null)" = "kasbah-backup-payload" ]' \
    "carrying the payload, through the pipe the manifest named (got '$(gzip -dc "$backup_file" 2>/dev/null)')"
assert '[ -z "$(find "$proj/backups" -name "*.partial" 2>/dev/null)" ]' \
    "and nothing half-written is left beside it"

# The versions.log line: all four frozen fields, plus kasbah= and digest=.
line="$(log_line)"
assert '[ "$(wc -l <<<"$line")" = "1" ]' "one line was appended to versions.log (got: $line)"
assert '[[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2}\ deploy\ 1\.5\.0\ backups/pre-deploy-[0-9]{8}-[0-9]{6}\.txt\.gz\ kasbah=0\.1\.0-test\ digest=sha256:aaa,sha256:bbb$ ]]' \
    "in the frozen shape, with the backup path, this kasbah's version and both digests comma-joined
        line: $line"

# The report on stdout, which is the whole of what this script writes there. The
# caller parses it unfiltered and treats a missing key as "the run did not reach
# its end" (lib/deploy.sh → _deploy_remote_deploy), so a `note` that drifted to
# stdout and a key that stopped being emitted are both protocol breaks.
assert '[ "$(grep -c . <<<"$run_out")" = "5" ]' \
    "the report is five lines and nothing else is on stdout (stdout: $(tr "\n" "/" <<<"$run_out"))"
# The control for that count. Both fixtures deliberately print a `key=value`
# line to stdout — one from inside a container, one from the server's own shell
# — and both must come out here instead. Without this, a hook that printed
# nothing at all would satisfy the count just as well.
assert 'grep -qF "version=9.9.9-from-the-hook" <<<"$run_err"' \
    "the pre-deploy hook's own stdout was redirected to stderr (stderr: $run_err)"
assert 'grep -qF "backup=leaked-from-the-check" <<<"$run_err"' \
    "and so was backup.check's (stderr: $run_err)"
assert 'grep -qxF "version=1.5.0" <<<"$run_out"' \
    "naming the version that ran (stdout: $(tr "\n" "/" <<<"$run_out"))"
assert 'grep -qxF "prev_version=" <<<"$run_out"' \
    "with prev_version present and empty on a first deploy rather than omitted — the two
        are the same thing to a reader that only checks for the key"
assert 'grep -qxF "deployed_before=no" <<<"$run_out"' \
    "and the other half of that question answered separately: an empty prev_version is
        also what a truncated last line produces, and only one of the two is a first
        deploy (stdout: $(tr "\n" "/" <<<"$run_out"))"
assert 'grep -qxE "backup=backups/pre-deploy-[0-9]{8}-[0-9]{6}\.txt\.gz" <<<"$run_out"' \
    "the backup path it wrote (stdout: $(tr "\n" "/" <<<"$run_out"))"
assert 'grep -qxF "digest=sha256:aaa,sha256:bbb" <<<"$run_out"' \
    "and the digests it recorded (stdout: $(tr "\n" "/" <<<"$run_out"))"
# Against the log rather than against a constant: the report and versions.log
# describe one deploy, and a report computed a second time could disagree.
read -r _ _ _ log_backup _ log_digest <<<"$line"
assert '[ "backup=$log_backup" = "$(grep -m1 "^backup=" <<<"$run_out")" ]' \
    "the backup path the report gives is the one the log line carries (log '$log_backup')"
assert '[ "$log_digest" = "$(grep -m1 "^digest=" <<<"$run_out")" ]' \
    "and so is the digest field (log '$log_digest')"

# The timestamp field is frozen, and `date -u -Iseconds` is what keeps it UTC:
# a VPS in Asia/Tokyo writing +09:00 into a space-delimited field every future
# kasbah has to parse is a contract break that no rig in Etc/UTC can show.
: > "$tmpdir/crumbs"
setup_run x1tz "$(run_manifest "true")" "$stock_compose"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
printf 'x 1.0.0 x x x\n' > "$proj/versions.log"
env TZ=Asia/Tokyo PATH="$stub_dir:$PATH" STUB_STATE="$STUB_STATE" DOCKER_LOG="$DOCKER_LOG" \
    KASBAH_VERSION=0.1.0-test "$proj/scripts/remote-deploy.sh" deploy 1.5.0 \
    >/dev/null 2>&1 </dev/null; rc=$?
tz_line="$(sed -n 2p "$proj/versions.log")"
assert '[ "$rc" = "0" ]' "a deploy on a server nine hours from UTC succeeds (exit $rc)"
assert '[[ "$tz_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00\  ]]' \
    "and still writes +00:00 — the frozen timestamp field is UTC, not the server's zone
        line: $tz_line"
tz_backup="$(find "$proj/backups" -name "pre-deploy-*.txt.gz" -printf "%f\n" 2>/dev/null | head -1)"
assert '[ -n "$tz_backup" ]' "with a backup written under TZ (found '$tz_backup')"

# --- Case X2: the backup gate says no ------------------------------------------------
: > "$tmpdir/crumbs"
setup_run x2 "$(run_manifest "printf 'backup-check\\n' >> $tmpdir/crumbs; exit 1")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a backup.check that exits 1 does not fail the deploy (exit $rc)
        stderr: $run_err"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' \
    "and no backup file is written (found: $(find "$proj/backups" -type f 2>/dev/null | tr "\n" " "))"
assert '[[ "$(log_line)" == *" 1.5.0 no-backup kasbah="* ]]' \
    "versions.log records no-backup in the frozen third field (line: $(log_line))"
assert 'grep -qF "backup=no-backup" "$tmpdir/crumbs"' \
    "and the hooks are told so through \$DEPLOY_BACKUP (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"
assert 'grep -qxF "docker|tag|demo-web:1.5.0|demo-web:current" "$DOCKER_LOG"' \
    "the deploy itself went ahead — the images were still retagged"

# --- Case X3: PREV_VERSION comes out of versions.log ----------------------------------
: > "$tmpdir/crumbs"
printf 'demo-web:1.6.0=sha256:ccc\ndemo-worker:1.6.0=sha256:ddd\n' >> "$STUB_STATE/images"
deploy deploy 1.6.0; rc=$?
assert '[ "$rc" = "0" ]' "a second deploy over the first exits 0 (exit $rc)
        stderr: $run_err"
assert 'grep -qF "pre v=1.6.0 prev=1.5.0 " "$tmpdir/crumbs"' \
    "and its hooks are handed the version the last versions.log entry recorded
        crumbs: $(tr "\n" "/" < "$tmpdir/crumbs")"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' \
    "versions.log is appended to, never rewritten ($(wc -l < "$proj/versions.log") lines)"
# The one fact in the report that no caller can compute for itself: what this
# server was running before. A report echoing the version it was asked for would
# be indistinguishable here if the two were ever the same.
assert 'grep -qxF "prev_version=1.5.0" <<<"$run_out"' \
    "and the report carries that previous version, not the one being deployed
        stdout: $(tr "\n" "/" <<<"$run_out")"
assert 'grep -qxF "version=1.6.0" <<<"$run_out"' "which is a different field (stdout: $(tr "\n" "/" <<<"$run_out"))"

# --- Case X4: the image preflight, before any side effect -----------------------------
: > "$tmpdir/crumbs"
setup_run x4 "$(run_manifest "printf 'backup-check\\n' >> $tmpdir/crumbs")" "$built_compose"
# Only one of the two images arrived.
printf 'demo-web:1.5.0=sha256:aaa\n' > "$STUB_STATE/images"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a missing image refuses the deploy (exit $rc)"
assert 'grep -qF "demo-worker:1.5.0" <<<"$run_err"' \
    "naming the image that is not there (said '$run_err')"
assert 'grep -qF "kasbah build-push" <<<"$run_err"' \
    "and the command that puts it there (said '$run_err')"
assert '[ ! -s "$tmpdir/crumbs" ]' \
    "the backup check never ran (crumbs: $(cat "$tmpdir/crumbs"))"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' "no backup was taken"
assert '! grep -q "^docker|tag|" "$DOCKER_LOG"' "nothing was retagged"
assert '! grep -q "^docker|compose|-p|demo|up" "$DOCKER_LOG"' "and nothing was brought up"
assert '[ ! -e "$proj/versions.log" ]' "and versions.log records nothing"
# The report is the last thing a completed run writes, which is what lets the
# caller read "exit 0 and no report" as "this did not finish". A refused run must
# therefore print none of it.
assert '[ -z "$run_out" ]' "and nothing at all reached stdout (stdout: '$run_out')"

# --- Case X5: the health wait's three branches ----------------------------------------
# (a) no health: block — every container in the compose project, and one of them
#     has no healthcheck at all, which must pass immediately rather than hang.
setup_run x5a 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' "$stock_compose"
printf 'web-c\nworker-c\n' > "$STUB_STATE/psq"
printf 'web-c=healthy\nworker-c=none\n' > "$STUB_STATE/health"
started=$(date +%s)
deploy deploy 1.5.0; rc=$?
elapsed=$(( $(date +%s) - started ))
assert '[ "$rc" = "0" ]' "with no health: block the deploy waits on the compose project (exit $rc)
        stderr: $run_err"
assert 'grep -qxF "docker|compose|-p|demo|ps|-q" "$DOCKER_LOG"' \
    "asking compose which containers those are, with -p"
assert 'grep -qF "worker-c declares no healthcheck" <<<"$run_err"' \
    "a container with no healthcheck is an immediate pass (said '$run_err')"
assert '[ "$elapsed" -lt 5 ]' "and not a wait (took ${elapsed}s)"
assert '[[ "$(log_line)" == *" digest=-"* ]]' \
    "a stock-only project records digest=- (line: $(log_line))"
assert '! grep -q "^docker|tag|" "$DOCKER_LOG"' "and retags nothing"

# (b) the named container comes up healthy only after a few polls.
setup_run x5b 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 30s
' "$stock_compose"
printf 'starting\nstarting\nhealthy\n' > "$STUB_STATE/seq-demo-web"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a container that goes healthy on the third poll passes (exit $rc)
        stderr: $run_err"
assert '[ "$(grep -c "docker|inspect|--format|{{if .State.Health}}" "$DOCKER_LOG")" = "3" ]' \
    "and it really polled — three inspects, not one ($(grep -c "docker|inspect|--format" "$DOCKER_LOG"))"
assert 'grep -qF "demo-web is healthy" <<<"$run_err"' "saying so (said '$run_err')"

# (c) it never does.
setup_run x5c 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 2s
' "$stock_compose"
printf 'demo-web=unhealthy\n' > "$STUB_STATE/health"
started=$(date +%s)
deploy deploy 1.5.0; rc=$?
elapsed=$(( $(date +%s) - started ))
assert '[ "$rc" != "0" ]' "a container that never becomes healthy fails the deploy (exit $rc)"
assert 'grep -qF "demo-web did not become healthy within 2s" <<<"$run_err"' \
    "naming the container and the budget it had (said '$run_err')"
assert 'grep -qF "unhealthy" <<<"$run_err"' "and its last state (said '$run_err')"
assert '[ "$elapsed" -lt 20 ]' "bounded by health.timeout, not by patience (took ${elapsed}s)"
assert '[ ! -e "$proj/versions.log" ]' "and nothing is written to versions.log"

# (d) the container the manifest names is not there at all — a different answer
#     from `none`, and it must not pass.
setup_run x5d 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
health:
  container: demo-web
  timeout: 2s
' "$stock_compose"
: > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a health.container docker has never heard of fails the deploy (exit $rc)"
assert 'grep -qF "demo-web did not become healthy within 2s" <<<"$run_err"' \
    "naming it (said '$run_err')"
assert 'grep -qF "last state was '"'"'missing'"'"'" <<<"$run_err"' \
    "and saying it was missing rather than reporting an empty state (said '$run_err')"

# --- Case X6: --skip-hooks skips the hooks and keeps the backup -------------------------
: > "$tmpdir/crumbs"
setup_run x6 "$(run_manifest "printf 'backup-check\\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0 --skip-hooks; rc=$?
assert '[ "$rc" = "0" ]' "--skip-hooks deploys (exit $rc)
        stderr: $run_err"
assert '! grep -q "echo \"pre " "$DOCKER_LOG"' "the pre-deploy hook did not run"
assert '! grep -q "echo \"post " "$DOCKER_LOG"' "nor the post-deploy hook"
assert '[ "$(cat "$tmpdir/crumbs")" = "backup-check" ]' \
    "but the backup check did — a dry-run-ish flag must not throw away the safety net
        crumbs: $(tr "\n" "/" < "$tmpdir/crumbs")"
assert '[ "$(find "$proj/backups" -name "pre-deploy-*.txt.gz" | wc -l)" = "1" ]' \
    "and the backup itself was written"
assert '[[ "$(log_line)" == *"backups/pre-deploy-"* ]]' \
    "and named in versions.log (line: $(log_line))"

# --- Case X7: --no-health-wait -----------------------------------------------------------
: > "$tmpdir/crumbs"
setup_run x7 "$(run_manifest "printf 'backup-check\\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
# Deliberately never healthy: without the flag this case would time out.
printf 'demo-web=starting\n' > "$STUB_STATE/health"
deploy deploy 1.5.0 --no-health-wait; rc=$?
assert '[ "$rc" = "0" ]' "--no-health-wait deploys past a container that is not healthy (exit $rc)
        stderr: $run_err"
assert '! grep -q "docker|inspect|--format|{{if .State.Health}}" "$DOCKER_LOG"' \
    "asking docker for no health state at all"
assert 'grep -qF "post v=1.5.0" "$tmpdir/crumbs"' \
    "while the post-deploy hook still runs (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"

# --- Case X8: two concurrent runs, one lock ----------------------------------------------
: > "$tmpdir/crumbs"
# A pre-deploy hook that sleeps: the first run is still inside it when the second
# starts, which is a property of this fixture rather than a race against the clock.
setup_run x8 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-web sleep 3"
' "$stock_compose"
printf 'demo-web\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
( env PATH="$stub_dir:$PATH" STUB_STATE="$STUB_STATE" DOCKER_LOG="$DOCKER_LOG" \
      KASBAH_VERSION=0.1.0-test "$proj/scripts/remote-deploy.sh" deploy 1.5.0 \
      >"$tmpdir/x8-first.out" 2>"$tmpdir/x8-first.err" </dev/null; echo $? > "$tmpdir/x8-first.rc" ) &
first_pid=$!
# Long enough to be inside the sleeping hook, short enough to be well before it ends.
sleep 1
started=$(date +%s%3N)
deploy deploy 1.5.0; second_rc=$?
second_ms=$(( $(date +%s%3N) - started ))
wait "$first_pid"
first_rc="$(cat "$tmpdir/x8-first.rc")"

assert '[ "$second_rc" != "0" ]' "the second concurrent deploy fails (exit $second_rc)"
assert 'grep -qF ".deploy.lock" <<<"$run_err"' \
    "naming the lock it could not take (said '$run_err')"
assert 'grep -qF "already running" <<<"$run_err"' \
    "and why (said '$run_err')"
assert '[ "$second_ms" -lt 2000 ]' \
    "fast, rather than queued behind the first (took ${second_ms}ms)"
assert '[ "$first_rc" = "0" ]' \
    "while the first run finishes untouched (exit $first_rc)
        stderr: $(cat "$tmpdir/x8-first.err")"
assert '[ "$(wc -l < "$proj/versions.log")" = "1" ]' \
    "and exactly one of them wrote a versions.log entry ($(wc -l < "$proj/versions.log"))"

# --- Case X9: backup rotation ---------------------------------------------------------
: > "$tmpdir/crumbs"
setup_run x9 "$(run_manifest "true")" "$stock_compose"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
mkdir -p "$proj/backups"
# retain is 3 in run_manifest, so three older ones plus the new one is one too many.
for stamp in 20200101-000000 20200102-000000 20200103-000000; do
    printf 'old %s\n' "$stamp" > "$proj/backups/pre-deploy-$stamp.txt.gz"
done
# Something the rotation must not touch: a different extension is a different
# backup set, and the glob is per-extension.
printf 'not mine\n' > "$proj/backups/pre-deploy-20200101-000000.sql.gz"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a deploy that rotates exits 0 (exit $rc)
        stderr: $run_err"
assert '[ "$(find "$proj/backups" -name "pre-deploy-*.txt.gz" | wc -l)" = "3" ]' \
    "three backups are kept, as backup.retain says
        backups: $(find "$proj/backups" -type f -printf "%f " 2>/dev/null)"
assert '[ ! -e "$proj/backups/pre-deploy-20200101-000000.txt.gz" ]' \
    "the oldest is the one removed"
assert '[ -e "$proj/backups/pre-deploy-20200103-000000.txt.gz" ]' \
    "the newest of the old ones is kept"
assert '[ -e "$proj/backups/pre-deploy-20200101-000000.sql.gz" ]' \
    "and a backup with a different extension is not in this set at all"

# --- Case X10: a backup that fails halfway ---------------------------------------------
: > "$tmpdir/crumbs"
setup_run x10 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
backup:
  container: demo-db
  check: "true"
  command: "echo half; exit 3"
  extension: txt
  retain: 3
' "$stock_compose"
printf 'demo-db\n' > "$STUB_STATE/containers"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a backup command that fails stops the deploy (exit $rc)"
assert 'grep -qF "demo-db" <<<"$run_err"' "naming the container it failed in (said '$run_err')"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' \
    "and leaves nothing behind — not the half file, not a .partial
        backups: $(find "$proj/backups" -type f -printf "%f " 2>/dev/null)"
assert '! grep -q "^docker|compose|-p|demo|up" "$DOCKER_LOG"' "nothing was brought up"
assert '[ ! -e "$proj/versions.log" ]' "and versions.log records nothing"

# --- Case X11: a hook that fails ---------------------------------------------------------
: > "$tmpdir/crumbs"
setup_run x11 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-web exit 7"
' "$stock_compose"
printf 'demo-web\n' > "$STUB_STATE/containers"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a pre-deploy hook that fails stops the deploy (exit $rc)"
assert 'grep -qF "pre-deploy hook failed in demo-web" <<<"$run_err"' \
    "naming the hook and its container (said '$run_err')"
assert '! grep -q "^docker|compose|-p|demo|up" "$DOCKER_LOG"' "before anything was brought up"
assert '[ ! -e "$proj/versions.log" ]' "and versions.log records nothing"

# --- Case X12: the command line ------------------------------------------------------------
setup_run x12 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' "$stock_compose"
deploy rollback 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "rollback is refused by name (exit $rc)"
assert 'grep -qF "rollback is not implemented" <<<"$run_err"' \
    "rather than as an unknown action (said '$run_err')"
deploy deploy; rc=$?
assert '[ "$rc" != "0" ]' "deploy with no version is refused (exit $rc)"
assert 'grep -qF "needs a version" <<<"$run_err"' "saying what is missing (said '$run_err')"
deploy deploy "1.5.0 extra"; rc=$?
assert '[ "$rc" != "0" ]' "a version with whitespace in it is refused (exit $rc)"
assert 'grep -qF "versions.log cannot carry" <<<"$run_err"' \
    "because versions.log's fields are space-delimited (said '$run_err')"
deploy deploy 1.5.0 --wat; rc=$?
assert '[ "$rc" != "0" ]' "an unknown flag is refused (exit $rc)"
assert 'grep -qF "unknown argument" <<<"$run_err"' "by name (said '$run_err')"
deploy --help; rc=$?
assert '[ "$rc" = "0" ]' "--help exits 0 (exit $rc)"
assert 'grep -qF -- "--skip-hooks" <<<"$run_err"' "and documents both flags (said '$run_err')"
assert 'grep -qF -- "--no-health-wait" <<<"$run_err"' "including --no-health-wait"

# --- Case X14: a first deploy, with nothing of this project running yet -----------------------
# The backup and the pre-deploy hooks act on the *outgoing* state, and a first
# deploy has none. Refusing there would make a first deploy impossible for every
# project that declares either, so both are skipped — and said out loud, because
# a silently-absent backup is the one thing that must never be quiet.
: > "$tmpdir/crumbs"
setup_run x14 "$(run_manifest "printf 'backup-check\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
# Nothing is running; `compose up` is what starts demo-web.
: > "$STUB_STATE/containers"
printf 'demo-web\n' > "$STUB_STATE/starts"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a first deploy of a project with hooks and a backup succeeds (exit $rc)
        stderr: $run_err"
assert 'grep -qF "nothing to back up" <<<"$run_err"' \
    "saying why no backup was taken (said '$run_err')"
assert 'grep -qF "pre-deploy hook skipped" <<<"$run_err"' \
    "and why the pre-deploy hook did not run (said '$run_err')"
assert '! grep -qF "backup-check" "$tmpdir/crumbs"' \
    "the backup gate was not even consulted — there is nothing to back up
        crumbs: $(tr "\n" "/" < "$tmpdir/crumbs")"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' "and no file was written"
assert '[[ "$(log_line)" == *" 1.5.0 no-backup kasbah="* ]]' \
    "versions.log says no-backup (line: $(log_line))"
assert 'grep -qxF "docker|tag|demo-web:1.5.0|demo-web:current" "$DOCKER_LOG"' \
    "while the deploy itself went through — the images were retagged"
assert 'grep -q "echo \"post " "$DOCKER_LOG"' \
    "and the post-deploy hook ran against the containers compose just started"

# A post-deploy hook whose container is not there after the health wait is a real
# failure, not a skip: that is the incoming state, and it should exist.
setup_run x14b 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  post-deploy:
    - "demo-web true"
' "$stock_compose"
: > "$STUB_STATE/containers"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a post-deploy hook with no container to run in fails the deploy (exit $rc)"
assert 'grep -qF "post-deploy hook failed in demo-web" <<<"$run_err"' \
    "rather than being skipped (said '$run_err')"
assert '[ ! -e "$proj/versions.log" ]' "and nothing is written to versions.log"

# --- Case X15: a crashed stack is not a first deploy ------------------------------------------
# `.State.Running` is false for a container that never existed and for one that
# died ten minutes ago alike. Reading the second as the first skips the backup
# exactly when it is most wanted and then deploys over the wreck, so the
# discriminator is versions.log, not the container list.
: > "$tmpdir/crumbs"
setup_run x15 "$(run_manifest "printf 'backup-check\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
# This project has deployed here before…
printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n' > "$proj/versions.log"
# …and its stack is down, not absent.
: > "$STUB_STATE/containers"
printf 'demo-web=exited\ndemo-db=exited\n' > "$STUB_STATE/stopped"
printf 'demo-web\n' > "$STUB_STATE/starts"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a redeploy over a stopped stack is refused (exit $rc)"
assert 'grep -qF "demo-web is exited" <<<"$run_err"' \
    "naming the container and the state docker reports for it (said '$run_err')"
assert 'grep -qF "versions.log records 1.4.0" <<<"$run_err"' \
    "and the entry that says this is not a first deploy (said '$run_err')"
assert 'grep -qF -- "--allow-stopped" <<<"$run_err"' \
    "and the flag for a stack that is meant to be down (said '$run_err')"
assert '! grep -qF "backup-check" "$tmpdir/crumbs"' \
    "nothing ran — not even the backup gate (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' "no backup was written"
assert '! grep -q "^docker|tag|" "$DOCKER_LOG"' "nothing was retagged"
assert '! grep -q "^docker|compose|-p|demo|up" "$DOCKER_LOG"' "and nothing was brought up"
assert '[ "$(wc -l < "$proj/versions.log")" = "1" ]' \
    "versions.log still holds only the earlier entry ($(wc -l < "$proj/versions.log") lines)"

# The same rig, with the operator saying the stack is meant to be down.
: > "$tmpdir/crumbs"
: > "$DOCKER_LOG"
deploy deploy 1.5.0 --allow-stopped; rc=$?
assert '[ "$rc" = "0" ]' "--allow-stopped deploys over it (exit $rc)
        stderr: $run_err"
assert 'grep -qF "allow-stopped" <<<"$run_err"' "saying which flag let it through (said '$run_err')"
assert '[ "$(find "$proj/backups" -type f 2>/dev/null | wc -l)" = "0" ]' \
    "still taking no backup — there is nothing running to take one from"
assert 'grep -qxF "docker|tag|demo-web:1.5.0|demo-web:current" "$DOCKER_LOG"' \
    "while the deploy itself goes through"
assert '[ "$(wc -l < "$proj/versions.log")" = "2" ]' "and appends its entry"

# And the case the refusal must not catch: a genuine first deploy, same stopped
# daemon state, no versions.log at all.
: > "$tmpdir/crumbs"
setup_run x15b "$(run_manifest "printf 'backup-check\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
: > "$STUB_STATE/containers"
printf 'demo-web\n' > "$STUB_STATE/starts"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "a genuine first deploy still succeeds with no flag (exit $rc)
        stderr: $run_err"
assert 'grep -qF "first deploy" <<<"$run_err"' \
    "saying so, and why (said '$run_err')"
assert '[[ "$(log_line)" == *" 1.5.0 no-backup kasbah="* ]]' \
    "recording no-backup (line: $(log_line))"

# --- Case X15c: history whose last line is malformed is still history -------------------------
# The two questions the preflight has to keep apart. "Which version was it" is
# field 3 of the last entry, and a `printf >>` killed mid-append leaves a line it
# cannot be read out of — so a guard turned on the *version* reads a project with
# real history as one that has never deployed here, and fails open in exactly the
# state that most wants it closed. "Has this deployed here" is any entry at all.
: > "$tmpdir/crumbs"
setup_run x15c "$(run_manifest "printf 'backup-check\n' >> $tmpdir/crumbs")" "$built_compose"
printf 'demo-web:1.5.0=sha256:aaa\ndemo-worker:1.5.0=sha256:bbb\n' > "$STUB_STATE/images"
{ printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n'
  printf '2026-01-02T00:00:00+0'; } > "$proj/versions.log"
: > "$STUB_STATE/containers"
printf 'demo-web=exited\ndemo-db=exited\n' > "$STUB_STATE/stopped"
printf 'demo-web\n' > "$STUB_STATE/starts"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' \
    "a stopped stack is still refused when the last versions.log line is a truncated write (exit $rc)"
assert 'grep -qF "deployed here before" <<<"$run_err"' \
    "on the evidence that there are entries at all (said '$run_err')"
assert 'grep -qF "not one a version can be read out of" <<<"$run_err"' \
    "and the message says why it cannot name the version rather than naming a wrong one
        said: $run_err"
assert '! grep -qF "first deploy" <<<"$run_err"' \
    "and never calls it a first deploy (said '$run_err')"
assert '[ "$(wc -l < "$proj/versions.log")" = "1" ]' \
    "nothing was appended ($(wc -l < "$proj/versions.log") complete lines)"

# The same file, with the stack up: the deploy proceeds, and $PREV_VERSION is
# empty rather than a guess at what the half-written line meant.
: > "$tmpdir/crumbs"
printf 'demo-web\ndemo-db\n' > "$STUB_STATE/containers"
: > "$STUB_STATE/stopped"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" = "0" ]' "with the stack up it deploys (exit $rc)
        stderr: $run_err"
assert 'grep -qF "prev= " "$tmpdir/crumbs"' \
    "handing the hooks an empty \$PREV_VERSION, not a fragment of the broken line
        crumbs: $(tr "\n" "/" < "$tmpdir/crumbs")"
# …and it says so as a fact of its own, because an empty prev_version is also
# what a genuine first deploy reports and the changelog gives the two different
# sentences (lib/deploy.sh → _deploy_changelog).
assert 'grep -qxF "deployed_before=yes" <<<"$run_out"' \
    "reporting that this project has deployed here, on the evidence the version could not
        be read from (stdout: $(tr "\n" "/" <<<"$run_out"))"

# What the append did to the file it appended to. The truncated last line has no
# newline on it, so a bare `printf '%s\n' >>` writes the new entry onto the end
# of it — and the fused line still has six fields, so every later reader accepts
# it, with the interrupted record's remains sitting in the frozen timestamp.
log_after="$(cat "$proj/versions.log")"
assert '[ "$(wc -l < "$proj/versions.log")" = "3" ]' \
    "the truncated line is terminated and the entry appended below it — three lines, not two
        log: $(tr "\n" "/" <<<"$log_after")"
assert '[ "$(sed -n 1p "$proj/versions.log")" = "2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-" ]' \
    "the complete earlier entry is byte-for-byte what it was
        got: $(sed -n 1p "$proj/versions.log")"
assert '[ "$(sed -n 2p "$proj/versions.log")" = "2026-01-02T00:00:00+0" ]' \
    "and the truncated one is still its own line, holding exactly what it held — nothing
        was written into it (got: $(sed -n 2p "$proj/versions.log"))"
assert '[[ "$(sed -n 3p "$proj/versions.log")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00\ deploy\ 1\.5\.0\  ]]' \
    "with the new entry on a line of its own, starting at its own timestamp
        got: $(sed -n 3p "$proj/versions.log")"
assert 'grep -qF "had no newline on it" <<<"$run_err"' \
    "and the repair is said out loud rather than done quietly (said '$run_err')"

# --- Case X15d: a *mixed* outgoing state, which the skips are per container for ---------------
# backup.container up, one pre-deploy hook's container down. rd_backup checks its
# own container and rd_run_hooks checks each hook's, so what --allow-stopped
# actually skips here is the hook and nothing else — a message that says "the
# backup and the pre-deploy hooks are skipped" announces a skip that does not
# happen, while the backup file is written and versions.log field 4 names it.
: > "$tmpdir/crumbs"
setup_run x15d 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-worker printf pre-hook-ran >> '"$tmpdir"'/crumbs"
backup:
  container: demo-db
  check: "echo backup-check >> '"$tmpdir"'/crumbs"
  command: echo kasbah-backup-payload
  extension: txt
  retain: 3
' "$stock_compose"
printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n' > "$proj/versions.log"
printf 'demo-db\n' > "$STUB_STATE/containers"
printf 'demo-worker=exited\n' > "$STUB_STATE/stopped"

deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "with one hook container down the redeploy is still refused (exit $rc)"
assert 'grep -qF "demo-worker is exited" <<<"$run_err"' "naming it (said '$run_err')"
assert '! grep -qF "demo-db" <<<"$run_err"' \
    "and not the backup's container, which is up (said '$run_err')"
assert 'grep -qF "cannot run the pre-deploy hooks in demo-worker" <<<"$run_err"' \
    "saying what it is that cannot run, rather than 'its backup or its pre-deploy hooks'
        said: $run_err"

: > "$tmpdir/crumbs"
deploy deploy 1.5.0 --allow-stopped; rc=$?
assert '[ "$rc" = "0" ]' "--allow-stopped lets it through (exit $rc)
        stderr: $run_err"
assert 'grep -qF -- "--allow-stopped: demo-worker is exited, so the pre-deploy hooks in demo-worker will not run" <<<"$run_err"' \
    "announcing exactly the step that is skipped (said '$run_err')"
# The killer for the blanket sentence: the backup it would have said was skipped
# is on disk, with its payload, and versions.log field 4 names it.
assert '! grep -qE -- "--allow-stopped:.*backup" <<<"$run_err"' \
    "and never claiming the backup was skipped (said '$run_err')"
assert '[ "$(cat "$tmpdir/crumbs")" = "backup-check" ]' \
    "the backup gate ran and no hook did (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"
backup_mixed="$(find "$proj/backups" -name 'pre-deploy-*.txt' 2>/dev/null | head -1)"
assert '[ -n "$backup_mixed" ] && [ "$(cat "$backup_mixed" 2>/dev/null)" = "kasbah-backup-payload" ]' \
    "and the backup was written with its payload (found '$backup_mixed')"
assert '[[ "$(sed -n 2p "$proj/versions.log")" == *" deploy 1.5.0 backups/pre-deploy-"*".txt kasbah="* ]]' \
    "with versions.log field 4 naming the file rather than no-backup
        line: $(sed -n 2p "$proj/versions.log")"
assert 'grep -qF "pre-deploy hook skipped: no demo-worker is running" <<<"$run_err"' \
    "and the hook that really was skipped saying so where it happened (said '$run_err')"

# --- Case X15e: absent is not stopped ---------------------------------------------------------
# Rename a container_name: in compose.prod.yml and forget the hook, and the
# second deploy is refused forever with "start it" — about a container the
# compose file no longer defines, which cannot start. The only way past is
# --allow-stopped, which then disables that hook silently on every deploy after
# it: the exact silent skip this preflight exists to stop. The stub tells the two
# apart because a name in neither `containers` nor `stopped` is `No such object`.
: > "$tmpdir/crumbs"
setup_run x15e 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-renamed true"
' "$stock_compose"
printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n' > "$proj/versions.log"
: > "$STUB_STATE/containers"
: > "$STUB_STATE/stopped"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a hook naming a container that does not exist refuses the redeploy (exit $rc)"
assert 'grep -qF "demo-renamed does not exist on this server" <<<"$run_err"' \
    "saying what docker actually reports, not 'demo-renamed is absent' (said '$run_err')"
assert '! grep -qF "Start it" <<<"$run_err"' \
    "and never telling the operator to start something that cannot start (said '$run_err')"
assert 'grep -qF "container_name:" <<<"$run_err"' \
    "pointing at the mismatch between the manifest and the compose file instead (said '$run_err')"
assert 'grep -qF "HK01" <<<"$run_err"' \
    "and at the local check that catches it before a deploy (said '$run_err')"
assert 'grep -qF "silently on every deploy after it" <<<"$run_err"' \
    "with what --allow-stopped would really buy here (said '$run_err')"
assert '[ "$(wc -l < "$proj/versions.log")" = "1" ]' "and nothing was appended"

# --- Case X17: no flock on this server is not a concurrent deploy ------------------------------
# `flock -n 9` on a host with no flock exits 127, and `|| fail` turns that into a
# statement about an operator who does not exist. No stub can express it — flock
# is a real binary — so the case builds a PATH that has everything the script
# uses except that one.
nobin="$tmpdir/nobin"
mkdir -p "$nobin"
for c in bash sh dirname basename date mkdir rm mv tail sleep cat gzip grep sed head wc tr find; do
    cp_from="$(command -v "$c" 2>/dev/null)" && ln -sf "$cp_from" "$nobin/$c"
done
assert '[ ! -e "$nobin/flock" ] && [ -x "$nobin/bash" ]' \
    "the reduced PATH has a bash and no flock — otherwise this case proves nothing"

setup_run x17 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' "$stock_compose"
env PATH="$stub_dir:$nobin" STUB_STATE="$STUB_STATE" DOCKER_LOG="$DOCKER_LOG" \
    KASBAH_VERSION=0.1.0-test "$proj/scripts/remote-deploy.sh" deploy 1.5.0 \
    >"$tmpdir/run.out" 2>"$tmpdir/run.err" </dev/null; rc=$?
run_err="$(cat "$tmpdir/run.err")"
assert '[ "$rc" != "0" ]' "a server with no flock refuses the deploy (exit $rc)"
assert 'grep -qF "flock is not installed on this server" <<<"$run_err"' \
    "saying that, rather than naming a lock nobody holds (said '$run_err')"
assert '! grep -qF "already running" <<<"$run_err"' \
    "and never accusing a concurrent deploy that does not exist (said '$run_err')"
assert 'grep -qF "util-linux" <<<"$run_err"' "with what to install (said '$run_err')"
assert '[ ! -e "$proj/.deploy.lock" ]' \
    "asked before the lock file is opened, so nothing is left behind either"
assert '[ ! -e "$proj/versions.log" ]' "and nothing was deployed"

# --- Case X16: --skip-hooks narrows what the outgoing preflight demands -----------------------
# With the hooks skipped their containers are not needed, so a stopped one is
# not a reason to refuse — but the backup's container still is, and both halves
# are asserted below.
: > "$tmpdir/crumbs"
setup_run x16 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
hooks:
  pre-deploy:
    - "demo-worker true"
' "$stock_compose"
printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n' > "$proj/versions.log"
: > "$STUB_STATE/containers"
printf 'demo-worker=exited\n' > "$STUB_STATE/stopped"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a stopped pre-deploy hook container refuses a redeploy (exit $rc)"
assert 'grep -qF "demo-worker is exited" <<<"$run_err"' "naming it (said '$run_err')"
deploy deploy 1.5.0 --skip-hooks; rc=$?
assert '[ "$rc" = "0" ]' \
    "while --skip-hooks does not need it at all (exit $rc)
        stderr: $run_err"

# The other half of the same sentence: --skip-hooks narrows the set to the
# backup's container, and does not empty it. A flag for a dry-run-ish deploy
# must not quietly become one that deploys over a stack with no backup taken.
: > "$tmpdir/crumbs"
setup_run x16b "$(run_manifest "printf 'backup-check\n' >> $tmpdir/crumbs")" "$stock_compose"
printf '2026-01-01T00:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0-test digest=-\n' > "$proj/versions.log"
: > "$STUB_STATE/containers"
printf 'demo-db=exited\ndemo-web=exited\n' > "$STUB_STATE/stopped"
printf 'demo-web=healthy\n' > "$STUB_STATE/health"
deploy deploy 1.5.0 --skip-hooks; rc=$?
assert '[ "$rc" != "0" ]' \
    "--skip-hooks still refuses a redeploy whose backup container is stopped (exit $rc)"
assert 'grep -qF "demo-db is exited" <<<"$run_err"' \
    "naming the backup's container, which the flag does not excuse (said '$run_err')"
assert '! grep -qF "backup-check" "$tmpdir/crumbs"' \
    "and the gate never ran (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"

# And with that one container up, --skip-hooks takes the backup and skips only
# the hooks — which is the whole contract of the flag.
: > "$tmpdir/crumbs"
printf 'demo-db\n' > "$STUB_STATE/containers"
printf 'demo-web=exited\n' > "$STUB_STATE/stopped"
deploy deploy 1.5.0 --skip-hooks; rc=$?
assert '[ "$rc" = "0" ]' "with the backup container running it deploys (exit $rc)
        stderr: $run_err"
assert '[ "$(find "$proj/backups" -name "pre-deploy-*.txt.gz" | wc -l)" = "1" ]' \
    "taking the backup
        backups: $(find "$proj/backups" -type f -printf "%f " 2>/dev/null)"
assert '[ "$(cat "$tmpdir/crumbs")" = "backup-check" ]' \
    "through its gate, and running no hook (crumbs: $(tr "\n" "/" < "$tmpdir/crumbs"))"

# --- Case X13: the preconditions the script has always had -----------------------------------
setup_run x13 'schema: 1
name: demo
domain: demo.test
sync:
  - compose.prod.yml -> compose.yml
' "$stock_compose"
rm -f "$proj/compose.yml"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "a project directory with no compose.yml is refused (exit $rc)"
assert 'grep -qF "compose.yml is missing" <<<"$run_err"' "by name (said '$run_err')"
printf 'services: {}\n' > "$proj/compose.yml"
rm -f "$proj/.env"
deploy deploy 1.5.0; rc=$?
assert '[ "$rc" != "0" ]' "and one with no .env (exit $rc)"
assert 'grep -qF ".env is missing" <<<"$run_err"' "by name (said '$run_err')"

exit "$fail"
