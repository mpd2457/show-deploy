#!/bin/bash
# restore-mitti.sh — undo setup-mitti.sh, put the Mac back to how it was.
#   sudo ./restore-mitti.sh            keep ~/Desktop/Ingest (show files survive)
#   sudo ./restore-mitti.sh --purge    also delete ~/Desktop/Ingest
# Reads /Library/Preferences/showkit/restore.env, written by setup-mitti.sh, so
# the wired port goes back to the exact addressing it had (DHCP or manual), the
# machine gets its old name back, the `show` account is removed only if setup
# created it, and File Sharing is switched off only if it was off before.
# Wi-Fi is never touched.
set -uo pipefail
if [ "$EUID" -ne 0 ]; then echo "Please run with sudo: sudo ./restore-mitti.sh"; exit 1; fi
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
RESTORE_DIR="/Library/Preferences/showkit"
RESTORE_ENV="$RESTORE_DIR/restore.env"
PLIST_PATH="/Library/LaunchDaemons/com.showkit.watcher.plist"
WATCHER_SCRIPT="/usr/local/bin/show-watcher-mac.sh"

# sensible fallbacks if restore.env is missing (setup never finished, or an
# older kit set this Mac up)
NET_SERVICE=""; PREV_MODE="dhcp"; PREV_IP=""; PREV_MASK=""; PREV_ROUTER=""; PREV_DNS=""
PREV_COMPUTERNAME=""; PREV_HOSTNAME=""; PREV_LOCALHOSTNAME=""
PREV_SMBD="off"; PREV_SHARE_USER="created"; SHARE_USER="show"
CONSOLE_USER="${SUDO_USER:-}"
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then CONSOLE_USER=$(stat -f %Su /dev/console); fi
HOME_DIR=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
INGEST_DIR="${HOME_DIR:-/Users/$CONSOLE_USER}/Desktop/Ingest"
if [ -f "$RESTORE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$RESTORE_ENV"
    echo "=== Mac restore starting (from $RESTORE_ENV) ==="
else
    echo "=== Mac restore starting (no restore.env - using defaults: DHCP, remove '$SHARE_USER', SMB off) ==="
fi
HOME_DIR=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
HOME_DIR="${HOME_DIR:-/Users/$CONSOLE_USER}"
LOG_FILE="$HOME_DIR/Library/Logs/showkit-arrival.log"
STATE_FILE="$HOME_DIR/Library/Logs/showkit-arrival.seen"

# 1. watcher
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH" "$WATCHER_SCRIPT" /usr/local/bin/show-watcher.sh
echo "Removed the arrival watcher"

# 2. share + File Sharing
sharing -r ShowShare 2>/dev/null || true
echo "Removed ShowShare"
if [ "$PREV_SMBD" = "off" ]; then
    launchctl bootout system/com.apple.smbd 2>/dev/null || true
    launchctl disable system/com.apple.smbd 2>/dev/null || true
    defaults delete /Library/Preferences/SystemConfiguration/com.apple.smb.server EnabledServices 2>/dev/null || true
    echo "File Sharing switched off (it was off before setup)"
else
    launchctl kickstart -k system/com.apple.smbd 2>/dev/null || true
    echo "File Sharing left on (it was on before setup)"
fi
defaults delete /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName 2>/dev/null || true

# 3. share account
if [ "$PREV_SHARE_USER" = "created" ]; then
    if dscl . -read "/Users/$SHARE_USER" >/dev/null 2>&1; then
        sysadminctl -deleteUser "$SHARE_USER" >/dev/null 2>&1 || dscl . -delete "/Users/$SHARE_USER" 2>/dev/null || true
        echo "Deleted local account '$SHARE_USER'"
    fi
else
    echo "Local account '$SHARE_USER' existed before setup - left in place"
fi
if [ -d "$INGEST_DIR" ]; then
    chmod -R -a# 0 "$INGEST_DIR" 2>/dev/null || true
    # drop the traverse ACLs setup added to the parent folders (Desktop, home)
    d="$(dirname "$INGEST_DIR")"
    while [ "$d" != "/" ] && [ "$d" != "/Users" ]; do
        chmod -a "$SHARE_USER allow search,readattr" "$d" 2>/dev/null || true
        d="$(dirname "$d")"
    done
fi

# 4. names
if [ -n "$PREV_COMPUTERNAME" ]; then scutil --set ComputerName "$PREV_COMPUTERNAME"; fi
if [ -n "$PREV_LOCALHOSTNAME" ]; then scutil --set LocalHostName "$PREV_LOCALHOSTNAME"; fi
if [ -n "$PREV_HOSTNAME" ]; then
    scutil --set HostName "$PREV_HOSTNAME"
else
    # HostName was unset before: clear it so macOS derives it again
    scutil --set HostName "" 2>/dev/null || true
fi
echo "Machine name restored to '${PREV_COMPUTERNAME:-(unchanged)}'"

# 5. wired port back to what it was
if [ -n "$NET_SERVICE" ]; then
    if [ "$PREV_MODE" = "manual" ] && [ -n "$PREV_IP" ]; then
        networksetup -setmanual "$NET_SERVICE" "$PREV_IP" "${PREV_MASK:-255.255.255.0}" "${PREV_ROUTER:-}" 2>/dev/null || true
        echo "'$NET_SERVICE' back to manual $PREV_IP"
    else
        networksetup -setdhcp "$NET_SERVICE"
        echo "'$NET_SERVICE' back to DHCP"
    fi
    if [ -n "$PREV_DNS" ]; then
        # shellcheck disable=SC2086
        networksetup -setdnsservers "$NET_SERVICE" $PREV_DNS
    else
        networksetup -setdnsservers "$NET_SERVICE" empty
    fi
else
    echo "No wired service recorded - network left alone. Check System Settings > Network if it is still on 192.168.50.x."
fi

# 6. /etc/hosts
if grep -q '# BEGIN SHOWNET' /etc/hosts; then
    sed -i '' '/# BEGIN SHOWNET/,/# END SHOWNET/d' /etc/hosts
    dscacheutil -flushcache 2>/dev/null || true
    echo "Removed SHOWNET entries from /etc/hosts"
fi

# 7. logs, state, folders
rm -f "$STATE_FILE" "$LOG_FILE.error"
if [ "$PURGE" -eq 1 ]; then
    rm -rf "$INGEST_DIR"
    rm -f "$LOG_FILE" "$LOG_FILE.1"
    echo "Deleted $INGEST_DIR and the arrival log"
else
    [ -d "$INGEST_DIR" ] && echo "Kept $INGEST_DIR ($(find "$INGEST_DIR" -type f | wc -l | tr -d ' ') files) - rerun with --purge to delete"
    echo "Kept the arrival log: $LOG_FILE"
fi
rm -rf "$RESTORE_DIR"

echo "=== Restore complete. Reboot so the old machine name takes effect everywhere. ==="
