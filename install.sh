#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="io.github.nobledoodle.omarchroma"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENABLE=0
INSTALL_PACKAGES=1
INSTALL_POLICY=1
REINSTALL=0
UPGRADE=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"

# The Dark Reader machine policy. Declared here rather than inside
# install_browser_policy so an upgrade can compare it with what is already on
# disk -- a world-readable file -- instead of authenticating just to find out
# nothing changed.
# The Firefox policy entry install_browser_policy writes. Only ever compared
# against here, never used to write -- the privileged helper holds its own
# literal, and these must stay in sync with it the way POLICY_DESTINATIONS does.
FIREFOX_POLICY_EXTENSION="addon@darkreader.org"
FIREFOX_POLICY_INSTALL_MODE="force_installed"
FIREFOX_POLICY_INSTALL_URL="https://addons.mozilla.org/firefox/downloads/latest/darkreader/latest.xpi"

CHROMIUM_POLICY_JSON='{
  "ExtensionSettings": {
    "eimadpbcbfnmbkopoojfekhnkhdbieeh": {
      "installation_mode": "force_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    }
  }
}
'

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--enable] [--no-packages] [--no-policy] [--reinstall]

Installs Omarchroma, its theme-change hook, GTK and Qt/KDE support, Dark Reader
policy, and the command used by its service and bar widget.

Re-run it to upgrade an existing install. An upgrade refreshes the plugin,
commands and hooks, and does not ask for consent again or re-authenticate a
browser policy that is already in place. Your captured original state is left
untouched, so nothing is re-captured.

  --enable       Enable Omarchroma and place its icon before the power widget
  --no-packages  Do not install adw-gtk-theme or python-plyvel
  --no-policy    Do not install the Dark Reader browser policy
  --reinstall    Treat an existing install as a first install (asks again)
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

# Whether the policy this installer would write is already the policy on disk.
# Both trust roots are world-readable, so an upgrade can answer this without
# authenticating; only a real change is worth a password prompt.
policy_already_current() {
  local family="$1" target="$2" expected actual
  if [[ $family == "chromium" ]]; then
    local file="$target/99-omarchroma-dark-reader.json"
    [[ -f $file ]] || return 1
    expected=$(printf '%s' "$CHROMIUM_POLICY_JSON" | sha256sum | awk '{print $1}')
    actual=$(sha256sum <"$file" | awk '{print $1}')
    [[ $actual == "$expected" ]]
  else
    # Not just "the file mentions Dark Reader": another tool's entry, with its
    # own install_url, would otherwise read as Omarchroma's policy already being
    # in place and an upgrade would stop re-asserting its own.
    [[ -f $target ]] || return 1
    jq -e \
      --arg id "$FIREFOX_POLICY_EXTENSION" \
      --arg mode "$FIREFOX_POLICY_INSTALL_MODE" \
      --arg url "$FIREFOX_POLICY_INSTALL_URL" \
      '.policies.ExtensionSettings[$id]
       | (.installation_mode == $mode) and (.install_url == $url)' \
      "$target" >/dev/null 2>&1
  fi
}

install_browser_policy() {
  local desktop="$1"
  local family="$2"
  local payload_b64 payload_digest
  payload_b64=$(printf '%s' "$CHROMIUM_POLICY_JSON" | base64 -w 0)
  payload_digest=$(printf '%s' "$CHROMIUM_POLICY_JSON" | sha256sum | awk '{print $1}')

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
    _atomic_write_into(path, data)


def _atomic_write_into(path: Path, data: bytes, mode: int = 0o644) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, 0, 0)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


STAGING_ROOT = Path("/var/lib/omarchroma/policy-backup")


def managed_target(family: str, policy_dir: str) -> Path:
    if family == "chromium":
        return Path(policy_dir) / "99-omarchroma-dark-reader.json"
    return Path(policy_dir)


def allowlisted_target(desktop: str, family: str) -> Path:
    """Rederive a destination from the fixed allowlist. A manifest never
    supplies a path; it only supplies an allowlist key to look one up with."""
    allowed = POLICY_DESTINATIONS.get(desktop)
    if allowed is None:
        die(f"policy backup names an unsupported browser: {desktop!r}")
    expected_family, policy_dir = allowed
    if family != expected_family:
        die(f"policy backup family does not match the allowlist for {desktop}")
    return managed_target(expected_family, policy_dir)


def backup_name(family: str, target: Path) -> str:
    digest = hashlib.sha256(str(target).encode()).hexdigest()[:16]
    return f"{family}-{digest}"


def normalized_entries(manifest: dict) -> dict:
    """Return {destination: entry} for manifest version 1 or 2. Destinations are
    rederived from the allowlist, and a key that disagrees with the entry it
    holds is refused."""
    version = manifest.get("version")
    if version == 1:
        # v1 recorded exactly one destination, at the top level.
        desktop = manifest.get("desktop")
        family = manifest.get("family")
        target = allowlisted_target(desktop, family)
        raw = manifest.get("entries")
        if not isinstance(raw, list) or len(raw) != 1 or not isinstance(raw[0], dict):
            die("policy backup manifest is corrupt")
        entry = {name: value for name, value in raw[0].items() if name != "key"}
        entry["desktop"] = desktop
        entry["family"] = family
        return {str(target): entry}
    if version != 2:
        die(f"unsupported policy backup manifest version: {version!r}")
    raw = manifest.get("entries")
    if not isinstance(raw, dict):
        die("policy backup manifest is corrupt")
    entries = {}
    for key, entry in raw.items():
        if not isinstance(entry, dict):
            die("policy backup manifest is corrupt")
        target = allowlisted_target(entry.get("desktop"), entry.get("family"))
        if str(target) != key:
            die(f"policy backup entry does not match its destination: {key}")
        entries[key] = entry
    return entries


def ensure_root_staging() -> Path:
    current = Path("/")
    for part in STAGING_ROOT.parts[1:]:
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            os.mkdir(current, 0o755)
            os.chmod(current, 0o755)
            os.chown(current, 0, 0)
            metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            die(f"refusing symlinked staging component: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            die(f"refusing non-directory staging component: {current}")
        if metadata.st_uid != 0:
            die(f"refusing non-root-owned staging component: {current}")
    return STAGING_ROOT


def read_regular_file(path: Path) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def load_manifest(manifest_path: Path):
    try:
        metadata = os.lstat(manifest_path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
        die("refusing untrusted policy backup manifest")
    try:
        manifest = json.loads(read_regular_file(manifest_path).decode())
    except (ValueError, UnicodeDecodeError):
        die("policy backup manifest is corrupt")
    if not isinstance(manifest, dict):
        die("policy backup manifest is corrupt")
    return manifest


def snapshot_destination_once(desktop: str, family: str, policy_dir: str) -> None:
    """Capture this destination's pristine state once. Create-once is scoped per
    destination, so changing the default browser between installs still records
    the new policy file for the uninstaller to clean up."""
    staging = ensure_root_staging()
    manifest_path = staging / "manifest.json"
    manifest = load_manifest(manifest_path)
    entries = normalized_entries(manifest) if manifest is not None else {}

    target = managed_target(family, policy_dir)
    key = str(target)
    if key in entries:
        return  # already captured; keep the pristine copy

    ensure_secure_directory(target.parent)
    entry = {"desktop": desktop, "family": family}
    try:
        file_metadata = os.lstat(target)
    except FileNotFoundError:
        entry["existed"] = False
    else:
        if stat.S_ISLNK(file_metadata.st_mode):
            die(f"refusing to back up symlinked policy file: {target}")
        if not stat.S_ISREG(file_metadata.st_mode):
            die(f"refusing to back up non-file policy target: {target}")
        data = read_regular_file(target)
        name = backup_name(family, target)
        # Record the original permissions and ownership so the uninstaller can
        # put the file back as it was instead of normalizing it. setuid, setgid
        # and sticky are dropped: a policy file has no use for them, and they
        # are not worth carrying through a privileged restore.
        mode = stat.S_IMODE(file_metadata.st_mode) & 0o777
        # The staging copy keeps the original permissions too, so a restrictive
        # original is not widened while it sits in the backup directory.
        _atomic_write_into(staging / name, data, mode)
        entry["existed"] = True
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        entry["backup"] = name
        entry["mode"] = mode
        entry["uid"] = file_metadata.st_uid
        entry["gid"] = file_metadata.st_gid

    entries[key] = entry
    _atomic_write_into(
        manifest_path,
        (json.dumps({"version": 2, "entries": entries}, indent=2) + "\n").encode(),
    )


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

# Capture the pristine policy state in root-owned staging before overwriting it,
# so the uninstaller can restore it without trusting any user-writable file.
snapshot_destination_once(desktop, family, target)

if family == "chromium":
    atomic_write(
        Path(target) / "99-omarchroma-dark-reader.json",
        payload,
    )
else:
    path = Path(target)
    ensure_secure_directory(path.parent)
    ensure_safe_file_target(path)
    # Read through a held O_NOFOLLOW descriptor like every other read in this
    # privileged script. ensure_safe_file_target above only lstat's the path, so
    # reopening it by name here would leave a window in which it became a
    # symlink -- narrow, since /usr/lib is root-owned, but this runs as root and
    # the rest of this script does not rely on that.
    policy = {}
    try:
        raw = read_regular_file(path)
    except FileNotFoundError:
        raw = b""
    except OSError as error:
        die(f"refusing to read policy file {path}: {error}")
    if raw:
        try:
            policy = json.loads(raw.decode())
        except (ValueError, UnicodeDecodeError):
            policy = {}
    if not isinstance(policy, dict):
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
- install the native Omarchy theme and font hooks:
  $HOME/.config/omarchy/hooks/theme-set.d/omarchroma
  $HOME/.config/omarchy/hooks/font-set.d/omarchroma
- snapshot original application and browser state under:
  ${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma/original/
- configure Dark Reader for the current default browser unless --no-policy is used
  or Dark Reader was already installed before Omarchroma first changed it
- for Chromium-family browsers, write managed policy under the browser's
  system policy directory, such as /etc/chromium/policies/managed
- for Firefox-family browsers, merge Dark Reader installation policy into the
  browser's system policies.json
- keep a root-owned backup of each browser policy file it replaces under:
  /var/lib/omarchroma/policy-backup/
  one record per policy destination, so a later change of default browser is
  still tracked and still removed at uninstall
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
each integration. Browser Dark Reader sync and restore require the target
browser to be closed. Restoring the system browser policy is performed by a
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
    --no-policy) INSTALL_POLICY=0 ;;
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

if (( INSTALL_POLICY )); then
  browser_desktop=$(default_browser_desktop)
  if policy_info=$(policy_info_for_desktop "$browser_desktop"); then
    # policy_target is only read here, to see whether an upgrade can skip
    # authenticating. Where the policy is actually written is rederived from the
    # allowlist inside the privileged helper, never taken from this value.
    IFS=$'\t' read -r browser_name browser_family policy_target <<<"$policy_info"
    browser_info=$("$TARGET_DIR/bin/omarchroma-dark-reader" --info || printf '{}')
    dark_reader_installed=$(jq -r '.darkReaderInstalled // false' \
      <<<"$browser_info" 2>/dev/null || printf false)
    # The pristine policy is captured in root-owned staging by the privileged
    # helper (install_browser_policy -> snapshot_destination_once). Its manifest
    # the record of "Omarchroma has managed this browser policy before".
    policy_backup_manifest="/var/lib/omarchroma/policy-backup/manifest.json"
    if (( UPGRADE )) && policy_already_current "$browser_family" "$policy_target"; then
      info "Browser policy for $browser_name is already current; no authentication needed"
    elif [[ $dark_reader_installed == "true" && ! -e "$policy_backup_manifest" ]]; then
      info "Dark Reader is already installed for $browser_name; leaving extension installation unmanaged"
    else
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

if (( UPGRADE )); then
  info "Omarchroma upgraded"
else
  info "Omarchroma installed"
fi
