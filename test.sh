#!/usr/bin/env bash
# Run the Go checks, then every tests/*_test.sh against the binary under test.
# Each test is a standalone bash script; exit 0 = pass.
#
# One line per check: each one's output goes to .cache/test-logs/<name>.log and
# is printed only when it fails or cannot run. KASBAH_TEST_VERBOSE=1 streams
# everything instead.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tests_dir="$repo_dir/tests"

shopt -s nullglob
tests=("$tests_dir"/*_test.sh)

# Integration tests need a rig (tests/rig/rig.sh up) and are opt-in, so the
# default run stays fast. Off, this costs one string comparison — no glob, no
# stat, nothing that grows with the repo.
#
# An unrecognised value is a hard failure rather than "off": `KASBAH_RIG_TESTS=true`
# treated as off prints the same three PASS lines and the same exit 0 as a run
# where the integration suite really passed, which is a false green rather than
# an error. Exit 2 so a misconfigured runner is distinguishable from exit 1,
# "tests failed".
case "${KASBAH_RIG_TESTS:-}" in
    ''|0) ;;
    1) tests+=("$tests_dir/integration"/*_test.sh) ;;
    *)  echo "KASBAH_RIG_TESTS='$KASBAH_RIG_TESTS' is not a valid value" >&2
        echo "  1        run the integration suite too (needs tests/rig/rig.sh up)" >&2
        echo "  0/empty  unit suites only" >&2
        exit 2 ;;
esac

if [ ${#tests[@]} -eq 0 ]; then
    echo "no tests found in $tests_dir" >&2
    exit 0
fi

# dist/kasbah runs here: darwin on a Mac, linux otherwise.
host_goos() { if [ "$(uname -s)" = Darwin ]; then echo darwin; else echo linux; fi; }

# The Go toolchain lives in compose.yml. UID is a read-only shell variable that
# is never exported, so it goes through env; without it the container writes as
# uid 1000. -p because an exported COMPOSE_PROJECT_NAME outranks the file's
# `name:`; stdin from /dev/null because -T still forwards it, and a run put in
# the background would stop on SIGTTIN.
go_compose() {
    env UID="$(id -u)" GID="$(id -g)" KASBAH_GOOS="$(host_goos)" \
        docker compose --progress quiet -p kasbah -f "$repo_dir/compose.yml" run --rm -T "$@" </dev/null
}
# No usable Docker is a fact about this machine, not the code: exit 2, like a
# rig that is down. A missing binary, a missing compose plugin and a daemon
# that is down or refuses this user all land here.
if ! command -v docker >/dev/null 2>&1 \
   || ! docker compose version >/dev/null 2>&1 \
   || ! docker info >/dev/null 2>&1; then
    echo "docker is needed: the Go checks and the build run in compose.yml's toolchain" >&2
    echo "  (checked: docker on PATH, \`docker compose version\`, \`docker info\`)" >&2
    exit 2
fi

case "${KASBAH_TEST_VERBOSE:-}" in
    ''|0) verbose=0 ;;
    1)    verbose=1 ;;
    *)    echo "KASBAH_TEST_VERBOSE='$KASBAH_TEST_VERBOSE' is not a valid value (1, or 0/empty)" >&2
          exit 2 ;;
esac
logs="$repo_dir/.cache/test-logs"
rm -rf "$logs"
mkdir -p "$logs"

# capture <log> <cmd…> — the command's stdout and stderr into <log>, or to the
# terminal when verbose; its exit status either way.
capture() {
    local log=$1; shift
    if [ "$verbose" = 1 ]; then
        "$@"
    else
        mkdir -p "$(dirname "$log")"
        "$@" >"$log" 2>&1
    fi
}
dump() { [ "$verbose" = 1 ] || sed 's/^/  /' "$1" >&2; }

failed=0
unrunnable=0

capture "$logs/go.log" go_compose test; rc=$?
if [ "$rc" -eq 0 ]; then
    echo "PASS go (docker compose run --rm test)"
else
    echo "FAIL go (docker compose run --rm test)" >&2
    dump "$logs/go.log"
    failed=$((failed + 1))
fi

# Every suite drives KASBAH_BIN (tests/cli.sh). Unset, it is this checkout's
# dist/kasbah, rebuilt here so no suite runs a binary older than the tree. A
# build that fails stops the run: whatever dist/ still holds is not this tree.
if [ -z "${KASBAH_BIN:-}" ]; then
    if ! go_compose build; then
        echo "FAIL build (docker compose run --rm build) — no suite run" >&2
        exit 1
    fi
    KASBAH_BIN="$repo_dir/dist/kasbah"
fi
if [ ! -x "$KASBAH_BIN" ]; then
    echo "KASBAH_BIN=$KASBAH_BIN is not an executable — no suite run" >&2
    exit 2
fi
export KASBAH_BIN

for t in "${tests[@]}"; do
    # Relative to tests/, not just the basename: a unit suite and an
    # integration suite for the same library share a name (ssh_test.sh), and
    # "FAIL ssh_test.sh" would not say which one.
    name="${t#"$tests_dir"/}"
    capture "$logs/$name.log" bash "$t"; rc=$?
    # A suite's own exit 2 carries this runner's meaning of 2: it could not run
    # (no rig, for the integration suite), which is a fact about the environment
    # and not about the code. Counting it as a failure was the whole confusion —
    # "1 test(s) failed" sent readers looking for a defect that was not there.
    case $rc in
        0) echo "PASS $name" ;;
        2) echo "SKIP $name — preconditions not met:" >&2
           dump "$logs/$name.log"
           unrunnable=$((unrunnable + 1)) ;;
        *) echo "FAIL $name" >&2
           dump "$logs/$name.log"
           failed=$((failed + 1)) ;;
    esac
done

# An incomplete run outranks a failing one: the verdict below it is not the
# verdict of the suite that was asked for. Both counts are printed either way.
if [ "$unrunnable" -gt 0 ]; then
    [ "$failed" -eq 0 ] || echo "$failed test(s) failed" >&2
    echo "$unrunnable suite(s) could not run — fix the environment and rerun" >&2
    exit 2
fi
if [ "$failed" -gt 0 ]; then
    echo "$failed test(s) failed" >&2
    exit 1
fi
exit 0
