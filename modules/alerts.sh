#!/usr/bin/env bash
# Module: Telegram alerts — periodic checks (systemd timer), deduplicated,
# with "recovered" messages. The bot token is never logged or put on a
# command line (curl reads it from stdin config).
# shellcheck shell=bash

ALERTS_DIR="${ALERTS_DIR:-${PGCTB_STATE_DIR}/alerts}"
ALERTS_CONFIG="${ALERTS_CONFIG:-${ALERTS_DIR}/telegram.env}"
ALERTS_STATE="${ALERTS_STATE:-${ALERTS_DIR}/state}"
ALERTS_REPEAT_SECONDS="${ALERTS_REPEAT_SECONDS:-21600}"   # re-send an open problem every 6h
ALERTS_UNIT="${ALERTS_UNIT:-pgclocktb-alerts}"
ALERTS_SYSTEMD_DIR="${ALERTS_SYSTEMD_DIR:-/etc/systemd/system}"
ALERTS_CONFIG_KEYS=(TG_BOT_TOKEN TG_CHAT_ID TG_API_BASE TG_PROXY ALERT_LABEL ALERT_DISK_PCT ALERT_CERT_DAYS)

_alerts_load() {
  TG_BOT_TOKEN="" TG_CHAT_ID="" TG_API_BASE="" TG_PROXY="" ALERT_LABEL=""
  ALERT_DISK_PCT="" ALERT_CERT_DAYS=""
  kv_load_file "$ALERTS_CONFIG" "${ALERTS_CONFIG_KEYS[@]}"
  TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"
  ALERT_LABEL="${ALERT_LABEL:-$(hostname 2>/dev/null || echo server)}"
  ALERT_DISK_PCT="${ALERT_DISK_PCT:-90}"
  ALERT_CERT_DAYS="${ALERT_CERT_DAYS:-14}"
}

_alerts_save() {
  mkdir -p "$ALERTS_DIR"
  chmod 700 "$ALERTS_DIR" 2>/dev/null || true
  local k tmp
  tmp="$(mktemp "${ALERTS_DIR}/.tg.XXXXXX")"
  chmod 600 "$tmp"
  {
    printf '# PGClockTB Telegram alerts (parsed, never sourced) — root only\n'
    for k in "${ALERTS_CONFIG_KEYS[@]}"; do
      kv_line "$k" "${!k-}"
    done
  } >"$tmp"
  mv -f "$tmp" "$ALERTS_CONFIG"
}

_alerts_configured() {
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]
}

_alerts_valid_token() { [[ "$1" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; }
_alerts_valid_chat() { [[ "$1" =~ ^-?[0-9]{3,}$ || "$1" =~ ^@[A-Za-z0-9_]{5,}$ ]]; }
_alerts_valid_base() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]]; }
_alerts_valid_proxy() { [[ -z "$1" || "$1" =~ ^(socks5h?|socks4a?|https?)://[A-Za-z0-9.:@_-]+$ ]]; }

alerts_send() {
  # alerts_send TEXT → 0 when Telegram accepted it
  local text="$1" resp
  _alerts_load
  _alerts_configured || return 1
  have_cmd curl || return 1
  text="[${ALERT_LABEL}] ${text}"
  # Token/URL go through curl's stdin config, never argv (visible in ps)
  local -a args=(-sS --max-time 20 -K -)
  [[ -n "$TG_PROXY" ]] && args+=(--proxy "$TG_PROXY")
  resp="$(printf 'url = "%s/bot%s/sendMessage"\n' "${TG_API_BASE%/}" "$TG_BOT_TOKEN" \
    | curl "${args[@]}" --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" --data-urlencode "disable_web_page_preview=true" 2>/dev/null || true)"
  [[ "$resp" == *'"ok":true'* ]]
}

alerts_send_test() {
  _alerts_load
  if ! _alerts_configured; then
    ui_error "Telegram alerts are not configured (Tools → Telegram alerts)"
    return 1
  fi
  if alerts_send "✅ PGClockTB test message — alerts work"; then
    ui_success "Test message delivered"
    return 0
  fi
  ui_error "Telegram did not accept the message (token / chat id / network)"
  ui_info "Servers in Iran usually cannot reach api.telegram.org — set a proxy or relay URL"
  return 1
}

# --- checks: print "KEY|message" for every open problem, "info|..." for news ---

_alerts_collect() {
  local p use
  while read -r p use; do
    [[ -n "$p" ]] || continue
    use="${use%\%}"
    (( use >= ALERT_DISK_PCT )) && echo "disk:${p}|💾 Disk ${p} is ${use}% full"
  done < <(df -P / /var 2>/dev/null | awk 'NR>1 && !seen[$6]++ {print $6, $5}')

  local app="${SSL_PANEL_APP_DIR:-/opt/pasarguard}" rc
  if [[ -d "$app" ]]; then
    rc=0
    _doc_compose_running "$app" || rc=$?
    (( rc == 1 )) && echo "panel|🔴 PasarGuard panel container is not running"
  fi
  if [[ -d /opt/pg-node ]]; then
    rc=0
    _doc_compose_running /opt/pg-node || rc=$?
    (( rc == 1 )) && echo "node|🔴 PasarGuard node container is not running"
  fi
  local PROXY_ENGINE=""
  kv_load_file "${PROXY_CONFIG_FILE:-${PGCTB_STATE_DIR}/proxy/config.env}" PROXY_ENGINE
  if [[ "$PROXY_ENGINE" == haproxy ]] && ! systemctl is-active --quiet haproxy 2>/dev/null; then
    echo "haproxy|🔴 HAProxy is not running — users cannot connect"
  fi
  if [[ -d /opt/pg-backup ]] && ! systemctl is-active --quiet pg-backup 2>/dev/null; then
    echo "pgbackup|🟡 PGClockBackup service is not running"
  fi

  _ssl_load_config
  if [[ -n "${SSL_PRIMARY:-}" ]]; then
    local live="${SSL_STATE_DIR}/live/fullchain.cer" days
    if [[ -f "$live" ]] && days="$(_doc_days_left "$live")"; then
      (( days < ALERT_CERT_DAYS )) && echo "cert|🔐 Certificate ${SSL_PRIMARY} expires in ${days} days — renewal is not working"
    fi
    [[ -f "$SSL_POST_HOOK_FAILED" ]] && echo "posthook|🔴 After certificate renewal these did not restart: $(cut -d' ' -f2- "$SSL_POST_HOOK_FAILED")"
    [[ -f "${SSL_STATE_DIR}/node-cert-changed" ]] && echo "nodecert|🟡 Node certificate changed — paste the new one into Panel → Nodes"
  fi
}

_alerts_state_get() {
  [[ -f "$ALERTS_STATE" ]] || return 0
  awk -F'|' -v k="$1" '$1==k {print $2; exit}' "$ALERTS_STATE"
}

alerts_check() {
  # Run by the systemd timer. Sends new problems, repeats open ones every 6h,
  # announces recoveries and fresh certificate renewals.
  _alerts_load
  _alerts_configured || return 0
  mkdir -p "$ALERTS_DIR"
  local now line key msg last rc=0
  now="$(date +%s)"
  local -A open_now=()
  local new_state=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%|*}"
    msg="${line#*|}"
    open_now["$key"]=1
    last="$(_alerts_state_get "$key")"
    if [[ -z "$last" ]] || (( now - last >= ALERTS_REPEAT_SECONDS )); then
      if alerts_send "$msg"; then
        last="$now"
      else
        rc=1
      fi
    fi
    new_state+="${key}|${last:-0}|${msg}"$'\n'
  done < <(_alerts_collect)

  # Recoveries: keys that were open last time and are gone now
  local old_key old_msg
  if [[ -f "$ALERTS_STATE" ]]; then
    while IFS='|' read -r old_key _ old_msg; do
      [[ -n "$old_key" && "$old_key" != _* ]] || continue
      [[ -n "${open_now[$old_key]:-}" ]] && continue
      alerts_send "✅ Recovered: ${old_msg}" || { rc=1; new_state+="${old_key}|0|${old_msg}"$'\n'; }
    done <"$ALERTS_STATE"
  fi

  # Successful certificate renewal (deploy hook stamps last_deploy.txt)
  local stamp seen
  stamp="$(cat "${SSL_STATE_DIR}/last_deploy.txt" 2>/dev/null || true)"
  seen="$(_alerts_state_get _deploy)"
  if [[ -n "$stamp" && "$stamp" != "$seen" ]]; then
    if [[ -z "$seen" ]] || alerts_send "🔐 Certificate ${SSL_PRIMARY:-} renewed and deployed (${stamp})"; then
      seen="$stamp"
    fi
  fi
  new_state+="_deploy|${seen}|"$'\n'

  printf '%s' "$new_state" >"${ALERTS_STATE}.tmp" && mv -f "${ALERTS_STATE}.tmp" "$ALERTS_STATE"
  return "$rc"
}

# --- timer ----------------------------------------------------------------------

alerts_install_timer() {
  local bin
  bin="$(command -v pgclock 2>/dev/null || echo /usr/local/bin/pgclock)"
  cat >"${ALERTS_SYSTEMD_DIR}/${ALERTS_UNIT}.service" <<EOF
[Unit]
Description=PGClockTB Telegram alert check
After=network-online.target

[Service]
Type=oneshot
ExecStart=${bin} alerts check
Nice=10
EOF
  cat >"${ALERTS_SYSTEMD_DIR}/${ALERTS_UNIT}.timer" <<EOF
[Unit]
Description=PGClockTB Telegram alert check every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "${ALERTS_UNIT}.timer" >/dev/null 2>&1
}

alerts_remove_timer() {
  systemctl disable --now "${ALERTS_UNIT}.timer" >/dev/null 2>&1 || true
  rm -f "${ALERTS_SYSTEMD_DIR}/${ALERTS_UNIT}.timer" "${ALERTS_SYSTEMD_DIR}/${ALERTS_UNIT}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

alerts_status() {
  _alerts_load
  ui_box_start "Telegram alerts"
  if _alerts_configured; then
    ui_kv "Configured" "yes (chat ${TG_CHAT_ID})"
  else
    ui_kv "Configured" "no"
  fi
  ui_kv "API base" "$TG_API_BASE"
  ui_kv "Proxy" "${TG_PROXY:-(none)}"
  ui_kv "Label" "$ALERT_LABEL"
  if systemctl is-enabled --quiet "${ALERTS_UNIT}.timer" 2>/dev/null; then
    ui_kv "Timer" "enabled (every 15 min)"
  else
    ui_kv "Timer" "disabled"
  fi
  ui_box_end
}

alerts_setup() {
  ui_step "Telegram alerts — setup"
  _alerts_load
  local token chat base proxy label
  ui_info "1) Create a bot with @BotFather and copy its token"
  ui_info "2) Send any message to the bot (or add it to a group), then get the chat id"
  ui_read_secret token "Bot token (input hidden, Enter keeps current)"
  token="$(trim "$token")"
  [[ -z "$token" ]] && token="$TG_BOT_TOKEN"
  if ! _alerts_valid_token "$token"; then
    ui_error "That does not look like a bot token (123456:ABC…)"
    return 1
  fi
  ui_ask chat "Chat id (number, or @channel)" "$TG_CHAT_ID"
  chat="$(trim "$chat")"
  _alerts_valid_chat "$chat" || { ui_error "Invalid chat id"; return 1; }
  ui_info "Servers in Iran usually cannot reach api.telegram.org:"
  ui_info "use a proxy (e.g. socks5h://127.0.0.1:1080) or a relay URL you control."
  ui_ask proxy "Proxy for Telegram (optional)" "$TG_PROXY"
  proxy="$(trim "$proxy")"
  _alerts_valid_proxy "$proxy" || { ui_error "Invalid proxy URL"; return 1; }
  ui_ask base "Telegram API base URL" "$TG_API_BASE"
  base="$(trim "$base")"
  _alerts_valid_base "$base" || { ui_error "API base must be an https:// URL"; return 1; }
  ui_ask label "Label for this server in messages" "$ALERT_LABEL"
  label="$(trim "$label")"
  label="${label//[^A-Za-z0-9 ._-]/}"

  TG_BOT_TOKEN="$token" TG_CHAT_ID="$chat" TG_PROXY="$proxy" TG_API_BASE="$base" ALERT_LABEL="${label:-server}"
  _alerts_save
  ui_success "Saved (${ALERTS_CONFIG}, root only)"
  if alerts_send_test && ui_confirm "Enable the 15-minute alert timer?" "Y"; then
    if alerts_install_timer; then
      ui_success "Alert timer enabled"
    else
      ui_warn "Could not enable the timer (systemd unavailable?)"
    fi
  fi
}

alerts_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Telegram alerts"
    alerts_status
    printf '  %s 1)%s Set up / change\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Send a test message\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Run a check now\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s Disable alerts (remove timer)\n' "$C_ORANGE" "$C_RESET"
    ui_menu_back_line
    printf '%sSelect%s [0-4]: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    case "$(trim "${choice:-}")" in
      1) ui_clear; alerts_setup || true; ui_pause ;;
      2) ui_clear; alerts_send_test || true; ui_pause ;;
      3) ui_clear; alerts_check && ui_success "Check done" || ui_warn "Some alerts could not be sent"; ui_pause ;;
      4) alerts_remove_timer; ui_success "Alert timer removed (settings kept)"; sleep 1 ;;
      0|b|B|back|Back) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}
