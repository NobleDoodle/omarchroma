#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SETTINGS_FILE=$(mktemp)
target_key() { case "$1" in gtk) printf gtk;; qt-kde) printf qtKde;; dark-reader) printf darkReader;; pear) printf pear;; *) return 1;; esac; }
eval "$(sed -n '/^target_enabled()/,/^}$/p' $REPO/bin/hyprchroma)"
msg() {
  printf '%s' "$1" > "$SETTINGS_FILE"; pear_installed=$2; qt_kde_deferred=$3
  local synced=() message
  target_enabled gtk && synced+=("GTK")
  if target_enabled qt-kde; then (( qt_kde_deferred )) || synced+=("Qt/KDE"); fi
  target_enabled dark-reader && synced+=("Dark Reader")
  target_enabled pear && (( pear_installed )) && synced+=("Pear Desktop")
  if (( ${#synced[@]} == 0 )); then message="nothing to synchronize; every framework is switched off"
  else message=$(printf '%s, ' "${synced[@]}"); message="${message%, } synchronized"; fi
  if target_enabled qt-kde && (( qt_kde_deferred )); then message+="; Qt/KDE deferred while KDE apps are open"; fi
  echo "  $message"
}
echo "all enabled, pear present:";        msg '{"frameworks":{}}' 1 0
echo "gtk+qtKde off:";                     msg '{"frameworks":{"gtk":false,"qtKde":false}}' 1 0
echo "everything off:";                    msg '{"frameworks":{"gtk":false,"qtKde":false,"darkReader":false,"pear":false}}' 1 0
echo "all on, pear not installed:";        msg '{"frameworks":{}}' 0 0
echo "all on, qt-kde deferred:";           msg '{"frameworks":{}}' 1 1
echo "qtKde off AND deferred flag set:";   msg '{"frameworks":{"qtKde":false}}' 1 1
rm -f "$SETTINGS_FILE"
