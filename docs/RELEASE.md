# Release integrity

`SHA256SUMS` inside a git tree or source zip **does not prove authenticity** — an
attacker who swaps the archive can swap the checksums too.

## Required publish steps

For each GitHub Release tag:

1. `./scripts/gen-checksums.sh` (optionally `RELEASE_TAG=0.2.1`)
2. Sign: `cd dist && gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS`
3. Upload as **separate Release assets**:
   - `install.sh`
   - `ToolBox-<tag>.tar.gz`
   - `SHA256SUMS`
   - `SHA256SUMS.asc`

`install.sh` downloads `SHA256SUMS` (+ `.asc`) from
`/releases/download/<tag>/…` **before** trusting the archive.

## Fail-closed policy

- Missing `SHA256SUMS` → **error** (refuses install) unless `SECUREBOX_ALLOW_INSECURE=1`
- Present `SHA256SUMS.asc` → must verify with `gpg` (or allow insecure)
- Optional pin: `SECUREBOX_GPG_FINGERPRINT=<40-char fingerprint>` requires a matching `.asc`

Do **not** commit `SHA256SUMS` into the repository as the trust root.
