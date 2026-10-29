#!/usr/bin/env bash
# Test: release.sh — the refusals, the double build, the asset names, get.sh
# stamped with the version, the checksums file, the stamp check, the
# signature, the tag, the GitHub release and which one is latest; the stage
# and flags subcommands, and that the workflow runs them and uploads what stage
# writes; VERSION is left alone.
#
# Hermetic. `docker` and `gh` are stubs on PATH that record every invocation:
# the docker stub plays the compose build (fixed bytes into dist/, or bytes
# that drift on the second build when asked; it fails unless HEAD carries the
# tag v<VERSION> on a clean tree, what makes tools/stamp's stamp exact) and
# the minisign container; the gh
# stub records the release and keeps copies of what it was handed. git is real,
# against a throwaway repository whose origin is a bare repo beside it, so a
# pushed tag is a fact in that bare repo and never a network.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
need_yaml2json

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- The stubs ------------------------------------------------------------------

stub_dir="$tmpdir/stub"
fakehome="$tmpdir/home"
mkdir -p "$stub_dir" "$fakehome"

export DOCKER_LOG="$tmpdir/docker.log"
export GH_LOG="$tmpdir/gh.log"
export GH_KEEP="$tmpdir/gh-keep"
export TEST_SH_LOG="$tmpdir/test-sh.log"
export BUILD_COUNT="$tmpdir/build-count"
export VERIFY_SAW_PUB="$tmpdir/verify-saw-pub"

# Mounts map container paths back to the host, so the minisign stub writes
# where the real one would. The build writes dist/ in the current directory,
# which release.sh has made the repo.
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
host_of() {
    local m
    for m in "${mounts[@]}"; do
        local h=${m%%:*} rest=${m#*:} c
        c=${rest%%:*}
        case "$1" in "$c"/*) printf '%s\n' "$h${1#"$c"}"; return ;; esac
    done
    echo "docker stub: no mount for $1" >&2; exit 9
}
mounts=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = -v ] && mounts+=("${args[i+1]}")
done
case " $* " in
    *" run --rm -T build "*)
        on_head="$(git tag --points-at HEAD)"
        if ! grep -qx "v$(tr -d '\r\n' <VERSION)" <<<"$on_head"; then
            echo "docker stub: the build ran with HEAD untagged — the stamp would carry a count and a time" >&2
            exit 9
        fi
        if [ -n "$(git status --porcelain)" ]; then
            echo "docker stub: the build ran on a dirty tree — the stamp would carry .dirty" >&2
            exit 9
        fi
        printf '%s\n' "${KASBAH_GOOS-unset}" > "$BUILD_COUNT.goos"
        n=$(( $(cat "$BUILD_COUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$BUILD_COUNT"
        salt=
        [ -n "${BUILD_DRIFT:-}" ] && [ "$n" -ge 2 ] && salt="-$n"
        mkdir -p dist/server dist/darwin
        # dist/kasbah answers --version as the real build would: the tag's
        # version exactly, or what STUB_STAMP says instead.
        printf '#!/bin/sh\necho "kasbah %s (schema 1)"\n# fake kasbah%s\n' "${STUB_STAMP:-$(tr -d '\r\n' <VERSION)}" "$salt" > dist/kasbah
        chmod 0755 dist/kasbah
        printf 'fake kasbah linux/amd64%s\n' "$salt" > dist/server/kasbah-linux-amd64
        printf 'fake kasbah linux/arm64%s\n' "$salt" > dist/server/kasbah-linux-arm64
        printf 'fake kasbah darwin/amd64%s\n' "$salt" > dist/darwin/kasbah-darwin-amd64
        printf 'fake kasbah darwin/arm64%s\n' "$salt" > dist/darwin/kasbah-darwin-arm64
        echo "built kasbah (stub $n)" ;;
    *" jedisct1/minisign -S "*)
        printf 'fake signature\n' > "$(host_of /work/checksums.txt.minisig)" ;;
    *" jedisct1/minisign -V "*)
        cp "$(host_of /work/release.pub)" "$VERIFY_SAW_PUB"
        exit "${MINISIGN_V_RC:-0}" ;;
    *" jedisct1/minisign -G "*)
        for ((i = 0; i < ${#args[@]}; i++)); do
            case "${args[i]}" in
                -p) printf 'fake public key\n' > "$(host_of "${args[i+1]}")" ;;
                -s) printf 'fake secret key\n' > "$(host_of "${args[i+1]}")" ;;
            esac
        done ;;
esac
exit 0
STUB

# release create: every file argument is copied aside, since the scratch
# directory they live in is gone when the case looks.
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
    "auth status") exit "${GH_AUTH_RC:-0}" ;;
    "release view") [ "${GH_RELEASE_EXISTS:-}" = 1 ] || exit 1
        [ "${4:-}" = --json ] && echo "https://github.example/releases/tag/$3" ;;
    "release create"|"release upload")
        rm -rf "$GH_KEEP"; mkdir -p "$GH_KEEP"
        for a; do [ -f "$a" ] && cp "$a" "$GH_KEEP/$(basename "$a")"; done
        [ "$2" = create ] && [ -n "${GH_CREATE_RC:-}" ] && exit "$GH_CREATE_RC"
        echo "https://github.example/releases/tag/$3" ;;
esac
exit 0
STUB
chmod 0755 "$stub_dir"/*

export PATH="$stub_dir:$PATH"
export HOME="$fakehome"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# --- A fresh repository per case ------------------------------------------------

repo="$tmpdir/repo"
origin="$tmpdir/origin.git"
key_dir="$tmpdir/keys"
export KASBAH_RELEASE_KEY="$key_dir/release.key"

# fresh <version> — a committed, pushed repo holding release.sh, a VERSION, a
# test.sh that passes (TEST_SH_RC otherwise) and logs, and the key pair.
fresh() {
    rm -rf "$repo" "$origin" "$key_dir" "$DOCKER_LOG" "$GH_LOG" "$GH_KEEP" "$TEST_SH_LOG" "$BUILD_COUNT" "$BUILD_COUNT.goos" "$VERIFY_SAW_PUB"
    mkdir -p "$repo" "$key_dir"
    cp "$repo_dir/release.sh" "$repo_dir/get.sh" "$repo/"
    printf '%s\n' "$1" > "$repo/VERSION"
    printf 'fake public key\n' > "$repo/release.pub"
    printf 'fake secret key\n' > "$key_dir/release.key"
    cat > "$repo/test.sh" <<'T'
#!/usr/bin/env bash
printf 'test.sh %s\n' "$*" >> "$TEST_SH_LOG"
exit "${TEST_SH_RC:-0}"
T
    chmod 0755 "$repo/test.sh" "$repo/release.sh"
    printf 'dist/\n' > "$repo/.gitignore"
    git init -q -b main "$repo"
    git init -q --bare "$origin"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "first commit"
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" push -q origin main
}

# release <args…> — runs release.sh in the repo without a terminal; stdout and
# stderr in $out and $err, exit status in $rc.
out= err= rc=
release() {
    out="$(cd "$repo" && ./release.sh "$@" 2>"$tmpdir/err" </dev/null)"; rc=$?
    err="$(cat "$tmpdir/err")"
}

origin_tags() { git --git-dir="$origin" tag; }
local_tags() { git -C "$repo" tag; }

# A refusal leaves nothing behind: no tag here or at origin, no release.
assert_nothing_released() {
    assert '[ "$rc" = 1 ]' "$1: refused with exit 1 (exit $rc: $err)"
    assert '[ -z "$(local_tags)" ]' "$1: no tag created (got $(local_tags | tr '\n' ' '))"
    assert '[ -z "$(origin_tags)" ]' "$1: nothing pushed (origin has $(origin_tags | tr '\n' ' '))"
    assert '! grep -q "^release create" "$GH_LOG" 2>/dev/null' "$1: no release created"
}

# --- Case 1: a release, end to end ---------------------------------------------

fresh 1.2.3
git -C "$repo" commit -q --allow-empty -m "second commit"
git -C "$repo" push -q origin main
release v1.2.3
assert '[ "$rc" = 0 ]' "v1.2.3 releases (exit $rc: $err)"
assert '[ "$(git -C "$repo" cat-file -t v1.2.3 2>/dev/null)" = tag ]' "the tag is annotated"
assert '[ "$(git -C "$repo" rev-parse v1.2.3^{commit})" = "$(git -C "$repo" rev-parse HEAD)" ]' "and on HEAD"
assert '[ "$(origin_tags)" = v1.2.3 ]' "the tag was pushed to origin (origin has '$(origin_tags | tr '\n' ' ')')"
assert '[ "$(grep -c "^test.sh" "$TEST_SH_LOG")" = 1 ]' "test.sh ran once"
builds="$(grep -c "compose --progress quiet -p kasbah -f $repo/compose.yml run --rm -T build" "$DOCKER_LOG")"
assert '[ "$builds" = 2 ]' "the compose build ran twice, quietly, with -p kasbah (ran $builds times)"
assert '[ "$(cat "$BUILD_COUNT.goos")" = linux ]' "with dist/kasbah built for this host, linux (KASBAH_GOOS=$(cat "$BUILD_COUNT.goos"))"
sign="$(grep "jedisct1/minisign -S" "$DOCKER_LOG")"
scratch_of_sign="$(sed -n 's/.* -v \([^ ]*\):\/work -w .*/\1/p' <<<"$sign")"
assert '[ -n "$sign" ]' "checksums.txt was signed through the minisign container"
assert 'grep -q -- "-v $key_dir:/keys:ro" <<<"$sign"' "with the key directory mounted read-only (got: $sign)"
assert 'grep -q -- "-s /keys/release.key -t kasbah 1.2.3 -m checksums.txt" <<<"$sign"' "the secret key, the trusted comment, the file (got: $sign)"
assert 'grep -q -- "run --rm -i --user $(id -u):$(id -g) " <<<"$sign"' "as this user, without a TTY when stdin is not one (got: $sign)"
verify="$(grep "jedisct1/minisign -V" "$DOCKER_LOG")"
assert 'grep -q -- "-v $scratch_of_sign:/work:ro -w /work jedisct1/minisign -V -p release.pub -m checksums.txt" <<<"$verify"' \
    "the signature was verified against release.pub from the scratch mount, read-only (got: $verify)"
assert 'cmp -s "$VERIFY_SAW_PUB" "$repo/release.pub"' "and the release.pub it verified with is the repo's copy"
assert 'grep -q "^release view v1.2.3$" "$GH_LOG"' "the release was looked up before being created"
assert '! grep -q "^release upload" "$GH_LOG"' "and not uploaded to, since it did not exist"
create="$(grep "^release create" "$GH_LOG")"
assert '[ -n "$create" ]' "gh release create was called"
assert 'grep -q "^release create v1.2.3 --title kasbah 1.2.3 --notes-file " <<<"$create"' "with the tag and the title (got: $create)"
for a in kasbah_1.2.3_linux_amd64 kasbah_1.2.3_linux_arm64 kasbah_1.2.3_darwin_amd64 kasbah_1.2.3_darwin_arm64 get.sh checksums.txt checksums.txt.minisig; do
    assert 'grep -q "/$a\( \|$\)" <<<"$create"' "with asset $a (got: $create)"
    assert '[ -f "$GH_KEEP/$a" ]' "and $a existed when gh was called"
done
assert '! grep -q -- "--prerelease" <<<"$create"' "not a prerelease"
assert 'grep -q -- " --latest " <<<"$create"' "marked latest, the only final (got: $create)"
assert '[ "$(grep -cx "stamped='"'"'1.2.3'"'"'" "$GH_KEEP/get.sh")" = 1 ] && ! grep -qF "stamped='"''"'" "$GH_KEEP/get.sh"' \
    "get.sh carries stamped='1.2.3' once and stamped='' nowhere"
assert '[ "$(sed "s/^stamped='"'"'1.2.3'"'"'\$/stamped='"''"'/" "$GH_KEEP/get.sh")" = "$(cat "$repo_dir/get.sh")" ]' \
    "and is the repo's get.sh otherwise"
assert 'cmp -s "$GH_KEEP/kasbah_1.2.3_linux_amd64" "$repo/dist/server/kasbah-linux-amd64"' "the amd64 asset is the linux/amd64 build"
assert 'cmp -s "$GH_KEEP/kasbah_1.2.3_linux_arm64" "$repo/dist/server/kasbah-linux-arm64"' "the arm64 asset is the linux/arm64 build"
assert 'cmp -s "$GH_KEEP/kasbah_1.2.3_darwin_amd64" "$repo/dist/darwin/kasbah-darwin-amd64" && cmp -s "$GH_KEEP/kasbah_1.2.3_darwin_arm64" "$repo/dist/darwin/kasbah-darwin-arm64"' \
    "the darwin assets are the darwin builds"
expected="$(cd "$GH_KEEP" && sha256sum get.sh kasbah_1.2.3_darwin_amd64 kasbah_1.2.3_darwin_arm64 kasbah_1.2.3_linux_amd64 kasbah_1.2.3_linux_arm64)"
assert '[ "$(cat "$GH_KEEP/checksums.txt")" = "$expected" ]' \
    "checksums.txt is sha256sum's format over the five assets, in name order (got: $(tr '\n' '|' <"$GH_KEEP/checksums.txt"))"
assert '[ "$(wc -l <"$GH_KEEP/checksums.txt")" = 5 ]' "and nothing else"
assert '[ "$(cat "$GH_KEEP/checksums.txt.minisig")" = "fake signature" ]' "the minisig is what minisign wrote"
notes="$(sed -n 's/.*--notes-file \([^ ]*\).*/\1/p' <<<"$create")"
assert '[ "$(cat "$GH_KEEP/$(basename "$notes")")" = "$(printf -- "- second commit\n- first commit")" ]' \
    "the notes are every commit subject when there is no previous tag (got: $(tr '\n' '|' <"$GH_KEEP/$(basename "$notes")"))"
assert '[ "$(cat "$repo/VERSION")" = 1.2.3 ]' "VERSION is left as it was (got $(cat "$repo/VERSION"))"
assert '[ -z "$(git -C "$repo" status --porcelain)" ]' "and the tree is clean after the release ($(git -C "$repo" status --porcelain | tr '\n' ' '))"
assert 'grep -q "^released v1.2.3" <<<"$out" && grep -q "https://github.example/releases/tag/v1.2.3" <<<"$out"' \
    "the summary names the tag and the release URL (got: $out)"
assert 'grep -q "assets: kasbah_1.2.3_darwin_amd64 kasbah_1.2.3_darwin_arm64 kasbah_1.2.3_linux_amd64 kasbah_1.2.3_linux_arm64 get.sh checksums.txt checksums.txt.minisig$" <<<"$out"' \
    "the summary lists the seven assets (got: $out)"
assert '[ ! -f "$fakehome/.config/kasbah/release.key" ]' "nothing was written under HOME"

# --- Case 2: notes since the previous tag; an existing tag on HEAD is reused ----

git -C "$repo" commit -q --allow-empty -m "a fix"
printf '1.2.4\n' > "$repo/VERSION"
git -C "$repo" commit -q -m "close 1.2.4" VERSION
git -C "$repo" tag -a v1.2.4 -m "kasbah 1.2.4"
git -C "$repo" push -q origin main
rm -f "$GH_LOG" "$DOCKER_LOG" "$BUILD_COUNT"
release v1.2.4
assert '[ "$rc" = 0 ]' "v1.2.4 releases with the tag already on HEAD (exit $rc: $err)"
assert '[ "$(origin_tags | tr "\n" " ")" = "v1.2.3 v1.2.4 " ]' "and it was pushed (origin has '$(origin_tags | tr '\n' ' ')')"
create="$(grep "^release create" "$GH_LOG")"
notes="$(sed -n 's/.*--notes-file \([^ ]*\).*/\1/p' <<<"$create")"
assert '[ "$(cat "$GH_KEEP/$(basename "$notes")")" = "$(printf -- "- close 1.2.4\n- a fix")" ]' \
    "the notes are the subjects since v1.2.3 (got: $(tr '\n' '|' <"$GH_KEEP/$(basename "$notes")"))"
assert 'grep -q -- " --latest " <<<"$create"' "v1.2.4 after v1.2.3 is latest (got: $create)"

# --- Case 3: a release candidate ------------------------------------------------

fresh 1.3.0-rc.1
release v1.3.0-rc.1
assert '[ "$rc" = 0 ]' "v1.3.0-rc.1 releases (exit $rc: $err)"
create="$(grep "^release create" "$GH_LOG")"
assert 'grep -q -- " --prerelease --latest=false " <<<"$create"' "as a prerelease, never latest (got: $create)"
assert 'grep -q "^stamped='"'"'1.3.0-rc.1'"'"'$" "$GH_KEEP/get.sh"' "get.sh carries the rc's version"
assert 'grep -q "/kasbah_1.3.0-rc.1_linux_amd64" <<<"$create"' "with the version in the asset name (got: $create)"
assert '[ "$(cat "$repo/VERSION")" = 1.3.0-rc.1 ]' "VERSION is left as it was after an rc (got $(cat "$repo/VERSION"))"
assert '[ "$(cat "$BUILD_COUNT")" = 2 ]' "an rc builds twice on its tag, and the builds match"
assert '[ "$(origin_tags)" = v1.3.0-rc.1 ]' "the rc tag was pushed"

# --- Latest: only the highest final version at origin -------------------------

# A final below one already at origin is released but not latest. The higher
# tag is only at origin: origin's tags count, not the clone's.
fresh 1.0.1
git -C "$repo" tag -a v2.0.0 -m "kasbah 2.0.0"
git -C "$repo" push -q origin v2.0.0
git -C "$repo" tag -d v2.0.0 >/dev/null
git -C "$repo" commit -q --allow-empty -m "a fix for 1.0"
git -C "$repo" push -q origin main
release v1.0.1
assert '[ "$rc" = 0 ]' "v1.0.1 releases after v2.0.0 (exit $rc: $err)"
create="$(grep "^release create" "$GH_LOG")"
assert 'grep -q -- " --latest=false " <<<"$create" && ! grep -q -- " --latest " <<<"$create"' \
    "and is not latest (got: $create)"
assert '! grep -q -- "--prerelease" <<<"$create"' "and is no prerelease either"

# flags <tag>, as the workflow runs it, against tags pushed to origin and
# then dropped from the clone.
flags_of() { (cd "$repo" && ./release.sh flags "$1" 2>"$tmpdir/err"); }
origin_has() {
    local t
    for t; do git -C "$repo" tag "$t"; done
    git -C "$repo" push -q origin "$@"
    git -C "$repo" tag -d "$@" >/dev/null
}
fresh 1.0.0
origin_has v1.9.0 v1.10.0
assert '[ "$(flags_of v1.10.0)" = --latest ]' "v1.10.0 above v1.9.0 is latest — versions, not strings ($(flags_of v1.10.0))"
assert '[ "$(flags_of v1.11.0)" = --latest ]' "a final above every tag is latest"
assert '[ "$(flags_of v1.9.1)" = --latest=false ]' "v1.9.1 below v1.10.0 is not ($(flags_of v1.9.1))"
assert '[ "$(flags_of v1.10.1-rc.1)" = "--prerelease --latest=false" ]' "an rc is a prerelease, never latest ($(flags_of v1.10.1-rc.1))"
origin_has v2.0.0-rc.1 v9.9.9-beta v10.0 v3.0.0.1 v4.0.0x release-99.0.0 v05.0.0
assert '[ "$(flags_of v1.10.0)" = --latest ]' "rc and junk tags above it do not count ($(flags_of v1.10.0))"
git -C "$repo" tag v7.0.0
assert '[ "$(flags_of v1.10.0)" = --latest ]' "nor a local tag nobody pushed ($(flags_of v1.10.0))"
git -C "$repo" tag -d v7.0.0 >/dev/null
flags_of v1.10 >/dev/null; rc=$?
assert '[ "$rc" = 1 ]' "flags refuses a tag that is not vX.Y.Z (exit $rc)"
git -C "$repo" remote set-url origin "$tmpdir/nowhere.git"
flags_of v1.10.0 >/dev/null; rc=$?
assert '[ "$rc" = 1 ] && grep -q "could not list origin" "$tmpdir/err"' "flags fails when origin cannot be read (exit $rc: $(cat "$tmpdir/err"))"
release v1.0.0
assert '[ "$rc" = 1 ] && grep -q "could not list origin" <<<"$err"' "a release refuses when origin's tags cannot be read (exit $rc: $err)"
assert '[ -z "$(local_tags)" ] && ! [ -f "$TEST_SH_LOG" ]' "an origin whose tags cannot be read: no tag, test.sh did not run"
assert '! grep -q "^release create" "$GH_LOG" 2>/dev/null' "an origin whose tags cannot be read: no release"

# --- stage <tag> <dir>, as the workflow runs it --------------------------------

fresh 1.2.3
mkdir -p "$repo/dist/server" "$repo/dist/darwin"
printf 'amd64 bytes\n' > "$repo/dist/server/kasbah-linux-amd64"
printf 'arm64 bytes\n' > "$repo/dist/server/kasbah-linux-arm64"
printf 'darwin amd64 bytes\n' > "$repo/dist/darwin/kasbah-darwin-amd64"
printf 'darwin arm64 bytes\n' > "$repo/dist/darwin/kasbah-darwin-arm64"
stage_in() { (cd "$tmpdir" && "$repo/release.sh" stage "$@" >"$tmpdir/out" 2>"$tmpdir/err"); }
stage_in v1.4.0-rc.2 staged; rc=$?
st="$tmpdir/staged"
assert '[ "$rc" = 0 ]' "stage succeeds (exit $rc: $(cat "$tmpdir/err"))"
assert '[ "$(ls "$st" | tr "\n" " ")" = "checksums.txt get.sh kasbah_1.4.0-rc.2_darwin_amd64 kasbah_1.4.0-rc.2_darwin_arm64 kasbah_1.4.0-rc.2_linux_amd64 kasbah_1.4.0-rc.2_linux_arm64 " ]' \
    "a relative DIR is the caller's, holding the six files (got: $(ls "$st" 2>&1 | tr '\n' ' '))"
assert 'cmp -s "$st/kasbah_1.4.0-rc.2_linux_amd64" "$repo/dist/server/kasbah-linux-amd64" && cmp -s "$st/kasbah_1.4.0-rc.2_linux_arm64" "$repo/dist/server/kasbah-linux-arm64"' \
    "the linux binaries are dist/server's"
assert 'cmp -s "$st/kasbah_1.4.0-rc.2_darwin_amd64" "$repo/dist/darwin/kasbah-darwin-amd64" && cmp -s "$st/kasbah_1.4.0-rc.2_darwin_arm64" "$repo/dist/darwin/kasbah-darwin-arm64"' \
    "the darwin binaries dist/darwin's"
assert '[ "$(grep -cx "stamped='"'"'1.4.0-rc.2'"'"'" "$st/get.sh")" = 1 ] && ! grep -qF "stamped='"''"'" "$st/get.sh"' \
    "get.sh is stamped with the version, no v (got: $(grep '^stamped=' "$st/get.sh"))"
assert 'sh -n "$st/get.sh"' "and still parses"
assert '(cd "$st" && sha256sum --quiet -c checksums.txt)' "checksums.txt checks out"
assert '[ "$(cut -d" " -f3 "$st/checksums.txt" | tr "\n" " ")" = "get.sh kasbah_1.4.0-rc.2_darwin_amd64 kasbah_1.4.0-rc.2_darwin_arm64 kasbah_1.4.0-rc.2_linux_amd64 kasbah_1.4.0-rc.2_linux_arm64 " ]' \
    "over the five, in name order (got: $(tr '\n' '|' <"$st/checksums.txt"))"
assert '! [ -f "$DOCKER_LOG" ] && ! [ -f "$GH_LOG" ]' "stage neither builds, signs nor releases"

# The workflow stages and flags through release.sh and uploads what stage
# wrote plus the signature — no more, no less.
wf="$repo_dir/.github/workflows/release.yml"
wf_run() { yaml2json "$wf" | jq -r --arg n "$1" '.jobs.release.steps[] | select(.name == $n) | .run'; }
assert '[ "$(wf_run "Stage assets and checksums")" = "./release.sh stage \"\$TAG\" release" ]' \
    "the workflow stages with ./release.sh stage (got: $(wf_run "Stage assets and checksums"))"
wf_create="$(wf_run "Create the GitHub release")"
assert 'grep -qF "\$(./release.sh flags \"\$TAG\")" <<<"$wf_create" && grep -qF "gh release create \"\$TAG\" --title \"kasbah \$ver\" --notes-file notes.md \"\${flags[@]}\"" <<<"$wf_create"' \
    "the workflow's release takes its flags from ./release.sh flags (got: $wf_create)"
wf_assets="$(sed -n '/gh release create/,$p' <<<"$wf_create" | grep -o 'release/[^" \\]*' | sed 's|^release/||' | LC_ALL=C sort)"
st_assets="$( (ls "$st"; echo checksums.txt.minisig) | sed 's/1\.4\.0-rc\.2/${ver}/' | LC_ALL=C sort)"
assert '[ "$wf_assets" = "$st_assets" ]' \
    "the workflow uploads exactly what stage writes plus the signature (got: $(tr '\n' ' ' <<<"$wf_assets"); want: $(tr '\n' ' ' <<<"$st_assets"))"

rm -rf "$st"
stage_in v1.4 staged; rc=$?
assert '[ "$rc" = 1 ] && ! [ -e "$st" ]' "stage refuses a tag that is not vX.Y.Z (exit $rc)"
stage_in v1.4.0; rc=$?
assert '[ "$rc" = 1 ]' "stage refuses without a DIR (exit $rc)"
printf 'stamped='"''"'\n' >> "$repo/get.sh"
stage_in v1.4.0 staged; rc=$?
assert '[ "$rc" = 1 ] && grep -q "2 times, not once" "$tmpdir/err"' "stage refuses get.sh with the stamp line twice (exit $rc: $(cat "$tmpdir/err"))"
cp "$repo_dir/get.sh" "$repo/get.sh"
printf '  stamped='"''"'\n' >> "$repo/get.sh"
stage_in v1.4.0 staged; rc=$?
assert '[ "$rc" = 1 ] && grep -q "still holds" "$tmpdir/err"' "stage refuses get.sh that keeps a stamped='' it cannot rewrite (exit $rc: $(cat "$tmpdir/err"))"
sed -i "/^stamped=''\$/d" "$repo/get.sh"
rm -rf "$st"
stage_in v1.4.0 staged; rc=$?
assert '[ "$rc" = 1 ] && grep -q "0 times, not once" "$tmpdir/err" && ! [ -e "$st/checksums.txt" ]' \
    "stage refuses get.sh without the stamp line, and writes no checksums.txt (exit $rc: $(cat "$tmpdir/err"))"
cp "$repo_dir/get.sh" "$repo/get.sh"
rm -rf "$st" "$repo/dist/darwin"
stage_in v1.4.0 staged; rc=$?
assert '[ "$rc" = 1 ] && grep -q "no dist/darwin/kasbah-darwin-amd64 — build first" "$tmpdir/err" && ! [ -e "$st" ]' \
    "stage refuses a dist/ without the darwin builds (exit $rc: $(cat "$tmpdir/err"))"
rm -rf "$repo/dist" "$st"
stage_in v1.4.0 staged; rc=$?
assert '[ "$rc" = 1 ] && grep -q "build first" "$tmpdir/err" && ! [ -e "$st" ]' "stage refuses without a build (exit $rc: $(cat "$tmpdir/err"))"

# --- Refusals, each before anything is built ------------------------------------

fresh 1.2.3
release v1.2
assert_nothing_released "a tag that is not vX.Y.Z"
assert '! [ -f "$TEST_SH_LOG" ]' "a tag that is not vX.Y.Z: test.sh did not run"

fresh 1.2.3
echo stray > "$repo/stray"
release v1.2.3
assert_nothing_released "a dirty tree"
assert 'grep -q "not clean" <<<"$err"' "a dirty tree: says so (got: $err)"

fresh 1.2.4-dev
release v1.2.3
assert_nothing_released "VERSION mismatch"
assert 'grep -q "VERSION is 1.2.4-dev, not 1.2.3" <<<"$err"' "VERSION mismatch: names both (got: $err)"

fresh 1.2.3
git -C "$repo" tag v9.9.9
release v1.2.3
assert '[ "$rc" = 1 ]' "another v-tag on HEAD: refused (exit $rc: $err)"
assert '[ "$(local_tags)" = v9.9.9 ]' "another v-tag on HEAD: v1.2.3 not created (tags: $(local_tags | tr '\n' ' '))"
assert '[ -z "$(origin_tags)" ]' "another v-tag on HEAD: nothing pushed"
assert 'grep -q "v9.9.9" <<<"$err"' "another v-tag on HEAD: names it (got: $err)"

fresh 1.2.3
git -C "$repo" tag not-a-version
release v1.2.3
assert '[ "$rc" = 0 ]' "a tag on HEAD that is not a v-tag is ignored (exit $rc: $err)"

fresh 1.2.3
git -C "$repo" commit -q --allow-empty -m "unpushed"
release v1.2.3
assert_nothing_released "an unpushed HEAD"
assert 'grep -q "not on any pushed origin branch" <<<"$err"' "an unpushed HEAD: says so (got: $err)"

fresh 1.2.3
git -C "$repo" commit -q --allow-empty -m "pushed elsewhere"
git init -q --bare "$tmpdir/other.git"
git -C "$repo" remote add other "$tmpdir/other.git" && git -C "$repo" push -q other main
release v1.2.3
rm -rf "$tmpdir/other.git"
assert_nothing_released "a HEAD pushed to a remote that is not origin"
assert 'grep -q "not on any pushed origin branch" <<<"$err"' "a HEAD pushed elsewhere: only origin counts (got: $err)"

fresh 1.2.3
rm "$key_dir/release.key"
release v1.2.3
assert_nothing_released "a missing key"
assert 'grep -q "keygen" <<<"$err"' "a missing key: names the remedy (got: $err)"

fresh 1.2.3
git -C "$repo" rm -q release.pub && git -C "$repo" commit -q -m "no pub" && git -C "$repo" push -q origin main
release v1.2.3
assert_nothing_released "a missing release.pub"
assert 'grep -q "release.pub" <<<"$err" && grep -q "keygen" <<<"$err"' "a missing release.pub: names it and the remedy (got: $err)"

fresh 1.2.3
export GH_AUTH_RC=1
release v1.2.3
unset GH_AUTH_RC
assert_nothing_released "gh not authenticated"
assert '! [ -f "$DOCKER_LOG" ]' "gh not authenticated: nothing built"

fresh 1.2.3
sed -i "/^stamped=''\$/d" "$repo/get.sh"
git -C "$repo" commit -q -am "get.sh unstampable" && git -C "$repo" push -q origin main
release v1.2.3
assert_nothing_released "get.sh without its stamp line"
assert 'grep -q "stamped=" <<<"$err"' "get.sh without its stamp line: says so (got: $err)"
assert '! [ -f "$TEST_SH_LOG" ]' "get.sh without its stamp line: refused before test.sh"

fresh 1.2.3
printf 'stamped='"''"'\n' >> "$repo/get.sh"
git -C "$repo" commit -q -am "get.sh stamped twice" && git -C "$repo" push -q origin main
release v1.2.3
assert_nothing_released "get.sh with its stamp line twice"

assert '! [ -f "$DOCKER_LOG" ] && ! [ -f "$TEST_SH_LOG" ]' "no refusal above reached test.sh or the build"

# --- Refusals after the checks: tests, the double build ------------------------

fresh 1.2.3
export TEST_SH_RC=1
release v1.2.3
unset TEST_SH_RC
assert_nothing_released "a failing test.sh"
assert '[ -f "$TEST_SH_LOG" ] && ! [ -f "$DOCKER_LOG" ]' "a failing test.sh: test.sh ran, nothing built"

fresh 1.2.3
export BUILD_DRIFT=1
release v1.2.3
unset BUILD_DRIFT
assert_nothing_released "two builds that differ"
assert '[ "$(cat "$BUILD_COUNT")" = 2 ]' "two builds that differ: both ran"
assert '! grep -q minisign "$DOCKER_LOG"' "two builds that differ: nothing signed"
assert '[ -z "$(local_tags)" ]' "two builds that differ: the tag made for the build is taken away (tags: $(local_tags | tr '\n' ' '))"
assert 'grep -q "not reproducible" <<<"$err" && grep -q "^first:" <<<"$err" && grep -q "^second:" <<<"$err"' \
    "two builds that differ: both hash sets printed (got: $err)"
assert '[ "$(grep -c "dist/server/kasbah-linux-arm64" <<<"$err")" = 2 ] && [ "$(grep -c "dist/darwin/kasbah-darwin-arm64" <<<"$err")" = 2 ]' "two builds that differ: every file in both sets"

fresh 1.2.3
git -C "$repo" tag -a v1.2.3 -m "kasbah 1.2.3"
export BUILD_DRIFT=1
release v1.2.3
unset BUILD_DRIFT
assert '[ "$rc" = 1 ]' "two builds that differ on a pre-existing tag: refused (exit $rc)"
assert '[ "$(local_tags)" = v1.2.3 ]' "two builds that differ on a pre-existing tag: the tag was not this run's to take away (tags: $(local_tags | tr '\n' ' '))"
assert '[ -z "$(origin_tags)" ]' "two builds that differ on a pre-existing tag: nothing pushed"

# A build whose stamp is not the tag — what another tag on HEAD or a dirty
# tree would give — is refused after the first build, before anything is signed.
fresh 1.2.3
export STUB_STAMP=1.2.4-dev.3.1700000000+gabc1234.dirty
release v1.2.3
unset STUB_STAMP
assert_nothing_released "a build stamped as a pre-release"
assert '[ "$(cat "$BUILD_COUNT")" = 1 ]' "a build stamped as a pre-release: refused after the first build (built $(cat "$BUILD_COUNT") times)"
assert '! grep -q minisign "$DOCKER_LOG"' "a build stamped as a pre-release: nothing signed"
assert 'grep -q "1.2.4-dev.3.1700000000+gabc1234.dirty" <<<"$err" && grep -q "kasbah 1.2.3 (schema N)" <<<"$err"' \
    "a build stamped as a pre-release: names the stamp it got and the one wanted (got: $err)"
assert 'grep -q "untracked" <<<"$err"' "a build stamped as a pre-release: names the likely causes (got: $err)"
fresh 1.2.3
git -C "$repo" tag -a v1.2.3 -m "kasbah 1.2.3"
export STUB_STAMP=1.2.4-dev.3.1700000000+gabc1234
release v1.2.3
unset STUB_STAMP
assert '[ "$rc" = 1 ] && [ "$(local_tags)" = v1.2.3 ] && [ -z "$(origin_tags)" ]' \
    "a build stamped as a pre-release on a pre-existing tag: refused, the tag kept, nothing pushed (exit $rc, tags: $(local_tags | tr '\n' ' '))"

# --- Refusals after signing: the pair, the push, the release --------------------

fresh 1.2.3
export MINISIGN_V_RC=1
release v1.2.3
unset MINISIGN_V_RC
assert_nothing_released "a public key that does not verify the signature"
assert 'grep -q "pair does not match" <<<"$err"' "a public key that does not verify: says so (got: $err)"

fresh 1.2.3
printf '#!/bin/sh\necho "tags are closed" >&2\nexit 1\n' > "$origin/hooks/pre-receive"
chmod 0755 "$origin/hooks/pre-receive"
release v1.2.3
assert '[ "$rc" = 1 ]' "a rejected push: refused (exit $rc)"
assert '[ "$(local_tags)" = v1.2.3 ]' "a rejected push: the local tag stays (tags: $(local_tags | tr '\n' ' '))"
assert '[ -z "$(origin_tags)" ]' "a rejected push: nothing in origin"
assert '! grep -q "^release create" "$GH_LOG"' "a rejected push: no release"
assert 'grep -q "pushing v1.2.3 failed" <<<"$err"' "a rejected push: says so (got: $err)"
assert '[ "$(cat "$repo/VERSION")" = 1.2.3 ]' "a rejected push: VERSION untouched"

fresh 1.2.3
export GH_CREATE_RC=1
release v1.2.3
unset GH_CREATE_RC
assert '[ "$rc" = 1 ]' "a failed release create: refused (exit $rc)"
assert '[ "$(origin_tags)" = v1.2.3 ]' "a failed release create: the tag is already in origin"
assert '[ "$(cat "$repo/VERSION")" = 1.2.3 ]' "a failed release create: VERSION untouched (got $(cat "$repo/VERSION"))"
assert 'grep -q "gh release delete v1.2.3 --cleanup-tag" <<<"$err"' "a failed release create: names the manual remedy (got: $err)"
rm -f "$GH_LOG" "$DOCKER_LOG" "$BUILD_COUNT"
export GH_RELEASE_EXISTS=1
release v1.2.3
unset GH_RELEASE_EXISTS
assert '[ "$rc" = 0 ]' "the rerun succeeds against the half-made release (exit $rc: $err)"
upload="$(grep "^release upload" "$GH_LOG")"
assert 'grep -q "^release upload v1.2.3 .*/checksums.txt.minisig --clobber$" <<<"$upload"' "the rerun replaces the assets (got: $upload)"
assert '[ "$(grep -c "^release upload" "$GH_LOG")" = 1 ]' "once"
for a in kasbah_1.2.3_linux_amd64 kasbah_1.2.3_linux_arm64 kasbah_1.2.3_darwin_amd64 kasbah_1.2.3_darwin_arm64 get.sh checksums.txt checksums.txt.minisig; do
    assert 'grep -q "/$a\( \|$\)" <<<"$upload"' "the rerun uploads $a (got: $upload)"
done
assert '! grep -q -- "--latest\|--prerelease" <<<"$upload"' "and leaves latest and prerelease as they are (got: $upload)"
assert '[ "$(grep -c "^stamped='"'"'1.2.3'"'"'$" "$GH_KEEP/get.sh")" = 1 ]' "the re-uploaded get.sh is stamped"
assert '! grep -q "^release create" "$GH_LOG"' "and does not create the release again"
assert '[ "$(cat "$repo/VERSION")" = 1.2.3 ]' "and VERSION is still as it was (got $(cat "$repo/VERSION"))"
assert 'grep -q "https://github.example/releases/tag/v1.2.3" <<<"$out"' "the summary still names the release URL (got: $out)"

# --- keygen ---------------------------------------------------------------------

fresh 1.2.3
rm -rf "$key_dir" "$repo/release.pub"
export KASBAH_RELEASE_KEY="$tmpdir/newkeys/deep/release.key"
release keygen
assert '[ "$rc" = 0 ]' "keygen succeeds (exit $rc: $err)"
gen="$(grep "jedisct1/minisign -G" "$DOCKER_LOG")"
assert 'grep -q -- "-v $tmpdir/newkeys/deep:/keys jedisct1/minisign -G -p /keys/release.key.pub -s /keys/release.key" <<<"$gen"' \
    "the pair is made through the container, in the key directory (got: $gen)"
assert '[ "$(cat "$KASBAH_RELEASE_KEY")" = "fake secret key" ]' "the secret key is where KASBAH_RELEASE_KEY says"
assert '[ "$(stat -c %a "$tmpdir/newkeys/deep")" = 700 ]' "its directory is 700 (got $(stat -c %a "$tmpdir/newkeys/deep"))"
assert '[ "$(cat "$repo/release.pub")" = "fake public key" ]' "the public key is at the repo's release.pub"
assert '! [ -e "$tmpdir/newkeys/deep/release.key.pub" ]' "and not left beside the secret key"
release keygen
assert '[ "$rc" = 1 ] && grep -q "refusing to overwrite" <<<"$err"' "keygen refuses to overwrite the key (exit $rc: $err)"
export KASBAH_RELEASE_KEY="$key_dir/release.key"

exit "$fail"
