# Ops guide — SSL, Reverse Proxy, Backup

Short English reference for the categorized ToolBox menus.

## Recommended order

1. **SSL Certificates → Issue / Setup** (domains only)
2. **Reverse Proxy → Setup HAProxy** (panel or node mode)
3. Set panel `.env` as printed (local HTTP behind the proxy)
4. **Backup** / **Restore & Migrate** when you need PGClockMG

Do **not** use Caddy auto-HTTPS and ToolBox SSL Issue on the same domain.

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

Panel `.env` example (direct TLS, no reverse proxy):

```text
UVICORN_SSL_CERTFILE = "/var/lib/pasarguard/certs/example.com.cer"
UVICORN_SSL_KEYFILE  = "/var/lib/pasarguard/certs/example.com.cer.key"
UVICORN_PORT = 443
```

Behind HAProxy/Nginx (recommended): remove `UVICORN_SSL_*` and listen on `127.0.0.1:8000`.

## Reverse Proxy

- **HAProxy panel** — HTTPS single-port, Host ACL, optional extra ports
- **HAProxy node** — TCP/SNI + REALITY `send-proxy`
- **Caddy** — automatic HTTPS (own ACME)
- **Nginx** — uses ToolBox/PasarGuard cert files
- Status / Remove — stop services and restore prior configs when backed up

## Backup / Restore & Migrate

Bridges to [PGClockMG](https://github.com/Mrclocks/PGClockMG) with ToolBox UI:

| Menu | Upstream |
|------|----------|
| Backup | PGClockBackup (`/opt/pg-backup`, port 7001) |
| Restore & Migrate | Wizard (`/opt/pg-migrator`, port 7000) |

Install downloads the upstream `install.sh` and runs
`PG_MIGRATOR_ACTION=install-backup|install-wizard` with your chosen port.
