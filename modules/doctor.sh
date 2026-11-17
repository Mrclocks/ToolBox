#!/usr/bin/env bash
# Module: Doctor — read-only health check (PASS / WARN / FAIL), shareable report
# shellcheck shell=bash

DOCTOR_DIR="${DOCTOR_DIR:-${PGCTB_STATE_DIR}/doctor}"
DOC_PASS=0
DOC_WARN=0
DOC_FAIL=0
DOC_LINES=()

_doc() {
  # _doc LEVEL AREA MESSAGE
  local level="$1" area="$2" msg="$3"
  case "$level" in
    PASS) DOC_PASS=$((DOC_PASS + 1)) ;;
    WARN) DOC_WARN=$((DOC_WARN + 1)) ;;
    FAIL) DOC_FAIL=$((DOC_FAIL + 1)) ;;
  esac
  DOC_LINES+=("$(printf '%-4s  %-9s %s' "$level" "$area" "$msg")")
}

_doc_listening() {
  have_cmd ss || return 2
  [[ -n "$(ss -tlnH "sport = :${1}" 2>/dev/null)" ]]
}

_doc_compose_running() {
  # 0 running · 1 not running · 2 cannot tell
  local dir="$1"
  have_cmd docker || return 2
  [[ -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] || return 2
  [[ -n "$(cd "$dir" && docker compose ps --status running -q 2>/dev/null)" ]]
}

_doc_days_left() {
  # days until a certificate expires (negative = expired)
  local end
  end="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  [[ -n "$end" ]] || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

_doc_cert_check() {
  local area="$1" file="$2" label="$3" days
  have_cmd openssl || { _doc INFO "$area" "${label}: openssl missing"; return; }
  if ! days="$(_doc_days_left "$file")"; then
    _doc WARN "$area" "${label}: cannot read ${file}"
    return
  fi
  if (( days < 7 )); then
    _doc FAIL "$area" "${label} expires in ${days} days"
  elif (( days < 21 )); then
    _doc WARN "$area" "${label} expires in ${days} days (renewal normally runs at 30)"
  else
    _doc PASS "$area" "${label} valid for ${days} more days"
  fi
}

# --- checks --------------------------------------------------------------------

doctor_system() {
  local m use
  while read -r m use; do
    [[ -n "$m" ]] || continue
    use="${use%\%}"
    if (( use >= 95 )); then
      _doc FAIL system "disk ${m} ${use}% full"
    elif (( use >= 85 )); then
      _doc WARN system "disk ${m} ${use}% full"
    else
      _doc PASS system "disk ${m} ${use}% used"
    fi
  done < <(df -P / /var 2>/dev/null | awk 'NR>1 && !seen[$6]++ {print $6, $5}')

  local total avail pct
  total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [[ -n "$total" && -n "$avail" && "$total" -gt 0 ]]; then
    pct=$(( avail * 100 / total ))
    if (( pct < 5 )); then
      _doc FAIL system "memory available ${pct}%"
    elif (( pct < 10 )); then
      _doc WARN system "memory available ${pct}%"
    else
      _doc PASS system "memory available ${pct}%"
    fi
  fi

  [[ -f /var/run/reboot-required ]] && _doc WARN system "reboot required (package updates)"

  if have_cmd timedatectl; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
      _doc PASS system "clock synchronized (NTP)"
    else
      _doc WARN system "clock not NTP-synchronized (TLS/ACME need correct time)"
    fi
  fi
}

doctor_network() {
  if safety_has_default_route; then
    _doc PASS network "default route present"
  else
    _doc FAIL network "no default route"
  fi
  if getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts cloudflare.com >/dev/null 2>&1; then
    _doc PASS network "DNS resolution works"
  else
    _doc FAIL network "DNS resolution fails"
  fi
  local rc=0
  safety_internet_ok || rc=$?
  case "$rc" in
    0) _doc PASS network "outbound HTTPS works" ;;
    2) _doc INFO network "outbound HTTPS not tested (curl missing)" ;;
    *) _doc WARN network "outbound HTTPS failed (filtered network or MTU problem?)" ;;
  esac
}

doctor_panel() {
  local app="${SSL_PANEL_APP_DIR:-/opt/pasarguard}" env port scheme code rc=0
  [[ -d "$app" ]] || { _doc INFO panel "PasarGuard panel not installed here"; return; }
  env="${app}/.env"
  _doc_compose_running "$app" || rc=$?
  case "$rc" in
    0) _doc PASS panel "container running" ;;
    1) _doc FAIL panel "container NOT running (cd ${app} && docker compose up -d)" ;;
    *) _doc INFO panel "container state unknown (docker not available)" ;;
  esac
  port="$(_ssl_env_get "$env" UVICORN_PORT 2>/dev/null || echo 8000)"
  if [[ -n "$(_ssl_env_get "$env" UVICORN_UDS 2>/dev/null)" ]]; then
    _doc INFO panel "listens on a unix socket (UVICORN_UDS)"
    return
  fi
  if _doc_listening "$port"; then
    _doc PASS panel "listening on port ${port}"
  else
    _doc FAIL panel "nothing listening on panel port ${port}"
    return
  fi
  scheme=http
  [[ -n "$(_ssl_env_get "$env" UVICORN_SSL_CERTFILE 2>/dev/null)" ]] && scheme=https
  if have_cmd curl; then
    code="$(curl -sk -o /dev/null --max-time 8 -w '%{http_code}' "${scheme}://127.0.0.1:${port}/" 2>/dev/null || true)"
    if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then
      _doc PASS panel "answers on ${scheme}://127.0.0.1:${port} (HTTP ${code})"
    else
      _doc FAIL panel "no HTTP answer on ${scheme}://127.0.0.1:${port} (${code:-none})"
    fi
  fi
}

doctor_node() {
  local app=/opt/pg-node rc=0 port cert
  [[ -d "$app" ]] || { _doc INFO node "PasarGuard node not installed here"; return; }
  _doc_compose_running "$app" || rc=$?
  case "$rc" in
    0) _doc PASS node "container running" ;;
    1) _doc FAIL node "container NOT running (cd ${app} && docker compose up -d)" ;;
    *) _doc INFO node "container state unknown (docker not available)" ;;
  esac
  port="$(_ssl_env_get "${app}/.env" SERVICE_PORT 2>/dev/null || true)"
  [[ -n "$port" ]] || port="$(sed -n 's/^[[:space:]]*SERVICE_PORT:[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p' "${app}/docker-compose.yml" 2>/dev/null | head -n1)"
  port="${port:-62050}"
  if _doc_listening "$port"; then
    _doc PASS node "service port ${port} listening"
  else
    _doc FAIL node "service port ${port} not listening"
  fi
  cert="${SSL_NODE_CERT_DIR:-/var/lib/pg-node/certs}/ssl_cert.pem"
  [[ -f "$cert" ]] && _doc_cert_check node "$cert" "node certificate"
  if [[ -f "${SSL_STATE_DIR}/node-cert-changed" ]]; then
    _doc WARN node "node certificate changed $(cat "${SSL_STATE_DIR}/node-cert-changed") — paste it in Panel → Nodes"
  fi
}

doctor_ssl() {
  _ssl_load_config
  if [[ -z "${SSL_PRIMARY:-}" ]]; then
    _doc INFO ssl "no certificate managed by PGClockTB"
    return
  fi
  local live="${SSL_STATE_DIR}/live/fullchain.cer"
  if [[ -f "$live" ]]; then
    _doc_cert_check ssl "$live" "certificate ${SSL_PRIMARY}"
  else
    _doc FAIL ssl "live certificate missing (${live})"
  fi
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    _doc PASS ssl "acme.sh auto-renew cron present"
  else
    _doc FAIL ssl "acme.sh cron missing — SSL → Repair auto-renew"
  fi
  [[ -f "$SSL_POST_HOOK_FAILED" ]] && _doc FAIL ssl "last renewal could not restart: $(cut -d' ' -f2- "$SSL_POST_HOOK_FAILED")"
  local rc=0
  _ssl_verify_live "$SSL_PRIMARY" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) _doc PASS ssl "served certificate matches the current one" ;;
    1) _doc FAIL ssl "served certificate is NOT the current one (restart / re-apply)" ;;
    *) _doc INFO ssl "served certificate not checked (no TLS listener known)" ;;
  esac
}

doctor_haproxy() {
  local PROXY_ENGINE="" PROXY_MODE="" PROXY_LISTEN_HTTPS="" PROXY_LISTEN_HTTP=""
  kv_load_file "${PROXY_CONFIG_FILE:-${PGCTB_STATE_DIR}/proxy/config.env}" \
    PROXY_ENGINE PROXY_MODE PROXY_LISTEN_HTTPS PROXY_LISTEN_HTTP
  [[ "$PROXY_ENGINE" == haproxy ]] || { _doc INFO haproxy "not configured by PGClockTB"; return; }
  if systemctl is-active --quiet haproxy 2>/dev/null; then
    _doc PASS haproxy "service active (${PROXY_MODE} mode)"
  else
    _doc FAIL haproxy "service NOT active (journalctl -u haproxy -n 40)"
  fi
  if have_cmd haproxy; then
    if haproxy -c -q -f "${PROXY_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}" >/dev/null 2>&1; then
      _doc PASS haproxy "configuration valid"
    else
      _doc FAIL haproxy "configuration INVALID (haproxy -c)"
    fi
  fi
  local p
  for p in ${PROXY_LISTEN_HTTPS:-443} ${PROXY_LISTEN_HTTP:-}; do
    [[ -n "$p" ]] || continue
    if [[ "$(_proxy_port_owner "$p" 2>/dev/null)" == haproxy ]]; then
      _doc PASS haproxy "port ${p} held by haproxy"
    else
      _doc FAIL haproxy "port ${p} not held by haproxy"
    fi
  done
}

doctor_security() {
  local p ports=()
  mapfile -t ports < <(detect_live_ssh_ports 2>/dev/null)
  local listening=()
  for p in "${ports[@]}"; do
    _doc_listening "$p" && listening+=("$p")
  done
  if ((${#listening[@]})); then
    _doc PASS security "SSH listening on ${listening[*]}"
  else
    _doc WARN security "no SSH listener found on ${ports[*]:-22}"
  fi
  if have_cmd sshd || [[ -x /usr/sbin/sshd ]]; then
    local sshd_bin=sshd
    have_cmd sshd || sshd_bin=/usr/sbin/sshd
    if "$sshd_bin" -t >/dev/null 2>&1; then
      _doc PASS security "sshd config valid"
    else
      _doc FAIL security "sshd config INVALID (sshd -t) — do not restart ssh"
    fi
  fi
  if have_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    local missing=()
    for p in "${listening[@]:-${ports[@]}}"; do
      ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]" || missing+=("$p")
    done
    if ((${#missing[@]})); then
      _doc FAIL security "UFW active but SSH port(s) ${missing[*]} not allowed"
    else
      _doc PASS security "UFW active, SSH allowed"
    fi
  else
    _doc INFO security "UFW not active"
  fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    _doc PASS security "Fail2Ban active"
  fi
  if have_cmd nft && nft list table inet securebox >/dev/null 2>&1; then
    local ip rules
    rules="$(nft list chain inet securebox input 2>/dev/null)"
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      if grep -q "saddr ${ip} accept" <<<"$rules"; then
        _doc PASS security "abuse block allows admin IP ${ip}"
      else
        _doc WARN security "abuse block has no allow rule for current admin IP ${ip} (re-apply)"
      fi
    done < <(pgctb_admin_ips)
  fi
}

doctor_toolbox() {
  _doc INFO toolbox "PGClockTB ${PGCTB_VERSION}"
  local k
  for k in ssh ufw dns mtu; do
    if declare -F rollback_is_armed >/dev/null 2>&1 && rollback_is_armed "$k"; then
      _doc WARN toolbox "timed rollback still armed for ${k} (confirm or it reverts)"
    fi
  done
}

# --- report --------------------------------------------------------------------

doctor_redact() {
  # Mask IPs, managed domains and e-mail addresses for sharing
  local -a doms=()
  local d i=0 SSL_DOMAINS="" SSL_PRIMARY="" PROXY_PANEL_DOMAIN="" PROXY_SUB_DOMAIN=""
  kv_load_file "${SSL_CONFIG_FILE:-${PGCTB_STATE_DIR}/ssl/config.env}" SSL_DOMAINS SSL_PRIMARY
  kv_load_file "${PROXY_CONFIG_FILE:-${PGCTB_STATE_DIR}/proxy/config.env}" PROXY_PANEL_DOMAIN PROXY_SUB_DOMAIN
  read -r -a doms <<<"${SSL_DOMAINS:-$SSL_PRIMARY} ${PROXY_PANEL_DOMAIN} ${PROXY_SUB_DOMAIN}"
  local -a sed_args=(-E
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[email]/g'
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[ip]/g'
    -e 's/([0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}/[ipv6]/g'
    -e 's/[0-9a-fA-F]{0,4}::[0-9a-fA-F:]+/[ipv6]/g')
  for d in "${doms[@]}"; do
    [[ -n "$d" ]] || continue
    i=$((i + 1))
    d="${d//./\\.}"
    d="${d//\*/\\*}"
    sed_args+=(-e "s/${d}/[domain${i}]/g")
  done
  sed "${sed_args[@]}"
}

module_doctor() {
  # module_doctor [--share]
  local share=0
  [[ "${1:-}" == "--share" ]] && share=1
  DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0 DOC_LINES=()
  ui_step "Doctor — health check (read-only)"
  doctor_system
  doctor_network
  doctor_panel
  doctor_node
  doctor_ssl
  doctor_haproxy
  doctor_security
  doctor_toolbox

  local report line
  report="$(
    printf 'PGClockTB %s doctor — %s\n' "$PGCTB_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "${DOC_LINES[@]}"
    printf 'SUMMARY  pass=%s warn=%s fail=%s\n' "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL"
  )"
  if (( share )); then
    report="$(doctor_redact <<<"$report")"
  fi

  while IFS= read -r line; do
    case "$line" in
      PASS*) printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET" ;;
      WARN*) printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET" ;;
      FAIL*) printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<<"$report"

  mkdir -p "$DOCTOR_DIR" && chmod 700 "$DOCTOR_DIR" 2>/dev/null || true
  local out suffix="" note=""
  if (( share )); then
    suffix="-shared"
    note=" (IPs, domains and e-mails masked)"
  fi
  out="${DOCTOR_DIR}/doctor-$(date +%Y%m%d-%H%M%S)${suffix}.txt"
  if printf '%s\n' "$report" >"$out" 2>/dev/null; then
    ui_info "Saved: ${out}${note}"
  fi
  (( DOC_FAIL == 0 ))
}

# --- external port check (no third party) -------------------------------------
# A port that is open locally can still be blocked upstream (provider firewall,
# filtering). The only honest test is a connection from OUTSIDE — run
# `pgclock portcheck` on another server you own (e.g. a node, or a server in
# the country your users are in).

portcheck_targets() {
  # Important public TCP ports of THIS server, one per line (sorted, unique)
  local p PROXY_ENGINE="" PROXY_LISTEN_HTTPS="" PROXY_LISTEN_HTTP="" PROXY_EXTRA_PORTS="" PROXY_EXTRA_PLAIN_PORTS=""
  {
    detect_live_ssh_ports 2>/dev/null
    kv_load_file "${PROXY_CONFIG_FILE:-${PGCTB_STATE_DIR}/proxy/config.env}" \
      PROXY_ENGINE PROXY_LISTEN_HTTPS PROXY_LISTEN_HTTP PROXY_EXTRA_PORTS PROXY_EXTRA_PLAIN_PORTS
    if [[ "$PROXY_ENGINE" == haproxy ]]; then
      for p in $PROXY_LISTEN_HTTPS $PROXY_LISTEN_HTTP $PROXY_EXTRA_PORTS $PROXY_EXTRA_PLAIN_PORTS; do
        echo "$p"
      done
    fi
    local env="${SSL_PANEL_APP_DIR:-/opt/pasarguard}/.env" host
    host="$(_ssl_env_get "$env" UVICORN_HOST 2>/dev/null || true)"
    if [[ -f "$env" && "$host" != 127.0.0.1 && "$host" != localhost ]]; then
      _ssl_env_get "$env" UVICORN_PORT 2>/dev/null || true
    fi
    if [[ -d /opt/pg-node ]]; then
      _ssl_env_get /opt/pg-node/.env SERVICE_PORT 2>/dev/null || echo 62050
    fi
    discover_public_ports 2>/dev/null | awk '$1 ~ /tcp/ {print $2}'
  } | while IFS= read -r p; do is_port "$p" && echo "$p"; done | sort -n -u
}

portcheck_run() {
  # portcheck_run HOST PORT... → TCP connect test from THIS machine
  local host="$1" p open=0 closed=0
  shift
  if [[ -z "$host" ]] || [[ ! "$host" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    ui_error "Invalid host: ${host}"
    return 1
  fi
  for p in "$@"; do
    is_port "$p" || { ui_warn "skip invalid port ${p}"; continue; }
    if timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${p}" 2>/dev/null; then
      printf '%s  %-6s open\n' "$host" "$p"
      open=$((open + 1))
    else
      printf '%s  %-6s CLOSED / filtered\n' "$host" "$p"
      closed=$((closed + 1))
    fi
  done
  ui_info "open=${open} closed=${closed} (tested from $(hostname 2>/dev/null || echo this host))"
  (( closed == 0 ))
}

portcheck_guide() {
  # Print ready-to-run commands for testing THIS server from another one
  local host ports
  _ssl_load_config 2>/dev/null || true
  host="${SSL_PRIMARY:-$(_ssl_public_ip)}"
  ports="$(portcheck_targets | tr '\n' ' ')"
  ports="$(trim "$ports")"
  ui_box_start "External port check — run from ANOTHER server you own"
  ui_info "Ports open locally can still be blocked upstream. Test from outside:"
  ui_kv "This server" "${host:-<public IP or domain>}"
  ui_kv "Ports" "${ports:-none detected}"
  echo
  printf '   # On a server with PGClockTB:\n'
  printf '   sudo pgclock portcheck %s "%s"\n\n' "${host:-HOST}" "$ports"
  printf '   # On any Linux server (bash only):\n'
  printf '   for p in %s; do timeout 4 bash -c "exec 3<>/dev/tcp/%s/$p" 2>/dev/null && echo "$p open" || echo "$p CLOSED"; done\n' \
    "$ports" "${host:-HOST}"
  echo
  ui_info "Tip: run it from a server in the same country as your users to see real reachability."
  ui_box_end
}
