#!/usr/bin/env bash
# Test: `kasbah build-push` (internal/buildpush) — everything that does not need
# a real server, a registry or a Docker daemon.
#
# Hermetic. `docker` and `ssh` are stubs on PATH that record every invocation.
# The ssh stub plays the server by running the remote command here: the
# bootstrap probe against a scratch apps tree whose kasbah binary is a copy of
# the one under test, and `kasbah remote load` for real, against the same docker
# stub — so what a case asserts is what crossed the wire and what the far side
# did with it. git is real, against throwaway repositories under a temp
# directory — including the `origin` the tag cases use, which is a bare repo
# two directories away and never a network.
#
# The stub logs are read both ways: a case asserts what was asked for, and the
# cases about refusals assert the logs are *empty*, which is only evidence when
# something else in the same run proves the stubs are really being used
# (plan/roadmap/02-spine.md — a "hermetic" block with no stub on PATH once passed
# on a DNS lookup failing).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
. "$repo_dir/tests/fixture_repo.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- The stubs ------------------------------------------------------------------

stub_dir="$tmpdir/stub"
scratch="$tmpdir/scratch"
fakehome="$tmpdir/home"
mkdir -p "$stub_dir" "$scratch" "$fakehome"

DOCKER_LOG="$tmpdir/docker.log"
SSH_LOG="$tmpdir/ssh.log"
SSH_STDIN_LOG="$tmpdir/ssh-stdin.log"
RSYNC_LOG="$tmpdir/rsync.log"
LOADED="$tmpdir/loaded"

# The server: an apps tree with a marker, and this build's binary at the
# shared path, so the same-build rule keeps it and nothing is uploaded.
FAKE_APPS="$tmpdir/srv/apps"
mkdir -p "$FAKE_APPS/.kasbah/bin"
printf '{"kasbah_version":"1.0.0","apps_path":"%s","data_path":"%s/data","cpu_limit":"1","mem_limit":"1g"}\n' \
    "$FAKE_APPS" "$FAKE_APPS" > "$FAKE_APPS/.kasbah/server.json"
cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"

cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "${1:-}" in
    # Something has to come out of save, or the stream is empty, which is not
    # what a real save does.
    save)
        # More than the sender's 1 MiB buffer, so a failing save has really
        # sent part of a stream when it fails.
        if [ -n "${DOCKER_SAVE_RC:-}" ]; then head -c 3000000 /dev/urandom; exit "$DOCKER_SAVE_RC"; fi
        if [ -n "${STUB_SAVE_TAR:-}" ]; then cat "$STUB_SAVE_TAR"; exit 0; fi
        printf 'fake-image-stream\n' ;;
    load)
        cat > "$LOADED"; cp "$LOADED" "$LOADED.$(ls "$LOADED".* 2>/dev/null | wc -l)"
        # The containerd store's answer to a layer it does not hold: a tagged
        # image, a line of narration, and exit 0.
        if [ -n "${STUB_UNPACK_FAIL:-}" ]; then
            names="$(tar -tf "$LOADED" 2>/dev/null)"
            grep -qF "$STUB_UNPACK_FAIL" <<<"$names" \
                || echo "Error unpacking image built-app-web:1.4.2: content digest sha256:$STUB_UNPACK_FAIL: not found"
        fi
        # The overlay2 store's: docker load fails.
        if [ -n "${STUB_LOAD_FAIL:-}" ]; then
            names="$(tar -tf "$LOADED" 2>/dev/null)"
            grep -qF "$STUB_LOAD_FAIL" <<<"$names" || { echo "open blobs/sha256/$STUB_LOAD_FAIL: no such file" >&2; exit 1; }
        fi
        exit "${DOCKER_LOAD_RC:-0}" ;;
    # Layer lists, by image name or id, from $STUB_ROOTFS; the server's own
    # images are the srv-* ids its image ls lists.
    image)
        if [ -n "${STUB_ROOTFS:-}" ] && [ "${2:-}" = ls ]; then cat "$STUB_ROOTFS/ids"; exit 0; fi
        if [ -n "${STUB_ROOTFS:-}" ] && [ "${2:-} ${3:-}" = "inspect --format" ]; then
            shift 4
            case "$*" in srv-*) [ "${STUB_SERVER_INSPECT_RC:-0}" = 0 ] || exit "$STUB_SERVER_INSPECT_RC" ;; esac
            for i; do cat "$STUB_ROOTFS/${i//:/_}" || exit 1; done
            exit 0
        fi ;;
    # A tree edited while the build runs; the platform each build was asked for.
    compose)
        printf '%s\n' "${DOCKER_DEFAULT_PLATFORM-unset}" >> "$DOCKER_LOG.platform"
        [ -z "${STUB_COMPOSE_ERR:-}" ] || { printf '%s\n' "$STUB_COMPOSE_ERR" >&2; exit 1; }
        [ -z "${DOCKER_BUILD_TOUCH:-}" ] || printf 'during\n' >> "$DOCKER_BUILD_TOUCH" ;;
    # The image store, when a case plays the containerd one.
    info) printf '%s\n' "${STUB_INFO:-}"; exit 0 ;;
    # The engine's own platform, when a case plays one.
    version) [ -z "${STUB_ENGINE:-}" ] || printf '%s\n' "$STUB_ENGINE"; exit 0 ;;
esac
exit "${DOCKER_RC:-0}"
STUB

# The last argument is the remote command, quoted word by word.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
[ "${SSH_RC:-0}" = 0 ] || exit "$SSH_RC"
last="${!#}"
[ "$last" = true ] && exit 0
eval "set -- $last"
if [ "$1 $2" = "sh -s" ]; then
    # The bootstrap probe: answered from the scratch tree, with no pointer.
    [ -n "${FAKE_NO_MARKER:-}" ] && rm -f "$FAKE_APPS/.kasbah/server.json"
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7" "${8:-}"
fi
if [ "${2:-} ${3:-}" = "remote load" ]; then
    if [ -n "${SSH_LOAD_OUT+set}" ]; then
        cat > "$SSH_STDIN_LOG"
        [ -z "$SSH_LOAD_OUT" ] || printf '%s\n' "$SSH_LOAD_OUT"
        exit 0
    fi
    # A connection that drops mid-stream: the far side gets the first bytes only.
    if [ -n "${SSH_TRUNCATE:-}" ]; then
        exec "$@" < <(head -c "$SSH_TRUNCATE" | tee "$SSH_STDIN_LOG")
    fi
    exec "$@" < <(tee "$SSH_STDIN_LOG")
fi
exec "$@"
STUB

# Nothing travels by rsync any more; the stub is there to prove it.
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_LOG"
exit 1
STUB

chmod 0755 "$stub_dir/docker" "$stub_dir/ssh" "$stub_dir/rsync"

# git is real, so it must not read the developer's own configuration: a global
# commit.gpgsign or a push default is not this suite's to inherit.
printf '[user]\n\temail = build-push-test@kasbah.test\n\tname = kasbah build-push test\n' \
    > "$fakehome/.gitconfig"

# --- Running the command ---------------------------------------------------------

# recommit <tag> — commit what a case edited in $projdir and move the tag onto
# it: build-push refuses a working tree that is not HEAD's.
recommit() {
    ( cd "$projdir" && HOME="$fakehome" git add -A && HOME="$fakehome" git commit -qm edit \
        && git tag -f "$1" ) >/dev/null 2>&1 || { echo "error: could not commit the edit in $projdir" >&2; exit 2; }
}

projdir=""
out=""
err=""

reset_logs() {
    : > "$DOCKER_LOG"
    : > "$DOCKER_LOG.platform"
    : > "$SSH_LOG"
    : > "$SSH_STDIN_LOG"
    : > "$RSYNC_LOG"
    rm -f "$LOADED" "$LOADED".*
    rm -rf "$scratch"
    mkdir -p "$scratch"
    printf '{"kasbah_version":"1.0.0","apps_path":"%s","data_path":"%s/data","cpu_limit":"1","mem_limit":"1g"}\n' \
        "$FAKE_APPS" "$FAKE_APPS" > "$FAKE_APPS/.kasbah/server.json"
}

# TMPDIR is the suite's own, so "did it leave anything behind" is a question
# about a directory nothing else writes to.
bp() (
    cd "$projdir" || exit 2
    env PATH="$stub_dir:$PATH" HOME="$fakehome" TMPDIR="$scratch" \
        DOCKER_LOG="$DOCKER_LOG" SSH_LOG="$SSH_LOG" SSH_STDIN_LOG="$SSH_STDIN_LOG" \
        RSYNC_LOG="$RSYNC_LOG" LOADED="$LOADED" FAKE_APPS="$FAKE_APPS" \
        "$KASBAH_BIN" build-push "$@" </dev/null
)

run() {
    reset_logs
    out="$(bp "$@" 2>"$tmpdir/err")"; rc=$?
    err="$(cat "$tmpdir/err")"
    return "$rc"
}

# Lines of the docker log that are compose invocations, one per line.
compose_calls() { grep '^compose ' "$DOCKER_LOG" 2>/dev/null; return 0; }

# --- Projects ----------------------------------------------------------------------

make() {
    local name="$1" fixture="$2"; shift 2
    local dir="$tmpdir/$name"
    if ! fixture_repo_make "$dir" "$repo_dir/tests/fixtures/$fixture" "$@" 2>>"$tmpdir/git.log"; then
        echo "error: could not build the $name project from tests/fixtures/$fixture" >&2
        sed 's/^/       | /' "$tmpdir/git.log" >&2
        exit 2
    fi
    printf '%s' "$dir"
}

if ! command -v git >/dev/null || ! command -v jq >/dev/null; then
    echo "error: this suite needs git and jq on PATH" >&2
    exit 2
fi

built="$(make built built-app v1.4.2)"
stock="$(make stock demo v2.0.0)"

# --- The version comes from HEAD's single v-tag -------------------------------------
# Every one of these must stop before anything is built: the version labels the
# images, so a build without one produces images kasbah cannot name.

projdir="$(make untagged built-app)"
run; rc=$?
assert '[ "$rc" = "1" ]' "an untagged HEAD with no terminal and no --bump is a failure (exit $rc)"
assert 'grep -qF "no version tag" <<<"$err"' "saying HEAD carries no version (said '$err')"
assert 'grep -qF -- "--bump=patch|minor|major" <<<"$err"' "and naming the flag that answers it (said '$err')"
assert '[ -z "$(cd "$projdir" && git tag)" ]' "and tagging nothing"
assert '[ ! -s "$DOCKER_LOG" ]' \
    "and nothing was built — docker was never called (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -s "$SSH_LOG" ]' "nor reached for a server (ssh log: $(cat "$SSH_LOG"))"

projdir="$(make twotags built-app v1.4.2 v1.5.0)"
run; rc=$?
assert '[ "$rc" = "1" ]' "two v-tags on HEAD is a failure (exit $rc)"
assert 'grep -qF "2 version tags" <<<"$err"' "counting them (said '$err')"
assert 'grep -qF "v1.4.2 v1.5.0" <<<"$err"' "and naming both (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "with nothing built (log: $(cat "$DOCKER_LOG"))"

projdir="$(make notsemver built-app v1.4)"
run; rc=$?
assert '[ "$rc" = "1" ]' "a v-tag that is not semver is refused (exit $rc)"
assert 'grep -qF "v1.4" <<<"$err"' "and quoted back (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "with nothing built (log: $(cat "$DOCKER_LOG"))"

projdir="$(make plaintag built-app release-7)"
run; rc=$?
assert '[ "$rc" = "1" ]' "a tag that is not a v-tag is no version at all (exit $rc)"
assert 'grep -qF "no version tag" <<<"$err"' \
    "and it is the no-tag branch that fires, not the two-tags one (said '$err')"

# --- A project that builds nothing --------------------------------------------------
# The stock-image case: exit 0 having done nothing at all. Asserted on the
# stub logs and the state file rather than on what it printed.

projdir="$stock"
run "user@somewhere"; rc=$?
assert '[ "$rc" = "0" ]' "a stock-only project exits 0 (exit $rc: $err)"
assert 'grep -qF "builds nothing" <<<"$out$err"' "saying so (said '$out$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "runs no docker at all (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -s "$SSH_LOG" ]' "and never opens a connection (ssh log: $(cat "$SSH_LOG"))"
assert '[ ! -e "$stock/.kasbah/state.json" ]' \
    "a run that shipped nothing records no last_server either"

# --- A built service must name its image ---------------------------------------------

projdir="$(make noimage built-app v1.4.2)"
sed -i '/^    image: built-app-web:current$/d' "$projdir/compose.prod.yml"
recommit v1.4.2
assert '! grep -q "image: built-app-web" "$projdir/compose.prod.yml"' \
    "the compose file really has lost its image: key — else the case below proves nothing"
run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a build: service with no image: is refused (exit $rc)"
assert 'grep -qF "service '"'"'built-app-web'"'"'" <<<"$err"' "naming the service (said '$err')"
assert 'grep -qF "image:" <<<"$err"' "and what to add (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' \
    "before anything is built — the whole compose file is read first (log: $(cat "$DOCKER_LOG"))"

# --- Tag derivation -------------------------------------------------------------------
# <image>:current → <image>:<version>. The registry-with-a-port form is the one
# that breaks a naive "strip after the last colon": reg.example:5000/app has a
# colon that is not a tag.

projdir="$(make images built-app v1.4.2)"
cat > "$projdir/compose.prod.yml" <<'COMPOSE'
name: built-app
services:
  built-app-web:
    build: .
    image: built-app-web:current
  worker:
    build:
      context: .
      dockerfile: Dockerfile
    image: reg.example:5000/built-app-worker:current
  bare:
    build: .
    image: built-app-bare
  ported:
    build: .
    image: reg.example:5000/built-app-ported
  cache:
    image: redis:7-alpine
COMPOSE
recommit v1.4.2

run --build-only; rc=$?
assert '[ "$rc" = "0" ]' "--build-only against four built services succeeds (exit $rc: $err)"
assert 'grep -qxF "tag built-app-web:current built-app-web:1.4.2" "$DOCKER_LOG"' \
    "the :current tag becomes :<version> (log: $(cat "$DOCKER_LOG"))"
assert 'grep -qxF "tag reg.example:5000/built-app-worker:current reg.example:5000/built-app-worker:1.4.2" "$DOCKER_LOG"' \
    "a registry port is not mistaken for a tag (log: $(cat "$DOCKER_LOG"))"
assert 'grep -qxF "tag built-app-bare built-app-bare:1.4.2" "$DOCKER_LOG"' \
    "an image named without a tag gains one (log: $(cat "$DOCKER_LOG"))"
assert 'grep -qxF "tag reg.example:5000/built-app-ported reg.example:5000/built-app-ported:1.4.2" "$DOCKER_LOG"' \
    "and a registry port with no tag after it keeps the port (log: $(cat "$DOCKER_LOG"))"
assert '[ "$(grep -c "^tag " "$DOCKER_LOG")" = "4" ]' \
    "while the stock service is not tagged — four built services, four tags (got $(grep -c "^tag " "$DOCKER_LOG"))"

# A compose file authored on Windows derives the same images: the values reach
# kasbah through a YAML parser, and nothing downstream may end up with a \r in a
# tag no docker daemon could match.
sed -i 's/$/\r/' "$projdir/compose.prod.yml"
recommit v1.4.2
assert 'grep -qU $'"'"'\r'"'"' "$projdir/compose.prod.yml"' \
    "the compose file really is CRLF now — else the case below proves nothing"
run --build-only; rc=$?
assert '[ "$rc" = "0" ]' "a CRLF compose file is read (exit $rc: $err)"
assert 'grep -qxF "tag built-app-web:current built-app-web:1.4.2" "$DOCKER_LOG"' \
    "with no carriage return anywhere in the tag (log: $(cat -v "$DOCKER_LOG"))"
sed -i 's/\r$//' "$projdir/compose.prod.yml"
recommit v1.4.2

# --- --build-only stops after the tag ---------------------------------------------------

assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "0" ]' \
    "--build-only saves nothing (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -s "$SSH_LOG" ]' "opens no connection (ssh log: $(cat "$SSH_LOG"))"
assert '[ ! -s "$RSYNC_LOG" ]' "transfers nothing (rsync log: $(cat "$RSYNC_LOG"))"
assert 'grep -qF "nothing was shipped" <<<"$out$err"' "and says so (said '$out$err')"
# The positive control for the four emptiness assertions above: the same run
# really did drive the stubs.
assert '[ -s "$DOCKER_LOG" ]' "while docker was driven through the stub (log: $(cat "$DOCKER_LOG"))"

# --build-only needs no server, and takes none from state either.
assert '[ ! -e "$projdir/.kasbah/state.json" ]' \
    "--build-only writes no state — it talked to no server"

# --- Every compose invocation carries -p -------------------------------------------------
# `name:` in a compose file is the weakest source of the project name and
# COMPOSE_PROJECT_NAME outranks it, which once put nine unrelated containers in
# range (plan/roadmap/01-rig.md).

calls="$(compose_calls)"
assert '[ -n "$calls" ]' "build-push runs docker compose at all (log: $(cat "$DOCKER_LOG"))"
bad=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "-p built-app " <<<"$line " || bad="$bad|$line"
done <<<"$calls"
assert '[ -z "$bad" ]' "every compose call names the project with -p (offenders: $bad)"

# --- One docker save, carrying every image ------------------------------------------------
# A save per image throws away the layer dedup one stream gives you.

projdir="$(make ship built-app v1.4.2)"
cat > "$projdir/compose.prod.yml" <<'COMPOSE'
name: built-app
services:
  built-app-web:
    build: .
    image: built-app-web:current
  worker:
    build: .
    image: built-app-worker:current
  cache:
    image: redis:7-alpine
COMPOSE
recommit v1.4.2

run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a two-image project ships (exit $rc: $err)"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' \
    "in exactly one docker save (log: $(cat "$DOCKER_LOG"))"
saveline="$(grep '^save ' "$DOCKER_LOG")"
assert 'grep -qF "built-app-web:1.4.2" <<<"$saveline"' \
    "carrying the first image (save: '$saveline')"
assert 'grep -qF "built-app-worker:1.4.2" <<<"$saveline"' \
    "and the second (save: '$saveline')"
assert '! grep -qF "redis" <<<"$saveline"' \
    "and not the stock one, which the server pulls (save: '$saveline')"
assert '! grep -qF ":current" <<<"$saveline"' \
    "and not :current, which build-push never moves (save: '$saveline')"

# --- What travels, and what is left behind ------------------------------------------------

load_calls="$(grep -F "'remote' 'load'" "$SSH_LOG")"
assert '[ "$(grep -c . <<<"$load_calls")" = "1" ]' \
    "one stream into one remote load, not one per image (ssh log: $(cat "$SSH_LOG"))"
assert 'grep -qF "'"'"'$FAKE_APPS/.kasbah/bin/kasbah'"'"' '"'"'remote'"'"' '"'"'load'"'"' '"'"'$FAKE_APPS'"'"' '"'"'built-app-web:1.4.2'"'"' '"'"'built-app-worker:1.4.2'"'"'" <<<"$load_calls"' \
    "run by the server's own binary at the shared path, naming its apps path and both images (call: '$load_calls')"
assert 'grep -qF "deploy@vps" <<<"$load_calls"' "on the server it was told (call: '$load_calls')"
assert 'gzip -t "$SSH_STDIN_LOG" 2>/dev/null' \
    "what travels is a complete gzip stream, not a bare tar ($(file -b "$SSH_STDIN_LOG" 2>/dev/null))"
assert '[ "$(gzip -dc "$SSH_STDIN_LOG" 2>/dev/null)" = "fake-image-stream" ]' \
    "carrying docker save's output ($(gzip -dc "$SSH_STDIN_LOG" 2>/dev/null | head -c 80))"
assert '[ "$(cat "$LOADED" 2>/dev/null)" = "fake-image-stream" ]' \
    "and the far side's docker load read it decompressed (load read: '$(cat "$LOADED" 2>/dev/null)')"
assert 'grep -qxF "image inspect built-app-web:1.4.2" "$DOCKER_LOG" && grep -qxF "image inspect built-app-worker:1.4.2" "$DOCKER_LOG"' \
    "and asked the daemon each image is really there (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -s "$RSYNC_LOG" ]' "nothing goes by rsync (rsync log: $(cat "$RSYNC_LOG"))"
assert '[ -z "$(find "$scratch" -mindepth 1 -maxdepth 1 ! -name "kasbah-ssh.*")" ]' \
    "no tarball or other file is written here (found: $(find "$scratch" -mindepth 1 -maxdepth 1))"
assert '[ "$(jq -r .last_server "$projdir/.kasbah/state.json" 2>/dev/null)" = "deploy@vps" ]' \
    "a successful ship records last_server (state: $(cat "$projdir/.kasbah/state.json" 2>/dev/null))"
assert '[ -z "$(find "$scratch" -maxdepth 1 -name "kasbah-ssh.*" 2>/dev/null)" ]' \
    "the ssh master's private directory is gone (found: $(find "$scratch" -maxdepth 1 -name "kasbah-ssh.*" 2>/dev/null))"
assert '! grep -qF "'"'"'rm'"'"'" "$SSH_LOG"' \
    "and nothing is left on the server to remove (ssh log: $(cat "$SSH_LOG"))"

# --- Layers the server already holds stay off the wire -----------------------------------
# A real docker ≥25 save shape: both images on one base, the server holding
# that base under an image of its own.
lay="$tmpdir/layers"
mkdir -p "$lay/tar/blobs/sha256" "$lay/rootfs"
blob() { local h; h="$(sha256sum "$1" | cut -d' ' -f1)"; mv "$1" "$lay/tar/blobs/sha256/$h"; printf '%s' "$h"; }
head -c 200000 /dev/urandom > "$lay/b"; hb="$(blob "$lay/b")"
printf 'web-app' > "$lay/a"; ha="$(blob "$lay/a")"
printf 'worker-app' > "$lay/w"; hw="$(blob "$lay/w")"
printf '{"Config":"x","Layers":["blobs/sha256/%s"]}' "$hb" > "$lay/tar/manifest.json"
printf '{}' > "$lay/tar/index.json"; printf '{"imageLayoutVersion":"1.0.0"}' > "$lay/tar/oci-layout"
tar -C "$lay/tar" -cf "$lay/save.tar" blobs index.json manifest.json oci-layout
printf '["sha256:%s","sha256:%s"]\n' "$hb" "$ha" > "$lay/rootfs/built-app-web_1.4.2"
printf '["sha256:%s","sha256:%s"]\n' "$hb" "$hw" > "$lay/rootfs/built-app-worker_1.4.2"
printf '["sha256:%s"]\n' "$hb" > "$lay/rootfs/srv-base"
printf 'srv-base\nsrv-base\n' > "$lay/rootfs/ids"
loaded_names() { tar -tf "${1:-$LOADED}" 2>/dev/null; }

STUB_SAVE_TAR="$lay/save.tar" STUB_ROOTFS="$lay/rootfs" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a ship over layers the server holds succeeds (exit $rc: $err)"
ssh_cmds="$(grep -oF -e "'remote' 'layers'" -e "'remote' 'load'" "$SSH_LOG")"
assert '[ "$ssh_cmds" = "'"'"'remote'"'"' '"'"'layers'"'"'
'"'"'remote'"'"' '"'"'load'"'"'" ]' \
    "one remote layers question, then the one remote load (ssh log: $(cat "$SSH_LOG"))"
names="$(loaded_names)"
assert '! grep -qF "$hb" <<<"$names"' "the base layer the server has did not travel (loaded: $names)"
assert 'grep -qF "$ha" <<<"$names" && grep -qF "$hw" <<<"$names" && grep -qxF "manifest.json" <<<"$names"' \
    "the two app layers and the manifest did (loaded: $names)"
assert 'gzip -t "$SSH_STDIN_LOG" 2>/dev/null' "still as one complete gzip stream"
assert 'grep -qF "1 of 3 layers (200.0 kB) already on the server, not sent" <<<"$err"' \
    "and the run says what it left out (said '$err')"

# Under the containerd store a load whose layer is missing exits 0 and leaves
# the image unpacked: the far side says so, and the images go again, whole.
STUB_SAVE_TAR="$lay/save.tar" STUB_ROOTFS="$lay/rootfs" STUB_UNPACK_FAIL="$hb" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "an image the server cannot unpack on its own layers is re-sent whole (exit $rc: $err)"
assert '[ "$(grep -cF "'"'"'remote'"'"' '"'"'load'"'"'" "$SSH_LOG")" = "2" ]' \
    "in a second remote load (ssh log: $(cat "$SSH_LOG"))"
assert '! grep -qF "$hb" <<<"$(loaded_names "$LOADED.0")" && grep -qF "$hb" <<<"$(loaded_names "$LOADED.1")"' \
    "the first without the base layer, the second with it"
assert 'grep -qF "could not load the images on the layers it reported" <<<"$err" && grep -qF "sent whole, after " <<<"$err"' \
    "saying why, and what each stream sent (said '$err')"

# An overlay2 server that lost the layer since it answered: the load fails.
STUB_SAVE_TAR="$lay/save.tar" STUB_ROOTFS="$lay/rootfs" STUB_LOAD_FAIL="$hb" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a load that fails without the skipped layers is retried whole (exit $rc: $err)"
assert '[ "$(grep -cF "'"'"'remote'"'"' '"'"'load'"'"'" "$SSH_LOG")" = "2" ] && grep -qF "$hb" <<<"$(loaded_names)"' \
    "in a second remote load carrying every layer (ssh log: $(cat "$SSH_LOG"))"

# A containerd-store workstation saves compressed blobs, named by no diffID.
cp -r "$lay/rootfs" "$lay/rootfs-c"
zid() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
printf '["%s","%s"]\n' "$(zid b)" "$(zid a)" > "$lay/rootfs-c/built-app-web_1.4.2"
printf '["%s","%s"]\n' "$(zid b)" "$(zid w)" > "$lay/rootfs-c/built-app-worker_1.4.2"
printf '["%s"]\n' "$(zid b)" > "$lay/rootfs-c/srv-base"
STUB_SAVE_TAR="$lay/save.tar" STUB_ROOTFS="$lay/rootfs-c" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ] && grep -qF "$hb" <<<"$(loaded_names)"' "a save that names no layer by diffID ships whole (exit $rc: $err)"
assert 'grep -qF "saves compressed layers — nothing could be left out" <<<"$err" && ! grep -qF "already on the server, not sent" <<<"$err"' \
    "and says why nothing was left out, not that nothing was there (said '$err')"

# The same workstation that says so: one local export learns the names, the
# server records them from the stream, and the next push needs no export.
c="$tmpdir/csave"
mkdir -p "$c/tar/blobs/sha256" "$c/rootfs"
cblob() { local h; h="$(sha256sum "$1" | cut -d' ' -f1)"; mv "$1" "$c/tar/blobs/sha256/$h"; printf '%s' "$h"; }
head -c 200000 /dev/urandom | { printf '\037\213'; cat; } > "$c/b"; cb="$(cblob "$c/b")"
printf '\037\213web-app' > "$c/a"; ca="$(cblob "$c/a")"
printf '\037\213worker-app' > "$c/w"; cw="$(cblob "$c/w")"
printf '{"rootfs":{"type":"layers","diff_ids":["%s","%s"]}}' "$(zid b)" "$(zid a)" > "$c/cfg-web"; cfw="$(cblob "$c/cfg-web")"
printf '{"rootfs":{"type":"layers","diff_ids":["%s","%s"]}}' "$(zid b)" "$(zid w)" > "$c/cfg-worker"; cfk="$(cblob "$c/cfg-worker")"
printf '[{"Config":"blobs/sha256/%s","RepoTags":["built-app-web:1.4.2"],"Layers":["blobs/sha256/%s","blobs/sha256/%s"]},{"Config":"blobs/sha256/%s","RepoTags":["built-app-worker:1.4.2"],"Layers":["blobs/sha256/%s","blobs/sha256/%s"]}]' \
    "$cfw" "$cb" "$ca" "$cfk" "$cb" "$cw" > "$c/tar/manifest.json"
printf '{}' > "$c/tar/index.json"; printf '{"imageLayoutVersion":"1.0.0"}' > "$c/tar/oci-layout"
tar -C "$c/tar" -cf "$c/save.tar" blobs index.json manifest.json oci-layout
map="$FAKE_APPS/.kasbah/layers.map"
rm -f "$map"
cinfo='[["driver-type","io.containerd.snapshotter.v1"]]'

STUB_SAVE_TAR="$c/save.tar" STUB_ROOTFS="$lay/rootfs-c" STUB_INFO="$cinfo" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a containerd-store workstation ships (exit $rc: $err)"
assert 'grep -qxF "learning this workstation'"'"'s layer names: one extra local export, nothing sent" <<<"$err"' \
    "announcing one learning export (said '$err')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "2" ] && [ "$(grep -cF "'"'"'remote'"'"' '"'"'load'"'"'" "$SSH_LOG")" = "1" ]' \
    "which is a second local save, not a second stream (docker log: $(cat "$DOCKER_LOG"))"
names="$(loaded_names)"
assert '! grep -qF "$cb" <<<"$names" && grep -qF "$ca" <<<"$names" && grep -qF "$cw" <<<"$names"' \
    "the base layer stayed home under its compressed name (loaded: $names)"
assert 'grep -qF "1 of 3 layers (200.0 kB) already on the server, not sent" <<<"$err"' \
    "and the run says so (said '$err')"
mapc="$(cat "$map" 2>/dev/null)"
assert 'grep -qxF "sha256:$cb $(zid b)" <<<"$mapc" && grep -qxF "sha256:$ca $(zid a)" <<<"$mapc" && grep -qxF "sha256:$cw $(zid w)" <<<"$mapc" && [ "$(grep -c . <<<"$mapc")" = "3" ]' \
    "the server recorded every layer's name from the stream, the one left out included (map: $mapc)"
assert '[ "$(stat -c %a "$map" 2>/dev/null)" = "664" ]' "at mode 664 ($(stat -c %a "$map" 2>/dev/null))"

STUB_SAVE_TAR="$c/save.tar" STUB_ROOTFS="$lay/rootfs-c" STUB_INFO="$cinfo" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ] && [ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ] && ! grep -qF "learning" <<<"$err"' \
    "the next push learns nothing: the server named the layer (exit $rc, docker log: $(cat "$DOCKER_LOG"), said '$err')"
assert '! grep -qF "$cb" <<<"$(loaded_names)" && grep -qF "1 of 3 layers" <<<"$err"' \
    "and still leaves it out (said '$err')"
mapc="$(cat "$map" 2>/dev/null)"
assert '[ "$(grep -c . <<<"$mapc")" = "3" ]' \
    "the map holds the names the server recorded, once each (map: $mapc)"
# The stub server's images hold only the base: the question prunes the rest,
# and this push's load records them again.
STUB_ROOTFS="$lay/rootfs-c" PATH="$stub_dir:$PATH" DOCKER_LOG="$DOCKER_LOG" "$FAKE_APPS/.kasbah/bin/kasbah" remote layers "$FAKE_APPS" >/dev/null 2>"$tmpdir/layers.err"
assert '[ "$(cat "$map" 2>/dev/null)" = "sha256:$cb $(zid b)" ]' \
    "remote layers prunes the names of layers no image on the server holds (map: $(cat "$map" 2>/dev/null); $(cat "$tmpdir/layers.err"))"
printf 'not a map\n' > "$map"
STUB_SAVE_TAR="$c/save.tar" STUB_ROOTFS="$lay/rootfs-c" STUB_INFO="$cinfo" run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ] && [ "$(grep -c "^save " "$DOCKER_LOG")" = "2" ] && [ "$(grep -c . "$map")" = "3" ]' \
    "an unreadable map is started over, never fatal (exit $rc, map: $(cat "$map"))"
rm -f "$map"

# A base the containerd store keeps uncompressed is saved under its diffID:
# the server records that identity, and the next push needs no export.
u="$tmpdir/usave"
mkdir -p "$u/tar/blobs/sha256" "$u/rootfs"
head -c 100000 /dev/urandom | { printf 'base/'; cat; } > "$u/b"
ub="$(sha256sum "$u/b" | cut -d' ' -f1)"; mv "$u/b" "$u/tar/blobs/sha256/$ub"
cp "$c/tar/blobs/sha256/$ca" "$c/tar/blobs/sha256/$cw" "$u/tar/blobs/sha256/"
printf '{"rootfs":{"type":"layers","diff_ids":["sha256:%s","%s"]}}' "$ub" "$(zid a)" > "$u/cfg-web"
ufw="$(sha256sum "$u/cfg-web" | cut -d' ' -f1)"; mv "$u/cfg-web" "$u/tar/blobs/sha256/$ufw"
printf '{"rootfs":{"type":"layers","diff_ids":["sha256:%s","%s"]}}' "$ub" "$(zid w)" > "$u/cfg-worker"
ufk="$(sha256sum "$u/cfg-worker" | cut -d' ' -f1)"; mv "$u/cfg-worker" "$u/tar/blobs/sha256/$ufk"
printf '[{"Config":"blobs/sha256/%s","Layers":["blobs/sha256/%s","blobs/sha256/%s"]},{"Config":"blobs/sha256/%s","Layers":["blobs/sha256/%s","blobs/sha256/%s"]}]' \
    "$ufw" "$ub" "$ca" "$ufk" "$ub" "$cw" > "$u/tar/manifest.json"
printf '{}' > "$u/tar/index.json"
tar -C "$u/tar" -cf "$u/save.tar" blobs index.json manifest.json
printf '["sha256:%s","%s"]\n' "$ub" "$(zid a)" > "$u/rootfs/built-app-web_1.4.2"
printf '["sha256:%s","%s"]\n' "$ub" "$(zid w)" > "$u/rootfs/built-app-worker_1.4.2"
printf '["sha256:%s"]\n' "$ub" > "$u/rootfs/srv-base"
printf 'srv-base\n' > "$u/rootfs/ids"
for i in 1 2; do
    STUB_SAVE_TAR="$u/save.tar" STUB_ROOTFS="$u/rootfs" STUB_INFO="$cinfo" run "deploy@vps"; rc=$?
    assert '[ "$rc" = "0" ] && ! grep -qF "$ub" <<<"$(loaded_names)"' "push $i leaves the uncompressed base out (exit $rc: $err)"
    saves[i]="$(grep -c "^save " "$DOCKER_LOG")"
done
assert '[ "${saves[1]}" = "2" ] && [ "${saves[2]}" = "1" ]' \
    "the first push learns, the second needs no export: the map names the base by its diffID (saves ${saves[1]}, ${saves[2]}; map: $(cat "$map"))"
rm -f "$map"

STUB_SAVE_TAR="$lay/save.tar" STUB_ROOTFS="$lay/rootfs" STUB_SERVER_INSPECT_RC=1 run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a server that cannot list its layers still gets the images (exit $rc: $err)"
assert 'grep -qF "$hb" <<<"$(loaded_names)"' "every layer of them (loaded: $(loaded_names))"
assert 'grep -qF "which layers it holds" <<<"$err"' "with a note that nothing was skipped (said '$err')"

# Nothing below this line ships successfully, so the state file the run above
# wrote is cleared: what the failure cases assert is that none of them writes one.
rm -rf "$projdir/.kasbah"

# The load report is a protocol, not a courtesy: a step that answered nothing
# must not read as a successful load.
SSH_LOAD_OUT="" run "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "a remote step that reports no loaded= count is a failure (exit $rc)"
assert 'grep -qF "loaded=2" <<<"$err"' "naming what it wanted (said '$err')"

SSH_LOAD_OUT="loaded=1" run "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' \
    "and a count that does not match the images sent is a failure too (exit $rc)"

# --- A stream that breaks, from either end ---------------------------------------------------

DOCKER_LOAD_RC=1 run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "a docker load the server refuses fails the run (exit $rc)"
assert 'grep -qF "docker load exited 1" <<<"$err"' "the far side saying why (said '$err')"
assert 'grep -qF "could not load the images onto deploy@vps" <<<"$err"' "and this side which step (said '$err')"
assert '[ ! -e "$projdir/.kasbah/state.json" ]' \
    "and a run that failed records no server (docs/project-manifest.md: only on success)"

# A save that fails after writing part of its stream must not reach the server
# as a short but valid one: the gzip trailer is never written.
DOCKER_SAVE_RC=1 run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "a docker save that fails fails the run (exit $rc)"
assert 'grep -qF "docker save" <<<"$err" && grep -qF "failed" <<<"$err"' "naming docker save (said '$err')"
assert 'grep -qF "cut short" <<<"$err"' "while the far side abandoned the load (said '$err')"
assert '[ "$(stat -c %s "$SSH_STDIN_LOG")" -gt 1048576 ]' \
    "after part of the stream had really crossed (sent $(stat -c %s "$SSH_STDIN_LOG") bytes)"
assert '! gzip -t "$SSH_STDIN_LOG" 2>/dev/null' "because what it was sent is not a complete gzip stream"
assert '! grep -qxF "image inspect built-app-web:1.4.2" "$DOCKER_LOG"' \
    "and it got no further than the load (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -e "$projdir/.kasbah/state.json" ]' "recording no server"

SSH_TRUNCATE=12 run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "a connection that drops mid-stream fails the run (exit $rc)"
assert 'grep -qF "cut short" <<<"$err"' "the far side refusing the partial stream (said '$err')"
assert '[ ! -e "$projdir/.kasbah/state.json" ]' "recording no server"

# --- A server kasbah cannot reach, or never prepared ------------------------------------------

SSH_RC=255 run "deploy@vps"; rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server is exit 3, as docs/cli.md has it (exit $rc: $err)"
assert '[ ! -s "$DOCKER_LOG" ]' \
    "and nothing was built or saved before the connection was proved (log: $(cat "$DOCKER_LOG"))"

FAKE_NO_MARKER=1 run "deploy@vps"; rc=$?
assert '[ "$rc" = "4" ]' "a server with no marker is exit 4 — the load runs in a binary under <apps> (exit $rc: $err)"
assert 'grep -qF "server.json" <<<"$err"' "naming the marker it looked for (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "before anything was built or saved (log: $(cat "$DOCKER_LOG"))"

# --- The git tag -----------------------------------------------------------------------------
# A bare repository two directories away plays origin. Nothing here can reach a
# network, and the assertion is what actually landed in it: nothing, ever.

origin="$tmpdir/origin.git"
git init -q --bare "$origin" >/dev/null 2>&1
projdir="$(make gitpush built-app v3.1.0 nightly)"
( cd "$projdir" && git remote add origin "$origin" ) || exit 2

origin_tags() { git --git-dir="$origin" tag | tr '\n' ' '; }
notice="git:     v3.1.0 is not on origin — the server runs a version origin cannot fetch; publish it:  git push origin v3.1.0"

run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a ship with an origin succeeds (exit $rc: $err)"
assert '[ "$(origin_tags)" = "" ]' \
    "and writes nothing to origin — kasbah never pushes a tag (origin has: '$(origin_tags)')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' "the images went (log: $(cat "$DOCKER_LOG"))"

# The `git:` line is an indented continuation of the `Shipped …` headline, so it
# has to come after it — the order `kasbah deploy` and `kasbah server init` both
# print theirs in. Read by line number off the one stream every info() goes to.
n_head="$(grep -n -m1 -F "Shipped built-app 3.1.0 to deploy@vps" <<<"$err" | cut -d: -f1)"
n_git="$(grep -n -m1 -F "  git:" <<<"$err" | cut -d: -f1)"
assert '[ -n "$n_head" ] && [ -n "$n_git" ]' \
    "the run prints both a headline and a git: line (said '$err')"
assert '[ "$n_head" -lt "$n_git" ]' \
    "and the headline comes first, with the git: line indented under it
        (headline on line $n_head, git: on line $n_git)
        said: $err"
assert 'grep -qF "$notice" <<<"$err"' \
    "which says origin cannot hand out the version and how to publish it (said '$err')"
assert '[ "$(grep -c "git:" <<<"$err")" = "1" ]' "in exactly one line (said '$err')"

# A tag origin has already is not worth a line.
( cd "$projdir" && git push -q origin refs/tags/v3.1.0 ) >/dev/null 2>&1
assert '[ "$(origin_tags)" = "v3.1.0 " ]' "origin now has v3.1.0 — else the case below proves nothing"
run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "shipping a version origin has succeeds (exit $rc: $err)"
assert '! grep -qF "git:" <<<"$err"' "and says nothing about the tag (said '$err')"

# --build-only ships nothing, so there is no server version to speak of.
git --git-dir="$origin" tag -d v3.1.0 >/dev/null 2>&1
run --build-only; rc=$?
assert '[ "$rc" = "0" ]' "--build-only succeeds with an origin present (exit $rc: $err)"
assert '[ "$(origin_tags)" = "" ] && ! grep -qF "git:" <<<"$err"' \
    "pushes nothing and says nothing about origin (origin has: '$(origin_tags)', said '$err')"

# An origin that cannot be asked is one line too, and never fails the ship.
( cd "$projdir" && git remote set-url origin "$tmpdir/gone.git" ) || exit 2
run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a ship whose origin cannot be reached still exits 0 (exit $rc: $err)"
assert 'grep -qF "git:     could not ask origin whether it has v3.1.0, so that went unchecked" <<<"$err"' \
    "saying the tag went unchecked (said '$err')"
assert '[ "$(grep -c "git:" <<<"$err")" = "1" ]' "in exactly one line (said '$err')"

# No origin at all: nothing to say.
projdir="$(make noorigin built-app v3.1.0)"
run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a repository with no origin exits 0 (exit $rc: $err)"
assert '! grep -qF "origin" <<<"$err"' "and says nothing about origin (said '$err')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' "and the images did ship (log: $(cat "$DOCKER_LOG"))"

# --- An untagged HEAD is tagged first -------------------------------------------------------
# HEAD one commit past v3.1.0: --bump=minor makes it v3.2.0, which is what the
# images carry; the tag stays local.

bump_origin="$tmpdir/bump-origin.git"
git init -q --bare "$bump_origin" >/dev/null 2>&1
projdir="$(make bumped built-app v3.1.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix && git remote add origin "$bump_origin" ) >/dev/null 2>&1 || exit 2
head_tags() { (cd "$projdir" && git tag --points-at HEAD | tr '\n' ' '); }

run --bump=minor "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "an untagged HEAD with --bump=minor ships (exit $rc: $err)"
assert '[ "$(head_tags)" = "v3.2.0 " ]' "having tagged HEAD v3.2.0 (HEAD has: '$(head_tags)')"
assert 'grep -qF "Tagged HEAD v3.2.0" <<<"$err"' "and said so (said '$err')"
assert 'grep -qF "Shipped built-app 3.2.0 to deploy@vps" <<<"$err"' "under that version (said '$err')"
assert 'grep -qF ":3.2.0" "$DOCKER_LOG"' "which is the images' tag (log: $(cat "$DOCKER_LOG"))"
assert '[ -z "$(git --git-dir="$bump_origin" tag)" ]' \
    "and the tag stays off origin (origin has: '$(git --git-dir="$bump_origin" tag | tr '\n' ' ')')"
assert 'grep -qF "git push origin v3.2.0" <<<"$err"' "which the run points out (said '$err')"

# A server that cannot be reached: the tag was already cut, and stays — local.
projdir="$(make bumpfail built-app v3.1.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix ) >/dev/null 2>&1 || exit 2
SSH_RC=255 run --bump=patch "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "an unreachable server still fails the run (exit $rc)"
assert '[ "$(head_tags)" = "v3.1.1 " ]' "and leaves HEAD tagged for the next run (HEAD has: '$(head_tags)')"
assert 'grep -qF "the tag stays" <<<"$err"' "as the run said it would (said '$err')"

# A computed tag that exists elsewhere is refused before anything happens.
projdir="$(make bumptaken built-app v3.1.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix && git tag v3.1.1 "$(git commit-tree "HEAD^{tree}" -m side)" ) >/dev/null 2>&1 || exit 2
run --bump=patch "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "a bump onto a tag that exists is refused (exit $rc)"
assert 'grep -qF "v3.1.1 already exists" <<<"$err"' "naming it (said '$err')"
assert '[ -z "$(head_tags)" ]' "tagging nothing (HEAD has: '$(head_tags)')"
assert '[ ! -s "$DOCKER_LOG" ] && [ ! -s "$SSH_LOG" ]' "building and reaching nothing"

# --build-only tags too: the images it builds carry the version.
projdir="$(make bumplocal built-app v3.1.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix ) >/dev/null 2>&1 || exit 2
run --build-only --bump=major; rc=$?
assert '[ "$rc" = "0" ]' "--build-only --bump=major builds (exit $rc: $err)"
assert '[ "$(head_tags)" = "v4.0.0 " ]' "having tagged HEAD v4.0.0 (HEAD has: '$(head_tags)')"
assert 'grep -qF ":4.0.0" "$DOCKER_LOG" && [ ! -s "$SSH_LOG" ]' "tagging the images so, and shipping nothing"

# A project that builds nothing has nothing to release: asked, but not tagged.
projdir="$(make bumpstock demo v2.0.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix ) >/dev/null 2>&1 || exit 2
run --bump=patch "user@somewhere"; rc=$?
assert '[ "$rc" = "0" ]' "a stock-only project with --bump exits 0 (exit $rc: $err)"
assert 'grep -qF "HEAD was not tagged v2.0.1" <<<"$err"' "saying it tagged nothing (said '$err')"
assert '[ -z "$(head_tags)" ] && [ ! -s "$DOCKER_LOG" ] && [ ! -s "$SSH_LOG" ]' "and tagging, building and reaching nothing"

# A tag that is not a v-tag is warned about, --bump or not.
projdir="$(make bumpplain built-app release-7)"
run --build-only --bump=patch; rc=$?
assert '[ "$rc" = "0" ]' "a HEAD tagged release-7 is bumped from 0.0.0 (exit $rc: $err)"
assert 'grep -qF "HEAD is tagged release-7" <<<"$err"' "with a warning naming the tag (said '$err')"
assert '[ "$(head_tags)" = "release-7 v0.0.1 " ]' "and HEAD gains v0.0.1 (HEAD has: '$(head_tags)')"

# Untagged and dirty: commit first.
projdir="$(make bumpdirty built-app v3.1.0)"
( cd "$projdir" && git commit -q --allow-empty -m fix && echo x > scratch ) >/dev/null 2>&1 || exit 2
run --bump=patch "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "an untagged, dirty HEAD is refused (exit $rc)"
assert 'grep -qF "commit first" <<<"$err"' "saying commit first (said '$err')"
assert '[ -z "$(head_tags)" ] && [ ! -s "$DOCKER_LOG" ]' "tagging and building nothing"

# --- The command line -------------------------------------------------------------------------

projdir="$built"
run --nope; rc=$?
assert '[ "$rc" = "1" ]' "an unknown flag is refused (exit $rc)"
assert 'grep -qF "unknown flag" <<<"$err"' "by name (said '$err')"
assert 'grep -qF -- "--nope" <<<"$err"' "quoting it (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "before anything runs (log: $(cat "$DOCKER_LOG"))"

# kasbah writes to no git remote, so there is no push to opt out of.
run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "unknown flag '"'"'--no-git-push'"'"'" <<<"$err"' \
    "--no-git-push is an unknown flag (exit $rc: $err)"

# A boolean flag handed a value is its own mistake, refused by name rather than
# as an unknown flag — the mirror image of the branch deploy has for --on-drift
# without one.
for pair in --build-only=yes --dirty=1; do
    run "$pair"; rc=$?
    assert '[ "$rc" = "1" ]' "'$pair' is refused (exit $rc)"
    assert 'grep -qF "takes no value" <<<"$err"' "for taking no value (said '$err')"
    assert 'grep -qF -- "${pair%%=*}" <<<"$err"' "naming the flag without its value (said '$err')"
    assert '! grep -qF "unknown flag" <<<"$err"' \
        "and not as an unknown flag, which is a different mistake (said '$err')"
    assert '[ ! -s "$DOCKER_LOG" ]' "before anything runs (log: $(cat "$DOCKER_LOG"))"
done

run "deploy@vps" 1.4.2; rc=$?
assert '[ "$rc" = "1" ]' "a second positional argument is refused (exit $rc)"
assert 'grep -qF "HEAD" <<<"$err"' "saying where the version comes from (said '$err')"

run --help; rc=$?
assert '[ "$rc" = "0" ]' "--help exits 0 (exit $rc)"
assert 'grep -qF "build-only" <<<"$out"' "and documents its flags (said '$out')"
# The distinction docs/cli.md draws and this command's own summary once lost:
# build-push runs `compose build` and never `compose up`.
assert 'grep -qF "does not run \`compose up\`" <<<"$out"' \
    "and says which half of compose it leaves to deploy (said '$out')"

# --- Not a kasbah project ------------------------------------------------------------------------

projdir="$tmpdir/notaproject"
mkdir -p "$projdir"
run; rc=$?
assert '[ "$rc" = "2" ]' "a directory with no kasbah.yml is exit 2 (exit $rc: $err)"

# --- No compose file ----------------------------------------------------------------------------
# The project shape is derived from compose, so a project without one has no
# shape to derive.

projdir="$(make nocompose built-app v1.4.2)"
rm -f "$projdir/compose.prod.yml"
recommit v1.4.2
run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a project with no compose.prod.yml fails (exit $rc)"
assert 'grep -qF "compose.prod.yml: not found" <<<"$err"' \
    "saying that file is missing rather than that it will not parse (said '$err')"

# --- No server, and none remembered ------------------------------------------------------------

projdir="$(make noserver built-app v1.4.2)"
run; rc=$?
assert '[ "$rc" = "1" ]' "a project that has never shipped and names no server fails (exit $rc)"
assert 'grep -qF "never talked to one" <<<"$err"' "saying so (said '$err')"
assert 'grep -qF -- "--build-only" <<<"$err"' \
    "and naming the mode that needs no server (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' \
    "asked before the build, not after it (log: $(cat "$DOCKER_LOG"))"

# The other half: the remembered server is used when none is given.
projdir="$(make remembered built-app v1.4.2)"
mkdir -p "$projdir/.kasbah"
printf '{"last_server":"stored@vps"}\n' > "$projdir/.kasbah/state.json"
run; rc=$?
assert '[ "$rc" = "0" ]' "a project with a last_server ships without being told (exit $rc: $err)"
assert 'grep -qF "stored@vps" <<<"$(grep -F "'"'"'remote'"'"' '"'"'load'"'"'" "$SSH_LOG")"' \
    "to that server (ssh log: $(cat "$SSH_LOG"))"

# --- A build that fails ---------------------------------------------------------------------------

projdir="$built"
DOCKER_RC=1 run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a failing docker compose build fails the run (exit $rc)"
assert 'grep -qF "build failed" <<<"$err"' "saying which step (said '$err')"

# --- Images are built for the server's platform -----------------------------------------------------
# The probe's uname -m is this machine's here; the engine the stub plays is
# the other arch, as a Mac on arm64 shipping to an amd64 VPS is.

case "$(uname -m)" in
    x86_64) srv_arch=amd64 other=arm64 ;;
    *) srv_arch=arm64 other=amd64 ;;
esac
projdir="$(make platform built-app v1.4.2)"
STUB_ENGINE="linux/$other" run "deploy@vps"; rc=$?
plat="$(cat "$DOCKER_LOG.platform")"
assert '[ "$rc" = "0" ]' "a server of another arch than the engine ships (exit $rc: $err)"
assert '[ "$plat" = "linux/$srv_arch" ]' "the build is asked for the server's platform, linux/$srv_arch (got: $plat)"
assert 'grep -qF "building for linux/$srv_arch, the platform of deploy@vps — this docker engine is linux/$other" <<<"$err"' \
    "and says so, naming both (said '$err')"

STUB_ENGINE="linux/$srv_arch" run "deploy@vps"; rc=$?
plat="$(cat "$DOCKER_LOG.platform")"
assert '[ "$rc" = "0" ] && [ "$plat" = "linux/$srv_arch" ]' "an engine of the server's own platform builds for it too (exit $rc, got: $plat)"
assert '! grep -qF "building for" <<<"$err"' "without a word about it (said '$err')"

STUB_ENGINE="linux/$other" DOCKER_DEFAULT_PLATFORM="linux/$other" run "deploy@vps"; rc=$?
plat="$(cat "$DOCKER_LOG.platform")"
assert '[ "$rc" = "0" ] && [ "$plat" = "linux/$srv_arch" ]' "a DOCKER_DEFAULT_PLATFORM of another arch is overridden (exit $rc, got: $plat)"
assert 'grep -qF "DOCKER_DEFAULT_PLATFORM=linux/$other is overridden" <<<"$err"' "and that is said (said '$err')"

STUB_ENGINE="linux/$other" DOCKER_RC=1 run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "needs emulation" <<<"$err" && grep -qF "tonistiigi/binfmt --install $srv_arch" <<<"$err"' \
    "a cross build that fails points at emulation (exit $rc, said '$err')"

STUB_ENGINE="linux/$other" STUB_COMPOSE_ERR="service \"web\" build.platforms does not support value set by DOCKER_DEFAULT_PLATFORM: linux/$srv_arch" \
    run "deploy@vps"; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "build.platforms must include linux/$srv_arch" <<<"$err" && ! grep -qF "emulation" <<<"$err"' \
    "compose refusing the platform for build.platforms says so, not emulation (exit $rc, said '$err')"

# A service pinned to another platform builds an image the server cannot run.
sed -i "s|^    image: built-app-web:current|&\n    platform: linux/$other|" "$projdir/compose.prod.yml"
recommit v1.4.2
STUB_ENGINE="linux/$srv_arch" run "deploy@vps"; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "service '"'"'built-app-web'"'"' sets platform: linux/$other, and deploy@vps is linux/$srv_arch" <<<"$err"' \
    "a service platform: other than the server's is warned about (exit $rc, said '$err')"
assert '! grep -qF "service '"'"'worker'"'"' sets platform" <<<"$err"' "and only that service (said '$err')"

STUB_ENGINE="linux/$other" run --build-only; rc=$?
plat="$(cat "$DOCKER_LOG.platform")"
assert '[ "$rc" = "0" ] && [ "$plat" = unset ]' "--build-only, with no server, sets no platform: the engine's own (exit $rc, got: $plat)"
DOCKER_DEFAULT_PLATFORM="linux/$other" run --build-only; rc=$?
plat="$(cat "$DOCKER_LOG.platform")"
assert '[ "$rc" = "0" ] && [ "$plat" = "linux/$other" ]' "or the one DOCKER_DEFAULT_PLATFORM names (exit $rc, got: $plat)"

# --- A working tree that is not HEAD's -------------------------------------------------------------
# Without --dirty it is refused before anything is built; with it, it ships
# under <base>-dirty.<UTC time>, has no tag, and leaves deploy --dirty the
# label, the server and the tree it built.

projdir="$(make dirty built-app v1.4.2)"
dirty_origin="$tmpdir/dirty-origin.git"
git init -q --bare "$dirty_origin" >/dev/null 2>&1
( cd "$projdir" && git remote add origin "$dirty_origin" ) || exit 2
printf 'scratch\n' > "$projdir/notes.txt"
run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "an untracked file refuses the build-push (exit $rc: $err)"
assert 'grep -qF "?? notes.txt" <<<"$err"' "naming the file (said '$err')"
assert 'grep -qF "kasbah build-push --dirty" <<<"$err"' "and the flag that ships it anyway (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ] && [ ! -s "$SSH_LOG" ]' \
    "before a build or a connection (docker: $(cat "$DOCKER_LOG"), ssh: $(cat "$SSH_LOG"))"

rm -f "$projdir/notes.txt"
printf '# edited\n' >> "$projdir/compose.prod.yml"
run "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ]' "a tracked change refuses it too (exit $rc: $err)"
assert 'grep -qF " M compose.prod.yml" <<<"$err"' "naming the file (said '$err')"

mkdir -p "$projdir/.kasbah"
printf '{}\n' > "$projdir/.kasbah/state.json"
printf 'ignored\n' >> "$projdir/.gitignore"
printf 'x\n' > "$projdir/ignored"
run --dirty "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "--dirty ships it (exit $rc: $err)"
label="$(sed -n 's/^tag built-app-web:current built-app-web:\(.*\)$/\1/p' "$DOCKER_LOG")"
assert 'grep -qxE "1\.4\.2-dirty\.20[0-9]{12}" <<<"$label"' \
    "tagged <base>-dirty.<UTC yyyymmddhhmmss> (log: $(cat "$DOCKER_LOG"))"
assert 'grep -qF "built-app-web:$label" <<<"$(grep -F "'"'"'remote'"'"' '"'"'load'"'"'" "$SSH_LOG")"' \
    "and loaded on the server under it (ssh log: $(cat "$SSH_LOG"))"
assert 'grep -qF "Shipped built-app $label to deploy@vps" <<<"$err"' "reporting the label (said '$err')"
assert '[ -z "$(git --git-dir="$dirty_origin" tag)" ]' "pushing no tag (origin has: '$(git --git-dir="$dirty_origin" tag)')"
assert '! grep -qF "git:" <<<"$err"' "and saying nothing of origin — a dirty build has no tag (said '$err')"
state="$(cat "$projdir/.kasbah/state.json" 2>/dev/null)"
assert '[ "$(jq -r .dirty_build <<<"$state")" = "$label" ] && [ "$(jq -r .dirty_server <<<"$state")" = "deploy@vps" ]' \
    "recording the label and the server for deploy --dirty (state: $state)"
assert 'grep -qxE "[0-9a-f]{64}" <<<"$(jq -r .dirty_tree <<<"$state")"' \
    "and the working tree it built (state: $state)"

# A tree edited during the build ships images that match neither state: not recorded.
DOCKER_BUILD_TOUCH="$projdir/during.txt" run --dirty "deploy@vps"; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "the working tree changed while" <<<"$err"' \
    "a tree edited during the build is refused (exit $rc: $err)"
assert '[ "$(cat "$projdir/.kasbah/state.json" 2>/dev/null)" = "$state" ]' \
    "and the label of the build before stays the recorded one (state: $(cat "$projdir/.kasbah/state.json"))"
rm -f "$projdir/during.txt"

# Paths git is told not to read are refused, --dirty included.
( cd "$projdir" && git update-index --assume-unchanged compose.prod.yml ) || exit 2
run --dirty --build-only; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "kasbah cannot see what is on disk for these" <<<"$err" && grep -qF "  compose.prod.yml" <<<"$err"' \
    "an assume-unchanged path refuses even --dirty, naming it (exit $rc: $err)"
( cd "$projdir" && git update-index --no-assume-unchanged compose.prod.yml ) || exit 2

# With nothing to change, --dirty is still a test build; an untagged HEAD's base
# is the highest tag it reaches.
recommit v1.4.2
( cd "$projdir" && HOME="$fakehome" git commit -q --allow-empty -m untagged ) || exit 2
run --dirty --build-only; rc=$?
assert '[ "$rc" = "0" ]' "--dirty on a clean, untagged HEAD builds (exit $rc: $err)"
assert 'grep -qE "^tag built-app-web:current built-app-web:1\.4\.2-dirty\.[0-9]{14}$" "$DOCKER_LOG"' \
    "labelled from the reachable v1.4.2 (log: $(cat "$DOCKER_LOG"))"

# --- The fence around fixture_repo_make's rm -rf ---------------------------------------------------
# It opens with `rm -rf` on a path its caller chose, so the guard is pinned in
# both directions the way tests/integration/rig_env.sh pins its own destructive
# payload.

for bad in "" "relative/path" "$HOME/kasbah-fixture-should-refuse" "/tmp" "$repo_dir" "$repo_dir/tests/fixtures/probe"; do
    _fixture_repo_check_dest "$bad" 2>/dev/null; rc=$?
    assert '[ "$rc" != "0" ]' \
        "fixture_repo_make refuses '${bad:-<empty>}' as a destination (rc $rc)"
done
_fixture_repo_check_dest "$tmpdir/somewhere"; rc=$?
assert '[ "$rc" = "0" ]' \
    "and accepts one under the suite's own temp directory (rc $rc) — else the refusals prove nothing"

# The checkout fence on its own. Under a checkout that lives in /tmp the temp-root
# check passes, so this is the only thing left standing between the guard and the
# fixtures the function is about to copy *from*. A copy of the file two
# directories deep is enough to move _FIXTURE_REPO_CHECKOUT there.
probe="$tmpdir/fence-probe"
mkdir -p "$probe/tests/fixtures"
cp "$repo_dir/tests/fixture_repo.sh" "$probe/tests/fixture_repo.sh"
fence() {
    bash -c '. "$1/tests/fixture_repo.sh"; _fixture_repo_check_dest "$2" && echo ACCEPTED || echo refused' \
        _ "$probe" "$1" 2>/dev/null
}
assert '[ "$(fence "$probe/tests/fixtures/probe")" = "refused" ]' \
    "a path inside a checkout is refused even when the checkout is under /tmp (said '$(fence "$probe/tests/fixtures/probe")')"
assert '[ "$(fence "$probe")" = "refused" ]' \
    "and so is the checkout itself, which the parent test cannot see (said '$(fence "$probe")')"
assert '[ "$(fence "$tmpdir/elsewhere")" = "ACCEPTED" ]' \
    "while a sibling path under the same temp root is still accepted (said '$(fence "$tmpdir/elsewhere")')"
assert '[ -f "$probe/tests/fixture_repo.sh" ]' "and nothing under the probe checkout was removed"

# --- The fixture stays a project kasbah accepts ----------------------------------------------------
# tests/fixtures/built-app is what the rest of this phase drives end to end, so
# it has to keep passing the compliance check: a fixture that quietly stopped
# would take its own failures into the deploy tests instead of finding them here.

check_out="$(cd "$built" && env HOME="$fakehome" "$KASBAH_BIN" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "kasbah check passes on the built-app fixture (exit $rc)"
assert 'grep -qF ", 0 failed" <<<"$check_out"' \
    "with no failed rule (said '$(tail -1 <<<"$check_out")')"

exit "$fail"
