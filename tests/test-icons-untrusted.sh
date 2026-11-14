#!/usr/bin/env bash
# What the Icons helper reads, and the state it keeps, sit where other
# programs running as this user can write. Checked here, for real against a
# throwaway home: nothing it reads can block it; an absolute Icon= is honored
# only for app artwork; revert puts back only what a desktop file of the
# user's own records about itself; image sizes are bounded before decoding;
# and one bad entry never costs the others their icons. Alongside each
# refusal, the case it must not break.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

/usr/bin/python3 -I - "$REPO" <<'E'
import ast, json, os, re, shutil, stat, subprocess, sys, tempfile, time, types
from pathlib import Path

REPO = sys.argv[1]
root = Path(os.path.realpath(tempfile.mkdtemp()))
H = root / "home"; H.mkdir()
SHARE = root / "usr/share"
os.environ.update({"HOME": str(H), "XDG_RUNTIME_DIR": str(root / "run"), "XDG_DATA_DIRS": str(SHARE),
                   "OMARCHY_PATH": str(root / "omarchy"), "HYPRCHROMA_ICONS_ISOLATED": "1"})
for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "DBUS_SESSION_BUS_ADDRESS"):
    os.environ.pop(name, None)
(root / "run").mkdir(mode=0o700)
helper = REPO + "/lib/hyprchroma-icons"
ic = types.ModuleType("ic")
ic.__dict__["__file__"] = helper
exec(compile(open(helper).read(), "ic", "exec"), ic.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}" + ("" if got == want else f": got [{got}] want [{want}]"))

def cli(*args, seconds=30):
    try:
        return subprocess.run([sys.executable, helper, *args], capture_output=True, text=True, timeout=seconds)
    except subprocess.TimeoutExpired:
        return None

from PIL import Image
def picture(path, size=(64, 64), color=(200, 40, 40, 255)):
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", size, color).save(path)
    return path

# A small Reversal, a theme, and the user's applications folder.
for name in ("Reversal", "Reversal-dark"):
    theme = SHARE / "icons" / name
    (theme / "places/scalable").mkdir(parents=True)
    (theme / "apps/scalable").mkdir(parents=True)
    (theme / "index.theme").write_text(f"[Icon Theme]\nName={name}\n")
    (theme / "places/scalable/folder.svg").write_text('<svg><path fill="#f5aa1e"/><path fill="#f08705"/></svg>')
    (theme / "apps/scalable/firefox.svg").write_text("<svg/>")
stock = root / "omarchy/themes/tokyo-night"; stock.mkdir(parents=True)
(stock / "colors.toml").write_text('accent = "#7aa2f7"\nbackground = "#1a1b26"\nforeground = "#c0caf5"\nmode = "dark"\n')
current = H / ".local/state/omarchy/current"; (current / "theme").mkdir(parents=True)
(current / "theme.name").write_text("tokyo-night\n")
(current / "theme/colors.toml").write_text((stock / "colors.toml").read_text())
apps = H / ".local/share/applications"; apps.mkdir(parents=True)
store = H / ".local/share/hyprchroma/icons/apps"
state = H / ".local/state/hyprchroma/icons"
def entry(name, icon):
    path = apps / f"{name}.desktop"
    path.write_text(f"[Desktop Entry]\nName={name}\nIcon={icon}\nExec=true\n")
    return path
def icon_line(path):
    match = re.search(r"^Icon=(.*)$", path.read_text(), re.M)
    return match.group(1) if match else None

# --- nothing it reads can block it ------------------------------------------------
code = Path(helper).read_text()
tree = ast.parse(code)
builtin_open = [node.lineno for node in ast.walk(tree) if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name) and node.func.id == "open"]
chk("the only plain open() is the /proc read at the top", [code.splitlines()[n - 1].strip() for n in builtin_open],
    ['with open(name, "r", encoding="ascii") as handle:'])
chk("...in pathlib_read, which only ever reads /proc",
    sorted(set(re.findall(r'pathlib_read\("([^"]+)"\)', code))), ["/proc/self/uid_map", "/proc/sys/kernel/overflowuid"])
image_opens = [ast.unparse(node.args[0]) for node in ast.walk(tree) if isinstance(node, ast.Call)
               and isinstance(node.func, ast.Attribute) and node.func.attr == "open"
               and isinstance(node.func.value, ast.Name) and node.func.value.id == "Image"]
chk("Pillow only ever opens bytes already read", sorted(set(image_opens)), ["io.BytesIO(data)", "io.BytesIO(result.stdout)"])
chk("nothing reads through Path.read_text or read_bytes", len(re.findall(r"\.read_(text|bytes)\(", code)), 0)
untimed = [node.lineno for node in ast.walk(tree) if isinstance(node, ast.Call)
           and ast.unparse(node.func) == "subprocess.run" and not any(k.arg == "timeout" for k in node.keywords)]
chk("every program it starts has a time limit", untimed, [])

for label, plant in (
        ("a .desktop file", apps / "evil.desktop"),
        ("a theme's icons.theme", H / ".config/omarchy/themes/mine/icons.theme"),
        ("the helper's own folder stamp", state / "folder-stamp"),
        ("an icon theme's artwork", H / ".local/share/icons/hicolor/48x48/apps/fifo-app.png")):
    plant.parent.mkdir(parents=True, exist_ok=True)
    plant.unlink(missing_ok=True)
    os.mkfifo(plant)
    if label == "an icon theme's artwork":
        entry("fifo-app", "fifo-app")
    run = cli("apply")
    chk(f"a FIFO as {label} does not block the apply, which completes",
        (run is not None and run.returncode, (H / ".icons/Omarchroma-Icons/index.theme").is_file()), (0, True))
    plant.unlink()
(apps / "fifo-app.desktop").unlink()
name_file = current / "theme.name"; name_file.unlink(); os.mkfifo(name_file)
run = cli("apply")
chk("...nor does one as Omarchy's theme.name", run is not None and run.returncode, 0)
name_file.unlink(); name_file.write_text("tokyo-night\n")
lock = state / "apply.lock"; lock.unlink(missing_ok=True); os.mkfifo(lock)
run = cli("apply", seconds=10)
chk("a FIFO as its own lock fails the apply at once rather than waiting",
    (run is not None, run is not None and run.returncode != 0), (True, True))
lock.unlink()
chk("read_regular takes a regular file only, and nothing over its cap",
    (ic.read_regular(H / ".local/state/omarchy/current/theme.name", 64), ic.read_regular(root / "run", 64),
     ic.read_regular(name_file, 4)), (b"tokyo-night\n", None, None))
sync = (Path(REPO) / "bin/hyprchroma").read_text()
chk("the sync bounds every Icons apply it starts",
    (len(re.findall(r'"\$HYPRCHROMA_LIB/hyprchroma-icons" apply', sync)),
     len(re.findall(r'timeout -k 5 "\$ICONS_SECONDS" "\$HYPRCHROMA_LIB/hyprchroma-icons" apply', sync))), (2, 2))

# --- an absolute Icon= is honored only for app artwork ----------------------------
good = {"opt": picture(H / ".local/opt/tool/tool.png"),
        "system": picture(SHARE / "pixmaps/sys-tool.png"),
        "share": picture(H / ".local/share/tool2/icon.png"),
        "plugin": picture(H / ".config/omarchy/plugins/io.example.tool/icon.png")}
entry("opt-tool", good["opt"]); entry("sys-tool", good["system"]); entry("share-tool", good["share"])
entry("plugin-tool", good["plugin"])
bad = {"pictures": picture(H / "Pictures/scan.png"),
       "documents": picture(H / "Documents/id.png"),
       "renamed": picture(H / "Fotos/holiday.png"),
       "dotfolder": picture(H / ".mozilla/firefox/cache.png"),
       "trash": picture(H / ".local/share/Trash/files/old.png"),
       "outside": picture(root / "elsewhere/x.png")}
(H / ".config").mkdir(exist_ok=True)
(H / ".config/user-dirs.dirs").write_text('XDG_PICTURES_DIR="$HOME/Fotos"\n')
for label, path in bad.items():
    entry(f"bad-{label}", path)
(H / ".local/opt/tool/link.png").symlink_to(bad["pictures"])
entry("bad-link", H / ".local/opt/tool/link.png")
(H / ".local/opt/tool/notes.png").write_text("not an image at all\n")
entry("bad-notimage", H / ".local/opt/tool/notes.png")
big = H / ".local/opt/tool/big.png"
with open(big, "wb") as handle:
    handle.write(b"\x89PNG\r\n\x1a\n" + b"\0" * (5 << 20))
entry("bad-big", big)
os.mkfifo(H / ".local/opt/tool/fifo.png"); entry("bad-fifo", H / ".local/opt/tool/fifo.png")
(state).mkdir(parents=True, exist_ok=True)
(state / "absolute-sources.json").write_text(json.dumps({"planted": str(bad["pictures"])}))
entry("planted", "planted")
run = cli("apply")
chk("(the apply succeeds)", run is not None and run.returncode, 0)
chk("app artwork under ~/.local/opt, ~/.local/share, Omarchy's plugins and the system's data folders gets covers",
    sorted(p.stem for p in store.glob("*.svg") if p.stem in ("opt-tool", "sys-tool", "share-tool", "plugin-tool")),
    ["opt-tool", "plugin-tool", "share-tool", "sys-tool"])
chk("...and those desktop files, all the user's own, name their covers",
    [icon_line(apps / f"{n}.desktop") for n in ("opt-tool", "sys-tool", "share-tool")], ["opt-tool", "sys-tool", "share-tool"])
refused = sorted(n for n in [f"bad-{k}" for k in bad] + ["bad-link", "bad-notimage", "bad-big", "bad-fifo", "planted"]
                 if (store / f"{n}.svg").exists())
chk("nothing from pictures, documents, a renamed pictures folder, another program's dot folder, the trash, "
    "outside the data folders, through a link, not an image, over 4 MiB, a FIFO, or a planted map", refused, [])
chk("...and each of those keeps its own icon", icon_line(apps / "bad-pictures.desktop"), str(bad["pictures"]))
modes = sorted({stat.S_IMODE(p.stat().st_mode) for p in store.iterdir() if not p.is_symlink()})
chk("covers and their notes are readable by this user only", modes, [0o600])

# --- revert puts back only what a file records about itself -----------------------
opt_tool = apps / "opt-tool.desktop"
chk("a rewritten desktop file records its own original", f"{ic._ORIGINAL_KEY}={good['opt']}" in opt_tool.read_text(), True)
legacy_ok = entry("legacy-ok", "legacy-ok")       # rewritten before the record line existed
legacy_bad = entry("legacy-bad", "legacy-bad")
mail = entry("mail", "mail")                       # never rewritten at all
outside = root / "elsewhere/victim.desktop"; outside.write_text("[Desktop Entry]\nName=Bank\nIcon=bank\nExec=true\n")
linked = apps / "linked.desktop"; linked.symlink_to(outside)
originals = json.loads((state / "absolute-icons.json").read_text())
originals.update({str(legacy_ok): str(good["system"]), str(legacy_bad): str(bad["pictures"]),
                  str(mail): "/attacker/chosen.png", str(apps / ".." / ".." / ".." / ".." / outside.relative_to(root)): "ESCAPED",
                  str(linked): str(good["system"])})
(state / "absolute-icons.json").write_text(json.dumps(originals))
run = cli("revert")
chk("(revert succeeds)", run is not None and run.returncode, 0)
chk("a rewritten file gets its own original back, and loses the record line",
    (icon_line(opt_tool), ic._ORIGINAL_KEY in opt_tool.read_text()), (str(good["opt"]), False))
chk("a file from before the record line is put back only to artwork Icons would draw",
    (icon_line(legacy_ok), icon_line(legacy_bad)), (str(good["system"]), "legacy-bad"))
chk("a file Icons never rewrote is left alone", icon_line(mail), "mail")
chk("...as is one outside the applications folder, by .. or by link", (icon_line(outside), linked.is_symlink()), ("bank", True))

# An entry rewritten earlier whose artwork is no longer one Icons may draw gets
# its own icon back on the next apply, rather than a name nothing provides.
opt_tool.write_text(f"[Desktop Entry]\nName=opt-tool\nIcon=opt-tool\n{ic._ORIGINAL_KEY}={bad['pictures']}\nExec=true\n")
(state / "absolute-icons.json").write_text(json.dumps({str(opt_tool): str(bad["pictures"])}))
cli("apply")
chk("a remembered source that is now refused is given back to the entry, not drawn",
    (icon_line(opt_tool), (store / "opt-tool.svg").exists()), (str(bad["pictures"]), False))

# --- image sizes are bounded before anything is decoded ---------------------------
Img = ic._pil()[0]
chk("Pillow's ceiling is 4096 x 4096 here", Img.MAX_IMAGE_PIXELS, 4096 * 4096)
tall = picture(root / "tall.png", (300, 2600))
wide = picture(root / "wide.png", (2048, 2048))
chk("a folder image that is not square, or over 1024 px, is not traced", (ic.vectorize(tall), ic.vectorize(wide)), (None, None))
huge = root / "huge.png"; Img.new("L", (5000, 5000)).save(huge)
started = time.monotonic()
chk("artwork over 4096 x 4096 is refused", ic.load_artwork(huge), None)
chk("...on its header, at once", time.monotonic() - started < 5, True)
chk("artwork that is a FIFO is refused, without blocking", ic.load_artwork(H / ".local/opt/tool/fifo.png"), None)

# --- one bad entry never costs the others their icons -----------------------------
for path in list(apps.glob("*.desktop")):
    path.unlink()
shutil.rmtree(H / ".icons", ignore_errors=True)
entry("long", "x" * 245)
picture(H / ".local/share/icons/hicolor/48x48/apps/broken.png").write_bytes(b"\x89PNG\r\n\x1a\nbroken")
entry("broken", "broken")
entry("good-tool", good["opt"])
run = cli("apply")
chk("an overlong name and artwork that will not decode leave the apply succeeding",
    (run is not None and run.returncode, (H / ".icons/Omarchroma-Icons/index.theme").is_file()), (0, True))
chk("...and the good entry still gets its cover", (store / "good-tool.svg").is_file(), True)
chk("...while the bad ones are counted as skipped", json.loads((state / "last-apply.json").read_text())["skipped"] >= 2, True)
chk("names a store file may take: the usual characters, at most 200", (
    bool(ic._ICON_NAME.fullmatch("steam_icon_730")), bool(ic._ICON_NAME.fullmatch("org.gnome.Nautilus")),
    bool(ic._ICON_NAME.fullmatch("x" * 201)), bool(ic._ICON_NAME.fullmatch("../x")), bool(ic._ICON_NAME.fullmatch(".hidden"))),
    (True, True, False, False, False))
shutil.rmtree(root)
E
