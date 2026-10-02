#!/bin/bash
cd "$(dirname "$0")" || exit 1
echo "Ingest restore (back to daily driver). You will be asked for your sudo password."
sudo bash ./restore-ingest.sh "$@"
echo
read -r -p "Press Enter to close"
