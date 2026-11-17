#!/usr/bin/env bats
# HAProxy v2 (0.8.0): auto-detect, port conflicts, ACME route (no downtime),
# verify through HAProxy with full rollback, Remove restores the panel.

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/proxy.sh"
  T="$BATS_TEST_TMPDIR"
  PROXY_STATE_DIR="${T}/proxy"
  PROXY_CONFIG_FILE="${PROXY_STATE_DIR}/config.env"
  PROXY_HAPROXY_CERT_DIR="${T}/haproxy-certs"
  PROXY_HAPROXY_CFG="${T}/haproxy.cfg"
  PROXY_HAPROXY_CFG_BAK="${PROXY_STATE_DIR}/haproxy.cfg.pre-mrclock"
  PROXY_HAPROXY_CFG_LAST="${PROXY_STATE_DIR}/haproxy.cfg.last"
  PROXY_PANEL_APP_DIR="${T}/opt-pasarguard"
  PROXY_PANEL_ENV_SNAPSHOT="${PROXY_STATE_DIR}/panel.env.pre-haproxy"
  PROXY_BIND_IPV6=no
  PROXY_VERIFY_TRIES=1
  SSL_STATE_DIR="${PGCTB_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_ACME_HOME="${T}/acme"
  SSL_PRE_HOOK="${SSL_STATE_DIR}/pre.sh"
  SSL_POST_HOOK="${SSL_STATE_DIR}/post.sh"
  SSL_DEPLOY_HOOK="${SSL_STATE_DIR}/deploy.sh"
  SSL_PANEL_CERT_DIR="${T}/no-certs"
  mkdir -p "$PROXY_STATE_DIR" "$PROXY_HAPROXY_CERT_DIR" "$PROXY_PANEL_APP_DIR" "$SSL_STATE_DIR"
  printf 'UVICORN_HOST = "0.0.0.0"\nUVICORN_PORT = 443\nUVICORN_SSL_CERTFILE = "/x/fullchain.pem"\n' \
    >"${PROXY_PANEL_APP_DIR}/.env"
  cp "${PROXY_PANEL_APP_DIR}/.env" "${T}/env.orig"
}

@test "panel port is read from .env" {
  [ "$(_proxy_detect_panel_port)" = 443 ]
  printf 'UVICORN_PORT = 8000\n' >"${PROXY_PANEL_APP_DIR}/.env"
  [ "$(_proxy_detect_panel_port)" = 8000 ]
}

@test "port conflicts: other owners refused, panel's own port and haproxy allowed" {
  _proxy_port_owner() {
    case "$1" in 443) echo xray ;; 80) echo haproxy ;; 8443) echo python3 ;; *) echo "" ;; esac
  }
  run _proxy_check_port_conflicts 8000 443 80
  [ "$status" -ne 0 ]
  _proxy_check_port_conflicts 8443 8443 80 9000
}

@test "panel config routes ACME challenges to the local acme.sh port" {
  PROXY_ACME_PORT=18099
  _proxy_write_haproxy_panel_cfg panel.example.com "" 127.0.0.1 8000 443 80 "" ""
  grep -q 'acl acme_challenge path_beg /.well-known/acme-challenge/' "$PROXY_HAPROXY_CFG"
  grep -q 'use_backend acme if acme_challenge' "$PROXY_HAPROXY_CFG"
  grep -q 'server acme 127.0.0.1:18099' "$PROXY_HAPROXY_CFG"
  # ACME rule comes before the host rules (any Host on :80)
  local a h
  a="$(grep -n 'use_backend acme' "$PROXY_HAPROXY_CFG" | cut -d: -f1)"
  h="$(grep -n 'use_backend panel' "$PROXY_HAPROXY_CFG" | cut -d: -f1)"
  (( a < h ))
}

@test "real HAProxy: ACME forwarded, panel reachable, unknown host 403 (verify_through)" {
  command -v haproxy >/dev/null || skip "haproxy not installed"
  command -v python3 >/dev/null || skip "python3 missing"
  local base=$(( 30000 + RANDOM % 20000 ))
  local panel=$base https=$((base+1)) http=$((base+2)) acme=$((base+3))
  mkdir -p "${T}/www/.well-known/acme-challenge" "${T}/panel"
  echo TOKEN-OK >"${T}/www/.well-known/acme-challenge/tok"
  echo PANEL >"${T}/panel/index.html"
  (cd "${T}/www" && exec python3 -m http.server "$acme" --bind 127.0.0.1) >/dev/null 2>&1 &
  local p1=$!
  (cd "${T}/panel" && exec python3 -m http.server "$panel" --bind 127.0.0.1) >/dev/null 2>&1 &
  local p2=$!
  make_cert "${PGCTB_STATE_DIR}/ssl/live" panel.example.com
  _proxy_ensure_certs_for_domains panel.example.com
  PROXY_ACME_PORT="$acme"
  _proxy_write_haproxy_panel_cfg panel.example.com "" 127.0.0.1 "$panel" "$https" "$http" "" ""
  sed -i '/^    user /d;/^    group /d;/^    daemon/d;s/maxconn 50000/maxconn 500/;s#log /dev/log local0##' "$PROXY_HAPROXY_CFG"
  haproxy -f "$PROXY_HAPROXY_CFG" -D -p "${T}/hp.pid" >/dev/null 2>&1
  command sleep 1
  local tok
  tok="$(curl --noproxy '*' -s -H 'Host: panel.example.com' "http://127.0.0.1:${http}/.well-known/acme-challenge/tok" || true)"
  PROXY_VERIFY_TRIES=5
  local vr=0
  sleep() { command sleep "$@"; }
  NO_PROXY='*' no_proxy='*' _proxy_verify_through panel.example.com "$https" >/dev/null || vr=$?
  kill "$(cat "${T}/hp.pid")" "$p1" "$p2" 2>/dev/null || true
  [ "$tok" = TOKEN-OK ]
  [ "$vr" -eq 0 ]
}

stub_setup_world() {
  ui_ask() { printf -v "$1" '%s' "${3:-}"; }
  ui_ask_port() { printf -v "$1" '%s' "${3:-}"; }
  ui_confirm() { return 0; }
  _proxy_warn_conflicts() { :; }
  _proxy_install_haproxy() { :; }
  _proxy_ensure_certs_for_domains() { :; }
  _proxy_port_owner() { :; }
  _proxy_haproxy_validate_and_start() { echo started >>"${T}/hp.log"; }
  _ssl_restart_compose() { echo restart >>"${T}/panel.log"; }
  systemctl() { echo "systemctl $*" >>"${T}/hp.log"; [[ "$1" != is-active ]]; }
  PROXY_PANEL_DOMAIN=panel.example.com
  echo "# previous haproxy" >"$PROXY_HAPROXY_CFG"
  cp "$PROXY_HAPROXY_CFG" "${T}/cfg.orig"
}

@test "setup: panel on 443 moves to 8000; verify failure rolls back cfg, .env and state" {
  stub_setup_world
  _proxy_verify_through() { return 1; }
  run _proxy_setup_panel
  [ "$status" -ne 0 ]
  cmp "$PROXY_HAPROXY_CFG" "${T}/cfg.orig"
  cmp "${PROXY_PANEL_APP_DIR}/.env" "${T}/env.orig"
  [ ! -f "$PROXY_CONFIG_FILE" ]
  grep -q 'systemctl stop haproxy' "${T}/hp.log"       # it was not running before
}

@test "setup success: panel local on 8000, snapshot kept, Remove restores the panel" {
  stub_setup_world
  _proxy_verify_through() { return 0; }
  _ssl_acme_switch_http() { echo "switch $*" >>"${T}/acme.log"; }
  _proxy_setup_panel
  grep -q '^UVICORN_PORT = 8000' "${PROXY_PANEL_APP_DIR}/.env"
  grep -q '^# UVICORN_SSL_CERTFILE' "${PROXY_PANEL_APP_DIR}/.env"
  grep -q 'server srv1 127.0.0.1:8000' "$PROXY_HAPROXY_CFG"
  cmp "$PROXY_PANEL_ENV_SNAPSHOT" "${T}/env.orig"
  grep -q 'switch haproxy 18080' "${T}/acme.log"
  # Remove gives the panel back its own TLS listener
  proxy_remove
  cmp "${PROXY_PANEL_APP_DIR}/.env" "${T}/env.orig"
  grep -q 'switch standalone' "${T}/acme.log"
}

@test "acme conf switch: haproxy port vs standalone hooks; DNS-01 confs untouched" {
  mkdir -p "${SSL_ACME_HOME}/example.com_ecc" "${SSL_ACME_HOME}/dns.example_ecc"
  local c="${SSL_ACME_HOME}/example.com_ecc/example.com.conf"
  printf "Le_Domain='example.com'\nLe_Webroot='no'\nLe_HTTPPort='80'\nLe_PreHook='x'\n" >"$c"
  printf 'SSL_PRIMARY=example.com\nSSL_METHOD=http\nSSL_ACME_HOME=%s\n' "$SSL_ACME_HOME" >"$SSL_CONFIG_FILE"
  _ssl_acme_switch_http haproxy 18080
  grep -q "^Le_HTTPPort='18080'$" "$c"
  ! grep -q '^Le_PreHook' "$c"
  _ssl_acme_switch_http standalone
  grep -q "^Le_HTTPPort='80'$" "$c"
  grep -q "^Le_PreHook='${SSL_PRE_HOOK}'$" "$c"
  # DNS-01 config is never switched
  printf 'SSL_PRIMARY=example.com\nSSL_METHOD=dns_cf\nSSL_ACME_HOME=%s\n' "$SSL_ACME_HOME" >"$SSL_CONFIG_FILE"
  cp "$c" "${T}/c.before"
  _ssl_acme_switch_http haproxy 18080
  cmp "$c" "${T}/c.before"
}

@test "HTTP-01 behind ToolBox HAProxy uses --httpport, never stop/start hooks" {
  _ssl_haproxy_acme_port() { echo 18080; }
  SSL_METHOD=http
  _ssl_method_args
  [ "${SSL_METHOD_ARGS[*]}" = "--standalone --httpport 18080" ]
  _ssl_haproxy_acme_port() { return 1; }
  _ssl_method_args
  [[ "${SSL_METHOD_ARGS[*]}" == *"--pre-hook"* ]]
}
