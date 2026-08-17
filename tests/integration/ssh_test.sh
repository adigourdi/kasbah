#!/usr/bin/env bash
# Integration test: lib/ssh.sh against the live rig, and the connection model
# every later rig-driven suite inherits from tests/integration/rig_env.sh.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which is establishing a known starting state rather than
# repairing a broken environment — a crashed earlier run must not decide what
# this one sees. The rig is cleaned again at the end only if everything passed,
# so a failure leaves its state there to be looked at.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).
#
# No kasbah command uses lib/ssh.sh yet — `server init` and `deploy` are the
# next units — so the transport is driven directly, under exactly the HOME and
# PATH that rig_env.sh will hand those commands.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
# One case hides the rig's marker file to prove the far-side guard fires. If
# this suite dies while it is hidden the rig would keep refusing every later
# clean, so the restore is a trap, not a line at the end of the case.
marker_hidden=0
cleanup() {
    [ "$marker_hidden" = 0 ] || rig_ssh "sudo mv -f $RIG_MARKER_FILE.hidden $RIG_MARKER_FILE" >/dev/null 2>&1
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

# --- The invoker the later units will use -------------------------------------
# No kasbah command reaches the rig yet, so what is asserted here is the
# invoker itself: the checkout's CLI runs under the scratch HOME and the ssh
# wrapper, which is the environment Units B-E will get.
cli_out=$(kasbah_cli --version 2>&1); cli_rc=$?
assert '[ "$cli_rc" = "0" ]' "kasbah_cli runs the checkout's CLI (exit $cli_rc: $cli_out)"
assert '[ "$cli_out" = "kasbah $(cat "$repo_dir/VERSION")" ]' \
    "kasbah_cli runs this checkout, not an installed copy (got '$cli_out')"

# --- The cleanup payload cannot run locally -----------------------------------
# A static read of rig_env.sh, before anything is executed: every destructive
# line must live inside the quoted heredoc that goes to the rig. This
# workstation runs unrelated production stacks, and a `docker compose down -v`
# that executed here instead of there would take them with it.
env_src="$repo_dir/tests/integration/rig_env.sh"
payload=$(awk "/<<'REMOTE'/{p=1;next} p&&/^REMOTE\$/{p=0} p" "$env_src")
assert '[ -n "$payload" ]' "the remote payload was found in rig_env.sh (else the checks below are vacuous)"
for token in 'docker compose -p' 'down -v' 'docker network rm' 'rm -rf /apps'; do
    in_file=$(grep -cF -- "$token" "$env_src")
    in_payload=$(grep -cF -- "$token" <<<"$payload")
    assert '[ "$in_payload" -gt 0 ]'            "the payload contains '$token' (else it does not clean)"
    assert '[ "$in_file" = "$in_payload" ]'     "'$token' appears only inside the remote payload ($in_payload of $in_file occurrences)"
done
for banned in 'docker system prune' 'docker volume prune' 'docker network prune' \
              'docker container prune' 'docker image prune' 'docker rm ' 'docker rmi ' \
              'docker ps -aq' 'docker volume ls'; do
    assert '! grep -qF -- "$banned" "$env_src"' \
        "rig_env.sh contains no '$banned' — nothing sweeps beyond compose projects"
done

# The payload does sweep every compose project, so the guard that decides where
# it lands is the whole safety argument. It has to be inside the payload, since
# that is the only part evaluated on the host that actually answered.
guard_expr='[ "$marker" != "$marker_value" ]'
assert 'grep -qF "$guard_expr" <<<"$payload"' \
    "the payload compares the rig marker before deleting anything"
assert 'grep -qF "$RIG_MARKER_VALUE" "$env_src"' \
    "rig_env.sh and tests/rig/Dockerfile agree on the marker value"
assert 'grep -qF "exit \"\$not_the_rig\"" <<<"$payload"' \
    "the payload exits without cleaning when the marker is wrong"

# The target is a constant. As a variable it was one exported environment
# variable away from being a remote wipe of any host the owner can reach.
alias_probe=$(RIG_SSH_ALIAS=somebody-elses-server bash -c \
    '. "$1"; printf %s "$RIG_SSH_ALIAS"' _ "$env_src" 2>&1)
assert '[ "$alias_probe" = "rig" ]' \
    "the cleanup target cannot be redirected from the environment (got '$alias_probe')"

# --- rig_clean: a known starting state, images kept ---------------------------
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi

# One session plants everything a Phase 2 deploy leaves behind: a compose
# project (created through `docker compose -p`, the way kasbah does it), the
# shared network, /apps, and an image that must survive. The image is built by
# importing an empty tar rather than pulling, so the suite stays offline.
seed_out=$(rig_ssh bash -s <<'REMOTE' 2>&1
set -uo pipefail
sudo mkdir -p /apps/probe/deep
docker network create kasbah-net >/dev/null 2>&1
tar -cf - -T /dev/null | docker import - kasbah-clean-probe:test >/dev/null 2>&1
mkdir -p /tmp/kasbah-clean-probe
{ printf 'services:\n  a:\n    image: kasbah-clean-probe:test\n'
  printf '    command: ["/nonexistent"]\n    volumes: [probe-data:/data]\n'
  printf 'volumes:\n  probe-data: {}\n'; } > /tmp/kasbah-clean-probe/compose.yml
cd /tmp/kasbah-clean-probe
# The container cannot start (the image has no filesystem); created is enough,
# `docker compose ls --all` reports the project either way.
docker compose -p kasbah-clean-probe up -d >/dev/null 2>&1
printf 'seeded_projects=%s\n' "$(docker compose ls --all -q | tr '\n' ',')"
printf 'seeded_apps=%s\n' "$([ -d /apps/probe/deep ] && echo yes || echo no)"
printf 'seeded_net=%s\n' "$(docker network ls --format '{{.Name}}' | grep -c '^kasbah-net$')"
printf 'seeded_volumes=%s\n' "$(docker volume ls -q | wc -l)"
# By name, not by count. The rig's image cache is deliberately kept across
# rig_clean, so every suite that starts a real stack leaves images behind for
# every later one: since Phase 2's Traefik unit the rig permanently carries
# traefik:v3.x, and a count of 1 could never hold again.
printf 'seeded_images=%s\n' "$(docker images --format '{{.Repository}}:{{.Tag}}' | tr '\n' ',')"
exit 0
REMOTE
)
assert 'grep -qF "seeded_apps=yes" <<<"$seed_out"'                  "/apps was created on the rig (got '$seed_out')"
assert 'grep -qF "seeded_net=1" <<<"$seed_out"'                     "kasbah-net was created on the rig (got '$seed_out')"
assert 'grep -qF "seeded_projects=kasbah-clean-probe," <<<"$seed_out"' "a compose project exists on the rig (got '$seed_out')"
assert 'grep -qF "seeded_volumes=1" <<<"$seed_out"'                 "a compose volume exists on the rig (got '$seed_out')"
assert 'grep -qE "^seeded_images=.*kasbah-clean-probe:test," <<<"$seed_out"' \
    "the image that must survive the clean exists on the rig (got '$(grep "^seeded_images=" <<<"$seed_out")')"

rig_clean; clean_rc=$?
assert '[ "$clean_rc" = "0" ]' "rig_clean succeeds against a dirty rig (exit $clean_rc)"

after_out=$(rig_ssh bash -s <<'REMOTE' 2>&1
set -uo pipefail
printf 'apps=%s\n' "$([ -e /apps ] && echo present || echo gone)"
printf 'projects=%s\n' "$(docker compose ls --all -q | tr '\n' ',')"
printf 'containers=%s\n' "$(docker ps -a -q | wc -l)"
printf 'volumes=%s\n' "$(docker volume ls -q | wc -l)"
printf 'networks=%s\n' "$(docker network ls --format '{{.Name}}' | sort | tr '\n' ',')"
printf 'images=%s\n' "$(docker images --format '{{.Repository}}:{{.Tag}}' | tr '\n' ',')"
exit 0
REMOTE
)
assert 'grep -qF "apps=gone" <<<"$after_out"'         "clean removes /apps (got '$after_out')"
projects_after=$(grep "^projects=" <<<"$after_out")
assert '[ "$projects_after" = "projects=" ]' \
    "clean removes every compose project (got '$projects_after')"
assert 'grep -qF "containers=0" <<<"$after_out"'      "clean removes every container (got '$(grep "^containers=" <<<"$after_out")')"
assert 'grep -qF "volumes=0" <<<"$after_out"'         "clean removes the projects' volumes (got '$(grep "^volumes=" <<<"$after_out")')"
assert 'grep -qxF "networks=bridge,host,none," <<<"$after_out"' \
    "clean removes kasbah-net and keeps the three built-ins (got '$(grep "^networks=" <<<"$after_out")')"
assert 'grep -qE "^images=.*kasbah-clean-probe:test," <<<"$after_out"' \
    "clean keeps the image cache — that is the whole reason it exists (got '$(grep "^images=" <<<"$after_out")')"

# --- The transport, against the live rig --------------------------------------
cat > "$tmpdir/transport.sh" <<'DRIVER'
set -uo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

kv() { printf '%s=%s\n' "$1" "$2"; }

ssh_connect "$1"
kv target "$SSH_TARGET"
kv parsed_user "$SSH_USER"
kv parsed_host "$SSH_HOST"

remote_user=$(ssh_run id -un); kv remote_user "$remote_user"

shopt -s nullglob
kv ctl_dir "$_SSH_CTL_DIR"
socks=("$_SSH_CTL_DIR"/*)
kv sockets_open "${#socks[@]}"
kv socket_path "${socks[0]:-none}"
if [ "${#socks[@]}" -gt 0 ] && [ -S "${socks[0]}" ]; then kv socket_is_socket yes; else kv socket_is_socket no; fi
# Nothing of kasbah's goes in the user's ~/.ssh any more.
home_socks=("$HOME"/.ssh/cm-*)
kv home_sockets "${#home_socks[@]}"

# Quotes, backticks, $, a percent, an embedded newline and a nested quoted
# heredoc — the shapes a remote deploy script is actually made of.
payload_out=$(ssh_script one 'two three' <<'REMOTE'
set -euo pipefail
name='it'"'"'s "quoted"'
back=`echo backticked`
cost='$100 & 50%'
multi="one
two"
cat <<'INNER' >/dev/null
$HOME `date` "untouched"
INNER
printf 'payload=%s|%s|%s|%s|%s|%s|%s\n' \
    "$name" "$back" "$cost" "${multi//$'\n'/+}" "$1" "$2" "$HOME"
REMOTE
)
kv payload "${payload_out#payload=}"

src="$HOME/rsync-src"
mkdir -p "$src"
printf 'rsynced through the master\n' > "$src/hello.txt"
ssh_rsync -a "$src/" "$SSH_TARGET:/tmp/kasbah-rsync-probe/" >/dev/null 2>&1
kv rsync_rc "$?"
kv rsync_readback "$(ssh_run cat /tmp/kasbah-rsync-probe/hello.txt)"
ssh_run rm -rf /tmp/kasbah-rsync-probe

ssh_disconnect
socks_after=("$_SSH_CTL_DIR"/*)
kv sockets_after "${#socks_after[@]}"
exit 0
DRIVER

transport_err="$tmpdir/transport.err"
transport_out=$(rig_env_bash "$tmpdir/transport.sh" "$RIG_TARGET" 2>"$transport_err")
transport_rc=$?
if [ "$transport_rc" -ne 0 ]; then
    echo "error: the transport driver did not finish (exit $transport_rc)" >&2
    sed 's/^/       | /' "$transport_err" >&2
    exit 2
fi

# The driver's output is a protocol: parsed once and checked complete before
# anything reads it, so a fact that went missing cannot be absorbed into a
# passing assertion (docs/phases/01-rig.md, from 1.3).
declare -A fact=()
while IFS= read -r line; do
    case $line in *=*) fact[${line%%=*}]=${line#*=} ;; esac
done <<<"$transport_out"
missing=()
for key in target parsed_user parsed_host remote_user ctl_dir sockets_open socket_path \
           socket_is_socket home_sockets payload rsync_rc rsync_readback sockets_after; do
    [ -n "${fact[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the transport driver reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$transport_out" >&2
    sed 's/^/       | /' "$transport_err" >&2
    exit 2
fi

assert '[ "${fact[parsed_user]}" = "stevedore" ]'  "the target's user is parsed out (got '${fact[parsed_user]}')"
assert '[ "${fact[parsed_host]}" = "rig" ]'        "the target's host is parsed out (got '${fact[parsed_host]}')"
assert '[ "${fact[remote_user]}" = "stevedore" ]'  "the session lands as stevedore (got '${fact[remote_user]}')"

assert '[ "${fact[sockets_open]}" = "1" ]'         "one control socket exists while connected (got '${fact[sockets_open]}')"
assert '[ "${fact[socket_is_socket]}" = "yes" ]'   "the control path is a socket, not a stray file"
assert '[[ "${fact[socket_path]}" == "${fact[ctl_dir]}/"* ]]' \
    "the control socket lives in the directory the run made for it (got '${fact[socket_path]}')"
assert '[[ "${fact[ctl_dir]}" == "${TMPDIR:-/tmp}/kasbah-ssh."* ]]' \
    "and that directory is a private one under TMPDIR (got '${fact[ctl_dir]}')"
assert '[ "${fact[home_sockets]}" = "0" ]' \
    "no control socket is left in the user's ~/.ssh (found ${fact[home_sockets]})"
# 90, not 104: the master listens on `<path>.<16 random chars>` and renames it
# into place, so sun_path's 108 bytes are spent before the path is.
assert '[ "${#fact[socket_path]}" -le 90 ]' \
    "the control path fits what a master can bind (${#fact[socket_path]} chars: ${fact[socket_path]})"
assert '[ "${fact[sockets_after]}" = "0" ]'        "an explicit disconnect removes the master (got '${fact[sockets_after]}')"
assert '[ ! -e "${fact[ctl_dir]}" ]' \
    "and the directory goes with the process (still there: ${fact[ctl_dir]})"

expected_payload='it'"'"'s "quoted"|backticked|$100 & 50%|one+two|one|two three|/home/stevedore'
assert '[ "${fact[payload]}" = "$expected_payload" ]' \
    "a multi-line script with awkward quoting round-trips intact
        wanted: $expected_payload
        got:    ${fact[payload]}"

assert '[ "${fact[rsync_rc]}" = "0" ]'                              "rsync over the shared master succeeds (exit ${fact[rsync_rc]})"
assert '[ "${fact[rsync_readback]}" = "rsynced through the master" ]' "the rsynced file is on the rig (got '${fact[rsync_readback]}')"

# --- Two runs against one server do not touch each other ----------------------
# The defect this pins: `ssh -O exit` closes a master **and every session
# multiplexed over it**, and kasbah used to name its socket `~/.ssh/cm-%C` —
# user, host and port, nothing about the process. So any second kasbah command
# against the same server shared the first one's master, and tore it down on its
# way out. Measured before the fix: a read-only `server status` that exited 4 and
# changed nothing, fired six seconds into a `server init`, killed the init's
# remote step (255), which then reported "could not start Traefik" about a
# Traefik that was `Up 21 seconds (healthy)` and left the server with no marker.
#
# Two library-level runs, exactly that shape: the holder is mid-command when the
# visitor connects, works and tears its own master down.
cat > "$tmpdir/holder.sh" <<'DRIVER'
set -uo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

ssh_connect "$1"
printf 'holder_ctl=%s\n' "$_SSH_CTL_DIR"
printf 'holder_ready=yes\n'
# Long enough that the visitor's whole run — connect, remote step, teardown —
# happens inside it. The output is what proves the session was not cut: a killed
# master takes the session with it, and ssh exits 255 having printed nothing.
out=$(ssh_script <<'REMOTE'
sleep 8
printf 'survived\n'
REMOTE
); rc=$?
printf 'holder_rc=%s\n' "$rc"
printf 'holder_out=%s\n' "$out"
DRIVER

cat > "$tmpdir/visitor.sh" <<'DRIVER'
set -uo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

ssh_connect "$1"
printf 'visitor_ctl=%s\n' "$_SSH_CTL_DIR"
printf 'visitor_user=%s\n' "$(ssh_run id -un)"
# Not called explicitly: the EXIT trap is what every command relies on, and the
# trap is what fired in the case above.
DRIVER

rig_env_bash "$tmpdir/holder.sh" "$RIG_TARGET" >"$tmpdir/holder.out" 2>"$tmpdir/holder.err" &
holder_pid=$!
# Wait for the holder's remote command to be under way rather than sleeping a
# guessed interval: the visitor has to arrive while there is something to kill.
for _ in $(seq 1 100); do
    grep -qF holder_ready "$tmpdir/holder.out" 2>/dev/null && break
    sleep 0.1
done
sleep 1

visitor_out=$(rig_env_bash "$tmpdir/visitor.sh" "$RIG_TARGET" 2>"$tmpdir/visitor.err")
visitor_rc=$?
wait "$holder_pid"; holder_rc=$?
holder_out=$(<"$tmpdir/holder.out")

assert '[ "$visitor_rc" = "0" ]' \
    "the second run works while the first is mid-command (exit $visitor_rc: $(cat "$tmpdir/visitor.err"))"
assert 'grep -qxF "visitor_user=stevedore" <<<"$visitor_out"' \
    "and really did reach the server (got '$visitor_out')"

holder_ctl=$(sed -n 's/^holder_ctl=//p' <<<"$holder_out")
visitor_ctl=$(sed -n 's/^visitor_ctl=//p' <<<"$visitor_out")
assert '[ -n "$holder_ctl" ] && [ "$holder_ctl" != "$visitor_ctl" ]' \
    "the two runs used different control directories ('$holder_ctl' and '$visitor_ctl')"

assert '[ "$holder_rc" = "0" ]' "the first run finished (exit $holder_rc: $(cat "$tmpdir/holder.err"))"
assert 'grep -qxF "holder_rc=0" <<<"$holder_out"' \
    "its remote command was not killed by the second run's teardown (got '$(grep -F holder_rc= <<<"$holder_out")')"
assert 'grep -qxF "holder_out=survived" <<<"$holder_out"' \
    "and returned its output whole (got '$(grep -F holder_out= <<<"$holder_out")')"
assert '[ ! -e "$holder_ctl" ] && [ ! -e "$visitor_ctl" ]' \
    "both control directories are gone afterwards ($holder_ctl, $visitor_ctl)"

# --- The real ~/.ssh/config is out of reach -----------------------------------
# Proven from ssh's own account of which files it read, not from this file's
# opinion. The control run establishes that the real config would have been
# read — otherwise the assertion below would pass on a machine that has none.
pw_home=$(getent passwd "$(id -u)" | cut -d: -f6)
harness_dbg=$(env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    ssh -vv -G "$RIG_SSH_ALIAS" 2>&1)
control_dbg=$(ssh -vv -G kasbah-not-in-any-config 2>&1)

assert '[ -n "$pw_home" ]' "the passwd entry names a home directory (got '$pw_home')"
assert 'grep -qF "Reading configuration data $pw_home/.ssh/config" <<<"$control_dbg"' \
    "ssh does read $pw_home/.ssh/config when nothing stops it (else the next check proves nothing)"
assert '! grep -qF "Reading configuration data $pw_home/.ssh/config" <<<"$harness_dbg"' \
    "under the harness, ssh never opens $pw_home/.ssh/config — so no host defined only there can resolve"
assert 'grep -qF "Reading configuration data $RIG_HOME/.ssh/config" <<<"$harness_dbg"' \
    "under the harness, ssh reads the scratch config"

harness_cfg=$(env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" ssh -G "$RIG_SSH_ALIAS" 2>&1)
assert 'grep -qxF "hostname 127.0.0.1" <<<"$harness_cfg"' "the included rig contract supplies the host (got '$(grep "^hostname " <<<"$harness_cfg")')"
assert 'grep -qxF "user stevedore" <<<"$harness_cfg"'     "the included rig contract supplies the user"

# A name the rig contract does not define must stay exactly what it was: if any
# other config were in play, this is where a `Host *` block would show up.
stray_cfg=$(env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" ssh -G kasbah-not-in-any-config 2>&1)
assert 'grep -qxF "hostname kasbah-not-in-any-config" <<<"$stray_cfg"' \
    "an unknown alias resolves to nothing under the harness (got '$(grep "^hostname " <<<"$stray_cfg")')"
assert 'grep -qxF "port 22" <<<"$stray_cfg"' \
    "an unknown alias keeps the default port under the harness (got '$(grep "^port " <<<"$stray_cfg")')"

# --- An unreachable host fails fast, with exit 3 ------------------------------
cat > "$tmpdir/unreachable.sh" <<'DRIVER'
set -uo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
ssh_connect "$1"
echo "connected=yes"
DRIVER

started=$SECONDS
unreachable_out=$(rig_env_bash "$tmpdir/unreachable.sh" \
    deploy@kasbah-unreachable.invalid 2>"$tmpdir/unreachable.err")
unreachable_rc=$?
elapsed=$((SECONDS - started))
unreachable_err=$(<"$tmpdir/unreachable.err")

assert '[ "$unreachable_rc" = "3" ]' "an unreachable host exits 3 (got $unreachable_rc)"
assert '[ -z "$unreachable_out" ]'   "nothing runs past an unreachable host (got '$unreachable_out')"
assert '[ "$elapsed" -lt 30 ]'       "an unreachable host fails promptly (took ${elapsed}s)"
assert 'grep -qF "kasbah-unreachable.invalid" <<<"$unreachable_err"' \
    "the unreachable target is named (got '$unreachable_err')"
# Whatever ssh said comes out first and unedited. Matching a particular phrase
# would only pin today's failure mode: under the harness fence an unroutable
# name dies in the ProxyCommand, not in DNS, and both are ssh speaking.
ssh_said="${unreachable_err%%$'\n'*}"
assert '[ -n "$ssh_said" ] && [[ "$ssh_said" != error:* ]]' \
    "ssh's own error is surfaced ahead of kasbah's, not swallowed (got '$ssh_said')"

# --- Everything but the rig is fenced off -------------------------------------
# `-F` replaces the config file; it does not stop an alias the config says
# nothing about from falling through to the defaults, real keys and all. The
# control here is the rig's own published endpoint reached by IP: a listener
# that genuinely answers ssh on this machine, and not the `rig` alias, so the
# fence is the only thing between the suite and it.
rig_ip=$(ssh -F "$RIG_SSH_CONFIG" -G "$RIG_SSH_ALIAS" 2>/dev/null | awk '$1=="hostname"{print $2}')
rig_port=$(ssh -F "$RIG_SSH_CONFIG" -G "$RIG_SSH_ALIAS" 2>/dev/null | awk '$1=="port"{print $2}')
rig_key=$(ssh -F "$RIG_SSH_CONFIG" -G "$RIG_SSH_ALIAS" 2>/dev/null | awk '$1=="identityfile"{print $2; exit}')
assert '[ -n "$rig_ip" ] && [ -n "$rig_port" ] && [ -n "$rig_key" ]' \
    "the rig contract yields an endpoint to aim the control at (got '$rig_ip:$rig_port' key '$rig_key')"

# Deliberately outside the harness and outside the contract's Host block: a
# plain ssh, to establish that this endpoint really does answer. Without it the
# fenced attempt below could be failing for any reason at all.
#
# `-n` for the same reason rig_env.sh redirects stdin: `timeout` runs its child
# in its own process group, so an ssh that reads the controlling terminal is
# stopped by SIGTTIN and never lives to receive the timeout's SIGTERM. Both
# calls here are `id -un` and want no stdin at all.
control_out=$(timeout 20 ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "$rig_key" -p "$rig_port" "$RIG_SSH_USER@$rig_ip" id -un 2>&1)
assert '[ "$control_out" = "stevedore" ]' \
    "the endpoint answers ssh when nothing fences it (got '$control_out')"

fenced_out=$(timeout 20 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    ssh -n -p "$rig_port" "$RIG_SSH_USER@$rig_ip" id -un 2>&1); fenced_rc=$?
assert '[ "$fenced_rc" != "0" ]' \
    "under the harness the same endpoint is unreachable by IP (exit $fenced_rc, said '$fenced_out')"
assert '[ "$fenced_out" != "stevedore" ]' "the fenced attempt did not log in"
# The ProxyCommand signature. A refused or absent listener would say
# "Connection refused" instead, which would prove nothing about the fence.
assert 'grep -qF "Connection closed by UNKNOWN" <<<"$fenced_out"' \
    "the fenced attempt died in ProxyCommand /bin/false, never reaching an sshd (got '$fenced_out')"

fenced_cfg=$(env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" ssh -G "$RIG_SSH_USER@$rig_ip" 2>/dev/null)
assert 'grep -qxF "proxycommand /bin/false" <<<"$fenced_cfg"' "a non-rig host has no way to connect"
assert 'grep -qxF "identityfile /dev/null" <<<"$fenced_cfg"'  "a non-rig host is offered no key"
assert 'grep -qxF "identityagent none" <<<"$fenced_cfg"'      "a non-rig host cannot reach the agent"
# And the fence leaves the rig alone — `Match host *,!rig` looks equivalent and
# does not, because its IdentityFile appends to the rig's instead of replacing.
rig_cfg=$(env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" ssh -G "$RIG_SSH_ALIAS" 2>/dev/null)
assert '! grep -qF "proxycommand" <<<"$rig_cfg"'          "the rig itself is not fenced"
assert 'grep -qxF "identityfile $rig_key" <<<"$rig_cfg"'  "the rig still gets exactly its own key"

# --- The payload refuses on a host that is not the rig ------------------------
# The marker is hidden on the rig itself: same sshd, same docker, same /apps —
# everything a real server has — differing only in the one file the payload
# checks. Restored by the EXIT trap whatever happens next.
rig_ssh 'sudo mkdir -p /apps/guard-probe' >/dev/null 2>&1
# Flagged before the move, not after: a crash between the two would otherwise
# leave the marker hidden and every later rig_clean refusing.
marker_hidden=1
if rig_ssh "sudo mv -f $RIG_MARKER_FILE $RIG_MARKER_FILE.hidden" >/dev/null 2>&1; then
    guard_err=$(rig_clean 2>&1); guard_rc=$?
    rig_ssh "sudo mv -f $RIG_MARKER_FILE.hidden $RIG_MARKER_FILE" >/dev/null 2>&1 \
        && marker_hidden=0
    guard_state=$(rig_ssh "[ -d /apps/guard-probe ] && echo present || echo gone; cat $RIG_MARKER_FILE" 2>&1)

    assert '[ "$guard_rc" = "$RIG_NOT_THE_RIG" ]' \
        "a host without the marker is refused with $RIG_NOT_THE_RIG (got $guard_rc)"
    assert 'grep -qF "not the rig" <<<"$guard_err"' \
        "the refusal says why (got '$guard_err')"
    assert 'grep -qF "present" <<<"$guard_state"' \
        "the refused clean deleted nothing (got '$guard_state')"
    assert 'grep -qxF "$RIG_MARKER_VALUE" <<<"$guard_state"' \
        "the marker is back where it belongs (got '$guard_state')"
else
    marker_hidden=0
    assert 'false' "could not hide $RIG_MARKER_FILE to exercise the payload's guard"
fi

# --- rig_clean refuses when the rig is unreachable ----------------------------
# The unreachable target comes from a stand-in contract, not from pointing the
# alias at some other machine: a rig_clean that can be aimed is the hazard, not
# the test. 192.0.2.0/24 is TEST-NET-1 and routes nowhere.
standin="$tmpdir/unreachable-rig.ssh_config"
{
    printf 'Host %s\n' "$RIG_SSH_ALIAS"
    printf '    HostName 192.0.2.1\n'
    printf '    Port 5022\n'
    printf '    User %s\n' "$RIG_SSH_USER"
    printf '    ConnectTimeout 2\n'
    printf '    BatchMode yes\n'
    printf '    StrictHostKeyChecking no\n'
    printf '    UserKnownHostsFile /dev/null\n'
} > "$standin"

rig_ssh 'sudo mkdir -p /apps/refusal-marker' >/dev/null 2>&1
refusal_err=$( (RIG_SSH_CONFIG="$standin" rig_clean) 2>&1 ); refusal_rc=$?
assert '[ "$refusal_rc" != "0" ]'                       "rig_clean fails when the rig does not answer (exit $refusal_rc)"
assert 'grep -qF "refusing to clean anything" <<<"$refusal_err"' \
    "the refusal says it changed nothing (got '$refusal_err')"
marker=$(rig_ssh '[ -d /apps/refusal-marker ] && echo present || echo gone' 2>&1)
assert '[ "$marker" = "present" ]' "a refused clean really changed nothing (got '$marker')"

# --- Leave the rig as it was found, but only on success -----------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh 'docker rmi -f kasbah-clean-probe:test >/dev/null 2>&1; rm -rf /tmp/kasbah-clean-probe' >/dev/null 2>&1
    rig_clean || fail=1
fi

exit "$fail"
