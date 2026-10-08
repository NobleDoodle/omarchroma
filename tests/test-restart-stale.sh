#!/usr/bin/env bash
# Restarting a stale application: close every window it has open, the way its
# own close button would, then launch it again with the command, directory
# and environment it already had. Run for real against real child processes,
# the same way test-quit-verify.sh drives the signal escalation it shares --
# a signal actually reaching a process, and a process actually relaunching
# with the right binary, are exactly the things in question.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import importlib.util, os, shutil, signal, stat, sys, tempfile, time, types, subprocess
from pathlib import Path

REPO = sys.argv[1]
src = open(REPO + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
st.__dict__["__file__"] = REPO + "/lib/hyprchroma-state"
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)
# Captured here, pristine, before any test below replaces it with a fixed
# answer of its own (most do, and do not restore it -- the next test's own
# replacement is expected to be the cleanup): the one later check that needs
# the real grouping logic again restores from this, not from whatever the
# immediately preceding test happened to leave behind.
pristine_stale_window_groups = st.stale_window_groups


def spawn_sleeper():
    """A `sleep 300` standing in for an open application, returned only once
    /proc shows its command line: read the instant after it starts, that can
    still be empty, which the restart rightly treats as a process it cannot
    relaunch -- a real application has been running long past that moment."""
    proc = subprocess.Popen(["sleep", "300"])
    for _ in range(100):
        if st.process_cmdline(proc.pid):
            break
        time.sleep(0.01)
    return proc


def kill_sleepers():
    # Relaunches run as the kernel's own record of the binary, /usr/bin/sleep,
    # so the pattern takes both spellings.
    subprocess.run(["pkill", "-f", "^(/usr/bin/)?sleep 300$"], check=False)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# Shortened for the test; what is under test is the escalation order and the
# final outcome, not how many seconds each rung is given in production.
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2
st.SIGNAL_GRACE_SECONDS = 0.3
st.APPLICATION_SETTLE_SECONDS = 0.3

closed_addresses = []
real_subprocess_run = subprocess.run
# st.subprocess is the real subprocess module, the same object this script
# imported -- Python caches it by name -- so patching .run here reaches every
# caller of it, including, further down, this very script's own use of it to
# compile the two probes the PATH-poisoning check needs. Only a hyprctl
# dispatch call is faked; everything else is the real subprocess.run, so a
# write-a-marker-and-wait probe is not needed to prove gcc actually ran.
dispatched = []
evaluated = []
def fake_run(command, **kwargs):
    # Answers the Lua form current Hyprland takes, as Hyprland does ("ok"),
    # and records which window each close and move was for.
    # hyprctl eval is Lua run inside the live Hyprland -- a window rule, here
    # -- so it is answered, never passed through to the real one.
    if command[:2] == ["hyprctl", "eval"]:
        evaluated.append(command[2])
        return types.SimpleNamespace(returncode=0, stdout="ok\n")
    if command[:2] == ["hyprctl", "dispatch"]:
        dispatched.append(command[2])
        found = __import__("re").search(r'address:(0x[0-9a-f]+)', command[2])
        if found and "window.close" in command[2]:
            closed_addresses.append("address:" + found.group(1))
        return types.SimpleNamespace(returncode=0, stdout="ok\n")
    return real_subprocess_run(command, **kwargs)
st.subprocess.run = fake_run

# -- stale_window_groups: grouped by process, not by window -----------------
st.theme_switched_at = lambda: 1_000_000
st.omarchy_reloaded_executables = lambda: {"reloaded-bin"}
st.gtk_portal_pids = lambda: {404}
st.open_window_records = lambda: [
    {"title": "A", "class": "app", "pid": 100, "address": "0xaaa"},
    {"title": "A - doc 2", "class": "app", "pid": 100, "address": "0xaab"},
    {"title": "B", "class": "newer", "pid": 200, "address": "0xbbb"},
    {"title": "C", "class": "reloaded", "pid": 300, "address": "0xccc"},
    {"title": "D", "class": "portal", "pid": 404, "address": "0xddd"},
]
st.process_started_at = lambda pid: {100: 500_000, 200: 2_000_000, 300: 500_000}.get(pid)
st.window_executable = lambda pid: {300: "reloaded-bin"}.get(pid)
groups = st.stale_window_groups()
# window_display_name prefers the class over the title once there is one --
# "App" from class "app", not the "A"/"A - doc 2" titles -- the same rule
# stale_open_windows already relies on; grouping by process is what is new.
chk("two windows of the same stale process become one group",
    sorted(g["name"] for g in groups), ["App"])
chk("...carrying every window address that process owns",
    sorted(next(g for g in groups if g["name"] == "App")["addresses"]), ["0xaaa", "0xaab"])
chk("a window that opened after the theme did is not a group of its own",
    any(g["pid"] == 200 for g in groups), False)
chk("a process Omarchy re-themes live is excluded, window and all",
    any(g["pid"] == 300 for g in groups), False)
chk("a file-chooser portal is excluded the same way stale_open_windows excludes it",
    any(g["pid"] == 404 for g in groups), False)

# -- process_cmdline / process_cwd / process_environ: real /proc reads ------
marker = tempfile.mkstemp()[1]
scratch = tempfile.mkdtemp()
probe = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(100)", "--probe-arg"],
    cwd=scratch, env={**os.environ, "HYPRCHROMA_TEST_MARKER": marker})
try:
    time.sleep(0.1)
    cmdline = st.process_cmdline(probe.pid)
    chk("process_cmdline reads the real argv, including an extra argument",
        cmdline[-1] if cmdline else None, "--probe-arg")
    chk("process_cwd reads the real working directory",
        st.process_cwd(probe.pid), os.path.realpath(scratch))
    chk("process_environ reads the real environment",
        st.process_environ(probe.pid).get("HYPRCHROMA_TEST_MARKER"), marker)
finally:
    probe.kill(); probe.wait(timeout=2)
chk("a pid already gone reads as None / {} rather than raising",
    (st.process_cmdline(999999), st.process_cwd(999999), st.process_environ(999999)),
    (None, None, {}))

# -- restart_stale_apps: closes, waits, escalates, then relaunches ----------
# A real application standing in for one with an open window: it writes its
# own pid to a marker file so a relaunch is provable, then sleeps.
app_dir = tempfile.mkdtemp()
app = Path(app_dir, "app.py")
app.write_text(
    "import os, pathlib, sys, time\n"
    "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
    "time.sleep(100)\n"
)
marker_a = Path(tempfile.mkdtemp(), "marker")

def spawn_app(extra_env=None):
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.Popen([sys.executable, str(app), str(marker_a)], env=env)
    for _ in range(50):
        if marker_a.exists() and marker_a.read_text():
            break
        time.sleep(0.05)
    return proc

proc = spawn_app()
try:
    closed_addresses.clear()
    st.stale_window_groups = lambda since=None: [
        {"pid": proc.pid, "name": "App", "class": "test-app", "addresses": ["0x111", "0x222"]}]
    restarted, pending, failed = st.restart_stale_apps(None)
    # Found live: closing a browser's windows one by one left only the last
    # in its own session, so it came back with one window of several.
    chk("an application with several windows is quit as a whole, not window by window",
        sorted(closed_addresses), [])
    chk("the application is reported restarted", (restarted, pending, failed),
        (["App"], [], []))
    chk("the original process is actually gone", st.process_alive(proc.pid), False)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and marker_a.read_text() == str(proc.pid):
        time.sleep(0.05)
    new_pid = int(marker_a.read_text())
    chk("...and a new one is running in its place", new_pid != proc.pid, True)
    subprocess.Popen(["kill", "-9", str(new_pid)]).wait()
finally:
    if proc.poll() is None:
        proc.kill(); proc.wait(timeout=2)

# -- a process that ignores every signal is left, not duplicated ------------
# SIGKILL cannot actually be ignored by any process, so a process a restart
# truly cannot move is not something a test can spawn. os.kill is patched
# instead, to a no-op for this one pid, standing in for one -- a D-state
# kernel task, most plainly -- no signal reaches; the process stays alive on
# its own merits, which is genuinely true of it throughout.
stubborn = subprocess.Popen([sys.executable, "-c",
    "import signal, time\n"
    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
    "time.sleep(100)\n"])
time.sleep(0.2)
try:
    real_kill = st.os.kill
    st.os.kill = lambda pid, sig: None if pid == stubborn.pid else real_kill(pid, sig)
    closed_addresses.clear()
    st.stale_window_groups = lambda since=None: [
        {"pid": stubborn.pid, "name": "Stubborn", "class": "test-app", "addresses": ["0x999"]}]
    restarted, pending, failed = st.restart_stale_apps(None)
    chk("a process nothing can close is reported pending, not restarted",
        (restarted, pending, failed), ([], ["Stubborn"], []))
    st.os.kill = real_kill
finally:
    if stubborn.poll() is None:
        stubborn.kill(); stubborn.wait(timeout=2)

# -- a relaunch that exits again on its own is failed, not restarted --------
# Found live: an application closed by this and relaunched, then exited
# again on its own within a second or two -- deferring to another instance's
# lock, most likely -- leaving nothing running and no window to reopen,
# while the old code called it "restarted" because Popen itself had not
# raised. Driven against a real child, like quit_application's own tests:
# a process that forks fine and exits of its own accord right after.
st.WINDOW_CLOSE_GRACE_SECONDS = 0.05
real_process_cmdline, real_running_binary = st.process_cmdline, st.running_binary
real_process_cwd, real_process_environ = st.process_cwd, st.process_environ
quitter = subprocess.Popen(["sleep", "100"])
quit_cmdline = ["sh", "-c", "exit 0"]
st.process_cmdline = lambda pid: quit_cmdline if pid == quitter.pid else real_process_cmdline(pid)
st.running_binary = lambda pid: shutil.which("sh") if pid == quitter.pid else real_running_binary(pid)
st.process_cwd = lambda pid: "/tmp" if pid == quitter.pid else real_process_cwd(pid)
st.process_environ = lambda pid: dict(os.environ) if pid == quitter.pid else real_process_environ(pid)
try:
    closed_addresses.clear()
    st.stale_window_groups = lambda since=None: [
        {"pid": quitter.pid, "name": "Quitter", "class": "test-app", "addresses": ["0x5"]}]
    restarted, pending, failed = st.restart_stale_apps(None)
    chk("a relaunch that exits again on its own is reported failed, not restarted",
        (restarted, pending, failed), ([], [], ["Quitter"]))
finally:
    if quitter.poll() is None:
        quitter.kill(); quitter.wait(timeout=2)
    st.process_cmdline, st.running_binary = real_process_cmdline, real_running_binary
    st.process_cwd, st.process_environ = real_process_cwd, real_process_environ
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- Steam: its own interface regardless of any theme, never flagged --------
# The pristine stale_window_groups, captured at the very top: every test
# before this one has left its own fixed answer in place instead of
# restoring it, and this one needs the actual grouping logic run against
# the fake window list below.
st.stale_window_groups = pristine_stale_window_groups
st.theme_switched_at = lambda: 1_000_000
st.omarchy_reloaded_executables = lambda: set()
st.gtk_portal_pids = lambda: set()
st.window_executable = lambda pid: None
st.open_windows = lambda: [("Steam", "steam", 500), ("Friends List", "steam", 500)]
st.process_started_at = lambda pid: 500_000
chk("Steam is never counted as stale: it has no theme to be behind on",
    st.stale_open_windows(), {})
st.open_window_records = lambda: [
    {"title": "Steam", "class": "steam", "pid": 500, "address": "0xfff"}]
chk("...nor offered a restart, for the same reason", st.stale_window_groups(), [])

# -- gone between listing and acting: failed, and nothing is launched -------
gone = subprocess.Popen(["true"]); gone.wait()
closed_addresses.clear()
st.stale_window_groups = lambda since=None: [
    {"pid": gone.pid, "name": "Gone", "class": "test-app", "addresses": ["0x000"]}]
real_popen = st.subprocess.Popen
launched = []
st.subprocess.Popen = lambda *a, **k: launched.append(a) or real_popen(["true"])
restarted, pending, failed = st.restart_stale_apps(None)
chk("a process already gone is reported failed", (restarted, pending, failed),
    ([], [], ["Gone"]))
chk("...and nothing is launched to replace it", launched, [])
st.subprocess.Popen = real_popen

# -- the executable actually run is the kernel's record, not argv re-resolved
# through PATH: a captured environment is attacker-shaped exactly where a
# malicious PATH entry would be, since it is handed back to the child
# unchanged. If a relaunch ever resolves cmdline[0] through that PATH instead
# of running the exact binary that was already running, this is what catches
# it before it reaches anyone's real applications.
# Compiled, not a #!-script: a script's /proc/pid/exe names its interpreter,
# not the script, which would make every cmdline here start with "python3" --
# a name neither binary below has -- and prove nothing. A real application is
# a native binary, and this has to be one to stand in for it honestly.
gcc = shutil.which("gcc") or shutil.which("cc")
if gcc is None:
    print("  SKIP the PATH-poisoning check: no C compiler on this machine")
else:
    real_scratch = tempfile.mkdtemp()
    real_bin = Path(real_scratch, "probe")
    evil_scratch = tempfile.mkdtemp()
    evil_bin = Path(evil_scratch, "probe")
    outcome = Path(tempfile.mkdtemp(), "outcome")
    source = ('#include <stdio.h>\n#include <unistd.h>\n'
              'int main(int argc, char **argv) {{'
              'FILE *f = fopen(argv[1], "w"); fputs("{word}", f); fclose(f);'
              '{pause}return 0; }}\n')
    for binary, word, pause in ((real_bin, "genuine", "pause(); "), (evil_bin, "POISONED", "")):
        c_file = binary.with_suffix(".c")
        c_file.write_text(source.format(word=word, pause=pause))
        subprocess.run([gcc, "-O0", "-o", str(binary), str(c_file)], check=True)
    # Launched by its real, absolute path -- as a process actually is -- but
    # with argv[0] shortened to the bare name a PATH lookup of cmdline[0]
    # would chase, and a PATH that finds the evil "probe" before the real one.
    poisoned_env = dict(os.environ)
    poisoned_env["PATH"] = f"{evil_scratch}:{poisoned_env.get('PATH', '')}"
    # DEVNULL, not inherited: the relaunch this proves correct is left running
    # (pause()) past this block's own end, by design -- its argv names "probe",
    # not real_bin's path, so nothing here would otherwise hold a test runner
    # reading this script's own output open past this script's exit.
    victim = subprocess.Popen(["probe", str(outcome)], executable=str(real_bin),
                              env=poisoned_env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    for _ in range(50):
        if outcome.exists():
            break
        time.sleep(0.05)
    try:
        closed_addresses.clear()
        st.stale_window_groups = lambda since=None: [
            {"pid": victim.pid, "name": "Probe", "class": "test-app", "addresses": ["0x1"]}]
        restarted, pending, failed = st.restart_stale_apps(None)
        chk("the relaunch ran the real binary", (restarted, outcome.read_text()),
            (["Probe"], "genuine"))
        chk("...never the one a poisoned PATH entry would have resolved to first",
            outcome.read_text(), "genuine")
    finally:
        # Matched on the outcome path, present in both the original victim's
        # argv and the relaunch's: real_bin's own path is not, since the
        # whole point here is that argv[0] is "probe", decoupled from it.
        subprocess.run(["pkill", "-9", "-f", str(outcome)], check=False)

# -- relaunch_command: an installed launcher by window class, where one -----
# exists, uwsm's own scope instead of a plain re-exec -- found live: a real
# GPU-sandboxed application relaunched by a plain re-exec of its binary
# exited silently within its first second, launched this way it did not.
# Real desktop files, not fakes: HOME is not sandboxed for this half of the
# script, and YouTube Music's, declaring the class below, ships with Omarchy.
chk("a window class with an installed launcher resolves to its desktop file, suffix and all",
    st.desktop_entries().get("com.github.th-ch.youtube-music"),
    "com.github.th-ch.youtube-music.desktop")
uwsm_path = shutil.which("uwsm", path=st.trusted_path())
if uwsm_path:
    chk("...and relaunch_command runs it through uwsm's own scope",
        st.relaunch_command("com.github.th-ch.youtube-music",
                            ["/opt/YouTube Music/youtube-music"],
                            "/opt/YouTube Music/youtube-music"),
        [uwsm_path, "app", "-s", "a", "--", "com.github.th-ch.youtube-music.desktop"])
else:
    print("  SKIP relaunch_command via uwsm: uwsm is not installed here")
chk("a class with no installed launcher falls back to the kernel's own exe",
    st.relaunch_command("no.such.class", ["firefox", "--new-window"], "/usr/bin/firefox"),
    ["/usr/bin/firefox", "--new-window"])

# -- several at once: close all, sync while closed, relaunch all ------------
# Found live: one application after another was too slow, and each came back
# before the sync that could only run with it closed (Dark Reader writes to a
# browser profile only while no process of that browser is left) had run, so
# it reopened on its old theme.
st.WINDOW_CLOSE_GRACE_SECONDS = 0.3
pair = [spawn_sleeper() for _ in range(2)]
seen = {}
def between():
    seen["old_alive"] = [st.process_alive(p.pid) for p in pair]
    def cmdline_of(name):
        try:
            return (Path("/proc") / name / "cmdline").read_bytes()
        except OSError:
            return b""
    seen["sleeps_running"] = any(cmdline_of(e.name) == b"sleep\x00300\x00"
                                 for e in os.scandir("/proc") if e.name.isdigit())
st.stale_window_groups = lambda since=None: [
    {"pid": p.pid, "name": f"Pair{i}", "class": "test-app", "addresses": [f"0x{i}"]}
    for i, p in enumerate(pair)]
started = time.monotonic()
try:
    restarted, pending, failed = st.restart_stale_apps(None, between=between)
    elapsed = time.monotonic() - started
    chk("every application is closed before the in-between sync runs",
        seen.get("old_alive"), [False, False])
    chk("...nothing relaunched yet when it does", seen.get("sleeps_running"), False)
    chk("...then every one is relaunched", (restarted, pending, failed), (["Pair0", "Pair1"], [], []))
    chk("...closing together, not one after another (under two close windows)",
        elapsed < 2 * st.WINDOW_CLOSE_GRACE_SECONDS + 2 * st.SIGNAL_GRACE_SECONDS
        + st.APPLICATION_SETTLE_SECONDS + st.RELAUNCH_CHECK_SECONDS, True)
finally:
    for p in pair:
        if p.poll() is None:
            p.kill(); p.wait(timeout=2)
    kill_sleepers()
st.stale_window_groups = pristine_stale_window_groups
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- ignoring a close is hurried; answering it with a dialog is respected -
# Found live: YouTube Music keeps its window when asked to close and sat out
# the whole close grace. An application with unsaved work answers with a new
# window, its "save changes?" dialog -- and a signal there is the lost work
# that dialog is asking about.
real_records = st.open_window_records
st.WINDOW_CLOSE_GRACE_SECONDS, st.CLOSE_ANSWER_SECONDS = 2.0, 0.3
def timed_close(answers_with_dialog):
    proc = spawn_sleeper()
    windows = [{"title": "Main", "class": "test-app", "pid": proc.pid, "address": "0x7"}]
    if answers_with_dialog:
        windows.append({"title": "Save changes?", "class": "test-app", "pid": proc.pid, "address": "0x8"})
    st.open_window_records = lambda: windows
    st.stale_window_groups = lambda since=None: [
        {"pid": proc.pid, "name": "Closer", "class": "test-app", "addresses": ["0x7"]}]
    started, closed_at = time.monotonic(), {}
    try:
        result = st.restart_stale_apps(
            None, between=lambda: closed_at.setdefault("t", time.monotonic()))
        alive = proc.poll() is None
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=2)
        kill_sleepers()
    return closed_at.get("t", time.monotonic()) - started, result, alive
ignored, ignored_result, _ = timed_close(False)
_, dialog_result, dialog_alive = timed_close(True)
chk("an application ignoring the close is ended well before the full grace",
    (ignored < st.WINDOW_CLOSE_GRACE_SECONDS, ignored_result[0]), (True, ["Closer"]))
chk("...one answering with a save dialog is never signalled, and is reported still open",
    (dialog_alive, dialog_result), (True, ([], ["Closer"], [])))
st.open_window_records = real_records
st.stale_window_groups = pristine_stale_window_groups
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- the close is sent in the form this Hyprland actually parses ------------
# Found live: under Omarchy's Lua config "closewindow address:..." fails to
# parse, and with its output discarded no window was ever asked to close --
# every "close" was the SIGTERM after it.
dispatched.clear()
st.close_window("0xabc")
chk("a close is sent as Lua, by address -- the form Omarchy's Lua config parses",
    dispatched, ['hl.dsp.window.close({ window = "address:0xabc" })'])
dispatched.clear()
chk("an address that is not one is never written into a dispatch",
    (st.close_window('0x1" }) hl.exec("x'), st.move_window_silently("0x1", '3" }) --'), dispatched),
    (False, False, []))
chk("workspaces are named the way a dispatch takes them",
    [st.workspace_selector(w) for w in ({"id": 3, "name": "3"}, {"id": -98, "name": "special:scratchpad"},
                                        {"id": 12, "name": "music"}, {"id": 4, "name": 'x"; os'}, None)],
    ["3", "special:scratchpad", "name:music", None, None])

# -- reopened windows go back to the workspaces they were on ----------------
real_records = st.open_window_records
st.PLACEMENT_SECONDS = 1.0
reopened = [{"title": "Docs - Vivaldi", "class": "vivaldi-stable", "pid": 9, "address": "0xb2", "workspace": "1"},
            {"title": "Mail - Vivaldi", "class": "vivaldi-stable", "pid": 9, "address": "0xb1", "workspace": "1"},
            {"title": "Terminal", "class": "kitty", "pid": 4, "address": "0xc0", "workspace": "1"}]
st.open_window_records = lambda: reopened
plan = {"windows": [{"address": "0xa1", "class": "vivaldi-stable", "title": "Mail - Vivaldi", "workspace": "3"},
                    {"address": "0xa2", "class": "vivaldi-stable", "title": "Docs - Vivaldi", "workspace": "special:scratchpad"}]}
dispatched.clear()
st.place_windows([plan], before={"0xc0"})
chk("each reopened window goes back to its original's workspace, matched by title",
    sorted(dispatched), sorted([
        'hl.dsp.window.move({ workspace = "3", follow = false, window = "address:0xb1" })',
        'hl.dsp.window.move({ workspace = "special:scratchpad", follow = false, window = "address:0xb2" })']))
chk("...silently, and never a window that was already open, or another application's",
    all("follow = false" in d and "0xc0" not in d for d in dispatched), True)
reopened[:] = [{"title": "New Tab", "class": "vivaldi-stable", "pid": 9, "address": "0xd1", "workspace": "3"}]
dispatched.clear()
st.place_windows([plan], before=set())
chk("unmatched by title, it takes the next original in order; already there, it is left",
    dispatched, [])
st.open_window_records = real_records

# -- a launcher that hands off and exits: judged by its window --------------
# Found live: VS Code's "code" starts the editor in the background and exits
# at once, and was reported "could not be restarted" while it came back fine.
real_records, real_cmdline, real_binary = st.open_window_records, st.process_cmdline, st.running_binary
st.WINDOW_CLOSE_GRACE_SECONDS, st.PLACEMENT_SECONDS = 0.3, 1.0
def handoff(window_returns):
    proc = spawn_sleeper()
    shown = []
    st.open_window_records = lambda: list(shown)
    st.process_cmdline = lambda pid: ["sh", "-c", "exit 0"] if pid == proc.pid else real_cmdline(pid)
    st.running_binary = lambda pid: shutil.which("sh") if pid == proc.pid else real_binary(pid)
    st.stale_window_groups = lambda since=None: [{
        "pid": proc.pid, "name": "Handoff", "class": "test-handoff", "addresses": ["0x50"],
        "windows": [{"address": "0x50", "class": "test-handoff", "title": "Editor", "workspace": "2"}]}]
    def between():
        if window_returns:
            # Appears once the relaunch has run, as the editor's would.
            import threading
            threading.Timer(0.5, lambda: shown.append(
                {"title": "Editor", "class": "test-handoff", "pid": 99, "address": "0x51", "workspace": "1"})).start()
    try:
        return st.restart_stale_apps(None, between=between)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=2)
chk("a launcher that exits at once is restarted when its window comes back",
    handoff(True), (["Handoff"], [], []))
chk("...and failed when no window of its own ever does", handoff(False), ([], [], ["Handoff"]))
st.open_window_records, st.process_cmdline, st.running_binary = real_records, real_cmdline, real_binary
st.stale_window_groups = pristine_stale_window_groups
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- relaunched windows open out of sight, then land where they were -------
# Found live: every relaunched window appeared on the workspace the user was
# on and visibly jumped away a moment later.
evaluated.clear()
st.hide_new_windows({"vivaldi-stable", "com.github.th-ch.youtube-music", 'x" }) hl.exec("y'})
chk("a rule sends the restarting apps' new windows to a hidden workspace, by class",
    evaluated, ['_G.omarchroma_restart_rule = hl.window_rule({ name = "omarchroma-restart", '
                'match = { class = "(?i)^(com\\\\.github\\\\.th\\\\-ch\\\\.youtube\\\\-music|vivaldi\\\\-stable)$" }, '
                'workspace = "special:omarchroma-restart silent" })'])
chk("...a class that is not a plain name is never written into it",
    'hl.exec' in evaluated[0], False)
real_records = st.open_window_records
st.open_window_records = lambda: [
    {"title": "Extra", "class": "vivaldi-stable", "pid": 9, "address": "0xe1", "workspace": "special:omarchroma-restart"},
    {"title": "Other", "class": "kitty", "pid": 4, "address": "0xe2", "workspace": "1"}]
dispatched.clear()
st.reveal_hidden_windows([{"windows": [{"class": "vivaldi-stable", "workspace": "3"}]}])
chk("a window left hidden goes to its application's own workspace; nothing else moves",
    dispatched, ['hl.dsp.window.move({ workspace = "3", follow = false, window = "address:0xe1" })'])
# The rule is switched off even when relaunching fails outright.
evaluated.clear()
real_relaunch = st.relaunch_and_place
def explode(closed, before):
    raise RuntimeError("relaunch failed")
st.relaunch_and_place = explode
proc = spawn_sleeper()
st.stale_window_groups = lambda since=None: [{
    "pid": proc.pid, "name": "Boom", "class": "test-boom", "addresses": ["0x60"],
    "windows": [{"address": "0x60", "class": "test-boom", "title": "T", "workspace": "2"}]}]
st.open_window_records = lambda: []
st.WINDOW_CLOSE_GRACE_SECONDS = 0.3
try:
    st.restart_stale_apps(None)
except RuntimeError:
    pass
finally:
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=2)
chk("...and the rule is switched off again even when relaunching fails",
    [e.split("(")[0] for e in evaluated], ["_G.omarchroma_restart_rule = hl.window_rule", "if _G.omarchroma_restart_rule then _G.omarchroma_restart_rule:set_enabled"])
st.relaunch_and_place, st.open_window_records = real_relaunch, real_records
st.stale_window_groups = pristine_stale_window_groups
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- one window: asked to close the way its close button would -------------
real_records = st.open_window_records
st.open_window_records = lambda: []
proc = spawn_sleeper()
st.stale_window_groups = lambda since=None: [
    {"pid": proc.pid, "name": "Single", "class": "test-single", "addresses": ["0x71"]}]
st.WINDOW_CLOSE_GRACE_SECONDS, st.CLOSE_ANSWER_SECONDS = 0.6, 0.2
closed_addresses.clear()
try:
    st.restart_stale_apps(None)
finally:
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=2)
    kill_sleepers()
chk("a single-window application is asked to close its window first",
    closed_addresses, ["address:0x71"])
st.open_window_records = real_records
st.stale_window_groups = pristine_stale_window_groups
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2

# -- mid-download or mid-copy: left open --------------------------------------
# Found live: a restart closed a file manager mid-transfer and a browser
# mid-download. A process writing to the user's own files is left alone.
scratch_home = Path(tempfile.mkdtemp())
real_home = st.Path.home
st.Path.home = staticmethod(lambda: scratch_home)
(scratch_home / "Downloads").mkdir()
(scratch_home / ".config").mkdir()
writer = subprocess.Popen([sys.executable, "-c",
    "import sys, time; f = open(sys.argv[1], 'w'); f.write('x'); f.flush(); time.sleep(60)",
    str(scratch_home / "Downloads" / "movie.mkv.crdownload")])
cfg = subprocess.Popen([sys.executable, "-c",
    "import sys, time; f = open(sys.argv[1], 'w'); time.sleep(60)", str(scratch_home / ".config" / "prefs")])
reader = subprocess.Popen([sys.executable, "-c",
    "import sys, time; open(sys.argv[1], 'w').close(); f = open(sys.argv[1]); time.sleep(60)",
    str(scratch_home / "Downloads" / "read.txt")])
time.sleep(0.4)
exe = st.running_binary(writer.pid)
found = st.writing_user_files(exe)
chk("a file being written in the user's own folders marks the application busy",
    any(f.endswith("movie.mkv.crdownload") for f in found), True)
chk("...its own configuration (a dot-directory) does not, nor a file only being read",
    any(f.endswith("prefs") or f.endswith("read.txt") for f in found), False)
real_writing = st.writing_user_files
st.writing_user_files = lambda e: ["/home/x/Downloads/a.crdownload"]
st.stale_window_groups = lambda since=None: [
    {"pid": writer.pid, "name": "Browser", "class": "test-browser", "addresses": ["0x81"]}]
closed_addresses.clear()
result = st.restart_stale_apps(None)
chk("...and a busy application is left open, said so, and not closed",
    (result, closed_addresses, writer.poll() is None),
    (([], ["Browser (busy writing a file)"], []), [], True))
st.writing_user_files = real_writing
st.stale_window_groups = pristine_stale_window_groups
st.Path.home = real_home
for proc in (writer, cfg, reader):
    proc.kill(); proc.wait(timeout=2)

# -- missing windows are opened through the new-window action ---------------
real_records, real_command = st.open_window_records, st.new_window_command
launched_windows = []
shown = [{"title": "Home", "class": "test-files", "pid": 5, "address": "0xf1", "workspace": "special:omarchroma-restart"}]
st.open_window_records = lambda: list(shown)
st.new_window_command = lambda klass: ["/bin/true", klass]
real_popen = st.subprocess.Popen
def fake_popen(argv, **kwargs):
    if argv[:1] == ["/bin/true"]:
        launched_windows.append(argv[1])
        shown.append({"title": "Home", "class": "test-files", "pid": 5, "address": "0xf2",
                      "workspace": "special:omarchroma-restart"})
    return real_popen(["true"])
st.subprocess.Popen = fake_popen
st.PLACEMENT_SECONDS, st.WINDOW_SETTLE_SECONDS = 2.0, 0.3
plan = {"windows": [{"address": "0xa1", "class": "test-files", "title": "Home", "workspace": "2"},
                    {"address": "0xa2", "class": "test-files", "title": "Downloads", "workspace": "5"}]}
dispatched.clear()
st.place_windows([plan], before=set())
st.subprocess.Popen = real_popen
chk("an application that came back with fewer windows has the rest opened for it",
    launched_windows, ["test-files"])
chk("...and every window, old or new, goes back to its own workspace",
    sorted(d.split('workspace = "')[1].split('"')[0] for d in dispatched), ["2", "5"])
st.open_window_records, st.new_window_command = real_records, real_command

# -- relaunch_environment: the session's, when the app's own reads empty ---
# Found live: Chromium and Electron reuse /proc/<pid>/environ for their
# process title, so Vivaldi and YouTube Music read back with no environment
# at all, and were relaunched with no display, no session bus and no runtime
# directory -- and exited at once.
real_environ, real_session = st.process_environ, st.session_environment
session = {"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": "wayland-1",
           "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"}
st.session_environment = lambda: session
st.process_environ = lambda pid: {}
chk("an application whose environment reads back empty gets the session's",
    st.relaunch_environment(1), session)
own = {"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": "wayland-1", "MY_FLAG": "1"}
st.process_environ = lambda pid: own
chk("...one whose own environment is real keeps exactly that",
    st.relaunch_environment(1), own)
st.process_environ, st.session_environment = real_environ, real_session
chk("the session environment parses bash's $'...' quoting systemctl uses",
    __import__("codecs").escape_decode(b"wayland,x11,*")[0].decode()
    + "|" + __import__("codecs").escape_decode(b"sh -c \\'col -bx\\'")[0].decode(),
    "wayland,x11,*|sh -c 'col -bx'")

# -- CLI: one line per name, grouped by outcome ------------------------------
import argparse, io, contextlib
root = Path(tempfile.mkdtemp())
(root / "status.json").write_text("{}")
st.stale_window_groups = lambda since=None: []
st.restart_stale_apps = lambda state_dir, since=None, between=None: (["Restarted1", "Restarted2"], ["Pending1"], ["Failed1"])
sys.argv = ["hyprchroma-state", "--state-dir", str(root), "--data-dir", str(root), "restart-stale-apps"]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    st.main()
lines = out.getvalue().splitlines()
chk("the CLI prints one labelled line per application", sorted(lines),
    sorted(["restarted Restarted1", "restarted Restarted2", "pending Pending1", "failed Failed1"]))
E

# -- bin/hyprchroma: the mode setting, the subcommand, and the force hook ---
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
unset DBUS_SESSION_BUS_ADDRESS
source "$REPO/tests/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/lib" "$ROOT/bin" "$XDG_STATE_HOME/hyprchroma"
cp "$REPO"/lib/hyprchroma-* "$REPO"/lib/sync-* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp -r "$REPO/share" "$ROOT/share"
SETTINGS="$XDG_STATE_HOME/hyprchroma/settings.json"
# Logs every call by subcommand, same as test-sync-lock.sh's stub, plus
# answers restart-stale-apps itself so the hook under test can be driven
# without touching a real process.
cat > "$ROOT/lib/hyprchroma-state" <<'STUB'
#!/usr/bin/env bash
prev="" command=""
for a in "$@"; do
  case $a in --state-dir|--data-dir|--path|--line|--mode|--target) ;; -*) ;; *)
    [[ $prev == --state-dir || $prev == --data-dir || $prev == --path || $prev == --line ||
       $prev == --mode || $prev == --target ]] || command=${command:-$a} ;;
  esac
  case $prev in
    --path) [[ $command == prepare-lock ]] && : > "$a"
            [[ $command == write-file ]] && cat > "$a"
            [[ $command == ensure-import ]] && echo "@import url(\"hyprchroma.css\");" > "$a" ;;
  esac
  prev=$a
done
echo "${command:-?}" >> "$HOME/state-calls.log"
[[ $command == restart-stale-apps ]] && echo "restarted Stale1"
exit 0
STUB
chmod +x "$ROOT/lib/hyprchroma-state"
cat > "$ROOT/lib/hyprchroma-dark-reader" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --info ]] && echo '{"installed": false, "signature": ""}'
exit 0
STUB
chmod +x "$ROOT/lib/hyprchroma-dark-reader"
sync() { bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; }

chk "no setting yet: the default is off" \
  "$(bash "$ROOT/bin/hyprchroma" restart-stale >/dev/null 2>&1; jq -r '.restartMode // "unset"' "$SETTINGS" 2>/dev/null || echo unset)" "unset"
sync --restart-mode=force
chk "--restart-mode=force is recorded" "$(jq -r .restartMode "$SETTINGS")" "force"
chk "...and does not run a sync to do it" \
  "$(grep -c '^event-pass$' "$ROOT/state-calls.log")" "0"
sync --restart-mode=confirm
chk "--restart-mode=confirm is recorded over it" "$(jq -r .restartMode "$SETTINGS")" "confirm"
sync --restart-mode=off
chk "--restart-mode=off is recorded the same way" "$(jq -r .restartMode "$SETTINGS")" "off"

: > "$ROOT/state-calls.log"
bash "$ROOT/bin/hyprchroma" restart-stale >"$ROOT/restart.out" 2>&1
chk "restart-stale calls the helper's restart-stale-apps" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "1"
chk "...and its report is in the output" "$(grep -c 'restarted: Stale1' "$ROOT/restart.out")" "1"
chk "...then re-records the stale list so the panel's count is current" \
  "$(grep -c '^report-stale-apps$' "$ROOT/state-calls.log")" "1"

# -- the force hook: fires only on a real change, with restartMode=force ----
: > "$ROOT/state-calls.log"
sed -i 's/"restartMode": *"[a-z]*"/"restartMode": "off"/' "$SETTINGS" 2>/dev/null || true
sync --force --quiet
chk "restartMode=off: a theme change does not call restart-stale-apps on its own" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "0"

python3 - "$SETTINGS" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
settings = json.loads(path.read_text()) if path.exists() else {}
settings["restartMode"] = "force"
path.write_text(json.dumps(settings))
PY
: > "$ROOT/state-calls.log"
# The restart is detached from the sync that starts it (its own inner sync
# needs the lock that sync holds), so it is waited for here, not assumed done.
settle_restart() {
  for _ in $(seq 50); do
    pgrep -f "$ROOT/bin/hyprchroma restart-stale" >/dev/null || return 0
    sleep 0.1
  done
}
sed -i 's/^background = .*/background = "#224466"/' "$HOME/.local/state/omarchy/current/theme/colors.toml"
sync --force --quiet; sleep 0.3; settle_restart
chk "restartMode=force: a real theme change calls it exactly once" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "1"
chk "...detached, so its own inner sync is not left waiting on this one's lock" \
  "$(grep -c 'setsid "$HYPRCHROMA_SELF" restart-stale' "$REPO/bin/hyprchroma")" "1"
: > "$ROOT/state-calls.log"
sync --force --quiet; sleep 0.3; settle_restart
chk "...and a sync that changes nothing after that does not call it again" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "0"
: > "$ROOT/state-calls.log"
sed -i 's/^background = .*/background = "#336655"/' "$HOME/.local/state/omarchy/current/theme/colors.toml"
HYPRCHROMA_NO_AUTO_RESTART=1 sync --force --quiet; sleep 0.3; settle_restart
chk "...nor does the restart's own inner sync, even on a real change" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "0"

rm -rf "$ROOT"

# -- the panel and bar widget: the shared key, the always-present button ----
cd -- "$REPO" || exit 1

chk "the guide's own key and the global hotkey's are the same one" \
  "$(grep -c 'key === "a" && root.staleWindowCount > 0' Panel.qml),$(grep -c 'key === "a"' Panel.qml)" "1,2"
chk "the global hotkey opens the same popup the guide's button does, via IPC" \
  "$(grep -c 'function restartStaleApps(): void' BarWidget.qml)" "1"
chk "...setting confirmRestartOpen and opening the panel" \
  "$(awk '/function restartStaleApps\(\)/,/^    }/' BarWidget.qml | grep -cE 'confirmRestartOpen = true|root.open\(\)')" "2"
guide_block=$(awk '/id: guide$/,/^        }$/' Panel.qml)
chk "Restart All's own button exists, gated only on there being something to restart" \
  "$(grep -c -F 'text: "Restart All  (a)"' <<<"$guide_block" || true),$(grep -B2 -F 'text: "Restart All  (a)"' <<<"$guide_block" | grep -c 'visible: root.staleWindowCount > 0' || true)" "1,1"
chk "...and nowhere does it gate on restartMode -- it is offered in every mode" \
  "$(grep -c 'visible:.*restartMode' <<<"$guide_block")" "0"
chk "all three modes are offered, and the write goes through the CLI flag" \
  "$(grep -c 'setRestartMode(mode)' Panel.qml),$(grep -cF -- '"--restart-mode=" + mode' Panel.qml)" "1,1"
chk "the popup can be answered with the same key, or Enter, or Space" \
  "$(grep -c 'onReturnRequested: if (root.confirmRestartOpen) root.confirmRestart()' Panel.qml),$(grep -c 'onActivateRequested: if (root.confirmRestartOpen) root.confirmRestart()' Panel.qml)" "1,1"
chk "Escape backs out of the popup before the guide, and the guide before the panel" \
  "$(awk '/onCloseRequested: \{/,/^      \}/' Panel.qml | grep -c 'confirmRestartOpen')" "1"
chk "restartMode=confirm opens the panel's own confirmation once the list is recorded" \
  "$(awk '/^report_stale_apps$/{r=NR} /omarchy-shell -q io.github.nobledoodle.omarchroma restartStaleApps/{print (r && r < NR) ? "after" : "before"; exit}' "$REPO/bin/hyprchroma")" "after"
chk "...only after a theme change that left something to restart" \
  "$(grep -B3 'omarchy-shell -q io.github.nobledoodle.omarchroma restartStaleApps' "$REPO/bin/hyprchroma" | grep -oE 'theme_changed|staleApps|== confirm' | sort -u | wc -l)" "3"
chk "...and the popup asks for the list afresh rather than trusting the file's timing" \
  "$(awk '/function restartStaleApps\(\)/,/^    }/' "$REPO/BarWidget.qml" | grep -c 'refreshStaleApps()')" "1"
