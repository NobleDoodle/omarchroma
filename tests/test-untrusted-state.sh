#!/usr/bin/env bash
# What anything this account runs can plant -- status.json, OMARCHY_PATH, a
# directory the nobody account owns -- met with the attack itself rather than
# a grep for its fix. Each of these was found in the 2.9 review:
#
# - The panel drew stale application names from status.json as rich text, so
#   an <img> in a planted name had the shell fetch any address it gave: a
#   Flatpak app granted ~/.local/state could reach the network through it.
# - A themeChangedAt in the future made every idle application count as older
#   than the theme, so recycling quit them again on every window event.
# - Omarchy's scripts were read from $OMARCHY_PATH with a plain read, inside
#   the event pass and under the sync lock: a fifo there hung every sync.
# - The overflow uid, trusted because systemd's sandboxing shows root's /usr
#   under it, is the nobody account once the service runs unsandboxed.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# -- a planted name, drawn by the panel ----------------------------------------
cd -- "$REPO" || exit 1
format=$(awk '/id: staleName/,/^              }/' Panel.qml | grep -o 'textFormat: Text.PlainText')
chk "the panel draws each stale application's name as plain text" "$format" "textFormat: Text.PlainText"
validator=$(sed -n '/^  function validStaleName(name) {/,/^  }/p' Panel.qml)
chk "...and checks each name before keeping it" "$(grep -c 'return typeof name' <<<"$validator")" "1"
chk "...whether it came from status.json or from the service's own answer" \
  "$(grep -c 'names.filter(root.validStaleName)' Panel.qml),$(grep -c '!root.validStaleName(name)' Panel.qml)" "1,1"

QML=/usr/lib/qt6/bin/qml
if [[ -x $QML ]]; then
  # A listener on loopback only, recording what it is asked for.
  python3 - "$ROOT/hits" > "$ROOT/port" <<'E' &
import http.server, socketserver, sys, threading
hits = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(hits, "a") as log:
            log.write(self.path + "\n")
        self.send_response(404); self.end_headers()
    def log_message(self, *args): pass
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
threading.Timer(20, server.shutdown).start()
server.serve_forever()
E
  listener=$!
  for _ in {1..40}; do [[ -s $ROOT/port ]] && break; sleep 0.05; done
  port=$(<"$ROOT/port"); : > "$ROOT/hits"
  # The name exactly as a planted status.json would hand it over, drawn with the
  # panel's own setting, beside the default the panel used before -- which
  # shows the probe can see a fetch at all.
  cat > "$ROOT/probe.qml" <<EOF
import QtQuick
Item {
  width: 400; height: 120
  property string planted: '<img src="http://127.0.0.1:$port/panel">Vivaldi'
  property string control: '<img src="http://127.0.0.1:$port/control">Vivaldi'
$validator
  Text { text: "•  " + parent.planted; $format }
  Text { y: 40; text: "•  " + parent.control }
  Component.onCompleted: console.warn("valid:", [planted, "Vivaldi", "Visual Studio Code",
    "Tab\tname", "x".repeat(65), "", 42].map(validStaleName).join(","))
  Timer { interval: 2500; running: true; onTriggered: Qt.quit() }
}
EOF
  # Offscreen and touching no display: the desktop's gtk3 platform theme would
  # otherwise go looking for one, and fail outright in the runner's home.
  out=$(env -u DISPLAY -u WAYLAND_DISPLAY -u QT_QPA_PLATFORMTHEME QT_FORCE_STDERR_LOGGING=1 \
    QT_QPA_PLATFORM=offscreen timeout 15 "$QML" "$ROOT/probe.qml" 2>&1)
  kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
  chk "the probe sees a fetch where a name is drawn as rich text" "$(grep -c '^/control$' "$ROOT/hits")" "1"
  chk "a name planted with an <img> makes the panel fetch nothing" "$(grep -c '^/panel$' "$ROOT/hits")" "0"
  chk "...and is refused outright, as are control characters, overlong names and non-strings" \
    "$(grep -o 'valid: .*' <<<"$out")" "valid: false,true,true,false,false,false,false"
else
  echo "  SKIP the offscreen probe: no $QML"
fi

# -- the helper: baseline, Omarchy's scripts, the overflow uid -----------------
python3 - "$REPO" "$ROOT" <<'E'
import json, os, sys, threading, time, types
from datetime import datetime, timezone
from pathlib import Path

REPO, ROOT = sys.argv[1], Path(sys.argv[2])
os.environ.update(HOME=str(ROOT / "home"), XDG_RUNTIME_DIR=str(ROOT / "run"))
def load(name):
    path = f"{REPO}/lib/{name}"
    module = types.ModuleType(name.replace("-", "_"))
    module.__dict__["__file__"] = path
    exec(compile(open(path).read(), path, "exec"), module.__dict__)
    return module
st = load("hyprchroma-state")

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))
iso = lambda epoch: datetime.fromtimestamp(epoch, timezone.utc).isoformat()

S = ROOT / "state"; S.mkdir()
now = int(time.time())
(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(now + 3600)}))
chk("a theme-change moment in the future is refused", st.theme_changed_at(S), None)
st.theme_switched_at = lambda: 12345
chk("...and the baseline falls back to the theme switch itself", st.stale_baseline(S), 12345)
(S / "status.json").write_text(json.dumps({"themeChangedAt": iso(now - 30)}))
chk("a moment in the past still counts", st.theme_changed_at(S), now - 30)
(S / "status.json").write_text(json.dumps({"themeChangedAt": "99999-01-01"}))
chk("...and one that is not a date at all is refused, not raised", st.theme_changed_at(S), None)

# A fifo where an Omarchy script is expected.
bin_dir = ROOT / "omarchy" / "bin"; bin_dir.mkdir(parents=True)
(bin_dir / "omarchy-theme-set").write_text("#!/bin/bash\nfoo --reload\n")
os.mkfifo(bin_dir / "omarchy-restart-planted")
st.OMARCHY_PACKAGED_BIN = ROOT / "absent"
os.environ["OMARCHY_PATH"] = str(ROOT / "omarchy")
st.running_executables = lambda: {"foo", "bar"}
result = {}
worker = threading.Thread(target=lambda: result.update(names=st.omarchy_reloaded_executables()), daemon=True)
worker.start(); worker.join(5)
chk("a fifo planted among Omarchy's scripts is skipped rather than waited on",
    (worker.is_alive(), sorted(result.get("names", []))), (False, ["foo"]))
if worker.is_alive():
    # Release it, so the check above is the only casualty.
    os.close(os.open(bin_dir / "omarchy-restart-planted", os.O_WRONLY | os.O_NONBLOCK))

# The overflow uid: trusted only where the namespace leaves it unmapped.
for name in ("hyprchroma-state", "hyprchroma-dark-reader", "hyprchroma-palette"):
    module = load(name)
    def with_map(text, module=module):
        real = module.pathlib_read
        module.pathlib_read = lambda path: text if path == "/proc/self/uid_map" else (
            "65534" if path == "/proc/sys/kernel/overflowuid" else real(path))
        try:
            return module._overflow_uid()
        finally:
            module.pathlib_read = real
    chk(f"{name}: in the host namespace the overflow uid is nobody, trusted with nothing",
        with_map("         0          0 4294967295"), -1)
    chk(f"{name}: under systemd's sandboxing it stands for unmapped owners, and is trusted",
        with_map("      1000       1000          1"), 65534)
    chk(f"{name}: a namespace that maps it makes it a real account again",
        with_map("         0     100000      65536"), -1)
    def unreadable(path, module=module):
        raise OSError("no map")
    real = module.pathlib_read
    module.pathlib_read = lambda path: "65534" if path.endswith("overflowuid") else unreadable(path)
    chk(f"{name}: with no map to read, it is trusted with nothing", module._overflow_uid(), -1)
    module.pathlib_read = real

# The directory walk, where it matters: a directory the nobody account owns.
for name in ("hyprchroma-state", "hyprchroma-dark-reader"):
    module = load(name)
    nobody_dir = os.stat_result((0o040755, 1, 1, 2, 65534, 65534, 0, 0, 0, 0))
    module.os = types.SimpleNamespace(fstat=lambda descriptor: nobody_dir, geteuid=os.geteuid)
    def walks(module=module):
        try:
            module._verify_directory(0, "/tmp/planted")
            return True
        except OSError:
            return False
    module._OVERFLOW_UID = -1
    chk(f"{name}: in the host namespace a directory owned by nobody is refused", walks(), False)
    module._OVERFLOW_UID = 65534
    chk(f"{name}: under systemd's sandboxing the same owner is the unmapped stand-in", walks(), True)
E

# -- the same rule in every shell entry point ------------------------------------
cd -- "$REPO" || exit 1
mapped_map=$ROOT/uid_map_full
printf '         0          0 4294967295\n' > "$mapped_map"
private_ok=0
unshare --user --map-current-user true 2>/dev/null && private_ok=1
for f in bin/hyprchroma bin/hyprchroma-setup lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma; do
  fn=$(grep -oE '^[a-z_]+_trusted_path\(\)' "$f" | tr -d '()')
  # The fallback is swapped for a marker, so passing the owner check cannot be
  # confused with falling back to the fixed PATH.
  # shellcheck disable=SC2016  # a literal ${...}, matched rather than expanded
  body=$(sed -n "/^$fn()/,/^}/p" "$f" | sed 's|\${trusted:-/usr/bin:/usr/share/omarchy/bin}|${trusted:-FALLBACK}|')
  chk "$f: /usr/bin is trusted as root's here" "$(bash -c "$body; $fn" | cut -d: -f1)" "/usr/bin"
  if (( private_ok )); then
    chk "$f: ...and as the unmapped stand-in under a namespace mapping only this account" \
      "$(unshare --user --map-current-user bash -c "$body; $fn" | cut -d: -f1)" "/usr/bin"
    # The same namespace, told that the overflow uid is mapped: /usr/bin, which
    # it sees under that uid, now belongs to a real account and is refused.
    chk "$f: ...but not where that uid is a real account" \
      "$(unshare --user --map-current-user bash -c "${body//\/proc\/self\/uid_map/$mapped_map}; $fn")" "FALLBACK"
  else
    echo "  SKIP $f: no unprivileged user namespace to check the unmapped case in"
  fi
done
