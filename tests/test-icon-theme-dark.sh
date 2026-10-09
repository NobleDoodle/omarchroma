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
eval "$(sed -n '/^kde_icon_theme() {/,/^}/p' "$REPO/lib/sync-qt-kde-theme")"
omarchy() { echo "$ROOT/theme"; }
omarchy-theme-color() { echo "$MODE"; }
pick() { MODE=$1; echo "$2" > "$ROOT/theme/icons.theme"; omarchy_icon_theme test 2>/dev/null; }

chk "a dark theme asking for a light icon set gets its dark variant" "$(pick dark Testset)" "Testset-dark"
chk "a light theme gets exactly the set it asks for" "$(pick light Testset)" "Testset"
chk "a dark theme whose set has no dark variant keeps the set it asked for" "$(pick dark Lonely)" "Lonely"
chk "a theme already naming a dark set is left alone, not made -dark-dark" "$(pick dark Testset-dark)" "Testset-dark"
chk "a set that is not installed is still refused, dark or not" "$(pick dark Missing)" ""

# -- what KDE applications are given: a hybrid theme ------------------------
# Found live: Okular stayed dark even on Yaru-red-dark -- Yaru lacks most icons
# a KDE application asks for, and they fell back to light-background Breeze.
# A hidden theme inheriting the Omarchy set first and Breeze second keeps the
# set's own icons and fills the rest from Breeze, in the theme's brightness.
export HYPRCHROMA_LIB=$REPO/lib
mkdir -p "$XDG_DATA_HOME/icons/breeze" "$XDG_DATA_HOME/icons/breeze-dark"
THEME=$XDG_DATA_HOME/icons/Omarchroma
kde() { MODE=$1; echo "$2" > "$ROOT/theme/icons.theme"; kde_icon_theme test 2>/dev/null; }
inherits() { grep '^Inherits=' "$THEME/index.theme" | cut -d= -f2; }
chk "KDE applications are pointed at Omarchroma's own theme" "$(kde dark Testset)" "Omarchroma"
chk "...which looks in the Omarchy set first, then breeze-dark, on a dark theme" "$(inherits)" "Testset-dark,breeze-dark,hicolor"
kde light Testset >/dev/null
chk "...and in the set itself, then breeze, on a light one" "$(inherits)" "Testset,breeze,hicolor"
kde dark Missing >/dev/null
chk "...with only Breeze when the theme names no installed set" "$(inherits)" "breeze-dark,hicolor"
chk "it is hidden, and declares a directory -- without one, KDE skips the theme" \
  "$(grep -c '^Hidden=true$' "$THEME/index.theme"),$(grep -c '^Directories=actions/22$' "$THEME/index.theme"),$([ -d "$THEME/actions/22" ] && echo dir)" "1,1,dir"
kde dark Testset >/dev/null; before=$(stat -c %Y.%i "$THEME/index.theme"); sleep 1
kde dark Testset >/dev/null
chk "...and is rewritten only when it changes" "$(stat -c %Y.%i "$THEME/index.theme")" "$before"
chk "kdeglobals is written with it" \
  "$(grep -c '"$(kde_icon_theme sync-qt-kde-theme)"' "$REPO/lib/sync-qt-kde-theme")" "1"
chk "the GTK icon setting is never touched" "$(grep -c 'gsettings set' "$REPO/lib/sync-qt-kde-theme")" "0"

python3 - "$REPO" <<'PY'
import sys, types
st = types.ModuleType("st")
exec(compile(open(sys.argv[1] + "/lib/hyprchroma-state").read().split("if __name__")[0], "st", "exec"), st.__dict__)
st.remove_hybrid_icon_theme()
PY
chk "switching Qt/KDE off removes the theme, directories and all" "$([ -e "$THEME" ] && echo still there || echo gone)" "gone"
chk "...from both revert paths" "$(grep -c '        remove_hybrid_icon_theme()' "$REPO/lib/hyprchroma-state")" "2"
