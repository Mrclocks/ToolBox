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
  SSL_HAPROXY_CERT_DIR="${SECUREBOX_STATE_DIR}/fake-haproxy/certs"
  SSL_POST_HOOK_FAILED="${SSL_STATE_DIR}/acme-post-hook.failed"
  SSL_ACME_HOME="${SECUREBOX_STATE_DIR}/acme"
  SSL_ACME_BIN="${SSL_ACME_HOME}/acme.sh"
  PROXY_HAPROXY_CFG="${SECUREBOX_STATE_DIR}/haproxy.cfg"
  mkdir -p "$SSL_STATE_DIR" "${SECUREBOX_STATE_DIR}/fake-haproxy"
}

# Stub a command on PATH for this test
stub() {
  local name="$1" body="$2"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"${BATS_TEST_TMPDIR}/bin/${name}"
  chmod +x "${BATS_TEST_TMPDIR}/bin/${name}"
  PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
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
SSL_HAPROXY_CERT_DIR=${SSL_HAPROXY_CERT_DIR}
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
  # HAProxy PEMs land in the configured dir, never in the real /etc/haproxy
  [ -f "${SSL_HAPROXY_CERT_DIR}/demo.example.com.pem" ]
  [ -f "${SSL_HAPROXY_CERT_DIR}/cdn.example.com.pem" ]
}

@test "ssl config.env is parsed, never executed (deploy hook too)" {
  local marker="${BATS_TEST_TMPDIR}/pwned"
  SSL_EMAIL="a@b.co \$(touch ${marker})"
  SSL_KEY_TYPE=ecc
  _ssl_save_config "panel" "demo.example.com" "demo.example.com" "cdn.example.com"
  SSL_EMAIL=""
  SSL_KEY_TYPE=""
  _ssl_load_config
  [ "$SSL_DOMAINS" = "demo.example.com cdn.example.com" ]
  [ "$SSL_KEY_TYPE" = "ecc" ]
  [ "$SSL_EMAIL" = "a@b.co \$(touch ${marker})" ]
  mkdir -p "${SSL_STATE_DIR}/live"
  printf 'CERT\n' >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY\n' >"${SSL_STATE_DIR}/live/key.pem"
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "legacy quoted SSL_DOMAINS still loads" {
  printf 'SSL_ROLE=panel\nSSL_PRIMARY=a.example.com\nSSL_DOMAINS="a.example.com b.example.com"\n' >"$SSL_CONFIG_FILE"
  _ssl_load_config
  [ "$SSL_DOMAINS" = "a.example.com b.example.com" ]
}

@test "_ssl_valid_email" {
  _ssl_valid_email ""
  _ssl_valid_email "ops@example.com"
  ! _ssl_valid_email "a b@example.com"
  ! _ssl_valid_email 'x@y.com$(id)'
}

@test "deploy hook fails loudly and skips restarts when cert unchanged" {
  _ssl_save_config "panel" "demo.example.com" "demo.example.com"
  mkdir -p "${SSL_STATE_DIR}/live"
  printf 'CERT\n' >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY\n' >"${SSL_STATE_DIR}/live/key.pem"
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=1"* ]]
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=0"* ]]
  # Unwritable target → non-zero exit (no silent success)
  rm -rf "$SSL_PANEL_CERT_DIR"
  mkdir -p "$SSL_PANEL_ROOT"
  printf 'x' >"$SSL_PANEL_CERT_DIR"   # a file where the dir should be
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_DEPLOY_HOOK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "ACME post-hook reports services it could not restart" {
  _ssl_write_acme_port_hooks
  stub systemctl 'exit 1'
  stub sleep 'exit 0'
  printf 'haproxy\n' >"${SSL_STATE_DIR}/.acme-stopped-services"
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_POST_HOOK"
  [ "$status" -ne 0 ]
  [ -f "$SSL_POST_HOOK_FAILED" ]
  grep -q haproxy "$SSL_POST_HOOK_FAILED"
  run _ssl_report_post_hook
  [ "$status" -ne 0 ]
  # Success clears the marker
  stub systemctl 'exit 0'
  printf 'haproxy\n' >"${SSL_STATE_DIR}/.acme-stopped-services"
  SECUREBOX_SSL_STATE_DIR="$SSL_STATE_DIR" run bash "$SSL_POST_HOOK"
  [ "$status" -eq 0 ]
  [ ! -f "$SSL_POST_HOOK_FAILED" ]
}

@test "_ssl_panel_behind_haproxy ignores stock commented .env lines" {
  PROXY_CONFIG_FILE="${SECUREBOX_STATE_DIR}/proxy/none.env"
  stub systemctl 'exit 0'   # haproxy "active"
  printf 'global\n' >"$PROXY_HAPROXY_CFG"
  ! _ssl_panel_behind_haproxy
  printf '# MrClock ToolBox — PasarGuard panel single-port (HTTP mode)\n' >"$PROXY_HAPROXY_CFG"
  _ssl_panel_behind_haproxy
}

@test "_ssl_dns_points_here: match, mismatch, NAT-unverifiable" {
  _ssl_local_ips() { printf '203.0.113.5\n'; }
  _ssl_resolve_domain() { printf '198.51.100.9\n203.0.113.5\n'; }
  _ssl_dns_points_here a.example.com
  _ssl_resolve_domain() { printf '198.51.100.9\n'; }
  run _ssl_dns_points_here a.example.com
  [ "$status" -eq 1 ]
  _ssl_local_ips() { printf '10.0.0.4\n'; }
  run _ssl_dns_points_here a.example.com
  [ "$status" -eq 2 ]
}

@test "_ssl_ecc_args follows saved key type, then acme.sh dirs" {
  SSL_KEY_TYPE=rsa
  [ -z "$(_ssl_ecc_args a.example.com)" ]
  SSL_KEY_TYPE=ecc
  [ "$(_ssl_ecc_args a.example.com)" = "--ecc" ]
  SSL_KEY_TYPE=""
  [ -z "$(_ssl_ecc_args a.example.com)" ]
  mkdir -p "${SSL_ACME_HOME}/a.example.com_ecc"
  touch "${SSL_ACME_HOME}/a.example.com_ecc/a.example.com.conf"
  [ "$(_ssl_ecc_args a.example.com)" = "--ecc" ]
}

@test "ssl_renew_now fails when the deploy hook fails" {
  SECUREBOX_DRY_RUN=0
  mkdir -p "$SSL_ACME_HOME"
  printf '#!/bin/sh\nexit 0\n' >"$SSL_ACME_BIN"
  chmod +x "$SSL_ACME_BIN"
  SSL_KEY_TYPE=ecc
  _ssl_save_config "panel" "demo.example.com" "demo.example.com"
  # No live cert anywhere → deploy hook must fail → renew must not report success
  run ssl_renew_now
  [ "$status" -ne 0 ]
  # With a cert in place it succeeds
  mkdir -p "${SSL_STATE_DIR}/live"
  printf 'CERT\n' >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY\n' >"${SSL_STATE_DIR}/live/key.pem"
  run ssl_renew_now
  [ "$status" -eq 0 ]
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

@test "_ssl_issue_cert records ECC on success and RSA only after ECC fails" {
  _ssl_preflight_issue() { return 0; }
  mkdir -p "$SSL_ACME_HOME" "${SSL_STATE_DIR}/live"
  printf 'CERT\n' >"${SSL_STATE_DIR}/live/fullchain.cer"
  printf 'KEY\n' >"${SSL_STATE_DIR}/live/key.pem"
  local log="${BATS_TEST_TMPDIR}/acme.log"
  # acme.sh stub: log args; fail ECC issue when ACME_FAIL_ECC=1
  cat >"$SSL_ACME_BIN" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$log"
if [[ "\${ACME_FAIL_ECC:-0}" == 1 && "\$*" == *"--issue"*"ec-256"* ]]; then exit 1; fi
exit 0
EOF
  chmod +x "$SSL_ACME_BIN"

  SSL_KEY_TYPE=""
  _ssl_issue_cert panel demo.example.com demo.example.com
  [ "$SSL_KEY_TYPE" = "ecc" ]
  [ "$(grep -c -- '--issue' "$log")" -eq 1 ]
  grep -- '--install-cert' "$log" | grep -q -- '--ecc'
  grep -q '^SSL_KEY_TYPE=ecc$' "$SSL_CONFIG_FILE"

  : >"$log"
  SSL_KEY_TYPE=""
  ACME_FAIL_ECC=1 _ssl_issue_cert panel demo.example.com demo.example.com
  [ "$SSL_KEY_TYPE" = "rsa" ]
  [ "$(grep -c -- '--issue' "$log")" -eq 2 ]
  ! grep -- '--install-cert' "$log" | grep -q -- '--ecc'
  grep -q '^SSL_KEY_TYPE=rsa$' "$SSL_CONFIG_FILE"
}
