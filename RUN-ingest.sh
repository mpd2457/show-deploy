#!/bin/bash
cd "$(dirname "$0")" || exit 1
echo "Ingest setup. You will be asked for your sudo password."
sudo bash ./setup-ingest.sh "$@"
echo
read -r -p "Press Enter to close"
