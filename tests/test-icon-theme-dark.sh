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
