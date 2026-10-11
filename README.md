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

## CLI

```bash
sudo mrclock --help
sudo mrclock --one-click --ufw --ufw-ports "443 51820/udp" --fail2ban
sudo mrclock --dry-run --one-click
sudo mrclock --verify
```

Notable flags: `--ssh-port`, `--mtu`, `--dns`, `--ufw` / `--no-ufw`, `--ufw-ports`,
`--ufw-discover`, `--block-abuse`, `--abuse-profile`, `--disable-ipv6`,
`--dry-run`, `--verify`, `--rollback-seconds`.

## Features

- Apply All: **Automatic (low-risk)** or **Customize** — Plan screen + preflight first
- DNS (live dig benchmark), MTU (default keep / MSS clamp), BBR
- UFW autopilot, SSH hardening (`00-securebox.conf`), Fail2Ban
- Optional abuse CIDR block (minimal / aggressive profiles)
- Optional IPv6 disable (refuses if your SSH session is IPv6)
- Restore previous configs + live MTU/sysctl/services/UFW state
- Verify module: `sshd -T`, `ss`, `resolvectl`, `ufw`, `tc`, sysctl
- Timed auto-rollback for SSH/UFW/DNS/MTU unless you confirm

Rule #1: never lock out the admin or cut connectivity.

## Safety notes

- After changing the SSH port, open a **new** terminal before closing the current session.
- Automatic never enables abuse block or UFW without asking; keeps DNS/MTU by default.
- Release archives ship `SHA256SUMS` (optional `.asc`); `install.sh` verifies when present.

## Dev / CI

```bash
shellcheck -x install.sh lib/*.sh modules/*.sh
bats -r tests
./scripts/gen-checksums.sh
```

---

MIT © MrClock
