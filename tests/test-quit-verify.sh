#!/usr/bin/env bash
# quit_application used to fire an application's own --quit, wait 1.5s, and if
# that did not work, fire the generic GApplication action and return
# regardless of whether either one actually worked. On a real Nautilus the
# fast path's own --quit did not reliably reach g_application_quit() inside
# that window -- a clean, isolated timing test showed the command returning in
# 0.135s while the process it was meant to end was still running fifteen
# seconds later -- and the generic action can itself take up to GApplication's
# own ten-second ceiling. The caller printed "closed idle X" regardless, so
# the log claimed success while a stale instance was still alive to catch a
# window reopened in that gap.
#
# quit_application now escalates through real signals instead of waiting on
# either D-Bus path once open_windows() has already confirmed nothing is on
# screen: SIGTERM, then SIGKILL. This drives it against real child processes,
# not a mock, because a signal actually reaching a process is exactly the
# thing that was in question.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import importlib.util, sys, time, types, subprocess

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# Shortened for the test; what is under test is the escalation order and the
# final answer, not how many seconds each rung is given in production.
st.QUIT_GRACE_SECONDS = 0.1
st.SIGNAL_GRACE_SECONDS = 0.3
st.GNOME_NAMESPACE = "test."

# The D-Bus phase never reports success here, so every case below exercises
# the signal escalation that follows it rather than the polite path, which
# test-dependency.sh-adjacent unit tests already cover with a mocked bus.
st.bus_call = lambda *a, **k: None
st.subprocess.run = lambda *a, **k: None
st.name_has_owner = lambda name: True
st.service_file_exec = lambda name: None

# -- a normal process dies to SIGTERM, the first rung -----------------------
proc = subprocess.Popen(["sleep", "100"])
try:
    ok = st.quit_application(proc.pid, "test.App", "/test/App")
    chk("an ordinary process is gone after SIGTERM", ok, True)
    chk("...and is not left as a zombie", proc.poll() is not None, True)
finally:
    proc.wait(timeout=2)

# -- a process that ignores SIGTERM is still ended by SIGKILL ---------------
proc = subprocess.Popen([sys.executable, "-c",
    "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(100)"])
time.sleep(0.2)  # let the signal handler actually get installed
try:
    ok = st.quit_application(proc.pid, "test.Stubborn", "/test/Stubborn")
    chk("a process ignoring SIGTERM is ended by SIGKILL", ok, True)
finally:
    proc.wait(timeout=2)

# -- a pid that is already gone is reported as already-gone, not a failure --
proc = subprocess.Popen(["true"])
proc.wait()
chk("an already-exited pid counts as success, not failure",
    st.quit_application(proc.pid, "test.AlreadyGone", "/test/AlreadyGone"), True)

# -- refresh_idle_apps only reports what quit_application actually confirmed
import contextlib, io
st.bus_names = lambda method: {"test.Stale", "test.Kept"}
gone = subprocess.Popen(["sleep", "100"])
holdout = subprocess.Popen(["sleep", "100"])
st.connection_pid = lambda name: {"test.Stale": gone.pid, "test.Kept": holdout.pid}[name]
st.process_started_at = lambda pid: 0
st.open_windows = lambda: []
st.has_quit_action = lambda name, path: True
# The real escalation is exercised above; this only has to prove that
# refresh_idle_apps' own message depends on quit_application's answer, not on
# whether it tried. Faking a target that survives every signal -- a D-state
# kernel task -- is not something a test can construct, so the survival
# itself is stood in for directly.
real_process_alive = st.process_alive
st.process_alive = lambda pid: True if pid == holdout.pid else real_process_alive(pid)
out = io.StringIO()
with contextlib.redirect_stdout(out):
    st.refresh_idle_apps(since=10**9)
text = out.getvalue()
chk("a confirmed quit is reported as closed",
    "closed idle test.Stale" in text, True)
chk("a target signals cannot reach is reported as not done",
    "test.Kept did not quit" in text and "closed idle test.Kept" not in text, True)
st.process_alive = real_process_alive
for p in (holdout, gone):
    if p.poll() is None:
        p.kill()
    p.wait(timeout=2)
E
