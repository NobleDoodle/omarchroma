#!/usr/bin/env bash
# Restarting and quitting applications signal them over seconds, ending in
# SIGKILL. By pid, one that exits in that time can have its number handed to
# an unrelated process, which the SIGKILL then reaches. Every signal now goes
# through a pidfd opened when the decision is made, and a restart checks that
# the pidfd holds the very process it judged stale, by its start time.
# This drives real processes: whether a signal reaches one is the question.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import os, signal, subprocess, sys, time, types

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

def sleeper():
    proc = subprocess.Popen(["sleep", "300"])
    time.sleep(0.1)
    return proc

# A process that exited is gone to its pidfd even before anyone reaps it --
# exactly the window in which its number is not yet free, and process_alive's
# /proc reading is what had to special-case zombies.
proc = sleeper()
fd = st.open_pidfd(proc.pid)
proc.send_signal(signal.SIGKILL)
time.sleep(0.2)
chk("an exited, unreaped process reads as gone through its pidfd", st.pidfd_alive(fd), False)
proc.wait()
chk("once reaped, its number free for reuse, the pidfd refuses every signal",
    st.pidfd_signal(fd, signal.SIGKILL), False)
os.close(fd)

proc = sleeper()
started = st.process_started_at(proc.pid)
fd = st.open_pidfd(proc.pid, started)
chk("a pidfd opens for the process that was judged", fd is not None, True)
os.close(fd)
chk("...and not for one whose start time differs: another process on that number",
    st.open_pidfd(proc.pid, started - 5), None)

# The restart itself, against a pid that now belongs to something else: the
# group was judged on a process that started earlier, and the one holding the
# number now must be neither closed nor signalled.
signals = []
real_signal = st.pidfd_signal
st.pidfd_signal = lambda fd, sig: signals.append(sig) or real_signal(fd, sig)
closed = []
st.close_window = lambda address: closed.append(address) or True
st.open_window_records = lambda: []
st.hide_new_windows = lambda classes: False
st.stale_window_groups = lambda since=None: [
    {"pid": proc.pid, "started": started - 5, "name": "Reused", "class": "test-app",
     "addresses": ["0x1"]}]
restarted, pending, failed = st.restart_stale_apps(None)
chk("a reused pid is reported failed, not restarted", (restarted, pending, failed), ([], [], ["Reused"]))
chk("...its window is not asked to close", closed, [])
chk("...no signal is sent", signals, [])
chk("...and the process now on that number is untouched", proc.poll(), None)
st.pidfd_signal = real_signal
proc.kill(); proc.wait()

# Statically: no signal is sent by number anywhere. kill(pid, 0) only asks
# whether a pid exists, and stays in process_alive for pids nothing holds.
code = "\n".join(line.split("#", 1)[0] for line in src.splitlines())
chk("no os.kill sends a real signal", sum(1 for line in code.splitlines()
    if "os.kill(" in line and "os.kill(pid, 0)" not in line), 0)
chk("both escalations go through pidfd_signal", code.count("pidfd_signal(plan[\"pidfd\"]"), 3)
chk("quit_application holds a pidfd", "descriptor = open_pidfd(pid)" in code, True)
E

# --- one restart at a time ---------------------------------------------------
# Run with no reachable Hyprland -- no instance signature, a scratch runtime
# dir -- so even a broken lock could find no window of the user's to close.
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
rt=$(mktemp -d "${TMPDIR:-/tmp}/restart-lock-XXXXXX"); chmod 700 "$rt"
python3 lib/hyprchroma-state prepare-lock --path "$rt/hyprchroma-restart.lock"
(
  exec 7<"$rt/hyprchroma-restart.lock"; flock -n 7
  # Exactly this line and nothing else: the helper, which would print what it
  # restarted, never ran.
  out=$(env -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$rt" \
        ./bin/hyprchroma restart-stale 2>&1 || true)
  chk "a second restart leaves while one is running, before the helper runs" \
    "$out" "Hyprchroma: a restart is already running"
)
chk "the helper does not hold the restart lock, so relaunched apps cannot" \
  "$(grep -c 'restart-stale-apps --sync-command "$HYPRCHROMA_SELF" 7<&-)' bin/hyprchroma)" "1"
rm -rf "$rt"

# --- a stalled Hyprland cannot hang a restart holding its lock --------------
python3 - "$REPO" <<'E'
import subprocess, sys, types
src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)
def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))
seen = {}
def stalled(args, **kw):
    seen["timeout"] = kw.get("timeout")
    raise subprocess.TimeoutExpired(args, kw.get("timeout"))
st.subprocess.run = stalled
chk("every hyprctl call has a timeout", (st.hyprctl("-j", "clients"), seen["timeout"]),
    (None, st.HYPRCTL_TIMEOUT_SECONDS))
chk("...and a stalled one reads as no windows, not a hang", st.open_window_records(), None)
chk("...a dispatch that got no answer is not taken as done", st.close_window("0x1"), False)
chk("no hyprctl call bypasses it", src.count('["hyprctl"'), 1)
E
