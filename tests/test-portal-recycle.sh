#!/usr/bin/env bash
# The file chooser that Chromium, VS Code and every Flatpak open to save or
# upload is drawn by xdg-desktop-portal-gtk, which starts at login and reads
# the GTK stylesheet once. refresh_idle_apps skipped it on two counts -- its
# bus name is under org.freedesktop., and its dialog's window class never
# matches that name -- so every save dialog kept the login-time palette
# through any number of theme switches, while Nautilus itself looked right.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import os, shutil, subprocess, sys, tempfile, time, types

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

GTK = "org.freedesktop.impl.portal.desktop.gtk"
HYPR = "org.freedesktop.impl.portal.desktop.hyprland"
NOTIFY = "org.freedesktop.Notifications"
PORTAL_PID, HYPR_PID, NOTIFY_PID = 1397, 1505, 1600
THEME_SWITCH = 10_000
BEFORE, AFTER = THEME_SWITCH - 3600, THEME_SWITCH + 60

def scenario(windows, started=BEFORE, binary="/usr/lib/xdg-desktop-portal-gtk",
             exec_line="/usr/lib/xdg-desktop-portal-gtk"):
    """Run refresh_idle_apps against a described session; return who it quit."""
    quit = []
    st.open_windows = lambda: windows
    st.theme_switched_at = lambda: THEME_SWITCH
    st.bus_names = lambda method: {GTK, HYPR, NOTIFY}
    st.connection_pid = lambda name: {GTK: PORTAL_PID, HYPR: HYPR_PID,
                                      NOTIFY: NOTIFY_PID}.get(name)
    st.process_started_at = lambda pid: started if pid == PORTAL_PID else BEFORE
    st.service_file_exec = lambda name: exec_line if name == GTK else None
    st.running_binary = lambda pid: binary if pid == PORTAL_PID else "/usr/bin/other"
    st.has_quit_action = lambda name, path: False
    st.quit_application = lambda pid, name, path: quit.append(name) or True
    st.refresh_idle_apps()
    return quit

# -- the reported case: portal idle, started before the theme switch --------
chk("an idle portal still on the previous palette is recycled",
    scenario(windows=[]), [GTK])

# -- a dialog is open: its window's class is not the bus name, so only the
#    pid can tell that this portal is busy
dialog = [("All Files", "xdg-desktop-portal-gtk", PORTAL_PID)]
chk("a portal with a dialog open is left alone",
    scenario(windows=dialog), [])

# -- the same session once the dialog closes: that window event's run is the
#    one that has to recycle it
chk("...and is recycled by the run after the dialog closes",
    scenario(windows=[]), [GTK])

# -- already started after the switch: it read the current palette
chk("a portal started after the theme switch is left alone",
    scenario(windows=[], started=AFTER), [])

# -- something else holding the name is not the portal the system installed
chk("a process that is not the service file's binary is left alone",
    scenario(windows=[], binary="/home/someone/fake-portal"), [])
chk("a service file naming no trusted binary is left alone",
    scenario(windows=[], exec_line=None), [])

# -- nothing else under org.freedesktop. is ever touched, stale or not ------
quit = scenario(windows=[])
chk("the hyprland portal is never recycled", HYPR in quit, False)
chk("the notification daemon is never recycled", NOTIFY in quit, False)

# -- no window list, no decision: an idle portal cannot be told from a busy one
st.open_windows = lambda: None
quit = []
st.quit_application = lambda pid, name, path: quit.append(name) or True
st.refresh_idle_apps()
chk("without a window list nothing is recycled", quit, [])

# -- the stale-apps report names applications, not a file chooser ----------
st.open_windows = lambda: [("All Files", "xdg-desktop-portal-gtk", PORTAL_PID),
                           ("Files", "org.gnome.Nautilus", 2000)]
st.process_started_at = lambda pid: BEFORE
st.omarchy_reloaded_executables = lambda: set()
st.window_executable = lambda pid: "whatever"
st.connection_pid = lambda name: PORTAL_PID if name == GTK else None
chk("an open portal dialog is not reported as an app to restart",
    st.stale_open_apps(since=THEME_SWITCH), ["Nautilus"])
E

# -- running_binary against real processes, since what /proc reports for a
#    binary replaced underneath a running process is the thing in question
python3 - "$REPO" <<'E'
import os, shutil, subprocess, sys, tempfile, time, types

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

sleep = shutil.which("sleep")
proc = subprocess.Popen([sleep, "30"])
try:
    chk("a running process reports its own binary",
        st.running_binary(proc.pid), os.path.realpath(sleep))
finally:
    proc.kill(); proc.wait()

# A package upgrade replaces the file under a running process.
work = tempfile.mkdtemp()
copy = os.path.join(work, "portal")
shutil.copy2(sleep, copy)
proc = subprocess.Popen([copy, "30"])
try:
    time.sleep(0.1)
    os.unlink(copy)
    chk("a binary replaced by an upgrade still matches its own path",
        st.running_binary(proc.pid), copy)
finally:
    proc.kill(); proc.wait()
    shutil.rmtree(work)

chk("a pid that does not exist has no binary", st.running_binary(2**22 + 7), None)
E
