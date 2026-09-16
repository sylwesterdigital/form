#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT_DIR="$ROOT/release"
OUT="$OUT_DIR/form-v$VERSION.zip"
TMP="$(mktemp -d /tmp/form-package.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT_DIR" "$TMP/form"

"$ROOT/scripts/verify_package.sh"

rsync --archive --delete \
  --exclude='.git/' \
  --exclude='.venv/' \
  --exclude='.env' \
  --exclude='.env.*' \
  --exclude='archive/' \
  --exclude='data/' \
  --exclude='logs/' \
  --exclude='release/' \
  --exclude='.watch-state/' \
  --exclude='.deploy-backups/' \
  --exclude='.playwright-browsers/' \
  --exclude='__pycache__/' \
  --exclude='.pytest_cache/' \
  "$ROOT/" "$TMP/form/"

rm -f "$OUT"
(cd "$TMP" && zip -qr "$OUT" form)
sha256sum "$OUT" | tee "$OUT.sha256"
echo "$OUT"
