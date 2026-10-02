#!/bin/bash
cd "$(dirname "$0")" || exit 1
chmod +x ./setup-mitti.sh
sudo ./setup-mitti.sh MITTIA
echo
read -r -p "Press Enter to close"
