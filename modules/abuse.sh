#!/usr/bin/env bash
# Module: abuse IP range blocking + anti-abuse posture
# Applies ONLY when SECUREBOX_ANSWERS[block_abuse] is explicitly yes.
# shellcheck shell=bash

ABUSE_SET_NAME="securebox_abuse"
ABUSE_RANGES_FILE="${SECUREBOX_DATA}/abuse-ranges.txt"

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
      nft add element inet securebox abuse4 "{ $(IFS=,; echo "${chunk[*]}") }" 2>/dev/null || true
      chunk=()
    fi
  done
  if ((${#chunk[@]})); then
    nft add element inet securebox abuse4 "{ $(IFS=,; echo "${chunk[*]}") }" 2>/dev/null || true
  fi

  nft list chain inet securebox input >/dev/null 2>&1 \
    || nft add chain inet securebox input '{ type filter hook input priority -10; policy accept; }'
  nft list chain inet securebox output >/dev/null 2>&1 \
    || nft add chain inet securebox output '{ type filter hook output priority -10; policy accept; }'
  nft flush chain inet securebox input 2>/dev/null || true
  nft flush chain inet securebox output 2>/dev/null || true
  # Inbound only
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
}

_abuse_apply_iptables() {
  local -a cidrs=("$@")
  iptables -N SECUREBOX_ABUSE 2>/dev/null || iptables -F SECUREBOX_ABUSE
  iptables -D INPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -D OUTPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -I INPUT 1 -j SECUREBOX_ABUSE

  local c
  for c in "${cidrs[@]}"; do
    iptables -A SECUREBOX_ABUSE -s "$c" -j DROP 2>/dev/null || true
  done

  if have_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  fi
}

_abuse_harden_services() {
  for svc in postfix exim4 sendmail named bind9 pdns-recursor; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\."; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ui_warn "Stopping potentially abuse-prone service: ${svc}"
        service_disable_stop "$svc"
      fi
    fi
  done
  if have_cmd ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw deny 25/tcp >/dev/null 2>&1 || true
    ufw deny 1900/udp >/dev/null 2>&1 || true
    ufw deny 11211/tcp >/dev/null 2>&1 || true
  fi
}

# Fully remove toolbox abuse blocks (used when user answered NO)
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

_abuse_repair_outbound() {
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
    ui_info "Abuse blocking disabled by your answer — removing any previous MrClock abuse rules."
    _abuse_remove_all
    module_skip "abuse" "block_abuse!=yes (answer='${SECUREBOX_ANSWERS[block_abuse]:-}')"
    return 0
  fi

  local file="${SECUREBOX_ANSWERS[abuse_file]:-$ABUSE_RANGES_FILE}"
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

  ui_info "Loaded ${#CIDRS[@]} CIDR ranges from $(basename "$file") [explicitly enabled]"
  _abuse_harden_services

  if ! _abuse_ensure_nft_or_iptables; then
    module_fail "abuse" "nft/iptables unavailable"
    confirm_continue_on_error "abuse" "no firewall backend for ranges" || return 1
    return 0
  fi

  ui_info "Applying inbound blocklist via ${ABUSE_BACKEND}..."
  if [[ "$ABUSE_BACKEND" == "nft" ]]; then
    if _abuse_apply_nft "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked ${#CIDRS[@]} abuse CIDRs with nftables (inbound only)"
    else
      module_fail "abuse" "nft apply failed"
      confirm_continue_on_error "abuse" "nft apply failed" || return 1
    fi
  else
    if _abuse_apply_iptables "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked ${#CIDRS[@]} abuse CIDRs with iptables (inbound only)"
    else
      module_fail "abuse" "iptables apply failed"
      confirm_continue_on_error "abuse" "iptables apply failed" || return 1
    fi
  fi
}
