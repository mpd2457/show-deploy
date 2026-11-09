#!/bin/bash
# fix-mitti-share.command - run on a Mac that already ran setup-mitti.sh but
# where Ingest could not see ShowShare. Grants the 'show' account traverse
# rights on ~/Desktop and the home folder (SMB hides a share whose path the
# user cannot reach), restarts smbd, and re-runs the self-test.
cd "$(dirname "$0")"
U="$(stat -f %Su /dev/console)"
H="$(dscl . -read /Users/$U NFSHomeDirectory | awk '{print $2}')"
echo "Fixing ShowShare visibility for 'show' on $(scutil --get ComputerName) (user $U)"
sudo chmod +a "show allow search,readattr" "$H" "$H/Desktop"
sudo chmod -R +a "show allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,delete,file_inherit,directory_inherit" "$H/Desktop/Ingest" 2>/dev/null
sudo launchctl kickstart -k system/com.apple.smbd 2>/dev/null
sleep 2
if smbutil view //show:password@127.0.0.1 2>/dev/null | grep -q ShowShare; then
    echo "PASS  'show' can now see ShowShare - this Mac is ready"
else
    echo "FAIL  still not visible. Shares seen by 'show':"; smbutil view //show:password@127.0.0.1
fi
read -r -p "Press Enter to close"
