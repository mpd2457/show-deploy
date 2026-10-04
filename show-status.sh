#!/usr/bin/env bash
# show-status.sh — Human-readable show deployment status
# Usage: bash show-status.sh
# To make executable: chmod +x show-status.sh

QUEUE_FILE="$HOME/.config/showkit/queue.json"
LOG_FILE="$HOME/Desktop/Ingest/push_log.txt"

python3 - "$QUEUE_FILE" "$LOG_FILE" <<'PYEOF'
import sys, json, os
from datetime import datetime

queue_file = sys.argv[1]
log_file   = sys.argv[2]

now = datetime.now().strftime("%H:%M:%S")
print(f"\n=== Show Status ===  {now}\n")

# ── Load queue ────────────────────────────────────────────────────────────────
if not os.path.exists(queue_file):
    print(f"  (no queue file found at {queue_file})\n")
    items = []
else:
    try:
        with open(queue_file) as f:
            data = json.load(f)
        # Support both a top-level list and {"queue": [...]}
        if isinstance(data, list):
            items = data
        elif isinstance(data, dict):
            items = data.get("queue", data.get("items", []))
        else:
            items = []
    except Exception as e:
        print(f"  ⚠️  Could not parse {queue_file}: {e}\n")
        items = []

# ── Bucket items by status ────────────────────────────────────────────────────
buckets = {"DONE": [], "SENDING": [], "FAILED": [], "QUEUED": []}

for item in items:
    name     = item.get("file", item.get("name", item.get("filename", "?")))
    status   = str(item.get("status", "QUEUED")).upper()
    targets  = item.get("targets", item.get("destinations", []))

    # Normalise targets to list of dicts with "name" and optional "status"
    norm_targets = []
    for t in targets:
        if isinstance(t, str):
            norm_targets.append({"name": t, "status": "DONE"})
        elif isinstance(t, dict):
            norm_targets.append({"name": t.get("name", t.get("host", "?")),
                                 "status": str(t.get("status", "DONE")).upper()})

    if status not in buckets:
        status = "QUEUED"
    buckets[status].append({"name": name, "targets": norm_targets})

# ── Emoji helpers ─────────────────────────────────────────────────────────────
STATUS_EMOJI = {"DONE": "✅", "SENDING": "🔄", "FAILED": "❌", "QUEUED": "⏳"}

def target_line(targets, show_per_status=False):
    if not targets:
        return ""
    if show_per_status:
        parts = []
        for t in targets:
            emoji = STATUS_EMOJI.get(t["status"], "⏳")
            parts.append(f"{t['name']} {emoji}")
        return "  ".join(parts)
    else:
        return " ".join(t["name"] for t in targets)

# ── Print each bucket ─────────────────────────────────────────────────────────
order = ["DONE", "SENDING", "FAILED", "QUEUED"]
for key in order:
    emoji = STATUS_EMOJI[key]
    entries = buckets[key]
    count   = len(entries)
    print(f"{emoji} {key} ({count})")
    for entry in entries:
        name = entry["name"]
        targets = entry["targets"]
        per_status = (key == "SENDING")
        tgt_str = target_line(targets, per_status)
        if tgt_str:
            # Pad filename to 22 chars for alignment
            print(f"   {name:<22} → {tgt_str}")
        else:
            print(f"   {name}")
    print()

# ── Ingest log tail ───────────────────────────────────────────────────────────
print("Ingest log (last 5 lines):")
if not os.path.exists(log_file):
    print(f"  (no log file found at {log_file})")
else:
    try:
        with open(log_file) as f:
            lines = f.read().splitlines()
        tail = lines[-5:] if len(lines) >= 5 else lines
        if tail:
            for line in tail:
                print(f"  {line}")
        else:
            print("  (log is empty)")
    except Exception as e:
        print(f"  ⚠️  Could not read log: {e}")
print()
PYEOF
