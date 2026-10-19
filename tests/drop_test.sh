#!/usr/bin/env bash
# Test: lib/drop.sh — `kasbah drop [--prune]`, everything that does not need a
# server, plus lib/prompt.sh's prompt_typed as drop uses it.
#
# Five layers, because the command has five:
#   * the pure parts (flag parsing, the project-name shape check), driven
#     straight through the library;
#   * the **act payload's own** name check, extracted from its heredoc and run
#     against a real directory tree — that block builds two `rm -rf` paths out
#     of an argument it did not assemble, and it is the most dangerous line in
#     the command;
#   * the read payload, likewise extracted, against a fake apps tree and a stub
#     docker;
#   * the command itself, through the CLI with a stub ssh that answers the
#     marker read, hands back a crafted probe block and records what the act
#     step was asked to do — which is what fixes the **exact removal set**;
#   * the two confirmations, over a real pty, including the one answered wrong.
#
# **This is a destructive command, so the bar is what it does not remove.**
# Every "X was not removed" assertion is paired with a positive one that pins
# the same mechanism from the other side — two repositories in the same project,
# differing only in the one fact under test — because a negative assertion is
# vacuous by default (docs/phases/07-operate.md → the phase close).
#
# The rig-driven half — that a real `docker compose down` really stops the
# stack, that the tags really leave a daemon, and that a redeploy brings the
# data back — is in tests/integration/drop_test.sh.

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

if ! command -v yq >/dev/null || ! command -v jq >/dev/null; then
    echo "error: this suite needs yq and jq" >&2
    exit 2
fi

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="0.1.0-test"
export NO_COLOR=1

b64() { printf '%s' "$1" | base64 -w0; }

# One REMOTE heredoc out of lib/drop.sh, by ordinal: the file carries two, and
# `sed -n '/<<.REMOTE./,/^REMOTE$/p'` would run them together.
extract_remote() {   # extract_remote <n> <outfile>
    awk -v want="$1" '
        /<<'"'"'REMOTE'"'"'$/ { n++; if (n == want) { inb = 1; next } }
        /^REMOTE$/            { inb = 0 }
        inb                   { print }
    ' "$repo_dir/lib/drop.sh" > "$2"
}

# --- Driver -------------------------------------------------------------------------
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
# `set -e` like the dispatcher: a helper that dies under errexit before its own
# caller can decide what the failure means is a defect this driver reproduces.
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/drop.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _drop_parse_args "$@"
        printf 'target=%s\nprune=%s\nyes=%s\n' "$_DROP_TARGET" "$_DROP_PRUNE" "$_DROP_YES"
        ;;
    manifest)
        # The whole of drop's own name check on this side: lib/manifest.sh's,
        # reached through manifest_require exactly as cmd_drop reaches it.
        cd "$2" || exit 9
        printf 'schema: 1\nkasbah_version: 0.1.0\nname: %s\ndomain: x.test\n' "$1" > kasbah.yml
        manifest_require
        printf 'name=%s\n' "$MANIFEST_NAME"
        ;;
    typed)
        # prompt_typed's own contract, without a command around it.
        if prompt_typed yes "$1" "$2" "${3:-}"; then printf 'typed=match\n'
        else printf 'typed=mismatch\n'; fi
        ;;
esac
DRV
drive() { bash "$driver" "$@" 2>&1; echo "rc=$?"; }

# --- Flags ----------------------------------------------------------------------------
out=$(drive parse deploy@vps)
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is the positional argument (got '$out')"
assert 'grep -qxF "prune=no" <<<"$out"' "and without --prune the drop is the reversible one (got '$out')"
assert 'grep -qxF "yes=" <<<"$out"' "and without --yes the answer is unset, which means *ask* (got '$out')"
out=$(drive parse deploy@vps --prune --yes)
assert 'grep -qxF "prune=yes" <<<"$out"' "--prune is read (got '$out')"
assert 'grep -qxF "yes=yes" <<<"$out"' "and --yes is the scriptable answer (got '$out')"
out=$(drive parse)
assert 'grep -qxF "target=" <<<"$out"' "no target is not an error here — last_server answers it later (got '$out')"
out=$(drive parse deploy@vps --prune=yes)
assert 'grep -qxF "rc=1" <<<"$out"' "--prune=yes is refused (got '$out')"
assert 'grep -qF "takes no value" <<<"$out"' "as the flag it is, spelled wrong (got '$out')"
out=$(drive parse deploy@vps --force)
assert 'grep -qF "unknown flag" <<<"$out"' "an unknown flag is refused rather than ignored (got '$out')"
out=$(drive parse deploy@vps other@vps)
assert 'grep -qF "two servers given" <<<"$out"' "two targets are refused (got '$out')"
out=$(drive parse demo)
assert 'grep -qxF "rc=1" <<<"$out"' "a bare word is not a target (got '$out')"
assert 'grep -qF "is not a USER@HOST" <<<"$out"' "and says so rather than guessing (got '$out')"

# --- The project name, on the outer edge -------------------------------------------------
#
# drop keeps no name check of its own: lib/manifest.sh already enforces the
# shape `rm -rf "$apps/$name"` needs, and cmd_drop reaches it through
# manifest_require before anything else happens. This is that edge; the inner
# one — the act payload, which can source nothing — is the block further down.
mdir="$tmpdir/manifest"
mkdir -p "$mdir"
out=$(drive manifest demo-app "$mdir")
assert 'grep -qxF "name=demo-app" <<<"$out"' "an ordinary project name passes (got '$out')"
for bad in "." ".." "../etc" "a/b" "Demo" "1demo" "-demo" "de mo" "demo;rm"; do
    out=$(drive manifest "$bad" "$mdir")
    assert 'grep -qxF "rc=1" <<<"$out"' "'$bad' never gets past the manifest (got '$out')"
    assert 'grep -qF "invalid name" <<<"$out"' "and is refused as the shape it is (got '$out')"
done
for reserved in traefik mail data backups; do
    out=$(drive manifest "$reserved" "$mdir")
    assert 'grep -qxF "rc=1" <<<"$out"' "'$reserved' is a directory kasbah owns, not a project (got '$out')"
    assert 'grep -qF "kasbah owns" <<<"$out"' "and the refusal says why (got '$out')"
done
assert '! grep -q "_drop_check_name" "$repo_dir/lib/drop.sh"' \
    "and lib/drop.sh keeps no second copy of that check, which manifest_require makes unreachable"

# --- The act payload'"'"'s reserved list, pinned to the one in lib/manifest.sh ----------
#
# A payload on the far side of ssh can source nothing, so the copy is forced —
# and an unpinned copy is how `mail` stops being refused on the day the list
# grows. tests/norm_path_test.sh pins its four copies the same way.
payload_reserved=$(sed -n "s/^case \" \(.*\) \" in\$/\1/p" "$repo_dir/lib/drop.sh")
lib_reserved=$(sed -n "s/^KASBAH_RESERVED_NAMES=(\(.*\))\$/\1/p" "$repo_dir/lib/manifest.sh")
assert '[ -n "$payload_reserved" ] && [ -n "$lib_reserved" ]' \
    "both reserved lists were found (payload: '$payload_reserved', lib: '$lib_reserved')"
assert '[ "$payload_reserved" = ".kasbah $lib_reserved" ] || [ "$payload_reserved" = "$lib_reserved .kasbah" ]' \
    "the act payload refuses exactly KASBAH_RESERVED_NAMES plus .kasbah
        payload: $payload_reserved
        lib:     $lib_reserved"

# --- prompt_typed ----------------------------------------------------------------------
out=$(drive typed demo "type it:" yes)
assert 'grep -qxF "typed=match" <<<"$out"' "--yes answers the typed confirmation too (got '$out')"
out=$(drive typed demo "type it:" </dev/null)
assert 'grep -qxF "rc=1" <<<"$out"' "without a flag and without a terminal it stops (got '$out')"
assert 'grep -qF -- "--yes" <<<"$out"' "naming the flag that would have answered (got '$out')"
assert '! grep -qF "typed=" <<<"$out"' "and answers nothing (got '$out')"
out=$(drive typed demo "type it:" no)
assert 'grep -qxF "rc=1" <<<"$out"' "a 'no' is not an answer this prompt has (got '$out')"
assert 'grep -qF "expected yes or empty" <<<"$out"' "and is diagnosed as the caller mistake it is (got '$out')"

# A real terminal for the branch an operator actually meets. script(1) merges
# the session's streams and turns every \n into \r\n, hence the strip.
run_tty() {   # run_tty <input> <args...>
    local input="$1"; shift
    local cmd
    cmd="$(printf '%q ' bash "$driver" "$@")"
    tty_out=$(printf '%s' "$input" | script -qec "$cmd" /dev/null 2>&1)
    tty_rc=$?
    tty_out=${tty_out//$'\r'/}
}
run_tty $'demo\n' typed demo "type the project name (demo) to confirm:"
assert '[ "$tty_rc" = 0 ]' "the name typed back is a match (exit $tty_rc)"
assert 'grep -qF "typed=match" <<<"$tty_out"' "and the caller is told so (got '$tty_out')"
assert 'grep -qF "type the project name (demo) to confirm:" <<<"$tty_out"' \
    "the question reaches the terminal (got '$tty_out')"
run_tty $'other\n' typed demo "type the name:"
assert 'grep -qF "typed=mismatch" <<<"$tty_out"' "a different name is a decline (got '$tty_out')"
run_tty $'\n' typed demo "type the name:"
assert 'grep -qF "typed=mismatch" <<<"$tty_out"' "and so is an empty line (got '$tty_out')"
run_tty $'demo\ndemo\n' typed demo "type the name:"
assert '[ "$(grep -c "type the name:" <<<"$tty_out")" = 1 ]' \
    "the question is asked once — a mismatch is an answer, not a typo to re-ask (got '$tty_out')"
run_tty '' typed demo "type the name:"
assert '[ "$tty_rc" != 0 ]' "EOF at the prompt fails rather than proceeding (exit $tty_rc)"
assert 'grep -qF -- "--yes" <<<"$tty_out"' "naming the flag (got '$tty_out')"

# --- The act payload's own name check, against a real tree ---------------------------------
#
# The single most dangerous block in the command: two `rm -rf` paths built from
# an argument the payload did not assemble. It is checked here rather than only
# through the library, because the library is exactly what it must not trust.
act="$tmpdir/act.sh"
extract_remote 2 "$act"
assert '[ -s "$act" ]' "the act step was extracted from lib/drop.sh"
assert 'grep -qF "rm -rf" "$act"' \
    "and it is the block that deletes — every case below is empty theatre otherwise"
assert 'grep -qF "flock -n 9" "$act"' "and the block that takes the deploy lock"

act_stub="$tmpdir/actstub"
mkdir -p "$act_stub"
cat > "$act_stub/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
exit 0
STUB
chmod 0755 "$act_stub/docker"

# A tree shaped like a server's, with a bystander project beside the target so
# that "nothing else was touched" is a measurement over something.
make_tree() {
    rm -rf "$tmpdir/srv"
    mkdir -p "$tmpdir/srv/apps/demo/backups" "$tmpdir/srv/apps/traefik/dynamic" \
             "$tmpdir/srv/apps/mail" "$tmpdir/srv/apps/other" "$tmpdir/srv/data/demo" \
             "$tmpdir/srv/data/other"
    printf 'x\n' > "$tmpdir/srv/apps/demo/compose.yml"
    printf 'x\n' > "$tmpdir/srv/apps/demo/backups/dump.gz"
    printf 'x\n' > "$tmpdir/srv/apps/traefik/dynamic/demo.yml"
    printf 'x\n' > "$tmpdir/srv/apps/traefik/dynamic/other.yml"
    printf 'x\n' > "$tmpdir/srv/apps/other/compose.yml"
    printf 'x\n' > "$tmpdir/srv/data/demo/db.sqlite"
    printf 'x\n' > "$tmpdir/srv/data/other/db.sqlite"
}
tree_digest() { (cd "$tmpdir/srv" && find . | LC_ALL=C sort | md5sum); }
run_act() {   # run_act <name> <prune> [registry]
    env -i PATH="$act_stub:/usr/bin:/bin" \
        bash "$act" "$tmpdir/srv/apps" "$tmpdir/srv/data" "$1" "$2" "${3:-}" 2>&1
}

for bad in "" "." ".." "../other" "de/mo" "Demo" "1demo" "de mo" "traefik" "mail" "data" "backups"; do
    make_tree
    before="$(tree_digest)"
    out=$(run_act "$bad" yes); rc=$?
    assert '[ "$rc" != 0 ]' "the act payload refuses the name '$bad' (rc=$rc: $out)"
    assert 'grep -qF "refusing to act" <<<"$out"' "loudly (got '$out')"
    # `started=yes` is the one thing that separates the caller's two diagnoses,
    # so a guard that refuses must not have printed it (got '$out')
    assert '! grep -qF "started=yes" <<<"$out"' \
        "and never says it started for '$bad' (got '$out')"
    assert '[ "$before" = "$(tree_digest)" ]' \
        "and nothing under the tree changed for '$bad'
        $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$(tree_digest)"))"
done

# The positive counterpart: the same payload, the same tree, a name that passes
# — so the refusals above are the name check and not a payload that never works.
make_tree
out=$(run_act demo yes); rc=$?
assert '[ "$rc" = 0 ]' "a well-formed name runs the act (rc=$rc: $out)"
assert 'grep -qxF "started=yes" <<<"$out"' \
    "a run that got past the guards says so (got '$out')"
assert '[ ! -e "$tmpdir/srv/apps/demo" ]' "--prune deleted the project directory"
assert '[ ! -e "$tmpdir/srv/data/demo" ]' "and the data directory"
assert '[ ! -e "$tmpdir/srv/apps/traefik/dynamic/demo.yml" ]' "and the fragment"
assert '[ -e "$tmpdir/srv/apps/other/compose.yml" ]' "the bystander project is untouched"
assert '[ -e "$tmpdir/srv/data/other/db.sqlite" ]' "and its data"
assert '[ -e "$tmpdir/srv/apps/traefik/dynamic/other.yml" ]' "and its route"
assert 'grep -qxF "config=removed" <<<"$out"' "and the step says what it did (got '$out')"

# The same name without --prune: the reversible half, measured rather than
# claimed. Without this pair, every "--prune deleted it" above would also pass
# on a payload that deletes whatever it is given.
make_tree
out=$(run_act demo no); rc=$?
assert '[ "$rc" = 0 ]' "plain drop runs (rc=$rc: $out)"
assert '[ -e "$tmpdir/srv/apps/demo/compose.yml" ]' "and keeps the project directory"
assert '[ -e "$tmpdir/srv/apps/demo/backups/dump.gz" ]' "and the on-VPS backups inside it"
assert '[ -e "$tmpdir/srv/data/demo/db.sqlite" ]' "and the data"
assert '[ ! -e "$tmpdir/srv/apps/traefik/dynamic/demo.yml" ]' "while the route still goes"
assert '! grep -q "^config=" <<<"$out"' "and it reports no config verdict at all (got '$out')"
assert 'grep -qxF "down=ok" <<<"$out"' "the stack came down (got '$out')"

# The lock, and the prerequisite that makes it possible. A server without flock
# must not have its missing prerequisite read as a concurrent operator — the
# confusion the payload asks about in that order to avoid.
noflock_dir="$tmpdir/noflock"
mkdir -p "$noflock_dir"
# Everything the payload reaches for, and nothing else — `flock` is the one
# name deliberately absent from this PATH.
for tool in bash openssl rm mv chmod tr; do
    src="$(command -v "$tool" 2>/dev/null)" || { echo "error: no $tool on PATH" >&2; exit 2; }
    ln -sf "$src" "$noflock_dir/$tool"
done
ln -sf "$act_stub/docker" "$noflock_dir/docker"
assert '! PATH="$noflock_dir" command -v flock >/dev/null' "the stripped PATH really has no flock"
make_tree
before="$(tree_digest)"
out=$(env -i PATH="$noflock_dir" bash "$act" "$tmpdir/srv/apps" "$tmpdir/srv/data" demo yes "" 2>&1); rc=$?
assert '[ "$rc" != 0 ]' "a server without flock stops the act payload (rc=$rc: $out)"
assert 'grep -qF "flock is not installed" <<<"$out"' "as the missing prerequisite it is (got '$out')"
assert '! grep -qF "already running" <<<"$out"' \
    "and never as a concurrent operator who does not exist (got '$out')"
assert '! grep -qF "started=yes" <<<"$out"' "having refused before it started (got '$out')"
assert '[ "$before" = "$(tree_digest)" ]' "and nothing was removed"

# The same payload with flock back on PATH, so the refusal above is the missing
# binary and not a payload that cannot run under env -i.
make_tree
out=$(run_act demo yes); rc=$?
assert '[ "$rc" = 0 ]' "with flock on PATH the same call runs (rc=$rc: $out)"

# A lock somebody else holds, taken for real against the payload.
if command -v flock >/dev/null; then
    make_tree
    : > "$tmpdir/srv/apps/demo/.deploy.lock"
    before="$(tree_digest)"
    out=$( { flock -n 7 || exit 1; run_act demo yes; } 7>"$tmpdir/srv/apps/demo/.deploy.lock" 2>&1 ); rc=$?
    assert '[ "$rc" != 0 ]' "a held .deploy.lock stops the act payload (rc=$rc: $out)"
    assert 'grep -qF "already running" <<<"$out"' "naming the concurrent run (got '$out')"
    assert '! grep -qF "started=yes" <<<"$out"' "having refused before it started (got '$out')"
    assert '[ "$before" = "$(tree_digest)" ]' "and nothing was removed"
fi

# An absolute-path check that is not about the name.
make_tree
out=$(env -i PATH="$act_stub:/usr/bin:/bin" bash "$act" "apps" "$tmpdir/srv/data" demo yes "" 2>&1)
assert 'grep -qF "not an absolute path" <<<"$out"' "a relative apps path is refused (got '$out')"
out=$(run_act demo maybe)
assert 'grep -qF "neither yes nor no" <<<"$out"' "and so is a prune flag that is neither (got '$out')"

# --- The read payload, run locally --------------------------------------------------------
probe="$tmpdir/probe.sh"
extract_remote 1 "$probe"
assert '[ -s "$probe" ]' "the read step was extracted from lib/drop.sh"
assert 'grep -qF "kv project_count" "$probe"' "and it is the right block"
assert '! grep -qF "rm -rf" "$probe"' "and it removes nothing"

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
case "$1 $2" in
    "version --format") printf '27.3.1\n'; exit 0 ;;
    "images -q")        printf 'sha256:aaa\nsha256:bbb\n'; exit 0 ;;
    "ps -a")
        # Answers with a one-off container unless **both** of compose's own
        # `down` filters are present. A probe that asked on the project label
        # alone would put something in the confirmation that `docker compose
        # down` leaves standing.
        case "$*" in
            *oneoff=False*) printf 'demo-web running\n'; exit 0 ;;
            *)              printf 'demo-web running\ndemo-oneoff exited\n'; exit 0 ;;
        esac ;;
esac
if [ "$1" = image ] && [ "$2" = inspect ]; then
    printf 'sha256:aaa demo-web:current demo-web:1.0.0\n'
    printf 'sha256:bbb nginx:alpine\n'
    exit 0
fi
exit 2
STUB
chmod 0755 "$stub_dir/docker"

apps="$tmpdir/probeapps"
data="$tmpdir/probedata"
mkdir -p "$apps/.kasbah" "$apps/demo/backups" "$apps/traefik/dynamic" "$apps/mail" \
         "$apps/other" "$apps/locked" "$data/demo"
printf 'services:\n  web:\n    build: .\n    image: demo-web:current\n' > "$apps/demo/compose.yml"
printf 'services:\n  web:\n    build: .\n    image: other-web:current\n' > "$apps/other/compose.yml"
: > "$apps/locked/compose.yml"
chmod 0000 "$apps/locked/compose.yml"
printf 'x\n' > "$apps/demo/backups/one.gz"
printf 'x\n' > "$apps/demo/backups/two.gz"
printf 'x\n' > "$apps/traefik/dynamic/demo.yml"
printf 'primary_domain: mail.example.com\ndomains:\n  - demo.test\n' > "$apps/mail/kasbah.yml"
touch "$apps/notaproject"

probe_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" DOCKER_LOG="$tmpdir/docker.log" \
    bash "$probe" "$apps" "$data" demo ".kasbah traefik mail data backups" 2>&1)
probe_rc=$?
fact() { sed -n "s/^$1=//p" <<<"$probe_out"; }
assert '[ "$probe_rc" = 0 ]' "the read step exits 0 (rc=$probe_rc: $probe_out)"
assert '[ "$(fact project_state)" = dir ]' "the project directory is found (got '$(fact project_state)')"
assert '[ "$(fact data_state)" = dir ]' "and its data directory (got '$(fact data_state)')"
assert '[ "$(fact backups_state)" = dir ]' "and its backups directory (got '$(fact backups_state)')"
assert '[ "$(fact backups_count)" = 2 ]' "counted, so --prune can say what it takes (got '$(fact backups_count)')"
assert '[ "$(fact fragment_state)" = ok ]' "and the Traefik fragment (got '$(fact fragment_state)')"
assert '[ "$(fact lock_state)" = free ]' "no deploy holds the lock (got '$(fact lock_state)')"
assert '[ ! -e "$apps/demo/.deploy.lock" ]' "and probing that did not create the lock file"
assert '[ "$(fact project_count)" = 4 ]' \
    "demo, other, locked and the thing that is not a directory are projects; traefik, mail and .kasbah are not (got '$(fact project_count)')"
assert '[ "$(fact mail_dir)" = dir ]' "the mail stack is seen (got '$(fact mail_dir)')"
assert '[ "$(fact mail_registry_state)" = ok ]' "and its registry read (got '$(fact mail_registry_state)')"
img=$(base64 -d <<<"$(fact images_b64)")
assert 'grep -qF "demo-web:current demo-web:1.0.0" <<<"$img"' \
    "every tag an image carries comes back on its line (got '$img')"
con=$(base64 -d <<<"$(fact containers_b64)")
assert 'grep -qF "demo-web running" <<<"$con"' "and the project's own containers (got '$con')"
# The pair: the stub answers with a one-off container unless *both* of compose's
# own `down` filters are asked for, so a probe that dropped `oneoff=False` would
# put something in the confirmation that `docker compose down` leaves standing.
assert '! grep -qF "demo-oneoff" <<<"$con"' \
    "asked with compose's own filters, so a one-off is not in the confirmation (got '$con')"
assert 'grep -qF "oneoff=False" "$tmpdir/docker.log"' \
    "and the probe really passed that filter (log: $(grep "ps -a" "$tmpdir/docker.log" | head -1))"
rows=$(base64 -d <<<"$(fact projects_b64)")
assert '[ "$(grep -cF "$(b64 locked) dir unreadable" <<<"$rows")" = 1 ]' \
    "a compose.yml this user cannot read is unreadable, not missing (rows: $rows)"
assert '[ "$(grep -cF "$(b64 notaproject) notdir" <<<"$rows")" = 1 ]' \
    "and something that is not a directory is reported, not skipped (rows: $rows)"

before=$(cd "$apps" && find . -printf '%p %s %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
env -i PATH="$stub_dir:/usr/bin:/bin" bash "$probe" "$apps" "$data" demo \
    ".kasbah traefik mail data backups" >/dev/null 2>&1
after=$(cd "$apps" && find . -printf '%p %s %m\n' 2>/dev/null | LC_ALL=C sort | md5sum)
assert '[ "$before" = "$after" ]' "the read step changes nothing under the apps path"
verbs=$(sed 's/^\([a-z]*\) \([a-z-]*\).*/\1 \2/' "$tmpdir/docker.log" | LC_ALL=C sort -u)
assert '! grep -qvE "^(version --format|images -q|image inspect|ps -a)$" <<<"$verbs"' \
    "and every docker verb in it is a read (got: $(tr '\n' '|' <<<"$verbs"))"
chmod 0644 "$apps/locked/compose.yml"

# A lock somebody else holds, seen from the probe.
touch "$apps/demo/.deploy.lock"
if command -v flock >/dev/null; then
    ( flock -n 8 || exit 1; probe_held=$(env -i PATH="$stub_dir:/usr/bin:/bin" \
        bash "$probe" "$apps" "$data" demo ".kasbah traefik mail data backups" 2>&1)
      printf '%s' "$probe_held" > "$tmpdir/held.out" ) 8>"$apps/demo/.deploy.lock"
    assert 'grep -qxF "lock_state=held" "$tmpdir/held.out"' \
        "a lock another process holds is reported held (got '$(sed -n "s/^lock_state=//p" "$tmpdir/held.out")')"
fi
probe_out=$(env -i PATH="$stub_dir:/usr/bin:/bin" bash "$probe" "$apps" "$data" demo \
    ".kasbah traefik mail data backups" 2>&1)
assert '[ "$(fact lock_state)" = free ]' \
    "and the same file with nobody on it is free — so 'held' is the lock and not the file (got '$(fact lock_state)')"
rm -f "$apps/demo/.deploy.lock"

# --- The command, with a stub ssh ------------------------------------------------------------
#
# Three script steps ride the stub: the marker read every project command makes,
# the batched probe, and the act. The act's arguments are recorded, so what the
# policy decided is visible as the exact list handed to `docker image rm`.
ssh_log="$tmpdir/ssh.log"
act_log="$tmpdir/act.log"
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
    # lib/marker.sh's discovery step.
    printf 'apps=/apps\nsource=default\n'
    printf '{"kasbah_version":"0.1.0-test","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2","mem_limit":"2g"}\n'
    exit 0
fi
if [ "$n" = 2 ]; then
    cat "$SSH_PAYLOAD"
    exit 0
fi
# The act. Its arguments arrive as one string that ssh would have handed to the
# login shell, quoted by lib/ssh.sh.
eval "set -- $last"
shift 3
act_prune=$4
act_registry=$5
{ printf 'apps=%s\ndata=%s\nname=%s\nprune=%s\n' "$1" "$2" "$3" "$4"
  printf 'registry=%s\n' "$(printf '%s' "$5" | base64 -w0)"; } > "$SSH_ACT_LOG"
shift 5
for ref in "$@"; do printf 'tag=%s\n' "$ref" >> "$SSH_ACT_LOG"; done
# A guard refusing before the payload's own `started=yes`, and a step that dies
# after it: the two shapes the caller has to tell apart.
if [ -n "${SSH_ACT_REFUSE:-}" ]; then
    printf 'remote: refusing to act: %s\n' "$SSH_ACT_REFUSE" >&2
    exit 1
fi
printf 'started=yes\n'
if [ -n "${SSH_ACT_DIE:-}" ]; then
    printf 'fragment=removed\n'
    printf 'remote: %s\n' "$SSH_ACT_DIE" >&2
    exit 1
fi
printf 'fragment=%s\ndown=%s\ndown_detail=\n' "${SSH_FRAGMENT:-removed}" "${SSH_DOWN:-ok}"
printf 'down_left=%s\n' "$(printf '%s' "${SSH_DOWN_LEFT:-}" | base64 -w0)"
for ref in "$@"; do
    if [ "$ref" = "${SSH_RM_FAIL:-}" ]; then
        printf 'failed=%s %s\n' "$(printf '%s' "$ref" | base64 -w0)" \
               "$(printf 'Error response from daemon: conflict: unable to delete' | base64 -w0)"
    else
        printf 'removed=%s\n' "$(printf '%s' "$ref" | base64 -w0)"
    fi
done
if [ "$act_prune" = yes ]; then
    if [ -n "$act_registry" ]; then printf 'mail=written\n'; else printf 'mail=skipped\n'; fi
    printf 'data=removed\nconfig=removed\n'
fi
printf 'done=yes\n'
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

# The project this command is run from.
proj="$tmpdir/project"
mkdir -p "$proj/.kasbah"
cat > "$proj/kasbah.yml" <<'YML'
schema: 1
kasbah_version: 0.1.0
name: alpha
domain: alpha.test
mail:
  domain: alpha.test
YML
printf '{"kasbah_version":"0.1.0-test","last_server":"deploy@vps"}\n' > "$proj/.kasbah/state.json"

mkdir -p "$tmpdir/home"
drop_cli() {
    : > "$ssh_log"; : > "$act_log"; rm -f "$tmpdir/ssh.count"
    ( cd "$proj" && env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_COUNT="$tmpdir/ssh.count" SSH_ACT_LOG="$act_log" SSH_PAYLOAD="$payload_file" \
        SSH_RM_FAIL="${SSH_RM_FAIL:-}" SSH_DOWN_LEFT="${SSH_DOWN_LEFT:-}" \
        SSH_DOWN="${SSH_DOWN:-ok}" SSH_FRAGMENT="${SSH_FRAGMENT:-removed}" \
        SSH_ACT_REFUSE="${SSH_ACT_REFUSE:-}" SSH_ACT_DIE="${SSH_ACT_DIE:-}" \
        "$KASBAH_BIN" drop "$@" 2>&1 )
}
act_tags() { sed -n 's/^tag=//p' "$act_log" | LC_ALL=C sort | tr '\n' ' '; }

# --- The fixture ------------------------------------------------------------------------------
#
# One server, four projects. alpha is the one being dropped; it builds two
# repositories and pulls one stock image. beta builds one of alpha's two — the
# pair that makes the ownership rule visible, since both are alpha's by its own
# compose file and only one of them is alpha's alone.
images='sha256:a10 alpha-web:current alpha-web:1.0.0
sha256:a09 alpha-web:0.9.0
sha256:b10 alpha-api:current alpha-api:1.0.0
sha256:s10 alpha-side:current spare/base:latest
sha256:r00 redis:7-alpine
sha256:n00 nginx:alpine
sha256:g10 gamma-web:current gamma-web:1.0.0'

alpha_compose='services:
  web:
    build: .
    image: alpha-web:current
  api:
    build: ./api
    image: alpha-api:current
  side:
    build: ./side
    image: alpha-side:current
  cache:
    image: redis:7-alpine
'
beta_compose='services:
  web:
    build: .
    image: nginx:alpine
  shared:
    build: ./shared
    image: alpha-api:current
'
gamma_compose='services:
  web:
    build: .
    image: gamma-web:current
'
broken_compose='services: [not: a mapping'

row() {   # row <name> <dir-state> <compose-state> <compose>
    printf '%s %s %s %s\n' "$(b64 "$1")" "$2" "$3" "${4:--}"
}
rows_ok="$(row alpha dir ok "$(b64 "$alpha_compose")")
$(row beta  dir ok "$(b64 "$beta_compose")")
$(row gamma dir ok "$(b64 "$gamma_compose")")"

registry='primary_domain: mail.example.com
domains:
  - alpha.test
  - keep.test
'

write_payload() {   # write_payload <rows> <count>
    {
        printf 'have_docker=yes\ndocker_error=\n'
        printf 'apps_state=dir\n'
        printf 'project_state=%s\n' "${PAYLOAD_PROJECT:-dir}"
        printf 'data_state=%s\n' "${PAYLOAD_DATA:-dir}"
        printf 'backups_state=%s\nbackups_count=%s\n' "${PAYLOAD_BACKUPS:-dir}" "${PAYLOAD_BACKUPS_N:-2}"
        printf 'fragment_state=%s\n' "${PAYLOAD_FRAGMENT:-ok}"
        printf 'lock_state=%s\n' "${PAYLOAD_LOCK:-free}"
        printf 'containers_b64=%s\n' "$(b64 "${PAYLOAD_CONTAINERS-alpha-web running
alpha-cache running}")"
        printf 'images_b64=%s\n' "$(b64 "$images")"
        printf 'mail_dir=dir\nmail_registry_state=ok\n'
        printf 'mail_registry_b64=%s\n' "$(b64 "${PAYLOAD_REGISTRY-$registry}")"
        printf 'project_count=%s\n' "$2"
        printf 'projects_b64=%s\n' "$(b64 "$1")"
    } > "$payload_file"
}
write_payload "$rows_ok" 3

# --- The plan, and the exact removal set --------------------------------------------------------
out=$(drop_cli deploy@vps --yes)
rc=$?
tags="$(act_tags)"
expected="alpha-side:current alpha-web:0.9.0 alpha-web:1.0.0 alpha-web:current "

assert '[ "$rc" = 0 ]' "a drop that does what it planned exits 0 (rc=$rc)
$out"
# **The** assertion: not "it removed something", but exactly these four and
# nothing else. Every keep below is one line of this set's complement.
assert '[ "$tags" = "$expected" ]' \
    "the removal set is exactly the tags alpha builds and nobody else claims
        wanted: $expected
        got:    $tags"

# Every tag of a repository this project builds — the version tags and :current
# alike, which is what makes drop different from prune.
assert 'grep -qE "^    alpha-web:current +built by alpha" <<<"$out"' \
    "':current' is removed, unlike in prune: the project is going (out: $out)"
assert 'grep -qE "^    alpha-web:0\.9\.0 +built by alpha" <<<"$out"' \
    "and so is a version tag no record mentions — age is not part of this rule (out: $out)"
# The two groups, and which side of the line each row is on. A `keep` row under
# a heading that reads "to remove" states the opposite of what it means.
plan_remove="$(sed -n "/^to remove\$/,/^\$/p" <<<"$out")"
plan_keep="$(sed -n "/^left alone\$/,/^\$/p" <<<"$out")"
assert 'grep -qF "alpha-web:current" <<<"$plan_remove"' \
    "the tags that go are under 'to remove' (got: $plan_remove)"
assert '! grep -qF "alpha-api" <<<"$plan_remove"' \
    "and the ones that stay are not (got: $plan_remove)"
assert 'grep -qF "alpha-api:current" <<<"$plan_keep"' \
    "they are under 'left alone' (got: $plan_keep)"

# Shared and stock. alpha's own compose declares all four, and only the two it
# alone builds go.
assert 'grep -qE "^    alpha-api:current +alpha-api is claimed by more than one project \(alpha beta\)" <<<"$out"' \
    "a repository beta also builds is kept, and the report names who else claims it (out: $out)"
assert '[ "${tags#*alpha-api}" = "$tags" ]' "and no alpha-api tag is in the removal set"
assert '! grep -qE "^    redis:" <<<"$out"' \
    "a stock image is never a candidate — it is in nobody's build: (out: $out)"
assert '[ "${tags#*redis}" = "$tags" ] && [ "${tags#*nginx}" = "$tags" ]' \
    "and neither redis:7-alpine nor nginx:alpine is removed"
assert '[ "${tags#*gamma}" = "$tags" ]' "another project's own images are not this project's to remove"
assert 'grep -qE "^    alpha-side:current +untags only.*spare/base:latest" <<<"$out"' \
    "a removal that only drops a name says so (out: $out)"

# The act was told the truth about the flags it does nothing for.
assert 'grep -qxF "prune=no" "$act_log"' "plain drop tells the act not to prune"
assert 'grep -qxF "registry=" "$act_log"' "and hands it no registry to write"
assert 'grep -qF "kept" <<<"$out"' "the report says what stays (out: $out)"
assert 'grep -qF "mail        alpha.test — kept" <<<"$out"' \
    "including the mail claim, which plain drop does not release (D11) (out: $out)"

steps=$(grep -c "'bash' '-s'" "$ssh_log")
assert '[ "$steps" = 3 ]' \
    "a run that drops makes three script round trips: marker, batched read, act (got $steps)
$(cat "$ssh_log")"

# --- --prune ------------------------------------------------------------------------------------
out=$(drop_cli deploy@vps --prune --yes)
rc=$?
assert '[ "$rc" = 0 ]' "--prune exits 0 (rc=$rc)
$out"
assert '[ "$(act_tags)" = "$expected" ]' "and removes the same images (got '$(act_tags)')"
assert 'grep -qxF "prune=yes" "$act_log"' "the act is told to prune"
reg="$(sed -n 's/^registry=//p' "$act_log" | base64 -d)"
assert 'grep -qF "keep.test" <<<"$reg"' "the rendered registry keeps the other domain (got '$reg')"
assert '! grep -qF "alpha.test" <<<"$reg"' "and drops this project's (got '$reg')"
assert 'grep -qF "primary_domain: mail.example.com" <<<"$reg"' "with the primary intact (got '$reg')"
assert 'grep -qF "to delete" <<<"$out"' "the report says the kept things are deleted instead (out: $out)"
assert 'grep -qF "released" <<<"$out"' "and that the mail claim is released (out: $out)"
assert 'grep -qF "add-mail-domain deploy@vps alpha.test" <<<"$out"' \
    "naming the command that reverses it (out: $out)"

# A claim on the stack's own primary is not a claim any project's drop takes
# away, and the pair that proves it is the run above with the same code path.
PAYLOAD_REGISTRY='primary_domain: alpha.test
domains:
  - keep.test
' write_payload "$rows_ok" 3
out=$(drop_cli deploy@vps --prune --yes)
assert '[ "$(sed -n "s/^registry=//p" "$act_log")" = "" ]' \
    "a project claiming the stack's primary_domain releases nothing (act: $(cat "$act_log"))"
assert 'grep -qF "primary_domain" <<<"$out"' "and the report says why (out: $out)"

# A registry no command will rewrite — whichever way it is broken. The two
# shapes reach the reader by different routes (yq refuses one, the reader
# refuses the other), and neither is a reason to stop somebody else's drop.
for broken in 'this is: [not: yaml' 'name: mail
domains:
  - keep.test
' 'primary_domain: not a domain
domains:
  - keep.test
'; do
    PAYLOAD_REGISTRY="$broken" write_payload "$rows_ok" 3
    out=$(drop_cli deploy@vps --prune --yes); rc=$?
    assert '[ "$rc" = 0 ]' "a registry kasbah will not rewrite does not stop the drop (rc=$rc)
        registry: $broken
$out"
    assert 'grep -qxF "prune=yes" "$act_log"' "the act still ran"
    assert '[ "$(sed -n "s/^registry=//p" "$act_log")" = "" ]' \
        "with no registry to write (act: $(sed -n "s/^registry=//p" "$act_log"))"
    assert 'grep -qF "NOT released" <<<"$out"' "and the plan said the claim stays (out: $out)"
    # The reason is the reader's own sentence, not a shrug — pinned so a future
    # change that swallows it shows up here.
    assert 'grep -qE "NOT released: .+" <<<"$out"' "with a reason (out: $out)"
    # And a plain drop of the same project never reads the file at all.
    out=$(drop_cli deploy@vps --yes); rc=$?
    assert '[ "$rc" = 0 ]' "and a plain drop of the same project is untouched by it (rc=$rc)
$out"
    assert 'grep -qF "mail        alpha.test — kept" <<<"$out"' \
        "keeping the claim without reading the registry (out: $out)"
done
PAYLOAD_REGISTRY="$registry" write_payload "$rows_ok" 3

# --- Ownership kasbah cannot enumerate -----------------------------------------------------------
#
# A project whose compose.yml does not parse could have declared any repository
# on the host, so none of them is provably single-owner. Plain drop goes ahead
# with the reversible half and removes no image; --prune is refused outright,
# because it deletes the one file that says which images alpha built.
rows_broken="$rows_ok
$(row omega dir ok "$(b64 "$broken_compose")")"
write_payload "$rows_broken" 4
out=$(drop_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 0 ]' "plain drop still completes (rc=$rc)
$out"
assert '[ -z "$(act_tags)" ]' "and removes no image at all (got '$(act_tags)')"
assert 'grep -qE "^    alpha-web:current +ownership cannot be established.*omega" <<<"$out"' \
    "every repository is kept, and the report names who made it unknowable (out: $out)"
assert 'grep -qF "provably single-owner" <<<"$out"' "in its own sentence too (out: $out)"
assert 'grep -qxF "prune=no" "$act_log"' "the containers and the route still go"

out=$(drop_cli deploy@vps --prune --yes)
rc=$?
assert '[ "$rc" = 1 ]' "--prune is refused while that is true (rc=$rc)
$out"
assert '[ ! -s "$act_log" ]' "and the act never ran"
assert 'grep -qF "omega" <<<"$out"' "naming the project that is actually unreadable (out: $out)"
assert '! grep -qF "only record of which images this project builds" <<<"$out"' \
    "and not claiming alpha's own record is what --prune would destroy — beta's compose read fine (out: $out)"
assert 'grep -qF "nothing can attribute those tags to it again" <<<"$out"' \
    "the reason that is true here: alpha's tags become unattributable once it stops being a project (out: $out)"
assert 'grep -qF "without --prune" <<<"$out"' "and names the run that is still safe (out: $out)"

# The pairing that makes those three bite: the same fixture with omega gone
# removes four tags. Nothing about the images changed — only what could be read.
write_payload "$rows_ok" 3
out=$(drop_cli deploy@vps --prune --yes)
assert '[ "$(act_tags)" = "$expected" ]' \
    "the same server without the unreadable project removes them all again (got '$(act_tags)')"

# --- The project's own compose, unreadable -------------------------------------------------------
rows_selfbroken="$(row alpha dir unreadable -)
$(row beta dir ok "$(b64 "$beta_compose")")"
write_payload "$rows_selfbroken" 2
out=$(drop_cli deploy@vps --yes)
assert '[ -z "$(act_tags)" ]' "a project whose own compose.yml cannot be read loses no image (got '$(act_tags)')"
assert 'grep -qF "unreadable" <<<"$out"' "and the report says so in the probe's own word (out: $out)"

# --prune here **is** refused, and with the reason that is true here: the file
# that says which images alpha built is the file --prune is about to delete.
out=$(drop_cli deploy@vps --prune --yes); rc=$?
assert '[ "$rc" = 1 ]' "--prune is refused on a project whose own compose.yml cannot be read (rc=$rc)"
assert '[ ! -s "$act_log" ]' "and the act never ran"
assert 'grep -qF "only record of which images this project builds" <<<"$out"' \
    "with the reason that fits this case and not the neighbour one (out: $out)"
assert 'grep -qF "unreadable" <<<"$out"' "naming the state the probe reported (out: $out)"

# --- The project's own directory, with no compose.yml at all -----------------------------------------
#
# The third shape of the same cliff, and the only one where refusing would be
# wrong: there is no record for --prune to destroy, no file to fix, and the
# operator's only other way out is a hand-run `rm -rf` on their server.
rows_nocompose="$(row alpha dir missing -)
$(row beta dir ok "$(b64 "$beta_compose")")"
write_payload "$rows_nocompose" 2
out=$(drop_cli deploy@vps --prune --yes); rc=$?
assert '[ "$rc" = 0 ]' "--prune goes ahead when the project directory has no compose.yml (rc=$rc)
$out"
assert 'grep -qxF "prune=yes" "$act_log"' "and really prunes"
assert '[ -z "$(act_tags)" ]' "removing no image, because none can be attributed (got '$(act_tags)')"
assert 'grep -qF "no compose.yml, so no image" <<<"$out"' "saying so plainly (out: $out)"
assert '! grep -qF "is refused" <<<"$out"' "and refusing nothing (out: $out)"
# The orphans it names. `:current` is written by deploy and by nothing else, so
# a repository carrying one was built by a kasbah project here; claimed by no
# readable compose file, it is an image nothing now attributes.
assert 'grep -qF "alpha-web:current" <<<"$out"' "naming the tags it leaves behind (out: $out)"
assert 'grep -qF "alpha-web:0.9.0" <<<"$out"' "every tag of them, not just the pointer (out: $out)"
# The pair that keeps that from being "it lists everything": a stock image
# carries no :current, so it is not an orphan and is not named.
assert '! grep -qE "^(warning:)? *redis:7-alpine" <<<"$out"' \
    "and not a stock image, which carries no :current and was built by nobody (out: $out)"
assert '! grep -qE "^ *nginx:alpine" <<<"$out"' "nor the other one (out: $out)"

# --- --prune on a project that was never deployed here -------------------------------------------------
# The registry does not list alpha.test here: a project that was never deployed
# to this server has no claim on its mail stack either, and a claim left in the
# fixture would be real work for --prune to do.
PAYLOAD_PROJECT=absent PAYLOAD_DATA=absent PAYLOAD_FRAGMENT=missing \
    PAYLOAD_BACKUPS=absent PAYLOAD_BACKUPS_N=0 PAYLOAD_CONTAINERS= \
    PAYLOAD_REGISTRY='primary_domain: mail.example.com
domains:
  - keep.test
' write_payload "$(row beta dir ok "$(b64 "$beta_compose")")" 1
for flags in "--prune --yes" "--prune"; do
    out=$(drop_cli deploy@vps $flags </dev/null); rc=$?
    assert '[ "$rc" = 0 ]' "--prune on a project that was never here exits 0 with '$flags' (rc=$rc)
$out"
    assert 'grep -qF "nothing to drop" <<<"$out"' "and says so (out: $out)"
    assert '[ ! -s "$act_log" ]' "with no act round trip"
    assert '! grep -qF "type the project name" <<<"$out"' \
        "and no confirmation, since there is nothing to confirm (out: $out)"
done
PAYLOAD_PROJECT="" PAYLOAD_DATA="" PAYLOAD_FRAGMENT="" PAYLOAD_BACKUPS="" \
    PAYLOAD_BACKUPS_N="" PAYLOAD_REGISTRY="$registry" write_payload "$rows_ok" 3
unset PAYLOAD_CONTAINERS

# --- A drop where an image removal fails -----------------------------------------------------------------
#
# Every outcome line goes to stdout in the order the far side did the work, and
# a failed run must not end on a sentence describing a clean one.
write_payload "$rows_ok" 3
out=$(SSH_RM_FAIL=alpha-web:1.0.0 drop_cli deploy@vps --yes); rc=$?
assert '[ "$rc" = 1 ]' "an image docker would not delete fails the run (rc=$rc)"
assert 'grep -qF "could not remove alpha-web:1.0.0" <<<"$out"' "naming the tag (out: $out)"
assert 'grep -qF "unable to delete" <<<"$out"' "and quoting docker's own reason (out: $out)"
assert 'grep -qF "removed 3 of 4" <<<"$out"' "and saying how many did go (out: $out)"
# The ordering: the server removed the route, then the containers, then the
# images, and the failure line is one of the image lines. Reported out of order
# it reads as a failure that happened before the two steps it followed.
route_at=$(grep -n "removed route" <<<"$out" | head -1 | cut -d: -f1)
down_at=$(grep -n "brought down" <<<"$out" | head -1 | cut -d: -f1)
failed_at=$(grep -n "FAILED to remove image" <<<"$out" | head -1 | cut -d: -f1)
err_at=$(grep -n "could not remove alpha-web:1.0.0" <<<"$out" | head -1 | cut -d: -f1)
assert '[ -n "$route_at" ] && [ -n "$down_at" ] && [ -n "$failed_at" ] && [ -n "$err_at" ]' \
    "all four lines are there (route=$route_at down=$down_at failed=$failed_at err=$err_at)"
assert '[ "$route_at" -lt "$down_at" ] && [ "$down_at" -lt "$failed_at" ]' \
    "the failure is reported after the two steps that preceded it on the server
        route=$route_at down=$down_at failed=$failed_at
$out"
assert '[ "$down_at" -lt "$err_at" ]' "and so is the error explaining it (down=$down_at err=$err_at)"
# And the last thing the operator reads is the failure, not a success sentence.
assert '! grep -qF "everything a redeploy needs is still there" <<<"$out"' \
    "a failed drop does not end by describing a clean one (out: $out)"
assert 'grep -qF "was not fully dropped" <<<"$out"' "it ends by saying it was not finished (out: $out)"
# last_server is owed to a run that reached the server and changed it.
assert '[ "$(jq -r .last_server "$proj/.kasbah/state.json")" = "deploy@vps" ]' \
    "and last_server is written even though the run failed (got '$(jq -r .last_server "$proj/.kasbah/state.json")')"

# The stream. The plan and the outcome are one report and go to one place, so a
# redirected run keeps both halves.
rm -f "$proj/.kasbah/state.json"
printf '{"kasbah_version":"0.1.0-test","last_server":"deploy@vps"}\n' > "$proj/.kasbah/state.json"
rm -f "$tmpdir/ssh.count"; : > "$act_log"
sout=$( cd "$proj" && env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        SSH_COUNT="$tmpdir/ssh.count" SSH_ACT_LOG="$act_log" SSH_PAYLOAD="$payload_file" \
        NO_COLOR=1 "$KASBAH_BIN" drop deploy@vps --yes 2>/dev/null )
assert 'grep -qE "^    alpha-web:current +built by alpha" <<<"$sout"' \
    "stdout alone holds the plan (got '$sout')"
assert 'grep -qF "removed image alpha-web:current" <<<"$sout"' "and what came of it (got '$sout')"
assert 'grep -qF "brought down" <<<"$sout"' "and the container step (got '$sout')"

# --- A remote step that exited non-zero: refused, or half-done ------------------------------
#
# Two different pieces of news, and telling an operator the worse one sends them
# looking for damage that is not there. `server destroy` already answers this
# with `started=yes`; the same mechanism, one file back.
write_payload "$rows_ok" 3
out=$(SSH_ACT_REFUSE="project name 'alpha' is not a project" drop_cli deploy@vps --yes); rc=$?
assert '[ "$rc" != 0 ]' "a payload that refused fails the run (rc=$rc: $out)"
assert 'grep -qF "it refused before changing anything — nothing was removed" <<<"$out"' \
    "and is reported as a refusal (out: $out)"
assert '! grep -qF "some of it may have run" <<<"$out"' \
    "not as a half-done one (out: $out)"

out=$(SSH_ACT_DIE="the fragment could not be removed" drop_cli deploy@vps --yes); rc=$?
assert '[ "$rc" != 0 ]' "a payload that died after starting fails the run too (rc=$rc: $out)"
assert 'grep -qF "some of it may have run" <<<"$out"' \
    "and *that* one is the half-done sentence (out: $out)"
assert 'grep -qF -- "kasbah drop deploy@vps" <<<"$out"' \
    "with the command that says what is left (out: $out)"
assert '! grep -qF "refused before changing anything" <<<"$out"' \
    "and not the refusal one (out: $out)"

# --- The return trip, and whether it needs --allow-stopped ----------------------------------
#
# `kasbah remote deploy` refuses to deploy over a project with history whose
# backup: / pre-deploy-hook containers do not exist, which is exactly what a
# plain drop leaves. Whether that applies is a property of the manifest, so drop
# reads it rather than telling the operator to.
out=$(drop_cli deploy@vps --yes)
assert 'grep -qF "kasbah deploy deploy@vps" <<<"$out"' "the return command is printed (out: $out)"
assert '! grep -qF -- "--allow-stopped" <<<"$out"' \
    "and carries no --allow-stopped for a manifest with no hooks and no backup: (out: $out)"

# Each half on its own, because either one is enough for the remote preflight to
# refuse: a manifest with a backup: and no hooks needs the flag exactly as much
# as one with hooks and no backup:, and a test that only ever declares both
# cannot tell which half is being read.
cp "$proj/kasbah.yml" "$tmpdir/kasbah.yml.plain"
printf 'backup:\n  container: alpha-web\n  command: echo x\n' >> "$proj/kasbah.yml"
out=$(drop_cli deploy@vps --yes)
assert 'grep -qF "kasbah deploy deploy@vps --allow-stopped" <<<"$out"' \
    "a backup: container alone asks for --allow-stopped (out: $out)"
assert 'grep -qF "containers this drop removed" <<<"$out"' "with the reason (out: $out)"

cp "$tmpdir/kasbah.yml.plain" "$proj/kasbah.yml"
printf 'hooks:\n  pre-deploy:\n    - '"'"'alpha-web echo hi'"'"'\n' >> "$proj/kasbah.yml"
out=$(drop_cli deploy@vps --yes)
assert 'grep -qF "kasbah deploy deploy@vps --allow-stopped" <<<"$out"' \
    "and a pre-deploy hook alone does too (out: $out)"

# A post-deploy hook is not one of them: it runs against the containers the
# deploy has just started, so it never meets the preflight.
cp "$tmpdir/kasbah.yml.plain" "$proj/kasbah.yml"
printf 'hooks:\n  post-deploy:\n    - '"'"'alpha-web echo hi'"'"'\n' >> "$proj/kasbah.yml"
out=$(drop_cli deploy@vps --yes)
assert '! grep -qF -- "--allow-stopped" <<<"$out"' \
    "while a post-deploy hook does not — it runs against containers the deploy starts (out: $out)"
cp "$tmpdir/kasbah.yml.plain" "$proj/kasbah.yml"

# --- A container `docker compose down` does not remove ------------------------------------------------------
out=$(SSH_DOWN_LEFT="alpha-oneoff " drop_cli deploy@vps --yes); rc=$?
assert '[ "$rc" = 0 ]' "a container left standing is not a failed drop (rc=$rc)"
assert '! grep -qF "brought down docker compose -p alpha" <<<"$out"' \
    "but the run does not claim it brought the stack down (out: $out)"
assert 'grep -qF "alpha-oneoff is still there" <<<"$out"' "it names what is still there (out: $out)"
assert 'grep -qF "oneoff=False" <<<"$out"' "and why compose left it (out: $out)"
# The pair: the same run with nothing left says the plain thing.
out=$(drop_cli deploy@vps --yes)
assert 'grep -qF "brought down docker compose -p alpha" <<<"$out"' \
    "and with nothing left it does claim it (out: $out)"

# --- The tri-state ---------------------------------------------------------------------------------
write_payload "$rows_ok" 3
out=$(drop_cli deploy@vps </dev/null)
rc=$?
assert '[ "$rc" = 1 ]' "without --yes and without a terminal, drop stops (rc=$rc)"
assert 'grep -qF -- "--yes" <<<"$out"' "naming the flag that would have answered (out: $out)"
assert '[ ! -s "$act_log" ]' "and changes nothing"
assert 'grep -qE "^    alpha-web:current +built by alpha" <<<"$out"' \
    "the plan is printed before the question, so the operator answers about something (out: $out)"
steps=$(grep -c "'bash' '-s'" "$ssh_log")
assert '[ "$steps" = 2 ]' "two round trips: the marker and the read happened, the act did not (got $steps)"

# The second refusal, which the first would hide: --yes answers the yes/no
# question, so a terminal-less run that got past it has to stop at the typed
# one. Driven by giving the confirmation an answer and nothing else.
typed_out=$(printf 'y\n' | drop_cli deploy@vps)
rc=$?
assert '[ "$rc" = 1 ]' "a piped 'y' is not a terminal, so the run still stops (rc=$rc)"
assert '[ ! -s "$act_log" ]' "and changes nothing"

# --- The confirmations, over a real terminal ---------------------------------------------------------
drop_tty() {   # drop_tty <input> <args...>
    local cmd
    : > "$act_log"; rm -f "$tmpdir/ssh.count"
    cmd="$(printf '%q ' "$KASBAH_BIN" drop "$@")"
    tty_out=$(printf '%s' "$1" | { shift; cd "$proj" && \
        env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
            HOME="$tmpdir/home" PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
            SSH_COUNT="$tmpdir/ssh.count" SSH_ACT_LOG="$act_log" \
            SSH_PAYLOAD="$payload_file" NO_COLOR=1 \
            script -qec "$(printf '%q ' "$KASBAH_BIN" drop "$@")" /dev/null; } 2>&1)
    tty_rc=$?
    tty_out=${tty_out//$'\r'/}
}
drop_tty $'y\nalpha\n' deploy@vps
assert '[ "$tty_rc" = 0 ]' "both confirmations answered, the drop runs (exit $tty_rc)
$tty_out"
assert '[ "$(act_tags)" = "$expected" ]' "with the planned removal set (got '$(act_tags)')"

drop_tty $'y\nbravo\n' deploy@vps
assert '[ "$tty_rc" != 0 ]' "the project name typed wrong aborts (exit $tty_rc)"
assert '[ ! -s "$act_log" ]' "having changed nothing at all"
assert 'grep -qF "that is not alpha" <<<"$tty_out"' "and says which answer it was (got '$tty_out')"

drop_tty $'n\n' deploy@vps
assert '[ "$tty_rc" != 0 ]' "answering no aborts (exit $tty_rc)"
assert '[ ! -s "$act_log" ]' "having changed nothing"
assert '! grep -qF "type the project name" <<<"$tty_out"' \
    "and the second question is never asked (got '$tty_out')"

# --- Nothing to drop --------------------------------------------------------------------------------
#
# The flag that does nothing: --yes on a run that would never have prompted.
PAYLOAD_PROJECT=absent PAYLOAD_DATA=absent PAYLOAD_FRAGMENT=missing \
    PAYLOAD_BACKUPS=absent PAYLOAD_BACKUPS_N=0 PAYLOAD_CONTAINERS= \
    write_payload "$(row beta dir ok "$(b64 "$beta_compose")")" 1
out=$(printf '' | drop_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 0 ]' "a project that is not on the server needs no answer (rc=$rc)
$out"
assert 'grep -qF "nothing to drop" <<<"$out"' "and says so (out: $out)"
assert '[ ! -s "$act_log" ]' "and makes no act round trip"
out=$(drop_cli deploy@vps </dev/null)
rc=$?
assert '[ "$rc" = 0 ]' "and without --yes and without a terminal it is still 0 — there was nothing to ask (rc=$rc)
$out"

# --- Servers drop will not touch ----------------------------------------------------------------------
PAYLOAD_LOCK=held write_payload "$rows_ok" 3
out=$(drop_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 1 ]' "a deploy holding the lock stops the drop (rc=$rc)"
assert '[ ! -s "$act_log" ]' "before anything is asked or removed"
assert 'grep -qF ".deploy.lock" <<<"$out"' "naming the file (out: $out)"
assert '! grep -qF "flock is not installed" <<<"$out"' \
    "and not confusing a held lock with a missing prerequisite (out: $out)"

PAYLOAD_LOCK=noflock write_payload "$rows_ok" 3
out=$(drop_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 1 ]' "a server without flock stops the drop (rc=$rc)"
assert 'grep -qF "flock is not installed" <<<"$out"' "as the missing prerequisite it is (out: $out)"
assert '! grep -qF "already running" <<<"$out"' \
    "and not as a concurrent operator who does not exist (out: $out)"
PAYLOAD_LOCK="" write_payload "$rows_ok" 3

: > "$payload_file"
printf 'have_docker=yes\napps_state=dir\n' > "$payload_file"
out=$(drop_cli deploy@vps --yes)
rc=$?
assert '[ "$rc" = 1 ]' "a truncated probe is refused (rc=$rc)"
assert 'grep -qF "reported no" <<<"$out"' "naming the facts that never arrived (out: $out)"
assert '[ ! -s "$act_log" ]' "and removes nothing on a payload it could not read whole"
write_payload "$rows_ok" 3

# --- No duplicate definitions ---------------------------------------------------------------------------
# Bash takes the last definition of a function and `bash -n` cannot see a
# duplicate, so a byte-identical copy can sit in a file with every suite green
# (docs/phases/07-operate.md → 7.1b). Heredoc-aware: the remote payloads are
# different shell programs with namespaces of their own.
for f in lib/drop.sh lib/prompt.sh; do
    dups=$(awk '/<<.REMOTE./{r=1} /^REMOTE$/{r=0} r==0 && /^[a-z_]+\(\)/{print $1}' \
               "$repo_dir/$f" | LC_ALL=C sort | uniq -d)
    assert '[ -z "$dups" ]' "$f defines each function once (duplicates: $dups)"
done

if [ "$fail" = 0 ]; then
    echo "drop: ok"
else
    echo "drop: FAILURES" >&2
fi
exit "$fail"
