#!/usr/bin/env bash
# SecureBox — network path detection (netplan / networkd / NetworkManager / resolved)
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

  # Prefer resolved real upstreams when stub is in use
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

# Apply persistent MTU on the default interface according to detected stack
apply_persistent_mtu() {
  local iface="$1"
  local mtu="$2"
  [[ -n "$iface" && -n "$mtu" ]] || return 1

  # Live apply
  ip link set dev "$iface" mtu "$mtu" || return 1

  case "$NET_STACK" in
    netplan)
      local file="${NETPLAN_FILE:-/etc/netplan/99-securebox-mtu.yaml}"
      if [[ -n "$NETPLAN_FILE" && -f "$NETPLAN_FILE" ]]; then
        backup_file "$NETPLAN_FILE"
        # Prefer a dedicated drop-in to avoid breaking complex YAML
        file="/etc/netplan/99-securebox-mtu.yaml"
      fi
      backup_file "$file"
      cat >"$file" <<EOF
# Managed by MrClock ${SECUREBOX_VERSION}
network:
  version: 2
  ethernets:
    ${iface}:
      mtu: ${mtu}
EOF
      # If iface is actually a bond/vlan/bridge name, also try renderer-agnostic match via networkd drop-in fallback below
      netplan generate >/dev/null 2>&1 || true
      netplan apply >/dev/null 2>&1 || true
      # Re-assert live MTU after apply
      ip link set dev "$iface" mtu "$mtu" || true
      ;;
    networkmanager)
      local conn
      conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$iface" '$2==d{print $1; exit}')"
      if [[ -n "$conn" ]]; then
        nmcli connection modify "$conn" 802-3-ethernet.mtu "$mtu" || nmcli connection modify "$conn" ethernet.mtu "$mtu" || true
        nmcli connection up "$conn" >/dev/null 2>&1 || true
      fi
      ip link set dev "$iface" mtu "$mtu" || true
      ;;
    networkd|unknown|ifupdown)
      mkdir -p /etc/systemd/network
      local dropin="/etc/systemd/network/10-securebox-${iface}.network"
      backup_file "$dropin"
      cat >"$dropin" <<EOF
# Managed by MrClock ${SECUREBOX_VERSION}
[Match]
Name=${iface}

[Link]
MTUBytes=${mtu}
EOF
      if systemctl is-enabled --quiet systemd-networkd 2>/dev/null || systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        systemctl restart systemd-networkd >/dev/null 2>&1 || true
      fi
      ip link set dev "$iface" mtu "$mtu" || true
      ;;
  esac
  return 0
}

apply_dns_servers() {
  local primary="$1"
  local secondary="${2-}"
  local -a servers=("$primary")
  [[ -n "$secondary" ]] && servers+=("$secondary")

  case "$DNS_MANAGER" in
    systemd-resolved)
      mkdir -p /etc/systemd
      backup_file /etc/systemd/resolved.conf
      local conf="/etc/systemd/resolved.conf.d/99-securebox-dns.conf"
      mkdir -p /etc/systemd/resolved.conf.d
      backup_file "$conf"
      {
        echo "# Managed by MrClock ${SECUREBOX_VERSION}"
        echo "[Resolve]"
        echo "DNS=${servers[*]}"
        echo "FallbackDNS="
        echo "Domains=~."
      } >"$conf"
      # Also set on default link if resolvectl supports it
      if have_cmd resolvectl && [[ -n "$NET_DEFAULT_IFACE" ]]; then
        resolvectl dns "$NET_DEFAULT_IFACE" "${servers[@]}" >/dev/null 2>&1 || true
        resolvectl domain "$NET_DEFAULT_IFACE" '~.' >/dev/null 2>&1 || true
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
        nmcli connection up "$conn" >/dev/null 2>&1 || true
      else
        return 1
      fi
      ;;
    netplan|static-resolv|resolvconf|unknown)
      # Netplan DNS persistence when stack is netplan
      if [[ "$NET_STACK" == "netplan" ]]; then
        local file="/etc/netplan/99-securebox-dns.yaml"
        backup_file "$file"
        local dns_yaml
        dns_yaml="$(printf '"%s", ' "${servers[@]}" | sed 's/, $//')"
        cat >"$file" <<EOF
# Managed by MrClock ${SECUREBOX_VERSION}
network:
  version: 2
  ethernets:
    ${NET_DEFAULT_IFACE:-eth0}:
      nameservers:
        addresses: [${dns_yaml}]
EOF
        netplan generate >/dev/null 2>&1 || true
        netplan apply >/dev/null 2>&1 || true
      fi
      # Always ensure resolv.conf usable if not a resolved stub we shouldn't clobber wrongly
      if [[ -L /etc/resolv.conf && "$(readlink /etc/resolv.conf)" == *stub-resolv.conf ]]; then
        :
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

  # Quick validation
  if have_cmd getent; then
    getent hosts cloudflare.com >/dev/null 2>&1 || getent hosts google.com >/dev/null 2>&1 || return 1
  fi
  return 0
}

disable_ipv6_persistent() {
  write_sysctl_dropin /etc/sysctl.d/99-securebox-disable-ipv6.conf \
    "net.ipv6.conf.all.disable_ipv6 = 1" \
    "net.ipv6.conf.default.disable_ipv6 = 1" \
    "net.ipv6.conf.lo.disable_ipv6 = 1"

  # GRUB optional persistence across boots for some kernels
  if [[ -f /etc/default/grub ]]; then
    backup_file /etc/default/grub
    if grep -q 'ipv6.disable=1' /etc/default/grub; then
      :
    else
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub || true
      if have_cmd update-grub; then
        update-grub >/dev/null 2>&1 || true
      elif have_cmd grub-mkconfig; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
      fi
    fi
  fi

  # UFW IPv6 off
  if [[ -f /etc/default/ufw ]]; then
    backup_file /etc/default/ufw
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
  fi

  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
}
