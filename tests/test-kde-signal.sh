#!/usr/bin/env bash
# Safe to run directly as well as through tests/run: never the real XDG
# folders or session bus, whatever the caller's environment holds.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
# Issue #7: after a theme change the Qt/KDE writer sent ConfigChanged on
# /kdeglobals as a{sas}. KConfigWatcher takes a{saay}, and Qt's decoder looped
# on the mismatch, allocating without bound in every app watching kdeglobals.
# The writer now sends no signal at all; running KDE apps take the new colors
# when they restart. Checked by running the writer on a bus of its own with a
# monitor attached, through a first sync and a palette change.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
code(){ find "$@" -maxdepth 1 -type f -exec grep -vhE '^[[:space:]]*#' {} +; }

chk "no KDE config signal is sent from any script or helper" \
  "$(code "$REPO/bin" "$REPO/lib" | grep -cE 'kconfig\.notify|ConfigChanged|KGlobalSettings')" "0"

for tool in dbus-run-session dbus-monitor; do
  command -v "$tool" >/dev/null || { echo "  SKIP the bus run: no $tool"; exit 0; }
done
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home XDG_RUNTIME_DIR=$ROOT/run GSETTINGS_BACKEND=memory HYPRCHROMA_NO_AUTO_RESTART=1
unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY DISPLAY HYPRCHROMA_TRACE_FD
mkdir -p "$HOME"; mkdir -m 700 "$XDG_RUNTIME_DIR"
palette() {
  printf '%s\t#%06x\n' background "$1" dark_background 2 darker_background 3 lighter_background 4 \
    foreground 5 dark_foreground 6 light_foreground 7 bright_foreground 8 accent 9 selection 10 \
    selection_foreground 11 muted 12 red 13 bright_red 14 green 15 bright_green 16 yellow 17 \
    bright_yellow 18 blue 19 magenta 20
  printf 'mode\tdark\n'
}
export REPO ROOT
export FIRST=$(palette 1) SECOND=$(palette 4210752)
timeout 60 dbus-run-session -- bash -c '
  dbus-monitor --session "type=signal" > "$ROOT/signals" 2>/dev/null & monitor=$!
  for _ in $(seq 50); do grep -q "member=NameAcquired" "$ROOT/signals" 2>/dev/null && break; sleep 0.1; done
  HYPRCHROMA_PALETTE_TSV=$FIRST "$REPO/lib/sync-qt-kde-theme" > "$ROOT/out1" 2>&1; echo $? > "$ROOT/rc1"
  cp "$HOME/.config/kdeglobals" "$ROOT/kdeglobals1" 2>/dev/null
  HYPRCHROMA_PALETTE_TSV=$SECOND "$REPO/lib/sync-qt-kde-theme" > "$ROOT/out2" 2>&1; echo $? > "$ROOT/rc2"
  # Ends the monitor only once a marker signal has come through it, so
  # anything the writer sent before it has been recorded.
  gdbus emit --session --object-path /hyprchroma/test --signal org.example.Test.Done 1 >/dev/null
  for _ in $(seq 50); do grep -q "member=Done" "$ROOT/signals" && break; sleep 0.1; done
  kill $monitor' 2>"$ROOT/bus.log"

chk "(the monitor saw the run end, so it saw all of it)" "$(grep -c 'member=Done' "$ROOT/signals")" "1"
chk "the writer ran: both syncs succeeded and kdeglobals took the scheme, then the change" \
  "$(cat "$ROOT/rc1"),$(cat "$ROOT/rc2"),$(grep -qx 'ColorScheme=Hyprchroma' "$HOME/.config/kdeglobals" && echo 1),$(cmp -s "$ROOT/kdeglobals1" "$HOME/.config/kdeglobals" && echo same || echo changed)" \
  "0,0,1,changed"
chk "...and no signal reached the bus on /kdeglobals, kconfig.notify or KGlobalSettings" \
  "$(grep -cE 'path=/kdeglobals|interface=org\.kde\.kconfig\.notify|interface=org\.kde\.KGlobalSettings' "$ROOT/signals")" "0"
