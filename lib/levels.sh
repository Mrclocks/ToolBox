#!/usr/bin/env bash
# PGClockTB — optimization levels + high-risk gate
#   🟢 low  (Safe)     : no connectivity risk, trivially reversible
#   🟡 mid  (Balanced) : low + Fail2Ban; DNS / MTU / IPv6 / services are asked
#                        one by one on a TTY and kept unchanged otherwise
#   🔴 high            : SSH, UFW, abuse block — NEVER part of a level;
#                        Security menu only, one item at a time, typed YES
# shellcheck shell=bash

# Same associative array as lib/questions.sh (no "=()": keep existing answers)
declare -gA PGCTB_ANSWERS

_level_base() {
  detect_network_stack 2>/dev/null || true
  detect_dns_manager 2>/dev/null || true
  PGCTB_ANSWERS[apply_mode]=level
  PGCTB_ANSWERS[continue_on_error]=yes

  # 🔴 high risk: never touched by a level
  PGCTB_ANSWERS[do_ssh]=no
  PGCTB_ANSWERS[ufw_enable]=no
  PGCTB_ANSWERS[ufw_reset]=no
  PGCTB_ANSWERS[ufw_auto_discover]=no
  PGCTB_ANSWERS[ufw_ports]=""
  PGCTB_ANSWERS[block_abuse]=no
  PGCTB_ANSWERS[abuse_profile]=minimal

  # 🟡 mid items start as "keep" (a level only changes what it states)
  # dns_choice must stay EMPTY: it is a preset index (non-numeric → wrong preset)
  PGCTB_ANSWERS[dns_choice]=""
  PGCTB_ANSWERS[dns_id]=keep
  PGCTB_ANSWERS[mtu]=keep
  PGCTB_ANSWERS[mtu_mss_clamp]=no
  PGCTB_ANSWERS[disable_ipv6]=no
  PGCTB_ANSWERS[disable_unused]=no
  PGCTB_ANSWERS[disable_snapd]=no
  PGCTB_ANSWERS[enable_fail2ban]=no
}

defaults_level_low() {
  _level_base
  PGCTB_ANSWERS[level]=low
  PGCTB_ANSWERS[do_update]=yes
  PGCTB_ANSWERS[update_mode]=safe          # apt-get upgrade (never removes packages)
  ask_update_docker_policy
  PGCTB_ANSWERS[do_timesync]=yes
  PGCTB_ANSWERS[do_bbr]=yes
  PGCTB_ANSWERS[do_logs]=yes
  PGCTB_ANSWERS[logs_truncate_active]=no   # rotated/journal only
  PGCTB_ANSWERS[logs_docker_prune]=no
  PGCTB_ANSWERS[unattended]=yes
  PGCTB_ANSWERS[unattended_reboot]=no
}

defaults_level_mid() {
  defaults_level_low
  PGCTB_ANSWERS[level]=mid
  local cur
  cur="$(_ssh_current_port 2>/dev/null || echo 22)"
  PGCTB_ANSWERS[ssh_current_port]="$cur"
  PGCTB_ANSWERS[ssh_port]="$cur"
  PGCTB_ANSWERS[enable_fail2ban]=yes
  PGCTB_ANSWERS[f2b_bantime]=1h
  PGCTB_ANSWERS[f2b_findtime]=10m
  PGCTB_ANSWERS[f2b_maxretry]=5

  if have_tty; then
    ui_step "🟡 Balanced level — choose each network change (Enter keeps current)"
    if ui_confirm "Change the DNS resolver? (benchmark shows the fastest)" "N"; then
      ask_dns || { PGCTB_ANSWERS[dns_choice]=""; PGCTB_ANSWERS[dns_id]=keep; }
    fi
    if ui_confirm "Tune MTU / MSS clamping?" "N"; then
      ask_mtu || PGCTB_ANSWERS[mtu]=keep
    fi
    ask_ipv6
    if ui_confirm "Review unused services to disable?" "N"; then
      ask_services
    fi
  else
    ui_info "No TTY: DNS, MTU, IPv6 and services are kept unchanged"
  fi
}

ask_update_docker_policy() {
  # Upgrading Docker restarts every container (PasarGuard panel/node → short
  # outage for users). Default: hold Docker during the upgrade.
  PGCTB_ANSWERS[update_docker]=no
  if ! have_cmd docker && ! dpkg -s docker-ce >/dev/null 2>&1 && ! dpkg -s docker.io >/dev/null 2>&1; then
    return 0
  fi
  if have_tty && ui_confirm "Docker is installed. Upgrade Docker too? (restarts panel/node containers)" "N"; then
    PGCTB_ANSWERS[update_docker]=yes
  else
    ui_info "Docker packages will be held during the upgrade (no container restart)"
  fi
}

_level_plan_line() {
  # _level_plan_line MODULE LABEL ANSWER_KEY
  local module="$1" label="$2" key="$3" val
  val="${PGCTB_ANSWERS[$key]:-}"
  case "$val" in
    yes) printf '   %-8s %-34s %s\n' "$(pgctb_risk_label "$module")" "$label" "apply" ;;
    ""|no|keep) printf '   %-8s %-34s %s\n' "$(pgctb_risk_label "$module")" "$label" "keep" ;;
    *) printf '   %-8s %-34s %s\n' "$(pgctb_risk_label "$module")" "$label" "$val" ;;
  esac
}

show_level_plan() {
  ui_box_start "Plan — ${1} level"
  _level_plan_line update "System update (${PGCTB_ANSWERS[update_mode]:-full})" do_update
  _level_plan_line update "  … upgrade Docker too" update_docker
  _level_plan_line timesync "Time sync" do_timesync
  _level_plan_line bbr "BBR + network tuning" do_bbr
  _level_plan_line logs "Clean rotated/journal logs" do_logs
  _level_plan_line unattended "Unattended security upgrades" unattended
  _level_plan_line fail2ban "Fail2Ban (SSH)" enable_fail2ban
  _level_plan_line dns "DNS resolver" dns_id
  _level_plan_line mtu "MTU" mtu
  _level_plan_line ipv6 "Disable IPv6" disable_ipv6
  _level_plan_line services "Disable unused services" disable_unused
  ui_info "🔴 SSH / UFW / abuse block are never part of a level (Security menu)"
  ui_box_end
}

run_level() {
  # run_level low|mid [assume_yes]
  local level="$1" assume_yes="${2:-0}" label
  case "$level" in
    low) label="🟢 Safe (low)"; defaults_level_low ;;
    mid) label="🟡 Balanced (low + mid)"; defaults_level_mid ;;
    *) ui_error "Unknown level: ${level} (use low or mid)"; return 1 ;;
  esac
  show_level_plan "$label"
  if [[ "$assume_yes" != "1" ]]; then
    if ! have_tty; then
      ui_error "No TTY to confirm — re-run with --yes to apply the ${level} level"
      return 1
    fi
    ui_confirm "Apply the ${label} level now?" "Y" || { ui_warn "Cancelled."; return 0; }
  fi
  run_pipeline_all
}

# --- 🔴 high-risk gate --------------------------------------------------------

declare -gA PGCTB_RISK_TEXT=(
  [ssh]="A wrong port, firewall or key setting can lock you out of SSH.|sshd -t validation before reload · old+new port kept during cutover · password login stays on without a usable key · timed rollback|Keep THIS session open and test login from a NEW terminal before confirming."
  [ufw]="Every port that is not allowed gets blocked — panel/node inbounds whose ports are missing stop working for users.|SSH ports always allowed · refuses to enable without SSH rules · rules shown before enable · timed rollback|Use auto-discover for listening ports and add every inbound port of PasarGuard."
  [node_cert]="The panel pins each node's certificate (pasted in Panel → Nodes). Replacing it breaks panel↔node until you paste the new one — and again after EVERY renewal (~60 days).|original node certificate is backed up · SSL → Status flags every change · SSL → Node certificate can restore the original|Nodes normally keep their self-signed certificate; only continue if you really need a public one."
  [abuse]="Blocks whole IP ranges — legitimate users or cloud clients inside them lose access (especially the aggressive profile).|your admin IP is always allowed first · established connections are kept · one-step removal in Undo|Prefer the minimal profile."
)

ui_risk_gate() {
  # ui_risk_gate MODULE TITLE → 0 only after the operator types YES on a TTY
  local module="$1" title="$2" risk safeguards advice ans=""
  IFS='|' read -r risk safeguards advice <<<"${PGCTB_RISK_TEXT[$module]:-High-risk change.||}"
  ui_box_start "🔴 HIGH RISK — ${title}"
  ui_warn "$risk"
  [[ -n "$safeguards" ]] && ui_info "Safeguards: ${safeguards}"
  [[ -n "$advice" ]] && ui_info "$advice"
  ui_box_end
  if ! have_tty; then
    ui_error "High-risk changes need an interactive terminal."
    return 1
  fi
  ui_ask ans "Type YES to continue (anything else cancels)" ""
  if [[ "$ans" != "YES" ]]; then
    ui_warn "Cancelled."
    return 1
  fi
  return 0
}
