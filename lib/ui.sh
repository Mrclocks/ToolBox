#!/usr/bin/env bash
# SecureBox — terminal UI
# shellcheck shell=bash

# Colors (safe when not a TTY)
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[38;2;255;95;109m'
  C_GREEN=$'\033[38;2;80;250;123m'
  C_YELLOW=$'\033[38;2;255;184;108m'
  C_BLUE=$'\033[38;2;94;196;255m'
  C_CYAN=$'\033[38;2;139;233;253m'
  C_MAGENTA=$'\033[38;2;188;154;255m'
  C_WHITE=$'\033[38;2;248;248;242m'
  C_GRAY=$'\033[38;2;120;130;150m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_WHITE=""; C_GRAY=""
fi

ui_clear() {
  [[ -t 1 ]] && clear || true
}

ui_line() {
  local width="${1:-64}"
  local char="${2:-─}"
  printf '%s' "$C_GRAY"
  printf '%*s' "$width" '' | tr ' ' "$char"
  printf '%s\n' "$C_RESET"
}

ui_banner() {
  ui_clear
  cat <<EOF
${C_CYAN}${C_BOLD}
   ███████╗███████╗ ██████╗██╗   ██╗██████╗ ███████╗██████╗  ██████╗ ██╗  ██╗
   ██╔════╝██╔════╝██╔════╝██║   ██║██╔══██╗██╔════╝██╔══██╗██╔═══██╗╚██╗██╔╝
   ███████╗█████╗  ██║     ██║   ██║██████╔╝█████╗  ██████╔╝██║   ██║ ╚███╔╝
   ╚════██║██╔══╝  ██║     ██║   ██║██╔══██╗██╔══╝  ██╔══██╗██║   ██║ ██╔██╗
   ███████║███████╗╚██████╗╚██████╔╝██║  ██║███████╗██████╔╝╚██████╔╝██╔╝ ██╗
   ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝
${C_RESET}${C_DIM}   VPN Hardening & Optimization Toolbox  ·  v${SECUREBOX_VERSION}${C_RESET}
EOF
  ui_line 72
  if [[ -n "${OS_PRETTY:-}" ]]; then
    printf '   %sHost:%s %s  %s·%s  %sKernel:%s %s\n' \
      "$C_GRAY" "$C_RESET" "$(hostname -f 2>/dev/null || hostname)" \
      "$C_GRAY" "$C_RESET" \
      "$C_GRAY" "$C_RESET" "$(uname -r)"
    printf '   %sOS:%s   %s\n' "$C_GRAY" "$C_RESET" "$OS_PRETTY"
    ui_line 72
  fi
}

ui_info()    { printf '%sℹ%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; log INFO "$*"; }
ui_success() { printf '%s✔%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; log INFO "$*"; }
ui_warn()    { printf '%s⚠%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; log WARN "$*"; }
ui_error()   { printf '%s✖%s  %s\n' "$C_RED" "$C_RESET" "$*"; log ERROR "$*"; }
ui_step()    { printf '\n%s▸ %s%s\n' "$C_MAGENTA$C_BOLD" "$*" "$C_RESET"; log INFO "STEP: $*"; }

ui_kv() {
  printf '   %s%-22s%s %s\n' "$C_GRAY" "$1" "$C_RESET" "$2"
}

ui_pause() {
  local msg="${1:-Press Enter to continue...}"
  if [[ -t 0 ]]; then
    printf '%s%s%s' "$C_DIM" "$msg" "$C_RESET"
    read -r _
  fi
}

ui_confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local hint
  if [[ "${default^^}" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '%s?%s %s [%s]: ' "$C_CYAN" "$C_RESET" "$prompt" "$hint"
    read -r ans || ans=""
    ans="$(trim "${ans:-}")"
    if [[ -z "$ans" ]]; then
      [[ "${default^^}" == "Y" ]] && return 0 || return 1
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) ui_warn "Please answer y or n." ;;
    esac
  done
}

ui_ask() {
  # ui_ask VAR prompt [default]
  local __var="$1"
  local __prompt="$2"
  local __default="${3-}"
  local __ans
  if [[ -n "$__default" ]]; then
    printf '%s?%s %s [%s]: ' "$C_CYAN" "$C_RESET" "$__prompt" "$__default"
  else
    printf '%s?%s %s: ' "$C_CYAN" "$C_RESET" "$__prompt"
  fi
  read -r __ans || __ans=""
  __ans="$(trim "${__ans:-}")"
  if [[ -z "$__ans" ]]; then
    __ans="$__default"
  fi
  printf -v "$__var" '%s' "$__ans"
}

ui_ask_port() {
  local __var="$1"
  local __prompt="$2"
  local __default="$3"
  local __ans
  while true; do
    ui_ask __ans "$__prompt" "$__default"
    if is_port "$__ans"; then
      printf -v "$__var" '%s' "$__ans"
      return 0
    fi
    ui_warn "Invalid port. Enter a number between 1 and 65535."
  done
}

ui_ask_mtu() {
  local __var="$1"
  local __prompt="$2"
  local __default="$3"
  local __ans
  while true; do
    ui_ask __ans "$__prompt" "$__default"
    if is_uint "$__ans" && (( __ans >= 1280 && __ans <= 9000 )); then
      printf -v "$__var" '%s' "$__ans"
      return 0
    fi
    ui_warn "Invalid MTU. Typical VPN-safe range: 1280–1500."
  done
}

ui_menu() {
  # ui_menu result_var title item1 item2 ...
  local __var="$1"
  local __title="$2"
  shift 2
  local -a __items=("$@")
  local i choice
  echo
  printf '%s%s%s\n' "$C_BOLD" "$__title" "$C_RESET"
  ui_line 56
  for i in "${!__items[@]}"; do
    printf '  %s%2d)%s %s\n' "$C_CYAN" "$((i + 1))" "$C_RESET" "${__items[$i]}"
  done
  ui_line 56
  while true; do
    printf '%sSelect%s [1-%d]: ' "$C_CYAN" "$C_RESET" "${#__items[@]}"
    read -r choice || choice=""
    choice="$(trim "$choice")"
    if is_uint "$choice" && (( choice >= 1 && choice <= ${#__items[@]} )); then
      printf -v "$__var" '%s' "$choice"
      return 0
    fi
    ui_warn "Enter a number between 1 and ${#__items[@]}."
  done
}

ui_progress() {
  local current="$1"
  local total="$2"
  local label="$3"
  local width=28
  local filled=0
  if (( total > 0 )); then
    filled=$(( current * width / total ))
  fi
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '█')"
  bar+="$(printf '%*s' "$((width - filled))" '' | tr ' ' '░')"
  printf '\r   %s[%s]%s %s/%s  %s' "$C_BLUE" "$bar" "$C_RESET" "$current" "$total" "$label"
  [[ "$current" -eq "$total" ]] && printf '\n' || true
}

ui_box_start() {
  echo
  printf '%s┌─ %s%s\n' "$C_GRAY" "$1" "$C_RESET"
}

ui_box_end() {
  printf '%s└────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
}
