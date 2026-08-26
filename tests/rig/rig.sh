#!/usr/bin/env bash
# Lifecycle for the fake VPS: tests/rig/rig.sh up|down|reset|ssh.
#
# Every verb is idempotent and safe to run from any working directory, and no
# verb can reach a container outside the rig's own compose project — see the
# `-p` in compose() for why the pin has to be a flag and not compose.yml's
# `name:`.
set -euo pipefail

rig_dir="$(cd "$(dirname "$0")" && pwd)"
compose_file="$rig_dir/compose.yml"
key_file="$rig_dir/id_ed25519"
pub_file="$key_file.pub"
# The one place the SSH flags are written down. Integration tests (1.3) and the
# rsync/scp calls of later phases take `-F "$ssh_config"` rather than restating
# them, because two copies of a connection contract drift.
ssh_config="$rig_dir/ssh_config"
ssh_alias=rig
# Mirrors `image:` in compose.yml; only used to tell a first build from a later one.
rig_image=kasbah-rig
# Mirrors `name:` in compose.yml, but passed as `-p` — see compose().
rig_project=kasbah-rig

# The two rest-server endpoints of compose.yml, and the file that hands them to
# a suite. Addresses and credentials are read back out of the containers rather
# than restated here: compose.yml declares them, and a second copy of a
# credential is a copy that drifts.
backup_service=backup-store
backup_admin_service=backup-store-admin
backup_port=8000
# The contract a suite reads, gitignored like ssh_config but not rendered on
# every verb the way that one is: `up` writes it when both endpoints serve and
# deletes it when they do not, so its absence is the signal and never a stale
# credential.
backup_env_file="$rig_dir/backup_env.sh"

# Where a *new* container gets published: compose.yml reads the same variables,
# so an override here moves the publish side. It does not move the connect side
# on its own — once a container exists, write_ssh_config reads the binding back
# out of Docker and overwrites these, because the port is a property of the
# running container and not of whatever a later caller happens to have exported.
rig_bind=${KASBAH_RIG_BIND:-127.0.0.1}
rig_ssh_port=${KASBAH_RIG_SSH_PORT:-5022}
# Bounds the wait for a usable rig: 30x the observed ~2 s, so a loaded machine
# still passes, and still inside this phase's "reset in under a minute" bar.
ready_timeout=${KASBAH_RIG_READY_TIMEOUT:-60}

die() {
    printf 'rig: %s\n' "$*" >&2
    exit 1
}

note() { printf 'rig: %s\n' "$*" >&2; }

# `-p` is not redundant with compose.yml's `name:`. Of the three sources of a
# project name — `-p`, COMPOSE_PROJECT_NAME, `name:` — the file is the weakest,
# so an exported COMPOSE_PROJECT_NAME left over from another stack silently
# retargets every call here. `down -v` would then remove that project's
# containers and volumes, since it works off the project label rather than the
# services listed in the file. The flag outranks the environment, which is the
# only reason this script cannot touch anything but the rig.
compose() { docker compose -p "$rig_project" -f "$compose_file" "$@"; }

# Empty when the rig has no container — including a container that exists but is
# stopped, which `-a` deliberately still reports.
container_id() { compose ps -aq rig 2>/dev/null || true; }

usage() {
    cat <<EOF
usage: rig.sh <up|down|reset|ssh>

  up            build if needed, start the rig, wait until it is usable
  down          stop the rig and remove its volumes
  reset         down then up — a pristine rig
  ssh [-- cmd]  ssh in as stevedore; with a command, propagate its exit status

environment: KASBAH_RIG_BIND, KASBAH_RIG_{SSH,HTTP,HTTPS}_PORT,
             KASBAH_RIG_READY_TIMEOUT, KASBAH_RIG_DOCKER_VERSION,
             KASBAH_RIG_DOCKERD_TIMEOUT
EOF
}

# A missing bind-mount source is materialised by Docker as a root-owned
# directory (see 01-rig.md); these paths are gitignored, so such a thing is
# invisible in `git status` and unwritable without sudo. Nothing mounts them
# any more, but `-f` rather than `-e` is the habit that catches the next one.
assert_plain_file() {
    [ ! -e "$1" ] || [ -f "$1" ] || die "$1 exists but is not a regular file — remove it (it may be a root-owned directory left by an older rig)"
}

ensure_key() {
    assert_plain_file "$key_file"
    assert_plain_file "$pub_file"
    if [ ! -s "$key_file" ]; then
        rm -f "$key_file" "$pub_file"
        ssh-keygen -t ed25519 -N '' -C kasbah-rig -f "$key_file" >/dev/null \
            || die "ssh-keygen could not write $key_file"
        note "generated a rig keypair at $key_file (gitignored)"
    fi
    chmod 0600 "$key_file"

    # The private half is the authority: whatever it derives to is the key the
    # rig must authorize. </dev/null so a passphrase-protected key fails here
    # rather than stopping to prompt in the middle of a test run.
    local derived
    derived=$(ssh-keygen -y -f "$key_file" </dev/null 2>/dev/null) \
        || die "could not read the private key $key_file — delete it and both halves are regenerated"

    if [ ! -s "$pub_file" ]; then
        # Derivable, and the rig cannot start without it. Writing it costs
        # nothing and destroys nothing.
        printf '%s\n' "$derived" > "$pub_file"
        return 0
    fi

    # A .pub that does not belong to the private key installs an authorized key
    # nobody holds: the rig boots, looks healthy, and refuses every login until
    # wait_ready times out blaming the rig. Caught here it costs milliseconds.
    # This is a hard failure rather than a silent rewrite because rig.sh cannot
    # produce this state — something outside it wrote that file, and quietly
    # deleting a file the operator put there is the worse surprise. Only type
    # and blob are compared, so a differing comment field is not a mismatch.
    local stored dtype dblob stype sblob
    stored=$(<"$pub_file")
    stored=${stored//$'\r'/}
    read -r dtype dblob _ <<<"$derived"
    read -r stype sblob _ <<<"$stored"
    [ "$dtype $dblob" = "$stype $sblob" ] \
        || die "$pub_file is not the public half of $key_file — delete it to have it rederived, or delete both to start from a fresh keypair"
}

# The authorized key travels to the container in the environment, never as a
# mount. compose.yml defaults it to empty so `down` still works without it,
# which means every command that creates or recreates the container must set it
# here or the entrypoint refuses to boot.
export_pubkey() {
    local pub
    pub=$(<"$pub_file")
    pub=${pub//$'\r'/}
    case $pub in
        'ssh-ed25519 '*|'ssh-rsa '*|'ecdsa-'*) ;;
        *) die "$pub_file does not hold a public key — delete it and rerun rig.sh up" ;;
    esac
    export KASBAH_RIG_PUBKEY=$pub
}

# The published SSH endpoint belongs to the container, not to this process's
# environment: it is fixed when the container is created, and every later caller
# shares one generated ssh_config. Deriving it from the environment instead let a
# single stray `KASBAH_RIG_SSH_PORT=… rig.sh ssh` repoint that shared file at a
# port nothing listens on, breaking every subsequent caller — which then blamed
# the rig. So it is read back out of Docker, and the environment is consulted
# only when there is no container to read (see write_ssh_config).
#
# `docker port` is the truth for a running container, but it prints one line per
# binding — an IPv4 and an IPv6 line for a wildcard bind — and it fails outright
# on a container that exists but is stopped. Hence: prefer its IPv4 line, and
# fall back to the bindings recorded at create time, which survive a stop.
# Returns 1 without touching anything if neither source names a port.
resolve_published_endpoint() {
    local cid=$1 out line ip port
    out=$(docker port "$cid" 22 2>/dev/null) || out=
    [ -n "$out" ] || out=$(docker inspect \
        -f '{{range index .HostConfig.PortBindings "22/tcp"}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}' \
        "$cid" 2>/dev/null) || out=
    [ -n "$out" ] || return 1

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        port=${line##*:}
        ip=${line%:*}
        # An IPv6 host keeps its colons (and its brackets, from `docker port`)
        # after that split. The config connects over IPv4, so those are not
        # candidates — and the IPv4 line is not always the first one.
        case $ip in *:*|*'['*) continue ;; esac
        [ -n "$port" ] || continue
        # An empty HostIp is Docker's "every interface"; 0.0.0.0 is how `docker
        # port` spells the same thing, and it is connectable.
        [ -n "$ip" ] || ip=0.0.0.0
        rig_bind=$ip
        rig_ssh_port=$port
        return 0
    done <<<"$out"
    return 1
}

# Rewritten on every invocation, from the container where there is one: it
# embeds the endpoint and the key path, so neither a changed KASBAH_RIG_SSH_PORT
# nor a recreated container can leave a stale file behind.
# Rendered to a sibling temp file and renamed, never truncated in place: two
# rig.sh calls at once would otherwise leave a window where a concurrent reader
# sees an empty config, silently loses the `Host rig` block, and tries to
# resolve `rig` as a real hostname. Rename is atomic, so a reader sees the old
# contract or the new one, never neither.
# StrictHostKeyChecking/UserKnownHostsFile are not laziness — the rig generates
# fresh host keys per container, so every reset would otherwise poison
# ~/.ssh/known_hosts. LogLevel ERROR silences the "permanently added" notice
# that /dev/null makes unavoidable and that would otherwise pollute test output.
write_ssh_config() {
    local tmp cid
    # No container means nothing has been published yet and the environment is
    # all there is — which is also exactly what the next `up` will publish with.
    cid=$(container_id)
    [ -z "$cid" ] || resolve_published_endpoint "$cid" || true

    tmp=$(mktemp "$ssh_config.XXXXXX") || die "could not create a temp file next to $ssh_config"
    # Cleaned up inline rather than with a RETURN trap: bash keeps a RETURN
    # trap installed after the function that set it returns, so the handler
    # fires again later against a `tmp` that is out of scope — with set -u,
    # that is an unbound-variable abort in an unrelated verb.
    if ! cat > "$tmp" <<EOF
# Generated by tests/rig/rig.sh — edits are overwritten. Reuse it, do not copy
# the flags: ssh -F "$ssh_config" $ssh_alias, rsync -e "ssh -F $ssh_config", …
Host $ssh_alias
    HostName $rig_bind
    Port $rig_ssh_port
    User stevedore
    IdentityFile $key_file
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    BatchMode yes
    ConnectTimeout 5
    LogLevel ERROR
EOF
    then
        rm -f "$tmp"
        die "could not write $ssh_config"
    fi
    chmod 0644 "$tmp" && mv -f "$tmp" "$ssh_config" \
        || { rm -f "$tmp"; die "could not install $ssh_config"; }
}

dump_diagnostics() {
    local cid
    cid=$(container_id)
    if [ -n "$cid" ]; then
        printf 'rig: container state: %s\n' \
            "$(docker inspect -f '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>&1)" >&2
    fi
    compose logs --tail 60 rig >&2 2>&1 || true
}

# Proves the rig works, not that a container exists. It is strictly stronger
# than compose's healthcheck — same three conditions plus "the installed key is
# *our* key", which the healthcheck cannot see — and it answers within a second
# of boot instead of waiting out the healthcheck's 10 s interval.
probe() { ssh -F "$ssh_config" "$ssh_alias" docker info >/dev/null 2>&1; }

wait_ready() {
    local deadline=$((SECONDS + ready_timeout)) cid
    cid=$(container_id)
    [ -n "$cid" ] || die 'no rig container after `docker compose up` — see the output above'
    while :; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" != true ]; then
            dump_diagnostics
            die 'the rig container stopped while starting up'
        fi
        probe && return 0
        if [ "$SECONDS" -ge "$deadline" ]; then
            dump_diagnostics
            die "the rig did not accept ssh with working docker within ${ready_timeout}s"
        fi
        sleep 0.5
    done
}

# ip, username and password of one rest-server, one field per line. Read from
# the container because that is what is actually serving; a stopped or
# never-created service returns 1 and says which one.
backup_facts() {
    local svc=$1 cid ip env_lines user password
    cid=$(compose ps -q "$svc" 2>/dev/null) || cid=
    [ -n "$cid" ] || { note "no $svc container — the backup harness is not up"; return 1; }
    # Separated and the first taken: concatenated, a second attached network
    # would hand out "10.77.29.1010.77.30.5" and the non-empty guard below would
    # pass it straight through.
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" 2>/dev/null) || ip=
    read -r ip _ <<<"$ip"
    env_lines=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null) || env_lines=
    user=$(grep -m1 '^RIG_BACKUP_USER=' <<<"$env_lines" || true); user=${user#*=}
    password=$(grep -m1 '^RIG_BACKUP_PASSWORD=' <<<"$env_lines" || true); password=${password#*=}
    [ -n "$ip" ] && [ -n "$user" ] && [ -n "$password" ] \
        || { note "$svc does not declare an address and a credential — see compose.yml"; return 1; }
    printf '%s\n%s\n%s\n' "$ip" "$user" "$password"
}

# The credentials end up unescaped in two places: a restic `rest:` URL, which
# would need percent-encoding, and inside single quotes on an ssh command line,
# which a quote would end. They are constants in compose.yml, so the answer is
# to refuse anything that would need encoding rather than to encode it.
backup_credential_safe() {
    case ${1-} in
        ''|*[!A-Za-z0-9._~-]*) return 1 ;;
    esac
    return 0
}

# Absence is the signal (see backup_env_file), so a harness that is not serving
# must not leave the file behind. Never fatal: fourteen of the fifteen
# integration suites never touch the harness, and the one that does exits 2 on
# its own — killing `up` here would turn one suite's environment problem into a
# rig nobody has.
backup_unavailable() {
    rm -f "$backup_env_file"
    note "backup harness unavailable, continuing without it — $1"
}

# One ssh session that retries on the far side: the consumer of these endpoints
# is a container the *rig's* daemon starts, so the honest probe is made from the
# rig. Two answers per endpoint, because neither alone is worth anything: 404 to
# the real credential on a path that is no repository (an empty htpasswd would
# give 401 instead), and 401 to a bogus one — measured, a server started
# --no-auth answers 404 to any credential at all, one word in compose.yml's
# OPTIONS away.
wait_backup_ready() {
    local log rc=0
    log=$(mktemp "${TMPDIR:-/tmp}/kasbah-rig-backup.XXXXXX") || die 'could not create a temp file for the backup probe'
    # Not $(ssh … <<'REMOTE'): bash cannot see a here-document delimiter through
    # a command substitution and warns "unterminated here-document".
    ssh -F "$ssh_config" "$ssh_alias" \
        "bash -s '$1' '$2' '$3' '$4' '$5' '$6' '$backup_port' '$ready_timeout'" >"$log" 2>&1 <<'REMOTE' || rc=$?
set -uo pipefail
vps_ip=$1; vps_user=$2; vps_pw=$3
ops_ip=$4; ops_user=$5; ops_pw=$6
port=$7
deadline=$((SECONDS + $8))
bogus_user=kasbah-rig-no-such-user
probe() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        -u "$2:$3" "http://$1:$port/kasbah-rig-readiness/config" 2>/dev/null
}
while :; do
    vps="$(probe "$vps_ip" "$vps_user" "$vps_pw")/$(probe "$vps_ip" "$bogus_user" wrong)"
    ops="$(probe "$ops_ip" "$ops_user" "$ops_pw")/$(probe "$ops_ip" "$bogus_user" wrong)"
    [ "$vps" = 404/401 ] && [ "$ops" = 404/401 ] && exit 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.5
done
printf 'append-only endpoint answered %s, full-access endpoint answered %s (wanted 404/401 from both: the credential known, a bogus one rejected)\n' \
    "${vps:-nothing}" "${ops:-nothing}" >&2
exit 1
REMOTE
    local out
    out=$(<"$log")
    rm -f "$log"
    [ "$rc" = 0 ] && return 0
    compose logs --tail 20 "$backup_service" "$backup_admin_service" >&2 2>&1 || true
    note "the backup harness did not answer from inside the rig within ${ready_timeout}s: $out"
    return 1
}

# The endpoints as a suite consumes them (tests/integration/rig_env.sh sources
# this). Written only once both answer; every path that cannot write it removes
# it instead, and none of them stops `up`.
write_backup_env() {
    local vps ops tmp
    vps=$(backup_facts "$backup_service") || { backup_unavailable "$backup_service is not serving"; return 0; }
    ops=$(backup_facts "$backup_admin_service") || { backup_unavailable "$backup_admin_service is not serving"; return 0; }
    local vps_ip vps_user vps_pw ops_ip ops_user ops_pw
    { read -r vps_ip; read -r vps_user; read -r vps_pw; } <<<"$vps"
    { read -r ops_ip; read -r ops_user; read -r ops_pw; } <<<"$ops"

    local cred
    for cred in "$vps_user" "$vps_pw" "$ops_user" "$ops_pw"; do
        backup_credential_safe "$cred" || {
            backup_unavailable "a credential in compose.yml is not URL- and shell-safe (only A-Z a-z 0-9 . _ ~ - are accepted)"
            return 0
        }
    done

    wait_backup_ready "$vps_ip" "$vps_user" "$vps_pw" "$ops_ip" "$ops_user" "$ops_pw" \
        || { backup_unavailable 'the endpoints did not answer'; return 0; }

    tmp=$(mktemp "$backup_env_file.XXXXXX") || { backup_unavailable "could not create a temp file next to $backup_env_file"; return 0; }
    if ! cat > "$tmp" <<EOF
# Generated by tests/rig/rig.sh — edits are overwritten. Sourced by
# tests/integration/rig_env.sh; the values are read back out of the running
# rest-server containers, so compose.yml is the only place they are declared.
# Unquoted because backup_credential_safe has already refused anything that
# would need quoting, encoding or escaping.
RIG_BACKUP_URL=http://$vps_ip:$backup_port/
RIG_BACKUP_USER=$vps_user
RIG_BACKUP_PASSWORD=$vps_pw
RIG_BACKUP_REPO_BASE=rest:http://$vps_user:$vps_pw@$vps_ip:$backup_port/
RIG_BACKUP_ADMIN_URL=http://$ops_ip:$backup_port/
RIG_BACKUP_ADMIN_USER=$ops_user
RIG_BACKUP_ADMIN_PASSWORD=$ops_pw
RIG_BACKUP_ADMIN_REPO_BASE=rest:http://$ops_user:$ops_pw@$ops_ip:$backup_port/
EOF
    then
        rm -f "$tmp"
        backup_unavailable "could not write $backup_env_file"
        return 0
    fi
    chmod 0644 "$tmp" && mv -f "$tmp" "$backup_env_file" \
        || { rm -f "$tmp"; backup_unavailable "could not install $backup_env_file"; }
}

# compose.yml pairs `build:` with a fixed `image:`, so `up` on its own reuses
# whatever `kasbah-rig` already is and silently ignores an edited Dockerfile or
# entrypoint. Rebuild control lives here, and the rule is "always ask the
# builder": Docker's layer cache is the only staleness oracle that cannot
# itself go stale, a no-op build costs ~0.3 s, and an hour lost to a rig running
# last week's entrypoint costs rather more.
#
# Verbosity is gated on "does the `kasbah-rig` tag exist yet", i.e. the very
# first build of a checkout is loud and every later one is quiet. That is not
# the same as cold-vs-cached: a Dockerfile edit that re-runs apt is a silent
# ~20 s wait. The alternative is BuildKit's cache report on every single `up`,
# including the ones inside 1.3's test loop, which is the worse trade.
build() {
    local quiet=()
    docker image inspect "$rig_image" >/dev/null 2>&1 && quiet=(--quiet)
    compose build "${quiet[@]+"${quiet[@]}"}"
}

cmd_up() {
    ensure_key
    export_pubkey
    build
    compose up -d
    # Re-render now that there is a container to read: main's earlier render
    # could only go on the environment (there may have been no container, or an
    # older one on a different port), and what compose actually published is the
    # contract. wait_ready's probe is the first thing to depend on it.
    write_ssh_config
    wait_ready
    # After wait_ready, because it probes over the rig's own ssh: a rig that is
    # not up yet must be reported as a rig that is not up. It never fails the
    # verb — see backup_unavailable.
    write_backup_env
    note "ready — ssh -F $ssh_config $ssh_alias"
}

cmd_down() {
    rm -f "$backup_env_file"
    # -v removes the rig's own docker-data and backup-store volumes and nothing
    # else: the snapshot store is disposable with the rig, it is only rig_clean
    # it has to outlive. `down` deletes by project label, not by the services
    # listed in the file, so the whole safety of this line rests on compose()
    # forcing the project with `-p` — without that, an inherited
    # COMPOSE_PROJECT_NAME aims it at somebody else's running stack.
    compose down -v
}

cmd_reset() {
    # Validate the keypair before tearing anything down: a broken .pub is a
    # local, fixable mistake, and discovering it after `down` leaves the caller
    # with no rig at all. ensure_key is idempotent, so cmd_up repeating it costs
    # nothing.
    ensure_key
    cmd_down
    cmd_up
}

cmd_ssh() {
    [ -s "$key_file" ] || die 'no rig keypair — run tests/rig/rig.sh up first'
    [ "${1:-}" != "--" ] || shift
    local status=0
    ssh -F "$ssh_config" "$ssh_alias" "$@" || status=$?
    # 255 is ssh's own "could not connect" status. A remote command may also
    # exit 255, so this is a hint rather than a diagnosis — the status is
    # propagated either way.
    [ "$status" -ne 255 ] || note "could not reach $rig_bind:$rig_ssh_port — is the rig up? (tests/rig/rig.sh up)"
    exit "$status"
}

main() {
    local verb=${1:-}
    [ $# -eq 0 ] || shift
    case $verb in
        # Only `ssh` forwards arguments. Swallowing the rest would let a typo
        # like `rig.sh up --build` report success while doing something else.
        up|down|reset) [ $# -eq 0 ] || die "$verb: unknown argument '$1' (this verb takes none)" ;;
        ssh) ;;
        -h|--help|help) usage; exit 0 ;;
        '') usage >&2; exit 1 ;;
        *) printf 'rig: unknown verb %s\n' "$verb" >&2; usage >&2; exit 1 ;;
    esac
    command -v docker >/dev/null 2>&1 || die 'docker is not installed'
    # Every verb refreshes the contract, because `ssh` needs one that matches the
    # container that is actually running and a keyless checkout has none at all.
    # It is a read of the container, not of the environment, so a read-only verb
    # cannot move it (`up` renders it a second time, after creating the
    # container).
    write_ssh_config
    "cmd_$verb" "$@"
}

main "$@"
