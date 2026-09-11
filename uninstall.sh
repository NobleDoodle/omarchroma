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
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchroma"
FONT_HOOK="$HOME/.config/omarchy/hooks/font-set.d/omarchroma"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchroma"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchroma"
restore_exit=0
mode=""

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--stock | --captured]

  --stock     Return each framework to Omarchy's own defaults.
  --captured  Put back what was on disk when Omarchroma first ran.

With neither, you are asked. Non-interactively the default is --captured.
EOF
}

while (( $# )); do
  case "$1" in
    --stock) mode="stock" ;;
    --captured) mode="captured" ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# The snapshot records whether it captured Omarchroma's own output -- which
# happens when an earlier install's state directory was lost while its generated
# files were still on disk. Restoring that would reinstate the previous
# generation, so stock becomes the default when the flag is set.
capture_tainted() {
  python3 - "$STATE_DIR/original/manifest.json" <<'MANIFEST'
import json, sys
from pathlib import Path

try:
    manifest = json.loads(Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if manifest.get("captureTainted") else 1)
MANIFEST
}

tainted=0
capture_tainted && tainted=1

if [[ -z $mode ]]; then
  if [[ -t 0 ]]; then
    cat <<'EOF'
How should Omarchroma put your theming back?

  1) stock     Omarchy's own defaults. Deletes the files Omarchy never creates
               -- gtk.css, kdeglobals, the generated colour scheme -- and lets
               Omarchy re-author the settings it owns.

  2) captured  Exactly what was on disk when Omarchroma first ran.

EOF
    if (( tainted )); then
      cat <<'EOF'
Note: this snapshot was taken while Omarchroma output was already on disk, so
parts of it are a previous Omarchroma generation rather than your originals.
Stock is recommended here.

EOF
      read -r -p "Choose [1/2, default 1]: " choice
      case "$choice" in
        2 | captured) mode="captured" ;;
        *) mode="stock" ;;
      esac
    else
      read -r -p "Choose [1/2, default 2]: " choice
      case "$choice" in
        1 | stock) mode="stock" ;;
        *) mode="captured" ;;
      esac
    fi
  elif (( tainted )); then
    mode="stock"
    echo "Omarchroma: snapshot contains Omarchroma output; defaulting to stock."
  else
    mode="captured"
  fi
fi
printf 'Omarchroma: restoring to %s state.\n' "$mode"

run_state_helper() {
  if [[ -x "$PLUGIN_DIR/bin/omarchroma-state" ]]; then
    "$PLUGIN_DIR/bin/omarchroma-state" "$@"
  elif command -v omarchroma-state >/dev/null; then
    omarchroma-state "$@"
  else
    echo "Omarchroma: state helper is missing; cannot restore." >&2
    return 1
  fi
}

run_dark_reader_helper() {
  if [[ -x "$PLUGIN_DIR/bin/omarchroma-dark-reader" ]]; then
    "$PLUGIN_DIR/bin/omarchroma-dark-reader" "$@"
  elif command -v omarchroma-dark-reader >/dev/null; then
    omarchroma-dark-reader "$@"
  else
    echo "Omarchroma: Dark Reader helper is missing; cannot restore." >&2
    return 1
  fi
}

# Disarm before restoring anything. Both theme hooks and every watcher in
# omarchroma-state re-apply by exec'ing ~/.local/bin/omarchroma-sync, so with
# that one path gone nothing can rewrite a file between the restore below and
# the plugin being removed. The helpers themselves keep working: they are run
# from $PLUGIN_DIR, which is only removed once the restore has succeeded.
disarm() {
  rm -f \
    "$HOOK" \
    "$FONT_HOOK" \
    "$HOME/.local/bin/omarchroma-sync" \
    "$HOME/.local/bin/omarchroma-dark-reader" \
    "$HOME/.local/bin/omarchroma-state"
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

disarm

run_dark_reader_helper --restore --mode="$mode" \
  --state-dir "$STATE_DIR" --status "$STATE_DIR/status.json" || restore_exit=$?

if (( restore_exit == 2 )); then
  echo "Close the browser and run the uninstaller again to finish restoring Dark Reader."
  exit 2
fi
if (( restore_exit != 0 )); then
  echo "Restore failed; Omarchroma was not removed." >&2
  exit "$restore_exit"
fi

run_state_helper --state-dir "$STATE_DIR" --data-dir "$DATA_DIR" \
  restore --mode "$mode" || restore_exit=$?
# Not run from here either. Uninstalling should not be the moment a script
# decides to authenticate on the user's behalf; it is said plainly instead.
if [[ -e /var/lib/omarchroma/policy-backup/manifest.json ]]; then
  echo "Omarchroma: a browser policy from a version before 1.6.0 is still installed."
  echo "Omarchroma: remove it with $PLUGIN_DIR/bin/omarchroma-policy-cleanup before"
  echo "Omarchroma: this directory is deleted, or with the copy in your clone afterwards."
fi

if (( restore_exit != 0 )); then
  echo "Restore failed; Omarchroma was not removed." >&2
  exit "$restore_exit"
fi

if command -v omarchy >/dev/null; then
  omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
fi

if [[ -d "$PLUGIN_DIR" ]]; then
  rm -rf -- "$PLUGIN_DIR"
fi

command -v omarchy-shell >/dev/null && \
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

rm -rf -- "$STATE_DIR" "$DATA_DIR"
printf 'Omarchroma removed; frameworks restored to their %s state.\n' "$mode"
