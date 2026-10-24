#!/usr/bin/env bash
# Test: install-dev.sh (through `dist/kasbah __install`, internal/install) puts
# the binary and the two server binaries into the build's own version
# directory, links <bin>/kasbah to the newest installed version, and removes
# every other dev build but no release — the binary carries its templates, so
# an installed kasbah runs with nothing beside it but what it ships to servers.
#
# Installing is the case nobody exercises by hand — the repo is always run from
# a checkout — so it is the one that silently rots.
#
# The repo is copied into a temp dir first, taking this checkout's dist/ along,
# and installs with KASBAH_SKIP_BUILD=1: building is the toolchain container's
# job, tested by `docker compose run --rm build`, and not worth a container per
# case here.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

version="$(tr -d '\r\n' <"$repo_dir/VERSION")"

for f in kasbah server/kasbah-linux-amd64 server/kasbah-linux-arm64; do
    if [ ! -x "$repo_dir/dist/$f" ]; then
        echo "no $repo_dir/dist/$f — build it: docker compose run --rm build" >&2
        exit 2
    fi
done
# What the checkout's build reports; the installed copy must report the same.
built_version="$("$repo_dir/dist/kasbah" --version)"
stamp=${built_version#kasbah }
stamp=${stamp%% (schema*}

repo="$tmpdir/repo"
mkdir -p "$repo"
cp -R "$repo_dir/dist" "$repo/"
cp "$repo_dir/install-dev.sh" "$repo_dir/VERSION" "$repo/"
chmod 0755 "$repo/install-dev.sh"

prefix="$tmpdir/prefix"
bin_dir="$prefix/bin"
lib_dir="$prefix/share/kasbah"

install_it() {
    env -u KASBAH_LIB_DIR KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
        "$repo/install-dev.sh" >"$tmpdir/install.out" 2>"$tmpdir/install.err"
}

# --- Case 1: the version directory, and the symlink to it -----------------------
# A 1.0.x install left a regular file at <bin>/kasbah; the symlink replaces it.
mkdir -p "$bin_dir"
printf '#!/bin/sh\nexit 0\n' > "$bin_dir/kasbah"
chmod 0755 "$bin_dir/kasbah"
install_it
rc=$?
ver_dir="$lib_dir/$stamp"
assert '[ "$rc" = "0" ]' "install-dev.sh succeeds (exit $rc: $(cat "$tmpdir/install.err"))"
assert '[ -L "$bin_dir/kasbah" ] && [ "$(readlink "$bin_dir/kasbah")" = "$ver_dir/kasbah" ]' \
    "<bin>/kasbah is a symlink to this build's version directory (got '$(readlink "$bin_dir/kasbah" || echo "a $(stat -c %F "$bin_dir/kasbah")")')"
assert 'cmp -s "$repo/dist/kasbah" "$ver_dir/kasbah" && [ -x "$ver_dir/kasbah" ]' \
    "the CLI installed is the built binary, executable"
for arch in amd64 arm64; do
    assert 'cmp -s "$repo/dist/server/kasbah-linux-$arch" "$ver_dir/server/kasbah-linux-$arch" &&
            [ -x "$ver_dir/server/kasbah-linux-$arch" ]' \
        "the linux/$arch server binary is installed, executable"
done
listing="$(cd "$lib_dir" && find . -mindepth 1 | sort | tr '\n' ' ')"
assert '[ "$listing" = "./$stamp ./$stamp/kasbah ./$stamp/server ./$stamp/server/kasbah-linux-amd64 ./$stamp/server/kasbah-linux-arm64 " ]' \
    "the library directory holds the version directory only (got: $listing)"

installed_version="$(env -u KASBAH_LIB_DIR XDG_DATA_HOME="$prefix/share" "$bin_dir/kasbah" --version 2>&1)"
assert '[ "$installed_version" = "$built_version" ]' \
    "the installed binary runs (got '$installed_version', built '$built_version')"
# The stamp is VERSION exactly (a tagged, clean tree) or a pre-release of
# VERSION or of the patch after it (tools/stamp), with the schema after it.
core=${version%%-*}
next_patch="${core%.*}.$(( ${core##*.} + 1 ))"
stamp_core=${stamp%%-*}; stamp_core=${stamp_core%%+*}
assert '[[ "$installed_version" =~ ^kasbah\ [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\ \(schema\ [0-9]+\)$ ]]' \
    "and reports a version stamp and the schema (got '$installed_version')"
assert '[ "$stamp_core" = "$core" ] || [ "$stamp_core" = "$next_patch" ]' \
    "the stamp is on VERSION's line ($version) or the patch after it (got '$stamp')"
assert '[ "$(head -1 "$tmpdir/install.out")" = "installed kasbah $stamp" ]' \
    "install-dev.sh reports the version it installed (got '$(head -1 "$tmpdir/install.out")')"
assert 'grep -qxF "  bin: $bin_dir/kasbah -> $ver_dir/kasbah" "$tmpdir/install.out" && grep -qxF "  lib: $ver_dir" "$tmpdir/install.out"' \
    "and where it went (got '$(cat "$tmpdir/install.out")')"
assert 'grep -qxF "note: $bin_dir is not in PATH" "$tmpdir/install.err"' \
    "a bin directory not in PATH is noted (got '$(cat "$tmpdir/install.err")')"

# --- Case 2: self-contained -----------------------------------------------------
# The library directory moved away and KASBAH_LIB_DIR pointed nowhere: every
# local command still runs — the templates are inside the binary.
proj="$tmpdir/proj"
cp -R "$repo_dir/tests/fixtures/demo" "$proj"
alone() { (cd "$proj" && env -u XDG_DATA_HOME KASBAH_LIB_DIR="$tmpdir/nowhere" "$bin_dir/kasbah" "$@"); }
out="$(alone --help 2>&1)"; rc=$?
assert '[ "$rc" = "0" ] && grep -qF "server init USER@HOST" <<<"$out"' "--help, alone (exit $rc)"
out="$(alone init-project --help 2>&1)"; rc=$?
assert '[ "$rc" = "0" ] && grep -qF "Usage: kasbah init-project" <<<"$out"' "init-project --help, alone (exit $rc: $out)"
out="$(alone check 2>&1)"; rc=$?
assert '{ [ "$rc" = "0" ] || [ "$rc" = "6" ]; } && grep -qF "Summary:" <<<"$out"' \
    "check runs to its summary in a project, alone (exit $rc)"

# --- Case 3: one dev build stays; releases stay -----------------------------------
# Version directories planted by hand stand in for other builds, each a script
# answering --version as that build would: releases older and newer, a newer
# one that does not run (the symlink skips it), and two other dev builds, the
# symlink pointing at one of them. A re-install replaces this build's files in
# place and repoints; a dev build removes both dev builds, a release (a clean
# checkout of its tag) removes none. Only dev stamps carry +g<sha>.
major=${stamp%%.*}
case $stamp in *+g*) dev=1 ;; *) dev=0 ;; esac
plant() {
    mkdir -p "$lib_dir/$1/server"
    printf '#!/bin/sh\necho "kasbah %s (schema 1)"\n' "$1" > "$lib_dir/$1/kasbah"
    printf 'server\n' > "$lib_dir/$1/server/kasbah-linux-amd64"
    chmod 0755 "$lib_dir/$1/kasbah"
}
older="0.0.1"; newer="$major.999.0"; broken="99.0.0"; rc_rel="$major.999.1-rc.1"
old_dev="0.0.1-dev.3.1700000000+gabc1234"; new_dev="$major.998.0-dev.9.1800000000+gdef5678.dirty"
for v in "$older" "$newer" "$broken" "$rc_rel" "$old_dev" "$new_dev"; do plant "$v"; done
printf '#!/bin/sh\nexit 3\n' > "$lib_dir/$broken/kasbah"
ln -sfn "$lib_dir/$new_dev/kasbah" "$bin_dir/kasbah"
rm -f "$ver_dir/kasbah"
printf 'stale\n' > "$ver_dir/kasbah"
install_it; rc=$?
assert '[ "$rc" = "0" ] && cmp -s "$repo/dist/kasbah" "$ver_dir/kasbah"' \
    "a re-install replaces this build's own binary (exit $rc: $(cat "$tmpdir/install.err"))"
dirs="$(cd "$lib_dir" && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')"
if [ "$dev" = 1 ]; then
    want_dirs="$(printf './%s\n' "$older" "$newer" "$broken" "$rc_rel" "$stamp" | sort | tr '\n' ' ')"
    assert '[ "$dirs" = "$want_dirs" ]' \
        "every other dev build is removed, every release kept (got: $dirs)"
    assert 'grep -qxF "  removed: $lib_dir/$old_dev (another dev build)" "$tmpdir/install.out" && grep -qxF "  removed: $lib_dir/$new_dev (another dev build)" "$tmpdir/install.out"' \
        "and install-dev.sh names each removal (got '$(cat "$tmpdir/install.out")')"
else
    want_dirs="$(printf './%s\n' "$older" "$newer" "$broken" "$rc_rel" "$old_dev" "$new_dev" "$stamp" | sort | tr '\n' ' ')"
    assert '[ "$dirs" = "$want_dirs" ]' \
        "a release install removes no dev build (got: $dirs)"
    assert '! grep -qF "removed:" "$tmpdir/install.out"' \
        "and install-dev.sh names no removal (got '$(cat "$tmpdir/install.out")')"
fi
assert '[ "$(readlink "$bin_dir/kasbah")" = "$lib_dir/$rc_rel/kasbah" ]' \
    "<bin>/kasbah, which pointed at a removed dev build, points at the newest version that runs (got '$(readlink "$bin_dir/kasbah")')"
assert 'grep -qF "bin: $bin_dir/kasbah -> $lib_dir/$rc_rel/kasbah" "$tmpdir/install.out"' \
    "and install-dev.sh says so (got '$(cat "$tmpdir/install.out")')"
rm -rf "${lib_dir:?}/$older" "${lib_dir:?}/$newer" "${lib_dir:?}/$broken" "${lib_dir:?}/$rc_rel"
install_it; rc=$?
if [ "$dev" = 1 ]; then linked="$ver_dir/kasbah"; else linked="$lib_dir/$new_dev/kasbah"; fi
assert '[ "$rc" = "0" ] && [ "$(readlink "$bin_dir/kasbah")" = "$linked" ]' \
    "with the releases gone the symlink points at the newest left — this build, or for a release the kept dev build (exit $rc)"

# Installing into the build's own dist/ would copy each binary onto itself.
before="$(cd "$repo/dist" && find . -type f -exec sha256sum {} + | sort)"
dist_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/dist-bin" KASBAH_LIB_DIR="$repo/dist" \
               "$repo/install-dev.sh" 2>&1 >/dev/null); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "this build'\''s own" <<<"$dist_err"' \
    "KASBAH_LIB_DIR naming the build's dist/ is refused (exit $rc: $dist_err)"
assert '[ "$(cd "$repo/dist" && find . -type f -exec sha256sum {} + | sort)" = "$before" ] && [ ! -e "$tmpdir/dist-bin" ]' \
    "and dist/ is intact, nothing installed"

# --- Case 4: a lib dir that is not kasbah's is not touched --------------------
# assert evals in its own frame, so the case lives in globals, not $1/$2.
refused() { # dir, label
    r_dir=$1 r_label=$2
    r_before="$(cd "$r_dir" && find . | sort)"
    r_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/$r_label-bin" KASBAH_LIB_DIR="$r_dir" \
                "$repo/install-dev.sh" 2>&1 >/dev/null); r_rc=$?
    assert '[ "$r_rc" = "1" ] && grep -qF "refusing to remove anything" <<<"$r_err" && grep -qF "<version>/server/kasbah-linux-*" <<<"$r_err"' \
        "$r_label: refused, naming what would qualify (exit $r_rc: $r_err)"
    assert '[ "$(cd "$r_dir" && find . | sort)" = "$r_before" ] && [ ! -e "$tmpdir/$r_label-bin" ]' \
        "$r_label: nothing in it was touched, nothing installed"
}
foreign="$tmpdir/foreign"
mkdir -p "$foreign/keepme" "$foreign/libexec"
printf 'not kasbah\n' > "$foreign/notes.txt"
printf 'nor this\n'    > "$foreign/lib.sh"
refused "$foreign" "a foreign directory"
# A project holding a VERSION, scripts, templates/ and a server/ of its own.
lookalike="$tmpdir/lookalike"
mkdir -p "$lookalike/templates" "$lookalike/server"
for f in VERSION build.sh README templates/page.html server/main.go; do printf 'mine\n' > "$lookalike/$f"; done
refused "$lookalike" "a look-alike directory"
# The layouts before the version directories are no longer kasbah's: no sweep.
old_layout="$tmpdir/old-layout"
mkdir -p "$old_layout/server" "$old_layout/libexec"
for f in VERSION common.sh libexec/kasbah-bash server/kasbah-linux-amd64 server/kasbah-linux-arm64; do printf 'old\n' > "$old_layout/$f"; done
refused "$old_layout" "a 1.0.x or pre-1.0 library"
refused "$repo" "a kasbah checkout"

# A fresh, absent target is the ordinary first install and must still work.
fresh="$tmpdir/fresh"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$fresh/bin" KASBAH_LIB_DIR="$fresh/lib" \
    "$repo/install-dev.sh" >/dev/null 2>&1
fresh_rc=$?
assert '[ "$fresh_rc" = "0" ] && [ -x "$fresh/lib/$stamp/server/kasbah-linux-arm64" ] && [ "$(readlink "$fresh/bin/kasbah")" = "$fresh/lib/$stamp/kasbah" ]' \
    "a first install into an absent directory succeeds (exit $fresh_rc)"
# The target comes from the environment, never from where dist/kasbah sits.
home_out=$(env -u XDG_DATA_HOME -u KASBAH_LIB_DIR -u KASBAH_BIN_DIR KASBAH_SKIP_BUILD=1 HOME="$tmpdir/home" \
               "$repo/install-dev.sh" 2>/dev/null); rc=$?
assert '[ "$rc" = "0" ] && [ -x "$tmpdir/home/.local/share/kasbah/$stamp/kasbah" ] && [ "$(readlink "$tmpdir/home/.local/bin/kasbah")" = "$tmpdir/home/.local/share/kasbah/$stamp/kasbah" ]' \
    "with only HOME set, the install lands under ~/.local (exit $rc: $home_out)"
nohome_err=$(env -u XDG_DATA_HOME -u HOME KASBAH_SKIP_BUILD=1 KASBAH_LIB_DIR="$tmpdir/nohome/lib" \
                 "$repo/install-dev.sh" 2>&1 >/dev/null); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "KASBAH_BIN_DIR" <<<"$nohome_err" && [ ! -e "$tmpdir/nohome" ]' \
    "no HOME and no KASBAH_BIN_DIR is refused by name, nothing installed (exit $rc: $nohome_err)"
mkdir -p "$tmpdir/dirbin/kasbah"
dirbin_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/dirbin" KASBAH_LIB_DIR="$tmpdir/dirbin-lib" \
                 "$repo/install-dev.sh" 2>&1 >/dev/null); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "not a regular file or a symlink" <<<"$dirbin_err" && [ ! -e "$tmpdir/dirbin-lib" ]' \
    "a directory at <bin>/kasbah is refused before anything is written (exit $rc: $dirbin_err)"

# --- Case 5: a dist/ install-dev.sh cannot use, or a KASBAH_SKIP_BUILD it cannot read
bogus_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=yes KASBAH_BIN_DIR="$tmpdir/bogus/bin" \
                KASBAH_LIB_DIR="$tmpdir/bogus/lib" "$repo/install-dev.sh" 2>&1 >/dev/null)
bogus_rc=$?
assert '[ "$bogus_rc" = "2" ] && [ ! -e "$tmpdir/bogus" ]' \
    "KASBAH_SKIP_BUILD=yes is exit 2 and installs nothing (exit $bogus_rc: $bogus_err)"

mv "$repo/dist/server/kasbah-linux-arm64" "$tmpdir/arm64.aside"
partial="$tmpdir/partial"
partial_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$partial/bin" \
                  KASBAH_LIB_DIR="$partial/lib" "$repo/install-dev.sh" 2>&1 >/dev/null)
partial_rc=$?
mv "$tmpdir/arm64.aside" "$repo/dist/server/kasbah-linux-arm64"
assert '[ "$partial_rc" != "0" ]' "a dist/ missing a server binary fails the install (exit $partial_rc)"
assert 'grep -qF "dist/server/kasbah-linux-arm64 is missing" <<<"$partial_err"' \
    "naming the missing binary (got '$partial_err')"
assert '[ ! -e "$partial/bin/kasbah" ] && [ ! -e "$partial/lib" ]' \
    "and nothing was installed"

# The new binary is asked its version before anything is replaced, so one that
# cannot run here fails the install and leaves the installed kasbah working.
# Replaced by rename, not rewritten: a binary that just ran may still be
# text-busy for a moment.
cp "$repo/dist/kasbah" "$tmpdir/kasbah.aside"
printf '#!/bin/sh\nexit 3\n' > "$repo/dist/.kasbah.broken"
chmod 0755 "$repo/dist/.kasbah.broken"
mv -f "$repo/dist/.kasbah.broken" "$repo/dist/kasbah"
broken_out=$(env -u KASBAH_LIB_DIR KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
                 "$repo/install-dev.sh" 2>/dev/null)
broken_rc=$?
mv -f "$tmpdir/kasbah.aside" "$repo/dist/kasbah"
assert '[ "$broken_rc" != "0" ]' "a binary that cannot run fails the install (exit $broken_rc)"
assert '! grep -q "^installed" <<<"$broken_out"' "and it does not claim success (got '$broken_out')"
assert '[ "$(readlink "$bin_dir/kasbah")" = "$linked" ] && cmp -s "$repo/dist/kasbah" "$ver_dir/kasbah" && "$bin_dir/kasbah" --version >/dev/null' \
    "and the installed kasbah is the previous one, still linked and running"


# --- Case 6: __install DIR, and --pin ---------------------------------------------
# install-dev.sh with any version argument installs a tag's dist/ through the working tree's
# `__install --pin DIR`: the symlink goes to that build even beside a newer one.
pin_lib="$tmpdir/pin/lib" pin_bin="$tmpdir/pin/bin"
pin_install() { # args… — sets p_rc, p_out
    p_out=$(env -u XDG_DATA_HOME KASBAH_LIB_DIR="$pin_lib" KASBAH_BIN_DIR="$pin_bin" \
                "$repo/dist/kasbah" __install "$@" 2>&1); p_rc=$?
}
mkdir -p "$pin_lib/$newer/server"
printf '#!/bin/sh\necho "kasbah %s (schema 1)"\n' "$newer" > "$pin_lib/$newer/kasbah"
chmod 0755 "$pin_lib/$newer/kasbah"
pin_install "$repo/dist"
assert '[ "$p_rc" = "0" ] && [ "$(readlink "$pin_bin/kasbah")" = "$pin_lib/$newer/kasbah" ]' \
    "__install DIR points <bin>/kasbah at the newest installed (exit $p_rc: $p_out)"
pin_install --pin "$repo/dist"
assert '[ "$p_rc" = "0" ] && [ "$(readlink "$pin_bin/kasbah")" = "$pin_lib/$stamp/kasbah" ] && [ -x "$pin_lib/$newer/kasbah" ]' \
    "__install --pin DIR points it at the build installed, the newer one kept (exit $p_rc: $p_out)"

# --- Case 7: a version argument ----------------------------------------------------
# Refused before anything is built or installed; resolution itself is
# internal/version's (Pick) and cmd/kasbah's (__pick-tag) to test, and a real
# tag build is install-dev.sh v1.0.0 run by hand (docs/phases/11-open.md).
args_run() { # args… — sets a_rc, a_err
    a_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/args/bin" KASBAH_LIB_DIR="$tmpdir/args/lib" \
                "$repo/install-dev.sh" "$@" 2>&1 >/dev/null); a_rc=$?
}
for a in "--pre" "bogus" "-x" "v1 v2" "v1 --yes"; do
    # shellcheck disable=SC2086
    args_run $a
    assert '[ "$a_rc" = "2" ] && grep -qF "usage: install-dev.sh [vN | vN.M | vN.M.P] [--pre]" <<<"$a_err"' \
        "'$a' is refused with the usage (exit $a_rc: $a_err)"
done
args_run --pre
assert 'grep -qF -- "--pre needs a version" <<<"$a_err"' "--pre alone says it needs a version (got: $a_err)"
args_run v1
assert '[ "$a_rc" = "1" ] && grep -qF "a version needs a git checkout" <<<"$a_err"' \
    "a version outside a git checkout is refused (exit $a_rc: $a_err)"

# The copy becomes a checkout holding tags that do not match.
git -C "$repo" init --quiet
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty -m fixture
for t in v0.9.0 v1.0.0-rc.1 not-a-version; do git -C "$repo" tag "$t"; done
args_run v1
assert '[ "$a_rc" = "1" ] && grep -qF "no local tag matches v1" <<<"$a_err" && grep -qF "git fetch --tags" <<<"$a_err" && grep -qF "1 pre-release tag(s) were skipped" <<<"$a_err"' \
    "no matching tag names git fetch --tags, and the skipped rc (exit $a_rc: $a_err)"
args_run v1.0.1
assert '[ "$a_rc" = "1" ] && grep -qF "no local tag matches v1.0.1" <<<"$a_err" && grep -qF "git fetch --tags" <<<"$a_err"' \
    "an exact version not tagged here names git fetch --tags (exit $a_rc: $a_err)"
args_run v1.x
assert '[ "$a_rc" = "1" ] && grep -qF "'"'"'v1.x'"'"' is not a version" <<<"$a_err"' \
    "a malformed version is refused (exit $a_rc: $a_err)"
assert '[ ! -e "$tmpdir/args" ]' "and none of them installed anything"

exit "$fail"
