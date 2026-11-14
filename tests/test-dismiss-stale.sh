#!/usr/bin/env bash
# The restart pane's Dismiss: the applications still showing the previous theme
# stop being listed -- on the bar, in the guide and in the confirmation -- until
# the next theme change, and nothing is closed or restarted. Run against a
# throwaway home; window lists and restarts are stand-ins, never real.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

/usr/bin/python3 -I - "$REPO" <<'E'
import fcntl, json, os, sys, tempfile, threading, time, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / "run"))
for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
    os.environ.pop(name, None)
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

S = root / "state"; S.mkdir()
status_path = S / "status.json"
def status(): return json.loads(status_path.read_text())
def write(data): status_path.write_text(json.dumps(data))

first = "2026-11-14T10:00:00+00:00"
write({"theme": "Soul", "themeChangedAt": first, "lastSync": first})
open_windows = {"Firefox": 2, "Vivaldi": 1}
st.record_stale_apps(S, open_windows)
chk("(before Dismiss the stale applications are recorded)", status()["staleApps"], ["Firefox", "Vivaldi"])

chk("Dismiss succeeds when a theme change is recorded", st.dismiss_stale_apps(S), True)
chk("...records that change, and empties the list at once",
    (status()["staleDismissed"], status()["staleApps"], status()["staleWindows"]), (first, [], {}))
chk("...keeping the rest of the status", (status()["theme"], status()["lastSync"]), ("Soul", first))
st.record_stale_apps(S, open_windows)
chk("a window event after it records nothing stale", (status()["staleApps"], status()["staleWindows"]), ([], {}))
chk("...and the list the panel asks for is empty", st.stale_dismissed(S), True)

# The CLI paths the panel and the service use, with the window list and the
# restart replaced by stand-ins: dismissed, neither is consulted.
consulted = []
st.stale_open_windows = lambda since: consulted.append("windows") or dict(open_windows)
st.restart_stale_apps = lambda *args, **kwargs: consulted.append("restart") or (["Firefox"], [], [])
def cli(*argv):
    sys.argv = ["hyprchroma-state", "--state-dir", str(S), "--data-dir", str(root / "data"), *argv]
    from io import StringIO
    out, real = StringIO(), sys.stdout
    sys.stdout = out
    try:
        st.main()
    finally:
        sys.stdout = real
    return out.getvalue()
chk("report-stale-apps lists nothing once dismissed", cli("report-stale-apps", "--since-last-sync", "--record"), "")
chk("restart-stale-apps restarts nothing once dismissed", cli("restart-stale-apps"), "")
chk("...without even looking at the windows", consulted, [])

# The next theme change lists whatever it leaves behind.
st.mark_theme_changed(S)
chk("a theme change ends the dismissal", st.stale_dismissed(S), False)
chk("...so its stale applications are listed again",
    cli("report-stale-apps", "--since-last-sync", "--record").split(), ["Firefox", "(2", "windows)", "Vivaldi"])
chk("...and recorded for the bar", status()["staleApps"], ["Firefox", "Vivaldi"])
chk("...and Restart All works again", cli("restart-stale-apps").strip(), "restarted Firefox")

# Only an exact match dismisses; a broken status file dismisses nothing.
data = status(); data["staleDismissed"] = "2020-01-01T00:00:00+00:00"; write(data)
chk("a stamp from another change dismisses nothing", st.stale_dismissed(S), False)
data["staleDismissed"] = None; data.pop("themeChangedAt"); data.pop("lastSync"); write(data)
chk("with no change recorded, nothing is dismissed", (st.stale_dismissed(S), st.dismiss_stale_apps(S)), (False, False))
status_path.write_text("[1, 2]")
chk("a status file that is not an object dismisses nothing, and is left alone",
    (st.stale_dismissed(S), st.dismiss_stale_apps(S), status_path.read_text()), (False, False, "[1, 2]"))
status_path.unlink()
chk("with no status file at all, Dismiss is refused", st.dismiss_stale_apps(S), False)

# It waits for a running sync, as a waiter's write does, rather than
# interleaving with the sync's own read-modify-write of status.json.
write({"themeChangedAt": first, "lastSync": first, "staleApps": ["Firefox"]})
lock_path = root / "run" / "hyprchroma-sync.lock"
st.prepare_lock(lock_path)
held = open(lock_path, "r"); fcntl.flock(held, fcntl.LOCK_EX)
done = []
worker = threading.Thread(target=lambda: done.append((st.dismiss_stale_apps(S), time.monotonic())))
worker.start(); time.sleep(0.6)
chk("Dismiss waits while a sync holds the lock", (done, status()["staleApps"]), ([], ["Firefox"]))
released = time.monotonic(); held.close(); worker.join(10)
chk("...and goes through once it is released", (bool(done) and done[0][0], bool(done) and done[0][1] >= released), (True, True))
E

# --- the command and the panel ---------------------------------------------------
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
H=$ROOT/home; mkdir -p "$H/.local/state/hyprchroma" "$ROOT/run"; chmod 700 "$ROOT/run"
printf '{"themeChangedAt": "2026-11-14T10:00:00+00:00", "staleApps": ["Firefox"], "staleWindows": {"Firefox": 1}}\n' \
  > "$H/.local/state/hyprchroma/status.json"
env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME HOME="$H" XDG_RUNTIME_DIR="$ROOT/run" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$ROOT/no-bus" "$REPO/bin/hyprchroma" dismiss-stale; rc=$?
chk "hyprchroma dismiss-stale records the dismissal" \
  "$rc,$(/usr/bin/python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["staleDismissed"], s["staleApps"])' "$H/.local/state/hyprchroma/status.json")" \
  "0,2026-11-14T10:00:00+00:00 []"
chk "...and is in the help" "$("$REPO/bin/hyprchroma" --help 2>&1 | grep -c 'dismiss-stale')" "1"

P=$REPO/Panel.qml
chk "the guide and the confirmation each offer Dismiss (d), only while something is stale" \
  "$(grep -c 'text: "Dismiss  (d)"' "$P"),$(grep -B3 'text: "Dismiss  (d)"' "$P" | grep -c 'visible: root.staleWindowCount > 0')" "2,2"
chk "...and it runs hyprchroma dismiss-stale, on the trusted PATH" \
  "$(grep -A2 'id: dismissProcess' "$P" | grep -c 'command: \[ "/usr/bin/hyprchroma", "dismiss-stale" \]'),$(grep -A3 'id: dismissProcess' "$P" | grep -c 'PATH: root.trustedPath')" "1,1"
chk "\"d\" dismisses in the guide and in the confirmation, and is the only single key the confirmation takes" \
  "$(grep -c 'if (key === "d") root.dismissStale()' "$P"),$(sed -n '/if (root.confirmRestartOpen) {/,/^    }/p' "$P" | grep -c 'key ===')" "2,1"
chk "Dismiss and a confirmed restart both close the panel, not go back to its main view" \
  "$(sed -n '/^  function dismissStale() {/,/^  }/p' "$P" | grep -c '^    root.close()$'),$(sed -n '/^  function runRestart() {/,/^  }/p' "$P" | grep -c '^    root.close()$')" "1,1"
chk "Dismiss itself closes no application: it neither restarts nor quits" \
  "$(sed -n '/^  function dismissStale() {/,/^  }/p' "$P" | grep -cE 'runRestart|restartProcess|confirmRestart\(\)')" "0"
