#!/usr/bin/env bash
# Test: `kasbah server init` and `kasbah server backup-prune` through the CLI,
# with no server: every question is asked, and every value refused, before
# anything is opened. The code is internal/serverinit and internal/backup,
# whose own cases are Go tests; the rig-driven halves live in
# tests/integration/server_init_test.sh and tests/integration/backup_test.sh.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export NO_COLOR=1

# --- The command line, through the CLI ---------------------------------------
# A recording ssh goes first on PATH, and every case below asserts its log is
# empty. That is what makes "the question is asked before anything is opened" an
# assertion rather than a hope: without the stub these runs reach the real ssh,
# spend a DNS lookup on a .invalid name, and fail for that instead — so a guard
# that had stopped working would still exit non-zero and the case would still
# pass. tests/deploy_test.sh does it this way for the same reason.
si_stub_dir="$tmpdir/stubbin"
mkdir -p "$si_stub_dir"
si_ssh_log="$tmpdir/ssh.log"
: > "$si_ssh_log"
cat > "$si_stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
echo "stub ssh: this suite reaches no network" >&2
exit 255
STUB
chmod 0755 "$si_stub_dir/ssh"

run() {
    : > "$si_ssh_log"
    env -u KASBAH_LIB_DIR \
        PATH="$si_stub_dir:$PATH" SSH_LOG="$si_ssh_log" \
        "$kasbah" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}

assert '[ "$(PATH="$si_stub_dir:$PATH" command -v ssh)" = "$si_stub_dir/ssh" ]' \
    "the stub ssh shadows any real one for the cases below"

run server; rc=$?
assert '[ "$rc" != "0" ]' "bare \`kasbah server\` fails (exit $rc)"
assert 'grep -qF "expected: init" "$tmpdir/err"' \
    "it names the subcommands that exist (said '$(cat "$tmpdir/err")')"

run server --help; rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah server --help\` is help, not an unknown subcommand (exit $rc: $(cat "$tmpdir/err"))"
assert 'grep -qF "init USER@HOST" "$tmpdir/out"' "it lists the subcommands (got '$(cat "$tmpdir/out")')"
run server -h; rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah server -h\` too (exit $rc)"

run server statsu; rc=$?
assert '[ "$rc" != "0" ]' "an unknown server subcommand fails (exit $rc)"
assert 'grep -qF "unknown subcommand '\''statsu'\''" "$tmpdir/err"' \
    "it names what was typed (said '$(cat "$tmpdir/err")')"

run --help
assert 'grep -qF "server init" "$tmpdir/out"' "usage advertises server init"

# Mail is built now, so --with-mail is no longer a refusal: it goes on to the
# server like any other answered run. What is checked here is that it *reaches*
# the transport rather than stopping at a leftover guard, and that it does not
# ask for the postmaster password before it knows whether the server already has
# an account — that question is settled from the server, not from the flag.
run server init deploy@kasbah-unit-test.invalid --with-mail --no-backup; rc=$?
assert '[ "$rc" = "3" ]' \
    "--with-mail goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '! grep -qF "not implemented" "$tmpdir/err"' \
    "and no longer refuses (said '$(cat "$tmpdir/err")')"
assert '[ -s "$si_ssh_log" ]' "the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"
assert '! grep -qF "postmaster" "$tmpdir/err"' \
    "and it did not ask for a postmaster password before reading the server (said '$(cat "$tmpdir/err")')"

# Backup no longer refuses: --with-backup goes on to the server exactly as
# --with-mail does, because what it has to ask — which repositories this server
# needs a password for — is a fact about the server. The unreachable host is
# what proves it got that far.
run server init deploy@kasbah-unit-test.invalid --no-mail --with-backup \
    --backup-repo-base=rest:http://example.invalid/ --no-backup-env; rc=$?
assert '[ "$rc" = "3" ]' \
    "--with-backup goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '! grep -qF "not implemented" "$tmpdir/err"' \
    "and no longer refuses (said '$(cat "$tmpdir/err")')"
assert '[ -s "$si_ssh_log" ]' "the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"

# The tri-state rule: no flag and no terminal is a hard fail naming the flag,
# never an assumed "no". Nothing is contacted first — and that half matters as
# much as the exit code, because a guard that stopped guarding would still fail
# the run, just further along and against somebody's server.
run server init deploy@kasbah-unit-test.invalid; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable mail question fails (exit $rc)"
assert 'grep -qF -- "--with-mail or --no-mail" "$tmpdir/err"' \
    "the no-TTY failure names both flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

run server init deploy@kasbah-unit-test.invalid --no-mail; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable backup question fails (exit $rc)"
assert 'grep -qF -- "--with-backup or --no-backup" "$tmpdir/err"' \
    "the no-TTY failure names the backup flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

# The positive control: with both questions answered the command does reach the
# transport, so the four empty logs above are about the guards and not about a
# stub that was never on PATH.
run server init deploy@kasbah-unit-test.invalid --no-mail --no-backup; rc=$?
assert '[ "$rc" = "3" ]' "an answered init goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '[ -s "$si_ssh_log" ]' "and the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"

# A target carrying a Windows line ending is the same target. ssh_target_parse
# strips it too, but only once a connection is being made: everything this
# command prints first — the two questions among them — reads _SI_TARGET
# directly, and a carriage return in the middle of a prompt overwrites the line
# the operator is being asked to answer.
run server init "$(printf 'deploy@kasbah-unit-test.invalid\r')"
assert '! grep -qU $'"'"'\r'"'"' "$tmpdir/err"' \
    "a CRLF target carries no carriage return into the prompt (said '$(cat -v "$tmpdir/err")')"
assert 'grep -qF "on deploy@kasbah-unit-test.invalid?" "$tmpdir/err"' \
    "and the question names the target it would act on (said '$(cat "$tmpdir/err")')"

# --- The help texts ------------------------------------------------------------
run server init --help; rc=$?
assert '[ "$rc" = "0" ]' "server init --help exits 0 (exit $rc)"
assert 'grep -qF "retention, applied by \"server backup-prune\"" "$tmpdir/out"' \
    "the help names what applies the retention (got '$(cat "$tmpdir/out")')"
assert 'grep -qF "one repository per \"client:\" plus one" "$tmpdir/out"' "and what a repository is"
assert '[ ! -s "$si_ssh_log" ]' "help opens nothing"
run server backup-prune --help; rc=$?
assert '[ "$rc" = "0" ]' "server backup-prune --help exits 0 (exit $rc)"
assert 'grep -qF -- "--docker-network=<net>" "$tmpdir/out"' "and lists its flags"

# --- Backup values are refused before a connection, never echoed -----------------
run server init deploy@kasbah-unit-test.invalid --no-mail --with-backup --backup-password=s3cr3t-do-not-print; rc=$?
assert '[ "$rc" = "1" ]' "a --backup-password= without a repository fails (exit $rc)"
assert '! grep -qF "s3cr3t" "$tmpdir/err"' "without quoting the password (said '$(cat "$tmpdir/err")')"
run server init deploy@kasbah-unit-test.invalid --no-mail --with-backup --backup-env=RESTIC_REPOSITORY=s3cr3t-do-not-print; rc=$?
assert 'grep -qF "kasbah owns" "$tmpdir/err" && ! grep -qF "s3cr3t" "$tmpdir/err"' \
    "an owned --backup-env key is refused by name only (said '$(cat "$tmpdir/err")')"
run server init deploy@kasbah-unit-test.invalid --no-mail --with-backup --backup-keep-daily=lots; rc=$?
assert 'grep -qF "server init: --backup-keep-daily=lots" "$tmpdir/err"' \
    "a check names the command and the flag it was given (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' "and none of them opened anything (ssh saw: $(cat "$si_ssh_log"))"
run server init deploy@kasbah-unit-test.invalid --no-mail --no-backup --backup-at=03:00 --no-backup-env; rc=$?
assert 'grep -qF -- "--backup-at= --no-backup-env had no effect: this run is not installing backups" "$tmpdir/err"' \
    "backup flags on a run without backups are named (said '$(cat "$tmpdir/err")')"

run server backup-prune; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "USER@HOST is required" "$tmpdir/err"' "backup-prune wants a target (exit $rc: $(cat "$tmpdir/err"))"
run server backup-prune deploy@kasbah-unit-test.invalid --envy=s3cr3t-do-not-print; rc=$?
assert 'grep -qF "unknown flag '\''--envy'\''" "$tmpdir/err" && ! grep -qF "s3cr3t" "$tmpdir/err"' \
    "an unknown flag is named, its value not (said '$(cat "$tmpdir/err")')"
run server backup-prune deploy@kasbah-unit-test.invalid --repo-base=rest:http://u:s3cr3t-do-not-print@h/b; rc=$?
assert 'grep -qF "must end in" "$tmpdir/err" && grep -qF "u:***@h" "$tmpdir/err" && ! grep -qF "s3cr3t" "$tmpdir/err"' \
    "a credential-bearing base is refused, redacted (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' "and nothing was opened (ssh saw: $(cat "$si_ssh_log"))"
run server backup-prune deploy@kasbah-unit-test.invalid --no-env --dry-run; rc=$?
assert '[ "$rc" = "3" ] && [ -s "$si_ssh_log" ]' "a parsed backup-prune goes on to the server (exit $rc: $(cat "$tmpdir/err"))"

exit "$fail"
