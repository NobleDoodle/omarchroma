#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="io.github.nobledoodle.omarchroma"
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

command_output() {
  local output
  output=$("$@" 2>/dev/null) || return 0
  printf '%s' "$output"
}

default_browser_desktop() {
  local desktop
  desktop=$(command_output xdg-settings get default-web-browser)
  if [[ -n "$desktop" ]]; then
    printf '%s\n' "$desktop"
    return
  fi
  command_output xdg-mime query default x-scheme-handler/https
  printf '\n'
}

policy_info_for_desktop() {
  local desktop="$1"
  case "$desktop" in
    helium.desktop)
      printf '%s\t%s\t%s\n' "Helium" "chromium" "/etc/chromium/policies/managed" ;;
    chromium.desktop)
      printf '%s\t%s\t%s\n' "Chromium" "chromium" "/etc/chromium/policies/managed" ;;
    google-chrome.desktop|google-chrome-stable.desktop)
      printf '%s\t%s\t%s\n' "Google Chrome" "chromium" "/etc/opt/chrome/policies/managed" ;;
    brave-browser.desktop)
      printf '%s\t%s\t%s\n' "Brave" "chromium" "/etc/brave/policies/managed" ;;
    vivaldi-stable.desktop)
      printf '%s\t%s\t%s\n' "Vivaldi" "chromium" "/etc/chromium/policies/managed" ;;
    microsoft-edge.desktop)
      printf '%s\t%s\t%s\n' "Microsoft Edge" "chromium" "/etc/opt/edge/policies/managed" ;;
    firefox.desktop)
      printf '%s\t%s\t%s\n' "Firefox" "firefox" "/usr/lib/firefox/distribution/policies.json" ;;
    firefox-developer-edition.desktop)
      printf '%s\t%s\t%s\n' "Firefox Developer Edition" "firefox" "/usr/lib/firefox-developer-edition/distribution/policies.json" ;;
    librewolf.desktop)
      printf '%s\t%s\t%s\n' "LibreWolf" "firefox" "/usr/lib/librewolf/distribution/policies.json" ;;
    waterfox.desktop)
      printf '%s\t%s\t%s\n' "Waterfox" "firefox" "/usr/lib/waterfox/distribution/policies.json" ;;
    floorp.desktop)
      printf '%s\t%s\t%s\n' "Floorp" "firefox" "/usr/lib/floorp/distribution/policies.json" ;;
    zen-browser.desktop|zen.desktop)
      printf '%s\t%s\t%s\n' "Zen Browser" "firefox" "/usr/lib/zen-browser/distribution/policies.json" ;;
    *)
      return 1 ;;
  esac
}

install_browser_policy() {
  local desktop="$1"
  local family="$2"
  local chromium_policy_json='{
  "ExtensionSettings": {
    "eimadpbcbfnmbkopoojfekhnkhdbieeh": {
      "installation_mode": "force_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    }
  }
}
'
  local payload_b64 payload_digest
  payload_b64=$(printf '%s' "$chromium_policy_json" | base64 -w 0)
  payload_digest=$(printf '%s' "$chromium_policy_json" | sha256sum | awk '{print $1}')

  local -a policy_command
  if [[ -t 0 ]]; then
    policy_command=(sudo python3 - "$desktop" "$family" "$payload_digest" "$payload_b64")
  else
    policy_command=(pkexec python3 - "$desktop" "$family" "$payload_digest" "$payload_b64")
  fi

  "${policy_command[@]}" <<'PY'
import base64
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

POLICY_DESTINATIONS = {
    "helium.desktop": ("chromium", "/etc/chromium/policies/managed"),
    "chromium.desktop": ("chromium", "/etc/chromium/policies/managed"),
    "google-chrome.desktop": ("chromium", "/etc/opt/chrome/policies/managed"),
    "google-chrome-stable.desktop": ("chromium", "/etc/opt/chrome/policies/managed"),
    "brave-browser.desktop": ("chromium", "/etc/brave/policies/managed"),
    "vivaldi-stable.desktop": ("chromium", "/etc/chromium/policies/managed"),
    "microsoft-edge.desktop": ("chromium", "/etc/opt/edge/policies/managed"),
    "firefox.desktop": ("firefox", "/usr/lib/firefox/distribution/policies.json"),
    "firefox-developer-edition.desktop": (
        "firefox",
        "/usr/lib/firefox-developer-edition/distribution/policies.json",
    ),
    "librewolf.desktop": ("firefox", "/usr/lib/librewolf/distribution/policies.json"),
    "waterfox.desktop": ("firefox", "/usr/lib/waterfox/distribution/policies.json"),
    "floorp.desktop": ("firefox", "/usr/lib/floorp/distribution/policies.json"),
    "zen-browser.desktop": ("firefox", "/usr/lib/zen-browser/distribution/policies.json"),
    "zen.desktop": ("firefox", "/usr/lib/zen-browser/distribution/policies.json"),
}


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def ensure_secure_directory(path: Path) -> None:
    if not path.is_absolute():
        die(f"policy path is not absolute: {path}")
    current = Path("/")
    for part in path.parts[1:]:
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            current.mkdir(mode=0o755)
            metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            die(f"refusing symlinked policy path component: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            die(f"refusing non-directory policy path component: {current}")


def ensure_safe_file_target(path: Path) -> None:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(metadata.st_mode):
        die(f"refusing symlinked policy file: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        die(f"refusing non-file policy target: {path}")


def atomic_write(path: Path, data: bytes) -> None:
    ensure_secure_directory(path.parent)
    ensure_safe_file_target(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


desktop, requested_family, expected_digest, payload_b64 = sys.argv[1:5]
allowed = POLICY_DESTINATIONS.get(desktop)
if allowed is None:
    die(f"unsupported browser policy destination: {desktop}")
family, target = allowed
if requested_family != family:
    die(f"browser policy family mismatch for {desktop}")

payload = base64.b64decode(payload_b64.encode(), validate=True)
if hashlib.sha256(payload).hexdigest() != expected_digest:
    die("browser policy payload digest mismatch")

if family == "chromium":
    atomic_write(
        Path(target) / "99-omarchroma-dark-reader.json",
        payload,
    )
else:
    path = Path(target)
    ensure_secure_directory(path.parent)
    ensure_safe_file_target(path)
    policy = {}
    if path.exists():
        try:
            policy = json.loads(path.read_text())
        except json.JSONDecodeError:
            policy = {}
    policies = policy.setdefault("policies", {})
    settings = policies.setdefault("ExtensionSettings", {})
    settings["addon@darkreader.org"] = {
        "installation_mode": "force_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/darkreader/latest.xpi",
    }
    atomic_write(path, (json.dumps(policy, indent=2) + "\n").encode())
PY
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
- install the native Omarchy theme hook:
  $HOME/.config/omarchy/hooks/theme-set.d/omarchroma
- remove stale Omarchroma hook shims if present:
  $HOME/.config/omarchy/hooks/theme-set.d/sync-gtk-theme
  $HOME/.local/bin/apply-dark-reader-theme
- snapshot original application and browser state under:
  ${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma/original/
- configure Dark Reader for the current default browser unless --no-policy is used
  or Dark Reader was already installed before Omarchroma first changed it
- for Chromium-family browsers, write managed policy under the browser's
  system policy directory, such as /etc/chromium/policies/managed
- for Firefox-family browsers, merge Dark Reader installation policy into the
  browser's system policies.json
- run an initial sync that may update:
  $HOME/.config/gtk-3.0/
  $HOME/.config/gtk-4.0/
  $HOME/.config/kdeglobals
  $HOME/.local/share/color-schemes/Omarchroma.colors
  $HOME/.config/YouTube Music/omarchroma.css
  the active browser profile's Dark Reader settings
- enable the Omarchy bar widget if --enable is used

The uninstaller restores the state captured before Omarchroma first changed
each integration. Browser Dark Reader sync and restore require the target
browser to be closed.

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
    --no-policy) INSTALL_POLICY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $argument" ;;
  esac
done

command -v omarchy >/dev/null || die "omarchy is not available"
require_install_acknowledgement

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
  install -m 755 "$SOURCE_DIR/bin/omarchroma-state" \
    "$TARGET_DIR/bin/omarchroma-state"
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
install -Dm755 "$TARGET_DIR/bin/omarchroma-state" \
  "$HOME/.local/bin/omarchroma-state"
omarchy hook install theme-set "$TARGET_DIR/hooks/omarchroma"
rm -f \
  "$HOME/.config/omarchy/hooks/theme-set.d/sync-gtk-theme" \
  "$HOME/.local/bin/apply-dark-reader-theme"

if (( INSTALL_POLICY )); then
  browser_desktop=$(default_browser_desktop)
  if policy_info=$(policy_info_for_desktop "$browser_desktop"); then
    IFS=$'\t' read -r browser_name browser_family policy_target <<<"$policy_info"
    browser_info=$("$TARGET_DIR/bin/omarchroma-dark-reader" --info || printf '{}')
    dark_reader_installed=$(jq -r '.darkReaderInstalled // false' \
      <<<"$browser_info" 2>/dev/null || printf false)
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"
    policy_snapshot="$state_dir/original/policy.json"
    if [[ $dark_reader_installed == "true" && ! -f "$policy_snapshot" ]]; then
      info "Dark Reader is already installed for $browser_name; leaving extension installation unmanaged"
    else
      if [[ ! -f "$policy_snapshot" ]]; then
        mkdir -p "$state_dir/original/policy"
        python3 - "$policy_snapshot" "$browser_family" "$policy_target" <<'PY'
import json
import shutil
import sys
from pathlib import Path

snapshot = Path(sys.argv[1])
family = sys.argv[2]
target = Path(sys.argv[3])
backup_dir = snapshot.parent / "policy"
entries = []
if family == "chromium":
    paths = [
        target / "99-omarchroma-dark-reader.json",
    ]
else:
    paths = [target]
for path in paths:
    entry = {"path": str(path), "existed": path.exists()}
    if path.exists():
        backup = backup_dir / path.name
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        entry["backup"] = str(backup.relative_to(snapshot.parent))
    entries.append(entry)
temporary = snapshot.with_suffix(".tmp")
temporary.write_text(json.dumps({"entries": entries}, indent=2) + "\n")
temporary.replace(snapshot)
PY
      fi
      info "Installing Dark Reader for the default browser: $browser_name"
      install_browser_policy "$browser_desktop" "$browser_family"
    fi
  else
    warn "The default browser is not supported; Dark Reader was skipped"
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
