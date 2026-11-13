#!/usr/bin/env bash
# Test: every project under examples/ passes `kasbah check` with nothing failed
# and nothing warned, and docs/authoring.md names each one. A new directory
# there is picked up as it is.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

guide="$repo_dir/docs/authoring.md"
assert '[ -f "$guide" ]' "docs/authoring.md exists"
guide_text="$(cat "$guide" 2>/dev/null)"

shopt -s nullglob
examples=("$repo_dir"/examples/*/)
assert '[ ${#examples[@]} -ge 7 ]' "examples/ holds every setup the guide walks through (found ${#examples[@]})"

for src in "${examples[@]}"; do
    name="$(basename "$src")"
    # A copy, so nothing check might write lands in the checkout.
    dir="$tmpdir/$name"
    cp -a "$src" "$dir"
    out="$(cd "$dir" && "$kasbah" check 2>&1)"; rc=$?
    assert '[ "$rc" = "0" ]' "$name: check exits 0 (rc $rc)
$out"
    assert 'grep -qE "^Summary: [0-9]+ passed, 0 warning, 0 failed$" <<<"$out"' \
        "$name: 0 warnings and 0 failed (said '$(grep '^Summary' <<<"$out")')"
    assert '! grep -q "⚠" <<<"$out"' "$name: no warning line
$(grep "⚠" <<<"$out")"
    assert 'grep -qF "examples/$name/" <<<"$guide_text"' \
        "$name: docs/authoring.md names examples/$name/"
    for f in kasbah.yml compose.prod.yml .env.prod.example .gitignore; do
        assert '[ -f "$src/$f" ]' "$name: has $f"
    done
done

# The other direction: every example the guide names is there.
for named in $(grep -oE 'examples/[a-z0-9-]+/' <<<"$guide_text" | sort -u); do
    assert '[ -d "$repo_dir/$named" ]' "docs/authoring.md names $named, which does not exist"
done

exit "$fail"
