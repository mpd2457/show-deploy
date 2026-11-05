#!/bin/bash
cd "$(dirname "$0")" || exit 1
chmod +x ./restore-mitti.sh
sudo -S -p '' ./restore-mitti.sh
echo
read -r -p "Press Enter to close"
