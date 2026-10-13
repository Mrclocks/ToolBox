#!/usr/bin/env bash
# Generate SEPARATE release-asset checksums (never ship these only inside the tarball).
# Usage (from a clean release checkout / tag):
#   ./scripts/gen-checksums.sh
# Then upload to the GitHub Release as assets:
#   - install.sh
#   - ToolBox-<tag>.tar.gz
#   - SHA256SUMS
#   - SHA256SUMS.asc   (gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="$(tr -d '[:space:]' <VERSION)"
[[ -n "$TAG" ]] || { echo "VERSION missing"; exit 1; }
# Allow VERSION like 0.2.0 → tag v0.2.0 or 0.2.0
ASSET_TAG="$TAG"
if [[ -n "${RELEASE_TAG:-}" ]]; then
  ASSET_TAG="$RELEASE_TAG"
fi

OUTDIR="${ROOT}/dist"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

cp -a install.sh "${OUTDIR}/install.sh"

ARCHIVE_NAME="ToolBox-${ASSET_TAG}.tar.gz"
# Pack under ToolBox-<tag>/ so install.sh finds a ToolBox-* root after extract.
# Flat tarballs break the one-liner with "archive layout unexpected".
STAGE="${OUTDIR}/stage/ToolBox-${ASSET_TAG}"
mkdir -p "$STAGE"
tar --exclude='./.git' --exclude='./dist' --exclude='./SHA256SUMS' --exclude='./SHA256SUMS.asc' \
  --exclude='./.cursor' \
  -C "$ROOT" -cf - . | tar -C "$STAGE" -xf -
tar -czf "${OUTDIR}/${ARCHIVE_NAME}" -C "${OUTDIR}/stage" "ToolBox-${ASSET_TAG}"
rm -rf "${OUTDIR}/stage"

(
  cd "$OUTDIR"
  sha256sum install.sh "$ARCHIVE_NAME" >SHA256SUMS
  echo "Wrote ${OUTDIR}/SHA256SUMS"
  cat SHA256SUMS
)

# Sanity: archive must contain a complete tree (same bar as _securebox_have_tree)
# (Avoid `tar | grep` under pipefail — SIGPIPE from early grep exit looks like failure.)
listing="$(tar -tzf "${OUTDIR}/${ARCHIVE_NAME}")"
for need in \
  "ToolBox-${ASSET_TAG}/lib/common.sh" \
  "ToolBox-${ASSET_TAG}/data/abuse-ranges.txt" \
  "ToolBox-${ASSET_TAG}/data/abuse-ranges-aggressive.txt"
do
  if ! grep -qx "$need" <<<"$listing"; then
    echo "ERROR: packed archive missing ${need}" >&2
    head -n 20 <<<"$listing" >&2
    exit 1
  fi
done

echo
echo "Publish these as GitHub Release assets (separate from source zip):"
echo "  ${OUTDIR}/install.sh"
echo "  ${OUTDIR}/${ARCHIVE_NAME}"
echo "  ${OUTDIR}/SHA256SUMS"
echo "  ${OUTDIR}/SHA256SUMS.asc   # gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS"
if command -v gpg >/dev/null 2>&1; then
  echo "Optional now: (cd dist && gpg --detach-sign -a -o SHA256SUMS.asc SHA256SUMS)"
fi
