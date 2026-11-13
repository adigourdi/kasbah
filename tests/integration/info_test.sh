#!/usr/bin/env bash
# Integration test: `kasbah info USER@HOST` against the rig (docs/cli.md) — the
# server's lines, and that info changes nothing there.
#
# Unprepared, three states of the rig's binary: none at all (no /apps), this
# build (shipped by the hidden `kasbah __ensure-server --apps-path=/apps`, the
# bootstrap mode), and one that is there but does not run (mode 644) — each
# answered with the no-marker refusal, never a runnable bare init. Prepared by
# `server init`: this build, and an older build planted over it (a variant
# stamped older, built through the compose toolchain under .cache/), which
# info says the next command would replace. Only this build reads the OS,
# Docker and compose, and those must be what the rig itself answers. In every
# state the files under /apps and /etc/kasbah are the same before and after.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
bin=$apps/.kasbah/bin/kasbah

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
variants=""
trap 'rm -rf "$tmpdir"; [ -z "$variants" ] || rm -rf "$variants"' EXIT

if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh — is the rig up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir"; then
    echo "error: could not build the scratch HOME and ssh wrapper under $tmpdir" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi

ours=$(kasbah_bin_version) || { echo "error: $KASBAH_BIN --version failed" >&2; exit 2; }

# What the rig answers by itself, for the same-build case to be checked against.
facts=$(rig_ssh '. /etc/os-release; printf "os=%s\n" "$PRETTY_NAME"; printf "machine=%s\n" "$(uname -m)"
    printf "docker=%s\n" "$(docker version --format "{{.Server.Version}}")"; printf "compose=%s\n" "$(docker compose version --short)"' 2>/dev/null)
facts=${facts//$'\r'/}
fact() { sed -n "s/^$1=//p" <<<"$facts"; }
case $(fact machine) in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch=$(fact machine) ;;
esac
if [ -z "$(fact os)" ] || [ -z "$(fact docker)" ]; then
    echo "error: could not read the rig's own os-release and docker version: $facts" >&2
    exit 2
fi

info() { kasbah_cli info "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
val() { tr -d '\r' <"$tmpdir/out" | sed -n "s/^$1: //p"; }
err() { tr -d '\r' <"$tmpdir/err"; }
snap() { rig_files_snapshot; rig_ssh "sha256sum $bin 2>/dev/null; stat -c %a $bin 2>/dev/null" 2>/dev/null | tr -d '\r'; }
server_keys="server server.apps server.prepared server.kasbah server.arch server.os server.docker server.compose"
keys() { tr -d '\r' <"$tmpdir/out" | cut -d: -f1 | tail -n 8 | tr '\n' ' '; }

# --- Case 1: nothing on the server --------------------------------------------
before=$(snap)
info; rc=$?
assert '[ "$rc" -eq 0 ]' "no binary: info exits 0 (got $rc: $(err))"
assert '[ "$(keys)" = "$server_keys " ]' "no binary: the server keys in order (got $(keys))"
assert '[ "$(val name)" = kasbah ] && [ "$(val build)" = "$ours" ]' "no binary: the workstation's lines come first"
assert '[ "$(val server)" = "$RIG_TARGET" ] && [ "$(val server.apps)" = "/apps (default)" ] && [ "$(val server.prepared)" = no ]' \
    "no binary: target, apps path and not prepared (got $(val server), $(val server.apps), $(val server.prepared))"
assert '[ "$(val server.kasbah)" = none ] && [ "$(val server.arch)" = "$arch" ]' "no binary: kasbah none, arch $arch (got $(val server.kasbah), $(val server.arch))"
assert '[ "$(val server.os)$(val server.docker)$(val server.compose)" = unknownunknownunknown ]' "no binary: os, docker and compose unknown"
assert 'grep -qF "has no server marker at $apps/.kasbah/server.json" <<<"$(err)" && grep -qF "changes nothing" <<<"$(err)"' "no binary: stderr says why, and the no-marker refusal (said $(err))"
assert '! grep -qF "init $RIG_TARGET" <<<"$(err)" && ! grep -qF "ships this build" <<<"$(err)"' "no binary: no runnable bare init, nothing said to ship (said $(err))"
assert '[ "$(snap)" = "$before" ]' "no binary: nothing written on the server"
assert '! rig_ssh "test -e $apps" 2>/dev/null' "no binary: no $apps created"

# --- Case 2: this build on the server -----------------------------------------
rig_ssh "sudo mkdir -p $apps && sudo chown $RIG_SSH_USER:$RIG_SSH_USER $apps" >/dev/null 2>&1
shipped=$(kasbah_cli __ensure-server --apps-path=$apps "$RIG_TARGET" 2>"$tmpdir/ensure.err" </dev/null); rc=$?
assert '[ "$rc" -eq 0 ] && [ "$shipped" = "shipped=none->$ours" ]' "this build is shipped for the case (rc $rc: $shipped $(cat "$tmpdir/ensure.err"))"
before=$(snap)
info; rc=$?
same_build() {
    prepared=$2
    assert '[ "$rc" -eq 0 ] && [ -z "$(err)" ]' "$1: info exits 0, nothing on stderr (got $rc: $(err))"
    assert '[ "$(val server.kasbah)" = "$ours" ] && [ "$(val server.prepared)" = "$prepared" ]' "$1: server.kasbah is ours, prepared $2 (got $(val server.kasbah), $(val server.prepared))"
    assert '[ "$(val server.os)" = "$(fact os)" ]' "$1: os is the rig's PRETTY_NAME ($(fact os), got $(val server.os))"
    assert '[ "$(val server.docker)" = "$(fact docker)" ]' "$1: docker is the rig's engine ($(fact docker), got $(val server.docker))"
    assert '[ "$(val server.compose)" = "$(fact compose)" ]' "$1: compose is the rig's ($(fact compose), got $(val server.compose))"
    assert '[ "$(val server.arch)" = "$arch" ]' "$1: arch (got $(val server.arch))"
    assert '[ "$(snap)" = "$before" ]' "$1: nothing written on the server"
}
same_build "same build" no

# --- Case 3: a binary that does not run ---------------------------------------
rig_ssh "chmod 644 $bin" >/dev/null 2>&1
before=$(snap)
info; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(val server.kasbah)" = unknown ] && [ "$(val server.os)" = unknown ]' \
    "not runnable: kasbah and os unknown (rc $rc, got $(val server.kasbah), $(val server.os))"
assert 'grep -qF "$bin is there and does not run" <<<"$(err)" && grep -qF "cannot say which build" <<<"$(err)"' "not runnable: stderr names the binary (said $(err))"
assert '! grep -qF "ships this build" <<<"$(err)"' "not runnable: unprepared, nothing said to ship (said $(err))"
assert '[ "$(snap)" = "$before" ]' "not runnable: the binary is neither replaced nor repaired"

# --- Case 4: a prepared server, this build ------------------------------------
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup --domain=rig.test --email=ops@rig.test \
        --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw" >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig:" >&2
    cat "$tmpdir/init.err" >&2
    exit 2
fi
before=$(snap)
info; rc=$?
same_build "prepared" yes

# --- Case 5: a prepared server, an older build --------------------------------
older="${ours%%.*}.0.0-dev.0.0"
mkdir -p "$repo_dir/.cache"
variants=$(mktemp -d "$repo_dir/.cache/info-test.XXXXXX")
rel=${variants#"$repo_dir"/}
if ! docker compose -f "$repo_dir/compose.yml" run --rm -T --entrypoint sh build -euc \
        'GOOS=linux GOARCH="$1" go build -trimpath -ldflags "-s -w -X main.build=$2" -o "$3" ./cmd/kasbah' \
        sh "$arch" "$older" "$rel/kasbah" >"$tmpdir/build.log" 2>&1 </dev/null; then
    echo "error: could not build the older server binary:" >&2
    cat "$tmpdir/build.log" >&2
    exit 2
fi
rig_ssh "cat > $bin.plant && chmod 755 $bin.plant && mv -f $bin.plant $bin" <"$variants/kasbah" >/dev/null 2>&1
older_sha=$(sha256sum "$variants/kasbah" | cut -d' ' -f1)
before=$(snap)
assert 'grep -qF "$older_sha" <<<"$before"' "older: the older build is planted"
info; rc=$?
assert '[ "$rc" -eq 0 ] && [ "$(val server.kasbah)" = "$older" ] && [ "$(val server.prepared)" = yes ]' \
    "older: info exits 0 naming the older build, prepared (rc $rc, got $(val server.kasbah), $(val server.prepared))"
assert '[ "$(val server.os)$(val server.docker)$(val server.compose)" = unknownunknownunknown ]' "older: its arm is not run, os, docker and compose unknown"
assert 'grep -qF "runs kasbah $older, another build" <<<"$(err)" && grep -qF "kasbah server status $RIG_TARGET\`, ships this build" <<<"$(err)"' \
    "older: stderr says the next server command ships this build (said $(err))"
assert '[ "$(snap)" = "$before" ]' "older: nothing shipped, nothing written on the server"

[ "$fail" = 0 ] && rig_clean && echo "info_test: info reads the server and changes nothing"
exit "$fail"
