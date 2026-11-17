#!/usr/bin/env bash
# Module: PasarGuard SSL issue + auto-renew (acme.sh)
# Panel certs  → /var/lib/pasarguard/certs/<domain>/fullchain.pem + privkey.pem (official)
# Node certs   → /var/lib/pg-node/certs/ssl_cert.pem + ssl_key.pem
# shellcheck shell=bash

SSL_PANEL_ROOT="${SSL_PANEL_ROOT:-/var/lib/pasarguard}"
SSL_NODE_ROOT="${SSL_NODE_ROOT:-/var/lib/pg-node}"
SSL_PANEL_CERT_DIR="${SSL_PANEL_CERT_DIR:-${SSL_PANEL_ROOT}/certs}"
SSL_NODE_CERT_DIR="${SSL_NODE_CERT_DIR:-${SSL_NODE_ROOT}/certs}"
SSL_STATE_DIR="${SSL_STATE_DIR:-${PGCTB_STATE_DIR}/ssl}"
SSL_CONFIG_FILE="${SSL_CONFIG_FILE:-${SSL_STATE_DIR}/config.env}"
SSL_DEPLOY_HOOK="${SSL_DEPLOY_HOOK:-${SSL_STATE_DIR}/deploy-hook.sh}"
SSL_PRE_HOOK="${SSL_PRE_HOOK:-${SSL_STATE_DIR}/acme-pre-hook.sh}"
SSL_POST_HOOK="${SSL_POST_HOOK:-${SSL_STATE_DIR}/acme-post-hook.sh}"
SSL_ACME_STOPPED="${SSL_ACME_STOPPED:-${SSL_STATE_DIR}/.acme-stopped-services}"
SSL_ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
SSL_ACME_BIN="${SSL_ACME_BIN:-${SSL_ACME_HOME}/acme.sh}"
SSL_POST_HOOK_FAILED="${SSL_POST_HOOK_FAILED:-${SSL_STATE_DIR}/acme-post-hook.failed}"
SSL_HAPROXY_CERT_DIR="${SSL_HAPROXY_CERT_DIR:-/etc/haproxy/certs}"
SSL_PANEL_APP_DIR="${SSL_PANEL_APP_DIR:-/opt/pasarguard}"
SSL_VERIFY_TRIES="${SSL_VERIFY_TRIES:-30}"
PROXY_CONFIG_FILE="${PROXY_CONFIG_FILE:-${PGCTB_STATE_DIR}/proxy/config.env}"
SSL_CONFIG_KEYS=(
  SSL_ROLE SSL_PRIMARY SSL_DOMAINS SSL_KEY_TYPE SSL_METHOD SSL_EMAIL
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
  # "*.example.com" is accepted (DNS-01 only) but never as the primary domain.
  local raw="$1"
  local -a list=()
  local d
  mapfile -t list < <(_ssl_normalize_domains "$raw")
  if ((${#list[@]} == 0)); then
    ui_error "No domains provided."
    return 1
  fi
  for d in "${list[@]}"; do
    if ! _ssl_valid_domain "$d" && ! { [[ "$d" == \*.* ]] && _ssl_valid_domain "${d#\*.}"; }; then
      ui_error "Invalid domain: ${d}"
      return 1
    fi
  done
  if [[ "${list[0]}" == \*.* ]]; then
    ui_error "Put a normal domain first (e.g. example.com *.example.com) — it names the files."
    return 1
  fi
  SSL_DOMAINS_ARR=("${list[@]}")
  SSL_PRIMARY="${list[0]}"
  return 0
}

_ssl_has_wildcard() {
  local d
  for d in "$@"; do [[ "$d" == \*.* ]] && return 0; done
  return 1
}

# Cloudflare edge IPv4 ranges (https://www.cloudflare.com/ips-v4)
SSL_CF_RANGES=(173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
  141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
  197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
  104.24.0.0/14 172.64.0.0/13 131.0.72.0/22)

_ssl_behind_cloudflare() {
  # 0 if any A record of any domain is a Cloudflare edge IP (orange cloud)
  local d ip c
  for d in "$@"; do
    [[ "$d" == \*.* ]] && continue
    while IFS= read -r ip; do
      is_ipv4 "$ip" || continue
      for c in "${SSL_CF_RANGES[@]}"; do
        ipv4_in_cidr "$ip" "$c" && return 0
      done
    done < <(_ssl_resolve_domain "$d")
  done
  return 1
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
# PGClockTB SSL deploy hook — runs after issue/renew (acme.sh --reloadcmd / cron)
set -uo pipefail
STATE_DIR="${PGCTB_SSL_STATE_DIR:-/var/lib/pgclocktb/ssl}"
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
read -r -a ALL_DOMAINS <<<"${SSL_DOMAINS:-$PRIMARY}"
DOMAINS=()   # names that get their own files (wildcards are covered by the cert only)
for d in "${ALL_DOMAINS[@]}"; do
  if ! [[ "${d#\*.}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "[ssl-deploy] refusing invalid domain in config: $d" >&2
    exit 1
  fi
  [[ "$d" == \*.* ]] || DOMAINS+=("$d")
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
  # Official PasarGuard layout: certs/<domain>/fullchain.pem + privkey.pem
  # (/var/lib/pasarguard is bind-mounted into the panel container).
  mkdir -p "$PANEL_DIR" || { FAIL=1; return; }
  local d
  for d in "${DOMAINS[@]}"; do
    mkdir -p "${PANEL_DIR}/${d}" || { FAIL=1; continue; }
    chmod 755 "${PANEL_DIR}/${d}" 2>/dev/null || true
    install_file "$SRC_CERT" "${PANEL_DIR}/${d}/fullchain.pem" 644 || FAIL=1
    install_file "$SRC_KEY" "${PANEL_DIR}/${d}/privkey.pem" 600 || FAIL=1
    # Pre-0.7 layout (<domain>.cer): keep refreshing it only where it exists,
    # so an .env that still points there never serves an expired cert.
    if [[ -f "${PANEL_DIR}/${d}.cer" ]]; then
      install_file "$SRC_CERT" "${PANEL_DIR}/${d}.cer" 644 || FAIL=1
      install_file "$SRC_KEY" "${PANEL_DIR}/${d}.cer.key" 600 || FAIL=1
    fi
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
  # The panel pins the node certificate (admins paste it in Panel → Nodes).
  # A changed cert breaks panel↔node until it is pasted again, so: keep the
  # original once, and raise a loud marker whenever the node cert changes.
  mkdir -p "$NODE_DIR" || { FAIL=1; return; }
  chmod 700 "$NODE_DIR" 2>/dev/null || true
  local cur="${NODE_DIR}/ssl_cert.pem"
  if [[ -f "$cur" && ! -f "${cur}.pre-pgclocktb" ]]; then
    cp -a "$cur" "${cur}.pre-pgclocktb" || FAIL=1
    [[ -f "${NODE_DIR}/ssl_key.pem" ]] && { cp -a "${NODE_DIR}/ssl_key.pem" "${NODE_DIR}/ssl_key.pem.pre-pgclocktb" || FAIL=1; }
  fi
  if [[ -f "$cur" ]] && cmp -s "$SRC_CERT" "$cur"; then
    return 0
  fi
  install_file "$SRC_CERT" "$cur" 644 || FAIL=1
  install_file "$SRC_KEY" "${NODE_DIR}/ssl_key.pem" 600 || FAIL=1
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/node-cert-changed"
  echo "[ssl-deploy] NODE CERTIFICATE CHANGED — paste the new ${cur} into Panel → Nodes" >&2
  logger -t pgclocktb-ssl "node certificate changed: paste ${cur} into Panel -> Nodes" 2>/dev/null || true
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
  none) ;;   # deployment switched off (e.g. original node certificate restored)
  node) deploy_node ;;
  both) deploy_panel; deploy_haproxy; deploy_node ;;
  *) deploy_panel; deploy_haproxy ;;
esac
case "$ROLE" in
  none) ;;
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
STATE_DIR="${PGCTB_SSL_STATE_DIR:-/var/lib/pgclocktb/ssl}"
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
STATE_DIR="${PGCTB_SSL_STATE_DIR:-/var/lib/pgclocktb/ssl}"
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
  logger -t pgclocktb-acme "post-hook could not start: ${failed[*]}" 2>/dev/null || true
  exit 1
fi
rm -f "$FAILED"
HOOK
  chmod 700 "$SSL_PRE_HOOK" "$SSL_POST_HOOK"
}

_ssl_panel_behind_haproxy() {
  # True only when HAProxy panel mode is set up by PGClockTB: saved proxy config,
  # or the ToolBox-managed panel haproxy.cfg is active. (PasarGuard's stock
  # .env already has commented UVICORN_SSL_* lines, so .env is no signal.)
  local PROXY_ENGINE="" PROXY_MODE=""
  kv_load_file "$PROXY_CONFIG_FILE" PROXY_ENGINE PROXY_MODE
  if [[ "$PROXY_ENGINE" == "haproxy" && "$PROXY_MODE" == "panel" ]]; then
    return 0
  fi
  local cfg="${PROXY_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
  if have_cmd systemctl && systemctl is-active --quiet haproxy 2>/dev/null \
      && grep -qE '^# (PGClockTB|MrClock ToolBox) — PasarGuard panel single-port' "$cfg" 2>/dev/null; then
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
    printf '# Generated by PGClockTB (parsed, never sourced)\n'
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
  SSL_METHOD=""
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

_ssl_haproxy_acme_port() {
  # Prints the local ACME port when ToolBox HAProxy routes /.well-known/acme-challenge
  local PROXY_ACME_PORT=""
  _ssl_panel_behind_haproxy || return 1
  grep -q '^backend acme$' "${PROXY_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}" 2>/dev/null || return 1
  systemctl is-active --quiet haproxy 2>/dev/null || return 1
  kv_load_file "$PROXY_CONFIG_FILE" PROXY_ACME_PORT
  is_port "${PROXY_ACME_PORT:-18080}" || return 1
  printf '%s\n' "${PROXY_ACME_PORT:-18080}"
}

_ssl_method_args() {
  # Fills SSL_METHOD_ARGS for acme.sh from SSL_METHOD (http | dns_cf).
  # HTTP-01 behind ToolBox HAProxy: acme.sh listens on the local ACME port and
  # HAProxy forwards the challenge → HAProxy keeps running (no downtime).
  SSL_METHOD_ARGS=()
  local aport
  case "${SSL_METHOD:-http}" in
    dns_cf) SSL_METHOD_ARGS=(--dns dns_cf) ;;
    *)
      if aport="$(_ssl_haproxy_acme_port)"; then
        SSL_METHOD_ARGS=(--standalone --httpport "$aport")
      else
        SSL_METHOD_ARGS=(--standalone --pre-hook "$SSL_PRE_HOOK" --post-hook "$SSL_POST_HOOK")
      fi
      ;;
  esac
}

_ssl_acme_switch_http() {
  # _ssl_acme_switch_http haproxy PORT | standalone
  # Rewrites the saved acme.sh domain conf so CRON renewals use the same path:
  # haproxy → Le_HTTPPort=PORT, no stop/start hooks; standalone → :80 + hooks.
  local mode="$1" port="${2:-}" conf tmp n=0
  _ssl_load_config
  [[ -n "${SSL_PRIMARY:-}" && "${SSL_METHOD:-http}" == "http" ]] || return 0
  _ssl_write_acme_port_hooks
  for conf in "${SSL_ACME_HOME}/${SSL_PRIMARY}_ecc/${SSL_PRIMARY}.conf" \
              "${SSL_ACME_HOME}/${SSL_PRIMARY}/${SSL_PRIMARY}.conf"; do
    [[ -f "$conf" ]] || continue
    grep -q "^Le_Webroot='no'" "$conf" || continue   # standalone HTTP-01 only
    tmp="$(mktemp)"
    grep -vE '^Le_HTTPPort=|^Le_PreHook=|^Le_PostHook=' "$conf" >"$tmp"
    if [[ "$mode" == haproxy ]]; then
      printf "Le_HTTPPort='%s'\n" "$port" >>"$tmp"
    else
      printf "Le_HTTPPort='80'\n" >>"$tmp"
      printf "Le_PreHook='%s'\n" "$SSL_PRE_HOOK" >>"$tmp"
      printf "Le_PostHook='%s'\n" "$SSL_POST_HOOK" >>"$tmp"
    fi
    cat "$tmp" >"$conf"
    rm -f "$tmp"
    n=$((n + 1))
  done
  (( n > 0 )) && ui_info "acme.sh renewals now use: ${mode}${port:+ (local port ${port})}"
  return 0
}

_ssl_acme_cert_dir() {
  # Prints the acme.sh dir of PRIMARY for the saved key type (ecc first)
  local primary="$1" d
  case "${SSL_KEY_TYPE:-}" in
    rsa) d="${SSL_ACME_HOME}/${primary}" ;;
    ecc) d="${SSL_ACME_HOME}/${primary}_ecc" ;;
    *)
      d="${SSL_ACME_HOME}/${primary}_ecc"
      [[ -f "${d}/fullchain.cer" ]] || d="${SSL_ACME_HOME}/${primary}"
      ;;
  esac
  printf '%s\n' "$d"
}

_ssl_cert_sans() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p'
}

_ssl_existing_cert_ok() {
  # 0 when acme.sh already holds a cert for PRIMARY that is valid > 30 days and
  # lists every requested name (exact SAN match, wildcards included).
  local primary="$1"
  shift
  have_cmd openssl || return 1
  local dir cert d
  for dir in "${SSL_ACME_HOME}/${primary}_ecc" "${SSL_ACME_HOME}/${primary}"; do
    cert="${dir}/fullchain.cer"
    [[ -s "$cert" ]] || continue
    openssl x509 -in "$cert" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 || continue
    local sans
    sans=" $(_ssl_cert_sans "$cert" | tr '\n' ' ') "
    local all=1
    for d in "$@"; do
      [[ "$sans" == *" ${d} "* ]] || { all=0; break; }
    done
    (( all )) || continue
    # Staging certs are not trusted — never reuse one
    openssl x509 -in "$cert" -noout -issuer 2>/dev/null | grep -qiE 'staging|fake|\(STAGING\)' && continue
    [[ "$dir" == *_ecc ]] && SSL_KEY_TYPE=ecc || SSL_KEY_TYPE=rsa
    SSL_REUSE_EXPIRY="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
    return 0
  done
  return 1
}

_ssl_staging_test() {
  # Dry issue against Let's Encrypt STAGING (no rate limits) in a throwaway
  # cert home: nothing is deployed and the real acme.sh state is untouched.
  local -a d_args=() ; local d tmp rc=0
  for d in "$@"; do d_args+=(-d "$d"); done
  tmp="$(mktemp -d)"
  ui_info "Staging test (Let's Encrypt test CA, nothing is installed)..."
  _ssl_method_args
  PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" "$SSL_ACME_BIN" --issue --staging --force \
    --cert-home "$tmp" "${d_args[@]}" --keylength ec-256 "${SSL_METHOD_ARGS[@]}" || rc=$?
  rm -rf "$tmp"
  if (( rc == 0 )); then
    ui_success "Staging test passed — requesting the real certificate"
  else
    ui_error "Staging test failed — fix DNS / port 80 / API token first (no real request was made)"
  fi
  return "$rc"
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

  # Stage under PGClockTB state; deploy-hook copies into Panel/Node paths.
  local fullchain="${SSL_STATE_DIR}/live/fullchain.cer"
  local keyfile="${SSL_STATE_DIR}/live/key.pem"
  mkdir -p "${SSL_STATE_DIR}/live"

  if [[ "${SSL_METHOD:-http}" == "http" ]] && ! _ssl_haproxy_acme_port >/dev/null; then
    _ssl_preflight_issue "${domains[@]}" || return 1
  fi
  _ssl_write_acme_port_hooks
  rm -f "$SSL_POST_HOOK_FAILED"
  _ssl_method_args

  local reuse=0
  if [[ "${SSL_FORCE_REISSUE:-0}" != "1" ]] && _ssl_existing_cert_ok "$primary" "${domains[@]}"; then
    ui_info "A valid certificate for these names already exists (expires ${SSL_REUSE_EXPIRY})."
    if ! have_tty || ui_confirm "Reuse it instead of requesting a new one? (protects Let's Encrypt rate limits)" "Y"; then
      reuse=1
    fi
  fi

  if (( reuse == 0 )); then
    if [[ "${SSL_STAGING_FIRST:-0}" == "1" ]]; then
      _ssl_staging_test "${domains[@]}" || return 1
    fi
    ui_info "Requesting certificate for: ${domains[*]} (method: ${SSL_METHOD:-http})"
    if PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" \
        "$SSL_ACME_BIN" --issue --force --server letsencrypt "${d_args[@]}" \
        --keylength ec-256 "${SSL_METHOD_ARGS[@]}" \
        --reloadcmd "$SSL_DEPLOY_HOOK"; then
      SSL_KEY_TYPE=ecc
    else
      # Retry RSA if ECC fails on older stacks
      ui_warn "ECC issue failed — retrying with RSA 2048"
      if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" \
          "$SSL_ACME_BIN" --issue --force --server letsencrypt "${d_args[@]}" \
          --keylength 2048 "${SSL_METHOD_ARGS[@]}" \
          --reloadcmd "$SSL_DEPLOY_HOOK"; then
        if [[ "${SSL_METHOD:-http}" == "dns_cf" ]]; then
          ui_error "Certificate issuance failed. Check the Cloudflare API token (Zone:DNS:Edit) and zone."
        else
          ui_error "Certificate issuance failed. Check DNS A/AAAA records point here and port 80 is free."
        fi
        _ssl_report_post_hook || true
        return 1
      fi
      SSL_KEY_TYPE=rsa
    fi
  fi
  # Persist key type + method so install-cert / renew / repair target the right cert
  _ssl_save_config "$role" "$primary" "${domains[@]}"
  _ssl_report_post_hook || true

  ui_info "Installing certificate files + enabling auto-renew reload hook"
  local -a ecc=()
  mapfile -t ecc < <(_ssl_ecc_args "$primary")
  if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" \
      "$SSL_ACME_BIN" --install-cert -d "$primary" "${ecc[@]}" \
      --fullchain-file "$fullchain" \
      --key-file "$keyfile" \
      --reloadcmd "$SSL_DEPLOY_HOOK"; then
    ui_error "acme.sh --install-cert failed"
    return 1
  fi

  # Run deploy once now (covers node copy + multi-domain aliases)
  if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" bash "$SSL_DEPLOY_HOOK"; then
    ui_error "Deploy hook failed after install-cert"
    return 1
  fi

  # Ensure acme cron is present (installer usually adds it)
  if [[ -x "$SSL_ACME_BIN" ]]; then
    "$SSL_ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
  fi
  if [[ "${SSL_METHOD:-http}" == "http" ]]; then
    local aport
    if aport="$(_ssl_haproxy_acme_port)"; then
      _ssl_acme_switch_http haproxy "$aport" || true
    else
      _ssl_register_acme_port_hooks "$primary" || true
    fi
  fi
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
      panel_env="${SSL_PANEL_APP_DIR}/.env"
      if [[ -d "$SSL_PANEL_APP_DIR" ]]; then
        cert_path="${SSL_PANEL_CERT_DIR}/${primary}/fullchain.pem"
        key_path="${SSL_PANEL_CERT_DIR}/${primary}/privkey.pem"
        if [[ ! -f "$panel_env" ]]; then
          touch "$panel_env"
          chmod 600 "$panel_env"
        fi
        backup_file "$panel_env" 2>/dev/null || true
        if _ssl_panel_behind_haproxy; then
          # TLS is terminated at HAProxy — do NOT re-enable Uvicorn direct TLS
          local k
          for k in UVICORN_SSL_CERTFILE UVICORN_SSL_KEYFILE UVICORN_SSL_CA_TYPE UVICORN_UDS; do
            _ssl_env_comment_key "$panel_env" "$k"
          done
          ui_success "Panel behind HAProxy — left UVICORN_SSL_* commented (local HTTP)"
          ui_kv "Cert on disk" "$cert_path"
          ui_kv "Key on disk" "$key_path"
          ui_info "HAProxy PEM refreshed by deploy hook under ${SSL_HAPROXY_CERT_DIR}/"
          applied=1
        elif ! _ssl_panel_direct_tls "$panel_env" "$primary" "$cert_path" "$key_path"; then
          return 1
        else
          applied=1
        fi
      else
        ui_warn "Panel dir ${SSL_PANEL_APP_DIR} not found — skipped .env auto-update"
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
              cp -a "$node_env" "${node_env}.bak.pgclocktb.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
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

_ssl_env_get() {
  # _ssl_env_get FILE KEY → value of an ACTIVE "KEY = value" line (quotes stripped)
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1)" || return 1
  val="${line#*=}"
  val="$(trim "$val")"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s\n' "$val"
}

_ssl_cert_fp() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

_ssl_served_fp() {
  # _ssl_served_fp HOST PORT SNI → SHA-256 fingerprint of the leaf served there
  local host="$1" port="$2" sni="$3"
  echo | timeout 10 openssl s_client -connect "${host}:${port}" -servername "$sni" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

_ssl_verify_served_cert() {
  # _ssl_verify_served_cert HOST PORT SNI CERT → 0 served == CERT · 1 not · 2 cannot tell
  local host="$1" port="$2" sni="$3" cert="$4" want got i
  have_cmd openssl || return 2
  want="$(_ssl_cert_fp "$cert")"
  [[ -n "$want" ]] || return 2
  for ((i = 0; i < SSL_VERIFY_TRIES; i++)); do
    got="$(_ssl_served_fp "$host" "$port" "$sni")"
    [[ "$got" == "$want" ]] && return 0
    sleep 2
  done
  return 1
}

_ssl_panel_endpoint() {
  # Prints "HOST PORT" the panel listens on (from .env), or fails for UDS
  local env="$1" host port
  [[ -n "$(_ssl_env_get "$env" UVICORN_UDS 2>/dev/null)" ]] && return 1
  host="$(_ssl_env_get "$env" UVICORN_HOST 2>/dev/null || true)"
  port="$(_ssl_env_get "$env" UVICORN_PORT 2>/dev/null || true)"
  case "$host" in
    ""|0.0.0.0|::|"[::]") host=127.0.0.1 ;;
  esac
  is_port "${port:-8000}" || return 1
  printf '%s %s\n' "$host" "${port:-8000}"
}

_ssl_panel_sees_path() {
  # 0 = panel container mounts PATH at the same path · 1 = it does not · 2 = cannot tell
  local path="$1" cid src dst
  have_cmd docker || return 2
  cid="$(cd "$SSL_PANEL_APP_DIR" 2>/dev/null && docker compose ps -q 2>/dev/null | head -n1)"
  [[ -n "$cid" ]] || return 2
  while IFS='|' read -r src dst; do
    [[ -n "$src" ]] || continue
    if [[ "$path" == "$src" || "$path" == "${src%/}/"* ]]; then
      [[ "$src" == "$dst" ]] && return 0
    fi
  done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$cid" 2>/dev/null)
  return 1
}

_ssl_panel_direct_tls() {
  # Write UVICORN_SSL_* (official layout), restart, then require the panel to
  # serve exactly this certificate — otherwise restore .env and restart again.
  local env="$1" primary="$2" cert="$3" key="$4" rc=0 ep host="" port=""
  _ssl_panel_sees_path "$cert" || rc=$?
  if (( rc == 1 )); then
    ui_error "Panel container cannot see ${cert} (no bind mount) — .env NOT changed"
    ui_info "Mount ${SSL_PANEL_ROOT} into the panel container (the official compose does)"
    return 1
  fi
  (( rc == 2 )) && ui_info "Could not inspect panel container mounts — continuing"

  safety_txn_begin "panel-env" "$env" || return 1
  _ssl_env_upsert "$env" "UVICORN_SSL_CERTFILE" "$cert" spaced
  _ssl_env_upsert "$env" "UVICORN_SSL_KEYFILE" "$key" spaced
  _ssl_env_upsert "$env" "UVICORN_SSL_CA_TYPE" "public" spaced
  # Direct TLS mode — UDS is for reverse-proxy setups
  _ssl_env_comment_key "$env" "UVICORN_UDS"
  ui_kv "UVICORN_SSL_CERTFILE" "$cert"
  ui_kv "UVICORN_SSL_KEYFILE" "$key"
  ui_info "UVICORN_PORT left unchanged (change it yourself if you want 443)"
  _ssl_restart_compose "$SSL_PANEL_APP_DIR" "PasarGuard panel"

  rc=0
  if ep="$(_ssl_panel_endpoint "$env")"; then
    read -r host port <<<"$ep"
    ui_info "Verifying the panel serves the new certificate on ${host}:${port}..."
    _ssl_verify_served_cert "$host" "$port" "$primary" "$cert" || rc=$?
  else
    rc=2
  fi
  case "$rc" in
    0)
      safety_txn_commit
      ui_success "Panel serves the new certificate (${host}:${port})"
      ;;
    2)
      safety_txn_commit
      ui_warn "Could not verify the served certificate (no openssl / UDS) — check https://${primary}:${port:-8000}/"
      ;;
    *)
      ui_error "Panel did not serve the new certificate — restoring previous .env"
      safety_txn_rollback
      _ssl_restart_compose "$SSL_PANEL_APP_DIR" "PasarGuard panel"
      return 1
      ;;
  esac
  ui_success "Panel .env updated: ${env}"
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
      ui_kv "Panel cert" "${SSL_PANEL_CERT_DIR}/${primary}/fullchain.pem"
      ui_kv "Panel key" "${SSL_PANEL_CERT_DIR}/${primary}/privkey.pem"
      if [[ -f "${SSL_PANEL_APP_DIR}/.env" ]]; then
        ui_success "Written into ${SSL_PANEL_APP_DIR}/.env (UVICORN_SSL_* only; port untouched)"
      else
        ui_info "If you install the panel later, re-run SSL → Show .env / path instructions"
        printf '   UVICORN_SSL_CERTFILE = "%s/%s/fullchain.pem"\n' "$SSL_PANEL_CERT_DIR" "$primary"
        printf '   UVICORN_SSL_KEYFILE = "%s/%s/privkey.pem"\n' "$SSL_PANEL_CERT_DIR" "$primary"
        printf '   UVICORN_SSL_CA_TYPE = "public"\n'
      fi
      if ((${#domains[@]} > 1)); then
        ui_info "SAN aliases also on disk:"
        for d in "${domains[@]}"; do
          ui_kv "$d" "${SSL_PANEL_CERT_DIR}/${d}/fullchain.pem"
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
      ui_warn "Panel → Nodes pins this certificate: paste the NEW ${SSL_NODE_CERT_DIR}/ssl_cert.pem there,"
      ui_warn "and again after every renewal (SSL → Status shows when it changed)."
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

_ssl_choose_role() {
  # Sets SSL_CHOSEN_ROLE. Panel-only is the default; anything that replaces the
  # node certificate goes through the 🔴 node_cert gate.
  local detected="$1" choice
  SSL_CHOSEN_ROLE=""
  case "$detected" in
    panel)
      SSL_CHOSEN_ROLE=panel
      ui_info "Using Panel paths under ${SSL_PANEL_CERT_DIR}"
      ;;
    node)
      ui_warn "This server is a PasarGuard node."
      ui_risk_gate node_cert "Replace the node certificate" || return 1
      SSL_CHOSEN_ROLE=node
      ;;
    both|none)
      [[ "$detected" == none ]] && ui_warn "PasarGuard Panel/Node not detected. Choose target paths:"
      ui_menu choice "Install the certificate for:" \
        "Panel only (recommended)" \
        "Panel + Node (replaces the node certificate)" \
        "Node only (replaces the node certificate)" || return 1
      case "$choice" in
        1) SSL_CHOSEN_ROLE=panel ;;
        2) ui_risk_gate node_cert "Replace the node certificate" || return 1; SSL_CHOSEN_ROLE=both ;;
        3) ui_risk_gate node_cert "Replace the node certificate" || return 1; SSL_CHOSEN_ROLE=node ;;
        *) return 1 ;;
      esac
      ;;
  esac
  [[ -n "$SSL_CHOSEN_ROLE" ]]
}

_ssl_cf_token_ok() {
  # Ask Cloudflare whether the API token is active (sent only to api.cloudflare.com)
  local token="$1" resp
  resp="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${token}" \
    https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null || true)"
  [[ "$resp" == *'"status":"active"'* ]]
}

_ssl_choose_method() {
  # Sets SSL_METHOD (http | dns_cf); for dns_cf also exports CF_Token
  local choice token=""
  SSL_METHOD=http
  if _ssl_has_wildcard "${SSL_DOMAINS_ARR[@]}"; then
    ui_info "Wildcard names need DNS-01 — using the Cloudflare DNS API."
    SSL_METHOD=dns_cf
  else
    local hint="HTTP-01 on port 80 (recommended)"
    if _ssl_behind_cloudflare "${SSL_DOMAINS_ARR[@]}"; then
      ui_warn "Domain resolves to Cloudflare (orange cloud): HTTP-01 may not reach this server."
      hint="HTTP-01 on port 80 (may fail behind the Cloudflare proxy)"
    fi
    ui_menu choice "Validation method:" \
      "$hint" \
      "DNS-01 via Cloudflare API token (works behind CDN, no port 80)" || return 1
    [[ "$choice" == 2 ]] && SSL_METHOD=dns_cf
  fi
  [[ "$SSL_METHOD" == dns_cf ]] || return 0

  if [[ -z "${CF_Token:-}" ]]; then
    ui_info "Create a token at dash.cloudflare.com → My Profile → API Tokens"
    ui_info "Permissions: Zone → DNS → Edit, Zone → Zone → Read (for this zone)"
    ui_read_secret token "Cloudflare API token (input hidden)"
    token="$(trim "$token")"
  else
    token="$CF_Token"
  fi
  if [[ ! "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
    ui_error "That does not look like a Cloudflare API token."
    return 1
  fi
  if ! _ssl_cf_token_ok "$token"; then
    ui_error "Cloudflare did not accept the token (inactive / wrong token)."
    return 1
  fi
  ui_success "Cloudflare token is active (acme.sh stores it for renewals in its account.conf)"
  export CF_Token="$token"
  return 0
}

ssl_issue_interactive() {
  ui_step "SSL — Issue / Setup"
  if is_dry_run; then
    ui_info "[dry-run] Would issue certificates with acme.sh and enable auto-renew"
    return 0
  fi

  local detected role raw_domains email
  _ssl_load_config
  detected="$(_ssl_detect_role)"
  ui_info "Detected role: ${detected}"
  if ! _ssl_choose_role "$detected"; then
    ui_info "Back."
    return 0
  fi
  role="$SSL_CHOSEN_ROLE"

  while true; do
    ui_ask raw_domains "Domain(s) — space or comma separated" "${SSL_DOMAINS:-}"
    if _ssl_parse_domains_arg "$raw_domains"; then
      break
    fi
  done

  if ! _ssl_choose_method; then
    ui_warn "Cancelled."
    return 0
  fi

  while true; do
    ui_ask email "Email for Let's Encrypt (optional)" "${SSL_EMAIL:-}"
    email="$(trim "$email")"
    _ssl_valid_email "$email" && break
    ui_warn "Invalid email address."
  done
  SSL_EMAIL="$email"

  SSL_STAGING_FIRST=0
  if ui_confirm "Run a Let's Encrypt staging test first? (no rate limits, nothing installed)" "N"; then
    SSL_STAGING_FIRST=1
  fi

  if ! ui_confirm "Issue certificate for ${SSL_DOMAINS_ARR[*]} → role=${role}, method=${SSL_METHOD}?" "Y"; then
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
  if ! _ssl_apply_env_paths "$role" "$SSL_PRIMARY"; then
    ui_error "Certificate is installed, but the panel was NOT switched to it (previous .env restored)."
    _ssl_print_env_guide "$role" "$SSL_PRIMARY" "${SSL_DOMAINS_ARR[@]}"
    return 1
  fi
  _ssl_verify_live "$SSL_PRIMARY" || true
  _ssl_print_env_guide "$role" "$SSL_PRIMARY" "${SSL_DOMAINS_ARR[@]}"
  return 0
}

_ssl_verify_live() {
  # Check what users actually get: HAProxy (443) or the panel's own TLS port.
  local primary="$1" cert host port rc=0 env="${SSL_PANEL_APP_DIR}/.env"
  cert="${SSL_STATE_DIR}/live/fullchain.cer"
  [[ -s "$cert" ]] || return 2
  if _ssl_panel_behind_haproxy && have_cmd haproxy; then
    local PROXY_LISTEN_HTTPS=""
    kv_load_file "$PROXY_CONFIG_FILE" PROXY_LISTEN_HTTPS
    host=127.0.0.1
    port="${PROXY_LISTEN_HTTPS:-443}"
  elif [[ -n "$(_ssl_env_get "$env" UVICORN_SSL_CERTFILE 2>/dev/null)" ]]; then
    read -r host port <<<"$(_ssl_panel_endpoint "$env" 2>/dev/null)" || return 2
    [[ -n "$port" ]] || return 2
  else
    return 2
  fi
  _ssl_verify_served_cert "$host" "$port" "$primary" "$cert" || rc=$?
  case "$rc" in
    0) ui_success "Live check: ${host}:${port} serves the current certificate" ;;
    1) ui_error "Live check: ${host}:${port} does NOT serve the current certificate" ;;
  esac
  return "$rc"
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
  ui_kv "Method" "${SSL_METHOD:-http}"
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
          local pc="${SSL_PANEL_CERT_DIR}/${f}/fullchain.pem"
          [[ -f "$pc" ]] || pc="${SSL_PANEL_CERT_DIR}/${f}.cer"   # pre-0.7 layout
          if [[ -f "$pc" ]]; then
            ui_success "Panel cert OK: ${pc}"
            if have_cmd openssl; then
              openssl x509 -in "$pc" -noout -dates 2>/dev/null \
                | while read -r line; do ui_kv "  $f" "$line"; done || true
            fi
          else
            ui_warn "Missing panel cert: ${SSL_PANEL_CERT_DIR}/${f}/fullchain.pem"
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
  _ssl_report_node_cert_change || true
  _ssl_verify_live "${primary:-}" >/dev/null 2>&1 && ui_success "Live: served certificate matches" || true

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
  # HTTP-01: pre/post hooks so HAProxy (or peers) release :80. DNS-01: none.
  # acme.sh --renew uses the hooks/port SAVED in the domain conf (CLI flags are
  # ignored there), so sync the conf to the current HTTP-01 path first.
  local -a hooks=()
  if [[ "${SSL_METHOD:-http}" == "http" ]]; then
    local aport
    if aport="$(_ssl_haproxy_acme_port)"; then
      _ssl_acme_switch_http haproxy "$aport" || true
    else
      _ssl_acme_switch_http standalone || true
      hooks=(--pre-hook "$SSL_PRE_HOOK" --post-hook "$SSL_POST_HOOK")
    fi
  fi
  if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" \
       "$SSL_ACME_BIN" --renew -d "$SSL_PRIMARY" --force "${ecc[@]}" "${hooks[@]}"; then
    ui_error "Renew failed — check DNS, port 80, and logs under ${SSL_ACME_HOME}"
    _ssl_report_post_hook || true
    ui_info "Tip: SSL → Repair auto-renew, then retry Renew now"
    return 1
  fi
  local rc=0
  _ssl_report_post_hook || rc=1
  # acme.sh already ran the deploy hook; run it again to get its exit status
  # (it skips restarts when the cert did not change since that run).
  if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" bash "$SSL_DEPLOY_HOOK"; then
    ui_error "Certificate renewed, but deploy failed (see messages above)"
    rc=1
  fi
  local live=0
  _ssl_verify_live "$SSL_PRIMARY" || live=$?
  (( live == 1 )) && rc=1
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
    _ssl_apply_env_paths "${SSL_ROLE:-panel}" "$SSL_PRIMARY" \
      || ui_error "Re-apply failed — previous .env kept"
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
    if ! PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" \
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

_ssl_report_node_cert_change() {
  local m="${SSL_STATE_DIR}/node-cert-changed"
  [[ -f "$m" ]] || return 0
  ui_warn "Node certificate changed on $(cat "$m") — paste ${SSL_NODE_CERT_DIR}/ssl_cert.pem into Panel → Nodes"
  ui_info "SSL → Node certificate: show it, mark as pasted, or restore the original"
  return 1
}

ssl_node_cert_menu() {
  local choice cur="${SSL_NODE_CERT_DIR}/ssl_cert.pem"
  _ssl_load_config
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "SSL — Node certificate"
    _ssl_report_node_cert_change || true
    printf '  %s 1)%s Show current node certificate (paste into Panel → Nodes)\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 2)%s I pasted it in the panel (clear the warning)\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Restore the original node certificate (stop deploying to the node)\n' "$C_ORANGE" "$C_RESET"
    ui_menu_back_line
    printf '%sSelect%s [0-3]: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    case "$(trim "${choice:-}")" in
      1)
        ui_clear
        if [[ -f "$cur" ]]; then
          cat "$cur"
          have_cmd openssl && openssl x509 -in "$cur" -noout -subject -enddate -fingerprint -sha256 2>/dev/null
        else
          ui_warn "No node certificate at ${cur}"
        fi
        ui_pause
        ;;
      2) rm -f "${SSL_STATE_DIR}/node-cert-changed"; ui_success "Warning cleared"; sleep 1 ;;
      3) ui_clear; ssl_node_restore_original; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

ssl_node_restore_original() {
  local cur="${SSL_NODE_CERT_DIR}/ssl_cert.pem" key="${SSL_NODE_CERT_DIR}/ssl_key.pem"
  if [[ ! -f "${cur}.pre-pgclocktb" || ! -f "${key}.pre-pgclocktb" ]]; then
    ui_warn "No original node certificate was saved (PGClockTB never replaced it)."
    return 0
  fi
  ui_confirm "Restore the original node certificate and stop deploying to the node?" "N" || return 0
  cp -a "${cur}.pre-pgclocktb" "$cur" && cp -a "${key}.pre-pgclocktb" "$key" || {
    ui_error "Restore failed"; return 1; }
  # Keep panel deployment if it was on; switch node deployment off
  local new_role=none
  [[ "${SSL_ROLE:-}" == "both" ]] && new_role=panel
  local -a doms=()
  read -r -a doms <<<"${SSL_DOMAINS:-$SSL_PRIMARY}"
  if [[ -n "${SSL_PRIMARY:-}" ]]; then
    _ssl_save_config "$new_role" "$SSL_PRIMARY" "${doms[@]}"
  fi
  _ssl_restart_compose /opt/pg-node "PasarGuard node"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${SSL_STATE_DIR}/node-cert-changed"
  ui_success "Original node certificate restored (deploy role now: ${new_role})"
  ui_warn "If the panel had the replaced certificate, paste the original back into Panel → Nodes."
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
    printf '  %s 6)%s Node certificate (show / restore original)\n' "$C_ORANGE" "$C_RESET"
    ui_menu_back_line
    local choice
    printf '%sSelect%s [0-6]: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) ui_clear; ssl_issue_interactive; ui_pause ;;
      2) ui_clear; ssl_status; ui_pause ;;
      3) ui_clear; ssl_renew_now; ui_pause ;;
      4) ui_clear; ssl_show_env_guide; ui_pause ;;
      5) ui_clear; ssl_repair_autorenew; ui_pause ;;
      6) ssl_node_cert_menu ;;
      0|b|B|back|Back) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

# Compatibility entry for run_single
module_ssl() {
  ssl_menu_loop
}
