# hosting — flag-or-prompt helpers
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_PROMPT_LOADED:-}" ] && return 0
_HOSTING_PROMPT_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"

# The tri-state rule of docs/overview.md → Interactivity lives here and nowhere
# else: an explicit flag wins, otherwise a terminal is asked, otherwise the run
# stops naming the flag that would have answered. A command parses its flags
# into a value ("yes"/"no", or the value itself) and hands that value over —
# the branch is never re-derived at the call site.
#
# Nothing here writes to stdout. Questions and warnings go to stderr (which is
# where bash's own `read -p` puts its prompt), and answers come back in a
# caller-named variable, so `x=$(prompt_value …)` yields an empty x rather than
# a plausible-looking wrong answer. Interactivity is a property of stdin, which
# command substitution does not touch — but the answer is the thing that would
# be lost, so the API refuses to travel that way at all.
#
# Locals are `_p_`-prefixed because the answer is written with `printf -v`: a
# caller-named variable that collided with a local would be written in the
# wrong scope.

# Every give-up path names the flags that make the choice scriptable. Exit 1
# rather than a return: an unanswerable question is not something a caller can
# recover from, and the alternative — assuming — is what this file exists to
# prevent.
_prompt_give_up() {
    local _p_reason="$1" _p_question="$2" _p_flags="$3"
    err "cannot ask: $_p_question"
    err_cont "$_p_reason — pass $_p_flags instead"
    exit 1
}

_prompt_out_var() {
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "internal: '${1:-}' is not a variable name to write the answer into"
}

# prompt_bool <feature> <question> [given]
#   given: "yes" or "no" as parsed from --with-<feature>/--no-<feature>, empty
#          when neither was passed.
# Answer is the exit status: 0 yes, 1 no. Used as `if prompt_bool mail …; then`.
prompt_bool() {
    local _p_flag="$1" _p_question="$2" _p_given="${3:-}"
    local _p_flags="--with-$_p_flag or --no-$_p_flag"

    case "${_p_given%$'\r'}" in
        yes) return 0 ;;
        no)  return 1 ;;
        '')  ;;
        *)   die "internal: prompt_bool $_p_flag was given '$_p_given' (expected yes, no or empty)" ;;
    esac

    [ -t 0 ] || _prompt_give_up "stdin is not a terminal" "$_p_question" "$_p_flags"

    local _p_answer
    while :; do
        read -r -p "$_p_question [y/n] " _p_answer \
            || _prompt_give_up "no answer given" "$_p_question" "$_p_flags"
        case "${_p_answer%$'\r'}" in
            y|Y|yes|Yes|YES) return 0 ;;
            n|N|no|No|NO)    return 1 ;;
        esac
        warn "answer y or n"
    done
}

# prompt_value <flag> <question> <given> <outvar> [default]
#   given: the flag's value, empty when it was not passed. A flag whose empty
#          value is meaningful is the caller's to reject before asking.
# Writes the answer into <outvar>. An empty answer takes the default; with no
# default, the question is asked again.
prompt_value() {
    local _p_flag="$1" _p_question="$2" _p_given="${3:-}" _p_out="${4:-}" _p_default="${5:-}"
    _prompt_out_var "$_p_out"
    local _p_flags="--$_p_flag=<value>"

    if [ -n "$_p_given" ]; then
        printf -v "$_p_out" '%s' "${_p_given%$'\r'}"
        return 0
    fi

    [ -t 0 ] || _prompt_give_up "stdin is not a terminal" "$_p_question" "$_p_flags"

    local _p_answer _p_suffix=""
    [ -z "$_p_default" ] || _p_suffix=" [$_p_default]"
    while :; do
        read -r -p "$_p_question$_p_suffix: " _p_answer \
            || _prompt_give_up "no answer given" "$_p_question" "$_p_flags"
        _p_answer="${_p_answer%$'\r'}"
        [ -n "$_p_answer" ] || _p_answer="$_p_default"
        if [ -n "$_p_answer" ]; then
            printf -v "$_p_out" '%s' "$_p_answer"
            return 0
        fi
        warn "an answer is required"
    done
}

# prompt_secret <flag> <question> <given> <outvar>
# As prompt_value, with the typing hidden. No default: a secret nobody typed is
# not a secret. The newline the terminal did not echo is supplied here, so the
# next line of output does not land on the prompt.
prompt_secret() {
    local _p_flag="$1" _p_question="$2" _p_given="${3:-}" _p_out="${4:-}"
    _prompt_out_var "$_p_out"
    local _p_flags="--$_p_flag=<value>"

    if [ -n "$_p_given" ]; then
        printf -v "$_p_out" '%s' "${_p_given%$'\r'}"
        return 0
    fi

    [ -t 0 ] || _prompt_give_up "stdin is not a terminal" "$_p_question" "$_p_flags"

    local _p_answer
    while :; do
        if ! read -rs -p "$_p_question: " _p_answer; then
            printf '\n' >&2
            _prompt_give_up "no answer given" "$_p_question" "$_p_flags"
        fi
        printf '\n' >&2
        _p_answer="${_p_answer%$'\r'}"
        if [ -n "$_p_answer" ]; then
            printf -v "$_p_out" '%s' "$_p_answer"
            return 0
        fi
        warn "an answer is required"
    done
}
