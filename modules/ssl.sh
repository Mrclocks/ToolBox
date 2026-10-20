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
SSL_ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
SSL_ACME_BIN="${SSL_ACME_BIN:-${SSL_ACME_HOME}/acme.sh}"

# --- detection / parsing ---------------------------------------------------

_ssl_detect_role() {
  # Prints: panel | node | both | none
  local has_panel=0 has_node=0
  if [[ -d /opt/pasarguard ]] || [[ -d "$SSL_PANEL_ROOT" ]] || [[ -f /opt/pasarguard/.env ]]; then
    has_panel=1
  fi
  if [[ -d /opt/pg-node ]] || [[ -d "$SSL_NODE_ROOT" ]] || [[ -f /opt/pg-node/docker-compose.yml ]]; then
    has_node=1
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
  cat >"$SSL_DEPLOY_HOOK" <<'HOOK'
#!/usr/bin/env bash
# MrClock SSL deploy hook — runs after issue/renew
set -euo pipefail
STATE_DIR="${SECUREBOX_SSL_STATE_DIR:-/var/lib/securebox/ssl}"
CONFIG="${STATE_DIR}/config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "[ssl-deploy] missing config: $CONFIG" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

PANEL_DIR="${SSL_PANEL_CERT_DIR:-/var/lib/pasarguard/certs}"
NODE_DIR="${SSL_NODE_CERT_DIR:-/var/lib/pg-node/certs}"
PRIMARY="${SSL_PRIMARY:-}"
ROLE="${SSL_ROLE:-panel}"
DOMAINS="${SSL_DOMAINS:-$PRIMARY}"
LIVE_DIR="${STATE_DIR}/live"

if [[ -z "$PRIMARY" ]]; then
  echo "[ssl-deploy] SSL_PRIMARY empty" >&2
  exit 1
fi

SRC_CERT="${LIVE_DIR}/fullchain.cer"
SRC_KEY="${LIVE_DIR}/key.pem"

# Prefer paths exported by acme.sh --reloadcmd
if [[ -n "${CERT_FULLCHAIN_PATH:-}" && -f "${CERT_FULLCHAIN_PATH}" ]]; then
  SRC_CERT="$CERT_FULLCHAIN_PATH"
fi
if [[ -n "${CERT_KEY_PATH:-}" && -f "${CERT_KEY_PATH}" ]]; then
  SRC_KEY="$CERT_KEY_PATH"
fi

if [[ ! -f "$SRC_CERT" || ! -f "$SRC_KEY" ]]; then
  # Fallback: panel copies, then acme.sh home
  if [[ -f "${PANEL_DIR}/${PRIMARY}.cer" && -f "${PANEL_DIR}/${PRIMARY}.cer.key" ]]; then
    SRC_CERT="${PANEL_DIR}/${PRIMARY}.cer"
    SRC_KEY="${PANEL_DIR}/${PRIMARY}.cer.key"
  else
    ACME_HOME="${SSL_ACME_HOME:-/root/.acme.sh}"
    for cand in \
      "${ACME_HOME}/${PRIMARY}_ecc/fullchain.cer" \
      "${ACME_HOME}/${PRIMARY}/fullchain.cer"; do
      if [[ -f "$cand" ]]; then
        SRC_CERT="$cand"
        break
      fi
    done
    for cand in \
      "${ACME_HOME}/${PRIMARY}_ecc/${PRIMARY}.key" \
      "${ACME_HOME}/${PRIMARY}/${PRIMARY}.key"; do
      if [[ -f "$cand" ]]; then
        SRC_KEY="$cand"
        break
      fi
    done
  fi
fi

if [[ ! -f "$SRC_CERT" || ! -f "$SRC_KEY" ]]; then
  echo "[ssl-deploy] cert/key not found for ${PRIMARY}" >&2
  exit 1
fi

# Keep a stable live copy for future renews
mkdir -p "$LIVE_DIR"
if [[ "$SRC_CERT" != "${LIVE_DIR}/fullchain.cer" ]]; then
  cp -f "$SRC_CERT" "${LIVE_DIR}/fullchain.cer"
fi
if [[ "$SRC_KEY" != "${LIVE_DIR}/key.pem" ]]; then
  cp -f "$SRC_KEY" "${LIVE_DIR}/key.pem"
fi
chmod 600 "${LIVE_DIR}/key.pem"
SRC_CERT="${LIVE_DIR}/fullchain.cer"
SRC_KEY="${LIVE_DIR}/key.pem"

deploy_panel() {
  mkdir -p "$PANEL_DIR"
  local d
  for d in $DOMAINS; do
    cp -f "$SRC_CERT" "${PANEL_DIR}/${d}.cer"
    cp -f "$SRC_KEY" "${PANEL_DIR}/${d}.cer.key"
    chmod 644 "${PANEL_DIR}/${d}.cer"
    chmod 600 "${PANEL_DIR}/${d}.cer.key"
  done
  # Combined PEM for HAProxy (ToolBox Reverse Proxy reads /etc/haproxy/certs/)
  mkdir -p /etc/haproxy/certs 2>/dev/null || true
  if [[ -d /etc/haproxy/certs ]]; then
    local d
    for d in $DOMAINS; do
      cat "$SRC_CERT" "$SRC_KEY" >"/etc/haproxy/certs/${d}.pem"
      chmod 600 "/etc/haproxy/certs/${d}.pem"
    done
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet haproxy 2>/dev/null; then
      systemctl reload haproxy >/dev/null 2>&1 || true
    fi
  fi
}

deploy_node() {
  mkdir -p "$NODE_DIR"
  cp -f "$SRC_CERT" "${NODE_DIR}/ssl_cert.pem"
  cp -f "$SRC_KEY" "${NODE_DIR}/ssl_key.pem"
  chmod 644 "${NODE_DIR}/ssl_cert.pem"
  chmod 600 "${NODE_DIR}/ssl_key.pem"
}

case "$ROLE" in
  panel) deploy_panel ;;
  node) deploy_node ;;
  both) deploy_panel; deploy_node ;;
  *) deploy_panel ;;
esac

# Soft-reload PasarGuard containers when compose is present
reload_compose() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  [[ -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] || return 0
  if command -v docker >/dev/null 2>&1; then
    (cd "$dir" && docker compose restart >/dev/null 2>&1) \
      || (cd "$dir" && docker-compose restart >/dev/null 2>&1) \
      || true
  fi
}

case "$ROLE" in
  panel|both) reload_compose /opt/pasarguard ;;
esac
case "$ROLE" in
  node|both) reload_compose /opt/pg-node ;;
esac

date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/last_deploy.txt"
echo "[ssl-deploy] OK role=${ROLE} primary=${PRIMARY}"
HOOK
  chmod 700 "$SSL_DEPLOY_HOOK"
}

_ssl_save_config() {
  local role="$1"
  local primary="$2"
  shift 2
  local domains=("$@")
  local joined
  joined="$(printf '%s ' "${domains[@]}")"
  joined="$(trim "$joined")"
  _ssl_ensure_dirs "$role"
  cat >"$SSL_CONFIG_FILE" <<EOF
# Generated by MrClock ToolBox — do not edit by hand unless you know why
SSL_ROLE=${role}
SSL_PRIMARY=${primary}
SSL_DOMAINS="${joined}"
SSL_PANEL_CERT_DIR=${SSL_PANEL_CERT_DIR}
SSL_NODE_CERT_DIR=${SSL_NODE_CERT_DIR}
SSL_ACME_HOME=${SSL_ACME_HOME}
SSL_EMAIL=${SSL_EMAIL:-}
EOF
  chmod 600 "$SSL_CONFIG_FILE"
  _ssl_write_deploy_hook
}

_ssl_load_config() {
  SSL_ROLE=""
  SSL_PRIMARY=""
  SSL_DOMAINS=""
  SSL_EMAIL=""
  if [[ -f "$SSL_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SSL_CONFIG_FILE"
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

  if _ssl_port80_busy; then
    ui_warn "Port 80 is in use. ACME HTTP-01 (standalone) needs port 80 free."
    if have_tty; then
      if ! ui_confirm "Continue anyway? (stop whatever holds :80 first, or this will fail)" "N"; then
        ui_error "Aborted — free port 80, then retry."
        return 1
      fi
    else
      ui_error "Port 80 busy and no TTY to confirm. Aborting."
      return 1
    fi
  fi

  ui_info "Requesting certificate for: ${domains[*]}"
  if ! "$SSL_ACME_BIN" --issue --force --standalone "${d_args[@]}" \
      --keylength ec-256; then
    # Retry RSA if ECC fails on older stacks
    ui_warn "ECC issue failed — retrying with RSA 2048"
    if ! "$SSL_ACME_BIN" --issue --force --standalone "${d_args[@]}" \
        --keylength 2048; then
      ui_error "Certificate issuance failed. Check DNS A/AAAA records point here and port 80 is free."
      return 1
    fi
  fi

  ui_info "Installing certificate files + enabling auto-renew reload hook"
  if ! "$SSL_ACME_BIN" --install-cert -d "$primary" \
      --ecc \
      --fullchain-file "$fullchain" \
      --key-file "$keyfile" \
      --reloadcmd "$SSL_DEPLOY_HOOK" 2>/dev/null; then
    # Non-ECC fallback
    if ! "$SSL_ACME_BIN" --install-cert -d "$primary" \
        --fullchain-file "$fullchain" \
        --key-file "$keyfile" \
        --reloadcmd "$SSL_DEPLOY_HOOK"; then
      ui_error "acme.sh --install-cert failed"
      return 1
    fi
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
  return 0
}

_ssl_print_env_guide() {
  local role="$1"
  local primary="$2"
  shift 2
  local -a domains=("$@")
  local d panel_env node_compose

  ui_box_start "How to set certificate paths"
  case "$role" in
    panel|both)
      panel_env="/opt/pasarguard/.env"
      ui_info "Panel — edit ${panel_env} (or create keys if missing):"
      echo
      printf '   UVICORN_SSL_CERTFILE = "%s/%s.cer"\n' "$SSL_PANEL_CERT_DIR" "$primary"
      printf '   UVICORN_SSL_KEYFILE  = "%s/%s.cer.key"\n' "$SSL_PANEL_CERT_DIR" "$primary"
      printf '   UVICORN_PORT = 443\n'
      echo
      if ((${#domains[@]} > 1)); then
        ui_info "Same certificate covers all domains (SAN). Per-domain copies also exist:"
        for d in "${domains[@]}"; do
          ui_kv "$d" "${SSL_PANEL_CERT_DIR}/${d}.cer + ${d}.cer.key"
        done
        echo
      fi
      ui_info "Then restart the panel:"
      printf '   cd /opt/pasarguard && docker compose restart\n'
      echo
      ;;
  esac
  case "$role" in
    node|both)
      node_compose="/opt/pg-node/docker-compose.yml"
      ui_info "Node — certificate files are ready at:"
      ui_kv "SSL_CERT_FILE" "${SSL_NODE_CERT_DIR}/ssl_cert.pem"
      ui_kv "SSL_KEY_FILE" "${SSL_NODE_CERT_DIR}/ssl_key.pem"
      echo
      ui_info "In ${node_compose} (or node .env / environment), set:"
      echo
      printf '   SSL_CERT_FILE: "%s/ssl_cert.pem"\n' "$SSL_NODE_CERT_DIR"
      printf '   SSL_KEY_FILE:  "%s/ssl_key.pem"\n' "$SSL_NODE_CERT_DIR"
      echo
      ui_info "In the PasarGuard panel → Nodes → this node, use the same paths if asked."
      ui_info "Then restart the node:"
      printf '   cd /opt/pg-node && docker compose restart\n'
      echo
      ;;
  esac
  ui_info "Auto-renew is ON (acme.sh cron). After each renew, files are redeployed automatically."
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
      ui_menu choice "This server looks like Panel + Node. Apply certs to:" \
        "Panel only" \
        "Node only" \
        "Both (recommended)"
      case "$choice" in
        1) role=panel ;;
        2) role=node ;;
        3) role=both ;;
      esac
      ;;
    none)
      ui_warn "PasarGuard Panel/Node not detected. Choose target paths:"
      ui_menu choice "Install certificates for:" \
        "Panel paths (/var/lib/pasarguard/certs)" \
        "Node paths (/var/lib/pg-node/certs)" \
        "Both"
      case "$choice" in
        1) role=panel ;;
        2) role=node ;;
        3) role=both ;;
      esac
      ;;
  esac

  while true; do
    ui_ask raw_domains "Domain(s) — space or comma separated" ""
    if _ssl_parse_domains_arg "$raw_domains"; then
      break
    fi
  done

  ui_ask email "Email for Let's Encrypt (optional)" "${SSL_EMAIL:-}"
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
        # shellcheck disable=SC2086
        for f in ${domain_list:-$primary}; do
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
  ui_info "Forcing renew for ${SSL_PRIMARY}..."
  if "$SSL_ACME_BIN" --renew -d "$SSL_PRIMARY" --force --ecc 2>/dev/null \
     || "$SSL_ACME_BIN" --renew -d "$SSL_PRIMARY" --force; then
    SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" bash "$SSL_DEPLOY_HOOK" || true
    ui_success "Renew + deploy completed"
    local -a doms=()
    # shellcheck disable=SC2206
    doms=(${SSL_DOMAINS:-$SSL_PRIMARY})
    _ssl_print_env_guide "${SSL_ROLE:-panel}" "$SSL_PRIMARY" "${doms[@]}"
    return 0
  fi
  ui_error "Renew failed — see acme.sh logs under ${SSL_ACME_HOME}"
  return 1
}

ssl_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    printf '%sSSL Certificates%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    ui_line 56 '-'
    printf '  %s 1)%s Issue / Setup (recommended)\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Status\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Renew now\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 0)%s Back\n' "$C_YELLOW" "$C_RESET"
    ui_line 56 '-'
    local choice
    printf '%sSelect%s: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-0}")"
    case "$choice" in
      1) ui_clear; ssl_issue_interactive; ui_pause ;;
      2) ui_clear; ssl_status; ui_pause ;;
      3) ui_clear; ssl_renew_now; ui_pause ;;
      0|b|B) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

# Compatibility entry for run_single
module_ssl() {
  ssl_menu_loop
}
