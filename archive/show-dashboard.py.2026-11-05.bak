#!/usr/bin/env python3
"""
show-dashboard.py — live status dashboard for the show-deploy ingest system.

Serves a self-refreshing HTML page on http://localhost:8080 that shows every
file in the push queue with colour-coded status, which machines have it, and
a tail of the push log.  No external dependencies — stdlib only.

Run standalone:   python3 show-dashboard.py
Or import and call start_dashboard_thread() to run alongside the watcher.
"""

import json
import os
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# ---------------------------------------------------------------- paths
HOME         = Path.home()
QUEUE_FILE   = HOME / ".config" / "showkit" / "queue.json"
LOG_FILE     = HOME / "Desktop" / "Ingest" / "push_log.txt"

DASHBOARD_PORT = 8080
LOG_TAIL_LINES = 20

# All machines the watcher knows about, in display order
ALL_TARGETS = ["GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"]

# ---------------------------------------------------------------- data helpers

def _read_queue() -> dict:
    """Load queue.json, return {} if missing or corrupt."""
    try:
        with QUEUE_FILE.open() as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _read_log_tail(n: int = LOG_TAIL_LINES) -> list[str]:
    """Return the last *n* lines of push_log.txt."""
    try:
        with LOG_FILE.open(errors="replace") as f:
            lines = f.readlines()
        return [l.rstrip() for l in lines[-n:]]
    except OSError:
        return []


def _classify_entry(entry: dict) -> str:
    """
    Return one of: "done", "failed", "sending", "queued"

    Logic mirrors the watcher:
      done     → entry["done"] is truthy
      failed   → given_up has at least one host that ran out of attempts
                 (as opposed to "machine never came up")
      sending  → has targets dict with at least one attempt on any host
      queued   → just entered the queue, no attempts yet
    """
    if entry.get("done"):
        return "done"

    given_up = entry.get("given_up", {})
    # Distinguish "never came up" (absent machine) from real failures
    real_fails = [h for h, why in given_up.items() if why != "machine never came up"]
    if real_fails:
        return "failed"

    targets = entry.get("targets", {})
    if any(v > 0 for v in targets.values()):
        return "sending"

    return "queued"


def _machines_status(entry: dict) -> dict[str, str]:
    """
    Return per-machine status for display.
    Values: "✅", "🔄", "❌", "–" (not a target), "🚫" (gave up / absent)
    """
    label   = entry.get("label", "")
    targets = entry.get("targets", {})
    delivered = entry.get("delivered", {})
    given_up  = entry.get("given_up", {})

    # Which machines are this file's concern?
    if label == "DECK":
        concerned = {"GFX1", "GFX2", "GFX3"}
    elif label == "MEDIA":
        concerned = {"MITTIA", "MITTIB"}
    else:
        concerned = set(ALL_TARGETS)

    result = {}
    for host in ALL_TARGETS:
        if host not in concerned:
            result[host] = "–"
            continue
        if delivered.get(host):
            result[host] = "✅"
        elif host in given_up:
            why = given_up[host]
            result[host] = "⚠️" if why == "machine never came up" else "❌"
        elif targets.get(host, 0) > 0:
            result[host] = "🔄"
        else:
            result[host] = "⏳"
    return result


def _fmt_time(iso: str) -> str:
    """Pretty-print an ISO timestamp, returning '' on failure."""
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(iso)
        return dt.strftime("%H:%M:%S")
    except (ValueError, TypeError):
        return iso[:19]


# ---------------------------------------------------------------- HTML builder

_CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    background: #111;
    color: #eee;
    font-family: 'Segoe UI', Arial, sans-serif;
    font-size: 18px;
    padding: 18px 24px 30px;
}
h1 {
    font-size: 2.2rem;
    font-weight: 700;
    letter-spacing: 0.04em;
    color: #fff;
    margin-bottom: 6px;
}
.subtitle {
    font-size: 1rem;
    color: #888;
    margin-bottom: 18px;
}
.summary {
    display: flex;
    gap: 18px;
    flex-wrap: wrap;
    margin-bottom: 20px;
}
.pill {
    border-radius: 999px;
    padding: 6px 20px;
    font-size: 1.1rem;
    font-weight: 600;
    letter-spacing: 0.03em;
}
.pill-done    { background: #1a4a2a; color: #6edf8e; border: 1.5px solid #3a8a5a; }
.pill-sending { background: #4a3a0a; color: #ffd966; border: 1.5px solid #aa8a20; }
.pill-queued  { background: #2a2a4a; color: #aabbff; border: 1.5px solid #5566bb; }
.pill-failed  { background: #4a0a0a; color: #ff7777; border: 1.5px solid #aa2222; }
.pill-total   { background: #222;    color: #aaa;    border: 1.5px solid #444; }

table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 28px;
    table-layout: fixed;
}
th {
    background: #1e1e1e;
    color: #aaa;
    font-size: 0.85rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 10px 14px;
    text-align: left;
    border-bottom: 2px solid #333;
}
td {
    padding: 11px 14px;
    border-bottom: 1px solid #222;
    vertical-align: middle;
    word-break: break-all;
}
tr:last-child td { border-bottom: none; }
.col-filename { width: 35%; }
.col-status   { width: 14%; }
.col-gfx1     { width: 7%;  text-align: center; }
.col-gfx2     { width: 7%;  text-align: center; }
.col-gfx3     { width: 7%;  text-align: center; }
.col-mittia   { width: 8%;  text-align: center; }
.col-mittib   { width: 8%;  text-align: center; }
.col-time     { width: 14%; font-size: 0.9rem; color: #888; }

.row-done    { background: #0d2818; }
.row-sending { background: #2a200a; }
.row-queued  { background: #131325; }
.row-failed  { background: #2a0d0d; }
.row-done:hover    { background: #133320; }
.row-sending:hover { background: #362a0e; }
.row-queued:hover  { background: #1a1a38; }
.row-failed:hover  { background: #3a1010; }

.status-badge {
    font-size: 0.95rem;
    font-weight: 700;
    letter-spacing: 0.03em;
}
.st-done    { color: #6edf8e; }
.st-sending { color: #ffd966; }
.st-queued  { color: #aabbff; }
.st-failed  { color: #ff7777; }

.machine-cell { font-size: 1.2rem; }

.empty-msg {
    text-align: center;
    color: #444;
    font-size: 1.1rem;
    padding: 36px 0;
}

.section-title {
    font-size: 1rem;
    font-weight: 600;
    color: #666;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    margin-bottom: 8px;
}
.log-box {
    background: #0a0a0a;
    border: 1px solid #2a2a2a;
    border-radius: 6px;
    padding: 12px 16px;
    max-height: 260px;
    overflow-y: auto;
    font-family: 'Cascadia Code', 'Fira Code', 'Consolas', monospace;
    font-size: 0.82rem;
    color: #6a9a6a;
    line-height: 1.55;
    white-space: pre-wrap;
    word-break: break-all;
}
.log-box .log-ok   { color: #5dba75; }
.log-box .log-fail { color: #e06060; }
.log-box .log-skip { color: #c0a030; }
.log-box .log-info { color: #5888c0; }
.log-box .log-done { color: #80e0a0; font-weight: 600; }
.log-box .log-give { color: #e07050; font-weight: 600; }

.footer {
    margin-top: 22px;
    font-size: 0.8rem;
    color: #444;
    text-align: right;
}
"""

_STATUS_LABEL = {
    "done":    "✅ DONE",
    "sending": "🔄 SENDING",
    "queued":  "⏳ QUEUED",
    "failed":  "❌ FAILED",
}
_STATUS_CLASS = {
    "done":    "st-done",
    "sending": "st-sending",
    "queued":  "st-queued",
    "failed":  "st-failed",
}
_ROW_CLASS = {
    "done":    "row-done",
    "sending": "row-sending",
    "queued":  "row-queued",
    "failed":  "row-failed",
}


def _log_line_class(line: str) -> str:
    ll = line.upper()
    if " OK " in ll:
        return "log-ok"
    if "DONE " in ll or ll.startswith("DONE"):
        return "log-done"
    if "FAIL" in ll or "SIZE MISMATCH" in ll:
        return "log-fail"
    if "GIVE UP" in ll or "GIVING UP" in ll:
        return "log-give"
    if "SKIP" in ll:
        return "log-skip"
    if "QUEUE" in ll or "WATCHER" in ll or "STARTED" in ll or "RE-ARMED" in ll:
        return "log-info"
    return ""


def _escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;"))


def build_html() -> str:
    queue     = _read_queue()
    log_lines = _read_log_tail()
    now_str   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Count by status
    counts = {"done": 0, "sending": 0, "queued": 0, "failed": 0}
    rows_data = []
    for name, entry in sorted(queue.items()):
        if not isinstance(entry, dict):
            continue
        status = _classify_entry(entry)
        counts[status] += 1
        mach = _machines_status(entry)
        queued_at = _fmt_time(entry.get("queued", ""))
        rows_data.append((name, status, mach, queued_at))

    total = sum(counts.values())

    # ---- summary pills
    summary_parts = []
    pill_data = [
        ("done",    counts["done"],    "pill-done",    "Done"),
        ("sending", counts["sending"], "pill-sending", "Sending"),
        ("queued",  counts["queued"],  "pill-queued",  "Queued"),
        ("failed",  counts["failed"],  "pill-failed",  "Failed"),
    ]
    for _, cnt, cls, label in pill_data:
        summary_parts.append(
            f'<span class="pill {cls}">{cnt} {label}</span>'
        )
    summary_parts.append(
        f'<span class="pill pill-total">{total} Total</span>'
    )
    summary_html = "\n".join(summary_parts)

    # ---- table rows
    if rows_data:
        rows_html_parts = []
        for name, status, mach, queued_at in rows_data:
            rc  = _ROW_CLASS[status]
            sc  = _STATUS_CLASS[status]
            sl  = _STATUS_LABEL[status]
            row = (
                f'<tr class="{rc}">'
                f'<td class="col-filename">{_escape(name)}</td>'
                f'<td class="col-status"><span class="status-badge {sc}">{sl}</span></td>'
            )
            for host in ALL_TARGETS:
                icon = _escape(mach[host])
                col  = f"col-{host.lower()}"
                row += f'<td class="{col} machine-cell">{icon}</td>'
            row += f'<td class="col-time">{_escape(queued_at)}</td>'
            row += "</tr>"
            rows_html_parts.append(row)
        rows_html = "\n".join(rows_html_parts)
    else:
        cols = 2 + len(ALL_TARGETS) + 1
        rows_html = (
            f'<tr><td colspan="{cols}" class="empty-msg">'
            "No files in queue — drop something into Ingest to get started"
            "</td></tr>"
        )

    # ---- log tail
    log_html_parts = []
    for line in log_lines:
        cls = _log_line_class(line)
        esc = _escape(line)
        if cls:
            log_html_parts.append(f'<span class="{cls}">{esc}</span>')
        else:
            log_html_parts.append(esc)
    log_html = "\n".join(log_html_parts) if log_html_parts else "(no log yet)"

    # ---- machine column headers
    mach_headers = "".join(
        f'<th class="col-{h.lower()}">{h}</th>' for h in ALL_TARGETS
    )

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="3">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Show Deploy — Ingest Status</title>
<style>
{_CSS}
</style>
</head>
<body>
<h1>📡 Show Deploy</h1>
<div class="subtitle">Ingest status &mdash; auto-refreshing every 3 seconds</div>

<div class="summary">
{summary_html}
</div>

<table>
  <thead>
    <tr>
      <th class="col-filename">File</th>
      <th class="col-status">Status</th>
      {mach_headers}
      <th class="col-time">Queued</th>
    </tr>
  </thead>
  <tbody>
{rows_html}
  </tbody>
</table>

<div class="section-title">Recent log — last {LOG_TAIL_LINES} lines</div>
<div class="log-box">{log_html}</div>

<div class="footer">Updated {_escape(now_str)} &mdash; {_escape(str(QUEUE_FILE))}</div>
</body>
</html>"""
    return html


# ---------------------------------------------------------------- HTTP server

class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path not in ("/", "/index.html", "/favicon.ico"):
            self.send_response(404)
            self.end_headers()
            return
        if self.path == "/favicon.ico":
            # Tiny inline favicon so the browser doesn't log 404s
            self.send_response(204)
            self.end_headers()
            return
        try:
            body = build_html().encode("utf-8")
        except Exception as exc:
            body = f"<pre>Dashboard error: {exc}</pre>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # suppress per-request console noise
        pass


def start_dashboard_thread(port: int = DASHBOARD_PORT) -> threading.Thread:
    """
    Start the dashboard HTTP server in a daemon thread.
    Returns the thread (already started).
    Call this from the watcher's main() to run both side by side.
    """
    server = HTTPServer(("", port), _Handler)

    def _serve():
        server.serve_forever()

    t = threading.Thread(target=_serve, name="dashboard", daemon=True)
    t.start()
    return t


# ---------------------------------------------------------------- standalone

if __name__ == "__main__":
    import sys
    port = DASHBOARD_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print(f"Usage: python3 show-dashboard.py [port]  (default {DASHBOARD_PORT})")
            sys.exit(1)

    print(f"Show Deploy Dashboard → http://localhost:{port}")
    print(f"  Queue : {QUEUE_FILE}")
    print(f"  Log   : {LOG_FILE}")
    print("  Ctrl-C to stop\n")

    server = HTTPServer(("", port), _Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard stopped.")
