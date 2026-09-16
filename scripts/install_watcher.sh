#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${FORM_DEST_DIR:-/var/www/mojoworks/labs/form}"

[[ "$(id -u)" == 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }
[[ "$ROOT" == "$DEST" ]] || echo "Installing watcher service for destination: $DEST"

mkdir -p "$DEST/archive" "$DEST/.watch-state" "$DEST/.deploy-backups"
install -m 0644 "$ROOT/systemd/form-watch.service" /etc/systemd/system/form-watch.service
systemctl daemon-reload
systemctl enable --now form-watch.service
systemctl --no-pager --full status form-watch.service || true

echo "Watcher installed. Drop form-v*.zip into $DEST/archive/"
