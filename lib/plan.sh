#!/usr/bin/env bash
# Preflight checks + Plan screen (dry-run / before execute)
# shellcheck shell=bash

preflight_checks() {
  ui_box_start "Preflight checks"
  local risk=low

  # SSH over IPv6?
  local peer=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    peer="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
  fi
  if [[ -n "$peer" && "$peer" == *:* ]]; then
    ui_warn "SSH session is over IPv6 — disabling IPv6 would lock you out"
    risk=high
  else
    ui_kv "SSH transport" "${peer:-unknown} (IPv4 or local)"
  fi

  # ssh.socket?
  if have_cmd systemctl && systemctl is-active --quiet ssh.socket 2>/dev/null; then
    ui_warn "ssh.socket is active (Ubuntu 24.04+ style) — port changes need socket drop-in"
    risk=medium
  else
    ui_kv "ssh.socket" "inactive / n/a"
  fi

  # Real SSH ports
  local ports
  ports="$(detect_live_ssh_ports 2>/dev/null | tr '\n' ' ')"
  ports="$(trim "$ports")"
  ui_kv "Live SSH ports" "${ports:-22}"

  # Listening services
  ui_info "Public listeners:"
  local line count=0
  while read -r line; do
    [[ -z "$line" ]] && continue
    printf '   %s\n' "$line"
    count=$((count + 1))
    (( count >= 12 )) && break
  done < <(discover_public_ports | awk '{print $2"/"$1}' | head -n 12)
  if (( count == 0 )); then
    printf '   %s\n' "(none discovered)"
  fi

  ui_kv "Risk level" "$risk"
  ui_box_end
  SECUREBOX_PREFLIGHT_RISK="$risk"
}

show_plan_screen() {
  preflight_checks
  echo
  ui_box_start "Plan — what will change"
  local -a rows=()
  local k v risk

  if answered_yes do_update; then
    rows+=("medium|System update (full-upgrade)")
  fi
  if answered_yes do_timesync; then
    rows+=("low|Enable chrony time sync")
  fi
  if [[ -n "${SECUREBOX_ANSWERS[dns_id]:-}" && "${SECUREBOX_ANSWERS[dns_id]}" != "keep" ]]; then
    rows+=("medium|DNS → ${SECUREBOX_ANSWERS[dns_primary]:-} ${SECUREBOX_ANSWERS[dns_secondary]:-}")
  else
    rows+=("low|DNS kept")
  fi
  if [[ -n "${SECUREBOX_ANSWERS[mtu]:-}" && "${SECUREBOX_ANSWERS[mtu]}" != "keep" ]]; then
    rows+=("medium|MTU → ${SECUREBOX_ANSWERS[mtu]}")
  elif answered_yes mtu_mss_clamp; then
    rows+=("medium|TCP MSS clamping (MTU unchanged)")
  else
    rows+=("low|MTU kept")
  fi
  if answered_yes do_bbr; then
    rows+=("low|BBR + sysctl tuning")
  fi
  if answered_yes do_ssh; then
    rows+=("high|SSH port ${SECUREBOX_ANSWERS[ssh_current_port]:-?} → ${SECUREBOX_ANSWERS[ssh_port]:-?} / harden")
  fi
  if answered_yes disable_ipv6; then
    rows+=("high|Disable IPv6")
  fi
  if answered_yes block_abuse; then
    rows+=("high|Abuse block (${SECUREBOX_ANSWERS[abuse_profile]:-minimal})")
  fi
  if answered_yes ufw_enable; then
    local ufw_extra="ports=${SECUREBOX_ANSWERS[ufw_ports]:-none}"
    answered_yes ufw_reset && ufw_extra="${ufw_extra}; RESET"
    answered_yes ufw_auto_discover && ufw_extra="${ufw_extra}; discover"
    rows+=("high|Enable UFW (${ufw_extra})")
  fi
  if answered_yes enable_fail2ban; then
    rows+=("low|Fail2Ban for SSH")
  fi
  if answered_yes unattended; then
    rows+=("low|Unattended upgrades")
  fi
  if answered_yes disable_unused; then
    rows+=("medium|Mask unused services")
  fi
  if answered_yes do_logs; then
    local log_bits="journal/rotated"
    answered_yes logs_truncate_active && log_bits="${log_bits}+truncate"
    answered_yes logs_docker_prune && log_bits="${log_bits}+docker-prune"
    rows+=("medium|Log cleanup (${log_bits})")
  fi

  local overall=low
  local row
  for row in "${rows[@]}"; do
    risk="${row%%|*}"
    v="${row#*|}"
    printf '   [%s] %s\n' "$risk" "$v"
    case "$risk" in
      high) overall=high ;;
      medium) [[ "$overall" != "high" ]] && overall=medium ;;
    esac
  done

  ui_kv "Overall risk" "$overall"
  if [[ "${SECUREBOX_DRY_RUN:-0}" == "1" ]]; then
    ui_warn "DRY-RUN — nothing will be applied"
  fi
  local rb="${SECUREBOX_ROLLBACK_SECONDS:-120}"
  if is_uint "$rb" && (( rb > 0 )); then
    ui_kv "Timed rollback" "${rb}s for SSH/UFW/DNS/MTU (unless confirmed)"
  else
    ui_kv "Timed rollback" "disabled"
  fi
  ui_box_end

  # Also show classic review
  review_answers
  return 0
}
