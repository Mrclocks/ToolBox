#!/usr/bin/env bash
# Module: SSH port change + hardening
# Keeps the old port open until the user confirms from a new terminal.
# shellcheck shell=bash

_ssh_config_path() {
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo /etc/ssh/sshd_config
  else
    return 1
  fi
}

_ssh_current_port() {
  local conf
  conf="$(_ssh_config_path)" || { echo 22; return; }
  local p
  p="$(awk 'BEGIN{p=22} /^[Pp]ort /{p=$2} END{print p}' "$conf")"
  # Also check drop-ins
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [[ -f "$f" ]] || continue
      local dp
      dp="$(awk '/^[Pp]ort /{p=$2} END{print p}' "$f")"
      [[ -n "$dp" ]] && p="$dp"
    done
  fi
  echo "${p:-22}"
}

_ssh_reload() {
  # sshd requires this directory; missing on some minimal/container images
  mkdir -p /run/sshd
  chmod 755 /run/sshd 2>/dev/null || true

  if have_cmd sshd; then
    sshd -t || return 1
  elif [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -t || return 1
  fi
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh || systemctl restart ssh || return 1
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd || systemctl restart sshd || return 1
  else
    service ssh reload 2>/dev/null || service ssh restart 2>/dev/null \
      || service sshd reload 2>/dev/null || service sshd restart 2>/dev/null || {
        # Config validated; service may be unavailable in containers without systemd
        log WARN "sshd config OK but service reload unavailable"
        return 0
      }
  fi
}

module_ssh() {
  ui_step "SSH port & hardening"

  if ! require_answer_yes do_ssh ssh "SSH changes not explicitly enabled"; then
    module_skip "ssh" "do_ssh='${SECUREBOX_ANSWERS[do_ssh]:-}'"
    return 0
  fi

  local conf
  conf="$(_ssh_config_path)" || {
    module_fail "ssh" "sshd_config not found"
    confirm_continue_on_error "ssh" "sshd_config missing" || return 1
    return 0
  }

  local current new_port
  current="$(_ssh_current_port)"
  SECUREBOX_ANSWERS[ssh_current_port]="$current"
  new_port="${SECUREBOX_ANSWERS[ssh_port]:-$current}"

  backup_file "$conf"
  mkdir -p /etc/ssh/sshd_config.d
  local dropin="/etc/ssh/sshd_config.d/99-securebox.conf"
  backup_file "$dropin"

  local harden_password="${SECUREBOX_ANSWERS[ssh_password_auth]:-keep}"
  local permit_root="${SECUREBOX_ANSWERS[ssh_permit_root]:-keep}"

  {
    echo "# Managed by MrClock ${SECUREBOX_VERSION} (${SECUREBOX_RUN_ID})"
    if [[ "$new_port" != "$current" ]]; then
      # Dual-port cutover: listen on BOTH until confirmed
      echo "Port ${current}"
      echo "Port ${new_port}"
    else
      echo "Port ${current}"
    fi
    echo "Protocol 2"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "X11Forwarding no"
    echo "PermitEmptyPasswords no"
    echo "ClientAliveInterval 60"
    echo "ClientAliveCountMax 3"
    echo "DebianBanner no"
    case "$permit_root" in
      no) echo "PermitRootLogin no" ;;
      prohibit-password) echo "PermitRootLogin prohibit-password" ;;
      yes) echo "PermitRootLogin yes" ;;
      *) : ;; # keep distro default for root
    esac
    case "$harden_password" in
      no)
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "ChallengeResponseAuthentication no"
        ;;
      yes)
        echo "PasswordAuthentication yes"
        ;;
      *) : ;;
    esac
  } >"$dropin"

  # Comment conflicting Port lines in main config to avoid surprises
  if grep -qE '^[Pp]ort ' "$conf"; then
    sed -i -E 's/^[Pp]ort /#Port /' "$conf" || true
  fi

  if ! _ssh_reload; then
    ui_error "sshd config test/reload failed — restoring backup"
    if [[ -f "${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}${dropin}" ]]; then
      cp -a "${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}${dropin}" "$dropin" 2>/dev/null || rm -f "$dropin"
    else
      rm -f "$dropin"
    fi
    _ssh_reload || true
    module_fail "ssh" "sshd reload failed; changes reverted"
    confirm_continue_on_error "ssh" "sshd reload failed" || return 1
    return 0
  fi

  # Ensure UFW allows both if ufw already active
  if have_cmd ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${current}/tcp" comment 'MrClock SSH current' >/dev/null 2>&1 || true
    ufw allow "${new_port}/tcp" comment 'MrClock SSH new' >/dev/null 2>&1 || true
  fi

  if [[ "$new_port" != "$current" ]]; then
    ui_warn "SSH now listens on BOTH :${current} (old) and :${new_port} (new)."
    ui_info "Open a NEW terminal and verify:  ssh -p ${new_port} USER@HOST"
    ui_info "Keep this session open until the new login works."
    echo "$current" >"${SECUREBOX_STATE_DIR}/ssh_old_port"
    echo "$new_port" >"${SECUREBOX_STATE_DIR}/ssh_new_port"
    echo "pending" >"${SECUREBOX_STATE_DIR}/ssh_cutover"

    if have_tty && is_true "${SECUREBOX_ANSWERS[ssh_wait_confirm]:-yes}"; then
      if ui_confirm "Have you successfully logged in on port ${new_port} from a NEW terminal?" "N"; then
        # Finalize: only new port
        {
          echo "# Managed by MrClock ${SECUREBOX_VERSION} (finalized)"
          echo "Port ${new_port}"
          echo "Protocol 2"
          echo "MaxAuthTries 3"
          echo "LoginGraceTime 30"
          echo "X11Forwarding no"
          echo "PermitEmptyPasswords no"
          echo "ClientAliveInterval 60"
          echo "ClientAliveCountMax 3"
          echo "DebianBanner no"
          case "$permit_root" in
            no) echo "PermitRootLogin no" ;;
            prohibit-password) echo "PermitRootLogin prohibit-password" ;;
            yes) echo "PermitRootLogin yes" ;;
          esac
          case "$harden_password" in
            no)
              echo "PasswordAuthentication no"
              echo "KbdInteractiveAuthentication no"
              echo "ChallengeResponseAuthentication no"
              ;;
            yes) echo "PasswordAuthentication yes" ;;
          esac
        } >"$dropin"
        if _ssh_reload; then
          if have_cmd ufw; then
            ufw delete allow "${current}/tcp" >/dev/null 2>&1 || true
            # delete by rule number is fragile; insert deny old only if user wants
            ufw allow "${new_port}/tcp" comment 'MrClock SSH' >/dev/null 2>&1 || true
          fi
          echo "done" >"${SECUREBOX_STATE_DIR}/ssh_cutover"
          ui_success "SSH cutover complete — only port ${new_port} remains"
        else
          ui_warn "Final cutover reload failed; both ports still active"
        fi
      else
        ui_warn "Leaving BOTH SSH ports active. Re-run SSH module later to finalize."
      fi
    fi
  else
    ui_info "SSH port unchanged (${current}); hardening applied"
  fi

  module_ok "ssh"
  ui_success "SSH configuration updated"
}
