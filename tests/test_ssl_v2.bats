#!/usr/bin/env bats
# SSL v2 (0.7.0): official layout, node-cert safety, reuse, staging, DNS-01,
# container mount check, served-cert verification with .env rollback.

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/levels.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  SSL_STATE_DIR="${PGCTB_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_DEPLOY_HOOK="${SSL_STATE_DIR}/deploy-hook.sh"
  SSL_PRE_HOOK="${SSL_STATE_DIR}/acme-pre-hook.sh"
  SSL_POST_HOOK="${SSL_STATE_DIR}/acme-post-hook.sh"
  SSL_POST_HOOK_FAILED="${SSL_STATE_DIR}/acme-post-hook.failed"
  SSL_PANEL_ROOT="${PGCTB_STATE_DIR}/fake-panel"
  SSL_NODE_ROOT="${PGCTB_STATE_DIR}/fake-node"
  SSL_PANEL_CERT_DIR="${SSL_PANEL_ROOT}/certs"
  SSL_NODE_CERT_DIR="${SSL_NODE_ROOT}/certs"
  SSL_HAPROXY_CERT_DIR="${PGCTB_STATE_DIR}/fake-haproxy/certs"
  SSL_PANEL_APP_DIR="${PGCTB_STATE_DIR}/opt-pasarguard"
  SSL_ACME_HOME="${PGCTB_STATE_DIR}/acme"
  SSL_ACME_BIN="${SSL_ACME_HOME}/acme.sh"
  PROXY_CONFIG_FILE="${PGCTB_STATE_DIR}/proxy/none.env"
  PROXY_HAPROXY_CFG="${PGCTB_STATE_DIR}/haproxy.cfg"
  SSL_VERIFY_TRIES=1
  sleep() { :; }
  mkdir -p "$SSL_STATE_DIR/live" "$SSL_ACME_HOME" "${PGCTB_STATE_DIR}/fake-haproxy"
  T="$BATS_TEST_TMPDIR"
}

stub() {
  mkdir -p "${T}/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"${T}/bin/$1"
  chmod +x "${T}/bin/$1"
  PATH="${T}/bin:$PATH"
}

run_hook() {
  PGCTB_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
}

live_cert() {
  printf '%s\n' "$1" >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY-%s\n' "$1" >"${SSL_STATE_DIR}/live/key.pem"
}

# --- deploy hook --------------------------------------------------------------

@test "panel deploy: official layout; legacy .cer refreshed only if it exists" {
  _ssl_save_config panel demo.example.com demo.example.com
  mkdir -p "$SSL_PANEL_CERT_DIR"
  echo OLD >"${SSL_PANEL_CERT_DIR}/demo.example.com.cer"
  live_cert NEW
  run_hook
  [ "$status" -eq 0 ]
  [ "$(cat "${SSL_PANEL_CERT_DIR}/demo.example.com/fullchain.pem")" = NEW ]
  [ "$(cat "${SSL_PANEL_CERT_DIR}/demo.example.com/privkey.pem")" = KEY-NEW ]
  [ "$(cat "${SSL_PANEL_CERT_DIR}/demo.example.com.cer")" = NEW ]
}

@test "node deploy: original backed up once, change flagged, unchanged not flagged" {
  _ssl_save_config node demo.example.com demo.example.com
  mkdir -p "$SSL_NODE_CERT_DIR"
  echo SELF-SIGNED >"${SSL_NODE_CERT_DIR}/ssl_cert.pem"
  echo SELF-KEY >"${SSL_NODE_CERT_DIR}/ssl_key.pem"
  live_cert LE1
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODE CERTIFICATE CHANGED"* ]]
  [ -f "${SSL_STATE_DIR}/node-cert-changed" ]
  [ "$(cat "${SSL_NODE_CERT_DIR}/ssl_cert.pem.pre-pgclocktb")" = SELF-SIGNED ]
  [ "$(cat "${SSL_NODE_CERT_DIR}/ssl_key.pem.pre-pgclocktb")" = SELF-KEY ]
  rm -f "${SSL_STATE_DIR}/node-cert-changed"
  run_hook
  [ ! -f "${SSL_STATE_DIR}/node-cert-changed" ]       # same cert → no alarm
  live_cert LE2
  run_hook
  [ -f "${SSL_STATE_DIR}/node-cert-changed" ]         # renewal → alarm again
  [ "$(cat "${SSL_NODE_CERT_DIR}/ssl_cert.pem.pre-pgclocktb")" = SELF-SIGNED ]
}

@test "deploy hook: wildcard covered by cert, no per-name files for it; role none deploys nothing" {
  _ssl_save_config panel example.com example.com '*.example.com'
  live_cert W
  run_hook
  [ "$status" -eq 0 ]
  [ -f "${SSL_PANEL_CERT_DIR}/example.com/fullchain.pem" ]
  [ ! -e "${SSL_PANEL_CERT_DIR}/*.example.com" ]
  rm -rf "$SSL_PANEL_CERT_DIR"
  _ssl_save_config none example.com example.com
  live_cert W2
  run_hook
  [ "$status" -eq 0 ]
  [ ! -e "$SSL_PANEL_CERT_DIR" ]
}

@test "node restore puts the original back and stops node deployment" {
  _ssl_save_config both demo.example.com demo.example.com
  mkdir -p "$SSL_NODE_CERT_DIR"
  echo ORIG >"${SSL_NODE_CERT_DIR}/ssl_cert.pem.pre-pgclocktb"
  echo ORIGK >"${SSL_NODE_CERT_DIR}/ssl_key.pem.pre-pgclocktb"
  echo LE >"${SSL_NODE_CERT_DIR}/ssl_cert.pem"
  ui_confirm() { return 0; }
  _ssl_restart_compose() { :; }
  _ssl_load_config
  ssl_node_restore_original
  [ "$(cat "${SSL_NODE_CERT_DIR}/ssl_cert.pem")" = ORIG ]
  _ssl_load_config
  [ "$SSL_ROLE" = panel ]
}

# --- domains / method ---------------------------------------------------------

@test "domains: wildcard allowed but never as primary" {
  _ssl_parse_domains_arg "example.com *.example.com"
  [ "$SSL_PRIMARY" = example.com ]
  _ssl_has_wildcard "${SSL_DOMAINS_ARR[@]}"
  run _ssl_parse_domains_arg "*.example.com example.com"
  [ "$status" -ne 0 ]
  run _ssl_parse_domains_arg "*.*.example.com"
  [ "$status" -ne 0 ]
}

@test "Cloudflare-proxied domain detected from its A record" {
  _ssl_resolve_domain() { echo 104.16.1.1; }
  _ssl_behind_cloudflare panel.example.com
  _ssl_resolve_domain() { echo 203.0.113.5; }
  ! _ssl_behind_cloudflare panel.example.com
}

@test "method: wildcard forces DNS-01; bad or inactive token refused; token kept out of output" {
  have_tty() { return 0; }
  SSL_DOMAINS_ARR=(example.com '*.example.com')
  CF_Token="short"
  run _ssl_choose_method
  [ "$status" -ne 0 ]
  CF_Token="abcdefghijklmnopqrstuvwxyz0123456789ABCD"
  _ssl_cf_token_ok() { return 1; }
  run _ssl_choose_method
  [ "$status" -ne 0 ]
  [[ "$output" != *"$CF_Token"* ]]
  _ssl_cf_token_ok() { return 0; }
  _ssl_choose_method
  [ "$SSL_METHOD" = dns_cf ]
}

@test "node role needs the typed-YES gate" {
  have_tty() { return 1; }
  run _ssl_choose_role node
  [ "$status" -ne 0 ]
  _ssl_choose_role panel
  [ "$SSL_CHOSEN_ROLE" = panel ]
}

# --- acme.sh interaction --------------------------------------------------------

acme_stub() {
  cat >"$SSL_ACME_BIN" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${T}/acme.log"
exit 0
EOF
  chmod +x "$SSL_ACME_BIN"
}

@test "staging test uses the test CA in a throwaway cert home, never deploys" {
  acme_stub
  SSL_METHOD=http
  _ssl_staging_test example.com
  grep -q -- '--staging' "${T}/acme.log"
  grep -q -- '--cert-home' "${T}/acme.log"
  ! grep -q -- '--reloadcmd' "${T}/acme.log"
}

@test "existing valid cert covering all names is reused (no new request)" {
  command -v openssl >/dev/null || skip "openssl missing"
  local d="${SSL_ACME_HOME}/example.com_ecc"
  mkdir -p "$d"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${d}/example.com.key" -out "${d}/fullchain.cer" -days 90 \
    -subj "/CN=example.com" -addext "subjectAltName=DNS:example.com,DNS:www.example.com" >/dev/null 2>&1
  _ssl_existing_cert_ok example.com example.com www.example.com
  [ "$SSL_KEY_TYPE" = ecc ]
  ! _ssl_existing_cert_ok example.com example.com api.example.com
  # Expiring within 30 days → not reused
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${d}/example.com.key" -out "${d}/fullchain.cer" -days 10 \
    -subj "/CN=example.com" -addext "subjectAltName=DNS:example.com" >/dev/null 2>&1
  ! _ssl_existing_cert_ok example.com example.com
}

@test "issue with reusable cert skips --issue; DNS-01 renew passes no port-80 hooks" {
  acme_stub
  _ssl_existing_cert_ok() { SSL_KEY_TYPE=ecc; SSL_REUSE_EXPIRY=later; return 0; }
  have_tty() { return 1; }
  live_cert C
  SSL_METHOD=dns_cf
  _ssl_issue_cert panel example.com example.com
  ! grep -q -- '--issue' "${T}/acme.log"
  grep -q -- '--install-cert' "${T}/acme.log"
  grep -q '^SSL_METHOD=dns_cf$' "$SSL_CONFIG_FILE"
  : >"${T}/acme.log"
  PGCTB_DRY_RUN=0
  ssl_renew_now || true
  grep -q -- '--renew' "${T}/acme.log"
  ! grep -q -- '--pre-hook' "${T}/acme.log"
}

# --- panel .env transaction ---------------------------------------------------

panel_env_fixture() {
  mkdir -p "$SSL_PANEL_APP_DIR"
  cat >"${SSL_PANEL_APP_DIR}/.env" <<'EOF'
UVICORN_HOST = "0.0.0.0"
UVICORN_PORT = 8443
# UVICORN_SSL_CERTFILE = "/var/lib/pasarguard/certs/example.com/fullchain.pem"
EOF
  cp "${SSL_PANEL_APP_DIR}/.env" "${T}/env.orig"
  _ssl_restart_compose() { echo restart >>"${T}/restarts"; }
}

@test "env helpers read panel host/port" {
  panel_env_fixture
  [ "$(_ssl_env_get "${SSL_PANEL_APP_DIR}/.env" UVICORN_PORT)" = 8443 ]
  [ "$(_ssl_panel_endpoint "${SSL_PANEL_APP_DIR}/.env")" = "127.0.0.1 8443" ]
  ! _ssl_env_get "${SSL_PANEL_APP_DIR}/.env" UVICORN_SSL_CERTFILE
}

@test "direct TLS: verified → .env uses official paths + CA type" {
  panel_env_fixture
  _ssl_panel_sees_path() { return 0; }
  _ssl_verify_served_cert() { return 0; }
  _ssl_apply_env_paths panel example.com
  local e="${SSL_PANEL_APP_DIR}/.env"
  grep -q "^UVICORN_SSL_CERTFILE = \"${SSL_PANEL_CERT_DIR}/example.com/fullchain.pem\"" "$e"
  grep -q "^UVICORN_SSL_KEYFILE = \"${SSL_PANEL_CERT_DIR}/example.com/privkey.pem\"" "$e"
  grep -q '^UVICORN_SSL_CA_TYPE = "public"' "$e"
  grep -q '^UVICORN_PORT = 8443' "$e"
}

@test "direct TLS: panel does not serve the new cert → .env restored exactly + restarted" {
  panel_env_fixture
  _ssl_panel_sees_path() { return 0; }
  _ssl_verify_served_cert() { return 1; }
  run _ssl_apply_env_paths panel example.com
  [ "$status" -ne 0 ]
  cmp "${SSL_PANEL_APP_DIR}/.env" "${T}/env.orig"
  [ "$(wc -l <"${T}/restarts")" -eq 2 ]
}

@test "direct TLS: container cannot see the cert path → .env untouched, no restart" {
  panel_env_fixture
  _ssl_panel_sees_path() { return 1; }
  run _ssl_apply_env_paths panel example.com
  [ "$status" -ne 0 ]
  cmp "${SSL_PANEL_APP_DIR}/.env" "${T}/env.orig"
  [ ! -f "${T}/restarts" ]
}

@test "served-cert check against a real TLS server" {
  command -v openssl >/dev/null || skip "openssl missing"
  make_cert "${T}/a" example.com
  make_cert "${T}/b" example.com
  local port=$(( 20000 + RANDOM % 20000 ))
  openssl s_server -quiet -accept "$port" -cert "${T}/a/fullchain.cer" -key "${T}/a/key.pem" \
    -www >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    _ssl_served_fp 127.0.0.1 "$port" example.com | grep -q . && break
    command sleep 0.1
  done
  run _ssl_verify_served_cert 127.0.0.1 "$port" example.com "${T}/a/fullchain.cer"
  local same=$status
  run _ssl_verify_served_cert 127.0.0.1 "$port" example.com "${T}/b/fullchain.cer"
  local other=$status
  kill "$pid" 2>/dev/null || true
  [ "$same" -eq 0 ]
  [ "$other" -eq 1 ]
}
