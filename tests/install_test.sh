#!/usr/bin/env bash
# Test: install.sh ships templates/ alongside the libraries, and bin/hosting
# finds them wherever it is running from.
#
# Installing is the case nobody exercises by hand — the repo is always run from
# a checkout — so it is the one that silently rots. Templates are rendered onto
# servers, so a hosting installed without them is a hosting whose `server init`
# works for its authors and for nobody else.
#
# The repo is copied into a temp dir first: the throwaway templates the modes
# and the stale-file rule need must not be created in the working tree.

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

# --- A repo copy with templates in it -----------------------------------------
repo="$tmpdir/repo"
mkdir -p "$repo"
cp -R "$repo_dir/bin" "$repo_dir/lib" "$repo_dir/templates" "$repo/"
cp "$repo_dir/install.sh" "$repo_dir/VERSION" "$repo/"
chmod 0755 "$repo/install.sh"

mkdir -p "$repo/templates/traefik/dynamic"
printf 'plain\n'                    > "$repo/templates/traefik/traefik.yml"
printf 'nested\n'                   > "$repo/templates/traefik/dynamic/_shared.yml"
printf '#!/usr/bin/env bash\ntrue\n' > "$repo/templates/remote-deploy.sh"
chmod 0755 "$repo/templates/remote-deploy.sh"

prefix="$tmpdir/prefix"
bin_dir="$prefix/bin"
lib_dir="$prefix/share/hosting"

install_it() {
    env -u HOSTING_LIB_DIR HOSTING_BIN_DIR="$bin_dir" XDG_DATA_HOME="$prefix/share" \
        "$repo/install.sh" >"$tmpdir/install.out" 2>"$tmpdir/install.err"
}

# --- Case 1: templates land, whole -------------------------------------------
install_it
rc=$?
assert '[ "$rc" = "0" ]' "install.sh succeeds (exit $rc: $(cat "$tmpdir/install.err"))"
assert '[ -f "$bin_dir/hosting" ]'                              "the CLI is installed"
assert '[ -f "$lib_dir/common.sh" ]'                            "the libraries are installed"
assert '[ -f "$lib_dir/templates/traefik/traefik.yml" ]'        "a template lands beside the libraries"
assert '[ -f "$lib_dir/templates/traefik/dynamic/_shared.yml" ]' "a nested template keeps its path"
assert '[ -f "$lib_dir/templates/remote-deploy.sh" ]'           "a template script lands"
assert '[ -x "$lib_dir/templates/remote-deploy.sh" ]' \
    "an executable template stays executable (mode $(stat -c %a "$lib_dir/templates/remote-deploy.sh" 2>/dev/null))"
assert '[ ! -x "$lib_dir/templates/traefik/traefik.yml" ]' \
    "a plain template is not made executable (mode $(stat -c %a "$lib_dir/templates/traefik/traefik.yml" 2>/dev/null))"

installed_version="$(env -u HOSTING_LIB_DIR XDG_DATA_HOME="$prefix/share" \
                         "$bin_dir/hosting" --version 2>&1)"
assert '[ "$installed_version" = "hosting $version" ]' \
    "the installed CLI runs from the installed libraries (got '$installed_version')"

# --- Case 2: an upgrade does not preserve what upstream deleted ---------------
# The same discipline the *.sh copy has: a template removed from the repo must
# not linger on an upgraded machine, where it would be rendered onto a server
# long after it stopped existing here.
rm "$repo/templates/traefik/dynamic/_shared.yml"
printf 'left over\n' > "$lib_dir/templates/orphan.yml"
install_it
assert '[ ! -f "$lib_dir/templates/traefik/dynamic/_shared.yml" ]' \
    "a template deleted upstream does not survive a re-install"
assert '[ ! -f "$lib_dir/templates/orphan.yml" ]' \
    "a file that was never a template does not survive a re-install"
assert '[ -f "$lib_dir/templates/traefik/traefik.yml" ]' \
    "the templates that remain are still installed"
assert '[ -x "$lib_dir/templates/remote-deploy.sh" ]' \
    "the executable bit survives a re-install too"

# --- Case 3: an empty templates/ still yields a directory ---------------------
# HOSTING_TEMPLATE_DIR resolves to this path on an installed hosting whether or
# not any template exists yet, and "no such directory" is a worse first
# encounter than an empty one.
rm -rf "$repo/templates"
mkdir -p "$repo/templates"
install_it
assert '[ -d "$lib_dir/templates" ]' "an empty templates/ still installs the directory"
assert '[ -z "$(ls -A "$lib_dir/templates")" ]' \
    "and it is empty (got: $(ls -A "$lib_dir/templates" 2>/dev/null | tr '\n' ' '))"

# --- Case 4: a lib dir that is not hosting's is not emptied -------------------
# Installing deletes inside $lib_dir, which comes from the environment. One
# mistyped HOSTING_LIB_DIR should not take a directory of unrelated files with
# it — and the *.sh sweep alone was already enough to do damage before templates
# made it recursive.
foreign="$tmpdir/foreign"
mkdir -p "$foreign/keepme"
printf 'not hosting\n' > "$foreign/notes.txt"
printf 'nor this\n'    > "$foreign/lib.sh"
foreign_err="$tmpdir/foreign.err"
env -u XDG_DATA_HOME HOSTING_BIN_DIR="$tmpdir/foreign-bin" HOSTING_LIB_DIR="$foreign" \
    "$repo/install.sh" >/dev/null 2>"$foreign_err"
foreign_rc=$?
assert '[ "$foreign_rc" != "0" ]' "installing into a foreign directory fails (exit $foreign_rc)"
assert 'grep -qF "refusing to remove anything" <"$foreign_err"' \
    "the refusal says it removed nothing (got '$(cat "$foreign_err")')"
assert '[ -f "$foreign/notes.txt" ] && [ -f "$foreign/lib.sh" ] && [ -d "$foreign/keepme" ]' \
    "nothing in the foreign directory was touched"

# A fresh, absent target is the ordinary first install and must still work.
fresh="$tmpdir/fresh"
env -u XDG_DATA_HOME HOSTING_BIN_DIR="$fresh/bin" HOSTING_LIB_DIR="$fresh/lib" \
    "$repo/install.sh" >/dev/null 2>&1
fresh_rc=$?
assert '[ "$fresh_rc" = "0" ]'              "a first install into an absent directory succeeds (exit $fresh_rc)"
assert '[ -f "$fresh/lib/common.sh" ]'      "the first install placed the libraries"
assert '[ -d "$fresh/lib/templates" ]'      "the first install placed the templates directory"

# --- Case 5: HOSTING_TEMPLATE_DIR resolution, all four modes ------------------
# There is no command that prints the resolved directory, so a stand-in library
# does: bin/hosting exports HOSTING_TEMPLATE_DIR before dispatching, and this
# reports what it exported. It replaces only the command, so the resolution
# under test is bin/hosting's own.
stub_lib="$tmpdir/stublib"
mkdir -p "$stub_lib"
cp "$repo_dir/lib/common.sh" "$stub_lib/common.sh"
cp "$repo_dir/VERSION" "$stub_lib/VERSION"
# Read back out of a child process, so the value is asserted the way a helper
# hosting shells out to would see it — exported, like HOSTING_LIB_DIR beside it.
cat > "$stub_lib/init_project.sh" <<'STUB'
cmd_init_project() {
    printf 'template_dir=%s\n' "$(bash -c 'printf %s "${HOSTING_TEMPLATE_DIR:-<not exported>}"')"
}
STUB

resolved() {
    local out
    out=$(env "$@" 2>&1)
    printf '%s' "${out#template_dir=}"
}

got=$(resolved HOSTING_LIB_DIR="$stub_lib" HOSTING_TEMPLATE_DIR="$tmpdir/elsewhere" \
               "$repo/bin/hosting" init-project)
assert '[ "$got" = "$tmpdir/elsewhere" ]' \
    "an explicit HOSTING_TEMPLATE_DIR wins (got '$got')"

# Templates travel with the libraries. Naming a library directory and getting
# the checkout's templates would pair an installed hosting's code with a
# working tree's files — a mix neither of them was tested as.
got=$(resolved -u HOSTING_TEMPLATE_DIR HOSTING_LIB_DIR="$stub_lib" \
               "$repo/bin/hosting" init-project)
assert '[ "$got" = "$stub_lib/templates" ]' \
    "an explicit HOSTING_LIB_DIR takes the templates with it, even inside a checkout (got '$got')"

# A plain checkout run — nothing in the environment — uses the checkout's own.
cp "$stub_lib/init_project.sh" "$repo/lib/init_project.sh"
got=$(resolved -u HOSTING_LIB_DIR -u HOSTING_TEMPLATE_DIR -u XDG_DATA_HOME \
               "$repo/bin/hosting" init-project)
assert '[ "$got" = "$repo/templates" ]' \
    "a checkout uses its own templates/ (got '$got')"

# The installed layout: no install.sh sibling to detect, so the templates are
# the ones that shipped next to the libraries.
cp "$stub_lib/init_project.sh" "$lib_dir/init_project.sh"
got=$(resolved -u HOSTING_LIB_DIR -u HOSTING_TEMPLATE_DIR XDG_DATA_HOME="$prefix/share" \
               "$bin_dir/hosting" init-project)
assert '[ "$got" = "$lib_dir/templates" ]' \
    "an installed hosting reads templates from beside its libraries (got '$got')"

exit "$fail"
