#!/usr/bin/env bash
# Test: lib/upgrade_traefik.sh — `kasbah server upgrade-traefik`, everything
# that does not need a server.
#
# Five layers, because the command has five:
#   * the pure parts — the flag grammar, and the Docker-tag check that stands
#     between a user-supplied string and both a YAML scalar and a `docker run`
#     argument;
#   * `_si_extract_image`, the fourth value a re-render reproduces off the
#     server, driven straight through the library it lives in;
#   * the stack read, extracted from its heredoc and run against a fake apps
#     tree with a stub docker;
#   * **the dry-run payload, which is the command**, extracted and driven with a
#     stub docker that replays real Traefik logs captured off the rig. That is
#     where "what counts as a config error" is fixed, and where the pairing
#     lives: every "this was not treated as an error" has a positive beside it
#     that would fire if the classifier stopped reading altogether;
#   * the start payload, whose rollback is the difference between a failed
#     upgrade and a dark server, and the command itself through bin/kasbah with
#     a stub ssh — which is what fixes the **ordering**: nothing is backed up,
#     shipped or restarted when the dry run says no.
#
# **A dry run is a negative assertion by construction** — it passes by saying
# nothing — so every case below that expects a pass also pins that the run
# *saw* something: the router set the throwaway reports is the same evidence the
# command requires before it will believe a clean verdict. A classifier that
# read an empty log would fail both halves, which is the point (docs/phases/
# 07-operate.md → 7.5).
#
# The rig-driven half — a real version bump against a real proxy, and a real
# broken fragment failing it — is in tests/integration/upgrade_traefik_test.sh.

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

if ! command -v yq >/dev/null || ! command -v openssl >/dev/null; then
    echo "error: this suite needs yq and openssl" >&2
    exit 2
fi

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

# --- Driver -------------------------------------------------------------------------
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like bin/kasbah: a helper that dies under errexit before its caller
# can decide what the failure means is a defect this driver reproduces.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/upgrade_traefik.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _server_upgrade_traefik_parse_args "$@"
        printf 'target=%s\nversion=%s\n' "$_UT_TARGET" "$_UT_VERSION"
        ;;
    image)
        content="$(cat)"
        img=""
        if _si_extract_image "$content" img; then printf 'image=[%s]\n' "$img"
        else printf 'image=refused\n'; fi
        ;;
esac
DRV
drive() { bash "$driver" "$@" 2>&1; echo "rc=$?"; }

# --- The flag grammar -------------------------------------------------------------------
out=$(drive parse deploy@vps --version=v3.7.10)
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is the positional argument (got '$out')"
assert 'grep -qxF "version=v3.7.10" <<<"$out"'   "and --version= carries the tag (got '$out')"

# There is no default version and no prompt for one: the command exists to
# change the tag, and a run that guessed which one would be a version bump
# nobody asked for.
out=$(drive parse deploy@vps)
assert 'grep -qxF "rc=1" <<<"$out"' "without --version the run refuses (got '$out')"
assert 'grep -qF -- "--version=<tag> is required" <<<"$out"' "and names the flag (got '$out')"
out=$(drive parse --version=v3.7.10)
assert 'grep -qxF "rc=1" <<<"$out"' "and without a target too (got '$out')"
out=$(drive parse deploy@vps --version)
assert 'grep -qF "needs a value" <<<"$out"' "--version without '=' is refused, not read as the target (got '$out')"
out=$(drive parse deploy@vps other@vps --version=v3.7.10)
assert 'grep -qF "given once" <<<"$out"' "a second target is refused (got '$out')"
out=$(drive parse deploy@vps --apps-path=/srv --version=v3.7.10)
assert 'grep -qF "unknown flag" <<<"$out"' \
    "there is no --apps-path here either — the apps path is the server's own answer (got '$out')"

# The tag reaches a YAML scalar and a `docker run` argument. Docker's own
# grammar is the check, so everything that could end the scalar or smuggle a
# second word is refused at the flag rather than in the renderer.
for bad in 'v3 7' 'v3"7' "v3'7" 'v3\$(id)' 'v3`id`' '-v3.7' '.v3.7' 'v3.7;rm' 'reg.io/traefik:v3' 'traefik:v3.7' 'v3.7
extra'; do
    out=$(drive parse deploy@vps --version="$bad")
    assert 'grep -qxF "rc=1" <<<"$out"' "--version='$bad' is refused (got '$out')"
done
# And the positive beside it: the shapes a real Traefik tag takes are accepted,
# so the check above is a grammar and not a blanket refusal.
for good in v3.7.10 v3 3.7.10 latest v3.7.10-rc1 v3.7 experimental-v3.8; do
    out=$(drive parse deploy@vps --version="$good")
    assert 'grep -qxF "version=$good" <<<"$out"' "--version=$good is accepted (got '$out')"
done

# --- The fourth recovered value ---------------------------------------------------------
#
# `server init` renders the image tag the server already runs rather than this
# kasbah's pin, which is the only thing that stops the next init undoing a
# managed upgrade. Narrow on purpose: the value is substituted into a YAML
# scalar, and a compose.yml is a file an operator can write anything into.
img_doc() { printf 'services:\n  traefik:\n    image: %s\n' "$1"; }
out=$(img_doc 'traefik:v3.6.7' | drive image)
assert 'grep -qxF "image=[traefik:v3.6.7]" <<<"$out"' "the tag on the server is reproduced (got '$out')"
out=$(img_doc 'traefik:v3.7.10' | drive image)
assert 'grep -qxF "image=[traefik:v3.7.10]" <<<"$out"' "including this kasbah's own pin (got '$out')"
# The pairing: same document shape, one field different, and the answer is empty
# — which the caller reads as "fall back to KASBAH_TRAEFIK_IMAGE and say so".
for weird in 'mirror.example/traefik:v3.7.10' 'traefik@sha256:abc' 'traefik' 'nginx:alpine' 'traefik:v3 7'; do
    out=$(img_doc "$weird" | drive image)
    assert 'grep -qxF "image=[]" <<<"$out"' "'$weird' is not a tag kasbah reproduces (got '$out')"
done
out=$(printf 'services:\n  other:\n    image: x\n' | drive image)
assert 'grep -qxF "image=[]" <<<"$out"' "a compose.yml with no traefik service yields nothing (got '$out')"
out=$(printf 'services: [\n' | drive image)
assert 'grep -qxF "image=refused" <<<"$out"' \
    "and one that does not parse is refused, not read as absent (got '$out')"

# --- The payloads, extracted ---------------------------------------------------------------
extract() {
    awk -v want="$1" '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next}
        inb && /^REMOTE$/{if (buf ~ want) printf "%s", buf; inb=0; next}
        inb{buf = buf $0 "\n"}' "$repo_dir/lib/upgrade_traefik.sh"
}
read_payload="$tmpdir/read.sh";   extract 'fragments_b64=' > "$read_payload"
dry_payload="$tmpdir/dry.sh";     extract 'dry_verdict='   > "$dry_payload"
backup_payload="$tmpdir/backup.sh"; extract 'backup_dir='  > "$backup_payload"
start_payload="$tmpdir/start.sh"; extract 'up_rolled_back=' > "$start_payload"
for p in read dry backup start; do
    f="$tmpdir/$p.sh"
    assert '[ -s "$f" ]' "the $p step was extracted from lib/upgrade_traefik.sh"
done
assert 'grep -qF "docker run -d" "$dry_payload"' \
    "and the dry-run block is the one that boots the throwaway — every case below is theatre otherwise"

# --- The stack read ------------------------------------------------------------------------
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
    *"compose -p traefik ps -a -q traefik") printf 'cid-traefik\n'; exit 0 ;;
    *"{{.State.Status}}"*)  printf 'running\n'; exit 0 ;;
    *"State.Health"*)       printf 'healthy\n'; exit 0 ;;
    *"{{.Config.Image}}"*)  printf 'traefik:v3.7.10\n'; exit 0 ;;
esac
exit 2
STUB
chmod 0755 "$stub_dir/docker"

apps="$tmpdir/apps"; data="$apps/data"
mkdir -p "$apps/traefik/dynamic" "$data/traefik/letsencrypt"
printf 'services:\n  traefik:\n    image: traefik:v3.7.10\n' > "$apps/traefik/compose.yml"
printf 'log:\n  level: INFO\n'                                > "$apps/traefik/traefik.yml"
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/_shared.yml"
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/_mail.yml"
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/gallery.yml"
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/legacy.toml"
# Neither of these is a file the provider reads, and both are things that end up
# in that directory: an editor's leftover, and a backup somebody made by hand.
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/gallery.yml.bak"
printf 'http: {}\n'                                           > "$apps/traefik/dynamic/notes.txt"
mkdir -p "$apps/traefik/dynamic/subdir"
printf '{"real":"store"}\n'                                   > "$data/traefik/letsencrypt/acme.json"

read_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG="$tmpdir/docker.log" \
    bash "$read_payload" "$apps" "$data" traefik 2>&1)
read_rc=$?
fact() { sed -n "s/^$1=//p" <<<"$read_out"; }
assert '[ "$read_rc" = 0 ]' "the stack read exits 0 (rc=$read_rc: $read_out)"
frags=$(base64 -d <<<"$(fact fragments_b64)" | LC_ALL=C sort | tr '\n' ' ')
assert '[ "$frags" = "_mail.yml _shared.yml gallery.yml legacy.toml " ]' \
    "it enumerates exactly the extensions Traefik's file provider reads (got '$frags')"
assert '[ "$(fact acme_state)" = nonempty ]' "a store with bytes in it reads nonempty (got '$(fact acme_state)')"
assert '[ "$(fact acme_digest)" = "$(openssl dgst -sha256 -r < "$data/traefik/letsencrypt/acme.json" | cut -d" " -f1)" ]' \
    "and comes back as its digest — the before half of 'the certificates survived' (got '$(fact acme_digest)')"
assert '[ "$(base64 -d <<<"$(fact traefik_compose_b64)")" = "$(cat "$apps/traefik/compose.yml")" ]' \
    "the three kasbah-owned files come back whole"
assert '[ "$(fact traefik_running_image)" = traefik:v3.7.10 ]' "and the image the live container runs (got '$(fact traefik_running_image)')"

# Read-only, digested rather than taken on trust — including acme.json, which
# this command must never write.
before=$(cd "$apps" && find . -printf '%p %s %T@ %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
env -i PATH="$stub_dir:/usr/bin:/bin" bash "$read_payload" "$apps" "$data" traefik >/dev/null 2>&1
after=$(cd "$apps" && find . -printf '%p %s %T@ %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
assert '[ "$before" = "$after" ]' "the stack read changes nothing under the apps path"
verbs=$(sed 's/^\([a-z]*\) \([a-z-]*\).*/\1 \2/' "$tmpdir/docker.log" | LC_ALL=C sort -u)
assert '! grep -qvE "^(compose -p|inspect -f)$" <<<"$verbs"' \
    "and every docker verb in it is a read (got: $(tr "\n" "|" <<<"$verbs"))"

# --- The dry run: what counts as a config error --------------------------------------------
#
# The stub docker replays a log the suite hands it, so the classifier is driven
# over the exact lines traefik:v3.7.10 produced on the rig for each broken
# fragment — captured, not invented.
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$1" in
    ps)   [ -z "${DRY_STALE:-}" ] || printf '%s\n' $DRY_STALE; exit 0 ;;
    rm)   exit 0 ;;
    pull) [ -z "${DRY_PULL_FAIL:-}" ] || exit 1; exit 0 ;;
    run)  [ -z "${DRY_RUN_FAIL:-}" ] || exit 1; exit 0 ;;
    logs) cat "${DRY_LOG:-/dev/null}"; exit 0 ;;
    inspect)
        case "$*" in
            *State.Running*)  printf '%s\n' "${DRY_RUNNING:-true}" ;;
            *State.ExitCode*) printf '%s\n' "${DRY_EXIT:-0}" ;;
        esac
        exit 0 ;;
esac
exit 2
STUB
chmod 0755 "$stub_dir/docker"

DRY_CA="https://127.0.0.1:1/kasbah-dry-run-no-ca"
DRY_MSG="Unable to obtain ACME certificate for domains"
# One excluded line per TLS router, exactly as Traefik emits it — this is the
# shape captured off the rig, colour codes and all.
acme_line() {
    printf '\033[90m2026-08-25T19:44:21Z\033[0m \033[31mERR\033[0m \033[1m%s\033[0m error="cannot get ACME client get directory at %s: connection refused" acmeCA=%s domains=["%s"] providerName=letsencrypt.acme routerName=%s rule=Host(`%s`)\n' \
        "$DRY_MSG" "$DRY_CA" "$DRY_CA" "$2" "$1" "$2"
}
clean_log() {
    printf '2026-08-25T19:44:21Z WRN Traefik can reject some encoded characters in the request path.\n'
    printf '2026-08-25T19:44:21Z INF Traefik version 3.7.10 built on 2026-07-31T12:42:19Z\n'
    printf '2026-08-25T19:44:21Z INF Starting provider *file.Provider\n'
    printf '2026-08-25T19:44:21Z INF Testing certificate renew... acmeCA=%s\n' "$DRY_CA"
    acme_line 'traefik-dashboard@file' traefik.example.com
    acme_line 'gallery@file'           gallery.example.com
    acme_line 'mail-cert@file'         mail.example.com
}
dry_run() {
    local log="$tmpdir/dry.log"; cat > "$log"
    env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG=/dev/null DRY_LOG="$log" \
        DRY_RUNNING="${1:-true}" DRY_EXIT="${2:-0}" DRY_STALE="${3:-}" \
        bash "$dry_payload" "$apps" traefik:v3.7.10 "$(printf 'http: {}\n' | openssl base64 -A)" \
             "$(printf 'log:\n  level: INFO\n' | openssl base64 -A)" \
             kasbah.role=traefik-dry-run 20260825T000000Z "$DRY_MSG" "$DRY_CA" "${4:-6}" 2>&1
}
dfact() { sed -n "s/^$1=//p" <<<"$dry_out"; }
derrs() { base64 -d <<<"$(dfact dry_errors_b64)"; }

dry_out=$(clean_log | dry_run)
assert '[ "$(dfact dry_verdict)" = spoke ]' "a clean configuration reaches a verdict (got '$(dfact dry_verdict)')"
assert '[ -z "$(derrs)" ]' "and it holds no config errors (got '$(derrs)')"
# The positive that makes the line above mean something. These are the same
# lines the classifier just excluded: the file provider emits one per TLS router
# it built out of the mounted fragments, so they are the proof it read them.
# First-seen order, deduplicated against a seen-list: `sort -u` is not on the
# far side's prerequisites, and the order the file provider built them in is
# what the log gives.
assert '[ "$(dfact dry_routers)" = "traefik-dashboard@file gallery@file mail-cert@file " ]' \
    "and it reports every router it built out of the fragments (got '$(dfact dry_routers)')"
assert '[ -n "$(base64 -d <<<"$(dfact dry_warns_b64)")" ]' \
    "the deprecation warning is reported, not swallowed"

# A log with nothing in it at all: no errors — and no routers either, which is
# the half the command refuses on. Without this pair, "no errors" is a pass a
# dry run could reach by reading an empty directory.
dry_out=$(printf '2026-08-25T19:44:21Z INF Starting provider *file.Provider\n' | dry_run true 0 '' 3)
assert '[ "$(dfact dry_verdict)" = timeout ]' \
    "a throwaway that never speaks times out rather than passing (got '$(dfact dry_verdict)')"
assert '[ -z "$(dfact dry_routers)" ]' "and reports no routers (got '$(dfact dry_routers)')"

# Every shape traefik:v3.7.10 was measured to produce on the rig, one per broken
# fragment. Each must land in the error set.
declare -A broken=(
  [unparseable-yaml]='2026-08-25T19:44:15Z ERR Cannot start the provider *file.Provider error="collecting file configs: /etc/traefik/dynamic/p.yml: yaml: line 2: did not find expected '"'"','"'"' or '"'"']'"'"'"'
  [unknown-field]='2026-08-25T19:44:27Z ERR Cannot start the provider *file.Provider error="collecting file configs: /etc/traefik/dynamic/p.yml: field not found, node: nosuchfield"'
  [missing-middleware]='2026-08-25T19:44:21Z ERR error="middleware \"nope@file\" does not exist" entryPointName=websecure routerName=a@file'
  [unparseable-rule]='2026-08-25T19:44:34Z ERR error="invalid rule Hostx(`a.test`, error: missing '"'"','"'"' before newline" entryPointName=websecure routerName=a@file'
  [unknown-resolver]='2026-08-25T19:44:40Z ERR Router uses a nonexistent certificate resolver certificateResolver=nosuch routerName=a@file'
  [unknown-entrypoint]='2026-08-25T19:44:46Z ERR EntryPoint doesn'"'"'t exist entryPointName=nosuchep routerName=a@file'
)
for case_name in "${!broken[@]}"; do
    dry_out=$( { clean_log; printf '%s\n' "${broken[$case_name]}"; } | dry_run)
    assert '[ -n "$(derrs)" ]' "$case_name is a config error (got '$(derrs)')"
    assert '[ "$(wc -l <<<"$(derrs)")" = 1 ]' \
        "and it is the only one — the ACME noise around it is not counted (got '$(derrs)')"
done

# The exclusion is anchored on *both* the message and the loopback URL this run
# chose, so it cannot cover a certificate error from anywhere else. Same line,
# one field different.
dry_out=$( { clean_log
    printf '2026-08-25T19:44:21Z ERR %s error="urn:acme:rateLimited" acmeCA=https://acme-v02.api.letsencrypt.org/directory domains=["x.test"] routerName=x@file\n' "$DRY_MSG"
  } | dry_run)
assert '[ -n "$(derrs)" ]' \
    "an ACME error naming a CA that is not the dry run's own is a config error (got '$(derrs)')"
assert '! grep -qF "x@file" <<<"$(dfact dry_routers)"' \
    "and does not count as evidence the fragments were read (got '$(dfact dry_routers)')"

# A throwaway that died instead of loading anything.
dry_out=$(printf '2026-08-25T19:44:21Z INF Traefik version 3.7.10\n' | dry_run false 1 '' 6)
assert '[ "$(dfact dry_verdict)" = exited ]' "a throwaway that exited is not a pass (got '$(dfact dry_verdict)')"
assert '[ "$(dfact dry_exitcode)" = 1 ]' "and its exit code comes back (got '$(dfact dry_exitcode)')"

# Whatever a crashed run left behind is swept by label before this one starts.
dry_out=$(clean_log | dry_run true 0 'old-a old-b')
assert '[ "$(dfact dry_swept)" = 2 ]' "leftover throwaways are swept by label (got '$(dfact dry_swept)')"

# The isolation, read off the argv the payload actually built. The live Traefik
# holds :80 and :443 for every site on the box.
: > "$tmpdir/docker.log"
clean_log > "$tmpdir/dry.log"
env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG="$tmpdir/docker.log" DRY_LOG="$tmpdir/dry.log" \
    bash "$dry_payload" "$apps" traefik:v3.7.10 "$(printf 'http: {}\n' | openssl base64 -A)" \
         "$(printf 'log:\n  level: INFO\n' | openssl base64 -A)" \
         kasbah.role=traefik-dry-run 20260825T000000Z "$DRY_MSG" "$DRY_CA" 6 >/dev/null 2>&1
runline=$(grep '^run ' "$tmpdir/docker.log")
assert 'grep -qF -- "--network none" <<<"$runline"' \
    "the throwaway has no network at all — no CA, no backend, nothing reaches it (got '$runline')"
assert '! grep -qE "(^| )-p( |$)" <<<"$runline"' \
    "and publishes no port: :80 and :443 belong to the live proxy (got '$runline')"
assert 'grep -qF "$apps/traefik/dynamic:/etc/traefik/dynamic:ro" <<<"$runline"' \
    "the dynamic directory is mounted read-only (got '$runline')"
assert '! grep -qF "acme.json" <<<"$runline"' \
    "and acme.json is not mounted into it at all (got '$runline')"
assert 'grep -qF -- "--label kasbah.role=traefik-dry-run" <<<"$runline"' \
    "it carries the label the next run sweeps by (got '$runline')"
assert 'grep -qF -- "--name kasbah-traefik-dry-run-20260825T000000Z" <<<"$runline"' \
    "and a name carrying this run's stamp, so no two can collide (got '$runline')"
assert 'grep -qE "^pull traefik:v3.7.10" "$tmpdir/docker.log"' \
    "the target image is pulled here, before anything on the server is overwritten"
assert '[ ! -d /etc/traefik ] && [ -z "$(ls "$apps/traefik/backups" 2>/dev/null)" ]' \
    "and the dry run creates nothing under the apps path"

# --- Backup before overwrite ---------------------------------------------------------------
backup_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" \
    bash "$backup_payload" "$apps" 20260825T000000Z traefik:v3.7.10 traefik:v3.6.7 2>&1)
backup_rc=$?
bdir="$apps/traefik/backups/20260825T000000Z"
assert '[ "$backup_rc" = 0 ]' "the backup step exits 0 (rc=$backup_rc: $backup_out)"
assert 'grep -qxF "backup_dir=$bdir" <<<"$backup_out"' "and reports where it put them (got '$backup_out')"
for f in compose.yml traefik.yml _shared.yml; do
    assert '[ -f "$bdir/$f" ]' "$f is in the backup"
done
assert '[ "$(cat "$bdir/compose.yml")" = "$(cat "$apps/traefik/compose.yml")" ]' \
    "byte for byte, before anything overwrites it"
assert 'grep -qF "traefik:v3.7.10 -> traefik:v3.6.7" "$bdir/kasbah-upgrade"' \
    "and the directory says which bump it belongs to"
# Never over an existing one: a second run within the same second would
# otherwise overwrite the only copy of the bytes it is about to replace.
backup_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" \
    bash "$backup_payload" "$apps" 20260825T000000Z a b 2>&1)
assert '[ "$?" != 0 ]' "a backup directory that already exists is refused (got '$backup_out')"
assert 'grep -qF "will not write over a backup" <<<"$backup_out"' "and says so (got '$backup_out')"
# The backup is outside dynamic/, which Traefik watches: a copy left in there is
# one more file for the file provider to have an opinion about.
assert '[ ! -e "$apps/traefik/dynamic/_shared.yml.20260825T000000Z" ]' \
    "nothing is written into the watched directory"

# --- The start, and the rollback that keeps a failure from going dark -----------------------
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
    *"compose -p traefik up -d") exit 0 ;;
    *"compose -p traefik logs"*) exit 0 ;;
    *"compose -p traefik ps -a -q traefik") printf 'cid-traefik\n'; exit 0 ;;
esac
# Health is a function of what is on disk: the marker file the suite plants next
# to compose.yml decides, so a rollback that really restored the bytes really
# changes the answer.
if [ "$1" = inspect ]; then
    good=no
    ! grep -q GOOD "$UP_COMPOSE" 2>/dev/null || good=yes
    case "$*" in
        *State.Health*)  [ "$good" = yes ] && printf 'healthy\n' || printf 'unhealthy\n' ;;
        *State.Running*) printf 'true\n' ;;
        *Config.Image*)  sed -n 's/^image=//p' "$UP_COMPOSE" ;;
        *State.StartedAt*) printf '2026-08-25T00:00:00Z\n' ;;
        *State.Status*)  printf 'running\n' ;;
    esac
    exit 0
fi
exit 2
STUB
chmod 0755 "$stub_dir/docker"

start_fixture() {
    rm -rf "$apps/traefik/backups/rollback"
    mkdir -p "$apps/traefik/backups/rollback"
    printf 'GOOD\nimage=traefik:v3.7.10\n' > "$apps/traefik/backups/rollback/compose.yml"
    printf 'old static\n'                  > "$apps/traefik/backups/rollback/traefik.yml"
    printf 'old shared\n'                  > "$apps/traefik/backups/rollback/_shared.yml"
    printf '%s\nimage=traefik:v3.6.7\n' "$1" > "$apps/traefik/compose.yml"
    printf 'new static\n'                  > "$apps/traefik/traefik.yml"
    printf 'new shared\n'                  > "$apps/traefik/dynamic/_shared.yml"
}
run_start() {
    env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG=/dev/null \
        UP_COMPOSE="$apps/traefik/compose.yml" \
        bash "$start_payload" "$apps" traefik "$apps/traefik/backups/rollback" \
             "$data/traefik/letsencrypt/acme.json" 4 2>&1
}

start_fixture GOOD
start_out=$(run_start); start_rc=$?
ufact() { sed -n "s/^$1=//p" <<<"$start_out"; }
assert '[ "$start_rc" = 0 ]' "a healthy start exits 0 (rc=$start_rc: $start_out)"
assert '[ "$(ufact up_rolled_back)" = no ]' "and rolls nothing back (got '$(ufact up_rolled_back)')"
assert '[ "$(ufact up_image)" = traefik:v3.6.7 ]' "the new image is what is running (got '$(ufact up_image)')"
assert '[ "$(cat "$apps/traefik/traefik.yml")" = "new static" ]' "and the shipped files are left in place"
assert '[ "$(ufact up_acme_digest)" = "$(openssl dgst -sha256 -r < "$data/traefik/letsencrypt/acme.json" | cut -d" " -f1)" ]' \
    "acme.json comes back digested and unchanged — the after half of the pair (got '$(ufact up_acme_digest)')"

# The pairing. Same fixture, one word different in compose.yml, and the proxy
# that holds :80 for every site goes back where it was rather than staying half
# switched. Both halves are asserted on the *files*, not on the message.
start_fixture BAD
start_out=$(run_start); start_rc=$?
assert '[ "$start_rc" = 3 ]' "a start that will not come up healthy exits non-zero (rc=$start_rc: $start_out)"
assert '[ "$(ufact up_rolled_back)" = yes ]' "and says it rolled back (got '$(ufact up_rolled_back)')"
assert 'grep -q GOOD "$apps/traefik/compose.yml"' "compose.yml is the backed-up copy again"
assert '[ "$(cat "$apps/traefik/traefik.yml")" = "old static" ]' "traefik.yml too"
assert '[ "$(cat "$apps/traefik/dynamic/_shared.yml")" = "old shared" ]' "and _shared.yml, which the live proxy watches"
assert '[ "$(ufact up_image)" = traefik:v3.7.10 ]' "so the version in effect is the old one (got '$(ufact up_image)')"

# And when there is nothing to roll back to, it says that rather than claiming
# a recovery it did not make.
start_fixture BAD
rm -rf "$apps/traefik/backups/rollback"
start_out=$(run_start)
assert '[ "$(ufact up_rolled_back)" = failed ]' \
    "a rollback with no backup to read reports failed (got '$(ufact up_rolled_back)')"

# --- The command, with a stub ssh ------------------------------------------------------------
#
# What this fixes is the **ordering**. The stub records every step it is asked
# for, so "nothing was backed up" is read off the log rather than off the
# message — and is paired with a run that differs only in the dry run's verdict,
# where the backup step *is* issued.
ssh_log="$tmpdir/ssh.log"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
case "$last" in true|*"' true'"|*' true') exit 0 ;; esac
case "$*" in *"-O exit"*) exit 0 ;; esac
# rsync's transport. No stub can play the far side of the protocol, so it is
# refused outright and never read from — a `cat` here waits for a peer that is
# never going to speak. The ship step is proved on the rig instead; what this
# stub fixes is the *order* the steps are issued in.
case "$*" in *"rsync --server"*) printf 'STEP ship\n' >> "$SSH_LOG"; exit 1 ;; esac
script="$(cat)"
name=other
grep -qF "printf 'source=" <<<"$script" && name=marker
grep -qF 'fragments_b64=' <<<"$script" && name=read
grep -qF 'dry_verdict='   <<<"$script" && name=dry
grep -qF 'backup_dir='    <<<"$script" && name=backup
grep -qF 'up_rolled_back=' <<<"$script" && name=start
printf 'STEP %s\n' "$name" >> "$SSH_LOG"
[ ! -f "$SSH_REPLY_DIR/$name" ] || cat "$SSH_REPLY_DIR/$name"
[ ! -f "$SSH_REPLY_DIR/$name.rc" ] || exit "$(cat "$SSH_REPLY_DIR/$name.rc")"
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

reply="$tmpdir/reply"; mkdir -p "$reply" "$tmpdir/home"
srv="$tmpdir/server"; mkdir -p "$srv"
render() {
    sed -e "s|__APPS_PATH__|/apps|g" -e "s|__DATA_PATH__|/apps/data|g" \
        -e "s|__ACME_EMAIL__|ops@example.com|g" \
        -e "s|__ACME_CA__|https://acme-v02.api.letsencrypt.org/directory|g" \
        -e "s|__DASHBOARD_DOMAIN__|example.com|g" \
        -e "s|__DASHBOARD_AUTH__|admin:\$2y\$05\$abcdefghijklmnopqrstuv|g" \
        -e "s|__TRAEFIK_IMAGE__|$1|g" "$repo_dir/templates/traefik/$2"
}
b64file() { openssl base64 -A -in "$1"; }
set_stack() {
    render "$1" compose.yml           > "$srv/compose.yml"
    render "$1" traefik.yml           > "$srv/traefik.yml"
    render "$1" dynamic/_shared.yml   > "$srv/_shared.yml"
    {
        printf 'traefik_compose_b64=%s\n' "$(b64file "$srv/compose.yml")"
        printf 'traefik_static_b64=%s\n'  "$(b64file "$srv/traefik.yml")"
        printf 'traefik_shared_b64=%s\n'  "$(b64file "$srv/_shared.yml")"
        printf 'fragments_b64=%s\n' "$(printf '_shared.yml\ngallery.yml\n' | openssl base64 -A)"
        printf 'acme_state=nonempty\nacme_digest=deadbeef\ndocker=yes\n'
        printf 'traefik_state=running\ntraefik_health=healthy\ntraefik_running_image=%s\n' "$1"
    } > "$reply/read"
}
# lib/marker.sh's protocol: two header lines, then the marker itself.
{
    printf 'apps=/apps\nsource=default\n'
    printf '{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g"}\n'
} > "$reply/marker"
dry_reply() {
    {
        printf 'dry_swept=0\ndry_verdict=spoke\ndry_exitcode=0\n'
        printf 'dry_errors_b64=%s\n' "$(printf '%s' "${1:-}" | openssl base64 -A)"
        printf 'dry_warns_b64=\n'
        printf 'dry_routers=%s\n' "${2:-traefik-dashboard@file gallery@file }"
        printf 'dry_log_b64=%s\n' "$(printf 'log' | openssl base64 -A)"
    } > "$reply/dry"
}
printf 'backup_dir=/apps/traefik/backups/S\n' > "$reply/backup"
printf 'up_rolled_back=no\nup_health=healthy\nup_state=running\nup_image=traefik:v3.6.7\nup_started_at=t\nup_acme_digest=deadbeef\n' > "$reply/start"

cli() {
    : > "$ssh_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_REPLY_DIR="$reply" \
        "$repo_dir/bin/kasbah" server upgrade-traefik "$@" 2>&1
}
steps() { sed -n 's/^STEP //p' "$ssh_log" | tr '\n' ' '; }

# The version the server already runs, so nothing differs and nothing is
# touched — and the dry run happens anyway, because validating the fragments
# against the tag in effect is worth doing on its own.
set_stack traefik:v3.7.10
dry_reply
out=$(cli deploy@vps --version=v3.7.10); rc=$?
assert '[ "$rc" = 0 ]' "a bump to the version already in effect succeeds (rc=$rc: $out)"
assert '[ "$(steps)" = "marker read dry " ]' "and stops after the dry run — nothing to back up (got '$(steps)')"
assert 'grep -qF "nothing to ship" <<<"$out"' "saying so (got '$out')"

# Byte-identical files are not a proxy on the target version. Same reply, one
# field changed: the container is running something else, and the run goes on to
# recreate it rather than reporting success over a proxy that did not move.
sed -i 's|^traefik_running_image=.*|traefik_running_image=traefik:v3.5.3|' "$reply/read"
out=$(cli deploy@vps --version=v3.7.10)
assert 'grep -qF "STEP backup" "$ssh_log"' \
    "files that already match but a container that does not still gets recreated (steps: $(steps))"
assert 'grep -qF "recreating it" <<<"$out"' "and the run says why (got '$out')"
set_stack traefik:v3.7.10

# The pairing, from the other side: same fixture, a different tag, and the
# backup step is issued before anything is shipped. (The ship itself is rsync,
# which no stub can play; the run dies there, which is why the assertion is on
# the log and not on the status.)
out=$(cli deploy@vps --version=v3.6.7)
assert 'grep -qF "STEP backup" "$ssh_log"' "a real bump backs the three files up (steps: $(steps))"
assert '[ "$(sed -n "s/^STEP //p" "$ssh_log" | sed -n 4p)" = backup ]' \
    "after the dry run and before anything else (got '$(steps)')"

# A dry run that found a config error stops the whole thing. The negative — no
# backup, no start — is the same log read the pair above uses.
dry_reply '2026-08-25T19:44:21Z ERR error="middleware \"nope@file\" does not exist" routerName=a@file'
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "a config error fails the upgrade (rc=$rc)"
assert '[ "$(steps)" = "marker read dry " ]' \
    "and nothing is backed up, shipped or restarted (got '$(steps)')"
assert 'grep -qF "still serving" <<<"$out"' "the message says what is still running (got '$out')"
assert 'grep -qF "nope@file" <<<"$out"' "and repeats the fragment error verbatim (got '$out')"

# A dry run that reported no errors *and no dashboard router* is not a pass: it
# validated nothing. Same reply, one field emptied.
dry_reply '' 'gallery@file '
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "a dry run that never loaded the dashboard router is refused (rc=$rc: $out)"
assert '[ "$(steps)" = "marker read dry " ]' "and changes nothing (got '$(steps)')"
assert 'grep -qF "validated nothing" <<<"$out"' "saying why (got '$out')"

# The other half of the mount, and the failure the assertion above cannot see.
# The throwaway mounts two things: the server's dynamic/ directory, and the
# _shared.yml this run rendered laid over it. `traefik-dashboard@file` comes out
# of that overlay — a file this side wrote and shipped as an argument — so it is
# built whatever the server's directory holds, including nothing. A dry run that
# reports it and nothing else has validated only kasbah's own file: exactly what
# a directory mount that silently resolved empty looks like, and it used to read
# as "dry run passed".
set_stack traefik:v3.7.10   # dynamic/ holds _shared.yml and gallery.yml
dry_reply '' 'traefik-dashboard@file '
out=$(cli deploy@vps --version=v3.6.7); rc=$?
# rc alone would be vacuous here: the ship step is rsync, which no stub can
# play, so an un-refused run dies at 1 as well. What separates them is where it
# stopped — measured, reverting the fix turns these steps into "marker read dry
# backup ship " with the same rc.
assert '[ "$rc" = 1 ] && ! grep -qF "STEP backup" "$ssh_log"' \
    "a dry run that built only kasbah's own overlaid router is refused before anything
        is backed up (rc=$rc, steps '$(steps)'): $out"
assert '[ "$(steps)" = "marker read dry " ]' "and changes nothing (got '$(steps)')"
assert 'grep -qF "loaded no router out of /apps/traefik/dynamic" <<<"$out"' \
    "naming the directory whose fragments never showed up (got '$out')"
assert 'grep -qF "gallery.yml" <<<"$out"' \
    "and the fragment step 2 read off the server (got '$out')"

# The control for it, on the same mechanism: one router off the server, and the
# same reply passes. Without this the assertion above is satisfied by a dry run
# that refuses everything.
dry_reply '' 'traefik-dashboard@file gallery@file '
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert 'grep -qF "dry run passed" <<<"$out"' \
    "a router built out of a server fragment is the evidence that directory was read (got '$out')"
assert '! grep -qF "loaded no router out of" <<<"$out"' "and nothing is refused (got '$out')"

# The edge: a server whose dynamic/ holds kasbah's _shared.yml and nothing else.
# There are no project fragments to prove were read, so demanding a router off
# the server would refuse an upgrade that is fine. The run asks the first half
# only — the file provider ran — and says out loud that this is all it checked,
# so "dry run passed" is never read as more than it is.
sed -i "s|^fragments_b64=.*|fragments_b64=$(printf '_shared.yml\n' | openssl base64 -A)|" "$reply/read"
dry_reply '' 'traefik-dashboard@file '
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert 'grep -qF "dry run passed" <<<"$out"' \
    "a server with no project fragments still passes the dry run (rc=$rc: $out)"
assert 'grep -qF "no project fragments to validate" <<<"$out"' \
    "and the pass line says that is all there was to validate (got '$out')"
# ...and the first half still bites there: no dashboard router, no pass.
dry_reply '' 'x@file '
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "with no dashboard router it is still refused (rc=$rc: $out)"
assert 'grep -qF "validated nothing" <<<"$out"' "saying why (got '$out')"
set_stack traefik:v3.7.10

# The four values are recovered, never invented. Each refusal below is the same
# stack with one value taken out of it.
dry_reply
strip() {
    set_stack traefik:v3.7.10
    "$@"
    {
        printf 'traefik_compose_b64=%s\n' "$(b64file "$srv/compose.yml")"
        printf 'traefik_static_b64=%s\n'  "$(b64file "$srv/traefik.yml")"
        printf 'traefik_shared_b64=%s\n'  "$(b64file "$srv/_shared.yml")"
        printf 'fragments_b64=\nacme_state=empty\nacme_digest=\ndocker=yes\n'
        printf 'traefik_state=running\ntraefik_health=healthy\ntraefik_running_image=traefik:v3.7.10\n'
    } > "$reply/read"
}
strip sed -i 's|caServer: .*|#gone|' "$srv/traefik.yml"
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "a traefik.yml with no caServer is refused (rc=$rc: $out)"
assert 'grep -qF "ACME endpoint" <<<"$out"' "naming what is missing (got '$out')"
assert '! grep -qF "STEP dry" "$ssh_log"' "before the dry run even starts (got '$(steps)')"
strip sed -i -e 's|^        users:$|        users: []|' -e '/^          - "admin/d' "$srv/_shared.yml"
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "a _shared.yml with no basic-auth entry is refused (rc=$rc: $out)"
assert 'grep -qF "basic-auth entry" <<<"$out"' "rather than a fresh hash locking the operator out (got '$out')"
strip sed -i 's|email: .*|#gone|' "$srv/traefik.yml"
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert 'grep -qF "ACME registration address" <<<"$out"' "an absent ACME address is refused (got '$out')"
strip sed -i 's|rule: "Host(`traefik.*|rule: "PathPrefix(`/x`)"|' "$srv/_shared.yml"
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert 'grep -qF "dashboard router" <<<"$out"' "and a dashboard rule kasbah does not recognise (got '$out')"
# A stack that is not there at all: the refusal points at init and does not run it.
set_stack traefik:v3.7.10
sed -i 's/^traefik_compose_b64=.*/traefik_compose_b64=/' "$reply/read"
out=$(cli deploy@vps --version=v3.6.7); rc=$?
assert '[ "$rc" = 1 ]' "a missing compose.yml is refused (rc=$rc: $out)"
assert 'grep -qF "kasbah server init deploy@vps" <<<"$out"' "with the command that lays the stack down (got '$out')"

# --- No duplicate definitions -----------------------------------------------------------------
#
# bash takes the last definition of a function and `bash -n` cannot see the
# first, so a byte-identical duplicate reads as working code with every suite
# green (docs/phases/07-operate.md). The remote payloads are excluded: they are
# separate scripts that legitimately define their own helpers.
dups=$(awk '/<<.REMOTE./{r=1} /^REMOTE$/{r=0} r==0 && /^[a-z_]+\(\)/{print $1}' \
    "$repo_dir/lib/upgrade_traefik.sh" | LC_ALL=C sort | uniq -d)
assert '[ -z "$dups" ]' "lib/upgrade_traefik.sh defines each function once (duplicated: $dups)"

# Every warning kasbah prints opens lowercase: `warn` already writes the
# "warning:" prefix, and a capital after it reads as two sentences. Phase 6's
# assertion, kept alongside every new command that warns.
caps=$(grep -o 'warn "[^"]*"' "$repo_dir/lib/upgrade_traefik.sh" | sed 's/^warn "//' | grep '^[A-Z]' || true)
assert '[ -z "$caps" ]' "no warn opens with a capital (got: $caps)"

exit "$fail"
