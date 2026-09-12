#!/usr/bin/env bash
set -euo pipefail

# Commands are resolved from a fixed, verified set of directories rather than
# from whatever PATH was inherited. Most of these scripts run unattended --
# from the shell service and from theme hooks -- so a directory someone else
# can write to appearing earlier in PATH would hand them every command run
# here; the installer and uninstaller pin it for the same reason even though
# a person starts those.
# /usr/local/bin and /usr/local/sbin are not in the set -- nothing this plugin
# invokes lives there, and they are the entries most often left group-writable
# on a real machine -- and /bin, /sbin and /usr/sbin are usrmerge symlinks to
# /usr/bin that add nothing. What is left is checked to be root-owned and
# unwritable by anyone else rather than assumed to be. /usr/bin/stat is named
# absolutely because it is the trust root the check is anchored to: if it
# cannot be trusted, nothing here can be.
omarchroma_trusted_path() {
  local directory owner mode trusted=""
  for directory in /usr/bin /usr/share/omarchy/bin; do
    [[ -d $directory ]] || continue
    read -r owner mode < <(/usr/bin/stat -Lc '%u %a' "$directory" 2>/dev/null) || continue
    [[ $owner == 0 ]] || continue
    (( (8#$mode & 8#022) == 0 )) || continue
    trusted="${trusted:+$trusted:}$directory"
  done
  # With stat itself unavailable there is nothing to validate against, so fall
  # back to the same fixed identities rather than to the inherited PATH.
  printf '%s' "${trusted:-/usr/bin:/usr/share/omarchy/bin}"
}
PATH=$(omarchroma_trusted_path)
export PATH

PLUGIN_ID="io.github.nobledoodle.omarchroma"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENABLE=0
REINSTALL=0
UPGRADE=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--enable] [--reinstall]

Installs Omarchroma, its theme-change hook, GTK and Qt/KDE support, and the
command used by its service and bar widget. It does not install Dark Reader:
install that yourself and Omarchroma will theme it.

Re-run it to upgrade an existing install. An upgrade refreshes the plugin,
commands and hooks, and does not ask for consent again or re-authenticate a
Your captured original state is left
untouched, so nothing is re-captured.

  --enable       Enable Omarchroma and place its icon before the power widget
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

This installer changes your own configuration so Omarchy theme changes can be
synchronized outside the Omarchy shell. It installs no packages, runs no
privileged command, and writes nothing outside your home directory.

Before installing, it may:
- install itself, replacing any earlier copy already there:
  $TARGET_DIR
  $HOME/.local/bin/omarchroma-sync
  $HOME/.local/bin/omarchroma-dark-reader
  $HOME/.local/bin/omarchroma-state
  $HOME/.config/omarchy/hooks/theme-set.d/omarchroma
  $HOME/.config/omarchy/hooks/font-set.d/omarchroma
- snapshot original application and browser state under:
  ${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma/original/
- set the KDE color scheme in kdeglobals and clear per-application pins that
  would override it (original values recorded for the uninstaller), skipping
  any application that is currently running
- defer that kdeglobals write while a KDE application has a window open,
  applying it once the window closes
- list, after a change, any open applications still showing the previous
  theme -- except ones Omarchy re-themes itself -- without touching them
- quit idle background services left running with no window and the previous
  theme, so their next launch is themed; anything with a window open is left
  alone, and each is asked to quit through its own action rather than signalled
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
closed; the extension itself is never installed or removed.

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

# Report what is missing; never install it. Omarchroma changes your own
# configuration, and asking for root to add system packages on top of that is a
# bigger ask than the job needs. The command is printed so it can be run
# deliberately, with pacman showing what it would do.
missing=()
for package in adw-gtk-theme python-plyvel; do
  pacman -Qq "$package" &>/dev/null || missing+=("$package")
done
if (( ${#missing[@]} )); then
  warn "Missing packages: ${missing[*]}"
  for package in "${missing[@]}"; do
    case "$package" in
      adw-gtk-theme)
        warn "  adw-gtk-theme  -- without it GTK 3 applications will not follow the theme" ;;
      python-plyvel)
        warn "  python-plyvel  -- without it Dark Reader cannot be themed in Chromium browsers" ;;
    esac
  done
  warn "Install them with:  sudo pacman -S --needed ${missing[*]}"
  warn "Omarchroma will install and run without them; those parts will not work."
fi

# Every destination this installer writes into is checked before anything is
# copied: a real directory, owned by this user, and unwritable by anyone else.
# "install" and "mkdir -p" both resolve their destination by pathname and will
# happily follow a symlink into a tree this account does not control, so the
# check is made once, here, rather than assumed at each of the copies below.
verify_destination() {
  local directory=$1 owner mode
  [[ -e $directory || -L $directory ]] || return 0
  [[ -L $directory ]] && {
    directory=$(readlink -f -- "$directory") || fail "cannot resolve $1"
  }
  [[ -d $directory ]] || fail "$1 exists but is not a directory"
  read -r owner mode < <(/usr/bin/stat -Lc '%u %a' "$directory") ||
    fail "cannot inspect $1"
  [[ $owner == "$(id -u)" ]] || fail "$1 is not owned by you"
  (( (8#$mode & 8#022) == 0 )) || fail "$1 is writable by other users"
}

for destination in "$TARGET_DIR" "$HOME/.local/bin" \
  "$HOME/.config/omarchy/hooks/theme-set.d" \
  "$HOME/.config/omarchy/hooks/font-set.d"; do
  verify_destination "$destination"
done

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
  action="upgraded"
else
  action="installed"
fi
if (( ${#missing[@]} )); then
  warn "Omarchroma $action, but incomplete: run 'sudo pacman -S --needed ${missing[*]}' to enable everything"
else
  info "Omarchroma $action"
fi
