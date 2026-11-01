#!/usr/bin/env bash
# Integration test: a server prepared somewhere other than /apps, and the
# project commands finding it with nothing to go on but the server itself.
#
# The bug this closes is that `kasbah deploy` and `kasbah env` looked for the
# marker at /apps/.kasbah/server.json and nowhere else, so a server prepared
# with --apps-path read as "never prepared" and exited 4. Neither command has a
# flag for it — the apps path is a property of the *server*, so the server
# carries it: `server init` writes /etc/kasbah/apps-path, and everything reads
# that before falling back to /apps.
#
# What only the rig can show, and what this suite is therefore about:
#   * the pointer written for real: root-owned, mode 644, through sudo;
#   * `deploy` and `env` reaching a tree neither of them was told about;
#   * the refusal that keeps one server to one kasbah, against a server that
#     really is prepared somewhere else;
#   * /apps never coming into existence, which is what makes the discovery the
#     explanation rather than a coincidence.
#
# The prepared tree lives outside /apps, where rig_clean does not reach, so the
# EXIT trap takes it off the rig.
#
# The rig is treated as given: this suite never starts, resets or stops it.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

# Deliberately not under /apps, and deliberately two levels down: the parent
# does not exist either, so init elevates to create it exactly as it would on a
# fresh VPS.
alt_root=/srv/kasbah-unit-e
alt_apps="$alt_root/apps"
alt_data="$alt_apps/data"
alt_marker="$alt_apps/.kasbah/server.json"
pointer=/etc/kasbah/apps-path

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw")

project=demo
project_host=demo.test
project_version=1.0.0

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
projdir="$tmpdir/$project"

# A sudo that prompts, for the section that needs one: a later sudoers file
# whose rule asks for a password wins over the image's NOPASSWD one.
rig_pw='rig-sudo-pw'
sudo_prompts() {
    rig_ssh "printf '%s:%s\n' $RIG_SSH_USER '$rig_pw' | sudo chpasswd &&
             sudo sh -c 'f=/etc/sudoers.d/zz-prompting; printf \"%s ALL=(ALL) ALL\\n\" $RIG_SSH_USER > \$f.new &&
                         chmod 0440 \$f.new && mv -f \$f.new \$f'"
}
# Back to the image's NOPASSWD sudo and a locked password, as root through the
# password: harmless when sudo never prompted.
sudo_restored() {
    rig_ssh "sudo -S -p '' sh -c 'rm -f /etc/sudoers.d/zz-prompting && usermod -p \"!\" $RIG_SSH_USER'" <<<"$rig_pw"
}
cleanup() {
    sudo_restored >/dev/null 2>&1
    # The tree, the pointer and the two compose projects it owns: all of it is
    # outside what rig_clean reaches, or reached by it only on a passing run.
    rig_ssh "docker compose -p $project down -v --remove-orphans; docker compose -p traefik down -v --remove-orphans; sudo rm -rf $alt_root; sudo rm -f $pointer" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
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
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi
rig_ssh "sudo rm -rf $alt_root" >/dev/null 2>&1

# --- Helpers --------------------------------------------------------------------
init()   { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
status() { kasbah_cli server status "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
# Bounded, because the failure mode being guarded against is a prompt nobody can
# answer rather than a wrong answer (tests/integration/rig_env.sh on timeout and
# stdin).
run_bounded() (
    local cmd="$1"; shift
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" "$cmd" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
exists() { rig_ssh "[ -e '$1' ] && echo present || echo absent" 2>/dev/null | tr -d '\r'; }

# --- A server prepared where nothing would look for it ---------------------------
assert '[ "$(exists /apps)" = "absent" ]' \
    "the rig starts with no /apps — else nothing below distinguishes discovery from luck"
assert '[ "$(exists $pointer)" = "absent" ]' "and no pointer"

init --apps-path="$alt_apps" --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init --apps-path=$alt_apps failed on a cleaned rig (exit $rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

pointer_facts=$(rig_ssh "stat -c '%U:%G %a' $pointer; cat $pointer" 2>&1 | tr -d '\r')
assert 'grep -qxF "root:root 644" <<<"$pointer_facts"' \
    "the pointer is root-owned and world-readable (got '$(tr "\n" "|" <<<"$pointer_facts")')"
assert 'grep -qxF "$alt_apps" <<<"$pointer_facts"' \
    "and names the tree the server was prepared at (got '$(tr "\n" "|" <<<"$pointer_facts")')"
assert '[ "$(exists $alt_marker)" = "present" ]' "the marker is under that tree"
assert '[ "$(exists /apps)" = "absent" ]' \
    "and /apps was not created — nothing about this server is at the default path"

# --- The refusal, against a server that really is prepared elsewhere -------------
# One kasbah per server, because one Traefik holds :80 and :443. Without this,
# `kasbah server init rig` — the obvious next thing to type — would render a
# second stack under the frozen `traefik` compose project and recreate the
# running proxy against it.
traefik_id_before=$(rig_ssh "docker inspect -f '{{.Id}}' traefik" 2>/dev/null | tr -d '\r')
assert '[ -n "$traefik_id_before" ]' "Traefik is running before the refusal (got '$traefik_id_before')"
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
traefik_id_after=$(rig_ssh "docker inspect -f '{{.Id}}' traefik" 2>/dev/null | tr -d '\r')
assert '[ "$rc" != "0" ]' "a bare init, which would prepare /apps, is refused (exit $rc)"
assert 'grep -qF "already prepared at $alt_apps" "$tmpdir/err"' \
    "naming where the server is (said '$(cli_err)')"
assert 'grep -qF "would prepare it at /apps" "$tmpdir/err"' \
    "and what this run would have done instead (said '$(cli_err)')"
assert '[ "$(exists /apps)" = "absent" ]'   "and it created nothing"
assert '[ "$traefik_id_after" = "$traefik_id_before" ]' \
    "the running proxy is the same container — the refusal is what that is for (was '$traefik_id_before', now '$traefik_id_after')"

# The idempotent re-run is untouched by the guard: same path, no complaint.
init --apps-path="$alt_apps" --no-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "re-running init at the same apps path still succeeds (exit $rc: $(cli_err))"
assert 'grep -qF "$pointer -> $alt_apps (unchanged)" "$tmpdir/err"' \
    "and leaves the pointer alone (said '$(cli_err)')"

# --- status, with no flag --------------------------------------------------------
status; rc=$?
assert '[ "$rc" = "0" ]' "server status with no --apps-path finds the server (exit $rc: $(cli_err))"
assert 'grep -qF "Root: $alt_apps (pointer)" "$tmpdir/out"' \
    "reading the tree the server's own record names (said '$(cli_out)')"

# --- The project ------------------------------------------------------------------
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$project_version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do. What changes is the server's own marker; nothing here special-cases
# kasbah (plan/roadmap/02-spine.md → Findings).
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    if ! grep -qF "threaded mode" <<<"$limit_probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
        sed 's/^/       | /' <<<"$limit_probe" >&2
        exit 2
    fi
    new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$(rig_ssh "cat $alt_marker" 2>/dev/null)" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $alt_marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
fi

# --- deploy, told nothing but the target ------------------------------------------
# The first run cannot render .env with no terminal at either end, which is exit
# 5 — and the file it names is the evidence: it is under the pointed-at tree,
# which nothing on this side ever mentioned.
run_bounded deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != "124" ]' "deploy against a non-default apps path returns rather than hanging"
assert '[ "$rc" = "5" ]' \
    "and stops at the env step, not at exit 4 — the server was found (exit $rc: $(cli_err))"
assert 'grep -qF "$alt_apps/$project/.env" "$tmpdir/err"' \
    "naming the .env under the tree the pointer names (said '$(cli_err)')"
assert '[ "$(exists $alt_apps/$project/.env.prod.example)" = "present" ]' \
    "and the template it shipped landed there too"
assert '[ "$(exists /apps)" = "absent" ]' "with nothing created at the default path"

# The operator renders .env with the server's own kasbah — this suite playing
# the person at the terminal, as spine_test.sh does.
setup_out=$(rig_setup_env "$alt_apps/$project" </dev/null 2>&1); setup_rc=$?
if [ "$setup_rc" -ne 0 ] || [ "$(exists $alt_apps/$project/.env)" != "present" ]; then
    echo "error: the server's env setup did not render $alt_apps/$project/.env (rc $setup_rc)" >&2
    sed 's/^/       | /' <<<"$setup_out" >&2
    exit 2
fi

run_bounded deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "  FAIL: kasbah deploy succeeds against a server prepared at $alt_apps (exit $rc)" >&2
    sed 's/^/        | /' "$tmpdir/err" >&2
    fail=1
fi

landed=$(rig_ssh "bash -s '$alt_apps' '$alt_data' '$project'" 2>/dev/null <<'REMOTE'
set -uo pipefail
apps=$1
data=$2
name=$3
kv() { printf '%s=%s\n' "$1" "$2"; }
isfile() { if [ -f "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }
# compose.prod.yml is the source name; the sync renames it on arrival.
isfile "$apps/$name/compose.yml" compose
isfile "$apps/$name/versions.log" versions
isfile "$apps/traefik/dynamic/$name.yml" fragment
kv running "$(docker ps --filter label=com.docker.compose.project=$name --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
kv env_limits "$(grep -c '^KASBAH_' "$apps/$name/.env" 2>/dev/null)"
exit 0
REMOTE
)
land() { sed -n "s/^$1=//p" <<<"$landed" | tr -d '\r'; }
assert '[ "$(land compose)" = "yes" ]'  "the project landed under $alt_apps (got '$(land compose)')"
assert '[ "$(land versions)" = "yes" ]' "with a versions.log (got '$(land versions)')"
assert '[ "$(land fragment)" = "yes" ]' "and a Traefik fragment in that tree's dynamic/ (got '$(land fragment)')"
assert '[ "$(land env_limits)" = "2" ]' \
    "injection wrote the two KASBAH_ limits from that tree's marker (got '$(land env_limits)')"
assert 'grep -qF "demo-web" <<<"$(land running)"' \
    "and the container is up (got '$(land running)')"
assert '[ "$(exists /apps)" = "absent" ]' \
    "the whole deploy happened without /apps existing at all"

# The page, through the Traefik that was rendered under the alternative tree.
page=$(rig_ssh "curl -s -m 15 -H 'Host: $project_host' http://127.0.0.1/" 2>/dev/null)
for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -qF "served-by-demo-web-through-the-file-provider" <<<"$page" && break
    sleep 2
    page=$(rig_ssh "curl -s -m 15 -H 'Host: $project_host' http://127.0.0.1/" 2>/dev/null)
done
assert 'grep -qF "served-by-demo-web-through-the-file-provider" <<<"$page"' \
    "and the site is served through the proxy that tree rendered (got '$(head -c 200 <<<"$page")')"

# --- env, told nothing but the target ---------------------------------------------
# The template is removed first, so its reappearance is this command's doing and
# not the deploy's. `kasbah env` runs the interactive generator every time, so
# with no terminal it stops at exit 5 — after it has shipped to the right tree,
# which is what is under test here.
rig_ssh "rm -f $alt_apps/$project/.env.prod.example" >/dev/null 2>&1
assert '[ "$(exists $alt_apps/$project/.env.prod.example)" = "absent" ]' \
    "the template is gone before kasbah env runs — else its presence proves nothing"
run_bounded env "$RIG_TARGET"; rc=$?
assert '[ "$rc" != "124" ]' "kasbah env returns rather than waiting on a prompt"
assert '[ "$rc" = "5" ]' \
    "and stops for the missing terminal, not at exit 4 (exit $rc: $(cli_err))"
assert '[ "$(exists $alt_apps/$project/.env.prod.example)" = "present" ]' \
    "having shipped its template to the tree the pointer names"
assert 'grep -qF "$alt_apps/$project" "$tmpdir/err"' \
    "and its message names that tree (said '$(cli_err)')"
assert '[ "$(exists /apps)" = "absent" ]' "still nothing at the default path"

# --- A pointer that has been lost -------------------------------------------------
# Exit 4 again, and the reason it is the same code is that it is the same server
# state: no marker where the apps path says one should be. Here the server is
# prepared and the record of where is gone, so the message must not read as
# "never prepared" alone, and must not send the reader into a bare init.
rig_ssh "sudo rm -f $pointer" >/dev/null 2>&1
run_bounded deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "4" ]' "with the pointer gone the server is undiscoverable again (exit $rc: $(cli_err))"
assert 'grep -qF "/apps/.kasbah/server.json" "$tmpdir/err"' \
    "naming where it looked (said '$(cli_err)')"
assert 'grep -qF -- "--apps-path=<dir>" "$tmpdir/err"' \
    "and the flag that restores the pointer (said '$(cli_err)')"
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" "$tmpdir/err"' \
    "and never a runnable bare \`server init\`, which would take the running proxy with it (said '$(cli_err)')"

# And init at the path it was prepared at puts it back, which is what the
# message says to do.
init --apps-path="$alt_apps" --no-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "init at the same apps path recovers (exit $rc: $(cli_err))"
assert '[ "$(rig_ssh "cat $pointer" 2>/dev/null | tr -d "\r")" = "$alt_apps" ]' \
    "and the pointer is back"
status; rc=$?
assert '[ "$rc" = "0" ]' "status finds the server again with no flag (exit $rc: $(cli_err))"

# --- No passwordless sudo: the operator runs the printed commands ------------------
# With a sudo that prompts, init and destroy cannot do their root steps; on a
# terminal they print the commands, wait for Enter and check again. The suite
# plays the operator: it waits for the prompt, runs the printed block as root
# through its own password, and presses Enter.

# drive ARGS… — kasbah behind a pty in the background, its keyboard a fifo on
# fd 7 that the suite types into once the run is waiting.
drive_pid=""
drive() {
    rm -f "$tmpdir/tty-in" "$tmpdir/tty-out"
    mkfifo "$tmpdir/tty-in" || return 1
    timeout 600 script -qfec "$(printf '%q ' env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" NO_COLOR=1 \
        "$KASBAH_BIN" "$@")" "$tmpdir/tty-out" <"$tmpdir/tty-in" >/dev/null 2>&1 &
    drive_pid=$!
    exec 7>"$tmpdir/tty-in"
}
# press — Enter on the run's keyboard. A run that is already gone fails the
# press instead of killing the suite with SIGPIPE.
press() {
    kill -0 "$drive_pid" 2>/dev/null || return 1
    ( trap '' PIPE; printf '\n' >&7 ) 2>/dev/null
}
# finish — closes the keyboard; the run's exit status.
finish() { exec 7>&-; wait "$drive_pid"; }
tty_out() { tr -d '\r' <"$tmpdir/tty-out"; }
# waiting N — until the Nth "Press Enter" is on the pty. Bounded, and given up
# as soon as the run is gone: a run that never asks must fail, not hang.
waiting() {
    local i n
    for ((i = 0; i < 480; i++)); do
        n=$(grep -c "Press Enter" "$tmpdir/tty-out" 2>/dev/null)
        [ "${n:-0}" -ge "$1" ] && return 0
        kill -0 "$drive_pid" 2>/dev/null || return 1
        sleep 0.5
    done
    return 1
}
# block — the last printed block's commands, one per line.
block() { tty_out | awk '/^Run on /{b=""; on=1; next} on && /^    /{b=b substr($0,5) "\n"; next} {on=0} END{printf "%s", b}'; }
as_root() { rig_ssh "sudo -S -p '' sh -s" <<<"$rig_pw"$'\n'"$1" >/dev/null 2>&1; }

rig_ssh "docker compose -p $project down -v --remove-orphans; docker compose -p traefik down -v --remove-orphans; sudo rm -rf $alt_root; sudo rm -f $pointer" >/dev/null 2>&1
if ! sudo_prompts >/dev/null 2>&1; then
    echo "  FAIL: could not give $RIG_SSH_USER a prompting sudo on the rig" >&2
    fail=1
fi
assert '! rig_ssh "sudo -n true" >/dev/null 2>&1' "sudo prompts on the rig now"

# Without a terminal: the refusal stands, and names the commands for this state.
init --apps-path="$alt_apps" --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
assert '[ "$rc" = 1 ]' "no sudo and no terminal is a refusal (exit $rc: $(cli_err))"
err_lines=$(sed 's/^ *//' "$tmpdir/err")
for want in "sudo mkdir -p $alt_root" "sudo mkdir $alt_apps" "sudo chown $RIG_SSH_USER:$RIG_SSH_USER $alt_apps"; do
    assert 'grep -qxF "$want" <<<"$err_lines"' "naming \`$want\` (said '$(cli_err)')"
done
assert '[ "$(exists $alt_root)" = absent ]' "and creating nothing"

# On a terminal: init waits twice — for the apps path, then for the pointer.
drive server init "$RIG_TARGET" --apps-path="$alt_apps" --no-mail --no-backup "${traefik_flags[@]}"
if waiting 1; then
    apps_block=$(block)
    assert '[ "$apps_block" = "sudo mkdir -p $alt_root
sudo mkdir $alt_apps
sudo chown $RIG_SSH_USER:$RIG_SSH_USER $alt_apps" ]' "init prints the apps path's commands (got '$apps_block')"
    as_root "$apps_block"
    press || assert false "the run was gone before Enter: $(tty_out)"
    if waiting 2; then
        pointer_block=$(block)
        assert 'grep -qxF "printf '"'"'%s\\n'"'"' $alt_apps | sudo tee $pointer >/dev/null" <<<"$pointer_block"' \
            "then the pointer's (got '$pointer_block')"
        assert '! grep -qF "chmod 755" <<<"$pointer_block"' \
            "only the steps this server needs: /etc/kasbah is already 755 (got '$pointer_block')"
        as_root "$pointer_block"
    else
        assert false "init never asked for the pointer: $(tty_out)"
    fi
    press || assert false "the run was gone before Enter: $(tty_out)"
else
    assert false "init never asked for the apps path: $(tty_out)"
fi
finish; rc=$?
assert '[ "$rc" = 0 ]' "init finishes once the commands have run (exit $rc: $(tty_out))"
assert 'grep -qF "created $alt_apps by hand, owner $RIG_SSH_USER:$RIG_SSH_USER" <<<"$(tty_out)"' "and says who created the apps path"
assert 'grep -qF "pointer: $pointer -> $alt_apps (written by hand)" <<<"$(tty_out)"' "and the pointer"
pointer_facts=$(rig_ssh "stat -c '%U:%G %a' $pointer; cat $pointer" 2>&1 | tr -d '\r')
assert '[ "$pointer_facts" = "root:root 644
$alt_apps" ]' "the hand-written pointer is the one init writes (got '$pointer_facts')"
assert '[ "$(exists $alt_marker)" = present ]' "and the marker is in place"

# destroy: the pointer is left to the operator, re-checked until it is gone.
drive server destroy "$RIG_TARGET" --yes
if waiting 1; then
    destroy_block=$(block)
    assert '[ "$destroy_block" = "sudo rm -f $pointer
sudo rmdir ${pointer%/*}" ]' "destroy prints the pointer's removal (got '$destroy_block')"
    press || assert false "the run was gone before Enter: $(tty_out)"
    if waiting 2; then
        assert 'grep -qF "still needs root" <<<"$(tty_out)"' "Enter with nothing done asks again"
        as_root "$destroy_block"
    else
        assert false "destroy did not ask again: $(tty_out)"
    fi
    press || assert false "the run was gone before Enter: $(tty_out)"
else
    assert false "destroy never asked: $(tty_out)"
fi
finish; rc=$?
assert '[ "$rc" = 0 ]' "destroy finishes once the pointer is gone (exit $rc: $(tty_out))"
assert 'grep -qF "$pointer and ${pointer%/*}/ were removed by hand" <<<"$(tty_out)"' "and says so"
assert '! grep -qF "still there and names" <<<"$(tty_out)"' "with no warning that the pointer is still there"
assert '[ "$(exists $pointer)" = absent ]' "the pointer is gone"
sudo_restored >/dev/null 2>&1
assert 'rig_ssh "sudo -n true" >/dev/null 2>&1' "passwordless sudo is back on the rig"

# --- Leave the rig as it was found, but only on success ----------------------------
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker compose -p $project down -v --remove-orphans; docker compose -p traefik down -v --remove-orphans" >/dev/null 2>&1
    rig_ssh "sudo rm -rf $alt_root" >/dev/null 2>&1
    assert '[ "$(exists $alt_root)" = "absent" ]' "the prepared tree was removed from the rig"
    rig_clean || fail=1
fi

exit "$fail"
