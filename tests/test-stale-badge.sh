#!/usr/bin/env bash
# The bar icon says when applications are still showing the previous theme:
# it takes the theme's urgent color, as Omarchy's agents widget does when a
# limit is near, with a small raised count. The service keeps the list in
# status.json -- after each sync, and on every window event -- and the panel
# watches the file, so the count follows an application being closed without
# anything polling. Rendered and checked in a sandboxed shell; these pin it.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import json, os, sys, tempfile, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / "run"))
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

S = root / "state"; S.mkdir()
status = S / "status.json"
def recorded():
    return json.loads(status.read_text()).get("staleApps") if status.exists() else None

st.record_stale_apps(S, [])
chk("nothing stale and no status yet: no status file is made just to say so", status.exists(), False)
status.write_text(json.dumps({"theme": "x", "darkReader": "synchronized"}))
st.record_stale_apps(S, ["Signal", "Nautilus"])
chk("the list is kept in status.json, in order", recorded(), ["Nautilus", "Signal"])
chk("...beside what was there", json.loads(status.read_text())["darkReader"], "synchronized")
inode = status.stat().st_ino
st.record_stale_apps(S, ["Nautilus", "Signal"])
chk("the same list again does not rewrite the file", status.stat().st_ino, inode)
st.record_stale_apps(S, ["Nautilus"])
chk("one closed: the list shrinks", recorded(), ["Nautilus"])
st.record_stale_apps(S, [])
chk("all closed: it empties rather than disappearing", recorded(), [])

# The daemon's pass keeps it current on every window event.
calls = []
st.refresh_idle_apps = lambda since=None: None
st.clear_app_color_schemes = lambda state_dir: None
st.resume_browsers = lambda *a: None
st.event_trigger = lambda state_dir: ("same",)
stale = ["Vivaldi"]
st.stale_open_apps = lambda since=None: list(stale)
memory = {"trigger": ("same",), "checked": 10**12}
st.event_work(S, S, memory)
chk("a window event records who is still on the previous theme", recorded(), ["Vivaldi"])
stale.clear()
st.event_work(S, S, memory)
chk("...and the one after it is closed drops it", recorded(), [])
def broken(since=None):
    raise RuntimeError("no window list")
st.stale_open_apps = broken
work, trigger = st.event_work(S, S, memory)
chk("a count that cannot be worked out costs no whole sync: it is display only",
    (work, trigger), ([], None))
st.stale_open_apps = lambda since=None: list(stale)

# A sync records the list it reports, under its lock; asking for the list
# alone, as the panel does, records nothing.
stale[:] = ["Helium"]
out = []
st.print = lambda *a, **k: out.append(a)
sys.argv = ["hyprchroma-state", "--state-dir", str(S), "--data-dir", str(S), "report-stale-apps", "--since-last-sync"]
st.main()
chk("asking for the list does not write it", recorded(), [])
sys.argv += ["--record"]
st.main()
chk("the sync's --record does", recorded(), ["Helium"])
E

cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
chk "the sync's own report records the list" \
  "$(grep -c 'report-stale-apps --record 2>' bin/hyprchroma)" "1"
chk "the panel watches status.json for it, rather than polling" \
  "$(grep -c 'path: root.statusPath' Panel.qml),$(awk '/id: statusFile/,/^  }/' Panel.qml | grep -c 'watchChanges: true')" "1,1"
chk "the icon turns the theme's urgent color while any are left" \
  "$(grep -c 'active: root.staleCount > 0' BarWidget.qml)" "1"
chk "...with a count raised beside it in that same color" \
  "$(awk '/id: staleBadge/,/^  }/' BarWidget.qml | grep -cE 'color: button.activeColor|visible: root.staleCount > 0')" "2"
chk "...drawn as the shell draws the glyph, so it is not color-fringed" \
  "$(awk '/id: staleBadge/,/^  }/' BarWidget.qml | grep -c 'renderType: Text.NativeRendering')" "1"
chk "...and capped at 9+ so it fits the icon's slot" \
  "$(grep -c 'root.staleCount > 9 ? "9+"' BarWidget.qml)" "1"

# -- one baseline: the moment the theme last changed ---------------------------
python3 - "$REPO" <<'E'
import json, os, sys, tempfile, time, types
from datetime import datetime, timezone
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / "run"))
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))
iso = lambda epoch: datetime.fromtimestamp(epoch, timezone.utc).isoformat()

S = root / "state"; S.mkdir()
T = int(time.time()) - 1000
# Vivaldi open before the theme changed; VS Code opened a minute after it.
windows = [("Vivaldi", "vivaldi-stable", 101), ("Code", "code", 202)]
started = {101: T - 100, 202: T + 60}
st.open_windows = lambda: list(windows)
st.process_started_at = lambda pid: started.get(pid)
st.window_executable = lambda pid: {101: "vivaldi-bin", 202: "code"}.get(pid)
st.omarchy_reloaded_executables = lambda: set()
st.gtk_portal_pids = lambda: set()

(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(T), "lastSync": iso(T)}))
chk("after a theme change, what was open then is stale", st.stale_open_apps(st.stale_baseline(S)), ["Vivaldi-stable"])
# A sync that changes nothing -- a Dark Reader retry while the browser is open --
# moves lastSync and nothing else.
(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(T), "lastSync": iso(T + 500)}))
chk("a later sync that changed nothing does not make what opened since stale",
    st.stale_open_apps(st.stale_baseline(S)), ["Vivaldi-stable"])
windows.pop(0)
chk("...and closing the stale app empties the list", st.stale_open_apps(st.stale_baseline(S)), [])

st.mark_theme_changed(S)
chk("a revert marks a change now, so what is open then counts",
    abs(st.theme_changed_at(S) - int(time.time())) < 5, True)
(S / "status.json").write_text(json.dumps({"lastSync": iso(T)}))
chk("a status file from before the stored baseline falls back to its lastSync",
    st.theme_changed_at(S), T)
chk("the baseline allows for an app launched while the change was written",
    st.stale_baseline(S), T - st.LAUNCH_GRACE_SECONDS)

# -- what Omarchy re-themes itself, read from its code, not its comments -------
fake = root / "omarchy/bin"; fake.mkdir(parents=True)
(fake / "omarchy-theme-set").write_text("#!/bin/bash\n# themes can run code\nomarchy-theme-set-foo\n")
(fake / "omarchy-theme-set-foo").write_text("#!/bin/bash\nfoo --reload-theme  # tells foo\n")
(fake / "omarchy-restart-bar").write_text("#!/bin/bash\npkill -USR2 bar\n")
real = types.ModuleType("real"); real.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "real", "exec"), real.__dict__)
real.OMARCHY_PACKAGED_BIN = fake
os.environ.pop("OMARCHY_PATH", None)
real.running_executables = lambda: {"code", "foo", "bar", "tells"}
chk("apps Omarchy re-themes are read from its theme scripts, comments ignored",
    sorted(real.omarchy_reloaded_executables()), ["bar", "foo"])
os.environ["OMARCHY_PATH"] = str(root / "elsewhere")
chk("...and the same whatever OMARCHY_PATH the asker has", sorted(real.omarchy_reloaded_executables()), ["bar", "foo"])
E
