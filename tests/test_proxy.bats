#!/usr/bin/env bats
# Reverse proxy helper unit tests

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/proxy.sh"
  PROXY_STATE_DIR="${SECUREBOX_STATE_DIR}/proxy"
  PROXY_CONFIG_FILE="${PROXY_STATE_DIR}/config.env"
  PROXY_HAPROXY_CERT_DIR="${SECUREBOX_STATE_DIR}/haproxy-certs"
  PROXY_HAPROXY_CFG="${SECUREBOX_STATE_DIR}/haproxy.cfg"
  PROXY_HAPROXY_CFG_BAK="${PROXY_STATE_DIR}/haproxy.cfg.pre-mrclock"
  mkdir -p "$PROXY_STATE_DIR" "$PROXY_HAPROXY_CERT_DIR"
}

@test "_proxy_valid_domain accepts FQDN" {
  _proxy_valid_domain "panel.example.com"
  ! _proxy_valid_domain "nope"
}

@test "_proxy_save_config and load roundtrip" {
  PROXY_ENGINE=haproxy
  PROXY_MODE=panel
  PROXY_PANEL_DOMAIN=panel.example.com
  PROXY_SUB_DOMAIN=sub.example.com
  PROXY_BACKEND_HOST=127.0.0.1
  PROXY_BACKEND_PORT=8000
  PROXY_LISTEN_HTTPS=443
  PROXY_LISTEN_HTTP=80
  PROXY_EXTRA_PORTS="8443"
  _proxy_save_config
  PROXY_ENGINE=""
  PROXY_PANEL_DOMAIN=""
  _proxy_load_config
  [ "$PROXY_ENGINE" = "haproxy" ]
  [ "$PROXY_PANEL_DOMAIN" = "panel.example.com" ]
  [ "$PROXY_SUB_DOMAIN" = "sub.example.com" ]
  [ "$PROXY_BACKEND_PORT" = "8000" ]
}

@test "_proxy_sync_pem_from_ssl builds combined PEM from live SSL" {
  local live="${SECUREBOX_STATE_DIR}/ssl/live"
  mkdir -p "$live"
  printf 'FULLCHAIN\n' >"${live}/fullchain.cer"
  printf 'PRIVKEY\n' >"${live}/key.pem"
  run _proxy_sync_pem_from_ssl "panel.example.com"
  [ "$status" -eq 0 ]
  [ -f "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem" ]
  grep -q 'FULLCHAIN' "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem"
  grep -q 'PRIVKEY' "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem"
}

@test "_proxy_write_haproxy_panel_cfg contains domains and backend" {
  _proxy_write_haproxy_panel_cfg \
    "panel.example.com" "sub.example.com" "127.0.0.1" "8000" "443" "80" "8443"
  [ -f "$PROXY_HAPROXY_CFG" ]
  grep -q 'panel.example.com' "$PROXY_HAPROXY_CFG"
  grep -q 'sub.example.com' "$PROXY_HAPROXY_CFG"
  grep -q '127.0.0.1:8000' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::443' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::8443' "$PROXY_HAPROXY_CFG"
  grep -q 'deny_backend' "$PROXY_HAPROXY_CFG"
}

@test "_proxy_write_haproxy_node_cfg uses TCP and send-proxy" {
  _proxy_write_haproxy_node_cfg "443" "reality.com" "127.0.0.1:12000" "127.0.0.1:11000"
  grep -q 'mode tcp' "$PROXY_HAPROXY_CFG"
  grep -q 'reality.com' "$PROXY_HAPROXY_CFG"
  grep -q 'send-proxy' "$PROXY_HAPROXY_CFG"
  grep -q '127.0.0.1:12000' "$PROXY_HAPROXY_CFG"
}

@test "proxy menu entries are wired in install.sh" {
  grep -q 'Setup HAProxy' "${REPO_ROOT}/modules/proxy.sh"
  grep -q 'Setup Caddy' "${REPO_ROOT}/modules/proxy.sh"
  grep -q 'Setup Nginx' "${REPO_ROOT}/modules/proxy.sh"
  grep -q 'Status / Remove' "${REPO_ROOT}/modules/proxy.sh"
}
