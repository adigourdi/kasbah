#!/usr/bin/env bash
# Rig PID 1: bring up dockerd, then sshd, and take the container down if
# either one dies.
set -euo pipefail

DOCKERD_LOG=/var/log/dockerd.log
# Bounds how long dockerd may take to answer at boot. Unrelated to compose's
# healthcheck start_period, which bounds how long an already-broken rig is
# allowed to look merely "starting" before it is reported unhealthy.
# compose.yml passes this through from the host's KASBAH_RIG_DOCKERD_TIMEOUT and
# passes it empty when that is unset, so `:-` (empty or unset) rather than `-`.
DOCKERD_TIMEOUT=${RIG_DOCKERD_TIMEOUT:-90}

fail() {
    printf 'rig: %s\n' "$*" >&2
    [ -s "$DOCKERD_LOG" ] && tail -n 40 "$DOCKERD_LOG" >&2
    exit 1
}

# The authorized key arrives in the environment rather than as a bind mount.
# Docker materialises a missing mount source as a root-owned directory on the
# host — at a gitignored path that would then be invisible in `git status` and
# unwritable without sudo. An env var simply cannot fail that way.
key=${RIG_AUTHORIZED_KEY:-}
case $key in
    'ssh-ed25519 '*|'ssh-rsa '*|'ecdsa-'*) ;;
    # Deliberately no "or export the key and drive docker compose yourself"
    # hint: a compose command without `-p kasbah-rig` is aimed by whatever
    # COMPOSE_PROJECT_NAME the shell carries, and the `down -v` that follows
    # removes that project instead. An error message is the last place to teach
    # a form that unsafe.
    *) fail 'RIG_AUTHORIZED_KEY holds no public key — start the rig with tests/rig/rig.sh up, which generates the keypair and passes it in' ;;
esac
install -d -m 0700 -o stevedore -g stevedore /home/stevedore/.ssh
printf '%s\n' "$key" > /home/stevedore/.ssh/authorized_keys
chown stevedore:stevedore /home/stevedore/.ssh/authorized_keys
chmod 0600 /home/stevedore/.ssh/authorized_keys

# Host keys are generated per container rather than shipped in the image: an
# image carrying a private key is a footgun even for a throwaway rig.
ssh-keygen -A >/dev/null
install -d -m 0755 /run/sshd

# Nested docker networks inherit the outer interface's MTU. A mismatch never
# reports itself — it shows up as TLS handshakes that hang forever — so pin
# dockerd to the MTU this container actually has rather than hoping for 1500.
mtu=1500
[ -r /sys/class/net/eth0/mtu ] && mtu=$(cat /sys/class/net/eth0/mtu)

# /run is part of the container filesystem, so a `docker restart` hands dockerd
# back its own pidfile and socket from the previous boot. dockerd then refuses
# to start ("process with PID n is still running") whenever an unrelated
# process has inherited that PID in the fresh namespace.
rm -f /var/run/docker.pid /var/run/docker.sock

dockerd --mtu="$mtu" >"$DOCKERD_LOG" 2>&1 &
dockerd_pid=$!

# Gate sshd on a daemon that answers, not on a fixed sleep: a rig that accepts
# SSH before docker works turns every later integration test into a flake.
deadline=$((SECONDS + DOCKERD_TIMEOUT))
until docker info >/dev/null 2>&1; do
    kill -0 "$dockerd_pid" 2>/dev/null || fail 'dockerd exited during startup'
    [ "$SECONDS" -lt "$deadline" ] || fail "dockerd did not answer within ${DOCKERD_TIMEOUT}s"
    sleep 0.5
done

/usr/sbin/sshd -D -e &
sshd_pid=$!

shutdown() {
    kill -TERM "$dockerd_pid" "$sshd_pid" 2>/dev/null || true
    wait "$dockerd_pid" "$sshd_pid" 2>/dev/null || true
}

# Forward the stop signal to both children so `docker stop` returns promptly
# instead of waiting out its kill timeout.
trap 'shutdown; exit 143' TERM INT

# Both processes are load-bearing: a container that keeps answering SSH with a
# dead dockerd looks healthy and fails every test that touches docker, which is
# the worst possible failure mode for later phases. Whichever dies first takes
# the rig with it. `wait -n` reports the dead child's status, so it is guarded
# against set -e.
status=0
wait -n "$dockerd_pid" "$sshd_pid" || status=$?
if kill -0 "$sshd_pid" 2>/dev/null; then
    dead=dockerd
else
    dead=sshd
fi
shutdown
printf 'rig: %s exited (status %s) — stopping the rig\n' "$dead" "$status" >&2
[ "$status" -ne 0 ] || status=1
exit "$status"
