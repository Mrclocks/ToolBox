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
  PROXY_BIND_IPV6=yes
  PROXY_HAPROXY_CFG_LAST="${PROXY_STATE_DIR}/haproxy.cfg.last"
  SSL_CONFIG_FILE="${SECUREBOX_STATE_DIR}/ssl/config.env"
  SSL_PANEL_CERT_DIR="${SECUREBOX_STATE_DIR}/no-panel-certs"
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
  make_cert "${SECUREBOX_STATE_DIR}/ssl/live" panel.example.com sub.example.com
  run _proxy_sync_pem_from_ssl "panel.example.com"
  [ "$status" -eq 0 ]
  [ -f "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem" ]
  grep -q 'BEGIN CERTIFICATE' "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem"
  grep -q 'PRIVATE KEY' "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem"
  [ "$(stat -c %a "${PROXY_HAPROXY_CERT_DIR}/panel.example.com.pem")" = "600" ]
}

@test "_proxy_sync_pem_from_ssl refuses a cert that does not cover the domain" {
  make_cert "${SECUREBOX_STATE_DIR}/ssl/live" panel.example.com
  run _proxy_sync_pem_from_ssl "other.example.net"
  [ "$status" -ne 0 ]
  [ ! -f "${PROXY_HAPROXY_CERT_DIR}/other.example.net.pem" ]
}

@test "_proxy_sync_pem_from_ssl refuses a key that does not match the cert" {
  local live="${SECUREBOX_STATE_DIR}/ssl/live"
  make_cert "$live" panel.example.com
  make_cert "${SECUREBOX_STATE_DIR}/other" panel.example.com
  cp "${SECUREBOX_STATE_DIR}/other/key.pem" "${live}/key.pem"
  run _proxy_sync_pem_from_ssl "panel.example.com"
  [ "$status" -ne 0 ]
}

@test "_proxy_ensure_certs_for_domains fails when any domain is missing" {
  make_cert "${SECUREBOX_STATE_DIR}/ssl/live" panel.example.com
  run _proxy_ensure_certs_for_domains panel.example.com sub.example.com
  [ "$status" -ne 0 ]
  run _proxy_ensure_certs_for_domains panel.example.com
  [ "$status" -eq 0 ]
}

@test "proxy config.env is parsed, never executed" {
  local marker="${BATS_TEST_TMPDIR}/pwned"
  PROXY_ENGINE=haproxy
  PROXY_MODE=panel
  PROXY_EXTRA_PORTS="8443 9443"
  PROXY_EXTRA_PLAIN_PORTS="9000"
  PROXY_PANEL_DOMAIN="\$(touch ${marker})"
  _proxy_save_config
  PROXY_EXTRA_PORTS=""
  PROXY_PANEL_DOMAIN=""
  _proxy_load_config
  [ "$PROXY_EXTRA_PORTS" = "8443 9443" ]
  [ "$PROXY_EXTRA_PLAIN_PORTS" = "9000" ]
  [ "$PROXY_PANEL_DOMAIN" = "\$(touch ${marker})" ]
  [ ! -e "$marker" ]
  # Unknown keys in the file are ignored
  printf 'PATH=/nowhere\n' >>"$PROXY_CONFIG_FILE"
  _proxy_load_config
  [ "$PATH" != "/nowhere" ]
}

@test "_proxy_clean_ports keeps valid unique ports and drops listen ports" {
  run _proxy_clean_ports "8443, 443 abc 8443 70000 9000 0 080" 443 80
  [ "$output" = "8443 9000" ]
}

@test "invalid haproxy config is rolled back (or moved aside if no previous)" {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' >"${bin}/haproxy"
  chmod +x "${bin}/haproxy"
  PATH="${bin}:$PATH"
  # No previous config at all → invalid file must not stay in place
  rm -f "$PROXY_HAPROXY_CFG" "$PROXY_HAPROXY_CFG_LAST"
  _proxy_write_haproxy_node_cfg "443" "" "127.0.0.1:12000" "127.0.0.1:11000"
  run _proxy_haproxy_validate_and_start
  [ "$status" -ne 0 ]
  [ ! -f "$PROXY_HAPROXY_CFG" ]
  # Previous config present → it is restored
  printf 'previous\n' >"$PROXY_HAPROXY_CFG"
  _proxy_write_haproxy_node_cfg "443" "" "127.0.0.1:12000" "127.0.0.1:11000"
  run _proxy_haproxy_validate_and_start
  [ "$status" -ne 0 ]
  [ "$(cat "$PROXY_HAPROXY_CFG")" = "previous" ]
}

@test "_proxy_bind falls back to IPv4 when IPv6 is unavailable" {
  PROXY_BIND_IPV6=no
  _proxy_write_haproxy_panel_cfg "panel.example.com" "" "127.0.0.1" "8000" "443" "80" "8443" "9000"
  grep -q 'bind 0.0.0.0:443 ssl crt' "$PROXY_HAPROXY_CFG"
  grep -q 'bind 0.0.0.0:9000$' "$PROXY_HAPROXY_CFG"
  ! grep -q ':::' "$PROXY_HAPROXY_CFG"
}

@test "generated panel config passes real haproxy -c (when installed)" {
  command -v haproxy >/dev/null 2>&1 || skip "haproxy not installed"
  make_cert "${SECUREBOX_STATE_DIR}/ssl/live" panel.example.com sub.example.com
  _proxy_ensure_certs_for_domains panel.example.com sub.example.com
  _proxy_write_haproxy_panel_cfg \
    "panel.example.com" "sub.example.com" "127.0.0.1" "8000" "443" "80" "8443" "9000"
  # Drop privileges/log lines that need a real system user/socket
  sed -i '/^    user haproxy/d;/^    group haproxy/d' "$PROXY_HAPROXY_CFG"
  run haproxy -c -f "$PROXY_HAPROXY_CFG"
  [ "$status" -eq 0 ]
}

@test "_proxy_write_haproxy_panel_cfg matches official single-port shape" {
  _proxy_write_haproxy_panel_cfg \
    "panel.example.com" "sub.example.com" "127.0.0.1" "8000" "443" "80" "8443" "9000"
  [ -f "$PROXY_HAPROXY_CFG" ]
  grep -q 'listen front' "$PROXY_HAPROXY_CFG"
  grep -q 'panel.example.com' "$PROXY_HAPROXY_CFG"
  grep -q 'sub.example.com' "$PROXY_HAPROXY_CFG"
  grep -q '127.0.0.1:8000' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::443' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::80' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::8443' "$PROXY_HAPROXY_CFG"
  grep -q 'bind :::9000 v4v6' "$PROXY_HAPROXY_CFG"
  # Host ACL must ignore :port (browsers send Host: domain:8443)
  grep -q 'acl host_panel hdr(host),field(1,:) -i panel.example.com' "$PROXY_HAPROXY_CFG"
  grep -q 'acl host_sub hdr(host),field(1,:) -i sub.example.com' "$PROXY_HAPROXY_CFG"
  grep -q 'path_beg /sub/' "$PROXY_HAPROXY_CFG"
  grep -q 'deny_backend' "$PROXY_HAPROXY_CFG"
  # Docs keep HTTP on :80 — we must NOT force redirect
  ! grep -q 'redirect scheme https' "$PROXY_HAPROXY_CFG"
}

@test "_proxy_write_haproxy_node_cfg uses TCP listen and send-proxy" {
  _proxy_write_haproxy_node_cfg "443" "reality.com" "127.0.0.1:12000" "127.0.0.1:11000"
  grep -q 'listen front_node' "$PROXY_HAPROXY_CFG"
  grep -q 'mode tcp' "$PROXY_HAPROXY_CFG"
  grep -q 'reality.com' "$PROXY_HAPROXY_CFG"
  grep -q 'send-proxy' "$PROXY_HAPROXY_CFG"
  grep -q '127.0.0.1:12000' "$PROXY_HAPROXY_CFG"
  grep -q 'tcp-request inspect-delay' "$PROXY_HAPROXY_CFG"
}

@test "proxy menu is HAProxy-only (no Caddy/Nginx)" {
  grep -q 'Setup HAProxy' "${REPO_ROOT}/modules/proxy.sh"
  grep -q 'Status / Remove' "${REPO_ROOT}/modules/proxy.sh"
  grep -q '_proxy_warn_conflicts' "${REPO_ROOT}/modules/proxy.sh"
  grep -q 'Reverse Proxy (HAProxy)' "${REPO_ROOT}/modules/proxy.sh"
  ! grep -qE 'proxy_setup_caddy|proxy_setup_nginx|Setup Caddy|Setup Nginx' "${REPO_ROOT}/modules/proxy.sh"
  ! grep -qE 'PROXY_CADDYFILE|PROXY_NGINX_SITE' "${REPO_ROOT}/modules/proxy.sh"
}

@test "_proxy_valid_host and hostport reject junk" {
  _proxy_valid_host "127.0.0.1"
  _proxy_valid_host "localhost"
  ! _proxy_valid_host "bad host"
  ! _proxy_valid_host '$(reboot)'
  _proxy_valid_hostport "127.0.0.1:12000"
  ! _proxy_valid_hostport "127.0.0.1"
  ! _proxy_valid_hostport "host:99999"
}
