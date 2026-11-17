# PGClockTB

PasarGuard ops toolbox for **Ubuntu 22–26** and **Debian 12–13**:
hardening, SSL, reverse proxy, and PGClockMG backup/restore bridges.

Ops details: [docs/OPS.md](docs/OPS.md).

## Install

```bash
curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash
```

Then:

```bash
sudo pgclock
```

### Upgrading from MrClock ToolBox (< 0.4.0)

Nothing to do by hand — the first run of 0.4.0 migrates automatically:

| Before | After | Old path becomes |
|---|---|---|
| `mrclock` | `pgclock` | alias (still works) |
| `/opt/mrclock-toolbox` | `/opt/pgclocktb` | symlink |
| `/var/lib/securebox` | `/var/lib/pgclocktb` | symlink |
| `/var/log/securebox` | `/var/log/pgclocktb` | symlink |
| `/var/backups/securebox` | `/var/backups/pgclocktb` | symlink |
| `SECUREBOX_*` env vars | `PGCTB_*` | still accepted |

Symlinks keep existing acme.sh renew hooks, cron entries and armed rollbacks
working. Files that older versions wrote under `/etc` (for example
`sshd_config.d/00-securebox.conf`, `99-securebox-*.conf`, nft table
`securebox`) keep their names on purpose — renaming live SSH/network drop-ins
is not worth the risk, and Undo still finds them.

## Commands

```bash
sudo pgclock                      # interactive menu
sudo pgclock status               # status report + verify
sudo pgclock optimize low --yes   # 🟢 Safe level   (no prompts)
sudo pgclock optimize mid         # 🟡 Balanced level (asks each network change)
sudo pgclock ssl status|renew|repair
sudo pgclock proxy status
sudo pgclock --help               # all flags (legacy --one-click etc.)
```

## Menu

1. **Status & Verify**
2. **SSL Certificates** — PasarGuard Panel/Node issue + auto-renew (acme.sh)
3. **Reverse Proxy** — HAProxy single-port (panel/node)
4. **Optimization** 🟢 / 🟡 — levels + individual items
5. **Security** 🔴 SSH · UFW · abuse block, 🟡 Fail2Ban — one at a time
6. **Backup & Restore** — PGClockBackup / PGClockMG
7. **Tools** — Undo PGClockTB changes, full custom wizard

## Risk levels

| Level | Items | Notes |
|---|---|---|
| 🟢 **Safe** (low) | update (`apt-get upgrade`, Docker held), time sync, BBR, rotated/journal log cleanup, unattended security upgrades (no auto-reboot) | no connectivity risk |
| 🟡 **Balanced** (mid) | Safe + Fail2Ban; DNS, MTU, IPv6, unused services asked one by one | network items keep current without a TTY |
| 🔴 **High** | SSH port/hardening, UFW, abuse IP block | never in a level; Security menu only, warning screen + typed `YES` |

Docker is held during upgrades by default: upgrading it restarts every
container (PasarGuard panel/node → users disconnected).

Every change goes through the safety core (lock, admin-IP guard,
verify-or-revert, timed rollback) — see [docs/OPS.md](docs/OPS.md#safety-core).

SSL details:

- Auto-detect Panel vs Node paths; multi-domain SAN
- Preflight: DNS hint + port 80 check
- Deploys to `/var/lib/pasarguard/certs/` and/or `/var/lib/pg-node/certs/`
- Auto-writes Panel/Node `.env` certificate paths (and restarts compose)
- Auto-renew via acme.sh cron + deploy hook (Repair menu if cron missing)

Reverse proxy / backup: see [docs/OPS.md](docs/OPS.md).

Rule #1: never lock out the admin or cut connectivity.

## Safety notes

- After changing the SSH port, open a **new** terminal before closing the current session.
- Automatic never enables abuse block or UFW without asking; keeps DNS/MTU by default.
- Prefer preserving SSH env under sudo (otherwise IPv6/admin-IP detection recover via `/proc`):
  `sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,SSH_TTY pgclock`
- Timed rollback arms only on a TTY (never auto-reverts headless `--one-click`).
- Release integrity is **fail-closed**: missing `SHA256SUMS` aborts unless
  `PGCTB_ALLOW_INSECURE=1`. See [docs/RELEASE.md](docs/RELEASE.md).

## Dev / CI

```bash
shellcheck -x -S warning install.sh lib/*.sh modules/*.sh scripts/*.sh
bats -r tests
./scripts/gen-checksums.sh   # writes dist/ for release upload
```

---

MIT © MrClock
