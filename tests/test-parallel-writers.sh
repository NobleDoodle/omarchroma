#!/usr/bin/env bash
# The frameworks' writers run in lanes, side by side,
# under the one sync lock. Every writer here is a stub that logs when it
# starts and ends and takes a moment, so the order of those marks shows what
# overlapped -- no wall-clock thresholds. Checked: the lanes overlap, the
# orders that matter hold (GTK, Icons, then Qt/KDE until the theme points at
# Icons' set; Flatpak, browsers, Thunderbird one at a time), the snapshots come
# first in one call, the log reads in a fixed order, a failing lane fails the
# sync without stopping the others, a stuck lane is stopped, and the private
# folder never outlives the run.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); trap 'pkill -P $$ 2>/dev/null; rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home XDG_RUNTIME_DIR=$ROOT/run DBUS_SESSION_BUS_ADDRESS=unix:path=$ROOT/no-bus
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME HYPRLAND_INSTANCE_SIGNATURE
export HYPRCHROMA_NO_AUTO_RESTART=1
mkdir -p "$HOME" "$ROOT/tree"; mkdir -m 700 "$XDG_RUNTIME_DIR"
source "$REPO/tests/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$HOME/.local/state/hyprchroma" "$HOME/.config/YouTube Music" "$HOME/.config/omarchy/themes/testtheme"
printf '{"frameworks":{"gtk":true,"qtKde":true,"darkReader":true,"pear":true,"flatpak":true,"browsers":true,"thunderbird":true,"icons":true}}\n' \
  > "$HOME/.local/state/hyprchroma/settings.json"

# The layout is derived from the binary's own location: a copy of the tree,
# with every writer stubbed.
T=$ROOT/tree; mkdir -p "$T/bin" "$T/lib" "$T/share"
cp "$REPO/bin/hyprchroma" "$T/bin/"; cp "$REPO"/lib/hyprchroma-palette "$T/lib/"
cp "$REPO/share/pear-theme.css.template" "$T/share/"
LOG=$ROOT/marks
mark='printf "%s %s %s\n" "$1" "$2" "$EPOCHREALTIME" >> '"$LOG"
cat > "$T/lib/stub-writer" <<EOF
#!/usr/bin/env bash
# stub-writer <name>: a writer that takes a moment, and says so.
m() { $mark; }
m start "\$1"; echo \$\$ > "$ROOT/pid-\$1"
sleep "\$(cat "$ROOT/delay-\$1" 2>/dev/null || echo 0.3)"
m end "\$1"
exit "\$(cat "$ROOT/exit-\$1" 2>/dev/null || echo 0)"
EOF
cat > "$T/lib/hyprchroma-state" <<EOF
#!/usr/bin/env bash
prev="" writing=0 lock=0
for a in "\$@"; do
  case \$a in prepare-lock) lock=1 ;; write-file) writing=1 ;; esac
  if [[ \$prev == --path ]]; then
    (( lock )) && : > "\$a"
    (( writing )) && { mkdir -p "\${a%/*}"; cat > "\$a"; }
  fi
  prev=\$a
done
(( lock || writing )) && exit 0
case " \$* " in
  *" snapshot "*) printf 'snapshot call %s %s\n' "\$EPOCHREALTIME" "\${*#*snapshot }" >> "$LOG"
                  [[ -d "\$(ls -d "$ROOT/run"/hyprchroma-lanes-* 2>/dev/null)" ]] && echo "snapshot-during-lanes" >> "$LOG"; exit 0 ;;
  *" kde-color-clients "*) "$T/lib/stub-writer" kde-check >/dev/null; cat "$ROOT/kde-clients" 2>/dev/null; exit 0 ;;
  *" watch-kde-exit "*) echo "watch-kde-exit armed" >> "$LOG"; exit 0 ;;
  *" sync-flatpak "*) "$T/lib/stub-writer" flatpak && echo synchronized; exit ;;
  *" sync-browsers "*) "$T/lib/stub-writer" browsers && printf 'synchronized\nFirefox\n'; exit ;;
  *" sync-thunderbird "*) "$T/lib/stub-writer" thunderbird && printf 'synchronized\nThunderbird\n'; exit ;;
esac
exit 0
EOF
cat > "$T/lib/hyprchroma-dark-reader" <<EOF
#!/usr/bin/env bash
[[ \$1 == --info ]] && { echo '{"installed": true, "signature": "s"}'; exit 0; }
stat -c %a "\$(ls -d "$ROOT/run"/hyprchroma-lanes-* | head -1)" > "$ROOT/lane-dir-mode"
"$T/lib/stub-writer" dark-reader && echo "Dark Reader synchronized"
EOF
printf '#!/usr/bin/env bash\n"%s/lib/stub-writer" icons && echo "icons summary"\n' "$T" > "$T/lib/hyprchroma-icons"
printf '#!/usr/bin/env bash\nexec "%s/lib/stub-writer" gtk\n' "$T" > "$T/lib/sync-gtk-theme"
printf '#!/usr/bin/env bash\nexec "%s/lib/stub-writer" qt-kde\n' "$T" > "$T/lib/sync-qt-kde-theme"
chmod +x "$T"/lib/*

sync_() { : > "$LOG"; "$T/bin/hyprchroma" --force "$@" >"$ROOT/out" 2>"$ROOT/err"; echo $? > "$ROOT/rc"; }
at() { awk -v k="$1 $2" '$1 " " $2 == k { print $3; exit }' "$LOG"; }
before() { awk -v a="$(at "$1" "$2")" -v b="$(at "$3" "$4")" 'BEGIN { print (a != "" && b != "" && a + 0 < b + 0) ? "yes" : "no" }'; }

# --- the pointer is in place: Qt/KDE runs alongside ---------------------------
echo Omarchroma-Icons > "$HOME/.config/omarchy/themes/testtheme/icons.theme"
sync_
chk "(the sync succeeds with every framework on)" "$(cat "$ROOT/rc")" "0"
chk "the lanes overlap: Qt/KDE, Dark Reader and Flatpak start before GTK ends" \
  "$(before start qt-kde end gtk),$(before start dark-reader end gtk),$(before start flatpak end gtk)" "yes,yes,yes"
chk "...GTK and Icons too, once the theme points at Icons' set" "$(before start icons end gtk)" "yes"
chk "Flatpak, browsers and Thunderbird run one at a time, in that order" \
  "$(before end flatpak start browsers),$(before end browsers start thunderbird)" "yes,yes"
chk "every capture is taken first, in one call, before any lane" \
  "$(grep -c '^snapshot call' "$LOG"),$(awk '$1 == "snapshot" { sub(/.* snapshot /, ""); print }' "$LOG"),$(grep -c snapshot-during-lanes "$LOG"),$(before snapshot call start gtk)" \
  "1,--target gtk --target qt-kde --target pear,0,yes"
chk "the lanes' folder is private while they run, and gone after" \
  "$(cat "$ROOT/lane-dir-mode"),$(ls "$XDG_RUNTIME_DIR" | grep -c hyprchroma-lanes)" "700,0"

chk "the KDE check runs while the snapshots are taken" "$(before snapshot call end kde-check)" "yes"

# --- a KDE application running: Qt/KDE is deferred, and its waiter armed ------
echo okular > "$ROOT/kde-clients"; sync_; rm -f "$ROOT/kde-clients"
chk "with a KDE application running, Qt/KDE is left alone and a waiter armed" \
  "$(at start qt-kde | grep -c .),$(grep -c '^watch-kde-exit armed' "$LOG"),$(grep -c 'Qt and KDE left untouched; still running: okular' "$ROOT/out")" "0,1,1"
chk "...and the sync still succeeds" "$(cat "$ROOT/rc")" "0"

# --- the pointer is not in place: Qt/KDE waits for Icons ----------------------
rm "$HOME/.config/omarchy/themes/testtheme/icons.theme"
sync_
chk "without Icons' pointer in place, GTK, Icons and Qt/KDE run in that order" \
  "$(before end gtk start icons),$(before end icons start qt-kde)" "yes,yes"

# --- the log reads in a fixed order -------------------------------------------
echo Omarchroma-Icons > "$HOME/.config/omarchy/themes/testtheme/icons.theme"
echo 0.05 > "$ROOT/delay-gtk"; echo 0.6 > "$ROOT/delay-dark-reader"   # finishing order turned around
order() { grep -E '^Hyprchroma: (synchronizing|icons:|additional|thunderbird:)|^Dark Reader' "$ROOT/out" | paste -sd'|'; }
sync_; first=$(order)
echo 0.6 > "$ROOT/delay-gtk"; echo 0.05 > "$ROOT/delay-dark-reader"
sync_; second=$(order)
rm -f "$ROOT/delay-gtk" "$ROOT/delay-dark-reader"
chk "the log is in framework order, whichever lane finishes first" "$second" "$first"
chk "...which is the order they ran in one after another" "$first" \
  "Hyprchroma: synchronizing GTK|Hyprchroma: synchronizing icons|Hyprchroma: icons: icons summary|Hyprchroma: synchronizing Qt and KDE|Hyprchroma: synchronizing Pear Desktop|Hyprchroma: synchronizing Flatpak apps|Hyprchroma: synchronizing additional browsers|Hyprchroma: additional browsers: Firefox|Hyprchroma: synchronizing Thunderbird|Hyprchroma: thunderbird: Thunderbird|Dark Reader synchronized"

# --- a failing lane fails the sync, once the others are done ------------------
status_before=$(stat -c %Y.%N "$HOME/.local/state/hyprchroma/status.json" 2>/dev/null)
echo 1 > "$ROOT/exit-flatpak"; sync_; rm -f "$ROOT/exit-flatpak"
chk "a failing writer fails the sync, with its message" \
  "$(cat "$ROOT/rc"),$(grep -c 'Flatpak synchronization failed' "$ROOT/err")" "1,1"
chk "...after the other lanes finished; only its own lane stops" \
  "$(at end dark-reader | grep -c .),$(at end qt-kde | grep -c .),$(at start browsers | grep -c .)" "1,1,0"
chk "...and the status is not written" "$(stat -c %Y.%N "$HOME/.local/state/hyprchroma/status.json" 2>/dev/null)" "$status_before"
chk "...nor the lanes' folder left behind" "$(ls "$XDG_RUNTIME_DIR" | grep -c hyprchroma-lanes)" "0"

# --- a stuck lane is stopped --------------------------------------------------
sed 's/^LANE_SECONDS=110$/LANE_SECONDS=2/' "$REPO/bin/hyprchroma" > "$T/bin/hyprchroma"
chk "(the copy took the shorter limit)" "$(grep -c '^LANE_SECONDS=2$' "$T/bin/hyprchroma")" "1"
echo 30 > "$ROOT/delay-browsers"; sync_; rm -f "$ROOT/delay-browsers"
chk "a lane still running at the limit fails the sync, named" \
  "$(cat "$ROOT/rc"),$(grep -c 'the files writers did not finish within 2 seconds' "$ROOT/err")" "1,1"
stuck=$(cat "$ROOT/pid-browsers")
chk "...and what it was running is stopped" "$(kill -0 "$stuck" 2>/dev/null && echo running || echo stopped)" "stopped"
chk "...and the lanes' folder is gone" "$(ls "$XDG_RUNTIME_DIR" | grep -c hyprchroma-lanes)" "0"
cp "$REPO/bin/hyprchroma" "$T/bin/hyprchroma"

# --- the shape -----------------------------------------------------------------
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
chk "a lane's results are read back only into the names it may set" \
  "$(code "$REPO/bin/hyprchroma" | grep -c 'icons_state|icons_summary|pear_state|flatpak_state|browsers_state|browsers_summary|thunderbird_state|thunderbird_summary|dark_reader_exit)$')" "1"
chk "Dark Reader's lookup starts before the palette is resolved" \
  "$(awk '/^exec \{dark_reader_info_fd\}< <\(/ { e = NR } /^load_palette$/ { l = NR } END { print (e && l && e == l - 1) ? "yes" : "no" }' "$REPO/bin/hyprchroma")" "yes"
chk "the watchdog does not hold the sync lock" \
  "$(code "$REPO/bin/hyprchroma" | grep -c '^) >/dev/null 2>&1 </dev/null 9>&- &$')" "1"
