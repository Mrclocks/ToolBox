#!/usr/bin/env bash
# Module: system update
# shellcheck shell=bash

module_update() {
  ui_step "System update & upgrade"
  if ! require_answer_yes do_update update "system update not explicitly enabled"; then
    module_skip "update" "do_update='${PGCTB_ANSWERS[do_update]:-}'"
    return 0
  fi
  if is_dry_run; then
    local dverb="full-upgrade"
    [[ "${PGCTB_ANSWERS[update_mode]:-full}" == "safe" ]] && dverb="upgrade"
    ui_info "[dry-run] Would run apt-get update && apt-get ${dverb} (hold Docker: $([[ "${PGCTB_ANSWERS[update_docker]:-yes}" == no ]] && echo yes || echo no))"
    module_ok "update"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive

  if ! apt_update_safe; then
    module_fail "update" "apt-get update failed"
    confirm_continue_on_error "update" "apt-get update failed" || return 1
    return 0
  fi

  # safe = apt-get upgrade (never removes packages); full = full-upgrade
  local verb="full-upgrade"
  [[ "${PGCTB_ANSWERS[update_mode]:-full}" == "safe" ]] && verb="upgrade"

  # Hold Docker unless explicitly allowed: a Docker upgrade restarts every
  # container (PasarGuard panel/node → users disconnected).
  local -a held=()
  if [[ "${PGCTB_ANSWERS[update_docker]:-yes}" == "no" ]]; then
    mapfile -t held < <(_update_hold_docker)
    ((${#held[@]})) && ui_info "Holding during upgrade: ${held[*]}"
  fi

  local rc=0
  retry_cmd 2 5 apt-get -y -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" "$verb" || rc=$?
  _update_unhold "${held[@]}"
  if (( rc != 0 )); then
    module_fail "update" "${verb} failed"
    confirm_continue_on_error "update" "${verb} failed" || return 1
    return 0
  fi

  apt-get -y autoremove --purge >/dev/null 2>&1 || true
  apt-get -y autoclean >/dev/null 2>&1 || true

  if [[ -f /var/run/reboot-required ]]; then
    ui_warn "A reboot is required to finish kernel/package upgrades."
    PGCTB_ANSWERS["reboot_needed"]=yes
  fi

  module_ok "update"
  ui_success "System packages updated"
}

_update_hold_docker() {
  # Prints the packages it newly put on hold (never touches existing holds)
  local p
  local -a pkgs=(docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker.io containerd)
  local holds
  holds="$(apt-mark showhold 2>/dev/null || true)"
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || continue
    grep -qx "$p" <<<"$holds" && continue
    apt-mark hold "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
  done
}

_update_unhold() {
  (($#)) || return 0
  apt-mark unhold "$@" >/dev/null 2>&1 || ui_warn "Could not unhold: $* (run: apt-mark unhold $*)"
}
