#!/usr/bin/env bats
# Doctor + external port check (0.9.0)

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/proxy.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/doctor.sh"
  T="$BATS_TEST_TMPDIR"
  DOCTOR_DIR="${T}/doctor"
  SSL_STATE_DIR="${PGCTB_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_POST_HOOK_FAILED="${SSL_STATE_DIR}/acme-post-hook.failed"
  SSL_PANEL_APP_DIR="${T}/opt-pasarguard"
  PROXY_CONFIG_FILE="${T}/proxy.env"
  mkdir -p "$SSL_STATE_DIR"
}

quiet_world() {
  doctor_system() { _doc PASS system ok; }
  doctor_network() { _doc PASS network ok; }
  doctor_panel() { :; }
  doctor_node() { :; }
  doctor_haproxy() { :; }
  doctor_security() { :; }
}

@test "doctor: exit status follows FAIL count, report saved" {
  quiet_world
  doctor_ssl() { _doc WARN ssl "expires soon"; }
  module_doctor
  ls "$DOCTOR_DIR"/doctor-*.txt
  grep -q 'SUMMARY  pass=2 warn=1 fail=0' "$DOCTOR_DIR"/doctor-*.txt
  doctor_ssl() { _doc FAIL ssl "cron missing"; }
  run module_doctor
  [ "$status" -ne 0 ]
}

@test "doctor --share masks IPs, managed domains and e-mails" {
  printf 'SSL_PRIMARY=panel.example.com\nSSL_DOMAINS=panel.example.com sub.example.com\n' >"$SSL_CONFIG_FILE"
  run doctor_redact <<<"FAIL ssl panel.example.com at 203.0.113.9 and 2001:db8:1:2:3:4:5:6, mail ops@example.org, sub.example.com ok 12:34:56"
  [[ "$output" != *"panel.example.com"* ]]
  [[ "$output" != *"203.0.113.9"* ]]
  [[ "$output" != *"2001:db8"* ]]
  [[ "$output" != *"ops@example.org"* ]]
  [[ "$output" == *"[domain1]"* && "$output" == *"[domain2]"* && "$output" == *"[ip]"* && "$output" == *"[email]"* ]]
  [[ "$output" == *"12:34:56"* ]]        # times are not mistaken for IPv6
}

@test "doctor: certificate expiry thresholds" {
  make_cert "${T}/c" example.com            # 2 days
  DOC_LINES=() DOC_FAIL=0 DOC_WARN=0 DOC_PASS=0
  _doc_cert_check ssl "${T}/c/fullchain.cer" cert
  [ "$DOC_FAIL" -eq 1 ]
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${T}/k.pem" -out "${T}/long.pem" -days 60 -subj /CN=x >/dev/null 2>&1
  _doc_cert_check ssl "${T}/long.pem" cert
  [ "$DOC_PASS" -eq 1 ]
}

@test "doctor ssl: missing cron and failed post-hook are FAILs" {
  printf 'SSL_PRIMARY=example.com\n' >"$SSL_CONFIG_FILE"
  echo "2026-01-01T00:00:00Z haproxy" >"$SSL_POST_HOOK_FAILED"
  crontab() { return 1; }
  _ssl_verify_live() { return 2; }
  DOC_LINES=() DOC_FAIL=0
  doctor_ssl
  [ "$DOC_FAIL" -ge 3 ]          # live cert missing, cron missing, post-hook failed
  printf '%s\n' "${DOC_LINES[@]}" | grep -q 'could not restart: haproxy'
}

@test "portcheck: real open and closed ports" {
  command -v python3 >/dev/null || skip "python3 missing"
  local open=$(( 40000 + RANDOM % 10000 )) closed
  closed=$((open + 1))
  python3 -m http.server "$open" --bind 127.0.0.1 >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$open) 2>/dev/null && break; sleep 0.1; done
  run portcheck_run 127.0.0.1 "$open" "$closed"
  kill "$pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"$open"*"open"* ]]
  [[ "$output" == *"$closed"*"CLOSED"* ]]
  run portcheck_run '127.0.0.1;id' 22
  [ "$status" -ne 0 ]
}

@test "portcheck targets: SSH + HAProxy ports, local-only panel excluded" {
  detect_live_ssh_ports() { echo 2222; }
  discover_public_ports() { echo "tcp 9443"; echo "udp 51820"; }
  printf 'PROXY_ENGINE=haproxy\nPROXY_LISTEN_HTTPS=443\nPROXY_LISTEN_HTTP=80\nPROXY_EXTRA_PORTS=8443\n' >"$PROXY_CONFIG_FILE"
  mkdir -p "$SSL_PANEL_APP_DIR"
  printf 'UVICORN_HOST = "127.0.0.1"\nUVICORN_PORT = 8000\n' >"${SSL_PANEL_APP_DIR}/.env"
  run portcheck_targets
  [ "$output" = $'80\n443\n2222\n8443\n9443' ]
}

@test "CLI: doctor and portcheck parse" {
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
  eval "$(sed -n '/^parse_args() {/,/^}/p' "${REPO_ROOT}/install.sh")"
  usage() { :; }
  parse_args doctor --share
  [ "$PGCTB_MODE" = doctor ] && [ "$PGCTB_CMD_ARG" = --share ]
  parse_args portcheck panel.example.com "443 80"
  [ "$PGCTB_MODE" = portcheck ] && [ "$PGCTB_CMD_ARG" = panel.example.com ] && [ "$PGCTB_CMD_ARG2" = "443 80" ]
  run parse_args portcheck onlyhost
  [ "$status" -ne 0 ]
}
