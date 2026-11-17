# Release integrity & self-update

`SHA256SUMS` inside a git tree or source zip **does not prove authenticity** — an
attacker who swaps the archive can swap the checksums too. Trust comes from
(1) `SHA256SUMS` published as a **separate release asset** and (2) a signature by
the **release key pinned inside `install.sh`**.

## One-time: create and pin the release key (maintainer)

```bash
gpg --quick-gen-key "PGClockTB release <you@example.com>" ed25519 sign 3y
gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}'   # fingerprint
./scripts/pin-release-key.sh <FINGERPRINT>
git commit -am "chore: pin release signing key"
```

Keep the **private** key offline / backed up; only the public key is embedded.
Until a key is pinned, installs and updates are verified by checksum only and
say so (`PGCTB_REQUIRE_SIGNATURE=1` makes that an error).

## Every release

1. Set `VERSION`, update `CHANGELOG.md`, tag `v<version>`.
2. `./scripts/gen-checksums.sh` (optionally `RELEASE_TAG=v1.0.0`)
   — the tarball **must** contain `PGClockTB-<tag>/lib/...` (not a flat root).
3. Sign: `cd dist && gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS`
4. Upload as **separate Release assets**:
   `install.sh`, `PGClockTB-<tag>.tar.gz`, `SHA256SUMS`, `SHA256SUMS.asc`.

## What the installer and `pgclock update` check

- `SHA256SUMS` missing → **refuse** (unless `PGCTB_ALLOW_INSECURE=1`).
- Archive hash must match its `SHA256SUMS` entry.
- Key pinned → `SHA256SUMS.asc` must exist and be a good signature **by that
  key**, verified in a throwaway GnuPG home (keys in root's keyring are never
  trusted). `PGCTB_GPG_FINGERPRINT=<fpr>` overrides the pinned fingerprint.
- `pgclock update` additionally requires the tree's `VERSION` to match the tag,
  runs `bash -n` on every script, installs atomically (`/opt/pgclocktb.new` →
  swap, old tree kept as `/opt/pgclocktb.prev`), smoke-tests the new version
  and rolls back automatically if it cannot start.
- `pgclock update rollback` restores the previous version at any time.

Do **not** commit `SHA256SUMS` into the repository as the trust root.
