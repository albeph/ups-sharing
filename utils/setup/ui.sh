#!/bin/bash
# =====================================================================
# SETUP UI & INTERACTIVE TUI MODULE (utils/setup/ui.sh)
# Provides interactive terminal components: arrow-key menus, styled
# text prompts, secret masking, and graceful non-interactive fallbacks.
# =====================================================================

# Styling constants
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# Cursor controls
cursor_hide() {
    tput civis 2>/dev/null || printf '\033[?25l'
}

cursor_show() {
    tput cnorm 2>/dev/null || printf '\033[?25h'
}

# Trap to restore cursor if user interrupts (Ctrl+C)
trap 'cursor_show' EXIT INT TERM

# ---------------------------------------------------------------------
# menu_select: Interactive arrow-key navigation with Enter confirmation
# ---------------------------------------------------------------------
# Usage:
#   menu_select "Choose an option:" RESULT_VAR "Option 1" "Option 2" "Option 3"
# Result:
#   RESULT_VAR receives the 0-based selected index
menu_select() {
    local prompt="$1"
    local out_var="$2"
    shift 2
    local -a options=("$@")
    local num_options=${#options[@]}
    local selected=0

    echo -e "${BOLD}${prompt}${RESET}"

    # Fallback for non-interactive environments (CI, pipes, non-TTY)
    if [ ! -t 0 ]; then
        for i in "${!options[@]}"; do
            echo "  $((i+1))) ${options[i]}"
        done
        echo -e "  ${GREEN}✔ Default selected: ${options[0]}${RESET}"
        eval "$out_var=0"
        return 0
    fi

    cursor_hide

    render_menu() {
        local cur=$1
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$cur" ]; then
                printf "\033[2K\r  ${CYAN}${BOLD}❯ %s${RESET}\n" "${options[i]}"
            else
                printf "\033[2K\r    ${DIM}%s${RESET}\n" "${options[i]}"
            fi
        done
    }

    render_menu "$selected"

    while true; do
        # Read escape sequence or single character
        IFS= read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            read -rsn2 -t 0.1 rest || rest=""
            key="$key$rest"
        fi

        case "$key" in
            $'\x1b[A'|[kK]) # Up arrow or vim 'k'
                selected=$(( (selected - 1 + num_options) % num_options ))
                printf "\033[%dA" "$num_options"
                render_menu "$selected"
                ;;
            $'\x1b[B'|[jJ]) # Down arrow or vim 'j'
                selected=$(( (selected + 1) % num_options ))
                printf "\033[%dA" "$num_options"
                render_menu "$selected"
                ;;
            "") # Enter key
                break
                ;;
            [1-9]) # Direct number selection
                local num=$((key - 1))
                if [ "$num" -lt "$num_options" ]; then
                    selected=$num
                    break
                fi
                ;;
        esac
    done

    # Clean up menu lines and print selected item
    printf "\033[%dA" "$num_options"
    for (( i=0; i<num_options; i++ )); do
        printf "\033[2K\r\033[1B"
    done
    printf "\033[%dA" "$num_options"
    printf "\033[2K\r  ${GREEN}${BOLD}✔ %s${RESET}\n\n" "${options[selected]}"

    cursor_show
    eval "$out_var=$selected"
}

# ---------------------------------------------------------------------
# prompt_text: Text input with default value
# ---------------------------------------------------------------------
# Usage:
#   prompt_text "Friendly name" RESULT_VAR "Home UPS"
prompt_text() {
    local label="$1"
    local out_var="$2"
    local default_val="$3"
    local input=""

    if [ -n "$default_val" ]; then
        read -rp "$(echo -e "${BOLD}${label}${RESET} [${default_val}]: ")" input
        input="${input:-$default_val}"
    else
        read -rp "$(echo -e "${BOLD}${label}${RESET}: ")" input
    fi
    eval "$out_var=\"\$input\""
}

# ---------------------------------------------------------------------
# prompt_secret: Masked silent password input
# ---------------------------------------------------------------------
# Usage:
#   prompt_secret "Enter password" RESULT_VAR "optional_default"
prompt_secret() {
    local label="$1"
    local out_var="$2"
    local default_val="${3:-}"
    local input=""

    read -rsp "$(echo -e "${BOLD}${label}${RESET}: ")" input
    echo ""

    if [ -z "$input" ] && [ -n "$default_val" ]; then
        echo -e "  ${YELLOW}⚠️  No password entered. Using temporary default.${RESET}"
        input="$default_val"
    fi
    eval "$out_var=\"\$input\""
}

# ---------------------------------------------------------------------
# prompt_confirm: Simple Yes/No prompt with default
# ---------------------------------------------------------------------
# Usage:
#   prompt_confirm "Is this your UPS device?" RESULT_VAR "Y"
prompt_confirm() {
    local label="$1"
    local out_var="$2"
    local default_yn="${3:-Y}"
    local input=""

    read -rp "$(echo -e "${BOLD}${label}${RESET} (Y/n) [${default_yn}]: ")" input
    input="${input:-$default_yn}"

    case "$input" in
        [yY]*) eval "$out_var=true" ;;
        *) eval "$out_var=false" ;;
    esac
}
