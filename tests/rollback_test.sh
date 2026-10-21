#!/usr/bin/env bash
# Test: `kasbah rollback`, and `kasbah deploy X.Y.Z`, which is the same code with
# a different log entry and hook pair (internal/deploy, tagged.go; the record is
# read through internal/vlog).
#
# Hermetic. `ssh` is a stub on PATH that records every call and answers
# as a prepared server's kasbah does — the bootstrap and the marker for real,
# against a scratch apps tree holding the binary under test, every other
# `kasbah remote` step canned, the engine's spec kept; `git` is real, because the whole subject is what a
# tag holds. The fixture repository is built so that **HEAD and v1.0.0 disagree
# about everything the invariant covers** — the sync list, the built-image set,
# the hooks and the Traefik fragment all differ — so a run that read the working
# tree instead of the ref produces visibly different calls rather than the same
# ones by luck.
#
# The sync runs for real, into a scratch root standing in for the server's /,
# which is the only way to see files that exist in a temp directory the run
# deletes on its way out.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# --- The fixture repository -------------------------------------------------------
# Three tags. v1.0.0 is the rollback target; v2.0.0 is HEAD and differs from it in
# every way the invariant is about; v3.0.0's manifest lists a file that tag does
# not carry, which is what the pathspec validation is for.
project="$tmpdir/demo"
mkdir -p "$project"

write_v1() {
    cat > "$project/kasbah.yml" <<'YML'
schema: 1
kasbah_version: 0.1.0
name: demo
domain: demo.test
client: acme
sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
hooks:
  pre-rollback:
    - 'demo-web echo v1-pre-rollback'
  post-rollback:
    - 'demo-web echo v1-post-rollback'
YML
    cat > "$project/compose.prod.yml" <<'YML'
name: demo
services:
  web:
    build:
      context: .
    image: demo-web:current
    container_name: demo-web
  cache:
    build:
      context: .
    image: demo-cache:current
    container_name: demo-cache
YML
    printf '%s\n' '# fragment at v1.0.0' > "$project/traefik-dynamic.yml"
    printf '%s\n' 'DEMO_GREETING=hi' > "$project/.env.prod.example"
    printf '%s\n' '.env' '.kasbah/' > "$project/.gitignore"
}

write_v2() {
    cat > "$project/kasbah.yml" <<'YML'
schema: 1
kasbah_version: 0.1.0
name: demo
domain: demo.test
client: beta-corp
sync:
  - compose.prod.yml -> compose.yml
  - .env.prod.example
  - extra.txt
  - site/
hooks:
  pre-rollback:
    - 'demo-web echo v2-pre-rollback'
  post-rollback:
    - 'demo-web echo v2-post-rollback'
YML
    cat > "$project/compose.prod.yml" <<'YML'
name: demo
services:
  web:
    build:
      context: .
    image: demo-web:current
    container_name: demo-web
  cache:
    build:
      context: .
    image: demo-cache:current
    container_name: demo-cache
  api:
    build:
      context: .
    image: demo-api:current
    container_name: demo-api
YML
    printf '%s\n' '# fragment at v2.0.0' > "$project/traefik-dynamic.yml"
    printf '%s\n' 'a file HEAD syncs and v1.0.0 never had' > "$project/extra.txt"
    mkdir -p "$project/site"
    printf '%s\n' '<p>v2</p>' > "$project/site/index.html"
}

(
    cd "$project" || exit 1
    git init -q .
    git config user.email kasbah-test@example.invalid
    git config user.name "kasbah test"
    git config commit.gpgsign false
    write_v1
    git add -A
    git commit -qm "the commit v1.0.0 tags"
    git tag v1.0.0
    write_v2
    git add -A
    git commit -qm "the commit v2.0.0 tags"
    git tag v2.0.0
    # A tag whose own manifest names a file that tag does not carry. `git add`
    # takes the manifest and nothing else, so ghost.txt is in the sync: list and
    # in no tree.
    sed -i 's|^  - extra.txt$|  - ghost.txt|' kasbah.yml
    printf '%s\n' 'never committed' > ghost.txt
    git add kasbah.yml
    git commit -qm "the commit v3.0.0 tags"
    git tag v3.0.0
    git reset -q --hard v2.0.0
    rm -f ghost.txt
    # A tag whose .gitattributes hides part of the sync: list from `git archive`
    # while leaving it in the tree — one whole file entry, and one file inside a
    # directory entry that otherwise survives.
    printf '%s\n' '<p>kept</p>' > site/keep.html
    printf '%s\n' '.env.prod.example export-ignore' 'site/index.html export-ignore' > .gitattributes
    git add -A
    git commit -qm "the commit v8.0.0 tags, with two paths marked export-ignore"
    git tag v8.0.0
    git reset -q --hard v2.0.0
    # A tag where two sync: entries are the other kind of thing than the
    # manifest says: `site/` is a file there and `extra.txt` a directory.
    rm -rf site && printf '%s\n' 'now a file' > site
    rm -f extra.txt && mkdir extra.txt && printf '%s\n' 'x' > extra.txt/f
    git add -A
    git commit -qm "the commit v9.0.0 tags, with site and extra.txt swapped"
    git tag v9.0.0
    git reset -q --hard v2.0.0
    # A tag from before the project was renamed. The server's directory is
    # <apps>/<name>, so the two names are two projects as far as a rollback can
    # tell.
    sed -i 's|^name: demo$|name: renamed|' kasbah.yml
    git commit -qam "the commit v4.0.0 tags, under the project's old name"
    git tag v4.0.0
    git reset -q --hard v2.0.0
    # A tag cut before kasbah checked `client:` at all, carrying a value this
    # kasbah refuses. Its bytes cannot be edited, so a rollback that died on it
    # would be a previously-working rollback made impossible over a field that
    # has a documented default.
    sed -i 's|^client: beta-corp$|client: Acme Corp|' kasbah.yml
    git commit -qam "the commit v10.0.0 tags, with a client: this kasbah refuses"
    git tag v10.0.0
    git reset -q --hard v2.0.0
) >/dev/null 2>&1

assert '[ "$(cd "$project" && git show v1.0.0:kasbah.yml | grep -c "extra.txt")" = "0" ]' \
    "v1.0.0's manifest does not list extra.txt — the fixture the invariant is read against"
assert '[ "$(cd "$project" && grep -c "extra.txt" kasbah.yml)" = "1" ]' \
    "while the working tree's does"
assert 'grep -qF "demo-api" "$project/compose.prod.yml"' \
    "and HEAD's compose builds a second image v1.0.0 never had"
assert '[ "$(cd "$project" && git show v1.0.0:compose.prod.yml | grep -c "demo-api")" = "0" ]' \
    "which is absent at v1.0.0"

# --- The stubs --------------------------------------------------------------------
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
ssh_log="$tmpdir/ssh.log"
call_log="$tmpdir/calls.log"
spec_copy="$tmpdir/shipped-spec.json"
seed_copy="$tmpdir/shipped-seed.json"
sync_root="$tmpdir/synced"
frag_copy="$sync_root/apps/traefik/dynamic/demo.yml"
compose_copy="$sync_root/apps/demo/compose.yml"
run_tmp="$tmpdir/runtmp"
mkdir -p "$tmpdir/home" "$run_tmp"

# The server: a marker saying /apps, and this build's binary at the shared path
# under a scratch tree the bootstrap probe is pointed at.
FAKE_APPS="$tmpdir/srv/apps"
mkdir -p "$FAKE_APPS/.kasbah/bin"
printf '%s\n' '{"kasbah_version":"1.0.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2.0","mem_limit":"4g"}' \
    > "$FAKE_APPS/.kasbah/server.json"
cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"

cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
printf '%s\n' "$*" >> "$SSH_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
last="${!#}"
[ "$last" = true ] && exit 0
eval "set -- $last"
# The bootstrap probe, which reads the marker, runs for real.
if [ "$1 $2" = "sh -s" ]; then
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7" "${8:-}"
fi
while [ $# -gt 0 ] && [ "$1" != remote ]; do shift; done
[ $# -gt 0 ] && shift
case "${1:-} ${2:-}" in
    # The deploy record: two files' states and bytes, one JSON line.
    "vlog "*)
        printf '{"active_state":"%s","active_b64":"%s","archive_state":"%s","archive_b64":"%s"}\n' \
            "${FAKE_ACTIVE_STATE:-ok}" "$(printf '%s' "${FAKE_ACTIVE:-}" | base64 -w0)" \
            "${FAKE_ARCHIVE_STATE:-missing}" "${FAKE_ARCHIVE_B64:-}" ;;
    "deploy prepare")
        printf 'client=%s\nprepared=yes\n' "${PREPARE_CLIENT:-written}" ;;
    # Derived, not answered: a stub that says a constant cannot tell a check
    # that looked at every image from one that looked at the first.
    "deploy images")
        shift 3
        printf 'checked=%s\nmissing=%s\n' "${CHECKED_OVERRIDE:-$#}" "${IMAGES_MISSING:-}" ;;
    "deploy mail")
        reg=false; [ -n "${MAIL_REGISTRY_B64:-}" ] && reg=true
        st=false; [ "${MAIL_STACK:-no}" = yes ] && st=true
        en=false; [ "${MAIL_ENV:-no}" = yes ] && en=true
        printf '{"stack":%s,"env":%s,"registry_b64":"%s","dms":"%s","snappymail":"running","registry":%s}\n' \
            "$st" "$en" "${MAIL_REGISTRY_B64:-}" "${MAIL_DMS:-running}" "$reg" ;;
    "deploy seed")
        cat > "$SEED_COPY"
        printf 'mail_seed=%s\n' "${MAIL_SEED:-copied}" ;;
    # The engine: the spec it was sent is kept, and the report answers the
    # version it was actually asked for.
    "deploy run")
        cat > "$SPEC_COPY"
        [ "${REMOTE_RC:-0}" = 0 ] || exit "$REMOTE_RC"
        asked="$(jq -r .version "$SPEC_COPY")"
        hist=true; [ "${REPORT_HISTORY-yes}" = yes ] || hist=false
        r='{"kasbah_deploy_report":1'
        [ "${REPORT_OMIT:-}" = version ]         || r+=",\"version\":\"${REPORT_VERSION-$asked}\""
        [ "${REPORT_OMIT:-}" = prev_version ]    || r+=",\"prev_version\":\"${REPORT_PREV-2.0.0}\""
        [ "${REPORT_OMIT:-}" = deployed_before ] || r+=",\"deployed_before\":$hist"
        [ "${REPORT_OMIT:-}" = backup ]          || r+=",\"backup\":\"${REPORT_BACKUP-no-backup}\""
        [ "${REPORT_OMIT:-}" = digest ]          || r+=",\"digest\":\"${REPORT_DIGEST--}\""
        printf '%s}\n' "$r" ;;
    "setup-env drift")
        printf 'template_exists=%s\n' "${ENV_TEMPLATE:-yes}"
        printf 'env_exists=%s\n' "${ENV_EXISTS:-yes}"
        printf 'missing=%s\n' "${ENV_MISSING:-}"
        printf 'extra=%s\n' "${ENV_EXTRA:-}" ;;
    "setup-env inject") exit 0 ;;
    "setup-env prepare") printf 'prepared=yes\n' ;;
    # The sync, received by the binary under test under a scratch root; the
    # call log keeps where it was aimed.
    "sync "*)
        case "$3" in
            *"/dynamic/demo.yml") [ -z "${SYNC_FAIL_FRAGMENT:-}" ] || exit 12 ;;
        esac
        mkdir -p "$SYNC_ROOT$(dirname "$3")"
        exec "$FAKE_APPS/.kasbah/bin/kasbah" remote sync "$2" "$SYNC_ROOT$3" ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB

chmod 0755 "$stub_dir/ssh"

# What the engine was asked to run, as "<mode> <version>"; empty when it never ran.
ran() { [ -s "$spec_copy" ] && jq -r '.mode + " " + .version' "$spec_copy"; }

# Two deploys in the active log, oldest first: rolling back with no version named
# targets the earlier of them.
log_two=$'2026-08-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'

kasbah_run() {
    : > "$ssh_log"; : > "$call_log"
    rm -f "$spec_copy" "$seed_copy"
    rm -rf "$sync_root"
    env -u KASBAH_LIB_DIR \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$run_tmp" \
        SSH_LOG="$ssh_log" CALL_LOG="$call_log" FAKE_APPS="$FAKE_APPS" \
        SPEC_COPY="$spec_copy" SEED_COPY="$seed_copy" SYNC_ROOT="$sync_root" \
        FAKE_ACTIVE="${FAKE_ACTIVE-$log_two}" \
        "$KASBAH_BIN" "$@" </dev/null 2>&1
}
rollback() { ( cd "$project" && kasbah_run rollback "$@" ) ; }
deploy()   { ( cd "$project" && kasbah_run deploy "$@" ) ; }

# --- A rollback that works, and the invariant it has to hold -----------------------
out="$(rollback deploy@vps 1.0.0)"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "a rollback to a version the server has run succeeds (rc $rc: $out)"
assert 'grep -qF "Rolled demo back to 1.0.0 on deploy@vps" <<<"$out"' "and says so (said '$out')"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "the server's engine is run in rollback mode, with the target version (ran: $(ran))"

# **The invariant.** Every one of these four is a fact about v1.0.0 that HEAD
# contradicts, so each of them fails against a run that read the working tree.
assert '! grep -qF "extra.txt" <<<"$calls"' \
    "the sync: list is v1.0.0's — HEAD's extra.txt is not shipped ($(grep -F "'sync'" <<<"$calls"))"
assert '! grep -qF "/apps/demo/site" <<<"$calls"' \
    "nor HEAD's site/ directory ($(grep -F "site" <<<"$calls"))"
assert 'grep -qF "'"'remote' 'sync' 'file' '/apps/demo/compose.yml'"'" <<<"$calls"' \
    "and the rename in it still lands on compose.yml — which \`git archive | tar -x\` could not do
        calls: $(grep -F "compose" <<<"$calls")"
assert 'grep -qF "demo-web" <<<"$calls" && grep -qF "demo-cache" <<<"$calls" &&
        ! grep -qF "demo-api" <<<"$calls"' \
    "the image check asks about v1.0.0's two built images and not the third HEAD added ($(grep -F "demo-" <<<"$calls"))"
assert '[ -f "$compose_copy" ] && ! grep -qF "demo-api" "$compose_copy"' \
    "the compose file that arrived is v1.0.0's ($(head -c 120 "$compose_copy" 2>/dev/null | tr '\n' '/'))"
assert '[ -f "$frag_copy" ] && grep -qF "fragment at v1.0.0" "$frag_copy"' \
    "so is the Traefik fragment (got '$(cat "$frag_copy" 2>/dev/null)')"
assert '! grep -qF "v2.0.0" "$frag_copy" 2>/dev/null' \
    "and not the working tree's, which says v2.0.0"
assert '[ "$(jq -c "[.pre, .post]" "$spec_copy")" = "[[\"demo-web echo v1-pre-rollback\"],[\"demo-web echo v1-post-rollback\"]]" ]' \
    "the hooks sent to the engine are v1.0.0's rollback pair ($(jq -c "[.pre, .post]" "$spec_copy" 2>/dev/null))"
assert '[ "$(jq -c .images "$spec_copy")" = "[\"demo-cache\",\"demo-web\"]" ]' \
    "and so is the image list it retags ($(jq -c .images "$spec_copy" 2>/dev/null))"
assert '! grep -qF "/scripts/" <<<"$calls"' \
    "and nothing is shipped to scripts/ — the engine is the server's binary ($(grep -F "/scripts/" <<<"$calls"))"

# `.kasbah-client` is the server's only record of which backup repository this
# project files into (08-keep.md D12), and the prepare step is what writes it —
# so a rollback that did not read v<target>'s `client:` would hand that step an
# empty value and *erase* the record. Asserted where it crosses to the server,
# and asserted as the **tag's** value: HEAD says beta-corp.
assert 'grep -qF "'\''/apps'\'' '\''/apps/data'\'' '\''demo'\'' '\''acme'\''" "$ssh_log"' \
    "the prepare step is handed v1.0.0's client: (ssh saw: $(grep -F "/apps/data" "$ssh_log"))"
assert '! grep -qF "beta-corp" "$ssh_log"' \
    "and not the working tree's, which says beta-corp (ssh saw: $(grep -F "/apps/data" "$ssh_log"))"
assert 'grep -qF "client:  acme (written," <<<"$out"' \
    "and the run says which repository the record now names (said '$out')"

# The working tree is neither read nor written: `git archive` and `git show` do
# not touch it, and a rollback that checked anything out would say so here.
assert '[ "$(cd "$project" && git status --porcelain)" = "" ]' \
    "the working tree is untouched (git says: $(cd "$project" && git status --porcelain | tr '\n' '/'))"
assert '[ "$(cd "$project" && git rev-parse HEAD)" = "$(cd "$project" && git rev-parse v2.0.0)" ]' \
    "and HEAD is still where it was"

# The order the fragment must keep, and the env step's place in it.
n_of() { grep -n -m1 -F -- "$1" <<<"$calls" | cut -d: -f1; }
n_vlog=$(n_of "'vlog' '/apps' 'demo'")
n_images=$(n_of "'demo-web'")
n_sync=$(n_of "'sync' 'file' '/apps/demo/compose.yml'")
n_drift=$(n_of "'setup-env' 'drift'")
n_remote=$(n_of "'deploy' 'run'")
n_frag=$(n_of "/dynamic/demo.yml")
for n in n_vlog n_images n_sync n_drift n_remote n_frag; do
    [ -n "${!n}" ] || printf -v "$n" '%s' 0
done
assert '[ "$n_vlog" -gt 0 ] && [ "$n_images" -gt 0 ] && [ "$n_sync" -gt 0 ] &&
        [ "$n_drift" -gt 0 ] && [ "$n_remote" -gt 0 ] && [ "$n_frag" -gt 0 ]' \
    "the run made every call the order below is about (log $n_vlog, images $n_images, sync $n_sync,
        drift $n_drift, remote $n_remote, fragment $n_frag)
        calls: $calls"
assert '[ "$n_frag" -gt "$n_remote" ]' \
    "the fragment ships after the remote step returns, never before it (fragment $n_frag, remote $n_remote)"
assert '[ "$n_images" -lt "$n_sync" ]' \
    "the image check runs before anything is shipped (images $n_images, first sync $n_sync)"
assert '[ "$n_drift" -gt "$n_sync" ] && [ "$n_drift" -lt "$n_remote" ]' \
    "and the env step keeps its place: after the template is on the server, before compose reads
        the .env it writes (sync $n_sync, drift $n_drift, remote $n_remote)"

# The state file belongs to the project root, not to the extraction the run
# deletes: written from in there it would vanish with it.
assert '[ "$(jq -r .last_version "$project/.kasbah/state.json" 2>/dev/null)" = "1.0.0" ]' \
    "a rollback that worked records the version it went back to"
assert '[ "$(jq -r .last_server "$project/.kasbah/state.json" 2>/dev/null)" = "deploy@vps" ]' \
    "and the server it went to"
leftover=$(find "$run_tmp" -mindepth 1 -maxdepth 1 2>/dev/null | sort | tr '\n' ' ')
assert '[ -z "$leftover" ]' \
    "and TMPDIR is empty afterwards — neither the extraction nor the ssh control directory
        outlives the run (found: $leftover)"
rm -rf "$project/.kasbah"

# --- Which version, and where it comes from ---------------------------------------
# No version named: the second-latest action=deploy entry, which is 1.0.0 here.
out="$(rollback deploy@vps)"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "a rollback with no version succeeds (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "targeting the deploy before the current one (ran: $(ran))"
assert 'grep -qF "rolling back to 1.0.0" <<<"$out"' "and says which entry it picked (said '$out')"
rm -rf "$project/.kasbah"

# The same question when the earlier deploy has aged into the rotation archive.
# Nothing in the active log names 1.0.0 at all, so a reader of that file alone
# has no implicit target and refuses.
arch_b64="$(printf '%s\n' '2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-' | gzip -c | base64 -w0)"
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$arch_b64" rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "the implicit target is found in the rotation archive too (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "and it is the archived deploy (ran: $(ran))"
rm -rf "$project/.kasbah"

# One deploy in the whole record: there is no *previous* one to go back to.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a record with one deploy in it has no implicit target (rc $rc: $out)"
assert 'grep -qF "no earlier deploy" <<<"$out"' "and says so (said '$out')"
assert 'grep -qF "kasbah rollback deploy@vps <X.Y.Z>" <<<"$out"' \
    "pointing at the argument that would answer it (said '$out')"
assert '[ -z "$(ran)" ]' "no implicit target: nothing ran on the server"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "no implicit target: nothing was shipped"

# An empty log is a different sentence: nothing was ever deployed here.
out="$( FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing rollback deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "so does a project with no record on this server (rc $rc: $out)"
assert 'grep -qF "holds no entry for this project at all" <<<"$out"' \
    "with the sentence that fits an empty log rather than the one about two deploys (said '$out')"

# --- A line the reader could not parse -------------------------------------------
# A `printf >>` killed mid-append leaves a last line no version can be read out
# of, and it is still a deploy that ran. Stepped over in silence it makes the
# deploy *before* it the rollback target — one version too far back, chosen
# confidently. The record's own damaged-line count is the only thing that can
# say so, and both answers built on it have to consult it.
log_damaged=$'2026-08-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:0'
out="$( FAKE_ACTIVE="$log_damaged" rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "an unreadable last line does not stop a rollback (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "the target is still the second-most-recent deploy it could read (ran: $(ran))"
assert 'grep -qF "has 1 line(s) no version can be read" <<<"$out"' \
    "but the count of lines it stepped over is said out loud (said '$out')"
assert 'grep -qF "one version further back than it should be" <<<"$out"' \
    "and what that costs: a deploy this side cannot read is still a deploy (said '$out')"
assert 'grep -qF "/apps/demo/versions.log" <<<"$out"' \
    "naming the file to look at (said '$out')"
rm -rf "$project/.kasbah"

# The control: the same rollback against a record with nothing damaged in it says
# none of that — otherwise the warning above proves only that a warning exists.
out="$( rollback deploy@vps )"; rc=$?
assert '[ "$rc" = "0" ]' "a clean record rolls back with no such warning (rc $rc: $out)"
assert '! grep -qF "no version can be read" <<<"$out"' "and says nothing about damaged lines (said '$out')"
rm -rf "$project/.kasbah"

# The other face of the same fact: the only line naming the target may be the one
# that could not be read, so "never deployed here" is a claim the reader cannot
# make.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:0' \
        rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a target that is not in a record with an unreadable line is still refused (rc $rc: $out)"
assert 'grep -qF "1 line(s) of" <<<"$out"' "counting what could not be read (said '$out')"
assert '! grep -qF "was never deployed to this VPS" <<<"$out"' \
    "without asserting an absence the reader cannot see (said '$out')"
assert 'grep -qF "the same thing as never having deployed it here" <<<"$out"' \
    "saying so outright (said '$out')"
assert 'grep -qF "kasbah deploy deploy@vps 1.0.0" <<<"$out"' \
    "and still offering the first-time deploy, conditioned (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"

# --- A damaged line that is in the archive, not in the active log ------------------
# `VLOG_SKIPPED_DAMAGED` counts across the whole record, so a message that names
# only the active log sends the operator to a file with nothing wrong in it. The
# fixture puts the damaged line where the message must not claim it is: the
# active log below is a single clean entry.
dmg_arch_b64="$( { printf '%s\n' '2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-'
                   printf '%s' '2026-02-01T00:00:00+00:0'; } | gzip -c | base64 -w0 )"
clean_active=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'
out="$( FAKE_ACTIVE="$clean_active" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$dmg_arch_b64" \
        rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "a damaged line in the archive does not stop a rollback (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "the target is the archived deploy behind it (ran: $(ran))"
assert 'grep -qF "has 1 line(s) no version can be read" <<<"$out"' \
    "and the count is said out loud (said '$out')"
assert 'grep -qF "/apps/demo/versions.log.gz" <<<"$out"' \
    "naming the archive, which is the file the line is actually in — the active log here is one
        clean entry, so a message pointing only at it points at nothing (said '$out')"
rm -rf "$project/.kasbah"

# The same split on the refusal: a target that is in neither file, with the
# unreadable line in the archive.
out="$( FAKE_ACTIVE="$clean_active" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$dmg_arch_b64" \
        rollback deploy@vps 5.5.5 )"; rc=$?
assert '[ "$rc" != "0" ]' "a target in neither file is still refused (rc $rc: $out)"
assert 'grep -qF "1 line(s) of" <<<"$out"' "counting what could not be read (said '$out')"
assert 'grep -qF "Look at /apps/demo/versions.log and /apps/demo/versions.log.gz" <<<"$out"' \
    "and sending the operator to both files, since the count spans both (said '$out')"

# --- An archive kasbah could not read through --------------------------------------
# Every conclusion a rollback draws from the *absence* of a record is a claim
# about both files. `vlog_fetch` refuses an unreadable *active* log outright, so
# the only way one half goes unread is the archive — which is a warning, and so
# reaches all three of the places a rollback concludes something. The worst of
# them answered with "use `kasbah deploy <host> X` for a first-time deploy" and
# a line claiming to have read the archive: following that advice takes a backup
# and runs the deploy hook pair over a version that has already run there.
#
# Two shapes, and they are not the same evidence. `noaccess` is an archive
# nothing was read out of; a truncated trailing gzip member is one that gave up
# part of itself, and the entries it swallows are the newest archived ones.
m1="$tmpdir/m1.gz"; m2="$tmpdir/m2.gz"
printf '%s\n' '2026-01-01T00:00:00+00:00 deploy 0.5.0 no-backup kasbah=0.1.0 digest=-' | gzip -c > "$m1"
printf '%s\n' '2026-02-01T00:00:00+00:00 deploy 0.6.0 no-backup kasbah=0.1.0 digest=-' | gzip -c > "$m2"
whole_b64="$( cat "$m1" "$m2" | base64 -w0 )"
cut_b64="$( { cat "$m1"; head -c 10 "$m2"; } | base64 -w0 )"
one_deploy=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'
# The fixture has to contain what the assertions below name: an entry that is
# really in the archive and really invisible once the last member is cut.
assert '[ "$(cat "$m1" "$m2" | zcat 2>/dev/null | grep -cF "0.6.0")" = "1" ]' \
    "the whole archive holds a 0.6.0 entry"
assert '[ "$( { cat "$m1"; head -c 10 "$m2"; } | zcat 2>/dev/null | grep -cF "0.6.0")" = "0" ]' \
    "and the truncated copy does not — that entry is what the cut member swallows"
assert '[ "$( { cat "$m1"; head -c 10 "$m2"; } | zcat 2>/dev/null | grep -cF "0.5.0")" = "1" ]' \
    "while the member before it still reads"

# Site 1: an implicit target read *out of* the half that would not decode
# through. The active log holds one deploy, so the walk has to reach the
# archive, and the entry a truncated member swallows is the newest archived one
# — which is the deploy that should have been the target.
mid="$tmpdir/mid.gz"
printf '%s\n' '2026-02-15T00:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-' | gzip -c > "$mid"
old_first="$tmpdir/old1.gz"
printf '%s\n' '2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-' | gzip -c > "$old_first"
hidden_whole_b64="$( cat "$old_first" "$mid" | base64 -w0 )"
hidden_cut_b64="$( { cat "$old_first"; head -c 10 "$mid"; } | base64 -w0 )"
assert '[ "$(cat "$old_first" "$mid" | zcat 2>/dev/null | grep -cF "1.5.0")" = "1" ]' \
    "the whole archive holds a deploy of 1.5.0 between 1.0.0 and the active log's entry"
assert '[ "$( { cat "$old_first"; head -c 10 "$mid"; } | zcat 2>/dev/null | grep -cF "1.5.0")" = "0" ]' \
    "and the truncated copy loses exactly that one — the nearer deploy is what the cut member
        swallows, which is what makes the target below wrong"

out="$( FAKE_ACTIVE="$one_deploy" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$hidden_cut_b64" \
        rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "a half-read archive does not stop a rollback (rc $rc: $out)"
assert 'grep -qF "rolling back to 1.0.0" <<<"$out"' \
    "and the target it can reach is one deploy further back (said '$out')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$out"' \
    "which it says, in the shape the decode found (said '$out')"
assert 'grep -qF "1.0.0 was read out of it" <<<"$out"' \
    "naming where the target came from (said '$out')"
assert 'grep -qF "a nearer deploy may be among the" <<<"$out"' \
    "and what the entries it could not decode may have been (said '$out')"
rm -rf "$project/.kasbah"

# Two controls, because the hedge has to be absent for two different reasons.
# A whole archive has nothing to be short of — and the target it yields is the
# 1.5.0 the run above could not see, which is what makes that run's answer
# wrong rather than merely hedged. (It stops at the tag check, which is step 4:
# the fixture repository has no v1.5.0, and getting that far is the proof the
# record check passed.)
out="$( FAKE_ACTIVE="$one_deploy" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$hidden_whole_b64" \
        rollback deploy@vps )"; rc=$?
assert 'grep -qF "rolling back to 1.5.0" <<<"$out"' \
    "the whole archive names 1.5.0 as the target, not the 1.0.0 the cut one reached (said '$out')"
assert 'grep -qF "is not a tag in this repository" <<<"$out"' \
    "and the run went on to step 4, so nothing in the record refused it (said '$out')"
assert '! grep -qF "not the whole record" <<<"$out"' \
    "with nothing said about a record it read all of (said '$out')"
assert '! grep -qF "a nearer deploy may be" <<<"$out"' "and no hedge on the target (said '$out')"
rm -rf "$project/.kasbah"

# And a target found in the active log cannot be displaced by anything the
# archive is missing — rotation moves entries out and never in — so an
# unreadable archive is raised as a fact and not as a doubt about the target.
out="$( FAKE_ARCHIVE_STATE=noaccess rollback deploy@vps )"; rc=$?
assert '[ "$rc" = "0" ]' "an unreadable archive does not stop a rollback either (rc $rc: $out)"
assert 'grep -qF "rolling back to 1.0.0" <<<"$out"' \
    "the target is the active log's second-most-recent deploy (said '$out')"
assert '! grep -qF "a nearer deploy may be" <<<"$out"' \
    "and nothing in the archive could have been nearer, so nothing says otherwise (said '$out')"
rm -rf "$project/.kasbah"

# Site 2: no implicit target at all, and an empty active log. "Nothing was ever
# deployed here" is a claim about both files.
out="$( FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing FAKE_ARCHIVE_STATE=noaccess rollback deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "with no target and no readable archive the rollback is refused (rc $rc: $out)"
assert '! grep -qF "holds no entry for this project at all" <<<"$out"' \
    "without the sentence that asserts the whole record is empty (said '$out')"
assert 'grep -qF "whether its archive holds one cannot be told" <<<"$out"' \
    "saying what is true instead — the same sentence \`history\` gives for the same record (said '$out')"
assert 'grep -qF "this is not evidence that" <<<"$out"' \
    "and naming outright what it is not evidence of (said '$out')"
assert 'grep -qF "deploy@vps has never deployed it" <<<"$out"' \
    "which is the claim it is refusing to make (said '$out')"
assert 'grep -qF "could not be read (the probe called it '\''noaccess'\'')" <<<"$out"' \
    "with the note under it (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"

# The control: the same empty log with the archive accounted for keeps the
# stronger sentence, which is the one that is true there.
out="$( FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing rollback deploy@vps )"; rc=$?
assert 'grep -qF "holds no entry for this project at all" <<<"$out"' \
    "an accounted-for archive is what lets the absence be stated (said '$out')"
assert '! grep -qF "cannot be told" <<<"$out"' "with no hedge (said '$out')"

# Site 3, and the one that used to send an operator to `kasbah deploy`. The
# target is genuinely in the archive, inside the member that will not decode.
out="$( FAKE_ACTIVE="$one_deploy" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$whole_b64" \
        rollback deploy@vps 0.6.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "the control run also fails, on the tag (rc $rc: $out)"
assert 'grep -qF "is not a tag in this repository" <<<"$out"' \
    "which is step 4 — so with the whole archive the record check passed and 0.6.0 really is
        in there (said '$out')"
assert '! grep -qF "never deployed to this VPS" <<<"$out"' \
    "and the record did not refuse it (said '$out')"

out="$( FAKE_ACTIVE="$one_deploy" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$cut_b64" \
        rollback deploy@vps 0.6.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "with the last archive member truncated, the same target is refused (rc $rc: $out)"
assert '! grep -qF "was never deployed to this VPS" <<<"$out"' \
    "but never as an absence — the entry naming it is in the part that would not decode (said '$out')"
assert '! grep -qF "and its rotation archive on" <<<"$out"' \
    "and never with the line claiming both files were read (said '$out')"
assert 'grep -qF "did not come back whole" <<<"$out"' \
    "it says which half it could not read (said '$out')"
assert 'grep -qF "ends in a truncated gzip member" <<<"$out"' \
    "in the shape the decode found, not one re-derived from what got through (said '$out')"
assert 'grep -qF "not the same thing as never having deployed it here" <<<"$out"' \
    "and says outright what the refusal is not (said '$out')"
assert 'grep -qF "kasbah deploy deploy@vps 0.6.0" <<<"$out"' \
    "still offering the first-time deploy, conditioned on the operator looking (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"

# The entry the truncated archive did give up is still a target, so the refusal
# above is about the missing member and not about an archive being present.
out="$( FAKE_ACTIVE="$one_deploy" FAKE_ARCHIVE_STATE=ok FAKE_ARCHIVE_B64="$cut_b64" \
        rollback deploy@vps 0.5.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "the entry before the damage fails on its tag, not on the record (rc $rc: $out)"
assert 'grep -qF "is not a tag in this repository" <<<"$out"' \
    "so the record check passed for it (said '$out')"

# --- The three refusals -------------------------------------------------------------
# Never deployed here. The version is a real tag in this checkout, so this is the
# record's answer and not git's.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "rolling back to a version this server never ran is refused (rc $rc: $out)"
assert 'grep -qF "Version 1.0.0 was never deployed to this VPS." <<<"$out"' \
    "with the spec's own sentence (said '$out')"
assert 'grep -qF "Use \`kasbah deploy deploy@vps 1.0.0\` for a first-time deploy." <<<"$out"' \
    "and the command that would do it instead (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"

# Any entry naming it counts, whatever its action: a version rolled back to twice
# has a `rollback` line as its most recent mention, and that is still proof it
# ran here.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 rollback 1.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' \
    "a version whose only mention is a rollback entry is still rollable-to (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "and the rollback ran (ran: $(ran))"
rm -rf "$project/.kasbah"

# A pruned image. The version is in the record and the tag is here; what is gone
# is the thing kasbah cannot rebuild and will not pretend to.
out="$( IMAGES_MISSING=demo-web rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a rollback whose image has been pruned is refused (rc $rc: $out)"
assert 'grep -qF "Image demo-web:1.0.0 is no longer on the VPS (outside the" <<<"$out"' \
    "naming the image and why (said '$out')"
assert 'grep -qF "NOT byte-identical to the original" <<<"$out"' \
    "saying plainly that a rebuild is not the same bytes (said '$out')"
assert 'grep -qF "git checkout v1.0.0 && kasbah build-push deploy@vps" <<<"$out"' \
    "with the escape hatch (said '$out')"
assert 'grep -qF "kasbah rollback deploy@vps 1.0.0" <<<"$out"' "and the retry (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"
assert '! grep -qF "never built" <<<"$out"' \
    "and it does not hedge: a rollback has already proved the version is in the record, so an
        absent image is one the retention window let go (said '$out')"

# The same branch in tagged-deploy mode, where the headline above is false. A
# `kasbah deploy <host> X.Y.Z` for a version that was never built and shipped is
# the commonest way here, and a deploy reads no record at all — so "no longer on
# the VPS (outside the retention window)" states a history kasbah never looked
# for. The advice below it already branched correctly; the headline did not.
out="$( IMAGES_MISSING=demo-web FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing deploy deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a tagged deploy whose image is not on the server is refused (rc $rc: $out)"
assert 'grep -qF "Image demo-web:1.0.0 is not on deploy@vps" <<<"$out"' \
    "naming the image and the server (said '$out')"
assert '! grep -qF "no longer on the VPS" <<<"$out"' \
    "without claiming it used to be there — nothing in this run read a record (said '$out')"
assert '! grep -qF "outside the retention window)." <<<"$out"' \
    "nor giving a reason it did not establish (said '$out')"
assert 'grep -qF "either it was never built" <<<"$out"' \
    "it names both states it cannot tell apart (said '$out')"
assert 'grep -qF "does not read the deploy record, so kasbah cannot tell which" <<<"$out"' \
    "and why it cannot (said '$out')"
assert 'grep -qF "kasbah history deploy@vps --all" <<<"$out"' \
    "pointing at the command that would answer it (said '$out')"
assert 'grep -qF "git checkout v1.0.0 && kasbah build-push deploy@vps" <<<"$out"' \
    "with the advice that fits either state (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# A tag this checkout does not have. `git fetch --tags` is spent on it once,
# unprompted, and the repository has no remote — so the retry finds nothing.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 7.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 7.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a target with no tag in this checkout is a hard failure (rc $rc: $out)"
assert 'grep -qF "this checkout has no tag v7.0.0" <<<"$out"' "saying which tag (said '$out')"
assert 'grep -qF "fetching tags from the remote" <<<"$out"' \
    "having tried a fetch first, out loud (said '$out')"
assert 'grep -qF "is not a tag in this repository" <<<"$out"' "and then giving up (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# A version that is in neither the record nor this checkout's tags. Both
# refusals fit, and the record's is the one that comes out: it is step 3 of the
# flow and the tag check is step 4, which is also the more useful order — the
# operator learns the server never ran it, not that a tag is missing.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 6.6.6 )"; rc=$?
assert '[ "$rc" != "0" ]' "a target in neither the record nor the tags is refused (rc $rc: $out)"
assert 'grep -qF "Version 6.6.6 was never deployed to this VPS." <<<"$out"' \
    "by the record, which is asked first (said '$out')"
assert '! grep -qF "is not a tag in this repository" <<<"$out"' \
    "and not by the tag check below it (said '$out')"

# --- The sync list, against the tree the tag really holds ---------------------------
# `git archive` exits 128 and produces nothing at all when one pathspec is
# missing, so the list is checked first. The tell is whose message comes out:
# git's own `pathspec … did not match any files` means the check was skipped.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 3.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 3.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a tag whose manifest lists a path it does not carry is refused (rc $rc: $out)"
assert 'grep -qF "ghost.txt — no such path at v3.0.0" <<<"$out"' \
    "naming the entry and the tag (said '$out')"
assert '! grep -qF "did not match any files" <<<"$out"' \
    "before \`git archive\` was asked for it — that is git's message, and it means the check
        never ran (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# A tag from before the project was renamed. Whichever name is right, kasbah
# cannot know which of the two directories on the server this run is about.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 4.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 4.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a target tagged under another project name is refused (rc $rc: $out)"
assert 'grep -qF "called demo today and was called renamed at v4.0.0" <<<"$out"' \
    "naming both (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# --- What `git archive` actually produced -----------------------------------------
# `git ls-tree` says what is in the tree and `git archive` says what gets
# exported, and .gitattributes export-ignore separates them: the path comes back
# from ls-tree, and the archive drops it with exit 0 and no message. Only the
# extraction reflects that, so only the extraction can be trusted.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 8.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 8.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a tag whose sync: list is partly export-ignored is refused (rc $rc: $out)"
assert 'grep -qF ".env.prod.example — in the tag'\''s tree, not in the archive" <<<"$out"' \
    "naming the file entry the archive dropped — the case that used to pass in silence (said '$out')"
assert 'grep -qF "site/index.html — in the tag'\''s tree, not in the archive" <<<"$out"' \
    "and the file inside a directory entry that survived without it (said '$out')"
assert 'grep -qF "export-ignore" <<<"$out"' "with the mechanism that does it (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# --- Sync entries that are the other kind of thing at the ref ------------------------
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 9.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 9.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a tag where a directory entry is a file is refused (rc $rc: $out)"
assert 'grep -qF "site/ — listed with a trailing slash" <<<"$out"' \
    "naming the entry and what it is there instead (said '$out')"
assert 'grep -qF "extra.txt — is a directory at v9.0.0" <<<"$out"' \
    "and the other direction in the same run (said '$out')"
assert '! grep -qF "did not match any files" <<<"$out"' \
    "before \`git archive\` was asked for either (said '$out')"
assert '[ "$(grep -c "'"'sync'"'" <<<"$calls")" = "0" ]' "and nothing was shipped"

# --- A tag whose `client:` this kasbah refuses -----------------------------------------
# `deploy` and `kasbah check` (S08) both refuse such a value, and they are right
# to: the operator has a file they can fix. A **tag** is different — its bytes
# cannot be edited, and dying here would make a rollback that used to work
# impossible over a field whose documented default is the project name. So it
# warns and falls back to that default, which is exactly what the runner does
# with a record it cannot read.
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 10.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 10.0.0 )"; rc=$?
assert '[ "$rc" = "0" ]' "a tag whose client: this kasbah refuses still rolls back (rc $rc: $out)"
assert 'grep -qF "Acme Corp" <<<"$out"' "naming the value it would not take (said '$out')"
assert 'grep -qF "falling back to '\''demo'\''" <<<"$out"' \
    "and the default it used instead (said '$out')"
assert 'grep -qF "'\''/apps'\'' '\''/apps/data'\'' '\''demo'\'' '\''demo'\''" "$ssh_log"' \
    "which is what the prepare step was handed (ssh saw: $(grep -F "/apps/data" "$ssh_log"))"
# The paired refusal, one command over: the same value in the working tree's
# manifest is a hard failure, because there the file can be fixed.
badclient="$tmpdir/badclient"
rm -rf "$badclient"; cp -R "$project" "$badclient"
sed -i 's|^client: beta-corp$|client: Acme Corp|' "$badclient/kasbah.yml"
out="$( cd "$badclient" && kasbah_run deploy deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "the same value in the working tree fails a deploy (rc $rc: $out)"
assert 'grep -qF "kasbah.yml: client '\''Acme Corp'\''" <<<"$out"' \
    "naming the file the operator can fix (said '$out')"

# --- A version with no fragment ------------------------------------------------------
# v1.0.0 carries one, so the case is constructed by asking for a tag that does
# not: HEAD's own, with the file removed from the ref by a fourth tag.
(
    cd "$project" || exit 1
    git rm -q --cached traefik-dynamic.yml
    git commit -qm "the commit v5.0.0 tags, with no fragment"
    git tag v5.0.0
    git reset -q --hard v2.0.0
) >/dev/null 2>&1
out="$( FAKE_ACTIVE=$'2026-08-02T00:00:00+00:00 deploy 5.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-03T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n' \
        rollback deploy@vps 5.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "a version with no traefik-dynamic.yml is rolled back to anyway (rc $rc: $out)"
assert 'grep -qF "v5.0.0 carries no traefik-dynamic.yml" <<<"$out"' "with a warning (said '$out')"
assert '! grep -qF "/dynamic/demo.yml" <<<"$calls"' \
    "nothing at all was sent to the dynamic directory ($(grep -F "dynamic/" <<<"$calls"))"
assert 'grep -qF "left as it is" <<<"$out"' \
    "and the route already there is left alone — removing one is \`kasbah drop\`'s decision (said '$out')"
rm -rf "$project/.kasbah"

# --- `kasbah deploy X.Y.Z` — the same path, two differences --------------------------
# It is not in this server's record at all, which a rollback would refuse and a
# deploy must not: deploying a tagged version for the first time is the point.
out="$( FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing deploy deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "deploying a tagged version this server has never run succeeds (rc $rc: $out)"
assert '[ "$(ran)" = "deploy 1.0.0" ]' \
    "in deploy mode, so the log entry and the hook pair are the deploy ones (ran: $(ran))"
assert '[ "$(jq -c .pre "$spec_copy")" = "[]" ] || [ "$(jq -c .pre "$spec_copy")" = "null" ]' \
    "v1.0.0 has no pre-deploy hooks, so its pre-rollback ones are not what was sent ($(jq -c .pre "$spec_copy" 2>/dev/null))"
assert '! grep -qF "'"'"'vlog'"'"'" <<<"$calls"' \
    "and the deploy record was not even read — there is no precondition on it
        ($(grep -F "vlog" <<<"$calls"))"
assert 'grep -qF "Deployed demo 1.0.0 to deploy@vps" <<<"$out"' "and it reports a deploy (said '$out')"
# Same ref, same invariant: the files are v1.0.0's here too.
assert '! grep -qF "extra.txt" <<<"$calls"' "shipping v1.0.0's sync list, not HEAD's"
assert '[ -f "$frag_copy" ] && grep -qF "fragment at v1.0.0" "$frag_copy"' \
    "and v1.0.0's fragment (got '$(cat "$frag_copy" 2>/dev/null)')"
rm -rf "$project/.kasbah"

# --- The image check counts what it looked at ---------------------------------------
# `missing=` computed over fewer images than were asked about is an empty answer
# that looks like a pass.
out="$( CHECKED_OVERRIDE=1 rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "an image check that looked at fewer images than it was given fails (rc $rc: $out)"
assert 'grep -qF "looked at 1 of demo'\''s 2 built images" <<<"$out"' \
    "naming both counts (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"

# --- A named version is judged locally before anything is connected to ---------------
# `kasbah deploy USER@HOST X.Y.Z` has no question for the server to answer first,
# so it keeps the no-args deploy's rule: every fact about this checkout is
# settled before the first ssh.
out="$( deploy deploy@vps 7.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "deploying a version with no tag here fails (rc $rc: $out)"
assert 'grep -qF "is not a tag in this repository" <<<"$out"' "on the tag (said '$out')"
assert '[ ! -s "$ssh_log" ]' \
    "and never opened a connection — a rollback cannot do this, because its target is a fact
        only the server has (ssh saw: $(cat "$ssh_log"))"
out="$( deploy deploy@vps 9.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "and so does one whose tag lists paths of the wrong kind (rc $rc: $out)"
assert '[ ! -s "$ssh_log" ]' "also before any connection (ssh saw: $(cat "$ssh_log"))"

# --- What the operator is told to run next -------------------------------------------
# The two late failures are where an operator reads most carefully, and `kasbah
# deploy` is a runnable instruction that ships the working tree — undoing the
# rollback that just succeeded.
out="$( SYNC_FAIL_FRAGMENT=1 rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "a fragment that will not ship fails the run (rc $rc: $out)"
assert 'grep -qF "the rollback itself succeeded" <<<"$out"' \
    "saying which run succeeded (said '$out')"
assert 'grep -qF "re-run \`kasbah rollback deploy@vps 1.0.0\`" <<<"$out"' \
    "and naming the command that repeats it, version and all (said '$out')"
assert '! grep -qE "re-run \`kasbah deploy" <<<"$out"' \
    "never \`kasbah deploy\`, which would ship the working tree and undo the rollback (said '$out')"
assert '! grep -qF "404 if it is a first deploy" <<<"$out"' \
    "and the sentence about what the host serves meanwhile is not the one for a first deploy,
        which a rollback cannot be — the target had to be in the record to get here (said '$out')"
assert 'grep -qF "the route the run before this one left" <<<"$out"' \
    "it describes the route that is actually still up (said '$out')"
rm -rf "$project/.kasbah"

out="$( REPORT_OMIT=digest rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "a truncated report fails the run (rc $rc: $out)"
assert 'grep -qF "the rollback step on deploy@vps reported no digest" <<<"$out"' \
    "naming the step that ran (said '$out')"
assert 'grep -qF "re-run \`kasbah rollback deploy@vps 1.0.0\` — it is safe to run again" <<<"$out"' \
    "and the command to repeat, not one that would deploy HEAD over it (said '$out')"

out="$( SYNC_FAIL_FRAGMENT=1 FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing deploy deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "the same failure in tagged-deploy mode fails too (rc $rc: $out)"
assert 'grep -qF "re-run \`kasbah deploy deploy@vps 1.0.0\`" <<<"$out"' \
    "and names the version there too — \`kasbah deploy\` alone is a different command (said '$out')"
assert 'grep -qF "404 if it is a first deploy" <<<"$out"' \
    "and there the first-deploy 404 is the right sentence, which is the control for the run above
        (said '$out')"

# --- The command line ----------------------------------------------------------------
# An argument with an `@` is the server, anything else is the version, in either
# order — the rule `kasbah exec` already uses.
out="$( rollback 1.0.0 deploy@vps )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "version before server parses the same way (rc $rc: $out)"
assert '[ "$(ran)" = "rollback 1.0.0" ]' \
    "with the same target (ran: $(ran))"
assert 'grep -qF "deploy@vps" <<<"$calls"' "and the same server"
rm -rf "$project/.kasbah"

# With the server remembered, the version alone is the whole command line.
out="$( rollback deploy@vps 1.0.0 )" >/dev/null
out="$( rollback 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "\`kasbah rollback 1.0.0\` uses the remembered server (rc $rc: $out)"
assert 'grep -qF "deploy@vps" <<<"$calls"' "which is the one state.json holds"
rm -rf "$project/.kasbah"

out="$( rollback deploy@vps other@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "two servers is a refusal (rc $rc: $out)"
assert 'grep -qF "two servers given" <<<"$out"' "saying which two (said '$out')"
out="$( rollback deploy@vps 1.0.0 2.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "and so is two versions (rc $rc: $out)"
assert 'grep -qF "two versions given" <<<"$out"' "saying which two (said '$out')"

out="$( rollback deploy@vps v1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "the tag spelling is refused rather than guessed at (rc $rc: $out)"
assert 'grep -qF "kasbah rollback 1.0.0" <<<"$out"' "showing the form that works (said '$out')"
assert '[ ! -s "$ssh_log" ]' "before any connection (ssh saw: $(cat "$ssh_log"))"
out="$( rollback deploy@vps 1.2 )"; rc=$?
assert '[ "$rc" != "0" ]' "and so is a version that is not semver (rc $rc: $out)"
assert 'grep -qF "1.2" <<<"$out"' "quoting it back (said '$out')"

out="$( rollback --help )"; rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah rollback --help\` exits 0 (rc $rc)"
for flag in --on-drift --skip-hooks --no-health-wait --allow-stopped; do
    assert 'grep -qF -- "$flag" <<<"$out"' "and lists $flag (said '$out')"
done

# The three passthrough flags, which the engine takes in rollback mode
# too — `--allow-stopped` above all, since its own refusal is the one an operator
# meets when the stack they are rolling back is the stack that fell over.
for flag in --skip-hooks --no-health-wait --allow-stopped; do
    out="$( rollback deploy@vps 1.0.0 "$flag" )"; rc=$?
    calls="$(<"$call_log")"
    assert '[ "$rc" = "0" ]' "\`kasbah rollback $flag\` succeeds (rc $rc: $out)"
    key="$(tr -- '-' '_' <<<"${flag#--}")"
    assert '[ "$(jq -r ".$key" "$spec_copy")" = true ]' \
        "and $flag reaches the engine's spec as $key (spec: $(cat "$spec_copy" 2>/dev/null))"
    rm -rf "$project/.kasbah"
done
out="$( rollback deploy@vps 1.0.0 )"; calls="$(<"$call_log")"
assert '[ "$(jq -c "[.skip_hooks, .no_health_wait, .allow_stopped]" "$spec_copy")" = "[false,false,false]" ]' \
    "and none of them travels when none was asked for (spec: $(cat "$spec_copy" 2>/dev/null))"
rm -rf "$project/.kasbah"

out="$( cd "$tmpdir" && kasbah_run rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" = "2" ]' "rollback outside a project exits 2 (rc $rc: $out)"
assert 'grep -qF "No kasbah.yml" <<<"$out"' "naming the file it wanted (said '$out')"
assert '[ ! -s "$ssh_log" ]' "and never opened a connection (ssh saw: $(cat "$ssh_log"))"

out="$( rollback 1.0.0 )"; rc=$?
assert '[ "$rc" = "1" ]' "no server and no state is a plain failure (rc $rc: $out)"
assert 'grep -qF "last_server" <<<"$out"' "naming the field that would have answered (said '$out')"

# --- The env step, which a rollback runs exactly as a deploy does ---------------------
# v<target>'s .env.prod.example may declare different keys from the one on the
# server, and .env is not in git — so the standard drift question is the only
# thing that can answer for it.
out="$( ENV_MISSING=NEW_KEY rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "5" ]' "a drifting .env with no terminal and no flag stops the rollback with 5 (rc $rc: $out)"
assert 'grep -qF -- "--on-drift" <<<"$out"' "naming the flag that would have answered (said '$out')"
assert '[ -z "$(ran)" ]' "and nothing ran on the server"
assert '! grep -qF "/dynamic/demo.yml" <<<"$calls"' "and no route was written"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and no state was recorded"

out="$( ENV_MISSING=NEW_KEY rollback deploy@vps 1.0.0 --on-drift=continue )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "--on-drift=continue rolls back anyway (rc $rc: $out)"
assert 'grep -qF "'"'"'setup-env'"'"' '"'"'inject'"'"'" <<<"$calls"' "and still refreshes the KASBAH_* block"
rm -rf "$project/.kasbah"

# --- The report is the completion marker here too --------------------------------------
out="$( REPORT_OMIT=deployed_before rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a report missing deployed_before fails the rollback (rc $rc: $out)"
assert 'grep -qF "the rollback step on deploy@vps reported no deployed_before" <<<"$out"' \
    "with the protocol's own sentence, naming the step that was actually run — \`the deploy
        step\` during a rollback is a sentence about a command nobody ran (said '$out')"
assert '! grep -qF "unbound variable" <<<"$out"' "and no unbound-variable crash (said '$out')"
assert '! grep -qF "/dynamic/demo.yml" <<<"$calls"' \
    "and no route was written for a run that cannot be shown to have finished"
assert '[ ! -f "$project/.kasbah/state.json" ]' "and no state was recorded"

out="$( REPORT_VERSION=9.9.9 rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "a report naming another version fails the rollback (rc $rc: $out)"
assert 'grep -qF "9.9.9" <<<"$out" && grep -qF "1.0.0" <<<"$out"' \
    "quoting both what it said and what it was asked for (said '$out')"

# A remote step that failed has already retagged :current — the retag runs before
# `compose up` and versions.log records only runs that finished, so nothing on
# the server says the tag moved.
out="$( REMOTE_RC=1 rollback deploy@vps 1.0.0 )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a remote step that fails fails the rollback (rc $rc: $out)"
assert 'grep -qF "may already carry :current" <<<"$out"' \
    "and says the tag may have moved regardless (said '$out')"
assert '! grep -qF "/dynamic/demo.yml" <<<"$calls"' "with no route written"

out="$( REMOTE_RC=1 FAKE_ACTIVE= FAKE_ACTIVE_STATE=missing deploy deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" != "0" ]' "the same failure in deploy mode fails too (rc $rc: $out)"
assert 'grep -qF "may already carry :current" <<<"$out"' "and carries the same warning (said '$out')"
assert 'grep -qF "kasbah rollback deploy@vps" <<<"$out"' \
    "naming the command that puts the tag back, which only a deploy can be told (said '$out')"

# --- The changelog a rollback prints ----------------------------------------------------
# The range runs the other way round: what the server was running, back to what it
# runs now, is what this rollback gave up.
out="$( rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" = "0" ]' "the rollback that reports prev=2.0.0 succeeds (rc $rc: $out)"
assert 'grep -qF "gave up: v1.0.0..v2.0.0" <<<"$out"' \
    "and names the range it gave up, from the server's own report (said '$out')"
assert 'grep -qF "the commit v2.0.0 tags" <<<"$out"' "listing the commit inside it (said '$out')"
assert '! grep -qF "the commit v1.0.0 tags" <<<"$out"' \
    "and not the one before it — a range, not a log (said '$out')"
rm -rf "$project/.kasbah"

out="$( REPORT_PREV= REPORT_HISTORY=no rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" = "0" ]' "a server reporting no history at all still finishes the rollback (rc $rc: $out)"
assert 'grep -qF "the two disagree" <<<"$out"' \
    "and says so: this rollback'\''s target came out of that server'\''s record, so a server with
        no history contradicts a fact this run already established (said '$out')"
rm -rf "$project/.kasbah"

out="$( REPORT_PREV=1.0.0 rollback deploy@vps 1.0.0 )"; rc=$?
assert '[ "$rc" = "0" ]' "rolling back to the version already running succeeds (rc $rc: $out)"
assert 'grep -qF "was already running 1.0.0" <<<"$out"' \
    "and says there was nothing to give up (said '$out')"
rm -rf "$project/.kasbah"

# --- The mail claim, on the rollback path ---------------------------------------------
# A rollback reads and reconciles the mail claim exactly as `deploy` does, and
# the manifest it reads it out of is **v<target>'s**, not HEAD's. A
# tag whose manifest claims mail is the only way to see that.
(
    cd "$project" || exit 1
    write_v1
    cat >> kasbah.yml <<'YML'
mail:
  domain: shop.demo.test
YML
    git add -A >/dev/null
    git commit -qm 'v6: a manifest that claims mail'
    git tag v6.0.0
) || { echo "  FAIL: could not tag v6.0.0" >&2; fail=1; }

# 6.0.0 has to be in the server's record: a rollback only ever goes to a version
# that server has run.
log_mail=$'2026-08-01T00:00:00+00:00 deploy 6.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'

registry_with=$(printf 'name: mail\nprimary_domain: demo.test\ndomains:\n  - demo.test\n  - shop.demo.test\n' | openssl base64 -A)
registry_without=$(printf 'name: mail\nprimary_domain: demo.test\ndomains:\n  - demo.test\n' | openssl base64 -A)

out="$( MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
        FAKE_ACTIVE="$log_mail" rollback deploy@vps 6.0.0 )"; rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a rollback to a version that claims mail succeeds (rc $rc: $out)"
assert 'grep -qF "'"'"'deploy'"'"' '"'"'mail'"'"' '"'"'/apps'"'"'" <<<"$calls"' \
    "and the claim step ran ($(grep -F "'mail'" <<<"$calls"))"
assert 'grep -qF "shop.demo.test is served by the stack" <<<"$out"' \
    "reconciled against the registry (said '$out')"
rm -rf "$project/.kasbah"

out="$( MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_without" \
        FAKE_ACTIVE="$log_mail" rollback deploy@vps 6.0.0 )"; rc=$?
assert '[ "$rc" = "0" ]' "an unmet claim does not stop a rollback either (rc $rc: $out)"
assert 'grep -qF "does not serve it" <<<"$out"' "and warns (said '$out')"
rm -rf "$project/.kasbah"

# --- The pre-seed comes out of the tag, not out of the working tree ------------------
# Everything else a rollback reads is v<target>'s: the manifest, the compose
# file, the sync list, the fragment. snappymail_domain: is the one path the
# claim step opens as a *file*, relative to the project root — so without the
# extraction this ships today's bytes for a version that declared different ones.
(
    cd "$project" || exit 1
    write_v1
    mkdir -p mail
    printf 'FROM-THE-TAG\n' > mail/seed.json
    cat >> kasbah.yml <<'YML'
mail:
  domain: shop.demo.test
  snappymail_domain: ./mail/seed.json
YML
    git add -A >/dev/null
    git commit -qm 'v11: a manifest that claims mail and names a pre-seed'
    git tag v11.0.0
    # The working tree moves on. Copy-if-missing means the wrong bytes here are
    # the ones that would stay on the server.
    printf 'FROM-THE-WORKING-TREE\n' > mail/seed.json
) || { echo "  FAIL: could not tag v11.0.0" >&2; fail=1; }

log_seed=$'2026-08-01T00:00:00+00:00 deploy 11.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'

out="$( MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
        FAKE_ACTIVE="$log_seed" rollback deploy@vps 11.0.0 )"; rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a rollback to a version naming a pre-seed succeeds (rc $rc: $out)"
assert '[ "$(cat "$seed_copy" 2>/dev/null)" = "FROM-THE-TAG" ]' \
    "and the bytes that travel are the tag's (sent: $(cat "$seed_copy" 2>/dev/null))"
assert '! grep -qF "FROM-THE-WORKING-TREE" "$seed_copy" 2>/dev/null' \
    "not the working tree's — which is what a rollback exists to avoid"
assert '! grep -qF "there is no such file in this checkout" <<<"$out"' \
    "and nothing is looked for in the checkout at all (said '$out')"
rm -rf "$project/.kasbah"

# The same rollback with the file gone from the working tree entirely. Before
# the extraction this reported the version's own pre-seed as missing.
mv "$project/mail/seed.json" "$tmpdir/seed.json.aside"
out="$( MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
        FAKE_ACTIVE="$log_seed" rollback deploy@vps 11.0.0 )"; rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a working tree with no copy of the file rolls back fine (rc $rc: $out)"
assert '[ "$(cat "$seed_copy" 2>/dev/null)" = "FROM-THE-TAG" ]' "the tag's bytes still travel"
assert '! grep -qF "there is no such file in this checkout" <<<"$out"' \
    "and no warning about a checkout this run never reads (said '$out')"
mv "$tmpdir/seed.json.aside" "$project/mail/seed.json"
rm -rf "$project/.kasbah"

# A version that names a pre-seed it does not carry. A warning naming the ref —
# never the checkout — and no seed step at all.
(
    cd "$project" || exit 1
    write_v1
    cat >> kasbah.yml <<'YML'
mail:
  domain: shop.demo.test
  snappymail_domain: ./mail/never-committed.json
YML
    git add -A >/dev/null
    git commit -qm 'v12: names a pre-seed the tag does not carry'
    git tag v12.0.0
) || { echo "  FAIL: could not tag v12.0.0" >&2; fail=1; }
log_noseed=$'2026-08-01T00:00:00+00:00 deploy 12.0.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n'
printf 'FROM-THE-WORKING-TREE\n' > "$project/mail/never-committed.json"
out="$( MAIL_STACK=yes MAIL_ENV=yes MAIL_REGISTRY_B64="$registry_with" \
        FAKE_ACTIVE="$log_noseed" rollback deploy@vps 12.0.0 )"; rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a version naming a pre-seed it does not carry still rolls back (rc $rc: $out)"
assert 'grep -qF "v12.0.0 does not carry that file" <<<"$out"' \
    "saying so against the ref (said '$out')"
assert '! grep -qF "'"'"'seed'"'"'" <<<"$calls"' \
    "and no seed step runs ($(grep -F "seed" <<<"$calls"))"
assert '[ ! -e "$seed_copy" ]' \
    "least of all with the untracked file sitting right there in the tree"
rm -f "$project/mail/never-committed.json"
rm -rf "$project/.kasbah"

# The control: v1.0.0's manifest has no mail: block, so rolling back to it looks
# for no mail stack at all.
out="$( MAIL_STACK=yes MAIL_ENV=yes rollback deploy@vps 1.0.0 )"; rc=$?
calls=$(<"$call_log")
assert '[ "$rc" = "0" ]' "a rollback to a version with no mail: block succeeds (rc $rc: $out)"
assert '! grep -qF "'"'"'deploy'"'"' '"'"'mail'"'"'" <<<"$calls"' \
    "and never looks for a mail stack ($(grep -F "'mail'" <<<"$calls"))"
rm -rf "$project/.kasbah"

exit "$fail"
