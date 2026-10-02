#!/bin/bash
# show-watcher-mac.sh - arrival logger for a Mitti Mac.
#
# Runs from a launchd WatchPaths job. Logs a line for each new file that lands in
# the Ingest folder so the operator can confirm arrivals.
#
# This used to use `find -newer $STAMP`, which silently missed any file that
# arrived carrying an old modification time - exactly what happens when the
# file is copied off the Archive folder with its timestamp preserved. It now
# tracks the set of names it has already reported, so mtime is irrelevant.

set -uo pipefail
DIR="${SHOWKIT_DIR:-/Users/show/Desktop/Ingest}"
LOG="${SHOWKIT_LOG:-$HOME/Library/Logs/showkit-arrival.log}"
STATE="${SHOWKIT_STATE:-$HOME/Library/Logs/showkit-arrival.seen}"
MAX_LOG_BYTES=5242880

mkdir -p "$(dirname "$LOG")"
touch "$LOG" "$STATE"

# Only report names we have never logged. Compare basenames, not paths, and do
# it without caring about modification times.
new_files() {
    find "$DIR" -maxdepth 1 -type f ! -name '.*' ! -name 'push_log.txt' -print0 \
        | while IFS= read -r -d '' f; do
            base=$(basename "$f")
            if ! grep -Fqx "$base" "$STATE" 2>/dev/null; then
                printf '%s\n' "$base"
            fi
        done
}

rotate_log() {
    [ "$(wc -c < "$LOG")" -lt "$MAX_LOG_BYTES" ] && return 0
    mv -f "$LOG" "$LOG.1"
    : > "$LOG"
}

main() {
    rotate_log
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        # wc -c rather than stat: stat's flag for size differs between BSD and GNU
        size=$(wc -c < "$DIR/$base" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        printf '%s - New file arrived: %s (%s MB)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$base" \
            "$(( size / 1048576 ))" >> "$LOG"
        printf '%s\n' "$base" >> "$STATE"
    done <<EOF
$(new_files)
EOF
    # keep the state file from growing without bound across a long show
    if [ -f "$STATE" ]; then
        tmp=$(mktemp)
        find "$DIR" -maxdepth 1 -type f ! -name '.*' ! -name 'push_log.txt' -exec basename {} \; \
            > "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$STATE"
    fi
    return 0
}

main
exit 0
