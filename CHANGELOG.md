# Changelog

## 0.3.5 — 2026-10-20

### Changed
- SSL auto `.env` update no longer touches `UVICORN_PORT` (user decides)

## 0.3.4 — 2026-10-20

### Added
- **SSL auto `.env` update**: after Issue/Renew, ToolBox replaces Panel
  `UVICORN_SSL_*` in `/opt/pasarguard/.env` and Node
  `SSL_CERT_FILE` / `SSL_KEY_FILE` in `/opt/pg-node/.env` (and compose),
  then restarts compose when possible. Show `.env` can re-apply.
  (`UVICORN_PORT` left alone as of 0.3.5)

## 0.3.3 — 2026-10-20

### Added
- **Polish (Phase 4)**:
  - SSL preflight (DNS soft-check + port 80 owner)
  - SSL menu: Show `.env` instructions · Repair auto-renew
  - Stronger Panel/Node detection (compose + docker image names)
  - Reverse Proxy conflict warning (stop other engine on :443)
  - PGClockMG Open ensures systemd service is started
  - `docs/OPS.md` ops reference for SSL / Proxy / Backup

## 0.3.2 — 2026-10-20

### Added
- **Backup / Restore & Migrate (Phase 3)** — ToolBox UI bridge to PGClockMG:
  - Backup: Install/Update, Open URL + setup token, Status, Uninstall (PGClockBackup)
  - Restore & Migrate: Install/Update wizard, Open URL + access token, Status,
    Uninstall, Redirect server (3x-ui / Hiddify)
  - Shared `lib/pgclockmg.sh` downloads upstream installer with
    `PG_MIGRATOR_ACTION` / port / `PG_MIGRATOR_YES=1`

## 0.3.1 — 2026-10-20

### Added
- **Reverse Proxy (Phase 2)**:
  - HAProxy panel single-port (HTTPS + optional extra ports, Host ACL, deny default)
  - HAProxy node TCP/SNI mode (REALITY `send-proxy` + fallback)
  - Caddy auto-HTTPS reverse proxy
  - Nginx reverse proxy using ToolBox/PasarGuard certificates
  - Status / Remove with config backup restore
  - End guide: set panel `.env` to local HTTP (no `UVICORN_SSL_*`)

## 0.3.0 — 2026-10-20

### Added
- **Categorized main menu** (English): Optimization, SSL Certificates,
  Reverse Proxy, Backup, Restore & Migrate
- **SSL Certificates**: acme.sh issue, multi-domain (SAN), Panel/Node path
  deploy, auto-renew cron + deploy hook, Status / Renew now
- End-of-setup guide prints exact `.env` / compose `SSL_*` paths for Panel and Node
- Scaffold menus for PGClockMG Backup / Restore & Migrate bridges

### Changed
- Toolbox undo renamed to **Undo Toolbox Changes** (under Optimization)
  to avoid confusion with PasarGuard restore

## 0.2.3 — 2026-10-13

### Fixed
- Bootstrap/`_securebox_have_tree` now requires both abuse ranges files under `data/`
  (empty `data/` no longer passes install then fails with "missing abuse ranges file")
- Abuse module resolves ranges paths at call time from `SECUREBOX_DATA`
- `gen-checksums.sh` refuses to publish without both abuse ranges assets

## 0.2.2 — 2026-10-11

### Fixed
- **One-liner install**: release tarball now packs under `ToolBox-<tag>/` (0.2.1 was
  flat → `archive layout unexpected` after checksum OK)
- Bootstrap treats fetch failure as fatal (no more empty `Starting from` / `/install.sh`)
- Extract accepts `ToolBox-*`, GitHub `Mrclocks-ToolBox-*`, or flat layout
- `gen-checksums.sh` refuses to publish if `ToolBox-<tag>/lib/common.sh` is missing

## 0.2.1 — 2026-10-11

### Fixed
- **Timed rollback actually arms**: no longer deletes the freshly written script via
  `cancel_timed_rollback` before `systemd-run`; verify script exists after arm
- Rollback skipped without TTY (prevents one-click UFW auto-disable after 120s)
- SSH timed rollback restores `ssh.socket` drop-in and clears `ssh_cutover` state
- Recover `SSH_CONNECTION` / `SSH_CLIENT` after `sudo` `env_reset` (IPv6 check,
  fail2ban ignoreip, SSH port detection); `mrclock` wrapper uses `--preserve-env`
- Release verify **fail-closed** on missing `SHA256SUMS` (override:
  `SECUREBOX_ALLOW_INSECURE=1`); optional `SECUREBOX_GPG_FINGERPRINT` pin
- Refresh MTU / UFW / sysctl baselines every run (no stale `state_record_once`)
- MTU timed-rollback default aligned to 120s (same as SSH/UFW/DNS)

## 0.2.0 — 2026-10-11

### Fixed — UFW
- Verify SSH rules with `ufw show added` before enable (status is useless when inactive)
- Detect live SSH ports from `$SSH_CONNECTION` and `ss -tlnp` (sshd)
- Support port ranges (`1000:2000/tcp`); report skipped invalid specs
- Warn that `ufw reset` wipes `before.rules` NAT and about `DEFAULT_FORWARD_POLICY=DROP`

### Fixed — Abuse block
- Accept `ct state established,related` (nft) / `ESTABLISHED,RELATED` (iptables) before drops
- Opt-in profiles: `minimal` (default) / `aggressive`
- Remove AWS/GCP/Azure/DO/Vultr/OVH/Contabo wide ranges from defaults
- Never stop/mask postfix/bind9/named — warn only
- Report nft loaded vs failed element counts
- `block_abuse=no` no longer deletes prior rules without asking

### Fixed — SSH
- Drop-in renamed to `00-securebox.conf` (first value wins); verify with `sshd -T`
- Ubuntu 24.04+ `ssh.socket`: socket drop-in + daemon-reload + restart
- Rollback restores `sshd_config` as well as the drop-in
- Re-run keeps pending dual-port cutover consistent
- Disable password auth only if current login user has a usable key (ignore `command=`)
- Remove `Protocol 2`; configurable `MaxAuthTries` (default 5)

### Fixed — IPv6 / Logs / Automatic
- Refuse or warn loudly if SSH session is over IPv6
- Remove GRUB `ipv6.disable=1` edit (sysctl only)
- No `docker system prune` by default; truncate auth/syslog only when opted in
- Quiet `find -delete`; Automatic asks before full-upgrade / mask services / log cleanup

### Fixed — CLI / restore / DNS / MTU / BBR / Fail2Ban
- Flags: `--ufw-ports`, `--ufw-discover`, `--dry-run`, `--verify`, …; validate ports/DNS/MTU
- Exit non-zero when any module failed; fix `is_ipv4` leading zeros; remove dead code
- Live state restore (`ip link` MTU, `sysctl -w`, `systemctl unmask`, `ufw disable`)
- Recommended restore never points at the restore safety snapshot; NM DNS rollback
- DNS validated with `dig @server` + `resolvectl status`
- MTU matched by MACAddress; default keep; optional TCP MSS clamping
- BBR: `ip_forward` opt-in; `nf_conntrack` via modules-load.d; skip read-only keys; `tc qdisc`
- Fail2Ban: `bantime.increment`, admin IP in `ignoreip`, `backend=systemd` without auth.log

### Added
- Plan / preflight screen with risk levels; timed auto-rollback (`systemd-run`)
- `verify` module + menu item 17
- `ui_clear` uses `clear -x`; backup dir `chmod 700`
- Release integrity: `SHA256SUMS` (+ `.asc`) verified as **separate** release assets (never trust sums inside the tarball); latest tag via `/releases/latest` redirect
- `--dry-run` is a hard no-write for `/etc` (modules + heal + persistent install skipped)
- bats unit tests + GitHub Actions (shellcheck, bats, Ubuntu 22/24 & Debian 12/13 smoke)
- README documents **all** CLI flags including `--ufw-ports` / `--ufw-discover`

## 0.1.10 — 2026-10-03

### Safety audit — never touch addressing/gateway
- MTU: **never** write netplan `ethernets:` stubs or networkd `.network` files
- MTU persistence only via systemd `.link` + live `ip link set`
- DNS: **never** write netplan DNS stubs; no `Domains=~.`; keep FallbackDNS; rollback on failure
- NetworkManager: prefer `device reapply` over `connection up` (no NIC flap)
- BBR: removed live `tc qdisc replace` on default iface
- Heal on startup removes dangerous `.network` + old `99-securebox-{mtu,dns}.yaml`
- Restore: no `netplan apply` / hard networkd restart

## 0.1.9 — 2026-10-03

### Fixed / Safety
- **Automatic** is now low-risk: keeps DNS + MTU, disables abuse block by default
- MTU on networkd no longer writes a `.network` file that can steal DHCP and kill connectivity (uses `.link` instead)
- `rp_filter` softened from strict(1) to loose(2) for VPS/VPN
- Startup auto-heals old dangerous `10-securebox-*.network` drop-ins

## 0.1.8 — 2026-10-03

### Added
- **Restore previous changes** (menu 15): restore DNS / MTU / SSH / UFW / Fail2Ban / sysctl / abuse from MrClock backups
- Backup MANIFEST tracks new vs existing files for accurate undo
- UFW rule files included in backups for proper restore

## 0.1.7 — 2026-10-03

### Changed
- Automatic Apply All now **asks only UFW + IPv6** (cannot be safely forced); everything else stays automatic

## 0.1.6 — 2026-10-03

### Added
- Apply All → choose **Automatic** or **Customize**
- Automatic: full safe profile, keep current SSH port, pick fastest DNS via live dig benchmark
- DNS menu shows live latency ranking (★ BEST for this server)
- Clean Logs module: journal vacuum, rotated `/var/log`, Docker JSON logs, apt cache

## 0.1.5 — 2026-10-03

### Fixed
- Apply All (option 1) asks for **every** step — nothing is forced
- Update / chrony / BBR / SSH now require explicit yes like the rest

## 0.1.4 — 2026-10-03

### Fixed
- MTU `keep` no longer fails when default interface is missing
- SSH cutover confirm works after `curl | bash` (uses `/dev/tty`, not only stdin)
- `--help` works without root
- Apply All clears stale answers from earlier menu actions
- UFW menu also applies IPv6 answer when requested
- Safer CLI arg parsing when values are missing
- nftables abuse rules reload cleanly on boot
- Fail2Ban backend set to `auto` for wider compatibility
- `ui_read` / error continue no longer break in non-TTY environments

### Improved
- Version read from `VERSION` file
- `apt-get update` runs once per session (faster Apply All)
- Branding messages say MrClock

## 0.1.3 — 2026-10-02

### Fixed
- Main menu hard-clears previous logs when returning
- Replaced Unicode separators/icons that became "?" on mobile terminals with ASCII

## 0.1.2 — 2026-10-02

### Fixed
- DNS menu selection was ignored (`ui_menu` shadowed `choice`)
- One-liner refreshes `/opt` from latest

## 0.1.1 — 2026-10-02

### Fixed
- Optional modules require explicit yes
- Stable `releases/latest` install URL

## 0.1.0-beta — 2026-10-02

Initial beta.
