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

# An installed launcher names its class: relaunched through it -- and with
# none of what the sandbox put in its own environment or working directory.
uwsm = shutil.which("uwsm", path=st.trusted_path())
if uwsm:
    st.desktop_entries = lambda: {"sandboxed-app": "sandboxed-app.desktop"}
    session = {"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": "wayland-1"}
    st.session_environment = lambda: session
    proc = sandboxed()
    try:
        st.stale_window_groups = lambda since=None: group(proc, "sandboxed-app")
        restarted, pending, failed = st.restart_stale_apps(None)
        plan = recorded[0] if recorded else {}
        chk("a sandboxed app with a launcher is relaunched through it",
            (restarted, plan.get("argv")), (["Sandboxed"], [uwsm, "app", "-s", "a", "--", "sandboxed-app.desktop"]))
        chk("...in the session's environment: no PYTHONPATH or NODE_OPTIONS of its own",
            plan.get("env"), session)
        chk("...from home, not the working directory it chose",
            plan.get("cwd"), os.path.expanduser("~"))
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
else:
    print("  SKIP launcher relaunch: uwsm is not installed here")

chk("the planted module never ran", os.path.exists(os.path.join(planted, "ESCAPED")), False)
shutil.rmtree(planted)
E
