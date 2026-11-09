#!/bin/bash
# setup-mitti.sh — wired IP only, Desktop/Ingest + Day 1..Day 5, share ShowShare = that folder
#
# Ingest logs in to this Mac as the SAME account it uses on the GFX machines:
# local user `show`, default password `password`. This script creates that
# account, turns on SMB for it, switches File Sharing on from the command line
# and then proves the share answers before it says "complete". Everything it
# changes is recorded in /Library/Preferences/showkit/restore.env so
# restore-mitti.sh can put the Mac back exactly.
set -euo pipefail
# Never die silently: say which line failed, and keep a log the crew can read back.
trap 'echo; echo "FAILED at line $LINENO: $BASH_COMMAND"; echo "Log: /tmp/showkit-setup.log"' ERR
exec > >(tee -a /tmp/showkit-setup.log) 2>&1
echo "--- $(date) ---"
if [ "$EUID" -ne 0 ]; then echo "Please run with sudo: sudo ./setup-mitti.sh MITTIA"; exit 1; fi
if [ $# -lt 1 ]; then echo "Usage: sudo ./setup-mitti.sh <MITTIA|MITTIB> [network-service-name]"; exit 1; fi
MACHINE_NAME="$1"
NET_SERVICE="${2:-}"
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then REAL_USER=$(stat -f %Su /dev/console); fi
HOME_DIR=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)
HOME_DIR="${HOME_DIR:-/Users/$REAL_USER}"
case "$MACHINE_NAME" in
    MITTIA) STATIC_IP="192.168.50.21" ;;
    MITTIB) STATIC_IP="192.168.50.22" ;;
    *) echo "First argument must be MITTIA or MITTIB"; exit 1 ;;
esac
GATEWAY="192.168.50.1"
SUBNET_MASK="255.255.255.0"
SHARE_USER="show"
DEFAULT_SHARE_PASS="password"
INGEST_DIR="$HOME_DIR/Desktop/Ingest"
LOG_FILE="$HOME_DIR/Library/Logs/showkit-arrival.log"
PLIST_PATH="/Library/LaunchDaemons/com.showkit.watcher.plist"
WATCHER_SCRIPT="/usr/local/bin/show-watcher-mac.sh"
STATE_FILE="$HOME_DIR/Library/Logs/showkit-arrival.seen"
RESTORE_DIR="/Library/Preferences/showkit"
RESTORE_ENV="$RESTORE_DIR/restore.env"
SMBD_PLIST="/System/Library/LaunchDaemons/com.apple.smbd.plist"
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
echo "=== $MACHINE_NAME setup starting (console user: $REAL_USER) ==="
echo "Looking for the wired network port..."

# ------------------------------------------------------------- pick the wired port
if [ -z "$NET_SERVICE" ]; then
    while IFS= read -r svc; do
        [[ "$svc" == \** ]] && continue
        is_wireless_service "$svc" && continue
        dev=$(networksetup -listallhardwareports | awk -v s="$svc" '$0=="Hardware Port: "s{getline; print $2}')
        [ -n "$dev" ] && ifconfig "$dev" 2>/dev/null | grep -q 'status: active' && { NET_SERVICE="$svc"; break; }
    done < <(networksetup -listallnetworkservices | tail -n +2)
fi
if [ -z "$NET_SERVICE" ]; then echo "No connected wired network service. Plug in Ethernet."; exit 1; fi
echo "Wired port: $NET_SERVICE"
if is_wireless_service "$NET_SERVICE"; then echo "Refusing '$NET_SERVICE': it is wireless."; exit 1; fi

# ------------------------------------------------- remember how the Mac was before
# Written once, on the first run. A re-run must not overwrite the real "before"
# state with the show state, or restore would put the show config back.
mkdir -p "$RESTORE_DIR"
if [ ! -f "$RESTORE_ENV" ]; then
    PREV_INFO=$(networksetup -getinfo "$NET_SERVICE" 2>/dev/null || true)
    if echo "$PREV_INFO" | grep -q '^Manual Configuration'; then PREV_MODE="manual"; else PREV_MODE="dhcp"; fi
    PREV_IP=$(echo "$PREV_INFO" | awk -F': ' '/^IP address:/{print $2; exit}')
    PREV_MASK=$(echo "$PREV_INFO" | awk -F': ' '/^Subnet mask:/{print $2; exit}')
    PREV_ROUTER=$(echo "$PREV_INFO" | awk -F': ' '/^Router:/{print $2; exit}')
    # grep -v finds nothing when no DNS is set; with pipefail that must not abort the script
    PREV_DNS=$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | grep -v "aren't" | tr '\n' ' ' | sed 's/ *$//' || true)
    if launchctl print system/com.apple.smbd >/dev/null 2>&1; then PREV_SMBD="on"; else PREV_SMBD="off"; fi
    if dscl . -read "/Users/$SHARE_USER" >/dev/null 2>&1; then PREV_SHARE_USER="existed"; else PREV_SHARE_USER="created"; fi
    cat > "$RESTORE_ENV" <<EOF
# written by setup-mitti.sh - read by restore-mitti.sh. Do not edit.
NET_SERVICE='$NET_SERVICE'
PREV_MODE='$PREV_MODE'
PREV_IP='$PREV_IP'
PREV_MASK='$PREV_MASK'
PREV_ROUTER='$PREV_ROUTER'
PREV_DNS='$PREV_DNS'
PREV_COMPUTERNAME='$(scutil --get ComputerName 2>/dev/null || true)'
PREV_HOSTNAME='$(scutil --get HostName 2>/dev/null || true)'
PREV_LOCALHOSTNAME='$(scutil --get LocalHostName 2>/dev/null || true)'
PREV_SMBD='$PREV_SMBD'
PREV_SHARE_USER='$PREV_SHARE_USER'
SHARE_USER='$SHARE_USER'
CONSOLE_USER='$REAL_USER'
INGEST_DIR='$INGEST_DIR'
EOF
    chmod 600 "$RESTORE_ENV"
    echo "Saved the pre-show state to $RESTORE_ENV"
else
    echo "Pre-show state already saved ($RESTORE_ENV) - keeping it."
fi

# ------------------------------------------------------------------ names + IP
echo "Setting name $MACHINE_NAME and IP $STATIC_IP..."
scutil --set ComputerName "$MACHINE_NAME"
scutil --set HostName "$MACHINE_NAME"
scutil --set LocalHostName "$MACHINE_NAME"
defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$MACHINE_NAME"
networksetup -setmanual "$NET_SERVICE" "$STATIC_IP" "$SUBNET_MASK" "$GATEWAY"
networksetup -setdnsservers "$NET_SERVICE" "$GATEWAY" "8.8.8.8"
echo "Static IP $STATIC_IP on '$NET_SERVICE' (wired only)"
sed -i '' '/# BEGIN SHOWNET/,/# END SHOWNET/d' /etc/hosts
cat >> /etc/hosts <<'EOF'

# BEGIN SHOWNET
192.168.50.10	INGEST
192.168.50.11	GFX1
192.168.50.12	GFX2
192.168.50.13	GFX3
192.168.50.14	GFX4
192.168.50.15	GFX5
192.168.50.16	GFX6
192.168.50.21	MITTIA
192.168.50.22	MITTIB
# END SHOWNET
EOF
dscacheutil -flushcache 2>/dev/null || true

# --------------------------------------------------------------------- folders
mkdir -p "$INGEST_DIR" "$HOME_DIR/Library/Logs"
for day in "Day 1" "Day 2" "Day 3" "Day 4" "Day 5"; do mkdir -p "$INGEST_DIR/$day"; done
chown -R "$REAL_USER":staff "$INGEST_DIR"
chmod 775 "$INGEST_DIR"

# ------------------------------------------------------------- the share account
# Same account name and default password as the GFX machines, so Ingest needs
# one password for the whole rig. Enter accepts the default; type to override
# (then type the same thing into Ingest, or media pushes fail).
if [ -t 0 ]; then
    read -r -s -p "Share password for '$SHARE_USER' (Enter = $DEFAULT_SHARE_PASS): " SHARE_PASS
    echo
    [ -n "$SHARE_PASS" ] || SHARE_PASS="$DEFAULT_SHARE_PASS"
else
    SHARE_PASS="$DEFAULT_SHARE_PASS"
    echo "No TTY: using the default share password."
fi
if dscl . -read "/Users/$SHARE_USER" >/dev/null 2>&1; then
    echo "Local account '$SHARE_USER' already exists - refreshing its password."
else
    # a service account: no real home, no login shell, hidden from the login
    # window. SMB does not need any of those.
    echo "Creating local account '$SHARE_USER'..."
    sysadminctl -addUser "$SHARE_USER" -fullName "Show Share" -password "$SHARE_PASS" \
        -home /var/empty -shell /usr/bin/false </dev/null >/dev/null 2>&1 \
        || dscl . -create "/Users/$SHARE_USER" </dev/null
    dscl . -create "/Users/$SHARE_USER" IsHidden 1 2>/dev/null || true
    echo "Created local account '$SHARE_USER'."
fi
# The "Windows File Sharing" tick in System Settings is these two lines: turn on
# the NT hash, then (re)set the password so the hash is generated. Setting the
# password alone is not enough - that is why the previous kit got the folder
# created but every login from Ingest refused.
echo "Enabling SMB login for '$SHARE_USER'..."
pwpolicy -u "$SHARE_USER" -sethashtypes SMB-NT on </dev/null >/dev/null 2>&1 || true
dscl . -passwd "/Users/$SHARE_USER" "$SHARE_PASS" </dev/null
# if an SMB access list exists, make sure our user is on it
if dscl . -read /Groups/com.apple.access_smb >/dev/null 2>&1; then
    dseditgroup -o edit -a "$SHARE_USER" -t user com.apple.access_smb 2>/dev/null || true
fi
# write access to the drop folder for the share account (console user keeps ownership)
chmod -R +a "$SHARE_USER allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,delete,file_inherit,directory_inherit" "$INGEST_DIR"

# ------------------------------------------------------------------ the share
echo "Sharing $INGEST_DIR as ShowShare..."
sharing -r ShowShare 2>/dev/null || true
sharing -a "$INGEST_DIR" -S ShowShare -s 001 -g 000
# File Sharing ON, SMB only (this is what the System Settings toggle writes)
defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server EnabledServices -array disk
launchctl enable system/com.apple.smbd 2>/dev/null || true
launchctl bootstrap system "$SMBD_PLIST" 2>/dev/null || true
launchctl kickstart -k system/com.apple.smbd 2>/dev/null || true
# the application firewall, if on, must let smbd answer
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
if [ -x "$FW" ] && "$FW" --getglobalstate 2>/dev/null | grep -qi enabled; then
    "$FW" --add /usr/sbin/smbd >/dev/null 2>&1 || true
    "$FW" --unblockapp /usr/sbin/smbd >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ the watcher
echo "Installing the arrival logger..."
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

# ------------------------------------------------------------- prove it works
# Do what Ingest will do: log in to the share over SMB as the share account,
# on this machine. If this fails, say so now rather than at the first push.
echo
echo "--- self-test ---"
sleep 2
OK=1
if lsof -nP -iTCP:445 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "PASS  SMB is listening on port 445"
else
    echo "FAIL  nothing listening on port 445 - File Sharing did not start"; OK=0
fi
if smbutil view "//$SHARE_USER:$SHARE_PASS@127.0.0.1" 2>/dev/null | grep -q ShowShare; then
    echo "PASS  '$SHARE_USER' can log in and sees ShowShare"
else
    echo "FAIL  '$SHARE_USER' could not log in to ShowShare"; OK=0
fi
unset SHARE_PASS
echo
echo "=== $MACHINE_NAME setup complete ==="
echo "IP $STATIC_IP   files land in $INGEST_DIR"
if [ "$OK" -eq 1 ]; then
    echo "Share verified. Reboot now so the new name sticks, then this Mac is ready."
else
    echo "The share did NOT verify. Open System Settings > General > Sharing:"
    echo "  File Sharing ON  >  (i)  >  ShowShare = Desktop/Ingest, SMB ticked,"
    echo "  Windows File Sharing: tick '$SHARE_USER' and type the share password."
    echo "Then reboot and run this again - it is safe to re-run."
fi
echo "On the first push, click Allow if macOS asks about the local network."
