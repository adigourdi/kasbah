#!/usr/bin/env bash
# Test: tests/rig/rig.sh — argument handling, keypair validation, and the
# generated ssh_config. A unit suite: no rig, no container, no Docker.
#
# Hermetic by construction, and both halves matter. rig.sh derives its own
# directory from $0 and hardcodes the `kasbah-rig` compose project, so running
# the script in place would drive the real rig on a developer's workstation; a
# real `docker` on PATH would let it. So the script is copied into a temp dir
# and a recording stub is put first on PATH. `./test.sh` must keep working on a
# machine with no Docker at all, which this also buys.

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

# --- Harness ------------------------------------------------------------------

rig_dir="$tmpdir/rig"
mkdir -p "$rig_dir"
cp "$repo_dir/tests/rig/rig.sh" "$rig_dir/rig.sh"
rig="$rig_dir/rig.sh"
ssh_config="$rig_dir/ssh_config"
key_file="$rig_dir/id_ed25519"
pub_file="$key_file.pub"

stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir"
# Two logs: one truncated per run, for per-case assertions, and one that
# accumulates every call the whole suite made, for the hermeticity check at the
# end.
export RIG_STUB_LOG="$tmpdir/docker.log"
export RIG_STUB_LOG_ALL="$tmpdir/docker.all.log"
: > "$RIG_STUB_LOG"
: > "$RIG_STUB_LOG_ALL"

cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
# Stand-in for docker: records the call, then answers what the case asked for.
# Reporting no container is the default, so a case that forgets to set anything
# cannot accidentally reach a real one.
printf '%s\n' "$*" >> "$RIG_STUB_LOG"
printf '%s\n' "$*" >> "$RIG_STUB_LOG_ALL"
case "$*" in
    *' ps -aq rig')
        [ -z "${RIG_STUB_CONTAINER:-}" ] || printf '%s\n' "$RIG_STUB_CONTAINER" ;;
    'port '*)
        # docker(1) exits 1 with this on a container that exists but is stopped.
        [ -n "${RIG_STUB_PORT_OUT:-}" ] \
            || { echo "no public port '22' published for kasbah-rig" >&2; exit 1; }
        printf '%s\n' "$RIG_STUB_PORT_OUT" ;;
    'inspect -f'*PortBindings*)
        [ -z "${RIG_STUB_BINDINGS:-}" ] || printf '%s\n' "$RIG_STUB_BINDINGS" ;;
    'image inspect '*)
        exit 1 ;;
esac
exit 0
STUB
chmod 0755 "$stub_dir/docker"

# rig.sh's only other reach outside the machine. Nothing here should get as far
# as opening a socket; this makes "should" into "cannot".
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$RIG_STUB_LOG_ALL"
exit 255
STUB
chmod 0755 "$stub_dir/ssh"

export PATH="$stub_dir:$PATH"

# Run the copied rig.sh. Arguments before `--` are `env` assignments for that
# run; the rest go to rig.sh. stdout and stderr are captured apart so "--help
# goes to stdout" is checkable at all. Sets: rc, out, err.
run_rig() {
    local env_args=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_args+=("$1"); shift; done
    [ $# -eq 0 ] || shift
    : > "$RIG_STUB_LOG"
    # The ambient environment is scrubbed of everything a case might care about,
    # so a developer running ./test.sh with KASBAH_RIG_SSH_PORT exported gets
    # the same verdicts as CI.
    out=$(env -u KASBAH_RIG_BIND -u KASBAH_RIG_SSH_PORT -u KASBAH_RIG_READY_TIMEOUT \
              -u RIG_STUB_CONTAINER -u RIG_STUB_PORT_OUT -u RIG_STUB_BINDINGS \
              "${env_args[@]+"${env_args[@]}"}" \
              "$rig" "$@" 2>"$tmpdir/err")
    rc=$?
    err=$(<"$tmpdir/err")
}

new_keypair() {
    rm -rf "$key_file" "$pub_file"
    ssh-keygen -t ed25519 -N '' -C rig-test -f "$key_file" >/dev/null
}

assert '[ "$(command -v docker)" = "$stub_dir/docker" ]' \
    "the stub docker shadows any real one (command -v docker gives $(command -v docker))"

# --- Case 1: up/down/reset take no arguments ----------------------------------
# A swallowed argument means `rig.sh up --rebuild` reports success while doing
# something else entirely.
for verb in up down reset; do
    run_rig -- "$verb" --rebuild
    assert '[ "$rc" != "0" ]'                              "$verb with an extra argument fails (got $rc)"
    assert 'grep -qF "rig: $verb: unknown argument" <<<"$err"' \
        "$verb's rejection names the verb (got '$err')"
    assert 'grep -qF -- "--rebuild" <<<"$err"'             "$verb's rejection quotes the argument (got '$err')"
    assert '[ ! -s "$RIG_STUB_LOG" ]'                      "$verb rejects the argument before touching docker (calls: $(cat "$RIG_STUB_LOG"))"
done

# --- Case 2: unknown verb, and no verb ----------------------------------------
run_rig -- bogus
assert '[ "$rc" != "0" ]'                       "an unknown verb fails (got $rc)"
assert 'grep -qF "unknown verb bogus" <<<"$err"' "an unknown verb is named (got '$err')"
assert 'grep -qF "usage: rig.sh" <<<"$err"'      "an unknown verb prints usage on stderr"
assert '[ -z "$out" ]'                           "an unknown verb prints nothing on stdout (got '$out')"

run_rig --
assert '[ "$rc" != "0" ]'                   "no verb fails (got $rc)"
assert 'grep -qF "usage: rig.sh" <<<"$err"' "no verb prints usage on stderr"
assert '[ -z "$out" ]'                      "no verb prints nothing on stdout (got '$out')"

# --- Case 3: --help is output, not an error -----------------------------------
# `rig.sh --help | less` has to work, so usage goes to stdout here and the exit
# status is 0 — the opposite of the two cases above.
run_rig -- --help
assert '[ "$rc" = "0" ]'                    "--help exits 0 (got $rc)"
assert 'grep -qF "usage: rig.sh" <<<"$out"' "--help prints usage on stdout (got '$out')"
assert '[ -z "$err" ]'                      "--help prints nothing on stderr (got '$err')"
assert 'grep -qF "KASBAH_RIG_DOCKERD_TIMEOUT" <<<"$out"' \
    "--help lists KASBAH_RIG_DOCKERD_TIMEOUT — an undocumented knob is a dead one"

# --- Case 4: a .pub that is not the private key's fails fast ------------------
# Such a rig boots, looks healthy, and refuses every login until the readiness
# probe times out blaming the rig. Caught here it costs milliseconds — so it
# must be caught before any container work.
new_keypair
ssh-keygen -t ed25519 -N '' -C intruder -f "$tmpdir/other" >/dev/null
cp "$tmpdir/other.pub" "$pub_file"
run_rig -- up
assert '[ "$rc" != "0" ]'                  "a mismatched .pub fails (got $rc)"
assert 'grep -qF "$pub_file" <<<"$err"'    "the mismatch names the file (got '$err')"
assert 'grep -qF "is not the public half" <<<"$err"' "the mismatch says what is wrong (got '$err')"
assert '[ "$(grep -cE "build| up -d" "$RIG_STUB_LOG")" = "0" ]' \
    "a mismatched .pub is caught before any build or up (calls: $(cat "$RIG_STUB_LOG"))"

# --- Case 5: a missing .pub is rederived, silently -----------------------------
# rig.sh can produce this state itself (the file is derivable and destroys
# nothing), so unlike case 4 it is not an error.
new_keypair
rm -f "$pub_file"
run_rig -- up
assert '[ -f "$pub_file" ]' "a missing .pub is rederived"
derived=$(ssh-keygen -y -f "$key_file" </dev/null 2>/dev/null)
stored=$(<"$pub_file")
# ssh-keygen -y emits a comment field of its own, so only type and blob compare.
read -r dtype dblob _ <<<"$derived"
read -r stype sblob _ <<<"$stored"
assert '[ "$dtype $dblob" = "$stype $sblob" ]' \
    "the rederived .pub is the public half of the private key ('$stype $sblob' vs '$dtype $dblob')"
assert '[ "$(grep -c "build" "$RIG_STUB_LOG")" != "0" ]' \
    "a rederived .pub does not stop the run (calls: $(cat "$RIG_STUB_LOG"))"

# --- Case 6: a directory where the .pub belongs is rejected --------------------
# Docker materialises a missing bind-mount source as a root-owned directory, and
# `[ -r ]`/`[ -e ]` are both true for one — which is how such a directory once
# got past the guard and left an unwritable path in a gitignored spot.
new_keypair
rm -f "$pub_file"
mkdir -p "$pub_file"
run_rig -- up
assert '[ "$rc" != "0" ]'                             "a directory in place of the .pub fails (got $rc)"
assert 'grep -qF "is not a regular file" <<<"$err"'   "the directory is diagnosed as such (got '$err')"
assert 'grep -qF "$pub_file" <<<"$err"'               "the directory rejection names the path (got '$err')"
rmdir "$pub_file"

# --- Case 7: with no container, ssh_config follows the environment -------------
new_keypair
rm -f "$ssh_config"
run_rig KASBAH_RIG_BIND=127.0.0.2 KASBAH_RIG_SSH_PORT=15022 -- down
cfg=$(<"$ssh_config")
assert 'grep -qE "^ +Port 15022$" <<<"$cfg"'         "KASBAH_RIG_SSH_PORT reaches ssh_config with no container to read"
assert 'grep -qE "^ +HostName 127\.0\.0\.2$" <<<"$cfg"' "KASBAH_RIG_BIND reaches ssh_config with no container to read"
assert '[ "$(grep -c "^Host " <<<"$cfg")" = "1" ]'   "ssh_config holds exactly one Host block (got $(grep -c "^Host " <<<"$cfg"))"
assert 'grep -qF "IdentityFile $key_file" <<<"$cfg"' "ssh_config points at the rig's own key"

# --- Case 8: with a container, ssh_config follows the container ----------------
# The published port is a property of the container, not of whoever runs the
# next command: one stray override used to repoint this shared file at a port
# nothing listens on, and every later caller then blamed the rig.
run_rig RIG_STUB_CONTAINER=deadbeef RIG_STUB_PORT_OUT=$'127.0.0.1:5022\n[::]:5022' \
        KASBAH_RIG_SSH_PORT=15022 KASBAH_RIG_BIND=127.0.0.9 -- down
cfg=$(<"$ssh_config")
assert 'grep -qE "^ +Port 5022$" <<<"$cfg"' \
    "a stray KASBAH_RIG_SSH_PORT does not repoint ssh_config away from the running container"
assert 'grep -qE "^ +HostName 127\.0\.0\.1$" <<<"$cfg"' \
    "a stray KASBAH_RIG_BIND does not repoint ssh_config away from the running container"
assert 'grep -qF "port deadbeef 22" "$RIG_STUB_LOG"' \
    "the endpoint was read back from the container (calls: $(cat "$RIG_STUB_LOG"))"

# An IPv6 binding is listed alongside the IPv4 one and can come first; ssh_config
# connects over IPv4.
run_rig RIG_STUB_CONTAINER=deadbeef RIG_STUB_PORT_OUT=$'[::]:5022\n0.0.0.0:5022' -- down
cfg=$(<"$ssh_config")
assert 'grep -qE "^ +HostName 0\.0\.0\.0$" <<<"$cfg"' "the IPv4 binding is picked even when listed second"
assert 'grep -qE "^ +Port 5022$" <<<"$cfg"'           "the IPv4 binding's port is used"

# --- Case 9: a stopped container still owns the endpoint -----------------------
# `docker port` fails outright on a container that exists but is stopped, so the
# bindings recorded at create time are the fallback — not the environment, which
# would reintroduce exactly the bug case 8 covers.
run_rig RIG_STUB_CONTAINER=deadbeef RIG_STUB_BINDINGS='127.0.0.3:5522' \
        KASBAH_RIG_SSH_PORT=15022 -- down
cfg=$(<"$ssh_config")
assert 'grep -qE "^ +Port 5522$" <<<"$cfg"'             "a stopped container's recorded port wins over the environment"
assert 'grep -qE "^ +HostName 127\.0\.0\.3$" <<<"$cfg"' "a stopped container's recorded bind wins over the environment"

# --- Hermeticity ---------------------------------------------------------------
# Everything above must have gone through the stub and named the temp copy. If a
# real docker had been reached, or a compose call had lost its project pin, this
# suite could have driven the developer's actual rig.
calls=$(<"$RIG_STUB_LOG_ALL")
compose_calls=$(grep -c '^compose ' <<<"$calls")
pinned=$(grep -c -- "^compose -p kasbah-rig -f $rig_dir/compose.yml " <<<"$calls")
assert '[ -s "$RIG_STUB_LOG_ALL" ]'      "the stub docker was the one that ran"
assert '[ "$compose_calls" -gt 0 ]'      "compose was exercised at all (else the check below is vacuous)"
assert '[ "$compose_calls" = "$pinned" ]' \
    "every compose call carried -p kasbah-rig and the temp compose file ($pinned of $compose_calls)"
assert '! grep -qF "$repo_dir/tests/rig" <<<"$calls"' \
    "no docker call named the real rig directory"
assert '! grep -q "^ssh " <<<"$calls"' \
    "no ssh was attempted (calls: $(grep "^ssh " <<<"$calls"))"

exit "$fail"
