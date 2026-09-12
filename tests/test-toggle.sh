#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
REPO=$REPO
ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
export HYPRCHROMA_LIB=$REPO/lib HYPRCHROMA_SHARE=$REPO/share
source "$(dirname "$0")/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR"

S=$XDG_STATE_HOME/hyprchroma
mkdir -p "$S/original/files" "$HOME/.config/gtk-3.0"
printf 'ORIGINAL-GTK3\n' > "$S/original/files/gtk3_css"
python3 - "$S/original/manifest.json" "$HOME" <<'E'
import json,sys
json.dump({"files":{
 "gtk3_css":{"path":f"{sys.argv[2]}/.config/gtk-3.0/gtk.css","existed":True,"backup":"files/gtk3_css"},
 "gtk4_css":{"path":f"{sys.argv[2]}/.config/gtk-4.0/gtk.css","existed":False}},
 "gsettings":{}}, open(sys.argv[1],"w"))
E
printf 'HYPRCHROMA-GENERATED\n' > "$HOME/.config/gtk-3.0/gtk.css"

echo "--- toggling gtk off ---"
bash "$REPO/bin/hyprchroma" --target=gtk --set-enabled=false
echo "exit=$?"
echo "gtk.css now: $(cat "$HOME/.config/gtk-3.0/gtk.css")"
echo "settings.json: $(cat "$S/settings.json")"
[[ $(cat "$HOME/.config/gtk-3.0/gtk.css") == "ORIGINAL-GTK3" ]] \
  && echo "PASS reverted to captured" || echo "FAIL not reverted"
grep -q '"gtk": false' "$S/settings.json" && echo "PASS toggle recorded" || echo "FAIL toggle not recorded"
[[ -f $S/settings.json ]] && echo "PASS settings.json survived" || echo "FAIL settings.json deleted"
rm -rf "$ROOT"
