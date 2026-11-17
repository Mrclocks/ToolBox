# Changelog

## 1.0.0 — 2026-11-17

First stable release of **PGClockTB** (formerly MrClock ToolBox).

Highlights since 0.3.x: rename + automatic migration (0.4) · safety core:
run lock, admin-IP guard, verify-or-revert (0.5) · menus by category, 🟢/🟡
levels, 🔴 Security menu (0.6) · SSL v2: node-certificate safety, verified
`.env`, DNS-01, reuse (0.7) · HAProxy v2: auto-detect, verified apply with
rollback, ACME without downtime (0.8) · Doctor + external port check (0.9) ·
Telegram alerts (0.10).

### Added
- **Self-update**: `pgclock update [--check]`, Tools → Update — verified
  download, version + syntax checks, atomic install, smoke test with automatic
  rollback, `pgclock update rollback`; `pgclock --version`
- **Pinned release key**: `scripts/pin-release-key.sh` embeds the public key;
  signatures are checked only against it in a throwaway GnuPG home;
  `PGCTB_REQUIRE_SIGNATURE=1` refuses unsigned releases

### Fixed
- **Running the installed `pgclock` deleted its own `lib/ modules/ data/`**
  (the tree was copied onto itself); later runs silently re-downloaded from
  GitHub and broke on servers without GitHub access. Installs are now atomic
  and never copy a tree onto itself
- A `.asc` signature was reported "OK" when made by any key in root's keyring


## 0.10.0 — 2026-11-17

### Added
- **Telegram alerts** (Tools → Telegram alerts, `pgclock alerts check|test|status`):
  panel/node/HAProxy/PGClockBackup down, disk, expiring certificate, failed
  post-renew restart, node certificate changed; 6 h repeat, "Recovered"
  messages, renewal announcements; systemd timer every 15 minutes
- Proxy / custom API base for servers that cannot reach api.telegram.org
- Token never logged or on a command line (curl stdin config), file 600

### Changed
- Read-only modes (`status`, `verify`, `doctor`, `portcheck`, `alerts check`,
  `ssl status`, `proxy status`) no longer heal, reinstall, migrate or lock —
  safe for unattended timers


## 0.9.0 — 2026-11-17

### Added
- **Doctor** (`pgclock doctor`, Status & Doctor menu): read-only PASS / WARN /
  FAIL report for system, network, panel, node, SSL, HAProxy, security and
  PGClockTB itself; non-zero exit on FAIL; saved under `/var/lib/pgclocktb/doctor/`
- `pgclock doctor --share`: IPs, managed domains and e-mails masked
- **External port check** without a third party: menu prints this server's
  important ports + ready commands; `pgclock portcheck <host> "<ports>"` tests
  another server from here (run it on a second server to test this one)

### Notes
- A public multi-country checker (check-host.net) was considered but its API
  could not be reached/verified from the build environment, so it is not
  shipped; testing from your own second server is the reliable option


## 0.8.0 — 2026-11-17

### Fixed
- **Remove HAProxy left the panel unreachable** (local HTTP only): the panel
  `.env` from before the first setup is restored and the panel restarted
- **Setup could leave a half-applied state**: config, panel `.env` and proxy
  state are one transaction; failure at any step rolls all of them back

### Added
- Auto-detect panel port (moves a panel on 443/80 to 127.0.0.1:8000) and
  domains from the SSL config — Enter accepts every default
- Port preflight: refuses ports held by other processes (e.g. Xray on 443)
- Verify through HAProxy after setup: panel reachable, unknown Host → 403
- ACME route in HAProxy (`/.well-known/acme-challenge/` → acme.sh on a local
  port): issue and renew no longer stop HAProxy; acme.sh domain conf switched
  for cron renewals and switched back on Remove
- `acme.sh --renew` path synced before every manual renew (renew ignores CLI hooks)

### Tests
- Real HAProxy test: ACME forwarding, panel through HAProxy, 403 for unknown
  hosts; rollback and Remove covered; 146 tests


## 0.7.0 — 2026-11-17

### Fixed
- **Node certificate could be replaced silently**: the panel pins node
  certificates, so deploying a Let's Encrypt cert to a node broke panel↔node
  (and again on every renewal). Default role is now Panel only; node roles need
  a typed `YES`; the original is backed up; every change raises an alert;
  SSL → Node certificate can restore the original and stop node deployment
- **Panel could restart on a cert it cannot read / does not serve**: `.env` is
  now a transaction — container mount check first, then restart, then the
  served certificate must match (fingerprint), otherwise `.env` is restored

### Changed
- Panel files follow the official installer layout:
  `certs/<domain>/fullchain.pem` + `privkey.pem`, `UVICORN_SSL_CA_TYPE = "public"`
  (pre-0.7 `<domain>.cer` files are refreshed only if they exist)

### Added
- DNS-01 via Cloudflare API token (hidden input, verified with Cloudflare);
  Cloudflare-proxied domains detected; wildcard names (`*.example.com`)
- Reuse of an existing valid certificate (30+ days, all names) instead of a new
  request; optional Let's Encrypt staging test in a throwaway cert home
- Live check after issue / renew / in Status (HAProxy or panel TLS port)
- Validation method saved (`SSL_METHOD`); DNS-01 renewals skip port-80 hooks

### Notes
- docs.pasarguard.org was not reachable from the build environment; paths and
  `.env` keys were taken from the official PasarGuard repos (panel/node
  `.env.example`, compose files, installer scripts)


## 0.6.0 — 2026-11-17

### Added
- **Optimization levels**: 🟢 Safe (low) and 🟡 Balanced (low + mid); 🔴 SSH /
  UFW / abuse block are never part of a level
- **Security menu**: 🔴 items one at a time behind a warning screen that needs a
  typed `YES` (refused without a TTY)
- **Commands**: `pgclock status`, `optimize low|mid [--yes]`,
  `ssl status|renew|repair`, `proxy status`; `--yes` flag
- **Update**: safe mode (`apt-get upgrade`), Docker packages held during the
  upgrade unless explicitly allowed (no surprise container restarts)

### Changed
- Main menu: Status · SSL · HAProxy · Optimization · Security · Backup & Restore · Tools
- Menus moved from `install.sh` to `lib/menu.sh`; levels in `lib/levels.sh`
- Fail2Ban `ignoreip` includes every admin IP (all SSH sessions + `PGCTB_ADMIN_IPS`)

### Fixed
- A non-numeric DNS choice could wrap to the last preset; now treated as keep
- Tests: per-test state dirs also on bats < 1.4 (Ubuntu 22.04 CI failure)


## 0.5.0 — 2026-11-17

### Added — safety core (`lib/safety.sh`)
- Single-run lock (`/run/pgclocktb.lock`): concurrent runs are refused
- Admin-IP discovery (SSH session, `who --ips`, `PGCTB_ADMIN_IPS`)
- Risk levels per module (low / mid / high; unknown = high)
- File transactions: exact snapshot/restore, including files that did not exist
- Real connectivity probe (route + HTTPS) and verify-or-revert helper

### Fixed
- **Abuse block could lock out the admin**: admin IPs now get an explicit allow
  rule before the drop rule (nft + iptables, persisted); a warning names any
  admin IP inside a blocked range; refuses when the admin IP is unknown and
  there is no TTY to confirm
- **MTU left a broken value in place** when the default route was lost; now the
  live MTU, `.link` file and NetworkManager setting are reverted immediately,
  also when an HTTPS probe fails after the change but worked before
- **IPv6 disable on IPv6-only hosts** (no IPv4 default route) is refused
- `((i++))` in abuse apply aborted under `set -e`

### CI
- New **VM scenario** job runs `scripts/scenario-smoke.sh` as root on a real
  runner VM (adds admin-IP rule order and lock checks); CI also runs on `claude/**`


## 0.4.0 — 2026-11-17

Roadmap to 1.0.0: 0.4 rename · 0.5 safety core · 0.6 menus & levels ·
0.7 SSL v2 · 0.8 HAProxy v2 · 0.9 Doctor & port check · 0.10 Telegram ·
1.0 signed self-update.

### Changed
- **Renamed to PGClockTB** (was MrClock ToolBox): banner, messages, docs
- Command is now **`pgclock`**; `mrclock` stays as an alias
- Install dir `/opt/pgclocktb`; state / log / backup dirs
  `/var/lib/pgclocktb`, `/var/log/pgclocktb`, `/var/backups/pgclocktb`
- Env vars `PGCTB_*`; legacy `SECUREBOX_*` overrides are still honoured
- Release asset `PGClockTB-<tag>.tar.gz` (installer still accepts `ToolBox-<tag>`)

### Migration (automatic, first non-dry run)
- Old dirs are moved and replaced by symlinks (acme.sh hooks, cron, armed
  rollbacks keep working); if both exist, files are merged without overwrite
- `/opt/mrclock-toolbox` becomes a symlink (only if it is a ToolBox tree)
- `/etc` artifacts written by older versions keep their names (safety)
- HAProxy panel detection accepts both old and new config markers

### Tests
- Real `install.sh` helpers are sourced in tests (`PGCTB_INSTALL_LIB_ONLY=1`)
- Migration, launchers, legacy env and marker compat covered (101 tests)


## 0.3.9 — 2026-11-17

### Fixed
- **PGClockMG / PGClockBackup install & uninstall always failed**: the installer
  path was captured together with UI messages; messages now go to stderr
- **HAProxy Host ACL** ignores `:port` — panel no longer returns 403 on extra
  HTTPS ports (8443…) or non-default listen ports
- **HAProxy PEMs**: a PEM is only built from a certificate that covers the
  domain and whose key matches; setup fails if *any* domain lacks one
- **Renew now** reports failure when the deploy hook fails (no more `|| true`);
  deploy hook exits non-zero on failed copy / HAProxy reload / compose restart
  and skips restarts when the certificate is unchanged (no double restart)
- **ACME post-hook** retries restarting stopped proxies and records failures
  (`acme-post-hook.failed`, syslog); Issue / Renew / Status surface it
- **"Behind HAProxy" detection** no longer trusts commented `UVICORN_SSL_*`
  lines (present in stock PasarGuard `.env`); uses ToolBox proxy config or the
  ToolBox-managed `haproxy.cfg`
- **ECC/RSA**: key type is saved; install-cert / renew / repair target the
  certificate that was actually issued (no stale ECC fallback, no hidden errors)
- **DNS preflight**: checks all A/AAAA answers against all local addresses and
  reports "cannot verify" behind NAT instead of a false warning
- HAProxy binds fall back to IPv4 when the kernel has no IPv6 (HAProxy used to
  refuse to start); extra plain ports are dual-stack like the others
- HAProxy config is validated before saving `config.env`; an invalid first-time
  config is moved aside instead of being left in place
- Extra HTTPS / plain ports default to none (were 8443 / 9000) and are validated

### Security
- `ssl/config.env` and `proxy/config.env` are parsed with an allow-list, never
  `source`d (values with spaces or `$(...)` were executed — including from cron)
- Let's Encrypt email is validated; deploy hook rejects invalid domains
- Deploy hook writes HAProxy PEMs only when HAProxy is installed (configurable dir)
- `ui_read` uses a dynamic fd instead of clobbering fd 3


## 0.3.8 — 2026-10-20

### Fixed
- **SSL renew behind HAProxy**: ACME pre/post hooks temporarily stop/start
  reverse proxies on :80 so HTTP-01 (and cron renew) works after HAProxy setup
- **Renew / Show .env no longer undo HAProxy**: renew does not rewrite panel
  `.env`; apply-env detects HAProxy panel mode and keeps `UVICORN_SSL_*` commented;
  Show .env defaults to **N**

### Security
- **PGClockMG installer** pinned to release tag + SHA-256 verification (fail closed)
- Wizard/Backup access prints **localhost URL** + token separately (no `?token=` in URL)
  and adds SSH-tunnel / UFW guidance
- HAProxy backend host / host:port inputs validated before writing config

## 0.3.7 — 2026-10-20

### Changed
- **Reverse Proxy is HAProxy-only** — Caddy and Nginx setup paths removed from
  menus, module code, docs, and tests (soft conflict warning if they are active)
- **Menus**: every submenu shows `0) Back`; `ui_menu` cancels with Back
- **Input**: `ui_read` uses `/dev/tty` + readline (`-e`) + `stty sane` so
  clear/retype works correctly after wipe / under sudo / curl|bash

## 0.3.6 — 2026-10-20

### Fixed
- **HAProxy panel config** aligned with PasarGuard single-port docs:
  `listen front`, plain `:80` (no forced redirect), optional plain `:9000`,
  Host ACL + `/sub/` gate + `deny_backend`
- After HAProxy panel setup, auto-prepare panel `.env` for local HTTP
  (comment `UVICORN_SSL_*`, set `UVICORN_HOST`/`PORT` to backend)
- Node mode uses `listen front_node` + `bind *:` like the official example

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
