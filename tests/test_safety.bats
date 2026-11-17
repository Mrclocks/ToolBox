#!/usr/bin/env bats
# Safety core (0.5.0): lock, admin IPs, CIDR math, risk, transactions,
# verify-or-revert, and the module guards built on them.

load helpers

setup() {
  T="${BATS_TEST_TMPDIR}/safety"
  mkdir -p "$T"
  PGCTB_TXN_DIR="${T}/txn"
  PGCTB_LOCK_FILE="${T}/run.lock"
}

stub() {
  mkdir -p "${T}/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"${T}/bin/$1"
  chmod +x "${T}/bin/$1"
  PATH="${T}/bin:$PATH"
}

@test "ipv4_in_cidr" {
  ipv4_in_cidr 198.51.100.7 198.51.100.0/24
  ipv4_in_cidr 10.1.2.3 10.0.0.0/8
  ipv4_in_cidr 1.2.3.4 0.0.0.0/0
  ipv4_in_cidr 1.2.3.4 1.2.3.4
  ! ipv4_in_cidr 198.51.101.7 198.51.100.0/24
  ! ipv4_in_cidr 1.2.3.4 1.2.3.0/33
  ! ipv4_in_cidr nope 1.2.3.0/24
}

@test "pgctb_admin_ips: SSH session, extra list, dedupe, junk dropped" {
  stub who 'exit 0'
  SSH_CONNECTION="203.0.113.9 51000 10.0.0.2 22" \
  SSH_CLIENT="203.0.113.9 51000 22" \
  PGCTB_ADMIN_IPS="198.51.100.1, 2001:db8::5 bogus \$(id)" \
    run pgctb_admin_ips
  [ "$status" -eq 0 ]
  [ "$output" = $'203.0.113.9\n198.51.100.1\n2001:db8::5' ]
}

@test "risk levels: known modules mapped, unknown is high" {
  [ "$(pgctb_risk bbr)" = low ]
  [ "$(pgctb_risk dns)" = mid ]
  [ "$(pgctb_risk ssh)" = high ]
  [ "$(pgctb_risk ufw)" = high ]
  [ "$(pgctb_risk abuse)" = high ]
  [ "$(pgctb_risk something-new)" = high ]
}

@test "transaction restores modified files and removes created ones" {
  echo original >"${T}/a.conf"
  safety_txn_begin test "${T}/a.conf" "${T}/new.conf"
  echo changed >"${T}/a.conf"
  echo created >"${T}/new.conf"
  safety_txn_rollback
  [ "$(cat "${T}/a.conf")" = original ]
  [ ! -e "${T}/new.conf" ]
  [ -z "$PGCTB_TXN" ]
}

@test "transaction commit keeps changes and prunes old ones" {
  PGCTB_TXN_KEEP=2
  local i
  for i in 1 2 3 4; do
    echo "v$i" >"${T}/f"
    safety_txn_begin "t$i" "${T}/f"
    echo "v$i-new" >"${T}/f"
    safety_txn_commit
  done
  [ "$(cat "${T}/f")" = "v4-new" ]
  [ "$(ls -1 "$PGCTB_TXN_DIR" | wc -l)" -eq 2 ]
}

@test "lock: second concurrent run is refused, released lock can be retaken" {
  pgctb_lock_acquire
  run bash -c 'source "$1/tests/helpers.bash"; PGCTB_LOCK_FILE="$2"; pgctb_lock_acquire' _ "$REPO_ROOT" "$PGCTB_LOCK_FILE"
  [ "$status" -ne 0 ]
  pgctb_lock_release
  run bash -c 'source "$1/tests/helpers.bash"; PGCTB_LOCK_FILE="$2"; pgctb_lock_acquire' _ "$REPO_ROOT" "$PGCTB_LOCK_FILE"
  [ "$status" -eq 0 ]
}

@test "verify_or_revert reverts only when connectivity broke" {
  local marker="${T}/reverted"
  revert() { touch "$marker"; }
  safety_internet_ok() { return 1; }
  run safety_verify_or_revert X 0 revert
  [ "$status" -ne 0 ]
  [ -f "$marker" ]
  rm -f "$marker"
  # Was already broken before → not our change, no revert
  run safety_verify_or_revert X 1 revert
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
  # Cannot tell (no curl) → no revert
  safety_internet_ok() { return 2; }
  run safety_verify_or_revert X 0 revert
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
}

@test "MTU: broken connectivity after change triggers immediate revert" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/mtu.sh"
  PGCTB_DRY_RUN=0
  declare -gA PGCTB_ANSWERS=([mtu]=1400 [continue_on_error]=yes)
  detect_network_stack() { NET_DEFAULT_IFACE=eth9; NET_STACK=other; NET_DEFAULT_MTU=1500; }
  network_has_default_route() { return 0; }
  iface_mtu() { echo 1500; }
  apply_persistent_mtu() { echo "$2" >"${T}/applied"; }
  local calls="${T}/probe-calls"
  safety_internet_ok() {
    echo x >>"$calls"
    [[ "$(wc -l <"$calls")" -eq 1 ]]   # ok before, broken after
  }
  _mtu_revert() { echo "$2" >"${T}/reverted"; }
  module_mtu || true
  [ "$(cat "${T}/applied")" = 1400 ]
  [ "$(cat "${T}/reverted")" = 1500 ]
  [[ " ${PGCTB_FAILED_MODULES[*]} " == *" mtu|"* ]]
}

@test "IPv6 disable refused on hosts without an IPv4 default route" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ipv6.sh"
  PGCTB_DRY_RUN=0
  declare -gA PGCTB_ANSWERS=([disable_ipv6]=yes [continue_on_error]=yes)
  safety_has_ipv4_default_route() { return 1; }
  disable_ipv6_persistent() { touch "${T}/disabled"; }
  module_ipv6 || true
  [ ! -f "${T}/disabled" ]
  [[ " ${PGCTB_FAILED_MODULES[*]} " == *" ipv6|"* ]]
}

@test "abuse: refuses without admin IP and without TTY" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/abuse.sh"
  pgctb_admin_ips() { :; }
  have_tty() { return 1; }
  CIDRS=(198.51.100.0/24)
  run _abuse_protect_admin
  [ "$status" -ne 0 ]
}

@test "abuse: admin IP inside a blocked range gets an allow rule before the drop (real nft)" {
  [[ $EUID -eq 0 ]] || skip "needs root"
  command -v nft >/dev/null || skip "nft missing"
  nft add table inet pgctbprobe 2>/dev/null || skip "nft not usable here"
  nft delete table inet pgctbprobe
  nft list table inet securebox >/dev/null 2>&1 && skip "real securebox table present"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/abuse.sh"
  backup_file() { :; }
  systemctl() { :; }
  mkdir() { command mkdir "$@"; }
  CIDRS=(198.51.100.0/24)
  PGCTB_ADMIN_IPS="198.51.100.7"
  SSH_CONNECTION="" SSH_CLIENT=""
  who() { :; }
  _abuse_protect_admin
  [ "${ABUSE_ADMIN_IPS[*]}" = "198.51.100.7" ]
  local conf_bak="${T}/nftables.conf.bak" had_conf=0
  [[ -f /etc/nftables.conf ]] && { cp -a /etc/nftables.conf "$conf_bak"; had_conf=1; }
  _abuse_apply_nft "${CIDRS[@]}" >/dev/null
  local rules
  rules="$(nft list chain inet securebox input)"
  nft delete table inet securebox
  rm -f /etc/nftables.d/securebox-abuse.nft
  (( had_conf )) && cp -a "$conf_bak" /etc/nftables.conf
  local accept_line drop_line
  accept_line="$(grep -n 'ip saddr 198.51.100.7 accept' <<<"$rules" | cut -d: -f1)"
  drop_line="$(grep -n 'ip saddr @abuse4 drop' <<<"$rules" | cut -d: -f1)"
  [ -n "$accept_line" ] && [ -n "$drop_line" ]
  (( accept_line < drop_line ))
}
