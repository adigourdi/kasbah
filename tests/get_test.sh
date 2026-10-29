#!/usr/bin/env bash
# Test: get.sh, the curl | sh installer, under dash (the host's) and busybox sh
# (pinned image, its wget instead of curl), against a fake release host
# (tests/get_fake_release.py: bare downloads, a token-guarded API whose assets
# redirect to a second host). The release's "binary" is a stub that records
# its argv, the files in any directory it is handed, its stdin and its
# environment, then exits with a chosen status.
#
# Each run gets a clean environment and a PATH of chosen tools only, so the
# host's own gh, minisign or curl never answer; the temp dir get.sh makes must
# be gone after every run.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
busybox=busybox:1.37.0
shellcheck=koalaman/shellcheck:v0.11.0

for t in dash python3 openssl setsid script docker curl wget sha256sum shasum perl; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "$t is needed on the host" >&2
        exit 2
    fi
done
if ! docker info >/dev/null 2>&1; then
    echo "docker is needed: busybox and shellcheck run from pinned images" >&2
    exit 2
fi

tmp="$(mktemp -d)"
server_pid=''
cleanup() {
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: [$sh] $2" >&2
        fail=1
    fi
}
sh=static

# --- The release: a stub binary, checksums, a placeholder signature ------------
srv="$tmp/srv"
out="$tmp/out"
scratch="$tmp/scratch"
mkdir -p "$srv/releases" "$out" "$scratch" "$tmp/home"
chmod 777 "$out" "$scratch"

cat >"$tmp/stub" <<'EOF'
#!/bin/sh
[ "${1-}" != --version ] || { echo "kasbah @CLAIM@ (schema 1)"; exit 0; }
{
    printf 'argv:'
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\n'
    for a in "$@"; do
        [ ! -d "$a" ] || for f in "$a"/*; do printf 'has=%s\n' "$f"; done
    done
    printf 'stdin=%s\n' "$(readlink /proc/self/fd/0)"
    printf 'self=%s\n' "$0"
    printf 'bin=%s lib=%s token=%s\n' "${KASBAH_BIN_DIR-unset}" "${KASBAH_LIB_DIR-unset}" "${GITHUB_TOKEN-unset}"
} >"$GET_TEST_OUT/stub.log"
[ -z "${GET_TEST_KILL:-}" ] || kill -TERM "$PPID"
exit "${GET_TEST_RC:-0}"
EOF
# release VER [CLAIM] — v<VER>'s assets, the stubs answering --version as CLAIM.
release() {
    local d="$srv/releases/v$1" a
    mkdir -p "$d"
    for a in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do sed "s/@CLAIM@/${2:-$1}/" "$tmp/stub" >"$d/kasbah_$1_$a"; done
    (cd "$d" && sha256sum kasbah_* >checksums.txt)
    echo "untrusted comment: placeholder" >"$d/checksums.txt.minisig"
}
release 1.1.0
# 1.2.0's checksums.txt does not match its amd64 binary.
release 1.2.0
sed -i "/_amd64\$/s/^[0-9a-f]*/$(printf '0%.0s' {1..64})/" "$srv/releases/v1.2.0/checksums.txt"
# 1.3.0's binary says it is 1.1.0.
release 1.3.0 1.1.0
# 1.4.0 has no checksums.txt; 1.5.0's does not list the amd64 binary.
release 1.4.0
rm "$srv/releases/v1.4.0/checksums.txt"
release 1.5.0
sed -i '/_amd64$/d' "$srv/releases/v1.5.0/checksums.txt"
# 1.7.0's checksums.txt reaches gh only (its copy under $tmp/ghrel).
release 1.7.0
mkdir -p "$tmp/ghrel"
cp -R "$srv/releases/v1.7.0" "$tmp/ghrel/"
rm "$srv/releases/v1.7.0/checksums.txt"
# 1.8.0 has no signature.
release 1.8.0
rm "$srv/releases/v1.8.0/checksums.txt.minisig"
# 1.6.0's checksums.txt is CRLF, in sha256sum's binary-mode form (*name).
release 1.6.0
sed -i 's/  / */; s/$/\r/' "$srv/releases/v1.6.0/checksums.txt"

# --- Stubs on PATH --------------------------------------------------------------
mkdir -p "$tmp/gh" "$tmp/minisign" "$tmp/uname-darwin" "$tmp/uname-darwin-x86" "$tmp/uname-rosetta" "$tmp/uname-freebsd" \
    "$tmp/uname-riscv" "$tmp/uname-arm"
cat >"$tmp/gh/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GET_TEST_OUT/gh.log"
[ "$1" = release ] && [ "$2" = download ] || exit 1
tag=$3 dir='' pats=''
shift 3
while [ $# -gt 0 ]; do
    case $1 in
        -p) pats="$pats $2"; shift 2 ;;
        -D) dir=$2; shift 2 ;;
        *) shift ;;
    esac
done
for p in $pats; do cp "$GET_TEST_REL/$tag/$p" "$dir/$p" || exit 1; done
EOF
cat >"$tmp/minisign/minisign" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GET_TEST_OUT/minisign.log"
[ ! -f "$2.minisig" ] || echo "sig beside $2" >>"$GET_TEST_OUT/minisign.log"
[ "${GET_TEST_MINISIGN_RC:-0}" = 0 ] || echo "Signature verification failed"
exit "${GET_TEST_MINISIGN_RC:-0}"
EOF
printf '#!/bin/sh\ncase $1 in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' >"$tmp/uname-darwin/uname"
printf '#!/bin/sh\ncase $1 in -s) echo Darwin ;; -m) echo x86_64 ;; esac\n' >"$tmp/uname-darwin-x86/uname"
# An arm64 Mac's shell under Rosetta: uname says x86_64, sysctl tells.
cp "$tmp/uname-darwin-x86/uname" "$tmp/uname-rosetta/uname"
printf '#!/bin/sh\n[ "$*" = "-n sysctl.proc_translated" ] && echo 1\n' >"$tmp/uname-rosetta/sysctl"
printf '#!/bin/sh\ncase $1 in -s) echo FreeBSD ;; -m) echo amd64 ;; esac\n' >"$tmp/uname-freebsd/uname"
printf '#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo riscv64 ;; esac\n' >"$tmp/uname-riscv/uname"
printf '#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo aarch64 ;; esac\n' >"$tmp/uname-arm/uname"
chmod 755 "$tmp"/gh/gh "$tmp"/minisign/minisign "$tmp"/uname-*/uname "$tmp"/uname-rosetta/sysctl

# Host tool sets for dash: curl is a wrapper that records its argv.
toolset() {
    local dir="$tmp/tools-$1" t
    shift
    mkdir -p "$dir"
    for t in "$@"; do
        if [ "$t" = curl ]; then
            printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$GET_TEST_OUT/curl.argv"\nexec %s "$@"\n' "$(command -v curl)" >"$dir/curl"
            chmod 755 "$dir/curl"
        else
            ln -s "$(command -v "$t")" "$dir/$t"
        fi
    done
}
base=(uname mktemp rm chmod mv awk readlink cp cat)
toolset curl "${base[@]}" sha256sum curl wget
toolset wget "${base[@]}" sha256sum wget
toolset shasum "${base[@]}" shasum perl curl
toolset nosha "${base[@]}" curl

# --- The fake host ----------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -subj /CN=127.0.0.1 -days 1 >/dev/null 2>&1 && cat "$tmp/key.pem" "$tmp/cert.pem" >"$srv/tls.pem"
if ! ports="$(python3 -I "$repo_dir/tests/get_fake_release.py" "$srv")"; then
    echo "  FAIL: the fake release host did not start" >&2
    exit 1
fi
read -r host_port storage_port tls_port server_pid <<<"$ports"
log="$srv/requests.log"
dash="$(command -v dash)"

# The released get.sh carries its version; 11.6's release.sh makes this edit.
sed "s/^stamped=''\$/stamped='1.1.0'/" "$repo_dir/get.sh" >"$tmp/get.sh"
cp "$repo_dir/get.sh" "$tmp/unstamped.sh"

# run SHELL MODE [ARG…] — get.sh ($getsh) under dash or busybox sh, as a file,
# piped into `sh -s --` (pipe) or on a terminal (tty, dash only), with the
# environment in envs, PATH = $extra then the tool set $tools (dash) or /bin.
# Sets rc; stdout and stderr land in $tmp/stdout and $tmp/stderr.
run() {
    local shell=$1 mode=$2 path
    shift 2
    rm -f "$out"/* "$log"
    rm -rf "${scratch:?}"/*
    local e=(GET_TEST_OUT="$out" GET_TEST_REL="$srv/releases" TMPDIR="$scratch" HOME="$tmp/home"
        KASBAH_GET_BASE="http://127.0.0.1:$host_port/download"
        KASBAH_RELEASES_API="http://127.0.0.1:$host_port/api" "${envs[@]}")
    if [ "$shell" = dash ]; then
        path="${extra:+$extra:}$tmp/tools-$tools"
        case $mode in
            file) setsid -w env -i PATH="$path" "${e[@]}" "$dash" "$getsh" "$@" </dev/null ;;
            pipe) cat "$getsh" | setsid -w env -i PATH="$path" "${e[@]}" "$dash" -s -- "$@" ;;
            tty) env -i PATH="$path" SHELL=/bin/sh "${e[@]}" "$(command -v script)" -qec "$dash $getsh $*" /dev/null </dev/null ;;
        esac >"$tmp/stdout" 2>"$tmp/stderr"
        rc=$?
    else
        path="${extra:+$extra:}/bin"
        local d=(docker run --rm -i --network host --user "$(id -u):$(id -g)" -v "$tmp:$tmp" "${dopts[@]}" -e PATH="$path")
        for v in "${e[@]}"; do d+=(-e "$v"); done
        case $mode in
            file) "${d[@]}" "$busybox" sh "$getsh" "$@" </dev/null ;;
            pipe) cat "$getsh" | "${d[@]}" "$busybox" sh -s -- "$@" ;;
        esac >"$tmp/stdout" 2>"$tmp/stderr"
        rc=$?
    fi
    if ! clean; then
        echo "  FAIL: [$shell] temp dir left after: ${envs[*]} get.sh $*: $(ls -A "$scratch")" >&2
        fail=1
    fi
}

stub() { cat "$out/stub.log" 2>/dev/null; }
clean() { [ -z "$(ls -A "$scratch")" ]; }
dopts=()

for sh in dash busybox; do
    getsh="$tmp/get.sh" tools=curl extra=''
    [ "$sh" = dash ] || tools=''

    # --- Bare download: arguments through, exit status back, env through --------
    envs=(KASBAH_BIN_DIR=/x/bin KASBAH_LIB_DIR=/x/lib GET_TEST_RC=3)
    run "$sh" file v1.1 --pre --yes
    assert '[ "$rc" = 3 ]' "bare: exit $rc, the stub's 3 expected; $(cat "$tmp/stderr")"
    assert 'grep -qxF "argv: [self-update] [v1.1] [--pre] [--yes]" <<<"$(stub)"' "bare: stub argv: $(stub)"
    assert 'grep -qxF "stdin=/dev/null" <<<"$(stub)"' "bare: stub stdin is not /dev/null: $(stub)"
    assert 'grep -qxF "bin=/x/bin lib=/x/lib token=unset" <<<"$(stub)"' "bare: env not passed through: $(stub)"
    self="$(sed -n 's/^self=//p' "$out/stub.log" 2>/dev/null)"
    assert '[[ "$self" == "$scratch"/tmp.*/kasbah ]]' "bare: the binary ran from '$self', not <mktemp -d>/kasbah"
    assert 'grep -q "^host /download/v1.1.0/kasbah_1.1.0_linux_amd64 auth=-" "$log" && grep -q "^host /download/v1.1.0/checksums.txt auth=-" "$log"' \
        "bare: requests: $(cat "$log")"
    assert 'grep -q "^host /download/v1.1.0/checksums.txt.minisig auth=-" "$log" && [ "$(grep -c . "$log")" = 3 ]' \
        "bare: not exactly the three bare downloads: $(cat "$log")"
    assert 'grep -q "no minisign here: kasbah checks the signature itself" "$tmp/stderr"' "bare: no word on the signature: $(cat "$tmp/stderr")"
    assert 'grep -q "sha256 of kasbah_1.1.0_linux_amd64 matches" "$tmp/stderr"' "bare: no word on the sha256"
    assert clean "bare: temp dir left: $(ls -A "$scratch")"

    # --- No version: this release, verified from the files fetched, no API call ---
    envs=()
    run "$sh" file --yes
    tmpd="$(sed -n 's/^self=\(.*\)\/kasbah$/\1/p' "$out/stub.log" 2>/dev/null)"
    assert '[ "$rc" = 0 ] && [[ "$tmpd" == "$scratch"/tmp.* ]] && grep -qxF "argv: [self-update] [v1.1.0] [--from] [$tmpd] [--yes]" <<<"$(stub)"' \
        "no version: exit $rc, stub: $(stub)"
    assert 'grep -qxF "has=$tmpd/checksums.txt" <<<"$(stub)" && grep -qxF "has=$tmpd/checksums.txt.minisig" <<<"$(stub)"' \
        "no version: the files were not beside the binary at the hand-off: $(stub)"
    assert '! grep -q /api/ "$log" && [ "$(grep -c . "$log")" = 3 ]' "no version: requests beyond the three downloads: $(cat "$log")"
    assert clean "no version: temp dir left"

    # --- Its own version named: the same hand-off, no API call -----------------
    run "$sh" file 1.1.0
    tmpd="$(sed -n 's/^self=\(.*\)\/kasbah$/\1/p' "$out/stub.log" 2>/dev/null)"
    assert '[ "$rc" = 0 ] && grep -qxF "argv: [self-update] [v1.1.0] [--from] [$tmpd]" <<<"$(stub)" && ! grep -q /api/ "$log"' \
        "own version named: exit $rc, stub: $(stub)"

    # --- curl | sh -s -- v1: the stub's stdin is not the script's pipe ----------
    envs=()
    run "$sh" pipe v1
    assert '[ "$rc" = 0 ]' "pipe: exit $rc; $(cat "$tmp/stderr")"
    assert 'grep -qxF "argv: [self-update] [v1]" <<<"$(stub)" && grep -qxF "stdin=/dev/null" <<<"$(stub)"' "pipe: stub: $(stub)"
    assert clean "pipe: temp dir left"

    # --- A checksum mismatch: the stub never runs --------------------------------
    envs=(KASBAH_GET_VERSION=1.2.0)
    run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ]' "mismatch: exit $rc, stub: $(stub)"
    assert 'grep -q "kasbah_1.2.0_linux_amd64 does not match checksums.txt: nothing was installed" "$tmp/stderr"' "mismatch: $(cat "$tmp/stderr")"
    assert clean "mismatch: temp dir left"

    # --- The stub fails, or kills get.sh: the temp dir still goes ---------------
    envs=(GET_TEST_RC=7)
    run "$sh" file
    assert '[ "$rc" = 7 ] && clean' "stub fails: exit $rc (7 expected), temp: $(ls -A "$scratch")"
    envs=(GET_TEST_KILL=1)
    run "$sh" file
    assert '[ "$rc" = 143 ] && clean' "SIGTERM: exit $rc (143 expected), temp: $(ls -A "$scratch")"

    # --- Unstamped --------------------------------------------------------------
    envs=()
    getsh="$tmp/unstamped.sh" run "$sh" file
    assert '[ "$rc" = 1 ] && grep -q "not from a release: use https://github.com/adigourdi/kasbah/releases/latest/download/get.sh" "$tmp/stderr"' \
        "unstamped: exit $rc: $(cat "$tmp/stderr")"
    assert '[ ! -e "$log" ]' "unstamped: requests made"

    # --- Platforms ---------------------------------------------------------------
    # macOS: the darwin binary, and both linux server builds for --from.
    extra="$tmp/uname-darwin" run "$sh" file
    assert '[ "$rc" = 0 ] && [ "$(grep -c "^host /download/v1.1.0/" "$log")" = 5 ]' "darwin: exit $rc, not five downloads: $(cat "$log") $(cat "$tmp/stderr")"
    for a in kasbah_1.1.0_darwin_arm64 kasbah_1.1.0_linux_amd64 kasbah_1.1.0_linux_arm64; do
        assert 'grep -q "^host /download/v1.1.0/$a " "$log" && grep -q "sha256 of $a matches checksums.txt" "$tmp/stderr"' "darwin: $a fetched and checked: $(cat "$log") $(cat "$tmp/stderr")"
    done
    assert '! grep -q "darwin_amd64" "$log"' "darwin arm64: the amd64 build fetched: $(cat "$log")"
    tmpd="$(sed -n 's/^self=\(.*\)\/kasbah$/\1/p' "$out/stub.log" 2>/dev/null)"
    assert '[ -n "$tmpd" ] && grep -qxF "argv: [self-update] [v1.1.0] [--from] [$tmpd]" <<<"$(stub)"' "darwin: --from the downloads: $(stub)"
    assert 'grep -qxF "has=$tmpd/kasbah_1.1.0_linux_amd64" <<<"$(stub)" && grep -qxF "has=$tmpd/kasbah_1.1.0_linux_arm64" <<<"$(stub)"' \
        "darwin: the linux builds sit in the --from directory: $(stub)"
    assert 'grep -q "kasbah 1.1.0 for darwin/arm64" "$tmp/stderr"' "darwin: the platform said: $(cat "$tmp/stderr")"
    extra="$tmp/uname-darwin-x86" run "$sh" file
    assert '[ "$rc" = 0 ] && grep -q "^host /download/v1.1.0/kasbah_1.1.0_darwin_amd64 " "$log" && ! grep -q "darwin_arm64" "$log"' "darwin x86_64: exit $rc: $(cat "$log")"
    extra="$tmp/uname-rosetta" run "$sh" file
    assert '[ "$rc" = 0 ] && grep -q "^host /download/v1.1.0/kasbah_1.1.0_darwin_arm64 " "$log"' "rosetta: the arm64 build: exit $rc: $(cat "$log")"
    # A server build that does not match: nothing runs.
    envs=(KASBAH_GET_VERSION=1.2.0)
    extra="$tmp/uname-darwin" run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "kasbah_1.2.0_linux_amd64 does not match checksums.txt: nothing was installed" "$tmp/stderr"' \
        "darwin, a server build mismatched: exit $rc: $(cat "$tmp/stderr")"
    envs=()
    extra="$tmp/uname-freebsd" run "$sh" file
    assert '[ "$rc" = 1 ] && grep -q "kasbah runs on Linux or macOS, not FreeBSD" "$tmp/stderr" && [ ! -e "$log" ]' "freebsd: exit $rc: $(cat "$tmp/stderr")"
    extra="$tmp/uname-riscv" run "$sh" file
    assert '[ "$rc" = 1 ] && grep -q "no build for riscv64" "$tmp/stderr" && [ ! -e "$log" ]' "riscv64: exit $rc: $(cat "$tmp/stderr")"
    extra="$tmp/uname-arm" run "$sh" file
    assert '[ "$rc" = 0 ] && grep -q "^host /download/v1.1.0/kasbah_1.1.0_linux_arm64 " "$log"' "aarch64: exit $rc: $(cat "$log")"

    # --- Arguments ---------------------------------------------------------------
    for bad in --force "v1 v2" "v1 1.2" "v1;x" v1.x 1..2 v01 v1.02 v 1.2.3.4 1.2.3-rc. v1.2-rc.1 v1.2.3-beta v99999999999999999999 1.2.3-rc.99999999999999999999 --pre "--pre --yes"; do
        # shellcheck disable=SC2086
        run "$sh" file $bad
        assert '[ "$rc" = 2 ] && grep -q "^usage: curl" "$tmp/stderr" && [ ! -e "$log" ]' "argument '$bad': exit $rc: $(cat "$tmp/stderr")"
    done
    for ok in "1.2.3 v1.2.3" "1.1 v1.1" "1.2.3-rc.4 v1.2.3-rc.4" "v0 v0" "v9999999999999999999 v9999999999999999999"; do
        run "$sh" file "${ok% *}" --pre
        assert '[ "$rc" = 0 ] && grep -qxF "argv: [self-update] [${ok#* }] [--pre]" <<<"$(stub)"' "argument '${ok% *}': exit $rc, stub: $(stub)"
    done
    run "$sh" file --help
    assert '[ "$rc" = 0 ] && grep -q "^usage: curl" "$tmp/stdout"' "--help: exit $rc"

    # --- Private: bare 404, no token, gh on PATH → gh release download ------------
    touch "$srv/private"
    envs=() extra="$tmp/gh"
    run "$sh" file v1
    assert '[ "$rc" = 0 ] && grep -qxF "argv: [self-update] [v1]" <<<"$(stub)"' "gh rung: exit $rc: $(cat "$tmp/stderr")"
    assert 'grep -qx "release download v1.1.0 --repo adigourdi/kasbah -p kasbah_1.1.0_linux_amd64 -p checksums.txt -p checksums.txt.minisig -D $scratch/tmp\.[^ ]* --clobber" "$out/gh.log"' \
        "gh rung: gh argv: $(cat "$out/gh.log" 2>/dev/null)"
    assert '! grep -q "auth token" "$out/gh.log"' "gh rung: gh's token asked for an API that is not GitHub's"
    assert clean "gh rung: temp dir left"

    # --- Private, nothing works: every rung named --------------------------------
    envs=(GITHUB_TOKEN=sekret) extra=''
    run "$sh" file
    if [ "$sh" = dash ]; then why_api="release v1.1.0: curl: (22)"; else why_api="needs curl"; fi
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ]' "no rung: exit $rc"
    assert 'grep -q "^  \(curl\|wget\) from http://127.0.0.1:$host_port/download: " "$tmp/stderr" &&
        grep -qF "  releases API (http://127.0.0.1:$host_port/api): $why_api" "$tmp/stderr" &&
        grep -qF "  gh release download: gh is not on PATH" "$tmp/stderr" &&
        grep -q "GITHUB_TOKEN set, or gh logged in" "$tmp/stderr"' "no rung: $(cat "$tmp/stderr")"
    assert clean "no rung: temp dir left"
    rm -f "$srv/private"

    # --- minisign on PATH: the signature fetched and checked against the key ------
    key="$(sed -n 2p "$repo_dir/release.pub")"
    envs=() extra="$tmp/minisign"
    run "$sh" file
    assert '[ "$rc" = 0 ] && grep -q "^host /download/v1.1.0/checksums.txt.minisig " "$log"' "minisign: exit $rc: $(cat "$tmp/stderr")"
    assert 'grep -qx -- "-Vm $scratch/tmp\.[^ ]*/checksums.txt -P $key" "$out/minisign.log" && grep -q "^sig beside" "$out/minisign.log"' \
        "minisign: args: $(cat "$out/minisign.log" 2>/dev/null)"
    envs=(GET_TEST_MINISIGN_RC=1)
    run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "does not verify against release.pub" "$tmp/stderr" && clean' \
        "minisign fails: exit $rc: $(cat "$tmp/stderr")"
    extra=''

    # --- The binary is checked before the hand-off -----------------------------
    envs=(KASBAH_GET_VERSION=1.3.0)
    run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "answers .kasbah 1.1.0 (schema 1)., not kasbah 1.3.0" "$tmp/stderr"' \
        "wrong --version: exit $rc: $(cat "$tmp/stderr")"
    envs=(KASBAH_GET_VERSION=1.5.0)
    run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "checksums.txt lists no kasbah_1.5.0_linux_amd64" "$tmp/stderr"' \
        "checksums.txt without the asset: exit $rc: $(cat "$tmp/stderr")"
    envs=(KASBAH_GET_VERSION=1.6.0)
    run "$sh" file
    assert '[ "$rc" = 0 ] && grep -q "^argv: \[self-update\] \[v1.6.0\] \[--from\] " <<<"$(stub)"' "checksums.txt CRLF and *name: exit $rc: $(cat "$tmp/stderr")"

    # --- A release without a signature: every rung fails naming it -------------
    envs=(KASBAH_GET_VERSION=1.8.0) extra="$tmp/gh"
    run "$sh" file
    assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "download: .* 404.* (checksums.txt.minisig)$" "$tmp/stderr" &&
        grep -q "^  gh release download: .*checksums.txt.minisig" "$tmp/stderr" && ! grep -q "private repository" "$tmp/stderr"' \
        "no signature: exit $rc: $(cat "$tmp/stderr")"
    assert clean "no signature: temp dir left"
    extra=''

    # --- The private-repository hint only after a 404 on the binary --------------
    envs=(KASBAH_GET_VERSION=1.4.0)
    run "$sh" file
    assert '[ "$rc" = 1 ] && grep -q "download: .* 404.* (checksums.txt)$" "$tmp/stderr" && ! grep -q "private repository" "$tmp/stderr"' \
        "a release without checksums.txt: exit $rc: $(cat "$tmp/stderr")"
    envs=(KASBAH_GET_BASE=http://127.0.0.1:1/download)
    run "$sh" file
    assert '[ "$rc" = 1 ] && grep -q "127.0.0.1:1/download: .*(kasbah_1.1.0_linux_amd64)$" "$tmp/stderr" && ! grep -q "private repository" "$tmp/stderr"' \
        "network error: exit $rc: $(cat "$tmp/stderr")"
    envs=()
done

# --- busybox only: a noexec temp dir, wget without certificate checks -------------
sh=busybox getsh="$tmp/get.sh" tools='' extra=''
envs=(TMPDIR=/tmp) dopts=(--tmpfs /tmp:rw,noexec,mode=1777)
run busybox file
assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "cannot run /tmp/tmp\.[^/]*/kasbah: its temp dir does not allow execution" "$tmp/stderr" &&
    grep -q "set TMPDIR to a directory that does" "$tmp/stderr"' "noexec: exit $rc: $(cat "$tmp/stderr")"
dopts=()
envs=(KASBAH_GET_BASE="https://127.0.0.1:$tls_port/download")
run busybox file
assert '[ "$rc" = 1 ] && [ ! -e "$out/stub.log" ] && grep -q "this wget does not check TLS certificates" "$tmp/stderr" &&
    grep -q "^tls /download/v1.1.0/kasbah_1.1.0_linux_amd64 " "$log"' "wget without TLS checks: exit $rc: $(cat "$tmp/stderr")"
extra="$tmp/minisign" run busybox file
assert '[ "$rc" = 0 ] && grep -q "signature verified with minisign" "$tmp/stderr"' "wget without TLS checks, minisign: exit $rc: $(cat "$tmp/stderr")"
# The bare rung fetched the binary over unchecked TLS, then gave up; gh delivered.
envs=(KASBAH_GET_BASE="https://127.0.0.1:$tls_port/download" KASBAH_GET_VERSION=1.7.0 GET_TEST_REL="$tmp/ghrel")
extra="$tmp/gh" run busybox file
assert '[ "$rc" = 0 ] && grep -q "fetched with gh release download" "$tmp/stderr" && ! grep -q "does not check TLS" "$tmp/stderr" &&
    grep -q "^tls /download/v1.7.0/kasbah_1.7.0_linux_amd64 " "$log" && grep -q "^tls /download/v1.7.0/checksums.txt " "$log"' \
    "wget without TLS checks, then gh: exit $rc: $(cat "$tmp/stderr")"
envs=()

# --- dash only: the token rung (curl), tools, a terminal --------------------------
sh=dash getsh="$tmp/get.sh" tools=curl extra=''
api=/api/repos/adigourdi/kasbah/releases
echo sekret >"$srv/token"
touch "$srv/private"
for style in compact pretty; do
    echo "$style" >"$srv/json"
    envs=(GITHUB_TOKEN=sekret)
    run dash file v1
    assert '[ "$rc" = 0 ] && grep -qxF "argv: [self-update] [v1]" <<<"$(stub)" && grep -q "token=sekret" <<<"$(stub)"' \
        "token $style: exit $rc: $(cat "$tmp/stderr")"
    assert 'grep -q "^host $api/tags/v1.1.0 auth=Bearer sekret accept=application/vnd.github+json$" "$log"' "token $style: no API call: $(cat "$log")"
    assert '[ "$(grep -c "^host $api/assets/[0-9]* auth=Bearer sekret accept=application/octet-stream$" "$log")" = 3 ]' \
        "token $style: asset requests: $(cat "$log")"
    # The redirect stays on the API's own host and port: only get.sh can keep the token off it.
    assert '[ "$(grep -c "^host /blob/v1.1.0/\(kasbah_1.1.0_linux_amd64\|checksums.txt\|checksums.txt.minisig\) auth=- " "$log")" = 3 ] && ! grep -q "^host /blob/.*auth=[^-]" "$log"' \
        "token $style: redirected requests (the token must not reach them): $(cat "$log")"
    assert '! grep -q sekret "$out/curl.argv"' "token $style: the token on curl's command line"
    assert 'grep -q "fetched through the releases API" "$tmp/stderr"' "token $style: no word on the rung"
    assert clean "token $style: temp dir left"
done

envs=("GITHUB_TOKEN=$(printf ' sekret\n\t')")
run dash file
assert '[ "$rc" = 0 ] && grep -q "^host $api/tags/v1.1.0 auth=Bearer sekret " "$log"' "token with whitespace: exit $rc: $(cat "$tmp/stderr")"
envs=(GITHUB_TOKEN=sek/ret)
run dash file
assert '[ "$rc" = 1 ] && grep -q "the token from GITHUB_TOKEN holds characters no GitHub token has" "$tmp/stderr" && ! grep -q /api/ "$log"' \
    "token with a slash: exit $rc: $(cat "$tmp/stderr")"
envs=(GITHUB_TOKEN=sekret KASBAH_GET_VERSION=1.4.0)
run dash file
assert '[ "$rc" = 1 ] && grep -q "the release v1.4.0 lists no asset checksums.txt" "$tmp/stderr"' "asset not in the JSON: exit $rc: $(cat "$tmp/stderr")"
envs=(GITHUB_TOKEN=sekret KASBAH_GET_VERSION=1.8.0)
run dash file
assert '[ "$rc" = 1 ] && grep -q "the release v1.8.0 lists no asset checksums.txt.minisig" "$tmp/stderr" && [ ! -e "$out/stub.log" ] && clean' \
    "no signature, token: exit $rc: $(cat "$tmp/stderr")"
touch "$srv/nolocation"
envs=(GITHUB_TOKEN=sekret)
run dash file
assert '[ "$rc" = 1 ] && grep -q "kasbah_1.1.0_linux_amd64: HTTP 302 without a location" "$tmp/stderr"' "302 without Location: exit $rc: $(cat "$tmp/stderr")"
rm -f "$srv/nolocation"

envs=(GITHUB_TOKEN=wrong)
run dash file
assert '[ "$rc" = 1 ] && grep -qF "releases API (http://127.0.0.1:$host_port/api): release v1.1.0: curl: (22)" "$tmp/stderr"' \
    "wrong token: exit $rc: $(cat "$tmp/stderr")"

touch "$srv/outside"
envs=(GITHUB_TOKEN=sekret)
run dash file
assert '[ "$rc" = 1 ] && grep -q "kasbah_1.1.0_linux_amd64 at http://127.0.0.1:$storage_port/repos/adigourdi/kasbah/releases/assets/[0-9]*, outside http://127.0.0.1:$host_port/api: not fetched" "$tmp/stderr"' \
    "outside: exit $rc: $(cat "$tmp/stderr")"
assert '! grep -q "^storage " "$log"' "outside: the storage host was asked: $(cat "$log")"
rm -f "$srv/outside"

envs=(GITHUB_TOKEN=sekret) tools=wget
run dash file
assert '[ "$rc" = 1 ] && grep -qF "releases API (http://127.0.0.1:$host_port/api): needs curl" "$tmp/stderr" && ! grep -q /api/ "$log"' \
    "wget, token: exit $rc: $(cat "$tmp/stderr")"
rm -f "$srv/private" "$srv/token"

envs=() tools=wget
run dash file
assert '[ "$rc" = 0 ] && grep -q "^host /download/v1.1.0/kasbah_1.1.0_linux_amd64 " "$log"' "wget: exit $rc: $(cat "$tmp/stderr")"
tools=shasum
run dash file
assert '[ "$rc" = 0 ] && grep -q "sha256 of kasbah_1.1.0_linux_amd64 matches" "$tmp/stderr"' "shasum: exit $rc: $(cat "$tmp/stderr")"
# A Mac has shasum, not sha256sum.
extra="$tmp/uname-darwin" run dash file
assert '[ "$rc" = 0 ] && [ "$(grep -c "^get.sh: sha256 of .* matches checksums.txt" "$tmp/stderr")" = 3 ]' "shasum, darwin: exit $rc: $(cat "$tmp/stderr")"
extra=''
tools=nosha
run dash file
assert '[ "$rc" = 1 ] && grep -q "neither sha256sum nor shasum" "$tmp/stderr" && [ ! -e "$log" ]' "no sha tool: exit $rc: $(cat "$tmp/stderr")"

tools=curl
run dash tty v1
assert 'grep -qxF "stdin=/dev/tty" <<<"$(stub)"' "tty: the stub's stdin is not the terminal: $(stub)"

# --- Static: the stamp line, the key, shellcheck ---------------------------------
sh=static
# 11.6's release.sh rewrites the one line stamped='' — it must stay exactly that.
if [ "$(grep -c '^stamped=' "$repo_dir/get.sh")" != 1 ] || ! grep -qxF "stamped=''" "$repo_dir/get.sh"; then
    echo "  FAIL: get.sh must hold exactly one stamp line, stamped=''" >&2
    fail=1
fi
key="$(sed -n 2p "$repo_dir/release.pub")"
if ! grep -qxF "kasbah_key='$key'" "$repo_dir/get.sh"; then
    echo "  FAIL: get.sh's kasbah_key is not release.pub's key ($key)" >&2
    fail=1
fi
if ! lint="$(docker run --rm -v "$repo_dir/get.sh:/mnt/get.sh:ro" "$shellcheck" -s sh /mnt/get.sh 2>&1)"; then
    echo "  FAIL: shellcheck -s sh get.sh:" >&2
    printf '%s\n' "$lint" >&2
    fail=1
fi

exit "$fail"
