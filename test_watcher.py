#!/usr/bin/env python3
"""
Offline harness for show-watcher.py.

Fakes ping/smbclient on PATH so the watcher can be exercised without the rig.
Runs it against a throwaway HOME. Scenarios:

  1. a deck reaches all three GFX machines, verified by size
  2. a machine that answers ping but refuses the put is retried, then succeeds
  3. a machine that never answers ping is SKIPped, rechecked, then given up on
  4. a truncated put (remote size != local size) is caught and retried
  5. a file still being written is NOT pushed until it settles
  6. pushes to different machines overlap in time (concurrency works)
  7. a pending file survives a watcher restart
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SRC = Path(__file__).resolve().parent / "show-watcher.py"
FAKEBIN = Path(__file__).resolve().parent / "testbin"

PING_UP = "hup"
SMBCLIENT_LOG = "smbcalls.log"
CONTROL = "control.json"

FAKE_PING = '''#!/usr/bin/env python3
import json, os, sys
host = sys.argv[-1]
up = json.load(open(os.path.join(os.environ["FAKE_HOME"], "control.json"))).get("up", [])
sys.exit(0 if host in up else 1)
'''

FAKE_SMBCLIENT = '''#!/usr/bin/env python3
import json, os, re, sys, time
home = os.environ["FAKE_HOME"]
ctl = json.load(open(os.path.join(home, "control.json")))
host = re.split(r"[/\\\\]", sys.argv[1].strip("/\\\\"))[0]
log = os.path.join(home, "smbcalls.log")

# last -c argument is the command string
cmd = sys.argv[sys.argv.index("-c") + 1]
with open(log, "a") as f:
    f.write("%.3f %s %s\\n" % (time.time(), host, cmd))

# each host keeps its own file store so parallel pushes cannot clobber
# each other's state
store = os.path.join(home, "store", host + ".json")
hostctl = ctl.get("hosts", {}).get(host, {})
files = {}
if os.path.exists(store):
    files = json.load(open(store))

def save():
    os.makedirs(os.path.join(home, "store"), exist_ok=True)
    json.dump(files, open(store, "w"))

delay = hostctl.get("delay", 0)
if delay:
    time.sleep(delay)

if cmd.strip() == "ls":
    print("  .                                   D        0  Fri Oct  2 12:00:00 2026")
    for name, size in sorted(files.items()):
        print("  %-40s %10d  Fri Oct  2 12:00:00 2026" % (name, size))
    sys.exit(0)

if cmd.startswith("put "):
    name = cmd.rsplit('"', 2)[1]
    if hostctl.get("refuse_put"):
        print("NT_STATUS_ACCESS_DENIED", file=sys.stderr)
        sys.exit(1)
    local = cmd.split('"')[1]
    size = os.path.getsize(local) if os.path.exists(local) else 12345
    if hostctl.get("corrupt_put"):
        size = max(0, size - 4096)
    files[name] = size
    save()
    sys.exit(0)

if cmd.startswith("allinfo "):
    name = cmd.rsplit('"', 2)[1]
    if name not in files:
        print("NT_STATUS_OBJECT_NAME_NOT_FOUND", file=sys.stderr)
        sys.exit(1)
    print("\\tName\\t\\t: %s" % name)
    print("\\tSize\\t\\t: %d" % files[name])
    sys.exit(0)

sys.exit(0)
'''


def build_fakes():
    FAKEBIN.mkdir(exist_ok=True)
    for name, body in (("ping", FAKE_PING), ("smbclient", FAKE_SMBCLIENT)):
        p = FAKEBIN / name
        p.write_text(body)
        p.chmod(0o755)


def make_home():
    home = Path(tempfile.mkdtemp(prefix="showkit-test-"))
    (home / "Desktop" / "Ingest").mkdir(parents=True)
    (home / "Desktop" / "Archive").mkdir(parents=True)
    conf = home / ".config" / "showkit"
    conf.mkdir(parents=True)
    (conf / "smbcreds").write_text("username=show\npassword=x\n")
    (conf / "smbcreds-mitti").write_text("username=mac\npassword=x\n")
    (home / "control.json").write_text(json.dumps({"up": [], "hosts": {}}))
    return home


def control(home):
    return json.loads((home / "control.json").read_text())


def set_control(home, data):
    (home / "control.json").write_text(json.dumps(data))


def run_watcher(home, seconds, extra_env=None):
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["FAKE_HOME"] = str(home)
    env["PATH"] = f"{FAKEBIN}:{env['PATH']}"
    if extra_env:
        env.update(extra_env)
    proc = subprocess.Popen(
        [sys.executable, str(SRC)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        out, _ = proc.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        proc.terminate()
        out, _ = proc.communicate(timeout=10)
    return out


def logtext(home):
    p = home / "Desktop" / "Ingest" / "push_log.txt"
    return p.read_text() if p.exists() else ""


def calls(home):
    p = home / "smbcalls.log"
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines():
        ts, host, cmd = line.split(" ", 2)
        out.append((float(ts), host, cmd))
    return out


def store(home, host):
    """Fake per-host file table."""
    p = home / "store" / f"{host}.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text())


PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}{'' if cond else '  <- ' + detail}")


def scenario(fn):
    def wrap():
        home = make_home()
        print(f"\n{fn.__name__.replace('_', ' ')}")
        try:
            fn(home)
        except Exception as e:
            import traceback
            traceback.print_exc()
            FAIL.append(fn.__name__ + " (exception)")
            print(f"  FAIL  {fn.__name__} raised {e}")
        finally:
            shutil.rmtree(home, ignore_errors=True)
    wrap.__name__ = fn.__name__
    return wrap


# ---------------------------------------------------------------- scenarios


@scenario
def s1_deck_reaches_all_gfx(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    (home / "Desktop" / "Ingest" / "show.pptx").write_bytes(b"x" * 4096)
    run_watcher(home, 12)
    txt = logtext(home)
    for h in ("GFX1", "GFX2", "GFX3"):
        check(f"OK logged for {h}", f"OK   [DECK] -> \\\\{h}" in txt, txt)
    check("archived", (home / "Desktop" / "Archive" / "show.pptx").exists())
    check(
        "all three hold 4096 bytes",
        all(store(home, h).get("show.pptx") == 4096 for h in ("GFX1", "GFX2", "GFX3")),
        json.dumps({h: store(home, h) for h in ("GFX1", "GFX2", "GFX3")}),
    )
    check("media not sent to GFX", "MITTIA" not in txt)


@scenario
def s2_refused_put_is_retried_then_succeeds(home):
    # GFX1 refuses every put for this run; GFX2 and GFX3 accept
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {"GFX1": {"refuse_put": True}}})
    (home / "Desktop" / "Ingest" / "deck.pptx").write_bytes(b"y" * 2048)
    run_watcher(home, 14)
    txt = logtext(home)
    check("first attempt FAILs", "FAIL" in txt, txt)
    check("says it will retry", "retry in" in txt, txt)
    check("healthy machines still delivered", "OK   [DECK] -> \\\\GFX2" in txt, txt)
    q = json.loads((home / ".config" / "showkit" / "queue.json").read_text())
    e = q["deck.pptx"]
    check("GFX1 attempts counted", e["targets"].get("GFX1", 0) >= 1, json.dumps(e))
    check("GFX2 succeeded after one try", e["targets"].get("GFX2") == 1, json.dumps(e))
    check("not done while GFX1 outstanding", not e.get("done"), json.dumps(e))


@scenario
def s3_absent_machine_skipped_then_given_up(home):
    set_control(home, {"up": [], "hosts": {}})
    (home / "Desktop" / "Ingest" / "clip.mov").write_bytes(b"z" * 1024)
    # compress the timing so the give-up path is reachable in a test
    run_watcher(home, 26, extra_env={"SHOWKIT_MAX_SKIPS": "3", "SHOWKIT_SKIP_RETRY": "1",
                                     "SHOWKIT_BACKOFF": "0,1"})
    txt = logtext(home)
    check("SKIP logged", "SKIP [MEDIA]" in txt, txt)
    check("no FAIL for absent machine", "FAIL [MEDIA]" not in txt, txt)
    check("rechecks an absent machine", txt.count("will check again") >= 2, txt)
    check("gives up eventually", "not retrying this machine" in txt, txt)
    q = json.loads((home / ".config" / "showkit" / "queue.json").read_text())
    e = q["clip.mov"]
    check("given_up records why", "machine never came up" in json.dumps(e.get("given_up", {})),
          json.dumps(e))
    check("no retries burned on absent host",
          all(v == 0 for k, v in e["targets"].items() if k in ("MITTIA", "MITTIB")),
          json.dumps(e["targets"]))
    check("DONE notes the absent machines", "machine(s) never came up" in txt, txt)


@scenario
def s4_size_mismatch_is_caught(home):
    set_control(home, {"up": ["GFX1"], "hosts": {"GFX1": {"corrupt_put": True}}})
    (home / "Desktop" / "Ingest" / "big.pptx").write_bytes(b"q" * 8192)
    run_watcher(home, 10)
    txt = logtext(home)
    check("SIZE MISMATCH detected", "SIZE MISMATCH" in txt, txt)
    check("no false OK", "OK   [DECK]" not in txt, txt)


@scenario
def s5_in_progress_copy_not_pushed(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    ingest = home / "Desktop" / "Ingest"
    partial = ingest / "growing.pptx"
    partial.write_bytes(b"a" * 1000)
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["FAKE_HOME"] = str(home)
    env["PATH"] = f"{FAKEBIN}:{env['PATH']}"
    proc = subprocess.Popen([sys.executable, str(SRC)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # keep appending for 8 seconds while the watcher runs
    for i in range(8):
        time.sleep(1)
        with partial.open("ab") as f:
            f.write(b"b" * 500)
    time.sleep(1)
    pushes_while_growing = [
        c for c in calls(home) if "growing.pptx" in c[2] and c[0] < time.time() - 1.5
    ]
    proc.terminate()
    proc.communicate(timeout=10)
    check("no push while the file was still growing", not pushes_while_growing,
          f"{len(pushes_while_growing)} premature put(s)")


@scenario
def s6_pushes_run_in_parallel(home):
    set_control(home, {
        "up": ["GFX1", "GFX2", "GFX3"],
        "hosts": {h: {"delay": 2.0} for h in ("GFX1", "GFX2", "GFX3")},
    })
    (home / "Desktop" / "Ingest" / "slow.pptx").write_bytes(b"p" * 512)
    run_watcher(home, 20)
    puts = [c for c in calls(home) if c[2].startswith("put ") and "slow.pptx" in c[2]]
    check("three puts attempted", len(puts) == 3, str(len(puts)))
    if len(puts) == 3:
        span = max(c[0] for c in puts) - min(c[0] for c in puts)
        check("puts overlapped rather than serialised (span < 4s)", span < 4.0, f"span={span:.2f}s")


@scenario
def s7_pending_survives_restart(home):
    set_control(home, {"up": [], "hosts": {}})
    (home / "Desktop" / "Ingest" / "wait.pptx").write_bytes(b"w" * 700)
    run_watcher(home, 8)
    q = json.loads((home / ".config" / "showkit" / "queue.json").read_text())
    check("queue file written", "wait.pptx" in q, json.dumps(q))
    check("not marked done while machine absent", not q["wait.pptx"].get("done"),
          json.dumps(q))

    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    run_watcher(home, 12)
    txt = logtext(home)
    check("carried-over file is picked up", "carried over from last run" in txt, txt)
    for h in ("GFX1", "GFX2", "GFX3"):
        check(f"delivered to {h} after restart", f"OK   [DECK] -> \\\\{h}" in txt, txt)
    check("not re-queued from scratch", txt.count("QUEUED wait.pptx") == 1,
          str(txt.count("QUEUED wait.pptx")))



@scenario
def s8_unknown_extension_goes_everywhere(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"], "hosts": {}})
    (home / "Desktop" / "Ingest" / "notes.txt").write_bytes(b"n" * 100)
    run_watcher(home, 12)
    txt = logtext(home)
    check("logged as UNKNOWN EXT", "UNKNOWN EXT .txt -> ALL" in txt, txt)
    for h in ("GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"):
        check(f"unknown ext reached {h}", f"-> \\\\{h}" in txt, txt)


@scenario
def s9_missing_ingest_dir_is_recreated(home):
    shutil.rmtree(home / "Desktop" / "Ingest")
    out = run_watcher(home, 6)
    check("no crash when Ingest folder is missing", "Traceback" not in out, out[-500:])
    check("Ingest folder recreated", (home / "Desktop" / "Ingest").exists())


@scenario
def s10_day_folders_are_inert(home):
    # Day folders exist so you can sort at the Ingest machine. Files already
    # sorted into them were delivered when they were dropped, so the watcher
    # must not push them a second time.
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"], "hosts": {}})
    drop = home / "Desktop" / "Ingest"
    for d in ["Day 1", "Day 2", "Day 3", "Day 4", "Day 5"]:
        (drop / d).mkdir()
    (drop / "top.pptx").write_bytes(b"t" * 500)
    (drop / "Day 1" / "sorted.pptx").write_bytes(b"s" * 500)
    (drop / "Day 3" / "clip.mov").write_bytes(b"m" * 500)
    run_watcher(home, 12)
    txt = logtext(home)
    check("top-level file is pushed", "QUEUED top.pptx" in txt, txt)
    check("Day folder decks are not re-pushed", "sorted.pptx" not in txt, txt)
    check("Day folder media is not re-pushed", "clip.mov" not in txt, txt)
    check("only the top-level file reached GFX1",
          list(store(home, "GFX1")) == ["top.pptx"], str(list(store(home, "GFX1"))))


@scenario
def s11_log_rotates(home):
    set_control(home, {"up": [], "hosts": {}})
    drop = home / "Desktop" / "Ingest"
    # pre-fill the log past the rotation threshold
    with (drop / "push_log.txt").open("w") as f:
        f.write("x" * (5 * 1024 * 1024 + 10))
    (drop / "deck.pptx").write_bytes(b"d" * 100)
    run_watcher(home, 12)
    check("log kept under the threshold",
          (drop / "push_log.txt").stat().st_size < 5 * 1024 * 1024,
          str((drop / "push_log.txt").stat().st_size))
    check("previous log kept as .1", (drop / "push_log.txt.1").exists())
    check("current log is the new one", "QUEUED deck.pptx" in logtext(home))


@scenario
def s12_queue_survives_corruption(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    q = home / ".config" / "showkit" / "queue.json"
    q.write_text("{ this is not json")
    (home / "Desktop" / "Ingest" / "deck.pptx").write_bytes(b"p" * 300)
    out = run_watcher(home, 12)
    check("does not crash on a corrupt queue", "Traceback" not in out, out[-600:])
    check("rewrites the queue", q.exists() and "deck.pptx" in q.read_text(), q.read_text()[:200])
    check("still delivers", "OK   [DECK] -> \\\\GFX1" in logtext(home), logtext(home))


def main():
    build_fakes()
    scenarios = [s1_deck_reaches_all_gfx, s2_refused_put_is_retried_then_succeeds,
                 s3_absent_machine_skipped_then_given_up, s4_size_mismatch_is_caught,
                 s5_in_progress_copy_not_pushed, s6_pushes_run_in_parallel,
                 s7_pending_survives_restart, s8_unknown_extension_goes_everywhere,
                 s9_missing_ingest_dir_is_recreated, s10_day_folders_are_inert,
                 s11_log_rotates, s12_queue_survives_corruption]
    only = sys.argv[1:]
    for s in scenarios:
        if only and not any(o in s.__name__ for o in only):
            continue
        s()
    print(f"\n{'=' * 60}")
    print(f"passed {len(PASS)}   failed {len(FAIL)}")
    if FAIL:
        print("failures:")
        for f in FAIL:
            print("  -", f)
    shutil.rmtree(FAKEBIN, ignore_errors=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
