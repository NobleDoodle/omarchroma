#!/usr/bin/env bash
# Safe to run directly as well as through tests/run: never the real XDG
# folders or session bus, whatever the caller's environment holds.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
# Everything under original/ -- the manifest and the captures -- can be
# written by any program running as this user. A restore must decide where
# it writes, what it reads and what it removes from its own fixed table, and
# take back from a capture only what each destination can hold safely. Each
# case forges the manifest the way such a program could, then reverts; beside
# each, the ordinary revert that must still work.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home; mkdir -p "$HOME"
STUB=$ROOT/stub; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "$*" >> "$HOME/gsettings.log"\n[[ $1 == get ]] && echo "'"'"'stubbed'"'"'"\nexit 0\n' > "$STUB/gsettings"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/omarchy-theme-set-gnome"
chmod +x "$STUB"/*

STUB_DIR=$STUB REPO=$REPO ROOT=$ROOT /usr/bin/python3 -I - <<'E'
import json, os, sys, types
from pathlib import Path

src = open(os.environ["REPO"] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''), "st", "exec"), st.__dict__)
os.environ["PATH"] = os.environ["STUB_DIR"] + ":" + os.environ["PATH"]
H, ROOT = Path.home(), Path(os.environ["ROOT"])
S = H / ".local/state/hyprchroma"; O = S / "original"; F = O / "files"

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}" + ("" if got == want else f": got [{got}] want [{want}]"))

def write(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)

def manifest(data):
    write(O / "manifest.json", json.dumps(data))

def restore(target):
    sys.argv = ["hyprchroma-state", "--state-dir", str(S), "--data-dir", str(ROOT / "data"),
                "restore", "--target", target, "--mode", "captured"]
    st.main()

victims = {name: H / name for name in (".bashrc", ".profile", "victim.txt")}
for path in victims.values():
    write(path, "UNTOUCHED\n")
secret = ROOT / "secret.txt"; write(secret, "SECRET\n")

# --- a forged path, backup name or "existed" decides nothing --------------------
write(F / "gtk3_css", "@define-color accent_bg_color #123456;\n")
write(H / ".config/gtk-3.0/gtk.css", "/* Hyprchroma's */\n")
write(H / ".config/gtk-4.0/gtk.css", "/* the user's */\n")
manifest({"files": {
    "gtk3_css": {"path": str(victims[".bashrc"]), "existed": True, "backup": str(secret)},
    "gtk4_css": {"path": str(victims["victim.txt"]), "existed": False},
}})
restore("gtk")
chk("a capture is written only to its own file, whatever path the manifest names",
    (victims[".bashrc"].read_text(), (H / ".config/gtk-3.0/gtk.css").read_text()),
    ("UNTOUCHED\n", "@define-color accent_bg_color #123456;\n"))
chk("...and is read only from its own capture, never a file the manifest names",
    "SECRET" in (H / ".config/gtk-3.0/gtk.css").read_text(), False)
chk("\"existed\": false removes only that framework's file",
    (victims["victim.txt"].exists(), (H / ".config/gtk-4.0/gtk.css").exists()), (True, False))
chk("an entry for a key no framework has is ignored",
    st.restore_file(O, "dotfile", {"path": str(victims[".profile"]), "existed": False}) is None
    and victims[".profile"].read_text(), "UNTOUCHED\n")

# --- files Hyprchroma owns by name are removed, never restored from a capture -----
write(F / "hyprchroma_colors", "[General]\nName=x\n[Colors:View]\nBackgroundNormal[$e]=$(planted)\n")
write(H / ".local/share/color-schemes/Hyprchroma.colors", "ours\n")
write(H / ".config/kdeglobals", "[General]\nColorScheme=Hyprchroma\n")
manifest({"files": {"hyprchroma_colors": {"existed": True, "backup": "files/hyprchroma_colors"}}})
restore("qt-kde")
chk("Hyprchroma's KDE color scheme is removed, a capture claiming otherwise notwithstanding",
    (H / ".local/share/color-schemes/Hyprchroma.colors").exists(), False)

# --- kdeglobals: only the keys Hyprchroma writes come back, checked -------------
write(F / "kdeglobals", "[General]\nColorScheme=Mine\nBrowserApplication=planted.desktop\n"
      "[KDE]\ncontrast=4\nTerminalApplication=/tmp/planted\n"
      "[Colors:Window][$e]\nBackgroundNormal=1,2,3\n[Colors:View]\nBackgroundNormal=$(planted)\nForegroundNormal=4,5,6\n"
      "[Icons]\nTheme=../../planted\n")
write(H / ".config/kdeglobals", "[General]\nColorScheme=Hyprchroma\nfixed=Mono,10\n[Colors:View]\nForegroundNormal=9,9,9\n")
manifest({"files": {"kdeglobals": {"existed": True, "backup": "files/kdeglobals"}}})
restore("qt-kde")
k = (H / ".config/kdeglobals").read_text()
chk("kdeglobals gets back the scheme and colors Hyprchroma replaced, and keeps the live file's own",
    all(line in k.splitlines() for line in ("ColorScheme=Mine", "contrast=4", "ForegroundNormal=4,5,6", "fixed=Mono,10")), True)
chk("...and nothing else from the capture: no programs to start, no expansion flags, no shell, no paths",
    [bad for bad in ("BrowserApplication", "TerminalApplication", "[$e]", "$(", "planted", "../") if bad in k], [])

# --- app color schemes: an rc file in the config folder, a scheme name ----------
write(H / ".config/okularrc", "[General]\nx=1\n")
manifest({"appColorSchemes": {
    str(victims[".bashrc"]): {"existed": True, "value": "Breeze"},
    str(H / ".config/okularrc"): {"existed": True, "value": "BreezeDark"},
    str(H / ".config/dolphinrc"): {"existed": True, "value": "x\n$(planted)"},
    str(H / ".config/../.config/katerc"): {"existed": True, "value": "Breeze"},
}})
write(H / ".config/dolphinrc", "[General]\n"); write(H / ".config/katerc", "[General]\n")
restore("qt-kde")
chk("a pinned scheme goes back into an rc file of the user's config folder",
    "ColorScheme=BreezeDark" in (H / ".config/okularrc").read_text(), True)
chk("...never into any other file, nor with anything but a scheme name, nor by a path through ..",
    (victims[".bashrc"].read_text(), "planted" in (H / ".config/dolphinrc").read_text(),
     "ColorScheme" in (H / ".config/katerc").read_text()), ("UNTOUCHED\n", False, False))

# --- gsettings: the captured keys only, as names ---------------------------------
(H / "gsettings.log").unlink(missing_ok=True)
manifest({"gsettings": {"gtk-theme": "'Adwaita-dark'", "cursor-theme": "'planted'",
                        "icon-theme": "'a' ; rm", "font-name": "'Planted 10'"}})
write(H / ".config/gtk-3.0/gtk.css", "x\n")
restore("gtk")
log = (H / "gsettings.log").read_text() if (H / "gsettings.log").exists() else ""
chk("gsettings gets back the captured keys, as names, and nothing else",
    [line for line in log.splitlines() if line.startswith("set ")],
    ["set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'"])

# --- Pear: the live list less Hyprchroma's, never a list from the capture ---------
write(F / "pear_config", json.dumps({"options": {"themes": ["/planted.css"]}}))
pear = H / ".config/YouTube Music/config.json"
write(pear, json.dumps({"options": {"themes": ["/u/mine.css", str(H / ".config/YouTube Music/hyprchroma.css")]}}))
write(H / ".config/YouTube Music/hyprchroma.css", "ours\n")
manifest({"files": {"pear_config": {"existed": True, "backup": "files/pear_config"},
                    "pear_css": {"existed": True, "backup": "files/pear_config"}}})
restore("pear")
chk("Pear keeps its own themes, less Hyprchroma's, and nothing from the capture",
    json.loads(pear.read_text())["options"]["themes"], ["/u/mine.css"])
chk("...and Hyprchroma's stylesheet is removed", (H / ".config/YouTube Music/hyprchroma.css").exists(), False)

# A capture is taken from its own file too: a forged backup name is not written.
write(H / ".config/YouTube Music/config.json", json.dumps({"options": {"themes": ["/u/a.css"]}}))
manifest({"files": {"pear_config": {"existed": True, "backup": str(victims["victim.txt"])}}})
st.strip_generated_pear_themes(O, json.loads((O / "manifest.json").read_text()))
chk("taking Pear's capture never writes where the manifest's backup name points",
    victims["victim.txt"].read_text(), "UNTOUCHED\n")

# --- Vivaldi: only theme ids of the shapes Vivaldi keeps --------------------------
chk("a captured Vivaldi theme is a theme id, or a light/dark pair of them", (
    st.vivaldi_theme_choice("Vivaldi2020"), st.vivaldi_theme_choice({"light": "a", "dark": "b"}),
    st.vivaldi_theme_choice({"x": "y"}), st.vivaldi_theme_choice("a\nb"), st.vivaldi_theme_choice(["a"])),
    (True, True, False, False, False))

# --- moving a file aside: kept, never deleted; a FIFO is left alone ---------------
hook = H / "hook"; write(hook, "#!/bin/sh\necho mine\n")
chk("a file is moved aside, readable by the user only, and gone from where it was",
    (st.preserve_file(hook, S / "replaced-hooks", "theme-set-1"), hook.exists(),
     (S / "replaced-hooks/theme-set-1").read_text(), oct((S / "replaced-hooks/theme-set-1").stat().st_mode & 0o777)),
    (True, False, "#!/bin/sh\necho mine\n", "0o600"))
fifo = H / "fifo"; os.mkfifo(fifo)
chk("...a FIFO is not read and stays where it is", (st.preserve_file(fifo, S / "replaced-hooks", "x"), fifo.exists()), (False, True))
chk("...nor is a name with a path in it used", st.preserve_file(H / ".profile", S / "replaced-hooks", "../out"), False)
E
