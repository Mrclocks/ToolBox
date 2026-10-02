#!/usr/bin/env bash
# Module: abuse IP range blocking + basic anti-abuse posture
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
      # Skip overly broad /8 blocks for safety
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
  # Flush set then re-add
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

  # Chains (recreate rules idempotently)
  nft list chain inet securebox input >/dev/null 2>&1 \
    || nft add chain inet securebox input '{ type filter hook input priority -10; policy accept; }'
  nft list chain inet securebox output >/dev/null 2>&1 \
    || nft add chain inet securebox output '{ type filter hook output priority -10; policy accept; }'
  nft flush chain inet securebox input 2>/dev/null || true
  nft flush chain inet securebox output 2>/dev/null || true
  nft add rule inet securebox input ip saddr @abuse4 drop
  nft add rule inet securebox output ip daddr @abuse4 drop

  # Persist
  mkdir -p /etc/nftables.d
  nft list table inet securebox > /etc/nftables.d/securebox-abuse.nft
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
  # Create dedicated chains
  iptables -N SECUREBOX_ABUSE 2>/dev/null || iptables -F SECUREBOX_ABUSE
  iptables -D INPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -D OUTPUT -j SECUREBOX_ABUSE 2>/dev/null || true
  iptables -I INPUT 1 -j SECUREBOX_ABUSE
  iptables -I OUTPUT 1 -j SECUREBOX_ABUSE

  local c
  for c in "${cidrs[@]}"; do
    iptables -A SECUREBOX_ABUSE -s "$c" -j DROP 2>/dev/null || true
    iptables -A SECUREBOX_ABUSE -d "$c" -j DROP 2>/dev/null || true
  done

  if have_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  fi
}

_abuse_harden_services() {
  # Reduce classic Hetzner abuse vectors: open relays / resolvers / unused mail
  for svc in postfix exim4 sendmail named bind9 pdns-recursor; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\."; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ui_warn "Stopping potentially abuse-prone service: ${svc}"
        service_disable_stop "$svc"
      fi
    fi
  done

  # Discourage SMTP open relay exposure via UFW later; here just sysctl/network posture
  if have_cmd ufw; then
    ufw deny 25/tcp >/dev/null 2>&1 || true
    ufw deny 1900/udp >/dev/null 2>&1 || true
    ufw deny 11211/tcp >/dev/null 2>&1 || true
  fi
}

module_abuse() {
  ui_step "Abuse IP range blocking + anti-abuse posture"

  if ! is_true "${SECUREBOX_ANSWERS[block_abuse]:-yes}"; then
    module_skip "abuse" "user declined abuse range blocking"
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

  ui_info "Loaded ${#CIDRS[@]} CIDR ranges from $(basename "$file")"
  _abuse_harden_services

  if ! _abuse_ensure_nft_or_iptables; then
    module_fail "abuse" "nft/iptables unavailable"
    confirm_continue_on_error "abuse" "no firewall backend for ranges" || return 1
    return 0
  fi

  ui_info "Applying blocklist via ${ABUSE_BACKEND}..."
  if [[ "$ABUSE_BACKEND" == "nft" ]]; then
    if _abuse_apply_nft "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked ${#CIDRS[@]} abuse CIDRs with nftables (in+out)"
    else
      module_fail "abuse" "nft apply failed"
      confirm_continue_on_error "abuse" "nft apply failed" || return 1
    fi
  else
    if _abuse_apply_iptables "${CIDRS[@]}"; then
      module_ok "abuse"
      ui_success "Blocked ${#CIDRS[@]} abuse CIDRs with iptables (in+out)"
    else
      module_fail "abuse" "iptables apply failed"
      confirm_continue_on_error "abuse" "iptables apply failed" || return 1
    fi
  fi
}
