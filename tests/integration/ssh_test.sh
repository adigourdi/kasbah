#!/usr/bin/env bash
# Integration test: kasbah's ssh transport against the live rig, and the
# connection model every rig-driven suite inherits from
# tests/integration/rig_env.sh.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which is establishing a known starting state rather than
# repairing a broken environment — a crashed earlier run must not decide what
# this one sees. The rig is cleaned again at the end only if everything passed,
# so a failure leaves its state there to be looked at.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

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

# --- The invoker every rig suite uses -----------------------------------------
# The checkout's CLI runs under the scratch HOME and the ssh wrapper.
cli_out=$(kasbah_cli --version 2>&1); cli_rc=$?
assert '[ "$cli_rc" = "0" ]' "kasbah_cli runs the checkout's CLI (exit $cli_rc: $cli_out)"
assert '[[ "$cli_out" == "kasbah $(kasbah_bin_version) (schema "* ]]' \
    "kasbah_cli runs this checkout, not an installed copy (got '$cli_out')"

# --- The cleanup payload cannot run locally -----------------------------------
# A static read of rig_env.sh, before anything is executed: every destructive
# line must live inside the quoted heredoc that goes to the rig. This
# workstation runs unrelated production stacks, and a `docker compose down -v`
# that executed here instead of there would take them with it.
env_src="$repo_dir/tests/integration/rig_env.sh"
payload=$(awk "/<<'REMOTE'/{p=1;next} p&&/^REMOTE\$/{p=0} p" "$env_src")
assert '[ -n "$payload" ]' "the remote payload was found in rig_env.sh (else the checks below are vacuous)"
for token in 'docker compose -p' 'down -v' 'docker network rm' 'docker volume rm' 'rm -rf /apps'; do
    in_file=$(grep -cF -- "$token" "$env_src")
    in_payload=$(grep -cF -- "$token" <<<"$payload")
    assert '[ "$in_payload" -gt 0 ]'            "the payload contains '$token' (else it does not clean)"
    assert '[ "$in_file" = "$in_payload" ]'     "'$token' appears only inside the remote payload ($in_payload of $in_file occurrences)"
done
for banned in 'docker system prune' 'docker volume prune' 'docker network prune' \
              'docker container prune' 'docker image prune' 'docker rm ' 'docker rmi ' \
              'docker ps -aq'; do
    assert '! grep -qF -- "$banned" "$env_src"' \
        "rig_env.sh contains no '$banned' — nothing sweeps beyond compose projects"
done

# The two resource classes the payload enumerates rather than names: orphaned
# project networks, and the anonymous volumes `down -v` cannot reap when it
# downs a project by label with no compose file to read. Both are allowed only
# in the filtered form, which is what keeps "sweep" from meaning "everything":
# `docker volume ls` on its own would list volumes another suite is still using,
# and `docker volume prune` is banned above precisely because it is that.
for pair in 'docker volume ls|--filter dangling=true' \
            'docker network ls|--filter label=com.docker.compose.project'; do
    listing="${pair%%|*}"
    filter="${pair#*|}"
    total=$(grep -cF -- "$listing" "$env_src")
    filtered=$(grep -F -- "$listing" "$env_src" | grep -cF -- "$filter")
    assert '[ "$total" -gt 0 ]' \
        "the payload enumerates with '$listing' (else nothing reaps what compose leaves behind)"
    assert '[ "$total" = "$filtered" ]' \
        "and every '$listing' carries '$filter' — an unfiltered one would sweep another suite's resources ($filtered of $total)"
    assert '[ "$total" = "$(grep -cF -- "$listing" <<<"$payload")" ]' \
        "and all of them are inside the remote payload"
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
  # Two volumes, and the second one is the point: `probe-data` is named and
  # carries compose's own labels, while `/anon` is anonymous — the shape any
  # image declaring VOLUME produces (redis:7-alpine, which the built-app fixture
  # runs). `docker compose down -v` reaps an anonymous volume only when it can
  # read the compose file, and rig_clean downs by project label with no file in
  # sight, so this is what its dangling sweep exists for.
  printf '    command: ["/nonexistent"]\n    volumes: [probe-data:/data, /anon]\n'
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
assert 'grep -qF "seeded_volumes=2" <<<"$seed_out"' \
    "both a named and an anonymous compose volume exist on the rig (got '$seed_out')"
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
assert 'grep -qF "volumes=0" <<<"$after_out"' \
    "clean removes the projects' volumes, the anonymous one included — an aborted
        suite that leaves one behind fails the next run's seed count
        (got '$(grep "^volumes=" <<<"$after_out")')"
assert 'grep -qxF "networks=bridge,host,none," <<<"$after_out"' \
    "clean removes kasbah-net and keeps the three built-ins (got '$(grep "^networks=" <<<"$after_out")')"
assert 'grep -qE "^images=.*kasbah-clean-probe:test," <<<"$after_out"' \
    "clean keeps the image cache — that is the whole reason it exists (got '$(grep "^images=" <<<"$after_out")')"

# --- The transport, against the live rig --------------------------------------
# One CLI run that connects, works and leaves: under a TMPDIR of its own, so
# what the run leaves behind is all that is in it. Quoting, the sync and the
# payloads are every other rig suite's business; this is the connection.
run_tmp="$tmpdir/run-tmp"
mkdir -p "$run_tmp"
# The rig is clean here, so `server status` connects, finds no marker and
# exits 4 — an answer only the server can give.
timeout "$RIG_WORK_TIMEOUT" env TMPDIR="$run_tmp" HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$KASBAH_BIN" server status "$RIG_TARGET" >/dev/null 2>"$tmpdir/transport.err" </dev/null
transport_rc=$?
assert '[ "$transport_rc" = "4" ] && grep -qF "$RIG_TARGET has no server marker" "$tmpdir/transport.err"' \
    "a CLI run reaches the rig through the harness and reads it (exit $transport_rc: $(cat "$tmpdir/transport.err"))"
shopt -s nullglob
left=("$run_tmp"/kasbah-ssh.*)
home_socks=("$RIG_HOME"/.ssh/cm-*)
shopt -u nullglob
assert '[ "${#left[@]}" = "0" ]' "the run's control directory goes with it (left: ${left[*]:-})"
assert '[ "${#home_socks[@]}" = "0" ]' "no control socket is left in the user's ~/.ssh (found ${#home_socks[@]})"

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
started=$SECONDS
unreachable_out=$(timeout "$RIG_WORK_TIMEOUT" env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" "$KASBAH_BIN" server status \
    deploy@kasbah-unreachable.invalid 2>"$tmpdir/unreachable.err" </dev/null)
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
