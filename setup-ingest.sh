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
DASHBOARD_SRC="$SCRIPT_DIR/show-dashboard.py"
DASHBOARD="$USER_HOME/.local/bin/show-dashboard.py"
UNIT_DIR="$USER_HOME/.config/systemd/user"
SERVICE="showwatcher"
DASHBOARD_SERVICE="showdashboard"
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
apt-get install -y -qq smbclient inotify-tools iputils-ping psmisc curl >/dev/null
# Install rclone if not present
if ! command -v rclone >/dev/null 2>&1; then
    curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 || true
fi

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
if [ ! -f "$DASHBOARD_SRC" ]; then
    echo "Cannot find $DASHBOARD_SRC. Copy the whole show-deploy folder."; exit 1
fi
install -m 0755 "$WATCHER_SRC" "$WATCHER"

# --------------------------------------------------------------------- watcher service
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

# --------------------------------------------------------------------- dashboard service
install -m 0755 "$DASHBOARD_SRC" "$DASHBOARD"

cat > "$UNIT_DIR/$DASHBOARD_SERVICE.service" <<EOF
[Unit]
Description=Show Deploy Dashboard (http://localhost:8080)
After=network.target $SERVICE.service
[Service]
ExecStart=/usr/bin/python3 $DASHBOARD
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
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user enable --now "$DASHBOARD_SERVICE.service"
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user restart "$DASHBOARD_SERVICE.service"
echo "Dashboard running at http://localhost:8080"


# --------------------------------------------------------------------- cloud sync (rclone)
CLOUD_DROP_DIR="$USER_HOME/Desktop/Ingest-cloud"
mkdir -p "$CLOUD_DROP_DIR" "$CONF_DIR"

echo
echo "=== Cloud inbox sync (OneDrive/Google Drive) ==="
echo "This sets up optional cloud sync. Files pulled to $CLOUD_DROP_DIR appear there for inspection; move them to $DROP_DIR to push."
if [ -t 0 ]; then
    read -r -p "Configure cloud sync now? [y/N]: " CONFIG_CLOUD
else
    CONFIG_CLOUD="n"
fi
CONFIG_CLOUD=$(echo "$CONFIG_CLOUD" | tr '[:upper:]' '[:lower:]')

if [ "$CONFIG_CLOUD" = "y" ] || [ "$CONFIG_CLOUD" = "yes" ]; then
    if ! command -v rclone >/dev/null 2>&1; then
        echo "rclone not found; attempting install..."
        curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 || true
    fi
    if command -v rclone >/dev/null 2>&1; then
        RCLONE_CONF_PATH="$CONF_DIR/rclone.conf"
        export RCLONE_CONFIG="$RCLONE_CONF_PATH"
        if [ ! -f "$RCLONE_CONF_PATH" ]; then
            touch "$RCLONE_CONF_PATH"
            chmod 600 "$RCLONE_CONF_PATH"
        fi
        echo "Configure remotes (e.g., od-producer, gd-producer). Type 'done' when finished."
        while true; do
            read -r -p "Add remote? [name or done]: " REMOTE_NAME
            if [ -z "$REMOTE_NAME" ]; then
                continue
            fi
            rnl=$(echo "$REMOTE_NAME" | tr '[:upper:]' '[:lower:]')
            if [ "$rnl" = "done" ]; then
                break
            fi
            sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" rclone config create "$REMOTE_NAME" auto config_is_local false 2>&1 || true
        done
        CLOUD_SYNC_SCRIPT="$USER_HOME/.local/bin/show-cloudsync.sh"
        cat > "$CLOUD_SYNC_SCRIPT" <<'EOS'
#!/bin/bash
set -euo pipefail
USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6 2>/dev/null || echo "$HOME")"
CONF_DIR="$USER_HOME/.config/showkit"
RCLONE_CONF="$CONF_DIR/rclone.conf"
CLOUD_DROP="$USER_HOME/Desktop/Ingest-cloud"
export RCLONE_CONFIG="$RCLONE_CONF"
mkdir -p "$CLOUD_DROP"
if [ -f "$RCLONE_CONF" ]; then
  remotes=$(rclone listremotes 2>/dev/null | tr '\n' ' ')
  for r in $remotes; do
    rname=${r%:}
    # copy, not sync: sync deletes anything at the destination that the source
    # does not have, so with two remotes each pass would wipe the other's files.
    # copy overwrites a file whose size or mtime changed, so a re-uploaded deck
    # does update the local copy.
    rclone copy "${rname}:ShowInbox" "$CLOUD_DROP" 2>/dev/null || \
    rclone copy "${rname}:" "$CLOUD_DROP" --include "ShowInbox/**" 2>/dev/null || true
  done
fi
EOS
        chmod +x "$CLOUD_SYNC_SCRIPT"
        chown "$SUDO_USER:$SUDO_USER" "$CLOUD_SYNC_SCRIPT" "$CLOUD_DROP" "$RCLONE_CONF_PATH" 2>/dev/null || true
        cat > "$UNIT_DIR/showcloudsync.service" <<EOF
[Unit]
Description=Cloud inbox sync (rclone pull to Desktop/Ingest-cloud)
[Service]
Type=oneshot
ExecStart=/bin/bash $CLOUD_SYNC_SCRIPT
EOF
        cat > "$UNIT_DIR/showcloudsync.timer" <<EOF
[Unit]
Description=Run cloud sync every 30 seconds
[Timer]
OnBootSec=30
OnUnitActiveSec=30
Persistent=true
[Install]
WantedBy=timers.target
EOF
        chown "$SUDO_USER:$SUDO_USER" "$UNIT_DIR/showcloudsync.service" "$UNIT_DIR/showcloudsync.timer" 2>/dev/null || true
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user daemon-reload
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$UID_" systemctl --user enable --now showcloudsync.timer
        echo "Cloud sync configured (timer every 30s)."
    else
        echo "rclone install failed; skipping cloud sync."
    fi
else
    echo "Skipping cloud sync."
fi
echo "=== Ingest setup complete ==="
echo "Drop files in $DROP_DIR"
echo "Archive: $ARCHIVE_DIR"
echo "Log:     $DROP_DIR/push_log.txt   (push_log.txt.1 and .2 kept)"
echo "Day folders: Day 1 - Day 5 (in $DROP_DIR)"
