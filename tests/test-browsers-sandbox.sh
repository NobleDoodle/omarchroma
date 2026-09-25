#!/usr/bin/env bash
# A Flatpak browser writes its profile inside its sandbox, under ~/.var/app/<id>,
# and this service reads and writes that same folder from outside the sandbox.
# So everything below that folder is treated as hostile: a link planted there
# must stop a walk rather than steer a write or a removal out of the sandbox, a
# fifo where a file belongs must not block the unattended service, and a file
# built to break a parser must not break every sync after it. Each attack here
# was demonstrated against the first version of the framework before the fix.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import json, os, signal, stat, sys, tempfile, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ["HOME"] = str(root)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)
dr = types.ModuleType("dr")
dr.__dict__["__file__"] = REPO + "/lib/hyprchroma-dark-reader"
exec(compile(open(dr.__file__).read(), "dr", "exec"), dr.__dict__)
st.vivaldi_pids = lambda: []
st.spawn_browsers_waiter = lambda *a: None

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

class Hung(Exception):
    pass
def alarm(*_):
    raise Hung()
signal.signal(signal.SIGALRM, alarm)
def bounded(call, seconds=5):
    """call(), or "hung" if it blocks: a hang is a failure, not a stuck suite."""
    signal.alarm(seconds)
    try:
        return call()
    except Hung:
        return "hung"
    finally:
        signal.alarm(0)

S, D = root / "state", root / "share"
S.mkdir(); D.mkdir()
(D / "browsers-theme.json").write_text(json.dumps({
    "mode": "dark", "background": "#1a1b26", "dark_background": "#16161e", "foreground": "#c0caf5",
    "accent": "#7aa2f7", "selection": "#33467c", "selection_foreground": "#c0caf5", "muted": "#565f89"}))
def sync(revert=False):
    return bounded(lambda: st.sync_browsers(S, D, revert=revert, spawn=False))
def manifest():
    return st.read_json(S / "original/manifest.json")

# Things outside every sandbox that a planted link might aim at.
gtk = root / ".config/gtk-3.0"; gtk.mkdir(parents=True)
GTK = "@define-color window_bg_color #123456;\n"
(gtk / "hyprchroma.css").write_text(GTK)
secret = root / "secret.txt"; secret.write_text("private\n")

APP = root / ".var/app/org.mozilla.firefox"
FF = APP / ".mozilla/firefox"
def profiles_ini(*names):
    FF.mkdir(parents=True, exist_ok=True)
    (FF / "profiles.ini").write_text("".join(
        f"[Profile{n}]\nIsRelative=1\nPath={name}\n\n" for n, name in enumerate(names)))

# -- a fifo where a file belongs never blocks the service ----------------------
FF.mkdir(parents=True)
os.mkfifo(FF / "profiles.ini")
chk("a fifo planted as profiles.ini is skipped, not waited on",
    sync(), ("not-installed", "no supported browser found", []))
(FF / "profiles.ini").unlink()

VIV = root / ".var/app/com.vivaldi.Vivaldi/config/vivaldi"
(VIV / "Default").mkdir(parents=True)
(VIV / "Default/Preferences").write_text("{}")
os.mkfifo(VIV / "Local State")
chk("...and as Vivaldi's Local State, whose profiles then go unlisted",
    sync(), ("not-installed", "no supported browser found", []))
(VIV / "Local State").unlink()

# -- a file built to break the parser breaks nothing ---------------------------
(VIV / "Local State").write_text("[" * 200000)
chk("a Local State nested past the parser's depth does not crash the sync",
    sync(), ("not-installed", "no supported browser found", []))
(VIV / "Local State").write_text(json.dumps({"profile": {"info_cache": {"Default": {}}}}))
(VIV / "Default/Preferences").write_text('{"a":' * 200000 + "1" + "}" * 200000)
state, summary, _ = sync()
chk("...nor do Preferences nested that deep: that profile is left alone",
    (state, summary), ("synchronized", "could not safely change a profile of Vivaldi"))
os.remove(VIV / "Default/Preferences"); os.mkfifo(VIV / "Default/Preferences")
chk("a fifo planted as Preferences is skipped too", sync()[1],
    "could not safely change a profile of Vivaldi")
os.remove(VIV / "Default/Preferences")
(VIV / "Default/Preferences").write_text("{}")

# -- no link below the sandbox's own folder is followed ------------------------
profiles_ini("p.default")
P = FF / "p.default"; P.mkdir()
(P / "chrome").symlink_to(gtk)
state, summary, _ = sync()
chk("a chrome folder linked out of the sandbox is refused",
    summary, "Vivaldi; could not safely change a profile of Firefox")
chk("...so the GTK stylesheet it points at is not overwritten",
    ((gtk / "hyprchroma.css").read_text(), sorted(p.name for p in gtk.iterdir())),
    (GTK, ["hyprchroma.css"]))
sync(revert=True)
chk("...and a revert does not remove it", (gtk / "hyprchroma.css").read_text(), GTK)
(P / "chrome").unlink()

(P / "prefs.js").symlink_to(secret)
state, summary, _ = sync()
chk("a linked prefs.js is never read for the capture",
    manifest()["browsers"]["firefox"][str(P)]["stylesheetsPref"], False)
sync(revert=True)
chk("...and never rewritten on revert", (secret.read_text(), (P / "prefs.js").is_symlink()),
    ("private\n", True))
(P / "prefs.js").unlink()

# The sandbox swaps its own profiles root for a link out of it.
(FF / "profiles.ini").rename(root / "profiles.ini.away")
os.rename(APP / ".mozilla", APP / ".mozilla.away")
outside = root / "outside/firefox"; outside.mkdir(parents=True)
(outside / "profiles.ini").write_text("[Profile0]\nIsRelative=1\nPath=victim\n")
(outside / "victim").mkdir()
(APP / ".mozilla").symlink_to(root / "outside")
chk("a profiles root that is itself a link out of the sandbox finds nothing",
    [n for n, _, _ in st.detected_browsers()], ["Vivaldi"])
sync()
chk("...and nothing is written where it points", sorted(p.name for p in (outside / "victim").iterdir()), [])
(APP / ".mozilla").unlink()
os.rename(APP / ".mozilla.away", APP / ".mozilla")
(root / "profiles.ini.away").rename(FF / "profiles.ini")

# A profile folder swapped for a link between finding it and writing to it.
found = [p for _, family, profiles in st.detected_browsers() if family == "firefox" for p in profiles]
chk("the profile is found while it is a folder", [p.name for p in found], ["p.default"])
os.rename(P, FF / "p.away")
P.symlink_to(root / "outside/firefox/victim")
try:
    st.sync_firefox_profile(found[0], "/* x */", {}); raced = "written"
except OSError:
    raced = "refused"
chk("...and once swapped for a link, writing to it is refused", raced, "refused")
chk("...leaving where the link points untouched", sorted(p.name for p in (outside / "victim").iterdir()), [])
P.unlink(); os.rename(FF / "p.away", P)

# -- a revert that can never finish is not retried forever ---------------------
state, _, _ = sync()
chk("themed while the profile exists", str(P) in manifest()["browsers"]["firefox"], True)
os.rename(P, FF / "p.gone")   # the user deletes the profile
sync(revert=True)
chk("a revert for a profile since deleted drops its capture", "browsers" in manifest(), False)
os.rename(FF / "p.gone", P)
sync()
(FF / "profiles.ini").unlink(); (VIV / "Local State").unlink(); (VIV / "Default/Preferences").unlink()
chk("...and so does one for a browser since uninstalled",
    (sync(revert=True)[0], "browsers" in manifest()), ("not-installed", False))
profiles_ini("p.default")

# -- line endings are the user's -----------------------------------------------
(P / "chrome").mkdir(exist_ok=True)
CRLF = b"/* mine */\r\n#nav-bar { order: 1; }\r\n"
(P / "chrome/userChrome.css").write_bytes(CRLF)
sync(); sync(revert=True)
chk("a userChrome.css with CRLF line endings comes back byte for byte",
    (P / "chrome/userChrome.css").read_bytes(), CRLF)

# -- the same guard everywhere a foreign file is read --------------------------
os.mkfifo(root / "fifo")
chk("read_capped returns nothing for a fifo rather than blocking",
    bounded(lambda: st.read_capped(root / "fifo")), None)
chk("...read_capped_bytes too", bounded(lambda: st.read_capped_bytes(root / "fifo")), None)
chk("...safe_read too", bounded(lambda: st.safe_read(root / "fifo", 100)), None)
chk("...and the Dark Reader helper's reader", bounded(lambda: dr.read_capped(root / "fifo")), None)
(root / "deep.json").write_text("[" * 200000)
chk("the Dark Reader helper survives a nesting bomb", dr.read_capped_json(root / "deep.json"), {})
pear = root / ".config/YouTube Music"; pear.mkdir(parents=True)
(pear / "config.json").write_text("[]")
try:
    st.rewrite_pear_themes(lambda themes: themes + ["x"]); pear_result = "no crash"
except Exception as error:
    pear_result = type(error).__name__
chk("a Pear config that is not an object is left alone rather than crashing",
    (pear_result, (pear / "config.json").read_text()), ("no crash", "[]"))
E

# -- the helpers still share one writer --------------------------------------
cd -- "$REPO" || exit 1
same=$(python3 - <<'PY'
import pathlib
def core(n):
    s = pathlib.Path(n).read_text()
    return s[s.index("# ------"):s.index("def prepare_lock")]
print("same" if core("lib/hyprchroma-state") == core("lib/hyprchroma-dark-reader") else "drifted")
PY
)
[[ $same == same ]] && echo "  PASS the descriptor-relative writer is the shared one" ||
  echo "  FAIL the descriptor-relative writer is the shared one: $same"
