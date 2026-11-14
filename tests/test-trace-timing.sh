#!/usr/bin/env bash
# Opt-in step timing. While trace-timing exists in the
# state folder, a sync writes a timestamped trace of each command, its own and
# the two generators', to $XDG_RUNTIME_DIR/hyprchroma-trace, on a descriptor of
# its own. Checked here: off by default; on, the file is private and new; a
# planted flag, directory or descriptor is refused; and stdout and stderr,
# which the sync parses, are unchanged either way.
#
# No whole sync is run: a forced one recycles idle applications by scanning
# /proc, and so would reach the real desktop's. The sync script runs here
# with no palette, so it stops right after the trace starts; the generators
# run alone, as test-python-isolation runs them.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home XDG_RUNTIME_DIR=$ROOT/run DBUS_SESSION_BUS_ADDRESS=unix:path=$ROOT/no-bus
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY DISPLAY
export GSETTINGS_BACKEND=memory HYPRCHROMA_NO_AUTO_RESTART=1
mkdir -p "$HOME/.local/state/hyprchroma"; mkdir -m 700 "$XDG_RUNTIME_DIR"
S=$HOME/.local/state/hyprchroma T=$XDG_RUNTIME_DIR/hyprchroma-trace
sync_() { "$REPO/bin/hyprchroma" --quiet >"$ROOT/out" 2>"$ROOT/err"; echo $? > "$ROOT/rc"; }
traces() { find "$T" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l; }

# --- off unless the flag file exists ----------------------------------------
sync_; cp "$ROOT/out" "$ROOT/out-off"; cp "$ROOT/err" "$ROOT/err-off"; rc_off=$(cat "$ROOT/rc")
chk "(with no palette the sync stops before writing anything)" "$rc_off,$([[ -e $HOME/.config ]] && echo wrote || echo none)" "1,none"
chk "without the flag no trace is written" "$([[ -e $T ]] && echo made || echo none)" "none"

# --- on: a private, new file, and the same output ----------------------------
touch "$S/trace-timing"; sync_
f=$(find "$T" -maxdepth 1 -name '*.log' 2>/dev/null | head -1)
chk "with the flag, one trace in a private folder, readable only by the user" \
  "$(traces),$(stat -c %a "$T" 2>/dev/null),$(stat -c %a "$f" 2>/dev/null)" "1,700,600"
chk "...each line stamped: time, pid, script and line" \
  "$(grep -cE '^\++[0-9]+\.[0-9]{6} [0-9]+ hyprchroma:[0-9]+ ' "$f" | awk '{print ($1 > 5) ? "stamped" : $1}')" "stamped"
chk "...from the lock on, the palette included" "$(grep -c 'prepare_lock_file\|load_palette' "$f" | awk '{print ($1 >= 2) ? "yes" : $1}')" "yes"
chk "...and stdout, stderr and the exit status are what they were without it" \
  "$(cmp -s "$ROOT/out" "$ROOT/out-off" && cmp -s "$ROOT/err" "$ROOT/err-off" && echo same || echo differ),$(cat "$ROOT/rc")" "same,$rc_off"
chk "...nothing is exported for other programs to inherit" \
  "$(grep -cE 'export (SHELLOPTS|PS4|BASH_XTRACEFD)' "$REPO/bin/hyprchroma")" "0"

# --- planted things are refused ---------------------------------------------
rm -rf "$T"; rm -f "$S/trace-timing"; touch "$ROOT/elsewhere"; ln -s "$ROOT/elsewhere" "$S/trace-timing"; sync_
chk "a symlinked flag is not a flag" "$([[ -e $T ]] && echo made || echo none)" "none"
rm -f "$S/trace-timing"; touch "$S/trace-timing"
mkdir -m 700 "$ROOT/decoy"; ln -s "$ROOT/decoy" "$T"; sync_
chk "a trace folder that is a symlink is not written through" "$(find "$ROOT/decoy" -type f | wc -l)" "0"
rm -f "$T"; mkdir -m 700 "$T"; chmod 500 "$T"; sync_; chmod 700 "$T"
chk "a trace folder it cannot write leaves the sync as it was" \
  "$(cmp -s "$ROOT/err" "$ROOT/err-off" && echo same || echo differ),$(cat "$ROOT/rc")" "same,$rc_off"
rm -f "$S/trace-timing"

# --- the generators trace only onto a descriptor the sync opened -------------
palette=$(printf '%s\t#%06x\n' background 1 dark_background 2 darker_background 3 lighter_background 4 \
  foreground 5 dark_foreground 6 light_foreground 7 bright_foreground 8 accent 9 selection 10 \
  selection_foreground 11 muted 12 red 13 bright_red 14 green 15 bright_green 16 yellow 17 \
  bright_yellow 18 blue 19 magenta 20; printf 'mode\tdark\n')
export HYPRCHROMA_PALETTE_TSV=$palette
for g in sync-gtk-theme sync-qt-kde-theme; do
  rm -rf "$HOME/.config" "$HOME/.local/share/color-schemes" "$HOME/.icons" "$HOME/.local/share/icons"
  "$REPO/lib/$g" >"$ROOT/g-out-off" 2>"$ROOT/g-err-off"
  rm -rf "$HOME/.config" "$HOME/.local/share/color-schemes" "$HOME/.icons" "$HOME/.local/share/icons"
  exec {fd}>"$ROOT/g-trace"
  HYPRCHROMA_TRACE_FD=$fd "$REPO/lib/$g" >"$ROOT/g-out" 2>"$ROOT/g-err"
  exec {fd}>&-
  chk "$g traces onto the sync's descriptor" \
    "$(grep -cE "^\++[0-9]+\.[0-9]{6} [0-9]+ $g:[0-9]+ " "$ROOT/g-trace" | awk '{print ($1 > 5) ? "yes" : $1}')" "yes"
  chk "...with its stdout and stderr unchanged" \
    "$(cmp -s "$ROOT/g-out" "$ROOT/g-out-off" && cmp -s "$ROOT/g-err" "$ROOT/g-err-off" && echo same || echo differ)" "same"
  refused=""
  for bad in 1 2 3 99; do
    HYPRCHROMA_TRACE_FD=$bad "$REPO/lib/$g" >"$ROOT/g-out" 2>"$ROOT/g-err"
    cmp -s "$ROOT/g-out" "$ROOT/g-out-off" && cmp -s "$ROOT/g-err" "$ROOT/g-err-off" && refused+="$bad "
  done
  chk "...and refuses stdout, stderr, a low or an unopened descriptor" "$refused" "1 2 3 99 "
done
unset HYPRCHROMA_PALETTE_TSV
chk "an inherited descriptor number is dropped before the sync starts" \
  "$(grep -c '^unset HYPRCHROMA_TRACE_FD$' "$REPO/bin/hyprchroma")" "1"
