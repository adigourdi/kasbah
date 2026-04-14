#!/usr/bin/env bash
# Run every tests/*_test.sh. Each test is a standalone bash script; exit 0 = pass.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tests_dir="$repo_dir/tests"

shopt -s nullglob
tests=("$tests_dir"/*_test.sh)

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
