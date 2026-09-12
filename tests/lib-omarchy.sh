# Seed a synthetic Omarchy theme under $HOME so the REAL omarchy answers against
# it. The scripts pin PATH, so a stubbed "omarchy" on PATH is correctly ignored
# -- the fake has to live where omarchy actually looks, which is $HOME.
seed_omarchy_theme() {
  local dir="$HOME/.local/state/omarchy/current/theme"
  mkdir -p "$dir"
  cat > "$dir/colors.toml" <<'TOML'
mode = "dark"
accent = "#e8bd72"
selection = "#405648"
muted = "#64766f"
background = "#17241e"
dark_background = "#101914"
darker_background = "#0b120e"
lighter_background = "#27382f"
selection_foreground = "#f2ecd9"
foreground = "#d9e1d4"
dark_foreground = "#83938b"
light_foreground = "#b9c7bd"
bright_foreground = "#f2ecd9"
red = "#d46f58"
bright_red = "#ed876b"
green = "#91a354"
bright_green = "#a8bb63"
yellow = "#e8bd72"
bright_yellow = "#f0cf95"
blue = "#6f9fb5"
magenta = "#b07fa8"
TOML
  echo "testtheme" > "$HOME/.local/state/omarchy/current/theme.name"
  # gsettings is real too; this backend keeps it out of the user's dconf.
  export GSETTINGS_BACKEND=memory
}
