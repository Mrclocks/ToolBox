#!/usr/bin/env bash
# MrClock / SecureBox — terminal UI
# shellcheck shell=bash

# Colors (safe when not a TTY) — orange theme
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[38;2;255;95;109m'
  C_GREEN=$'\033[38;2;80;250;123m'
  C_YELLOW=$'\033[38;2;255;184;108m'
  # Brand orange (replaces blue/cyan accents)
  C_ORANGE=$'\033[38;2;255;140;0m'
  C_BLUE=$'\033[38;2;255;140;0m'
  C_CYAN=$'\033[38;2;255;140;0m'
  C_MAGENTA=$'\033[38;2;255;160;40m'
  C_WHITE=$'\033[38;2;248;248;242m'
  C_GRAY=$'\033[38;2;120;130;150m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_ORANGE=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_WHITE=""; C_GRAY=""
fi

ui_clear() {
  # Hard clear scrollback + screen so only the next draw remains
  if [[ -t 1 ]]; then
    printf '\033[3J\033[2J\033[H' 2>/dev/null || true
    clear 2>/dev/null || true
  fi
  if [[ -w /dev/tty ]]; then
    printf '\033[3J\033[2J\033[H' >/dev/tty 2>/dev/null || true
  fi
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
  # Always refresh live facts before drawing header
  if declare -F detect_os >/dev/null 2>&1; then
    detect_os >/dev/null 2>&1 || true
  fi
  if declare -F detect_network_stack >/dev/null 2>&1; then
    detect_network_stack
  fi
  if declare -F detect_dns_manager >/dev/null 2>&1; then
    detect_dns_manager
  fi

  cat <<EOF
${C_ORANGE}${C_BOLD}
   ███╗   ███╗██████╗  ██████╗██╗      ██████╗  ██████╗██╗  ██╗
   ████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██╔════╝██║ ██╔╝
   ██╔████╔██║██████╔╝██║     ██║     ██║   ██║██║     █████╔╝
   ██║╚██╔╝██║██╔══██╗██║     ██║     ██║   ██║██║     ██╔═██╗
   ██║ ╚═╝ ██║██║  ██║╚██████╗███████╗╚██████╔╝╚██████╗██║  ██╗
   ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝
${C_RESET}${C_DIM}   VPN Hardening & Optimization Toolbox  ·  v${SECUREBOX_VERSION}${C_RESET}
EOF
  ui_line 72
  ui_server_status_panel
}

ui_server_status_panel() {
  local host iface mtu dns cc qdisc ssh_ports ufw_st ipv6_st f2b_st
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  iface="${NET_DEFAULT_IFACE:-unknown}"
  mtu="${NET_DEFAULT_MTU:-?}"
  if ((${#DNS_CURRENT[@]})); then
    dns="${DNS_CURRENT[*]}"
  else
    dns="(none)"
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
  ssh_ports="$(grep -hE '^[Pp]ort ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ssh_ports="$(echo "$ssh_ports" | sed 's/[[:space:]]*$//')"
  [[ -n "$ssh_ports" ]] || ssh_ports="22"

  if have_cmd ufw 2>/dev/null; then
    ufw_st="$(ufw status 2>/dev/null | head -n1 | sed 's/Status: //')"
  else
    ufw_st="n/a"
  fi
  if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]]; then
    ipv6_st="disabled"
  else
    ipv6_st="enabled"
  fi
  if have_cmd systemctl && systemctl is-active --quiet fail2ban 2>/dev/null; then
    f2b_st="active"
  else
    f2b_st="inactive"
  fi

  printf '   %sHost:%s %-28s %sKernel:%s %s\n' \
    "$C_GRAY" "$C_RESET" "$host" "$C_GRAY" "$C_RESET" "$(uname -r)"
  printf '   %sOS:%s   %s\n' "$C_GRAY" "$C_RESET" "${OS_PRETTY:-unknown}"
  printf '   %sNet:%s  iface=%s  mtu=%s  stack=%s\n' \
    "$C_GRAY" "$C_RESET" "$iface" "$mtu" "${NET_STACK:-unknown}"
  printf '   %sDNS:%s  %s (%s)\n' "$C_GRAY" "$C_RESET" "$dns" "${DNS_MANAGER:-unknown}"
  printf '   %sTCP:%s  %s + %s    %sSSH:%s %s\n' \
    "$C_GRAY" "$C_RESET" "$cc" "$qdisc" "$C_GRAY" "$C_RESET" "$ssh_ports"
  printf '   %sUFW:%s  %-12s %sIPv6:%s %-10s %sF2B:%s %s\n' \
    "$C_GRAY" "$C_RESET" "$ufw_st" "$C_GRAY" "$C_RESET" "$ipv6_st" "$C_GRAY" "$C_RESET" "$f2b_st"
  ui_line 72
}

ui_info()    { printf '%sℹ%s  %s\n' "$C_ORANGE" "$C_RESET" "$*"; log INFO "$*"; }
ui_success() { printf '%s✔%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; log INFO "$*"; }
ui_warn()    { printf '%s⚠%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; log WARN "$*"; }
ui_error()   { printf '%s✖%s  %s\n' "$C_RED" "$C_RESET" "$*"; log ERROR "$*"; }
ui_step()    { printf '\n%s▸ %s%s\n' "$C_ORANGE$C_BOLD" "$*" "$C_RESET"; log INFO "STEP: $*"; }

ui_kv() {
  printf '   %s%-22s%s %s\n' "$C_GRAY" "$1" "$C_RESET" "$2"
}

ui_read() {
  # Read a line from the real terminal when stdin is a pipe (curl|bash).
  local __dest="$1"
  local __line=""
  if [[ -t 0 ]]; then
    read -r __line || __line=""
  elif [[ -r /dev/tty ]]; then
    read -r __line </dev/tty || __line=""
  else
    read -r __line || __line=""
  fi
  printf -v "$__dest" '%s' "$__line"
}

ui_pause() {
  local msg="${1:-Press Enter to continue...}"
  if [[ -t 0 || -r /dev/tty ]]; then
    printf '%s%s%s' "$C_DIM" "$msg" "$C_RESET"
    local _
    ui_read _
  fi
}

ui_confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local hint ans
  if [[ "${default^^}" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '%s?%s %s [%s]: ' "$C_ORANGE" "$C_RESET" "$prompt" "$hint"
    ui_read ans
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
    printf '%s?%s %s [%s]: ' "$C_ORANGE" "$C_RESET" "$__prompt" "$__default"
  else
    printf '%s?%s %s: ' "$C_ORANGE" "$C_RESET" "$__prompt"
  fi
  ui_read __ans
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
  # IMPORTANT: do not name locals the same as result_var (printf -v would set local only).
  local __var="$1"
  local __title="$2"
  shift 2
  local -a __items=("$@")
  local __i __sel
  echo
  printf '%s%s%s\n' "$C_BOLD$C_ORANGE" "$__title" "$C_RESET"
  ui_line 56
  for __i in "${!__items[@]}"; do
    printf '  %s%2d)%s %s\n' "$C_ORANGE" "$((__i + 1))" "$C_RESET" "${__items[$__i]}"
  done
  ui_line 56
  while true; do
    printf '%sSelect%s [1-%d]: ' "$C_ORANGE" "$C_RESET" "${#__items[@]}"
    ui_read __sel
    __sel="$(trim "$__sel")"
    if is_uint "$__sel" && (( __sel >= 1 && __sel <= ${#__items[@]} )); then
      printf -v "$__var" '%s' "$__sel"
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
  printf '\r   %s[%s]%s %s/%s  %s' "$C_ORANGE" "$bar" "$C_RESET" "$current" "$total" "$label"
  [[ "$current" -eq "$total" ]] && printf '\n' || true
}

ui_box_start() {
  echo
  printf '%s┌─ %s%s\n' "$C_GRAY" "$1" "$C_RESET"
}

ui_box_end() {
  printf '%s└────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
}
