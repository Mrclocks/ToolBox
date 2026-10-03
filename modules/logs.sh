#!/usr/bin/env bash
# Module: reclaim disk — Ubuntu journal/logs + Docker container logs
# shellcheck shell=bash

_logs_bytes_human() {
  local b="${1:-0}"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$b" 2>/dev/null && return 0
  fi
  # fallback rough
  if (( b >= 1073741824 )); then
    printf '%sG\n' "$((b / 1073741824))"
  elif (( b >= 1048576 )); then
    printf '%sM\n' "$((b / 1048576))"
  else
    printf '%sK\n' "$((b / 1024))"
  fi
}

_logs_path_size() {
  local path="$1"
  if [[ -e "$path" ]]; then
    du -sb "$path" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

_logs_disk_used() {
  df -B1 --output=used / 2>/dev/null | tail -n1 | tr -d ' ' || echo 0
}

_logs_clean_journal() {
  if ! have_cmd journalctl; then
    return 0
  fi
  ui_info "Vacuuming systemd journal (keep ~100MB / 3 days)..."
  journalctl --vacuum-size=100M >/dev/null 2>&1 || true
  journalctl --vacuum-time=3d >/dev/null 2>&1 || true
}

_logs_clean_rotated() {
  ui_info "Removing rotated / compressed /var/log archives..."
  find /var/log -type f \( \
      -name '*.gz' -o -name '*.xz' -o -name '*.bz2' \
      -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' \
      -o -name '*.4' -o -name '*.5' -o -name '*.6' -o -name '*.7' \
    \) -print -delete 2>/dev/null || true
  # Truncate huge active text logs that grow forever (keep file inode for daemons)
  local f
  for f in /var/log/syslog /var/log/messages /var/log/kern.log /var/log/auth.log \
           /var/log/daemon.log /var/log/ufw.log /var/log/fail2ban.log; do
    if [[ -f "$f" ]]; then
      local sz
      sz="$(_logs_path_size "$f")"
      if (( sz > 50 * 1048576 )); then
        ui_info "Truncating large log $(basename "$f") ($(_logs_bytes_human "$sz"))"
        : >"$f" 2>/dev/null || true
      fi
    fi
  done
}

_logs_clean_apt() {
  ui_info "Cleaning apt package cache..."
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
}

_logs_clean_docker() {
  if ! have_cmd docker && [[ ! -d /var/lib/docker ]]; then
    ui_info "Docker not present — skip container logs"
    return 0
  fi

  ui_info "Truncating Docker container JSON logs..."
  local f count=0 bytes=0 sz
  while IFS= read -r -d '' f; do
    sz="$(_logs_path_size "$f")"
    (( bytes += sz )) || true
    : >"$f" 2>/dev/null || truncate -s 0 "$f" 2>/dev/null || true
    count=$((count + 1))
  done < <(find /var/lib/docker/containers -type f -name '*-json.log' -print0 2>/dev/null)

  if (( count > 0 )); then
    ui_success "Truncated ${count} Docker log file(s) (~$(_logs_bytes_human "$bytes") before)"
  else
    ui_info "No Docker container JSON logs found"
  fi

  # Unused dangling images/build cache can be huge — only prune dangling, not volumes
  if have_cmd docker && docker info >/dev/null 2>&1; then
    ui_info "Pruning dangling Docker data (images/containers/networks — not volumes)..."
    docker system prune -f >/dev/null 2>&1 || true
  fi
}

_logs_clean_crash_tmp() {
  ui_info "Cleaning crash reports and old temp leftovers..."
  rm -rf /var/crash/* 2>/dev/null || true
  find /var/tmp -type f -mtime +7 -size +10M -delete 2>/dev/null || true
}

module_logs() {
  ui_step "Clean Ubuntu & Docker logs (free disk)"

  if ! require_answer_yes do_logs logs "log cleanup not explicitly enabled"; then
    module_skip "logs" "do_logs='${SECUREBOX_ANSWERS[do_logs]:-}'"
    return 0
  fi

  local before after freed
  before="$(_logs_disk_used)"
  ui_info "Disk used before: $(_logs_bytes_human "$before")"

  _logs_clean_journal
  _logs_clean_rotated
  _logs_clean_docker
  _logs_clean_apt
  _logs_clean_crash_tmp

  after="$(_logs_disk_used)"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ && before -ge after ]]; then
    freed=$((before - after))
    module_ok "logs"
    ui_success "Log cleanup done — reclaimed ~$(_logs_bytes_human "$freed") (used now $(_logs_bytes_human "$after"))"
  else
    module_ok "logs"
    ui_success "Log cleanup finished"
  fi
}
