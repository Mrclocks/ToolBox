#!/usr/bin/env bash
# Module: PasarGuard SSL issue + auto-renew (acme.sh)
# Panel certs  → /var/lib/pasarguard/certs/<domain>.cer[.key]
# Node certs   → /var/lib/pg-node/certs/ssl_cert.pem + ssl_key.pem
# shellcheck shell=bash

SSL_PANEL_ROOT="${SSL_PANEL_ROOT:-/var/lib/pasarguard}"
SSL_NODE_ROOT="${SSL_NODE_ROOT:-/var/lib/pg-node}"
SSL_PANEL_CERT_DIR="${SSL_PANEL_CERT_DIR:-${SSL_PANEL_ROOT}/certs}"
SSL_NODE_CERT_DIR="${SSL_NODE_CERT_DIR:-${SSL_NODE_ROOT}/certs}"
SSL_STATE_DIR="${SSL_STATE_DIR:-${SECUREBOX_STATE_DIR}/ssl}"
SSL_CONFIG_FILE="${SSL_CONFIG_FILE:-${SSL_STATE_DIR}/config.env}"
SSL_DEPLOY_HOOK="${SSL_DEPLOY_HOOK:-${SSL_STATE_DIR}/deploy-hook.sh}"
SSL_PRE_HOOK="${SSL_PRE_HOOK:-${SSL_STATE_DIR}/acme-pre-hook.sh}"
SSL_POST_HOOK="${SSL_POST_HOOK:-${SSL_STATE_DIR}/acme-post-hook.sh}"
SSL_ACME_STOPPED="${SSL_ACME_STOPPED:-${SSL_STATE_DIR}/.acme-stopped-services}"
SSL_ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
SSL_ACME_BIN="${SSL_ACME_BIN:-${SSL_ACME_HOME}/acme.sh}"
SSL_POST_HOOK_FAILED="${SSL_POST_HOOK_FAILED:-${SSL_STATE_DIR}/acme-post-hook.failed}"
SSL_HAPROXY_CERT_DIR="${SSL_HAPROXY_CERT_DIR:-/etc/haproxy/certs}"
PROXY_CONFIG_FILE="${PROXY_CONFIG_FILE:-${SECUREBOX_STATE_DIR}/proxy/config.env}"
SSL_CONFIG_KEYS=(
  SSL_ROLE SSL_PRIMARY SSL_DOMAINS SSL_KEY_TYPE SSL_EMAIL
  SSL_PANEL_CERT_DIR SSL_NODE_CERT_DIR SSL_HAPROXY_CERT_DIR SSL_ACME_HOME
)

# --- detection / parsing ---------------------------------------------------

_ssl_detect_role() {
  # Prints: panel | node | both | none
  local has_panel=0 has_node=0
  if [[ -d /opt/pasarguard ]] || [[ -d "$SSL_PANEL_ROOT" ]] || [[ -f /opt/pasarguard/.env ]] \
      || [[ -f /opt/pasarguard/docker-compose.yml ]]; then
    has_panel=1
  fi
  if [[ -d /opt/pg-node ]] || [[ -d "$SSL_NODE_ROOT" ]] || [[ -f /opt/pg-node/docker-compose.yml ]]; then
    has_node=1
  fi
  # Docker image name hints (best-effort)
  if have_cmd docker; then
    if docker ps --format '{{.Image}}' 2>/dev/null | grep -qiE 'pasarguard/panel|pasarguard.panel'; then
      has_panel=1
    fi
    if docker ps --format '{{.Image}}' 2>/dev/null | grep -qiE 'pasarguard/node|pasarguard.node|pg-node'; then
      has_node=1
    fi
  fi
  if (( has_panel && has_node )); then
    printf 'both\n'
  elif (( has_panel )); then
    printf 'panel\n'
  elif (( has_node )); then
    printf 'node\n'
  else
    printf 'none\n'
  fi
}

_ssl_normalize_domains() {
  # stdin or $1 → newline-separated lowercase FQDNs
  local raw="${1-}"
  if [[ -z "$raw" ]]; then
    raw="$(cat)"
  fi
  printf '%s\n' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ',;' '  ' \
    | tr -s '[:space:]' '\n' \
    | sed '/^$/d' \
    | awk 'NF && !seen[$0]++'
}

_ssl_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

_ssl_parse_domains_arg() {
  # Sets SSL_DOMAINS_ARR and SSL_PRIMARY from a raw string. Returns 1 on bad input.
  local raw="$1"
  local -a list=()
  local d
  mapfile -t list < <(_ssl_normalize_domains "$raw")
  if ((${#list[@]} == 0)); then
    ui_error "No domains provided."
    return 1
  fi
  for d in "${list[@]}"; do
    if ! _ssl_valid_domain "$d"; then
      ui_error "Invalid domain: ${d}"
      return 1
    fi
  done
  SSL_DOMAINS_ARR=("${list[@]}")
  SSL_PRIMARY="${list[0]}"
  return 0
}

_ssl_port80_busy() {
  if have_cmd ss; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '(:|\.)80$' >/dev/null 2>&1
    return $?
  fi
  if have_cmd netstat; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -E '(:|\.)80$' >/dev/null 2>&1
    return $?
  fi
  return 1
}

_ssl_port80_owner() {
  # Best-effort process/service name holding :80
  local line=""
  if have_cmd ss; then
    line="$(ss -tlnp 2>/dev/null | grep -E ':80\s' | head -n1 || true)"
  fi
  if [[ -n "$line" ]]; then
    if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    # Fallback: last users= chunk
    if [[ "$line" =~ \"([a-zA-Z0-9._-]+)\" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  local svc
  for svc in haproxy nginx caddy apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      printf '%s\n' "$svc"
      return 0
    fi
  done
  printf 'unknown\n'
  return 0
}

_ssl_local_ips() {
  # All global addresses on this host (v4 + v6), one per line
  if have_cmd ip; then
    ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
  elif have_cmd hostname; then
    hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
  fi
}

_ssl_public_ip() {
  # First public-looking local address (for display), else first address
  local ip first=""
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    [[ -z "$first" ]] && first="$ip"
    if ! _ssl_is_private_ip "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done < <(_ssl_local_ips)
  printf '%s\n' "$first"
}

_ssl_is_private_ip() {
  local ip="$1"
  case "$ip" in
    10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;  # CGNAT
    fc*|fd*|fe80:*|::1) return 0 ;;
  esac
  return 1
}

_ssl_resolve_domain() {
  # All A + AAAA answers, one per line
  local domain="$1"
  if have_cmd dig; then
    { dig +short A "$domain"; dig +short AAAA "$domain"; } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true
  elif have_cmd getent; then
    getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  elif have_cmd host; then
    host "$domain" 2>/dev/null | awk '/has (IPv6 )?address/{print $NF}'
  fi
}

_ssl_dns_points_here() {
  # 0 = a DNS answer is one of this host's addresses
  # 1 = DNS answers exist but none is ours (or no answer at all)
  # 2 = cannot verify (no resolver tool, or host only has private/NAT addresses)
  local domain="$1"
  local -a mine=() answers=()
  local a m has_public=0
  mapfile -t mine < <(_ssl_local_ips)
  ((${#mine[@]} > 0)) || return 2
  if ! have_cmd dig && ! have_cmd getent && ! have_cmd host; then
    return 2
  fi
  mapfile -t answers < <(_ssl_resolve_domain "$domain")
  ((${#answers[@]} > 0)) || return 1
  for a in "${answers[@]}"; do
    for m in "${mine[@]}"; do
      [[ "${a,,}" == "${m,,}" ]] && return 0
    done
  done
  for m in "${mine[@]}"; do
    _ssl_is_private_ip "$m" || has_public=1
  done
  # Behind NAT (typical cloud VM): the public IP is not on any interface
  (( has_public )) || return 2
  return 1
}

_ssl_preflight_issue() {
  # Warn about DNS + port 80 before ACME standalone. Returns 1 only on hard abort.
  local -a domains=("$@")
  local d owner self_ip
  self_ip="$(_ssl_public_ip)"
  ui_box_start "SSL preflight"
  ui_kv "Server IP" "${self_ip:-(unknown)}"
  local rc
  for d in "${domains[@]}"; do
    rc=0
    _ssl_dns_points_here "$d" || rc=$?
    case "$rc" in
      0) ui_success "DNS looks OK for ${d}" ;;
      2) ui_info "DNS for ${d}: cannot verify from here (NAT / private IP) — make sure A/AAAA is this server" ;;
      *) ui_warn "DNS for ${d} does not point to this server — Let's Encrypt will fail if A/AAAA is wrong" ;;
    esac
  done
  if _ssl_port80_busy; then
    owner="$(_ssl_port80_owner)"
    case "$owner" in
      haproxy|nginx|caddy|apache2|httpd)
        ui_info "Port 80 held by ${owner} — ACME pre-hook will stop it briefly, then restore."
        ;;
      *)
        ui_warn "Port 80 is in use (likely: ${owner}). ACME HTTP-01 needs :80 free."
        ui_info "ACME pre-hook will try to free known reverse proxies; other owners may still fail."
        if have_tty; then
          if ! ui_confirm "Continue anyway?" "N"; then
            ui_box_end
            ui_error "Aborted — free port 80, then retry Issue / Setup."
            return 1
          fi
        else
          ui_box_end
          ui_error "Port 80 busy and no TTY to confirm. Aborting."
          return 1
        fi
        ;;
    esac
  else
    ui_success "Port 80 is free"
  fi
  ui_box_end
  return 0
}

_ssl_ensure_dirs() {
  local role="${1:-}"
  case "$role" in
    panel|both)
      mkdir -p "$SSL_PANEL_CERT_DIR"
      chmod 755 "$SSL_PANEL_ROOT" "$SSL_PANEL_CERT_DIR" 2>/dev/null || true
      ;;
  esac
  case "$role" in
    node|both)
      mkdir -p "$SSL_NODE_CERT_DIR"
      chmod 755 "$SSL_NODE_ROOT" "$SSL_NODE_CERT_DIR" 2>/dev/null || true
      ;;
  esac
  mkdir -p "$SSL_STATE_DIR" "${SSL_STATE_DIR}/live"
  chmod 700 "$SSL_STATE_DIR" 2>/dev/null || true
}

# --- acme.sh ---------------------------------------------------------------

_ssl_ensure_acme() {
  local email="${1:-}"
  if [[ -x "$SSL_ACME_BIN" ]]; then
    return 0
  fi
  ui_info "Installing acme.sh..."
  if ! apt_install_safe curl socat cron; then
    ui_warn "Could not apt-install curl/socat/cron — continuing if already present"
  fi
  if ! have_cmd curl; then
    ui_error "curl is required to install acme.sh"
    return 1
  fi
  local installer
  installer="$(mktemp)"
  if ! curl -fsSL https://get.acme.sh -o "$installer"; then
    rm -f "$installer"
    ui_error "Failed to download acme.sh installer"
    return 1
  fi
  if [[ -n "$email" ]]; then
    if ! sh "$installer" -s email="$email"; then
      rm -f "$installer"
      ui_error "acme.sh installer failed"
      return 1
    fi
  else
    if ! sh "$installer"; then
      rm -f "$installer"
      ui_error "acme.sh installer failed"
      return 1
    fi
  fi
  rm -f "$installer"
  # Ensure PATH for current shell
  if [[ ! -x "$SSL_ACME_BIN" && -x "${HOME}/.acme.sh/acme.sh" ]]; then
    SSL_ACME_HOME="${HOME}/.acme.sh"
    SSL_ACME_BIN="${SSL_ACME_HOME}/acme.sh"
  fi
  if [[ ! -x "$SSL_ACME_BIN" ]]; then
    ui_error "acme.sh not found after install at ${SSL_ACME_BIN}"
    return 1
  fi
  # Prefer Let's Encrypt
  "$SSL_ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  ui_success "acme.sh ready"
  return 0
}

_ssl_write_deploy_hook() {
  mkdir -p "$SSL_STATE_DIR"
  cat >"$SSL_DEPLOY_HOOK" <<'HOOK'
#!/usr/bin/env bash
# MrClock SSL deploy hook — runs after issue/renew (acme.sh --reloadcmd / cron)
set -uo pipefail
STATE_DIR="${SECUREBOX_SSL_STATE_DIR:-/var/lib/securebox/ssl}"
CONFIG="${STATE_DIR}/config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "[ssl-deploy] missing config: $CONFIG" >&2
  exit 1
fi

# Parse KEY=VALUE (never source: values must not be executed)
SSL_ROLE="" SSL_PRIMARY="" SSL_DOMAINS="" SSL_PANEL_CERT_DIR="" SSL_NODE_CERT_DIR=""
SSL_HAPROXY_CERT_DIR="" SSL_ACME_HOME=""
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^(SSL_ROLE|SSL_PRIMARY|SSL_DOMAINS|SSL_PANEL_CERT_DIR|SSL_NODE_CERT_DIR|SSL_HAPROXY_CERT_DIR|SSL_ACME_HOME)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
  printf -v "$key" '%s' "$val"
done <"$CONFIG"

PANEL_DIR="${SSL_PANEL_CERT_DIR:-/var/lib/pasarguard/certs}"
NODE_DIR="${SSL_NODE_CERT_DIR:-/var/lib/pg-node/certs}"
HAPROXY_DIR="${SSL_HAPROXY_CERT_DIR:-/etc/haproxy/certs}"
PRIMARY="${SSL_PRIMARY:-}"
ROLE="${SSL_ROLE:-panel}"
LIVE_DIR="${STATE_DIR}/live"
FAIL=0

if [[ -z "$PRIMARY" ]]; then
  echo "[ssl-deploy] SSL_PRIMARY empty" >&2
  exit 1
fi
read -r -a DOMAINS <<<"${SSL_DOMAINS:-$PRIMARY}"
for d in "${DOMAINS[@]}"; do
  if ! [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "[ssl-deploy] refusing invalid domain in config: $d" >&2
    exit 1
  fi
done

SRC_CERT="${LIVE_DIR}/fullchain.cer"
SRC_KEY="${LIVE_DIR}/key.pem"
# Prefer paths exported by acme.sh --reloadcmd
if [[ -n "${CERT_FULLCHAIN_PATH:-}" && -s "${CERT_FULLCHAIN_PATH}" ]]; then
  SRC_CERT="$CERT_FULLCHAIN_PATH"
fi
if [[ -n "${CERT_KEY_PATH:-}" && -s "${CERT_KEY_PATH}" ]]; then
  SRC_KEY="$CERT_KEY_PATH"
fi
if [[ ! -s "$SRC_CERT" || ! -s "$SRC_KEY" ]]; then
  ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
  for dir in "${ACME_HOME}/${PRIMARY}_ecc" "${ACME_HOME}/${PRIMARY}"; do
    if [[ -s "${dir}/fullchain.cer" && -s "${dir}/${PRIMARY}.key" ]]; then
      SRC_CERT="${dir}/fullchain.cer"
      SRC_KEY="${dir}/${PRIMARY}.key"
      break
    fi
  done
fi
if [[ ! -s "$SRC_CERT" || ! -s "$SRC_KEY" ]]; then
  echo "[ssl-deploy] cert/key not found for ${PRIMARY}" >&2
  exit 1
fi

# Keep a stable live copy for future renews
mkdir -p "$LIVE_DIR"
[[ "$SRC_CERT" -ef "${LIVE_DIR}/fullchain.cer" ]] || cp -f "$SRC_CERT" "${LIVE_DIR}/fullchain.cer" || exit 1
[[ "$SRC_KEY" -ef "${LIVE_DIR}/key.pem" ]] || cp -f "$SRC_KEY" "${LIVE_DIR}/key.pem" || exit 1
chmod 600 "${LIVE_DIR}/key.pem"
SRC_CERT="${LIVE_DIR}/fullchain.cer"
SRC_KEY="${LIVE_DIR}/key.pem"

# Same cert as last successful deploy? Then copy files but skip restarts
# (acme.sh renew runs this hook, and "Renew now" runs it again).
FP_FILE="${STATE_DIR}/last_deploy.sha256"
FP="$(cat "$SRC_CERT" "$SRC_KEY" | sha256sum | awk '{print $1}')"
CHANGED=1
if [[ "${SSL_DEPLOY_FORCE_RELOAD:-0}" != "1" && -f "$FP_FILE" && "$(cat "$FP_FILE")" == "$FP" ]]; then
  CHANGED=0
fi

install_file() {
  # install_file SRC DEST MODE
  local tmp
  tmp="$(mktemp "$(dirname "$2")/.deploy.XXXXXX")" || return 1
  cat "$1" >"$tmp" && chmod "$3" "$tmp" && mv -f "$tmp" "$2"
}

deploy_panel() {
  mkdir -p "$PANEL_DIR" || { FAIL=1; return; }
  local d
  for d in "${DOMAINS[@]}"; do
    install_file "$SRC_CERT" "${PANEL_DIR}/${d}.cer" 644 || FAIL=1
    install_file "$SRC_KEY" "${PANEL_DIR}/${d}.cer.key" 600 || FAIL=1
  done
}

deploy_haproxy() {
  # Only when HAProxy is installed (do not create /etc/haproxy on hosts without it)
  [[ -d "$(dirname "$HAPROXY_DIR")" ]] || return 0
  mkdir -p "$HAPROXY_DIR" || { FAIL=1; return; }
  local d pem
  for d in "${DOMAINS[@]}"; do
    pem="$(mktemp "${HAPROXY_DIR}/.pem.XXXXXX")" || { FAIL=1; continue; }
    chmod 600 "$pem"
    cat "$SRC_CERT" "$SRC_KEY" >"$pem" && mv -f "$pem" "${HAPROXY_DIR}/${d}.pem" || FAIL=1
  done
  if (( CHANGED )) && command -v systemctl >/dev/null 2>&1 \
      && systemctl is-active --quiet haproxy 2>/dev/null; then
    if ! systemctl reload haproxy >/dev/null 2>&1; then
      echo "[ssl-deploy] haproxy reload FAILED — check: journalctl -u haproxy -n 40" >&2
      FAIL=1
    fi
  fi
}

deploy_node() {
  mkdir -p "$NODE_DIR" || { FAIL=1; return; }
  install_file "$SRC_CERT" "${NODE_DIR}/ssl_cert.pem" 644 || FAIL=1
  install_file "$SRC_KEY" "${NODE_DIR}/ssl_key.pem" 600 || FAIL=1
}

reload_compose() {
  local dir="$1"
  (( CHANGED )) || return 0
  [[ -d "$dir" ]] || return 0
  [[ -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  if ! (cd "$dir" && docker compose restart >/dev/null 2>&1) \
      && ! (cd "$dir" && docker-compose restart >/dev/null 2>&1); then
    echo "[ssl-deploy] restart FAILED in ${dir}" >&2
    FAIL=1
  fi
}

case "$ROLE" in
  node) deploy_node ;;
  both) deploy_panel; deploy_haproxy; deploy_node ;;
  *) deploy_panel; deploy_haproxy ;;
esac
case "$ROLE" in
  node) reload_compose /opt/pg-node ;;
  both) reload_compose /opt/pasarguard; reload_compose /opt/pg-node ;;
  *) reload_compose /opt/pasarguard ;;
esac

if (( FAIL )); then
  echo "[ssl-deploy] FAILED role=${ROLE} primary=${PRIMARY}" >&2
  exit 1
fi
printf '%s\n' "$FP" >"$FP_FILE"
date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/last_deploy.txt"
echo "[ssl-deploy] OK role=${ROLE} primary=${PRIMARY} changed=${CHANGED}"
HOOK
  chmod 700 "$SSL_DEPLOY_HOOK"
}

# Temporarily free :80 for ACME HTTP-01 (esp. when HAProxy owns it).
_ssl_write_acme_port_hooks() {
  mkdir -p "$SSL_STATE_DIR"
  cat >"$SSL_PRE_HOOK" <<'HOOK'
#!/usr/bin/env bash
# Stop reverse proxies that hold :80 so acme.sh --standalone can bind.
set -euo pipefail
STATE_DIR="${SECUREBOX_SSL_STATE_DIR:-/var/lib/securebox/ssl}"
STOPPED="${STATE_DIR}/.acme-stopped-services"
mkdir -p "$STATE_DIR"
: >"$STOPPED"
for svc in haproxy nginx caddy apache2 httpd; do
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$svc" 2>/dev/null; then
    if systemctl stop "$svc" >/dev/null 2>&1; then
      echo "$svc" >>"$STOPPED"
      echo "[acme-pre] stopped ${svc}" >&2
    fi
  fi
done
# Brief wait for sockets to release
sleep 1
HOOK
  cat >"$SSL_POST_HOOK" <<'HOOK'
#!/usr/bin/env bash
# Restart services stopped by acme-pre-hook.
set -euo pipefail
STATE_DIR="${SECUREBOX_SSL_STATE_DIR:-/var/lib/securebox/ssl}"
STOPPED="${STATE_DIR}/.acme-stopped-services"
[[ -f "$STOPPED" ]] || exit 0
FAILED="${STATE_DIR}/acme-post-hook.failed"
failed=()
while IFS= read -r svc || [[ -n "$svc" ]]; do
  [[ -n "$svc" ]] || continue
  command -v systemctl >/dev/null 2>&1 || continue
  ok=0
  for _ in 1 2 3; do
    if systemctl start "$svc" >/dev/null 2>&1 && systemctl is-active --quiet "$svc"; then
      ok=1
      break
    fi
    sleep 2
  done
  if (( ok )); then
    echo "[acme-post] started ${svc}" >&2
  else
    echo "[acme-post] FAILED to start ${svc} — journalctl -u ${svc} -n 40" >&2
    failed+=("$svc")
  fi
done <"$STOPPED"
rm -f "$STOPPED"
if ((${#failed[@]} > 0)); then
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${failed[*]}" >"$FAILED"
  logger -t mrclock-acme "post-hook could not start: ${failed[*]}" 2>/dev/null || true
  exit 1
fi
rm -f "$FAILED"
HOOK
  chmod 700 "$SSL_PRE_HOOK" "$SSL_POST_HOOK"
}

_ssl_panel_behind_haproxy() {
  # True only when HAProxy panel mode is set up by ToolBox: saved proxy config,
  # or the ToolBox-managed panel haproxy.cfg is active. (PasarGuard's stock
  # .env already has commented UVICORN_SSL_* lines, so .env is no signal.)
  local PROXY_ENGINE="" PROXY_MODE=""
  kv_load_file "$PROXY_CONFIG_FILE" PROXY_ENGINE PROXY_MODE
  if [[ "$PROXY_ENGINE" == "haproxy" && "$PROXY_MODE" == "panel" ]]; then
    return 0
  fi
  local cfg="${PROXY_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
  if have_cmd systemctl && systemctl is-active --quiet haproxy 2>/dev/null \
      && grep -q '^# MrClock ToolBox — PasarGuard panel single-port' "$cfg" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Persist pre/post hooks into acme.sh domain conf so cron renew frees :80.
_ssl_register_acme_port_hooks() {
  local primary="${1:-}"
  [[ -n "$primary" ]] || return 1
  _ssl_write_acme_port_hooks
  local conf tmp found=0
  local -a confs=(
    "${SSL_ACME_HOME}/${primary}_ecc/${primary}.conf"
    "${SSL_ACME_HOME}/${primary}/${primary}.conf"
  )
  for conf in "${confs[@]}"; do
    [[ -f "$conf" ]] || continue
    found=1
    tmp="$(mktemp)"
    # Drop prior hook lines, then append ours (single-quoted paths; no spaces to escape)
    grep -vE '^Le_PreHook=|^Le_PostHook=' "$conf" >"$tmp" 2>/dev/null || true
    printf "Le_PreHook='%s'\n" "$SSL_PRE_HOOK" >>"$tmp"
    printf "Le_PostHook='%s'\n" "$SSL_POST_HOOK" >>"$tmp"
    cat "$tmp" >"$conf"
    rm -f "$tmp"
  done
  (( found == 1 ))
}

_ssl_valid_email() {
  [[ -z "${1-}" || "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

_ssl_save_config() {
  local role="$1"
  local primary="$2"
  shift 2
  local -a domains=("$@")
  _ssl_ensure_dirs "$role"
  local SSL_ROLE="$role" SSL_PRIMARY="$primary" SSL_DOMAINS="${domains[*]}"
  local k tmp
  tmp="$(mktemp "${SSL_STATE_DIR}/.config.XXXXXX")"
  {
    printf '# Generated by MrClock ToolBox (parsed, never sourced)\n'
    for k in "${SSL_CONFIG_KEYS[@]}"; do
      kv_line "$k" "${!k-}"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SSL_CONFIG_FILE"
  _ssl_write_deploy_hook
  _ssl_write_acme_port_hooks
}

_ssl_load_config() {
  SSL_ROLE=""
  SSL_PRIMARY=""
  SSL_DOMAINS=""
  SSL_EMAIL=""
  SSL_KEY_TYPE=""
  # Paths keep their module defaults unless the file overrides them
  kv_load_file "$SSL_CONFIG_FILE" "${SSL_CONFIG_KEYS[@]}"
  SSL_PANEL_CERT_DIR="${SSL_PANEL_CERT_DIR:-${SSL_PANEL_ROOT}/certs}"
  SSL_NODE_CERT_DIR="${SSL_NODE_CERT_DIR:-${SSL_NODE_ROOT}/certs}"
  SSL_HAPROXY_CERT_DIR="${SSL_HAPROXY_CERT_DIR:-/etc/haproxy/certs}"
  SSL_ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
  SSL_ACME_BIN="${SSL_ACME_HOME}/acme.sh"
}

_ssl_ecc_args() {
  # Prints "--ecc" when the primary cert is ECC (saved type, else acme.sh dirs)
  local primary="$1"
  case "${SSL_KEY_TYPE:-}" in
    ecc) printf -- '--ecc\n'; return 0 ;;
    rsa) return 0 ;;
  esac
  if [[ -f "${SSL_ACME_HOME}/${primary}_ecc/${primary}.conf" ]]; then
    printf -- '--ecc\n'
  fi
}

_ssl_issue_cert() {
  local role="$1"
  local primary="$2"
  shift 2
  local -a domains=("$@")
  local -a d_args=()
  local d
  for d in "${domains[@]}"; do
    d_args+=(-d "$d")
  done

  _ssl_ensure_dirs "$role"

  # Stage under ToolBox state; deploy-hook copies into Panel/Node paths.
  local fullchain="${SSL_STATE_DIR}/live/fullchain.cer"
  local keyfile="${SSL_STATE_DIR}/live/key.pem"
  mkdir -p "${SSL_STATE_DIR}/live"

  if ! _ssl_preflight_issue "${domains[@]}"; then
    return 1
  fi

  _ssl_write_acme_port_hooks
  rm -f "$SSL_POST_HOOK_FAILED"
  ui_info "Requesting certificate for: ${domains[*]}"
  # pre/post hooks free :80 (HAProxy/etc) so HTTP-01 works now and on cron renew
  if SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" \
      "$SSL_ACME_BIN" --issue --force --standalone "${d_args[@]}" \
      --keylength ec-256 \
      --pre-hook "$SSL_PRE_HOOK" \
      --post-hook "$SSL_POST_HOOK" \
      --reloadcmd "$SSL_DEPLOY_HOOK"; then
    SSL_KEY_TYPE=ecc
  else
    # Retry RSA if ECC fails on older stacks
    ui_warn "ECC issue failed — retrying with RSA 2048"
    if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" \
        "$SSL_ACME_BIN" --issue --force --standalone "${d_args[@]}" \
        --keylength 2048 \
        --pre-hook "$SSL_PRE_HOOK" \
        --post-hook "$SSL_POST_HOOK" \
        --reloadcmd "$SSL_DEPLOY_HOOK"; then
      ui_error "Certificate issuance failed. Check DNS A/AAAA records point here and port 80 is free."
      _ssl_report_post_hook || true
      return 1
    fi
    SSL_KEY_TYPE=rsa
  fi
  # Persist key type so install-cert / renew / repair target the right cert
  _ssl_save_config "$role" "$primary" "${domains[@]}"
  _ssl_report_post_hook || true

  ui_info "Installing certificate files + enabling auto-renew reload hook"
  local -a ecc=()
  mapfile -t ecc < <(_ssl_ecc_args "$primary")
  if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" \
      "$SSL_ACME_BIN" --install-cert -d "$primary" "${ecc[@]}" \
      --fullchain-file "$fullchain" \
      --key-file "$keyfile" \
      --reloadcmd "$SSL_DEPLOY_HOOK"; then
    ui_error "acme.sh --install-cert failed"
    return 1
  fi

  # Run deploy once now (covers node copy + multi-domain aliases)
  if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" bash "$SSL_DEPLOY_HOOK"; then
    ui_error "Deploy hook failed after install-cert"
    return 1
  fi

  # Ensure acme cron is present (installer usually adds it)
  if [[ -x "$SSL_ACME_BIN" ]]; then
    "$SSL_ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
  fi
  _ssl_register_acme_port_hooks "$primary" || true
  return 0
}

_ssl_report_post_hook() {
  # Returns 1 (and explains) if the ACME post-hook could not restart a proxy
  [[ -f "$SSL_POST_HOOK_FAILED" ]] || return 0
  ui_error "ACME post-hook could not restart: $(cut -d' ' -f2- "$SSL_POST_HOOK_FAILED")"
  ui_info "Start it manually: systemctl start <service> ; journalctl -u <service> -n 40"
  return 1
}

# Upsert KEY in a dotenv-style file. style=spaced → KEY = "value" (panel);
# style=bare → KEY=value or KEY = value without forcing quotes when bare.
_ssl_env_upsert() {
  local file="$1"
  local key="$2"
  local value="$3"
  local style="${4:-spaced}"
  local tmp line
  [[ -n "$file" && -n "$key" ]] || return 1
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  # Drop existing assignments (active or commented) for this key
  grep -vE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file" >"$tmp" 2>/dev/null || true
  # Keep a trailing newline
  if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$tmp"
  fi
  case "$style" in
    bare)
      printf '%s = %s\n' "$key" "$value" >>"$tmp"
      ;;
    *)
      printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
      ;;
  esac
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}

_ssl_env_comment_key() {
  # Comment out active KEY= lines (leave already-commented alone)
  local file="$1"
  local key="$2"
  local tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
      printf '# %s\n' "$(trim "$line")" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

_ssl_compose_upsert_env() {
  # Update environment: KEY: "value" (or KEY: value) inside a compose YAML (best-effort)
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  [[ -f "$file" ]] || return 1
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*${key}:[[:space:]]*" "$file"; then
    sed -E "s|^([[:space:]]*${key}:[[:space:]]*).*$|\1\"${value}\"|" "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_ssl_restart_compose() {
  local dir="$1"
  local label="$2"
  [[ -d "$dir" ]] || return 0
  [[ -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] || return 0
  if ! have_cmd docker; then
    ui_warn "docker not found — restart ${label} manually: cd ${dir} && docker compose restart"
    return 0
  fi
  ui_info "Restarting ${label}..."
  if (cd "$dir" && docker compose restart >/dev/null 2>&1) \
      || (cd "$dir" && docker-compose restart >/dev/null 2>&1); then
    ui_success "${label} restarted"
  else
    ui_warn "Could not restart ${label} — run: cd ${dir} && docker compose restart"
  fi
}

_ssl_apply_env_paths() {
  # Write certificate paths into Panel/Node env (and node compose) automatically.
  # When HAProxy panel mode is active, keep UVICORN_SSL_* commented (local HTTP).
  local role="$1"
  local primary="$2"
  local panel_env="/opt/pasarguard/.env"
  local node_env="/opt/pg-node/.env"
  local node_compose="/opt/pg-node/docker-compose.yml"
  local cert_path key_path applied=0

  case "$role" in
    panel|both)
      if [[ -d /opt/pasarguard ]]; then
        cert_path="${SSL_PANEL_CERT_DIR}/${primary}.cer"
        key_path="${SSL_PANEL_CERT_DIR}/${primary}.cer.key"
        if [[ -f "$panel_env" ]]; then
          if declare -F backup_file >/dev/null 2>&1; then
            backup_file "$panel_env" || true
          else
            cp -a "$panel_env" "${panel_env}.bak.mrclock.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
          fi
        else
          touch "$panel_env"
          chmod 600 "$panel_env"
        fi
        if _ssl_panel_behind_haproxy; then
          # TLS is terminated at HAProxy — do NOT re-enable Uvicorn direct TLS
          _ssl_env_comment_key "$panel_env" "UVICORN_SSL_CERTFILE"
          _ssl_env_comment_key "$panel_env" "UVICORN_SSL_KEYFILE"
          _ssl_env_comment_key "$panel_env" "UVICORN_UDS"
          ui_success "Panel behind HAProxy — left UVICORN_SSL_* commented (local HTTP)"
          ui_kv "Cert on disk" "$cert_path"
          ui_kv "Key on disk" "$key_path"
          ui_info "HAProxy PEM refreshed by deploy hook under /etc/haproxy/certs/"
          applied=1
        else
          _ssl_env_upsert "$panel_env" "UVICORN_SSL_CERTFILE" "$cert_path" spaced
          _ssl_env_upsert "$panel_env" "UVICORN_SSL_KEYFILE" "$key_path" spaced
          # Direct TLS mode — UDS is for reverse-proxy setups
          _ssl_env_comment_key "$panel_env" "UVICORN_UDS"
          ui_success "Panel .env updated: ${panel_env}"
          ui_kv "UVICORN_SSL_CERTFILE" "$cert_path"
          ui_kv "UVICORN_SSL_KEYFILE" "$key_path"
          ui_info "UVICORN_PORT left unchanged (change it yourself if you want 443)"
          _ssl_restart_compose /opt/pasarguard "PasarGuard panel"
          applied=1
        fi
      else
        ui_warn "Panel dir /opt/pasarguard not found — skipped .env auto-update"
      fi
      ;;
  esac

  case "$role" in
    node|both)
      if [[ -d /opt/pg-node ]] || [[ -d "$SSL_NODE_CERT_DIR" ]]; then
        cert_path="${SSL_NODE_CERT_DIR}/ssl_cert.pem"
        key_path="${SSL_NODE_CERT_DIR}/ssl_key.pem"
        if [[ -d /opt/pg-node ]]; then
          if [[ -f "$node_env" ]]; then
            if declare -F backup_file >/dev/null 2>&1; then
              backup_file "$node_env" || true
            else
              cp -a "$node_env" "${node_env}.bak.mrclock.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            fi
          else
            touch "$node_env"
            chmod 600 "$node_env" 2>/dev/null || true
          fi
          _ssl_env_upsert "$node_env" "SSL_CERT_FILE" "$cert_path" bare
          _ssl_env_upsert "$node_env" "SSL_KEY_FILE" "$key_path" bare
          ui_success "Node .env updated: ${node_env}"
          ui_kv "SSL_CERT_FILE" "$cert_path"
          ui_kv "SSL_KEY_FILE" "$key_path"
          if [[ -f "$node_compose" ]]; then
            if declare -F backup_file >/dev/null 2>&1; then
              backup_file "$node_compose" || true
            fi
            _ssl_compose_upsert_env "$node_compose" "SSL_CERT_FILE" "$cert_path" || true
            _ssl_compose_upsert_env "$node_compose" "SSL_KEY_FILE" "$key_path" || true
            ui_info "Node docker-compose SSL paths refreshed (if keys were present)"
          fi
          _ssl_restart_compose /opt/pg-node "PasarGuard node"
          applied=1
        else
          ui_warn "Node install dir /opt/pg-node not found — cert files are on disk only"
          ui_kv "SSL_CERT_FILE" "$cert_path"
          ui_kv "SSL_KEY_FILE" "$key_path"
        fi
      fi
      ;;
  esac

  if (( applied == 0 )); then
    ui_info "No Panel/Node install dirs found — paths were not written to .env"
  fi
  return 0
}

_ssl_print_env_guide() {
  local role="$1"
  local primary="$2"
  shift 2
  local -a domains=("$@")
  local d

  ui_box_start "Certificate paths"
  case "$role" in
    panel|both)
      ui_kv "Panel cert" "${SSL_PANEL_CERT_DIR}/${primary}.cer"
      ui_kv "Panel key" "${SSL_PANEL_CERT_DIR}/${primary}.cer.key"
      if [[ -f /opt/pasarguard/.env ]]; then
        ui_success "Written into /opt/pasarguard/.env (UVICORN_SSL_* only; port untouched)"
      else
        ui_info "If you install the panel later, re-run SSL → Show .env / path instructions"
        printf '   UVICORN_SSL_CERTFILE = "%s/%s.cer"\n' "$SSL_PANEL_CERT_DIR" "$primary"
        printf '   UVICORN_SSL_KEYFILE  = "%s/%s.cer.key"\n' "$SSL_PANEL_CERT_DIR" "$primary"
      fi
      if ((${#domains[@]} > 1)); then
        ui_info "SAN aliases also on disk:"
        for d in "${domains[@]}"; do
          ui_kv "$d" "${SSL_PANEL_CERT_DIR}/${d}.cer"
        done
      fi
      ;;
  esac
  case "$role" in
    node|both)
      ui_kv "Node cert" "${SSL_NODE_CERT_DIR}/ssl_cert.pem"
      ui_kv "Node key" "${SSL_NODE_CERT_DIR}/ssl_key.pem"
      if [[ -f /opt/pg-node/.env ]]; then
        ui_success "Written into /opt/pg-node/.env (SSL_CERT_FILE / SSL_KEY_FILE)"
      fi
      ui_info "In PasarGuard panel → Nodes, use the same paths if the UI asks."
      ;;
  esac
  if _ssl_panel_behind_haproxy; then
    ui_info "HAProxy panel mode active — panel stays on local HTTP; certs feed /etc/haproxy/certs/."
  else
    ui_info "Note: if you later put HAProxy in front, switch panel to local HTTP (no UVICORN_SSL_*)."
  fi
  ui_info "Auto-renew is ON — files redeploy automatically; .env TLS mode is preserved."
  ui_box_end
}

# --- public actions --------------------------------------------------------

ssl_issue_interactive() {
  ui_step "SSL — Issue / Setup"
  if is_dry_run; then
    ui_info "[dry-run] Would issue certificates with acme.sh and enable auto-renew"
    return 0
  fi

  local detected role choice raw_domains email
  detected="$(_ssl_detect_role)"
  ui_info "Detected role: ${detected}"

  case "$detected" in
    panel)
      role=panel
      ui_info "Using Panel paths under ${SSL_PANEL_CERT_DIR}"
      ;;
    node)
      role=node
      ui_info "Using Node paths under ${SSL_NODE_CERT_DIR}"
      ;;
    both)
      if ! ui_menu choice "This server looks like Panel + Node. Apply certs to:" \
          "Panel only" \
          "Node only" \
          "Both (recommended)"; then
        ui_info "Back."
        return 0
      fi
      case "$choice" in
        1) role=panel ;;
        2) role=node ;;
        3) role=both ;;
        *) return 0 ;;
      esac
      ;;
    none)
      ui_warn "PasarGuard Panel/Node not detected. Choose target paths:"
      if ! ui_menu choice "Install certificates for:" \
          "Panel paths (/var/lib/pasarguard/certs)" \
          "Node paths (/var/lib/pg-node/certs)" \
          "Both"; then
        ui_info "Back."
        return 0
      fi
      case "$choice" in
        1) role=panel ;;
        2) role=node ;;
        3) role=both ;;
        *) return 0 ;;
      esac
      ;;
  esac

  while true; do
    ui_ask raw_domains "Domain(s) — space or comma separated" ""
    if _ssl_parse_domains_arg "$raw_domains"; then
      break
    fi
  done

  while true; do
    ui_ask email "Email for Let's Encrypt (optional)" "${SSL_EMAIL:-}"
    email="$(trim "$email")"
    _ssl_valid_email "$email" && break
    ui_warn "Invalid email address."
  done
  SSL_EMAIL="$email"

  if ! ui_confirm "Issue certificate for ${SSL_DOMAINS_ARR[*]} → role=${role}?" "Y"; then
    ui_warn "Cancelled."
    return 0
  fi

  if ! _ssl_ensure_acme "$SSL_EMAIL"; then
    return 1
  fi

  _ssl_save_config "$role" "$SSL_PRIMARY" "${SSL_DOMAINS_ARR[@]}"

  if ! _ssl_issue_cert "$role" "$SSL_PRIMARY" "${SSL_DOMAINS_ARR[@]}"; then
    return 1
  fi

  ui_success "Certificate installed and auto-renew enabled"
  ui_step "Updating Panel/Node .env paths"
  _ssl_apply_env_paths "$role" "$SSL_PRIMARY"
  _ssl_print_env_guide "$role" "$SSL_PRIMARY" "${SSL_DOMAINS_ARR[@]}"
  return 0
}

ssl_status() {
  ui_step "SSL — Status"
  _ssl_load_config
  local role="${SSL_ROLE:-unknown}"
  local primary="${SSL_PRIMARY:-}"
  # SSL_DOMAINS is a space-separated string in config.env (not an array)
  # shellcheck disable=SC2178
  local domain_list="${SSL_DOMAINS:-}"

  ui_box_start "SSL configuration"
  ui_kv "Role" "$role"
  ui_kv "Primary" "${primary:-(none)}"
  ui_kv "Domains" "${domain_list:-(none)}"
  ui_kv "Key type" "${SSL_KEY_TYPE:-(unknown)}"
  ui_kv "Config" "$SSL_CONFIG_FILE"
  ui_kv "Deploy hook" "$SSL_DEPLOY_HOOK"
  ui_kv "acme.sh" "$([[ -x $SSL_ACME_BIN ]] && echo OK || echo missing)"
  if [[ -f "${SSL_STATE_DIR}/last_deploy.txt" ]]; then
    ui_kv "Last deploy" "$(tr -d '[:space:]' <"${SSL_STATE_DIR}/last_deploy.txt")"
  else
    ui_kv "Last deploy" "(never)"
  fi
  ui_box_end

  local f
  if [[ -n "$primary" ]]; then
    case "$role" in
      panel|both)
        local -a status_doms=()
        read -r -a status_doms <<<"${domain_list:-$primary}"
        for f in "${status_doms[@]}"; do
          if [[ -f "${SSL_PANEL_CERT_DIR}/${f}.cer" ]]; then
            ui_success "Panel cert OK: ${SSL_PANEL_CERT_DIR}/${f}.cer"
            if have_cmd openssl; then
              openssl x509 -in "${SSL_PANEL_CERT_DIR}/${f}.cer" -noout -dates 2>/dev/null \
                | while read -r line; do ui_kv "  $f" "$line"; done || true
            fi
          else
            ui_warn "Missing panel cert: ${SSL_PANEL_CERT_DIR}/${f}.cer"
          fi
        done
        ;;
    esac
    case "$role" in
      node|both)
        if [[ -f "${SSL_NODE_CERT_DIR}/ssl_cert.pem" && -f "${SSL_NODE_CERT_DIR}/ssl_key.pem" ]]; then
          ui_success "Node cert OK: ${SSL_NODE_CERT_DIR}/ssl_cert.pem"
          if have_cmd openssl; then
            openssl x509 -in "${SSL_NODE_CERT_DIR}/ssl_cert.pem" -noout -dates 2>/dev/null \
              | while read -r line; do ui_kv "  node" "$line"; done || true
          fi
        else
          ui_warn "Missing node certs under ${SSL_NODE_CERT_DIR}"
        fi
        ;;
    esac
  else
    ui_warn "No SSL setup saved yet. Use Issue / Setup first."
  fi

  _ssl_report_post_hook || true

  # Cron presence
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    ui_success "Auto-renew cron: present"
  else
    ui_warn "Auto-renew cron not found — run Issue / Setup again to repair"
  fi
}

ssl_renew_now() {
  ui_step "SSL — Renew now"
  if is_dry_run; then
    ui_info "[dry-run] Would force renew via acme.sh"
    return 0
  fi
  _ssl_load_config
  if [[ -z "${SSL_PRIMARY:-}" ]]; then
    ui_error "No saved SSL config. Run Issue / Setup first."
    return 1
  fi
  if [[ ! -x "$SSL_ACME_BIN" ]]; then
    ui_error "acme.sh missing at ${SSL_ACME_BIN}"
    return 1
  fi
  _ssl_write_deploy_hook
  _ssl_write_acme_port_hooks
  rm -f "$SSL_POST_HOOK_FAILED"
  local -a ecc=()
  mapfile -t ecc < <(_ssl_ecc_args "$SSL_PRIMARY")
  ui_info "Forcing renew for ${SSL_PRIMARY} (${ecc[*]:-rsa})..."
  # Pass pre/post hooks so HAProxy (or peers) release :80 for HTTP-01
  if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" \
       "$SSL_ACME_BIN" --renew -d "$SSL_PRIMARY" --force "${ecc[@]}" \
       --pre-hook "$SSL_PRE_HOOK" --post-hook "$SSL_POST_HOOK"; then
    ui_error "Renew failed — check DNS, port 80, and logs under ${SSL_ACME_HOME}"
    _ssl_report_post_hook || true
    ui_info "Tip: SSL → Repair auto-renew, then retry Renew now"
    return 1
  fi
  local rc=0
  _ssl_report_post_hook || rc=1
  # acme.sh already ran the deploy hook; run it again to get its exit status
  # (it skips restarts when the cert did not change since that run).
  if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" bash "$SSL_DEPLOY_HOOK"; then
    ui_error "Certificate renewed, but deploy failed (see messages above)"
    rc=1
  fi
  if (( rc != 0 )); then
    return 1
  fi
  ui_success "Renew + deploy completed"
  local -a doms=()
  read -r -a doms <<<"${SSL_DOMAINS:-$SSL_PRIMARY}"
  # Do NOT rewrite .env here — paths are unchanged; rewriting UVICORN_SSL_*
  # would undo HAProxy local-HTTP prep. Deploy hook already refreshed files/PEMs.
  _ssl_print_env_guide "${SSL_ROLE:-panel}" "$SSL_PRIMARY" "${doms[@]}"
  return 0
}

ssl_show_env_guide() {
  ui_step "SSL — .env / path instructions"
  _ssl_load_config
  if [[ -z "${SSL_PRIMARY:-}" ]]; then
    ui_warn "No saved SSL config yet. Run Issue / Setup first."
    return 0
  fi
  local -a doms=()
  read -r -a doms <<<"${SSL_DOMAINS:-$SSL_PRIMARY}"
  if _ssl_panel_behind_haproxy; then
    ui_info "HAProxy panel mode detected — re-apply keeps UVICORN_SSL_* commented."
  fi
  # Default N: avoid accidentally flipping panel back to direct TLS
  if ui_confirm "Re-apply certificate paths into Panel/Node .env now?" "N"; then
    _ssl_apply_env_paths "${SSL_ROLE:-panel}" "$SSL_PRIMARY"
  fi
  _ssl_print_env_guide "${SSL_ROLE:-panel}" "$SSL_PRIMARY" "${doms[@]}"
}

ssl_repair_autorenew() {
  ui_step "SSL — Repair auto-renew"
  if is_dry_run; then
    ui_info "[dry-run] Would reinstall acme.sh cron + deploy hook"
    return 0
  fi
  _ssl_load_config
  if [[ -z "${SSL_PRIMARY:-}" ]]; then
    ui_error "No saved SSL config. Run Issue / Setup first."
    return 1
  fi
  if [[ ! -x "$SSL_ACME_BIN" ]]; then
    if ! _ssl_ensure_acme "${SSL_EMAIL:-}"; then
      return 1
    fi
  fi
  _ssl_write_deploy_hook
  _ssl_write_acme_port_hooks
  local fullchain="${SSL_STATE_DIR}/live/fullchain.cer"
  local keyfile="${SSL_STATE_DIR}/live/key.pem"
  mkdir -p "${SSL_STATE_DIR}/live"
  if [[ -f "$fullchain" && -f "$keyfile" ]]; then
    local -a ecc=()
    mapfile -t ecc < <(_ssl_ecc_args "$SSL_PRIMARY")
    if ! SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" \
        "$SSL_ACME_BIN" --install-cert -d "$SSL_PRIMARY" "${ecc[@]}" \
        --fullchain-file "$fullchain" --key-file "$keyfile" \
        --reloadcmd "$SSL_DEPLOY_HOOK"; then
      ui_warn "acme.sh --install-cert failed — auto-renew reload hook may be stale"
    fi
  fi
  if _ssl_register_acme_port_hooks "$SSL_PRIMARY"; then
    ui_success "ACME pre/post hooks registered (free :80 during HTTP-01 renew)"
  else
    ui_warn "Could not patch acme.sh domain conf yet — run Renew once after Issue"
  fi
  "$SSL_ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    ui_success "Auto-renew cron repaired"
  else
    ui_warn "Cron still missing — check that cron package is installed"
  fi
  if [[ -x "$SSL_DEPLOY_HOOK" ]]; then
    ui_success "Deploy hook OK: ${SSL_DEPLOY_HOOK}"
  fi
  if [[ -x "$SSL_PRE_HOOK" && -x "$SSL_POST_HOOK" ]]; then
    ui_success "ACME port-80 hooks OK (stop/start HAProxy during HTTP-01)"
  fi
  return 0
}

ssl_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "SSL Certificates"
    printf '  %s 1)%s Issue / Setup (recommended)\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Status\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Renew now\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s Show .env / path instructions\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 5)%s Repair auto-renew\n' "$C_ORANGE" "$C_RESET"
    ui_menu_back_line
    local choice
    printf '%sSelect%s [0-5]: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) ui_clear; ssl_issue_interactive; ui_pause ;;
      2) ui_clear; ssl_status; ui_pause ;;
      3) ui_clear; ssl_renew_now; ui_pause ;;
      4) ui_clear; ssl_show_env_guide; ui_pause ;;
      5) ui_clear; ssl_repair_autorenew; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

# Compatibility entry for run_single
module_ssl() {
  ssl_menu_loop
}
