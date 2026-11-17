#!/usr/bin/env bash
# Pin the release signing key into install.sh (maintainer, one time).
# Usage: ./scripts/pin-release-key.sh <FINGERPRINT> [gpg --homedir DIR]
#   Exports the PUBLIC key for FINGERPRINT from your keyring and writes it plus
#   the fingerprint into install.sh (PGCTB_RELEASE_FPR / PGCTB_RELEASE_PUBKEY).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fp="${1:-}"
shift || true
fp="${fp// /}"
fp="${fp^^}"
[[ "$fp" =~ ^[0-9A-F]{40}$ ]] || { echo "usage: $0 <40-hex fingerprint> [gpg options]" >&2; exit 1; }
key="$(gpg "$@" --batch --armor --export "$fp")"
[[ "$key" == *"BEGIN PGP PUBLIC KEY BLOCK"* ]] || { echo "public key ${fp} not found" >&2; exit 1; }
[[ "$key" != *'"'* && "$key" != *'$'* && "$key" != *'`'* ]] || { echo "unexpected characters in key" >&2; exit 1; }
tmp="$(mktemp)"
awk -v fp="$fp" -v key="$key" '
  /^PGCTB_RELEASE_FPR=/ { print "PGCTB_RELEASE_FPR=\"" fp "\""; next }
  /^PGCTB_RELEASE_PUBKEY="/ {
    print "PGCTB_RELEASE_PUBKEY=\"" key "\""
    # skip an already pinned multi-line value up to its closing quote
    if ($0 !~ /^PGCTB_RELEASE_PUBKEY=""$/ && $0 !~ /"$/ ) { skipping = 1 }
    next
  }
  skipping { if ($0 ~ /"$/) skipping = 0; next }
  { print }
' "${ROOT}/install.sh" >"$tmp"
bash -n "$tmp"
cat "$tmp" >"${ROOT}/install.sh"
rm -f "$tmp"
echo "Pinned ${fp} into install.sh — commit it, then sign every release's SHA256SUMS with this key."
