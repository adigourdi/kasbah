#!/usr/bin/env bash
# Test: lib/server_destroy.sh — `kasbah server destroy`, everything that does
# not need a server.
#
# Five layers, because the command has five:
#   * the pure parts (flag parsing, the usage text), driven straight through the
#     library;
#   * the **act payload's own** guards, extracted from its heredoc and run
#     against a real directory tree — that block deletes paths built from
#     arguments it did not assemble, and rewrites a file holding a project's
#     only copy of its secrets;
#   * the `.env` sentinel strip and the mail `.env` filter, against a table of
#     awkward files, compared byte for byte;
#   * the read payload, likewise extracted, against a fake apps tree and a stub
#     docker;
#   * the command itself, through the CLI with a stub ssh — which is what
#     fixes the exact removal set and both no-TTY refusals.
#
# **The whole command is negatives**, so every "X is gone" assertion here is
# paired with a positive that pins the same mechanism from the other side: the
# same payload, the same tree, one fact changed. A negative assertion is vacuous
# by default (docs/phases/07-operate.md → the phase close).
#
# The rig-driven half — that every container really keeps serving through the
# operation, that a project really comes back up afterwards, and that the backup
# stack really stops — is in tests/integration/server_destroy_test.sh.

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

if ! command -v jq >/dev/null; then
    echo "error: this suite needs jq" >&2
    exit 2
fi

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

b64() { printf '%s' "$1" | base64 -w0; }

# The frozen sentinel strings, read out of lib/env.sh rather than copied here:
# this suite must not be the second place they are written down either.
BEGIN="$(sed -n "s/^ENV_MANAGED_BEGIN='\(.*\)'\$/\1/p" "$repo_dir/lib/env.sh")"
END="$(sed -n "s/^ENV_MANAGED_END='\(.*\)'\$/\1/p" "$repo_dir/lib/env.sh")"
assert '[ -n "$BEGIN" ] && [ -n "$END" ]' "the managed-block sentinels were read out of lib/env.sh"

# One REMOTE heredoc out of lib/server_destroy.sh, by ordinal: the file carries
# three, and `sed -n '/<<.REMOTE./,/^REMOTE$/p'` would run them together.
extract_remote() {   # extract_remote <n> <outfile>
    awk -v want="$1" '
        /<<'"'"'REMOTE'"'"'$/ { n++; if (n == want) { inb = 1; next } }
        /^REMOTE$/            { inb = 0 }
        inb                   { print }
    ' "$repo_dir/lib/server_destroy.sh" > "$2"
}

# --- Driver -------------------------------------------------------------------------
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like the dispatcher: a helper that dies under errexit before its own
# caller can decide what the failure means is a defect this driver reproduces.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/server_destroy.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _sd_parse_args "$@"
        printf 'target=%s\nyes=%s\n' "$_SD_TARGET" "$_SD_YES"
        ;;
    constants)
        printf 'reserved=%s\n' "${_SD_RESERVED[*]}"
        printf 'helpers=%s\n' "${_SD_HELPERS[*]}"
        printf 'mailkeys=%s\n' "${_SD_MAIL_KEYS[*]}"
        printf 'bproject=%s\nbcontainer=%s\nbvolume=%s\nbnetwork=%s\n' \
            "$_SD_BACKUP_PROJECT" "$_SD_BACKUP_CONTAINER" "$_SD_BACKUP_VOLUME" "$_SD_BACKUP_NETWORK"
        printf 'begin=%s\nend=%s\n' "$ENV_MANAGED_BEGIN" "$ENV_MANAGED_END"
        ;;
esac
DRV
drive() { bash "$driver" "$@" 2>&1; echo "rc=$?"; }

# --- Flags ----------------------------------------------------------------------------
out=$(drive parse deploy@vps)
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is the positional argument (got '$out')"
assert 'grep -qxF "yes=" <<<"$out"' "and without --yes the answer is unset, which means *ask* (got '$out')"
out=$(drive parse deploy@vps --yes)
assert 'grep -qxF "yes=yes" <<<"$out"' "--yes is the scriptable answer (got '$out')"
out=$(drive parse)
assert 'grep -qxF "rc=1" <<<"$out"' "no target is an error — destroy has nothing to remember one from (got '$out')"
assert 'grep -qF "no server given" <<<"$out"' "and says so (got '$out')"
out=$(drive parse deploy@vps --yes=yes)
assert 'grep -qxF "rc=1" <<<"$out"' "--yes=yes is refused (got '$out')"
assert 'grep -qF "takes no value" <<<"$out"' "as the flag it is, spelled wrong (got '$out')"
out=$(drive parse deploy@vps --force)
assert 'grep -qF "unknown flag" <<<"$out"' "an unknown flag is refused rather than ignored (got '$out')"
out=$(drive parse deploy@vps other@vps)
assert 'grep -qF "two servers given" <<<"$out"' "two targets are refused (got '$out')"

# Through the CLI with the suite's own KASBAH_LIB_DIR unset: the dispatcher
# reads VERSION from beside whatever library directory it is given, and an
# exported one pointing at lib/ has no VERSION in it.
cli() { env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION "$KASBAH_BIN" "$@"; }
usage_out=$(cli server destroy --help 2>&1); usage_rc=$?
assert '[ "$usage_rc" = 0 ]' "--help exits 0 (rc=$usage_rc: $usage_out)"
assert 'grep -qF -- "--yes" <<<"$usage_out"' "and lists the flag that answers both confirmations"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$usage_out"' "and names the discovery pointer it removes"
assert 'grep -qF ".kasbah-client" <<<"$usage_out"' "and .kasbah-client, which D12 added"
assert 'grep -qF "postmaster" <<<"$usage_out"' "and says the postmaster account is kept"
sub_out=$(cli server --help 2>&1)
assert 'grep -qF "destroy USER@HOST" <<<"$sub_out"' "\`kasbah server --help\` lists destroy (got '$sub_out')"
sub_out=$(cli server nosuchthing 2>&1); sub_rc=$?
assert '[ "$sub_rc" != 0 ]' "an unknown subcommand is refused (rc=$sub_rc)"
assert 'grep -qF "destroy" <<<"$sub_out"' "and the message lists destroy among the real ones (got '$sub_out')"

# --- Constants, pinned to the one place each is really declared -------------------------
#
# Every one of these is a name kasbah wrote somewhere else and destroy has to
# say back exactly. An unpinned copy is how `mail` stops being refused, or how
# a volume stops being removed, on the day the other file changes.
out=$(drive constants)
lib_reserved=$(sed -n "s/^KASBAH_RESERVED_NAMES=(\(.*\))\$/\1/p" "$repo_dir/lib/manifest.sh")
got_reserved=$(sed -n 's/^reserved=//p' <<<"$out")
assert '[ -n "$lib_reserved" ] && [ -n "$got_reserved" ]' \
    "both reserved lists were found (destroy: '$got_reserved', lib: '$lib_reserved')"
assert '[ "$got_reserved" = ".kasbah $lib_reserved" ]' \
    "destroy walks past exactly KASBAH_RESERVED_NAMES plus .kasbah
        destroy: $got_reserved
        lib:     $lib_reserved"

got_helpers=$(sed -n 's/^helpers=//p' <<<"$out")
assert '[ "$got_helpers" = "remote-deploy.sh setup-env.sh" ]' \
    "the helper list is the two files a pre-10.8 deploy installed (got '$got_helpers')"
# Nothing ships either one any more — the engine and the env setup run in the
# server binary — so the list is what servers deployed before Phase 10.8 still
# carry, and it is pinned to docs/files.md's two rows for them.
for h in $got_helpers; do
    assert 'grep -qF "scripts/$h" "$repo_dir/docs/files.md"' \
        "and docs/files.md still names scripts/$h for destroy to remove"
done

# The keys of <apps>/mail/.env kasbah owns, pinned as a **set** against
# lib/server_init.sh — which is where "these keys are kasbah's, every other line
# is copied through untouched" is actually decided, by rewriting each of them by
# name. Taking the first three assignments out of templates/mail/env instead
# would keep passing on the day a fourth key is appended after DATA_PATH, while
# destroy silently stripped it and the mail stack stopped starting.
init_keys=$(grep -oE '^[[:space:]]+[A-Z_]+=\*\)' "$repo_dir/lib/server_init.sh" \
            | tr -d ' \t' | sed 's/=\*)$//' | LC_ALL=C sort -u | tr '\n' ' ')
init_keys="${init_keys% }"
got_mailkeys=$(sed -n 's/^mailkeys=//p' <<<"$out" | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' ')
got_mailkeys="${got_mailkeys% }"
assert '[ -n "$init_keys" ]' "lib/server_init.sh's own list of the mail keys kasbah rewrites was found"
assert '[ "$got_mailkeys" = "$init_keys" ]' \
    "destroy keeps exactly the keys server init owns — no more, and no fewer
        destroy:   $got_mailkeys
        init:      $init_keys"
# And every one of them really is in the shipped template, so the set is not
# self-consistent nonsense.
for k in $init_keys; do
    assert 'grep -qE "^$k=" "$repo_dir/templates/mail/env"' \
        "and templates/mail/env really assigns $k"
done

got_bvolume=$(sed -n 's/^bvolume=//p' <<<"$out")
got_bproject=$(sed -n 's/^bproject=//p' <<<"$out")
got_bcontainer=$(sed -n 's/^bcontainer=//p' <<<"$out")
got_bnetwork=$(sed -n 's/^bnetwork=//p' <<<"$out")
assert 'grep -qxF "    name: $got_bvolume" "$repo_dir/templates/backup/compose.yml"' \
    "the cache volume destroy removes is the one the backup template names (got '$got_bvolume')"
assert 'grep -qxF "name: $got_bproject" "$repo_dir/templates/backup/compose.yml"' \
    "and the compose project (got '$got_bproject')"
assert 'grep -qxF "    container_name: $got_bcontainer" "$repo_dir/templates/backup/compose.yml"' \
    "and the container (got '$got_bcontainer')"
assert '[ "$got_bnetwork" = "${got_bproject}_default" ]' \
    "and the default network compose derives from the project name (got '$got_bnetwork')"

# The sentinels reach the far side as arguments, so lib/server_destroy.sh holds
# no copy of them at all — the thing that makes them impossible to drift.
assert '! grep -qF "kasbah managed block" "$repo_dir/lib/server_destroy.sh"' \
    "lib/server_destroy.sh writes the managed-block sentinels down nowhere: they are lib/env.sh's"
assert 'grep -qF "ENV_MANAGED_BEGIN" "$repo_dir/lib/server_destroy.sh"' \
    "it passes lib/env.sh's own variables instead"

# --- The act payload's guards, against a real tree ----------------------------------------
act="$tmpdir/act.sh"
extract_remote 3 "$act"
assert '[ -s "$act" ]' "the act step was extracted from lib/server_destroy.sh"
assert 'grep -qF "rm -rf" "$act"' \
    "and it is the block that deletes — every case below is empty theatre otherwise"
assert 'grep -qF "strip_env" "$act"' "and the block that rewrites a project's .env"

stub="$tmpdir/stub"
mkdir -p "$stub"
cat > "$stub/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$1 $2" in
    "container inspect")
        [ "${DOCKER_CONTAINER:-present}" = present ] || exit 1
        case "$*" in *State.Status*) printf 'running\n' ;; esac
        exit 0 ;;
    "volume inspect")
        [ "${DOCKER_VOLUME:-present}" = present ] || exit 1
        exit 0 ;;
    "network inspect")
        [ "${DOCKER_NETWORK:-present}" = present ] || exit 1
        exit 0 ;;
esac
case "$1" in
    compose) exit "${DOCKER_DOWN_RC:-0}" ;;
    rm|volume|network) exit 0 ;;
esac
exit 0
STUB
chmod 0755 "$stub/docker"
# `sudo` that is only a pass-through, so the pointer branch can be driven
# without this workstation's real sudo policy deciding the outcome.
cat > "$stub/sudo" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" != "-n" ] || shift
exec "$@"
STUB
chmod 0755 "$stub/sudo"

pointer_rel="etc/kasbah/apps-path"
make_tree() {
    rm -rf "$tmpdir/srv"
    mkdir -p "$tmpdir/srv/apps/.kasbah/backup/repos" "$tmpdir/srv/apps/.kasbah/backup/state" \
             "$tmpdir/srv/apps/demo/scripts" "$tmpdir/srv/apps/demo/backups" \
             "$tmpdir/srv/apps/other/scripts" \
             "$tmpdir/srv/apps/traefik/dynamic" "$tmpdir/srv/apps/mail" \
             "$tmpdir/srv/apps/data/demo" "$tmpdir/srv/etc/kasbah"
    printf '{"apps_path":"/apps"}\n' > "$tmpdir/srv/apps/.kasbah/server.json"
    printf 'name: kasbah-backup\n' > "$tmpdir/srv/apps/.kasbah/backup/compose.yml"
    printf '#!/bin/sh\n' > "$tmpdir/srv/apps/.kasbah/backup/backup.sh"
    printf 'KASBAH_BACKUP_REPO_BASE=rest:https://u:p@store/\n' > "$tmpdir/srv/apps/.kasbah/backup/env"
    printf 'super-secret\n' > "$tmpdir/srv/apps/.kasbah/backup/repos/demo.pass"
    for p in demo other; do
        printf 'services: {}\n' > "$tmpdir/srv/apps/$p/compose.yml"
        printf 'deploy 1.0.0 x y\n' > "$tmpdir/srv/apps/$p/versions.log"
        printf 'gz\n' > "$tmpdir/srv/apps/$p/versions.log.gz"
        : > "$tmpdir/srv/apps/$p/.deploy.lock"
        printf '%s\n' "$p" > "$tmpdir/srv/apps/$p/.kasbah-client"
        printf '#!/bin/sh\n' > "$tmpdir/srv/apps/$p/scripts/remote-deploy.sh"
        printf '#!/bin/sh\n' > "$tmpdir/srv/apps/$p/scripts/setup-env.sh"
        { printf 'DB_PASSWORD=s3cr3t\n'
          printf '%s\n' "$BEGIN"
          printf 'KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=2g\n'
          printf '%s\n' "$END"
          printf 'API_KEY=abc\n'; } > "$tmpdir/srv/apps/$p/.env"
    done
    printf 'x\n' > "$tmpdir/srv/apps/demo/backups/dump.gz"
    printf 'x\n' > "$tmpdir/srv/apps/traefik/dynamic/demo.yml"
    printf 'db\n' > "$tmpdir/srv/apps/data/demo/db.sqlite"
    { printf 'MAIL_HOSTNAME=mail.example.com\nDOMAIN=example.com\nDATA_PATH=/apps/data\n'
      printf '\n# the relay\nDEFAULT_RELAY_HOST=[smtp.example.com]:587\n'
      printf 'RELAY_USER=agency\nRELAY_PASSWORD=agency-smtp-key\n'; } > "$tmpdir/srv/apps/mail/.env"
    printf 'name: mail\nprimary_domain: example.com\n' > "$tmpdir/srv/apps/mail/kasbah.yml"
    printf '/apps\n' > "$tmpdir/srv/$pointer_rel"
}
tree_digest() { (cd "$tmpdir/srv" && find . -printf '%p %s %m\n' 2>/dev/null | LC_ALL=C sort | md5sum); }

run_act() {   # run_act [override...] -- <name>...
    local apps="$tmpdir/srv/apps" pointer="$tmpdir/srv/$pointer_rel"
    local a_apps="$apps" a_pointer="$pointer" a_reserved=".kasbah traefik mail data backups"
    local a_begin="$BEGIN" a_end="$END"
    local a_helpers="remote-deploy.sh setup-env.sh" a_mail="MAIL_HOSTNAME DOMAIN DATA_PATH"
    local a_path="$stub:/usr/bin:/bin"
    while [ $# -gt 0 ]; do
        case "$1" in
            apps=*)    a_apps="${1#*=}" ;;
            pointer=*) a_pointer="${1#*=}" ;;
            begin=*)   a_begin="${1#*=}" ;;
            end=*)     a_end="${1#*=}" ;;
            helpers=*) a_helpers="${1#*=}" ;;
            mail=*)    a_mail="${1#*=}" ;;
            path=*)    a_path="${1#*=}" ;;
            --) shift; break ;;
        esac
        shift
    done
    env -i PATH="$a_path" DOCKER_LOG="${DOCKER_LOG:-/dev/null}" \
        DOCKER_CONTAINER="${DOCKER_CONTAINER:-present}" \
        DOCKER_VOLUME="${DOCKER_VOLUME:-present}" \
        DOCKER_NETWORK="${DOCKER_NETWORK:-present}" \
        DOCKER_DOWN_RC="${DOCKER_DOWN_RC:-0}" \
        bash "$act" "$a_apps" "$a_pointer" "$a_reserved" \
            kasbah-backup kasbah-backup kasbah-backup-cache kasbah-backup_default \
            "$a_begin" "$a_end" "$a_helpers" "$a_mail" "$@" 2>&1
}

# Every refusal, and the tree unchanged after each. A guard that fires on a
# payload that never works would pass all of these.
guard_case() {   # guard_case <description> <override-or---> ... -- <names>
    make_tree
    local before after out rc
    before="$(tree_digest)"
    out=$(run_act "$@"); rc=$?
    after="$(tree_digest)"
    assert '[ "$rc" != 0 ]' "the act payload refuses: $GUARD_WHY (rc=$rc: $out)"
    assert 'grep -qF "refusing to act" <<<"$out"' "loudly ($GUARD_WHY; got '$out')"
    assert '[ "$before" = "$after" ]' "and nothing under the tree changed ($GUARD_WHY)"
}

for bad in "" "." ".." "../other" "de/mo" "Demo" "1demo" "de mo" "demo;rm" ".kasbah" traefik mail data backups; do
    GUARD_WHY="project name '$bad'" guard_case -- "$bad"
done
GUARD_WHY="a relative apps path" guard_case "apps=apps" -- demo
GUARD_WHY="an apps path ending in a slash" guard_case "apps=$tmpdir/srv/apps/" -- demo
GUARD_WHY="a relative pointer path" guard_case "pointer=etc/kasbah/apps-path" -- demo
GUARD_WHY="an empty begin sentinel" guard_case "begin=" -- demo
GUARD_WHY="an empty end sentinel" guard_case "end=" -- demo
GUARD_WHY="two identical sentinels" guard_case "end=$BEGIN" -- demo
GUARD_WHY="no helper names" guard_case "helpers=" -- demo
GUARD_WHY="a helper name with a slash in it" guard_case "helpers=../../etc/passwd" -- demo
GUARD_WHY="no mail keys" guard_case "mail=" -- demo

# The positive counterpart: the same payload, the same tree, arguments that pass
# — so every refusal above is the guard and not a payload that never works.
make_tree
DOCKER_LOG="$tmpdir/docker.log" run_act -- demo other > "$tmpdir/act.out" 2>&1; rc=$?
act_out="$(cat "$tmpdir/act.out")"
assert '[ "$rc" = 0 ]' "well-formed arguments run the act (rc=$rc: $act_out)"
assert 'grep -qxF "done=yes" <<<"$act_out"' "and it runs to the end (got '$act_out')"

# The backup stack — the sharpest of the removals, because a schedule left
# running keeps pushing the new owner's data to the departing operator.
assert 'grep -qxF "bk_down=ok" <<<"$act_out"' "the backup stack is brought down (got '$act_out')"
assert 'grep -qF "compose -p kasbah-backup down" "$tmpdir/docker.log"' \
    "with compose's own project name (log: $(cat "$tmpdir/docker.log"))"
assert 'grep -qxF "bk_volume=removed" <<<"$act_out"' "its cache volume is removed by name"
assert 'grep -qF "volume rm kasbah-backup-cache" "$tmpdir/docker.log"' \
    "and really named to docker (log: $(cat "$tmpdir/docker.log"))"
assert 'grep -qxF "bk_network=removed" <<<"$act_out"' "and its network"
assert '[ ! -e "$tmpdir/srv/apps/.kasbah/backup" ]' "the whole backup directory is gone"
assert '[ ! -e "$tmpdir/srv/apps/.kasbah/backup/env" ]' "with the credentials in it"
assert '[ ! -e "$tmpdir/srv/apps/.kasbah/backup/repos/demo.pass" ]' "and every repository password"

# Per project.
for p in demo other; do
    assert '[ ! -e "$tmpdir/srv/apps/$p/versions.log" ]' "$p's versions.log is gone"
    assert '[ ! -e "$tmpdir/srv/apps/$p/versions.log.gz" ]' "and its archive"
    assert '[ ! -e "$tmpdir/srv/apps/$p/.deploy.lock" ]' "and its .deploy.lock"
    assert '[ ! -e "$tmpdir/srv/apps/$p/.kasbah-client" ]' "and its .kasbah-client"
    assert '[ ! -e "$tmpdir/srv/apps/$p/scripts" ]' "and its scripts/ directory, helpers and all"
    assert 'grep -qE "^project=$p removed removed removed removed removed stripped\$" <<<"$act_out"' \
        "and it reported all six in one row (got '$(grep "^project=$p" <<<"$act_out")')"
done
# The other half of the same act: what it must not have taken.
assert '[ -e "$tmpdir/srv/apps/demo/compose.yml" ]' "the project's compose.yml stays"
assert '[ -e "$tmpdir/srv/apps/demo/backups/dump.gz" ]' "and its on-VPS backups"
assert '[ -e "$tmpdir/srv/apps/data/demo/db.sqlite" ]' "and its data"
assert '[ -e "$tmpdir/srv/apps/traefik/dynamic/demo.yml" ]' "and its Traefik route"
assert '[ -e "$tmpdir/srv/apps/mail/.env" ]' "the mail .env still exists"

# The marker and the pointer, last and only on a clean run.
assert '[ ! -e "$tmpdir/srv/apps/.kasbah/server.json" ]' "the server marker is gone"
assert '[ ! -e "$tmpdir/srv/apps/.kasbah" ]' "and the directory that held it"
assert 'grep -qxF "kasbah_dir=removed" <<<"$act_out"' "and it says so (got '$act_out')"
assert '[ ! -e "$tmpdir/srv/$pointer_rel" ]' "the discovery pointer is gone"
assert '[ ! -e "$tmpdir/srv/etc/kasbah" ]' "and /etc/kasbah with it, since it held nothing else"

# --- The mail .env filter -----------------------------------------------------------------
mail_after="$(cat "$tmpdir/srv/apps/mail/.env")"
assert 'grep -qxF "MAIL_HOSTNAME=mail.example.com" <<<"$mail_after"' \
    "MAIL_HOSTNAME survives — the stack does not start without it (got '$mail_after')"
assert 'grep -qxF "DOMAIN=example.com" <<<"$mail_after"' "and DOMAIN"
assert 'grep -qxF "DATA_PATH=/apps/data" <<<"$mail_after"' "and DATA_PATH"
assert '! grep -qF "agency-smtp-key" <<<"$mail_after"' \
    "the operator's relay password is gone (got '$mail_after')"
assert '! grep -qF "RELAY_USER" <<<"$mail_after"' "and the relay user"
assert '! grep -qF "DEFAULT_RELAY_HOST" <<<"$mail_after"' "and the relay host"
assert '! grep -qF "# the relay" <<<"$mail_after"' \
    "and every other line, comments included — a comment kasbah did not write may carry a credential"
assert '[ "$(stat -c '%a' "$tmpdir/srv/apps/mail/.env")" = 600 ]' \
    "and the file is still 600 (got $(stat -c '%a' "$tmpdir/srv/apps/mail/.env"))"
assert 'grep -qxF "mail_env_n=5" <<<"$act_out"' \
    "five lines went, and the run counted them (got '$(grep mail_env <<<"$act_out")')"
assert '[ ! -e "$tmpdir/srv/apps/mail/kasbah.yml" ]' "the domain registry is gone"

# The paired positive: a mail .env holding nothing but the three keys is left
# alone entirely, so "stripped" above is the filter and not a payload that
# rewrites whatever it is given.
make_tree
printf 'MAIL_HOSTNAME=a.b\nDOMAIN=b\nDATA_PATH=/d\n' > "$tmpdir/srv/apps/mail/.env"
before_mail="$(md5sum < "$tmpdir/srv/apps/mail/.env")"
out=$(run_act -- demo)
assert 'grep -qxF "mail_env=unchanged" <<<"$out"' \
    "a mail .env with only kasbah's keys is reported unchanged (got '$(grep mail_env <<<"$out")')"
assert '[ "$before_mail" = "$(md5sum < "$tmpdir/srv/apps/mail/.env")" ]' "and is byte for byte as it was"
leftover="$(find "$tmpdir/srv/apps" -name '*.kasbah-destroy.*' 2>/dev/null | tr '\n' ' ')"
assert '[ -z "$leftover" ]' "with no temp file left beside it (found: $leftover)"
# The paired positive: `find` really sees a file of that shape, so the emptiness
# above is a measurement. The old spelling was `ls | grep -q` — a dotfile plain
# `ls` never lists, and the one producer-into-`grep -q` in this change.
: > "$tmpdir/srv/apps/mail/.env.kasbah-destroy.999"
assert '[ -n "$(find "$tmpdir/srv/apps" -name "*.kasbah-destroy.*" 2>/dev/null)" ]' \
    "and the probe finds one when there is one — a dotfile is exactly what it has to see"
rm -f "$tmpdir/srv/apps/mail/.env.kasbah-destroy.999"

# --- The .env sentinel strip, byte for byte ------------------------------------------------
#
# This is the dangerous rewrite: the file holds the project's only copy of its
# secrets, and the two KASBAH_* values between the sentinels are what compose
# interpolates into every service's `cpus:` and `mem_limit:`. Every case below
# compares the whole file against bytes written out by hand — not against a
# second implementation of the same rule, which would pass while both were wrong.
env_case() {   # env_case <name> <input-file> <expected-file>
    make_tree
    cp "$2" "$tmpdir/srv/apps/demo/.env"
    chmod 640 "$tmpdir/srv/apps/demo/.env"
    local out
    out=$(run_act -- demo)
    ENV_CASE_OUT="$out"
    if cmp -s "$tmpdir/srv/apps/demo/.env" "$3"; then
        return 0
    fi
    echo "  FAIL: the .env strip changed '$1' into something other than the expected bytes" >&2
    diff <(od -c "$3") <(od -c "$tmpdir/srv/apps/demo/.env") | sed 's/^/        /' >&2
    fail=1
    return 1
}

in="$tmpdir/env.in"; want="$tmpdir/env.want"

# a) the ordinary managed .env a deploy leaves.
{ printf 'DB_PASSWORD=s3cr3t\n'; printf '%s\n' "$BEGIN"
  printf 'KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=2g\n'; printf '%s\n' "$END"
  printf 'API_KEY=abc\n'; } > "$in"
{ printf 'DB_PASSWORD=s3cr3t\n'
  printf 'KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=2g\n'
  printf 'API_KEY=abc\n'; } > "$want"
env_case "an ordinary managed .env" "$in" "$want"
assert 'grep -qE "^project=demo .* stripped\$" <<<"$ENV_CASE_OUT"' \
    "and it is reported stripped (got '$(grep "^project=demo" <<<"$ENV_CASE_OUT")')"
assert '[ "$(stat -c "%a" "$tmpdir/srv/apps/demo/.env")" = 640 ]' \
    "the file keeps the mode it had, not the temp file's (got $(stat -c '%a' "$tmpdir/srv/apps/demo/.env"))"

# b) CRLF throughout: the sentinels are matched with the CR off, every other
#    line keeps its CR.
{ printf 'DB_PASSWORD=s3cr3t\r\n'; printf '%s\r\n' "$BEGIN"
  printf 'KASBAH_CPU_LIMIT=2\r\n'; printf '%s\r\n' "$END"; } > "$in"
{ printf 'DB_PASSWORD=s3cr3t\r\n'; printf 'KASBAH_CPU_LIMIT=2\r\n'; } > "$want"
env_case "a CRLF .env" "$in" "$want"

# c) no block at all — the file is not touched, and the run says so.
printf 'DB_PASSWORD=s3cr3t\nAPI_KEY=abc\n' > "$in"
cp "$in" "$want"
env_case "an .env with no managed block" "$in" "$want"
assert 'grep -qE "^project=demo .* noblock\$" <<<"$ENV_CASE_OUT"' \
    "and it is reported noblock rather than stripped (got '$(grep "^project=demo" <<<"$ENV_CASE_OUT")')"

# d) two blocks — an older kasbah's and this one's. Both sets of sentinels go
#    and both sets of values stay, because compose reads the last assignment.
{ printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=1\n'; printf '%s\n' "$END"
  printf 'X=1\n'
  printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=2\n'; printf '%s\n' "$END"; } > "$in"
{ printf 'KASBAH_CPU_LIMIT=1\nX=1\nKASBAH_CPU_LIMIT=2\n'; } > "$want"
env_case "an .env with two managed blocks" "$in" "$want"

# e) a block at EOF, file ending in a newline.
{ printf 'X=1\n'; printf '%s\n' "$BEGIN"; printf 'KASBAH_MEM_LIMIT=8g\n'; printf '%s\n' "$END"; } > "$in"
printf 'X=1\nKASBAH_MEM_LIMIT=8g\n' > "$want"
env_case "a block at EOF" "$in" "$want"

# f) the same, with **no final newline**: the end sentinel is the last bytes of
#    the file. The line before it keeps the newline it had.
{ printf 'X=1\n'; printf '%s\n' "$BEGIN"; printf 'KASBAH_MEM_LIMIT=8g\n'; printf '%s' "$END"; } > "$in"
printf 'X=1\nKASBAH_MEM_LIMIT=8g\n' > "$want"
env_case "a block at EOF with no final newline" "$in" "$want"

# g) a value as the final line with no newline after it — data docker compose
#    reads, and it must not grow one.
{ printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=2\n'; printf '%s\n' "$END"
  printf 'LAST=no-newline'; } > "$in"
printf 'KASBAH_CPU_LIMIT=2\nLAST=no-newline' > "$want"
env_case "a final line with no newline" "$in" "$want"

# h) a stray KASBAH_* outside the block, and one commented out. Neither is a
#    sentinel, so both survive verbatim — destroy removes comments, not values.
{ printf 'KASBAH_STRAY=1\n'; printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=2\n'
  printf '%s\n' "$END"; printf '#%s\n' "$BEGIN"; } > "$in"
{ printf 'KASBAH_STRAY=1\nKASBAH_CPU_LIMIT=2\n'; printf '#%s\n' "$BEGIN"; } > "$want"
env_case "a stray KASBAH_* and a commented-out sentinel" "$in" "$want"

# i) a begin sentinel with no end after it. lib/env.sh calls that "a position,
#    not a block" and leaves the tail alone; destroy removes the *comment*
#    either way, because what it claims — that the block is rewritten on every
#    deploy — is false from here on however the file is shaped.
{ printf 'A=1\n'; printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=2\nB=2\n'; } > "$in"
printf 'A=1\nKASBAH_CPU_LIMIT=2\nB=2\n' > "$want"
env_case "a begin sentinel with no end" "$in" "$want"

# j) awkward bytes on every kept line: quoting, `#`, `$`, backslashes, tabs,
#    trailing spaces, a blank line, and a leading-blank `export`.
{ printf '%s\n' "$BEGIN"; printf 'KASBAH_CPU_LIMIT=2\n'; printf '%s\n' "$END"
  printf 'A=a b\t c   \n'
  printf 'B="quoted # not a comment"\n'
  printf 'C=$dollar\\backslash\n'
  printf '\n'
  printf '   export D=indented\n'
  printf '# a comment the operator wrote\n'; } > "$in"
{ printf 'KASBAH_CPU_LIMIT=2\n'
  printf 'A=a b\t c   \n'
  printf 'B="quoted # not a comment"\n'
  printf 'C=$dollar\\backslash\n'
  printf '\n'
  printf '   export D=indented\n'
  printf '# a comment the operator wrote\n'; } > "$in.want"
env_case "awkward bytes on every kept line" "$in" "$in.want"

# k) an .env that is only the two sentinels: the file survives, empty.
{ printf '%s\n' "$BEGIN"; printf '%s\n' "$END"; } > "$in"
: > "$want"
env_case "an .env that is nothing but the two sentinels" "$in" "$want"
assert '[ -f "$tmpdir/srv/apps/demo/.env" ]' "and the file itself is still there"

# l) no .env at all.
make_tree
rm -f "$tmpdir/srv/apps/demo/.env"
out=$(run_act -- demo)
assert 'grep -qE "^project=demo .* absent\$" <<<"$out"' \
    "a project with no .env is reported absent, not failed (got '$(grep "^project=demo" <<<"$out")')"

# --- An .env this step cannot rewrite is a FAILURE, not a shrug -----------------------------
#
# The one case where carrying on quietly would leave the operator's own
# credential on a machine kasbah has just told them is clean. Both files, and in
# both cases the marker and the pointer have to stay so the run can be repeated.
make_tree
chmod 0000 "$tmpdir/srv/apps/demo/.env"
out=$(run_act -- demo other); rc=$?
chmod 0644 "$tmpdir/srv/apps/demo/.env"
assert '[ "$rc" = 0 ]' "the payload still reports rather than dying (rc=$rc)"
assert 'grep -qE "^project=demo .* unreadable\$" <<<"$out"' \
    "an .env this user cannot read is reported unreadable (got '$(grep "^project=demo" <<<"$out")')"
assert 'grep -qxF "marker=held" <<<"$out"' \
    "and the marker is held back — a server whose .env still claims kasbah rewrites it must stay findable (got '$out')"
assert 'grep -qxF "pointer=held" <<<"$out"' "and the pointer"
assert '[ -e "$tmpdir/srv/apps/.kasbah/server.json" ]' "the marker really is still there"
assert 'grep -qE "^project=other .* stripped\$" <<<"$out"' \
    "while the neighbouring project's .env was stripped — one unreadable file does not strand the rest"

make_tree
chmod 0000 "$tmpdir/srv/apps/mail/.env"
out=$(run_act -- demo); rc=$?
chmod 0600 "$tmpdir/srv/apps/mail/.env"
assert 'grep -qxF "mail_env=unreadable" <<<"$out"' \
    "a mail .env this user cannot read is reported unreadable (got '$(grep mail_env <<<"$out")')"
assert 'grep -qxF "marker=held" <<<"$out"' \
    "and the marker is held back — the relay credential is still on the server (got '$out')"
assert '[ -e "$tmpdir/srv/$pointer_rel" ]' "and the pointer really is still there"

# The paired positive: the same tree with both files readable removes both, so
# `held` above is the unreadable file and not a payload that always holds.
make_tree
out=$(run_act -- demo)
assert 'grep -qxF "marker=removed" <<<"$out"' "with both readable, the same call removes the marker (got '$out')"

# --- scripts/: kasbah's helpers, and nobody else's ------------------------------------------
make_tree
printf 'operator\n' > "$tmpdir/srv/apps/demo/scripts/deploy-notes.txt"
out=$(run_act -- demo other)
assert '[ ! -e "$tmpdir/srv/apps/demo/scripts/remote-deploy.sh" ]' "kasbah's helper goes"
assert '[ ! -e "$tmpdir/srv/apps/demo/scripts/setup-env.sh" ]' "and the other one"
assert '[ -e "$tmpdir/srv/apps/demo/scripts/deploy-notes.txt" ]' \
    "a file kasbah did not write stays, and so does the directory holding it"
assert 'grep -qE "^project=demo [a-z]+ [a-z]+ kept " <<<"$out"' \
    "and the row says kept (got '$(grep "^project=demo" <<<"$out")')"
assert '[ ! -e "$tmpdir/srv/apps/other/scripts" ]' \
    "while the neighbouring project's scripts/ — which held only helpers — is gone"

# --- Partial failure: the marker and the pointer are kept ------------------------------------
#
# They are how a later run finds this server at all, so a run that could not
# finish must not take them. Driven by a `docker compose down` that fails, which
# is the one step that can fail without any file being unwritable.
make_tree
out=$(DOCKER_DOWN_RC=1 run_act -- demo); rc=$?
assert '[ "$rc" = 0 ]' "the payload still reports rather than dying (rc=$rc)"
assert 'grep -qxF "bk_down=failed" <<<"$out"' "the failure is reported (got '$out')"
assert 'grep -qxF "marker=held" <<<"$out"' "and the marker is held back (got '$out')"
assert 'grep -qxF "pointer=held" <<<"$out"' "and so is the pointer"
assert '[ -e "$tmpdir/srv/apps/.kasbah/server.json" ]' "the marker really is still there"
assert '[ -e "$tmpdir/srv/$pointer_rel" ]' "and the pointer"
assert '[ ! -e "$tmpdir/srv/apps/demo/versions.log" ]' \
    "while the steps that did succeed did happen — held is not 'nothing ran'"

# --- No passwordless sudo: warn and carry on --------------------------------------------------
nosudo="$tmpdir/nosudo"
mkdir -p "$nosudo"
for tool in bash openssl rm mv rmdir chmod tr readlink id test mktemp; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$src" "$nosudo/$tool"
done
ln -sf "$stub/docker" "$nosudo/docker"
assert '! PATH="$nosudo" command -v sudo >/dev/null' "the stripped PATH really has no sudo"
make_tree
out=$(run_act "path=$nosudo" -- demo); rc=$?
assert '[ "$rc" = 0 ]' "a server with no passwordless sudo does not stop the run (rc=$rc: $out)"
assert 'grep -qxF "pointer=nosudo" <<<"$out"' "the pointer is reported as unremovable (got '$out')"
assert '[ -e "$tmpdir/srv/$pointer_rel" ]' "and it really is still there"
assert '[ ! -e "$tmpdir/srv/apps/.kasbah/server.json" ]' \
    "while everything that needed no elevation was removed"
assert '[ ! -e "$tmpdir/srv/apps/demo/versions.log" ]' "including the deploy record"
# The paired positive: the same tree with sudo back on PATH removes it, so
# `nosudo` above is the missing binary and not a payload that never gets there.
make_tree
out=$(run_act -- demo)
assert 'grep -qxF "pointer=removed" <<<"$out"' "with sudo on PATH the same call removes it (got '$out')"

# --- /etc/kasbah keeps whatever it holds that kasbah did not write -----------------------------
make_tree
printf 'not ours\n' > "$tmpdir/srv/etc/kasbah/something-else"
out=$(run_act -- demo)
assert 'grep -qxF "pointer=removed" <<<"$out"' "the pointer still goes (got '$out')"
assert 'grep -qxF "pointer_dir=kept" <<<"$out"' "but the directory stays (got '$out')"
assert '[ -e "$tmpdir/srv/etc/kasbah/something-else" ]' "with the file that is not kasbah's"

# --- <apps>/.kasbah keeps whatever it holds that this kasbah does not know -----------------------
make_tree
printf 'newer\n' > "$tmpdir/srv/apps/.kasbah/from-a-newer-kasbah.json"
out=$(run_act -- demo)
assert 'grep -qxF "marker=removed" <<<"$out"' "the marker still goes (got '$out')"
assert 'grep -qxF "kasbah_dir=kept" <<<"$out"' "but the directory stays (got '$out')"
assert '[ -e "$tmpdir/srv/apps/.kasbah/from-a-newer-kasbah.json" ]' "with the file this kasbah did not write"

# --- The read payload, run locally --------------------------------------------------------------
probe="$tmpdir/probe.sh"
extract_remote 2 "$probe"
assert '[ -s "$probe" ]' "the read step was extracted from lib/server_destroy.sh"
assert 'grep -qF "kv project_count" "$probe"' "and it is the right block"
assert '! grep -qE "rm -rf|mv -f|rmdir " "$probe"' "and it removes nothing"

make_tree
mkdir -p "$tmpdir/srv/apps/locked"
: > "$tmpdir/srv/apps/locked/.env"
chmod 0000 "$tmpdir/srv/apps/locked/.env"
touch "$tmpdir/srv/apps/notaproject"
probe_before="$(tree_digest)"
probe_out=$(env -i PATH="$stub:/usr/bin:/bin" bash "$probe" \
    "$tmpdir/srv/apps" "$tmpdir/srv/$pointer_rel" ".kasbah traefik mail data backups" \
    kasbah-backup kasbah-backup-cache kasbah-backup_default \
    "$BEGIN" "$END" "remote-deploy.sh setup-env.sh" "MAIL_HOSTNAME DOMAIN DATA_PATH" 2>&1)
probe_rc=$?
fact() { sed -n "s/^$1=//p" <<<"$probe_out"; }
assert '[ "$probe_rc" = 0 ]' "the read step exits 0 (rc=$probe_rc: $probe_out)"
assert '[ "$probe_before" = "$(tree_digest)" ]' "and changes nothing under the tree"
assert '[ "$(fact apps_state)" = dir ]' "the apps path is found (got '$(fact apps_state)')"
assert '[ "$(fact marker_state)" = ok ]' "and the marker (got '$(fact marker_state)')"
assert '[ "$(fact backup_dir)" = dir ]' "and the backup stack's directory (got '$(fact backup_dir)')"
assert '[ "$(fact backup_container)" = running ]' \
    "and the backup container's own state comes back from docker (got '$(fact backup_container)')"
assert '[ "$(fact backup_volume)" = present ]' "and the cache volume (got '$(fact backup_volume)')"
assert '[ "$(fact backup_network)" = present ]' "and the network (got '$(fact backup_network)')"
assert '[ "$(fact pointer_state)" = ok ]' "the discovery pointer is read (got '$(fact pointer_state)')"
assert '[ "$(fact pointer_dir_other)" = 0 ]' \
    "and /etc/kasbah holds nothing but it (got '$(fact pointer_dir_other)')"
assert '[ "$(fact mail_dir)" = dir ]' "the mail stack is seen (got '$(fact mail_dir)')"
assert '[ "$(fact mail_env_state)" = ok ]' "and its .env (got '$(fact mail_env_state)')"
assert '[ "$(fact mail_env_extra)" = 5 ]' \
    "with five lines in it that are not kasbah's three keys (got '$(fact mail_env_extra)')"
assert '[ "$(fact mail_registry_state)" = ok ]' "and the domain registry (got '$(fact mail_registry_state)')"
assert '[ "$(fact project_count)" = 4 ]' \
    "demo, other, locked and the thing that is not a directory are projects; traefik, mail, data and .kasbah are not (got '$(fact project_count)')"
rows=$(base64 -d <<<"$(fact projects_b64)")
assert '[ "$(grep -cE "^$(b64 demo) dir ok ok dir 2 0 empty ok ok 2\$" <<<"$rows")" = 1 ]' \
    "demo's row names every artifact and counts its two sentinel lines (rows: $rows)"
assert '[ "$(grep -cF "$(b64 notaproject) notdir" <<<"$rows")" = 1 ]' \
    "and something that is not a directory is reported, not skipped (rows: $rows)"
assert 'grep -qF "$(b64 locked) dir missing missing absent 0 0 missing missing unreadable 0" <<<"$rows"' \
    "an .env this user cannot read is unreadable with no sentinel count, not a silent zero (rows: $rows)"
chmod 0644 "$tmpdir/srv/apps/locked/.env"

# An entry under the apps path that is not a project name. Each of these is
# plausible on a real server, and every one of them used to `fail` the act after
# both confirmations had been answered — an unrecoverable block on the whole
# command. The probe declines to call them projects; the act's identical guard
# stays as the last word and simply stops being reachable.
make_tree
for odd in "Notes.txt" "README.md" "Old-Site" ".DS_Store" "site.bak" "a_b"; do
    : > "$tmpdir/srv/apps/$odd"
done
probe_out=$(env -i PATH="$stub:/usr/bin:/bin" bash "$probe" \
    "$tmpdir/srv/apps" "$tmpdir/srv/$pointer_rel" ".kasbah traefik mail data backups" \
    kasbah-backup kasbah-backup-cache kasbah-backup_default \
    "$BEGIN" "$END" "remote-deploy.sh setup-env.sh" "MAIL_HOSTNAME DOMAIN DATA_PATH" 2>&1)
assert '[ "$(fact project_count)" = 2 ]' \
    "six oddly-named entries are not projects; demo and other are (got '$(fact project_count)')"
skipped=$(base64 -d <<<"$(fact skipped_b64)")
for odd in "Notes.txt" "README.md" "Old-Site" ".DS_Store" "site.bak" "a_b"; do
    assert 'grep -qF "$odd" <<<"$skipped"' "and $odd is reported as left alone rather than dropped in silence (got '$skipped')"
done
rows=$(base64 -d <<<"$(fact projects_b64)")
assert '! grep -qF "$(b64 Notes.txt)" <<<"$rows"' "and no row was built for it (rows: $rows)"
# The paired positive, one character apart: `old-site` *is* a project name, and
# the same walk does describe it — so the filter is the shape and not the walk.
mkdir -p "$tmpdir/srv/apps/old-site"
probe_out=$(env -i PATH="$stub:/usr/bin:/bin" bash "$probe" \
    "$tmpdir/srv/apps" "$tmpdir/srv/$pointer_rel" ".kasbah traefik mail data backups" \
    kasbah-backup kasbah-backup-cache kasbah-backup_default \
    "$BEGIN" "$END" "remote-deploy.sh setup-env.sh" "MAIL_HOSTNAME DOMAIN DATA_PATH" 2>&1)
rows=$(base64 -d <<<"$(fact projects_b64)")
assert 'grep -qF "$(b64 old-site) dir" <<<"$rows"' \
    "old-site, one character from Old-Site, is described as a project (rows: $rows)"
assert '[ "$(fact project_count)" = 3 ]' "and counted (got '$(fact project_count)')"
make_tree

# The paired positive for the sentinel count: the same probe over the same tree
# with the block taken out reports 0, so `2` above is the count and not a
# constant.
printf 'DB_PASSWORD=x\n' > "$tmpdir/srv/apps/demo/.env"
probe_out=$(env -i PATH="$stub:/usr/bin:/bin" bash "$probe" \
    "$tmpdir/srv/apps" "$tmpdir/srv/$pointer_rel" ".kasbah traefik mail data backups" \
    kasbah-backup kasbah-backup-cache kasbah-backup_default \
    "$BEGIN" "$END" "remote-deploy.sh setup-env.sh" "MAIL_HOSTNAME DOMAIN DATA_PATH" 2>&1)
rows=$(base64 -d <<<"$(fact projects_b64)")
assert '[ "$(grep -cE "^$(b64 demo) dir .* 0\$" <<<"$rows")" = 1 ]' \
    "an .env with no block counts zero sentinels (rows: $rows)"

# --- The command, with a stub ssh -----------------------------------------------------------
#
# Three script steps ride the stub: lib/marker.sh's discovery, the batched probe
# and the act. The act's arguments are recorded, so the exact project list the
# plan decided on is visible as what the far side was asked to touch.
ssh_log="$tmpdir/ssh.log"
act_log="$tmpdir/act.log"
payload_file="$tmpdir/payload"
cat > "$stub/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
case "$last" in true) exit 0 ;; esac
case "$*" in *"-O exit"*) exit 0 ;; esac
n=0
[ ! -f "$SSH_COUNT" ] || n=$(cat "$SSH_COUNT")
n=$((n + 1)); printf '%s' "$n" > "$SSH_COUNT"
if [ "$n" = 1 ]; then
    printf 'apps=/apps\nsource=default\n'
    printf '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2","mem_limit":"2g"}\n'
    exit 0
fi
if [ "$n" = 2 ]; then
    cat "$SSH_PAYLOAD"
    exit 0
fi
eval "set -- $last"
shift 3
{ printf 'apps=%s\npointer=%s\n' "$1" "$2"; } > "$SSH_ACT_LOG"
shift 11
for name in "$@"; do printf 'name=%s\n' "$name" >> "$SSH_ACT_LOG"; done
printf 'started=yes\n'
printf 'bk_down=%s\nbk_down_detail=\n' "${SSH_BK_DOWN:-ok}"
printf 'bk_container=%s\n' "${SSH_BK_CONTAINER:-removed}"
printf 'bk_volume=removed\nbk_network=%s\nbk_files=removed\n' "${SSH_BK_NETWORK:-removed}"
for name in "$@"; do
    printf 'project=%s removed removed removed removed removed %s\n' "$name" "${SSH_PROJ_ENV:-stripped}"
done
printf 'mail_env=%s\nmail_env_n=3\nmail_registry=removed\n' "${SSH_MAIL_ENV:-stripped}"
# The same rule the real payload applies: anything that did not do what it was
# asked holds the marker and the pointer back.
held=no
[ "${SSH_BK_DOWN:-ok}" = ok ] || held=yes
[ "${SSH_MAIL_ENV:-stripped}" != unreadable ] || held=yes
[ "${SSH_PROJ_ENV:-stripped}" != unreadable ] || held=yes
if [ "$held" = yes ]; then
    printf 'marker=held\nkasbah_dir=held\npointer=held\npointer_dir=held\n'
else
    printf 'marker=removed\nkasbah_dir=removed\npointer=%s\npointer_dir=%s\n' \
        "${SSH_POINTER:-removed}" "${SSH_POINTER:-removed}"
fi
printf 'done=yes\n'
exit 0
STUB
chmod 0755 "$stub/ssh"

row() {   # row <name> <vlog> <vloggz> <scripts> <helpers> <others> <lock> <client> <env> <sentinels>
    printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
        "$(b64 "$1")" dir "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}
rows_full="$(row alpha ok ok dir 2 0 empty ok ok 2)
$(row beta ok missing dir 2 0 missing ok ok 2)"
rows_clean="$(row alpha missing missing absent 0 0 missing missing ok 0)"

write_payload() {   # write_payload <rows> <count>
    {
        printf 'have_docker=yes\ndocker_error=\n'
        printf 'apps_state=dir\n'
        printf 'marker_state=%s\n' "${P_MARKER:-ok}"
        printf 'kasbah_dir=%s\n' "${P_KASBAH_DIR:-dir}"
        printf 'kasbah_extra_b64=%s\n' "$(b64 "${P_KASBAH_EXTRA:-}")"
        printf 'backup_dir=%s\n' "${P_BACKUP_DIR:-dir}"
        printf 'backup_container=%s\n' "${P_BACKUP_CONTAINER:-running}"
        printf 'backup_volume=%s\n' "${P_BACKUP_VOLUME:-present}"
        printf 'backup_network=%s\n' "${P_BACKUP_NETWORK:-present}"
        printf 'pointer_state=%s\n' "${P_POINTER:-ok}"
        printf 'pointer_dir=%s\npointer_dir_other=%s\n' "${P_POINTER_DIR:-dir}" "${P_POINTER_OTHER:-0}"
        printf 'sudo_state=%s\n' "${P_SUDO:-yes}"
        printf 'mail_dir=%s\n' "${P_MAIL_DIR:-dir}"
        printf 'mail_env_state=ok\nmail_env_extra=%s\n' "${P_MAIL_EXTRA:-4}"
        printf 'mail_registry_state=%s\n' "${P_MAIL_REGISTRY:-ok}"
        printf 'project_count=%s\n' "$2"
        printf 'projects_b64=%s\n' "$(b64 "$1")"
        printf 'skipped_b64=%s\n' "$(b64 "${P_SKIPPED:-}")"
    } > "$payload_file"
}

mkdir -p "$tmpdir/home"
destroy_cli() {
    : > "$ssh_log"; : > "$act_log"; rm -f "$tmpdir/ssh.count"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub:$PATH" SSH_LOG="$ssh_log" \
        SSH_COUNT="$tmpdir/ssh.count" SSH_ACT_LOG="$act_log" SSH_PAYLOAD="$payload_file" \
        SSH_BK_DOWN="${SSH_BK_DOWN:-ok}" SSH_BK_CONTAINER="${SSH_BK_CONTAINER:-removed}" \
        SSH_BK_NETWORK="${SSH_BK_NETWORK:-removed}" SSH_MAIL_ENV="${SSH_MAIL_ENV:-stripped}" \
        SSH_PROJ_ENV="${SSH_PROJ_ENV:-stripped}" SSH_POINTER="${SSH_POINTER:-removed}" \
        "$KASBAH_BIN" server destroy "$@" 2>&1
}
act_names() { sed -n 's/^name=//p' "$act_log" | LC_ALL=C sort | tr '\n' ' '; }

write_payload "$rows_full" 2

# The plan, then the exact project set the act was given.
out=$(destroy_cli deploy@vps --yes </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "a destroy that does what it planned exits 0 (rc=$rc)
$out"
assert '[ "$(act_names)" = "alpha beta " ]' \
    "the act is given exactly the projects the probe described (got '$(act_names)')"
assert 'grep -qF "stopped the kasbah-backup stack" <<<"$out"' "the report says the backup stack was stopped"
assert 'grep -qF "removed the server marker" <<<"$out"' "and that the marker went"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' "and the discovery pointer"
assert 'grep -qF "plain Docker Compose host now" <<<"$out"' "and it closes on a clean run's claim"

# The two directories destroy can only remove when it wrote everything in them.
# Both facts come back from the probe; without these lines nothing read either,
# and an unread fact is one that can go wrong unnoticed.
assert 'grep -qF "/apps/.kasbah/ itself, which holds nothing else" <<<"$out"' \
    "the plan says <apps>/.kasbah/ goes when it holds nothing else (got '$out')"
assert 'grep -qF "/etc/kasbah/ with it, which holds nothing else" <<<"$out"' \
    "and /etc/kasbah/ likewise"
out2=$(P_KASBAH_EXTRA="from-a-newer-kasbah.json " P_POINTER_OTHER=2 write_payload "$rows_full" 2
       destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF ".kasbah/ itself stays — it also holds from-a-newer-kasbah.json" <<<"$out2"' \
    "and names what keeps it when there is something else in it (got '$out2')"
assert 'grep -qF "/etc/kasbah/ itself stays — it holds 2 other file(s)" <<<"$out2"' \
    "and counts what keeps /etc/kasbah"
write_payload "$rows_full" 2

# The plan's per-project line reads as a list. `IFS=', '` joins on the first
# character of IFS alone, which produced a comma-run with no spaces — found by
# reading a real run's output, not by any assertion that existed then.
assert 'grep -qF "versions.log, versions.log.gz, " <<<"$out"' \
    "the plan lists a project's artifacts separated by \", \" (got: $(grep -F "  alpha " <<<"$out"))"

# "absent" means two different things for the two objects `docker compose down`
# removes itself, and one sentence for both would describe a run that did not
# happen: the plan had just said the container was running.
out2=$(SSH_BK_CONTAINER=absent SSH_BK_NETWORK=absent destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "went down with the stack" <<<"$out2"' \
    "a container gone after a \`down\` that ran is reported as \`down\` doing its job (got '$out2')"
assert '! grep -qF "there was no kasbah-backup container" <<<"$out2"' \
    "and never as \"there was none\", which the plan had just contradicted"
out2=$(P_BACKUP_DIR=absent P_BACKUP_CONTAINER=absent write_payload "$rows_full" 2
       SSH_BK_DOWN=skipped SSH_BK_CONTAINER=absent SSH_BK_NETWORK=absent destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "there was no kasbah-backup container" <<<"$out2"' \
    "while on a server that never had a stack, there was none (got '$out2')"
write_payload "$rows_full" 2

# The report reads in the order the far side did the work — a failure printed
# above the step that preceded it on the server is a report about a run that did
# not happen (docs/phases/08-keep.md → 8.1, defect A).
order=$(grep -nE "kasbah-backup stack|^  alpha:|^  beta:|mail/kasbah.yml|server marker|/etc/kasbah/apps-path" <<<"$out" | cut -d: -f1 | tr '\n' ' ')
assert '[ "$order" = "$(printf "%s" "$order" | tr " " "\n" | sort -n | tr "\n" " ")" ]' \
    "the report's own lines are in the far side's order (line numbers: $order)"

# The closing claim is only made on a clean run: 8.1 shipped a failed run whose
# last line said it had succeeded.
out=$(SSH_BK_DOWN=failed destroy_cli deploy@vps --yes </dev/null); rc=$?
assert '[ "$rc" = 1 ]' "a run whose backup stack would not stop exits 1 (rc=$rc)"
assert '! grep -qF "plain Docker Compose host now" <<<"$out"' \
    "and never claims the server is handed over (got '$out')"
assert 'grep -qF "was not fully de-branded" <<<"$out"' "it says what happened instead"
assert 'grep -qF "kept the server marker" <<<"$out"' "and that the marker was kept so a re-run can find the server"
assert 'grep -qF "destroy deploy@vps" <<<"$out"' "naming the command that picks up what is left"
order=$(grep -nE "FAILED: docker compose|^  alpha:|kept the server marker" <<<"$out" | cut -d: -f1 | tr '\n' ' ')
assert '[ "$order" = "$(printf "%s" "$order" | tr " " "\n" | sort -n | tr "\n" " ")" ]' \
    "and the failure path prints in the far side's order too (line numbers: $order)"

# --- The three closing paragraphs ------------------------------------------------------------
#
# The last sentence of the report is a claim about the state the run leaves, and
# there are three states. A run that left an agency secret behind printing the
# clean one — and exiting 0 — is the defect this command can least afford, since
# the same run removes the marker and a second run would then call the server
# clean while `RELAY_PASSWORD=` is still in <apps>/mail/.env.
out=$(SSH_MAIL_ENV=unreadable destroy_cli deploy@vps --yes </dev/null); rc=$?
assert '[ "$rc" = 1 ]' "a mail .env that could not be rewritten fails the run (rc=$rc)
$out"
assert '! grep -qF "plain Docker Compose host now" <<<"$out"' \
    "and never claims the server is handed over (got '$out')"
assert 'grep -qF "was not fully de-branded" <<<"$out"' "it says what happened instead"
assert 'grep -qF "relay credential in it is still on this server" <<<"$out"' \
    "naming the secret that is still there (got '$out')"
assert 'grep -qF "kept the server marker" <<<"$out"' \
    "and the marker is held, so the server stays findable and the run can be repeated"

out=$(SSH_PROJ_ENV=unreadable destroy_cli deploy@vps --yes </dev/null); rc=$?
assert '[ "$rc" = 1 ]' "a project .env that could not be rewritten fails the run too (rc=$rc)"
assert '! grep -qF "plain Docker Compose host now" <<<"$out"' "with no clean claim (got '$out')"
assert 'grep -qF "kept the server marker" <<<"$out"' "and the marker held"
# The per-project line is the operator's only view of *which* file it was, and
# it has to read as the failure it is rather than as a step that chose to skip.
assert 'grep -qF "FAILED: .env could not be read or written" <<<"$out"' \
    "and the project line says FAILED, not \"left alone\" (got '$out')"
assert 'grep -qF "still carries the comment saying kasbah rewrites the block" <<<"$out"' \
    "naming what is now false in it"

# nosudo is exit 0 by spec (docs/cli.md), and that is exactly why it needs a
# closing sentence of its own: the clean paragraph is false on it.
out=$(SSH_POINTER=nosudo destroy_cli deploy@vps --yes </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "a run with no passwordless sudo still exits 0 (rc=$rc)
$out"
assert '! grep -qF "nothing kasbah installed is left" <<<"$out"' \
    "but it does not claim nothing of kasbah's is left, because something is (got '$out')"
assert 'grep -qF "one file short of a plain Docker Compose host" <<<"$out"' \
    "it says exactly what is short (got '$out')"
assert 'grep -qF "sudo rm -f /etc/kasbah/apps-path" <<<"$out"' \
    "and closes on the command that finishes the job"

# The clean run still gets the clean sentence, so the two above are the states
# and not a paragraph that never prints.
out=$(destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "nothing kasbah installed is left" <<<"$out"' \
    "and a run that removed everything still says so (got '$out')"

# --- Entries under <apps> that are not projects ------------------------------------------------
out=$(P_SKIPPED="Notes.txt README.md " write_payload "$rows_full" 2
      destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "Notes.txt README.md under /apps — not a project name" <<<"$out"' \
    "the plan says out loud what it walked past (got '$out')"
assert '[ "$(act_names)" = "alpha beta " ]' \
    "and they are nowhere near the act (got '$(act_names)')"
write_payload "$rows_full" 2

# --- The act's rows are matched by name, not counted -------------------------------------------
# Two rows for one project and none for the other is the same count, and the
# report is keyed by name — it would print one project's verdicts under
# another's heading.
cp "$stub/ssh" "$tmpdir/ssh.good"
sed -i 's/^for name in "\$@"; do$/for name in "$1" "$1"; do/' "$stub/ssh"
out=$(destroy_cli deploy@vps --yes </dev/null); rc=$?
cp "$tmpdir/ssh.good" "$stub/ssh"
assert '[ "$rc" != 0 ]' "a step that reported the wrong projects is refused (rc=$rc)"
assert 'grep -qF "where the plan named" <<<"$out"' \
    "naming the disagreement rather than counting to the same number (got '$out')"

# --- A refusal that changed nothing is not "some of it may have run" ---------------------------
cp "$stub/ssh" "$tmpdir/ssh.good"
sed -i "s#^printf 'started=yes.*#printf 'remote: refusing to act\\n' >\&2; exit 1#" "$stub/ssh"
out=$(destroy_cli deploy@vps --yes </dev/null); rc=$?
cp "$tmpdir/ssh.good" "$stub/ssh"
assert '[ "$rc" != 0 ]' "a payload that refused before starting fails the run (rc=$rc)"
assert 'grep -qF "refused before changing anything" <<<"$out"' \
    "and is diagnosed as having changed nothing (got '$out')"
assert '! grep -qF "some of it may have run" <<<"$out"' \
    "not as damage to go looking for"
# The paired positive: a payload that got past its guards and then died mid-way
# gets the other sentence.
cp "$stub/ssh" "$tmpdir/ssh.good"
sed -i "s#^printf 'bk_down=%s.*#exit 1#" "$stub/ssh"
out=$(destroy_cli deploy@vps --yes </dev/null); rc=$?
cp "$tmpdir/ssh.good" "$stub/ssh"
assert 'grep -qF "some of it may have run" <<<"$out"' \
    "while one that died after starting gets the other sentence (got '$out')"

# --- The plan does not promise what the run cannot do --------------------------------------
#
# Without passwordless sudo the pointer is skipped, so promising to remove the
# directory holding it one line later is a plan arguing with itself.
out2=$(P_SUDO=no write_payload "$rows_full" 2
       destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "sudo -n\` is not available here" <<<"$out2"' \
    "the plan says the pointer will be skipped (got '$out2')"
assert '! grep -qF "/etc/kasbah/ with it" <<<"$out2"' \
    "and does not promise /etc/kasbah/ in the same breath (got '$out2')"
# The paired positive, one fact changed: with sudo the same plan does promise it.
out2=$(P_SUDO=yes write_payload "$rows_full" 2
       destroy_cli deploy@vps --yes </dev/null)
assert 'grep -qF "/etc/kasbah/ with it" <<<"$out2"' \
    "while with sudo it does (got '$out2')"
write_payload "$rows_full" 2

# --- Both no-TTY refusals -----------------------------------------------------------------
#
# The tri-state's give-up branch, twice: destroy asks two questions, and neither
# may be assumed. `--yes` answers both, and it is the flag both refusals must
# name (docs/overview.md → Interactivity).
out=$(destroy_cli deploy@vps </dev/null); rc=$?
assert '[ "$rc" = 1 ]' "with no terminal and no --yes, destroy stops (rc=$rc)"
assert 'grep -qF -- "--yes" <<<"$out"' "naming the flag that would have answered (got '$out')"
assert 'grep -qF "de-brand deploy@vps?" <<<"$out"' "and quoting the question it could not ask"
assert '[ ! -s "$act_log" ]' "and the act step never ran"
assert 'grep -qF "to remove" <<<"$out"' "while the plan was printed first, so the question was about something"

# The second question, reached by answering the first. A pty, because that is
# the branch an operator actually meets; script(1) merges the streams and turns
# every \n into \r\n, hence the strip.
run_tty() {   # run_tty <input> <args...>
    local input="$1"; shift
    local cmd
    : > "$ssh_log"; : > "$act_log"; rm -f "$tmpdir/ssh.count"
    cmd="$(printf '%q ' env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub:$PATH" SSH_LOG="$ssh_log" \
        SSH_COUNT="$tmpdir/ssh.count" SSH_ACT_LOG="$act_log" SSH_PAYLOAD="$payload_file" \
        SSH_BK_DOWN=ok "$KASBAH_BIN" server destroy "$@")"
    tty_out=$(printf '%s' "$input" | script -qec "$cmd" /dev/null 2>&1)
    tty_rc=$?
    tty_out=${tty_out//$'\r'/}
}
if command -v script >/dev/null; then
    run_tty $'n\n' deploy@vps
    assert '[ "$tty_rc" = 1 ]' "declining the first question ends the run (rc=$tty_rc)"
    assert 'grep -qF "not confirmed" <<<"$tty_out"' "and says so rather than exiting in silence (got '$tty_out')"
    assert '[ ! -s "$act_log" ]' "and nothing was asked of the server"

    run_tty $'y\nsomething-else\n' deploy@vps
    assert '[ "$tty_rc" = 1 ]' "a hostname typed wrong ends the run (rc=$tty_rc)"
    assert 'grep -qF "that is not vps" <<<"$tty_out"' "naming what was expected (got '$tty_out')"
    assert '[ ! -s "$act_log" ]' "and nothing was asked of the server"

    run_tty $'y\nvps\n' deploy@vps
    assert '[ "$tty_rc" = 0 ]' "the hostname typed back runs it (rc=$tty_rc: $tty_out)"
    assert 'grep -qF "type the hostname (vps) to confirm:" <<<"$tty_out"' \
        "and the question asked for the hostname, not the project name (got '$tty_out')"
    assert '[ "$(act_names)" = "alpha beta " ]' "and the act ran over both projects"

    # A second decline at the typed prompt is never offered: a name that is not
    # the one asked for is an answer, not a typo (lib/prompt.sh).
    run_tty $'y\nnope\nvps\n' deploy@vps
    assert '[ "$(grep -c "type the hostname" <<<"$tty_out")" = 1 ]' \
        "the typed question is asked once (got '$tty_out')"
fi

# --- A server with no marker at all ----------------------------------------------------------
#
# What a completed destroy leaves — so it must not error — but "carries nothing
# of kasbah's" is a claim, and a marker removed **by hand** leaves this command
# unable to enumerate anything while the backup credentials are still sitting at
# mode 600. A clean bill of health that is wrong is worse than no bill at all.
cat > "$stub/ssh" <<'STUB'
#!/usr/bin/env bash
last="${!#}"
case "$last" in true) exit 0 ;; esac
case "$*" in *"-O exit"*) exit 0 ;; esac
n=0
[ ! -f "$SSH_COUNT" ] || n=$(cat "$SSH_COUNT")
n=$((n + 1)); printf '%s' "$n" > "$SSH_COUNT"
if [ "$n" = 1 ]; then
    # lib/marker.sh's discovery, on a server with no marker: exit 3.
    printf 'apps=/apps
source=default
'
    exit 3
fi
# The leftovers probe.
printf 'pointer=%s
' "${SSH_LEFT_POINTER:-no}"
[ -z "${SSH_LEFT_KASBAH:-}" ] || printf 'kasbah=%s
' "$SSH_LEFT_KASBAH"
[ -z "${SSH_LEFT_CREDS:-}" ] || printf 'creds=%s
' "$SSH_LEFT_CREDS"
exit 0
STUB
chmod 0755 "$stub/ssh"
nomarker() {
    rm -f "$tmpdir/ssh.count"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub:$PATH" SSH_COUNT="$tmpdir/ssh.count" \
        SSH_LEFT_POINTER="${SSH_LEFT_POINTER:-no}" SSH_LEFT_KASBAH="${SSH_LEFT_KASBAH:-}" \
        SSH_LEFT_CREDS="${SSH_LEFT_CREDS:-}" \
        "$KASBAH_BIN" server destroy deploy@vps 2>&1
}
out=$(nomarker </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "a server with no marker and nothing left exits 0 (rc=$rc: $out)"
assert 'grep -qF "carries nothing of" <<<"$out"' "and says so (got '$out')"
assert 'grep -qF "no .kasbah directory" <<<"$out"' "having said it looked (got '$out')"

# Credentials that outlived the marker are a **failure**, not a report. This is
# the same grading _sd_report_act applies one function over: an unreadable .env
# exits 1 and holds the marker, `nosudo` keeps its spec'd exit 0. A handover
# script spelled `kasbah server destroy "$h" && mark_handed_over "$h"` marks the
# machine handed over on exit 0 — while the departing operator's repository URL
# and one password per repository sit on it at mode 600 and the scheduler pushes
# the new owner's data to them at the next 02:00 slot.
out=$(SSH_LEFT_CREDS=/apps/.kasbah/backup SSH_LEFT_KASBAH=/apps/.kasbah nomarker </dev/null); rc=$?
assert '[ "$rc" != 0 ]' \
    "a marker removed by hand over live backup credentials is a failure, not a clean run (rc=$rc: $out)"
assert '! grep -qF "carries nothing of" <<<"$out"' \
    "and is never called clean while they are still on it (got '$out')"
assert 'grep -qF "/apps/.kasbah/backup is still there" <<<"$out"' "naming them (got '$out')"
assert 'grep -qF "password per repository, at mode 600" <<<"$out"' "and what they are (got '$out')"
assert 'grep -qF "rm -rf /apps/.kasbah/backup" <<<"$out"' "and the command that takes them off"

# The other two leftovers are a discovery hint and a directory — world-readable,
# no secret — so they stay at exit 0, which is what `nosudo` is specified to do
# about the very same pointer (docs/cli.md). Split from the case above because
# one assertion covering both could only pin the weaker of the two answers.
out=$(SSH_LEFT_POINTER=yes nomarker </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "a pointer that outlived the marker is reported, at exit 0 (rc=$rc: $out)"
assert '! grep -qF "carries nothing of" <<<"$out"' \
    "and the server is not called clean while it is there (got '$out')"
assert 'grep -qF "sudo rm -f /etc/kasbah/apps-path" <<<"$out"' "naming the command that removes it"
out=$(SSH_LEFT_KASBAH=/apps/.kasbah nomarker </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "and so is a .kasbah directory with nothing secret in it (rc=$rc: $out)"
assert '! grep -qF "carries nothing of" <<<"$out"' \
    "nor is a server carrying one called clean (got '$out')"
cp "$tmpdir/ssh.good" "$stub/ssh" 2>/dev/null || true

# --- Nothing left to do ---------------------------------------------------------------------
#
# A server whose marker is still there but that carries nothing else of kasbah's:
# the run must say so and ask nothing, rather than confirm an empty plan.
P_MARKER=missing P_KASBAH_DIR=absent P_BACKUP_DIR=absent P_BACKUP_CONTAINER=absent \
P_BACKUP_VOLUME=absent P_BACKUP_NETWORK=absent P_POINTER=missing \
P_MAIL_DIR=absent P_MAIL_EXTRA=0 P_MAIL_REGISTRY=missing \
    write_payload "$rows_clean" 1
out=$(destroy_cli deploy@vps </dev/null); rc=$?
assert '[ "$rc" = 0 ]' "a server with nothing of kasbah's left exits 0 (rc=$rc: $out)"
assert 'grep -qF "nothing of kasbah is left" <<<"$out"' "and says so (got '$out')"
assert '! grep -qF "type the hostname" <<<"$out"' "with no confirmation, since there is nothing to confirm"
assert '[ ! -s "$act_log" ]' "and the act step never ran"

# The paired positive, one fact changed: put the discovery pointer back and the
# same server has work again — so "nothing to do" is a reading of the facts and
# not a payload the command cannot see.
P_MARKER=missing P_KASBAH_DIR=absent P_BACKUP_DIR=absent P_BACKUP_CONTAINER=absent \
P_BACKUP_VOLUME=absent P_BACKUP_NETWORK=absent P_POINTER=ok \
P_MAIL_DIR=absent P_MAIL_EXTRA=0 P_MAIL_REGISTRY=missing \
    write_payload "$rows_clean" 1
out=$(destroy_cli deploy@vps </dev/null); rc=$?
assert '[ "$rc" = 1 ]' "with the pointer still there it asks again (rc=$rc)"
assert 'grep -qF -- "--yes" <<<"$out"' "and stops on the unanswered question (got '$out')"

exit "$fail"
