# Ops guide — SSL, Reverse Proxy, Backup

Short English reference for the categorized ToolBox menus.

## Recommended order

1. **SSL Certificates → Issue / Setup** (domains only)
2. **Reverse Proxy → Setup HAProxy** (panel or node mode)
3. Set panel `.env` as printed (local HTTP behind the proxy)
4. **Backup** / **Restore & Migrate** when you need PGClockMG

## SSL Certificates

| Item | Path |
|------|------|
| Panel cert | `/var/lib/pasarguard/certs/<domain>.cer` |
| Panel key | `/var/lib/pasarguard/certs/<domain>.cer.key` |
| Node cert | `/var/lib/pg-node/certs/ssl_cert.pem` |
| Node key | `/var/lib/pg-node/certs/ssl_key.pem` |
| Live copy | `/var/lib/securebox/ssl/live/` |
| HAProxy PEM | `/etc/haproxy/certs/<domain>.pem` |

Menu:

1. Issue / Setup — ask domains, enable auto-renew
2. Status — expiry + cron check
3. Renew now — force renew + redeploy
4. Show `.env` / path instructions
5. Repair auto-renew — reinstall cron + deploy hook

Preflight checks DNS (soft: all A/AAAA answers vs. every local address; behind
NAT it says "cannot verify" instead of warning) and port **80**. If
HAProxy/nginx/caddy hold `:80`, ACME **pre/post hooks** stop them briefly for
HTTP-01 (including cron renew), then restore. If the post-hook cannot restart a
service it retries, logs to syslog (`mrclock-acme`), and leaves
`/var/lib/securebox/ssl/acme-post-hook.failed`; Status / Renew report it.

The deploy hook exits non-zero on any failed copy, HAProxy reload or compose
restart, so **Renew now** only reports success when deploy really succeeded.
Restarts are skipped when the certificate did not change since the last deploy.

State files (`ssl/config.env`, `proxy/config.env`) are plain `KEY=value` and are
**parsed, never sourced** — nothing in them is executed.

After **Issue / Setup**, ToolBox **automatically** writes paths into:

- Panel: `/opt/pasarguard/.env` → `UVICORN_SSL_CERTFILE`, `UVICORN_SSL_KEYFILE` only
  (`UVICORN_PORT` is never changed; `UVICORN_UDS` is commented for direct TLS)
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

Bridges to [PGClockMG](https://github.com/Mrclocks/PGClockMG) with ToolBox UI:

| Menu | Upstream |
|------|----------|
| Backup | PGClockBackup (`/opt/pg-backup`, port 7001) |
| Restore & Migrate | Wizard (`/opt/pg-migrator`, port 7000) |

Install downloads a **pinned release** of the upstream `install.sh` (SHA-256
verified) and runs `PG_MIGRATOR_ACTION=install-backup|install-wizard` with your
chosen port. Prefer SSH tunnel / UFW-restrict access; tokens are not put in URLs.
