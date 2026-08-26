#!/usr/bin/env bash
# Test: lib/prune.sh — `kasbah server prune`, everything that does not need a
# server.
#
# Four layers, because the command has four:
#   * the pure parts (flag parsing, the month reckoning, the compose read, the
#     last-3-deployed walk), driven straight through the library;
#   * the month reckoning again, side by side with rotation's own
#     `_rd_month_index` out of templates/remote-deploy.sh — the retention window
#     and the rotation window are one window, and two implementations of "older
#     than three months" is the drift the whole policy hangs on;
#   * the remote read step, extracted from its heredoc and run against a fake
#     apps tree with a stub docker;
#   * the command itself, through bin/kasbah with a stub ssh that hands back a
#     crafted protocol block and records the removal step's arguments — which is
#     what fixes the **exact removal set** for a server nothing can be put into
#     on demand.
#
# **This is a destructive command, so the bar is what it does not remove.**
# Every "X was not removed" assertion below is paired with a positive one that
# pins the same mechanism from the other side — two tags of the same age, in the
# same repository, differing only in the one fact under test — because a
# negative assertion is vacuous by default (docs/phases/07-operate.md → 7.6).
#
# The rig-driven half — that the tags really do disappear, and that a real
# `docker image rm` refuses what a container holds — is in
# tests/integration/prune_test.sh.

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

if ! command -v yq >/dev/null || ! command -v gzip >/dev/null || ! command -v zcat >/dev/null; then
    echo "error: this suite needs yq, gzip and zcat" >&2
    exit 2
fi

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

b64() { printf '%s' "$1" | base64 -w0; }

# --- Driver -------------------------------------------------------------------------
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like bin/kasbah: a helper that dies under errexit before its own
# caller can decide what the failure means is a defect this driver reproduces.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prune.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _server_prune_parse_args "$@"
        printf 'target=%s\nyes=%s\n' "$_PR_TARGET" "$_PR_YES"
        ;;
    month)
        idx=""
        if _prune_month_index "$1" idx; then printf 'idx=%s\n' "$idx"
        else printf 'idx=refused\n'; fi
        ;;
    repos)
        content="$(cat)"
        repos=""
        if _prune_project_repos "$content" repos; then printf 'repos=[%s]\n' "$repos"
        else printf 'repos=refused\n'; fi
        ;;
    keep)
        # The record arrives as the two decoded blobs vlog_load takes, archive
        # first, split on a line holding only `--`.
        payload="$(cat)"
        archive="${payload%%$'\n'--$'\n'*}"
        active="${payload#*$'\n'--$'\n'}"
        [ "$archive" != "$payload" ] || { archive=""; active="$payload"; }
        vlog_load "$archive" "$active"
        keep=""
        if _prune_keep_versions keep; then printf 'keep=[%s]\n' "$keep"
        else printf 'keep=refused\n'; fi
        ;;
esac
DRV
drive() { bash "$driver" "$@" 2>&1; echo "rc=$?"; }

# --- Flags ----------------------------------------------------------------------------
out=$(drive parse deploy@vps)
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is the positional argument (got '$out')"
assert 'grep -qxF "yes=" <<<"$out"'  "and without --yes the answer is unset, which means *ask* (got '$out')"
out=$(drive parse deploy@vps --yes)
assert 'grep -qxF "yes=yes" <<<"$out"' "--yes is the scriptable answer (got '$out')"
# There is no --apps-path on this command, on purpose: `server status` is the
# only command that takes one, and aiming a deletion at a tree the server does
# not consider its own is not a recovery path (docs/cli.md).
out=$(drive parse deploy@vps --apps-path=/srv/apps)
assert 'grep -qxF "rc=1" <<<"$out"' "--apps-path is not a flag prune has (got '$out')"
assert 'grep -qF "unknown flag" <<<"$out"' "and it is refused rather than ignored (got '$out')"
out=$(drive parse)
assert 'grep -qxF "rc=1" <<<"$out"' "USER@HOST is required (got '$out')"
assert 'grep -qF "USER@HOST is required" <<<"$out"' "and says so (got '$out')"
out=$(drive parse deploy@vps --force)
assert 'grep -qF "unknown flag" <<<"$out"' "an unknown flag is refused rather than ignored (got '$out')"

# --- The month, against rotation's own copy ---------------------------------------------
#
# The two implementations are asked the same table. A divergence here is the
# retention window and the rotation window disagreeing about what "three months"
# means, which no behavioural test of either one alone can see.
rd_runner="$tmpdir/rd.sh"
sed -n '/^_rd_month_index() {/,/^}/p' "$repo_dir/templates/remote-deploy.sh" > "$tmpdir/rd_month.sh"
assert '[ -s "$tmpdir/rd_month.sh" ]' "rotation's _rd_month_index was extracted from the template"
assert '[ "$(grep -c "^_rd_month_index() {" "$repo_dir/templates/remote-deploy.sh")" = 1 ]' \
    "and there is exactly one of it, so the extraction is unambiguous"
cat > "$rd_runner" <<'RUN'
#!/usr/bin/env bash
set -uo pipefail
. "$1"
if out=$(_rd_month_index "$2"); then printf '%s\n' "$out"; else printf 'refused\n'; fi
RUN

for ts in 2026-08-01 2026-08-13T22:30:37+00:00 2026-01-31T00:00:00Z 2027-12-01 \
          1999-01-01T00:00:00Z 2026-8-01 not-a-date "" 2026-04-30T23:00:00.5Z; do
    ours=$(drive month "$ts" | sed -n 's/^idx=//p')
    theirs=$(bash "$rd_runner" "$tmpdir/rd_month.sh" "$ts")
    assert '[ "$ours" = "$theirs" ]' \
        "prune and rotation read the month of '$ts' the same way (prune '$ours', rotation '$theirs')"
done
# The cutoff itself, as docs/build-deploy.md states it: writing in August prunes
# April and earlier. Three months back from 2026-08 is 2026-05, and the
# comparison is strictly less than.
aug=$(drive month 2026-08-01 | sed -n 's/^idx=//p')
may=$(drive month 2026-05-31 | sed -n 's/^idx=//p')
apr=$(drive month 2026-04-01 | sed -n 's/^idx=//p')
assert '[ "$(( aug - 3 ))" = "$may" ]' "August minus three months is May (aug=$aug may=$may)"
assert '[ "$apr" -lt "$(( aug - 3 ))" ]' "and April is strictly older than the cutoff (apr=$apr)"

# --- Which images a project builds --------------------------------------------------------
compose_two='services:
  web:
    build: .
    image: alpha-web:current
  api:
    build:
      context: ./api
    image: alpha-api:current
  cache:
    image: redis:7-alpine
'
out=$(drive repos <<<"$compose_two")
assert 'grep -qxF "repos=[ alpha-web alpha-api ]" <<<"$out"' \
    "only services with a build: key name a repository prune may touch (got '$out')"
assert '! grep -q "redis" <<<"$out"' \
    "a stock image is nobody's repository — that is why redis:7-alpine can never be a candidate (got '$out')"
out=$(drive repos <<<'services:
  web:
    build: .
    image: reg.example:5000/team/web:current
')
assert 'grep -qxF "repos=[ reg.example:5000/team/web ]" <<<"$out"' \
    "a registry port is not a tag (got '$out')"
out=$(drive repos <<<'services: [not: a mapping')
assert 'grep -qxF "repos=refused" <<<"$out"' \
    "a compose file that is not YAML yields no repositories, and no is not empty (got '$out')"
out=$(drive repos <<<'services:
  web:
    image: nginx:alpine
')
assert 'grep -qxF "repos=[ ]" <<<"$out"' \
    "a project of stock images only claims nothing (got '$out')"

# --- The last three deployed ---------------------------------------------------------------
log5='2026-01-01T10:00:00+00:00 deploy 1.1.0 no-backup kasbah=0.1.0 digest=-
2026-02-01T10:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=-
2026-03-01T10:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0 digest=-
2026-04-01T10:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0 digest=-
2026-05-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-'
out=$(drive keep <<<"$log5")
assert 'grep -qxF "keep=[ 1.5.0 1.4.0 1.3.0 ]" <<<"$out"' \
    "three, newest first, and no more (got '$out')"
# A rollback entry names a version that ran here, exactly as a deploy does —
# lib/versions_log.sh says so in as many words, and after a rollback the version
# :current points at is the rollback's target.
out=$(drive keep <<<"$log5
2026-05-02T10:00:00+00:00 rollback 1.2.0 no-backup kasbah=0.1.0 digest=-")
assert 'grep -qxF "keep=[ 1.2.0 1.5.0 1.4.0 ]" <<<"$out"' \
    "a rollback's target is the first of the three (got '$out')"
# Redeploying the same version twice does not use up two of the three slots.
out=$(drive keep <<<"$log5
2026-05-03T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-")
assert 'grep -qxF "keep=[ 1.5.0 1.4.0 1.3.0 ]" <<<"$out"' \
    "distinct versions, so a redeploy does not spend a slot (got '$out')"
out=$(drive keep <<<'2026-05-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-')
assert 'grep -qxF "keep=[ 1.5.0 ]" <<<"$out"' \
    "a project that has deployed once keeps one (got '$out')"
out=$(drive keep <<<"")
assert 'grep -qxF "keep=refused" <<<"$out"' \
    "an empty record yields no keep set at all: deleting on it is deleting on the absence of a record (got '$out')"
out=$(drive keep <<<"$log5
this line was written by a truncated append")
assert 'grep -qxF "keep=refused" <<<"$out"' \
    "a line the parser cannot read, inside the span walked, refuses the whole answer (got '$out')"
# ...but one older than the three does not: it cannot change which three are newest.
out=$(drive keep <<<"a truncated line, older than everything below it
$log5")
assert 'grep -qxF "keep=[ 1.5.0 1.4.0 1.3.0 ]" <<<"$out"' \
    "a damaged line the walk never reached does not refuse the answer (got '$out')"
# The archive half of the record is read too — rotation is meant to be
# transparent, and a rarely-deployed project's older versions are only there.
out=$(drive keep <<<"2025-01-01T10:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-
--
2026-05-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-")
assert 'grep -qxF "keep=[ 1.5.0 0.9.0 ]" <<<"$out"' \
    "an archived deploy counts toward the three (got '$out')"

# --- The remote read step, run locally ---------------------------------------------------
payload="$tmpdir/remote.sh"
sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$repo_dir/lib/prune.sh" | sed '1d;$d' > "$payload"
assert '[ -s "$payload" ]' "the read step was extracted from lib/prune.sh"
assert 'grep -qF "kv project_count" "$payload"' \
    "and it is the right block — every case below is empty theatre otherwise"
assert 'grep -qF "docker image inspect" "$payload"' \
    "the read step asks docker for the image table"

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$1 $2" in
    "version --format") printf '27.3.1\n'; exit 0 ;;
esac
case "$1 $2" in
    "images -q") printf 'sha256:aaa\nsha256:bbb\n'; exit 0 ;;
    "ps -a")     printf 'c1\n'; exit 0 ;;
esac
if [ "$1" = "image" ] && [ "$2" = inspect ]; then
    printf 'sha256:aaa 2026-08-01T00:00:00Z demo-web:current demo-web:1.0.0\n'
    printf 'sha256:bbb 2025-01-01T00:00:00Z old-web:0.1.0\n'
    exit 0
fi
if [ "$1" = inspect ]; then
    printf 'sha256:aaa running /demo-web\n'
    exit 0
fi
exit 2
STUB
chmod 0755 "$stub_dir/docker"

apps="$tmpdir/apps"
mkdir -p "$apps/.kasbah" "$apps/demo" "$apps/traefik" "$apps/mail" "$apps/locked" "$apps/data"
printf '{"apps_path":"%s"}\n' "$apps" > "$apps/.kasbah/server.json"
printf 'services:\n  web:\n    build: .\n    image: demo-web:current\n' > "$apps/demo/compose.yml"
printf '2026-08-01T10:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n' > "$apps/demo/versions.log"
printf 'not gzip at all\n' > "$apps/demo/versions.log.gz"
: > "$apps/locked/compose.yml"
chmod 0000 "$apps/locked/compose.yml"
touch "$apps/notaproject"

printf '%s\n' "$apps" > "$tmpdir/apps-path"
probe_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG="$tmpdir/docker.log" \
    bash "$payload" /apps "$tmpdir/apps-path" ".kasbah traefik mail data backups" 2>&1)
probe_rc=$?
fact() { sed -n "s/^$1=//p" <<<"$probe_out"; }
assert '[ "$probe_rc" = 0 ]' "the read step exits 0 (rc=$probe_rc: $probe_out)"
assert '[ "$(fact apps_path)" = "$apps" ]' "it read the tree the pointer names (got '$(fact apps_path)')"
assert '[ "$(fact apps_source)" = pointer ]' "and says the pointer is where that came from (got '$(fact apps_source)')"
assert '[ -n "$(fact marker_b64)" ]' "the marker's bytes come back, for the data path inside them"

assert '[ "$(fact marker_state)" = present ]' "and found the server marker (got '$(fact marker_state)')"
assert '[ "$(fact now_month)" = "$(date -u +%Y-%m)" ]' \
    "the month comes from the server's own clock in UTC, as rotation asks it (got '$(fact now_month)')"
assert '[ "$(fact project_count)" = 3 ]' \
    "demo, locked and the thing that is not a directory are projects; traefik, mail, data and .kasbah are not (got '$(fact project_count)')"
img=$(base64 -d <<<"$(fact images_b64)")
assert 'grep -qF "demo-web:current demo-web:1.0.0" <<<"$img"' \
    "every tag an image carries comes back on its line (got '$img')"
held=$(base64 -d <<<"$(fact containers_b64)")
assert 'grep -qF "sha256:aaa running /demo-web" <<<"$held"' \
    "and the containers holding images, by image id (got '$held')"
rows=$(base64 -d <<<"$(fact projects_b64)")
demo_row=$(grep -F "$(printf 'demo' | base64 -w0) " <<<"$rows")
assert '[ -n "$demo_row" ]' "demo has a row (rows: $rows)"
assert '[ "$(cut -d" " -f2 <<<"$demo_row")" = ok ]' "with its compose.yml read (got '$demo_row')"
assert '[ "$(cut -d" " -f4 <<<"$demo_row")" = ok ]' "and its versions.log (got '$demo_row')"
assert '[ "$(cut -d" " -f6 <<<"$demo_row")" = ok ]' "and its archive, whole or not — that is the reader's verdict (got '$demo_row')"
locked_row=$(grep -F "$(printf 'locked' | base64 -w0) " <<<"$rows")
assert '[ "$(cut -d" " -f2 <<<"$locked_row")" = unreadable ]' \
    "a compose.yml this user cannot read is unreadable, not missing (got '$locked_row')"
assert '[ "$(cut -d" " -f4 <<<"$locked_row")" = missing ]' \
    "and a versions.log that is genuinely absent is missing (got '$locked_row')"
notdir_row=$(grep -F "$(printf 'notaproject' | base64 -w0) " <<<"$rows")
assert '[ "$(cut -d" " -f2 <<<"$notdir_row")" = notdir ]' \
    "something under the apps path that is not a directory is reported, not skipped (got '$notdir_row')"

# Read-only: the step opens files and asks docker four questions, all of them
# reads. The tree is digested before and after rather than taking that on trust.
before=$(cd "$apps" && find . -printf '%p %s %T@ %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
env -i PATH="$stub_dir:/usr/bin:/bin" \
    bash "$payload" /apps "$tmpdir/apps-path" ".kasbah traefik mail data backups" >/dev/null 2>&1
after=$(cd "$apps" && find . -printf '%p %s %T@ %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
assert '[ "$before" = "$after" ]' "the read step changes nothing under the apps path"
verbs=$(sed 's/^\([a-z]*\) \([a-z-]*\).*/\1 \2/' "$tmpdir/docker.log" | LC_ALL=C sort -u)
assert '! grep -qvE "^(version --format|images -q|image inspect|ps -a|inspect --format)$" <<<"$verbs" ' \
    "and every docker verb in it is a read (got: $(tr '\n' '|' <<<"$verbs"))"
chmod 0644 "$apps/locked/compose.yml"

# --- The command, with a stub ssh ------------------------------------------------------------
#
# The stub answers the reachability probe, hands the first script step the
# crafted protocol block, and for the second — the removal — records the tags it
# was given and answers as docker would. Everything the policy decides is
# visible in those two facts: what came back, and what was asked to be deleted.
ssh_log="$tmpdir/ssh.log"
rm_log="$tmpdir/rm.log"
payload_file="$tmpdir/payload"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
case "$last" in true) exit 0 ;; esac
case "$*" in *"-O exit"*) exit 0 ;; esac
n=0
[ ! -f "$SSH_COUNT" ] || n=$(cat "$SSH_COUNT")
n=$((n + 1)); printf '%s' "$n" > "$SSH_COUNT"
if [ "$n" = 1 ]; then
    [ -z "${SSH_STEP_RC:-}" ] || exit "$SSH_STEP_RC"
    cat "$SSH_PAYLOAD"
    exit 0
fi
# The removal step. Its arguments are the tags; the command arrives as one
# string that ssh would have handed to the login shell, quoted by lib/ssh.sh.
eval "set -- $last"
shift 3
for ref in "$@"; do
    printf '%s\n' "$ref" >> "$SSH_RM_LOG"
    if [ "$ref" = "${SSH_RM_FAIL:-}" ]; then
        printf 'failed=%s %s\n' "$(printf '%s' "$ref" | base64 -w0)" \
               "$(printf 'Error response from daemon: conflict: unable to delete' | base64 -w0)"
    else
        printf 'removed=%s\n' "$(printf '%s' "$ref" | base64 -w0)"
    fi
done
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

mkdir -p "$tmpdir/home"
prune_cli() {
    : > "$ssh_log"; : > "$rm_log"; rm -f "$tmpdir/ssh.count"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_COUNT="$tmpdir/ssh.count" SSH_RM_LOG="$rm_log" \
        SSH_PAYLOAD="$payload_file" \
        "$repo_dir/bin/kasbah" server prune "$@" 2>&1
}

# --- The fixture ------------------------------------------------------------------------------
#
# One server, five projects, and an image table built so that every edge of the
# policy has a **pair** in it: two tags of the same age in the same repository,
# differing only in the fact under test. Today is 2026-08, so the cutoff is
# 2026-05 and anything from 2026-04 or earlier is outside the window.
now_month=2026-08

images=""
add_image() { images="$images$1 $2 ${*:3}
"; }
#          id            created                     tags…
add_image sha256:a15 2026-08-01T00:00:00Z alpha-web:current alpha-web:1.5.0
add_image sha256:a14 2026-07-01T00:00:00Z alpha-web:1.4.0
# The last-3 pair: same day, same repository, one in the record's newest three
# and one not.
add_image sha256:a13 2026-01-01T00:00:00Z alpha-web:1.3.0
add_image sha256:a12 2026-01-01T00:00:00Z alpha-web:1.2.0
# The in-use pair: same day, one held by a running container.
add_image sha256:a11 2025-12-01T00:00:00Z alpha-web:1.1.0
add_image sha256:a10 2025-12-01T00:00:00Z alpha-web:1.0.0
# The window pair: one month apart, straddling the cutoff, neither in the record.
add_image sha256:a09 2026-05-31T00:00:00Z alpha-web:0.9.0
add_image sha256:a08 2026-04-01T00:00:00Z alpha-web:0.8.0
# The :current pair: same day, one of them the image :current points at even
# though the deploy record's newest three do not name its version.
add_image sha256:b05 2025-10-01T00:00:00Z alpha-api:current alpha-api:0.5.0
add_image sha256:b04 2025-10-01T00:00:00Z alpha-api:0.4.0 spare/base:latest
# Stock images, ancient, belonging to no project's build: — and one repository
# two projects both declare.
add_image sha256:r00 2024-01-01T00:00:00Z redis:7-alpine
add_image sha256:n00 2024-01-01T00:00:00Z nginx:alpine
add_image sha256:c01 2024-01-01T00:00:00Z common-web:0.1.0
add_image sha256:g22 2026-08-02T00:00:00Z gamma-web:current gamma-web:2.2.0
# gamma's archive pair: one day apart, both ancient — 2.0.0 is named only in the
# rotated archive, 1.0.0 is named nowhere.
add_image sha256:g20 2025-09-02T00:00:00Z gamma-web:2.0.0
add_image sha256:g10 2025-09-01T00:00:00Z gamma-web:1.0.0
# The three skipped projects' tags, all ancient, all in no keep set — the only
# thing standing between them and removal is that their record cannot be read.
add_image sha256:e10 2025-09-01T00:00:00Z beta-web:current beta-web:2.0.0
add_image sha256:e11 2025-09-01T00:00:00Z beta-web:1.0.0
add_image sha256:d10 2025-09-01T00:00:00Z delta-web:current delta-web:2.0.0
add_image sha256:d11 2025-09-01T00:00:00Z delta-web:1.0.0
# Tags of a name no project under the apps path declares at all — ancient, and
# candidates for nothing, because a repository nobody claims is nobody's to prune.
add_image sha256:f10 2025-09-01T00:00:00Z epsilon-web:current epsilon-web:2.0.0
add_image sha256:f11 2025-09-01T00:00:00Z epsilon-web:1.0.0
# zeta's active log is not a regular file and its *archive* reads fine; eta's
# active log ends in a line the parser cannot read. Both have a keep set to be
# had from what did read — which is exactly why the guard has to be the state,
# not the entries: without it each of these produces a plausible answer and a
# deletion.
add_image sha256:z10 2026-08-01T00:00:00Z zeta-web:current zeta-web:2.0.0
add_image sha256:z11 2025-09-01T00:00:00Z zeta-web:1.0.0
add_image sha256:h10 2026-08-01T00:00:00Z eta-web:current eta-web:3.0.0
add_image sha256:h11 2025-09-01T00:00:00Z eta-web:1.0.0

containers='sha256:a10 running /alpha-web
sha256:a15 exited /alpha-web-old'

alpha_compose='services:
  web:
    build: .
    image: alpha-web:current
  api:
    build: ./api
    image: alpha-api:current
  shared:
    build: ./shared
    image: common-web:current
  cache:
    image: redis:7-alpine
'
gamma_compose='services:
  web:
    build: .
    image: gamma-web:current
  shared:
    build: ./shared
    image: common-web:current
'
other_compose() { printf 'services:\n  web:\n    build: .\n    image: %s-web:current\n' "$1"; }

alpha_log='2026-01-01T10:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=-
2026-01-02T10:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0 digest=-
2026-07-01T10:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0 digest=-
2026-08-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-'
gamma_active='2026-08-01T10:00:00+00:00 deploy 2.1.0 no-backup kasbah=0.1.0 digest=-
2026-08-02T10:00:00+00:00 deploy 2.2.0 no-backup kasbah=0.1.0 digest=-'
gamma_archive_text='2025-09-02T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-'
printf '%s\n' "$gamma_archive_text" | gzip -c > "$tmpdir/gamma.gz"
gamma_archive_b64="$(base64 -w0 < "$tmpdir/gamma.gz")"
other_log='2026-08-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-'
printf '2026-08-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
    | gzip -c > "$tmpdir/zeta.gz"
zeta_archive_b64="$(base64 -w0 < "$tmpdir/zeta.gz")"
eta_log='2026-08-01T10:00:00+00:00 deploy 3.0.0 no-backup kasbah=0.1.0 digest=-
2026-08-02T10:00:00+00:00 deploy'

# name compose-state compose active-state active archive-state archive
row() {
    printf '%s %s %s %s %s %s %s\n' \
        "$(b64 "$1")" "$2" "${3:--}" "$4" "${5:--}" "$6" "${7:--}"
}
rows="$(row alpha   ok "$(b64 "$alpha_compose")"        ok "$(b64 "$alpha_log")"   missing -)
$(row beta    ok "$(b64 "$(other_compose beta)")"    unreadable -                  missing -)
$(row gamma   ok "$(b64 "$gamma_compose")"           ok "$(b64 "$gamma_active")"   ok "$gamma_archive_b64")
$(row delta   ok "$(b64 "$(other_compose delta)")"   ok "$(b64 "$other_log")"      ok "$(b64 'this is not gzip')")
$(row zeta    ok "$(b64 "$(other_compose zeta)")"    notfile -                     ok "$zeta_archive_b64")
$(row eta     ok "$(b64 "$(other_compose eta)")"     ok "$(b64 "$eta_log")"        missing -)
$(row store   missing -                              missing -                     missing -)"

write_payload() {
    {
        printf 'pointer_state=absent\npointer_value=\n'
        printf 'apps_path=/apps\napps_source=default\n'
        printf 'now_month=%s\n' "${PAYLOAD_MONTH:-$now_month}"
        printf 'have_docker=yes\ndocker_error=\n'
        printf 'apps_state=dir\nmarker_state=%s\n' "${PAYLOAD_MARKER:-present}"
        printf 'marker_b64=%s\n' "$(b64 '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/store"}')"
        printf 'images_b64=%s\n' "$(b64 "$images")"
        printf 'containers_b64=%s\n' "$(b64 "$containers")"
        printf 'project_count=7\n'
        printf 'projects_b64=%s\n' "$(b64 "$rows")"
    } > "$payload_file"
}
write_payload

# --- The plan, and the exact removal set --------------------------------------------------------
out=$(prune_cli deploy@vps --yes)
rc=$?
removed="$(LC_ALL=C sort "$rm_log" | tr '\n' ' ')"
expected="alpha-api:0.4.0 alpha-web:0.8.0 alpha-web:1.1.0 alpha-web:1.2.0 gamma-web:1.0.0 "

assert '[ "$rc" = 0 ]' "a run that removes what it planned exits 0 (rc=$rc)
$out"
# **The** assertion: not "it removed something", but exactly these five and
# nothing else. Every keep below is one line of this set's complement.
assert '[ "$removed" = "$expected" ]' \
    "the removal set is exactly the five tags the policy names
        wanted: $expected
        got:    $removed"

# Older than three months — both sides of the cutoff, one month apart.
assert 'grep -qF "remove alpha-web:0.8.0" <<<"$(tr -s " " <<<"$out")"' \
    "a tag from April, three months back from August, is removed (out: $out)"
assert 'grep -qE "keep +alpha-web:0.9.0.*inside the 3-month window" <<<"$out"' \
    "and the one from May, one month newer, is kept for being inside the window (out: $out)"
assert '[ "${removed#*alpha-web:0.9.0}" = "$removed" ]' "0.9.0 is not in the removal set"

# Last 3 deployed — two images built the same day, one named in the record's
# newest three and one not.
assert 'grep -qE "keep +alpha-web:1.3.0.*among the last 3 deployed" <<<"$out"' \
    "an old image whose version is among the last 3 deployed is kept for that reason (out: $out)"
assert 'grep -qE "remove +alpha-web:1.2.0.*older than 3 months" <<<"$out"' \
    "and the one built the same day, one version older, is removed (out: $out)"
assert '[ "${removed#*alpha-web:1.3.0}" = "$removed" ]' "1.3.0 is not in the removal set"

# :current is never pruned, and neither is the version it points at — even when
# the record's newest three do not name it.
assert '! grep -qE "(remove|keep) +alpha-api:current" <<<"$out"' \
    ":current is not a version tag and never appears as a candidate (out: $out)"
assert 'grep -qE "keep +alpha-api:0.5.0.*:current points at this image" <<<"$out"' \
    "the version :current points at is kept, and the report says why (out: $out)"
assert 'grep -qE "remove +alpha-api:0.4.0" <<<"$out"' \
    "while the tag built the same day that :current does not point at is removed (out: $out)"
assert '[ "${removed#*:current}" = "$removed" ]' "no :current tag is in the removal set"

# Shared and stock tags. redis and nginx are candidates for nothing because no
# service builds them; common-web is claimed by two projects, so no single
# project's record is evidence about it.
assert '! grep -qE "(remove|keep) +(redis|nginx):" <<<"$out"' \
    "a stock image is never a candidate — it is in no project's build: (out: $out)"
assert '[ "${removed#*redis}" = "$removed" ] && [ "${removed#*nginx}" = "$removed" ]' \
    "and neither redis:7-alpine nor nginx:alpine is removed, ancient as they are"
assert 'grep -qE "keep +common-web:0.1.0.*claimed by more than one project" <<<"$out"' \
    "a repository two projects declare is kept, and the report names them (out: $out)"

# A tag a container holds. Two images built the same day; one has a container.
assert 'grep -qE "keep +alpha-web:1.0.0.*held by container alpha-web" <<<"$out"' \
    "a tag a running container holds is kept, and the report says which container (out: $out)"
assert 'grep -qE "remove +alpha-web:1.1.0" <<<"$out"' \
    "and the one built the same day that no container holds is removed (out: $out)"

# The archive is really read: two ancient tags one day apart, one named only in
# versions.log.gz.
assert 'grep -qE "keep +gamma-web:2.0.0.*among the last 3 deployed" <<<"$out"' \
    "a version named only in the rotated archive still counts toward the three (out: $out)"
assert 'grep -qE "remove +gamma-web:1.0.0" <<<"$out"' \
    "and the tag one day older, named in neither file, is removed (out: $out)"

# Removing a tag from an image that carries another is an untag, and the report
# says so rather than implying disk was freed.
assert 'grep -qE "remove +alpha-api:0.4.0.*untags only.*spare/base:latest" <<<"$out"' \
    "a removal that only drops a name says so (out: $out)"

# --- The skipped projects, and the proof they were untouched ---------------------------------------
for p in beta delta zeta eta; do
    assert 'grep -qE "^  $p: " <<<"$out"' "$p is named in the skipped section (out: $out)"
    assert '[ "${removed#*$p-web}" = "$removed" ]' "and not one $p tag is in the removal set"
    assert '! grep -qE "(remove|keep) +$p-web:" <<<"$out"' \
        "and no $p tag reached the plan at all — a skipped project is not judged and then spared"
done
assert 'grep -qE "^  beta: .*versions.log cannot be read.*unreadable" <<<"$out"' \
    "beta's reason is its unreadable log (out: $out)"
assert 'grep -qE "^  delta: .*(not gzip|truncated)" <<<"$out"' \
    "delta's reason is its damaged archive (out: $out)"
assert 'grep -qE "^  zeta: .*versions.log cannot be read.*notfile" <<<"$out"' \
    "zeta's reason is its active log, even though its archive read perfectly (out: $out)"
assert 'grep -qE "^  eta: .*(could not parse|does not yield)" <<<"$out"' \
    "eta's reason is the line its record holds that the parser cannot read (out: $out)"
assert 'grep -qF "4 project(s) were skipped whole" <<<"$out"' \
    "and the run says how many, loudly, after the report (out: $out)"
# --- The bind-mount root is not a project ---------------------------------------------------
#
# `--data-path` can put it under the apps path with any name, so the fixed
# reserved list cannot catch it and the marker is the only record of which
# directory it is — the same fact, out of the same file, that `server status`
# drops the same row on. Reported as a project it would be skipped on **every**
# run, which prints the "skipped whole" warning permanently and trains the
# operator to ignore this command's one safety signal; and, since a directory
# with no compose.yml is a project of unknown ownership, it would stop prune
# removing anything anywhere. The non-empty removal set above is that positive
# counterpart: it exists only because this row was dropped.
assert '! grep -qE "^  store: " <<<"$out"' \
    "the data path named in the marker is not reported as a skipped project (out: $out)"
assert '! grep -qE "(remove|keep) +store" <<<"$out"' "and holds no candidate tags"
assert 'grep -qE "^  beta: " <<<"$out"' \
    "while a directory that is *not* the data path is still reported — the drop is targeted, not a filter on shape"

# The pairing that makes the three assertions above bite: gamma-web:1.0.0 is the
# same age and in the same position in its project as beta-web:1.0.0, and it
# *was* removed. Nothing about age or shape spared beta — only the unreadable
# record did.
assert '[ "${removed#*gamma-web:1.0.0}" != "$removed" ]' \
    "the readable project's identically-aged tag was removed, so the skips are not an accident of the fixture"

# --- Round trips -------------------------------------------------------------------------------------
steps=$(grep -c "'bash' '-s'" "$ssh_log")
assert '[ "$steps" = 2 ]' \
    "a run that removes something makes exactly two script round trips: one batched read, one removal (got $steps)
$(cat "$ssh_log")"

# --- The tri-state ------------------------------------------------------------------------------------
out=$(prune_cli deploy@vps </dev/null)
rc=$?
assert '[ "$rc" = 1 ]' "without --yes and without a terminal, prune stops (rc=$rc)"
assert 'grep -qF -- "--yes" <<<"$out"' "naming the flag that would have answered (out: $out)"
assert '[ ! -s "$rm_log" ]' "and removes nothing"
steps=$(grep -c "'bash' '-s'" "$ssh_log")
assert '[ "$steps" = 1 ]' "one round trip only: the read happened, the removal did not (got $steps)"
assert 'grep -qE "remove +alpha-web:1.2.0" <<<"$out"' \
    "the plan is printed before the question, so the operator answers about something (out: $out)"

# --- Nothing to remove --------------------------------------------------------------------------------
PAYLOAD_MONTH=2025-10 write_payload
out=$(prune_cli deploy@vps </dev/null)
rc=$?
assert '[ "$rc" = 0 ]' "a server whose every tag is inside the window needs no answer (rc=$rc)
$out"
assert 'grep -qF "nothing to remove" <<<"$out"' "and says so (out: $out)"
assert '[ ! -s "$rm_log" ]' "and makes no removal round trip"
steps=$(grep -c "'bash' '-s'" "$ssh_log")
assert '[ "$steps" = 1 ]' "one round trip (got $steps)"
PAYLOAD_MONTH="" write_payload

# --- A removal docker refuses ---------------------------------------------------------------------------
out=$(SSH_RM_FAIL=alpha-web:1.2.0 prune_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 1 ]' "a tag docker would not delete fails the run (rc=$rc)"
assert 'grep -qF "could not remove alpha-web:1.2.0" <<<"$out"' "naming the tag (out: $out)"
assert 'grep -qF "unable to delete" <<<"$out"' "and quoting docker's own reason (out: $out)"
assert 'grep -qF "removed 4 of 5" <<<"$out"' "and says how many did go (out: $out)"

# --- Servers prune will not touch --------------------------------------------------------------------------
PAYLOAD_MARKER=absent write_payload
out=$(prune_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 4 ]' "a host with no server marker is exit 4, not a deletion (rc=$rc)"
assert '[ ! -s "$rm_log" ]' "and nothing is removed there"
assert 'grep -qF "no readable server marker" <<<"$out"' "with a message that says which question is open (out: $out)"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and the recovery it names is server status, read-only, not a path flag on this command (out: $out)"
assert '! grep -qE "server prune .*--apps-path" <<<"$out"' \
    "and never prescribes re-aiming prune itself at a tree the server does not claim (out: $out)"
PAYLOAD_MARKER="" write_payload

: > "$payload_file"
printf 'apps_path=/apps\napps_source=default\n' > "$payload_file"
out=$(prune_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 1 ]' "a truncated probe is refused (rc=$rc)"
assert 'grep -qF "reported no" <<<"$out"' "naming the facts that never arrived (out: $out)"
assert '[ ! -s "$rm_log" ]' "and removes nothing on a payload it could not read whole"
write_payload

# --- Ownership kasbah cannot enumerate ------------------------------------------------------
#
# The multi-owner guard exists so that no single project's record is evidence
# about a repository another project also declares. A project whose compose.yml
# kasbah cannot read, or cannot parse, is exactly the case where that question
# cannot be answered — so it must not be answered as "claims nothing", which
# would *defeat* the guard with the very condition that triggers the skip.
#
# The fixture is two ancient tags in two repositories, in a project whose own
# record is perfectly readable. The only thing that moves between the two runs
# below is whether a project of unknown ownership is on the server.
alt_images=""
alt_add() { alt_images="$alt_images$1 $2 ${*:3}
"; }
alt_add sha256:t30 2026-08-02T00:00:00Z shared-web:current shared-web:3.0.0
alt_add sha256:t10 2025-09-01T00:00:00Z shared-web:1.0.0
alt_add sha256:t20 2026-08-02T00:00:00Z theta-web:current theta-web:2.0.0
alt_add sha256:t11 2025-09-01T00:00:00Z theta-web:1.0.0

theta_compose='services:
  web:
    build: .
    image: theta-web:current
  shared:
    build: ./shared
    image: shared-web:current
'
theta_log='2026-08-02T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-'
# `ok` state, and yq refuses it. That is a different fact from a file the probe
# could not open, and until now it fell through every branch.
omega_compose='services: [not: a mapping'

write_alt_payload() {   # <rows> <count>
    {
        printf 'pointer_state=absent\npointer_value=\n'
        printf 'apps_path=/apps\napps_source=default\n'
        printf 'now_month=%s\n' "$now_month"
        printf 'have_docker=yes\ndocker_error=\n'
        printf 'apps_state=dir\nmarker_state=present\n'
        printf 'marker_b64=%s\n' "$(b64 '{"apps_path":"/apps","data_path":"/apps/data"}')"
        printf 'images_b64=%s\n' "$(b64 "$alt_images")"
        printf 'containers_b64=%s\n' "$(b64 "")"
        printf 'project_count=%s\n' "$2"
        printf 'projects_b64=%s\n' "$(b64 "$1")"
    } > "$payload_file"
}

theta_row="$(row theta ok "$(b64 "$theta_compose")" ok "$(b64 "$theta_log")" missing -)"
omega_row="$(row omega ok "$(b64 "$omega_compose")" ok "$(b64 "$theta_log")" missing -)"
kappa_row="$(row kappa unreadable -                 ok "$(b64 "$theta_log")" missing -)"

# Run A — theta, plus two projects whose declared images cannot be enumerated.
write_alt_payload "$theta_row
$omega_row
$kappa_row" 3
out=$(prune_cli deploy@vps --yes)
rc=$?
removed="$(LC_ALL=C sort "$rm_log" | tr '\n' ' ')"
assert '[ "$rc" = 0 ]' "the run completes (rc=$rc)
$out"
assert '[ -z "$removed" ]' \
    "nothing at all is removed while a project's declared images cannot be enumerated (got: $removed)"
# A compose.yml that reads fine and does not parse is its own skip, with its own
# reason — the state test alone let this one through every branch silently.
assert 'grep -qE "^  omega: .*compose.yml does not parse" <<<"$out"' \
    "the project whose compose.yml is not YAML is skipped and named (out: $out)"
assert 'grep -qE "^  kappa: .*compose.yml cannot be read" <<<"$out"' \
    "and so is the one whose compose.yml could not be opened (out: $out)"
assert 'grep -qF "2 project(s) were skipped whole" <<<"$out"' \
    "both are counted in the warning (out: $out)"
# The negative — and its positive counterpart is the *reason*, which pins the
# ownership mechanism rather than any other keep. If the guard stopped firing,
# these lines would read "older than 3 months" and the removal set would fill.
assert 'grep -qE "keep +shared-web:1.0.0.*ownership cannot be established.*(omega|kappa)" <<<"$out"' \
    "a repository another project might also declare is kept, and the report names who made it unknowable (out: $out)"
assert 'grep -qE "keep +theta-web:1.0.0.*ownership cannot be established.*(omega|kappa)" <<<"$out"' \
    "which is every repository on the server, because an unreadable compose could have declared any of them (out: $out)"
assert 'grep -qF "no repository on deploy@vps is provably single-owner" <<<"$out"' \
    "and the run says so once, in its own sentence, rather than only in per-tag reasons (out: $out)"

# Run B — the same server, the same tags, the same ages, with the unknowable
# projects gone. Without this the assertions above pass on a fixture that never
# had anything to remove.
write_alt_payload "$theta_row" 1
out=$(prune_cli deploy@vps --yes)
rc=$?
removed="$(LC_ALL=C sort "$rm_log" | tr '\n' ' ')"
assert '[ "$rc" = 0 ]' "the same fixture without them completes (rc=$rc)
$out"
assert '[ "$removed" = "shared-web:1.0.0 theta-web:1.0.0 " ]' \
    "and removes both ancient tags, so the run above was held back by the guard and not by the fixture
        wanted: shared-web:1.0.0 theta-web:1.0.0
        got:    $removed"
assert '! grep -qF "skipped" <<<"$out"' "with nothing skipped (out: $out)"
write_payload

# --- No duplicate definitions ------------------------------------------------------------------------------
# Bash takes the last definition of a function and `bash -n` cannot see a
# duplicate, so a byte-identical copy can sit in a file with every suite green
# (docs/phases/07-operate.md → 7.1b). Heredoc-aware: the remote payload is a
# different shell program with a namespace of its own.
for f in lib/prune.sh lib/versions_log.sh lib/common.sh lib/build_push.sh \
         lib/remote_deploy.sh bin/kasbah; do
    dups=$(awk '/<<.REMOTE./{r=1} /^REMOTE$/{r=0} r==0 && /^[a-z_]+\(\)/{print $1}' \
               "$repo_dir/$f" | LC_ALL=C sort | uniq -d)
    assert '[ -z "$dups" ]' "$f defines each function once (duplicates: $dups)"
done

# --- A declined confirmation says so -----------------------------------------------------------------------
# Under errexit a bare `prompt_confirm` would exit 1 with nothing printed, so an
# operator answering `n` and an operator hitting a failure read the same run.
decline_out=$(cd "$repo_dir" && printf 'n\n' | script -qec \
    "bash -c '. lib/common.sh; . lib/prompt.sh; \
       if ! prompt_confirm yes \"remove 3 image tag(s) from you@vps?\"; then \
         err \"not confirmed — nothing was removed\"; exit 1; fi'" /dev/null 2>&1)     && decline_rc=0 || decline_rc=$?
assert '[ "$decline_rc" != 0 ]' "declining the prune confirmation is a non-zero exit (got $decline_rc)"
assert 'grep -q "not confirmed" <<<"$decline_out"' \
    "declining the prune confirmation says so rather than exiting in silence"
# The pair: confirming must NOT print it, or the needle above would match a run
# that went ahead.
accept_out=$(cd "$repo_dir" && printf 'y\n' | script -qec \
    "bash -c '. lib/common.sh; . lib/prompt.sh; \
       if ! prompt_confirm yes \"remove 3 image tag(s) from you@vps?\"; then \
         err \"not confirmed — nothing was removed\"; exit 1; fi; echo WENT-AHEAD'" /dev/null 2>&1)
assert 'grep -q "WENT-AHEAD" <<<"$accept_out"' "confirming the prune confirmation proceeds"
assert '! grep -q "not confirmed" <<<"$accept_out"' \
    "confirming does not print the decline message"

# Two halves, because either alone passes a bare call: the string cmd_server_prune
# prints, and the guarded shape that makes it reachable. A bare `prompt_confirm`
# under errexit exits before any message it is paired with.
assert 'grep -q "not confirmed — nothing was removed" "$repo_dir/lib/prune.sh"' \
    "cmd_server_prune prints the decline message this suite asserts"
assert 'grep -q "if ! prompt_confirm" "$repo_dir/lib/prune.sh"' \
    "cmd_server_prune tests the confirmation rather than calling it bare"

if [ "$fail" = 0 ]; then
    echo "prune: ok"
else
    echo "prune: FAILURES" >&2
fi
exit "$fail"
