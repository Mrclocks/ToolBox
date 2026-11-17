#!/usr/bin/env bats
# Telegram alerts (0.10.0)

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/doctor.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/alerts.sh"
  T="$BATS_TEST_TMPDIR"
  ALERTS_DIR="${T}/alerts"
  ALERTS_CONFIG="${ALERTS_DIR}/telegram.env"
  ALERTS_STATE="${ALERTS_DIR}/state"
  ALERTS_SYSTEMD_DIR="${T}/systemd"
  SSL_STATE_DIR="${PGCTB_STATE_DIR}/ssl"
  SSL_CONFIG_FILE="${SSL_STATE_DIR}/config.env"
  SSL_POST_HOOK_FAILED="${SSL_STATE_DIR}/acme-post-hook.failed"
  mkdir -p "$ALERTS_DIR" "$SSL_STATE_DIR" "$ALERTS_SYSTEMD_DIR"
  TOKEN="123456789:AAbbCCddEEffGGhhIIjjKKllMMnnOOppQQr"
  mkdir -p "${T}/bin"
  # curl stub: records argv and the stdin config separately, answers ok
  cat >"${T}/bin/curl" <<STUB
#!/usr/bin/env bash
echo "ARGV \$*" >>"${T}/curl.log"
cat >>"${T}/curl.stdin"
echo '{"ok":true}'
STUB
  chmod +x "${T}/bin/curl"
  PATH="${T}/bin:$PATH"
}

configure() {
  TG_BOT_TOKEN="$TOKEN" TG_CHAT_ID="-1001234567" TG_PROXY="" TG_API_BASE="https://api.telegram.org" ALERT_LABEL="srv1" \
    ALERT_DISK_PCT="" ALERT_CERT_DAYS=""
  _alerts_save
}

@test "config saved root-only and parsed back" {
  configure
  [ "$(stat -c %a "$ALERTS_CONFIG")" = 600 ]
  _alerts_load
  [ "$TG_CHAT_ID" = "-1001234567" ]
  _alerts_configured
}

@test "token is passed via curl stdin config, never in argv or output" {
  configure
  run alerts_send "hello"
  [ "$status" -eq 0 ]
  ! grep -q "$TOKEN" "${T}/curl.log"
  grep -q "bot${TOKEN}/sendMessage" "${T}/curl.stdin"
  grep -q -- '-K -' "${T}/curl.log"
  grep -q 'text=\[srv1\] hello' "${T}/curl.log"
  [[ "$output" != *"$TOKEN"* ]]
}

@test "proxy is used when configured" {
  configure
  TG_PROXY="socks5h://127.0.0.1:1080"
  _alerts_save
  alerts_send "x"
  grep -q -- '--proxy socks5h://127.0.0.1:1080' "${T}/curl.log"
}

@test "input validation" {
  _alerts_valid_token "$TOKEN"
  ! _alerts_valid_token "nope"
  _alerts_valid_chat "-1001234567"
  _alerts_valid_chat "@mychannel"
  ! _alerts_valid_chat "abc"
  _alerts_valid_base "https://relay.example.com/tg"
  ! _alerts_valid_base "http://api.telegram.org"
  ! _alerts_valid_proxy 'socks5://x;id'
}

@test "check: new problem sent once, repeated after 6h, recovery announced" {
  configure
  _alerts_collect() { echo "panel|🔴 panel down"; }
  alerts_check
  [ "$(grep -c 'panel down' "${T}/curl.log")" -eq 1 ]
  alerts_check                                   # still open, < 6h → silent
  [ "$(grep -c 'panel down' "${T}/curl.log")" -eq 1 ]
  ALERTS_REPEAT_SECONDS=0
  alerts_check                                   # repeat window passed
  [ "$(grep -c 'panel down' "${T}/curl.log")" -eq 2 ]
  _alerts_collect() { :; }
  alerts_check
  grep -q 'Recovered: 🔴 panel down' "${T}/curl.log"
  alerts_check                                   # recovery announced only once
  [ "$(grep -c 'Recovered' "${T}/curl.log")" -eq 1 ]
}

@test "check: certificate renewal announced once (not on first run)" {
  configure
  _alerts_collect() { :; }
  printf 'SSL_PRIMARY=example.com\n' >"$SSL_CONFIG_FILE"
  echo "2026-11-01T00:00:00Z" >"${SSL_STATE_DIR}/last_deploy.txt"
  alerts_check
  ! grep -q 'renewed' "${T}/curl.log" 2>/dev/null
  echo "2026-12-30T00:00:00Z" >"${SSL_STATE_DIR}/last_deploy.txt"
  alerts_check
  alerts_check
  [ "$(grep -c 'renewed' "${T}/curl.log")" -eq 1 ]
}

@test "collect: disk, haproxy down, expiring cert, failed post-hook, node cert" {
  df() { printf 'Filesystem 1 2 3 4 5\n/dev/x 1 1 1 95%% /\n'; }
  systemctl() { return 1; }
  PROXY_CONFIG_FILE="${T}/proxy.env"
  printf 'PROXY_ENGINE=haproxy\n' >"$PROXY_CONFIG_FILE"
  printf 'SSL_PRIMARY=example.com\n' >"$SSL_CONFIG_FILE"
  make_cert "${SSL_STATE_DIR}/live" example.com      # 2 days left
  echo "t haproxy" >"$SSL_POST_HOOK_FAILED"
  touch "${SSL_STATE_DIR}/node-cert-changed"
  _alerts_load
  run _alerts_collect
  [[ "$output" == *"disk:/|"* ]]
  [[ "$output" == *"haproxy|"* ]]
  [[ "$output" == *"cert|"* ]]
  [[ "$output" == *"posthook|"* ]]
  [[ "$output" == *"nodecert|"* ]]
}

@test "unconfigured check is a silent no-op" {
  run alerts_check
  [ "$status" -eq 0 ]
  [ ! -f "${T}/curl.log" ]
}

@test "timer units: oneshot service + 15 min timer" {
  systemctl() { echo "systemctl $*" >>"${T}/sys.log"; }
  alerts_install_timer
  grep -q 'ExecStart=.* alerts check' "${ALERTS_SYSTEMD_DIR}/pgclocktb-alerts.service"
  grep -q 'OnUnitActiveSec=15min' "${ALERTS_SYSTEMD_DIR}/pgclocktb-alerts.timer"
  grep -q 'enable --now pgclocktb-alerts.timer' "${T}/sys.log"
}

@test "read-only modes never heal / lock / reinstall" {
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
  eval "$(sed -n '/^_pgctb_mode_mutates() {/,/^}/p' "${REPO_ROOT}/install.sh")"
  local m
  for m in status verify doctor portcheck; do
    PGCTB_MODE=$m; ! _pgctb_mode_mutates
  done
  PGCTB_MODE=alerts PGCTB_CMD_ARG=check; ! _pgctb_mode_mutates
  PGCTB_MODE=ssl PGCTB_CMD_ARG=status; ! _pgctb_mode_mutates
  PGCTB_MODE=ssl PGCTB_CMD_ARG=renew; _pgctb_mode_mutates
  PGCTB_MODE=menu; _pgctb_mode_mutates
  PGCTB_MODE=level; _pgctb_mode_mutates
}
