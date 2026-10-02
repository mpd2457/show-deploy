#!/bin/bash
# restore-ingest.sh — undo setup-ingest.sh, put mkultra back to daily driver.
#   sudo bash ./restore-ingest.sh            keep ~/Desktop/Ingest and ~/Desktop/Archive
#   sudo bash ./restore-ingest.sh --purge    also delete those two folders (show files gone)
# Wi-Fi is never touched. Packages (smbclient etc.) are left installed - harmless.
set -euo pipefail
if [ "$EUID" -ne 0 ]; then echo "Please run with sudo: sudo bash ./restore-ingest.sh"; exit 1; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
    echo "Run via sudo from your normal login, not a root shell."; exit 1
fi
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
DROP_DIR="$USER_HOME/Desktop/Ingest"
ARCHIVE_DIR="$USER_HOME/Desktop/Archive"
CONF_DIR="$USER_HOME/.config/showkit"
WATCHER="$USER_HOME/.local/bin/show-watcher.py"
UNIT_DIR="$USER_HOME/.config/systemd/user"
SERVICE="showwatcher"
UID_="$(id -u "$SUDO_USER")"
asuser() { sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" "$@"; }
echo "=== Ingest restore starting (user: $SUDO_USER) ==="

# 1. Watcher service
if [ -f "$UNIT_DIR/$SERVICE.service" ]; then
    asuser systemctl --user disable --now "$SERVICE.service" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SERVICE.service"
    asuser systemctl --user daemon-reload 2>/dev/null || true
    asuser systemctl --user reset-failed 2>/dev/null || true
    echo "Removed $SERVICE service"
else
    echo "$SERVICE service not present"
fi
rm -f "$WATCHER" && echo "Removed watcher script"
# linger is left as-is: other user services on this box depend on it.

# 2. Credentials and the push queue (queue.json lives in the same folder)
if [ -d "$CONF_DIR" ]; then rm -rf "$CONF_DIR"; echo "Removed SMB credentials and push queue ($CONF_DIR)"; fi

# 3. Wired static IP -> back to normal DHCP
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
    if nmcli -t -f NAME connection show | grep -qx SHOWNET; then
        nmcli connection down SHOWNET >/dev/null 2>&1 || true
        nmcli connection delete SHOWNET >/dev/null
        echo "Deleted SHOWNET profile"
    else
        echo "SHOWNET profile not present"
    fi
    # bring the everyday wired profile back if a cable is plugged in
    WIRED_DEV=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2=="ethernet" && $3!="unavailable"{print $1; exit}')
    if [ -n "${WIRED_DEV:-}" ]; then
        nmcli device connect "$WIRED_DEV" >/dev/null 2>&1 && echo "Wired port $WIRED_DEV back on DHCP" || echo "(wired port $WIRED_DEV: no profile auto-connected - it will DHCP when plugged into a normal network)"
    fi
fi
if [ -f /etc/netplan/99-showstatic.yaml ]; then
    rm -f /etc/netplan/99-showstatic.yaml
    netplan apply || true
    echo "Removed netplan static IP"
fi

# 4. /etc/hosts
if grep -q '# BEGIN SHOWNET' /etc/hosts; then
    sed -i '/# BEGIN SHOWNET/,/# END SHOWNET/d' /etc/hosts
    # drop the blank line setup added before the block if it left a double blank at the end
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts
    echo "Removed SHOWNET entries from /etc/hosts"
else
    echo "/etc/hosts already clean"
fi

# 5. Show folders
if [ "$PURGE" -eq 1 ]; then
    rm -rf "$DROP_DIR" "$ARCHIVE_DIR"
    echo "Deleted $DROP_DIR and $ARCHIVE_DIR"
else
    for d in "$DROP_DIR" "$ARCHIVE_DIR"; do
        [ -d "$d" ] && echo "Kept $d ($(find "$d" -type f | wc -l) files) - rerun with --purge to delete"
    done
    echo "Read the push log before you delete it: $DROP_DIR/push_log.txt"
fi

echo "=== Restore complete - mkultra is back to daily driver. No reboot needed. ==="
