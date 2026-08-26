#!/usr/bin/env bash
# Integration test: the rig's backup harness — two restic/rest-server endpoints
# over one snapshot store, one `--append-only` and one not.
#
# It proves the harness, not kasbah: nothing here runs a kasbah command. What it
# has to establish before 8.3 can rest on it:
#
#   * restic reaches the endpoint from a container the *rig's* daemon started,
#     which is where a VPS's backups run (08-keep.md, D1) and two network
#     namespaces from the server;
#   * the credential a VPS is given cannot delete — attempted for real, on a
#     real snapshot, refused with the server's own 403, with the snapshot still
#     listed afterwards;
#   * the operator's credential deletes that same snapshot, so the negative
#     above cannot be a restic that never tried;
#   * the store outlives `rig_clean`, which is what makes "restore onto a fresh
#     rig" (exit criterion 3) a thing a suite can execute.
#
# The repository is named per run and pruned empty at the end, because
# rest-server 0.14.0 answers 405 to a DELETE on a repository path — there is no
# way to remove one over the wire. The few-KB skeletons that leaves go with
# `tests/rig/rig.sh down`.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

repo_name="harness-$(date +%s)-$$"
vps_repo="${RIG_BACKUP_REPO_BASE:-}$repo_name/"
admin_repo="${RIG_BACKUP_ADMIN_REPO_BASE:-}$repo_name/"
src="/tmp/kasbah-backup-harness-$$"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

cleanup() {
    rig_ssh "rm -rf $src" >/dev/null 2>&1
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
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
if [ ! -f "$RIG_BACKUP_ENV" ]; then
    echo "error: no $RIG_BACKUP_ENV — the rig is up without its backup harness" >&2
    echo "       rig.sh writes it once both endpoints answer: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_backup_ready; then
    echo "error: the backup endpoints did not both answer from inside the rig" >&2
    echo "       $RIG_BACKUP_URL (append-only) and $RIG_BACKUP_ADMIN_URL (full access)" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi
# Pulled up front so a cold rig's download is not inside a timed assertion, and
# so "restic is not there" reads as an environment problem rather than a refusal.
if ! rig_ssh "docker pull $RIG_RESTIC_IMAGE" >/dev/null 2>&1; then
    echo "error: the rig could not pull $RIG_RESTIC_IMAGE" >&2
    exit 2
fi

# --- Something worth backing up -------------------------------------------------
if ! rig_ssh "mkdir -p $src && printf 'first\n' > $src/one.txt" >/dev/null 2>&1; then
    echo "error: could not create $src on the rig" >&2
    exit 2
fi

snapshot_ids() {
    local out
    out=$(rig_restic "$1" snapshots --json 2>/dev/null) || return 1
    jq -r '.[].short_id' <<<"$out" 2>/dev/null
}

# ==================================================================================
# The append-only endpoint accepts writes
# ==================================================================================
out=$(rig_restic "$vps_repo" init 2>&1); rc=$?
assert '[ "$rc" = "0" ]' \
    "restic init reaches the append-only endpoint from a nested container (exit $rc)
        output: $out"
if [ "$rc" != "0" ]; then
    echo "error: no repository — every assertion below would be vacuous" >&2
    exit 2
fi

out=$(RIG_RESTIC_MOUNT="$src" rig_restic "$vps_repo" backup /src 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "and takes a backup with the VPS credential (exit $rc)
        output: $out"
rig_ssh "printf 'second\n' > $src/two.txt" >/dev/null 2>&1
out=$(RIG_RESTIC_MOUNT="$src" rig_restic "$vps_repo" backup /src 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "and a second one (exit $rc)
        output: $out"

mapfile -t ids < <(snapshot_ids "$vps_repo")
assert '[ "${#ids[@]}" = "2" ]' \
    "two snapshots are listed back over the same credential (got ${#ids[@]}: ${ids[*]-})"
if [ "${#ids[@]}" != "2" ]; then
    echo "error: without two snapshots there is nothing to refuse a delete of" >&2
    exit 2
fi
victim="${ids[0]}"
survivor="${ids[1]}"

# ==================================================================================
# The VPS credential cannot delete — the property the whole feature rests on
# ==================================================================================
# A named snapshot, because every "delete everything" spelling of forget exits
# non-zero on restic's own argument check before it reaches the server, which
# would read as a refusal: `--keep-last 0` gives "no policy was specified",
# adding `--unsafe-allow-remove-all` gives "not allowed unless a snapshot filter
# option is specified" (restic 0.18.0, against a repository with snapshots in
# it). Three independent things are asserted, because any one of them alone
# has a way of passing for the wrong reason: a non-zero status, the server's own
# 403 in the output, and the snapshot still being there afterwards.
out=$(rig_restic "$vps_repo" forget "$victim" --prune 2>&1); rc=$?
assert '[ "$rc" != "0" ]' \
    "forget $victim over the append-only endpoint fails (exit $rc)
        output: $out"
assert 'grep -qF "403 Forbidden" <<<"$out"' \
    "and fails because the server refused it, not for a reason of restic's own (output: $out)"

mapfile -t after_refusal < <(snapshot_ids "$vps_repo")
assert '[ "${#after_refusal[@]}" = "2" ]' \
    "with both snapshots still in the repository (got ${#after_refusal[@]}: ${after_refusal[*]-})"
assert '[[ " ${after_refusal[*]-} " == *" $victim "* ]]' \
    "$victim among them (got: ${after_refusal[*]-})"

# ==================================================================================
# The operator credential can — same repository, same snapshot
# ==================================================================================
# This is what stops the refusal above being "restic could not delete anything
# here". Only the credential and the endpoint differ.
out=$(rig_restic "$admin_repo" forget "$victim" --prune 2>&1); rc=$?
assert '[ "$rc" = "0" ]' \
    "forget $victim over the full-access endpoint succeeds (exit $rc)
        output: $out"

mapfile -t after_prune < <(snapshot_ids "$admin_repo")
assert '[ "${#after_prune[@]}" = "1" ]' \
    "leaving one snapshot (got ${#after_prune[@]}: ${after_prune[*]-})"
assert '[ "${after_prune[0]-}" = "$survivor" ]' \
    "and it is $survivor, not $victim (got: ${after_prune[0]-})"

# The append-only endpoint reads the same store, so the deletion is the store's
# and not one endpoint's view of it.
mapfile -t seen_by_vps < <(snapshot_ids "$vps_repo")
assert '[ "${seen_by_vps[*]-}" = "$survivor" ]' \
    "and the append-only endpoint serves the same one repository (got: ${seen_by_vps[*]-})"

# ==================================================================================
# The store is outside the rig
# ==================================================================================
# rig_clean tears down every compose project the *nested* daemon knows and wipes
# /apps. The snapshot store is a volume on the workstation's Docker, so it is not
# among them — which is the whole basis of restoring onto a "fresh" rig.
#
# The canary is what stops this reading as proof when nothing was ever at risk:
# this suite puts nothing under /apps of its own, so without something for
# rig_clean to destroy, "the snapshot is still there" would hold on a rig_clean
# that did nothing at all.
canary=$(rig_ssh "sudo mkdir -p /apps && sudo touch /apps/backup-harness-canary && test -e /apps/backup-harness-canary && echo PLACED" 2>/dev/null)
if [ "${canary//$'\r'/}" != "PLACED" ]; then
    echo "error: could not place the canary under /apps on the rig" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean failed mid-suite" >&2
    exit 2
fi
rig_state=$(rig_ssh "test -e /apps/backup-harness-canary && echo CANARY-PRESENT || echo CANARY-GONE" 2>/dev/null)
rig_state=${rig_state//$'\r'/}
assert '[ "$rig_state" = "CANARY-GONE" ]' \
    "rig_clean really destroys what is in its reach (canary: $rig_state)"

mapfile -t after_clean < <(snapshot_ids "$vps_repo")
assert '[ "${after_clean[*]-}" = "$survivor" ]' \
    "and the snapshot survived it (got: ${after_clean[*]-})"

# --- Leave the store as it was found, but only on success ---------------------------
if [ "$fail" -eq 0 ]; then
    rig_restic "$admin_repo" forget "$survivor" --prune >/dev/null 2>&1
fi

exit "$fail"
