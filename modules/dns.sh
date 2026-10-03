#!/usr/bin/env bash
# Module: DNS (+ live latency benchmark for this server's location)
# shellcheck shell=bash

# Preset catalog: id|label|primary|secondary
DNS_PRESETS=(
  "cloudflare|Cloudflare (1.1.1.1)|1.1.1.1|1.0.0.1"
  "google|Google (8.8.8.8)|8.8.8.8|8.8.4.4"
  "quad9|Quad9 (9.9.9.9)|9.9.9.9|149.112.112.112"
  "opendns|OpenDNS (208.67.222.222)|208.67.222.222|208.67.220.220"
  "adguard|AdGuard (94.140.14.14)|94.140.14.14|94.140.15.15"
  "keep|Keep current DNS||"
  "custom|Custom DNS servers (manual entry)||"
)

# Benchmark probe names (diverse CDNs / endpoints)
DNS_BENCH_NAMES=(google.com cloudflare.com github.com)

# Results from last dns_run_benchmark (parallel arrays)
DNS_BENCH_IDS=()
DNS_BENCH_LABELS=()
DNS_BENCH_PRIMARY=()
DNS_BENCH_SECONDARY=()
DNS_BENCH_MS=()      # average ms; 99999 = failed
DNS_BENCH_OK=()      # 1/0
DNS_BENCH_BEST_IDX=""

dns_preset_labels() {
  local p
  for p in "${DNS_PRESETS[@]}"; do
    IFS='|' read -r _ label _ _ <<<"$p"
    printf '%s\n' "$label"
  done
}

dns_ensure_dig() {
  if have_cmd dig; then
    return 0
  fi
  ui_info "Installing dnsutils for accurate DNS latency tests..."
  apt_install_safe dnsutils >/dev/null 2>&1 || true
  have_cmd dig
}

# Query one nameserver for one name → print milliseconds, or fail
dns_query_ms() {
  local server="$1"
  local name="$2"
  local out ms status
  out="$(dig +time=2 +tries=1 +stats @"$server" "$name" A 2>/dev/null)" || return 1
  status="$(awk '/status:/ {for(i=1;i<=NF;i++) if($i ~ /^status:$/) {print $(i+1); exit}}' <<<"$out")"
  status="${status%,}"
  [[ "$status" == "NOERROR" ]] || return 1
  ms="$(awk '/Query time:/ {print $4; exit}' <<<"$out")"
  [[ "$ms" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ms"
}

# Average successful queries across DNS_BENCH_NAMES (need ≥1 success)
dns_avg_ms() {
  local server="$1"
  local name ms sum=0 count=0
  for name in "${DNS_BENCH_NAMES[@]}"; do
    ms="$(dns_query_ms "$server" "$name" 2>/dev/null)" || continue
    sum=$((sum + ms))
    count=$((count + 1))
  done
  (( count > 0 )) || return 1
  printf '%s\n' "$(( (sum + count / 2) / count ))"
}

dns_run_benchmark() {
  # Populates DNS_BENCH_* and prints a ranked table for this server location.
  DNS_BENCH_IDS=()
  DNS_BENCH_LABELS=()
  DNS_BENCH_PRIMARY=()
  DNS_BENCH_SECONDARY=()
  DNS_BENCH_MS=()
  DNS_BENCH_OK=()
  DNS_BENCH_BEST_IDX=""

  if ! dns_ensure_dig; then
    ui_warn "dig unavailable — skipping DNS speed test"
    return 1
  fi

  ui_step "DNS speed test for this server"
  ui_info "Probing: ${DNS_BENCH_NAMES[*]}"
  ui_info "Metric: average dig Query time (UDP/53) — lower is better"
  echo

  local p id label primary secondary ms idx=0 best_ms=99999 best_i=""
  for p in "${DNS_PRESETS[@]}"; do
    IFS='|' read -r id label primary secondary <<<"$p"
    id="$(trim "$id")"
    case "$id" in
      keep|custom) continue ;;
    esac
    [[ -n "$primary" ]] || continue

    printf '   testing %-12s %-15s ... ' "$id" "$primary"
    if ms="$(dns_avg_ms "$primary")"; then
      printf '%s%sms%s\n' "$C_GREEN" "$ms" "$C_RESET"
      DNS_BENCH_OK+=("1")
      DNS_BENCH_MS+=("$ms")
      if (( ms < best_ms )); then
        best_ms=$ms
        best_i=$idx
      fi
    else
      printf '%sfail%s\n' "$C_RED" "$C_RESET"
      DNS_BENCH_OK+=("0")
      DNS_BENCH_MS+=("99999")
    fi
    DNS_BENCH_IDS+=("$id")
    DNS_BENCH_LABELS+=("$label")
    DNS_BENCH_PRIMARY+=("$primary")
    DNS_BENCH_SECONDARY+=("$secondary")
    idx=$((idx + 1))
  done

  # Also sample current resolver if known
  if ((${#DNS_CURRENT[@]})) && is_ipv4 "${DNS_CURRENT[0]}"; then
    local cur="${DNS_CURRENT[0]}"
    local already=0
    for primary in "${DNS_BENCH_PRIMARY[@]}"; do
      [[ "$primary" == "$cur" ]] && already=1 && break
    done
    if (( ! already )); then
      printf '   testing %-12s %-15s ... ' "current" "$cur"
      if ms="$(dns_avg_ms "$cur")"; then
        printf '%s%sms%s\n' "$C_GREEN" "$ms" "$C_RESET"
        DNS_BENCH_OK+=("1")
        DNS_BENCH_MS+=("$ms")
        if (( ms < best_ms )); then
          # current can win the table display, but auto-pick still uses presets only
          best_ms=$ms
        fi
      else
        printf '%sfail%s\n' "$C_RED" "$C_RESET"
        DNS_BENCH_OK+=("0")
        DNS_BENCH_MS+=("99999")
      fi
      DNS_BENCH_IDS+=("current")
      DNS_BENCH_LABELS+=("Current (${cur})")
      DNS_BENCH_PRIMARY+=("$cur")
      DNS_BENCH_SECONDARY+=("${DNS_CURRENT[1]:-}")
    fi
  fi

  DNS_BENCH_BEST_IDX="$best_i"

  echo
  ui_box_start "DNS ranking (best for THIS server)"
  local i mark
  for i in "${!DNS_BENCH_IDS[@]}"; do
    mark=""
    if [[ -n "$best_i" && "$i" == "$best_i" && "${DNS_BENCH_OK[$i]}" == "1" ]]; then
      mark="  << BEST"
    fi
    if [[ "${DNS_BENCH_OK[$i]}" == "1" ]]; then
      ui_kv "${DNS_BENCH_LABELS[$i]}" "${DNS_BENCH_MS[$i]} ms${mark}"
    else
      ui_kv "${DNS_BENCH_LABELS[$i]}" "unreachable"
    fi
  done
  ui_box_end

  if [[ -n "$best_i" ]]; then
    ui_success "Best preset here: ${DNS_BENCH_LABELS[$best_i]} (${DNS_BENCH_MS[$best_i]} ms)"
    return 0
  fi
  ui_warn "No DNS preset responded — you can keep current or enter custom"
  return 1
}

dns_apply_best_from_benchmark() {
  # Sets SECUREBOX_ANSWERS dns_* from best preset (not "current")
  local i id choice=0
  if [[ -z "${DNS_BENCH_BEST_IDX}" ]]; then
    return 1
  fi
  i="${DNS_BENCH_BEST_IDX}"
  id="${DNS_BENCH_IDS[$i]}"
  # Map id → preset index in DNS_PRESETS (1-based dns_choice)
  local p pid
  local n=0
  for p in "${DNS_PRESETS[@]}"; do
    n=$((n + 1))
    IFS='|' read -r pid _ _ _ <<<"$p"
    if [[ "$pid" == "$id" ]]; then
      choice=$n
      break
    fi
  done
  (( choice > 0 )) || return 1
  SECUREBOX_ANSWERS[dns_choice]="$choice"
  SECUREBOX_ANSWERS[dns_id]="$id"
  SECUREBOX_ANSWERS[dns_primary]="${DNS_BENCH_PRIMARY[$i]}"
  SECUREBOX_ANSWERS[dns_secondary]="${DNS_BENCH_SECONDARY[$i]}"
  return 0
}

dns_preset_labels_with_bench() {
  # Menu labels enriched with last benchmark timings
  local p id label primary secondary
  local i ms_show
  for p in "${DNS_PRESETS[@]}"; do
    IFS='|' read -r id label primary secondary <<<"$p"
    id="$(trim "$id")"
    ms_show=""
    if [[ "$id" != "keep" && "$id" != "custom" ]]; then
      for i in "${!DNS_BENCH_IDS[@]}"; do
        if [[ "${DNS_BENCH_IDS[$i]}" == "$id" ]]; then
          if [[ "${DNS_BENCH_OK[$i]}" == "1" ]]; then
            ms_show=" — ${DNS_BENCH_MS[$i]}ms"
            if [[ -n "${DNS_BENCH_BEST_IDX}" && "$i" == "${DNS_BENCH_BEST_IDX}" ]]; then
              ms_show="${ms_show} ★ BEST"
            fi
          else
            ms_show=" — unreachable"
          fi
          break
        fi
      done
    fi
    printf '%s%s\n' "$label" "$ms_show"
  done
}

dns_resolve_choice() {
  # Sets DNS_PRIMARY DNS_SECONDARY DNS_CHOICE_ID from SECUREBOX_ANSWERS
  local idx="${SECUREBOX_ANSWERS[dns_choice]:-}"
  if [[ -z "$idx" ]]; then
    DNS_CHOICE_ID="${SECUREBOX_ANSWERS[dns_id]:-}"
    DNS_PRIMARY="${SECUREBOX_ANSWERS[dns_primary]:-}"
    DNS_SECONDARY="${SECUREBOX_ANSWERS[dns_secondary]:-}"
    return 0
  fi
  local p="${DNS_PRESETS[$((idx - 1))]}"
  local id label primary secondary
  IFS='|' read -r id label primary secondary <<<"$p"
  DNS_CHOICE_ID="$id"

  if [[ -n "${SECUREBOX_ANSWERS[dns_primary]:-}" && "$id" != "keep" ]]; then
    DNS_PRIMARY="${SECUREBOX_ANSWERS[dns_primary]}"
    DNS_SECONDARY="${SECUREBOX_ANSWERS[dns_secondary]:-}"
    return 0
  fi

  case "$id" in
    keep)
      DNS_PRIMARY="${DNS_CURRENT[0]:-}"
      DNS_SECONDARY="${DNS_CURRENT[1]:-}"
      ;;
    custom)
      DNS_PRIMARY="${SECUREBOX_ANSWERS[dns_primary]}"
      DNS_SECONDARY="${SECUREBOX_ANSWERS[dns_secondary]:-}"
      ;;
    *)
      DNS_PRIMARY="$primary"
      DNS_SECONDARY="$secondary"
      SECUREBOX_ANSWERS[dns_primary]="$primary"
      SECUREBOX_ANSWERS[dns_secondary]="$secondary"
      ;;
  esac
}

module_dns() {
  ui_step "Configure DNS"
  detect_dns_manager

  if [[ -z "${SECUREBOX_ANSWERS[dns_choice]:-}" && -z "${SECUREBOX_ANSWERS[dns_id]:-}" ]]; then
    module_skip "dns" "no DNS choice from user"
    return 0
  fi

  dns_resolve_choice

  if [[ "$DNS_CHOICE_ID" == "keep" ]]; then
    module_skip "dns" "user kept current DNS"
    ui_info "DNS unchanged"
    return 0
  fi

  if ! is_ipv4 "$DNS_PRIMARY"; then
    module_fail "dns" "invalid primary DNS: ${DNS_PRIMARY}"
    confirm_continue_on_error "dns" "invalid primary DNS" || return 1
    return 0
  fi
  if [[ -n "$DNS_SECONDARY" ]] && ! is_ipv4 "$DNS_SECONDARY"; then
    module_fail "dns" "invalid secondary DNS: ${DNS_SECONDARY}"
    confirm_continue_on_error "dns" "invalid secondary DNS" || return 1
    return 0
  fi

  ui_info "DNS manager: ${DNS_MANAGER}"
  ui_info "Applying DNS: ${DNS_PRIMARY} ${DNS_SECONDARY}"

  if apply_dns_servers "$DNS_PRIMARY" "$DNS_SECONDARY"; then
    module_ok "dns"
    ui_success "DNS configured via ${DNS_MANAGER}"
  else
    module_fail "dns" "apply or resolve check failed"
    confirm_continue_on_error "dns" "DNS apply/resolve failed" || return 1
  fi
}
