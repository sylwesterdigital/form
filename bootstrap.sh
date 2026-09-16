#!/usr/bin/env bash
set -Eeuo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${FORM_DEST_DIR:-/var/www/mojoworks/labs/form}"
REMOTE="${FORM_GIT_REMOTE:-git@github.com:sylwesterdigital/form.git}"

[[ "$(id -u)" == 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

if ! command -v rsync >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || { echo "rsync/git missing and apt-get unavailable" >&2; exit 1; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y rsync git unzip zip curl ca-certificates
fi

mkdir -p "$(dirname "$DEST")"
if [[ ! -d "$DEST/.git" ]]; then
  # If the destination is empty and SSH access is configured, preserve Git history
  # by cloning the open-source repo before synchronising this package.
  if [[ ! -e "$DEST" || -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    rm -rf "$DEST"
    if git clone "$REMOTE" "$DEST"; then
      echo "Cloned $REMOTE into $DEST"
    else
      echo "WARNING: Git clone failed; deploying without .git. GitHub publishing will be skipped until the checkout is configured." >&2
      mkdir -p "$DEST"
    fi
  else
    echo "WARNING: $DEST is not a Git checkout and is not empty; preserving it. GitHub publishing will be skipped." >&2
  fi
fi

# Preserve deployment/runtime state while installing source from the bootstrap package.
rsync --archive --checksum --delete \
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
  "$SRC/" "$DEST/"

cd "$DEST"
./deploy.sh
./scripts/install_watcher.sh

echo
echo "Bootstrap complete."
echo "Future packages: copy form-v*.zip to $DEST/archive/"
