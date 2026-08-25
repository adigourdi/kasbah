#!/usr/bin/env bash
# Integration test: `kasbah server prune` against the live rig, over real images
# in a real daemon.
#
# What only the rig can show, and what the hermetic suite therefore cannot:
#   * `docker image rm` really removing the tag, and really removing the *image*
#     when that tag was its only name — a stub ssh agrees with any spelling;
#   * an image a running container holds surviving, in a daemon that would have
#     refused to delete it;
#   * a project directory whose versions.log this ssh user cannot read, which is
#     a filesystem state and not a protocol string;
#   * every other tag on the host — the rig's stock image cache included — still
#     being there afterwards.
#
# The image ages are real too. `SOURCE_DATE_EPOCH` makes BuildKit stamp the
# image config with a date of the suite's choosing, so an image genuinely built
# a minute ago carries a `Created` from 2024 — which is the honest number prune
# reads, and the only way to put a fresh daemon on both sides of a three-month
# cutoff.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which leaves images alone, so every image and tag it
# creates is removed by name here — `tests/integration/ship_test.sh` asserts a
# freshly loaded image carries exactly one tag, and a stray tag from this suite
# would fail it.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps

# Every tag this suite creates, in one list, so the cleanup is an enumeration
# and never a sweep.
tags=(ripe-web:current ripe-web:3.0.0 ripe-web:0.3.0 ripe-web:0.2.0 ripe-web:0.1.0
      ripe-web:0.5.0 ripe-web:0.4.0
      held-web:current held-web:2.0.0 held-web:0.2.0 held-web:0.1.0
      sealed-web:current sealed-web:2.0.0 sealed-web:0.1.0)
container=kasbah-prune-held

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    rig_ssh "docker rm -f $container >/dev/null 2>&1; docker image rm -f ${tags[*]} >/dev/null 2>&1; rm -rf /tmp/kasbah-prune-build; true" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions ----------------------------------------------------------------
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
# A previous interrupted run's leavings, before anything is measured.
rig_ssh "docker rm -f $container >/dev/null 2>&1; docker image rm -f ${tags[*]} >/dev/null 2>&1; true" >/dev/null 2>&1

prune()   { kasbah_cli server prune "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
# Every tag on the rig right now, one per line.
rig_tags() { rig_ssh "docker images --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | tr -d '\r'; }
has_tag()  { local t; t="$(rig_tags)"; grep -qxF "$1" <<<"$t"; }

# --- The fixture, built on the rig -------------------------------------------------
#
# Six images. Three carry a `Created` from October 2024 — more than three months
# before any date this suite can run on — and three are built with today's. The
# pairs are deliberate: within one repository, two images of the *same* age
# differing only in the one fact under test.
old_epoch=1730000000   # 2024-10-27
# The cutoff itself, computed the way the policy states it rather than picked:
# an image in the month `now - 3` is inside the window and one in `now - 4` is
# not, whatever month this suite is run in. Twenty-two months of daylight
# between "old" and "new" would let a cutoff off by one month pass unnoticed.
month1="$(date -u -d "$(date -u +%Y-%m-01) -3 months" +%s)"   # keep
month0="$(date -u -d "$(date -u +%Y-%m-01) -4 months" +%s)"   # remove
if [ -z "$month1" ] || [ -z "$month0" ]; then
    echo "error: this suite needs a date(1) that does \`-d '<date> -3 months'\`" >&2
    exit 2
fi
setup_rc=0
rig_ssh "bash -s '$old_epoch' '$month1' '$month0'" <<'REMOTE' >"$tmpdir/setup" 2>&1 || setup_rc=$?
set -uo pipefail
old=$1
month1=$2
month0=$3
root=/tmp/kasbah-prune-build
rm -rf "$root"; mkdir -p "$root"

# One image per tag, each with a layer of its own so no two share an id.
build() {  # build <tag> <epoch|now>
    local tag=$1 epoch=$2 dir="$root/${1//[:\/]/_}"
    mkdir -p "$dir"
    printf 'FROM alpine:3.20\nRUN touch /kasbah-%s\n' "${tag//[:\/]/-}" > "$dir/Dockerfile"
    if [ "$epoch" = now ]; then
        docker build --quiet -t "$tag" "$dir" >/dev/null || return 1
    else
        SOURCE_DATE_EPOCH="$epoch" docker build --quiet -t "$tag" "$dir" >/dev/null || return 1
    fi
}

build ripe-web:3.0.0   now  || exit 1
docker tag ripe-web:3.0.0 ripe-web:current || exit 1
build ripe-web:0.3.0   now  || exit 1
build ripe-web:0.2.0   "$old" || exit 1
build ripe-web:0.1.0   "$old" || exit 1
# One month apart, straddling the cutoff, in neither the record nor a container.
build ripe-web:0.5.0   "$month1" || exit 1
build ripe-web:0.4.0   "$month0" || exit 1

build held-web:2.0.0   now  || exit 1
docker tag held-web:2.0.0 held-web:current || exit 1
build held-web:0.1.0   "$old" || exit 1
build held-web:0.2.0   "$old" || exit 1

build sealed-web:2.0.0 now  || exit 1
docker tag sealed-web:2.0.0 sealed-web:current || exit 1
build sealed-web:0.1.0 "$old" || exit 1

# A container on held-web:0.1.0 and on nothing else: that image is the only tag
# it holds, so a daemon would refuse to delete it — which is what prune must not
# try.
docker rm -f kasbah-prune-held >/dev/null 2>&1 || true
docker run -d --name kasbah-prune-held held-web:0.1.0 sleep 3600 >/dev/null || exit 1

# The apps tree. /apps is root-owned on a rig whose ssh user is unprivileged;
# stevedore has passwordless sudo, and rig_clean removes the tree the same way.
sudo rm -rf /apps
sudo mkdir -p /apps/.kasbah || exit 1
sudo chown -R "$(id -u):$(id -g)" /apps || exit 1
printf '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data"}\n' \
    > /apps/.kasbah/server.json || exit 1

project() {  # project <name>
    mkdir -p "/apps/$1" || return 1
    {
        printf 'services:\n'
        printf '  web:\n    build: .\n    image: %s-web:current\n' "$1"
        printf '  cache:\n    image: nginx:alpine\n'
    } > "/apps/$1/compose.yml"
}
project ripe   || exit 1
project held   || exit 1
project sealed || exit 1

# ripe has deployed twice: 3.0.0 and 0.2.0. Its last-3 set is those two, so
# 0.1.0 — the same age as 0.2.0 — is outside it and 0.3.0 is saved by its date.
{
    printf '2026-01-02T10:00:00+00:00 deploy 0.2.0 no-backup kasbah=0.1.0-test digest=-\n'
    printf '2026-08-01T10:00:00+00:00 deploy 3.0.0 no-backup kasbah=0.1.0-test digest=-\n'
} > /apps/ripe/versions.log

# held has deployed once. 0.1.0 and 0.2.0 are the same age and in no keep set;
# only the running container separates them.
printf '2026-08-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0-test digest=-\n' \
    > /apps/held/versions.log

# sealed's record cannot be read by this user at all. Its 0.1.0 is the same age
# as ripe's 0.1.0, which prune removes.
printf '2026-08-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0-test digest=-\n' \
    > /apps/sealed/versions.log
chmod 0000 /apps/sealed/versions.log || exit 1
# Its rotated archive, on the other hand, reads perfectly and names a version.
# Without the state check there is a plausible keep set to be had here, and a
# deletion follows from it — which is the whole point: the guard is the state of
# the record, not how many entries could be scraped out of what was readable.
printf '2026-07-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0-test digest=-\n' \
    | gzip -c > /apps/sealed/versions.log.gz || exit 1

# The pointer the probe reads when no --apps-path is given.
sudo mkdir -p /etc/kasbah && printf '/apps\n' | sudo tee /etc/kasbah/apps-path >/dev/null || exit 1
sudo chmod 755 /etc/kasbah && sudo chmod 644 /etc/kasbah/apps-path || exit 1

docker image inspect --format '{{.Id}} {{.Created}} {{range .RepoTags}}{{.}} {{end}}' \
    $(docker images -q | sort -u) 2>/dev/null
exit 0
REMOTE

if [ "$setup_rc" -ne 0 ]; then
    echo "error: could not build the prune fixture on the rig (rc=$setup_rc)" >&2
    sed 's/^/       /' "$tmpdir/setup" >&2
    exit 2
fi
assert 'grep -qF "2024-10-27" "$tmpdir/setup"' \
    "SOURCE_DATE_EPOCH really did backdate the old images — every age assertion below
        is empty theatre otherwise:
$(sed -n '1,20p' "$tmpdir/setup")"

# The state before, so "untouched" is a measurement and not a claim.
before_tags="$(rig_tags | LC_ALL=C sort)"
before_sealed="$(rig_ssh "sudo find /apps/sealed -printf '%p %s %T@ %m\n' | LC_ALL=C sort | md5sum" 2>/dev/null | tr -d '\r')"
held_id="$(rig_ssh "docker image inspect --format '{{.Id}}' held-web:0.1.0" 2>/dev/null | tr -d '\r')"
doomed_id="$(rig_ssh "docker image inspect --format '{{.Id}}' ripe-web:0.1.0" 2>/dev/null | tr -d '\r')"
assert '[ -n "$held_id" ] && [ -n "$doomed_id" ]' "the fixture's two old images have ids"

# --- The plan, without --yes and without a terminal --------------------------------------
prune "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ]' "with no terminal and no --yes, prune stops rather than assuming (exit $rc)
        stderr: $(cli_err)"
assert 'grep -qF -- "--yes" "$tmpdir/err"' "naming the flag that would have answered (stderr: $(cli_err))"
assert 'grep -qE "remove +ripe-web:0.1.0" "$tmpdir/out"' \
    "and it printed the plan first, so the question is about something (stdout: $(cli_out))"
after="$(rig_tags | LC_ALL=C sort)"
assert '[ "$before_tags" = "$after" ]' \
    "a run nobody answered removed nothing at all
        $(diff <(printf '%s\n' "$before_tags") <(printf '%s\n' "$after"))"

# --- The removal --------------------------------------------------------------------------
prune "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "the run exits 0 (exit $rc)
        stdout: $(cli_out)
        stderr: $(cli_err)"

now_tags="$(rig_tags | LC_ALL=C sort)"
gone="$(comm -23 <(printf '%s\n' "$before_tags") <(printf '%s\n' "$now_tags") | tr '\n' ' ')"
assert '[ "$gone" = "held-web:0.2.0 ripe-web:0.1.0 ripe-web:0.4.0 " ]' \
    "exactly three tags left the rig, and they are the three the policy names
        wanted: held-web:0.2.0 ripe-web:0.1.0 ripe-web:0.4.0
        got:    $gone"

# Older than three months, both sides of it. Same repository, same day built.
assert '! has_tag ripe-web:0.1.0' "the old tag outside the keep set is gone"
assert 'has_tag ripe-web:0.2.0'   "the tag built the same second, but named in the deploy record, is still here"
assert 'has_tag ripe-web:0.3.0'   "and the one built today, in no record at all, is still here — age is the other half of the rule"
# The cutoff, one month either side of it, on a daemon rather than in a table.
assert 'has_tag ripe-web:0.5.0'   "an image from the month three back from this one is inside the window and stays"
assert '! has_tag ripe-web:0.4.0' "and the one from the month before that, one month older, goes"

# :current, and the version it points at.
assert 'has_tag ripe-web:current' "':current' is still here"
assert 'has_tag ripe-web:3.0.0'   "and so is the version it points at"

# A single-tag image really is deleted, not merely untagged.
still="$(rig_ssh "docker image inspect --format '{{.Id}}' $doomed_id" 2>/dev/null | tr -d '\r')"
assert '[ -z "$still" ]' \
    "the image behind ripe-web:0.1.0 is gone from the daemon, not just its name (got '$still')"

# What a container holds. Same repository, same age, one difference.
assert 'has_tag held-web:0.1.0' "a tag a running container holds is still here"
assert '! has_tag held-web:0.2.0' "and the one built the same second that nothing holds is gone"
state="$(rig_ssh "docker inspect -f '{{.State.Status}}' $container" 2>/dev/null | tr -d '\r')"
assert '[ "$state" = running ]' "the container is still running (got '$state')"
still="$(rig_ssh "docker image inspect --format '{{.Id}}' $held_id" 2>/dev/null | tr -d '\r')"
assert '[ "$still" = "$held_id" ]' "and its image is still in the daemon"
assert 'grep -qE "keep +held-web:0.1.0.*held by container" "$tmpdir/out"' \
    "the report says which container spared it (stdout: $(cli_out))"

# The skipped project, whole.
assert 'has_tag sealed-web:0.1.0' \
    "the project whose versions.log cannot be read keeps its old tag — the same age as ripe's, which went"
assert 'has_tag sealed-web:2.0.0 && has_tag sealed-web:current' "and every other tag of it"
assert 'grep -qE "^  sealed: " "$tmpdir/out"' "it is named in the skipped section (stdout: $(cli_out))"
assert 'grep -qF "1 project(s) were skipped whole" "$tmpdir/err"' \
    "and the run says so loudly (stderr: $(cli_err))"
after_sealed="$(rig_ssh "sudo find /apps/sealed -printf '%p %s %T@ %m\n' | LC_ALL=C sort | md5sum" 2>/dev/null | tr -d '\r')"
assert '[ "$before_sealed" = "$after_sealed" ]' \
    "and its directory — sizes, mtimes and modes — is byte for byte as it was
        before: $before_sealed
        after:  $after_sealed"

# The rig's own image cache, which prune has no business in: none of these is in
# any project's `build:`, and two of them are older than everything else here.
for stock in alpine:3.20 alpine:latest nginx:alpine redis:7-alpine traefik:v3.7.10; do
    assert 'has_tag "$stock"' "$stock is untouched — a stock image is in nobody's build:"
done

# --- Idempotence ----------------------------------------------------------------------------
prune "$RIG_TARGET" --yes; rc=$?
assert '[ "$rc" = 0 ]' "a second run exits 0 (exit $rc: $(cli_err))"
assert 'grep -qF "nothing to remove" "$tmpdir/out"' \
    "and has nothing left to do (stdout: $(cli_out))"
again="$(rig_tags | LC_ALL=C sort)"
assert '[ "$now_tags" = "$again" ]' "and removes nothing the second time
        $(diff <(printf '%s\n' "$now_tags") <(printf '%s\n' "$again"))"

# --- Leave the rig as it was found, but only on success -----------------------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker rm -f $container >/dev/null 2>&1; docker image rm -f ${tags[*]} >/dev/null 2>&1; rm -rf /tmp/kasbah-prune-build; sudo chmod 0644 /apps/sealed/versions.log 2>/dev/null; true" >/dev/null 2>&1
    left="$(rig_tags | grep -E '^(ripe|held|sealed)-web:' | tr '\n' ' ')"
    assert '[ -z "$left" ]' "every tag this suite made is gone from the rig (left: $left)"
    rig_clean || fail=1
fi

exit "$fail"
