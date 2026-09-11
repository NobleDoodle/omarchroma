#!/usr/bin/env bash
set -euo pipefail

# sudo and pkexec are resolved from here rather than from the inherited PATH:
# this script authenticates, and a planted "sudo" earlier in PATH would be a
# credential prompt under someone else's control. Omarchy's own privileged
# helper pins PATH for the same reason and accepts the same cost -- a dev-linked
# Omarchy checkout is shadowed by the packaged one.
PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/share/omarchy/bin
export PATH

PLUGIN_ID="io.github.nobledoodle.omarchroma"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENABLE=0
INSTALL_PACKAGES=1
REINSTALL=0
UPGRADE=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--enable] [--no-packages] [--reinstall]

Installs Omarchroma, its theme-change hook, GTK and Qt/KDE support, and the
command used by its service and bar widget. It does not install Dark Reader:
install that yourself and Omarchroma will theme it.

Re-run it to upgrade an existing install. An upgrade refreshes the plugin,
commands and hooks, and does not ask for consent again or re-authenticate a
Your captured original state is left
untouched, so nothing is re-captured.

  --enable       Enable Omarchroma and place its icon before the power widget
  --no-packages  Do not install adw-gtk-theme or python-plyvel
  --reinstall    Treat an existing install as a first install (asks again)
EOF
}

command_output() {
  local output
  output=$("$@" 2>/dev/null) || return 0
  printf '%s' "$output"
}

require_install_acknowledgement() {
  cat <<EOF
Omarchroma install consent

This installer changes user and system configuration so Omarchy theme changes
can be synchronized outside the Omarchy shell.

Before installing, it may:
- install missing outside packages with pacman: adw-gtk-theme, python-plyvel
- copy this plugin into:
  $TARGET_DIR
- overwrite Omarchroma command shims in:
  $HOME/.local/bin/omarchroma-sync
  $HOME/.local/bin/omarchroma-dark-reader
  $HOME/.local/bin/omarchroma-state
- install the native Omarchy theme and font hooks:
  $HOME/.config/omarchy/hooks/theme-set.d/omarchroma
  $HOME/.config/omarchy/hooks/font-set.d/omarchroma
- snapshot original application and browser state under:
  ${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma/original/
- remove the browser policy an earlier Omarchroma installed, if one is still
  present, together with the root-owned backup it kept under
  /var/lib/omarchroma/. Omarchroma installs no browser policy of its own;
  Dark Reader is yours to install and yours to remove
- set the KDE color scheme for every app once in kdeglobals, and clear
  per-application pins that would override it, recording each original value
  for the uninstaller, never editing the configuration of an application that
  is currently running
- leave kdeglobals and the generated color scheme untouched while a KDE
  application has a window open, and start a helper that sleeps until that
  application exits and then applies them
- after a change, list the open applications still showing the previous theme,
  excluding those Omarchy re-themes itself, and without signalling, quitting or
  restarting any of them
- close background application services that are left running with no window and
  the previous theme, so their next window is themed; anything with a window on
  screen is never touched, and each is asked through its own quit action rather
  than signalled
- run an initial sync that may update:
  $HOME/.config/gtk-3.0/
  $HOME/.config/gtk-4.0/
  $HOME/.config/kdeglobals
  the [UiSettings] ColorScheme key in $HOME/.config/*rc
  the GTK and KDE icon theme, set to the one the Omarchy theme names
  the GTK monospace font family, set to the one Omarchy is using
  $HOME/.local/share/color-schemes/Omarchroma.colors
  $HOME/.config/YouTube Music/omarchroma.css
  the active browser profile's Dark Reader settings
- enable the Omarchy bar widget if --enable is used

The uninstaller restores the state captured before Omarchroma first changed
each integration. Dark Reader sync and restore require the target browser to be
closed. Removing a browser policy left by an earlier version is performed by a
fixed privileged helper and prompts for administrator authentication.

Type "I understand" to continue:
EOF

  local acknowledgement
  if ! read -r acknowledgement; then
    die "install cancelled: acknowledgement was not provided"
  fi
  [[ "$acknowledgement" == "I understand" ]] || \
    die "install cancelled: acknowledgement did not match"
}

for argument in "$@"; do
  case "$argument" in
    --enable) ENABLE=1 ;;
    --no-packages) INSTALL_PACKAGES=0 ;;
    --reinstall) REINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $argument" ;;
  esac
done

command -v omarchy >/dev/null || die "omarchy is not available"
command -v jq >/dev/null || die "jq is not available"

# An existing install is an upgrade. Consent covers changing your system and
# capturing its original state; both already happened, and neither is repeated
# here -- capture is create-once, so the recorded original survives untouched.
# Asking again on every version bump trains people to type past it.
if (( ! REINSTALL )) && [[ -f "$TARGET_DIR/manifest.json" || -e "$STATE_DIR/original/manifest.json" ]]; then
  UPGRADE=1
fi

if (( UPGRADE )); then
  version=$(jq -r '.version // "?"' "$SOURCE_DIR/manifest.json" 2>/dev/null || printf '?')
  info "Upgrading Omarchroma to $version"
  info "Refreshing the plugin, commands and hooks; captured original state is left as it is"
else
  require_install_acknowledgement
fi

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
  install -m 755 "$SOURCE_DIR/bin/omarchroma-policy-cleanup" \
    "$TARGET_DIR/bin/omarchroma-policy-cleanup"
  install -m 755 "$SOURCE_DIR/bin/omarchroma-state" \
    "$TARGET_DIR/bin/omarchroma-state"
  install -m 755 "$SOURCE_DIR/hooks/omarchroma" "$TARGET_DIR/hooks/omarchroma"
  install -m 644 "$SOURCE_DIR/assets/pear-theme.css.template" \
    "$TARGET_DIR/assets/pear-theme.css.template"
  install -m 755 "$SOURCE_DIR/lib/sync-gtk-theme" "$TARGET_DIR/lib/sync-gtk-theme"
  install -m 755 "$SOURCE_DIR/lib/sync-qt-kde-theme" \
    "$TARGET_DIR/lib/sync-qt-kde-theme"
fi

install -Dm755 "$TARGET_DIR/bin/omarchroma-sync" "$HOME/.local/bin/omarchroma-sync"
install -Dm755 "$TARGET_DIR/bin/omarchroma-dark-reader" \
  "$HOME/.local/bin/omarchroma-dark-reader"
install -Dm755 "$TARGET_DIR/bin/omarchroma-state" \
  "$HOME/.local/bin/omarchroma-state"
omarchy hook install theme-set "$TARGET_DIR/hooks/omarchroma"
# omarchy font set fires font-set; without this the new font only reaches
# GTK when something else happens to trigger a sync.
omarchy hook install font-set "$TARGET_DIR/hooks/omarchroma"

# Omarchroma does not install Dark Reader. It used to, through a browser
# enterprise policy, which never themed anything by itself and made a theming
# plugin the browser's administrator -- and on a browser that could not complete
# the install it left the extension impossible to install by any route. Only
# say whether it is there; Omarchroma themes it either way once it is.
browser_info=$("$TARGET_DIR/bin/omarchroma-dark-reader" --info 2>/dev/null || printf '{}')
browser_name=$(jq -r '.name // "your browser"' <<<"$browser_info")
if [[ $(jq -r '.supported // false' <<<"$browser_info") != "true" ]]; then
  info "$browser_name is not a supported browser; Dark Reader will not be themed"
elif [[ $(jq -r '.darkReaderInstalled // false' <<<"$browser_info") == "true" ]]; then
  info "Dark Reader found in $browser_name; it will follow the theme"
else
  info "Dark Reader is not installed in $browser_name. Install it yourself and"
  info "Omarchroma will theme it from the next sync -- it installs nothing for you."
fi

# An older Omarchroma installed a browser policy. Take it back out rather than
# leaving a root-owned file behind that nothing maintains. This is the only
# privileged step besides installing packages, it runs once, and it only ever
# removes.
if [[ -e /var/lib/omarchroma/policy-backup/manifest.json ]]; then
  info "Removing the browser policy an earlier Omarchroma installed"
  "$TARGET_DIR/bin/omarchroma-policy-cleanup" || \
    warn "Could not remove it; run $TARGET_DIR/bin/omarchroma-policy-cleanup by hand"
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

if (( UPGRADE )); then
  info "Omarchroma upgraded"
else
  info "Omarchroma installed"
fi
