#!/bin/bash
# setup-mitti.sh — wired IP only, Desktop/Ingest + Day 1..Day 5, share ShowShare = that folder
set -euo pipefail
if [ "$EUID" -ne 0 ]; then echo "Please run with sudo: sudo ./setup-mitti.sh MITTIA"; exit 1; fi
if [ $# -lt 1 ]; then echo "Usage: sudo ./setup-mitti.sh <MITTIA|MITTIB> [network-service-name]"; exit 1; fi
MACHINE_NAME="$1"
NET_SERVICE="${2:-}"
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then REAL_USER=$(stat -f %Su /dev/console); fi
HOME_DIR=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
HOME_DIR="${HOME_DIR:-/Users/$REAL_USER}"
case "$MACHINE_NAME" in
    MITTIA) STATIC_IP="192.168.50.15" ;;
    MITTIB) STATIC_IP="192.168.50.16" ;;
    *) echo "First argument must be MITTIA or MITTIB"; exit 1 ;;
esac
GATEWAY="192.168.50.1"
SUBNET_MASK="255.255.255.0"
INGEST_DIR="$HOME_DIR/Desktop/Ingest"
LOG_FILE="$HOME_DIR/Library/Logs/showkit-arrival.log"
PLIST_PATH="/Library/LaunchDaemons/com.showkit.watcher.plist"
WATCHER_SCRIPT="/usr/local/bin/show-watcher-mac.sh"
STATE_FILE="$HOME_DIR/Library/Logs/showkit-arrival.seen"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/show-watcher-mac.sh" ]; then
    echo "Cannot find show-watcher-mac.sh next to this script. Copy the whole show-deploy folder."; exit 1
fi
is_wireless_service() {
    case "$1" in
        *Wi-Fi*|*WiFi*|*Wireless*|*AirPort*|*Bluetooth*|*VPN*|*iPhone*) return 0 ;;
        *) return 1 ;;
    esac
}
echo "=== $MACHINE_NAME setup starting (user: $REAL_USER) ==="
scutil --set ComputerName "$MACHINE_NAME"
scutil --set HostName "$MACHINE_NAME"
scutil --set LocalHostName "$MACHINE_NAME"
defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$MACHINE_NAME"
if [ -z "$NET_SERVICE" ]; then
    while IFS= read -r svc; do
        [[ "$svc" == \** ]] && continue
        is_wireless_service "$svc" && continue
        dev=$(networksetup -listallhardwareports | awk -v s="$svc" '$0=="Hardware Port: "s{getline; print $2}')
        [ -n "$dev" ] && ifconfig "$dev" 2>/dev/null | grep -q 'status: active' && { NET_SERVICE="$svc"; break; }
    done < <(networksetup -listallnetworkservices | tail -n +2)
fi
if [ -z "$NET_SERVICE" ]; then echo "No connected wired network service. Plug in Ethernet."; exit 1; fi
if is_wireless_service "$NET_SERVICE"; then echo "Refusing '$NET_SERVICE': it is wireless."; exit 1; fi
networksetup -setmanual "$NET_SERVICE" "$STATIC_IP" "$SUBNET_MASK" "$GATEWAY"
networksetup -setdnsservers "$NET_SERVICE" "$GATEWAY" "8.8.8.8"
sed -i '' '/# BEGIN SHOWNET/,/# END SHOWNET/d' /etc/hosts
cat >> /etc/hosts <<'EOF'

# BEGIN SHOWNET
192.168.50.10	INGEST
192.168.50.11	GFX1
192.168.50.12	GFX2
192.168.50.13	GFX3
192.168.50.15	MITTIA
192.168.50.16	MITTIB
# END SHOWNET
EOF
dscacheutil -flushcache 2>/dev/null || true
mkdir -p "$INGEST_DIR" "$HOME_DIR/Library/Logs"
for day in "Day 1" "Day 2" "Day 3" "Day 4" "Day 5"; do mkdir -p "$INGEST_DIR/$day"; done
chown -R "$REAL_USER":staff "$INGEST_DIR"
chmod 775 "$INGEST_DIR"

# The share user logs in with this account's own password over SMB. Offer the same
# default the GFX and Ingest scripts use so all six machines take one password:
# Enter accepts it, type to set something else. Changing it means also typing the
# new one into Ingest, or media pushes fail.
DEFAULT_SHARE_PASS="showrig"
if [ -t 0 ]; then
    read -r -s -p "Login password to set for '$REAL_USER' (Enter = $DEFAULT_SHARE_PASS): " NEW_PASS
    echo
    [ -n "$NEW_PASS" ] || NEW_PASS="$DEFAULT_SHARE_PASS"
else
    NEW_PASS="$DEFAULT_SHARE_PASS"
    echo "No TTY: setting the default password. Re-run interactively to change it."
fi
if dscl . -read "/Users/$REAL_USER" NFSHomeDirectory >/dev/null 2>&1 \
   && dscl . -authonly "$REAL_USER" "$NEW_PASS" >/dev/null 2>&1; then
    echo "Password already matches - left as is."
else
    # dscl -passwd can need an admin unlock on some setups; if it cannot, say so
    # plainly rather than leaving Ingest to fail later with an auth error.
    if dscl . -passwd "/Users/$REAL_USER" "$NEW_PASS" >/dev/null 2>&1; then
        echo "Set the login password for '$REAL_USER'."
    else
        echo "WARNING: could not set the password for '$REAL_USER' automatically." >&2
        echo "Set it by hand (System Settings > Users & Groups), then type the same" >&2
        echo "one into Ingest, or media pushes to this Mac will fail." >&2
    fi
fi
unset NEW_PASS
sharing -r ShowShare 2>/dev/null || true
sharing -a "$INGEST_DIR" -S ShowShare -s 001 -g 000 2>/dev/null || true
launchctl enable system/com.apple.smbd 2>/dev/null || true
launchctl kickstart -k system/com.apple.smbd 2>/dev/null || true
# Install the watcher and bake this Mac's paths in as the defaults, so the
# script can be replaced by simply re-running this setup.
install -m 0755 "$SCRIPT_DIR/show-watcher-mac.sh" "$WATCHER_SCRIPT"
/usr/bin/sed -i '' \
    -e "s|^DIR=.*|DIR=\"\${SHOWKIT_DIR:-$INGEST_DIR}\"|" \
    -e "s|^LOG=.*|LOG=\"\${SHOWKIT_LOG:-$LOG_FILE}\"|" \
    -e "s|^STATE=.*|STATE=\"\${SHOWKIT_STATE:-$STATE_FILE}\"|" \
    "$WATCHER_SCRIPT"
chown root:wheel "$WATCHER_SCRIPT"
rm -f /usr/local/bin/show-watcher.sh 2>/dev/null || true
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.showkit.watcher</string>
<key>ProgramArguments</key><array><string>$WATCHER_SCRIPT</string></array>
<key>WatchPaths</key><array><string>$INGEST_DIR</string></array>
<key>ThrottleInterval</key><integer>3</integer>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$LOG_FILE.error</string>
<key>StandardErrorPath</key><string>$LOG_FILE.error</string>
</dict></plist>
EOF
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap system "$PLIST_PATH"
echo "=== $MACHINE_NAME setup complete ==="
echo "Files land in $INGEST_DIR"
echo "Manual: System Settings > Sharing > File Sharing ON."
echo "ShowShare must be $INGEST_DIR, SMB ticked, user ticked."
echo "On Ingest store this Mac login and the password you chose above,"
echo "then click Allow on the Local Network prompt at the first push."
