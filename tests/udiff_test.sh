#!/usr/bin/env bash
# Test: the unified diff `check --fix` shows is proven against GNU patch and
# GNU diff — a randomised corpus and every Go --fix case. The toolchain image
# has no patch, so the test binaries are built there and run here.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

for tool in patch diff docker; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is needed on this machine: the diff proofs run GNU patch and GNU diff here" >&2
        exit 2
    fi
done
for tool in patch diff; do
    v="$("$tool" --version 2>/dev/null)" || v=""
    if ! grep -q GNU <<<"${v%%$'\n'*}"; then
        echo "$tool on this machine is not GNU's — the proofs are against GNU's" >&2
        exit 2
    fi
done

mkdir -p "$repo_dir/.cache"
bins="$(mktemp -d "$repo_dir/.cache/udiff.XXXXXX")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$bins"' EXIT
chmod 755 "$bins"

fail=0

build='set -e; go test -c -o "$0/udiff.test" ./internal/udiff; go test -c -o "$0/check.test" ./internal/check'
if ! env UID="$(id -u)" GID="$(id -g)" docker compose -p kasbah -f "$repo_dir/compose.yml" \
        run --rm -T test sh -c "$build" ".cache/${bins##*/}" </dev/null; then
    echo "  FAIL: the test binaries did not build" >&2
    exit 1
fi

# run PKG BIN ARGS… — the binary from its package directory, as go test would,
# with nothing from this shell's environment but PATH (and KASBAH_UDIFF_CORPUS,
# the corpus size, 10000 unset).
run() {
    local pkg="$1" bin="$2"
    shift 2
    (cd "$repo_dir/$pkg" && env -i PATH="$PATH" HOME="$tmpdir" TMPDIR="$tmpdir" KASBAH_UDIFF_GNU=1 \
        ${KASBAH_UDIFF_CORPUS:+KASBAH_UDIFF_CORPUS="$KASBAH_UDIFF_CORPUS"} "$bins/$bin" -test.v -test.count=1 "$@" 2>&1)
}

out="$(run internal/udiff udiff.test -test.run '^TestGNURoundTrip$')"; rc=$?
if [ "$rc" -ne 0 ] || ! grep -q -- '--- PASS: TestGNURoundTrip' <<<"$out"; then
    echo "  FAIL: the GNU round trip over the corpus (rc $rc):" >&2
    tail -40 <<<"$out" >&2
    fail=1
else
    grep -o 'corpus [0-9]*:.*' <<<"$out"
fi

out="$(run internal/check check.test -test.run '^TestFix')"; rc=$?
trips="$(grep -c 'patch round trip:' <<<"$out")"
if [ "$rc" -ne 0 ] || grep -q -- '--- SKIP' <<<"$out"; then
    echo "  FAIL: the --fix cases under GNU patch (rc $rc):" >&2
    grep -E -- '--- (FAIL|SKIP)|_test.go:[0-9]+' <<<"$out" | head -40 >&2
    fail=1
elif [ "$trips" -lt 10 ]; then
    echo "  FAIL: only $trips --fix diffs went through GNU patch, expected at least 10" >&2
    fail=1
else
    echo "--fix cases: $trips diffs applied by GNU patch, all exact"
fi

exit "$fail"
