#!/usr/bin/env bash
# Test: install.sh ships the binary, the Bash tree it hands off to and the
# templates, and kasbah finds them wherever it is running from.
#
# Installing is the case nobody exercises by hand — the repo is always run from
# a checkout — so it is the one that silently rots. Templates are rendered onto
# servers, so a kasbah installed without them is a kasbah whose `server init`
# works for its authors and for nobody else.
#
# The repo is copied into a temp dir first: the throwaway templates the modes
# and the stale-file rule need must not be created in the working tree. The
# copy takes this checkout's dist/ along and installs with KASBAH_SKIP_BUILD=1:
# building is the toolchain container's job, tested by `docker compose run
# --rm build`, and not worth a container per case here.

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

version="$(cat "$repo_dir/VERSION")"

for f in kasbah server/kasbah-linux-amd64 server/kasbah-linux-arm64; do
    if [ ! -x "$repo_dir/dist/$f" ]; then
        echo "no $repo_dir/dist/$f — build it: docker compose run --rm build" >&2
        exit 2
    fi
done
# What the checkout's build reports; the installed copy must report the same.
built_version="$("$repo_dir/dist/kasbah" --version)"

# --- A repo copy with templates in it -----------------------------------------
repo="$tmpdir/repo"
mkdir -p "$repo"
cp -R "$repo_dir/dist" "$repo_dir/libexec" "$repo_dir/lib" "$repo_dir/templates" "$repo/"
cp "$repo_dir/install.sh" "$repo_dir/VERSION" "$repo/"
chmod 0755 "$repo/install.sh"

mkdir -p "$repo/templates/traefik/dynamic"
printf 'plain\n'                    > "$repo/templates/traefik/traefik.yml"
printf 'nested\n'                   > "$repo/templates/traefik/dynamic/_shared.yml"
printf '#!/usr/bin/env bash\ntrue\n' > "$repo/templates/remote-deploy.sh"
chmod 0755 "$repo/templates/remote-deploy.sh"

prefix="$tmpdir/prefix"
bin_dir="$prefix/bin"
lib_dir="$prefix/share/kasbah"

install_it() {
    env -u KASBAH_LIB_DIR KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
        "$repo/install.sh" >"$tmpdir/install.out" 2>"$tmpdir/install.err"
}

# --- Case 1: templates land, whole -------------------------------------------
install_it
rc=$?
assert '[ "$rc" = "0" ]' "install.sh succeeds (exit $rc: $(cat "$tmpdir/install.err"))"
assert '[ -f "$bin_dir/kasbah" ]'                              "the CLI is installed"
assert 'cmp -s "$repo/dist/kasbah" "$bin_dir/kasbah"'           "the CLI installed is the built binary"
assert '[ -x "$lib_dir/libexec/kasbah-bash" ]'                  "the Bash dispatcher is installed, executable"
for arch in amd64 arm64; do
    assert 'cmp -s "$repo/dist/server/kasbah-linux-$arch" "$lib_dir/server/kasbah-linux-$arch" &&
            [ -x "$lib_dir/server/kasbah-linux-$arch" ]' \
        "the linux/$arch server binary is installed, executable"
done
assert '[ -f "$lib_dir/common.sh" ]'                            "the libraries are installed"
assert '[ -f "$lib_dir/templates/traefik/traefik.yml" ]'        "a template lands beside the libraries"
assert '[ -f "$lib_dir/templates/traefik/dynamic/_shared.yml" ]' "a nested template keeps its path"
assert '[ -f "$lib_dir/templates/remote-deploy.sh" ]'           "a template script lands"
assert '[ -x "$lib_dir/templates/remote-deploy.sh" ]' \
    "an executable template stays executable (mode $(stat -c %a "$lib_dir/templates/remote-deploy.sh" 2>/dev/null))"
assert '[ ! -x "$lib_dir/templates/traefik/traefik.yml" ]' \
    "a plain template is not made executable (mode $(stat -c %a "$lib_dir/templates/traefik/traefik.yml" 2>/dev/null))"

installed_version="$(env -u KASBAH_LIB_DIR XDG_DATA_HOME="$prefix/share" \
                         "$bin_dir/kasbah" --version 2>&1)"
assert '[ "$installed_version" = "$built_version" ]' \
    "the installed binary hands off to the installed dispatcher, which runs (got '$installed_version', built '$built_version')"
assert '[[ "$installed_version" == "kasbah $version"* ]]' \
    "and reports the VERSION it was built from (got '$installed_version')"
assert '[ "$(head -1 "$tmpdir/install.out")" = "installed $built_version" ]' \
    "install.sh reports the version it installed (got '$(head -1 "$tmpdir/install.out")')"

# --- Case 2: an upgrade does not preserve what upstream deleted ---------------
# The same discipline the *.sh copy has: a template removed from the repo must
# not linger on an upgraded machine, where it would be rendered onto a server
# long after it stopped existing here.
rm "$repo/templates/traefik/dynamic/_shared.yml"
printf 'left over\n' > "$lib_dir/templates/orphan.yml"
printf 'left over\n' > "$lib_dir/libexec/orphan"
printf 'left over\n' > "$lib_dir/server/kasbah-linux-mips"
install_it
assert '[ ! -e "$lib_dir/libexec/orphan" ] && [ ! -e "$lib_dir/server/kasbah-linux-mips" ]' \
    "nothing stale survives in libexec/ or server/ either"
assert '[ ! -f "$lib_dir/templates/traefik/dynamic/_shared.yml" ]' \
    "a template deleted upstream does not survive a re-install"
assert '[ ! -f "$lib_dir/templates/orphan.yml" ]' \
    "a file that was never a template does not survive a re-install"
assert '[ -f "$lib_dir/templates/traefik/traefik.yml" ]' \
    "the templates that remain are still installed"
assert '[ -x "$lib_dir/templates/remote-deploy.sh" ]' \
    "the executable bit survives a re-install too"

# --- Case 3: an empty templates/ still yields a directory ---------------------
# KASBAH_TEMPLATE_DIR resolves to this path on an installed kasbah whether or
# not any template exists yet, and "no such directory" is a worse first
# encounter than an empty one.
rm -rf "$repo/templates"
mkdir -p "$repo/templates"
install_it
assert '[ -d "$lib_dir/templates" ]' "an empty templates/ still installs the directory"
assert '[ -z "$(ls -A "$lib_dir/templates")" ]' \
    "and it is empty (got: $(ls -A "$lib_dir/templates" 2>/dev/null | tr '\n' ' '))"

# --- Case 4: a lib dir that is not kasbah's is not emptied -------------------
# Installing deletes inside $lib_dir, which comes from the environment. One
# mistyped KASBAH_LIB_DIR should not take a directory of unrelated files with
# it — and the *.sh sweep alone was already enough to do damage before templates
# made it recursive.
foreign="$tmpdir/foreign"
mkdir -p "$foreign/keepme"
printf 'not kasbah\n' > "$foreign/notes.txt"
printf 'nor this\n'    > "$foreign/lib.sh"
foreign_err="$tmpdir/foreign.err"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/foreign-bin" KASBAH_LIB_DIR="$foreign" \
    "$repo/install.sh" >/dev/null 2>"$foreign_err"
foreign_rc=$?
assert '[ "$foreign_rc" != "0" ]' "installing into a foreign directory fails (exit $foreign_rc)"
assert 'grep -qF "refusing to remove anything" <"$foreign_err"' \
    "the refusal says it removed nothing (got '$(cat "$foreign_err")')"
assert '[ -f "$foreign/notes.txt" ] && [ -f "$foreign/lib.sh" ] && [ -d "$foreign/keepme" ]' \
    "nothing in the foreign directory was touched"

# A fresh, absent target is the ordinary first install and must still work.
fresh="$tmpdir/fresh"
env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$fresh/bin" KASBAH_LIB_DIR="$fresh/lib" \
    "$repo/install.sh" >/dev/null 2>&1
fresh_rc=$?
assert '[ "$fresh_rc" = "0" ]'              "a first install into an absent directory succeeds (exit $fresh_rc)"
assert '[ -f "$fresh/lib/common.sh" ]'      "the first install placed the libraries"
assert '[ -d "$fresh/lib/templates" ]'      "the first install placed the templates directory"
# A non-default library directory is named again at run time; the binary
# finds its dispatcher there.
fresh_version=$(env -u XDG_DATA_HOME KASBAH_LIB_DIR="$fresh/lib" "$fresh/bin/kasbah" --version 2>&1)
assert '[ "$fresh_version" = "$built_version" ]' \
    "an install under KASBAH_LIB_DIR runs from it (got '$fresh_version')"
# Pointed nowhere, it says where it looked rather than running something else.
nowhere_out=$(env -u XDG_DATA_HOME KASBAH_LIB_DIR="$tmpdir/nowhere" "$fresh/bin/kasbah" --help 2>&1)
nowhere_rc=$?
assert '[ "$nowhere_rc" = "1" ] && grep -qF "$tmpdir/nowhere/libexec/kasbah-bash" <<<"$nowhere_out"' \
    "a library directory without the dispatcher is exit 1, naming the path (exit $nowhere_rc: $nowhere_out)"
# --version is the one question a binary with no Bash beside it — a server's —
# still answers, from its own stamp.
nowhere_version=$(env -u XDG_DATA_HOME KASBAH_LIB_DIR="$tmpdir/nowhere" "$fresh/bin/kasbah" --version 2>&1)
nowhere_rc=$?
assert '[ "$nowhere_rc" = "0" ] && [ "$nowhere_version" = "$built_version" ]' \
    "without a dispatcher, --version still answers with the build (exit $nowhere_rc: $nowhere_version)"

# --- Case 4b: a dist/ install.sh cannot use, or a KASBAH_SKIP_BUILD it cannot read
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

# The installed copy is asked its version before install.sh reports success, so
# a layout it cannot run from fails the install rather than printing a blank.
cp "$repo/libexec/kasbah-bash" "$tmpdir/dispatcher.aside"
printf '#!/usr/bin/env bash\nexit 3\n' > "$repo/libexec/kasbah-bash"
broken_out=$(env -u XDG_DATA_HOME KASBAH_SKIP_BUILD=1 KASBAH_BIN_DIR="$tmpdir/broken/bin" \
                 KASBAH_LIB_DIR="$tmpdir/broken/lib" "$repo/install.sh" 2>/dev/null)
broken_rc=$?
cp "$tmpdir/dispatcher.aside" "$repo/libexec/kasbah-bash"
assert '[ "$broken_rc" != "0" ]' "an installed copy that cannot run fails the install (exit $broken_rc)"
assert '! grep -q "^installed" <<<"$broken_out"' "and it does not claim success (got '$broken_out')"

# --- Case 5: KASBAH_TEMPLATE_DIR resolution, all four modes ------------------
# There is no command that prints the resolved directory, so a stand-in library
# does: the dispatcher exports KASBAH_TEMPLATE_DIR before dispatching, and this
# reports what it exported. It replaces only the command, so the resolution
# under test is the dispatcher's own, reached through the binary.
stub_lib="$tmpdir/stublib"
mkdir -p "$stub_lib"
cp "$repo_dir/lib/common.sh" "$stub_lib/common.sh"
cp "$repo_dir/VERSION" "$stub_lib/VERSION"
# Read back out of a child process, so the value is asserted the way a helper
# kasbah shells out to would see it — exported, like KASBAH_LIB_DIR beside it.
cat > "$stub_lib/init_project.sh" <<'STUB'
cmd_init_project() {
    printf 'template_dir=%s\n' "$(bash -c 'printf %s "${KASBAH_TEMPLATE_DIR:-<not exported>}"')"
}
STUB

# `init-project --help`, never a bare init-project: the Go binary owns the
# command and hands only --help to the dispatcher, which then reaches the stub.
# From $tmpdir, so a probe that ever reaches the real command scaffolds nothing
# into the checkout.
resolved() {
    local out
    out=$(cd "$tmpdir" && env "$@" 2>&1)
    printf '%s' "${out#template_dir=}"
}

got=$(resolved KASBAH_LIB_DIR="$stub_lib" KASBAH_TEMPLATE_DIR="$tmpdir/elsewhere" \
               "$repo/dist/kasbah" init-project --help)
assert '[ "$got" = "$tmpdir/elsewhere" ]' \
    "an explicit KASBAH_TEMPLATE_DIR wins (got '$got')"

# Templates travel with the libraries. Naming a library directory and getting
# the checkout's templates would pair an installed kasbah's code with a
# working tree's files — a mix neither of them was tested as.
got=$(resolved -u KASBAH_TEMPLATE_DIR KASBAH_LIB_DIR="$stub_lib" \
               "$repo/dist/kasbah" init-project --help)
assert '[ "$got" = "$stub_lib/templates" ]' \
    "an explicit KASBAH_LIB_DIR takes the templates with it, even inside a checkout (got '$got')"

# A plain checkout run — nothing in the environment — uses the checkout's own.
cp "$stub_lib/init_project.sh" "$repo/lib/init_project.sh"
got=$(resolved -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u XDG_DATA_HOME \
               "$repo/dist/kasbah" init-project --help)
assert '[ "$got" = "$repo/templates" ]' \
    "a checkout uses its own templates/ (got '$got')"

# The installed layout: no install.sh sibling to detect, so the templates are
# the ones that shipped next to the libraries.
cp "$stub_lib/init_project.sh" "$lib_dir/init_project.sh"
got=$(resolved -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR XDG_DATA_HOME="$prefix/share" \
               "$bin_dir/kasbah" init-project --help)
assert '[ "$got" = "$lib_dir/templates" ]' \
    "an installed kasbah reads templates from beside its libraries (got '$got')"

exit "$fail"
