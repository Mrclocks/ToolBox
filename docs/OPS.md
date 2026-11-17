# Ops guide — SSL, Reverse Proxy, Backup

Short English reference for the categorized PGClockTB menus.

## Recommended order

1. **SSL Certificates → Issue / Setup** (domains only)
2. **Reverse Proxy → Setup HAProxy** (panel or node mode)
3. Set panel `.env` as printed (local HTTP behind the proxy)
4. **Backup** / **Restore & Migrate** when you need PGClockMG

## SSL Certificates

| Item | Path |
|------|------|
| Panel cert | `/var/lib/pasarguard/certs/<domain>/fullchain.pem` |
| Panel key | `/var/lib/pasarguard/certs/<domain>/privkey.pem` |
| Node cert | `/var/lib/pg-node/certs/ssl_cert.pem` |
| Node key | `/var/lib/pg-node/certs/ssl_key.pem` |
| Live copy | `/var/lib/pgclocktb/ssl/live/` |
| HAProxy PEM | `/etc/haproxy/certs/<domain>.pem` |

Paths follow the official PasarGuard installer (`/var/lib/pasarguard` is
bind-mounted into the panel container). Files from older ToolBox versions
(`<domain>.cer`) keep being refreshed only if they already exist.

Menu:

1. Issue / Setup — role, domains, method, optional staging test, auto-renew
2. Status — expiry, method, cron, live check, node-certificate alerts
3. Renew now — force renew + redeploy + live check
4. Show `.env` / path instructions
5. Repair auto-renew — reinstall cron + deploy hook
6. Node certificate — show it, mark as pasted, restore the original

**Validation method**

- **HTTP-01** (port 80, standalone) — default.
- **DNS-01 via Cloudflare API** — for domains behind the Cloudflare proxy (orange
  cloud is detected from the A record), when port 80 is closed, and required for
  wildcards (`example.com *.example.com`). The token needs Zone → DNS → Edit and
  Zone → Zone → Read; it is read hidden, checked with Cloudflare's
  `tokens/verify`, and stored by acme.sh (`account.conf`) for renewals.

**Rate limits** — an existing certificate that is valid for 30+ more days and
lists every requested name is reused instead of requesting a new one. An
optional **staging test** runs against the Let's Encrypt test CA in a throwaway
directory first (nothing is installed).

**Node certificates are pinned by the panel.** The node installer creates a
self-signed certificate that you paste into Panel → Nodes. Replacing it (role
Node / Panel + Node) breaks panel↔node until the new one is pasted — and again
after every renewal. So the default role is **Panel only**, node roles need a
typed `YES`, the original node certificate is kept as
`ssl_cert.pem.pre-pgclocktb`, every change raises an alert in Status, and
**Node certificate → Restore** puts the original back and stops node deployment.

**Panel `.env` is applied as a transaction** — PGClockTB checks that the panel
container mounts the certificate path, writes `UVICORN_SSL_CERTFILE`,
`UVICORN_SSL_KEYFILE` and `UVICORN_SSL_CA_TYPE = "public"`, restarts, and then
requires the panel to serve exactly the new certificate (`openssl s_client`
fingerprint). If it does not, the previous `.env` is restored and the panel is
restarted again.

Preflight checks DNS (soft: all A/AAAA answers vs. every local address; behind
NAT it says "cannot verify" instead of warning) and port **80**. If
HAProxy/nginx/caddy hold `:80`, ACME **pre/post hooks** stop them briefly for
HTTP-01 (including cron renew), then restore. If the post-hook cannot restart a
service it retries, logs to syslog (`pgclocktb-acme`), and leaves
`/var/lib/pgclocktb/ssl/acme-post-hook.failed`; Status / Renew report it.

The deploy hook exits non-zero on any failed copy, HAProxy reload or compose
restart, so **Renew now** only reports success when deploy really succeeded.
Restarts are skipped when the certificate did not change since the last deploy.

State files (`ssl/config.env`, `proxy/config.env`) are plain `KEY=value` and are
**parsed, never sourced** — nothing in them is executed.

After **Issue / Setup**, PGClockTB **automatically** writes paths into:

- Panel: `/opt/pasarguard/.env` → `UVICORN_SSL_CERTFILE`, `UVICORN_SSL_KEYFILE`,
  `UVICORN_SSL_CA_TYPE` (`UVICORN_PORT` is never changed; `UVICORN_UDS` is
  commented for direct TLS)
- Node: `/opt/pg-node/.env` (+ compose `SSL_CERT_FILE` / `SSL_KEY_FILE` when present)

Then it restarts the matching docker compose stack when possible.

Behind HAProxy later: remove `UVICORN_SSL_*` and listen on `127.0.0.1:8000`
(Reverse Proxy setup does this automatically). Renew does **not** re-enable
Uvicorn TLS; Show `.env` defaults to skip re-apply and respects HAProxy mode.

Menu item **Show .env / path instructions** can optionally re-apply (keeps
local HTTP when HAProxy panel mode is detected).

## Reverse Proxy

HAProxy only — aligned with [PasarGuard single-port](https://docs.pasarguard.org/en/learn/single-port/):

- **Panel mode** — `listen front`, mode http, Host ACL (`hdr(host),field(1,:)`
  so `Host: domain:8443` still matches), deny default, PEM dir
  `/etc/haproxy/certs/`, binds 443 SSL + 80 plain, plus optional extra SSL /
  plain ports (none by default). Binds are dual-stack when the kernel has IPv6,
  IPv4-only otherwise.
  Every domain (panel + subscription) must have a certificate that really
  covers it (checked with `openssl x509 -checkhost` and key match) or setup stops.
  The config is validated with `haproxy -c` before it is saved; a bad write is
  rolled back to the previous file.
  No forced HTTP→HTTPS redirect (docs keep :80 working).
  After setup, panel `.env` is switched to local HTTP (`UVICORN_HOST`/`PORT`, SSL keys commented).
- **Node mode** — `listen front_node`, TCP/SNI, REALITY `send-proxy`, fallback backend
- **Status / Remove** — stop HAProxy and restore prior config when backed up
- Soft warning if another web server is already active on the host before setup

## Backup / Restore & Migrate

Bridges to [PGClockMG](https://github.com/Mrclocks/PGClockMG) with PGClockTB UI:

| Menu | Upstream |
|------|----------|
| Backup | PGClockBackup (`/opt/pg-backup`, port 7001) |
| Restore & Migrate | Wizard (`/opt/pg-migrator`, port 7000) |

Install downloads a **pinned release** of the upstream `install.sh` (SHA-256
verified) and runs `PG_MIGRATOR_ACTION=install-backup|install-wizard` with your
chosen port. Prefer SSH tunnel / UFW-restrict access; tokens are not put in URLs.

## Safety core

Every change follows **Preflight → Snapshot → Apply → Verify → Rollback**.

- **One run at a time** — `/run/pgclocktb.lock`; a second run exits instead of
  racing `/etc` edits (dry-run is read-only and not locked).
- **Admin IPs are never blocked** — your SSH client IP, other `who --ips`
  sessions and `PGCTB_ADMIN_IPS="1.2.3.4 5.6.7.8"` get an explicit allow rule
  *before* the abuse drop rule. Without a known admin IP the blocklist asks
  (TTY) or refuses (no TTY).
- **Verify with real traffic** — MTU changes are checked with an HTTPS fetch
  (DNS + TCP + TLS, i.e. large packets) before and after; if it worked before
  and fails after, the live MTU, the `.link` file and NetworkManager are
  reverted immediately. DNS already validates with `dig` and restores.
- **IPv6-only hosts** — disabling IPv6 is refused when there is no IPv4 default route.
- **Risk levels** — 🟢 low: update, timesync, BBR, logs, unattended ·
  🟡 mid: DNS, MTU, IPv6, services, Fail2Ban · 🔴 high: SSH, UFW, abuse block.
  Unknown modules count as high.
- **Existing guards kept** — UFW never enables without SSH allow rules; password
  login is never disabled without a usable SSH key; IPv6 disable refuses over an
  IPv6 SSH session; timed rollback for SSH/UFW/DNS/MTU on a TTY.
- **CI** runs `scripts/scenario-smoke.sh` on a real VM (systemd, netfilter):
  real UFW/sshd/nft/MTU changes are applied and reverted.

