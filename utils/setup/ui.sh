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

on_interrupt() {
    cursor_show
    echo ""
    echo -e "  ${YELLOW}Setup cancelled by user.${RESET}"
    echo ""
    exit 130
}

on_terminate() {
    cursor_show
    echo ""
    exit 143
}

# Trap to restore cursor on normal exit, and cleanly terminate on Ctrl+C / SIGTERM
trap 'cursor_show' EXIT
trap 'on_interrupt' INT
trap 'on_terminate' TERM

# ---------------------------------------------------------------------
# print_step: Formatted step banner with clear visual separation
# ---------------------------------------------------------------------
print_step() {
    local step_num="$1"
    local title="$2"
    local subtitle="${3:-}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${BOLD}${CYAN}Step ${step_num}: ${title}${RESET}"
    if [ -n "$subtitle" ]; then
        echo -e "  ${DIM}${subtitle}${RESET}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ---------------------------------------------------------------------
# print_info: Formatted contextual note with breathing room
# ---------------------------------------------------------------------
print_info() {
    local msg="$1"
    echo -e "  ${CYAN}ℹ${RESET}  ${DIM}${msg}${RESET}\n"
}

# ---------------------------------------------------------------------
# menu_select: Interactive arrow-key navigation with Enter confirmation
# ---------------------------------------------------------------------
menu_select() {
    local prompt="$1"
    local out_var="$2"
    shift 2
    local -a options=("$@")
    local num_options=${#options[@]}
    local selected=0

    echo -e "  ${BOLD}${prompt}${RESET}\n"

    # Fallback for non-interactive environments (CI, pipes, non-TTY)
    if [ ! -t 0 ]; then
        for i in "${!options[@]}"; do
            echo "    $((i+1))) ${options[i]}"
        done
        echo -e "\n  ${GREEN}✔ Selected: ${options[0]}${RESET}\n"
        printf -v "$out_var" '%s' "0"
        return 0
    fi

    cursor_hide

    render_menu() {
        local cur=$1
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$cur" ]; then
                printf "\033[2K\r    ${CYAN}${BOLD}❯ %s${RESET}\n" "${options[i]}"
            else
                printf "\033[2K\r      ${DIM}%s${RESET}\n" "${options[i]}"
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
            $'\x03'|[qQ]) # Ctrl+C or 'q'
                on_interrupt
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
    printf "\033[2K\r  ${GREEN}${BOLD}✔ Selected: %s${RESET}\n\n" "${options[selected]}"

    cursor_show
    printf -v "$out_var" '%s' "$selected"
}

# ---------------------------------------------------------------------
# prompt_text: Text input with default value and clean spacing
# ---------------------------------------------------------------------
prompt_text() {
    local label="$1"
    local out_var="$2"
    local default_val="$3"
    local input=""

    if [ -n "$default_val" ]; then
        printf "  %b%s%b [%b%s%b]: " "${BOLD}" "$label" "${RESET}" "${CYAN}" "$default_val" "${RESET}"
    else
        printf "  %b%s%b: " "${BOLD}" "$label" "${RESET}"
    fi
    read -r input || true
    input="${input:-$default_val}"
    echo ""
    printf -v "$out_var" '%s' "$input"
}

# ---------------------------------------------------------------------
# prompt_secret: Masked silent password input with clean spacing
# ---------------------------------------------------------------------
prompt_secret() {
    local label="$1"
    local out_var="$2"
    local default_val="${3:-}"
    local input=""

    printf "  %b%s%b: " "${BOLD}" "$label" "${RESET}"
    read -rs input || true
    echo ""

    if [ -z "$input" ] && [ -n "$default_val" ]; then
        echo -e "  ${YELLOW}⚠️  No password entered. Using temporary default.${RESET}\n"
        input="$default_val"
    else
        echo ""
    fi
    printf -v "$out_var" '%s' "$input"
}

# ---------------------------------------------------------------------
# prompt_confirm: Simple Yes/No prompt with default and clean spacing
# ---------------------------------------------------------------------
prompt_confirm() {
    local label="$1"
    local out_var="$2"
    local default_yn="${3:-Y}"
    local input=""

    printf "  %b%s%b (Y/n) [%b%s%b]: " "${BOLD}" "$label" "${RESET}" "${CYAN}" "$default_yn" "${RESET}"
    read -r input || true
    echo ""
    input="${input:-$default_yn}"

    case "$input" in
        [yY]*) printf -v "$out_var" '%s' "true" ;;
        *) printf -v "$out_var" '%s' "false" ;;
    esac
}
