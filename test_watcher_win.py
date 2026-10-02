#!/usr/bin/env python3
"""
Offline harness for the Windows INGEST watcher (show-watcher.ps1).

The rig's watcher is written in Python, so this harness borrows its fake
ping/smbclient pair, fakes the SMB store on disk, and runs show-watcher.ps1
under pwsh against a throwaway "USERPROFILE". Same nine behaviours, plus the
ones that are specific to the Windows path.

Skipped (with a clear notice) when pwsh is not installed, since the rig only
ever runs this on Windows.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WATCHER = HERE / "show-watcher.ps1"
FAKEBIN = HERE / "testbin-win"
STORE = "store"

PWSH = shutil.which("pwsh") or shutil.which("powershell")

FAKE_PING = '''#!/usr/bin/env python3
import json, os, sys
host = sys.argv[-1]
up = json.load(open(os.path.join(os.environ["FAKE_HOME"], "control.json"))).get("up", [])
sys.exit(0 if host in up else 1)
'''

# The watcher imports ThreadJob; pwsh ships it in the same tree, but make sure
# the module is available before anything else runs.
PRELUDE_IMPORTS = "Import-Module ThreadJob -ErrorAction Stop\n"

FAKE_SMBCLIENT = '''#!/usr/bin/env python3
import json, os, re, sys, time
home = os.environ["FAKE_HOME"]
ctl = json.load(open(os.path.join(home, "control.json")))
# PowerShell builds the UNC as \\\\HOST\\ShowShare, so strip both separators
host = re.split(r"[/\\\\]", sys.argv[1].strip("/\\\\"))[0]
cmd = sys.argv[sys.argv.index("-c") + 1]
with open(os.path.join(home, "smbcalls.log"), "a") as f:
    f.write("%.3f %s %s\\n" % (time.time(), host, cmd))

store = os.path.join(home, "store", host + ".json")
hostctl = ctl.get("hosts", {}).get(host, {})
files = json.load(open(store)) if os.path.exists(store) else {}

def save():
    os.makedirs(os.path.join(home, "store"), exist_ok=True)
    json.dump(files, open(store, "w"))

if hostctl.get("delay"):
    time.sleep(hostctl["delay"])

if cmd.strip() == "ls":
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

PWSH_PRELUDE = r'''
$ErrorActionPreference = "Stop"
Import-Module ThreadJob -ErrorAction Stop
# The watcher builds its paths from Windows conventions; point them at the
# throwaway tree so this runs on Linux pwsh too.
$prof     = $env:FAKE_USERPROFILE
$env:USERPROFILE  = $prof
$env:LOCALAPPDATA = Join-Path $prof "AppData\Local"
$env:SHOWKIT_CONFIG  = Join-Path $env:LOCALAPPDATA "showkit"
$env:SHOWKIT_DROP    = Join-Path $prof "Desktop/Ingest"
$env:SHOWKIT_ARCHIVE = Join-Path $prof "Desktop/Archive"
foreach ($d in @($env:LOCALAPPDATA, $env:SHOWKIT_CONFIG, $env:SHOWKIT_DROP, $env:SHOWKIT_ARCHIVE)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
Set-Content -LiteralPath (Join-Path $env:SHOWKIT_CONFIG "smbcreds") -Value "username=show`npassword=x" -NoNewline
Set-Content -LiteralPath (Join-Path $env:SHOWKIT_CONFIG "smbcreds-mitti") -Value "username=mac`npassword=x" -NoNewline
'''

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}{'' if cond else '  <- ' + detail}")


def build_fakes():
    FAKEBIN.mkdir(exist_ok=True)
    for name, body in (("ping", FAKE_PING), ("smbclient", FAKE_SMBCLIENT)):
        p = FAKEBIN / name
        p.write_text(body)
        p.chmod(0o755)


def make_home():
    home = Path(tempfile.mkdtemp(prefix="showkit-win-"))
    (home / "control.json").write_text(json.dumps({"up": [], "hosts": {}}))
    return home


def control(home):
    return json.loads((home / "control.json").read_text())


def set_control(home, data):
    (home / "control.json").write_text(json.dumps(data))


def run_watcher(home, seconds, env_extra=None, prelude=""):
    profile = home / "profile"
    profile.mkdir(exist_ok=True)
    script = PWSH_PRELUDE + prelude
    runner = home / "run.ps1"
    runner.write_text(script + f"\n& '{WATCHER}'\n")
    env = dict(os.environ)
    env["FAKE_HOME"] = str(home)
    env["FAKE_USERPROFILE"] = str(profile)
    env["PATH"] = f"{FAKEBIN}:{env['PATH']}"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen([PWSH, "-NoProfile", "-File", str(runner)],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = proc.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            out, _ = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
    return out


def logtext(home):
    p = home / "profile" / "Desktop" / "Ingest" / "push_log.txt"
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
    p = home / STORE / f"{host}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def queue(home):
    p = home / "profile" / "AppData" / "Local" / "showkit" / "queue.json"
    return json.loads(p.read_text()) if p.exists() else {}


SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


@scenario
def s1_deck_reaches_all_gfx(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "show.pptx").write_bytes(b"x" * 4096)
    out = run_watcher(home, 40)
    txt = logtext(home)
    for h in ("GFX1", "GFX2", "GFX3"):
        check(f"OK logged for {h}", f"OK   [DECK] -> \\\\{h}" in txt, txt or out[-800:])
    check("archived", (home / "profile" / "Desktop" / "Archive" / "show.pptx").exists())
    check("all three hold 4096 bytes",
          all(store(home, h).get("show.pptx") == 4096 for h in ("GFX1", "GFX2", "GFX3")),
          json.dumps({h: store(home, h) for h in ("GFX1", "GFX2", "GFX3")}))
    check("media hosts untouched", "MITTIA" not in txt, txt)


@scenario
def s2_refused_put_is_retried(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {"GFX1": {"refuse_put": True}}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "deck.pptx").write_bytes(b"y" * 2048)
    out = run_watcher(home, 40)
    txt = logtext(home)
    check("first attempt FAILs", "FAIL" in txt, txt or out[-800:])
    check("says it will retry", "retry in" in txt, txt)
    check("healthy machines still delivered", "OK   [DECK] -> \\\\GFX2" in txt, txt)
    e = queue(home).get("deck.pptx", {})
    check("GFX1 attempts counted", e.get("targets", {}).get("GFX1", 0) >= 1, json.dumps(e))
    check("GFX2 succeeded after one try", e.get("targets", {}).get("GFX2") == 1, json.dumps(e))
    check("not done while GFX1 outstanding", not e.get("done"), json.dumps(e))


@scenario
def s3_absent_machine_skipped(home):
    set_control(home, {"up": [], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "clip.mov").write_bytes(b"z" * 1024)
    out = run_watcher(home, 45)
    txt = logtext(home)
    check("SKIP logged", "SKIP [MEDIA]" in txt, txt or out[-800:])
    check("no FAIL for absent machine", "FAIL [MEDIA]" not in txt, txt)
    e = queue(home).get("clip.mov", {})
    check("no retries burned on absent host",
          all(v == 0 for k, v in e.get("targets", {}).items() if k in ("MITTIA", "MITTIB")),
          json.dumps(e.get("targets")))


@scenario
def s4_size_mismatch_is_caught(home):
    set_control(home, {"up": ["GFX1"], "hosts": {"GFX1": {"corrupt_put": True}}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "big.pptx").write_bytes(b"q" * 8192)
    out = run_watcher(home, 40)
    txt = logtext(home)
    check("SIZE MISMATCH detected", "SIZE MISMATCH" in txt, txt or out[-800:])
    check("no false OK", "OK   [DECK]" not in txt, txt)


@scenario
def s5_in_progress_copy_not_pushed(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    partial = d / "growing.pptx"
    partial.write_bytes(b"a" * 1000)
    profile = home / "profile"
    profile.mkdir(exist_ok=True)
    runner = home / "run.ps1"
    runner.write_text(PWSH_PRELUDE + f"\n& '{WATCHER}'\n")
    env = dict(os.environ)
    env["FAKE_HOME"] = str(home)
    env["FAKE_USERPROFILE"] = str(profile)
    env["PATH"] = f"{FAKEBIN}:{env['PATH']}"
    proc = subprocess.Popen([PWSH, "-NoProfile", "-File", str(runner)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for _ in range(10):
        time.sleep(1)
        with partial.open("ab") as f:
            f.write(b"b" * 500)
    time.sleep(1)
    premature = [c for c in calls(home) if "growing.pptx" in c[2] and c[0] < time.time() - 1.5]
    proc.terminate()
    try:
        proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
    check("no push while the file was still growing", not premature,
          f"{len(premature)} premature put(s)")


@scenario
def s6_pushes_run_in_parallel(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"],
                       "hosts": {h: {"delay": 3.0} for h in ("GFX1", "GFX2", "GFX3")}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "slow.pptx").write_bytes(b"p" * 512)
    run_watcher(home, 75)
    puts = [c for c in calls(home) if c[2].startswith("put ") and "slow.pptx" in c[2]]
    check("three puts attempted", len(puts) == 3, str(len(puts)))
    if len(puts) == 3:
        span = max(c[0] for c in puts) - min(c[0] for c in puts)
        check("puts overlapped rather than serialised (span < 6s)", span < 6.0, f"span={span:.2f}s")


@scenario
def s7_pending_survives_restart(home):
    set_control(home, {"up": [], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "wait.pptx").write_bytes(b"w" * 700)
    run_watcher(home, 40)
    e = queue(home).get("wait.pptx", {})
    check("queue file written", "wait.pptx" in queue(home), json.dumps(list(queue(home))))
    check("not marked done while machine absent", not e.get("done"), json.dumps(e))

    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    out = run_watcher(home, 45)
    txt = logtext(home)
    check("carried-over file is picked up", "carried over from last run" in txt,
          txt or out[-800:])
    for h in ("GFX1", "GFX2", "GFX3"):
        check(f"delivered to {h} after restart", f"OK   [DECK] -> \\\\{h}" in txt, txt)
    check("not re-queued from scratch", txt.count("QUEUED wait.pptx") == 1,
          str(txt.count("QUEUED wait.pptx")))


@scenario
def s8_unknown_extension_goes_everywhere(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    (d / "notes.txt").write_bytes(b"n" * 100)
    out = run_watcher(home, 60)
    txt = logtext(home)
    check("logged as UNKNOWN EXT", "UNKNOWN EXT .txt -> ALL" in txt, txt or out[-800:])
    for h in ("GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"):
        check(f"unknown ext reached {h}", f"-> \\\\{h}" in txt, txt)


@scenario
def s9_missing_ingest_dir_is_recreated(home):
    out = run_watcher(home, 25)
    check("no crash when Ingest folder is missing",
          "Traceback" not in out and "JoinPath" not in out, out[-600:])
    check("Ingest folder recreated", (home / "profile" / "Desktop" / "Ingest").exists())


@scenario
def s10_day_folders_are_inert(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3", "MITTIA", "MITTIB"], "hosts": {}})
    drop = home / "profile" / "Desktop" / "Ingest"
    drop.mkdir(parents=True, exist_ok=True)
    for d in ["Day 1", "Day 2", "Day 3", "Day 4", "Day 5"]:
        (drop / d).mkdir(exist_ok=True)
    (drop / "top.pptx").write_bytes(b"t" * 500)
    (drop / "Day 1" / "sorted.pptx").write_bytes(b"s" * 500)
    (drop / "Day 3" / "clip.mov").write_bytes(b"m" * 500)
    run_watcher(home, 45)
    txt = logtext(home)
    check("top-level file is pushed", "QUEUED top.pptx" in txt, txt)
    check("Day folder decks are not re-pushed", "sorted.pptx" not in txt, txt)
    check("Day folder media is not re-pushed", "clip.mov" not in txt, txt)


@scenario
def s12_given_up_file_rearms_when_recopied(home):
    """Port of the Python s13: a GIVE UP file must not spin, and must re-arm once
    its mtime moves. Both watchers share this behaviour, so both are held to it."""
    # all three GFX up so the file can settle; GFX1 refuses every put
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {"GFX1": {"refuse_put": True}}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    f = d / "stuck.pptx"
    f.write_bytes(b"s" * 4096)
    prelude = "$env:SHOWKIT_BACKOFF = '0,0,0,0,0,0,0,0'\n"
    run_watcher(home, 60, prelude=prelude)
    txt = logtext(home)
    check("gives up after exhausting attempts", "GIVE UP stuck.pptx" in txt, txt[-700:])
    check("says how to retry", "re-copy" in txt, txt[-400:])
    check("healthy machines still got it", "OK   [DECK] -> \\\\GFX2" in txt, txt[-500:])
    puts = len([c for c in calls(home) if c[1] == "GFX1" and c[2].startswith("put ")])
    check("stopped at 8 attempts, no 9th", puts == 8, f"{puts} puts")

    q = home / "profile" / "AppData" / "Local" / "showkit" / "queue.json"
    entry = json.loads(q.read_text())["stuck.pptx"]
    check("records the timestamp it gave up at", "gave_up_mtime" in entry, json.dumps(entry)[:300])
    check("marked done so it is not picked up again", entry.get("done") is True, json.dumps(entry)[:300])

    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    # re-copy the file: a fresh mtime is the operator saying "try that again"
    f.write_bytes(b"s" * 4096)
    os.utime(f, None)
    run_watcher(home, 60, prelude=prelude)
    txt = logtext(home)
    check("re-arms a re-copied file", "RE-ARMED stuck.pptx" in txt, txt[-500:])
    check("re-armed file is delivered again",
          "DONE stuck.pptx" in txt.split("RE-ARMED")[-1], txt.split("RE-ARMED")[-1][-300:])


@scenario
def s11_queue_survives_corruption(home):
    set_control(home, {"up": ["GFX1", "GFX2", "GFX3"], "hosts": {}})
    d = home / "profile" / "Desktop" / "Ingest"
    d.mkdir(parents=True, exist_ok=True)
    q = home / "profile" / "AppData" / "Local" / "showkit" / "queue.json"
    q.parent.mkdir(parents=True, exist_ok=True)
    q.write_text("{ this is not json")
    (d / "deck.pptx").write_bytes(b"p" * 300)
    out = run_watcher(home, 45)
    check("does not crash on a corrupt queue",
          "Traceback" not in out and "ConvertFrom-Json" not in out, out[-800:])
    check("still delivers", "OK   [DECK] -> \\\\GFX1" in logtext(home), logtext(home))


def main():
    if not PWSH:
        print("pwsh not found - install PowerShell 7 to run these tests.")
        print("They exercise show-watcher.ps1, which only ever runs on the rig.")
        return 0
    build_fakes()
    only = sys.argv[1:]
    scenarios = SCENARIOS
    for fn in scenarios:
        if only and not any(o in fn.__name__ for o in only):
            continue
        home = make_home()
        print(f"\n{fn.__name__.replace('_', ' ')}")
        try:
            fn(home)
        except Exception as e:
            import traceback
            traceback.print_exc()
            FAIL.append(fn.__name__)
            print(f"  FAIL  {fn.__name__} raised {e}")
        finally:
            shutil.rmtree(home, ignore_errors=True)
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
