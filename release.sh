#!/usr/bin/env bash
# Publish a kasbah release from this checkout, or make the signing key.
#
#   ./release.sh vX.Y.Z[-rc.N]   tag, build twice (the builds must match),
#                                checksum, sign, push the tag, create the
#                                GitHub release
#   ./release.sh keygen          create the minisign key pair: the secret key
#                                at $KASBAH_RELEASE_KEY, the public key at
#                                release.pub in the repo
#   ./release.sh stage vX.Y.Z[-rc.N] DIR
#                                write the assets except the signature into DIR,
#                                from the build in dist/
#   ./release.sh flags vX.Y.Z[-rc.N]
#                                print the gh release create flags: --latest
#                                only for the highest final version at origin
#
# Assets (frozen): kasbah_<ver>_linux_amd64, kasbah_<ver>_linux_arm64,
# get.sh (its stamped='' line set to the version), checksums.txt (sha256sum
# format, over the three), checksums.txt.minisig. The workflow stages and
# flags through this script too.
#
# A release build — an rc included — carries the tag exactly: tools/stamp
# finds HEAD tagged v<ver> on a clean tree (no commit count, no build time),
# so the two builds match byte for byte and the installed binary reports
# `kasbah <ver>`. That is why the tag is made before the builds; a release
# that fails before the push takes the tag it made away again. VERSION is
# not touched: after v1.0.0 the checkout's builds stamp themselves
# 1.0.1-dev…; setting VERSION to the next minor or major is the release
# line's own commit.
#
# minisign runs in its container and asks for the key's password itself, so a
# release needs a terminal on stdin (there is no environment variable for it).
# Needs gh (authenticated), docker, git and sha256sum on PATH.

set -euo pipefail

caller_dir="$PWD"
repo_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_dir"

key="${KASBAH_RELEASE_KEY:-${HOME:?HOME is not set}/.config/kasbah/release.key}"
key_dir="$(dirname "$key")"
key_name="$(basename "$key")"
minisign_image="jedisct1/minisign"

die() { echo "release: $*" >&2; exit 1; }

scratch=
made_tag=
cleanup() {
    [ -n "$scratch" ] && rm -rf "$scratch"
    [ -n "$made_tag" ] && git tag -d "$made_tag" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# minisign in its container, as this user so what it writes is ours; a terminal
# on stdin is passed through for the password prompt.
minisign() {
    local tty=-i
    [ -t 0 ] && tty=-it
    docker run --rm "$tty" --user "$(id -u):$(id -g)" "$@"
}

need() {
    for c; do command -v "$c" >/dev/null 2>&1 || die "$c is not on PATH"; done
}

keygen() {
    need docker
    [ -e "$key" ] && die "$key exists — refusing to overwrite the signing key"
    [ -e "$repo_dir/release.pub" ] && die "$repo_dir/release.pub exists — refusing to overwrite the public key"
    install -d -m 700 "$key_dir"
    minisign -v "$key_dir:/keys" "$minisign_image" -G -p "/keys/$key_name.pub" -s "/keys/$key_name"
    mv -f "$key_dir/$key_name.pub" "$repo_dir/release.pub"
    chmod 600 "$key"
    echo "secret key: $key"
    echo "public key: $repo_dir/release.pub — commit it"
}

check_tag() {
    [[ ${1#v} =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$ && $1 == v* ]] \
        || die "'$1' is not a release tag: vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N"
}

# stamp_get <ver> <out> — get.sh with its one stamped='' line set to ver.
stamp_get() {
    local ver=$1 out=$2 src="$repo_dir/get.sh" n
    [ -f "$src" ] || die "no $src"
    n="$(grep -cx "stamped=''" "$src" || true)"
    [ "$n" = 1 ] || die "get.sh holds the line stamped='' $n times, not once — nothing to stamp"
    sed "s/^stamped=''\$/stamped='$ver'/" "$src" >"$out" || die "could not write $out"
    ! grep -qF "stamped=''" "$out" || die "get.sh still holds stamped='' once stamped — it must be one top-level line"
    n="$(grep -cxF "stamped='$ver'" "$out" || true)"
    [ "$n" = 1 ] || die "get.sh holds stamped='$ver' $n times once stamped, not once"
}

# stage <tag> <dir> — the two binaries from dist/server, the stamped get.sh and
# checksums.txt over the three in name order, into dir (made if missing).
stage() {
    local tag=$1 dir=$2 ver
    check_tag "$tag"
    ver=${tag#v}
    need sha256sum
    local arch
    for arch in amd64 arm64; do
        [ -f "dist/server/kasbah-linux-$arch" ] || die "no dist/server/kasbah-linux-$arch — build first"
    done
    mkdir -p "$dir" || die "could not make $dir"
    stamp_get "$ver" "$dir/get.sh"
    cp dist/server/kasbah-linux-amd64 "$dir/kasbah_${ver}_linux_amd64"
    cp dist/server/kasbah-linux-arm64 "$dir/kasbah_${ver}_linux_arm64"
    (cd "$dir" && sha256sum get.sh "kasbah_${ver}_linux_amd64" "kasbah_${ver}_linux_arm64") \
        >"$dir/checksums.txt" || die "could not write $dir/checksums.txt"
}

# flags <tag> — an rc is a prerelease, never latest; a final is latest only
# when no final tag at origin is higher. Origin's tags, not the local ones: a
# local tag nobody pushed is no release, and a stale clone may lack newer ones.
flags() {
    local tag=$1 refs finals highest
    check_tag "$tag"
    if [[ $tag == *-* ]]; then
        echo "--prerelease --latest=false"
        return
    fi
    need git
    refs="$(git ls-remote --tags --refs origin)" || die "could not list origin's tags"
    finals="$(sed -n 's|^[0-9a-f]*\trefs/tags/||p' <<<"$refs")"
    finals="$(printf '%s\n%s\n' "$finals" "$tag" | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')"
    highest="$(sort -V <<<"$finals" | tail -n 1)"
    if [ "$highest" = "$tag" ]; then echo "--latest"; else echo "--latest=false"; fi
}

release() {
    local tag=$1 ver
    check_tag "$tag"
    ver=${tag#v}

    need gh docker git sha256sum
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
    [ -z "$(git status --porcelain)" ] || die "the tree is not clean — commit or stash first"
    local version
    version="$(tr -d '\r\n' <VERSION)"
    [ "$version" = "$ver" ] || die "VERSION is $version, not $ver — set it and commit"

    # HEAD's v-tags, as internal/release.Pick reads them: at most this one.
    local vtags
    vtags="$(git tag --points-at HEAD)" || die "could not list the tags on HEAD"
    vtags="$(grep '^v' <<<"$vtags" || true)"
    local have_tag=0
    if [ -n "$vtags" ]; then
        [ "$vtags" = "$tag" ] || die "HEAD already carries a version tag: $(tr '\n' ' ' <<<"$vtags")— one release per commit"
        have_tag=1
    fi
    local remote
    remote="$(git branch -r --contains HEAD)" || die "could not list the remote branches holding HEAD"
    grep -q '^ *origin/' <<<"$remote" || die "HEAD is not on any pushed origin branch — push it first"
    [ -f "$key" ] || die "no signing key at $key — ./release.sh keygen makes one (or set KASBAH_RELEASE_KEY)"
    [ -f "$repo_dir/release.pub" ] || die "no $repo_dir/release.pub — ./release.sh keygen makes the pair"
    # get.sh's stamp line and origin's tags are checked before anything is built.
    scratch="$(mktemp -d)"
    stamp_get "$ver" "$scratch/get.sh"
    local flag_words gh_flags
    flag_words="$(flags "$tag")" || exit 1
    read -ra gh_flags <<<"$flag_words"

    ./test.sh || die "test.sh failed — nothing released"

    # The tag first: tools/stamp reads it. Until the push it is this run's to
    # take away (cleanup), as it was never anyone else's.
    if [ "$have_tag" != 1 ]; then
        git tag -a "$tag" -m "kasbah $ver" || die "could not tag $tag"
        made_tag=$tag
    fi

    # An exact stamp carries no count and no time, so two builds of the same
    # tree are byte-identical; anything else means the build is not reproducible.
    local first second
    build
    local reported
    reported="$(./dist/kasbah --version 2>&1)" || die "dist/kasbah --version failed: $reported"
    [[ $reported =~ ^kasbah\ $(printf '%s' "$ver" | sed 's/[.]/[.]/g')\ \(schema\ [0-9]+\)$ ]] || {
        echo "release: the build reports '$reported', not 'kasbah $ver (schema N)' — the stamp is not the tag, nothing released" >&2
        echo "  tools/stamp stamps a build as the tag only when HEAD carries $tag (another tag on HEAD is fine)" >&2
        echo "  and the tree is clean as the build container sees it — untracked files count" >&2
        exit 1
    }
    first="$(hashes)"
    build
    second="$(hashes)"
    if [ "$first" != "$second" ]; then
        echo "release: the two builds differ — the build is not reproducible, nothing released" >&2
        echo "first:" >&2; sed 's/^/  /' <<<"$first" >&2
        echo "second:" >&2; sed 's/^/  /' <<<"$second" >&2
        exit 1
    fi

    stage "$tag" "$scratch"
    cp "$repo_dir/release.pub" "$scratch/release.pub"
    minisign -v "$key_dir:/keys:ro" -v "$scratch:/work" -w /work "$minisign_image" \
        -S -s "/keys/$key_name" -t "kasbah $ver" -m checksums.txt
    # The committed public key must be the secret key's pair, or nobody can verify.
    minisign -v "$scratch:/work:ro" -w /work "$minisign_image" -V -p release.pub -m checksums.txt >/dev/null \
        || die "release.pub does not verify what $key signed — the pair does not match"

    local notes prev
    notes="$scratch/notes.md"
    prev="$(git describe --tags --abbrev=0 --match 'v*' --exclude "$tag" HEAD 2>/dev/null || true)"
    if [ -n "$prev" ]; then
        git log --format='- %s' "$prev..HEAD" >"$notes"
    else
        git log --format='- %s' HEAD >"$notes"
    fi

    # From here the tag stays whatever happens: a rerun reuses it.
    made_tag=
    git push origin "$tag" || die "pushing $tag failed — nothing released; the local tag stays"
    # A release that exists already is one a failed upload left behind: its
    # assets are replaced, the release is not made again.
    local assets=("$scratch/kasbah_${ver}_linux_amd64" "$scratch/kasbah_${ver}_linux_arm64" "$scratch/get.sh"
                  "$scratch/checksums.txt" "$scratch/checksums.txt.minisig")
    local url
    if gh release view "$tag" >/dev/null 2>&1; then
        gh release upload "$tag" "${assets[@]}" --clobber \
            || die "uploading the assets to the existing release $tag failed — retry, or start over: gh release delete $tag --cleanup-tag"
        url="$(gh release view "$tag" --json url --jq .url)" || url=
    else
        url="$(gh release create "$tag" --title "kasbah $ver" --notes-file "$notes" "${gh_flags[@]}" "${assets[@]}")" \
            || die "creating the release $tag failed — retry (an existing release gets its assets replaced), or start over: gh release delete $tag --cleanup-tag"
    fi

    echo "released $tag"
    echo "  assets: kasbah_${ver}_linux_amd64 kasbah_${ver}_linux_arm64 get.sh checksums.txt checksums.txt.minisig"
    echo "  $url"
}

build() {
    env UID="$(id -u)" GID="$(id -g)" \
        docker compose --progress quiet -p kasbah -f "$repo_dir/compose.yml" run --rm -T build >&2 </dev/null \
        || die "the build failed"
}

hashes() {
    sha256sum dist/kasbah dist/server/kasbah-linux-amd64 dist/server/kasbah-linux-arm64
}

usage="usage: ./release.sh vX.Y.Z[-rc.N] | keygen | stage vX.Y.Z[-rc.N] DIR | flags vX.Y.Z[-rc.N]"
case "${1:-}" in
    keygen) [ $# -eq 1 ] || die "keygen takes no argument"; keygen ;;
    stage)  [ $# -eq 3 ] || die "$usage"
            dir=$3; [[ $dir == /* ]] || dir="$caller_dir/$dir"
            stage "$2" "$dir" ;;
    flags)  [ $# -eq 2 ] || die "$usage"; flags "$2" ;;
    v*)     [ $# -eq 1 ] || die "$usage"; release "$1" ;;
    *)      echo "$usage" >&2; exit 1 ;;
esac
