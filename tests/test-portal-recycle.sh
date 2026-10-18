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

real_restart, real_resend = st.restart_portal_backend, st.resend_color_scheme

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
    st.has_quit_action = lambda name, path, pid=None: False
    st.quit_application = lambda pid, name, path: quit.append(name) or True
    st.restart_portal_backend = lambda name: steps.append(("restart", name)) or restart_ok
    st.resend_color_scheme = lambda: steps.append(("resend",)) or True
    st.refresh_idle_apps()
    return quit

steps, restart_ok = [], True

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

# -- issue #4: the recycled backend is what sends apps their color scheme ----
steps.clear()
chk("a recycled portal is started again at once, then the color scheme re-sent",
    (scenario(windows=[]), steps), ([GTK], [("restart", GTK), ("resend",)]))
steps.clear()
scenario(windows=[], started=AFTER)
chk("...and nothing is restarted or re-sent when nothing was recycled", steps, [])
steps.clear(); restart_ok = False
scenario(windows=[])
chk("a backend that does not come back is not followed by a re-send",
    steps, [("restart", GTK)])
restart_ok = True

# restart_portal_backend: starts the name, waits for an owner, then reads once
st.restart_portal_backend, st.resend_color_scheme = real_restart, real_resend
calls, owners = [], iter([False, False, True])
st.bus_call = lambda dest, path, method, *a: calls.append((dest, method, a)) or "()"
st.name_has_owner = lambda name: next(owners, True)
st.time.sleep = lambda s: None
chk("a restarted backend is waited for until it owns its name",
    st.restart_portal_backend(GTK), True)
chk("...started through D-Bus, then read through the portal once",
    [c[1] for c in calls], ["org.freedesktop.DBus.StartServiceByName",
                            "org.freedesktop.portal.Settings.ReadOne"])
chk("...for the backend just quit, and the appearance color scheme",
    (calls[0][2], calls[1][2]), ((GTK, "0"), ("org.freedesktop.appearance", "color-scheme")))
calls.clear()
st.name_has_owner = lambda name: False
st.PORTAL_RESTART_SECONDS = 0.05
real_monotonic = st.time.monotonic
chk("one that never comes back is reported, not waited on forever",
    st.restart_portal_backend(GTK), False)

# resend_color_scheme: through "default" and back, the value always restored
ran, current = [], ["'prefer-dark'"]
class Done:
    def __init__(self, out=""): self.stdout, self.returncode = out, 0
def fake_run(args, **kw):
    if args[1] == "get":
        if current[0] is None:
            raise st.subprocess.TimeoutExpired(args, 10)
        return Done(current[0])
    ran.append(args[-1])
    return Done()
st.subprocess.run = fake_run
chk("a dark scheme is re-sent through default", (st.resend_color_scheme(), ran),
    (True, ["default", "prefer-dark"]))
ran.clear()
current[0] = "'default'"
chk("no preference needs nothing sent", (st.resend_color_scheme(), ran), (False, []))
current[0] = None
chk("an unreadable scheme is left alone", (st.resend_color_scheme(), ran), (False, []))
current[0] = "'prefer-light'"
def interrupted(s):
    raise KeyboardInterrupt
st.time.sleep = interrupted
try:
    st.resend_color_scheme()
except KeyboardInterrupt:
    pass
chk("...and an interruption still puts the original value back",
    ran, ["default", "prefer-light"])

# a gsettings that hangs or fails is an answer, never an exception
st.time.sleep = lambda s: None
ran.clear(); current[0] = "'prefer-dark'"
attempts = []
def flaky_run(args, **kw):
    if args[1] == "get":
        return Done(current[0])
    attempts.append(args[-1])
    if args[-1] == "prefer-dark" and attempts.count("prefer-dark") == 1:
        raise st.subprocess.TimeoutExpired(args, 10)
    return Done()
st.subprocess.run = flaky_run
chk("a restore that times out is tried again, not raised",
    (st.resend_color_scheme(), attempts), (True, ["default", "prefer-dark", "prefer-dark"]))
def failing_run(args, **kw):
    if args[1] == "get":
        return Done(current[0])
    attempts.append(args[-1])
    r = Done(); r.returncode = 1; return r
attempts.clear(); st.subprocess.run = failing_run
st.set_color_scheme = st.set_color_scheme  # real one, using the failing run
chk("a scheme that cannot be set to default is left exactly as it was",
    (st.resend_color_scheme(), attempts), (False, ["default"]))
def hung(*a, **k):
    raise st.subprocess.TimeoutExpired("gdbus", 10)
st.bus_call = hung
chk("a bus that does not answer reads as a backend not back, not an exception",
    st.restart_portal_backend(GTK), False)

# -- the stale-apps report names applications, not a file chooser ----------
st.open_windows = lambda: [("All Files", "xdg-desktop-portal-gtk", PORTAL_PID),
                           ("Files", "org.gnome.Nautilus", 2000)]
st.process_started_at = lambda pid: BEFORE
st.omarchy_reloaded_executables = lambda: set()
st.window_executable = lambda pid: "whatever"
st.connection_pid = lambda name: PORTAL_PID if name == GTK else None
chk("an open portal dialog is not reported as an app to restart",
    st.stale_open_windows(since=THEME_SWITCH), {"Nautilus": 1})
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
