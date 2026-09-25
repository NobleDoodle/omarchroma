#!/usr/bin/env bash
# Dark Reader's settings live in each browser's own database, locked while the
# browser runs, so a theme change made with a browser open waits for it to
# exit. The waiter that did that looked the helper up in ~/.local/bin, where
# the pre-package installer used to leave shims. With those gone it raised
# FileNotFoundError on its first line, every time, into /dev/null -- nothing
# waited at all, and the write landed only if some unrelated window event
# happened to run a full sync after the browser's last process ended. Reopen
# the browser before that, and it kept the previous theme until closed again.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
ROOT=$(mktemp -d)
export HOME=$ROOT XDG_RUNTIME_DIR=$ROOT/run
mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/state" "$ROOT/data" "$ROOT/elsewhere"

python3 - "$REPO" "$ROOT" <<'E'
import json, os, subprocess, sys, time, types
from pathlib import Path

repo, root = Path(sys.argv[1]), Path(sys.argv[2])
src = (repo / "lib/hyprchroma-state").read_text()
st = types.ModuleType("st")
st.__dict__["__file__"] = str(repo / "lib/hyprchroma-state")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

state, data = root / "state", root / "data"
helper = str(repo / "lib/hyprchroma-dark-reader")

# -- where the helper comes from ------------------------------------------
chk("the helper is the one installed beside this module",
    st.dark_reader_helper(), helper)
chk("...never one under the home directory",
    st.dark_reader_helper().startswith(str(root)), False)

# -- a helper that cannot run is "cannot tell", not "no browser" -----------
st.__dict__["__file__"] = str(root / "elsewhere/hyprchroma-state")
chk("a missing helper reports that it cannot tell, rather than crashing",
    st.browser_client_groups(), None)
st.__dict__["__file__"] = str(repo / "lib/hyprchroma-state")

# -- what the waiter runs, and when ----------------------------------------
def settings(dark_reader):
    (state / "settings.json").write_text(json.dumps({"frameworks": {"darkReader": dark_reader}}))

commands = []

def waiter(groups_sequence, returncodes=(0,), action="sync"):
    """Drive watch_browser_exit through scripted browsers; return what it ran.
    Each step is what --info reports open: one list of PIDs per browser."""
    ran, groups, codes = [], list(groups_sequence), list(returncodes)
    commands.clear()
    st.browser_client_groups = lambda: groups.pop(0) if groups else []
    def run(command, check=False):
        commands.append(command)
        ran.append(command[1])  # --theme for an apply, --restore for a revert
        return types.SimpleNamespace(returncode=codes.pop(0) if codes else 0)
    st.subprocess = types.SimpleNamespace(run=run)
    st.watch_browser_exit(state, data, action)
    return ran

settings(True)
chk("no browser with Dark Reader open and it on: the theme is applied",
    waiter([[]]), ["--theme"])
chk("...by the helper itself, not a whole sync that has to win the sync lock",
    commands[0][0], helper)
chk("...with the theme file the queuing sync generated",
    commands[0][2], str(data / "dark-reader-theme.json"))

settings(False)
chk("switched off while waiting: the revert that toggle queued is done instead",
    waiter([[]]), ["--restore"])
settings(True)
chk("a revert waiter reverts", waiter([[]], action="revert"), ["--restore"])

chk("the helper unable to say what is open: nothing is run",
    waiter([None]), [])

# Reopened in the moment before the write: the helper finds it back and says
# 2, so the waiter waits for that instance too, then writes once it is gone.
reopened = subprocess.Popen(["sleep", "0.3"])
chk("a browser reopened before the write is waited out, then written",
    waiter([[], [[reopened.pid]], []], returncodes=(2, 0)), ["--theme", "--theme"])
reopened.wait()

# -- how soon after the last process ends the write starts -----------------
# The whole complaint was a delay, so this is measured against a real process
# rather than assumed from the pidfd design.
browser = subprocess.Popen(["sleep", "0.5"])
ended = {}
st.browser_client_groups = lambda: [[browser.pid]] if browser.poll() is None else []
def run(command, check=False):
    ended.setdefault("at", time.monotonic())
    return types.SimpleNamespace(returncode=0)
st.subprocess = types.SimpleNamespace(run=run)
start = time.monotonic()
st.watch_browser_exit(state, data, "sync")
browser.wait()
lag = ended["at"] - start - 0.5
chk(f"the write starts within 0.2s of the browser's last process ending",
    lag < 0.2, True)

# -- two browsers: the one that closes is themed without waiting on the other -
# Helium closes while Firefox stays open all afternoon: Helium's profile is
# written as soon as Helium is gone, not when every browser has finished.
closes = subprocess.Popen(["sleep", "0.3"])
stays = subprocess.Popen(["sleep", "30"])
closes_tabs = subprocess.Popen(["sleep", "0.1"])   # a renderer that went first
ended.clear()
def open_now():
    groups = [[pid.pid for pid in (closes, closes_tabs) if pid.poll() is None],
              [stays.pid]]
    return [group for group in groups if group]
st.browser_client_groups = open_now
st.subprocess = types.SimpleNamespace(run=run)
start = time.monotonic()
st.watch_browser_exit(state, data, "sync")
chk("with two browsers open, the one that closes is written straight away",
    ended["at"] - start < 1.0, True)
chk("...only once all of its own processes are gone, not at its first to exit",
    ended["at"] - start >= 0.3, True)
stays.kill(); stays.wait(); closes.wait(); closes_tabs.wait()
E
rm -rf "$ROOT"
