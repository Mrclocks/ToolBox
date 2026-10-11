#!/usr/bin/env bash
# Module: SSH port change + hardening
# Keeps the old port open until the user confirms from a new terminal.
# shellcheck shell=bash

SSH_DROPIN_NAME="00-securebox.conf"
SSH_DROPIN_PATH="/etc/ssh/sshd_config.d/${SSH_DROPIN_NAME}"
# Legacy drop-in from older releases
SSH_DROPIN_LEGACY="/etc/ssh/sshd_config.d/99-securebox.conf"

_ssh_config_path() {
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo /etc/ssh/sshd_config
  else
    return 1
  fi
}

_ssh_current_port() {
  # Prefer live listening ports, then effective sshd -T, then config files
  local p
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    if is_port "$p"; then
      echo "$p"
      return 0
    fi
  fi

  if have_cmd ss; then
    p="$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | head -n1)"
    if [[ -n "$p" ]]; then
      if [[ "$p" == \[*\]* ]]; then
        p="${p##*]:}"
      else
        p="${p##*:}"
      fi
      if is_port "$p"; then
        echo "$p"
        return 0
      fi
    fi
  fi

  if have_cmd sshd || [[ -x /usr/sbin/sshd ]]; then
    local sshd_bin="${SSH_BIN:-sshd}"
    have_cmd sshd || sshd_bin=/usr/sbin/sshd
    p="$("$sshd_bin" -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    if is_port "$p"; then
      echo "$p"
      return 0
    fi
  fi

  local conf
  conf="$(_ssh_config_path)" || { echo 22; return; }
  p="$(awk 'BEGIN{p=22} /^[Pp]ort /{p=$2; exit} END{print p}' "$conf")"
  # Drop-ins: OpenSSH uses first value wins — sort so 00- comes first
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    local f dp
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [[ -f "$f" ]] || continue
      dp="$(awk '/^[Pp]ort /{print $2; exit}' "$f")"
      if [[ -n "$dp" ]]; then
        p="$dp"
        break
      fi
    done
  fi
  echo "${p:-22}"
}

_ssh_socket_active() {
  have_cmd systemctl || return 1
  systemctl is-active --quiet ssh.socket 2>/dev/null \
    || systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

_ssh_write_socket_dropin() {
  local -a ports=("$@")
  local dir="/etc/systemd/system/ssh.socket.d"
  mkdir -p "$dir"
  local dropin="${dir}/00-securebox.conf"
  backup_file "$dropin"
  {
    echo "# Managed by MrClock ${SECUREBOX_VERSION}"
    echo "[Socket]"
    # Clear packaged ListenStream then set ours
    echo "ListenStream="
    local p
    for p in "${ports[@]}"; do
      echo "ListenStream=${p}"
    done
  } >"$dropin"
  systemctl daemon-reload >/dev/null 2>&1 || true
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

  if _ssh_socket_active; then
    systemctl restart ssh.socket >/dev/null 2>&1 || true
    # Also ensure ssh.service is fine for Accept=no style
    systemctl try-reload-or-restart ssh >/dev/null 2>&1 \
      || systemctl try-reload-or-restart sshd >/dev/null 2>&1 || true
    return 0
  fi

  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh || systemctl restart ssh || return 1
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd || systemctl restart sshd || return 1
  else
    service ssh reload 2>/dev/null || service ssh restart 2>/dev/null \
      || service sshd reload 2>/dev/null || service sshd restart 2>/dev/null || {
        log WARN "sshd config OK but service reload unavailable"
        return 0
      }
  fi
}

_ssh_verify_ports_listening() {
  local -a want=("$@")
  local p found=0 missing=()
  for p in "${want[@]}"; do
    if have_cmd ss && ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|])${p}$"; then
      found=$((found + 1))
    else
      missing+=("$p")
    fi
  done
  if ((${#missing[@]})); then
    ui_warn "SSH ports not observed listening yet: ${missing[*]}"
    return 1
  fi
  return 0
}

_ssh_warn_conflicts() {
  local dropin="$1"
  have_cmd sshd || [[ -x /usr/sbin/sshd ]] || return 0
  local sshd_bin=sshd
  have_cmd sshd || sshd_bin=/usr/sbin/sshd

  local effective_port effective_pw
  effective_port="$("$sshd_bin" -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  effective_pw="$("$sshd_bin" -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')"

  ui_info "sshd -T effective: port=${effective_port:-?} PasswordAuthentication=${effective_pw:-?}"

  local f
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "$(basename "$dropin")" ]] && continue
    if grep -qE '^[Pp]ort |^PasswordAuthentication |^PermitRootLogin |^KbdInteractiveAuthentication ' "$f" 2>/dev/null; then
      # Lexicographic: earlier files win
      if [[ "$(basename "$f")" < "$(basename "$dropin")" ]]; then
        ui_warn "Conflict: $(basename "$f") sorts BEFORE $(basename "$dropin") — its Port/auth settings win."
      else
        ui_warn "Note: $(basename "$f") also sets SSH options (our $(basename "$dropin") takes precedence)."
      fi
    fi
  done
}

_ssh_login_user() {
  local u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == "root" ]]; then
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      # Prefer the user who owns the sshd session
      u="$(who am i 2>/dev/null | awk '{print $1}')"
    fi
  fi
  if [[ -z "$u" ]]; then
    u="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "$u" ]]; then
    u="${USER:-root}"
  fi
  printf '%s\n' "$u"
}

_ssh_user_has_usable_key() {
  # True if the login user has an authorized_keys entry without forced command=
  local user home keys
  user="$(_ssh_login_user)"
  if [[ "$user" == "root" ]]; then
    home="/root"
  else
    home="$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}')"
    [[ -n "$home" ]] || home="/home/${user}"
  fi
  keys="${home}/.ssh/authorized_keys"
  [[ -s "$keys" ]] || return 1
  # Usable = at least one line that is not a comment and has no command="..."
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /command="/ {next}
    /command=/ {next}
    {found=1; exit}
    END {exit found?0:1}
  ' "$keys"
}

_ssh_write_dropin() {
  local dropin="$1"
  local current="$2"
  local new_port="$3"
  local finalize="${4:-0}"
  local harden_password="${SECUREBOX_ANSWERS[ssh_password_auth]:-keep}"
  local permit_root="${SECUREBOX_ANSWERS[ssh_permit_root]:-keep}"
  local max_auth="${SECUREBOX_ANSWERS[ssh_max_auth_tries]:-5}"
  is_uint "$max_auth" || max_auth=5

  {
    echo "# Managed by MrClock ${SECUREBOX_VERSION} (${SECUREBOX_RUN_ID})"
    if [[ "$finalize" == "1" ]]; then
      echo "Port ${new_port}"
    elif [[ "$new_port" != "$current" ]]; then
      # Dual-port cutover: listen on BOTH until confirmed
      echo "Port ${current}"
      echo "Port ${new_port}"
    else
      echo "Port ${current}"
    fi
    echo "MaxAuthTries ${max_auth}"
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
      *) : ;;
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
}

_ssh_rollback_files() {
  local conf="$1"
  local dropin="$2"
  local run="${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}"
  ui_error "sshd config test/reload failed — restoring backup"
  if [[ -f "${run}${dropin}" ]]; then
    cp -a "${run}${dropin}" "$dropin" 2>/dev/null || rm -f "$dropin"
  else
    rm -f "$dropin"
  fi
  if [[ -f "${run}${conf}" ]]; then
    cp -a "${run}${conf}" "$conf" 2>/dev/null || true
  fi
  # Restore socket drop-in if we changed it
  local sock="/etc/systemd/system/ssh.socket.d/00-securebox.conf"
  if [[ -f "${run}${sock}" ]]; then
    cp -a "${run}${sock}" "$sock" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif [[ -f "$sock" ]] && [[ ! -f "${run}${sock}" ]]; then
    # Was marked REMOVE (new file)
    rm -f "$sock"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  _ssh_reload || true
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
  # Honor pending cutover: do not silently drop the old port on re-run
  if [[ -f "${SECUREBOX_STATE_DIR}/ssh_cutover" && "$(cat "${SECUREBOX_STATE_DIR}/ssh_cutover" 2>/dev/null)" == "pending" ]]; then
    current="$(cat "${SECUREBOX_STATE_DIR}/ssh_old_port" 2>/dev/null || _ssh_current_port)"
    new_port="$(cat "${SECUREBOX_STATE_DIR}/ssh_new_port" 2>/dev/null || echo "${SECUREBOX_ANSWERS[ssh_port]:-$current}")"
    ui_warn "Pending SSH cutover detected — keeping dual-port state (${current} + ${new_port})"
  else
    current="$(_ssh_current_port)"
    new_port="${SECUREBOX_ANSWERS[ssh_port]:-$current}"
  fi
  SECUREBOX_ANSWERS[ssh_current_port]="$current"

  # Password auth guard: only disable if login user has a usable key
  if [[ "${SECUREBOX_ANSWERS[ssh_password_auth]:-}" == "no" ]]; then
    if ! _ssh_user_has_usable_key; then
      ui_warn "Refusing to disable password auth — user '$(_ssh_login_user)' has no usable SSH key (ignoring forced-command keys)."
      SECUREBOX_ANSWERS["ssh_password_auth"]=keep
    fi
  fi

  backup_file "$conf"
  mkdir -p /etc/ssh/sshd_config.d
  chmod 700 "${SECUREBOX_BACKUP_ROOT}" 2>/dev/null || true

  local dropin="$SSH_DROPIN_PATH"
  # Migrate legacy 99- drop-in → 00- (first value wins)
  if [[ -f "$SSH_DROPIN_LEGACY" && ! -f "$dropin" ]]; then
    backup_file "$SSH_DROPIN_LEGACY"
    mv -f "$SSH_DROPIN_LEGACY" "$dropin"
  elif [[ -f "$SSH_DROPIN_LEGACY" ]]; then
    backup_file "$SSH_DROPIN_LEGACY"
    rm -f "$SSH_DROPIN_LEGACY"
  fi
  backup_file "$dropin"

  if is_true "${SECUREBOX_DRY_RUN:-0}"; then
    ui_info "[dry-run] Would write ${dropin} (port ${current}→${new_port})"
    module_ok "ssh"
    return 0
  fi

  _ssh_write_dropin "$dropin" "$current" "$new_port" 0

  # Comment conflicting Port lines in main config to avoid surprises
  if grep -qE '^[Pp]ort ' "$conf"; then
    sed -i -E 's/^[Pp]ort /#Port /' "$conf" || true
  fi

  # Ubuntu 24.04+ socket activation
  if _ssh_socket_active; then
    ui_info "ssh.socket is active — updating socket ListenStream drop-in"
    if [[ "$new_port" != "$current" ]]; then
      _ssh_write_socket_dropin "$current" "$new_port"
    else
      _ssh_write_socket_dropin "$current"
    fi
  fi

  if ! _ssh_reload; then
    _ssh_rollback_files "$conf" "$dropin"
    module_fail "ssh" "sshd reload failed; changes reverted (sshd_config + drop-in)"
    confirm_continue_on_error "ssh" "sshd reload failed" || return 1
    return 0
  fi

  _ssh_warn_conflicts "$dropin"

  # Ensure UFW allows both if ufw already active
  if have_cmd ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${current}/tcp" comment 'MrClock SSH current' >/dev/null 2>&1 || true
    ufw allow "${new_port}/tcp" comment 'MrClock SSH new' >/dev/null 2>&1 || true
  fi

  if [[ "$new_port" != "$current" ]]; then
    _ssh_verify_ports_listening "$current" "$new_port" || true
    ui_warn "SSH now listens on BOTH :${current} (old) and :${new_port} (new)."
    ui_info "Open a NEW terminal and verify:  ssh -p ${new_port} USER@HOST"
    ui_info "Keep this session open until the new login works."
    mkdir -p "$SECUREBOX_STATE_DIR"
    echo "$current" >"${SECUREBOX_STATE_DIR}/ssh_old_port"
    echo "$new_port" >"${SECUREBOX_STATE_DIR}/ssh_new_port"
    echo "pending" >"${SECUREBOX_STATE_DIR}/ssh_cutover"

    # Timed auto-rollback unless confirmed
    local rollback_secs="${SECUREBOX_ANSWERS[ssh_rollback_seconds]:-${SECUREBOX_ROLLBACK_SECONDS:-120}}"
    if have_cmd systemd-run && is_uint "$rollback_secs" && (( rollback_secs > 0 )); then
      ui_warn "Auto-rollback armed: SSH config reverts in ${rollback_secs}s unless you confirm."
      if declare -F schedule_timed_rollback >/dev/null 2>&1; then
        schedule_timed_rollback "ssh" "$rollback_secs" || true
      fi
    fi

    if have_tty && is_true "${SECUREBOX_ANSWERS[ssh_wait_confirm]:-yes}"; then
      if ui_confirm "Have you successfully logged in on port ${new_port} from a NEW terminal?" "N"; then
        _ssh_write_dropin "$dropin" "$current" "$new_port" 1
        if _ssh_socket_active; then
          _ssh_write_socket_dropin "$new_port"
        fi
        if _ssh_reload; then
          if have_cmd ufw; then
            ufw delete allow "${current}/tcp" >/dev/null 2>&1 || true
            ufw allow "${new_port}/tcp" comment 'MrClock SSH' >/dev/null 2>&1 || true
          fi
          echo "done" >"${SECUREBOX_STATE_DIR}/ssh_cutover"
          if declare -F cancel_timed_rollback >/dev/null 2>&1; then
            cancel_timed_rollback "ssh" || true
          fi
          ui_success "SSH cutover complete — only port ${new_port} remains"
          _ssh_verify_ports_listening "$new_port" || true
        else
          ui_warn "Final cutover reload failed; both ports still active"
        fi
      else
        ui_warn "Leaving BOTH SSH ports active. Re-run SSH module later to finalize."
      fi
    fi
  else
    ui_info "SSH port unchanged (${current}); hardening applied"
    _ssh_verify_ports_listening "$current" || true
  fi

  module_ok "ssh"
  ui_success "SSH configuration updated"
}
