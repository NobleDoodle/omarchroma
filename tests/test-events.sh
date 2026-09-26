#!/usr/bin/env bash
# A window opening or closing is handled in the daemon's own process: idle
# applications recycled, color scheme pins cleared, and a whole sync started
# only when something it compares may have changed. It used to start a whole
# quiet sync -- a shell, the palette resolved through Omarchy, and several more
# interpreters, more than a second of work -- on every window event, to find
# nearly every time that nothing had. Everything here runs against a throwaway
# home; nothing is quit, written outside it, or started for real.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import json, os, sys, tempfile, time, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ["HOME"] = str(root)
os.environ["XDG_RUNTIME_DIR"] = str(root / "run")
os.environ.pop("XDG_CONFIG_HOME", None)
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

S, D = root / ".local/state/hyprchroma", root / ".local/share/hyprchroma"
S.mkdir(parents=True); D.mkdir(parents=True)
theme = root / ".local/state/omarchy/current/theme"
theme.mkdir(parents=True)
(theme / "colors.toml").write_text('background = "#111111"\n')
(theme.parent / "theme.name").write_text("test\n")

# Every side effect is recorded, never performed.
calls = []
st.refresh_idle_apps = lambda since=None: calls.append("refresh")
st.clear_app_color_schemes = lambda state_dir: calls.append("clear")
st.resume_browsers = lambda *a: calls.append("resume")
dark_reader = types.SimpleNamespace(signature="helium:/a")
st.dark_reader_module = lambda: types.SimpleNamespace(
    dark_reader_targets=lambda: [], targets_signature=lambda targets: dark_reader.signature)
ran, spawned, exit_codes = [], [], []
def run(command, check=False):
    ran.append(command[-1])
    return types.SimpleNamespace(returncode=exit_codes.pop(0) if exit_codes else 0)
st.subprocess = types.SimpleNamespace(
    run=run, Popen=lambda command, **k: spawned.append(command[-1]), DEVNULL=None, PIPE=None)
st.kde_color_client_pids = lambda: []
st.stale_open_apps = lambda since=None: []

memory = {}
def event():
    calls.clear(); ran.clear(); spawned.clear()
    return st.event_pass(S, D, memory)

# -- the per-event work, and a whole sync only when something moved ----------
chk("the first event after starting compares everything once", (event(), ran), (True, ["--quiet"]))
chk("...and clears pins and recycles idle applications itself", calls[:2], ["clear", "refresh"])
chk("with nothing changed, the next event starts no sync at all", (event(), ran), (True, []))
chk("...while still recycling what the closed window left idle", "refresh" in calls, True)

(theme / "colors.toml").write_text('background = "#222222"\n')
chk("the palette's source file changing starts a sync", (event(), ran), (True, ["--quiet"]))
chk("...once", (event(), ran), (True, []))
(S / "settings.json").write_text(json.dumps({"frameworks": {"pear": False}}))
chk("the settings changing starts one", (event(), ran), (True, ["--quiet"]))
dark_reader.signature = "helium:/a;firefox:/b"
chk("Dark Reader added to another browser starts one", (event(), ran), (True, ["--quiet"]))
(root / ".config/YouTube Music").mkdir(parents=True)
chk("Pear Desktop appearing starts one", (event(), ran), (True, ["--quiet"]))
(root / ".config/hyprchroma").mkdir(parents=True)
(root / ".config/hyprchroma/palette.toml").write_text('background = "#333333"\n')
chk("a palette file appearing starts one", (event(), ran), (True, ["--quiet"]))

memory["checked"] -= st.FULL_CHECK_SECONDS + 1
chk("however little seems to change, a whole check runs within FULL_CHECK_SECONDS",
    (event(), ran), (True, ["--quiet"]))

exit_codes.append(1)
(theme.parent / "theme.name").write_text("other\n")
event()
chk("a sync that failed is compared again at the next event, not remembered as done",
    (event(), ran), (True, ["--quiet"]))

(S / "settings.json").write_text(json.dumps({"frameworks": {"qtKde": False}}))
event()
chk("with Qt/KDE off, pins are left alone", (event(), calls[:1]), (True, ["refresh"]))
(S / "settings.json").write_text(json.dumps({"frameworks": {}}))
event()

# -- a sync holding the lock: retried, never dropped --------------------------
held = st.try_lock(st.runtime_dir(S) / "hyprchroma-sync.lock")
chk("with a sync holding the lock the pass reports it, to be retried", event(), False)
chk("...and touches nothing while that sync works", (calls, ran), ([], []))
held.close()
chk("once free, the retry does the work", (event(), "refresh" in calls), (True, True))

# -- work left waiting is restarted only when its waiter is gone --------------
(S / "status.json").write_text(json.dumps({"qtKde": "deferred", "darkReader": "pending-browser-exit"}))
chk("deferred Qt/KDE and pending Dark Reader with no waiters: each waiter is restarted",
    (event(), sorted(spawned), ran), (True, ["watch-browser-exit", "watch-kde-exit"], []))
kde = st.try_lock(st.runtime_dir(S) / "hyprchroma-kde-wait.lock")
browser = st.try_lock(st.runtime_dir(S) / "hyprchroma-browser-wait.lock")
chk("...and with their waiters alive, nothing is started, as no whole sync is",
    (event(), spawned, ran), (True, [], []))
kde.close(); browser.close()
(S / "status.json").write_text(json.dumps({}))
chk("outstanding browser work is resumed in the pass when its waiter is gone",
    (event(), "resume" in calls), (True, True))
browsers = st.try_lock(st.runtime_dir(S) / "hyprchroma-browsers-wait.lock")
chk("...and left to its waiter when that is alive", (event(), "resume" in calls), (True, False))
browsers.close()

# -- a pass that fails still does what a quiet sync did -----------------------
st.refresh_idle_apps = lambda since=None: (_ for _ in ()).throw(RuntimeError("boom"))
chk("a pass that raises falls back to a whole quiet sync", (event(), ran), (True, ["--quiet"]))

# -- the pieces it relies on ----------------------------------------------------
chk("an event is acted on within half a second", st.EVENT_DEBOUNCE_SECONDS <= 0.5, True)

# Recording, not writing: an unchanged manifest is not rewritten.
S2 = root / "clear"; (S2 / "original").mkdir(parents=True)
src = open(helper).read()
fresh = types.ModuleType("fresh"); fresh.__dict__["__file__"] = helper
exec(compile(src, "fresh", "exec"), fresh.__dict__)
fresh.running_executables = lambda: set()
fresh.clear_app_color_schemes(S2)
manifest = S2 / "original/manifest.json"
first = manifest.stat().st_ino if manifest.exists() else None
fresh.clear_app_color_schemes(S2)
chk("clearing pins with none to clear does not rewrite the manifest",
    (manifest.exists(), manifest.stat().st_ino == first), (True, True))
fresh.snapshot(S2, S2, "qt-kde")
inode = manifest.stat().st_ino
fresh.snapshot(S2, S2, "qt-kde")
chk("a snapshot with everything already captured does not rewrite it either",
    manifest.stat().st_ino, inode)

# busctl: one listing for the pass, validated, or gdbus as before.
listing = json.dumps([
    {"name": "org.gnome.Nautilus", "pid": 41}, {"name": ":1.12", "pid": 42},
    {"name": "../../evil", "pid": 43}, {"name": "org.example.Gone", "pid": None}])
activatable = json.dumps([{"name": "org.gnome.Nautilus", "pid": None}, {"name": "bad/name", "pid": None}])
answers = {(): listing, ("--activatable",): activatable}
fresh.subprocess.run = lambda command, **k: types.SimpleNamespace(
    returncode=0, stdout=answers[tuple(command[4:])])
chk("busctl's listing gives each well-known name its PID, and only those",
    fresh.bus_listing(), ({"org.gnome.Nautilus": 41}, {"org.gnome.Nautilus"}))
fresh.subprocess.run = lambda command, **k: types.SimpleNamespace(returncode=1, stdout="")
chk("busctl failing gives no listing, so each question goes to gdbus", fresh.bus_listing(), None)

# The quit action asked once per process, not on every event.
asked = []
def bus_call(name, path, method):
    asked.append(name)
    return {"org.a.NoQuit": "([],)", "org.a.Quits": "(['quit'],)"}.get(name)
fresh.bus_call = bus_call
for _ in range(3):
    fresh.has_quit_action("org.a.NoQuit", "/", 10)
    fresh.has_quit_action("org.a.Quits", "/", 11)
    fresh.has_quit_action("org.a.Broken", "/", 12)
chk("a process with no quit action is asked once, one with one each time it matters",
    (asked.count("org.a.NoQuit"), asked.count("org.a.Quits")), (1, 3))
chk("...and one whose call failed is not asked again for a while", asked.count("org.a.Broken"), 1)
fresh._NO_QUIT_ACTION[("org.a.Broken", 12)] -= fresh.NO_ACTIONS_RECHECK_SECONDS + 1
fresh.has_quit_action("org.a.Broken", "/", 12)
chk("...but is asked again once that has passed", asked.count("org.a.Broken"), 2)
chk("a new process under the same name is asked afresh",
    (fresh.has_quit_action("org.a.NoQuit", "/", 99), asked.count("org.a.NoQuit")), (False, 2))
E

# -- the loop itself, against a stand-in for Hyprland's event socket ----------
python3 - "$REPO" <<'E'
import os, socket, sys, tempfile, threading, time, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / "run"), HYPRLAND_INSTANCE_SIGNATURE="test")
stream_dir = root / "run/hypr/test"
stream_dir.mkdir(parents=True)
os.chmod(root / "run", 0o700)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(stream_dir / ".socket2.sock"))
server.listen(1)
start = {}
def hyprland():
    connection, _ = server.accept()
    start["at"] = time.monotonic()
    def at(offset, *lines):
        time.sleep(max(0, start["at"] + offset - time.monotonic()))
        connection.sendall(b"".join(line + b"\n" for line in lines))
    at(0.0, b"openwindow>>a,1,foot,foot")
    at(1.0, *[b"openwindow>>b%d,1,foot,foot" % n for n in range(5)])
    at(2.0, b"closewindow>>c")
    at(3.0, b"activewindow>>foot,foot", b"workspace>>2")
    time.sleep(max(0, start["at"] + 3.6 - time.monotonic()))
    connection.close()
threading.Thread(target=hyprland, daemon=True).start()

passes, answers = [], [True, True, False, True]
def event_pass(state_dir, data_dir, memory):
    passes.append(round(time.monotonic() - start["at"], 2))
    return answers.pop(0) if answers else True
st.event_pass = event_pass
(root / "state").mkdir()
st.watch_events(root / "state", root / "data")

expected = [0.3, 1.3, 2.3, 2.8]
chk("one event is acted on a debounce later; a burst of five, once",
    len(passes), len(expected))
chk("...each within 0.15 s of when it should be: " + ", ".join(map(str, passes)),
    all(abs(got - want) < 0.15 for got, want in zip(passes, expected)), True)
chk("a pass that found the lock held is retried EVENT_RETRY_SECONDS later, not dropped",
    passes[3:] and round(passes[3] - passes[2], 1), st.EVENT_RETRY_SECONDS)
chk("events other than a window opening or closing start nothing", passes[4:], [])
E
