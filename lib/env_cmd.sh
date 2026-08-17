# kasbah — `kasbah env`, and the same env step inside a deploy
# Sourced by bin/kasbah and lib/deploy.sh. Do not execute directly.

[ -n "${_KASBAH_ENV_CMD_LOADED:-}" ] && return 0
_KASBAH_ENV_CMD_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
. "$KASBAH_LIB_DIR/state.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
. "$KASBAH_LIB_DIR/marker.sh"

# Step 6 of docs/build-deploy.md, and the whole of `kasbah env`: get the
# project's .env on the server into a state a deploy can run against, then
# refresh the KASBAH_* block from the server marker's limits.
#
# **lib/env.sh is deliberately not sourced here.** Every question this file asks
# about a .env is asked on the far side, by the copy of lib/env.sh that shipped
# there as scripts/setup-env.sh — the same bytes `kasbah check` sources
# locally, which is what makes "one shared drift function" literally true
# instead of two copies that agree today (docs/phases/03-env.md → 3.1). Not
# sourcing it also keeps its ~26 unprefixed globals (KEY, VALUE, DEFAULT, line,
# …) out of a file that calls lib/prompt.sh, whose prompt_value writes into a
# caller-named variable with `printf -v`.
#
# Ordering, both halves load-bearing:
#   * the env step runs *after* the project rsync, because the interactive
#     setup prompts from the .env.prod.example that rsync put there, and
#   * *before* the remote deploy, because `compose up` reads the file — and
#     therefore long before the Traefik fragment, which is still the last thing
#     any deploy ships (docs/phases/02-spine.md).
#   * injection runs *after* setup, never before: env_setup_run rebuilds .env
#     from a template that carries no reserved keys, so a run destroys the
#     managed block (docs/env-template.md).

# What the far side answered, folded out of scripts/setup-env.sh --drift.
_ENV_TEMPLATE_EXISTS=""
_ENV_EXISTS=""
_ENV_MISSING=""
_ENV_EXTRA=""
# The tri-state answer. Prefixed, because lib/prompt.sh writes it with
# `printf -v` into a name this file hands over — an unprefixed one could collide
# with a local somewhere up the call stack and be written in the wrong scope.
_ENV_ON_DRIFT_ANSWER=""

# --- The flag ---------------------------------------------------------------------

# env_on_drift_check CMD VALUE — the three answers of docs/build-deploy.md step
# 6, validated where the flag is parsed rather than where it is used, so a typo
# costs a sentence at the top of the run instead of a prompt at the bottom of it.
# Not a --with-x/--no-x pair: the boolean form leaves *abort* unrequestable,
# which is the one a scripted deploy wants (docs/phases/03-env.md → Decisions).
env_on_drift_check() {
    local cmd="$1" value="${2%$'\r'}"
    case "$value" in
        setup|continue|abort) return 0 ;;
    esac
    die "$cmd: --on-drift='$value' is not one of setup, continue or abort"
}

# --- Shipping ---------------------------------------------------------------------

# env_ship_helper APPS NAME — lib/env.sh itself, byte for byte, as the project's
# scripts/setup-env.sh. There is no generation step and no second copy: the file
# is dual-mode by construction (docs/phases/03-env.md → 3.1), so it comes from
# KASBAH_LIB_DIR rather than from KASBAH_TEMPLATE_DIR. Executable is stated
# rather than inherited, the way remote-deploy.sh is: a checkout on a filesystem
# that lost the mode bit would otherwise ship a script nothing can run.
env_ship_helper() {
    local apps="$1" name="$2"
    local src="${KASBAH_LIB_DIR:-}/env.sh"
    local dest="$apps/$name/scripts/setup-env.sh"

    [ -n "${KASBAH_LIB_DIR:-}" ] || die "internal: KASBAH_LIB_DIR is not set"
    [ -f "$src" ] \
        || die "the env helper is missing (looked in $src) — this kasbah installation is incomplete"

    ssh_rsync -pt --chmod=F755 -s "$src" "$SSH_TARGET:$dest" >/dev/null \
        || die "could not ship setup-env.sh to $SSH_TARGET:$dest"
    return 0
}

# --- Reading the far side ----------------------------------------------------------

# The key set is checked as a protocol before any verdict reads a value: an
# answer that never arrived must not be absorbed into a passing branch
# (docs/phases/01-rig.md). "no drift" and "the report was truncated" are
# indistinguishable once an empty string has been taken for an answer.
#
# lib/deploy.sh's _deploy_absorb does the same job and is deliberately not
# reused: it writes into _DEPLOY_FACT and reports through _DEPLOY_TARGET, so
# calling it from here would make env_cmd.sh depend on deploy.sh — the reverse
# of the direction that exists, and a sourcing cycle. Two twenty-line readers
# beat that.
_env_absorb() {
    local out="$1"
    local line seen=""

    _ENV_TEMPLATE_EXISTS=""
    _ENV_EXISTS=""
    _ENV_MISSING=""
    _ENV_EXTRA=""

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case $line in
            template_exists=*) _ENV_TEMPLATE_EXISTS="${line#*=}"; seen="$seen template_exists" ;;
            env_exists=*)      _ENV_EXISTS="${line#*=}";          seen="$seen env_exists" ;;
            missing=*)         _ENV_MISSING="${line#*=}";         seen="$seen missing" ;;
            extra=*)           _ENV_EXTRA="${line#*=}";           seen="$seen extra" ;;
        esac
    done <<<"$out"

    local key
    local absent=()
    for key in template_exists env_exists missing extra; do
        case " $seen " in
            *" $key "*) ;;
            *) absent+=("$key") ;;
        esac
    done
    if [ "${#absent[@]}" -gt 0 ]; then
        err "the env check on $SSH_TARGET reported no ${absent[*]}"
        err_cont "the step was truncated, or setup-env.sh is not the one this kasbah ships —"
        err_cont "raw output:"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
        exit 1
    fi
    return 0
}

_env_probe() {
    local apps="$1" name="$2"
    local script="$apps/$name/scripts/setup-env.sh"
    local out rc=0

    out=$(ssh_run "$script" --drift "$apps/$name") || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "could not read the env state of $apps/$name on $SSH_TARGET"
        err_cont "$script --drift exited $rc (see above). That script is shipped by this same"
        err_cont "command moments earlier, so a failure here is the server refusing to run it."
        exit 1
    fi
    _env_absorb "$out"
    return 0
}

# --- The interactive half ----------------------------------------------------------

# The remedies a refusal offers, per reason, because a remedy that cannot reach
# the branch it is printed under is the defect Phase 2 named: `--on-drift=` is
# only consulted when there *is* drift, so offering it to an operator whose .env
# does not exist tells them to re-run the identical command for the identical
# exit 5. A missing .env has exactly two ways out — a terminal, or the file
# written by hand — and both are spelled out rather than alluded to.
_env_remedies() {
    local reason="$1" dir="$2"
    case "$reason" in
        missing)
            err_cont "  * run \`kasbah env $SSH_TARGET\` from a terminal, or"
            err_cont "  * write the file on the server yourself, from the template that is"
            err_cont "    already beside it:"
            err_cont "      ssh $SSH_TARGET 'cp $dir/.env.prod.example $dir/.env'   # then edit it there"
            err_cont "--on-drift= does not reach this: there is no .env to have drifted."
            ;;
        drift)
            err_cont "  * run \`kasbah env $SSH_TARGET\` from a terminal, or"
            err_cont "  * pass --on-drift=continue to deploy against $dir/.env as it stands, or"
            err_cont "  * pass --on-drift=abort to stop without touching the server."
            ;;
        reconfigure)
            err_cont "  * run \`kasbah env $SSH_TARGET\` from a terminal."
            err_cont "$dir/.env is already in sync with the template, so \`kasbah deploy\`"
            err_cont "needs nothing from you — this command exists to re-answer the prompts,"
            err_cont "and there is nobody here to answer them."
            ;;
        *) err_cont "  * run \`kasbah env $SSH_TARGET\` from a terminal." ;;
    esac
    return 0
}

# The generator, on the far side, over a real terminal. `ssh -t` needs one at
# both ends: the far side has to be able to mask a password with `read -rs` and
# read one character at a menu, and this side has to have a session to hand it.
#
# Both `-t 0` and `-t 1` are checked here, and the `-t 1` half is not
# over-strictness borrowed from lib/prompt.sh: the generator's prompts go to its
# *stdout* (lib/env.sh decides its own colour on `[ -t 1 ]`), so a run whose
# stdout is a file has nowhere to show the question even when somebody is
# sitting at the keyboard.
#
# Without a local terminal there is nothing to fall back to — running it anyway
# feeds the generator EOF, which its `|| true` turns into every default silently
# accepted, secrets included. So this refuses, names the way out *for this
# reason*, and exits 5 (cross-phase rule 1: an unanswerable prompt is a hard
# failure, never a hang).
_env_run_setup() {
    local apps="$1" name="$2" why="$3" reason="$4"
    local dir="$apps/$name"
    local rc=0

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        err "$why on $SSH_TARGET, and there is no terminal here to render it on"
        err_cont "the setup is interactive — it prompts per variable, masks the secret ones and"
        err_cont "runs the template's generators (docs/env-template.md). Either:"
        _env_remedies "$reason" "$dir"
        err_cont "Nothing was deployed."
        exit "$KASBAH_EXIT_ENV_SETUP"
    fi

    info "$why — running the interactive env setup on $SSH_TARGET"
    ssh_run_tty "$dir/scripts/setup-env.sh" "$dir" || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "the env setup on $SSH_TARGET did not finish (setup-env.sh exited $rc, see above)"
        err_cont "it was aborted, answered with nothing, or could not run at all — all three"
        err_cont "leave the .env unwritten, which is what exit 5 says. Nothing was deployed."
        err_cont "Re-run and answer it through, or:"
        _env_remedies "$reason" "$dir"
        exit "$KASBAH_EXIT_ENV_SETUP"
    fi
    return 0
}

# Re-read rather than assumed: the generator's own abort (`q`) and its EOF path
# both leave the file untouched and say so on stdout, and a deploy that took
# "the command returned 0" for "there is a .env now" would go on to a
# `compose up` that fails on an unset variable.
_env_require_env_file() {
    local apps="$1" name="$2"

    _env_probe "$apps" "$name"
    [ "$_ENV_EXISTS" = yes ] && return 0

    err "the env setup left no $apps/$name/.env on $SSH_TARGET"
    err_cont "it was aborted, or answered with nothing. Nothing was deployed — re-run"
    err_cont "\`kasbah env $SSH_TARGET\` and answer it through."
    exit "$KASBAH_EXIT_ENV_SETUP"
}

# The three answers of docs/build-deploy.md step 6. The flag wins; otherwise a
# terminal is asked; otherwise the run stops naming the flag that would have
# answered — docs/overview.md's interactivity rule.
#
# `[ -t 0 ]` only, deliberately, and it is the same test lib/prompt.sh:86 makes:
# prompt_value puts its question on **stderr**, the way bash's own `read -p`
# does, so `kasbah env user@vps > out.log` is an answerable prompt and must not
# be refused. Re-deriving the rule more strictly than the helper that owns it is
# how one command ends up refusing what `kasbah server init` accepts in the
# same shape. (The setup itself is the other case — see _env_run_setup, whose
# `-t 1` check is about the *remote* generator's stdout, not about this prompt.)
#
# The give-up here exits 5 rather than prompt.sh's 1, because "the env step
# could not complete" is a thing a script branches on. One path keeps prompt.sh's
# 1 and is left that way on purpose: Ctrl-D at the prompt reaches
# prompt_value's own give-up, which exits 1 for every kasbah prompt there is,
# and making this one command answer differently to the same keystroke would be
# the worse inconsistency. Changing it would mean either reaching into
# lib/prompt.sh or re-implementing the read loop this comment argues against.
_env_choose_on_drift() {
    local given="${1:-}"

    _ENV_ON_DRIFT_ANSWER=""
    if [ -z "$given" ] && [ ! -t 0 ]; then
        err "cannot ask what to do about the drift: there is no terminal to ask on"
        err_cont "pass --on-drift=setup (re-run the interactive setup), --on-drift=continue"
        err_cont "(deploy against the .env as it stands) or --on-drift=abort."
        err_cont "Nothing was deployed."
        exit "$KASBAH_EXIT_ENV_SETUP"
    fi

    while :; do
        prompt_value on-drift \
            "re-run setup, continue with the .env as it stands, or abort? [setup/continue/abort]" \
            "$given" _ENV_ON_DRIFT_ANSWER
        case "$_ENV_ON_DRIFT_ANSWER" in
            setup|continue|abort) return 0 ;;
        esac
        warn "answer setup, continue or abort"
        # A flag value is validated where it is parsed, so this can only be a
        # typed answer — and clearing it keeps the loop from re-accepting the
        # same rejected value forever.
        given=""
    done
}

# --- Injection --------------------------------------------------------------------

# The managed block, written by the same shipped script. Values go through
# exactly as the marker spells them (docs/env-template.md): a `0` limit stays
# `0`, which is what a host that cannot apply cgroup limits needs.
#
# Exit 1, not 5, and the line between them is the *step*, not the cause. Exit 5
# is the env setup: every way it can end without a .env kasbah will deploy
# against — drift declined, nobody there to be asked, or setup-env.sh itself not
# finishing (126 and 127 included). Injection is not setup; it takes no answer
# from anyone, so it fails the way _env_probe, the helper rsync and
# remote-deploy.sh do. Pinned in tests/deploy_test.sh so the two cannot merge.
_env_inject() {
    local apps="$1" name="$2" cpu="$3" mem="$4"
    local dir="$apps/$name"
    local rc=0

    ssh_run "$dir/scripts/setup-env.sh" --inject "$dir" \
        "KASBAH_CPU_LIMIT=$cpu" "KASBAH_MEM_LIMIT=$mem" || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "could not write the kasbah-managed block into $dir/.env on $SSH_TARGET"
        err_cont "setup-env.sh --inject exited $rc (see above). Without it \`compose up\` fails on"
        err_cont "an unset KASBAH_CPU_LIMIT, so nothing was deployed."
        exit 1
    fi
    return 0
}

# --- The step ---------------------------------------------------------------------

# env_step_run APPS NAME CPU MEM ON_DRIFT ALWAYS_SETUP
#
# ALWAYS_SETUP is `yes` for `kasbah env`, whose whole job is to run the
# generator, and `no` for a deploy, which only runs it when the .env is not
# there or has drifted. Either way the step ends in injection.
env_step_run() {
    local apps="$1" name="$2" cpu="$3" mem="$4" on_drift="${5:-}" always="${6:-no}"
    local dir="$apps/$name"
    local action=continue
    # `why` is the sentence the refusal opens with; `reason` selects the
    # remedies that can actually reach the branch (see _env_remedies).
    local why="$dir/.env is being reconfigured" reason=reconfigure

    _env_probe "$apps" "$name"

    if [ "$_ENV_EXISTS" != yes ]; then
        if [ "$_ENV_TEMPLATE_EXISTS" != yes ]; then
            err "$SSH_TARGET has no $dir/.env, and no $dir/.env.prod.example to render one from"
            err_cont "the template is the project's own file and reaches the server through the"
            err_cont "manifest's sync: list — add .env.prod.example to it"
            err_cont "(docs/project-manifest.md, docs/env-template.md). Nothing was deployed."
            exit "$KASBAH_EXIT_ENV_SETUP"
        fi
        action=setup
        why="$dir/.env does not exist yet"
        reason=missing
    elif [ "$_ENV_TEMPLATE_EXISTS" != yes ]; then
        # No template, so there is no drift question to ask: every key in .env
        # would read as "extra" against an empty key set, which is an artefact
        # of the missing file rather than a fact about the .env.
        warn "$SSH_TARGET has no $dir/.env.prod.example, so its .env cannot be checked for drift"
        warn "add .env.prod.example to the manifest's sync: list (docs/project-manifest.md)"
        if [ "$always" = yes ]; then
            # `kasbah env` with no template on the far side has nothing to
            # prompt from, and the generator would refuse anyway.
            die "there is no $dir/.env.prod.example on $SSH_TARGET to run the setup against"
        fi
    elif [ -n "$_ENV_MISSING$_ENV_EXTRA" ]; then
        # env_drift never signals through its exit status — the two lists are
        # the answer, and `if env_drift …` would test nothing (docs/env-template.md).
        warn "$dir/.env on $SSH_TARGET has drifted from .env.prod.example"
        [ -z "$_ENV_MISSING" ] || warn "  in the template, not in .env: $_ENV_MISSING"
        [ -z "$_ENV_EXTRA" ]   || warn "  in .env, not in the template: $_ENV_EXTRA"
        _env_choose_on_drift "$on_drift"
        action="$_ENV_ON_DRIFT_ANSWER"
        why="$dir/.env has drifted from .env.prod.example"
        reason=drift
    elif [ "$always" = yes ]; then
        action=setup
    fi

    case "$action" in
        setup)
            _env_run_setup "$apps" "$name" "$why" "$reason"
            _env_require_env_file "$apps" "$name"
            if [ -n "$_ENV_MISSING$_ENV_EXTRA" ]; then
                warn "$dir/.env still differs from .env.prod.example — continuing with it as it stands"
            fi
            ;;
        continue) ;;
        abort)
            err "aborted: $dir/.env on $SSH_TARGET has drifted from .env.prod.example"
            err_cont "nothing was deployed. \`kasbah env $SSH_TARGET\` re-runs the setup, or pass"
            err_cont "--on-drift=continue to deploy against the .env as it stands."
            exit "$KASBAH_EXIT_ENV_SETUP"
            ;;
        *) die "internal: env_step_run reached action '$action'" ;;
    esac

    _env_inject "$apps" "$name" "$cpu" "$mem"
    return 0
}

# --- The command ------------------------------------------------------------------

_ENV_TARGET=""
_ENV_ON_DRIFT=""

_env_usage() {
    cat <<EOF
Usage: kasbah env [USER@HOST] [--on-drift=setup|continue|abort]

Renders <apps>/<name>/.env on the server from this project's .env.prod.example,
interactively, and refreshes the kasbah-managed KASBAH_* block in it from the
server marker's resource limits. Run from the project root; USER@HOST defaults
to the last server this project deployed to (.kasbah/state.json).

The setup is interactive and needs a terminal at both ends. Without one the run
stops (exit 5) rather than accepting every default silently — including when
--on-drift= is passed, since this command runs the setup whether or not .env has
drifted.

Flags, for when it has:
  --on-drift=setup      re-run the setup. What the command does anyway; there
                        is no default answer, an empty one is asked again
  --on-drift=continue   leave .env alone; only refresh the KASBAH_* block
  --on-drift=abort      stop, changing nothing

See docs/env-template.md for the template conventions.
EOF
}

_env_parse_args() {
    _ENV_TARGET=""
    _ENV_ON_DRIFT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _env_usage; exit 0 ;;
            --on-drift=*)
                _ENV_ON_DRIFT="${1#*=}"
                env_on_drift_check env "$_ENV_ON_DRIFT"
                ;;
            --on-drift)
                die "env: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort" ;;
            -*) die "env: unknown flag '${1%%=*}' (env takes USER@HOST and --on-drift=)" ;;
            *)
                if [ -z "$_ENV_TARGET" ]; then
                    _ENV_TARGET="${1%$'\r'}"
                else
                    die "env: too many arguments ('$1') — env takes USER@HOST and nothing else"
                fi
                ;;
        esac
        shift
    done
    return 0
}

_env_resolve_target() {
    local stored=""

    [ -z "$_ENV_TARGET" ] || return 0

    state_get last_server stored
    if [ -z "$stored" ] || [ "$stored" = null ]; then
        err "env: no server given, and this project has never deployed to one"
        err_cont "pass it once — \`kasbah env user@vps\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        exit 1
    fi
    _ENV_TARGET="$stored"
    return 0
}

# The project directory and its scripts/, so the two rsyncs below have somewhere
# to land: rsync creates the last component of a destination path, never the
# ones above it.
_env_prepare() {
    local apps="$1" name="$2"
    local out rc=0

    out=$(ssh_script "$apps" "$name" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
name=$2

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

[ -d "$apps" ] || fail "$apps is not a directory"
for d in "$apps/$name" "$apps/$name/scripts"; do
    mkdir -p "$d" || fail "could not create $d"
done

printf 'prepared=yes\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not prepare $apps/$name on $_ENV_TARGET (the remote step exited $rc, see above)"
    case $out in
        *prepared=yes*) ;;
        *) die "the prepare step on $_ENV_TARGET reported no prepared (raw output: $out)" ;;
    esac
    return 0
}

cmd_env() {
    _env_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    command -v rsync >/dev/null || die "rsync is required (install rsync and retry)"

    manifest_require
    _env_resolve_target
    [ -f .env.prod.example ] \
        || die "no .env.prod.example in $PWD — that file is the template this renders .env from (docs/env-template.md)"

    ssh_connect "$_ENV_TARGET"
    marker_read "$_ENV_TARGET"
    _env_prepare "$MARKER_APPS_PATH" "$MANIFEST_NAME"

    # The template first: the generator prompts from it, so it has to be the
    # current one before anything reads it.
    ssh_rsync -lpt -s .env.prod.example \
        "$SSH_TARGET:$MARKER_APPS_PATH/$MANIFEST_NAME/.env.prod.example" >/dev/null \
        || die "could not ship .env.prod.example to $_ENV_TARGET:$MARKER_APPS_PATH/$MANIFEST_NAME/"
    env_ship_helper "$MARKER_APPS_PATH" "$MANIFEST_NAME"

    env_step_run "$MARKER_APPS_PATH" "$MANIFEST_NAME" \
        "$MARKER_CPU_LIMIT" "$MARKER_MEM_LIMIT" "$_ENV_ON_DRIFT" yes

    state_record last_server "$_ENV_TARGET"

    info "$MANIFEST_NAME's .env on $_ENV_TARGET is ready"
    info "  file:   $MARKER_APPS_PATH/$MANIFEST_NAME/.env"
    info "  limits: KASBAH_CPU_LIMIT=$MARKER_CPU_LIMIT KASBAH_MEM_LIMIT=$MARKER_MEM_LIMIT (from the server marker)"
}
