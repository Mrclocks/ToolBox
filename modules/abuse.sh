#!/usr/bin/env bash
# Module: abuse IP range blocking + anti-abuse posture
# Applies ONLY when SECUREBOX_ANSWERS[block_abuse] is explicitly yes.
# shellcheck shell=bash

ABUSE_RANGES_FILE="${SECUREBOX_DATA}/abuse-ranges.txt"
ABUSE_RANGES_AGGRESSIVE="${SECUREBOX_DATA}/abuse-ranges-aggressive.txt"

_abuse_load_cidrs() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      cidr=$1
      n=split(cidr, a, "/")
      if (n==2 && a[2]+0 <= 8) next
      print cidr
    }
  ' "$f"
}

_abuse_resolve_file() {
  local profile="${SECUREBOX_ANSWERS[abuse_profile]:-minimal}"
  local custom="${SECUREBOX_ANSWERS[abuse_file]:-}"
  if [[ -n "$custom" && -r "$custom" ]]; then
    printf '%s\n' "$custom"
    return 0
  fi
  case "${profile,,}" in
    aggressive)
      if [[ -r "$ABUSE_RANGES_AGGRESSIVE" ]]; then
        printf '%s\n' "$ABUSE_RANGES_AGGRESSIVE"
      else
        printf '%s\n' "$ABUSE_RANGES_FILE"
      fi
      ;;
    *)
      printf '%s\n' "$ABUSE_RANGES_FILE"
      ;;
  esac
}

_abuse_ensure_nft_or_iptables() {
  if have_cmd nft; then
    ABUSE_BACKEND=nft
  elif have_cmd iptables; then
    ABUSE_BACKEND=iptables
  else
    apt_install_safe iptables nftables >/dev/null 2>&1 || true
    if have_cmd nft; then
      ABUSE_BACKEND=nft
    elif have_cmd iptables; then
      ABUSE_BACKEND=iptables
    else
      ABUSE_BACKEND=""
      return 1
    fi
  fi
}

_abuse_apply_nft() {
  local -a cidrs=("$@")
  local loaded=0 failed=0

  nft list table inet securebox >/dev/null 2>&1 || nft add table inet securebox
  nft list set inet securebox abuse4 >/dev/null 2>&1 \
    || nft add set inet securebox abuse4 '{ type ipv4_addr; flags interval; auto-merge; }'
  nft flush set inet securebox abuse4 2>/dev/null || true

  local c chunk=()
  local i=0
  for c in "${cidrs[@]}"; do
    chunk+=("$c")
    ((i++))
    if (( i % 40 == 0 )); then
      if nft add element inet securebox abuse4 "{ $(IFS=,; echo "${chunk[*]}") }" 2>/dev/null; then
        loaded=$((loaded + ${#chunk[@]}))
      else
        # Retry one-by-one to count failures accurately
        local one
        for one in "${chunk[@]}"; do
          if nft add element inet securebox abuse4 "{ ${one} }" 2>/dev/null; then
            loaded=$((loaded + 1))
          else
            failed=$((failed + 1))
            log WARN "nft add element failed: $one"
          fi
        done
      fi
      chunk=()
    fi
  done
  if ((${#chunk[@]})); then
    if nft add element inet securebox abuse4 "{ $(IFS=,; echo "${chunk[*]}") }" 2>/dev/null; then
      loaded=$((loaded + ${#chunk[@]}))
    else
      local one
      for one in "${chunk[@]}"; do
        if nft add element inet securebox abuse4 "{ ${one} }" 2>/dev/null; then
          loaded=$((loaded + 1))
        else
          failed=$((failed + 1))
          log WARN "nft add element failed: $one"
        fi
      done
    fi
  fi

  nft list chain inet securebox input >/dev/null 2>&1 \
    || nft add chain inet securebox input '{ type filter hook input priority -10; policy accept; }'
  nft list chain inet securebox output >/dev/null 2>&1 \
    || nft add chain inet securebox output '{ type filter hook output priority -10; policy accept; }'
  nft flush chain inet securebox input 2>/dev/null || true
  nft flush chain inet securebox output 2>/dev/null || true

  # Allow replies to our outbound connections BEFORE dropping abuse sources
  nft add rule inet securebox input ct state established,related accept
  # Inbound only drop from abuse set
  nft add rule inet securebox input ip saddr @abuse4 drop

  mkdir -p /etc/nftables.d
  {
    echo '#!/usr/sbin/nft -f'
    echo '# Managed by MrClock — safe reload on boot'
    echo 'table inet securebox'
    echo 'delete table inet securebox'
    nft list table inet securebox
  } >/etc/nftables.d/securebox-abuse.nft
  if [[ -f /etc/nftables.conf ]]; then
    backup_file /etc/nftables.conf
    if ! grep -q 'securebox-abuse.nft' /etc/nftables.conf; then
      echo 'include "/etc/nftables.d/securebox-abuse.nft"' >>/etc/nftables.conf
    fi
    systemctl enable nftables >/dev/null 2>&1 || true
  fi

  ABUSE_LOADED="$loaded"
  ABUSE_FAILED="$failed"
  ui_info "nft elements: loaded=${loaded} failed=${failed}"
  (( failed == 0 || loaded > 0 ))
}

_abuse_apply_iptables() {
  local -a cidrs=("$@")
  local loaded=0 failed=0
  iptables -N SECUREBOX_ABUSE 2>/dev/null || iptables -F SECUREBOX_ABUSE
  iptables -D INPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -D OUTPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -I INPUT 1 -j SECUREBOX_ABUSE

  # Allow established/related before drops so outbound replies work
  iptables -A SECUREBOX_ABUSE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || iptables -A SECUREBOX_ABUSE -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || true

  local c
  for c in "${cidrs[@]}"; do
    if iptables -A SECUREBOX_ABUSE -s "$c" -j DROP 2>/dev/null; then
      loaded=$((loaded + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if have_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  fi

  ABUSE_LOADED="$loaded"
  ABUSE_FAILED="$failed"
  ui_info "iptables rules: loaded=${loaded} failed=${failed}"
  (( failed == 0 || loaded > 0 ))
}

_abuse_harden_services() {
  # WARN ONLY — never stop/mask mail or DNS (admin lockout / mail break risk)
  for svc in postfix exim4 sendmail named bind9 pdns-recursor; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\."; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ui_warn "Service '${svc}' is running and may be abuse-prone — not stopping (warn only)."
      fi
    fi
  done
  if have_cmd ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw deny 25/tcp >/dev/null 2>&1 || true
    ufw deny 1900/udp >/dev/null 2>&1 || true
    ufw deny 11211/tcp >/dev/null 2>&1 || true
  fi
}

# Fully remove toolbox abuse blocks
_abuse_remove_all() {
  if have_cmd nft; then
    nft delete table inet securebox 2>/dev/null || true
    rm -f /etc/nftables.d/securebox-abuse.nft 2>/dev/null || true
  fi
  if have_cmd iptables; then
    iptables -D INPUT -j SECUREBOX_ABUSE 2>/dev/null || true
    iptables -D OUTPUT -j SECUREBOX_ABUSE 2>/dev/null || true
    iptables -F SECUREBOX_ABUSE 2>/dev/null || true
    iptables -X SECUREBOX_ABUSE 2>/dev/null || true
    if have_cmd netfilter-persistent; then
      netfilter-persistent save >/dev/null 2>&1 || true
    elif [[ -d /etc/iptables ]]; then
      iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    fi
  fi
}

_abuse_is_active() {
  if have_cmd nft && nft list table inet securebox >/dev/null 2>&1; then
    return 0
  fi
  if have_cmd iptables && iptables -L SECUREBOX_ABUSE -n >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

_abuse_repair_outbound() {
  # Older betas dropped OUTPUT — strip that without removing inbound blocks
  if have_cmd nft; then
    nft flush chain inet securebox output 2>/dev/null || true
  fi
  if have_cmd iptables; then
    iptables -D OUTPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  fi
}

module_abuse() {
  ui_step "Abuse IP range blocking"

  _abuse_repair_outbound

  # STRICT: never block unless user explicitly said yes
  if ! require_answer_yes block_abuse abuse "user did not enable abuse IP blocking"; then
    if _abuse_is_active; then
      ui_warn "Abuse blocking answered NO, but previous MrClock abuse rules are still active."
      local remove=no
      if have_tty; then
        if ui_confirm "Remove previously enabled MrClock abuse rules?" "N"; then
          remove=yes
        fi
      else
        ui_info "Non-interactive: leaving existing abuse rules in place (will not delete without ask)."
      fi
      if [[ "$remove" == "yes" ]]; then
        ui_info "Removing previous MrClock abuse rules..."
        _abuse_remove_all
      else
        ui_info "Keeping existing abuse rules."
      fi
    else
      ui_info "Abuse blocking disabled — no active MrClock abuse rules."
    fi
    module_skip "abuse" "block_abuse!=yes (answer='${SECUREBOX_ANSWERS[block_abuse]:-}')"
    return 0
  fi

  local file
  file="$(_abuse_resolve_file)"
  if [[ ! -r "$file" ]]; then
    module_fail "abuse" "ranges file missing: $file"
    confirm_continue_on_error "abuse" "missing abuse ranges file" || return 1
    return 0
  fi

  mapfile -t CIDRS < <(_abuse_load_cidrs "$file")
  if ((${#CIDRS[@]} == 0)); then
    module_fail "abuse" "no usable CIDRs loaded"
    confirm_continue_on_error "abuse" "empty CIDR list" || return 1
    return 0
  fi

  local profile="${SECUREBOX_ANSWERS[abuse_profile]:-minimal}"
  ui_info "Loaded ${#CIDRS[@]} CIDR ranges from $(basename "$file") [profile=${profile}]"
  _abuse_harden_services

  if ! _abuse_ensure_nft_or_iptables; then
    module_fail "abuse" "nft/iptables unavailable"
    confirm_continue_on_error "abuse" "no firewall backend for ranges" || return 1
    return 0
  fi

  if is_dry_run; then
    ui_info "[dry-run] Would apply ${#CIDRS[@]} abuse CIDRs via ${ABUSE_BACKEND} (with established/related accept)"
    module_ok "abuse"
    return 0
  fi

  ui_info "Applying inbound blocklist via ${ABUSE_BACKEND} (established/related allowed)..."
  ABUSE_LOADED=0
  ABUSE_FAILED=0
  if [[ "$ABUSE_BACKEND" == "nft" ]]; then
    if _abuse_apply_nft "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked abuse CIDRs with nftables (loaded=${ABUSE_LOADED} failed=${ABUSE_FAILED})"
    else
      module_fail "abuse" "nft apply failed (loaded=${ABUSE_LOADED} failed=${ABUSE_FAILED})"
      confirm_continue_on_error "abuse" "nft apply failed" || return 1
    fi
  else
    if _abuse_apply_iptables "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked abuse CIDRs with iptables (loaded=${ABUSE_LOADED} failed=${ABUSE_FAILED})"
    else
      module_fail "abuse" "iptables apply failed (loaded=${ABUSE_LOADED} failed=${ABUSE_FAILED})"
      confirm_continue_on_error "abuse" "iptables apply failed" || return 1
    fi
  fi
}
