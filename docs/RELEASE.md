# Release integrity

`SHA256SUMS` inside a git tree or source zip **does not prove authenticity** — an
attacker who swaps the archive can swap the checksums too.

## Required publish steps

For each GitHub Release tag:

1. `./scripts/gen-checksums.sh` (optionally `RELEASE_TAG=v0.2.0`)
2. Sign: `cd dist && gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS`
3. Upload as **separate Release assets**:
   - `install.sh`
   - `ToolBox-<tag>.tar.gz`
   - `SHA256SUMS`
   - `SHA256SUMS.asc`

`install.sh` downloads `SHA256SUMS` (+ `.asc`) from
`/releases/download/<tag>/…` **before** trusting the archive, verifies the
signature when gpg is available, then checks the archive hash.

Do **not** commit `SHA256SUMS` into the repository as the trust root.
