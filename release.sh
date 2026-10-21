#!/usr/bin/env bash
# Publish a kasbah release from this checkout, or make the signing key.
#
#   ./release.sh vX.Y.Z[-rc.N]   tag, build twice (the builds must match),
#                                checksum, sign, push the tag, create the
#                                GitHub release; then bump VERSION to the next
#                                patch -dev (an rc bumps nothing)
#   ./release.sh keygen          create the minisign key pair: the secret key
#                                at $KASBAH_RELEASE_KEY, the public key at
#                                release.pub in the repo
#
# Assets (frozen): kasbah_<ver>_linux_amd64, kasbah_<ver>_linux_arm64,
# checksums.txt (sha256sum format), checksums.txt.minisig.
#
# minisign runs in its container and asks for the key's password itself, so a
# release needs a terminal on stdin (there is no environment variable for it).
# Needs gh (authenticated), docker, git and sha256sum on PATH.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_dir"

key="${KASBAH_RELEASE_KEY:-${HOME:?HOME is not set}/.config/kasbah/release.key}"
key_dir="$(dirname "$key")"
key_name="$(basename "$key")"
minisign_image="jedisct1/minisign"

die() { echo "release: $*" >&2; exit 1; }

scratch=
trap '[ -n "$scratch" ] && rm -rf "$scratch"' EXIT

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

release() {
    local tag=$1 ver prerelease=()
    ver=${tag#v}
    [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
        || die "'$tag' is not a release tag: vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N"
    [[ $ver == *-* ]] && prerelease=(--prerelease)

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

    ./test.sh || die "test.sh failed — nothing released"

    # Release stamps carry no time, so two builds of the same tree are
    # byte-identical; anything else means the build is not reproducible.
    local first second
    build
    first="$(hashes)"
    build
    second="$(hashes)"
    if [ "$first" != "$second" ]; then
        echo "release: the two builds differ — the build is not reproducible, nothing released" >&2
        echo "first:" >&2; sed 's/^/  /' <<<"$first" >&2
        echo "second:" >&2; sed 's/^/  /' <<<"$second" >&2
        exit 1
    fi

    scratch="$(mktemp -d)"
    cp dist/server/kasbah-linux-amd64 "$scratch/kasbah_${ver}_linux_amd64"
    cp dist/server/kasbah-linux-arm64 "$scratch/kasbah_${ver}_linux_arm64"
    (cd "$scratch" && sha256sum "kasbah_${ver}_linux_amd64" "kasbah_${ver}_linux_arm64" | LC_ALL=C sort -k2) \
        >"$scratch/checksums.txt"
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

    [ "$have_tag" = 1 ] || git tag -a "$tag" -m "kasbah $ver"
    git push origin "$tag" || die "pushing $tag failed — nothing released; the local tag stays"
    # A release that exists already is one a failed upload left behind: its
    # assets are replaced, the release is not made again.
    local assets=("$scratch/kasbah_${ver}_linux_amd64" "$scratch/kasbah_${ver}_linux_arm64"
                  "$scratch/checksums.txt" "$scratch/checksums.txt.minisig")
    local url
    if gh release view "$tag" >/dev/null 2>&1; then
        gh release upload "$tag" "${assets[@]}" --clobber \
            || die "uploading the assets to the existing release $tag failed — retry, or start over: gh release delete $tag --cleanup-tag"
        url="$(gh release view "$tag" --json url --jq .url)" || url=
    else
        url="$(gh release create "$tag" --title "kasbah $ver" --notes-file "$notes" "${prerelease[@]}" "${assets[@]}")" \
            || die "creating the release $tag failed — retry (an existing release gets its assets replaced), or start over: gh release delete $tag --cleanup-tag"
    fi

    echo "released $tag"
    echo "  assets: kasbah_${ver}_linux_amd64 kasbah_${ver}_linux_arm64 checksums.txt checksums.txt.minisig"
    echo "  $url"
    if [ ${#prerelease[@]} -eq 0 ]; then
        local next="${ver%.*}.$(( ${ver##*.} + 1 ))-dev"
        printf '%s\n' "$next" >VERSION
        echo "  VERSION is now $next — commit it:  git commit -m 'open $next' VERSION"
    fi
}

build() {
    env UID="$(id -u)" GID="$(id -g)" \
        docker compose -p kasbah -f "$repo_dir/compose.yml" run --rm -T build >&2 </dev/null \
        || die "the build failed"
}

hashes() {
    sha256sum dist/kasbah dist/server/kasbah-linux-amd64 dist/server/kasbah-linux-arm64
}

case "${1:-}" in
    keygen) [ $# -eq 1 ] || die "keygen takes no argument"; keygen ;;
    v*)     [ $# -eq 1 ] || die "usage: ./release.sh vX.Y.Z[-rc.N] | keygen"; release "$1" ;;
    *)      echo "usage: ./release.sh vX.Y.Z[-rc.N] | keygen" >&2; exit 1 ;;
esac
