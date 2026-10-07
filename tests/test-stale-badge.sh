#!/usr/bin/env bash
# The bar icon says how many windows are still showing the previous theme:
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

def windows():
    return json.loads(status.read_text()).get("staleWindows")

st.record_stale_apps(S, {})
chk("nothing stale and no status yet: no status file is made just to say so", status.exists(), False)
status.write_text(json.dumps({"theme": "x", "darkReader": "synchronized"}))
st.record_stale_apps(S, {"Signal": 1, "Nautilus": 1})
chk("the list is kept in status.json, in order", recorded(), ["Nautilus", "Signal"])
chk("...beside what was there", json.loads(status.read_text())["darkReader"], "synchronized")
chk("...with each app's window count", windows(), {"Nautilus": 1, "Signal": 1})
inode = status.stat().st_ino
st.record_stale_apps(S, {"Nautilus": 1, "Signal": 1})
chk("the same list again does not rewrite the file", status.stat().st_ino, inode)
st.record_stale_apps(S, {"Nautilus": 1})
chk("one closed: the list shrinks", recorded(), ["Nautilus"])
st.record_stale_apps(S, {"Nautilus": 1, "Vivaldi": 2})
chk("an app with two windows open counts both", windows(), {"Nautilus": 1, "Vivaldi": 2})
st.record_stale_apps(S, {"Nautilus": 1, "Vivaldi": 1})
chk("closing one of them is recorded, though the list of apps is the same",
    (recorded(), windows()), (["Nautilus", "Vivaldi"], {"Nautilus": 1, "Vivaldi": 1}))
st.record_stale_apps(S, {})
chk("all closed: it empties rather than disappearing", (recorded(), windows()), ([], {}))

# The daemon's pass keeps it current on every window event.
calls = []
st.refresh_idle_apps = lambda since=None: None
st.clear_app_color_schemes = lambda state_dir: None
st.resume_browsers = lambda *a: None
st.event_trigger = lambda state_dir: ("same",)
stale = {"Vivaldi": 2}
st.stale_open_windows = lambda since=None: dict(stale)
memory = {"trigger": ("same",), "checked": 10**12}
st.event_work(S, S, memory)
chk("a window event records who is still on the previous theme", (recorded(), windows()),
    (["Vivaldi"], {"Vivaldi": 2}))
stale["Vivaldi"] = 1
st.event_work(S, S, memory)
chk("...one of its windows closing takes the count down", windows(), {"Vivaldi": 1})
stale.clear()
st.event_work(S, S, memory)
chk("...and the last closing drops it", recorded(), [])
def broken(since=None):
    raise RuntimeError("no window list")
st.stale_open_windows = broken
work, trigger = st.event_work(S, S, memory)
chk("a count that cannot be worked out costs no whole sync: it is display only",
    (work, trigger), ([], None))
st.stale_open_windows = lambda since=None: dict(stale)

# A sync records the list it reports, under its lock; asking for the list
# alone, as the panel does, records nothing.
stale.update({"Helium": 1, "Vivaldi": 3})
out = []
st.print = lambda *a, **k: out.append(a)
sys.argv = ["hyprchroma-state", "--state-dir", str(S), "--data-dir", str(S), "report-stale-apps", "--since-last-sync"]
st.main()
chk("asking for the list does not write it", recorded(), [])
chk("it reads one app a line, with its windows where there is more than one",
    [line for (line,) in out], ["Helium", "Vivaldi (3 windows)"])
sys.argv += ["--record"]
st.main()
chk("the sync's --record does", (recorded(), windows()), (["Helium", "Vivaldi"], {"Helium": 1, "Vivaldi": 3}))

# The panel reads that line back when it asks the service itself: the pattern
# it matches, taken from Panel.qml, against what the helper prints.
import re
qml = open(REPO + "/Panel.qml").read()
pattern = re.search(r"var match = /(.*?)/\.exec\(line\)", qml).group(1)
parsed = [re.match(pattern, st.stale_line(name, count)) for name, count in
          [("Vivaldi", 3), ("Helium", 1), ("Visual Studio Code (Insiders)", 2)]]
chk("the panel's pattern reads back what the helper prints",
    [(m.group(1), m.group(2)) if m else None for m in parsed],
    [("Vivaldi", "3"), None, ("Visual Studio Code (Insiders)", "2")])
E

cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
chk "the sync's own report records the list" \
  "$(grep -c 'report-stale-apps --record 2>' bin/hyprchroma)" "1"
chk "the panel watches status.json for it, rather than polling" \
  "$(grep -c 'path: root.statusPath' Panel.qml),$(awk '/id: statusFile/,/^  }/' Panel.qml | grep -c 'watchChanges: true')" "1,1"
chk "the icon turns the theme's urgent color while any are left" \
  "$(grep -c 'active: root.alertCount > 0' BarWidget.qml)" "1"
chk "...counting windows, not applications" \
  "$(grep -c 'panelLoader.item.staleWindowCount$' BarWidget.qml)" "1"
chk "the panel takes each app's windows from status.json, beside the list" \
  "$(awk '/id: statusFile/,/^  }/' Panel.qml | grep -c 'var counts = status.staleWindows')" "1"
chk "...counting one for an app a service older than the counts lists without them" \
  "$(grep -c 'count <= 999 && count === Math.floor(count))' Panel.qml),$(grep -c '      ? count : 1$' Panel.qml)" "1,1"
chk "...totals them for the button, the heading and the restart confirmation" \
  "$(grep -c 'root.windowsPhrase(root.staleWindowCount)' Panel.qml)" "3"
chk "...and puts each app's count beside it, in words so it is not taken for a key" \
  "$(grep -c 'text: root.windowsPhrase(root.windowsOf(staleRow.modelData))' Panel.qml)" "1"
chk "...readable on every theme: the name's color dimmed, not Color.muted, which all but vanished" \
  "$(awk '/id: staleRowWindows/,/^              }/' Panel.qml | sed 's|//.*||' | grep -cE 'color: root.bar \? root.bar.foreground|opacity: 0.7|Color.muted')" "2"
chk "...with a count raised beside it in that same color" \
  "$(awk '/id: staleBadge/,/^  }/' BarWidget.qml | grep -cE 'color: button.activeColor|visible: root.alertCount > 0')" "2"
chk "...drawn as the shell draws the glyph, so it is not color-fringed" \
  "$(awk '/id: staleBadge/,/^  }/' BarWidget.qml | grep -c 'renderType: Text.NativeRendering')" "1"
chk "...and capped at 9+ so it fits the icon's slot" \
  "$(grep -c 'root.alertCount > 9 ? "9+"' BarWidget.qml)" "1"

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
# Two Vivaldi windows open before the theme changed; VS Code opened a minute after it.
windows = [("Vivaldi", "vivaldi-stable", 101), ("Vivaldi", "vivaldi-stable", 101), ("Code", "code", 202)]
started = {101: T - 100, 202: T + 60}
st.open_windows = lambda: list(windows)
st.process_started_at = lambda pid: started.get(pid)
st.window_executable = lambda pid: {101: "vivaldi-bin", 202: "code"}.get(pid)
st.omarchy_reloaded_executables = lambda: set()
st.gtk_portal_pids = lambda: set()

(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(T), "lastSync": iso(T)}))
chk("after a theme change, what was open then is stale, counted by window",
    st.stale_open_windows(st.stale_baseline(S)), {"Vivaldi-stable": 2})
# A sync that changes nothing -- a Dark Reader retry while the browser is open --
# moves lastSync and nothing else.
(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(T), "lastSync": iso(T + 500)}))
chk("a later sync that changed nothing does not make what opened since stale",
    st.stale_open_windows(st.stale_baseline(S)), {"Vivaldi-stable": 2})
windows.pop(0)
chk("...closing one of its windows counts one fewer", st.stale_open_windows(st.stale_baseline(S)),
    {"Vivaldi-stable": 1})
windows.pop(0)
chk("...and closing the last empties the list", st.stale_open_windows(st.stale_baseline(S)), {})

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

# -- a pending service update: the same alert, counted as one -------------------
chk "a service older than the plugin counts as one on the icon, beside any windows" \
  "$(grep -c 'readonly property int alertCount: staleCount + (updatePending ? 1 : 0)' BarWidget.qml)" "1"
chk "...which is the panel's own outdated check" \
  "$(grep -c 'panelLoader.item.outdated === true' BarWidget.qml)" "1"
chk "...and the tooltip says so, with the windows after it" \
  "$(grep -cE '"1 service update pending"|", and "' BarWidget.qml)" "2"
chk "the version is asked as the shell starts, not only when the panel opens" \
  "$(grep -c 'Component.onCompleted: presenceProcess.running = true' Panel.qml)" "1"
chk "...again when the plugin's manifest changes" \
  "$(awk '/id: manifestFile/,/^  }/' Panel.qml | grep -cE 'watchChanges: true|onFileChanged: reload\(\)')" "2"
chk "...and when pacman replaces the service's binary" \
  "$(awk '/id: serviceBinary/,/^  }/' Panel.qml | grep -cE 'path: "/usr/bin/hyprchroma"|watchChanges: true|presenceProcess.running = true')" "3"
chk "the Update button is lit in the urgent color while an update is pending: a fill and a border of it" \
  "$(grep -c 'background: root.outdated ? Util.alpha(alertColor, 0.30) : "transparent"' Panel.qml),$(grep -cE 'border.color: parent.alertColor' Panel.qml)" "1,1"
chk "...drawn by the panel, not the kit's selected state, which a theme may fix to its own color" \
  "$(grep -cE '^\s+selected: root.outdated' Panel.qml)" "0"
