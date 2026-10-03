#!/usr/bin/env bash
# SecureBox — network path detection + SAFE apply helpers
# CRITICAL RULE: never write configs that redefine an interface's addressing
# (DHCP/static/gateway). MTU/DNS persistence must not steal the NIC.
# shellcheck shell=bash

NET_STACK=""          # netplan | networkd | networkmanager | ifupdown | unknown
NET_DEFAULT_IFACE=""
NET_DEFAULT_MTU=""
DNS_MANAGER=""        # systemd-resolved | NetworkManager | resolvconf | static-resolv | unknown
DNS_RESOLV_PATH="/etc/resolv.conf"
DNS_CURRENT=()
NETPLAN_FILE=""
NETWORKD_FILE=""

detect_network_stack() {
  NET_DEFAULT_IFACE="$(default_iface || true)"
  if [[ -n "$NET_DEFAULT_IFACE" ]]; then
    NET_DEFAULT_MTU="$(iface_mtu "$NET_DEFAULT_IFACE" || true)"
  fi

  if have_cmd netplan && [[ -d /etc/netplan ]] && compgen -G '/etc/netplan/*.yaml' >/dev/null 2>&1; then
    NET_STACK="netplan"
    NETPLAN_FILE="$(ls -1 /etc/netplan/*.yaml 2>/dev/null | head -n1)"
  elif have_cmd nmcli && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NET_STACK="networkmanager"
  elif [[ -d /etc/systemd/network ]] && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    NET_STACK="networkd"
    NETWORKD_FILE="$(ls -1 /etc/systemd/network/*.{network,netdev} 2>/dev/null | head -n1 || true)"
  elif [[ -f /etc/network/interfaces ]]; then
    NET_STACK="ifupdown"
  else
    NET_STACK="unknown"
  fi
}

detect_dns_manager() {
  DNS_CURRENT=()
  if [[ -L /etc/resolv.conf ]]; then
    DNS_RESOLV_PATH="$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)"
  else
    DNS_RESOLV_PATH="/etc/resolv.conf"
  fi

  if systemctl is-active --quiet systemd-resolved 2>/dev/null \
     || [[ -L /etc/resolv.conf && "$(readlink /etc/resolv.conf 2>/dev/null)" == *systemd* ]]; then
    DNS_MANAGER="systemd-resolved"
  elif have_cmd nmcli && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    DNS_MANAGER="NetworkManager"
  elif have_cmd resolvconf; then
    DNS_MANAGER="resolvconf"
  elif [[ -f /etc/resolv.conf ]]; then
    DNS_MANAGER="static-resolv"
  else
    DNS_MANAGER="unknown"
  fi

  if [[ -r /etc/resolv.conf ]]; then
    mapfile -t DNS_CURRENT < <(awk '/^nameserver / {print $2}' /etc/resolv.conf)
  fi

  if [[ "$DNS_MANAGER" == "systemd-resolved" ]] && have_cmd resolvectl; then
    local upstreams
    upstreams="$(resolvectl dns 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}' | sort -u)"
    if [[ -n "$upstreams" ]]; then
      mapfile -t DNS_CURRENT <<<"$upstreams"
    fi
  fi
}

print_network_facts() {
  ui_box_start "Network detection"
  ui_kv "Stack" "${NET_STACK}"
  ui_kv "Default iface" "${NET_DEFAULT_IFACE:-unknown} (MTU ${NET_DEFAULT_MTU:-?})"
  ui_kv "DNS manager" "${DNS_MANAGER}"
  ui_kv "resolv.conf" "${DNS_RESOLV_PATH}"
  if ((${#DNS_CURRENT[@]})); then
    ui_kv "Current DNS" "${DNS_CURRENT[*]}"
  else
    ui_kv "Current DNS" "(none detected)"
  fi
  [[ -n "$NETPLAN_FILE" ]] && ui_kv "Netplan file" "$NETPLAN_FILE"
  ui_box_end
}

# True if we still have a default IPv4 route (gateway present)
network_has_default_route() {
  ip -4 route show default 2>/dev/null | grep -q .
}

# Soft reload networkd without hard restart when possible
_networkd_soft_reload() {
  if have_cmd networkctl; then
    networkctl reload >/dev/null 2>&1 || true
    return 0
  fi
  # Avoid systemctl restart — that can drop DHCP leases / gateway
  systemctl reload systemd-networkd >/dev/null 2>&1 || true
}

# Remove ANY MrClock artifacts that can steal addressing / break gateway
heal_network_safety() {
  local f changed=0

  # 1) Old .network drop-ins without [Network] (killed DHCP/gateway)
  for f in /etc/systemd/network/10-securebox-*.network; do
    [[ -e "$f" ]] || continue
    backup_file "$f"
    rm -f "$f"
    ui_warn "Removed dangerous networkd file: $(basename "$f")"
    changed=1
  done

  # 2) Netplan stubs that redefine ethernets.<iface> with only mtu/nameservers
  #    These can conflict with cloud-init match:/set-name: layouts and drop addressing.
  for f in /etc/netplan/99-securebox-mtu.yaml /etc/netplan/99-securebox-dns.yaml; do
    [[ -e "$f" ]] || continue
    backup_file "$f"
    rm -f "$f"
    ui_warn "Removed risky netplan stub: $(basename "$f")"
    changed=1
  done

  if (( changed )); then
    if have_cmd netplan; then
      netplan generate >/dev/null 2>&1 || true
      # Do NOT netplan apply here — can flap interfaces; live config already running
    fi
    _networkd_soft_reload
    ui_info "Network safety heal done (no hard network restart)"
  fi
}

# Persist MTU via systemd .link only (never redefines IP/DHCP/gateway)
_mtu_write_link_file() {
  local iface="$1"
  local mtu="$2"
  mkdir -p /etc/systemd/network
  local linkfile="/etc/systemd/network/10-securebox-${iface}.link"
  backup_file "$linkfile"
  cat >"$linkfile" <<EOF
# Managed by MrClock ${SECUREBOX_VERSION}
# SAFE: .link sets MTU only — does NOT touch IP / DHCP / gateway
[Match]
OriginalName=${iface}

[Link]
MTUBytes=${mtu}
EOF
}

# Apply persistent MTU — connectivity-safe
apply_persistent_mtu() {
  local iface="$1"
  local mtu="$2"
  [[ -n "$iface" && -n "$mtu" ]] || return 1

  if ! network_has_default_route; then
    ui_warn "No default route before MTU change — refusing to modify networking"
    return 1
  fi

  # Live apply only (does not touch addressing)
  if ! ip link set dev "$iface" mtu "$mtu"; then
    return 1
  fi

  case "$NET_STACK" in
    networkmanager)
      local conn
      conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$iface" '$2==d{print $1; exit}')"
      if [[ -n "$conn" ]]; then
        # Modify only — do NOT nmcli connection up (that flaps the NIC / can lose GW)
        nmcli connection modify "$conn" 802-3-ethernet.mtu "$mtu" 2>/dev/null \
          || nmcli connection modify "$conn" ethernet.mtu "$mtu" 2>/dev/null \
          || true
        if have_cmd nmcli; then
          nmcli device reapply "$iface" >/dev/null 2>&1 || true
        fi
      fi
      # Also write .link as boot-safe persistence
      _mtu_write_link_file "$iface" "$mtu"
      ;;
    *)
      # netplan / networkd / ifupdown / unknown:
      # NEVER write netplan ethernets stubs — they can override cloud-init addressing.
      # Persist with systemd .link + live apply only.
      _mtu_write_link_file "$iface" "$mtu"
      ;;
  esac

  # Re-assert live MTU
  ip link set dev "$iface" mtu "$mtu" || true

  if ! network_has_default_route; then
    ui_error "Default route disappeared after MTU change — this should not happen (live MTU only)"
    return 1
  fi
  return 0
}

# Snapshot helpers for DNS rollback
_dns_snapshot_dir() {
  printf '%s\n' "${SECUREBOX_STATE_DIR}/dns-snap-${SECUREBOX_RUN_ID}"
}

_dns_snapshot_save() {
  local snap
  snap="$(_dns_snapshot_dir)"
  mkdir -p "$snap"
  [[ -f /etc/systemd/resolved.conf.d/99-securebox-dns.conf ]] \
    && cp -a /etc/systemd/resolved.conf.d/99-securebox-dns.conf "$snap/" || true
  [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]] \
    && cp -a /etc/resolv.conf "$snap/resolv.conf" || true
  if have_cmd resolvectl && [[ -n "${NET_DEFAULT_IFACE:-}" ]]; then
    resolvectl dns "$NET_DEFAULT_IFACE" >"$snap/resolvectl-dns.txt" 2>/dev/null || true
  fi
}

_dns_snapshot_restore() {
  local snap
  snap="$(_dns_snapshot_dir)"
  [[ -d "$snap" ]] || return 0
  if [[ -f "$snap/99-securebox-dns.conf" ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cp -a "$snap/99-securebox-dns.conf" /etc/systemd/resolved.conf.d/99-securebox-dns.conf
  else
    rm -f /etc/systemd/resolved.conf.d/99-securebox-dns.conf
  fi
  if [[ -f "$snap/resolv.conf" && ! -L /etc/resolv.conf ]]; then
    cp -a "$snap/resolv.conf" /etc/resolv.conf
  fi
  systemctl restart systemd-resolved >/dev/null 2>&1 || true
}

apply_dns_servers() {
  local primary="$1"
  local secondary="${2-}"
  local -a servers=("$primary")
  [[ -n "$secondary" ]] && servers+=("$secondary")

  _dns_snapshot_save

  case "$DNS_MANAGER" in
    systemd-resolved)
      mkdir -p /etc/systemd/resolved.conf.d
      local conf="/etc/systemd/resolved.conf.d/99-securebox-dns.conf"
      backup_file "$conf"
      {
        echo "# Managed by MrClock ${SECUREBOX_VERSION}"
        echo "[Resolve]"
        echo "DNS=${servers[*]}"
        # Keep public fallbacks — empty FallbackDNS + Domains=~. can blackhole resolution
        echo "FallbackDNS=1.0.0.1 8.8.8.8"
        # Do NOT set Domains=~. (routing all queries exclusively is too aggressive)
      } >"$conf"
      if have_cmd resolvectl && [[ -n "$NET_DEFAULT_IFACE" ]]; then
        resolvectl dns "$NET_DEFAULT_IFACE" "${servers[@]}" >/dev/null 2>&1 || true
      fi
      systemctl restart systemd-resolved >/dev/null 2>&1 || true
      ;;
    NetworkManager)
      local conn
      conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$NET_DEFAULT_IFACE" '$2==d{print $1; exit}')"
      if [[ -z "$conn" ]]; then
        conn="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -n1)"
      fi
      if [[ -n "$conn" ]]; then
        nmcli connection modify "$conn" ipv4.ignore-auto-dns yes
        nmcli connection modify "$conn" ipv4.dns "${servers[*]}"
        # Prefer reapply over connection up (avoids full link flap)
        if [[ -n "$NET_DEFAULT_IFACE" ]]; then
          nmcli device reapply "$NET_DEFAULT_IFACE" >/dev/null 2>&1 \
            || nmcli connection up "$conn" >/dev/null 2>&1 \
            || true
        else
          nmcli connection up "$conn" >/dev/null 2>&1 || true
        fi
      else
        return 1
      fi
      ;;
    static-resolv|resolvconf|unknown|netplan)
      # SAFE: never write netplan ethernets DNS stubs (can break gateway/DHCP merge).
      # Only touch resolv.conf when it is a real file (not resolved stub symlink).
      if [[ -L /etc/resolv.conf ]]; then
        # If managed by resolved/NetworkManager symlink — configure via resolved path above failed;
        # try resolved drop-in as best effort without rewriting netplan.
        mkdir -p /etc/systemd/resolved.conf.d
        local conf="/etc/systemd/resolved.conf.d/99-securebox-dns.conf"
        backup_file "$conf"
        {
          echo "# Managed by MrClock ${SECUREBOX_VERSION}"
          echo "[Resolve]"
          echo "DNS=${servers[*]}"
          echo "FallbackDNS=1.0.0.1 8.8.8.8"
        } >"$conf"
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
      else
        backup_file /etc/resolv.conf
        {
          echo "# Managed by MrClock ${SECUREBOX_VERSION}"
          for s in "${servers[@]}"; do
            echo "nameserver $s"
          done
          echo "options timeout:2 attempts:3"
        } >/etc/resolv.conf
      fi
      ;;
  esac

  # Validate resolution; rollback on failure
  local ok=0
  if have_cmd getent; then
    getent hosts cloudflare.com >/dev/null 2>&1 && ok=1
    getent hosts google.com >/dev/null 2>&1 && ok=1
  fi
  if (( ! ok )); then
    ui_warn "DNS validation failed — rolling back DNS changes"
    _dns_snapshot_restore
    return 1
  fi
  if ! network_has_default_route; then
    ui_warn "Default route missing after DNS change — rolling back"
    _dns_snapshot_restore
    return 1
  fi
  return 0
}

disable_ipv6_persistent() {
  write_sysctl_dropin /etc/sysctl.d/99-securebox-disable-ipv6.conf \
    "net.ipv6.conf.all.disable_ipv6 = 1" \
    "net.ipv6.conf.default.disable_ipv6 = 1" \
    "net.ipv6.conf.lo.disable_ipv6 = 1"

  # GRUB optional — does not affect IPv4 addressing
  if [[ -f /etc/default/grub ]]; then
    backup_file /etc/default/grub
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub || true
      if have_cmd update-grub; then
        update-grub >/dev/null 2>&1 || true
      elif have_cmd grub-mkconfig; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ -f /etc/default/ufw ]]; then
    backup_file /etc/default/ufw
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
  fi

  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
}
