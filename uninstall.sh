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

restore_policy() {
  local snapshot="$STATE_DIR/original/policy.json"
  [[ -f "$snapshot" ]] || return 0

  local script
  script=$(mktemp)
  python3 - "$snapshot" >"$script" <<'PY'
import json
import shlex
import sys
from pathlib import Path

snapshot = Path(sys.argv[1])
root = snapshot.parent
for entry in json.loads(snapshot.read_text()).get("entries", []):
    path = shlex.quote(entry["path"])
    if entry.get("existed"):
        backup = shlex.quote(str(root / entry["backup"]))
        print(f"install -m 644 {backup} {path}")
    else:
        print(f"rm -f {path}")
PY

  if [[ -s "$script" ]]; then
    if [[ -t 0 ]]; then
      sudo sh "$script"
    else
      pkexec sh "$script"
    fi
  fi
  rm -f "$script"
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
