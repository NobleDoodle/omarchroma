#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SETTINGS_FILE=$(mktemp)
target_key() { case "$1" in gtk) printf gtk;; qt-kde) printf qtKde;; dark-reader) printf darkReader;; pear) printf pear;; *) return 1;; esac; }
eval "$(sed -n '/^target_enabled()/,/^}$/p' $REPO/bin/hyprchroma)"
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got $2 want $3"; }
r(){ target_enabled "$1" && echo enabled || echo disabled; }

printf '{"frameworks":{"gtk":false,"qtKde":false,"darkReader":true,"pear":true}}' > "$SETTINGS_FILE"
chk "gtk false -> disabled"        "$(r gtk)"         "disabled"
chk "qt-kde false -> disabled"     "$(r qt-kde)"      "disabled"
chk "dark-reader true -> enabled"  "$(r dark-reader)" "enabled"
printf '{"frameworks":{}}' > "$SETTINGS_FILE"
chk "missing key -> enabled"       "$(r gtk)"         "enabled"
printf '{}' > "$SETTINGS_FILE"
chk "no frameworks -> enabled"     "$(r gtk)"         "enabled"
printf 'not json' > "$SETTINGS_FILE"
chk "corrupt file -> enabled"      "$(r gtk)"         "enabled"
rm -f "$SETTINGS_FILE"
chk "absent file -> enabled"       "$(r gtk)"         "enabled"
