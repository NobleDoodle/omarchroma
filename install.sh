#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="omarchroma"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENABLE=0
INSTALL_PACKAGES=1
INSTALL_POLICY=1

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--enable] [--no-packages] [--no-policy]

Installs Omarchroma, its theme-change hook, GTK and Qt/KDE support, Dark Reader
policy, and the command used by its service and bar widget.

  --enable       Enable Omarchroma and place its icon before the power widget
  --no-packages  Do not install adw-gtk-theme or python-plyvel
  --no-policy    Do not install the Dark Reader browser policy
EOF
}

for argument in "$@"; do
  case "$argument" in
    --enable) ENABLE=1 ;;
    --no-packages) INSTALL_PACKAGES=0 ;;
    --no-policy) INSTALL_POLICY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $argument" ;;
  esac
done

command -v omarchy >/dev/null || die "omarchy is not available"

if (( INSTALL_PACKAGES )); then
  missing=()
  for package in adw-gtk-theme python-plyvel; do
    pacman -Qq "$package" &>/dev/null || missing+=("$package")
  done
  if (( ${#missing[@]} )); then
    info "Installing dependencies: ${missing[*]}"
    if [[ -t 0 ]]; then
      sudo pacman -S --needed --noconfirm "${missing[@]}"
    else
      pkexec pacman -S --needed --noconfirm "${missing[@]}"
    fi
  fi
fi

info "Installing Omarchroma"
if [[ "$SOURCE_DIR" != "$TARGET_DIR" ]]; then
  mkdir -p \
    "$TARGET_DIR/bin" \
    "$TARGET_DIR/hooks" \
    "$TARGET_DIR/assets" \
    "$TARGET_DIR/lib"
  install -m 644 "$SOURCE_DIR/manifest.json" "$TARGET_DIR/manifest.json"
  install -m 644 "$SOURCE_DIR/BarWidget.qml" "$TARGET_DIR/BarWidget.qml"
  install -m 644 "$SOURCE_DIR/Panel.qml" "$TARGET_DIR/Panel.qml"
  install -m 644 "$SOURCE_DIR/Service.qml" "$TARGET_DIR/Service.qml"
  install -m 644 "$SOURCE_DIR/README.md" "$TARGET_DIR/README.md"
  install -m 644 "$SOURCE_DIR/LICENSE" "$TARGET_DIR/LICENSE"
  install -m 755 "$SOURCE_DIR/install.sh" "$TARGET_DIR/install.sh"
  install -m 755 "$SOURCE_DIR/uninstall.sh" "$TARGET_DIR/uninstall.sh"
  install -m 755 "$SOURCE_DIR/bin/omarchroma-sync" "$TARGET_DIR/bin/omarchroma-sync"
  install -m 755 "$SOURCE_DIR/bin/omarchroma-dark-reader" \
    "$TARGET_DIR/bin/omarchroma-dark-reader"
  install -m 755 "$SOURCE_DIR/hooks/omarchroma" "$TARGET_DIR/hooks/omarchroma"
  install -m 644 "$SOURCE_DIR/assets/dark-reader-policy.json" \
    "$TARGET_DIR/assets/dark-reader-policy.json"
  install -m 644 "$SOURCE_DIR/assets/pear-theme.css.template" \
    "$TARGET_DIR/assets/pear-theme.css.template"
  install -m 755 "$SOURCE_DIR/lib/sync-gtk-theme" "$TARGET_DIR/lib/sync-gtk-theme"
  install -m 755 "$SOURCE_DIR/lib/sync-qt-kde-theme" \
    "$TARGET_DIR/lib/sync-qt-kde-theme"
fi

install -Dm755 "$TARGET_DIR/bin/omarchroma-sync" "$HOME/.local/bin/omarchroma-sync"
install -Dm755 "$TARGET_DIR/bin/omarchroma-dark-reader" \
  "$HOME/.local/bin/omarchroma-dark-reader"
omarchy hook install theme-set "$TARGET_DIR/hooks/omarchroma"
rm -f \
  "$HOME/.config/omarchy/hooks/theme-set.d/sync-gtk-theme" \
  "$HOME/.local/bin/apply-dark-reader-theme"

if (( INSTALL_POLICY )); then
  browser_info=$("$TARGET_DIR/bin/omarchroma-dark-reader" --info)
  if [[ $(jq -r '.supported' <<<"$browser_info") == "true" ]]; then
    policy_dir=$(jq -r '.policy' <<<"$browser_info")
    browser_name=$(jq -r '.name' <<<"$browser_info")
    info "Installing Dark Reader for the default browser: $browser_name"
    if [[ -t 0 ]]; then
      sudo install -d -m 755 "$policy_dir"
      sudo rm -f "$policy_dir/99-primeval-dawn-dark-reader.json"
      sudo install -m 644 "$TARGET_DIR/assets/dark-reader-policy.json" \
        "$policy_dir/99-omarchroma-dark-reader.json"
    else
      pkexec install -d -m 755 "$policy_dir"
      pkexec rm -f "$policy_dir/99-primeval-dawn-dark-reader.json"
      pkexec install -m 644 "$TARGET_DIR/assets/dark-reader-policy.json" \
        "$policy_dir/99-omarchroma-dark-reader.json"
    fi
  else
    warn "The default browser is not Chromium-based; Dark Reader was skipped"
  fi
fi

omarchy plugin validate "$TARGET_DIR"
command -v omarchy-shell >/dev/null && \
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if (( ENABLE )); then
  omarchy plugin enable "$PLUGIN_ID" \
    --section right --before omarchy.power
fi

OMARCHROMA_PLUGIN_DIR="$TARGET_DIR" "$HOME/.local/bin/omarchroma-sync" \
  --force --notify || warn "Initial synchronization was incomplete"

info "Omarchroma installed"
