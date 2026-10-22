#!/usr/bin/env bash
# Test: install.sh puts the binary and the two server binaries into the
# build's own version directory, links <bin>/kasbah to the newest installed
# version, and removes nothing but the layouts before the launcher — the binary
# carries its templates, so an installed kasbah runs with nothing beside it
# but what it ships to servers.
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
cp "$repo_dir/install.sh" "$repo_dir/VERSION" "$repo/"
chmod 0755 "$repo/install.sh"

prefix="$tmpdir/prefix"
bin_dir="$prefix/bin"
lib_dir="$prefix/share/kasbah"

install_it() {
    env -u KASBAH_LIB_DIR KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
        "$repo/install.sh" >"$tmpdir/install.out" 2>"$tmpdir/install.err"
}

# --- Case 1: the version directory, and the symlink to it -----------------------
# A 1.0.x install left a regular file at <bin>/kasbah; the symlink replaces it.
mkdir -p "$bin_dir"
printf '#!/bin/sh\nexit 0\n' > "$bin_dir/kasbah"
chmod 0755 "$bin_dir/kasbah"
install_it
rc=$?
ver_dir="$lib_dir/$stamp"
assert '[ "$rc" = "0" ]' "install.sh succeeds (exit $rc: $(cat "$tmpdir/install.err"))"
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
assert '[ "$(head -1 "$tmpdir/install.out")" = "installed $built_version" ]' \
    "install.sh reports the version it installed (got '$(head -1 "$tmpdir/install.out")')"

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

# --- Case 3: other versions stay; the layouts before the launcher go ---------------
# Version directories planted by hand stand in for other builds: an older one,
# a newer one, and a newer one whose kasbah does not run, which the symlink
# skips. A re-install replaces this build's files in place.
older_dir="$lib_dir/0.0.1"
newer_dir="$lib_dir/${stamp%%.*}.999.0"
broken_dir="$lib_dir/99.0.0"
for d in "$older_dir" "$newer_dir" "$broken_dir"; do
    mkdir -p "$d/server"
    cp "$repo/dist/kasbah" "$d/kasbah"
done
printf '#!/bin/sh\nexit 3\n' > "$broken_dir/kasbah"
rm -f "$ver_dir/kasbah"
printf 'stale\n' > "$ver_dir/kasbah"
install_it; rc=$?
assert '[ "$rc" = "0" ] && cmp -s "$repo/dist/kasbah" "$ver_dir/kasbah"' \
    "a re-install replaces this build's own binary (exit $rc: $(cat "$tmpdir/install.err"))"
assert '[ -x "$older_dir/kasbah" ] && [ -x "$newer_dir/kasbah" ] && [ -x "$broken_dir/kasbah" ]' \
    "and deletes no other version directory"
assert '[ "$(readlink "$bin_dir/kasbah")" = "$newer_dir/kasbah" ]' \
    "<bin>/kasbah points at the newest version that runs (got '$(readlink "$bin_dir/kasbah")')"
assert 'grep -qF "bin: $bin_dir/kasbah -> $newer_dir/kasbah" "$tmpdir/install.out"' \
    "and install.sh says so (got '$(cat "$tmpdir/install.out")')"
rm -rf "$older_dir" "$newer_dir" "$broken_dir"

# The 1.0.x layout — server binaries at the top of the library — and what a
# pre-1.0 install put beside it — the Bash tree, the templates, VERSION — go;
# a file of somebody else's in server/ stays.
mkdir -p "$lib_dir/libexec" "$lib_dir/templates/traefik" "$lib_dir/server"
printf 'old\n' > "$lib_dir/libexec/kasbah-bash"
printf 'old\n' > "$lib_dir/templates/traefik/traefik.yml"
printf 'old\n' > "$lib_dir/common.sh"
printf 'old\n' > "$lib_dir/VERSION"
printf 'old\n' > "$lib_dir/server/kasbah-linux-amd64"
printf 'old\n' > "$lib_dir/server/kasbah-linux-arm64"
printf 'mine\n' > "$lib_dir/server/app.go"
install_it; rc=$?
listing="$(cd "$lib_dir" && find . -mindepth 1 | sort | tr '\n' ' ')"
assert '[ "$rc" = "0" ] && [ "$listing" = "./$stamp ./$stamp/kasbah ./$stamp/server ./$stamp/server/kasbah-linux-amd64 ./$stamp/server/kasbah-linux-arm64 ./server ./server/app.go " ]' \
    "a re-install over an old layout leaves the version directory and nothing of the old tree (exit $rc, got: $listing)"
assert '[ "$(cat "$lib_dir/server/app.go")" = mine ] && [ "$(readlink "$bin_dir/kasbah")" = "$ver_dir/kasbah" ]' \
    "a file of somebody else's in server/ is kept, and the symlink points back at this build"
rm -rf "$lib_dir/server"

# Installing into the build's own dist/ would copy each binary onto itself.
before="$(cd "$repo/dist" && find . -type f -exec sha256sum {} + | sort)"
dist_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/dist-bin" KASBAH_LIB_DIR="$repo/dist" \
               "$repo/install.sh" 2>&1 >/dev/null); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "this build'\''s own" <<<"$dist_err"' \
    "KASBAH_LIB_DIR naming the build's dist/ is refused (exit $rc: $dist_err)"
assert '[ "$(cd "$repo/dist" && find . -type f -exec sha256sum {} + | sort)" = "$before" ] && [ ! -e "$tmpdir/dist-bin" ]' \
    "and dist/ is intact, nothing installed"

# A pre-1.0 install with no server/ at all is still recognised as kasbah's.
legacy="$tmpdir/legacy"
mkdir -p "$legacy/libexec"
printf 'old\n' > "$legacy/VERSION"
printf 'old\n' > "$legacy/libexec/kasbah-bash"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/legacy-bin" KASBAH_LIB_DIR="$legacy" \
    "$repo/install.sh" >/dev/null 2>&1; rc=$?
assert '[ "$rc" = "0" ] && [ ! -e "$legacy/libexec" ] && [ ! -e "$legacy/VERSION" ] && [ -x "$legacy/$stamp/server/kasbah-linux-amd64" ]' \
    "a pre-1.0 library directory is upgraded in place (exit $rc)"

# --- Case 4: a lib dir that is not kasbah's is not emptied --------------------
foreign="$tmpdir/foreign"
mkdir -p "$foreign/keepme" "$foreign/libexec"
printf 'not kasbah\n' > "$foreign/notes.txt"
printf 'nor this\n'    > "$foreign/lib.sh"
foreign_err="$tmpdir/foreign.err"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/foreign-bin" KASBAH_LIB_DIR="$foreign" \
    "$repo/install.sh" >/dev/null 2>"$foreign_err"
foreign_rc=$?
assert '[ "$foreign_rc" != "0" ]' "installing into a foreign directory fails (exit $foreign_rc)"
assert 'grep -qF "refusing to remove anything" <"$foreign_err"' \
    "the refusal says it removed nothing (got '$(cat "$foreign_err")')"
assert '[ -f "$foreign/notes.txt" ] && [ -f "$foreign/lib.sh" ] && [ -d "$foreign/keepme" ] && [ -d "$foreign/libexec" ]' \
    "nothing in the foreign directory was touched"
assert '[ ! -e "$tmpdir/foreign-bin" ]' "and no binary was installed"

# A project that happens to hold a VERSION, scripts, templates/ and a server/
# directory of its own is not a pre-1.0 install.
lookalike="$tmpdir/lookalike"
mkdir -p "$lookalike/templates" "$lookalike/server"
for f in VERSION build.sh README templates/page.html server/main.go; do printf 'mine\n' > "$lookalike/$f"; done
before="$(cd "$lookalike" && find . | sort)"
look_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/look-bin" KASBAH_LIB_DIR="$lookalike" \
               "$repo/install.sh" 2>&1 >/dev/null); rc=$?
assert '[ "$rc" = "1" ] && grep -qF "server/kasbah-linux-*" <<<"$look_err"' \
    "a look-alike directory is refused, naming what would qualify (exit $rc: $look_err)"
assert '[ "$(cd "$lookalike" && find . | sort)" = "$before" ] && [ ! -e "$tmpdir/look-bin" ]' \
    "and nothing in it was removed, nothing installed"
# Nor is a kasbah checkout.
before="$(cd "$repo" && find . | sort)"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/co-bin" KASBAH_LIB_DIR="$repo" \
    "$repo/install.sh" >/dev/null 2>&1; rc=$?
assert '[ "$rc" = "1" ] && [ "$(cd "$repo" && find . | sort)" = "$before" ]' \
    "KASBAH_LIB_DIR naming a checkout is refused, the checkout untouched (exit $rc)"

# A fresh, absent target is the ordinary first install and must still work.
fresh="$tmpdir/fresh"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$fresh/bin" KASBAH_LIB_DIR="$fresh/lib" \
    "$repo/install.sh" >/dev/null 2>&1
fresh_rc=$?
assert '[ "$fresh_rc" = "0" ] && [ -x "$fresh/lib/$stamp/server/kasbah-linux-arm64" ] && [ "$(readlink "$fresh/bin/kasbah")" = "$fresh/lib/$stamp/kasbah" ]' \
    "a first install into an absent directory succeeds (exit $fresh_rc)"

# --- Case 5: a dist/ install.sh cannot use, or a KASBAH_SKIP_BUILD it cannot read
bogus_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=yes KASBAH_BIN_DIR="$tmpdir/bogus/bin" \
                KASBAH_LIB_DIR="$tmpdir/bogus/lib" "$repo/install.sh" 2>&1 >/dev/null)
bogus_rc=$?
assert '[ "$bogus_rc" = "2" ] && [ ! -e "$tmpdir/bogus" ]' \
    "KASBAH_SKIP_BUILD=yes is exit 2 and installs nothing (exit $bogus_rc: $bogus_err)"

mv "$repo/dist/server/kasbah-linux-arm64" "$tmpdir/arm64.aside"
partial="$tmpdir/partial"
partial_err=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$partial/bin" \
                  KASBAH_LIB_DIR="$partial/lib" "$repo/install.sh" 2>&1 >/dev/null)
partial_rc=$?
mv "$tmpdir/arm64.aside" "$repo/dist/server/kasbah-linux-arm64"
assert '[ "$partial_rc" != "0" ]' "a dist/ missing a server binary fails the install (exit $partial_rc)"
assert 'grep -qF "dist/server/kasbah-linux-arm64 is missing" <<<"$partial_err"' \
    "naming the missing binary (got '$partial_err')"
assert '[ ! -e "$partial/bin/kasbah" ] && [ ! -e "$partial/lib" ]' \
    "and nothing was installed"

# The new binary is asked its version before anything is replaced, so one that
# cannot run here fails the install and leaves the installed kasbah working.
cp "$repo/dist/kasbah" "$tmpdir/kasbah.aside"
printf '#!/bin/sh\nexit 3\n' > "$repo/dist/kasbah"
broken_out=$(env -u KASBAH_LIB_DIR KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
                 "$repo/install.sh" 2>/dev/null)
broken_rc=$?
cp "$tmpdir/kasbah.aside" "$repo/dist/kasbah"
assert '[ "$broken_rc" != "0" ]' "a binary that cannot run fails the install (exit $broken_rc)"
assert '! grep -q "^installed" <<<"$broken_out"' "and it does not claim success (got '$broken_out')"
assert 'cmp -s "$repo/dist/kasbah" "$bin_dir/kasbah" && [ "$(readlink "$bin_dir/kasbah")" = "$ver_dir/kasbah" ] && "$bin_dir/kasbah" --version >/dev/null' \
    "and the installed kasbah is the previous one, still linked and running"

exit "$fail"
