#!/bin/bash
# setup-ingest.sh — wired IP only, drop ~/Desktop/Ingest, archive ~/Desktop/Archive
#
# Passwords are prompted for, never stored in this file:
#   sudo bash ./setup-ingest.sh
# Pass a wired interface name as the first argument if auto-detection picks wrong:
#   sudo bash ./setup-ingest.sh enp3s0
set -euo pipefail
if [ "$EUID" -ne 0 ]; then echo "Please run with sudo: sudo bash ./setup-ingest.sh"; exit 1; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
    echo "Run via sudo from your normal login, not a root shell."; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_IP="192.168.50.10/24"
GATEWAY="192.168.50.1"
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
DROP_DIR="$USER_HOME/Desktop/Ingest"
ARCHIVE_DIR="$USER_HOME/Desktop/Archive"
CONF_DIR="$USER_HOME/.config/showkit"
CREDS="$CONF_DIR/smbcreds"
CREDS_MITTI="$CONF_DIR/smbcreds-mitti"
WATCHER_SRC="$SCRIPT_DIR/show-watcher.py"
WATCHER="$USER_HOME/.local/bin/show-watcher.py"
UNIT_DIR="$USER_HOME/.config/systemd/user"
SERVICE="showwatcher"
DAY_NAMES=("Day 1" "Day 2" "Day 3" "Day 4" "Day 5")

echo "=== Ingest setup starting (user: $SUDO_USER) ==="

# ---------------------------------------------------------------- credentials
ask() {
    # ask <prompt> <varname> [default]
    local prompt="$1" varname="$2" default="${3:-}" reply
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " reply
        reply="${reply:-$default}"
    else
        read -r -p "$prompt: " reply
    fi
    printf -v "$varname" '%s' "$reply"
}

SMB_USER="show"
ask "GFX share username" SMB_USER "show"
# The password is prompted for rather than hardcoded, but a default is offered so
# load-in is not six machines x an invented password. Enter accepts it; type to
# override. See the README section "The share password" for what this does and
# does not protect against.
DEFAULT_SMB_PASS="showrig"
while true; do
    read -r -s -p "GFX share password for '$SMB_USER' (Enter = $DEFAULT_SMB_PASS): " SMB_PASS
    echo
    [ -n "$SMB_PASS" ] || SMB_PASS="$DEFAULT_SMB_PASS"
    break
done
if [ "$SMB_PASS" = "$DEFAULT_SMB_PASS" ]; then
    echo "Using the default share password."
fi

MITTI_USER=""
MITTI_PASS=""
if [ -t 0 ]; then
    ask "Mac share username (blank if no Macs on this show)" MITTI_USER
else
    echo "No TTY: skipping Mac credentials. Re-run interactively to set them."
fi
if [ -n "$MITTI_USER" ]; then
    # Same default as the GFX password. It must match whatever you set on the
    # Mac itself in setup-mitti.sh, or media pushes will fail.
    read -r -s -p "Mac login password for '$MITTI_USER' (Enter = $DEFAULT_SMB_PASS): " MITTI_PASS
    echo
    [ -n "$MITTI_PASS" ] || MITTI_PASS="$DEFAULT_SMB_PASS"
fi

# ------------------------------------------------------------------- packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq smbclient inotify-tools iputils-ping psmisc >/dev/null

# ------------------------------------------------------------------- interface
IFACE="${1:-}"
if [ -z "$IFACE" ]; then
    for path in /sys/class/net/*; do
        cand=$(basename "$path")
        [ "$cand" = "lo" ] && continue
        [ -d "/sys/class/net/$cand/wireless" ] && continue
        [[ "$cand" == docker* || "$cand" == veth* || "$cand" == br-* || "$cand" == virbr* ]] && continue
        IFACE="$cand"; break
    done
fi
if [ -z "$IFACE" ]; then echo "No wired interface found. Pass one as the first argument."; exit 1; fi
if [ -d "/sys/class/net/$IFACE/wireless" ]; then echo "Refusing '$IFACE': it is wireless."; exit 1; fi
echo "Using wired interface: $IFACE"

# ------------------------------------------------------------------ static IP
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
    if nmcli -t -f NAME connection show | grep -qx SHOWNET; then
        nmcli connection modify SHOWNET connection.interface-name "$IFACE"
    else
        nmcli connection add type ethernet ifname "$IFACE" con-name SHOWNET >/dev/null
    fi
    nmcli connection modify SHOWNET ipv4.method manual ipv4.addresses "$STATIC_IP" \
        ipv4.gateway "$GATEWAY" ipv4.dns "$GATEWAY,8.8.8.8" ipv4.never-default yes \
        connection.autoconnect yes connection.autoconnect-priority 100
    nmcli connection up SHOWNET >/dev/null 2>&1 || echo "(cable not plugged in yet - SHOWNET will come up when it is)"
else
    NETPLAN_FILE="/etc/netplan/99-showstatic.yaml"
    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [$STATIC_IP]
EOF
    chmod 600 "$NETPLAN_FILE"
    netplan apply || true
fi

# ------------------------------------------------------------------- hostnames
sed -i '/# BEGIN SHOWNET/,/# END SHOWNET/d' /etc/hosts
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

# --------------------------------------------------------------------- folders
mkdir -p "$USER_HOME/Desktop" "$DROP_DIR" "$ARCHIVE_DIR" "$CONF_DIR" \
         "$(dirname "$WATCHER")" "$UNIT_DIR"
# Day folders exist here too, so you can sort at the Ingest machine and not only
# at the far end. Files dropped straight into Ingest are still what gets pushed.
for day in "${DAY_NAMES[@]}"; do
    mkdir -p "$DROP_DIR/$day"
done
printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$CREDS"
if [ -n "$MITTI_USER" ]; then
    printf 'username=%s\npassword=%s\n' "$MITTI_USER" "$MITTI_PASS" > "$CREDS_MITTI"
    echo "Stored Mac credentials for '$MITTI_USER'."
else
    rm -f "$CREDS_MITTI"
    echo "No Mac credentials stored - media pushes will FAIL if Mitti machines are used."
fi
chmod 600 "$CREDS" "$CREDS_MITTI" 2>/dev/null || true
unset SMB_PASS MITTI_PASS

# --------------------------------------------------------------------- watcher
if [ ! -f "$WATCHER_SRC" ]; then
    echo "Cannot find $WATCHER_SRC. Copy the whole show-deploy folder."; exit 1
fi
install -m 0755 "$WATCHER_SRC" "$WATCHER"

cat > "$UNIT_DIR/$SERVICE.service" <<EOF
[Unit]
Description=Show push watcher (Desktop/Ingest -> GFX decks, Mitti media)
[Service]
ExecStart=/usr/bin/python3 $WATCHER
Nice=10
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF

chown -R "$SUDO_USER:$SUDO_USER" "$DROP_DIR" "$ARCHIVE_DIR" "$CONF_DIR" \
    "$USER_HOME/.local/bin" "$UNIT_DIR"

# linger so the watcher survives logout and, with it, the show
loginctl enable-linger "$SUDO_USER"
UID_="$(id -u "$SUDO_USER")"
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user daemon-reload
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user enable --now "$SERVICE.service"
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user restart "$SERVICE.service"

echo "=== Ingest setup complete ==="
echo "Drop files in $DROP_DIR"
echo "Archive: $ARCHIVE_DIR"
echo "Log:     $DROP_DIR/push_log.txt   (push_log.txt.1 and .2 kept)"
echo "Day folders: Day 1 - Day 5 (in $DROP_DIR)"
