#!/usr/bin/env bash
# install-desktop-launcher.sh
# Copies show-deploy.desktop to ~/Desktop with THIS folder's path baked in,
# then marks it trusted so GNOME will launch it.
# Usage: bash install-desktop-launcher.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_SRC="$SCRIPT_DIR/show-deploy.desktop"
DESKTOP_DEST="$HOME/Desktop/show-deploy.desktop"

[ -f "$DESKTOP_SRC" ] || { echo "missing $DESKTOP_SRC"; exit 1; }

echo "Installing launcher on Desktop..."
# The committed .desktop has a placeholder path. Replace it with the folder
# this script actually lives in, so a copy on a USB stick still works.
sed "s|/home/miked/Desktop/show-deploy|$SCRIPT_DIR|g" "$DESKTOP_SRC" > "$DESKTOP_DEST"
chmod +x "$DESKTOP_DEST"

if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DEST" metadata::trusted true
    echo "  marked trusted via gio"
fi

echo "Launcher: $DESKTOP_DEST"
echo "Double-click Show Deploy Setup (needs your sudo password)."
