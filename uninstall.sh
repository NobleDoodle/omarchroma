#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="omarchroma"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchroma"

if command -v omarchy >/dev/null; then
  omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
fi

rm -f \
  "$HOOK" \
  "$HOME/.local/bin/omarchroma-sync" \
  "$HOME/.local/bin/omarchroma-dark-reader"

if [[ -d "$PLUGIN_DIR" ]]; then
  rm -rf -- "$PLUGIN_DIR"
fi

command -v omarchy-shell >/dev/null && \
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Omarchroma removed. Generated application themes were left in place."
