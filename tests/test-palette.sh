#!/usr/bin/env bash
# The palette is an input now, not a call into Omarchy. Omarchy is one source
# among others; a palette file is another, and it is what makes this usable on
# a plain Arch or Quickshell system with no Omarchy at all.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
countcode(){ local pat=$1; shift; code "$@" | grep -ohE "$pat" | wc -l; }
P=lib/hyprchroma-palette

# A throwaway home with a synthetic Omarchy theme in it, which the real
# omarchy command then answers against: the capture checks below then test the
# resolver, not whichever theme this machine happens to be on -- and seeding
# never lands in a real home, even when this suite is run on its own.
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
source "$REPO/tests/lib-omarchy.sh"
seed_omarchy_theme
# Omarchy's own themes leave this out and derive it, which is the point of
# the "derives rather than stores" check.
sed -i '/^selection_foreground = /d' "$HOME/.local/state/omarchy/current/theme/colors.toml"
T=$(mktemp -d "$HOME/palette-XXXXXX")
mkdir -p "$T/hyprchroma"

# --- the file format is complete and self-describing ----------------------
./$P --template > "$T/hyprchroma/palette.toml"
chk "the template carries every required key" \
  "$(grep -c '^[a-z_]* = "#' "$T/hyprchroma/palette.toml")" "20"
chk "a file source wins over Omarchy" \
  "$(XDG_CONFIG_HOME=$T ./$P --source)" "$T/hyprchroma/palette.toml"

# Hex values start with "#", so a parser that strips comments first destroys
# every color in the file. It did.
chk "a quoted #rrggbb value survives parsing" \
  "$(XDG_CONFIG_HOME=$T ./$P background)" "#000000"
printf 'background = "#123456"  # a trailing comment\n' >> "$T/hyprchroma/palette.toml"
chk "a trailing comment after a value is ignored" \
  "$(XDG_CONFIG_HOME=$T ./$P background)" "#123456"

# --- mode is inferred rather than demanded --------------------------------
chk "a dark background infers dark" "$(XDG_CONFIG_HOME=$T ./$P mode)" "dark"
sed -i 's/^background = .*/background = "#f5f5f5"/' "$T/hyprchroma/palette.toml"
chk "a light background infers light" "$(XDG_CONFIG_HOME=$T ./$P mode)" "light"

# --- an incomplete or wrong file says so ----------------------------------
printf 'background = "#111111"\n' > "$T/hyprchroma/palette.toml"
chk "a missing key is named" \
  "$(XDG_CONFIG_HOME=$T ./$P background 2>&1 | grep -c 'is missing: ')" "1"
./$P --template | sed 's/^accent = .*/accent = "nonsense"/' > "$T/hyprchroma/palette.toml"
chk "a value that is not #rrggbb is refused" \
  "$(XDG_CONFIG_HOME=$T ./$P accent 2>&1 | grep -c 'not #rrggbb')" "1"

# --- capture is the bridge from Omarchy to the file -----------------------
# Omarchy derives several keys rather than storing them, so its own colors.toml
# is not a palette file. Capturing resolves them through Omarchy and writes the
# result, which is why it is not the same as copying the theme.
if ./$P --source 2>/dev/null | grep -q omarchy; then
  ./$P --capture > "$T/hyprchroma/palette.toml"
  chk "capture writes every required key" \
    "$(grep -c '^[a-z_]* = "#' "$T/hyprchroma/palette.toml")" "20"
  chk "capture includes a key Omarchy derives rather than stores" \
    "$(XDG_CONFIG_HOME=$T ./$P selection_foreground | grep -c '^#')" "1"
  chk "what capture wrote reads back without Omarchy" \
    "$(XDG_CONFIG_HOME=$T ./$P --all | wc -l)" "21"
else
  echo "  SKIP capture checks (no Omarchy on this machine)"
fi

# --- cost -----------------------------------------------------------------
# Resolving key by key meant a process start per key, and a full sync reads
# more than fifty. One pass, once per script.
chk "the whole palette is resolved in one Omarchy call" \
  "$(countcode '"omarchy", "theme", "color", "--all"' $P)" "1"
chk "no per-key Omarchy call remains" \
  "$(countcode '"omarchy", "theme", "color", key' $P)" "0"
# $(color x) runs in a subshell, so anything color() sets is discarded; loading
# from inside it re-resolved the palette on every single key.
chk "color() does not load the palette itself" \
  "$(countcode 'PALETTE_LOADED \)\) \|\| load_palette' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "0"
chk "each generator loads it once, in the parent shell" \
  "$(grep -c '^load_palette$' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme | grep -c ':1$')" "3"

# --- Omarchy stays first class -------------------------------------------
chk "hooks are installed only when Omarchy is the source" \
  "$(countcode 'hyprchroma-palette" --source 2>/dev/null\) == omarchy' bin/hyprchroma)" "1"
chk "no generator calls omarchy for a color any more" \
  "$(countcode 'omarchy theme color' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "0"
