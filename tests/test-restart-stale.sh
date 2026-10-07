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

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# Shortened for the test; what is under test is the escalation order and the
# final outcome, not how many seconds each rung is given in production.
st.WINDOW_CLOSE_GRACE_SECONDS = 0.2
st.SIGNAL_GRACE_SECONDS = 0.3

closed_addresses = []
real_subprocess_run = subprocess.run
# st.subprocess is the real subprocess module, the same object this script
# imported -- Python caches it by name -- so patching .run here reaches every
# caller of it, including, further down, this very script's own use of it to
# compile the two probes the PATH-poisoning check needs. Only a hyprctl
# dispatch call is faked; everything else is the real subprocess.run, so a
# write-a-marker-and-wait probe is not needed to prove gcc actually ran.
def fake_run(command, **kwargs):
    if command[:2] == ["hyprctl", "dispatch"]:
        closed_addresses.append(command[3])
        return types.SimpleNamespace(returncode=0)
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
        {"pid": proc.pid, "name": "App", "addresses": ["0x111", "0x222"]}]
    restarted, pending, failed = st.restart_stale_apps(None)
    chk("hyprctl is asked to close every window the group listed",
        sorted(closed_addresses), ["address:0x111", "address:0x222"])
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
        {"pid": stubborn.pid, "name": "Stubborn", "addresses": ["0x999"]}]
    restarted, pending, failed = st.restart_stale_apps(None)
    chk("a process nothing can close is reported pending, not restarted",
        (restarted, pending, failed), ([], ["Stubborn"], []))
    st.os.kill = real_kill
finally:
    if stubborn.poll() is None:
        stubborn.kill(); stubborn.wait(timeout=2)

# -- gone between listing and acting: failed, and nothing is launched -------
gone = subprocess.Popen(["true"]); gone.wait()
closed_addresses.clear()
st.stale_window_groups = lambda since=None: [
    {"pid": gone.pid, "name": "Gone", "addresses": ["0x000"]}]
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
    victim = subprocess.Popen(["probe", str(outcome)],
                              executable=str(real_bin), env=poisoned_env)
    for _ in range(50):
        if outcome.exists():
            break
        time.sleep(0.05)
    try:
        closed_addresses.clear()
        st.stale_window_groups = lambda since=None: [
            {"pid": victim.pid, "name": "Probe", "addresses": ["0x1"]}]
        restarted, pending, failed = st.restart_stale_apps(None)
        chk("the relaunch ran the real binary", (restarted, outcome.read_text()),
            (["Probe"], "genuine"))
        chk("...never the one a poisoned PATH entry would have resolved to first",
            outcome.read_text(), "genuine")
    finally:
        subprocess.run(["pkill", "-9", "-f", str(real_bin)], check=False)

# -- CLI: one line per name, grouped by outcome ------------------------------
import argparse, io, contextlib
root = Path(tempfile.mkdtemp())
(root / "status.json").write_text("{}")
st.stale_window_groups = lambda since=None: []
st.restart_stale_apps = lambda state_dir, since=None: (["Restarted1", "Restarted2"], ["Pending1"], ["Failed1"])
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
sed -i 's/^background = .*/background = "#224466"/' "$HOME/.local/state/omarchy/current/theme/colors.toml"
sync --force --quiet
chk "restartMode=force: a real theme change calls it exactly once" \
  "$(grep -c '^restart-stale-apps$' "$ROOT/state-calls.log")" "1"
: > "$ROOT/state-calls.log"
sync --force --quiet
chk "...and a sync that changes nothing after that does not call it again" \
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
