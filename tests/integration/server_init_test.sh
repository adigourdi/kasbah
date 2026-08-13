#!/usr/bin/env bash
# Integration test: `hosting server init` against the live rig.
#
# What the hermetic suite cannot show: that the layout really lands on a VPS,
# that acme.json is a *file* on a real filesystem, that the marker carries this
# host's own resources, and that a second run changes nothing. Everything is
# read back off the rig — hosting's own summary is not evidence.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which establishes a known starting state rather than
# repairing a broken one.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
data=/apps/data
acme="$data/traefik/letsencrypt/acme.json"
marker="$apps/.hosting/server.json"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
# One case moves a required binary out of the way to prove the preflight
# diagnoses it. If this suite dies while it is hidden the rig would stay short a
# prerequisite for every later run, so the restore is a trap, not a line at the
# end of the case (the same idiom tests/integration/ssh_test.sh uses to hide the
# rig marker).
hidden_bin=""
# Likewise the root-owned directories one group of cases aims at: they live
# outside the apps path, so rig_clean would not take them away. One of them is a
# mount, which has to come down before its directory can.
foreign=""
mounted=""
cleanup() {
    [ -z "$hidden_bin" ] || rig_ssh "sudo mv -f $hidden_bin.hidden $hidden_bin" >/dev/null 2>&1
    [ -z "$mounted" ] || rig_ssh "sudo umount $mounted" >/dev/null 2>&1
    [ -z "$foreign" ] || rig_ssh "sudo rm -rf $foreign" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions ------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh" >&2
    echo "       is the rig up? tests/rig/rig.sh up" >&2
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

init() { hosting_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
init_err() { cat "$tmpdir/err"; }

# Names, types, modes, ownership and contents of everything under the apps path,
# in one digest. Anything init writes differently on a second run moves it.
apps_checksum() {
    rig_ssh "{ find $apps -printf '%y %m %u:%g %p\n' | sort; find $apps -type f -exec sha256sum {} + | sort; } | sha256sum" 2>/dev/null
}
apps_state() { rig_ssh "[ -e $apps ] && echo present || echo absent" 2>/dev/null; }

# --- A refusal must reach the server not at all -------------------------------
# Both cases run against a rig with no /apps, so "nothing was created" is
# checkable rather than assumed.
init --with-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]'                       "--with-mail fails rather than skipping mail silently (exit $rc)"
assert 'grep -qF "Phase 7" "$tmpdir/err"'       "--with-mail names the phase that builds it (said '$(init_err)')"
assert 'grep -qF -- "--no-mail" "$tmpdir/err"'  "--with-mail says how to proceed today"
assert '[ "$(apps_state)" = "absent" ]'         "a refused --with-mail run created nothing on the rig"

init; rc=$?
assert '[ "$rc" != "0" ]'                                  "no flags and no terminal is a hard fail (exit $rc)"
assert 'grep -qF -- "--with-mail or --no-mail" "$tmpdir/err"' \
    "the no-TTY failure names the flag that would answer it (said '$(init_err)')"
assert '[ "$(apps_state)" = "absent" ]'                    "an unanswered prompt created nothing on the rig"

# --- A reachable target that is short a prerequisite --------------------------
# Still on a rig with no /apps, so "nothing was created" is the same checkable
# fact as above. A version of this case that ran after the layout existed could
# not fail: the layout is idempotent, so re-running it changes no checksum, and
# "no remote step ran" cannot be read off a step that ran and succeeded.
#
# gzip is moved aside rather than uninstalled, and put back by the EXIT trap
# whatever happens. It is the one required binary nothing else in the rig suites
# uses, so the window cannot flake a neighbour.
hidden_bin=/usr/bin/gzip
if rig_ssh "sudo mv $hidden_bin $hidden_bin.hidden" >/dev/null 2>&1; then
    init --no-mail --no-backup; rc=$?
    rig_ssh "sudo mv -f $hidden_bin.hidden $hidden_bin" >/dev/null 2>&1 && hidden_bin=""

    assert '[ "$rc" != "0" ]' "a host missing gzip fails preflight (exit $rc)"
    assert 'grep -qF "gzip is missing" "$tmpdir/err"' \
        "the failure names the row and the binary (said '$(init_err)')"
    assert 'grep -qF "prerequisites" "$tmpdir/err"' \
        "the failure says it is a prerequisite, not a bug in hosting"
    assert '[ "$(apps_state)" = "absent" ]' \
        "preflight fails before anything is created — the apps path is still not there"
    assert '[ -z "$hidden_bin" ]' "gzip was put back on the rig"
    assert '[ "$(rig_ssh "command -v gzip" 2>/dev/null)" = "/usr/bin/gzip" ]' \
        "gzip is where the rig found it"
else
    hidden_bin=""
    assert 'false' "could not move /usr/bin/gzip aside to exercise the preflight"
fi

# --- The golden path ----------------------------------------------------------
init --no-mail --no-backup; rc=$?
if [ "$rc" != "0" ]; then
    echo "  FAIL: server init succeeded on a cleaned rig (exit $rc)" >&2
    sed 's/^/        | /' "$tmpdir/err" >&2
    fail=1
fi

# One session for every fact about the result. The control at the end is the
# point of the acme rows: a directory answers -e and -r exactly like a file
# does (docs/phases/01-rig.md), so the assertion has to be shown capable of
# telling them apart before it is worth anything.
probe_out=$(rig_ssh "bash -s '$apps' '$data'" 2>"$tmpdir/probe.err" <<'REMOTE'
set -uo pipefail
apps=$1
data=$2
acme=$data/traefik/letsencrypt/acme.json
marker=$apps/.hosting/server.json

kv() { printf '%s=%s\n' "$1" "$2"; }
isdir() { if [ -d "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }

isdir "$apps"                     d_apps
isdir "$apps/.hosting"            d_hosting
isdir "$apps/backups"             d_backups
isdir "$apps/traefik"             d_traefik
isdir "$apps/traefik/dynamic"     d_dynamic
isdir "$data"                     d_data
isdir "$data/traefik/letsencrypt" d_letsencrypt

kv apps_owner "$(stat -c '%U:%G' "$apps" 2>/dev/null)"

if [ -f "$acme" ]; then kv acme_isfile yes; else kv acme_isfile no; fi
if [ -d "$acme" ]; then kv acme_isdir yes; else kv acme_isdir no; fi
if [ -r "$acme" ]; then kv acme_isreadable yes; else kv acme_isreadable no; fi
kv acme_mode "$(stat -c '%a' "$acme" 2>/dev/null)"
kv acme_owner "$(stat -c '%U:%G' "$acme" 2>/dev/null)"

if [ -f "$marker" ]; then kv marker_isfile yes; else kv marker_isfile no; fi

# The control: a directory at a path named acme.json, which is exactly what
# Docker leaves behind when it materialises a missing bind-mount source.
control=/tmp/hosting-acme-control/acme.json
rm -rf /tmp/hosting-acme-control
mkdir -p "$control"
if [ -f "$control" ]; then kv control_isfile yes; else kv control_isfile no; fi
if [ -r "$control" ]; then kv control_isreadable yes; else kv control_isreadable no; fi
rm -rf /tmp/hosting-acme-control

kv nproc "$(nproc)"
memtotal_kb=""
while read -r field value _; do
    if [ "$field" = "MemTotal:" ]; then memtotal_kb=$value; break; fi
done < /proc/meminfo
kv memtotal_kb "$memtotal_kb"
exit 0
REMOTE
); probe_rc=$?

if [ "$probe_rc" -ne 0 ] || [ -z "$probe_out" ]; then
    echo "error: could not read the result back off the rig (ssh exit $probe_rc)" >&2
    sed 's/^/       | /' "$tmpdir/probe.err" >&2
    exit 2
fi

# The probe output is a protocol: parsed once and checked complete before any
# assertion reads it, so a fact that went missing cannot produce a green
# assertion (docs/phases/01-rig.md, from 1.3).
declare -A fact=()
while IFS= read -r line; do
    case $line in *=*) fact[${line%%=*}]=${line#*=} ;; esac
done <<<"$probe_out"
missing=()
for key in d_apps d_hosting d_backups d_traefik d_dynamic d_data d_letsencrypt \
           apps_owner acme_isfile acme_isdir acme_isreadable acme_mode acme_owner \
           marker_isfile control_isfile control_isreadable nproc memtotal_kb; do
    [ -n "${fact[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$probe_out" >&2
    exit 2
fi

# --- The layout ---------------------------------------------------------------
for d in d_apps:"$apps" d_hosting:"$apps/.hosting" d_backups:"$apps/backups" \
         d_traefik:"$apps/traefik" d_dynamic:"$apps/traefik/dynamic" \
         d_data:"$data" d_letsencrypt:"$data/traefik/letsencrypt"; do
    key="${d%%:*}"; path="${d#*:}"
    got="${fact[$key]}"
    assert '[ "$got" = "yes" ]' "$path is a directory on the rig (got '$got')"
done
assert '[ "${fact[apps_owner]}" = "$RIG_SSH_USER:$RIG_SSH_USER" ]' \
    "$apps is handed to the deploy user, so nothing below it needs sudo (got '${fact[apps_owner]}')"

# --- acme.json is a file, and the test can tell -------------------------------
assert '[ "${fact[acme_isfile]}" = "yes" ]'  "$acme is a regular file (got '${fact[acme_isfile]}')"
assert '[ "${fact[acme_isdir]}" = "no" ]'    "$acme is not a directory (got '${fact[acme_isdir]}')"
assert '[ "${fact[acme_mode]}" = "600" ]'    "$acme is mode 600 (got '${fact[acme_mode]}')"
assert '[ "${fact[acme_owner]}" = "$RIG_SSH_USER:$RIG_SSH_USER" ]' \
    "$acme belongs to the deploy user (got '${fact[acme_owner]}')"
assert '[ "${fact[control_isfile]}" = "no" ]' \
    "the -f test says no to a directory named acme.json — without this the row above proves nothing"
assert '[ "${fact[control_isreadable]}" = "yes" ]' \
    "and -r says yes to that same directory, which is why -f is the guard and -e/-r are not"

# --- The marker ---------------------------------------------------------------
assert '[ "${fact[marker_isfile]}" = "yes" ]' "$marker exists as a file"
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
assert 'jq -e . >/dev/null 2>&1 <<<"$marker_json"' "the marker parses as JSON (got '$marker_json')"
if jq -e . >/dev/null 2>&1 <<<"$marker_json"; then
    for key in hosting_version apps_path data_path cpu_limit mem_limit backup; do
        assert 'jq -e --arg k "$key" "has(\$k)" >/dev/null <<<"$marker_json"' \
            "the marker carries $key (got '$marker_json')"
    done
    version="$(cat "$repo_dir/VERSION")"
    assert '[ "$(jq -r .hosting_version <<<"$marker_json")" = "$version" ]' \
        "the marker records this checkout's version (wanted $version, got '$(jq -r .hosting_version <<<"$marker_json")')"
    assert '[ "$(jq -r .apps_path <<<"$marker_json")" = "$apps" ]'  "the marker records the apps path"
    assert '[ "$(jq -r .data_path <<<"$marker_json")" = "$data" ]'  "the marker records the data path"
    assert '[ "$(jq -r .backup.enabled <<<"$marker_json")" = "false" ]' \
        "backup is off — nothing was installed for it"

    # Plausible for *this* host: the rig reports the workstation's own cores and
    # RAM, so a hard-coded number would pass here and fail on another machine.
    # Both bounds and the exact rule are checked, in integer arithmetic, the way
    # the library computes them.
    cpu="$(jq -r .cpu_limit <<<"$marker_json")"
    mem="$(jq -r .mem_limit <<<"$marker_json")"
    nproc="${fact[nproc]}"
    memkb="${fact[memtotal_kb]}"
    assert '[[ "$cpu" =~ ^[0-9]+\.[0-9]$ ]]' "cpu_limit is one decimal place (got '$cpu')"
    assert '[[ "$mem" =~ ^[0-9]+g$ ]]'       "mem_limit is whole GiB with a unit (got '$mem')"
    if [[ "$cpu" =~ ^[0-9]+\.[0-9]$ ]] && [[ "$mem" =~ ^[0-9]+g$ ]]; then
        cpu_tenths=$((10#${cpu%.*} * 10 + 10#${cpu#*.}))
        mem_gib=$((10#${mem%g}))
        host_gib=$((memkb / 1048576))
        assert '[ "$cpu_tenths" -lt $((nproc * 10)) ] && [ "$cpu_tenths" -ge $((nproc * 8)) ]' \
            "cpu_limit is a ceiling below the rig's $nproc cores, not far below (got $cpu)"
        assert '[ "$mem_gib" -lt "$host_gib" ] && [ "$mem_gib" -ge $((host_gib * 8 / 10)) ]' \
            "mem_limit is a ceiling below the rig's ${host_gib}GiB, not far below (got $mem)"
        assert '[ "$cpu_tenths" = $((nproc * 9)) ]' \
            "cpu_limit is exactly 90% of $nproc cores (wanted $((nproc * 9)) tenths, got $cpu_tenths)"
        assert '[ "$mem_gib" = $((memkb * 9 / 10485760)) ]' \
            "mem_limit is exactly 90% of ${memkb}kB floored to GiB (wanted $((memkb * 9 / 10485760)), got $mem_gib)"
    fi
fi

# --- A second run changes nothing ---------------------------------------------
before=$(apps_checksum)
assert '[ -n "$before" ]' "the apps tree hashes to something (got '$before')"

# The digest is only evidence if it can move. Both probes are undone, and the
# tree is confirmed back at the baseline afterwards.
rig_ssh "touch $apps/traefik/dynamic/.checksum-probe" >/dev/null 2>&1
assert '[ "$(apps_checksum)" != "$before" ]' "the digest notices a new file"
rig_ssh "rm -f $apps/traefik/dynamic/.checksum-probe" >/dev/null 2>&1
rig_ssh "chmod 644 $acme" >/dev/null 2>&1
assert '[ "$(apps_checksum)" != "$before" ]' "the digest notices a mode change"
rig_ssh "chmod 600 $acme" >/dev/null 2>&1
assert '[ "$(apps_checksum)" = "$before" ]'  "and both probes were undone"

init --no-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "a second server init succeeds (exit $rc: $(init_err))"
after=$(apps_checksum)
assert '[ "$after" = "$before" ]' \
    "re-running server init changes nothing under $apps
        before: $before
        after:  $after"

# --- The acme.json trap, and the marker written last --------------------------
# Docker's bind-mount behaviour reproduced by hand: a directory where the file
# belongs. init must refuse — and refuse before writing the marker, which is the
# signal that a server is ready.
rig_ssh "rm -f $acme $marker && mkdir -p $acme" >/dev/null 2>&1
init --no-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "init refuses when a directory sits where acme.json belongs (exit $rc)"
assert 'grep -qF "not a regular file" "$tmpdir/err"' \
    "the refusal names the trap (said '$(init_err)')"
marker_after=$(rig_ssh "[ -e $marker ] && echo present || echo absent" 2>/dev/null)
assert '[ "$marker_after" = "absent" ]' \
    "no marker is written by a run that failed — its presence means init completed (got '$marker_after')"

rig_ssh "rmdir $acme" >/dev/null 2>&1
init --no-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "init repairs the tree once the directory is gone (exit $rc: $(init_err))"
assert '[ "$(apps_checksum)" = "$before" ]' "and the repaired tree is the same tree, byte for byte"

# --- A marker this hosting did not write in full ------------------------------
# Phase 8 will put backup.repo_base in the marker, and a newer hosting may put
# keys this one has never heard of. Init owns five keys; a re-run must leave the
# rest of the file exactly as it found it.
if [ -n "$marker_json" ]; then
    seeded=$(jq '.backup = {enabled: true, repo_base: "s3:https://example/hosting-backups"}
                 | .future_key = {kept: [1, 2]}' <<<"$marker_json")
    printf '%s\n' "$seeded" | rig_ssh "cat > $marker" >/dev/null 2>&1

    init --no-mail --no-backup; rc=$?
    kept=$(rig_ssh "cat $marker" 2>/dev/null)
    assert '[ "$rc" = "0" ]' "init runs against a marker carrying keys it does not own (exit $rc: $(init_err))"
    assert '[ "$(jq -r .backup.repo_base <<<"$kept")" = "s3:https://example/hosting-backups" ]' \
        "backup.repo_base survived the re-run (marker is now '$kept')"
    assert '[ "$(jq -r .backup.enabled <<<"$kept")" = "true" ]' \
        "an enabled backup is not switched off by a plain re-run"
    assert '[ "$(jq -c .future_key <<<"$kept")" = "{\"kept\":[1,2]}" ]' \
        "a key from a newer hosting survived the re-run"
    assert '[ "$(jq -r .cpu_limit <<<"$kept")" = "${cpu:-unset}" ]' \
        "and the keys init does own are still current"

    # docs/server-setup.md's compatibility rule: an older tool refuses a newer
    # major rather than writing fields it does not understand.
    newer=$(jq '.hosting_version = "99.0.0"' <<<"$marker_json")
    printf '%s\n' "$newer" | rig_ssh "cat > $marker" >/dev/null 2>&1
    init --no-mail --no-backup; rc=$?
    still=$(rig_ssh "cat $marker" 2>/dev/null)
    assert '[ "$rc" != "0" ]' "init refuses a marker from a newer major (exit $rc)"
    assert 'grep -qF "99.0.0" "$tmpdir/err"' "the refusal names the version it found (said '$(init_err)')"
    assert '[ "$(jq -r .hosting_version <<<"$still")" = "99.0.0" ]' \
        "the refused run did not overwrite the marker (got '$still')"

    rig_ssh "rm -f $marker" >/dev/null 2>&1
    init --no-mail --no-backup; rc=$?
    assert '[ "$rc" = "0" ]' "a fresh marker is written once the old one is gone (exit $rc: $(init_err))"
    assert '[ "$(apps_checksum)" = "$before" ]' "and the tree is back at the baseline"
fi

# --- Paths that are not hosting's to take -------------------------------------
# Everything below lives outside the apps path, so rig_clean would not remove
# it; the EXIT trap does.
foreign=/srv/hosting-unit-b
owned="$foreign/owned"
# The dangerous shape, not merely the awkward one: root-owned and *writable* by
# the deploy user. A mode that kept hosting out would let a plain permission
# error stand in for the ownership rule, and the rule is the thing under test.
rig_ssh "sudo mkdir -p $owned $foreign/ro && sudo sh -c 'echo secret > $owned/PRECIOUS' \
         && sudo chmod 777 $owned \
         && sudo ln -sfn /nonexistent $foreign/dangling && sudo chmod 555 $foreign/ro" >/dev/null 2>&1
setup=$(rig_ssh "[ -f $owned/PRECIOUS ] && [ -w $owned ] && echo file-ok; [ -L $foreign/dangling ] && [ ! -e $foreign/dangling ] && echo dangling-ok; [ -d $foreign/ro ] && ! [ -w $foreign/ro ] && echo ro-ok" 2>/dev/null)
assert 'grep -qF "file-ok" <<<"$setup"'     "a root-owned directory the deploy user can write exists to aim at (got '$setup')"
assert 'grep -qF "dangling-ok" <<<"$setup"' "a dangling symlink exists to aim at (got '$setup')"
assert 'grep -qF "ro-ok" <<<"$setup"'       "an unwritable parent exists to aim at (got '$setup')"

# The state hosting must never repair: a directory that exists, holds somebody
# else's files, and is not the deploy user's. Chowning it would hand a live
# /var/www to the deploy user and leave its contents in mixed ownership.
init --apps-path="$owned" --no-mail --no-backup; rc=$?
after_owned=$(rig_ssh "stat -c '%U:%G %a' $owned; stat -c '%U:%G' $owned/PRECIOUS; ls -a $owned | tr '\n' ' '" 2>&1)
assert '[ "$rc" != "0" ]' "init refuses an apps path owned by somebody else (exit $rc)"
assert 'grep -qF "belongs to root:root" "$tmpdir/err"' \
    "the refusal names the owner (said '$(init_err)')"
assert 'grep -qF "sudo chown $RIG_SSH_USER:$RIG_SSH_USER $owned" "$tmpdir/err"' \
    "the refusal names the one command that would hand it over"
assert 'grep -qF "root:root" <<<"$after_owned"' \
    "the directory still belongs to root — it was not seized (got '$after_owned')"
assert '! grep -qF "$RIG_SSH_USER:$RIG_SSH_USER" <<<"$after_owned"' \
    "nothing in it changed hands (got '$after_owned')"
assert '! grep -qF ".hosting" <<<"$after_owned"' \
    "and nothing was created inside it (got '$after_owned')"

# The operator does what the message says, and then it works.
rig_ssh "sudo chown $RIG_SSH_USER:$RIG_SSH_USER $owned" >/dev/null 2>&1
init --apps-path="$owned" --no-mail --no-backup; rc=$?
handed=$(rig_ssh "[ -f $owned/.hosting/server.json ] && echo marker-ok; stat -c '%U:%G' $owned/PRECIOUS" 2>&1)
assert '[ "$rc" = "0" ]' "init uses the path once it has been handed over (exit $rc: $(init_err))"
assert 'grep -qF "marker-ok" <<<"$handed"' "the marker lands there (got '$handed')"
assert 'grep -qF "root:root" <<<"$handed"' \
    "and the pre-existing file is still root's — hosting chowns nothing recursively (got '$handed')"

# A symlink to nothing answers -e with "no" and then fails `mkdir -p` with
# "File exists", so it is diagnosed rather than walked into.
init --apps-path="$foreign/dangling" --no-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "init refuses a dangling symlink at the apps path (exit $rc)"
assert 'grep -qF "symlink to nothing" "$tmpdir/err"' \
    "the refusal says what it found (said '$(init_err)')"
assert '! grep -qF "remote:" "$tmpdir/err"' \
    "and it never reached mkdir on the far side, whose own diagnosis is useless here"

# A data path outside the apps path has a parent of its own, and the deploy user
# may not be able to write in it. That has to be a preflight verdict: reaching
# the layout means a half-built tree and a diagnosis three steps late.
init --data-path="$foreign/ro/data" --no-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "init refuses a data path it cannot create (exit $rc)"
assert 'grep -qF "$foreign/ro is not writable" "$tmpdir/err"' \
    "the refusal names the parent that stopped it (said '$(init_err)')"
assert 'grep -qF "does not meet the prerequisites" "$tmpdir/err"' \
    "it is a preflight verdict, not a failure part-way through the layout"
assert '! grep -qF "remote:" "$tmpdir/err"' \
    "no remote step ran — the layout was never started"
assert '[ "$(apps_checksum)" = "$before" ]' "and $apps is untouched by the refused run"

# --- An apps path the deploy user cannot see ----------------------------------
# The one that got through two rounds of review. A root-owned directory with
# content, behind a parent the deploy user cannot traverse: `-e` answers false
# for the same reason `-e` answers false for a path that is not there, so the
# state reads as `absent`, elevation fires, and the chown — which runs as root,
# and root can see it perfectly well — takes the directory. The observed result
# was `victim/` owned by the deploy user with its contents still root's: exactly
# the mixed ownership the refusal exists to prevent, and invisible in the output
# because the run then failed for an unrelated reason.
locked="$foreign/locked"
victim="$locked/victim"
rig_ssh "sudo mkdir -p $victim && sudo sh -c 'echo secret > $victim/PRECIOUS' && sudo chmod 700 $locked" >/dev/null 2>&1
wall=$(rig_ssh "[ -e $victim ] && echo visible || echo not-visible; [ -x $locked ] && echo traversable || echo walled" 2>/dev/null)
assert 'grep -qF "not-visible" <<<"$wall"' \
    "the deploy user cannot see the directory (got '$wall') — else this case proves nothing"
assert 'grep -qF "walled" <<<"$wall"' "because its parent is not traversable (got '$wall')"

init --apps-path="$victim" --no-mail --no-backup; rc=$?
walled_after=$(rig_ssh "sudo stat -c '%U:%G' $victim; sudo stat -c '%U:%G' $victim/PRECIOUS; sudo ls -a $victim | tr '\n' ' '" 2>&1)
assert '[ "$rc" != "0" ]' "init refuses an apps path only root can see (exit $rc)"
assert 'grep -qF "belongs to root:root" "$tmpdir/err"' \
    "the refusal names the owner root reported, not the one the deploy user could not read (said '$(init_err)')"
assert 'grep -qF "cannot see it" "$tmpdir/err"' "and says why it could not be seen"
assert '[ "$(head -1 <<<"$walled_after")" = "root:root" ]' \
    "the directory still belongs to root — it did not change hands (got '$walled_after')"
assert '! grep -qF "$RIG_SSH_USER:$RIG_SSH_USER" <<<"$walled_after"' \
    "nothing under it changed hands either (got '$walled_after')"
assert '! grep -qF ".hosting" <<<"$walled_after"' "and nothing was created inside it (got '$walled_after')"

# The same wall, with nothing behind it: hosting cannot tell whether the path
# exists, and a path the deploy user cannot enter is no use even once created.
init --apps-path="$locked/newone" --no-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "init refuses to create below a wall it cannot cross (exit $rc)"
assert 'grep -qF "$locked is not traversable" "$tmpdir/err"' \
    "the refusal names the directory that stopped it (said '$(init_err)')"
assert '[ "$(rig_ssh "sudo ls $locked | tr \\\\n \\ " 2>/dev/null)" = "victim " ]' \
    "and created nothing behind it"

# --- An apps path on a read-only filesystem -----------------------------------
# Correctly owned, correct mode, and still not writable. `chmod u+rwx` is the
# wrong advice, and the errno is the only thing that distinguishes the two.
romnt="$foreign/romnt"
if rig_ssh "sudo mkdir -p $romnt && sudo mount -t tmpfs tmpfs $romnt && sudo chown $RIG_SSH_USER:$RIG_SSH_USER $romnt && sudo mount -o remount,ro $romnt" >/dev/null 2>&1; then
    mounted="$romnt"
    ro_state=$(rig_ssh "stat -c '%U:%G' $romnt; touch $romnt/probe 2>&1" 2>&1)
    assert 'grep -qF "$RIG_SSH_USER:$RIG_SSH_USER" <<<"$ro_state"' \
        "the read-only mount belongs to the deploy user (got '$ro_state')"
    assert 'grep -qF "Read-only file system" <<<"$ro_state"' \
        "and is genuinely unwritable (got '$ro_state')"

    init --apps-path="$romnt" --no-mail --no-backup; rc=$?
    assert '[ "$rc" != "0" ]' "init refuses a read-only apps path (exit $rc)"
    assert 'grep -qF "read-only filesystem" "$tmpdir/err"' \
        "the refusal names the real cause (said '$(init_err)')"
    assert '! grep -qF "chmod u+rwx" "$tmpdir/err"' \
        "and does not prescribe a chmod that cannot work"
    rig_ssh "sudo umount $romnt" >/dev/null 2>&1 && mounted=""
else
    assert 'false' "could not mount a read-only filesystem on the rig to exercise the row"
fi

rig_ssh "sudo rm -rf $foreign" >/dev/null 2>&1 && foreign=""

# --- --data-path equal to --apps-path -----------------------------------------
# Odd, not wrong. It used to be refused with a message that contradicted itself
# ("the data path /apps cannot be created: / is not writable … It sits outside
# /apps"), because "below" was tested strictly.
if rig_clean; then
    init --apps-path="$apps" --data-path="$apps" --no-mail --no-backup; rc=$?
    same_path=$(rig_ssh "find $apps | sort | tr '\n' ' '" 2>/dev/null)
    assert '[ "$rc" = "0" ]' "--data-path equal to --apps-path is accepted (exit $rc: $(init_err))"
    assert 'grep -qF "$apps/traefik/letsencrypt/acme.json" <<<"$same_path"' \
        "acme.json lands below the data path, wherever that is (got '$same_path')"
    assert '[ "$(jq -r .data_path <<<"$(rig_ssh "cat $marker" 2>/dev/null)")" = "$apps" ]' \
        "and the marker records it"
else
    assert 'false' "could not clean the rig before the equal-paths case"
fi

# --- Leave the rig as it was found, but only on success -----------------------
if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi

exit "$fail"
