#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
REPO=$REPO
ROOT=$(mktemp -d); export HOME=$ROOT
STUB=$ROOT/stub; mkdir -p "$STUB"
cat > "$STUB/gsettings" <<'E'
#!/usr/bin/env bash
echo "$*" >> "$HOME/gsettings.log"
[[ $1 == get ]] && echo "'stubbed'"
exit 0
E
cat > "$STUB/omarchy-theme-set-gnome" <<'E'
#!/usr/bin/env bash
echo "reauthored" >> "$HOME/gsettings.log"
E
chmod +x "$STUB"/*; export PATH="$STUB:$PATH"

S=$HOME/.local/state/hyprchroma; D=$HOME/.local/share/hyprchroma
mkdir -p "$S/original/files" "$D" "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0" \
         "$HOME/.local/share/color-schemes" "$HOME/.config/YouTube Music"

printf 'ORIGINAL-GTK3\n' > "$S/original/files/gtk3_css"
printf 'ORIGINAL-KDEGLOBALS\n' > "$S/original/files/kdeglobals"
printf '{\n\t"window-size": {"width": 900},\n\t"url": "USER-URL",\n\t"options": {"themes": ["/u/mine.css"]}\n}\n' \
  > "$S/original/files/pear_config"

python3 - "$S/original/manifest.json" "$HOME" <<'E'
import json,sys
m={"files":{
 "gtk3_css":{"path":f"{sys.argv[2]}/.config/gtk-3.0/gtk.css","existed":True,"backup":"files/gtk3_css"},
 "gtk4_css":{"path":f"{sys.argv[2]}/.config/gtk-4.0/gtk.css","existed":False},
 "kdeglobals":{"path":f"{sys.argv[2]}/.config/kdeglobals","existed":True,"backup":"files/kdeglobals"},
 "hyprchroma_colors":{"path":f"{sys.argv[2]}/.local/share/color-schemes/Hyprchroma.colors","existed":False},
 "pear_config":{"path":f"{sys.argv[2]}/.config/YouTube Music/config.json","existed":True,"backup":"files/pear_config"},
 "pear_css":{"path":f"{sys.argv[2]}/.config/YouTube Music/hyprchroma.css","existed":False}},
 "gsettings":{"gtk-theme":"'captured-gtk'","accent-color":"'captured-accent'"}}
open(sys.argv[1],"w").write(json.dumps(m,indent=2))
E

seed() {
  mkdir -p "$HOME/.local/share/color-schemes"
  printf 'HYPRCHROMA-GENERATED\n' > "$HOME/.config/gtk-3.0/gtk.css"
  printf 'HYPRCHROMA-GENERATED\n' > "$HOME/.config/gtk-4.0/gtk.css"
  printf 'HYPRCHROMA-GENERATED\n' > "$HOME/.config/kdeglobals"
  printf 'HYPRCHROMA\n' > "$HOME/.local/share/color-schemes/Hyprchroma.colors"
  printf 'HYPRCHROMA\n' > "$HOME/.config/YouTube Music/hyprchroma.css"
  printf '{\n\t"window-size": {"width": 351},\n\t"url": "LATER-URL",\n\t"options": {"themes": ["/u/mine.css", "%s/.config/YouTube Music/hyprchroma.css"]}\n}\n' "$HOME" \
    > "$HOME/.config/YouTube Music/config.json"
  : > "$HOME/gsettings.log"
}
# Drive the module in process and re-open PATH *after* its pin, so the stubs
# can be observed. The shipped code still pins; this is the harness declining to
# be pinned, which is the only way to watch which commands it would run.
run() {
  STUB_DIR="$STUB" REPO="$REPO" S="$S" D="$D" python3 - "$@" <<'DRIVER'
import os, sys, types
src = open(os.environ["REPO"] + "/lib/hyprchroma-state").read()
mod = types.ModuleType("state")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "state", "exec"), mod.__dict__)
os.environ["PATH"] = os.environ["STUB_DIR"] + ":" + os.environ["PATH"]
sys.argv = ["hyprchroma-state", "--state-dir", os.environ["S"],
            "--data-dir", os.environ["D"], "restore"] + sys.argv[1:]
raise SystemExit(mod.main() or 0)
DRIVER
}
chk() { if [[ $2 == "$3" ]]; then echo "  PASS $1"; else echo "  FAIL $1: got [$2] want [$3]"; fi; }
ex()  { [[ -e $2 ]] && echo "  FAIL $1: $2 still exists" || echo "  PASS $1"; }

echo "--- captured: gtk ---"; seed; run --target gtk --mode captured >/dev/null
chk "gtk3 restored from backup" "$(cat "$HOME/.config/gtk-3.0/gtk.css")" "ORIGINAL-GTK3"
ex  "gtk4 removed (existed=false)" "$HOME/.config/gtk-4.0/gtk.css"
chk "gsettings replayed" "$(grep -c 'set org.gnome' "$HOME/gsettings.log")" "2"

echo "--- stock: gtk ---"; seed; run --target gtk --mode stock >/dev/null
ex  "gtk3 deleted" "$HOME/.config/gtk-3.0/gtk.css"
ex  "gtk4 deleted" "$HOME/.config/gtk-4.0/gtk.css"
chk "hyprchroma-only keys reset" "$(grep -c '^reset' "$HOME/gsettings.log")" "2"
chk "omarchy re-authored owned keys" "$(grep -c '^reauthored' "$HOME/gsettings.log")" "1"
chk "no captured gsettings replayed" "$(grep -c 'captured' "$HOME/gsettings.log")" "0"

echo "--- stock: qt-kde ---"; seed; run --target qt-kde --mode stock >/dev/null
ex  "kdeglobals deleted" "$HOME/.config/kdeglobals"
ex  "Hyprchroma.colors deleted" "$HOME/.local/share/color-schemes/Hyprchroma.colors"

echo "--- captured: qt-kde ---"; seed; run --target qt-kde --mode captured >/dev/null
chk "kdeglobals restored" "$(cat "$HOME/.config/kdeglobals")" "ORIGINAL-KDEGLOBALS"

echo "--- pear: user state must survive ---"; seed
run --target pear --mode captured >/dev/null
chk "captured themes" "$(python3 -c 'import json,os;print(json.load(open(os.environ["HOME"]+"/.config/YouTube Music/config.json"))["options"]["themes"])')" "['/u/mine.css']"
chk "window-size NOT rolled back" "$(python3 -c 'import json,os;print(json.load(open(os.environ["HOME"]+"/.config/YouTube Music/config.json"))["window-size"]["width"])')" "351"
chk "url NOT rolled back" "$(python3 -c 'import json,os;print(json.load(open(os.environ["HOME"]+"/.config/YouTube Music/config.json"))["url"])')" "LATER-URL"

seed; run --target pear --mode stock >/dev/null
chk "stock drops only hyprchroma" "$(python3 -c 'import json,os;print(json.load(open(os.environ["HOME"]+"/.config/YouTube Music/config.json"))["options"]["themes"])')" "['/u/mine.css']"
ex  "pear css deleted" "$HOME/.config/YouTube Music/hyprchroma.css"

echo "--- single target must not delete settings.json ---"; seed
printf '{"frameworks":{"gtk":false}}' > "$S/settings.json"
run --target gtk --mode captured >/dev/null
[[ -f $S/settings.json ]] && echo "  PASS settings.json kept" || echo "  FAIL settings.json deleted"
run --mode captured >/dev/null
[[ -f $S/settings.json ]] && echo "  FAIL settings.json kept on full revert" || echo "  PASS settings.json cleared on full revert"
rm -rf "$ROOT"
