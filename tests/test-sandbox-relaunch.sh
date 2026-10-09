#!/usr/bin/env bash
# Marketplace review of eb2614a: the restart copied a window process's whole
# environment into the host's uwsm. A sandboxed Flatpak app could set
# PYTHONPATH to its own writable data, and uwsm -- a Python program -- would
# run that code outside the sandbox when the user confirmed a restart. The
# fallback re-exec had the same shape: the process's own argv and reported
# binary, both the sandbox's to choose.
#
# Now every relaunch gets the session's environment, and a process in another
# mount or user namespace is relaunched only through an installed launcher,
# from home -- or not closed at all. This stages the attack for real: a
# process in its own namespaces (unshare), PYTHONPATH and its working
# directory pointing at a planted module. Nothing is launched: the relaunch
# step is replaced by a recorder, so the test reads exactly what would run.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

if ! unshare -Urm true 2>/dev/null; then
  echo "  SKIP sandbox relaunch: unprivileged namespaces are not available here"
  exit 0
fi

python3 - "$REPO" <<'E'
import os, shutil, subprocess, sys, tempfile, time, types

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

planted = tempfile.mkdtemp(prefix="sandbox-data-")
with open(os.path.join(planted, "sitecustomize.py"), "w") as handle:
    handle.write("open(%r, 'w').write('escaped')\n" % os.path.join(planted, "ESCAPED"))

def sandboxed():
    proc = subprocess.Popen(["unshare", "-Urm", "sleep", "300"], cwd=planted,
                            env={**os.environ, "PYTHONPATH": planted, "NODE_OPTIONS": "--require " + planted + "/x.js"})
    time.sleep(0.3)
    return proc

st.WINDOW_CLOSE_GRACE_SECONDS = 2.0
st.CLOSE_ANSWER_SECONDS = 0.1
st.APPLICATION_SETTLE_SECONDS = 0.1
closed = []
st.close_window = lambda address: closed.append(address) or True
st.open_window_records = lambda: []
st.hide_new_windows = lambda classes: False
st.writing_user_files = lambda exe: False
recorded = []
real_desktop_entries, real_flatpak_entries = st.desktop_entries, st.flatpak_entries
st.relaunch_and_place = lambda plans, before: (recorded.extend(plans), ([p["name"] for p in plans], []))[1]

def group(proc, klass):
    return [{"pid": proc.pid, "started": st.process_started_at(proc.pid), "name": "Sandboxed",
             "class": klass, "addresses": ["0x1"]}]

proc = sandboxed()
try:
    chk("a process in its own namespaces reads as confined", st.runs_confined(proc.pid), True)
    chk("...and one in this helper's own does not", st.runs_confined(os.getpid()), False)
    chk("...and one that cannot be read fails closed, as confined", st.runs_confined(999999), True)

    # No installed launcher names its class: nothing safe to bring it back
    # with, so it is not closed at all.
    st.stale_window_groups = lambda since=None: group(proc, "no.such.class")
    restarted, pending, failed = st.restart_stale_apps(None)
    chk("a sandboxed app with no launcher is reported failed, not restarted",
        (restarted, pending, failed), ([], [], ["Sandboxed"]))
    chk("...its window is never asked to close", closed, [])
    chk("...it is still running", proc.poll(), None)
    chk("...and nothing is relaunched for it", recorded, [])
finally:
    if proc.poll() is None:
        proc.kill(); proc.wait()

# A bare sandbox claiming a host app's class gets no host launcher: only
# Flatpak's own record can name a sandboxed app's launcher.
st.desktop_entries = lambda: {"sandboxed-app": "/usr/share/applications/sandboxed-app.desktop"}
st.flatpak_entries = lambda: {}
proc = sandboxed()
try:
    recorded.clear(); closed.clear()
    st.stale_window_groups = lambda since=None: group(proc, "sandboxed-app")
    result = st.restart_stale_apps(None)
    chk("a sandbox claiming a host app's class is not relaunched as that app",
        (result, recorded, closed, proc.poll()), (([], [], ["Sandboxed"]), [], [], None))
finally:
    if proc.poll() is None:
        proc.kill(); proc.wait()

# A Flatpak -- staged with bubblewrap and a /.flatpak-info of its own --
# whose window claims to be Firefox: relaunched as itself, through its own
# export, never the host's Firefox, and with nothing from its environment or
# working directory.
uwsm = shutil.which("uwsm", path=st.trusted_path())
bwrap = shutil.which("bwrap")
if uwsm and bwrap:
    info = os.path.join(planted, "flatpak-info")
    with open(info, "w") as handle:
        handle.write("[Application]\nname=org.example.Evil\nruntime=runtime/x/y/z\n")
    host_firefox = "/usr/share/applications/firefox.desktop"
    evil_export = os.path.expanduser("~/.local/share/flatpak/exports/share/applications/org.example.Evil.desktop")
    st.desktop_entries = lambda: {"firefox": host_firefox}
    st.flatpak_entries = lambda: {"org.example.Evil": evil_export}
    session = {"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": "wayland-1"}
    st.session_environment = lambda: session
    proc = subprocess.Popen(
        [bwrap, "--die-with-parent", "--unshare-user", "--ro-bind", "/usr", "/usr", "--symlink", "usr/bin", "/bin",
         "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64", "--proc", "/proc",
         "--dev", "/dev", "--ro-bind", info, "/.flatpak-info", "--bind", planted, planted,
         "--chdir", planted, "sleep", "300"],
        env={**os.environ, "PYTHONPATH": planted, "NODE_OPTIONS": "--require " + planted + "/x.js"})
    time.sleep(0.3)

    # bwrap's outer process stays outside as a monitor; the app -- the process
    # a window's pid names -- is the sleep running inside.
    def descendants(pid):
        try:
            children = open(f"/proc/{pid}/task/{pid}/children").read().split()
        except OSError:
            return []
        return [int(c) for c in children] + [d for c in children for d in descendants(int(c))]
    inner = next((d for d in descendants(proc.pid)
                  if open(f"/proc/{d}/comm").read().strip() == "sleep"), proc.pid)
    app = types.SimpleNamespace(pid=inner, poll=proc.poll)
    try:
        chk("a Flatpak's app id is read from Flatpak's own record", st.flatpak_app_id(app.pid), "org.example.Evil")
        recorded.clear()
        st.stale_window_groups = lambda since=None: group(app, "firefox")
        restarted, pending, failed = st.restart_stale_apps(None)
        plan = recorded[0] if recorded else {}
        chk("a Flatpak whose window claims to be Firefox comes back as itself, through its own export",
            (restarted, plan.get("argv")), (["Sandboxed"], [uwsm, "app", "-s", "a", "--", evil_export]))
        chk("...in the session's environment: no PYTHONPATH or NODE_OPTIONS of its own",
            plan.get("env"), session)
        chk("...from home, not the working directory it chose",
            plan.get("cwd"), os.path.expanduser("~"))
    finally:
        # The sandboxed app itself, then bwrap: a sleep left behind would be
        # taken by later suites for one of theirs.
        try:
            os.kill(inner, 9)
        except OSError:
            pass
        if proc.poll() is None:
            proc.kill()
        proc.wait()
else:
    print("  SKIP Flatpak relaunch: uwsm or bwrap is not installed here")

# The other direction, through a real scan: a Flatpak export declaring
# StartupWMClass=firefox, in a folder read before /usr/share, must not
# become the host Firefox's launcher or lend it its name.
home = tempfile.mkdtemp(prefix="entries-home-")
system = tempfile.mkdtemp(prefix="entries-system-")
exports = os.path.join(home, ".local/share/flatpak/exports/share/applications")
os.makedirs(exports)
os.makedirs(os.path.join(system, "applications"))
with open(os.path.join(exports, "org.example.Evil.desktop"), "w") as handle:
    handle.write("[Desktop Entry]\nName=Firefox\nStartupWMClass=firefox\nExec=flatpak run org.example.Evil\n")
with open(os.path.join(system, "applications", "firefox.desktop"), "w") as handle:
    handle.write("[Desktop Entry]\nName=Firefox Web Browser\nExec=firefox\nActions=new-window;\n")
real_home, real_dirs = st.Path.home, os.environ.get("XDG_DATA_DIRS")
st.Path.home = staticmethod(lambda: st.Path(home))
os.environ["XDG_DATA_DIRS"] = os.path.join(home, ".local/share/flatpak/exports/share") + ":" + system
st._DESKTOP_ENTRIES = st._FLATPAK_ENTRIES = None
st.desktop_entries, st.flatpak_entries = real_desktop_entries, real_flatpak_entries
try:
    chk("a host window of class firefox resolves to the host's own entry, not the Flatpak claiming it",
        st.launcher_for("firefox"), os.path.join(system, "applications", "firefox.desktop"))
    chk("...and is named by it", st.app_display_name("t", "firefox"), "Firefox Web Browser")
    chk("snapd's exported entries are never host launchers either",
        (st.is_snap_export("/var/lib/snapd/desktop"), st.is_snap_export("/usr/share")), (True, False))
    chk("...while the Flatpak's export is reachable only by its app id",
        (st.flatpak_entries().get("org.example.Evil", "").endswith("org.example.Evil.desktop"),
         st.launcher_for("org.example.evil")), (True, None))
finally:
    st.Path.home = real_home
    if real_dirs is None:
        os.environ.pop("XDG_DATA_DIRS", None)
    else:
        os.environ["XDG_DATA_DIRS"] = real_dirs
    shutil.rmtree(home); shutil.rmtree(system)

chk("the planted module never ran", os.path.exists(os.path.join(planted, "ESCAPED")), False)
shutil.rmtree(planted)
E
