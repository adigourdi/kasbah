#!/usr/bin/env bash
# Regenerates the goldens the yamlx parity test compares against, from the real
# tool: kislyuk yq (PyYAML + jq), the parser the Bash kasbah answers through.
# Run on the host, never in the Go container (it has no yq).
#
#   regen.sh            one golden per corpus input: golden/<repo path>.json,
#                       holding `yq -c .`'s stdout, or .refused when yq exits
#                       non-zero (the Bash loader drops a failed conversion whole)
#   regen.sh capture    refill captured/ with every YAML document yq is handed
#                       while tests/check_test.sh and tests/yaml_test.sh run
#                       (the Bash suites: valid until the cutover retires them)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

yq_real="$(command -v yq)" || { echo "regen: no yq on PATH" >&2; exit 1; }
yq_help="$("$yq_real" --help 2>&1)" || true
grep -q "jq wrapper for YAML" <<<"$yq_help" \
    || { echo "regen: $yq_real is not kislyuk's yq (the jq wrapper kasbah's Bash runs)" >&2; exit 1; }

tmp=""
trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT

capture() {
    local shim
    tmp="$(mktemp -d)"
    shim="$tmp/bin"
    mkdir -p "$shim" "$tmp/seen"
    cat > "$shim/yq" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
keep() { local h d; h=\$(sha256sum "\$1"); d="$tmp/seen/\${h:0:16}.yml"; [ -e "\$d" ] || cat "\$1" > "\$d"; }
file=no
for a in "\$@"; do
    if [ -f "\$a" ]; then keep "\$a"; file=yes; fi
done
if [ "\$file" = no ] && [ ! -t 0 ]; then
    in=\$(mktemp "$tmp/stdin.XXXXXX")
    cat > "\$in"
    [ ! -s "\$in" ] || keep "\$in"
    exec "$yq_real" "\$@" < "\$in"
fi
exec "$yq_real" "\$@"
SHIM
    chmod +x "$shim/yq"
    local suite rc
    for suite in check_test.sh yaml_test.sh; do
        rc=0
        PATH="$shim:$PATH" bash "$repo/tests/$suite" >"$tmp/$suite.log" 2>&1 || rc=$?
        [ "$rc" = 0 ] || grep -F "FAIL" "$tmp/$suite.log" >&2 || true
        echo "regen: $suite exited $rc while capturing" >&2
    done
    # Staged beside captured/ and swapped in whole: a failed copy keeps the old set.
    rm -rf "$here/captured.new"
    mkdir "$here/captured.new"
    cp "$tmp"/seen/*.yml "$here/captured.new/"
    rm -rf "$here/captured"
    mv "$here/captured.new" "$here/captured"
    echo "regen: captured $(find "$here/captured" -name '*.yml' | wc -l) distinct documents" >&2
}

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
    capture) capture ;;
    '') goldens ;;
    *) echo "usage: regen.sh [capture]" >&2; exit 2 ;;
esac
