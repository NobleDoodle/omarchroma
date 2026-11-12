#!/usr/bin/env bash
# Icons: every Omarchy theme points at one icon theme, Omarchroma-Icons, inheriting the
# Reversal or Yaru color nearest its accent, with folders recolored from the
# theme. Everything runs against a throwaway HOME, a fake Reversal and fake
# Omarchy themes; no real icon theme, theme folder or session bus is touched.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

# --- opt-in, like Flatpak and Thunderbird -----------------------------------
SETTINGS_FILE=$(mktemp)
eval "$(sed -n '/^target_key()/,/^}$/p' "$REPO/bin/hyprchroma")"
eval "$(sed -n '/^target_enabled()/,/^}$/p' "$REPO/bin/hyprchroma")"
r(){ target_enabled "$1" && echo enabled || echo disabled; }
printf '{}' > "$SETTINGS_FILE"
chk "icons is off with nothing recorded" "$(r icons)" "disabled"
printf '{"frameworks":{"icons":true}}' > "$SETTINGS_FILE"
chk "a recorded true turns icons on" "$(r icons)" "enabled"
rm -f "$SETTINGS_FILE"
chk "the panel lists Icons before Additional Apps, whose drop-down sits last" \
  "$(grep -o 'target: "icons"\|target: "apps"' "$REPO/Panel.qml" | tr '\n' ' ')" 'target: "icons" target: "apps" '
chk "the safe-io core is identical in the icons helper" "$(python3 - "$REPO" <<'PY'
import pathlib, sys
def core(n):
    s = (pathlib.Path(sys.argv[1]) / n).read_text()
    end = s.index("def prepare_lock") if "def prepare_lock" in s else s.rindex("\n", 0, s.index(" paths --")) + 1
    return s[s.index("# ------"):end].rstrip()
print("same" if core("lib/hyprchroma-state") == core("lib/hyprchroma-icons") else "drifted")
PY
)" "same"

python3 - "$REPO" <<'E'
import json, os, subprocess, sys, tempfile, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
H = root / "home"
H.mkdir()
SHARE = root / "usr/share"
os.environ.update({
    "HOME": str(H), "XDG_RUNTIME_DIR": str(root / "run"), "XDG_DATA_DIRS": str(SHARE),
    "OMARCHY_PATH": str(root / "omarchy"), "HYPRCHROMA_ICONS_ISOLATED": "1",
})
for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "DBUS_SESSION_BUS_ADDRESS"):
    os.environ.pop(name, None)
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-icons"
ic = types.ModuleType("ic")
ic.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "ic", "exec"), ic.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}" + ("" if got == want else f": got [{got}] want [{want}]"))

def cli(*args):
    return subprocess.run([sys.executable, helper, *args], capture_output=True, text=True)

# -- color choice -------------------------------------------------------------
chk("a blue accent takes Reversal's light blue", ic.base_family("#7aa2f7"), "Reversal-lightblue")
chk("a near-grey accent stays grey", ic.base_family("#808080"), "Reversal-grey")
chk("a dark near-grey accent is black", ic.base_family("#303030"), "Reversal-black")
chk("Yaru has no grey: near-grey is sage", ic.base_family("#808080", "yaru"), "Yaru-sage")
chk("gold dark is Reversal-dark, not Reversal--dark",
    ic.base_theme_name("#f5aa1e", "dark"), "Reversal-dark")
face, tab = ic.folder_colors("#7AA2F7")
chk("the folder face is the theme color exactly", face, "#7aa2f7")
chk("the tab is darker in the same hue", ic.oklch(tab)[0] < ic.oklch(face)[0], True)
chk("Yaru's roles keep the face exactly", ic.yaru_roles("#336699")["face"], "#336699")
chk("a slug that climbs out is not one", (ic.valid_slug("../x"), ic.valid_slug("tokyo-night")), ("", "tokyo-night"))

# -- a fake Reversal (the AUR package's shape: default and dark only) --------
GOLD = """<svg xmlns="http://www.w3.org/2000/svg"><path fill="#f5aa1e"/><path fill="#fafafa"/>
<path fill="#f08705"/><path fill="#ffc841"/></svg>"""
for name in ("Reversal", "Reversal-dark"):
    theme = SHARE / "icons" / name
    (theme / "places/scalable").mkdir(parents=True)
    (theme / "apps/scalable").mkdir(parents=True)
    (theme / "index.theme").write_text(f"[Icon Theme]\nName={name}\n")
    (theme / "places/scalable/folder.svg").write_text(GOLD)
    (theme / "places/scalable/network-server.svg").write_text('<svg fill="#123456"/>')
    (theme / "apps/scalable/firefox.svg").write_text("<svg/>")
chk("Reversal without its colors still counts as installed", ic.set_installed("reversal"), True)
chk("Yaru is not installed here", ic.set_installed("yaru"), False)

# -- fake Omarchy themes: a user theme with its own icons.theme, a stock one --
stock = root / "omarchy/themes"
for slug, accent, mode in (("tokyo-night", "#7aa2f7", "dark"), ("latte", "#1e66f5", "light")):
    (stock / slug).mkdir(parents=True)
    (stock / slug / "colors.toml").write_text(
        f'accent = "{accent}"\nbackground = "#1a1b26"\nlighter_background = "#24283b"\n'
        f'foreground = "#c0caf5"\nmode = "{mode}"\n')
    (stock / slug / "icons.theme").write_text("Yaru-blue\n")
user = H / ".config/omarchy/themes/mine"
user.mkdir(parents=True)
(user / "colors.toml").write_text('accent = "#a6e3a1"\nforeground = "#cdd6f4"\nbackground = "#1e1e2e"\n')
(user / "icons.theme").write_text("Papirus\n")
current = H / ".local/state/omarchy/current"
(current / "theme").mkdir(parents=True)
(current / "theme.name").write_text("tokyo-night\n")
(current / "theme/colors.toml").write_text((stock / "tokyo-night/colors.toml").read_text())
(current / "theme/icons.theme").write_text("Yaru-blue\n")
chk("a color not installed falls back to the set's own dark", ic.base_theme_for("tokyo-night"), "Reversal-dark")
chk("on a light theme, to the set itself", ic.base_theme_for("latte"), "Reversal")

# -- a planted link where the theme's index goes is replaced, not followed ---
bystander = root / "bystander"
bystander.write_text("UNTOUCHED")
(H / ".icons/Omarchroma-Icons").mkdir(parents=True)
(H / ".icons/Omarchroma-Icons/index.theme").symlink_to(bystander)

# -- an app of the user's own with an absolute icon ---------------------------
from PIL import Image
art = H / "art/tool.png"
art.parent.mkdir()
Image.new("RGBA", (64, 64), (200, 40, 40, 255)).save(art)
apps = H / ".local/share/applications"
apps.mkdir(parents=True)
(apps / "my-tool.desktop").write_text(f"[Desktop Entry]\nName=Tool\nIcon={art}\nExec=true\n")

run = cli("apply")
chk("apply succeeds", (run.returncode, run.stderr.strip()), (0, ""))
index = (H / ".icons/Omarchroma-Icons/index.theme")
chk("the theme inherits the base for the active theme", "Inherits=Reversal-dark,hicolor" in index.read_text(), True)
chk("the planted link was replaced by the theme's own file", (index.is_symlink(), bystander.read_text()), (False, "UNTOUCHED"))
chk("KDE finds it by name in ~/.local/share/icons",
    os.readlink(H / ".local/share/icons/Omarchroma-Icons"), "../../../.icons/Omarchroma-Icons")
places = H / ".local/share/hyprchroma/icons/places"
folder = (places / "folder.svg").read_text()
chk("folders take the sidebar highlight by default", ic.sidebar_highlight("tokyo-night") in folder, True)
chk("no gold is left in a recolored folder", any(h in folder for h in ("#f5aa1e", "#f08705", "#ffc841")), False)
chk("artwork that is not a folder is not taken", (places / "network-server.svg").exists(), False)
chk("the folder is linked into the theme",
    (H / ".icons/Omarchroma-Icons/places/scalable/folder.svg").resolve() == (places / "folder.svg").resolve(), True)
chk("the user's theme now points at Omarchroma-Icons", (user / "icons.theme").read_text(), "Omarchroma-Icons\n")
chk("a stock theme gets an overlay holding only that", sorted(p.name for p in (H / ".config/omarchy/themes/latte").iterdir()), ["icons.theme"])
chk("the staged current theme points at Omarchroma-Icons", (current / "theme/icons.theme").read_text(), "Omarchroma-Icons\n")
chk("the stock theme itself is untouched", (stock / "latte/icons.theme").read_text(), "Yaru-blue\n")
desktop = (apps / "my-tool.desktop").read_text()
chk("an absolute Icon= names its cover instead", "Icon=my-tool\n" in desktop, True)
chk("the cover is an SVG in the theme",
    (H / ".icons/Omarchroma-Icons/apps/scalable/my-tool.svg").resolve().read_text().startswith("<?xml"), True)
status = json.loads((H / ".local/state/hyprchroma/icons/status.json").read_text())
chk("status says what is applied", (status["base"], status["mode"], status["active"], status["applying"]),
    ("Reversal-dark", "background", True, False))

again = cli("apply")
chk("a second apply changes nothing", again.stdout.strip().endswith("unchanged"), True)

run = cli("folders", "next")
status = json.loads((H / ".local/state/hyprchroma/icons/status.json").read_text())
chk("next folder color is the accent", (status["mode"], status["face"]), ("accent", "#7aa2f7"))
chk("the panel gets all four colors", sorted(status["modes"]), ["accent", "background", "border", "yaru"])
chk("and the folders follow", "#7aa2f7" in (places / "folder.svg").read_text(), True)
chk("a set that is not installed is refused", cli("set", "yaru").returncode, 3)
chk("the theme's Yaru color is the variant it names", (ic.mode_source("latte", "yaru"), ic.yaru_color("latte")),
    ("#2686e6", "#2686e6"))
chk("a theme naming no Yaru color takes its accent", ic.mode_source("mine", "yaru"), "#a6e3a1")
(stock / "latte/icons.theme").write_text("Yaru-sage-dark\n")
chk("-dark names the same color", ic.yaru_color("latte"), "#7c8c7f")
(stock / "latte/icons.theme").write_text("Yaru-blue\n")
chk("a folder mode that does not exist is refused", cli("folders", "gold").returncode != 0, True)

# A theme switch: the next apply follows the new theme.
(current / "theme.name").write_text("latte\n")
(current / "theme/colors.toml").write_text((stock / "latte/colors.toml").read_text())
cli("apply")
chk("a theme change moves Inherits", "Inherits=Reversal,hicolor" in index.read_text(), True)
chk("and the folders", "#1e66f5" in (places / "folder.svg").read_text(), True)

# -- switching off puts everything back ---------------------------------------
run = cli("revert")
chk("revert succeeds", run.returncode, 0)
chk("the user's own icons.theme is back", (user / "icons.theme").read_text(), "Papirus\n")
chk("the overlay it made is gone", (H / ".config/omarchy/themes/latte").exists(), False)
chk("the staged theme's icons.theme is back", (current / "theme/icons.theme").read_text(), "Yaru-blue\n")
chk("the desktop file names its own artwork again", f"Icon={art}\n" in (apps / "my-tool.desktop").read_text(), True)
chk("the theme and its link are gone",
    ((H / ".icons/Omarchroma-Icons").exists(), os.path.lexists(H / ".local/share/icons/Omarchroma-Icons")), (False, False))
chk("generated folders and covers are gone", (H / ".local/share/hyprchroma/icons").exists(), False)
chk("Reversal itself is left installed", (SHARE / "icons/Reversal/index.theme").is_file(), True)

E

# --- end to end: switching the framework on and off through hyprchroma --------
# A home of its own, and no XDG directory inherited: run on its own, outside
# tests/run, this suite once wrote through XDG_STATE_HOME and XDG_CONFIG_HOME
# into the real ones while HOME pointed at a scratch folder.
HOME=$(mktemp -d); export HOME
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=$HOME/run
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
trap 'rm -rf "$HOME"' EXIT
source "$REPO/tests/lib-omarchy.sh"
seed_omarchy_theme
SHARE=$(mktemp -d)
mkdir -p "$SHARE/icons/Reversal/places/scalable" "$SHARE/icons/Reversal-dark"
printf '[Icon Theme]\nName=Reversal\n' > "$SHARE/icons/Reversal/index.theme"
printf '[Icon Theme]\nName=Reversal-dark\n' > "$SHARE/icons/Reversal-dark/index.theme"
printf '<svg><path fill="#f5aa1e"/><path fill="#ffc841"/></svg>' > "$SHARE/icons/Reversal/places/scalable/folder.svg"
export XDG_DATA_DIRS=$SHARE HYPRCHROMA_ICONS_ISOLATED=1
status_of(){ jq -r ".$1 // \"\"" "$HOME/.local/state/hyprchroma/status.json" 2>/dev/null; }
# Switching off a framework that never ran writes nothing -- the installer's
# "no" to Icons is exactly that.
"$REPO/bin/hyprchroma" --target=icons --set-enabled=false --quiet >/dev/null 2>&1
chk "switching off Icons that never ran writes no icon state" \
  "$([[ -e $HOME/.local/state/hyprchroma/icons || -e $HOME/.icons/Omarchroma-Icons ]] && echo written || echo none)" "none"
"$REPO/bin/hyprchroma" --target=icons --set-enabled=true --quiet >/dev/null 2>&1
chk "switching icons on applies it" "$(status_of icons)" "synchronized"
chk "and builds the icon theme" "$(grep -c '^Inherits=Reversal-dark' "$HOME/.icons/Omarchroma-Icons/index.theme" 2>/dev/null)" "1"
chk "the panel can ask for the icon status" \
  "$("$REPO/bin/hyprchroma" icons status 2>/dev/null | jq -r '.theme')" "Omarchroma-Icons"
"$REPO/bin/hyprchroma" icons folders border >/dev/null 2>&1
chk "the panel's folder choice applies at once while on" \
  "$(jq -r '.mode' "$HOME/.local/state/hyprchroma/icons/status.json")" "border"
"$REPO/bin/hyprchroma" --target=icons --set-enabled=false --quiet >/dev/null 2>&1
chk "switching icons off reverts it" "$([[ -e $HOME/.icons/Omarchroma-Icons ]] && echo present || echo gone)" "gone"
"$REPO/bin/hyprchroma" icons folders accent >/dev/null 2>&1
chk "while off, a folder choice is only saved" \
  "$(jq -r '.folder_mode' "$HOME/.local/state/hyprchroma/icons/settings.json")-$([[ -e $HOME/.icons/Omarchroma-Icons ]] && echo built || echo none)" "accent-none"
rm -rf "$SHARE"

# --- setup offers Reversal whenever Icons is included -------------------------
U=$REPO/bin/hyprchroma-setup
chk "setup offers Reversal whichever set is picked, unless its AUR package is there" \
  "$(grep -c '^if \[\[ $want_icons == yes \]\] && ! pacman -Qq "$REVERSAL_AUR" &>/dev/null; then$' "$U")" "1"
