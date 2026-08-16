#!/usr/bin/env bash
# =============================================================================
# hosting — interactive .env generator
#
# Reads .env.prod.example and prompts for each variable.
# If .env already exists, detects drift and only prompts for new vars.
# Dropped vars (in .env but removed from template) are silently excluded.
#
# Value conventions in .env.prod.example:
#   VAR=value       → "value" shown as default, Enter to accept
#   VAR=            → empty, user types or Enter to keep empty
#   VAR=# hint      → hint shown as guide, user must type
#   VAR=! command   → command runs to generate default if Enter pressed
#   VAR=value # comment → default with inline hint
#
# Comment lines are preserved in the output. Ones matching `# ---`/`# ===` are
# additionally rendered as bold section headers while prompting.
#
# Also carries the drift helpers (env_extract_keys, env_drift) and the
# HOSTING_* managed-block writer, so the VPS copy answers "has this .env
# drifted" with the same code the workstation runs.
#
# Dual-mode. Sourced as a library locally; the same bytes are rsynced to the
# VPS as scripts/setup-env.sh and executed there, where no other hosting file
# exists — so nothing here may source common.sh, read HOSTING_LIB_DIR, or call
# info/warn/err/die. Tool budget: coreutils and bash builtins, never a
# separately-packaged one (awk, bc, jq).
#
# Usage (executed):
#   ./scripts/setup-env.sh                          # interactive
#   ./scripts/setup-env.sh /path/to/dir             # custom directory
# =============================================================================

# Never exported, so the executed case reaches the guard with it unset and the
# `return` below is never taken.
[ -n "${_HOSTING_ENV_LOADED:-}" ] && return 0
_HOSTING_ENV_LOADED=1

# Errexit is part of this file's contract, not decoration: the two menu reads
# are the only ones without `|| true`, so EOF at a menu aborts and leaves .env
# untouched. A shell that sources this must already be running -euo pipefail.
set -euo pipefail

# Keys under this prefix are hosting's: never prompted, invisible to drift in
# both directions, and owned by the managed block below. The prefix is matched
# anchored — MY_HOSTING_URL is the user's key, not hosting's.
# docs/env-template.md § Drift detection, docs/compliance.md § Env.
ENV_RESERVED_PREFIX=HOSTING_

# The block env_inject_hosting_vars owns. Frozen strings: an older hosting's
# block has to be recognised, and every one of them collapses into a single
# rewritten block.
ENV_MANAGED_BEGIN='# >>> hosting managed block - do not edit, rewritten on every deploy >>>'
ENV_MANAGED_END='# <<< hosting managed block <<<'

# ---------------------------------------------------------------------------
# Colors — this script's prompts go to stdout, so that is what decides.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    CYAN='\033[36m'
    YELLOW='\033[33m'
    GREEN='\033[32m'
    RED='\033[31m'
    RESET='\033[0m'
else
    BOLD='' DIM='' CYAN='' YELLOW='' GREEN='' RED='' RESET=''
fi

# ---------------------------------------------------------------------------
# Prompt helper — reads input, masks sensitive vars
# ---------------------------------------------------------------------------
# Reads KEY and writes VALUE in the caller's scope by dynamic scoping: neither
# may be made local here. Named `_env_prompt_value` because lib/prompt.sh
# already owns `prompt_value` with an unrelated signature and lib/deploy.sh
# sources both.
_env_prompt_value() {
    VALUE=""
    if [[ "$KEY" =~ PASSWORD|SECRET|KEY ]]; then
        read -rs VALUE || true
        echo ""
    else
        read -r VALUE || true
    fi
}

# env_setup_run [target_dir]
# Returns 1 when the template is missing and 0 on abort, already-in-sync, or a
# written .env — a `return`, not an `exit`, so a sourced caller survives it.
# It does *not* return on every path: EOF at one of the menu prompts trips
# errexit, which kills the calling shell. Callers that must survive that run it
# in a subshell.
#
# Rebuilds .env from the template, which carries no reserved keys — so a run
# destroys the managed block, and `docker compose up` then fails on an unset
# HOSTING_CPU_LIMIT. The order is fixed: env_inject_hosting_vars runs *after*
# this, never before.
#
# The six `declare`d arrays below are function-local (declare inside a function
# is), unlike the standalone original's globals — so a second call in one shell
# cannot see the first call's NEW_KEYS. Everything else it sets is global.
env_setup_run() {
    TARGET_DIR="${1:-.}"
    EXAMPLE="${TARGET_DIR}/.env.prod.example"
    OUTPUT="${TARGET_DIR}/.env"

    if [[ ! -f "$EXAMPLE" ]]; then
        echo "ERROR: Template not found at ${EXAMPLE}"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Load existing .env values if present
    # -----------------------------------------------------------------------
    declare -A EXISTING=()
    if [[ -f "$OUTPUT" ]]; then
        # `|| [[ -n "$line" ]]`, here and in every other reader in this file: a
        # final line with no newline is data. docker compose and lib/check.sh's
        # readers see it, and dropping it loses a live value on reconfigure.
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
                case "${BASH_REMATCH[1]}" in "$ENV_RESERVED_PREFIX"*) continue ;; esac
                EXISTING["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            fi
        done < "$OUTPUT"
    fi

    # -----------------------------------------------------------------------
    # Update mode: detect new/dropped vars, let user choose scope
    # -----------------------------------------------------------------------
    UPDATE_ONLY=false

    if [[ ${#EXISTING[@]} -gt 0 ]]; then
        # Extract template keys
        declare -a TEMPLATE_KEYS=()
        while IFS= read -r tline || [[ -n "$tline" ]]; do
            tline="${tline%$'\r'}"
            if [[ "$tline" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
                case "${BASH_REMATCH[1]}" in "$ENV_RESERVED_PREFIX"*) continue ;; esac
                TEMPLATE_KEYS+=("${BASH_REMATCH[1]}")
            fi
        done < "$EXAMPLE"

        # Build template key set
        declare -A TEMPLATE_KEY_SET=()
        for tkey in "${TEMPLATE_KEYS[@]}"; do
            TEMPLATE_KEY_SET[$tkey]=1
        done

        # New keys: in template but not in existing .env
        declare -a NEW_KEYS=()
        for tkey in "${TEMPLATE_KEYS[@]}"; do
            if [[ -z "${EXISTING[$tkey]+isset}" ]]; then
                NEW_KEYS+=("$tkey")
            fi
        done

        # Dropped keys: in existing .env but not in template
        declare -a DROPPED_KEYS=()
        for ekey in "${!EXISTING[@]}"; do
            if [[ -z "${TEMPLATE_KEY_SET[$ekey]+isset}" ]]; then
                DROPPED_KEYS+=("$ekey")
            fi
        done

        KEPT_COUNT=$(( ${#TEMPLATE_KEYS[@]} - ${#NEW_KEYS[@]} ))

        echo ""
        echo -e "    Existing .env found — ${GREEN}${KEPT_COUNT} kept${RESET}, ${YELLOW}${#NEW_KEYS[@]} new${RESET}, ${RED}${#DROPPED_KEYS[@]} removed${RESET}"

        if [[ ${#NEW_KEYS[@]} -gt 0 ]]; then
            echo ""
            echo -e "    ${YELLOW}New:${RESET}"
            for nkey in "${NEW_KEYS[@]}"; do
                echo -e "      + ${BOLD}${nkey}${RESET}"
            done
        fi

        if [[ ${#DROPPED_KEYS[@]} -gt 0 ]]; then
            echo ""
            echo -e "    ${RED}Removed:${RESET}"
            for dkey in "${DROPPED_KEYS[@]}"; do
                echo -e "      - ${dkey}"
            done
        fi

        echo ""
        if [[ ${#NEW_KEYS[@]} -eq 0 && ${#DROPPED_KEYS[@]} -eq 0 ]]; then
            echo -e "    No changes detected — .env is in sync with template."
            echo ""
            read -p "    Reconfigure all vars? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo ""
                echo -e "${GREEN}${BOLD}==> .env is up to date${RESET}"
                return 0
            fi
        else
            echo -ne "    ${BOLD}[Enter]${RESET} Configure new vars only  ${DIM}|${RESET}  ${BOLD}a${RESET} Reconfigure all  ${DIM}|${RESET}  ${BOLD}q${RESET} Abort: "
            read -r -n 1 CHOICE
            echo ""

            case "$CHOICE" in
                q|Q)
                    echo "    Aborted."
                    return 0
                    ;;
                a|A)
                    echo ""
                    echo "    Reconfiguring all variables..."
                    ;;
                *)
                    UPDATE_ONLY=true
                    if [[ ${#NEW_KEYS[@]} -gt 0 ]]; then
                        echo ""
                        echo "    Configuring ${#NEW_KEYS[@]} new variable(s)..."
                    else
                        echo ""
                        echo "    No new variables — regenerating .env from template..."
                    fi
                    ;;
            esac
        fi

        echo ""
    fi

    # -----------------------------------------------------------------------
    # Parse template and prompt
    # -----------------------------------------------------------------------
    SUPPRESS_HEADERS=false
    # Short-circuit: NEW_KEYS only exists when UPDATE_ONLY could be true
    [[ "$UPDATE_ONLY" == true ]] && [[ ${#NEW_KEYS[@]} -eq 0 ]] && SUPPRESS_HEADERS=true

    declare -a OUTPUT_LINES=()

    # Read template from FD 3 so stdin stays free for user input
    while IFS= read -r line <&3 || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        # Blank lines → preserve
        if [[ -z "$line" ]]; then
            OUTPUT_LINES+=("")
            continue
        fi

        # Section headers: lines like "# --- Section Name ---" or "# ==== Section ===="
        if [[ "$line" =~ ^#\ *[-=]{3,} ]]; then
            [[ "$SUPPRESS_HEADERS" != true ]] && echo "" && echo -e "${CYAN}${BOLD}${line}${RESET}"
            OUTPUT_LINES+=("$line")
            continue
        fi

        # Other comment lines → preserve and display as context
        if [[ "$line" =~ ^# ]]; then
            [[ "$SUPPRESS_HEADERS" != true ]] && echo -e "${DIM}${line}${RESET}"
            OUTPUT_LINES+=("$line")
            continue
        fi

        # Variable lines: KEY=VALUE
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
            KEY="${BASH_REMATCH[1]}"
            RAW_VALUE="${BASH_REMATCH[2]}"

            # Reserved: dropped rather than preserved, so the only line setting
            # it is the managed block's. `hosting check` warns (E05).
            case "$KEY" in "$ENV_RESERVED_PREFIX"*) continue ;; esac

            # Check if existing .env has this var
            EXISTING_VALUE="${EXISTING[$KEY]:-}"
            HAS_EXISTING=false
            if [[ -n "$EXISTING_VALUE" || ${EXISTING[$KEY]+isset} ]]; then
                HAS_EXISTING=true
            fi

            # Update mode: auto-accept existing values without prompting
            if [[ "$UPDATE_ONLY" == true && "$HAS_EXISTING" == true ]]; then
                OUTPUT_LINES+=("${KEY}=${EXISTING_VALUE}")
                continue
            fi

            # Determine prompt type from the first two characters of the value.
            if [[ "${RAW_VALUE:0:2}" == "! " ]]; then
                # Type 4: command generator
                CMD="${RAW_VALUE#! }"
                if [[ "$HAS_EXISTING" == true ]]; then
                    DEFAULT="$EXISTING_VALUE"
                    if [[ "$KEY" =~ PASSWORD|SECRET|KEY ]]; then DISPLAY_CURRENT="****"; else DISPLAY_CURRENT="$DEFAULT"; fi
                    echo -ne "${BOLD}${KEY}${RESET} [${DISPLAY_CURRENT}] ${YELLOW}(auto)${RESET}: "
                else
                    DEFAULT=""
                    echo -ne "${BOLD}${KEY}${RESET} ${YELLOW}(auto)${RESET}: "
                fi

                _env_prompt_value

                if [[ -z "$VALUE" ]]; then
                    if [[ "$HAS_EXISTING" == true ]]; then
                        VALUE="$DEFAULT"
                    else
                        VALUE=$(eval "$CMD" || echo "")
                        echo -e "    ${GREEN}→ generated${RESET}"
                    fi
                fi

            elif [[ "${RAW_VALUE:0:2}" == "# " ]]; then
                # Type 3: hint
                HINT="${RAW_VALUE#\# }"
                if [[ "$HAS_EXISTING" == true ]]; then
                    if [[ "$KEY" =~ PASSWORD|SECRET|KEY ]]; then DISPLAY_CURRENT="****"; else DISPLAY_CURRENT="$EXISTING_VALUE"; fi
                    echo -ne "${BOLD}${KEY}${RESET} ${DIM}(${HINT})${RESET} [current: ${DISPLAY_CURRENT}]: "
                else
                    echo -ne "${BOLD}${KEY}${RESET} ${DIM}(${HINT})${RESET}: "
                fi

                _env_prompt_value

                if [[ -z "$VALUE" && "$HAS_EXISTING" == true ]]; then
                    VALUE="$EXISTING_VALUE"
                fi

            elif [[ "$RAW_VALUE" == *" # "* ]]; then
                # Type 5: default with inline comment (VAR=value # comment)
                DEFAULT="${RAW_VALUE%% \# *}"
                COMMENT="${RAW_VALUE#* \# }"
                if [[ "$HAS_EXISTING" == true ]]; then
                    DEFAULT="$EXISTING_VALUE"
                fi

                if [[ "$KEY" =~ PASSWORD|SECRET|KEY ]]; then
                    DISPLAY="****"
                else
                    DISPLAY="$DEFAULT"
                fi

                echo -ne "${BOLD}${KEY}${RESET} [${DISPLAY}] ${DIM}(${COMMENT})${RESET}: "

                _env_prompt_value

                if [[ -z "$VALUE" ]]; then
                    VALUE="$DEFAULT"
                fi

            elif [[ -z "$RAW_VALUE" ]]; then
                # Type 1: empty
                if [[ "$HAS_EXISTING" == true ]]; then
                    echo -ne "${BOLD}${KEY}${RESET} [current: ${EXISTING_VALUE}]: "
                else
                    echo -ne "${BOLD}${KEY}${RESET}: "
                fi

                _env_prompt_value

                if [[ -z "$VALUE" && "$HAS_EXISTING" == true ]]; then
                    VALUE="$EXISTING_VALUE"
                fi

            else
                # Type 2: has default value
                DEFAULT="$RAW_VALUE"
                if [[ "$HAS_EXISTING" == true ]]; then
                    DEFAULT="$EXISTING_VALUE"
                fi

                # Mask display for sensitive vars
                if [[ "$KEY" =~ PASSWORD|SECRET|KEY ]]; then
                    DISPLAY="****"
                else
                    DISPLAY="$DEFAULT"
                fi

                echo -ne "${BOLD}${KEY}${RESET} [${DISPLAY}]: "

                _env_prompt_value

                if [[ -z "$VALUE" ]]; then
                    VALUE="$DEFAULT"
                fi
            fi

            # Escape $ as $$ for Docker Compose compatibility
            ESCAPED_VALUE="${VALUE//\$/\$\$}"
            OUTPUT_LINES+=("${KEY}=${ESCAPED_VALUE}")
        else
            # Unknown line format — preserve as-is
            OUTPUT_LINES+=("$line")
        fi
    done 3< "$EXAMPLE"

    # -----------------------------------------------------------------------
    # Write .env
    # -----------------------------------------------------------------------
    echo ""
    printf '%s\n' "${OUTPUT_LINES[@]}" > "$OUTPUT"
    echo -e "${GREEN}${BOLD}==> .env written to ${OUTPUT}${RESET}"
    return 0
}

# ---------------------------------------------------------------------------
# Drift — shared by `hosting check` (E02/E03) and the deploy path
# ---------------------------------------------------------------------------

# env_extract_keys FILE — every assignment's key, one per line, in file order.
# A missing or key-less file comes back empty with status 0: under pipefail a
# `grep` finding nothing would tip the caller's `var=$(…)` instead.
env_extract_keys() {
    local f="$1" line
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done < "$f"
    return 0
}

# _env_drift_keys FILE — sorted, deduplicated, reserved keys removed.
_env_drift_keys() {
    local key keys
    keys="$(env_extract_keys "$1")"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case "$key" in "$ENV_RESERVED_PREFIX"*) continue ;; esac
        printf '%s\n' "$key"
    done <<<"$keys" | sort -u
    return 0
}

# env_drift TEMPLATE ENVFILE — sets ENV_DRIFT_MISSING (keys the template has
# and the .env lacks) and ENV_DRIFT_EXTRA (the reverse), each a space-separated
# list, empty when in sync. Values are never compared: a user may legitimately
# keep a default verbatim.
#
# Always returns 0. Signalling drift through the exit status would put the one
# call every caller makes on the left of `||`, which switches errexit off for
# this whole function — read the two variables instead.
env_drift() {
    local template_keys env_keys missing extra
    template_keys="$(_env_drift_keys "$1")"
    env_keys="$(_env_drift_keys "$2")"
    missing="$(comm -23 <(printf '%s\n' "$template_keys") <(printf '%s\n' "$env_keys"))"
    extra="$(comm -13 <(printf '%s\n' "$template_keys") <(printf '%s\n' "$env_keys"))"
    ENV_DRIFT_MISSING="${missing//$'\n'/ }"
    ENV_DRIFT_EXTRA="${extra//$'\n'/ }"
}

# ---------------------------------------------------------------------------
# HOSTING_* injection
# ---------------------------------------------------------------------------

# _env_line_sets_reserved LINE — true when Compose would read the line as
# assigning a reserved key. Compose trims leading blanks and honours an
# `export ` prefix, so both shapes are strays; a `#` comment is not.
_env_line_sets_reserved() {
    [[ "${1%$'\r'}" =~ ^[[:space:]]*(export[[:space:]]+)?${ENV_RESERVED_PREFIX}[A-Za-z0-9_]*= ]]
}

# env_inject_hosting_vars ENVFILE HOSTING_KEY=VALUE... — writes the managed
# block, creating ENVFILE if it does not exist, and runs *after* env_setup_run,
# which rebuilds .env from a template holding no reserved keys. Values go
# through unchanged: the marker's spelling (`14.4`, `54g`) is the contract, not
# this function's to reformat or validate.
#
# Every other line survives byte-for-byte in its original order, except lines
# Compose would read as setting a reserved key, which are removed — the last
# assignment wins, so a stray outside the block silently outranks the marker.
env_inject_hosting_vars() {
    local envfile="$1"; shift
    local pair
    for pair in "$@"; do
        [[ "$pair" =~ ^${ENV_RESERVED_PREFIX}[A-Za-z0-9_]*= ]] && continue
        echo "ERROR: env_inject_hosting_vars: '${pair}' is not a ${ENV_RESERVED_PREFIX}NAME=value pair"
        return 1
    done

    # A symlinked .env is written through: renaming over the link would leave a
    # regular file in its place and orphan the target with stale content.
    local target="$envfile"
    if [ -L "$envfile" ]; then
        target=$(readlink -f -- "$envfile") || {
            echo "ERROR: env_inject_hosting_vars: cannot resolve '${envfile}'"
            return 1
        }
    fi

    local -a lines=() kept=()
    local line
    if [ -f "$target" ]; then
        if [ ! -r "$target" ]; then
            echo "ERROR: env_inject_hosting_vars: cannot read '${target}'"
            return 1
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            lines+=("$line")
        done < "$target"
    fi

    # Every managed block collapses into one, rewritten where the first began.
    # A begin sentinel with no end after it is not a block, only a position:
    # running it to EOF would swallow the tail of a half-written file.
    local i j k n=${#lines[@]}
    local -a in_block=()
    for ((i = 0; i < n; i++)); do in_block+=(0); done
    for ((i = 0; i < n; i++)); do
        [ "${lines[i]%$'\r'}" = "$ENV_MANAGED_BEGIN" ] || continue
        for ((j = i + 1; j < n; j++)); do
            [ "${lines[j]%$'\r'}" = "$ENV_MANAGED_END" ] && break
        done
        [ "$j" -eq "$n" ] && j=$i
        for ((k = i; k <= j; k++)); do in_block[k]=1; done
        i=$j
    done

    local at=-1
    for ((i = 0; i < n; i++)); do
        if [ "${in_block[i]}" = 1 ]; then
            [ "$at" -lt 0 ] && at=${#kept[@]}
            continue
        fi
        if _env_line_sets_reserved "${lines[i]}"; then continue; fi
        kept+=("${lines[i]}")
    done
    [ "$at" -lt 0 ] && at=${#kept[@]}

    # A .env this created holds secrets and starts 600; one that already exists
    # keeps its mode. `chmod --reference` is GNU-only, and failing it falls back
    # to that 600 by design. Ownership is deliberately not copied: on the VPS
    # the deploy user running injection already owns the file.
    local tmp="${target}.hosting-inject.$$"
    # Whether the path is usable is the next line's verdict, not this one's:
    # `rm -f` still fails on a directory, and must not abort the caller.
    rm -f "$tmp" 2>/dev/null || true
    if ! (umask 077; : > "$tmp") 2>/dev/null; then
        echo "ERROR: env_inject_hosting_vars: cannot write beside '${target}'"
        return 1
    fi
    if [ -f "$target" ]; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
    fi
    # The temp lives in the tree `deploy` rsyncs, so no failure may leave it.
    if ! {
        if [ "$at" -gt 0 ]; then printf '%s\n' "${kept[@]:0:$at}"; fi
        printf '%s\n' "$ENV_MANAGED_BEGIN"
        if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
        printf '%s\n' "$ENV_MANAGED_END"
        if [ "${#kept[@]}" -gt "$at" ]; then printf '%s\n' "${kept[@]:$at}"; fi
    } > "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: env_inject_hosting_vars: could not write '${target}'"
        return 1
    fi
    # Renamed, never copied: a reader sees the whole old file or the whole new.
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        echo "ERROR: env_inject_hosting_vars: could not replace '${target}'"
        return 1
    fi
}

# Entry point for the executed case. Arguments pass straight through to the
# interactive setup, so the shipped scripts/setup-env.sh keeps the original's
# `[target_dir]` calling convention and its exit codes. The call is bare on
# purpose: wrapping it in `|| rc=$?` would switch errexit off for the whole of
# env_setup_run, and a failed `read` there has to abort exactly as it does in
# the standalone original.
env_main() {
    env_setup_run "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    env_main "$@"
fi
