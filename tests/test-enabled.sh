#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SETTINGS_FILE=$(mktemp)
target_key() { case "$1" in gtk) printf gtk;; qt-kde) printf qtKde;; dark-reader) printf darkReader;; pear) printf pear;; *) return 1;; esac; }
eval "$(sed -n '/^target_enabled()/,/^}$/p' $REPO/bin/hyprchroma)"
eval "$(sed -n '/^declare -A FRAMEWORK_SWITCH/,/^FRAMEWORKS_READ=0$/p;/^read_framework_switches()/,/^}$/p' $REPO/bin/hyprchroma)"
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

# --- read once per sync -------------------------------
# The same answers from one read as from a jq per check, and nothing new can
# turn an opt-in framework on.
target_key() { case "$1" in gtk) printf gtk;; qt-kde) printf qtKde;; dark-reader) printf darkReader;; pear) printf pear;;
                 flatpak) printf flatpak;; icons) printf icons;; browsers) printf browsers;; *) return 1;; esac; }
both(){ local a b; FRAMEWORKS_READ=0; a=$(r "$1"); read_framework_switches; b=$(r "$1"); FRAMEWORKS_READ=0; echo "$a/$b"; }
printf '{"frameworks":{"gtk":false,"qtKde":false,"darkReader":true,"pear":"true","flatpak":1,"icons":"yes"}}' > "$SETTINGS_FILE"
chk "one read agrees with a jq per check, value by value" \
  "$(both gtk) $(both qt-kde) $(both dark-reader) $(both pear) $(both flatpak) $(both icons) $(both browsers)" \
  "disabled/disabled disabled/disabled enabled/enabled enabled/enabled disabled/disabled disabled/disabled disabled/disabled"
for content in '{"frameworks":{}}' '{}' 'not json' '{"frameworks":[true]}' '{"frameworks":null}'; do
  printf '%s' "$content" > "$SETTINGS_FILE"
  chk "...and for $content" "$(both gtk) $(both flatpak)" "enabled/enabled disabled/disabled"
done
rm -f "$SETTINGS_FILE"
chk "...and with no file" "$(both gtk) $(both icons)" "enabled/enabled disabled/disabled"
# A value crafted to read as another line must not switch an opt-in framework on.
printf '{"frameworks":{"qtKde":"x\\nflatpak\\ttrue","icons\\ttrue":false,"browsers\\n":true}}' > "$SETTINGS_FILE"
read_framework_switches
chk "a value or key crafted as another line enables nothing" \
  "$(r flatpak) $(r icons) $(r browsers) $(r qt-kde)" "disabled disabled disabled disabled"
FRAMEWORKS_READ=0
printf '{"frameworks":{"flatpak":true}}' > "$SETTINGS_FILE"; read_framework_switches
printf '{"frameworks":{"flatpak":false}}' > "$SETTINGS_FILE"; read_framework_switches
chk "each read replaces the last; nothing is kept from it" "$(r flatpak)" "disabled"
rm -f "$SETTINGS_FILE"
chk "the sync reads them once, right after it takes the lock" \
  "$(grep -B1 '^read_framework_switches$' "$REPO/bin/hyprchroma" | head -1)" "fi"
