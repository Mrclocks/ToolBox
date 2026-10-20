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

Preflight checks DNS (soft) and that port **80** is free for ACME HTTP-01.

After **Issue / Setup**, ToolBox **automatically** writes paths into:

- Panel: `/opt/pasarguard/.env` → `UVICORN_SSL_CERTFILE`, `UVICORN_SSL_KEYFILE` only
  (`UVICORN_PORT` is never changed; `UVICORN_UDS` is commented for direct TLS)
- Node: `/opt/pg-node/.env` (+ compose `SSL_CERT_FILE` / `SSL_KEY_FILE` when present)

Then it restarts the matching docker compose stack when possible.

Behind HAProxy later: remove `UVICORN_SSL_*` and listen on `127.0.0.1:8000`
(Reverse Proxy setup prints that guide).

Menu item **Show .env / path instructions** can re-apply the same writes.

## Reverse Proxy

HAProxy only — aligned with [PasarGuard single-port](https://docs.pasarguard.org/en/learn/single-port/):

- **Panel mode** — `listen front`, mode http, Host ACL, deny default,
  PEM dir `/etc/haproxy/certs/`, binds 443(+extras) SSL + 80 plain (+ optional 9000 plain).
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

Install downloads the upstream `install.sh` and runs
`PG_MIGRATOR_ACTION=install-backup|install-wizard` with your chosen port.
