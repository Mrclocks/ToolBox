#!/usr/bin/env bash
# Module: IPv6 disable (optional, asked up-front)
# shellcheck shell=bash

_ipv6_ssh_session_is_v6() {
  # True if the current SSH session is over IPv6
  local peer=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    peer="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
  fi
  if [[ -z "$peer" && -n "${SSH_CLIENT:-}" ]]; then
    peer="$(awk '{print $1}' <<<"$SSH_CLIENT")"
  fi
  [[ -n "$peer" ]] || return 1
  # IPv6 addresses contain ':' (and are not IPv4-mapped only checks)
  [[ "$peer" == *:* ]]
}

module_ipv6() {
  ui_step "IPv6 policy"

  if ! require_answer_yes disable_ipv6 ipv6 "IPv6 disable not explicitly requested"; then
    module_skip "ipv6" "disable_ipv6='${SECUREBOX_ANSWERS[disable_ipv6]:-}' — left unchanged"
    return 0
  fi

  if is_dry_run; then
    if _ipv6_ssh_session_is_v6; then
      ui_warn "[dry-run] SSH is over IPv6 — live run would refuse/warn loudly"
    fi
    ui_info "[dry-run] Would disable IPv6 via sysctl drop-in (no GRUB edit)"
    module_ok "ipv6"
    return 0
  fi

  if _ipv6_ssh_session_is_v6; then
    ui_error "Current SSH session is over IPv6 — disabling IPv6 would lock you out."
    if have_tty; then
      if ! ui_confirm "Really disable IPv6 anyway? (NOT recommended)" "N"; then
        module_fail "ipv6" "refused: SSH session is IPv6"
        confirm_continue_on_error "ipv6" "SSH over IPv6 — skipped" || return 1
        return 0
      fi
      ui_warn "Proceeding despite IPv6 SSH session — keep this session open and verify IPv4 access."
    else
      module_fail "ipv6" "refused non-interactively: SSH session is IPv6"
      confirm_continue_on_error "ipv6" "SSH over IPv6 — skipped" || return 1
      return 0
    fi
  fi

  if disable_ipv6_persistent; then
    module_ok "ipv6"
    ui_success "IPv6 disabled via sysctl (+ UFW IPV6=no if present)"
    ui_warn "A reboot may be required for full IPv6 disable on all interfaces."
    SECUREBOX_ANSWERS["reboot_needed"]=yes
  else
    module_fail "ipv6" "failed to disable IPv6"
    confirm_continue_on_error "ipv6" "disable failed" || return 1
  fi
}
