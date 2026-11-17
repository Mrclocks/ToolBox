#!/usr/bin/env bash
# PGClockTB — safety core
#   Preflight → Snapshot → Apply → Verify → (fail → Rollback) → Report
# Shared by every module that changes the system:
#   - single-run lock (two runs must never interleave /etc edits)
#   - admin IP discovery (never block the person running the tool)
#   - risk levels per module (low / mid / high)
#   - file transactions (exact snapshot + restore, including "file was absent")
#   - real connectivity probe (route + DNS + TLS fetch), not just "command ran"
# shellcheck shell=bash

PGCTB_LOCK_FILE="${PGCTB_LOCK_FILE:-/run/pgclocktb.lock}"
PGCTB_TXN_DIR="${PGCTB_TXN_DIR:-${PGCTB_STATE_DIR}/txn}"
PGCTB_TXN_KEEP="${PGCTB_TXN_KEEP:-20}"
PGCTB_TXN=""
PGCTB_LOCK_FD=""

# --- single-run lock ----------------------------------------------------------

pgctb_lock_acquire() {
  # Non-blocking: a second concurrent run exits instead of racing the first.
  have_cmd flock || return 0
  mkdir -p "$(dirname "$PGCTB_LOCK_FILE")" 2>/dev/null || true
  if ! { exec {PGCTB_LOCK_FD}>>"$PGCTB_LOCK_FILE"; } 2>/dev/null; then
    ui_warn "Could not open lock file ${PGCTB_LOCK_FILE} — continuing without lock"
    return 0
  fi
  if ! flock -n "$PGCTB_LOCK_FD"; then
    ui_error "Another PGClockTB run is in progress (lock ${PGCTB_LOCK_FILE})."
    ui_info "Wait for it to finish, or check: fuser -v ${PGCTB_LOCK_FILE}"
    return 1
  fi
  return 0
}

pgctb_lock_release() {
  [[ -n "$PGCTB_LOCK_FD" ]] || return 0
  flock -u "$PGCTB_LOCK_FD" 2>/dev/null || true
  exec {PGCTB_LOCK_FD}>&- 2>/dev/null || true
  PGCTB_LOCK_FD=""
}

# --- admin IPs ----------------------------------------------------------------

_pgctb_valid_ip() {
  local ip="$1"
  is_ipv4 "$ip" && return 0
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:.]+$ ]]
}

pgctb_admin_ips() {
  # Client IPs that must never be blocked: this SSH session, other logged-in
  # SSH sessions, and PGCTB_ADMIN_IPS (space/comma separated). One per line.
  local ip
  {
    [[ -n "${SSH_CONNECTION:-}" ]] && printf '%s\n' "${SSH_CONNECTION%% *}"
    [[ -n "${SSH_CLIENT:-}" ]] && printf '%s\n' "${SSH_CLIENT%% *}"
    if have_cmd who; then
      who --ips 2>/dev/null | awk '{print $NF}'
    fi
    tr ', ' '\n\n' <<<"${PGCTB_ADMIN_IPS:-}"
  } | while IFS= read -r ip; do
    ip="${ip#::ffff:}"
    ip="${ip#(}"
    ip="${ip%)}"
    [[ -n "$ip" ]] || continue
    if _pgctb_valid_ip "$ip"; then printf '%s\n' "$ip"; fi
  done | awk '!seen[$0]++'
}

_ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%u\n' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

ipv4_in_cidr() {
  # ipv4_in_cidr IP CIDR → 0 if IP is inside CIDR (a bare IP means /32)
  local ip="$1" cidr="$2" net bits mask
  net="${cidr%/*}"
  bits=32
  [[ "$cidr" == */* ]] && bits="${cidr#*/}"
  is_ipv4 "$ip" && is_ipv4 "$net" || return 1
  [[ "$bits" =~ ^[0-9]{1,2}$ ]] && (( bits <= 32 )) || return 1
  if (( bits == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  fi
  (( ($(_ipv4_to_int "$ip") & mask) == ($(_ipv4_to_int "$net") & mask) ))
}

# --- risk levels --------------------------------------------------------------
# low  : no connectivity risk, trivially reversible
# mid  : may affect some hosts/clients, does not normally touch SSH access
# high : can lock the admin out or block users — always confirmed one by one
declare -gA PGCTB_RISK=(
  [update]=low [timesync]=low [bbr]=low [logs]=low [unattended]=low
  [dns]=mid [mtu]=mid [ipv6]=mid [services]=mid [fail2ban]=mid
  [ssh]=high [ufw]=high [abuse]=high
)

pgctb_risk() {
  # Unknown modules are treated as high risk (fail safe)
  printf '%s\n' "${PGCTB_RISK[${1:-}]:-high}"
}

pgctb_risk_label() {
  case "$(pgctb_risk "$1")" in
    low) printf '🟢 low\n' ;;
    mid) printf '🟡 mid\n' ;;
    *) printf '🔴 high\n' ;;
  esac
}

# --- file transactions --------------------------------------------------------

safety_txn_begin() {
  # safety_txn_begin NAME FILE... → snapshot files (absent ones too); sets PGCTB_TXN
  local name="$1"
  shift
  local dir f n=0
  dir="${PGCTB_TXN_DIR}/${name}-$(date +%Y%m%d%H%M%S)-$$-${RANDOM}"
  mkdir -p "${dir}/files" || return 1
  chmod 700 "$PGCTB_TXN_DIR" "$dir" 2>/dev/null || true
  : >"${dir}/manifest"
  for f in "$@"; do
    [[ -n "$f" ]] || continue
    if [[ -e "$f" || -L "$f" ]]; then
      cp -a "$f" "${dir}/files/${n}" || { rm -rf "$dir"; return 1; }
      printf 'present\t%s\t%s\n' "$n" "$f" >>"${dir}/manifest"
    else
      printf 'absent\t%s\t%s\n' "$n" "$f" >>"${dir}/manifest"
    fi
    n=$((n + 1))
  done
  PGCTB_TXN="$dir"
  log INFO "txn begin $(basename "$dir") (${n} paths)"
}

safety_txn_rollback() {
  # Restore every path exactly as it was at begin (absent ⇒ removed again)
  local dir="${1:-$PGCTB_TXN}" state n path rc=0
  [[ -n "$dir" && -f "${dir}/manifest" ]] || return 1
  while IFS=$'\t' read -r state n path; do
    [[ -n "$path" ]] || continue
    case "$state" in
      present)
        mkdir -p "$(dirname "$path")"
        rm -rf "${path:?}"
        cp -a "${dir}/files/${n}" "$path" || rc=1
        ;;
      absent)
        rm -rf "${path:?}" || rc=1
        ;;
    esac
  done <"${dir}/manifest"
  touch "${dir}/rolled-back"
  log WARN "txn rollback $(basename "$dir") rc=${rc}"
  [[ "$dir" == "$PGCTB_TXN" ]] && PGCTB_TXN=""
  return "$rc"
}

safety_txn_commit() {
  local dir="${1:-$PGCTB_TXN}"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  touch "${dir}/committed"
  log INFO "txn commit $(basename "$dir")"
  [[ "$dir" == "$PGCTB_TXN" ]] && PGCTB_TXN=""
  _safety_txn_prune
}

_safety_txn_prune() {
  # Keep the newest PGCTB_TXN_KEEP finished transactions
  local -a done_dirs=()
  local d
  while IFS= read -r d; do
    [[ -f "${d}/committed" || -f "${d}/rolled-back" ]] && done_dirs+=("$d")
  done < <(ls -1dt "${PGCTB_TXN_DIR}"/*/ 2>/dev/null | sed 's:/$::')
  local i
  for ((i = PGCTB_TXN_KEEP; i < ${#done_dirs[@]}; i++)); do
    rm -rf "${done_dirs[$i]:?}"
  done
}

# --- connectivity probe -------------------------------------------------------

PGCTB_PROBE_URLS="${PGCTB_PROBE_URLS:-https://deb.debian.org/ https://archive.ubuntu.com/ https://cloudflare.com/}"

safety_has_default_route() {
  ip -4 route show default 2>/dev/null | grep -q . \
    || ip -6 route show default 2>/dev/null | grep -q .
}

safety_has_ipv4_default_route() {
  ip -4 route show default 2>/dev/null | grep -q .
}

safety_internet_ok() {
  # 0 = default route + a real HTTPS fetch works (DNS, TCP, TLS = large packets)
  # 1 = broken; 2 = cannot tell (no curl)
  safety_has_default_route || return 1
  have_cmd curl || return 2
  # Any HTTP status means DNS + TCP + TLS worked; 000 means it did not.
  local u code
  local -a urls=()
  read -r -a urls <<<"$PGCTB_PROBE_URLS"
  for u in "${urls[@]}"; do
    code="$(curl -sS -o /dev/null --max-time "${PGCTB_PROBE_TIMEOUT:-8}" \
      -w '%{http_code}' "$u" 2>/dev/null || true)"
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && return 0
  done
  return 1
}

# safety_verify_or_revert NAME BEFORE_RC REVERT_FN...
#   When connectivity worked before (BEFORE_RC=0) but not now, run REVERT_FN
#   immediately (no waiting for a timer) and return 1.
safety_verify_or_revert() {
  local name="$1" before="$2"
  shift 2
  local after=0
  safety_internet_ok || after=$?
  if (( before == 0 && after == 1 )); then
    ui_error "${name}: connectivity broke after the change — reverting now"
    "$@" || ui_error "${name}: revert reported errors — check manually"
    local again=0
    safety_internet_ok || again=$?
    if (( again == 0 )); then
      ui_success "${name}: connectivity restored"
    else
      ui_error "${name}: connectivity still failing after revert"
    fi
    return 1
  fi
  return 0
}
