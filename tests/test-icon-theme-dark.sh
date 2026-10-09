#!/usr/bin/env bash
# Issue #3: KDE applications (Okular) drew dark monochrome icons on dark
# themes. Omarchy's themes name the light variant of their icon set (Yaru-blue,
# Yaru-red) even when the theme is dark, and KDE recolors only Breeze's icons,
# so the Qt/KDE sync uses the set's dark variant on a dark theme where one is
# installed. Driven against the function itself, with Omarchy's two commands
# stood in for and icon sets that exist only in a scratch data directory.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data
mkdir -p "$XDG_STATE_HOME/omarchy/current" "$ROOT/theme" "$XDG_DATA_HOME/icons/Testset" "$XDG_DATA_HOME/icons/Testset-dark" "$XDG_DATA_HOME/icons/Lonely"
echo "test-theme" > "$XDG_STATE_HOME/omarchy/current/theme.name"
eval "$(sed -n '/^omarchy_icon_theme() {/,/^}/p' "$REPO/lib/sync-qt-kde-theme")"
omarchy() { echo "$ROOT/theme"; }
omarchy-theme-color() { echo "$MODE"; }
pick() { MODE=$1; echo "$2" > "$ROOT/theme/icons.theme"; omarchy_icon_theme test 2>/dev/null; }

chk "a dark theme asking for a light icon set gets its dark variant" "$(pick dark Testset)" "Testset-dark"
chk "a light theme gets exactly the set it asks for" "$(pick light Testset)" "Testset"
chk "a dark theme whose set has no dark variant keeps the set it asked for" "$(pick dark Lonely)" "Lonely"
chk "a theme already naming a dark set is left alone, not made -dark-dark" "$(pick dark Testset-dark)" "Testset-dark"
chk "a set that is not installed is still refused, dark or not" "$(pick dark Missing)" ""

# -- the setting Qt applications actually read -------------------------------
# On Omarchy, QT_QPA_PLATFORMTHEME=gtk3: Qt takes its icon set from the GTK
# setting, not kdeglobals -- found live, Okular still dark after the kdeglobals
# fix. gsettings is stood in for: nothing here touches the real setting.
eval "$(sed -n '/^sync_icon_theme_setting() {/,/^}/p' "$REPO/lib/sync-qt-kde-theme")"
GSET=$ROOT/gsettings.log
gsettings() {
  case $1 in
    get) echo "'$CURRENT'" ;;
    set) echo "$4" >> "$GSET" ;;
  esac
}
setting() { : > "$GSET"; MODE=$1; echo "$2" > "$ROOT/theme/icons.theme"; CURRENT=$3; sync_icon_theme_setting; cat "$GSET"; }
chk "a dark theme turns Omarchy's light icon setting into the set's dark variant" \
  "$(setting dark Testset Testset)" "Testset-dark"
chk "...but never a setting that holds something else, the user's own choice included" \
  "$(setting dark Testset Papirus)" ""
chk "...nor anything on a light theme" "$(setting light Testset Testset)" ""
chk "...and one already dark is not set again" "$(setting dark Testset Testset-dark)" ""
chk "the sync applies it ahead of waiting for KDE applications to close" \
  "$(grep -A8 'sync-qt-kde-theme" --icon-theme' "$REPO/bin/hyprchroma" | grep -c 'kde_clients=\$(')" "1"

# -- reverting puts Omarchy's own set back, and only that ---------------------
undo() {
  python3 - "$REPO" "$1" "$2" <<'PY'
import sys, types
st = types.ModuleType("st")
exec(compile(open(sys.argv[1] + "/lib/hyprchroma-state").read().split("if __name__")[0], "st", "exec"), st.__dict__)
calls = []
current = sys.argv[3]
def fake_run(argv, **kwargs):
    calls.append(argv[1:])
    return types.SimpleNamespace(returncode=0, stdout=f"'{current}'\n")
st.subprocess.run = fake_run
st.undo_dark_icon_theme()
print(" ".join(c[-1] for c in calls if c[0] == "set") or "none")
PY
}
echo "Testset" > "$ROOT/theme/icons.theme"
mkdir -p "$XDG_STATE_HOME/omarchy/current/theme"; echo "Testset" > "$XDG_STATE_HOME/omarchy/current/theme/icons.theme"
chk "switching Qt/KDE off puts back the light set Omarchy named" "$(undo x Testset-dark)" "Testset"
chk "...but leaves any other setting as it is" "$(undo x Papirus)" "none"
chk "...and both revert paths do it" "$(grep -c '        undo_dark_icon_theme()' "$REPO/lib/hyprchroma-state")" "2"
