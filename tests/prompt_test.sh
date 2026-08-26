#!/usr/bin/env bash
# Test: lib/prompt.sh — the tri-state rule (flag wins, else prompt, else fail).
#
# All three branches are exercised for real, including the terminal one:
# `script -qec … /dev/null` puts the driver behind a pty, so `[ -t 0 ]` is
# genuinely true and the answer genuinely comes from a terminal. Faking that
# with a pipe would test the no-TTY branch twice and leave the interactive path
# — the one a user meets — unproven.

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

export KASBAH_LIB_DIR="$repo_dir/lib"
# Colour is decided by [ -t 2 ], which is true behind the pty; the escapes
# would then break every substring match below.
export NO_COLOR=1

# --- Driver -------------------------------------------------------------------
# A stand-in for a command that has parsed its flags: it hands the tri-state
# over and reports what came back. Answers land on stdout as key=value;
# everything the functions say belongs on stderr, which is asserted separately.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prompt.sh"

case "$1" in
    bool)
        if prompt_bool "$2" "$3" "${4:-}"; then echo "answer=yes"; else echo "answer=no"; fi ;;
    value)
        prompt_value "$2" "$3" "${4:-}" ANSWER "${5:-}"; echo "answer=$ANSWER" ;;
    secret)
        prompt_secret "$2" "$3" "${4:-}" ANSWER; echo "answer=$ANSWER" ;;
    secret-quiet)
        # Reports only the length, so the terminal transcript can be searched
        # for the secret itself and be expected to come up empty.
        prompt_secret "$2" "$3" "${4:-}" ANSWER; echo "answer_len=${#ANSWER}" ;;
    value-substituted)
        # The misuse the API has to make harmless: the answer is written into a
        # variable, so a caller who wraps the call in $(…) captures nothing at
        # all rather than something that looks like an answer.
        captured=$(prompt_value "$2" "$3" "${4:-}" ANSWER "${5:-}")
        echo "captured=[$captured]"
        echo "answer=${ANSWER:-<unset>}" ;;
    choice)
        if prompt_choice "$2" "$3" "$4" "${5:-}"; then echo "answer=yes"; else echo "answer=no"; fi ;;
    confirm)
        if prompt_confirm "$2" "$3" "${4:-}"; then echo "answer=yes"; else echo "answer=no"; fi ;;
    typed)
        if prompt_typed "$2" "$3" "$4" "${5:-}"; then echo "answer=match"; else echo "answer=mismatch"; fi ;;
    bad-given-typed)
        prompt_typed yes demo "Name?" no ;;
    bad-expected-typed)
        prompt_typed yes "" "Name?" ;;
    bad-outvar)
        prompt_value domain "Domain?" "" 'ANSWER; rm -rf /' ;;
    bad-given)
        prompt_bool mail "Mail?" maybe ;;
    bad-given-confirm)
        prompt_confirm yes "Reset?" no ;;
    bad-given-choice)
        prompt_choice reset-acme keep-acme "Reset?" maybe ;;
esac
DRV
chmod 0755 "$driver"

# Runs the driver with a real terminal on stdin, feeding it $1. script(1) merges
# the session's stdout and stderr into one stream (that is what a terminal is),
# and turns every \n into \r\n — hence the \r strip, the same tolerance the
# manifest reader applies to user-authored files.
#
# tty_input_delay holds the input back until the driver is certainly inside its
# read. Terminal echo is the pty's doing, not the program's, so input written
# before the program disables echo is echoed anyway — without the delay, "the
# secret was not echoed" would be a race that passes for the wrong reason.
tty_input_delay=0
run_tty() {
    local input="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$driver" "$@")"
    tty_out=$({ [ "$tty_input_delay" = 0 ] || sleep "$tty_input_delay"
                printf '%s' "$input"; } | script -qec "$cmd" /dev/null 2>&1)
    tty_rc=$?
    tty_out=${tty_out//$'\r'/}
}

# No terminal anywhere: stdin is closed outright, so a function that reaches for
# an answer fails rather than blocking. Sets rc, out (stdout), err (stderr).
run_closed() {
    out=$("$driver" "$@" 2>"$tmpdir/err" <&-)
    rc=$?
    err=$(<"$tmpdir/err")
}

# --- Case 1: an explicit flag answers, with no terminal in sight ---------------
run_closed bool mail "Enable mail?" yes
assert '[ "$rc" = "0" ]'            "--with-mail answers without a terminal (exit $rc)"
assert '[ "$out" = "answer=yes" ]'  "a yes flag yields yes (got '$out')"
assert '[ -z "$err" ]'              "answering from a flag says nothing (got '$err')"

run_closed bool mail "Enable mail?" no
assert '[ "$rc" = "0" ]'            "--no-mail answers without a terminal (exit $rc)"
assert '[ "$out" = "answer=no" ]'   "a no flag yields no (got '$out')"

run_closed value domain "Domain?" app.example.com
assert '[ "$out" = "answer=app.example.com" ]' "--domain= answers without a terminal (got '$out')"

run_closed secret traefik-auth "Password?" hunter2
assert '[ "$out" = "answer=hunter2" ]' "a given secret answers without a terminal (got '$out')"

# --- Case 2: no flag and no terminal is a hard failure naming the flags -------
run_closed bool mail "Enable mail?"
assert '[ "$rc" != "0" ]'                       "no flag and no terminal fails (exit $rc)"
assert 'grep -qF -- "--with-mail" <<<"$err"'    "the failure names --with-mail (got '$err')"
assert 'grep -qF -- "--no-mail" <<<"$err"'      "the failure names --no-mail (got '$err')"
assert 'grep -qF "Enable mail?" <<<"$err"'      "the failure repeats the question (got '$err')"
assert 'grep -qF "not a terminal" <<<"$err"'    "the failure says why it could not ask (got '$err')"
assert '[ -z "$out" ]'                          "a failed prompt prints nothing on stdout (got '$out')"

run_closed value domain "Domain?"
assert '[ "$rc" != "0" ]'                       "a value with no flag and no terminal fails (exit $rc)"
assert 'grep -qF -- "--domain=<value>" <<<"$err"' "the value failure names the flag with its argument (got '$err')"

run_closed secret traefik-auth "Password?"
assert '[ "$rc" != "0" ]'                              "a secret with no flag and no terminal fails (exit $rc)"
assert 'grep -qF -- "--traefik-auth=<value>" <<<"$err"' "the secret failure names the flag (got '$err')"

# A default is not an answer: without a terminal the flag is still required, or
# `kasbah` would quietly deploy to whatever the default happened to be.
run_closed value domain "Domain?" "" app.example.com
assert '[ "$rc" != "0" ]' "a default does not substitute for a flag when there is no terminal (exit $rc)"

# --- Case 3: the terminal branch, for real ------------------------------------
run_tty $'y\n' bool mail "Enable mail?"
assert '[ "$tty_rc" = "0" ]'                     "an answered prompt succeeds (exit $tty_rc)"
assert 'grep -qF "answer=yes" <<<"$tty_out"'     "y at the prompt means yes (got '$tty_out')"
assert 'grep -qF "Enable mail?" <<<"$tty_out"'   "the question reaches the terminal (got '$tty_out')"

run_tty $'n\n' bool mail "Enable mail?"
assert 'grep -qF "answer=no" <<<"$tty_out"'      "n at the prompt means no (got '$tty_out')"

# A flag still wins over the terminal — the prompt must not appear at all.
# Nothing is typed: were the flag ignored, the run would end at EOF instead of
# answering. (Input left unread also keeps script(1) from its 2 s drain wait.)
run_tty '' bool mail "Enable mail?" yes
assert 'grep -qF "answer=yes" <<<"$tty_out"'     "the flag outranks the terminal (got '$tty_out')"
assert '! grep -qF "Enable mail?" <<<"$tty_out"' "a flagged choice is never asked (got '$tty_out')"

run_tty $'maybe\ny\n' bool mail "Enable mail?"
assert 'grep -qF "answer=yes" <<<"$tty_out"'     "an unparsable answer is re-asked, not guessed (got '$tty_out')"
assert 'grep -qF "answer y or n" <<<"$tty_out"'  "the re-ask says what is acceptable (got '$tty_out')"

# Ctrl-D at the prompt: a terminal that gives no answer is as unanswered as no
# terminal, and must name the flags just the same.
run_tty '' bool mail "Enable mail?"
assert '[ "$tty_rc" != "0" ]'                    "EOF at the prompt fails (exit $tty_rc)"
assert 'grep -qF -- "--with-mail" <<<"$tty_out"' "EOF at the prompt names the flags (got '$tty_out')"

run_tty $'app.example.com\n' value domain "Domain?"
assert 'grep -qF "answer=app.example.com" <<<"$tty_out"' "a typed value comes back (got '$tty_out')"

run_tty $'\n' value domain "Domain?" "" fallback.example.com
assert 'grep -qF "answer=fallback.example.com" <<<"$tty_out"' "an empty answer takes the default (got '$tty_out')"
assert 'grep -qF "[fallback.example.com]" <<<"$tty_out"'      "the default is shown in the prompt (got '$tty_out')"

run_tty $'\nreal.example.com\n' value domain "Domain?"
assert 'grep -qF "answer=real.example.com" <<<"$tty_out"' "with no default, an empty answer is re-asked (got '$tty_out')"

tty_input_delay=0.4
run_tty $'hunter2\n' secret-quiet traefik-auth "Password?"
tty_input_delay=0
assert 'grep -qF "answer_len=7" <<<"$tty_out"'  "a typed secret comes back whole (got '$tty_out')"
assert 'grep -qF "Password?" <<<"$tty_out"'     "the secret prompt reaches the terminal (got '$tty_out')"
assert '! grep -qF "hunter2" <<<"$tty_out"'     "the typed secret never appears on the terminal (got '$tty_out')"

# --- Case 4: the answer never travels on stdout -------------------------------
# `x=$(prompt_value …)` is the shape that would silently take a wrong turn if
# the answer were printed. It captures nothing, and the variable the caller
# named is not set in its own shell either — an empty value it must handle,
# never a plausible wrong one.
run_tty $'typed.example.com\n' value-substituted domain "Domain?"
assert 'grep -qF "captured=[]" <<<"$tty_out"'    "command substitution captures no answer (got '$tty_out')"
assert 'grep -qF "answer=<unset>" <<<"$tty_out"' "the subshell's write does not reach the caller (got '$tty_out')"
assert 'grep -qF "Domain?" <<<"$tty_out"'        "the question still reached the terminal (got '$tty_out')"

# --- Case 5: caller mistakes are named as such --------------------------------
run_closed bad-outvar
assert '[ "$rc" != "0" ]'                        "a non-identifier output variable fails (exit $rc)"
assert 'grep -qF "is not a variable name" <<<"$err"' "the bad output variable is diagnosed (got '$err')"

run_closed bad-given
assert '[ "$rc" != "0" ]'                        "a tri-state that is neither yes, no nor empty fails (exit $rc)"
assert 'grep -qF "expected yes, no or empty" <<<"$err"' "the bad tri-state is diagnosed (got '$err')"

run_closed bad-given-confirm
assert '[ "$rc" != "0" ]'                        "a confirmation given a 'no' fails (exit $rc)"
assert 'grep -qF "expected yes or empty" <<<"$err"' \
    "because there is no such answer to script — not confirming is not running the command (got '$err')"

# --- Case 6: confirming a destructive act -------------------------------------
# The same read loop as prompt_bool, and one flag rather than a pair: "no" is
# not a second way to run the command, so `--yes` is the whole of what a script
# has to say.
run_closed confirm yes "Reset acme.json?" yes
assert '[ "$rc" = "0" ]'            "--yes confirms without a terminal (exit $rc)"
assert '[ "$out" = "answer=yes" ]'  "and answers yes (got '$out')"
assert '[ -z "$err" ]'              "silently (got '$err')"

run_closed confirm yes "Reset acme.json?"
assert '[ "$rc" != "0" ]'                    "an unconfirmed destructive act with no terminal fails (exit $rc)"
assert 'grep -qF -- "--yes" <<<"$err"'       "naming --yes (got '$err')"
assert '! grep -qF -- "--no-yes" <<<"$err"'  "and nothing else, since there is no --no-yes (got '$err')"
assert 'grep -qF "Reset acme.json?" <<<"$err"' "repeating the question (got '$err')"
assert '[ -z "$out" ]'                       "and printing nothing on stdout (got '$out')"

run_tty $'y\n' confirm yes "Reset acme.json?"
assert 'grep -qF "answer=yes" <<<"$tty_out"'      "y at the confirmation means yes (got '$tty_out')"
run_tty $'n\n' confirm yes "Reset acme.json?"
assert '[ "$tty_rc" = "0" ]'                      "declining is an answer, not an error (exit $tty_rc)"
assert 'grep -qF "answer=no" <<<"$tty_out"'       "n at the confirmation means no (got '$tty_out')"
run_tty '' confirm yes "Reset acme.json?"
assert '[ "$tty_rc" != "0" ]'                     "EOF at the confirmation fails rather than proceeding (exit $tty_rc)"
assert 'grep -qF -- "--yes" <<<"$tty_out"'        "naming the flag (got '$tty_out')"

# --- Case 8: the typed half of a double confirmation --------------------------
# What is expected is a parameter, not a noun this function knows: `drop` types
# a project name at it and `server destroy` a hostname, and one function is what
# keeps "double confirmation" meaning the same in both (08-keep.md, D10).
run_closed typed yes demo "Type the name:" yes
assert '[ "$rc" = "0" ]'              "--yes answers the typed confirmation without a terminal (exit $rc)"
assert '[ "$out" = "answer=match" ]'  "as a match (got '$out')"
assert '[ -z "$err" ]'                "silently (got '$err')"

run_closed typed yes demo "Type the name:"
assert '[ "$rc" != "0" ]'                     "no flag and no terminal fails (exit $rc)"
assert 'grep -qF -- "--yes" <<<"$err"'        "naming --yes (got '$err')"
assert '! grep -qF -- "--no-yes" <<<"$err"'   "and nothing else, since there is no --no-yes (got '$err')"
assert 'grep -qF "Type the name:" <<<"$err"'  "repeating the question (got '$err')"
assert '[ -z "$out" ]'                        "and answering nothing (got '$out')"

run_tty $'demo\n' typed yes demo "Type the name:"
assert 'grep -qF "answer=match" <<<"$tty_out"'    "the expected string typed back is a match (got '$tty_out')"
run_tty $'vps.example.com\n' typed yes vps.example.com "Type the host:"
assert 'grep -qF "answer=match" <<<"$tty_out"'    "and so is a hostname — the function bakes in no noun (got '$tty_out')"
run_tty $'  demo  \n' typed yes demo "Type the name:"
assert 'grep -qF "answer=match" <<<"$tty_out"' \
    "surrounding blanks are read's to strip, here as in prompt_value (got '$tty_out')"
run_tty $'demonstration\n' typed yes demo "Type the name:"
assert 'grep -qF "answer=mismatch" <<<"$tty_out"' \
    "a name the expected one is a prefix of is not it (got '$tty_out')"
run_tty '' typed yes demo "Type the name:"
assert '[ "$tty_rc" != "0" ]'                     "EOF at the typed prompt fails rather than proceeding (exit $tty_rc)"
assert 'grep -qF -- "--yes" <<<"$tty_out"'        "naming the flag (got '$tty_out')"

run_closed bad-given-typed
assert '[ "$rc" != "0" ]'                             "a typed confirmation given a 'no' fails (exit $rc)"
assert 'grep -qF "expected yes or empty" <<<"$err"'   "because declining is not running the command (got '$err')"
run_closed bad-expected-typed
assert '[ "$rc" != "0" ]'                                  "and one given nothing to expect fails (exit $rc)"
assert 'grep -qF "nothing for the operator to type" <<<"$err"' \
    "as the caller mistake it is — an empty expectation any answer could match (got '$err')"

run_closed bad-given-choice
assert '[ "$rc" != "0" ]'                        "a choice given a value that is neither answer fails (exit $rc)"
assert 'grep -qF "expected yes, no or empty" <<<"$err"' "and is diagnosed as the caller mistake it is (got '$err')"

# --- Case 7: a choice whose flags are not --with-x/--no-x ---------------------
# Both spellings are given, not derived, because the two answers of a real
# choice are rarely "with X" and "without X" — and a give-up that names a flag
# nobody can pass is worse than no message at all.
run_closed choice reset-acme keep-acme "Reset the store?" yes
assert '[ "$rc" = "0" ]'            "--reset-acme answers without a terminal (exit $rc)"
assert '[ "$out" = "answer=yes" ]'  "as yes (got '$out')"
run_closed choice reset-acme keep-acme "Reset the store?" no
assert '[ "$rc" = "0" ]'            "--keep-acme answers without a terminal too (exit $rc)"
assert '[ "$out" = "answer=no" ]'   "as no — the safe answer is expressible in a script (got '$out')"
assert '[ -z "$err" ]'              "silently (got '$err')"

run_closed choice reset-acme keep-acme "Reset the store?"
assert '[ "$rc" != "0" ]'                          "neither flag and no terminal fails (exit $rc)"
assert 'grep -qF -- "--reset-acme or --keep-acme" <<<"$err"' \
    "naming both flags, neither of them derived from a feature name (got '$err')"
assert '! grep -qF -- "--with-" <<<"$err"'         "and inventing no --with- spelling (got '$err')"

run_tty $'n\n' choice reset-acme keep-acme "Reset the store?"
assert '[ "$tty_rc" = "0" ]'                  "n at a choice is an answer, not an error (exit $tty_rc)"
assert 'grep -qF "answer=no" <<<"$tty_out"'   "and means no (got '$tty_out')"
run_tty '' choice reset-acme keep-acme "Reset the store?"
assert '[ "$tty_rc" != "0" ]'                             "EOF at a choice fails rather than picking one (exit $tty_rc)"
assert 'grep -qF -- "--reset-acme or --keep-acme" <<<"$tty_out"' "naming both flags (got '$tty_out')"

exit "$fail"
