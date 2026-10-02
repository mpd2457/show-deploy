#!/usr/bin/env python3
"""
show-watcher.py - push files from ~/Desktop/Ingest to the GFX and Mitti machines.

Safety rules this file exists to enforce:
  * a file is only pushed after its size AND mtime have stopped changing and
    no process holds it open, so a half-copied deck never lands
  * every push is verified against the size reported by the far end
  * a failed push is retried with backoff, and the queue is written to disk so
    failures survive a reboot or a crash
  * pushes to different machines run in parallel, so one big media file does
    not stall the rest
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------- configuration

HOME = Path.home()
CONF = HOME / ".config" / "showkit"
CREDS_GFX = CONF / "smbcreds"
CREDS_MITTI = CONF / "smbcreds-mitti"
QUEUE_FILE = CONF / "queue.json"
DROP = HOME / "Desktop" / "Ingest"
ARCHIVE = HOME / "Desktop" / "Archive"
LOG = DROP / "push_log.txt"

GFX_TARGETS = ["GFX1", "GFX2", "GFX3"]
MITTI_TARGETS = ["MITTIA", "MITTIB"]

DECK_EXTENSIONS = {".pptx", ".ppt", ".key", ".pdf"}
MEDIA_EXTENSIONS = {".mp4", ".mov", ".mxf", ".avi", ".mkv", ".wav", ".mp3", ".aac", ".m4a"}
IGNORE = {"push_log.txt", ".directory", "desktop.ini", "Thumbs.db", "queue.json"}

def _env_num(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


POLL_SECONDS = 2
SETTLE_POLLS = 3           # consecutive identical size+mtime samples before a push
MAX_ATTEMPTS = 8
BACKOFF = [
    int(x) for x in
    os.environ.get("SHOWKIT_BACKOFF", "0,5,15,45,120,300,600,900").split(",")
]
MAX_SKIPS = _env_num("SHOWKIT_MAX_SKIPS", 10)   # give up on a machine that never answers a ping
SKIP_RETRY = _env_num("SHOWKIT_SKIP_RETRY", 60)
PUT_TIMEOUT = 7200         # a 20 GB media file over gigabit is slow but real
LOG_ROTATE_BYTES = 5 * 1024 * 1024
LOG_KEEP = 3

_log_lock = threading.Lock()
_queue_lock = threading.Lock()

# ------------------------------------------------------------------------ logging


def _rotate_log():
    """Shift the log aside: .2 -> .3, .1 -> .2, current -> .1, then start fresh."""
    if not LOG.exists() or LOG.stat().st_size < LOG_ROTATE_BYTES:
        return
    oldest = LOG.with_name(LOG.name + "." + str(LOG_KEEP))
    if oldest.exists():
        oldest.unlink(missing_ok=True)
    for i in range(LOG_KEEP - 1, 0, -1):
        src = LOG.with_name(LOG.name + "." + str(i))
        if src.exists():
            src.replace(LOG.with_name(LOG.name + "." + str(i + 1)))
    LOG.replace(LOG.with_name(LOG.name + ".1"))


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} - {msg}\n"
    with _log_lock:
        try:
            _rotate_log()
            with LOG.open("a") as f:
                f.write(line)
        except OSError as e:
            print(f"LOG WRITE FAILED: {e}", file=sys.stderr)


# ------------------------------------------------------------------- durable queue
# entry: {"size": int, "targets": {host: attempts}, "label": str, "queued": iso}


def load_queue():
    try:
        with QUEUE_FILE.open() as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def _save_queue_locked(queue):
    """Write the queue. Caller must already hold _queue_lock."""
    tmp = QUEUE_FILE.with_suffix(".tmp")
    try:
        with tmp.open("w") as f:
            json.dump(queue, f, indent=1, sort_keys=True)
        tmp.replace(QUEUE_FILE)
    except OSError as e:
        log(f"QUEUE WRITE FAILED: {e}")


def save_queue(queue):
    """Write the queue, taking the lock. Use _save_queue_locked if already held."""
    with _queue_lock:
        _save_queue_locked(queue)


def enqueue(path, queue):
    name = path.name
    size = path.stat().st_size
    label = classify(path)
    with _queue_lock:
        existing = queue.get(name)
        if existing and existing.get("size") == size:
            return False
        queue[name] = {
            "size": size,
            "targets": {},
            "label": label,
            "queued": datetime.now().isoformat(timespec="seconds"),
        }
        _save_queue_locked(queue)
    log(f"QUEUED {name} [{label}]")
    return True


def classify(path):
    ext = path.suffix.lower()
    if ext in DECK_EXTENSIONS:
        return "DECK"
    if ext in MEDIA_EXTENSIONS:
        return "MEDIA"
    return f"UNKNOWN EXT {ext} -> ALL"


def targets_for(label):
    if label == "DECK":
        return list(GFX_TARGETS)
    if label == "MEDIA":
        return list(MITTI_TARGETS)
    return GFX_TARGETS + MITTI_TARGETS


# ---------------------------------------------------------------------- SMB layer


def reachable(host):
    try:
        return subprocess.run(
            ["ping", "-c", "1", "-W", "1", host],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def _smb(host, script, timeout):
    creds = CREDS_MITTI if host in MITTI_TARGETS else CREDS_GFX
    return subprocess.run(
        ["smbclient", f"//{host}/ShowShare", "-A", str(creds), "-m", "SMB3", "-c", script],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def smb_put(host, path):
    r = _smb(host, f'put "{path}" "{path.name}"', PUT_TIMEOUT)
    if r.returncode != 0:
        out = (r.stderr or r.stdout).strip()
        raise RuntimeError(out.splitlines()[-1] if out else f"smbclient exit {r.returncode}")


_SIZE_RE = re.compile(r"size\s*[:=]\s*(\d+)", re.IGNORECASE)


def smb_size(host, name):
    """Size the far end reports for `name`, or None if it cannot be determined."""
    try:
        r = _smb(host, f'allinfo "{name}"', 120)
    except (subprocess.SubprocessError, OSError):
        return None
    if r.returncode != 0:
        return None
    for line in (r.stdout or "").splitlines():
        m = _SIZE_RE.search(line)
        if m:
            return int(m.group(1))
    return None


def push_one(host, path, expected_size):
    """Push and verify. Returns (ok, detail)."""
    if not reachable(host):
        return None, "not on network this show"
    smb_put(host, path)
    remote = smb_size(host, path.name)
    if remote is None:
        return True, "pushed, size not verifiable"
    if remote != expected_size:
        return False, f"SIZE MISMATCH local {expected_size} remote {remote}"
    return True, ""


# -------------------------------------------------------------------------- worker


def process(path, entry, queue):
    name = path.name
    expected = entry["size"]
    label = entry["label"]
    target_list = targets_for(label)
    dest = lambda h: f"\\\\{h}\\ShowShare"  # noqa: E731

    # archive once, on first attempt
    with _queue_lock:
        already_archived = entry.get("archived")
        entry["archived"] = True
    if not already_archived:
        try:
            shutil.copy2(path, ARCHIVE / name)
        except Exception as e:
            log(f"ARCHIVE FAILED : {name} : {e}")

    # decide the work list under the lock, then release it: _queue_lock is a plain
    # threading.Lock and is NOT reentrant across the worker threads below.
    now = time.time()
    with _queue_lock:
        work = [
            host
            for host in target_list
            if not entry.get("delivered", {}).get(host)
            and host not in entry.get("given_up", {})
            and now >= entry.get("next_try", {}).get(host, 0)
        ]

    if not work:
        return

    def run(host):
        try:
            ok, detail = push_one(host, path, expected)
        except Exception as e:
            ok, detail = False, str(e)
        with _queue_lock:
            if ok is None:
                n = entry.setdefault("skip_count", {}).get(host, 0) + 1
                entry["skip_count"][host] = n
                if n <= MAX_SKIPS:
                    entry.setdefault("next_try", {})[host] = time.time() + SKIP_RETRY
                    log(f"SKIP [{label}] -> {dest(host)} : {name} "
                        f"(machine not present, will check again in {SKIP_RETRY}s)")
                else:
                    # machine stayed away for the whole window: stop watching it,
                    # but do not spend a retry attempt on it
                    entry.setdefault("given_up", {})[host] = "machine never came up"
                    entry.get("next_try", {}).pop(host, None)
                    log(f"SKIP [{label}] -> {dest(host)} : {name} "
                        f"(never came up, not retrying this machine)")
                _save_queue_locked(queue)
                return
            entry.setdefault("skip_count", {}).pop(host, None)
            entry.setdefault("given_up", {}).pop(host, None)
            entry["targets"][host] = entry["targets"].get(host, 0) + 1
            next_try = entry.setdefault("next_try", {})
            if ok:
                entry.setdefault("delivered", {})[host] = True
                next_try.pop(host, None)
                suffix = f" : {detail}" if detail else ""
                log(f"OK   [{label}] -> {dest(host)} : {name} ({entry['targets'][host]} attempt){suffix}")
            else:
                delay = BACKOFF[min(entry["targets"][host], len(BACKOFF) - 1)]
                next_try[host] = time.time() + delay
                left = MAX_ATTEMPTS - entry["targets"][host]
                if left <= 0:
                    entry["given_up"][host] = detail
                    log(f"FAIL [{label}] -> {dest(host)} : {name} : {detail} : giving up")
                else:
                    log(f"FAIL [{label}] -> {dest(host)} : {name} : {detail} "
                        f": retry in {delay}s, {left} attempt(s) left")
        _save_queue_locked(queue)

    with ThreadPoolExecutor(max_workers=len(work)) as pool:
        list(pool.map(run, work))

    with _queue_lock:
        # a target is settled when it has either been delivered or been given up on
        settled = all(
            entry.get("delivered", {}).get(h) or h in entry.get("given_up", {})
            for h in target_list
        )
        if settled:
            entry["done"] = True
            given_up = entry.get("given_up", {})
            absent = [h for h, why in given_up.items() if why == "machine never came up"]
            failed = [
                f"{h} ({entry['targets'].get(h, 0)}/{MAX_ATTEMPTS} tries)"
                for h in target_list
                if h in given_up and h not in absent
            ]
            if failed:
                # Remember what the file looked like when we gave up. Re-dropping an
                # identical file is not a new request - enqueue() ignores it and a
                # done entry is skipped - so "re-drop the file" only works if the
                # file is actually re-copied, which changes its mtime.
                entry["gave_up_mtime"] = path.stat().st_mtime_ns
                log(f"GIVE UP {name} : {', '.join(failed)} - "
                    f"re-copy the file into Ingest (or rename it) to try again")
            else:
                extra = f" ({len(absent)} machine(s) never came up)" if absent else ""
                log(f"DONE {name}{extra}")
    _save_queue_locked(queue)


# -------------------------------------------------------------------------- loop


def listing():
    return [p for p in DROP.iterdir() if p.is_file() and p.name not in IGNORE]


def is_open(path):
    try:
        return subprocess.run(
            ["fuser", "-s", str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def sweep(queue):
    """Drop queue entries whose file is gone, and re-arm ones that are still due."""
    with _queue_lock:
        for name in list(queue):
            if not (DROP / name).exists():
                log(f"GONE  {name} - removed from Ingest, dropping from queue")
                del queue[name]
        _save_queue_locked(queue)


def main():
    DROP.mkdir(parents=True, exist_ok=True)
    ARCHIVE.mkdir(parents=True, exist_ok=True)

    running = {"go": True}

    def stop(signum, frame):
        running["go"] = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    queue = load_queue()
    stable = {}
    resumed = [n for n, e in queue.items() if isinstance(e, dict) and not e.get("done")]
    # A restart usually means the rig just came up: forget backoff timers and
    # never-present flags so anything outstanding is retried immediately.
    for name in resumed:
        entry = queue[name]
        entry.pop("next_try", None)
        entry.pop("skip_count", None)
        entry.pop("given_up", None)
    if resumed:
        save_queue(queue)
    log(f"Watcher started, {len(resumed)} file(s) carried over from last run")

    while running["go"]:
        time.sleep(POLL_SECONDS)
        try:
            files = listing()
        except OSError:
            continue

        due = []
        for f in files:
            try:
                st = f.stat()
            except OSError:
                continue
            sig = (st.st_size, st.st_mtime_ns)

            entry = queue.get(f.name)
            if entry is not None and entry.get("size") != st.st_size:
                # file changed under us, it is a new version: re-queue it
                with _queue_lock:
                    queue.pop(f.name, None)
                    _save_queue_locked(queue)
                log(f"CHANGED {f.name} - size moved, treating as a new version")
                entry = None

            if entry is None:
                prev = stable.get(f.name)
                if prev is None:
                    stable[f.name] = (sig, 1)
                    continue
                if prev[0] != sig:
                    stable[f.name] = (sig, 1)
                    continue
                count = prev[1] + 1
                stable[f.name] = (sig, count)
                if count >= SETTLE_POLLS and not is_open(f):
                    if enqueue(f, queue):
                        stable.pop(f.name, None)
                continue

            if entry.get("done"):
                # A file that was given up on (or delivered) stays in the queue and
                # is skipped. If it has since been re-copied, its mtime has moved:
                # that is the operator asking for another go, so start it fresh.
                gu = entry.get("gave_up_mtime")
                if gu is not None and st.st_mtime_ns != gu:
                    with _queue_lock:
                        queue.pop(f.name, None)
                        _save_queue_locked(queue)
                    log(f"RE-ARMED {f.name} - file was re-copied after giving up")
                continue
            needs_retry = any(
                not entry.get("delivered", {}).get(h)
                and h not in entry.get("given_up", {})
                and time.time() >= entry.get("next_try", {}).get(h, 0)
                for h in targets_for(entry["label"])
            )
            if needs_retry and not is_open(f):
                due.append(f)

        stable = {k: v for k, v in stable.items() if (DROP / k).exists()}

        for f in due:
            entry = queue.get(f.name)
            if entry:
                process(f, entry, queue)
        if due:
            sweep(queue)

    log("Watcher stopping")
    save_queue(queue)


if __name__ == "__main__":
    main()
