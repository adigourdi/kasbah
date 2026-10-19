#!/usr/bin/env bash
# Regenerates the goldens the yamlx parity test compares against, from the real
# tool: kislyuk yq (PyYAML + jq), the parser the Bash kasbah answers through.
# Run on the host, never in the Go container (it has no yq).
#
#   regen.sh            one golden per corpus input: golden/<repo path>.json,
#                       holding `yq -c .`'s stdout, or .refused when yq exits
#                       non-zero (the Bash loader drops a failed conversion whole)
#
# captured/ is a frozen corpus: the documents the retired Bash suites handed yq.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

yq_real="$(command -v yq)" || { echo "regen: no yq on PATH" >&2; exit 1; }
yq_help="$("$yq_real" --help 2>&1)" || true
grep -q "jq wrapper for YAML" <<<"$yq_help" \
    || { echo "regen: $yq_real is not kislyuk's yq (the jq wrapper kasbah's Bash runs)" >&2; exit 1; }

inputs() {
    (cd "$repo" && find tests/fixtures templates internal/yamlx/testdata/edge internal/yamlx/testdata/captured \
        -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
}

goldens() {
    local f out rc n=0 refused=0
    rm -rf "$here/golden"
    while IFS= read -r f; do
        mkdir -p "$here/golden/$(dirname "$f")"
        rc=0
        out="$("$yq_real" -c . "$repo/$f" 2>/dev/null)" || rc=$?
        if [ "$rc" = 0 ]; then
            [ -z "$out" ] || out+=$'\n'
            printf '%s' "$out" > "$here/golden/$f.json"
        else
            : > "$here/golden/$f.refused"
            refused=$((refused + 1))
        fi
        n=$((n + 1))
    done < <(inputs)
    echo "regen: $n goldens, $refused of them refusals" >&2
}

case "${1:-}" in
    '') goldens ;;
    *) echo "usage: regen.sh" >&2; exit 2 ;;
esac
