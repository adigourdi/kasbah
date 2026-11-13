#!/usr/bin/env bash
# Test: `kasbah info` without a host (docs/cli.md): every key, in order, the
# build's docs URL, the binary as invoked and resolved, the install method for
# a checkout, a library version directory and anywhere else, and that
# `kasbah help info` is `kasbah info --help`. A host that does not answer
# still leaves the workstation's lines (a stand-in ssh, nothing on the network).
# `kasbah remote info`, run here against a stand-in docker, reads docker's
# stdout for a version and its stderr for why it failed.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"
build="$(kasbah_bin_version)"
base="$(kasbah_base_version)"
real="$(readlink -f "$kasbah")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/home" "$tmpdir/cwd"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# run BIN ARGS… — info in a scratch cwd and HOME, with nothing else from this
# shell's environment but PATH (and KASBAH_LIB_DIR when set).
run() {
    (cd "$tmpdir/cwd" && env -i PATH="${RUN_PATH:-$PATH}" HOME="$tmpdir/home" \
        ${KASBAH_LIB_DIR:+KASBAH_LIB_DIR="$KASBAH_LIB_DIR"} "$@" >"$tmpdir/out" 2>"$tmpdir/err")
}
val() { sed -n "s/^$1: //p" "$tmpdir/out"; }

# --- Case 1: the keys, in order, and their values -----------------------------
run "$kasbah" info; rc=$?
assert '[ "$rc" -eq 0 ]' "info exits 0 (got $rc)"
assert '[ ! -s "$tmpdir/err" ]' "info prints nothing on stderr: $(cat "$tmpdir/err")"
keys=$(cut -d: -f1 "$tmpdir/out" | tr '\n' ' ')
assert '[ "$keys" = "name version build os arch binary resolved install lib docs " ]' "the keys in order (got: $keys)"
assert '! grep -vqE "^[a-z.]+: .+$" "$tmpdir/out"' "every line is key: value"
assert '[ "$(val name)" = kasbah ]' "name: kasbah"
assert '[ "$(val build)" = "$build" ]' "build is the --version stamp ($build, got $(val build))"
assert '[ "$(val version)" = "$base" ]' "version is the base version ($base, got $(val version))"
assert '[ "$(val os)/$(val arch)" = "$(uname -s | tr A-Z a-z)/$(case $(uname -m) in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) uname -m;; esac)" ]' \
    "os/arch is this machine's (got $(val os)/$(val arch))"
assert '[ "$(val binary)" = "$kasbah" ] && [ "$(val resolved)" = "$real" ]' "binary and resolved name the binary run (got $(val binary), $(val resolved))"
if [[ $build =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then ref="v$build"; else ref=main; fi
assert '[ "$(val docs)" = "https://github.com/adigourdi/kasbah/tree/$ref/docs" ]' "docs is the tree at $ref (got $(val docs))"
root="$(cd "$(dirname "$real")/.." && pwd)"
if [ -f "$root/go.mod" ] && [ -d "$root/cmd/kasbah" ]; then
    assert '[ "$(val install)" = checkout ]' "a checkout's dist/kasbah is install: checkout (got $(val install))"
    assert '[ "$(val lib)" = "$tmpdir/home/.local/share/kasbah" ]' "a checkout's lib is the environment's (got $(val lib))"
fi

# --- Case 2: started through a symlink on PATH --------------------------------
mkdir -p "$tmpdir/bin"
ln -s "$real" "$tmpdir/bin/kasbah"
RUN_PATH="$tmpdir/bin:$PATH" run kasbah info; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(val binary)" = "$tmpdir/bin/kasbah" ] && [ "$(val resolved)" = "$real" ]' \
    "a symlink on PATH is binary, its target resolved (rc $rc, got $(val binary), $(val resolved))"

# --- Case 3: a library version directory, and anywhere else -------------------
mkdir -p "$tmpdir/lib/1.2.3" "$tmpdir/opt"
cp "$real" "$tmpdir/lib/1.2.3/kasbah"
cp "$real" "$tmpdir/opt/kasbah"
ln -s "$tmpdir/lib/1.2.3/kasbah" "$tmpdir/bin/kasbah-lib"
run "$tmpdir/bin/kasbah-lib" info; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(val install)" = library ] && [ "$(val lib)" = "$tmpdir/lib" ] && [ "$(val resolved)" = "$tmpdir/lib/1.2.3/kasbah" ]' \
    "a version directory is install: library, its parent the lib (got $(val install), $(val lib), $(val resolved))"
run "$tmpdir/opt/kasbah" info; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(val install)" = other ] && [ "$(val lib)" = "$tmpdir/home/.local/share/kasbah" ]' \
    "anywhere else is install: other, the lib the environment's (got $(val install), $(val lib))"
KASBAH_LIB_DIR="$tmpdir/elsewhere" run "$tmpdir/opt/kasbah" info
assert '[ "$(val lib)" = "$tmpdir/elsewhere" ]' "KASBAH_LIB_DIR is the lib (got $(val lib))"

# --- Case 4: help, and the refusals -------------------------------------------
run "$kasbah" help info; rc1=$?; cp "$tmpdir/out" "$tmpdir/help1"
run "$kasbah" info --help; rc2=$?
assert '[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && cmp -s "$tmpdir/help1" "$tmpdir/out"' "kasbah help info is kasbah info --help"
assert 'grep -q "^Usage: kasbah info \[USER@HOST\]" "$tmpdir/out"' "info --help prints its usage"
run "$kasbah" --help
assert 'grep -qE "^  info \[USER@HOST\] +" "$tmpdir/out"' "kasbah --help lists info"
run "$kasbah" info --json; rc=$?
assert '[ "$rc" -eq 1 ] && grep -q "unknown flag '"'"'--json'"'"'" "$tmpdir/err"' "an unknown flag exits 1 naming it (rc $rc)"
run "$kasbah" info a@b c@d; rc=$?
assert '[ "$rc" -eq 1 ] && grep -q "unexpected argument '"'"'c@d'"'"'" "$tmpdir/err"' "a second host exits 1 (rc $rc)"

# --- Case 5: a host that does not answer --------------------------------------
mkdir -p "$tmpdir/nossh"
printf '#!/bin/sh\necho "ssh: connect to host nowhere: Connection refused" >&2\nexit 255\n' >"$tmpdir/nossh/ssh"
chmod 755 "$tmpdir/nossh/ssh"
RUN_PATH="$tmpdir/nossh:$PATH" run "$kasbah" info ops@nowhere; rc=$?
assert '[ "$rc" -eq 3 ]' "an unreachable host exits 3 (got $rc)"
assert '[ "$(val name)" = kasbah ] && [ -n "$(val docs)" ] && ! grep -q "^server" "$tmpdir/out"' "the workstation's lines are printed before the connection"
assert 'grep -q "cannot reach ops@nowhere" "$tmpdir/err"' "the refusal names the host"

# --- Case 6: `remote info`, the server's arm, against a stand-in docker -------
mkdir -p "$tmpdir/docker-warn" "$tmpdir/docker-down" "$tmpdir/nodocker"
# A daemon that answers with a warning on stderr: the value is stdout alone.
printf '%s\n' '#!/bin/sh' 'echo "WARNING: bridge-nf-call-iptables is disabled" >&2' \
    'if [ "$1" = compose ]; then echo 2.29.7; else echo 27.3.1; fi' >"$tmpdir/docker-warn/docker"
printf '%s\n' '#!/bin/sh' '[ "$1" = compose ] && { echo 2.29.7; exit 0; }' \
    'echo "permission denied while trying to connect to the Docker daemon socket" >&2' 'exit 1' >"$tmpdir/docker-down/docker"
chmod 755 "$tmpdir/docker-warn/docker" "$tmpdir/docker-down/docker"
remote_info() { (cd "$tmpdir/cwd" && env -i PATH="$1" HOME="$tmpdir/home" "$kasbah" remote info >"$tmpdir/out" 2>"$tmpdir/err"); }
kv() { sed -n "s/^$1=//p" "$tmpdir/out"; }
flat() { tr '\n' ' ' <"$tmpdir/out"; }
remote_info "$tmpdir/docker-warn:/usr/bin:/bin"; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(kv build)" = "$build" ] && [ "$(kv docker)" = 27.3.1 ] && [ "$(kv compose)" = 2.29.7 ]' \
    "remote info: docker and compose are stdout alone, a stderr warning dropped (rc $rc: $(flat))"
assert '! grep -q "^docker_error=" "$tmpdir/out"' "remote info: no docker_error when docker answers"
remote_info "$tmpdir/docker-down:/usr/bin:/bin"; rc=$?
assert '[ "$rc" -eq 0 ] && [ -z "$(kv docker)" ] && [ "$(kv docker_error)" = "permission denied while trying to connect to the Docker daemon socket" ]' \
    "remote info: a failing docker is its stderr's first line (rc $rc: $(flat))"
remote_info "$tmpdir/nodocker"; rc=$?
assert '[ "$rc" -eq 0 ] && grep -qx "docker=" "$tmpdir/out" && grep -qx "compose=" "$tmpdir/out" && ! grep -q "^docker_error=" "$tmpdir/out"' \
    "remote info: no docker on PATH is docker= with no docker_error, which info shows as none (rc $rc: $(flat))"

exit "$fail"
