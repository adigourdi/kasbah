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
# An unrecognised value is a hard failure rather than "off": `HOSTING_RIG_TESTS=true`
# treated as off prints the same three PASS lines and the same exit 0 as a run
# where the integration suite really passed, which is a false green rather than
# an error. Exit 2 so a misconfigured runner is distinguishable from exit 1,
# "tests failed".
case "${HOSTING_RIG_TESTS:-}" in
    ''|0) ;;
    1) tests+=("$tests_dir/integration"/*_test.sh) ;;
    *)  echo "HOSTING_RIG_TESTS='$HOSTING_RIG_TESTS' is not a valid value" >&2
        echo "  1        run the integration suite too (needs tests/rig/rig.sh up)" >&2
        echo "  0/empty  unit suites only" >&2
        exit 2 ;;
esac

if [ ${#tests[@]} -eq 0 ]; then
    echo "no tests found in $tests_dir" >&2
    exit 0
fi

failed=0
for t in "${tests[@]}"; do
    name="$(basename "$t")"
    if bash "$t"; then
        echo "PASS $name"
    else
        echo "FAIL $name" >&2
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "$failed test(s) failed" >&2
    exit 1
fi
exit 0
