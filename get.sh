#!/bin/sh
# Install kasbah on Linux: download this release's binary for the machine and
# its checksums.txt, check the sha256 (and the signature when minisign is
# here), then hand off to the binary's own `self-update`, which installs it.
#
#   curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh
#   curl -fsSL …/get.sh | sh -s -- [vN | vN.M | vN.M.P] [--pre] [--yes]
#
# Downloads try, in order: curl (or wget) from the release URL; curl with a
# token (GITHUB_TOKEN, else gh's) through the releases API; gh release download.
# KASBAH_GET_VERSION replaces the stamped version, KASBAH_GET_BASE the release
# URL, KASBAH_RELEASES_API the API.

set -eu

# release.sh stamps the release's version into this line; empty: not a release.
stamped=''

# release.pub's key: minisign -V checks checksums.txt against it.
kasbah_key='RWS3pRJJwM6L/B8Sp/FgiS4cUxJlSnceHOFLZIKsXPaE7LYtWA4ROLt8'
kasbah_repo='adigourdi/kasbah'

say() {
    printf 'get.sh: %s\n' "$*" >&2
}

# die MESSAGE [LINE…] — refuse, each further line indented beneath.
die() {
    printf 'get.sh: %s\n' "$1" >&2
    shift
    for die_l in ${1+"$@"}; do
        printf '  %s\n' "$die_l" >&2
    done
    exit 1
}

usage() {
    printf '%s\n' \
        "usage: curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh -s -- [vN | vN.M | vN.M.P] [--pre] [--yes]" \
        "  no version   this release, or the newest of its major" \
        "  a version    that release, resolved by kasbah self-update" \
        "  --pre        let vN / vN.M pick a pre-release (-rc.N)" \
        "  --yes        move ~/.local/bin/kasbah across majors without asking"
}

bad_usage() {
    printf 'get.sh: %s\n' "$1" >&2
    usage >&2
    exit 2
}

# why FILE RC — the last line of a failed command's stderr, else its status.
why() {
    g_why="exit status $2"
    while IFS= read -r why_l || [ -n "$why_l" ]; do
        [ -z "$why_l" ] || g_why=$why_l
    done <"$1"
}

# denied — whether g_why is an HTTP 401 or 404 (GNU wget -q: exit 8, any server error).
denied() {
    case $g_why in
        *"error: 401"* | *"error: 404"* | *" 401 "* | *" 404 "* | "exit status 8") return 0 ;;
    esac
    return 1
}

# Prints "name url" for every object of the release's top-level "assets" array
# that has string members "name" and "url"; key order does not matter.
# shellcheck disable=SC2016
assets_awk='
function str(v) {
    if (key == "url") u[d] = v
    else if (key == "name") nm[d] = v
    else if (key == "") cand = v
    key = ""
}
{
    s = $0; n = length(s); i = 1
    while (i <= n) {
        if (instr) {
            rest = substr(s, i)
            if (!match(rest, /["\\]/)) { buf = buf rest; break }
            buf = buf substr(rest, 1, RSTART - 1); i += RSTART - 1
            if (substr(s, i, 1) == "\\") {
                e = substr(s, i + 1, 1)
                buf = buf (e == "/" ? "/" : "\\" e); i += 2; continue
            }
            instr = 0; str(buf); i++; continue
        }
        c = substr(s, i, 1)
        if (c == "\"") { instr = 1; buf = "" }
        else if (c == "{" || c == "[") {
            if (c == "[" && d == 1 && key == "assets") ad = 2
            d++; u[d] = ""; nm[d] = ""; key = ""; cand = ""
        }
        else if (c == "}") {
            if (ad && d == ad + 1 && u[d] != "" && nm[d] != "") print nm[d], u[d]
            d--; key = ""; cand = ""
        }
        else if (c == "]") { if (d == ad) ad = 0; d--; key = ""; cand = "" }
        else if (c == ":") { key = cand; cand = "" }
        else if (c == ",") { key = ""; cand = "" }
        else if (c != " " && c != "\t" && c != "\r") key = ""
        i++
    }
}'

# Rung 1: the release URL, no credentials.
rung_bare() {
    if [ -z "$g_dl" ]; then
        g_why='neither curl nor wget is on PATH'
        return 1
    fi
    for g_f in $g_files; do
        g_url=$g_base/v$g_ver/$g_f
        g_rc=0
        if [ "$g_dl" = curl ]; then
            curl -fsSL -o "$g_tmp/$g_f" "$g_url" 2>"$g_tmp/err" || g_rc=$?
        else
            wget -q -O "$g_tmp/$g_f" "$g_url" 2>"$g_tmp/err" || g_rc=$?
        fi
        if [ "$g_rc" != 0 ]; then
            why "$g_tmp/err" "$g_rc"
            # A private repository refuses everything, the binary first.
            if [ "$g_f" = "$g_asset" ] && denied; then g_denied=1; fi
            g_why="$g_why ($g_f)"
            return 1
        fi
        # Busybox wget without certificate checks says so, and downloads anyway.
        case $g_dl$g_url in
            wgethttps://*)
                if awk '/TLS certificate validation not implemented/ { f = 1 } END { exit !f }' "$g_tmp/err"; then
                    g_tlsweak=1
                fi
                ;;
        esac
    done
}

# Rung 2: the releases API with a token, curl only — wget would resend the
# header to wherever an asset redirects. The redirect is followed by hand, so
# the token never leaves the API host whatever the curl version.
rung_api() {
    if [ "$g_dl" != curl ]; then
        g_why='needs curl (wget would carry the token across redirects)'
        return 1
    fi
    # The token passes through builtins and stdin only, never a command line.
    g_tok=${GITHUB_TOKEN:-} g_from=GITHUB_TOKEN
    case $g_tok in
        '')
            g_from=''
            if [ "$g_api" = https://api.github.com ] && command -v gh >/dev/null 2>&1; then
                g_tok=$(gh auth token --hostname github.com 2>/dev/null) || g_tok=''
                g_from='gh auth token'
            fi
            ;;
    esac
    # $g_ws unquoted on purpose: posh misreads quotes inside a bracket expression.
    # shellcheck disable=SC2295
    g_tok=${g_tok#"${g_tok%%[!$g_ws]*}"}
    # shellcheck disable=SC2295
    g_tok=${g_tok%"${g_tok##*[!$g_ws]}"}
    case $g_tok in
        '') g_why='no token (set GITHUB_TOKEN, or gh auth login)'; return 1 ;;
        *[!A-Za-z0-9_.-]*) g_why="the token from $g_from holds characters no GitHub token has"; return 1 ;;
    esac
    { : >"$g_tmp/auth" && chmod 600 "$g_tmp/auth" && cat >>"$g_tmp/auth"; } <<EOF || { g_why='could not write the header file'; return 1; }
Authorization: Bearer $g_tok
EOF
    say "trying the releases API at $g_api with the token from $g_from"
    curl -fsS -H @"$g_tmp/auth" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        -o "$g_tmp/release.json" "$g_api/repos/$kasbah_repo/releases/tags/v$g_ver" 2>"$g_tmp/err" ||
        { why "$g_tmp/err" $?; if denied; then g_denied=1; fi; g_why="release v$g_ver: $g_why"; return 1; }
    awk "$assets_awk" "$g_tmp/release.json" >"$g_tmp/assets" || { g_why='could not read the release JSON'; return 1; }
    for g_f in $g_files; do
        g_u=$(awk -v n="$g_f" 'NF == 2 && $1 == n { print $2; exit }' "$g_tmp/assets") || g_u=''
        case $g_u in
            '') g_why="the release v$g_ver lists no asset $g_f"; return 1 ;;
            "$g_api"/*) ;;
            *) g_why="the release lists $g_f at $g_u, outside $g_api: not fetched, the token not sent"; return 1 ;;
        esac
        g_out=$(curl -sS -H @"$g_tmp/auth" -H 'Accept: application/octet-stream' -H 'X-GitHub-Api-Version: 2022-11-28' \
            -o "$g_tmp/$g_f" -w '%{http_code} %{redirect_url}' "$g_u" 2>"$g_tmp/err") ||
            { why "$g_tmp/err" $?; g_why="$g_f: $g_why"; return 1; }
        g_code=${g_out%% *} g_loc=${g_out#* }
        case $g_code in
            200) ;;
            301 | 302 | 303 | 307 | 308)
                [ -n "$g_loc" ] || { g_why="$g_f: HTTP $g_code without a location"; return 1; }
                curl -fsSL -o "$g_tmp/$g_f" "$g_loc" 2>"$g_tmp/err" || { why "$g_tmp/err" $?; g_why="$g_f: $g_why"; return 1; }
                ;;
            *) g_why="$g_f: HTTP $g_code"; return 1 ;;
        esac
    done
}

# Rung 3: gh, with whatever login it holds.
rung_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        g_why='gh is not on PATH'
        return 1
    fi
    set --
    for g_f in $g_files; do
        set -- ${1+"$@"} -p "$g_f"
    done
    gh release download "v$g_ver" --repo "$kasbah_repo" ${1+"$@"} -D "$g_tmp" --clobber >/dev/null 2>"$g_tmp/err" ||
        { why "$g_tmp/err" $?; return 1; }
}

# fetch bare|api|gh LABEL — try one rung; on failure note why, under LABEL.
fetch() {
    for g_f in $g_files; do
        rm -f "$g_tmp/$g_f"
    done
    # The TLS note counts only for the rung that delivers.
    g_why='' g_ok='' g_tlsweak=''
    case $1 in
        bare) rung_bare && g_ok=1 ;;
        api) rung_api && g_ok=1; rm -f "$g_tmp/auth" ;;
        gh) rung_gh && g_ok=1 ;;
    esac
    if [ -n "$g_ok" ]; then
        for g_f in $g_files; do
            [ -f "$g_tmp/$g_f" ] || { g_why="$g_f did not arrive"; break; }
        done
        [ -n "$g_why" ] || return 0
    fi
    g_report="$g_report
  $2: $g_why"
    return 1
}

get_main() {
    g_want=''
    for g_a in ${1+"$@"}; do
        case $g_a in
            -h | --help) usage; exit 0 ;;
            --pre | --yes) ;;
            v[0-9]*)
                case $g_a in *[!0-9A-Za-z.-]*) bad_usage "not a version: '$g_a'" ;; esac
                [ -z "$g_want" ] || bad_usage "one version at a time ('$g_want', then '$g_a')"
                g_want=$g_a
                ;;
            *) bad_usage "unknown argument '$g_a'" ;;
        esac
    done

    g_ver=${KASBAH_GET_VERSION:-$stamped}
    [ -n "$g_ver" ] || die 'this get.sh is not from a release: use https://github.com/adigourdi/kasbah/releases/latest/download/get.sh'
    case $g_ver in
        *[!0-9A-Za-z.-]* | v*) die "not a release version: '$g_ver' (N.M.P[-rc.K], no v)" ;;
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "not a release version: '$g_ver' (N.M.P[-rc.K], no v)" ;;
    esac

    g_os=$(uname -s)
    [ "$g_os" = Linux ] || die "kasbah runs on Linux, not $g_os"
    g_m=$(uname -m)
    case $g_m in
        x86_64 | amd64) g_arch=amd64 ;;
        aarch64 | arm64) g_arch=arm64 ;;
        *) die "kasbah has no build for $g_m: Linux on x86_64 (amd64) or aarch64 (arm64) only" ;;
    esac

    if command -v sha256sum >/dev/null 2>&1; then
        g_sha='sha256sum'
    elif command -v shasum >/dev/null 2>&1; then
        g_sha='shasum -a 256'
    else
        die 'neither sha256sum nor shasum is on PATH: the download cannot be checked'
    fi
    if command -v curl >/dev/null 2>&1; then
        g_dl=curl
    elif command -v wget >/dev/null 2>&1; then
        g_dl=wget
    else
        g_dl=''
    fi

    # Not a version-named directory: kasbah reads <dir>/<semver>/kasbah as a library.
    g_tmp=$(mktemp -d) || die 'mktemp -d failed'
    trap 'rm -rf "$g_tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    g_asset=kasbah_${g_ver}_linux_$g_arch
    g_files="$g_asset checksums.txt"
    g_minisign=''
    if command -v minisign >/dev/null 2>&1; then
        g_minisign=minisign
        g_files="$g_files checksums.txt.minisig"
    fi
    g_base=${KASBAH_GET_BASE:-https://github.com/$kasbah_repo/releases/download}
    g_api=${KASBAH_RELEASES_API:-https://api.github.com}
    g_api=${g_api%/}

    say "kasbah $g_ver for linux/$g_arch: fetching $g_asset from $g_base/v$g_ver/"
    g_report='' g_denied=''
    # Whitespace a token may carry around it: space, newline, tab, CR.
    g_ws=$(printf ' \n\t\r')
    if fetch bare "${g_dl:-download} from $g_base"; then
        :
    elif fetch api "releases API ($g_api)"; then
        say "fetched through the releases API"
    elif fetch gh "gh release download"; then
        say "fetched with gh release download"
    else
        printf 'get.sh: could not download kasbah %s:%s\n' "$g_ver" "$g_report" >&2
        [ -z "$g_denied" ] || die 'a private repository needs GITHUB_TOKEN set, or gh logged in (gh auth login)'
        exit 1
    fi
    if [ -n "$g_tlsweak" ] && [ -z "$g_minisign" ]; then
        die "this wget does not check TLS certificates, so the download from $g_base is unauthenticated: nothing was run" \
            'install curl, or minisign to check the signature, and run get.sh again'
    fi

    if [ -n "$g_minisign" ]; then
        g_out=$(minisign -Vm "$g_tmp/checksums.txt" -P "$kasbah_key" 2>&1) ||
            die "checksums.txt does not verify against release.pub: nothing was installed" "$g_out"
        say 'checksums.txt signature verified with minisign'
    else
        say 'no minisign here: kasbah checks the signature itself before it installs'
    fi

    g_want_sum=$(awk -v n="$g_asset" '{ sub(/\r$/, "") } NF == 2 && ($2 == n || $2 == "*" n) { print $1; exit }' "$g_tmp/checksums.txt")
    [ -n "$g_want_sum" ] || die "checksums.txt lists no $g_asset: nothing was installed"
    g_sum=$($g_sha <"$g_tmp/$g_asset")
    g_sum=${g_sum%% *}
    [ "$g_sum" = "$g_want_sum" ] ||
        die "$g_asset does not match checksums.txt: nothing was installed" "sha256 $g_sum" "expected $g_want_sum"
    say "sha256 of $g_asset matches checksums.txt"

    mv "$g_tmp/$g_asset" "$g_tmp/kasbah"
    chmod 755 "$g_tmp/kasbah"
    g_rc=0
    g_v=$("$g_tmp/kasbah" --version 2>&1) || g_rc=$?
    case $g_rc in
        0) ;;
        126) die "cannot run $g_tmp/kasbah: its temp dir does not allow execution (mounted noexec?)" \
            'set TMPDIR to a directory that does, and run get.sh again' ;;
        *) die "$g_asset does not run here (exit $g_rc): nothing was installed" "$g_v" ;;
    esac
    case $g_v in
        "kasbah $g_ver" | "kasbah $g_ver "*) ;;
        *) die "$g_asset answers '$g_v', not kasbah $g_ver: nothing was installed" ;;
    esac
    # Never the pipe this script may arrive on: the terminal, else nothing.
    if (: </dev/tty) 2>/dev/null; then g_in=/dev/tty; else g_in=/dev/null; fi
    say "running kasbah self-update${*:+ $*}"
    g_rc=0
    "$g_tmp/kasbah" self-update ${1+"$@"} <"$g_in" || g_rc=$?
    exit "$g_rc"
}

get_main ${1+"$@"} </dev/null
