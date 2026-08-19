# Shared test helper: a fixture project with a git history of its own.
# Sourced by tests/build_push_test.sh and tests/integration/ship_test.sh.
# Never executed.
#
# The copy is the whole point. `git init` inside the kasbah checkout would land
# in kasbah's own history as a gitlink, and the fixtures live in that checkout —
# so every suite that needs a project with a v-tag works on a copy somewhere
# writable instead.

[ -n "${_KASBAH_FIXTURE_REPO_LOADED:-}" ] && return 0
_KASBAH_FIXTURE_REPO_LOADED=1

# The checkout this file lives in. Resolved once, and used below to keep a
# destination out of it.
_FIXTURE_REPO_CHECKOUT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where a destination is allowed to be. `rm -rf` on a caller-supplied path is
# what this function opens with, so it is fenced the way tests/integration/
# rig_env.sh fences its own destructive payload: not by trusting the caller, but
# by two checks that hold independently of each other.
#
#   1. The destination must sit under a temp root — the one the caller's own
#      `mktemp -d` used, or /tmp. A typo that lands on a real path is refused
#      rather than removed.
#   2. It must be neither inside this checkout nor the checkout itself, which is
#      where the fixtures being copied *from* live, and which a checkout made
#      under /tmp would otherwise slip past check 1. Both halves are needed: the
#      parent test below refuses every path inside the checkout and says nothing
#      about the directory, and `rm -rf` on that takes the fixtures with it.
_fixture_repo_check_dest() {
    local dest="$1" parent tmproot resolved

    if [ -z "$dest" ]; then
        echo "fixture_repo_make: no destination given" >&2
        return 1
    fi
    case $dest in
        /*) ;;
        *)  echo "fixture_repo_make: destination '$dest' is not an absolute path" >&2
            return 1 ;;
    esac
    # The parent, because the destination itself may not exist yet. -P so a
    # symlink cannot point the check at one directory and the rm at another.
    parent="$(cd -P "$(dirname "$dest")" 2>/dev/null && pwd)" || parent=""
    if [ -z "$parent" ]; then
        echo "fixture_repo_make: '$(dirname "$dest")' is not a directory" >&2
        return 1
    fi

    tmproot="$(cd -P "${TMPDIR:-/tmp}" 2>/dev/null && pwd)" || tmproot=""
    [ -n "$tmproot" ] || tmproot=/tmp
    case "$parent/" in
        "$tmproot"/*|/tmp/*) ;;
        *)  echo "fixture_repo_make: refusing to remove '$dest' — it is not under $tmproot or /tmp" >&2
            return 1 ;;
    esac
    case "$parent/" in
        "$_FIXTURE_REPO_CHECKOUT"/*)
            echo "fixture_repo_make: refusing to remove '$dest' — it is inside the kasbah checkout" >&2
            return 1 ;;
    esac
    # The destination itself, when there is one to resolve: the test above is on
    # the parent, so the checkout's own path passes it. -P again, so a symlink
    # cannot point the check somewhere other than where the rm would land.
    if [ -d "$dest" ]; then
        resolved="$(cd -P "$dest" 2>/dev/null && pwd)" || resolved=""
        if [ "$resolved" = "$_FIXTURE_REPO_CHECKOUT" ]; then
            echo "fixture_repo_make: refusing to remove '$dest' — it is the kasbah checkout" >&2
            return 1
        fi
    fi
    return 0
}

# fixture_repo_make <dest> <fixture-dir> <tag>... — copy the fixture to dest,
# commit it, and point each tag at that commit. Returns 1 with git's own output
# on stderr if any of it fails.
fixture_repo_make() {
    local dest="$1" src="$2"; shift 2
    local tag

    _fixture_repo_check_dest "$dest" || return 1
    rm -rf "$dest" || return 1
    cp -R "$src" "$dest" || return 1
    (
        cd "$dest" || exit 1
        git init -q . || exit 1
        # A suite runs under a scratch HOME with no git identity, and signing is
        # off for the same reason: whatever the developer's global config says
        # must not decide whether this commit can be made.
        git config user.email "fixture@kasbah.test" || exit 1
        git config user.name "kasbah fixture" || exit 1
        git config commit.gpgsign false || exit 1
        git add -A || exit 1
        git commit -qm "the $(basename "$src") fixture" || exit 1
        for tag in "$@"; do
            git tag "$tag" || exit 1
        done
    ) >&2 || return 1
    return 0
}
