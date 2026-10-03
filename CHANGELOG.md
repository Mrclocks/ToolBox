# Changelog

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
