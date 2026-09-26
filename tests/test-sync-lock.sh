#!/usr/bin/env bash
# A sync that finds another holding the lock waits for it, rather than leaving.
# Leaving lost work: the running sync may have begun too early to see what the
# second was started for -- a waiter's write, the window that just closed -- so
# it sat undone until some later event happened along. Plain quiet runs queue
# at most one behind the running one, since each compares everything afresh;
# anything more specific always waits its turn. Also: what a sync costs, in
# processes started, so the savings made here cannot quietly come undone.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
unset DBUS_SESSION_BUS_ADDRESS
source "$REPO/tests/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/lib" "$ROOT/bin" "$XDG_STATE_HOME/hyprchroma"
cp "$REPO"/lib/hyprchroma-* "$REPO"/lib/sync-* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp -r "$REPO/share" "$ROOT/share"
# The state helper, logging each call by its subcommand; files it is asked to
# write are written, so status and stylesheets exist between runs.
cat > "$ROOT/lib/hyprchroma-state" <<'STUB'
#!/usr/bin/env bash
prev="" command=""
for a in "$@"; do
  case $a in --state-dir|--data-dir|--path|--line|--mode|--target) ;; -*) ;; *)
    [[ $prev == --state-dir || $prev == --data-dir || $prev == --path || $prev == --line ||
       $prev == --mode || $prev == --target ]] || command=${command:-$a} ;;
  esac
  case $prev in
    --path) [[ $command == prepare-lock ]] && : > "$a"
            [[ $command == write-file ]] && cat > "$a"
            [[ $command == ensure-import ]] && echo "@import url(\"hyprchroma.css\");" > "$a" ;;
  esac
  prev=$a
done
echo "${command:-?}" >> "$HOME/state-calls.log"
[[ $command == event-pass ]] && echo "ran" >> "$HOME/runs.log"
exit 0
STUB
chmod +x "$ROOT/lib/hyprchroma-state"
cat > "$ROOT/lib/hyprchroma-dark-reader" <<'STUB'
#!/usr/bin/env bash
echo "${1:-}" >> "$HOME/dark-reader-calls.log"
[[ $1 == --info ]] && echo '{"installed": false, "signature": ""}'
exit 0
STUB
chmod +x "$ROOT/lib/hyprchroma-dark-reader"
# The real resolver, counted.
mv "$ROOT/lib/hyprchroma-palette" "$ROOT/lib/hyprchroma-palette.real"
printf '#!/usr/bin/env bash\necho "$*" >> "$HOME/palette-calls.log"\nexec "%s" "$@"\n' \
  "$ROOT/lib/hyprchroma-palette.real" > "$ROOT/lib/hyprchroma-palette"
chmod +x "$ROOT/lib/hyprchroma-palette"
sync() { bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; }
lines() { [[ -f $1 ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
LOCK=$XDG_RUNTIME_DIR/hyprchroma-sync.lock

sync --force --quiet   # a first, whole run: status, stylesheets and lock in place
: > "$ROOT/runs.log"

# -- held: queued, not dropped ---------------------------------------------------
flock "$LOCK" sleep 2 &
holder=$!
sleep 0.3
sync --quiet & queued=$!
sleep 0.4
start=$(date +%s%N)
sync --quiet
second=$(( ($(date +%s%N) - start) / 1000000 ))
sync --target=gtk --quiet & targeted=$!
sleep 0.3
chk "while the lock is held, nothing gets past it" "$(lines "$ROOT/runs.log")" "0"
wait "$holder" "$queued" "$targeted"
chk "a quiet run started meanwhile waits and then runs, rather than being lost" \
  "$(grep -c ran "$ROOT/runs.log")" "2"
chk "...a second quiet run leaves at once, one already waiting covering it" \
  "$(( second < 1000 ))" "1"
chk "...and a targeted run waits its turn too: two runs in all, not three" \
  "$(lines "$ROOT/runs.log")" "2"
: > "$ROOT/runs.log"
sync --quiet
chk "with the lock free, a run goes straight through" "$(lines "$ROOT/runs.log")" "1"

# -- what a run costs --------------------------------------------------------------
: > "$ROOT/state-calls.log"; : > "$ROOT/palette-calls.log"; : > "$ROOT/dark-reader-calls.log"
sync --quiet
chk "a quiet run finding nothing changed starts the state helper once" \
  "$(sort "$ROOT/state-calls.log" | uniq -c | awk '{printf "%s:%s ", $2, $1}')" "event-pass:1 "
chk "...the palette resolver once" "$(cat "$ROOT/palette-calls.log")" "--for-sync"
chk "...and asks Dark Reader only where it is installed, not what is running" \
  "$(cat "$ROOT/dark-reader-calls.log")" "--info"
: > "$ROOT/state-calls.log"
sync --force --quiet
chk "a forced run over an unchanged palette rewrites no stylesheet and no import" \
  "$(grep -cE '^(write-file|ensure-import)$' "$ROOT/state-calls.log")" "1"
chk "...its one write being the status" \
  "$(grep -c '^write-file$' "$ROOT/state-calls.log")" "1"
: > "$ROOT/palette-calls.log"
sync --force --quiet
chk "the generators take the palette the sync resolved, not resolving it again" \
  "$(cat "$ROOT/palette-calls.log")" "--for-sync"
# Handed over or not, every value is checked: one that is not #rrggbb is
# refused rather than written into a stylesheet.
bad=$(HYPRCHROMA_PALETTE_TSV=$(printf 'background\tred; } * { color: red\nmode\tdark\n') \
  bash "$ROOT/lib/sync-gtk-theme" 2>&1 >/dev/null; echo "exit=$?")
chk "a generator refuses a handed-over value that is not a color" \
  "$(grep -c 'invalid palette color' <<<"$bad"),$(grep -o 'exit=[0-9]*' <<<"$bad")" "1,exit=1"
rm -rf "$ROOT"
