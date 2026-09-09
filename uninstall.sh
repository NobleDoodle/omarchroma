#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="io.github.nobledoodle.omarchroma"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchroma"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchroma"
restore_exit=0

run_state_helper() {
  if [[ -x "$PLUGIN_DIR/bin/omarchroma-state" ]]; then
    "$PLUGIN_DIR/bin/omarchroma-state" "$@"
  elif command -v omarchroma-state >/dev/null; then
    omarchroma-state "$@"
  fi
}

run_dark_reader_helper() {
  if [[ -x "$PLUGIN_DIR/bin/omarchroma-dark-reader" ]]; then
    "$PLUGIN_DIR/bin/omarchroma-dark-reader" "$@"
  elif command -v omarchroma-dark-reader >/dev/null; then
    omarchroma-dark-reader "$@"
  fi
}

# Restore the system browser policy from the root-owned backup that install.sh
# captured. The restore logic runs entirely inside a privileged Python helper
# fed on stdin: destinations are rederived from a fixed browser allowlist, the
# backup is read from root-owned staging with its digest verified, symlink and
# non-directory path components are rejected, and no user-writable file or
# script is executed or reopened after authorization.
# Fixed policy destinations, mirroring the allowlist the privileged helpers
# enforce. Only ever read here, to tell the user what an absent backup record
# left behind.
CHROMIUM_POLICY_DIRS=(
  /etc/chromium/policies/managed
  /etc/opt/chrome/policies/managed
  /etc/brave/policies/managed
  /etc/opt/edge/policies/managed
)
FIREFOX_POLICY_FILES=(
  /usr/lib/firefox/distribution/policies.json
  /usr/lib/firefox-developer-edition/distribution/policies.json
  /usr/lib/librewolf/distribution/policies.json
  /usr/lib/waterfox/distribution/policies.json
  /usr/lib/floorp/distribution/policies.json
  /usr/lib/zen-browser/distribution/policies.json
)

# Without the root-owned backup record the uninstaller cannot know what the
# original policy looked like, and it will not guess. Say plainly what was left
# in place instead of exiting quietly as though nothing had been installed.
report_unrestorable_policy() {
  local path
  local -a leftovers=()
  for path in "${CHROMIUM_POLICY_DIRS[@]}"; do
    if [[ -f "$path/99-omarchroma-dark-reader.json" ]]; then
      leftovers+=("$path/99-omarchroma-dark-reader.json")
    fi
  done
  for path in "${FIREFOX_POLICY_FILES[@]}"; do
    if [[ -f "$path" ]] && grep -q 'addon@darkreader\.org' "$path" 2>/dev/null; then
      leftovers+=("$path (still carries a Dark Reader policy entry)")
    fi
  done
  (( ${#leftovers[@]} )) || return 0
  echo "Omarchroma: no policy backup record was found, so system browser policy was left in place:" >&2
  printf '  %s\n' "${leftovers[@]}" >&2
  echo "Review these with sudo if Dark Reader should no longer be installed by policy." >&2
}

restore_policy() {
  if [[ ! -e /var/lib/omarchroma/policy-backup/manifest.json ]]; then
    report_unrestorable_policy
    return 0
  fi

  local -a runner
  if [[ -t 0 ]]; then
    runner=(sudo python3 -)
  else
    runner=(pkexec python3 -)
  fi

  "${runner[@]}" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

STAGING_ROOT = Path("/var/lib/omarchroma/policy-backup")

# Fixed allowlist; must stay in sync with install.sh's POLICY_DESTINATIONS.
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


def die(message):
    print(f"Omarchroma: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_root_dir_chain(path):
    current = Path("/")
    for part in path.parts[1:]:
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            die(f"policy backup staging is missing: {current}")
        if stat.S_ISLNK(metadata.st_mode):
            die(f"refusing symlinked staging component: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            die(f"refusing non-directory staging component: {current}")
        if metadata.st_uid != 0:
            die(f"refusing non-root-owned staging component: {current}")


def secure_directory_state(path):
    """"ok" when every component is a real directory, "missing" when a
    component does not exist. Symlinked or non-directory components abort."""
    current = Path("/")
    for part in path.parts[1:]:
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return "missing"
        if stat.S_ISLNK(metadata.st_mode):
            die(f"refusing symlinked policy path component: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            die(f"refusing non-directory policy path component: {current}")
    return "ok"


def existing_regular_file(path):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(metadata.st_mode):
        die(f"refusing symlinked policy file: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        die(f"refusing non-file policy target: {path}")
    return metadata


def read_root_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            die(f"refusing non-regular backup file: {path}")
        if metadata.st_uid != 0:
            die(f"refusing non-root-owned backup file: {path}")
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def restored_attributes(entry):
    """Permissions and ownership recorded when the policy was first replaced.
    Manifests written before those were recorded fall back to the defaults a
    policy file normally carries. setuid, setgid and sticky are never restored
    onto a policy file."""
    mode = entry.get("mode")
    if isinstance(mode, bool) or not isinstance(mode, int) or not 0 <= mode <= 0o777:
        mode = 0o644
    uid = entry.get("uid")
    if isinstance(uid, bool) or not isinstance(uid, int) or uid < 0:
        uid = 0
    gid = entry.get("gid")
    if isinstance(gid, bool) or not isinstance(gid, int) or gid < 0:
        gid = 0
    return mode, uid, gid


def atomic_write(path, data, mode=0o644, uid=0, gid=0):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def managed_target(family, policy_dir):
    if family == "chromium":
        return Path(policy_dir) / "99-omarchroma-dark-reader.json"
    return Path(policy_dir)


BACKUP_NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def allowlisted_target(desktop, family):
    """Rederive a destination from the fixed allowlist. A manifest never
    supplies a path; it only supplies an allowlist key to look one up with."""
    allowed = POLICY_DESTINATIONS.get(desktop)
    if allowed is None:
        die(f"policy backup names an unsupported browser: {desktop!r}")
    expected_family, policy_dir = allowed
    if family != expected_family:
        die(f"policy backup family does not match the allowlist for {desktop}")
    return managed_target(expected_family, policy_dir)


def safe_backup_name(name):
    if (not isinstance(name, str) or name in {".", ".."}
            or BACKUP_NAME_PATTERN.match(name) is None):
        die("policy backup entry names an unsafe backup file")
    return name


def normalized_entries(manifest):
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


require_root_dir_chain(STAGING_ROOT)

manifest_path = STAGING_ROOT / "manifest.json"
if existing_regular_file(manifest_path) is None:
    print("Omarchroma: no policy backup to restore")
    raise SystemExit(0)

try:
    manifest = json.loads(read_root_file(manifest_path).decode())
except (ValueError, UnicodeDecodeError):
    die("policy backup manifest is corrupt")
if not isinstance(manifest, dict):
    die("policy backup manifest is corrupt")

entries = normalized_entries(manifest)
if not entries:
    die("policy backup manifest has no entries")

actions = []
for key in sorted(entries):
    entry = entries[key]
    # Destination is rederived from the allowlist, never taken from the manifest.
    target = allowlisted_target(entry.get("desktop"), entry.get("family"))

    if secure_directory_state(target.parent) == "missing":
        # The admin/package-owned policy directory is gone; nothing of ours can
        # remain there, and recreating system paths is not the uninstaller's job.
        continue

    if entry.get("existed"):
        digest = entry.get("sha256")
        if not isinstance(digest, str) or not digest:
            die(f"policy backup entry is missing its digest: {target}")
        data = read_root_file(STAGING_ROOT / safe_backup_name(entry.get("backup")))
        if hashlib.sha256(data).hexdigest() != digest:
            die(f"policy backup digest mismatch: {target}")
        existing_regular_file(target)  # reject a symlink/non-file left in place
        mode, uid, gid = restored_attributes(entry)
        atomic_write(target, data, mode, uid, gid)
        actions.append(f"restored {target}")
    else:
        if existing_regular_file(target) is not None:
            os.unlink(target)
            actions.append(f"removed {target}")

# Success: drop the now-consumed root-owned staging tree.
for child in sorted(STAGING_ROOT.iterdir()):
    if not stat.S_ISREG(os.lstat(child).st_mode):
        die(f"unexpected entry in policy backup staging: {child}")
    os.unlink(child)
STAGING_ROOT.rmdir()
try:
    STAGING_ROOT.parent.rmdir()  # /var/lib/omarchroma when empty
except OSError:
    pass

for line in actions:
    print(f"Omarchroma: {line}")
print("Omarchroma: browser policy restored")
PY
}

run_dark_reader_helper --restore --state-dir "$STATE_DIR" --status "$STATE_DIR/status.json" || restore_exit=$?

if (( restore_exit == 2 )); then
  echo "Close the browser and run the uninstaller again to finish restoring Dark Reader."
  exit 2
fi
if (( restore_exit != 0 )); then
  echo "Restore failed; Omarchroma was not removed." >&2
  exit "$restore_exit"
fi

run_state_helper --state-dir "$STATE_DIR" --data-dir "$DATA_DIR" restore || restore_exit=$?
restore_policy || restore_exit=$?

if (( restore_exit != 0 )); then
  echo "Restore failed; Omarchroma was not removed." >&2
  exit "$restore_exit"
fi

if command -v omarchy >/dev/null; then
  omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
fi

rm -f \
  "$HOOK" \
  "$HOME/.local/bin/omarchroma-sync" \
  "$HOME/.local/bin/omarchroma-dark-reader" \
  "$HOME/.local/bin/omarchroma-state"

if [[ -d "$PLUGIN_DIR" ]]; then
  rm -rf -- "$PLUGIN_DIR"
fi

command -v omarchy-shell >/dev/null && \
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

rm -rf -- "$STATE_DIR" "$DATA_DIR"
echo "Omarchroma removed and original application theme state restored."
