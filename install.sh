#!/usr/bin/env bash
# =============================================================================
# MrClock ToolBox — VPN Hardening & Optimization
# Ubuntu 22–26 · Debian 12–13
# =============================================================================
# One-liner (always latest release — no version pin needed):
#   curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash
# After first install, re-run anytime without network:
#   sudo mrclock
# =============================================================================
set -o pipefail

SECUREBOX_REPO="${SECUREBOX_REPO:-Mrclocks/ToolBox}"
# "latest" resolves to the newest GitHub Release tag automatically
SECUREBOX_REF="${SECUREBOX_REF:-latest}"
SECUREBOX_INSTALL_DIR="${SECUREBOX_INSTALL_DIR:-/opt/mrclock-toolbox}"
SECUREBOX_BIN_LINK="${SECUREBOX_BIN_LINK:-/usr/local/bin/mrclock}"

# --- Bootstrap: local install first, then one-liner fetch ---
_securebox_have_tree() {
  local root="$1"
  [[ -f "${root}/lib/common.sh" && -f "${root}/lib/runner.sh" && -d "${root}/modules" && -d "${root}/data" ]]
}

_securebox_resolve_ref() {
  local ref="${1:-${SECUREBOX_REF:-latest}}"
  if [[ "$ref" != "latest" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi

  local api tag
  api="https://api.github.com/repos/${SECUREBOX_REPO}/releases/latest"
  tag="$(curl -fsSL --connect-timeout 15 "$api" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1)"

  # Fallback: newest release including pre-releases
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    api="https://api.github.com/repos/${SECUREBOX_REPO}/releases?per_page=5"
    tag="$(curl -fsSL --connect-timeout 15 "$api" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1)"
  fi

  if [[ -z "$tag" || "$tag" == "null" ]]; then
    echo "[MrClock] ERROR: could not resolve latest release tag." >&2
    return 1
  fi
  printf '%s\n' "$tag"
}

_securebox_install_persistent() {
  local src="$1"
  [[ -n "$src" ]] && _securebox_have_tree "$src" || return 1
  mkdir -p "$SECUREBOX_INSTALL_DIR"
  # Copy tree (portable; no rsync required)
  rm -rf "${SECUREBOX_INSTALL_DIR:?}/lib" "${SECUREBOX_INSTALL_DIR}/modules" "${SECUREBOX_INSTALL_DIR}/data" 2>/dev/null || true
  cp -a "${src}/lib" "${src}/modules" "${src}/data" "$SECUREBOX_INSTALL_DIR/"
  cp -a "${src}/install.sh" "$SECUREBOX_INSTALL_DIR/install.sh"
  [[ -f "${src}/VERSION" ]] && cp -a "${src}/VERSION" "$SECUREBOX_INSTALL_DIR/VERSION" || true
  [[ -f "${src}/LICENSE" ]] && cp -a "${src}/LICENSE" "$SECUREBOX_INSTALL_DIR/LICENSE" || true
  [[ -f "${src}/README.md" ]] && cp -a "${src}/README.md" "$SECUREBOX_INSTALL_DIR/README.md" || true
  chmod 755 "$SECUREBOX_INSTALL_DIR/install.sh"
  mkdir -p "$(dirname "$SECUREBOX_BIN_LINK")"
  cat >"$SECUREBOX_BIN_LINK" <<EOF
#!/usr/bin/env bash
exec bash "${SECUREBOX_INSTALL_DIR}/install.sh" "\$@"
EOF
  chmod 755 "$SECUREBOX_BIN_LINK"
  echo "[MrClock] Installed to ${SECUREBOX_INSTALL_DIR} (command: mrclock)" >&2
}

_securebox_fetch_tree() {
  local tmp archive url resolved
  resolved="$(_securebox_resolve_ref "${SECUREBOX_REF}")" || exit 1
  SECUREBOX_REF="$resolved"
  export SECUREBOX_REF

  tmp="$(mktemp -d /tmp/securebox-fetch.XXXXXX)"
  archive="${tmp}/securebox.tgz"

  url="https://github.com/${SECUREBOX_REPO}/archive/refs/tags/${SECUREBOX_REF}.tar.gz"
  echo "[MrClock] Downloading ${SECUREBOX_REPO}@${SECUREBOX_REF} (latest) ..." >&2
  if ! curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 2 "$url" -o "$archive"; then
    url="https://codeload.github.com/${SECUREBOX_REPO}/tar.gz/refs/tags/${SECUREBOX_REF}"
    curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 2 "$url" -o "$archive" || {
      echo "[MrClock] ERROR: failed to download release archive." >&2
      echo "[MrClock] Tip: if this is a re-run, try:  sudo mrclock" >&2
      rm -rf "$tmp"
      exit 1
    }
  fi

  tar -xzf "$archive" -C "$tmp" || {
    echo "[MrClock] ERROR: failed to extract archive." >&2
    rm -rf "$tmp"
    exit 1
  }

  local extracted
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'ToolBox-*' | head -n1)"
  if [[ -z "$extracted" ]] || ! _securebox_have_tree "$extracted"; then
    echo "[MrClock] ERROR: archive layout unexpected." >&2
    rm -rf "$tmp"
    exit 1
  fi

  printf '%s\n' "$extracted"
}

_securebox_bootstrap() {
  local candidate=""

  # 1) Running from a full checkout / persistent install
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if _securebox_have_tree "$candidate"; then
      SECUREBOX_ROOT="$candidate"
      # Keep persistent copy fresh when running from a newer tree
      if [[ "$candidate" != "$SECUREBOX_INSTALL_DIR" ]]; then
        _securebox_install_persistent "$candidate" 2>/dev/null || true
      fi
      return 0
    fi
  fi

  # 2) Prefer previously installed local copy (works even if GitHub is unreachable)
  if _securebox_have_tree "$SECUREBOX_INSTALL_DIR"; then
    SECUREBOX_ROOT="$SECUREBOX_INSTALL_DIR"
    if [[ "${SECUREBOX_BOOTSTRAPPED:-0}" != "1" ]]; then
      export SECUREBOX_BOOTSTRAPPED=1
      export SECUREBOX_ROOT
      echo "[MrClock] Using local install: ${SECUREBOX_INSTALL_DIR}" >&2
      exec bash "${SECUREBOX_INSTALL_DIR}/install.sh" "$@"
    fi
    return 0
  fi

  if [[ -n "${SECUREBOX_ROOT:-}" ]] && _securebox_have_tree "$SECUREBOX_ROOT"; then
    return 0
  fi

  if [[ "${SECUREBOX_BOOTSTRAPPED:-0}" == "1" ]]; then
    echo "[MrClock] ERROR: bootstrap loop detected." >&2
    exit 1
  fi

  # 3) First-time / one-liner: fetch release, install persistently, re-exec
  local extracted
  extracted="$(_securebox_fetch_tree)"
  _securebox_install_persistent "$extracted" || true
  export SECUREBOX_BOOTSTRAPPED=1
  export SECUREBOX_ROOT="${SECUREBOX_INSTALL_DIR}"
  if ! _securebox_have_tree "$SECUREBOX_ROOT"; then
    SECUREBOX_ROOT="$extracted"
  fi
  echo "[MrClock] Starting from ${SECUREBOX_ROOT}" >&2
  exec bash "${SECUREBOX_ROOT}/install.sh" "$@"
}

_securebox_bootstrap "$@"

# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/ui.sh"
# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/os.sh"
# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/net.sh"
# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/questions.sh"
# shellcheck disable=SC1091
source "${SECUREBOX_ROOT}/lib/runner.sh"

source_modules
usage() {
  cat <<EOF
${SECUREBOX_NAME} v${SECUREBOX_VERSION}

Usage: sudo bash install.sh [options]

Options:
  --one-click          Non-interactive Apply All with safe defaults
  --ssh-port <port>    SSH port for --one-click
  --disable-ipv6       Disable IPv6 in --one-click
  --mtu <value>        MTU for --one-click (or 'keep')
  --dns <id>           cloudflare|google|quad9|opendns|adguard|keep
  --no-abuse-block     Skip abuse CIDR blocking
  --no-ufw             Prepare rules but do not enable UFW
  --help               Show this help

Interactive mode (default): menu with Apply All + individual features.
EOF
}

defaults_one_click() {
  detect_network_stack
  detect_dns_manager
  questionnaire_common_safety
  SECUREBOX_ANSWERS[continue_on_error]=yes
  # Conservative one-click: only core safe steps unless flags opt in
  SECUREBOX_ANSWERS[do_update]=yes
  SECUREBOX_ANSWERS[do_timesync]=yes
  SECUREBOX_ANSWERS[do_bbr]=yes
  SECUREBOX_ANSWERS[do_ssh]=no
  SECUREBOX_ANSWERS[dns_choice]=6
  SECUREBOX_ANSWERS[dns_id]=keep
  SECUREBOX_ANSWERS[mtu]=keep
  SECUREBOX_ANSWERS[ssh_current_port]="$(_ssh_current_port)"
  SECUREBOX_ANSWERS[ssh_port]="${SECUREBOX_CLI_SSH_PORT:-${SECUREBOX_ANSWERS[ssh_current_port]}}"
  if [[ -n "${SECUREBOX_CLI_SSH_PORT:-}" ]]; then
    SECUREBOX_ANSWERS[do_ssh]=yes
  fi
  SECUREBOX_ANSWERS[ssh_wait_confirm]=no
  SECUREBOX_ANSWERS[ssh_password_auth]=keep
  SECUREBOX_ANSWERS[ssh_permit_root]=keep
  SECUREBOX_ANSWERS[disable_ipv6]="${SECUREBOX_CLI_DISABLE_IPV6:-no}"
  SECUREBOX_ANSWERS[block_abuse]="${SECUREBOX_CLI_BLOCK_ABUSE:-no}"
  SECUREBOX_ANSWERS[ufw_enable]="${SECUREBOX_CLI_UFW_ENABLE:-no}"
  SECUREBOX_ANSWERS[ufw_auto_discover]=no
  SECUREBOX_ANSWERS[ufw_ports]=""
  SECUREBOX_ANSWERS[ufw_reset]=no
  SECUREBOX_ANSWERS[enable_fail2ban]="${SECUREBOX_CLI_FAIL2BAN:-no}"
  SECUREBOX_ANSWERS[unattended]="${SECUREBOX_CLI_UNATTENDED:-no}"
  SECUREBOX_ANSWERS[unattended_reboot]=no
  SECUREBOX_ANSWERS[disable_unused]=no
  SECUREBOX_ANSWERS[disable_snapd]=no
  SECUREBOX_ANSWERS[f2b_bantime]=1h
  SECUREBOX_ANSWERS[f2b_findtime]=10m
  SECUREBOX_ANSWERS[f2b_maxretry]=4
  if [[ -n "${SECUREBOX_CLI_MTU:-}" ]]; then
    SECUREBOX_ANSWERS[mtu]="$SECUREBOX_CLI_MTU"
  fi
  if [[ -n "${SECUREBOX_CLI_DNS:-}" ]]; then
    case "$SECUREBOX_CLI_DNS" in
      cloudflare) SECUREBOX_ANSWERS[dns_choice]=1; SECUREBOX_ANSWERS[dns_id]=cloudflare; SECUREBOX_ANSWERS[dns_primary]=1.1.1.1; SECUREBOX_ANSWERS[dns_secondary]=1.0.0.1 ;;
      google) SECUREBOX_ANSWERS[dns_choice]=2; SECUREBOX_ANSWERS[dns_id]=google; SECUREBOX_ANSWERS[dns_primary]=8.8.8.8; SECUREBOX_ANSWERS[dns_secondary]=8.8.4.4 ;;
      quad9) SECUREBOX_ANSWERS[dns_choice]=3; SECUREBOX_ANSWERS[dns_id]=quad9; SECUREBOX_ANSWERS[dns_primary]=9.9.9.9; SECUREBOX_ANSWERS[dns_secondary]=149.112.112.112 ;;
      opendns) SECUREBOX_ANSWERS[dns_choice]=4; SECUREBOX_ANSWERS[dns_id]=opendns; SECUREBOX_ANSWERS[dns_primary]=208.67.222.222; SECUREBOX_ANSWERS[dns_secondary]=208.67.220.220 ;;
      adguard) SECUREBOX_ANSWERS[dns_choice]=5; SECUREBOX_ANSWERS[dns_id]=adguard; SECUREBOX_ANSWERS[dns_primary]=94.140.14.14; SECUREBOX_ANSWERS[dns_secondary]=94.140.15.15 ;;
      keep) SECUREBOX_ANSWERS[dns_choice]=6; SECUREBOX_ANSWERS[dns_id]=keep ;;
    esac
  fi
}

parse_args() {
  SECUREBOX_MODE=menu
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --one-click) SECUREBOX_MODE=one_click; shift ;;
      --ssh-port) SECUREBOX_CLI_SSH_PORT="$2"; shift 2 ;;
      --disable-ipv6) SECUREBOX_CLI_DISABLE_IPV6=yes; shift ;;
      --mtu) SECUREBOX_CLI_MTU="$2"; shift 2 ;;
      --dns) SECUREBOX_CLI_DNS="$2"; shift 2 ;;
      --no-abuse-block) SECUREBOX_CLI_BLOCK_ABUSE=no; shift ;;
      --block-abuse) SECUREBOX_CLI_BLOCK_ABUSE=yes; shift ;;
      --no-ufw) SECUREBOX_CLI_UFW_ENABLE=no; shift ;;
      --ufw) SECUREBOX_CLI_UFW_ENABLE=yes; shift ;;
      --fail2ban) SECUREBOX_CLI_FAIL2BAN=yes; shift ;;
      --unattended) SECUREBOX_CLI_UNATTENDED=yes; shift ;;
      --help|-h) usage; exit 0 ;;
      *) ui_error "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

menu_loop() {
  while true; do
    # Full-screen clean draw: banner + menu only
    ui_banner
    printf '%sMain menu%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    ui_line 56
    printf '  %s 1)%s Apply All Features\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s System Update & Upgrade\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Time Sync (chrony)\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s DNS Resolver\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 5)%s MTU Tuning\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 6)%s BBR + Network Tuning\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 7)%s Abuse IP Range Block\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 8)%s UFW Autopilot\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 9)%s SSH Port & Hardening\n' "$C_ORANGE" "$C_RESET"
    printf '  %s10)%s Fail2Ban\n' "$C_ORANGE" "$C_RESET"
    printf '  %s11)%s IPv6 Disable\n' "$C_ORANGE" "$C_RESET"
    printf '  %s12)%s Unattended Upgrades\n' "$C_ORANGE" "$C_RESET"
    printf '  %s13)%s Disable Unused Services\n' "$C_ORANGE" "$C_RESET"
    printf '  %s14)%s Show Status Report\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 0)%s Exit\n' "$C_YELLOW" "$C_RESET"
    ui_line 56
    local choice
    printf '%sSelect%s: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-0}")"

    case "$choice" in
      1)
        ui_clear
        if questionnaire_all; then
          run_pipeline_all
          ui_pause
        else
          ui_pause
        fi
        ;;
      2)
        ui_clear
        questionnaire_update_only && run_single update && run_single report
        ui_pause
        ;;
      3)
        ui_clear
        questionnaire_common_safety
        if ui_confirm "Enable chrony time sync?" "Y"; then
          SECUREBOX_ANSWERS[do_timesync]=yes
          run_single timesync && run_single report
        fi
        ui_pause
        ;;
      4)
        ui_clear
        questionnaire_dns_only && run_single dns && run_single report
        ui_pause
        ;;
      5)
        ui_clear
        questionnaire_mtu_only && run_single mtu && run_single report
        ui_pause
        ;;
      6)
        ui_clear
        questionnaire_bbr_only && run_single bbr && run_single report
        ui_pause
        ;;
      7)
        ui_clear
        questionnaire_abuse_only && run_single abuse && run_single report
        ui_pause
        ;;
      8)
        ui_clear
        questionnaire_ufw_only && run_single ufw && run_single report
        ui_pause
        ;;
      9)
        ui_clear
        questionnaire_ssh_only && run_single ssh && run_single report
        ui_pause
        ;;
      10)
        ui_clear
        questionnaire_fail2ban_only && run_single fail2ban && run_single report
        ui_pause
        ;;
      11)
        ui_clear
        questionnaire_ipv6_only && run_single ipv6 && run_single report
        ui_pause
        ;;
      12)
        ui_clear
        questionnaire_unattended_only && run_single unattended && run_single report
        ui_pause
        ;;
      13)
        ui_clear
        questionnaire_services_only && run_single services && run_single report
        ui_pause
        ;;
      14)
        ui_clear
        run_single report
        ui_pause
        ;;
      0|q|Q|exit)
        ui_info "Goodbye."
        exit 0
        ;;
      *)
        ui_warn "Invalid selection."
        sleep 1
        ;;
    esac
  done
}

main() {
  require_root
  parse_args "$@"
  assert_supported_os
  detect_network_stack
  detect_dns_manager

  # Auto-heal outbound abuse blocks from older betas so re-runs / updates work
  if declare -F _abuse_repair_outbound >/dev/null 2>&1; then
    _abuse_repair_outbound
  fi

  # Ensure local launcher exists for next run without curl
  if _securebox_have_tree "${SECUREBOX_ROOT}"; then
    _securebox_install_persistent "${SECUREBOX_ROOT}" 2>/dev/null || true
  fi

  log INFO "MrClock toolbox ${SECUREBOX_VERSION} starting on ${OS_PRETTY}"

  case "$SECUREBOX_MODE" in
    one_click)
      ui_banner
      defaults_one_click
      review_answers
      run_pipeline_all
      ;;
    menu)
      menu_loop
      ;;
  esac
}

main "$@"
