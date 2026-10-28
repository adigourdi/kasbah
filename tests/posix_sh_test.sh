#!/usr/bin/env bash
# Test: every package whose tests run shell passes whole under pinned busybox
# (its ash and userland, as nobody), and shellcheck -s sh passes on every remote script.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
busybox=busybox:1.37.0
shellcheck=koalaman/shellcheck:v0.11.0
want="destroy-leftover destroy-pointer destroy-tail serverbin-probe serverbin-upload serverinit-elevate serverinit-group serverinit-pointer serverinit-probe"

if ! docker info >/dev/null 2>&1; then
    echo "docker is needed: busybox and shellcheck run from pinned images" >&2
    exit 2
fi

# Found, not listed: a package runs on the server (remote.go), names a shell
# in its code, or runs a script, a stub or ssh in its tests.
found="$(cd "$repo_dir" && {
    grep -rlE '"sh", "-[cs]"|shtest\.|#!/bin/sh|"ssh"' --include='*_test.go' internal cmd
    grep -rlE '"(sh|bash|dash)"' --include='*.go' --exclude='*_test.go' internal cmd
    find internal cmd -name remote.go
    echo internal/remote/x
})"
pkgs="$(cd "$repo_dir" && printf '%s\n' "$found" | xargs -n1 dirname | sort -u |
    while read -r d; do ! compgen -G "$d/*_test.go" >/dev/null || echo "$d"; done)"
for p in internal/serverinit internal/serverbin internal/destroy internal/ssh internal/env internal/remote; do
    if ! grep -qxF "$p" <<<"$pkgs"; then
        echo "  FAIL: $p was not found among the packages that run shell" >&2
        exit 1
    fi
done

mkdir -p "$repo_dir/.cache"
bins="$(mktemp -d "$repo_dir/.cache/posix-sh.XXXXXX")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$bins"' EXIT
mkdir -p "$tmpdir/scripts"
chmod 777 "$tmpdir/scripts"
chmod 755 "$bins"

fail=0

# Static test binaries (CGO_ENABLED=0 in compose.yml), built where the
# toolchain container can write.
build='set -e; for p in '"$(tr '\n' ' ' <<<"$pkgs")"'; do go test -c -o "$0/$(echo "$p" | tr / -).test" "./$p"; done'
if ! env UID="$(id -u)" GID="$(id -g)" docker compose -p kasbah -f "$repo_dir/compose.yml" \
        run --rm -T test sh -c "$build" ".cache/${bins##*/}" </dev/null; then
    echo "  FAIL: the test binaries did not build" >&2
    exit 1
fi

ash="$(docker run --rm "$busybox" sh -c '[ /bin/sh -ef /bin/busybox ] && command -v sh' 2>&1)"
if [ "$ash" != /bin/sh ]; then
    echo "  FAIL: $busybox's sh is not busybox ash: $ash" >&2
    exit 1
fi

for p in $pkgs; do
    name="$(tr / - <<<"$p")"
    # Tests in a file that runs git are the workstation's (busybox has no git);
    # such a file must not also run shell, or the exemption would hide it.
    wsfiles="$(cd "$repo_dir" && grep -l '"git"' "$p"/*_test.go 2>/dev/null)"
    if [ -n "$wsfiles" ] && shfiles="$(cd "$repo_dir" && grep -lE '"sh", "-[cs]"|shtest\.|#!/bin/sh' $wsfiles)"; then
        echo "  FAIL: $p: a test file runs both git and shell, so busybox cannot run it: $shfiles" >&2
        fail=1
    fi
    ws="$(cd "$repo_dir" && printf '%s\n' $wsfiles | xargs -r sed -n 's/^func \(Test[A-Za-z0-9_]*\)(t \*testing\.T).*/\1/p' | paste -sd'|')"
    skip=()
    [ -z "$ws" ] || skip=(-test.skip "^($ws)\$")
    out="$(docker run --rm --user 65534:65534 \
        -e KASBAH_TEST_SHELLS=sh -e KASBAH_SCRIPT_DIR=/scripts \
        -v "$repo_dir:/src:ro" -v "$bins:/bins:ro" -v "$tmpdir/scripts:/scripts" \
        -w "/src/$p" "$busybox" "/bins/$name.test" -test.v -test.count=1 "${skip[@]}" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: $p under busybox (rc $rc):" >&2
        grep -E -- '--- FAIL|_test.go:[0-9]+' <<<"$out" | head -40 >&2
        fail=1
    # A Test…Helper is a process another test re-executes; alone it skips.
    elif skipped="$(grep -E -- '--- SKIP' <<<"$out" | grep -vE -- '--- SKIP: Test[A-Za-z0-9]*Helper ')"; then
        echo "  FAIL: $p skipped a test under busybox:" >&2
        printf '%s\n' "$skipped" >&2
        fail=1
    fi
done

got=""
for f in "$tmpdir"/scripts/*.sh; do
    [ -e "$f" ] || continue
    n="${f##*/}"
    got="$got ${n%.sh}"
done
if [ "${got# }" != "$want" ]; then
    echo "  FAIL: scripts written: '${got# }', expected '$want'" >&2
    fail=1
fi

args=()
for n in $want; do args+=("/mnt/$n.sh"); done
if ! lint="$(docker run --rm -v "$tmpdir/scripts:/mnt:ro" "$shellcheck" -s sh "${args[@]}" 2>&1)"; then
    echo "  FAIL: shellcheck -s sh:" >&2
    printf '%s\n' "$lint" >&2
    fail=1
fi

exit "$fail"
