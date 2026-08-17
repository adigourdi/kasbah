#!/usr/bin/env bash
# Run every tests/*_test.sh. Each test is a standalone bash script; exit 0 = pass.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tests_dir="$repo_dir/tests"

shopt -s nullglob
tests=("$tests_dir"/*_test.sh)

# Integration tests need a rig (tests/rig/rig.sh up) and are opt-in, so the
# default run stays fast and works on a machine with no Docker. Off, this costs
# one string comparison — no glob, no stat, nothing that grows with the repo.
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

failed=0
unrunnable=0
for t in "${tests[@]}"; do
    # Relative to tests/, not just the basename: a unit suite and an
    # integration suite for the same library share a name (ssh_test.sh), and
    # "FAIL ssh_test.sh" would not say which one.
    name="${t#"$tests_dir"/}"
    bash "$t"; rc=$?
    # A suite's own exit 2 carries this runner's meaning of 2: it could not run
    # (no rig, for the integration suite), which is a fact about the environment
    # and not about the code. Counting it as a failure was the whole confusion —
    # "1 test(s) failed" sent readers looking for a defect that was not there.
    case $rc in
        0) echo "PASS $name" ;;
        2) echo "SKIP $name — preconditions not met (see above)" >&2
           unrunnable=$((unrunnable + 1)) ;;
        *) echo "FAIL $name" >&2
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
