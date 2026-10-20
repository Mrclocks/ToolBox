# MrClock ToolBox

VPN hardening & optimization for **Ubuntu 22–26** and **Debian 12–13**.

## Install

```bash
curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash
```

Then:

```bash
sudo mrclock
```

## CLI (all flags)

```text
Modes:
  (default)              Interactive menu
  --one-click            Non-interactive Apply All with safe defaults
  --dry-run              Plan only — show what would change, do not apply
  --verify               Run the verify module and exit
  --help, -h             Show this help

SSH / network:
  --ssh-port <port>      SSH port (1–65535) for --one-click
  --mtu <value>          MTU (1280–9000) or 'keep'
  --dns <id>             cloudflare|google|quad9|opendns|adguard|keep
  --disable-ipv6         Disable IPv6 in --one-click

UFW:
  --ufw                  Enable UFW in --one-click
  --no-ufw               Do not enable UFW (default for one-click)
  --ufw-ports <list>     Extra allows, e.g. "443 51820/udp 1000:2000/tcp"
  --ufw-discover         Auto-allow discovered public listeners
  --ufw-reset            Reset UFW rules before applying (dangerous for NAT)

Abuse / extras:
  --block-abuse          Enable abuse CIDR blocking (minimal profile)
  --no-abuse-block       Skip abuse CIDR blocking (default)
  --abuse-profile <p>    minimal|aggressive (with --block-abuse)
  --fail2ban             Enable Fail2Ban
  --unattended           Enable unattended-upgrades

Safety:
  --rollback-seconds N   Arm timed auto-rollback for SSH/UFW/DNS/MTU (default 120)
  --no-rollback          Disable timed auto-rollback
```

Examples:

```bash
sudo mrclock --help
sudo mrclock --one-click --ufw --ufw-ports "443 51820/udp" --ufw-discover --fail2ban
sudo mrclock --dry-run --one-click
sudo mrclock --verify
```

## Features

Categorized menu:

1. **Optimization** — Apply All, DNS/MTU/BBR, UFW, SSH, Fail2Ban, abuse block, undo
2. **SSL Certificates** — PasarGuard Panel/Node issue + auto-renew (acme.sh)
3. **Reverse Proxy** — HAProxy single-port (panel/node), Caddy, Nginx
4. **Backup** — Install/open PGClockBackup (ToolBox UI → upstream installer)
5. **Restore & Migrate** — PGClockMG wizard + redirect helpers

Optimization details:

- Apply All: **Automatic (low-risk)** or **Customize** — Plan screen + preflight first
- DNS (live dig benchmark), MTU (default keep / MSS clamp), BBR
- UFW autopilot, SSH hardening (`00-securebox.conf`), Fail2Ban
- Optional abuse CIDR block (minimal / aggressive profiles)
- Optional IPv6 disable (refuses if your SSH session is IPv6)
- Undo Toolbox Changes + live MTU/sysctl/services/UFW state
- Verify module: `sshd -T`, `ss`, `resolvectl`, `ufw`, `tc`, sysctl
- Timed auto-rollback for SSH/UFW/DNS/MTU unless you confirm

SSL details:

- Auto-detect Panel vs Node paths; multi-domain SAN
- Deploys to `/var/lib/pasarguard/certs/` and/or `/var/lib/pg-node/certs/`
- Prints exact `.env` / `SSL_CERT_FILE` settings after install
- Auto-renew via acme.sh cron + deploy hook

Rule #1: never lock out the admin or cut connectivity.

## Safety notes

- After changing the SSH port, open a **new** terminal before closing the current session.
- Automatic never enables abuse block or UFW without asking; keeps DNS/MTU by default.
- Prefer preserving SSH env under sudo (otherwise IPv6/admin-IP detection recover via `/proc`):
  `sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,SSH_TTY mrclock`
- Timed rollback arms only on a TTY (never auto-reverts headless `--one-click`).
- Release integrity is **fail-closed**: missing `SHA256SUMS` aborts unless
  `SECUREBOX_ALLOW_INSECURE=1`. See [docs/RELEASE.md](docs/RELEASE.md).

## Dev / CI

```bash
shellcheck -x -S warning install.sh lib/*.sh modules/*.sh scripts/*.sh
bats -r tests
./scripts/gen-checksums.sh   # writes dist/ for release upload
```

---

MIT © MrClock
