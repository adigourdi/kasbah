#!/usr/bin/env bash
# Integration: `kasbah env` against the rig — the Go command on the workstation,
# `kasbah remote setup-env` in the server binary it ships, the interactive setup
# over a real `ssh -t`, the managed block, the .env's mode, last_server, a
# Ctrl-C at a server prompt, and `kasbah env set` changing one key.
#
# The interactive runs sit behind script(1), which gives kasbah a terminal; its
# answers are typed ahead, which a pty buffers until something reads them.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
marker="$apps/.kasbah/server.json"
project=demo
pdir="$apps/$project"
traefik_flags=(--domain=rig.test --email=ops@rig.test --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
holder=""
cleanup() {
    [ -z "$holder" ] || kill "$holder" 2>/dev/null
    rig_ssh "cd $pdir 2>/dev/null && docker compose -p $project down >/dev/null 2>&1" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if ! command -v script >/dev/null 2>&1; then
    echo "error: script(1) is required to give kasbah a terminal" >&2
    exit 2
fi
if [ ! -f "$RIG_SSH_CONFIG" ] || ! rig_reachable; then
    echo "error: the rig did not answer ssh — is it up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir" || ! rig_clean; then
    echo "error: could not prepare the scratch HOME or clean the rig" >&2
    exit 2
fi
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup "${traefik_flags[@]}" \
        >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig:" >&2
    cat "$tmpdir/init.err" >&2
    exit 2
fi
marker_json=$(rig_ssh "cat $marker" 2>/dev/null | tr -d '\r')
cpu=$(jq -r .cpu_limit <<<"$marker_json")
mem=$(jq -r .mem_limit <<<"$marker_json")

proj="$tmpdir/$project"
cp -R "$repo_dir/tests/fixtures/$project" "$proj" || exit 2
cat > "$proj/.env.prod.example" <<'TMPL'
# --- App ---
APP_NAME=demo
APP_PORT=8080 # the port
DB_PASSWORD=! echo generated-pw
API_SECRET=
MAIL_HOST=# smtp host
export EXPORTED=x
KASBAH_CPU_LIMIT=9
TMPL

nocr() { tr -d '\r'; }
remote() { rig_ssh "$1" 2>/dev/null | nocr; }
# True only when ssh worked and the command printed nothing.
remote_empty() { local out; out=$(remote "$1") || return 1; [ -z "$out" ]; }
no_staging() { remote_empty "ls -A $pdir | grep -F .kasbah- || true"; }
block="# >>> kasbah managed block - do not edit, rewritten on every deploy >>>
KASBAH_CPU_LIMIT=$cpu
KASBAH_MEM_LIMIT=$mem
# <<< kasbah managed block <<<"
last_server() { jq -r '.last_server // ""' "$proj/.kasbah/state.json" 2>/dev/null; }

headless() {
    (cd "$proj" && timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
        "$KASBAH_BIN" env "$@") >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}
err() { nocr <"$tmpdir/err"; }

# tty INPUT ARGS… — the command behind a pty, INPUT typed ahead.
tty_rc=0
tty_out=""
tty() {
    local input="$1"; shift
    printf '%s' "$input" >"$tmpdir/tty-in"
    timeout 120 script -qfec "cd $(printf '%q' "$proj") && $(printf '%q ' env HOME="$RIG_HOME" \
        PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 "$KASBAH_BIN" env "$@")" "$tmpdir/tty-out" \
        <"$tmpdir/tty-in" >/dev/null 2>&1
    tty_rc=$?
    tty_out=$(grep -v '^Script \(started\|done\) on ' "$tmpdir/tty-out" | nocr)
}

# --- Case 1: headless, no .env: exit 5, and nothing but the template --------------
headless "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 5 ]' "a first env with no terminal is exit 5 (rc $rc: $(err))"
assert 'grep -qF ".env does not exist yet" <<<"$(err)"' "naming why (said '$(err)')"
assert '[ "$(remote "[ -x $apps/.kasbah/bin/kasbah ] && echo yes")" = yes ]' "the server binary was shipped"
assert '[ "$(remote "cat $pdir/.env.prod.example" | head -1)" = "# --- App ---" ]' "the template was shipped"
assert '[ "$(remote "ls -A $pdir")" = ".env.prod.example" ]' \
    "and nothing else: no .env, no scripts/setup-env.sh (got '$(remote "ls -A $pdir")')"
assert '[ -z "$(last_server)" ]' "a failed run records no last_server"

# --- Case 2: on a terminal, the setup runs over ssh -t ----------------------------
# APP_NAME Enter, APP_PORT typed, DB_PASSWORD generated, API_SECRET typed
# (masked), MAIL_HOST typed, EXPORTED Enter.
tty $'\n9090\n\ns3cr3t-typed\nsmtp.test\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ]' "env on a terminal exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qF "→ generated" <<<"$tty_out"' "the generator ran on the server (said '$tty_out')"
want="# --- App ---
APP_NAME=demo
APP_PORT=9090
DB_PASSWORD=generated-pw
API_SECRET=s3cr3t-typed
MAIL_HOST=smtp.test
EXPORTED=x
$block"
got=$(remote "cat $pdir/.env")
assert '[ "$got" = "$want" ]' "the .env is the template answered, export dropped, block last
        got: $got"
assert '[ "$(remote "stat -c %a:%G $pdir/.env")" = 660:kasbah ]' "a .env kasbah creates is 660, the kasbah group's (got $(remote "stat -c %a:%G $pdir/.env"))"
assert '[ "$(last_server)" = "$RIG_TARGET" ]' "a run that worked records last_server"
assert 'no_staging' "no staging file left"

# --- Case 3: in sync: declined, then reconfigured — a 600 .env converges to 660 ----
remote "chmod 600 $pdir/.env" >/dev/null
tty 'n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF "up to date" <<<"$tty_out"' "declining the reconfigure exits 0 (rc $tty_rc: $tty_out)"
tty $'y\n\n\n\n\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF ".env written to" <<<"$tty_out"' "reconfiguring rewrites it (rc $tty_rc: $tty_out)"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "every live value kept through Enter"
assert '[ "$(remote "stat -c %a $pdir/.env")" = 660 ]' "an existing 600 .env is given the group's read and write by the setup"
assert 'no_staging' "no staging file left"

# An existing .env the deploy user cannot read is never taken for a first run.
# Its keys read as missing, so the drift prompt comes first.
remote "chmod 200 $pdir/.env" >/dev/null
tty $'setup\n\n\n\n\n\n\n' "$RIG_TARGET"
remote "chmod 640 $pdir/.env" >/dev/null
assert '[ "$tty_rc" = 5 ] && grep -qF "cannot read" <<<"$tty_out"' "an unreadable .env stops the setup (rc $tty_rc: $tty_out)"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "and leaves it as it was"

# --- Case 4: drift, headless ---------------------------------------------------------
printf 'NEW_KEY=nk\n' >> "$proj/.env.prod.example"
headless "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 5 ] && grep -qF -- "--on-drift=continue" <<<"$(err)"' "drift with no terminal names the flag (rc $rc: $(err))"
headless "$RIG_TARGET" --on-drift=abort; rc=$?
assert '[ "$rc" = 5 ]' "--on-drift=abort is exit 5 (rc $rc)"
remote "sed -i 's/^KASBAH_CPU_LIMIT=.*/KASBAH_CPU_LIMIT=stale/' $pdir/.env" >/dev/null
headless "$RIG_TARGET" --on-drift=continue; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "has drifted" <<<"$(err)"' "--on-drift=continue goes through (rc $rc: $(err))"
assert '[ "$(remote "cat $pdir/.env")" = "$want" ]' "leaving .env as it stood, the block refreshed"

# --- Case 5: drift, on a terminal: setup, then the new key only ---------------------
tty $'setup\n\n\n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ]' "answering setup exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qF "setup/continue/abort" <<<"$tty_out" && grep -qF "1 new" <<<"$tty_out"' "asked, then the menu (said '$tty_out')"
assert 'grep -qx "NEW_KEY=nk" <<<"$(remote "cat $pdir/.env")"' "the new key is in .env"
assert 'grep -qx "API_SECRET=s3cr3t-typed" <<<"$(remote "cat $pdir/.env")"' "the live values kept"

# --- Case 6: Ctrl-C at a server prompt ------------------------------------------------
# Typed through the pty, as an operator would: ssh carries it to the server's
# terminal, the server binary restores it and exits 130, and the run is exit 5.
before=$(remote "cat $pdir/.env")
mkfifo "$tmpdir/fifo"
sleep 300 >"$tmpdir/fifo" &
holder=$!
(cd "$proj" && timeout 120 script -qfec "$(printf '%q ' env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    NO_COLOR=1 "$KASBAH_BIN" env "$RIG_TARGET")" "$tmpdir/int-out" <"$tmpdir/fifo" >/dev/null 2>&1; \
    echo $? >"$tmpdir/int-rc") &
runner=$!
exec 3>"$tmpdir/fifo"
waiting=""
for _ in $(seq 1 40); do
    if [ -n "$(remote "pgrep -f 'remote setup-env [s]etup' || true")" ]; then waiting=yes; break; fi
    sleep 0.5
done
assert '[ "$waiting" = yes ]' "the server's setup started"
sleep 1
printf '\003' >&3
exec 3>&-
wait "$runner"
kill "$holder" 2>/dev/null; holder=""
int_rc=$(cat "$tmpdir/int-rc" 2>/dev/null)
assert '[ "$int_rc" = 5 ]' "Ctrl-C at the server's prompt ends the run with 5 (rc $int_rc: $(nocr <"$tmpdir/int-out"))"
assert 'remote_empty "pgrep -f '"'remote [s]etup-env'"' || true"' "nothing left running on the server"
assert '[ "$(remote "cat $pdir/.env")" = "$before" ]' "the .env untouched"
assert 'no_staging' "no staging file left"

# --- Case 7: env set — one key, the value on stdin, never printed ------------------
# set_env INPUT ARGS… — `kasbah env set ARGS…` with INPUT on stdin, no terminal.
set_env() {
    local input="$1"; shift
    (cd "$proj" && printf '%s' "$input" | timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
        NO_COLOR=1 "$KASBAH_BIN" env set "$@") >"$tmpdir/out" 2>"$tmpdir/err"
}
said() { nocr <"$tmpdir/out"; nocr <"$tmpdir/err"; }
before=$(remote "cat $pdir/.env")

set_env $'rotated-pw\n' API_SECRET "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ] && grep -qF -- "--restart" <<<"$(err)" && grep -qF -- "--no-restart" <<<"$(err)"' \
    "no terminal and no restart flag is refused naming both (rc $rc: $(err))"
assert '[ "$(remote "cat $pdir/.env")" = "$before" ]' "and changes nothing"

set_env $'rotated-pw\n' NOPE "$RIG_TARGET" --no-restart; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "not a key of $pdir/.env.prod.example" <<<"$(err)"' \
    "a key the server's template lacks is refused naming it (rc $rc: $(err))"
set_env $'9\n' KASBAH_CPU_LIMIT "$RIG_TARGET" --no-restart; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "kasbah'"'"'s own" <<<"$(err)"' "a KASBAH_ key is refused (rc $rc: $(err))"
assert '[ "$(remote "cat $pdir/.env")" = "$before" ]' "neither refusal changed .env"

set_env $'rotated-pw\n' API_SECRET "$RIG_TARGET" --no-restart; rc=$?
after=$(remote "cat $pdir/.env")
changed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]')
assert '[ "$rc" = 0 ]' "env set from stdin exits 0 (rc $rc: $(err))"
assert '[ "$changed" = "< API_SECRET=s3cr3t-typed
> API_SECRET=rotated-pw" ]' "exactly the one line changed (diff: $changed)"
assert 'grep -qF "API_SECRET changed" <<<"$(said)"' "the output names the key (said '$(said)')"
assert '! grep -qF "rotated-pw" <<<"$(said)"' "and never the value"
assert '[ "$(remote "stat -c %a $pdir/.env")" = 660 ]' "the .env keeps the group's mode"
assert 'no_staging' "no staging file left"

# --restart recreates the container with the new value.
remote "cat > $pdir/compose.yml" >/dev/null <<'YML'
services:
  envset:
    image: nginx:alpine
    container_name: demo-envset
    environment:
      API_SECRET: ${API_SECRET}
YML
remote "cd $pdir && docker compose -p $project up -d >/dev/null 2>&1" >/dev/null
old_id=$(remote "docker inspect -f '{{.Id}}' demo-envset")
assert '[ "$(remote "docker exec demo-envset printenv API_SECRET")" = rotated-pw ]' "the container runs the set value"
set_env 'restarted-pw' API_SECRET "$RIG_TARGET" --restart; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "restarted" <<<"$(said)"' "env set --restart exits 0 (rc $rc: $(said))"
assert '[ "$(remote "docker exec demo-envset printenv API_SECRET")" = restarted-pw ]' "the recreated container has the new value"
assert '[ "$(remote "docker inspect -f '"'{{.Id}}'"' demo-envset")" != "$old_id" ]' "the container was recreated"
assert '! grep -qF "restarted-pw" <<<"$(said)"' "the value never printed"
assert '! grep -qF "env set" <<<"$(remote "cat $pdir/versions.log 2>/dev/null")"' "no versions.log line"

# A value compose would cut or choke on unquoted reaches the container intact.
nasty="  pa\$\$ss #frag 'q\"\\"
set_env "$nasty" API_SECRET "$RIG_TARGET" --restart; rc=$?
assert '[ "$rc" = 0 ]' "env set of a value that needs quoting exits 0 (rc $rc: $(said))"
assert '[ "$(remote "docker exec demo-envset printenv API_SECRET")" = "$nasty" ]' \
    "compose reads it back exactly (got [$(remote "docker exec demo-envset printenv API_SECRET")])"

# A run holding .deploy.lock refuses the set. The holder prints its pid once it
# has the lock, and a bounded read waits for that line.
mkfifo "$tmpdir/lockfifo"
rig_ssh "flock -n $pdir/.deploy.lock sh -c 'echo \$\$; exec sleep 60'" >"$tmpdir/lockfifo" 2>/dev/null </dev/null &
holder=$!
lock_pid=""
read -r -t 30 lock_pid <"$tmpdir/lockfifo"
lock_pid=${lock_pid%$'\r'}
assert '[ -n "$lock_pid" ]' "the lock holder started"
set_env 'locked-pw' API_SECRET "$RIG_TARGET" --no-restart; rc=$?
assert '[ "$rc" = 1 ] && grep -qF ".deploy.lock" <<<"$(err)"' "a held .deploy.lock refuses the set (rc $rc: $(err))"
assert '! grep -qx "API_SECRET=locked-pw" <<<"$(remote "cat $pdir/.env")"' "and leaves .env alone"
[ -z "$lock_pid" ] || remote "kill $lock_pid" >/dev/null
wait "$holder" 2>/dev/null
holder=""

# On a terminal the value is asked hidden, then the restart question.
tty $'tty-pw\nn\n' set API_SECRET "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF "Restart $project" <<<"$tty_out"' "env set on a terminal asks and exits 0 (rc $tty_rc: $tty_out)"
assert 'grep -qx "API_SECRET=tty-pw" <<<"$(remote "cat $pdir/.env")"' "the typed value is written"


# --- Case 8: resources: in kasbah.yml — a share of the host, resolved on it -------
# The server binary reads its own nproc and MemTotal; the suite reads them over
# ssh and spells 50% the way the marker spells 90%.
cores=$(remote "nproc")
kb=$(remote "cat /proc/meminfo" | sed -n 's/^MemTotal: *\([0-9]*\) kB$/\1/p')
share() { # PCT → the cpus and memory a share of this host resolves to
    local t=$((cores * $1 / 10)) g=$((kb * $1 / 104857600))
    [ "$t" -ge 1 ] || t=1
    share_cpu="$((t / 10)).$((t % 10))"
    if [ "$g" -ge 1 ]; then share_mem="${g}g"; else share_mem="$((kb * $1 / 102400))m"; fi
}
share 50
cp "$proj/kasbah.yml" "$tmpdir/kasbah.yml.before"
printf '\nresources:\n  cpus: 50%%\n  memory: 50%%\n' >> "$proj/kasbah.yml"
tty 'n' "$RIG_TARGET"
assert '[ "$tty_rc" = 0 ] && grep -qF "KASBAH_CPU_LIMIT=$share_cpu KASBAH_MEM_LIMIT=$share_mem (from kasbah.yml resources)" <<<"$tty_out"' \
    "env resolves 50% of $cores cores / $kb kB on the server (rc $tty_rc: $tty_out)"
got=$(remote "cat $pdir/.env")
assert 'grep -qxF "KASBAH_CPU_LIMIT=$share_cpu" <<<"$got" && grep -qxF "KASBAH_MEM_LIMIT=$share_mem" <<<"$got"' \
    "the managed block carries the resolved values (got: $got)"
tty 'n' "$RIG_TARGET"
assert '[ "$(remote "cat $pdir/.env")" = "$got" ]' "a re-run leaves the .env byte for byte"

# Two neighbours at the same share: three projects below the ceiling that add
# up to 150% of the host, which check --server sums.
for other in shop blog; do
    remote "mkdir -p $apps/$other && printf '%s\\n' 'SECRET=x' '# >>> kasbah managed block - do not edit, rewritten on every deploy >>>' 'KASBAH_CPU_LIMIT=$share_cpu' 'KASBAH_MEM_LIMIT=$share_mem' '# <<< kasbah managed block <<<' > $apps/$other/.env" >/dev/null
done
(cd "$proj" && timeout 120 env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
    "$KASBAH_BIN" check --server "$RIG_TARGET") >"$tmpdir/out" 2>&1 </dev/null
said_check=$(nocr <"$tmpdir/out")
assert 'grep -qF "⚠ the projects on $RIG_TARGET with their own cpus limit add up to" <<<"$said_check" && grep -qF "⚠ the projects on $RIG_TARGET with their own memory limit add up to" <<<"$said_check"' \
    "check --server warns that the shares add up past the host (said '$said_check')"
assert 'grep -qF "blog $share_cpu, $project $share_cpu, shop $share_cpu" <<<"$said_check"' "naming each project once (said '$said_check')"
assert 'grep -qF "set by kasbah.yml'"'"'s resources:" <<<"$said_check" && ! grep -qF "are below the host" <<<"$said_check"' \
    "and R04 does not warn on a limit kasbah.yml asked for (said '$said_check')"
remote "rm -rf $apps/shop $apps/blog" >/dev/null

# Over the ceiling: refused before anything is written.
cp "$tmpdir/kasbah.yml.before" "$proj/kasbah.yml"
printf '\nresources:\n  memory: 95%%\n' >> "$proj/kasbah.yml"
headless "$RIG_TARGET"; rc=$?
assert '[ "$rc" = 1 ] && grep -qF "resources.memory '"'"'95%'"'"' comes to" <<<"$(err)" && grep -qF "ceiling of $mem" <<<"$(err)"' \
    "a share above the 90% ceiling is refused naming the field and the ceiling (rc $rc: $(err))"
assert '[ "$(remote "cat $pdir/.env")" = "$got" ]' "and the .env is untouched"
cp "$tmpdir/kasbah.yml.before" "$proj/kasbah.yml"

exit "$fail"
