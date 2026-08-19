#!/usr/bin/env bash
# Test: lib/build_push.sh — everything about `kasbah build-push` that does not
# need a server, a registry or a Docker daemon.
#
# Hermetic. `docker`, `ssh` and `rsync` are stubs on PATH that record every
# invocation and answer as told, so what a case asserts is what kasbah asked
# for. git is real, against throwaway repositories under a temp directory —
# including the `origin` the push cases use, which is a bare repo two
# directories away and never a network.
#
# The stub logs are read both ways: a case asserts what was asked for, and the
# cases about refusals assert the logs are *empty*, which is only evidence when
# something else in the same run proves the stubs are really being used
# (docs/phases/02-spine.md — a "hermetic" block with no stub on PATH once passed
# on a DNS lookup failing).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
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

cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
# `save` writes the image stream to stdout; something has to come out of it or
# the tarball the caller gzips into is empty, which is not what a real save does.
case "${1:-}" in
    save) printf 'fake-image-stream\n' ;;
esac
exit "${DOCKER_RC:-0}"
STUB

# Only the script form is fed anything: `ssh -n` (the probe, ssh_run) closes
# stdin, and draining it unconditionally would hang the suite when stdin is a
# terminal (tests/integration/rig_env.sh records the same hazard from the other
# side).
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
# ssh_run/ssh_script quote every word, so the script form arrives as 'bash' '-s'.
if [[ "$*" == *"'bash' '-s'"* ]]; then
    cat >> "$SSH_STDIN_LOG"
    # The payload reports how many images it was handed, so this answers the
    # same way: re-split the quoted command the way the remote login shell
    # would, drop `bash -s -- <tarball>`, and count what is left. A constant
    # here would be right by accident for a one-image project.
    cmd="${!#}"
    eval "set -- $cmd"
    shift 4 2>/dev/null || set --
    printf '%s\n' "${SSH_SCRIPT_OUT-loaded=$#}"
    exit "${SSH_SCRIPT_RC:-0}"
fi
exit "${SSH_RC:-0}"
STUB

# The source is rsync's second-to-last argument. Kept, because the tarball is
# removed from both ends by the time the command returns and the only way to look
# inside what travelled is to catch it in flight.
cat > "$stub_dir/rsync" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_LOG"
[ -z "${RSYNC_COPY:-}" ] || cp "${@:$#-1:1}" "$RSYNC_COPY"
exit "${RSYNC_RC:-0}"
STUB

chmod 0755 "$stub_dir/docker" "$stub_dir/ssh" "$stub_dir/rsync"

# git is real, so it must not read the developer's own configuration: a global
# commit.gpgsign or a push default is not this suite's to inherit.
printf '[user]\n\temail = build-push-test@kasbah.test\n\tname = kasbah build-push test\n' \
    > "$fakehome/.gitconfig"

# --- Running the command ---------------------------------------------------------

projdir=""
out=""
err=""

reset_logs() {
    : > "$DOCKER_LOG"
    : > "$SSH_LOG"
    : > "$SSH_STDIN_LOG"
    : > "$RSYNC_LOG"
    rm -rf "$scratch"
    mkdir -p "$scratch"
}

# TMPDIR is the suite's own, so "did it leave a tarball behind" is a question
# about a directory nothing else writes to.
bp() (
    cd "$projdir" || exit 2
    env PATH="$stub_dir:$PATH" HOME="$fakehome" TMPDIR="$scratch" \
        DOCKER_LOG="$DOCKER_LOG" SSH_LOG="$SSH_LOG" SSH_STDIN_LOG="$SSH_STDIN_LOG" \
        RSYNC_LOG="$RSYNC_LOG" RSYNC_COPY="$tmpdir/travelled" \
        "$repo_dir/bin/kasbah" build-push "$@" </dev/null
)

run() {
    reset_logs
    out="$(bp "$@" 2>"$tmpdir/err")"; rc=$?
    err="$(cat "$tmpdir/err")"
    return "$rc"
}

tarballs() { find "$scratch" -name '*.tar.gz' 2>/dev/null; }

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

if ! command -v git >/dev/null || ! command -v yq >/dev/null || ! command -v jq >/dev/null; then
    echo "error: this suite needs git, yq and jq on PATH" >&2
    exit 2
fi

built="$(make built built-app v1.4.2)"
stock="$(make stock demo v2.0.0)"

# --- The version comes from HEAD's single v-tag -------------------------------------
# Every one of these must stop before anything is built: the version labels the
# images, so a build without one produces images kasbah cannot name.

projdir="$(make untagged built-app)"
run; rc=$?
assert '[ "$rc" = "1" ]' "an untagged HEAD is a failure (exit $rc)"
assert 'grep -qF "no version tag" <<<"$err"' "saying HEAD carries no version (said '$err')"
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
# filesystem and on the stub logs rather than on what it printed — "no tarball
# was created" is a fact about a directory.

projdir="$stock"
run "user@somewhere"; rc=$?
assert '[ "$rc" = "0" ]' "a stock-only project exits 0 (exit $rc: $err)"
assert 'grep -qF "builds nothing" <<<"$out$err"' "saying so (said '$out$err')"
assert '[ -z "$(tarballs)" ]' "and creates no tarball (found: $(tarballs))"
assert '[ ! -s "$DOCKER_LOG" ]' "runs no docker at all (log: $(cat "$DOCKER_LOG"))"
assert '[ ! -s "$SSH_LOG" ]' "and never opens a connection (ssh log: $(cat "$SSH_LOG"))"
assert '[ ! -e "$stock/.kasbah/state.json" ]' \
    "a run that shipped nothing records no last_server either"

# --- A built service must name its image ---------------------------------------------

projdir="$(make noimage built-app v1.4.2)"
sed -i '/^    image: built-app-web:current$/d' "$projdir/compose.prod.yml"
assert '! grep -q "image: built-app-web" "$projdir/compose.prod.yml"' \
    "the compose file really has lost its image: key — else the case below proves nothing"
run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a build: service with no image: is refused (exit $rc)"
assert 'grep -qF "service '"'"'web'"'"'" <<<"$err"' "naming the service (said '$err')"
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
  web:
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
assert 'grep -qU $'"'"'\r'"'"' "$projdir/compose.prod.yml"' \
    "the compose file really is CRLF now — else the case below proves nothing"
run --build-only; rc=$?
assert '[ "$rc" = "0" ]' "a CRLF compose file is read (exit $rc: $err)"
assert 'grep -qxF "tag built-app-web:current built-app-web:1.4.2" "$DOCKER_LOG"' \
    "with no carriage return anywhere in the tag (log: $(cat -v "$DOCKER_LOG"))"
sed -i 's/\r$//' "$projdir/compose.prod.yml"

# --- --build-only stops after the tag ---------------------------------------------------

assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "0" ]' \
    "--build-only saves nothing (log: $(cat "$DOCKER_LOG"))"
assert '[ -z "$(tarballs)" ]' "writes no tarball (found: $(tarballs))"
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
# range (docs/phases/01-rig.md).

calls="$(compose_calls)"
assert '[ -n "$calls" ]' "build-push runs docker compose at all (log: $(cat "$DOCKER_LOG"))"
bad=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "-p built-app " <<<"$line " || bad="$bad|$line"
done <<<"$calls"
assert '[ -z "$bad" ]' "every compose call names the project with -p (offenders: $bad)"

# --- One docker save, carrying every image ------------------------------------------------
# Per-image tarballs throw away the layer dedup save gives you inside one.

projdir="$(make ship built-app v1.4.2)"
cat > "$projdir/compose.prod.yml" <<'COMPOSE'
name: built-app
services:
  web:
    build: .
    image: built-app-web:current
  worker:
    build: .
    image: built-app-worker:current
  cache:
    image: redis:7-alpine
COMPOSE

run --no-git-push "deploy@vps"; rc=$?
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

rsyncline="$(cat "$RSYNC_LOG")"
assert '[ "$(wc -l < "$RSYNC_LOG")" = "1" ]' "one transfer, not one per image (rsync log: '$rsyncline')"
assert 'grep -qF "deploy@vps:/tmp/built-app-1.4.2.tar.gz" <<<"$rsyncline"' \
    "the tarball goes to the server's /tmp under project and version (rsync: '$rsyncline')"
assert 'grep -qF "$scratch/built-app-1.4.2.tar.gz" <<<"$rsyncline"' \
    "from the same name locally (rsync: '$rsyncline')"
# -s, so the far side never re-splits the path it is given: without it rsync
# hands the destination to a remote shell, which reads a space as an argument
# boundary.
assert 'grep -qF -- " -s " <<<"$rsyncline "' \
    "with the remote path protected from a second round of word splitting (rsync: '$rsyncline')"
assert 'gzip -t "$tmpdir/travelled" 2>/dev/null' \
    "and what travels is a gzip stream, not a bare tar ($(file -b "$tmpdir/travelled" 2>/dev/null))"
assert '[ -z "$(tarballs)" ]' "and is gone from here when the run ends (found: $(tarballs))"

# The shape of the payload, and only its shape: the ssh stub records the script
# it was fed and never runs it, so a line that is present but disabled reads the
# same here. That these three steps actually happen is proved on the rig, by
# tests/integration/ship_test.sh — the image is inspected there, and the rig's
# own /tmp is checked for what the load step was supposed to remove.
payload="$(cat "$SSH_STDIN_LOG")"
assert 'grep -qF "docker load" <<<"$payload"' "the remote step is written to load the tarball"
assert 'grep -qF "rm -f" <<<"$payload"' "and to remove it there itself"
assert 'grep -qF "docker image inspect" <<<"$payload"' \
    "and to ask the daemon the images are really there"
assert '[ "$(jq -r .last_server "$projdir/.kasbah/state.json" 2>/dev/null)" = "deploy@vps" ]' \
    "a successful ship records last_server (state: $(cat "$projdir/.kasbah/state.json" 2>/dev/null))"
# lib/ssh.sh chains its teardown onto the EXIT trap that is already installed,
# and `trap … EXIT` is last-writer-wins — so a command that installs its own
# trap *after* connecting silently drops the master teardown and leaves its
# private socket directory behind. That directory is under this suite's TMPDIR.
assert '[ -z "$(find "$scratch" -maxdepth 1 -name "kasbah-ssh.*" 2>/dev/null)" ]' \
    "the ssh master's private directory is gone, so this command's cleanup did not
     replace lib/ssh.sh's (found: $(find "$scratch" -maxdepth 1 -name "kasbah-ssh.*" 2>/dev/null))"
assert '! grep -qF "'"'"'rm'"'"'" "$SSH_LOG"' \
    "and the cleanup never has to reach for the server, because the load step
     removed the tarball itself (ssh log: $(cat "$SSH_LOG"))"

# Nothing below this line ships successfully, so the state file the run above
# wrote is cleared: what the failure cases assert is that none of them writes one.
rm -rf "$projdir/.kasbah"

# The load report is a protocol, not a courtesy: a step that answered nothing
# must not read as a successful load.
SSH_SCRIPT_OUT="" run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "a remote step that reports no loaded= count is a failure (exit $rc)"
assert 'grep -qF "loaded=2" <<<"$err"' "naming what it wanted (said '$err')"

SSH_SCRIPT_OUT="loaded=1" run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' \
    "and a count that does not match the images sent is a failure too (exit $rc)"

# --- The tarball is cleaned up on both ends when the transfer fails ---------------------------

RSYNC_RC=1 run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "a failed transfer fails the run (exit $rc)"
assert 'grep -qF "could not send" <<<"$err"' "saying what failed (said '$err')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' \
    "the tarball had been written — else the next assertion proves nothing"
assert '[ -z "$(tarballs)" ]' \
    "and it does not survive the failure locally (found: $(tarballs))"
assert 'grep -qF "'"'"'rm'"'"' '"'"'-f'"'"' '"'"'/tmp/built-app-1.4.2.tar.gz'"'"'" "$SSH_LOG"' \
    "nor on the server, where a half-sent one would be (ssh log: $(cat "$SSH_LOG"))"
assert '[ ! -e "$projdir/.kasbah/state.json" ]' \
    "and a run that failed records no server (docs/project-manifest.md: only on success)"

# The same from the other side: a load that fails leaves nothing behind either.
SSH_SCRIPT_RC=1 run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "a remote step that exits non-zero fails the run (exit $rc)"
assert '[ -z "$(tarballs)" ]' "with no local tarball left (found: $(tarballs))"

# --- An unreachable server -------------------------------------------------------------------

SSH_RC=255 run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" = "3" ]' "an unreachable server is exit 3, as docs/cli.md has it (exit $rc: $err)"
assert '[ -z "$(tarballs)" ]' \
    "and nothing was saved before the connection was proved (found: $(tarballs))"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "0" ]' \
    "not even asked for (log: $(cat "$DOCKER_LOG"))"

# --- The git tag ------------------------------------------------------------------------------
# A bare repository two directories away plays origin. Nothing here can reach a
# network, and the assertion is what actually landed in it.

origin="$tmpdir/origin.git"
git init -q --bare "$origin" >/dev/null 2>&1
projdir="$(make gitpush built-app v3.1.0 nightly)"
( cd "$projdir" && git remote add origin "$origin" ) || exit 2

origin_tags() { git --git-dir="$origin" tag | tr '\n' ' '; }

run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a ship with an origin succeeds (exit $rc: $err)"
assert '[ "$(cd "$projdir" && git tag | tr "\n" " ")" = "nightly v3.1.0 " ]' \
    "the fixture carries a second, unrelated tag — else 'pushes this tag' cannot be
     told from 'pushes every tag' (local tags: $(cd "$projdir" && git tag | tr '\n' ' '))"
assert '[ "$(origin_tags)" = "v3.1.0 " ]' \
    "and it is the version tag alone that lands on origin (origin has: '$(origin_tags)')"

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
assert 'grep -qF "git:     pushed v3.1.0 to origin" <<<"$err"' \
    "which says what it did with the tag (said '$err')"

# Idempotent: a tag already on origin is not pushed again, and that is not an error.
run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "shipping the same version again succeeds (exit $rc: $err)"
assert 'grep -qF "already on origin" <<<"$out$err"' \
    "and says the tag was already there (said '$out$err')"
assert '[ "$(grep -n -m1 -F "Shipped built-app" <<<"$err" | cut -d: -f1)" -lt "$(grep -n -m1 -F "  git:" <<<"$err" | cut -d: -f1)" ]' \
    "under the headline here too, not above it (said '$err')"

# --build-only is the whole short circuit: no transfer and no push either.
git --git-dir="$origin" tag -d v3.1.0 >/dev/null 2>&1
assert '[ "$(origin_tags)" = "" ]' "origin is back to no tags — else --build-only proves nothing"
run --build-only; rc=$?
assert '[ "$rc" = "0" ]' "--build-only succeeds with an origin present (exit $rc: $err)"
assert '[ "$(origin_tags)" = "" ]' \
    "and pushes nothing — it ships nothing, so there is nothing to point a tag at (origin has: '$(origin_tags)')"

git --git-dir="$origin" tag -d v3.1.0 >/dev/null 2>&1
assert '[ "$(origin_tags)" = "" ]' "origin is back to no tags — else --no-git-push proves nothing"
run --no-git-push "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "--no-git-push still ships (exit $rc: $err)"
assert '[ "$(origin_tags)" = "" ]' \
    "and leaves the tag exactly where it was (origin has: '$(origin_tags)')"
assert 'grep -qF "git:     v3.1.0 left where it is (--no-git-push)" <<<"$err"' \
    "saying so under the headline rather than staying silent about the tag (said '$err')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' \
    "the images went all the same (log: $(cat "$DOCKER_LOG"))"

# The ordering the push depends on, from the only side that can show it: a
# transfer that fails must leave origin exactly as it was. A tag on origin
# naming images no server has is the worse of the two messes, which is why the
# push is the last step rather than an early one.
git --git-dir="$origin" tag -d v3.1.0 >/dev/null 2>&1
assert '[ "$(origin_tags)" = "" ]' "origin is back to no tags — else the case below proves nothing"
RSYNC_RC=1 run "deploy@vps"; rc=$?
assert '[ "$rc" != "0" ]' "a ship whose transfer fails is a failed run (exit $rc)"
assert '[ "$(origin_tags)" = "" ]' \
    "and pushed no tag — the tag follows the images (origin has: '$(origin_tags)')"

# No origin at all: the images have already shipped by then, so failing there
# would be perverse. Warn and finish.
projdir="$(make noorigin built-app v3.1.0)"
run "deploy@vps"; rc=$?
assert '[ "$rc" = "0" ]' "a repository with no origin still exits 0 (exit $rc: $err)"
assert 'grep -qF "no '"'"'origin'"'"' remote" <<<"$err"' "with a warning that says why (said '$err')"
assert 'grep -qF "git:     v3.1.0 not pushed" <<<"$err"' \
    "and the summary line under the headline agrees with the warning (said '$err')"
assert '[ "$(grep -c "^save " "$DOCKER_LOG")" = "1" ]' "and the images did ship (log: $(cat "$DOCKER_LOG"))"

# --- The command line -------------------------------------------------------------------------

projdir="$built"
run --nope; rc=$?
assert '[ "$rc" = "1" ]' "an unknown flag is refused (exit $rc)"
assert 'grep -qF "unknown flag" <<<"$err"' "by name (said '$err')"
assert 'grep -qF -- "--nope" <<<"$err"' "quoting it (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' "before anything runs (log: $(cat "$DOCKER_LOG"))"

# A boolean flag handed a value is its own mistake, refused by name rather than
# as an unknown flag — the mirror image of the branch deploy has for --on-drift
# without one.
for pair in --build-only=yes --no-git-push=true; do
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
run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a project with no compose.prod.yml fails (exit $rc)"
assert 'grep -qF "compose.prod.yml: not found" <<<"$err"' \
    "saying that file is missing rather than that it will not parse (said '$err')"

# --- No server, and none remembered ------------------------------------------------------------

projdir="$(make noserver built-app v1.4.2)"
run; rc=$?
assert '[ "$rc" = "1" ]' "a project that has never shipped and names no server fails (exit $rc)"
assert 'grep -qF "never shipped" <<<"$err"' "saying so (said '$err')"
assert 'grep -qF -- "--build-only" <<<"$err"' \
    "and naming the mode that needs no server (said '$err')"
assert '[ ! -s "$DOCKER_LOG" ]' \
    "asked before the build, not after it (log: $(cat "$DOCKER_LOG"))"

# The other half: the remembered server is used when none is given.
projdir="$(make remembered built-app v1.4.2)"
mkdir -p "$projdir/.kasbah"
printf '{"last_server":"stored@vps"}\n' > "$projdir/.kasbah/state.json"
run --no-git-push; rc=$?
assert '[ "$rc" = "0" ]' "a project with a last_server ships without being told (exit $rc: $err)"
assert 'grep -qF "stored@vps:/tmp/built-app-1.4.2.tar.gz" "$RSYNC_LOG"' \
    "to that server (rsync log: $(cat "$RSYNC_LOG"))"

# --- A build that fails ---------------------------------------------------------------------------

projdir="$built"
DOCKER_RC=1 run --build-only; rc=$?
assert '[ "$rc" = "1" ]' "a failing docker compose build fails the run (exit $rc)"
assert 'grep -qF "build failed" <<<"$err"' "saying which step (said '$err')"

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

check_out="$(cd "$built" && env HOME="$fakehome" "$repo_dir/bin/kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "kasbah check passes on the built-app fixture (exit $rc)"
assert 'grep -qF ", 0 failed" <<<"$check_out"' \
    "with no failed rule (said '$(tail -1 <<<"$check_out")')"

exit "$fail"
