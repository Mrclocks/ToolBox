#!/usr/bin/env bash
# Module: DNS
# shellcheck shell=bash

# Preset catalog: id|label|primary|secondary
DNS_PRESETS=(
  "cloudflare|Cloudflare (1.1.1.1) - fast & private|1.1.1.1|1.0.0.1"
  "google|Google (8.8.8.8) - widely compatible|8.8.8.8|8.8.4.4"
  "quad9|Quad9 (9.9.9.9) - malware blocking|9.9.9.9|149.112.112.112"
  "opendns|OpenDNS (208.67.222.222)|208.67.222.222|208.67.220.220"
  "adguard|AdGuard (94.140.14.14) - ads/trackers|94.140.14.14|94.140.15.15"
  "keep|Keep current DNS||"
  "custom|Custom DNS servers (manual entry)||"
)

dns_preset_labels() {
  local p
  for p in "${DNS_PRESETS[@]}"; do
    IFS='|' read -r _ label _ _ <<<"$p"
    printf '%s\n' "$label"
  done
}

dns_resolve_choice() {
  # Sets DNS_PRIMARY DNS_SECONDARY DNS_CHOICE_ID from SECUREBOX_ANSWERS
  local idx="${SECUREBOX_ANSWERS[dns_choice]:-1}"
  local p="${DNS_PRESETS[$((idx - 1))]}"
  local id label primary secondary
  IFS='|' read -r id label primary secondary <<<"$p"
  DNS_CHOICE_ID="$id"

  # Prefer values already resolved during questionnaire
  if [[ -n "${SECUREBOX_ANSWERS[dns_primary]:-}" && "$id" != "keep" ]]; then
    DNS_PRIMARY="${SECUREBOX_ANSWERS[dns_primary]}"
    DNS_SECONDARY="${SECUREBOX_ANSWERS[dns_secondary]:-}"
    return 0
  fi

  case "$id" in
    keep)
      DNS_PRIMARY="${DNS_CURRENT[0]:-}"
      DNS_SECONDARY="${DNS_CURRENT[1]:-}"
      ;;
    custom)
      DNS_PRIMARY="${SECUREBOX_ANSWERS[dns_primary]}"
      DNS_SECONDARY="${SECUREBOX_ANSWERS[dns_secondary]:-}"
      ;;
    *)
      DNS_PRIMARY="$primary"
      DNS_SECONDARY="$secondary"
      SECUREBOX_ANSWERS[dns_primary]="$primary"
      SECUREBOX_ANSWERS[dns_secondary]="$secondary"
      ;;
  esac
}

module_dns() {
  ui_step "Configure DNS"
  detect_dns_manager
  dns_resolve_choice

  if [[ "$DNS_CHOICE_ID" == "keep" ]]; then
    module_skip "dns" "user kept current DNS"
    ui_info "DNS unchanged"
    return 0
  fi

  if ! is_ipv4 "$DNS_PRIMARY"; then
    module_fail "dns" "invalid primary DNS: ${DNS_PRIMARY}"
    confirm_continue_on_error "dns" "invalid primary DNS" || return 1
    return 0
  fi
  if [[ -n "$DNS_SECONDARY" ]] && ! is_ipv4 "$DNS_SECONDARY"; then
    module_fail "dns" "invalid secondary DNS: ${DNS_SECONDARY}"
    confirm_continue_on_error "dns" "invalid secondary DNS" || return 1
    return 0
  fi

  ui_info "DNS manager: ${DNS_MANAGER}"
  ui_info "Applying DNS: ${DNS_PRIMARY} ${DNS_SECONDARY}"

  if apply_dns_servers "$DNS_PRIMARY" "$DNS_SECONDARY"; then
    module_ok "dns"
    ui_success "DNS configured via ${DNS_MANAGER}"
  else
    module_fail "dns" "apply or resolve check failed"
    confirm_continue_on_error "dns" "DNS apply/resolve failed" || return 1
  fi
}
