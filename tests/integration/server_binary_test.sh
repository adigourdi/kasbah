#!/usr/bin/env bash
# Integration test: the server binary's same-build rule (docs/server-setup.md,
# version compatibility), driven through the hidden `kasbah __ensure-server
# USER@HOST`.
#
# The workstation is the binary under test. The server's binary is planted
# from variant builds stamped older, newer of the same major and newer of the
# next major, built through the compose toolchain into a scratch directory
# under .cache/ — never over dist/. After each case the bytes at
# <apps>/.kasbah/bin/kasbah are checked against the build that should be there.
# A newer same-major build is refused, and the workstation hands the command
# off to that build when it is installed under KASBAH_LIB_DIR. A release
# build replaces a dev build of its major however the two order, and a dev
# build never replaces the release it ranks below. A dev build over a release
# that ranks below it asks first: without a terminal or --ship-dev/--keep-server
# it fails naming both; --keep-server hands off to the release when it is
# installed; --ship-dev ships. Every change prints `server kasbah OLD → NEW`.
#
# Also: an unprepared server refuses with exit 4; a server binary from another
# build is refused before it replaces anything; two workstations racing end on
# the newer build; a hanging server binary is refused by the timeout; SIGINT
# mid-probe and mid-upload leave nothing behind; stale uploads are swept;
# `--apps-path` ships with no marker; a noexec apps path is named as the cause.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
bin_dir=$apps/.kasbah/bin
bin=$bin_dir/kasbah
pointer=/etc/kasbah/apps-path
noexec_mnt=/srv/kasbah-noexec
boot_dir=/srv/kasbah-boot

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
variants=""
mounted=""
pointer_saved=""
cleanup() {
    rig_ssh "sudo rm -rf $boot_dir" >/dev/null 2>&1
    [ -z "$mounted" ] || rig_ssh "sudo umount $mounted; sudo rmdir $mounted" >/dev/null 2>&1
    [ -z "$pointer_saved" ] || rig_ssh "sudo cp $pointer_saved $pointer && sudo rm -f $pointer_saved" >/dev/null 2>&1
    [ -z "$variants" ] || rm -rf "$variants"
    rm -rf "$tmpdir"
}
trap cleanup EXIT

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

machine=$(rig_ssh "uname -m" 2>/dev/null); machine=${machine//$'\r'/}
case $machine in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "error: the rig's machine type '$machine' has no server build" >&2; exit 2 ;;
esac

ours=$(kasbah_bin_version) || { echo "error: $KASBAH_BIN --version failed" >&2; exit 2; }
major=${ours%%.*}

# The server binary the workstation under test ships: its own build's, found
# the way the binary finds it (internal/serverbin.Home).
ws_root=$(cd "$(dirname "$(readlink -f "$KASBAH_BIN")")/.." && pwd)
if [ -f "$ws_root/go.mod" ] && [ -d "$ws_root/cmd/kasbah" ]; then
    ours_server="$ws_root/dist/server/kasbah-linux-$arch"
else
    ours_server="$(dirname "$(readlink -f "$KASBAH_BIN")")/server/kasbah-linux-$arch"
fi
if [ ! -f "$ours_server" ]; then
    echo "error: no server binary beside $KASBAH_BIN (looked for $ours_server)" >&2
    exit 2
fi

# --- Variant builds -----------------------------------------------------------
older="$major.0.0-dev.0.0"
newer="$major.999999.0"
next_major="$((major + 1)).0.0"
# A release of our major that outranks our build — our own base version when
# ours is a pre-release, the next patch when it is a release — and a dev build
# above it by order (another checkout's, as tools/stamp marks them).
base=${ours%%[-+]*}
if [ "$base" != "$ours" ]; then
    release=$base
else
    release="${base%.*}.$(( ${base##*.} + 1 ))"
fi
dev_above="$major.999999.0-dev.1.1+gabc1234.dirty"
# A release ours replaces, when ours is a dev build of a later version.
below="$major.0.0"

mkdir -p "$repo_dir/.cache"
variants=$(mktemp -d "$repo_dir/.cache/server-binary-test.XXXXXX")
rel=${variants#"$repo_dir"/}
# An ELF that never answers: a server binary hanging in `remote version`.
printf 'package main\n\nimport "time"\n\nfunc main() { time.Sleep(time.Hour) }\n' >"$variants/hang.go"
if ! docker compose -f "$repo_dir/compose.yml" run --rm -T --entrypoint sh build -euc '
        for v in "$@"; do
            GOOS=linux GOARCH='"$arch"' go build -trimpath -ldflags "-s -w -X main.build=$v" \
                -o "'"$rel"'/kasbah-$v" ./cmd/kasbah
        done
        GOOS=linux GOARCH='"$arch"' go build -o "'"$rel"'/hang" "'"$rel"'/hang.go"' \
        sh "$older" "$newer" "$next_major" "$release" "$dev_above" "$below" >"$tmpdir/build.log" 2>&1 </dev/null; then
    echo "error: could not build the variant server binaries:" >&2
    cat "$tmpdir/build.log" >&2
    exit 2
fi

sha() { sha256sum "$1" | cut -d' ' -f1; }
server_sha() {
    local s
    s=$(rig_ssh "sha256sum $bin 2>/dev/null || echo absent" 2>/dev/null)
    s=${s//$'\r'/}
    printf '%s\n' "${s%% *}"
}
# What sits beside the binary: `kasbah` and the install lock, never an upload.
bin_dir_list() {
    local s
    s=$(rig_ssh "ls -A ${1:-$bin_dir} 2>/dev/null" 2>/dev/null)
    printf '%s\n' "${s//$'\r'/}"
}
uploads_left() { bin_dir_list "$@" | grep -F .kasbah. || true; }
plant() {
    rig_ssh "mkdir -p $bin_dir && cat > $bin_dir/.plant && chmod 755 $bin_dir/.plant && mv -f $bin_dir/.plant $bin" <"$1" >/dev/null 2>&1
}
ensure() {
    kasbah_cli __ensure-server "$@" "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}
out() { tr -d '\r' <"$tmpdir/out"; }
err() { tr -d '\r' <"$tmpdir/err"; }

ours_sha=$(sha "$ours_server")
older_sha=$(sha "$variants/kasbah-$older")
newer_sha=$(sha "$variants/kasbah-$newer")
major_sha=$(sha "$variants/kasbah-$next_major")
release_sha=$(sha "$variants/kasbah-$release")
dev_above_sha=$(sha "$variants/kasbah-$dev_above")
below_sha=$(sha "$variants/kasbah-$below")

# --- Case 0: a server init never prepared -------------------------------------
ensure; rc=$?
assert '[ "$rc" = 4 ]' "an unprepared server is exit 4 (exit $rc: $(err))"
assert 'grep -qF "kasbah server init" <<<"$(err)"' "and the refusal names kasbah server init (said '$(err)')"
assert '! grep -qF "kasbah server init $RIG_TARGET" <<<"$(err)"' \
    "but no runnable bare init, which a lost pointer would turn on the running proxy (said '$(err)')"
assert '[ "$(rig_ssh "[ -e $apps ] && echo present || echo absent" 2>/dev/null | tr -d "\r")" = absent ]' \
    "nothing was created on the unprepared server"

if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}" \
        >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig:" >&2
    cat "$tmpdir/init.err" >&2
    exit 2
fi
# Init ships the binary into the apps path it has just created (bootstrap
# mode); taken away again so the cases below start from none.
assert '[ "$(server_sha)" = "$ours_sha" ]' "server init left the workstation's build at $bin ($(server_sha))"
rig_ssh "rm -rf $bin_dir" >/dev/null 2>&1

# --- Case 1: absent → shipped -------------------------------------------------
ensure; rc=$?
assert '[ "$rc" = 0 ]' "absent: ensure succeeds (exit $rc: $(err))"
assert '[ "$(out)" = "shipped=none->$ours" ]' "absent: the workstation's build is shipped (said '$(out)')"
assert 'grep -qxF "server kasbah (none) → $ours" <<<"$(err)"' "absent: the change is one line on stderr (said '$(err)')"
assert '[ "$(server_sha)" = "$ours_sha" ]' "absent: the server holds the workstation's server build ($(server_sha))"
assert '[ "$(bin_dir_list)" = ".lock
kasbah" ]' "absent: the binary and the install lock, nothing else, in $bin_dir ($(bin_dir_list | tr '\n' ' '))"
modes=$(rig_ssh "stat -c '%a %U %G' $bin_dir $bin $bin_dir/.lock" 2>/dev/null | tr -d '\r')
assert '[ "$modes" = "2775 $RIG_SSH_USER kasbah
775 $RIG_SSH_USER kasbah
664 $RIG_SSH_USER kasbah" ]' "the directory is 2775, the binary 775, the lock 664: the deploy user's, and the kasbah group's for every operator (got '$modes')"
direct=$(rig_ssh "$bin remote version; $bin --version" 2>&1 | tr -d '\r')
ours_line=$("$KASBAH_BIN" --version)
assert '[ "$direct" = "build=$ours
$ours_line" ]' "the server binary answers remote version and --version (got '$direct')"

# --- Case 2: older → replaced -------------------------------------------------
plant "$variants/kasbah-$older"
assert '[ "$(server_sha)" = "$older_sha" ]' "older: the older build is planted"
ensure; rc=$?
assert '[ "$rc" = 0 ]' "older: ensure succeeds (exit $rc: $(err))"
assert '[ "$(out)" = "shipped=$older->$ours" ]' "older: replaced, naming both builds (said '$(out)')"
assert 'grep -qxF "server kasbah $older → $ours" <<<"$(err)"' "older: a dev build on the server is replaced without a question, in one line (said '$(err)')"
assert '[ "$(server_sha)" = "$ours_sha" ]' "older: the server now holds the workstation's build"
assert '[ -z "$(uploads_left)" ]' "older: no upload left behind ($(uploads_left))"

# --- Case 3: same → kept ------------------------------------------------------
inode_before=$(rig_ssh "stat -c %i $bin" 2>/dev/null | tr -d '\r')
ensure; rc=$?
inode_after=$(rig_ssh "stat -c %i $bin" 2>/dev/null | tr -d '\r')
assert '[ "$rc" = 0 ]' "same: ensure succeeds (exit $rc: $(err))"
assert '[ "$(out)" = "kept=$ours" ]' "same: kept (said '$(out)')"
assert '[ -z "$(err)" ]' "same: nothing changed, nothing said (said '$(err)')"
assert '[ "$inode_before" = "$inode_after" ] && [ "$(server_sha)" = "$ours_sha" ]' \
    "same: the file was not rewritten (inode $inode_before → $inode_after)"

# --- Case 4: newer of the same major → refused, or handed off to that build ---
plant "$variants/kasbah-$newer"
ensure; rc=$?
assert '[ "$rc" = 1 ]' "newer: refused with exit 1 (exit $rc: $(err))"
assert 'grep -qF "$newer" <<<"$(err)" && grep -qF "$ours" <<<"$(err)"' \
    "newer: the refusal names both builds (said '$(err)')"
assert 'grep -qF "checkout" <<<"$(err)"' "newer: a checkout says it cannot hand off (said '$(err)')"
assert '[ -z "$(out)" ]' "newer: no result line (got '$(out)')"
assert '[ "$(server_sha)" = "$newer_sha" ] && [ -z "$(uploads_left)" ]' \
    "newer: nothing was replaced and no upload left ($(bin_dir_list | tr '\n' ' '))"

# An installed workstation of our build, with the newer build installed beside
# it, hands the command off to it: the newer build then keeps the server's.
if [ "$(uname -m)" = "$machine" ]; then
    lib="$tmpdir/lib"
    mkdir -p "$lib/$ours/server" "$lib/$newer"
    cp "$KASBAH_BIN" "$lib/$ours/kasbah"
    cp "$ours_server" "$lib/$ours/server/kasbah-linux-$arch"
    cp "$variants/kasbah-$newer" "$lib/$newer/kasbah"
    installed_ensure() {
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" KASBAH_LIB_DIR="$lib" "$@" \
            "$lib/$ours/kasbah" __ensure-server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
    }
    installed_ensure env; rc=$?
    assert '[ "$rc" = 0 ] && [ "$(out)" = "kept=$newer" ]' \
        "hand-off: the newer build runs the command and keeps its own (exit $rc: $(out) $(err))"
    assert '[ "$(server_sha)" = "$newer_sha" ] && [ -z "$(uploads_left)" ]' "hand-off: nothing was replaced"
    installed_ensure env KASBAH_HANDOFF="$older"; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "already handed off from kasbah $older" <<<"$(err)"' \
        "hand-off: a second hop is refused, naming the first (exit $rc: $(err))"
    rm -rf "$lib/$newer"
    installed_ensure env; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "kasbah self-update v$newer" <<<"$(err)" && grep -qF "install-dev.sh" <<<"$(err)"' \
        "hand-off: a build not installed is named with both remedies (exit $rc: $(err))"
    assert '[ "$(server_sha)" = "$newer_sha" ] && [ -z "$(uploads_left)" ]' "hand-off refusals: nothing was replaced"
else
    assert 'false' "hand-off: the rig ($machine) is not this machine's architecture ($(uname -m)); the newer build cannot run here"
fi

# --- Case 4b: a release replaces a dev build of its major that outranks it ----
# The release variant runs here as an installed workstation beside its own
# server build (the rig is this machine's architecture).
plant "$variants/kasbah-$dev_above"
assert '[ "$(server_sha)" = "$dev_above_sha" ]' "release over dev: the dev build is planted"
if [ "$(uname -m)" = "$machine" ]; then
    rel_ws="$tmpdir/relws"
    mkdir -p "$rel_ws/$release/server"
    cp "$variants/kasbah-$release" "$rel_ws/$release/kasbah"
    cp "$variants/kasbah-$release" "$rel_ws/$release/server/kasbah-linux-$arch"
    env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" KASBAH_LIB_DIR="$rel_ws" \
        "$rel_ws/$release/kasbah" __ensure-server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; rc=$?
    assert '[ "$rc" = 0 ]' "release over dev: ensure succeeds (exit $rc: $(err))"
    assert '[ "$(out)" = "shipped=$dev_above->$release" ]' "release over dev: replaced, naming both builds (said '$(out)')"
    assert '[ "$(server_sha)" = "$release_sha" ] && [ -z "$(uploads_left)" ]' \
        "release over dev: the server holds the release, no upload left ($(bin_dir_list | tr '\n' ' '))"
    # The dev build under test ranks below that release: refused, and the
    # remedy is the release's tag.
    ensure; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "$release" <<<"$(err)" && grep -qF "$ours" <<<"$(err)"' \
        "dev under a release: refused, naming both builds (exit $rc: $(err))"
    assert '[ "$(server_sha)" = "$release_sha" ] && [ -z "$(uploads_left)" ]' "dev under a release: nothing was replaced"
else
    assert 'false' "release over dev: the rig ($machine) is not this machine's architecture ($(uname -m)); the release build cannot run here"
fi

# --- Case 4c: a dev build over a release asks first --------------------------
dev_ours=no
case $ours in *-*.*.*.*) [ "${ours%%-*}" != "$below" ] && dev_ours=yes ;; esac
if [ "$dev_ours" = no ]; then
    echo "  note: $ours is no dev build above $below; the dev-over-release case does not apply" >&2
elif [ "$(uname -m)" != "$machine" ]; then
    assert 'false' "dev over release: the rig ($machine) is not this machine's architecture ($(uname -m)); the release build cannot run here"
else
    plant "$variants/kasbah-$below"
    ensure; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF -- "--ship-dev or --keep-server" <<<"$(err)" && grep -qF "$below" <<<"$(err)"' \
        "dev over release, no terminal and no flag: fails naming both flags and the release (exit $rc: $(err))"
    assert '[ -z "$(out)" ] && [ "$(server_sha)" = "$below_sha" ] && [ -z "$(uploads_left)" ]' \
        "dev over release, unanswered: nothing was replaced ($(out); $(bin_dir_list | tr '\n' ' '))"
    ensure --ship-dev --keep-server; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "cannot both be given" <<<"$(err)" && [ "$(server_sha)" = "$below_sha" ]' \
        "dev over release: both flags are refused (exit $rc: $(err))"
    ensure --keep-server; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "keeps its kasbah $below" <<<"$(err)" && grep -qF "checkout" <<<"$(err)"' \
        "--keep-server from a checkout: keeps the release and says a checkout does not hand off (exit $rc: $(err))"
    assert '[ "$(server_sha)" = "$below_sha" ] && [ -z "$(uploads_left)" ]' "--keep-server: nothing was replaced"
    kept_lib="$tmpdir/keptlib"
    mkdir -p "$kept_lib/$ours/server" "$kept_lib/$below"
    cp "$KASBAH_BIN" "$kept_lib/$ours/kasbah"
    cp "$ours_server" "$kept_lib/$ours/server/kasbah-linux-$arch"
    cp "$variants/kasbah-$below" "$kept_lib/$below/kasbah"
    kept_ensure() {
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" KASBAH_LIB_DIR="$kept_lib" \
            "$kept_lib/$ours/kasbah" __ensure-server "$@" "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
    }
    kept_ensure --keep-server; rc=$?
    assert '[ "$rc" = 0 ] && [ "$(out)" = "kept=$below" ]' \
        "--keep-server, the release installed: the run hands off to it, without the flag it does not know (exit $rc: $(out) $(err))"
    assert '[ "$(server_sha)" = "$below_sha" ] && [ -z "$(uploads_left)" ]' "--keep-server hand-off: nothing was replaced"
    rm -rf "${kept_lib:?}/$below"
    kept_ensure --keep-server; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "kasbah self-update v$below" <<<"$(err)"' \
        "--keep-server, the release not installed: aborts naming self-update (exit $rc: $(err))"
    ensure --ship-dev; rc=$?
    assert '[ "$rc" = 0 ] && [ "$(out)" = "shipped=$below->$ours" ]' "--ship-dev: ships over the release (exit $rc: $(out) $(err))"
    assert 'grep -qxF "server kasbah $below → $ours" <<<"$(err)"' "--ship-dev: the change is one line (said '$(err)')"
    assert '[ "$(server_sha)" = "$ours_sha" ] && [ -z "$(uploads_left)" ]' "--ship-dev: the server holds the dev build"
fi

# --- Case 5: newer major → refusal, nothing replaced --------------------------
plant "$variants/kasbah-$next_major"
ensure; rc=$?
assert '[ "$rc" = 1 ]' "newer major: refused with exit 1 (exit $rc)"
assert 'grep -qF "$next_major" <<<"$(err)" && grep -qF "$ours" <<<"$(err)"' \
    "newer major: the refusal names both versions (said '$(err)')"
assert '[ -z "$(out)" ]' "newer major: no result line (got '$(out)')"
assert '[ "$(server_sha)" = "$major_sha" ]' "newer major: nothing was replaced"

# --- Case 6: a server build from another build is never shipped ---------------
# The workstation binary, installed-style, beside an older server binary.
ws="$tmpdir/ws/$ours"
mkdir -p "$ws/server"
cp "$KASBAH_BIN" "$ws/kasbah"
cp "$variants/kasbah-$older" "$ws/server/kasbah-linux-$arch"
rig_ssh "rm -f $bin" >/dev/null 2>&1
env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" KASBAH_LIB_DIR="$tmpdir/ws" \
    "$ws/kasbah" __ensure-server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; rc=$?
assert '[ "$rc" = 1 ]' "mismatch: refused (exit $rc: $(err))"
assert 'grep -qF "another build" <<<"$(err)"' "mismatch: says why (said '$(err)')"
assert '[ "$(server_sha)" = absent ] && [ -z "$(uploads_left)" ]' \
    "mismatch: no binary and no upload left on the server ($(bin_dir_list | tr '\n' ' '))"

# --- Case 7: stale uploads are swept, fresh ones left -------------------------
plant "$variants/kasbah-$older"
rig_ssh "touch $bin_dir/.kasbah.stale0 $bin_dir/.kasbah.fresh0 && touch -d '2 hours ago' $bin_dir/.kasbah.stale0" >/dev/null 2>&1
ensure; rc=$?
assert '[ "$rc" = 0 ] && [ "$(out)" = "shipped=$older->$ours" ]' "sweep: the ship itself succeeds (exit $rc: $(out) $(err))"
assert '[ "$(uploads_left)" = .kasbah.fresh0 ]' \
    "sweep: the two-hour-old upload is gone, the fresh one (perhaps another run's) kept (left: $(uploads_left | tr '\n' ' '))"
rig_ssh "rm -f $bin_dir/.kasbah.fresh0" >/dev/null 2>&1

# --- Case 8: two workstations racing end on the newer build -------------------
# The older variant runs here as a workstation too (the rig is this machine's
# architecture), beside its own server build and with our build installed
# beside it: when the newer build lands first, the older run hands off to it.
if [ "$(uname -m)" = "$machine" ]; then
    old_ws="$tmpdir/oldws"
    mkdir -p "$old_ws/$older/server" "$old_ws/$ours/server"
    cp "$variants/kasbah-$older" "$old_ws/$older/kasbah"
    cp "$variants/kasbah-$older" "$old_ws/$older/server/kasbah-linux-$arch"
    cp "$KASBAH_BIN" "$old_ws/$ours/kasbah"
    cp "$ours_server" "$old_ws/$ours/server/kasbah-linux-$arch"
    for round in 1 2 3; do
        if [ "$round" = 2 ]; then plant "$variants/kasbah-$older"; else rig_ssh "rm -f $bin" >/dev/null 2>&1; fi
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" KASBAH_LIB_DIR="$old_ws" \
            "$old_ws/$older/kasbah" __ensure-server "$RIG_TARGET" >"$tmpdir/race_b" 2>&1 </dev/null &
        pid_b=$!
        kasbah_cli __ensure-server "$RIG_TARGET" >"$tmpdir/race_a" 2>&1 </dev/null; rc_a=$?
        wait "$pid_b"; rc_b=$?
        a=$(tr -d '\r' <"$tmpdir/race_a"); b=$(tr -d '\r' <"$tmpdir/race_b")
        # The result line is the last; a change line may precede it.
        b_result=${b##*$'\n'}
        assert '[ "$rc_a" = 0 ] && [ "$rc_b" = 0 ]' "race $round: both runs succeed ($rc_a: $a / $rc_b: $b)"
        assert '[ "$(server_sha)" = "$ours_sha" ]' "race $round: the server ends on the newer build (A: $a, B: $b)"
        assert 'case $b_result in "shipped="*"->$older"|"shipped="*"->$ours"|"kept=$ours"|"kept=$older") true ;; *) false ;; esac' \
            "race $round: the older run reports what it did truthfully, handed off or not (said '$b')"
        assert '[ -z "$(uploads_left)" ]' "race $round: no upload left ($(uploads_left))"
    done
else
    assert 'false' "race: the rig ($machine) is not this machine's architecture ($(uname -m)); the older workstation cannot run here"
fi

# --- Case 9: a server binary that hangs is refused by the timeout -------------
plant "$variants/hang"
hang_sha=$(sha "$variants/hang")
started=$SECONDS
ensure; rc=$?
took=$((SECONDS - started))
assert '[ "$rc" = 1 ] && grep -qF "within 30 s" <<<"$(err)"' "hang: refused, naming the timeout (exit $rc: $(err))"
assert '[ "$took" -lt 60 ]' "hang: bounded (took ${took}s)"
assert '[ "$(server_sha)" = "$hang_sha" ]' "hang: nothing was replaced"

# --- Case 10: SIGINT mid-probe -------------------------------------------------
# The hanging binary holds the run in its probe, with the master up, well inside
# the 30 s bound; the signal goes to kasbah alone.
sigtmp="$tmpdir/sigtmp"
mkdir -p "$sigtmp"
env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" TMPDIR="$sigtmp" \
    "$KASBAH_BIN" __ensure-server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null &
pid=$!
for _ in $(seq 1 50); do
    compgen -G "$sigtmp/kasbah-ssh.*/m1" >/dev/null && break
    sleep 0.2
done
assert 'compgen -G "$sigtmp/kasbah-ssh.*/m1" >/dev/null' "SIGINT: the run opened its master (TMPDIR holds $(ls -A "$sigtmp"))"
sleep 2
kill -INT "$pid"
for _ in $(seq 1 75); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"
    assert 'false' "SIGINT: kasbah did not exit within 15 s"
fi
wait "$pid"; rc=$?
assert '[ "$rc" = 130 ]' "SIGINT: kasbah exits 130 (exit $rc: $(err))"
assert '[ -z "$(ls -A "$sigtmp")" ]' "SIGINT: the control directory is gone (left: $(ls -A "$sigtmp"))"
masters=$(pgrep -af -- "$sigtmp" || true)
assert '[ -z "$masters" ]' "SIGINT: no ssh master outlives the run (still running: $masters)"
assert '[ "$(server_sha)" = "$hang_sha" ]' "SIGINT: nothing was replaced"
rig_ssh "rm -f $bin" >/dev/null 2>&1

# --- Case 11: SIGINT mid-upload ------------------------------------------------
# A shim in front of the rig's ssh stalls the upload's stdin after 200 kB, so
# the run is caught with a partial `.kasbah.*` on the server.
slow="$tmpdir/slow"
mkdir -p "$slow"
printf '#!/usr/bin/env bash\ncase "${!#}" in\n    *"umask 002"*) touch %q; { head -c 200000; sleep 20; cat; } | %q "$@"; exit ;;\nesac\nexec %q "$@"\n' \
    "$tmpdir/uploading" "$RIG_SHIM_DIR/ssh" "$RIG_SHIM_DIR/ssh" >"$slow/ssh"
chmod 0755 "$slow/ssh"
env HOME="$RIG_HOME" PATH="$slow:$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" __ensure-server "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null &
pid=$!
for _ in $(seq 1 75); do
    [ -e "$tmpdir/uploading" ] && break
    sleep 0.2
done
sleep 2
partial=$(uploads_left)
kill -INT "$pid"
for _ in $(seq 1 75); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
done
kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid"; assert 'false' "upload SIGINT: kasbah did not exit within 15 s"; }
wait "$pid"; rc=$?
sleep 1
assert '[ -n "$partial" ]' "upload SIGINT: the run was caught mid-upload (bin dir: $(bin_dir_list | tr '\n' ' '))"
assert '[ "$rc" = 130 ]' "upload SIGINT: kasbah exits 130 (exit $rc: $(err))"
assert '[ -z "$(uploads_left)" ] && [ "$(server_sha)" = absent ]' \
    "upload SIGINT: the partial upload is removed and nothing installed (left: $(bin_dir_list | tr '\n' ' '))"

# --- Case 12: --apps-path, the bootstrap mode: no marker, an explicit dir ------
rig_ssh "sudo rm -rf $boot_dir && sudo mkdir -p $boot_dir && sudo chown $RIG_SSH_USER:$RIG_SSH_USER $boot_dir" >/dev/null 2>&1
ensure --apps-path="$boot_dir"; rc=$?
assert '[ "$rc" = 0 ] && [ "$(out)" = "shipped=none->$ours" ]' "bootstrap: ships into an unmarked apps path (exit $rc: $(out) $(err))"
boot=$(rig_ssh "sha256sum $boot_dir/.kasbah/bin/kasbah | cut -d' ' -f1; [ -e $boot_dir/.kasbah/server.json ] && echo marker || echo no-marker" 2>/dev/null | tr -d '\r')
assert '[ "$boot" = "$ours_sha
no-marker" ]' "bootstrap: the binary is there and no marker was invented (got '$boot')"
ensure --apps-path="$boot_dir/missing"; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "no directory" <<<"$(err)"' "bootstrap: a missing apps path is refused (exit $rc: $(err))"

# --- Case 13: a noexec apps path is named, on upload and on probe ---------------
if rig_ssh "sudo mkdir -p $noexec_mnt && sudo mount -t tmpfs -o noexec tmpfs $noexec_mnt && sudo chown $RIG_SSH_USER:$RIG_SSH_USER $noexec_mnt" >/dev/null 2>&1; then
    mounted=$noexec_mnt
    rig_ssh "sudo cp $pointer $pointer.server-binary-test" >/dev/null 2>&1 && pointer_saved=$pointer.server-binary-test
    rig_ssh "mkdir -p $noexec_mnt/.kasbah && echo '{}' > $noexec_mnt/.kasbah/server.json && echo $noexec_mnt | sudo tee $pointer >/dev/null" >/dev/null 2>&1
    ensure; rc=$?
    assert '[ "$rc" = 1 ]' "noexec upload: refused (exit $rc: $(err))"
    assert 'grep -qF "noexec" <<<"$(err)" && grep -qF "$noexec_mnt/.kasbah/bin" <<<"$(err)"' \
        "noexec upload: the refusal names the directory and the mount, not a bare 126 (said '$(err)')"
    assert '[ -z "$(uploads_left "$noexec_mnt/.kasbah/bin")" ]' "noexec upload: the upload was removed"

    rig_ssh "cat > $noexec_mnt/.kasbah/bin/kasbah && chmod 755 $noexec_mnt/.kasbah/bin/kasbah" <"$ours_server" >/dev/null 2>&1
    ensure; rc=$?
    assert '[ "$rc" = 1 ] && grep -qF "mounted noexec" <<<"$(err)"' "noexec probe: an existing binary there is named, not replaced (exit $rc: $(err))"
    left=$(rig_ssh "sha256sum $noexec_mnt/.kasbah/bin/kasbah | cut -d' ' -f1" 2>/dev/null | tr -d '\r')
    assert '[ "$left" = "$ours_sha" ] && [ -z "$(uploads_left "$noexec_mnt/.kasbah/bin")" ]' "noexec probe: nothing uploaded or replaced"
else
    assert 'false' "could not mount a noexec tmpfs on the rig to exercise the row"
fi

[ "$fail" = 0 ] && echo "server_binary_test: the same-build rule holds in every direction"
exit "$fail"
