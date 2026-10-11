#!/usr/bin/env bash
# Generate SHA256SUMS for release artifacts (run from repo root before tagging)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FILES=(install.sh VERSION LICENSE README.md)
# Include shell trees
while IFS= read -r f; do
  FILES+=("$f")
done < <(find lib modules data -type f | sort)

{
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    sha256sum "$f"
  done
} >SHA256SUMS

echo "Wrote ${ROOT}/SHA256SUMS"
if command -v gpg >/dev/null 2>&1; then
  echo "Optional: gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS"
fi
