#!/usr/bin/env bash
# install-desktop-launcher.sh
# Copies show-deploy.desktop to ~/Desktop and marks it trusted.
# Usage: bash install-desktop-launcher.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_SRC="$SCRIPT_DIR/show-deploy.desktop"
DESKTOP_DEST="$HOME/Desktop/show-deploy.desktop"

# ── 1. Copy the launcher ──────────────────────────────────────────────────────
echo "Copying launcher to Desktop..."
cp "$DESKTOP_SRC" "$DESKTOP_DEST"

# ── 2. Make it executable ─────────────────────────────────────────────────────
chmod +x "$DESKTOP_DEST"
echo "  chmod +x done."

# ── 3. Mark as trusted (GNOME / Nautilus) ─────────────────────────────────────
if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DEST" metadata::trusted true
    echo "  Marked trusted via gio."
else
    echo "  (gio not found — skipping trusted flag; right-click → Allow Launching if needed)"
fi

# ── 4. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "Launcher installed on Desktop — double-click Show Deploy Setup to run"
