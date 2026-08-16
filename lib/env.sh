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
# Dual-mode. Sourced as a library locally; the same bytes are rsynced to the
# VPS as scripts/setup-env.sh and executed there, where no other hosting file
# exists — so nothing here may source common.sh, read HOSTING_LIB_DIR, or call
# info/warn/err/die.
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
        while IFS= read -r line; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
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
        while IFS= read -r tline; do
            tline="${tline%$'\r'}"
            if [[ "$tline" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
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
    while IFS= read -r line <&3; do
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
