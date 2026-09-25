#!/usr/bin/env bash
# Omarchy colors the Chromium family itself, with a managed policy. The rest --
# Firefox and its derivatives, and Vivaldi -- it leaves alone, and this
# framework themes them: a stylesheet in each Firefox-family profile, a custom
# theme in Vivaldi's preferences. It writes inside browser profiles, so it is
# opt-in, finds profiles only where each browser's own records put them, never
# writes through or replaces a link, and hands back exactly the bytes that were
# there. Everything here runs against a throwaway HOME; no real browser, and
# nothing on this machine, is read or touched.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

python3 - "$REPO" <<'E'
import json, os, signal, stat, subprocess, sys, tempfile, threading, time, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
os.environ["HOME"] = str(root)
os.environ["XDG_RUNTIME_DIR"] = str(root / "run")
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-state"
st = types.ModuleType("st")
st.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# Nothing here may depend on what happens to be running on the machine.
running_vivaldi = []
st.vivaldi_pids = lambda: list(running_vivaldi)
spawned = []
st.spawn_browsers_waiter = lambda *a: spawned.append(a)

S, D = root / "state", root / "share"
S.mkdir(); D.mkdir()
PALETTE = {"mode": "dark", "background": "#1a1b26", "dark_background": "#16161e",
           "foreground": "#c0caf5", "accent": "#7aa2f7", "selection": "#33467c",
           "selection_foreground": "#c0caf5", "muted": "#565f89"}
def palette(**changes):
    (D / "browsers-theme.json").write_text(json.dumps(dict(PALETTE, **changes)))
def sync(revert=False):
    return st.sync_browsers(S, D, revert=revert, spawn=False)
def manifest():
    return st.read_json(S / "original" / "manifest.json")
def settings(on):
    (S / "settings.json").write_text(json.dumps({"frameworks": {"browsers": on}}))
def tree(path):
    return sorted(str(p.relative_to(path)) for p in path.rglob("*"))

# -- nothing installed, nothing done ------------------------------------------
chk("no supported browser: reported, and nothing written",
    (st.sync_browsers(S, D)[0], (S / "original").exists()), ("not-installed", False))

# -- discovery: only where each browser's own records say ---------------------
ff = root / ".mozilla/firefox"
ff.mkdir(parents=True)
outside = root / "outside"; outside.mkdir()
(root / "escape").mkdir()
for name in ("a.default", "b.abs", "c.prefon", "d.empty", "e.linked", "f.planted",
             "g.running", "h.stale", "i.stow"):
    (ff / name).mkdir()
(ff / "link.default").symlink_to(outside)
entries = [("a.default", 1), (str(ff / "b.abs"), 0), ("c.prefon", 1), ("d.empty", 1),
           ("e.linked", 1), ("f.planted", 1), ("g.running", 1), ("h.stale", 1),
           ("i.stow", 1), (str(outside), 0), ("../../escape", 1), ("link.default", 1),
           ("gone.default", 1)]
(ff / "profiles.ini").write_text("[General]\nStartWithLastProfile=1\n\n" + "".join(
    f"[Profile{n}]\nName=p{n}\nIsRelative={rel}\nPath={path}\n\n"
    for n, (path, rel) in enumerate(entries)) + "[Install4F96D1932A9F858E]\nDefault=a.default\n")
found = [p.name for p in st.firefox_profiles(ff)]
chk("profiles.ini: relative and contained absolute entries are found",
    found, ["a.default", "b.abs", "c.prefon", "d.empty", "e.linked", "f.planted",
            "g.running", "h.stale", "i.stow"])
chk("...an absolute entry outside the browser's folder is refused", str(outside) in map(str, st.firefox_profiles(ff)), False)
chk("...so is one that climbs out with ..", any("escape" in str(p) for p in st.firefox_profiles(ff)), False)
chk("...so is a profile folder that is a link out of it", "link.default" in found, False)

zen = root / ".config/zen"
(zen / "33bxv52z.Default (release)").mkdir(parents=True)
(zen / "profiles.ini").write_text(
    "[Profile0]\nName=Default (release)\nIsRelative=1\nPath=33bxv52z.Default (release)\n")
chk("Zen's own layout, a name with spaces and parentheses",
    [p.name for p in st.firefox_profiles(zen)], ["33bxv52z.Default (release)"])

viv = root / ".config/vivaldi"
for name in ("Default", "Profile 1", "Profile 2"):
    (viv / name).mkdir(parents=True)
(outside / "Preferences").write_text("{}")
(viv / "Profile 3").symlink_to(outside)
(viv / "Local State").write_text(json.dumps({"profile": {"info_cache": {
    "Default": {}, "Profile 1": {}, "Profile 2": {}, "Profile 3": {}, "../../outside": {}}}}))
DEFAULT_PREFS = {"vivaldi": {"themes": {"current": "Vivaldi4",
                                        "user": [{"id": "mine", "name": "Mine"}]},
                             "theme": {"schedule": {"o_s": {"light": "Vivaldi1", "dark": "Vivaldi4"},
                                                    "enabled": "os"}},
                             "tabs": {"stacking": 2}},
                 "protection": {"macs": {"browser": {"show_home_button": "0A1B"}}},
                 "browser": {"show_home_button": True}}
PROFILE1_PREFS = {"browser": {"window_placement": {"left": 0}},
                  "extensions": {"hosts": ["<all_urls>"], "note": "a\u2028b"}}
(viv / "Default/Preferences").write_text(json.dumps(DEFAULT_PREFS))
os.chmod(viv / "Default/Preferences", 0o600)
# As Chromium writes it: compact, with "<" and the two line separators escaped.
PROFILE1_BYTES = (json.dumps(PROFILE1_PREFS, separators=(",", ":"))
                  .replace("<", "\\u003C"))
(viv / "Profile 1/Preferences").write_text(PROFILE1_BYTES)
chk("Vivaldi: the profiles Local State names that have preferences",
    [p.name for p in st.vivaldi_profiles(viv)], ["Default", "Profile 1"])
chk("the supported browsers found, by name",
    [name for name, _, _ in st.detected_browsers()], ["Firefox", "Zen", "Vivaldi"])
out = subprocess.run([helper, "detect-browsers"], capture_output=True, text=True,
                     env=dict(os.environ, HOME=str(root)))
chk("detect-browsers needs no state or data directory", (out.returncode, out.stdout),
    (0, "Firefox\nZen\nVivaldi\n"))

# -- the palette file is checked, not trusted ---------------------------------
chk("no palette file: unusable", st.browser_palette(D), None)
try:
    st.sync_browsers(S, D, spawn=False); refused = False
except SystemExit:
    refused = True
chk("...rather than theming from nothing", refused, True)
palette(mode="sepia")
chk("a mode other than dark or light is refused", st.browser_palette(D), None)
palette(background="#fff; } * { display: none")
chk("a color that is not #rrggbb is refused, so nothing is spliced into CSS",
    st.browser_palette(D), None)
palette()
chk("a well-formed palette is accepted", st.browser_palette(D)["background"], "#1a1b26")

# -- Firefox family: one stylesheet of ours, one line in each of two files ----
A = ff / "a.default"
(A / "chrome").mkdir()
# Floorp ships a userChrome.css that opens with a blank line and an @charset.
USERCHROME = '\n/* mine */\n@charset "UTF-8";\n#TabsToolbar { display: none !important; }\n'
USERJS = 'user_pref("browser.startup.page", 3);\n'
PREFS = '// Mozilla User Preferences\n\nuser_pref("browser.startup.page", 3);\n'
(A / "chrome/userChrome.css").write_text(USERCHROME)
(A / "user.js").write_text(USERJS); os.chmod(A / "user.js", 0o600)
(A / "prefs.js").write_text(PREFS); os.chmod(A / "prefs.js", 0o600)
B = ff / "b.abs"
(B / "prefs.js").write_text(PREFS)
C = ff / "c.prefon"
PREFS_ON = PREFS + 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);\n'
(C / "prefs.js").write_text(PREFS_ON)
Dp = ff / "d.empty"
(Dp / "chrome").mkdir(); (Dp / "chrome/userChrome.css").write_text(""); (Dp / "user.js").write_text("")
E_ = ff / "e.linked"
(root / "dotfiles").mkdir()
(root / "dotfiles/user.js").write_text("// arkenfox\n")
(E_ / "user.js").symlink_to(root / "dotfiles/user.js")
F = ff / "f.planted"
(F / "chrome").mkdir()
(root / "victim.txt").write_text("keep me\n")
(F / "chrome/hyprchroma.css").symlink_to(root / "victim.txt")
I = ff / "i.stow"
(I / "chrome").mkdir()
(root / "dotfiles/userChrome.css").write_text("#nav-bar { order: 1; }\n")
(I / "chrome/userChrome.css").symlink_to(root / "dotfiles/userChrome.css")
for profile in (ff / "g.running", ff / "h.stale"):
    (profile / "prefs.js").write_text(PREFS)
before = {p: tree(p) for p in (B, Dp, E_, I)}

state, summary, waits = sync()
chk("switching it on themes every browser found",
    (state, summary.split(";")[0]), ("synchronized", "Firefox, Zen, Vivaldi"))
chk("...and says which profile it could not safely change", summary.split("; ")[1:],
    ["could not safely change a profile of Firefox"])
css = (A / "chrome/hyprchroma.css").read_text()
chk("the stylesheet carries the palette", ("#1a1b26" in css, "#7aa2f7" in css), (True, True))
chk("...for Zen's own variables too", "--zen-primary-color: var(--hyprchroma-accent)" in css, True)
chk("...including the text color and scheme Zen otherwise computes for a light theme",
    ("--toolbox-textcolor: var(--hyprchroma-fg) !important" in css,
     "--toolbar-color-scheme: dark !important" in css), (True, True))
text = (A / "chrome/userChrome.css").read_text()
chk("userChrome.css: the import goes first, where CSS requires @import",
    text.splitlines()[0], st.USERCHROME_IMPORT)
chk("...and every byte of the user's file follows, untouched",
    text[len(st.USERCHROME_IMPORT) + 1:], USERCHROME)
chk("user.js: the one preference line, then the user's own, untouched",
    (A / "user.js").read_text(), st.USERJS_PREF + "\n" + USERJS)
chk("...keeping the file's own permissions", stat.S_IMODE((A / "user.js").stat().st_mode), 0o600)
chk("prefs.js is the browser's, and is not touched to switch it on", (A / "prefs.js").read_text(), PREFS)
chk("a profile with none of these gets a chrome folder and three files",
    sorted(set(tree(B)) - set(before[B])),
    ["chrome", "chrome/hyprchroma.css", "chrome/userChrome.css", "user.js"])
chk("a linked user.js (arkenfox, dotfiles) is refused, not replaced by a copy",
    ((E_ / "user.js").is_symlink(), (root / "dotfiles/user.js").read_text(), tree(E_)),
    (True, "// arkenfox\n", before[E_]))
chk("a linked userChrome.css is refused the same way, so the link survives",
    ((I / "chrome/userChrome.css").is_symlink(), (root / "dotfiles/userChrome.css").read_text(),
     tree(I)), (True, "#nav-bar { order: 1; }\n", before[I]))
chk("a stylesheet planted as a link is replaced, never written through",
    ((F / "chrome/hyprchroma.css").is_symlink(), (root / "victim.txt").read_text()),
    (False, "keep me\n"))
chk("Zen's profile is themed the same way",
    (zen / "33bxv52z.Default (release)/chrome/hyprchroma.css").is_file(), True)

files = lambda: {p: p.read_bytes() for p in A.rglob("*") if p.is_file()}
first, inode = files(), (A / "chrome/hyprchroma.css").stat().st_ino
sync()
chk("syncing again changes nothing", files(), first)
chk("...and does not even rewrite the stylesheet", (A / "chrome/hyprchroma.css").stat().st_ino, inode)
palette(background="#282828")
sync()
chk("a new palette rewrites the stylesheet", "#282828" in (A / "chrome/hyprchroma.css").read_text(), True)
chk("...and leaves the user's two files alone",
    ((A / "user.js").read_bytes(), (A / "chrome/userChrome.css").read_bytes()),
    (first[A / "user.js"], first[A / "chrome/userChrome.css"]))

# The browser starts: Gecko copies what user.js set into prefs.js.
for profile in (A, B, ff / "h.stale", ff / "g.running"):
    with open(profile / "prefs.js", "a") as handle:
        handle.write('user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);\n')

# -- a running browser: prefs.js waits until it has closed --------------------
G = ff / "g.running"
(ff / "h.stale/lock").symlink_to("127.0.0.1:+999999")   # left by a crash
holder = subprocess.Popen([sys.executable, "-c",
    "import sys, time; f = open(sys.argv[1], 'a'); print('held', flush=True); time.sleep(60)",
    str(G / ".parentlock")], stdout=subprocess.PIPE, text=True)
holder.stdout.readline()
chk("a browser with the profile open is found by its lock descriptor",
    st.profile_holders(G), [holder.pid])
chk("...and a lock symlink left by a crash does not count as running",
    st.profile_holders(ff / "h.stale"), [])

state, summary, waits = sync(revert=True)
chk("reverting with Firefox open: its prefs.js line waits for it",
    (state, summary, waits), ("pending", "Zen, Vivaldi; Firefox when it closes", [holder.pid]))
chk("...while everything else of it is already reverted",
    ((G / "chrome").exists(), (G / "user.js").exists()), (False, False))
chk("...prefs.js is left for the browser to finish with",
    st.stylesheets_pref_on((G / "prefs.js").read_text()), True)
chk("...and its capture is kept until that is done", list(manifest()["browsers"]["firefox"]), [str(G)])

chk("reverted: userChrome.css is byte for byte what the user had",
    (A / "chrome/userChrome.css").read_text(), USERCHROME)
chk("...user.js too", (A / "user.js").read_text(), USERJS)
chk("...with its own permissions", stat.S_IMODE((A / "user.js").stat().st_mode), 0o600)
chk("...prefs.js loses exactly the line the browser copied from user.js", (A / "prefs.js").read_text(), PREFS)
chk("...the stylesheet is gone, the user's folder is kept", tree(A / "chrome"), ["userChrome.css"])
chk("a profile that had none of it is left exactly as it was", tree(B), before[B])
chk("...its prefs.js included", (B / "prefs.js").read_text(), PREFS)
chk("the preference already on beforehand stays on", (C / "prefs.js").read_text(), PREFS_ON)
chk("files that existed empty stay, empty",
    ((Dp / "chrome/userChrome.css").read_text(), (Dp / "user.js").read_text(), (Dp / "chrome").is_dir()),
    ("", "", True))
chk("a crash's stale lock does not hold up the revert", st.stylesheets_pref_on((ff / "h.stale/prefs.js").read_text()), False)
chk("the planted link's target was never touched", (root / "victim.txt").read_text(), "keep me\n")
chk("the refused profiles are still exactly as they were", (tree(E_), tree(I)), (before[E_], before[I]))

# The waiter finishes it once the browser exits, and records that it has.
settings(False)
(S / "status.json").write_text(json.dumps({"browsers": "pending", "theme": "x"}))
threading.Timer(1.0, holder.terminate).start()
started = time.monotonic()
st.watch_browsers_exit(S, D)
chk("the waiter returns once the browser has exited", time.monotonic() - started < 15, True)
chk("...having taken out the prefs.js line", (G / "prefs.js").read_text(), PREFS)
chk("...dropped the last capture", "browsers" in manifest(), False)
chk("...and recorded the framework as off", st.read_json(S / "status.json"),
    {"browsers": "disabled", "theme": "x"})
holder.wait()

# -- Vivaldi: its own custom theme, written only while it is closed -----------
V, V1 = viv / "Default/Preferences", viv / "Profile 1/Preferences"
settings(True)
palette()
state, _, _ = sync()
prefs = json.loads(V.read_text())
ours = [t for t in prefs["vivaldi"]["themes"]["user"] if t["id"] == "Hyprchroma"]
chk("Vivaldi: the theme is added beside the user's own",
    [t["id"] for t in prefs["vivaldi"]["themes"]["user"]], ["mine", "Hyprchroma"])
chk("...carries the palette", (ours[0]["colorBg"], ours[0]["colorHighlightBg"]), ("#1a1b26", "#7aa2f7"))
chk("...and is selected, including by the light/dark schedule that overrides it",
    (prefs["vivaldi"]["themes"]["current"], prefs["vivaldi"]["theme"]["schedule"]["o_s"]),
    ("Hyprchroma", {"light": "Hyprchroma", "dark": "Hyprchroma"}))
chk("...nothing else in the preferences moves",
    (prefs["protection"], prefs["browser"], prefs["vivaldi"]["tabs"],
     prefs["vivaldi"]["theme"]["schedule"]["enabled"]),
    (DEFAULT_PREFS["protection"], DEFAULT_PREFS["browser"], {"stacking": 2}, "os"))
chk("...with the file's own permissions", stat.S_IMODE(V.stat().st_mode), 0o600)
palette(background="#282828")
sync()
prefs = json.loads(V.read_text())
chk("a new palette replaces the theme rather than adding another",
    [t["colorBg"] for t in prefs["vivaldi"]["themes"]["user"] if t["id"] == "Hyprchroma"], ["#282828"])
chk("...and the user's choice is captured once, not overwritten with ours",
    manifest()["browsers"]["vivaldi"][str(viv / "Default")]["current"], "Vivaldi4")

running_vivaldi[:] = [4242]
untouched = V.read_bytes()
state, summary, waits = sync(revert=True)
chk("Vivaldi open: nothing is written under it", V.read_bytes(), untouched)
chk("...it is left for when it closes", (state, summary.endswith("Vivaldi when it closes"), waits),
    ("pending", True, [4242]))
st.sync_browsers(S, D, revert=True, spawn=True)
chk("...by a waiter, started for it", len(spawned), 1)
running_vivaldi[:] = []

sync(revert=True)
chk("reverted: the user's theme, schedule and list come back exactly", json.loads(V.read_text()), DEFAULT_PREFS)
chk("...a profile that never had a theme set is exactly as it was, no empty keys",
    json.loads(V1.read_text()), PROFILE1_PREFS)
chk("...and written the way Chromium writes it, \\u003C and all", V1.read_text(), PROFILE1_BYTES)
chk("...and no capture is left behind", "browsers" in manifest(), False)
sync(revert=True)
chk("a revert repeated with nothing captured leaves the user's choice alone",
    json.loads(V.read_text()), DEFAULT_PREFS)
sync()
prefs = json.loads(V.read_text()); prefs["vivaldi"]["themes"]["current"] = "Vivaldi3"
V.write_text(json.dumps(prefs))
sync(revert=True)
prefs = json.loads(V.read_text())
chk("a theme picked while it was on is the user's, and a revert keeps it",
    (prefs["vivaldi"]["themes"]["current"], prefs["vivaldi"]["theme"]["schedule"]["o_s"]),
    ("Vivaldi3", DEFAULT_PREFS["vivaldi"]["theme"]["schedule"]["o_s"]))
prefs["vivaldi"]["themes"]["current"] = "Vivaldi4"; V.write_text(json.dumps(prefs))

sync(); sync(revert=True)
prefs = json.loads(V.read_text()); prefs["vivaldi"]["themes"]["current"] = "Vivaldi2"
V.write_text(json.dumps(prefs))
sync(); sync(revert=True)
chk("a theme the user picks between two uses is the one a later revert returns",
    json.loads(V.read_text())["vivaldi"]["themes"]["current"], "Vivaldi2")

(root / "dotfiles/Preferences").write_text(json.dumps(PROFILE1_PREFS))
V1.unlink(); V1.symlink_to(root / "dotfiles/Preferences")
state, summary, _ = sync()
chk("linked Vivaldi preferences are refused, and the link kept",
    (summary.endswith("could not safely change a profile of Firefox or Vivaldi"), V1.is_symlink(),
     json.loads((root / "dotfiles/Preferences").read_text())), (True, True, PROFILE1_PREFS))
sync(revert=True)

# -- work a waiter did not finish is resumed -----------------------------------
settings(False)
(S / "status.json").write_text(json.dumps({"browsers": "disabled"}))
chk("switched off with nothing outstanding: resuming does nothing",
    (st.resume_browsers(S, D), (S / "original/manifest.json").read_text()), (None, "{}\n"))
settings(True)
sync()
settings(False)   # switched off, but the revert never ran
chk("switched off with a capture left: resuming reverts it", st.resume_browsers(S, D), "synchronized")
chk("...leaving nothing captured", ("browsers" in manifest(), (A / "chrome/hyprchroma.css").exists()),
    (False, False))
settings(True)
(S / "status.json").write_text(json.dumps({"browsers": "pending"}))
chk("switched on and still pending: resuming themes it", st.resume_browsers(S, D), "synchronized")
chk("...and records that it is done", st.read_json(S / "status.json")["browsers"], "synchronized")
chk("switched on and done: resuming does nothing", st.resume_browsers(S, D), None)
settings(False); sync(revert=True)

chk("every profile the framework could change is back where it started",
    (tree(B), (A / "chrome/userChrome.css").read_text(), (A / "user.js").read_text()),
    (before[B], USERCHROME, USERJS))
E

# -- opt-in: only a recorded true turns it on ----------------------------------
T=$(mktemp -d)
enabled() {
  printf '%s' "$1" > "$T/settings.json"
  ( SETTINGS_FILE=$T/settings.json
    source <(awk '/^target_key\(\) \{/,/^\}/' "$REPO/bin/hyprchroma")
    source <(awk '/^target_enabled\(\) \{/,/^\}/' "$REPO/bin/hyprchroma")
    target_enabled "$2" && echo on || echo off )
}
chk "no setting recorded: additional browsers are off" "$(enabled '{}' browsers)" "off"
chk "a recorded true turns it on" "$(enabled '{"frameworks":{"browsers":true}}' browsers)" "on"
chk "a recorded false keeps it off" "$(enabled '{"frameworks":{"browsers":false}}' browsers)" "off"
chk "switching another framework records it as off, never on" \
  "$(grep -c 'frameworks.setdefault("browsers", False)' "$REPO/bin/hyprchroma")" "1"
rm -rf "$T"

# -- the panel, setup and documentation agree ---------------------------------
P=$REPO/Panel.qml
chk "the panel lists it as a sixth framework" \
  "$(grep -c 'target: "browsers", label: "Additional browsers"' "$P")" "1"
chk "the panel reads it as off unless settings say true" \
  "$(grep -c 'browsers: frameworks.browsers === true' "$P")" "1"
chk "...and treats a missing value as off" \
  "$(grep -c 'if (key === "flatpak" || key === "browsers") return enabledTargets\[key\] === true' "$P")" "1"
chk "it can be toggled over IPC like the others" \
  "$(grep -c 'function toggleBrowsers(): void { root.toggleFramework("browsers") }' "$REPO/BarWidget.qml")" "1"
U=$REPO/bin/hyprchroma-setup
chk "setup asks only about browsers the helper actually finds" \
  "$(grep -c 'lib/hyprchroma-state" detect-browsers' "$U")" "1"
chk "declining is the default" "$(grep -c '^want_browsers=no$' "$U")" "1"
chk "a yes switches it on; anything else keeps it out of the panel" \
  "$(grep -cE 'hyprchroma framework (restore|remove) browsers' "$U")" "2"
chk "the README documents it and its IPC call" \
  "$(grep -c 'toggleBrowsers' "$REPO/README.md")" "1"

# -- the sync script's wiring, against a stubbed state helper ----------------
ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
source "$(dirname "$0")/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/lib" "$ROOT/bin" "$XDG_STATE_HOME/hyprchroma/original"
cp "$REPO"/lib/hyprchroma-* "$REPO"/lib/sync-* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp -r "$REPO/share" "$ROOT/share"
cat > "$ROOT/lib/hyprchroma-state" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case $a in prepare-lock) lock=1 ;; write-file) writing=1 ;; esac
  case $prev in
    --path) [[ ${lock:-0} == 1 ]] && : > "$a"
            [[ ${writing:-0} == 1 ]] && cat > "$a" ;;
  esac
  prev=$a
done
[[ ${lock:-0} == 1 || ${writing:-0} == 1 ]] && exit 0
for a in "$@"; do
  case $a in
    sync-browsers) line="$*"; echo "sync-browsers${line##*sync-browsers}" >> "$HOME/calls.log"
                   printf 'synchronized\nFirefox\n'; exit 0 ;;
    restore) line="$*"; echo "restore ${line##*restore }" >> "$HOME/calls.log"; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$ROOT/lib/hyprchroma-state"
printf '#!/usr/bin/env bash\n[[ $1 == --info ]] && echo "{}"\nexit 0\n' > "$ROOT/lib/hyprchroma-dark-reader"
chmod +x "$ROOT/lib/hyprchroma-dark-reader"
run() { : > "$HOME/calls.log"; bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; cat "$HOME/calls.log"; }
settings=$XDG_STATE_HOME/hyprchroma/settings.json
status=$XDG_STATE_HOME/hyprchroma/status.json
captured=$XDG_STATE_HOME/hyprchroma/original/manifest.json
theme=$XDG_DATA_HOME/hyprchroma/browsers-theme.json

chk "a full sync with nothing recorded themes no browser" "$(run --force --quiet)" ""
chk "switching another framework on does not switch browsers on" \
  "$(run --target=gtk --set-enabled=true --quiet; jq -r '.frameworks.browsers' "$settings")" "false"
chk "switching it on themes them" "$(run --target=browsers --set-enabled=true --quiet)" "sync-browsers"
chk "...and records it on" "$(jq -r '.frameworks.browsers' "$settings")" "true"
chk "...from a palette file of seven #rrggbb colors and a mode" \
  "$(jq -r '[.mode, (.background, .dark_background, .foreground, .accent, .selection, .selection_foreground, .muted | test("^#[0-9a-fA-F]{6}$"))] | map(tostring) | join(",")' "$theme")" \
  "dark,true,true,true,true,true,true,true"
chk "...and records the result" "$(jq -r '.browsers' "$status")" "synchronized"
chk "a full sync keeps them themed once on" "$(run --force --quiet)" "sync-browsers"
chk "an unchanged palette with nothing pending costs nothing" "$(run --quiet)" ""
jq '.browsers = "pending"' "$status" > "$status.new" && mv "$status.new" "$status"
chk "left pending, the next quiet sync retries just this, nothing else" "$(run --quiet)" "sync-browsers --resume"
chk "switching it off reverts to what was captured" \
  "$(run --target=browsers --set-enabled=false --quiet)" "restore --target browsers --mode captured"
chk "...and a full sync then leaves it alone" "$(run --force --quiet)" ""
echo '{"browsers":{"vivaldi":{}}}' > "$captured"
chk "a revert that outlived its waiter is finished by the next sync" "$(run --quiet)" "sync-browsers --resume"
rm -rf "$ROOT"
