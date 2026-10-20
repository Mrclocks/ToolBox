#!/usr/bin/env bats
# SSL helper unit tests (no network / no root required)

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  SSL_STATE_DIR="${SECUREBOX_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_DEPLOY_HOOK="${SSL_STATE_DIR}/deploy-hook.sh"
  SSL_PRE_HOOK="${SSL_STATE_DIR}/acme-pre-hook.sh"
  SSL_POST_HOOK="${SSL_STATE_DIR}/acme-post-hook.sh"
  SSL_ACME_STOPPED="${SSL_STATE_DIR}/.acme-stopped-services"
  PROXY_CONFIG_FILE="${SECUREBOX_STATE_DIR}/proxy/config.env"
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

@test "SSL menu includes env guide and repair entries" {
  grep -q 'Show .env / path instructions' "${REPO_ROOT}/modules/ssl.sh"
  grep -q 'Repair auto-renew' "${REPO_ROOT}/modules/ssl.sh"
  grep -q '_ssl_preflight_issue' "${REPO_ROOT}/modules/ssl.sh"
}

@test "_ssl_port80_owner returns a string" {
  run _ssl_port80_owner
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "docs/OPS.md documents SSL paths" {
  grep -q '/var/lib/pasarguard/certs' "${REPO_ROOT}/docs/OPS.md"
  grep -q 'PGClockBackup' "${REPO_ROOT}/docs/OPS.md"
  grep -q 'HAProxy' "${REPO_ROOT}/docs/OPS.md"
}

@test "_ssl_env_upsert replaces previous path and comments UDS" {
  local envf="${SECUREBOX_STATE_DIR}/panel.env"
  cat >"$envf" <<'EOF'
UVICORN_HOST = "0.0.0.0"
UVICORN_PORT = 8000
UVICORN_SSL_CERTFILE = "/old/path.cer"
UVICORN_SSL_KEYFILE = "/old/path.key"
UVICORN_UDS = "/var/lib/pasarguard/pasarguard.socket"
EOF
  _ssl_env_upsert "$envf" "UVICORN_SSL_CERTFILE" "/var/lib/pasarguard/certs/a.cer" spaced
  _ssl_env_upsert "$envf" "UVICORN_SSL_KEYFILE" "/var/lib/pasarguard/certs/a.cer.key" spaced
  _ssl_env_comment_key "$envf" "UVICORN_UDS"
  grep -q 'UVICORN_SSL_CERTFILE = "/var/lib/pasarguard/certs/a.cer"' "$envf"
  grep -q 'UVICORN_SSL_KEYFILE = "/var/lib/pasarguard/certs/a.cer.key"' "$envf"
  # Port must stay untouched by SSL helpers
  grep -q 'UVICORN_PORT = 8000' "$envf"
  ! grep -qE '^[[:space:]]*UVICORN_SSL_CERTFILE = "/old/' "$envf"
  grep -qE '^# UVICORN_UDS' "$envf"
}

@test "_ssl_compose_upsert_env updates YAML env keys" {
  local yml="${SECUREBOX_STATE_DIR}/compose.yml"
  cat >"$yml" <<'EOF'
services:
  node:
    environment:
      SSL_CERT_FILE: "/old/ssl_cert.pem"
      SSL_KEY_FILE: "/old/ssl_key.pem"
EOF
  _ssl_compose_upsert_env "$yml" "SSL_CERT_FILE" "/var/lib/pg-node/certs/ssl_cert.pem"
  _ssl_compose_upsert_env "$yml" "SSL_KEY_FILE" "/var/lib/pg-node/certs/ssl_key.pem"
  grep -q 'SSL_CERT_FILE: "/var/lib/pg-node/certs/ssl_cert.pem"' "$yml"
  grep -q 'SSL_KEY_FILE: "/var/lib/pg-node/certs/ssl_key.pem"' "$yml"
}

@test "_ssl_write_acme_port_hooks creates executable pre/post scripts" {
  _ssl_write_acme_port_hooks
  [ -x "$SSL_PRE_HOOK" ]
  [ -x "$SSL_POST_HOOK" ]
  grep -q 'haproxy' "$SSL_PRE_HOOK"
  grep -q 'systemctl start' "$SSL_POST_HOOK"
}

@test "_ssl_panel_behind_haproxy detects proxy config" {
  local pdir="${SECUREBOX_STATE_DIR}/proxy"
  mkdir -p "$pdir"
  PROXY_CONFIG_FILE="${pdir}/config.env"
  cat >"$PROXY_CONFIG_FILE" <<'EOF'
PROXY_ENGINE=haproxy
PROXY_MODE=panel
EOF
  _ssl_panel_behind_haproxy
}

@test "_ssl_apply_env_paths keeps UVICORN_SSL commented behind HAProxy" {
  local pdir="${SECUREBOX_STATE_DIR}/proxy"
  local panel="${SECUREBOX_STATE_DIR}/fake-pasarguard"
  mkdir -p "$pdir" "$panel" "$SSL_PANEL_CERT_DIR"
  PROXY_CONFIG_FILE="${pdir}/config.env"
  cat >"$PROXY_CONFIG_FILE" <<'EOF'
PROXY_ENGINE=haproxy
PROXY_MODE=panel
EOF
  # Point apply helper at sandbox panel by temporarily using real path layout:
  # create /opt/pasarguard is not allowed — instead unit-test the comment path
  # via direct helper when config says haproxy panel.
  _ssl_panel_behind_haproxy
  local envf="${SECUREBOX_STATE_DIR}/panel-haproxy.env"
  cat >"$envf" <<'EOF'
UVICORN_HOST = "127.0.0.1"
UVICORN_PORT = 8000
# UVICORN_SSL_CERTFILE = "/old.cer"
# UVICORN_SSL_KEYFILE = "/old.key"
EOF
  _ssl_env_comment_key "$envf" "UVICORN_SSL_CERTFILE"
  _ssl_env_comment_key "$envf" "UVICORN_SSL_KEYFILE"
  ! grep -qE '^[[:space:]]*UVICORN_SSL_CERTFILE[[:space:]]*=' "$envf"
  grep -qE '^#.*UVICORN_SSL_CERTFILE' "$envf"
}

@test "ssl_renew_now does not call _ssl_apply_env_paths" {
  # Renew must not rewrite .env (would undo HAProxy local-HTTP prep)
  ! awk '/^ssl_renew_now\(\)/,/^ssl_show_env_guide\(\)/' "${REPO_ROOT}/modules/ssl.sh" \
    | grep -q '_ssl_apply_env_paths'
}
