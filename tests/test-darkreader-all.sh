#!/usr/bin/env bash
# Dark Reader is themed wherever it is installed: every profile of every
# supported browser that has it, not only the default browser's current one.
# Each profile is captured once, before anything is written over it, and a
# revert puts each back; a browser that is open waits while the rest go ahead.
# The releases that themed one browser left a capture of the first default
# browser only -- a browser themed after the default changed had none -- so
# that capture is migrated, and such a browser is reset rather than left themed.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
python3 -c "import plyvel" 2>/dev/null || { echo "  SKIP (python-plyvel not installed)"; exit 0; }

python3 - "$REPO" <<'E'
import base64, json, os, shutil, sqlite3, subprocess, sys, tempfile, time, types
from pathlib import Path
import plyvel

REPO = sys.argv[1]
home = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ["HOME"] = str(home)
helper = REPO + "/lib/hyprchroma-dark-reader"
dr = types.ModuleType("dr")
dr.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "dr", "exec"), dr.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

STORE, FIREFOX_ID = dr.CHROMIUM_STORE_EXTENSION_ID, dr.FIREFOX_EXTENSION_ID
real_target_pids = dr.target_pids
running = set()   # profiles whose browser is open, for the tests below
dr.target_pids = lambda target: [4242] if target.profile.name in running else []

# -- a machine with Dark Reader in some profiles of some browsers --------------
def chromium_profile(root, name, dark_reader, cache=None):
    profile = home / root / name
    profile.mkdir(parents=True)
    (profile / "Preferences").write_text("{}")
    if dark_reader:
        (profile / "Extensions" / STORE).mkdir(parents=True)
    local = home / root / "Local State"
    names = json.loads(local.read_text())["profile"]["info_cache"] if local.exists() else {}
    names.update({name: {}}, **(cache or {}))
    local.write_text(json.dumps({"profile": {"info_cache": names, "last_used": "Default"}}))
    return profile

def firefox_profile(root, name, dark_reader, absolute=False):
    base = home / root
    profile = base / name
    profile.mkdir(parents=True)
    (profile / "prefs.js").write_text("")
    if dark_reader:
        (profile / "extensions.json").write_text(json.dumps({"addons": [{"id": FIREFOX_ID, "active": True}]}))
    ini = base / "profiles.ini"
    text = ini.read_text() if ini.exists() else ""
    count = text.count("[Profile")
    path, relative = (str(profile), 0) if absolute else (name, 1)
    ini.write_text(text + f"[Profile{count}]\nName={name}\nIsRelative={relative}\nPath={path}\n\n")
    return profile

helium = chromium_profile(".config/net.imput.helium", "Default", True, cache={"../../escape": {}})
chromium_profile(".config/net.imput.helium", "Profile 1", False)
chromium = chromium_profile(".config/chromium", "Default", True)
firefox = firefox_profile(".mozilla/firefox", "a.default", True)
firefox_profile(".mozilla/firefox", "b.default", False)
(home / "escape").mkdir()
elsewhere = home / "elsewhere/x.default"
elsewhere.mkdir(parents=True)
(elsewhere / "extensions.json").write_text(json.dumps({"addons": [{"id": FIREFOX_ID}]}))
with open(home / ".mozilla/firefox/profiles.ini", "a") as ini:
    ini.write(f"[Profile9]\nIsRelative=0\nPath={elsewhere}\n")
zen = firefox_profile(".config/zen", "z.default", True)

targets = dr.dark_reader_targets()
chk("every profile with Dark Reader, in every browser, is found",
    sorted((t.name, t.profile.name) for t in targets),
    [("Chromium", "Default"), ("Firefox", "a.default"), ("Helium", "Default"), ("Zen Browser", "z.default")])
chk("...not a profile of the same browser without it", "Profile 1" in [t.profile.name for t in targets], False)
chk("...nor a profiles.ini entry outside the browser's folder",
    "x.default" in [t.profile.name for t in targets], False)

out = subprocess.run([helper, "--info"], capture_output=True, text=True, env=dict(os.environ, HOME=str(home)))
info = json.loads(out.stdout)
chk("--info names every browser it is in", (info["installed"], info["browsers"]),
    (True, ["Chromium", "Firefox", "Helium", "Zen Browser"]))
chk("...and a signature that changes with them", info["signature"].count(";"), 3)
chk("...without reading the process table, which only the waiter needs", "running" in info, False)
out = subprocess.run([helper, "--info", "--running"], capture_output=True, text=True,
                     env=dict(os.environ, HOME=str(home)))
chk("--info --running adds which of them are open", "running" in json.loads(out.stdout), True)

# Firefox's own settings for Dark Reader, there before Hyprchroma ever ran.
dr.write_firefox_storage_data(firefox / "storage-sync-v2.sqlite", {"enabled": False, "mine": 1})

# -- applied to all of them -----------------------------------------------------
state = home / "state"
status = state / "status.json"   # where the sync keeps it, and where a migration reads it
state.mkdir()
theme = home / "theme.json"
def write_theme(background):
    theme.write_text(json.dumps({"darkSchemeBackgroundColor": background, "stylesheet": ""}))
def chromium_theme(profile):
    with plyvel.DB(str(profile / "Sync Extension Settings" / STORE)) as db:
        return json.loads(db.get(b"theme"))["darkSchemeBackgroundColor"] if db.get(b"theme") else None
def firefox_data(profile):
    return dr.firefox_storage_data(profile / "storage-sync-v2.sqlite")
def snapshot():
    return json.loads((state / "original/dark-reader.json").read_text())

write_theme("#111111")
chk("with every browser closed, all of them are themed", dr.apply_theme(theme, state, status), 0)
chk("...Helium and Chromium", (chromium_theme(helium), chromium_theme(chromium)), ("#111111", "#111111"))
chk("...Firefox and Zen", (firefox_data(firefox)["theme"]["darkSchemeBackgroundColor"],
                           firefox_data(zen)["theme"]["darkSchemeBackgroundColor"]), ("#111111", "#111111"))
chk("...and the status lists them", json.loads(status.read_text())["darkReaderBrowsers"],
    ["Chromium", "Firefox", "Helium", "Zen Browser"])
chk("each profile is captured, keyed by where it is", sorted(Path(k).name for k in snapshot()["targets"]),
    ["Default", "Default", "a.default", "z.default"])
chk("...Firefox's own settings as they were", snapshot()["targets"][str(firefox)]["data"],
    {"enabled": False, "mine": 1})

write_theme("#222222")
dr.apply_theme(theme, state, status)
chk("a later theme leaves the captures as the originals",
    snapshot()["targets"][str(firefox)]["data"], {"enabled": False, "mine": 1})

# -- one browser open: the rest go ahead ----------------------------------------
running.add("a.default")
write_theme("#333333")
chk("with Firefox open, the others are themed and Firefox waits", dr.apply_theme(theme, state, status), 2)
chk("...Firefox untouched while it runs",
    firefox_data(firefox)["theme"]["darkSchemeBackgroundColor"], "#222222")
chk("...the rest have the new theme", (chromium_theme(helium), chromium_theme(chromium)), ("#333333", "#333333"))
chk("...and the status says which waits", (json.loads(status.read_text())["darkReader"],
                                           json.loads(status.read_text())["darkReaderPending"]),
    ("pending-browser-exit", ["Firefox"]))
running.clear()

# -- one broken profile does not stop the rest ---------------------------------
with sqlite3.connect(zen / "storage-sync-v2.sqlite") as connection:
    connection.execute("UPDATE storage_sync_data SET data = '[1, 2]' WHERE ext_id = ?", (FIREFOX_ID,))
write_theme("#444444")
chk("a profile whose stored settings are unusable fails, and says so", dr.apply_theme(theme, state, status), 1)
chk("...without stopping the others", chromium_theme(helium), "#444444")
chk("...and without overwriting what it could not read",
    sqlite3.connect(zen / "storage-sync-v2.sqlite").execute(
        "SELECT data FROM storage_sync_data WHERE ext_id = ?", (FIREFOX_ID,)).fetchone()[0], "[1, 2]")
with sqlite3.connect(zen / "storage-sync-v2.sqlite") as connection:
    connection.execute("DELETE FROM storage_sync_data WHERE ext_id = ?", (FIREFOX_ID,))

# -- reverted, each to its own original ----------------------------------------
dr.restore_theme(state, status)
chk("a revert puts Firefox's own settings back", firefox_data(firefox), {"enabled": False, "mine": 1})
with plyvel.DB(str(helium / "Sync Extension Settings" / STORE)) as db:
    chk("...and removes what Chromium-family profiles never had", (db.get(b"theme"), db.get(b"enabled")),
        (None, None))
chk("...in every browser", chromium_theme(chromium), None)
chk("...the status says so", json.loads(status.read_text())["darkReader"], "restored")

# -- the single-browser releases' capture ---------------------------------------
# Helium was the default and was captured; the default then became Firefox,
# which was themed with no capture at all.
(state / "original/dark-reader.json").write_text(json.dumps({
    "browser": "Helium", "browserDesktop": "helium.desktop", "browserFamily": "chromium",
    "browserProfile": str(helium), "database": str(helium / "Sync Extension Settings" / STORE),
    "entries": {"enabled": {"existed": True, "value": base64.b64encode(b"false").decode()}}}))
status.write_text(json.dumps({"darkReader": "synchronized", "browser": "Firefox",
                              "browserDesktop": "firefox.desktop", "browserProfile": str(firefox)}))
dr.write_firefox_storage_data(firefox / "storage-sync-v2.sqlite", {"theme": {"ours": True}})
with plyvel.DB(str(helium / "Sync Extension Settings" / STORE)) as db:
    db.put(b"enabled", b"true")
migrated = dr.load_snapshot(state)
chk("an old capture becomes one entry per profile",
    sorted((Path(k).name, v["captured"]) for k, v in migrated["targets"].items()),
    [("Default", True), ("a.default", False)])
chk("...written back at once, before a status write drops what it was built from",
    snapshot().get("version"), 2)
# Themed once under the new release -- which drops the old status fields --
# and only then switched off.
write_theme("#666666")
dr.apply_theme(theme, state, status)
dr.write_firefox_storage_data(firefox / "storage-sync-v2.sqlite", {"theme": {"ours": True}})
dr.restore_theme(state, status)
with plyvel.DB(str(helium / "Sync Extension Settings" / STORE)) as db:
    chk("...the captured browser is restored from it", db.get(b"enabled"), b"false")
chk("...and the one themed without a capture is reset to Dark Reader's defaults",
    firefox_data(firefox), {})
chk("...and the old single-browser fields are gone from the status",
    [key for key in ("browser", "browserDesktop", "browserProfile") if key in json.loads(status.read_text())], [])

(state / "original/dark-reader.json").write_text("not json")
write_theme("#555555")
chk("an unreadable capture file stops theming rather than losing it",
    (dr.apply_theme(theme, state, status), chromium_theme(chromium)), (1, None))

# -- nothing installed ------------------------------------------------------------
shutil.rmtree(home / ".config"); shutil.rmtree(home / ".mozilla")
chk("with Dark Reader in no browser, there is nothing to do", dr.apply_theme(theme, state, status), 0)
chk("...and the status says so", json.loads(status.read_text())["darkReader"], "not-installed")

# -- knowing a browser is open ---------------------------------------------------
dr.target_pids = real_target_pids
profile = firefox_profile(".mozilla/firefox", "held.default", True)
# As Firefox holds it: open, with a POSIX lock on it.
holder = subprocess.Popen([sys.executable, "-c",
    "import fcntl, sys, time; f = open(sys.argv[1], 'a'); fcntl.lockf(f, fcntl.LOCK_EX);"
    " print('held', flush=True); time.sleep(30)",
    str(profile / ".parentlock")], stdout=subprocess.PIPE, text=True)
holder.stdout.readline()
target = dr.Target("zen", "Zen Browser", "firefox", profile)
chk("a Gecko browser is known open by the profile lock it holds, whatever its binary is called",
    dr.target_pids(target), [holder.pid])
holder.kill(); holder.wait()
chk("...and closed once it lets go", dr.target_pids(target), [])

# A browser updated while open keeps running the replaced binary.
binary = home / "bin/helium"
binary.parent.mkdir()
shutil.copy("/usr/bin/sleep", binary)
process = subprocess.Popen([str(binary), "30"])
time.sleep(0.2)
binary.unlink()
chk("a browser whose binary was replaced by an update still counts as open",
    process.pid in dr.pids_running(["helium"]), True)
process.kill(); process.wait()
E

# -- the sync script asks for all of them, not the default browser -------------
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
chk "the default browser is no longer asked for" \
  "$(grep -c 'xdg-settings\|default-web-browser\|xdg-mime' lib/hyprchroma-dark-reader bin/hyprchroma | awk -F: '{s+=$2} END {print s}')" "0"
chk "adding Dark Reader to another browser changes the fingerprint" \
  "$(grep -c '"$dark_reader_signature" "$pear_installed"' bin/hyprchroma)" "1"
chk "the not-installed notice needs the helper to have answered" \
  "$(grep -c 'dark_reader_known == "true" && $dark_reader_installed != "true"' bin/hyprchroma)" "1"
