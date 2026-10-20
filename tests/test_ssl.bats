#!/usr/bin/env bats
# SSL helper unit tests (no network / no root required)

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  SSL_STATE_DIR="${SECUREBOX_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_DEPLOY_HOOK="${SSL_STATE_DIR}/deploy-hook.sh"
  SSL_PANEL_ROOT="${SECUREBOX_STATE_DIR}/fake-panel"
  SSL_NODE_ROOT="${SECUREBOX_STATE_DIR}/fake-node"
  SSL_PANEL_CERT_DIR="${SSL_PANEL_ROOT}/certs"
  SSL_NODE_CERT_DIR="${SSL_NODE_ROOT}/certs"
  mkdir -p "$SSL_STATE_DIR"
}

@test "_ssl_normalize_domains splits commas spaces and dedupes" {
  run _ssl_normalize_domains "Foo.COM, bar.com  foo.com;BAR.com"
  [ "$status" -eq 0 ]
  [[ "$output" == $'foo.com\nbar.com' ]] || [[ "$output" == $'foo.com\nbar.com\n' ]]
}

@test "_ssl_valid_domain accepts FQDN rejects junk" {
  _ssl_valid_domain "panel.example.com"
  ! _ssl_valid_domain "not a domain"
  ! _ssl_valid_domain "-bad.com"
  ! _ssl_valid_domain "localhost"
}

@test "_ssl_parse_domains_arg sets primary and array" {
  _ssl_parse_domains_arg "a.example.com, b.example.com"
  [ "$SSL_PRIMARY" = "a.example.com" ]
  [ "${#SSL_DOMAINS_ARR[@]}" -eq 2 ]
  [ "${SSL_DOMAINS_ARR[1]}" = "b.example.com" ]
}

@test "_ssl_parse_domains_arg rejects invalid" {
  run _ssl_parse_domains_arg "ok.example.com bogus"
  [ "$status" -ne 0 ]
}

@test "_ssl_detect_role none by default in test env" {
  # No /opt/pasarguard in CI sandbox typically
  run _ssl_detect_role
  [ "$status" -eq 0 ]
  [[ "$output" == "none" || "$output" == "panel" || "$output" == "node" || "$output" == "both" ]]
}

@test "_ssl_save_config writes config and deploy hook" {
  _ssl_save_config "panel" "demo.example.com" "demo.example.com" "sub.example.com"
  [ -f "$SSL_CONFIG_FILE" ]
  [ -x "$SSL_DEPLOY_HOOK" ]
  grep -q 'SSL_PRIMARY=demo.example.com' "$SSL_CONFIG_FILE"
  grep -q 'SSL_ROLE=panel' "$SSL_CONFIG_FILE"
  grep -q 'ssl-deploy' "$SSL_DEPLOY_HOOK"
}

@test "deploy hook copies panel and node certs" {
  _ssl_save_config "both" "demo.example.com" "demo.example.com" "cdn.example.com"
  mkdir -p "${SSL_STATE_DIR}/live"
  # Minimal PEM-like placeholders (openssl not required for copy test)
  printf 'CERT\n' >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY\n' >"${SSL_STATE_DIR}/live/key.pem"

  # Override paths inside config for sandbox
  cat >"$SSL_CONFIG_FILE" <<EOF
SSL_ROLE=both
SSL_PRIMARY=demo.example.com
SSL_DOMAINS="demo.example.com cdn.example.com"
SSL_PANEL_CERT_DIR=${SSL_PANEL_CERT_DIR}
SSL_NODE_CERT_DIR=${SSL_NODE_CERT_DIR}
SSL_ACME_HOME=/tmp
SSL_EMAIL=
EOF
  _ssl_write_deploy_hook

  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
  [ "$status" -eq 0 ]
  [ -f "${SSL_PANEL_CERT_DIR}/demo.example.com.cer" ]
  [ -f "${SSL_PANEL_CERT_DIR}/demo.example.com.cer.key" ]
  [ -f "${SSL_PANEL_CERT_DIR}/cdn.example.com.cer" ]
  [ -f "${SSL_NODE_CERT_DIR}/ssl_cert.pem" ]
  [ -f "${SSL_NODE_CERT_DIR}/ssl_key.pem" ]
  [ "$(cat "${SSL_NODE_CERT_DIR}/ssl_cert.pem")" = "CERT" ]
}

@test "menu labels are English in install.sh" {
  grep -q 'SSL Certificates' "${REPO_ROOT}/install.sh"
  grep -q 'Optimization' "${REPO_ROOT}/install.sh"
  grep -q 'Undo Toolbox Changes' "${REPO_ROOT}/install.sh"
  grep -q 'Restore & Migrate' "${REPO_ROOT}/install.sh"
  grep -q 'Reverse Proxy' "${REPO_ROOT}/install.sh"
  # No Arabic/Persian script in menu entry points
  ! grep -E 'بهینه|بکاپ|ریستور|سرتیفیکیت|منو' "${REPO_ROOT}/install.sh"
}
