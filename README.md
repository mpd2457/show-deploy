# Show Deployment Kit

Pushes files from one Ingest laptop to the rest of a show rig over SMB, and nothing
else. Drop a deck in a folder, it lands on the GFX machines. Drop media, it lands on
the Macs. Machines that are off are skipped rather than failed. Nothing auto-opens.

Stick must be exFAT. Copy this whole folder onto it.

**Two Ingest options.** The Linux laptop (mkultra2) is the normal one. A Windows 11
Pro work laptop can take the same role with identical behaviour if mkultra2 is not
available — see [Windows Ingest](#windows-ingest-fallback).

## Contents

| File | Runs on | What it does |
|---|---|---|
| `setup-ingest.sh` | Linux Ingest | static IP, folders, creds, installs the watcher |
| `restore-ingest.sh` | Linux Ingest | undoes the above, puts the laptop back to normal |
| `RUN-ingest.sh` / `RUN-restore.sh` | Linux Ingest | double-click wrappers around the two above |
| `setup-ingest-win.ps1` | Windows Ingest | same job as `setup-ingest.sh` |
| `restore-ingest-win.ps1` | Windows Ingest | undoes it, restores the adapter's prior addressing |
| `RUN-ingest-win.bat` / `RUN-ingest-win-restore.bat` | Windows Ingest | Run as administrator wrappers |
| `show-watcher.py` | Linux Ingest | the push watcher itself |
| `show-watcher.ps1` | Windows Ingest | the same watcher, ported |
| `setup-gfx.ps1` | GFX1-3 | Windows deck machines: IP, share, arrival log |
| `RUN-gfx1.bat` … `RUN-gfx3.bat` | GFX1-3 | one per machine, so you cannot run the wrong one |
| `setup-mitti.sh` | MITTIA/B | Mac video/audio: IP, share, arrival log |
| `RUN-mittiA.command` / `RUN-mittiB.command` | MITTIA/B | one per machine |
| `show-watcher-mac.sh` | MITTIA/B | the Mac arrival logger |
| `test_watcher.py` | any | offline tests for the Linux watcher |
| `test_watcher_win.py` | any | offline tests for the Windows watcher |

Tests need no rig and touch nothing on it: they fake `ping` and `smbclient` in a
temp directory and run the real watcher against them.

```bash
python3 test_watcher.py        # 49 checks
python3 test_watcher_win.py    # 40 checks, needs pwsh
```

## Network, wired only

192.168.50.0/24, gateway 192.168.50.1. Wi-Fi is never changed.
Plug into the rig switch before setup.

INGEST  192.168.50.10   drop files in ~/Desktop/Ingest (mkultra2, or the Windows fallback)
GFX1    192.168.50.11   decks
GFX2    192.168.50.12   decks
GFX3    192.168.50.13   decks
MITTIA  192.168.50.15   video/audio
MITTIB  192.168.50.16   video/audio

## Folders

INGEST   ~/Desktop/Ingest     drop here. push_log.txt inside.
         ~/Desktop/Archive    copy of every drop.
         Ingest also has Day 1 through Day 5.
GFX      C:/Users/Public/Desktop/Ingest   plus Day 1 through Day 5
Mitti    ~/Desktop/Ingest                 plus Day 1 through Day 5

Share name is still ShowShare, but it points at that Desktop Ingest folder.
Files land straight in Ingest. Day folders stay empty until you drag into them.

Decks go to the GFX machines, media to the Mitti Macs, anything else to
everything — see [What gets pushed where](#what-gets-pushed-where).

Log in as the share user `show`. **No password is stored in this repo.** Every
setup script prompts for it, and Ingest writes it to `~/.config/showkit/smbcreds`
at mode 600 (on Windows, to `%LOCALAPPDATA%\showkit` with an ACL for your user
only). Macs use each Mac's own login, stored the same way in `smbcreds-mitti`.

The restore scripts delete these files. If you use a throwaway password for a
show, change it afterwards.

## What you will see in the log

  QUEUED  name [DECK]              new file seen, waiting to settle
  OK   [DECK] -> \\GFX1\ShowShare : name (1 attempt)
  SKIP [MEDIA] -> \\MITTIA\ShowShare : name (machine not present, will check again in 60s)
  FAIL [DECK] -> \\GFX2\ShowShare : name : NT_STATUS_ACCESS_DENIED : retry in 15s, 7 attempt(s) left
  DONE  name                        every target delivered
  GONE  name                        you deleted it from Ingest while it was still queued

OK = landed, and the far end confirmed the size. SKIP = machine not here.
FAIL = password or share, and it will be retried. DONE means you can stop watching.

See [How it stays out of trouble](#how-it-stays-out-of-trouble) for why these
outcomes can be trusted.

## Install once per machine

Cable to the switch first.

Ingest on mkultra2 (Linux), from the show-deploy folder:
  sudo bash ./setup-ingest.sh
It asks for the GFX password, then offers the Mac login (blank to skip).
Pass the wired interface name as the first argument if auto-detection is wrong.
No reboot.
Check: systemctl --user status showwatcher

GFX: double-click RUN-gfx1.bat on the .11 laptop, RUN-gfx2.bat on .12, RUN-gfx3.bat on .13.
UAC Yes. It asks for the share password. Reboot if it renamed the PC.

Mac: right-click RUN-mittiA.command or RUN-mittiB.command, Open.
Then System Settings, Sharing, File Sharing ON.
ShowShare must be Desktop/Ingest. Tick SMB and tick the user.
Reboot. On the first push, click Allow on the Local Network prompt.

## Windows Ingest fallback

Use this when mkultra2 is not available. Same IP, same drop folder, same log,
same retry behaviour — `show-watcher.ps1` is a port of `show-watcher.py`, not a
simplification, so a show behaves identically whichever laptop is in the van.

Right-click `RUN-ingest-win.bat`, Run as administrator. It asks the same
questions, creates `Desktop\Ingest`, `Desktop\Archive` and Day 1-5, stores
credentials under `%LOCALAPPDATA%\showkit`, and registers a scheduled task that
starts the watcher at logon.

Two deliberate differences:

* The drop folder is the signed-in user's own `Desktop\Ingest`, not the Public
  desktop the GFX machines use.
* It consumes a share rather than serving one, so there is nothing to turn on in
  File Sharing.

Requires `smbclient.exe`, present on Windows 11 Pro out of the box, and
`ThreadJob` from PowerShell 5.1+. Both are standard on Pro; Home editions are
not a supported target.

To undo it, run `RUN-ingest-win-restore.bat` as administrator. It removes the
scheduled task, deletes the stored credentials and push queue, restores the
wired adapter to the exact addressing it had beforehand (saved at setup, so
not merely "assume DHCP"), and cleans the hosts file. Add `-Purge` to also
delete the Ingest and Archive folders.

## Show day

Drop a small pptx and a short mp4 into the Ingest folder, then watch the log:

    tail -f ~/Desktop/Ingest/push_log.txt        # Linux
    Get-Content "$env:USERPROFILE\Desktop\Ingest\push_log.txt" -Wait -Tail 20   # Windows

Look for `DONE` on both, and both files in `~/Desktop/Archive`. If something
goes wrong, the log names the machine and the reason.

Every show: power on, cable Ingest, drop files with a new filename each version.
Sort into Day 1-Day 5 yourself.

After 5 MB the log rotates, keeping `push_log.txt.1` and `.2`.

### What gets pushed where

| Extension | Goes to |
|---|---|
| `.pptx .ppt .key .pdf` | GFX1, GFX2, GFX3 |
| `.mp4 .mov .mxf .avi .mkv .wav .mp3 .aac .m4a` | MITTIA, MITTIB |
| anything else | everything, logged as `UNKNOWN EXT` |

Only the top level of the drop folder is watched. Files you drag into a Day
folder are left alone — they were delivered when you dropped them.

## If something fails

FAIL on GFX: smbclient //GFX1/ShowShare -A ~/.config/showkit/smbcreds -c ls
FAIL on Mac: smbclient //MITTIA/ShowShare -A ~/.config/showkit/smbcreds-mitti -c ls

A machine that answers a ping but refuses the share is a FAIL, not a SKIP:
the share is asleep or the password is wrong. Give it 8 attempts, then
GIVE UP is logged and the file needs re-dropping.

Unsure what is still outstanding:
  cat ~/.config/showkit/queue.json

## How it stays out of trouble

**A half-copied file never lands.** A file is only pushed after its size and
modification time have held still across several polls and nothing has it open.
A deck still copying off a USB stick is invisible to the watcher until it stops
moving.

**Every push is verified.** After transferring, Ingest asks the far end how big
the file is. A mismatch is a failure and gets retried, so a transfer that dies
halfway is caught rather than silently accepted.

**Failures retry.** Up to 8 attempts with backoff, then `GIVE UP` and the file
needs re-dropping. The queue is written to disk, so if Ingest reboots mid-show
it resumes instead of starting over. Backoff timers reset on restart, because a
restart usually means the rig just came up.

**Absence is not failure.** A machine that does not answer a ping is `SKIP`ped
and re-checked every 60s for 10 minutes, without spending retry attempts. A
machine that answers ping but refuses the share is a genuine `FAIL` — the share
is asleep or the password is wrong — and does consume attempts.

**One slow machine cannot block the others.** Pushes run in parallel, so a 20 GB
media file does not hold up the decks.

**Wi-Fi is never touched.** Every script refuses a wireless adapter outright
rather than trusting the operator picked the right cable, and the restore path
only ever re-addresses the wired port.

## After the event: Ingest back to daily driver

Linux:
  cd ~/Desktop/show-deploy && sudo bash ./restore-ingest.sh

Windows fallback:
  Right-click RUN-ingest-win-restore.bat, Run as administrator.
  Add -Purge to also delete the Ingest and Archive folders.

Both: stop and remove the watcher service/task, delete the stored SMB
passwords and the push queue, put the wired port back to how it was
(it goes to DHCP), clean the hosts file. Wi-Fi is never touched. No reboot.
Ingest and Archive folders are KEPT so you still have the show files.
To delete those too on Linux: sudo bash ./restore-ingest.sh --purge
Run setup-ingest.sh again before the next show.

GFX and Mitti machines keep their show setup: static IP, share and local
account. To undo those, run the setup script again to refresh, or set the
adapter back to DHCP by hand. They are only ever plugged into the rig switch.

## Notes

Built for a six-machine rig on a closed 192.168.50.0/24 network with no
internet dependency at show time. The addresses, machine names and share name
are defined once per file — `show-watcher.py` has them near the top,
`setup-gfx.ps1` and `setup-mitti.sh` have an IP map. Retargeting the kit to a
different subnet means editing those.

The scripts assume `exFAT` or `NTFS` on the stick and a wired switch. Neither
watcher daemonises itself: Linux uses a systemd user service with linger
enabled, Windows uses a scheduled task at logon.
