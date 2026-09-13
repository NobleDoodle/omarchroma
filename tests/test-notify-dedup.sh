#!/usr/bin/env bash
# report_stale_apps fired notify-send unconditionally whenever the stale-app
# list was non-empty, with no check against the --notify flag every other
# notification in this script respects. The daemon's own event-driven sync --
# hyprchroma --quiet, run on every window opened or closed nearby, not only
# ones that mattered -- calls it on every one of them, so with an app like a
# browser left open for a while, the same "restart to finish theming" popup
# fired again and again for as long as it stayed open.
#
# notify-send itself is resolved from this script's pinned PATH -- deliberately
# immune to anything a test can put in front of it -- so what this actually
# asserts on is the one thing gated the same way notify-send is: the write
# that records what was last reported. It happens exactly when, and only when,
# the real call would have fired.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
source "$(dirname "$0")/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME/hyprchroma"

mkdir -p "$ROOT/lib" "$ROOT/bin" "$ROOT/share/hooks"
cp "$REPO"/lib/hyprchroma-* "$ROOT/lib/" 2>/dev/null
cp "$REPO"/lib/sync-* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp "$REPO/share/hooks/hyprchroma" "$ROOT/share/hooks/hyprchroma"
cp "$REPO/share/pear-theme.css.template" "$ROOT/share/"

# STALE_APPS controls what report-stale-apps answers with, so the same fake
# binary can play "something is stale" and "nothing is" across separate runs.
# Every write-file call is counted separately by its target path, so a write
# to last-stale-notify -- the one report_stale_apps only reaches once it has
# decided to notify -- is distinguishable from the others this same run makes.
cat > "$ROOT/lib/hyprchroma-state" <<E
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  case \$a in
    prepare-lock) lock=1 ;;
    write-file) writing=1 ;;
  esac
  case \$prev in
    --path) [[ \${lock:-0} == 1 ]] && : > "\$a"
            if [[ \${writing:-0} == 1 ]]; then
              cat > "\$a"
              [[ \$a == "$XDG_STATE_HOME/hyprchroma/last-stale-notify" ]] && \
                echo x >> "$ROOT/notify-writes.log"
            fi ;;
  esac
  prev=\$a
done
[[ \${lock:-0} == 1 || \${writing:-0} == 1 ]] && exit 0
for a in "\$@"; do
  case \$a in
    report-stale-apps) [[ -n \${STALE_APPS:-} ]] && printf '%s\n' "\$STALE_APPS"; exit 0 ;;
    kde-color-clients|clear-app-color-schemes|snapshot|refresh-idle-apps) exit 0 ;;
  esac
done
exit 0
E
chmod +x "$ROOT/lib/hyprchroma-state"
printf '#!/usr/bin/env bash\n[[ $1 == --info ]] && echo "{}"\nexit 0\n' > "$ROOT/lib/hyprchroma-dark-reader"
chmod +x "$ROOT/lib/hyprchroma-dark-reader"

chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
notify_writes() {
  [[ -f $ROOT/notify-writes.log ]] || { echo 0; return; }
  wc -l < "$ROOT/notify-writes.log" | tr -d ' '
}

# -- the theme-set hook is the one caller that should pass --notify ---------
# A theme switch is a one-shot, user-initiated event, not the daemon's
# continuous per-window sync --notify is withheld from above -- and the
# dedup this file already covers means it cannot repeat for the same still-
# open app. --quiet only silences the console log line and says nothing
# about the notification, so both flags belong on this one call together.
chk "the theme-set hook asks to be notified, not just to run quietly" \
    "$(grep -c '^exec /usr/bin/hyprchroma --force --quiet --notify$' "$REPO/share/hooks/hyprchroma")" "1"

run() { bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; }

# -- the daemon's own quiet syncs never reach the notify gate ---------------
rm -f "$ROOT/notify-writes.log"
STALE_APPS="Helium" run --quiet
STALE_APPS="Helium" run --quiet
STALE_APPS="Helium" run --force --quiet
chk "a quiet sync never notifies, no matter how many times it repeats" \
    "$(notify_writes)" "0"

# -- a --notify run does, once, for a list not shown before ------------------
rm -f "$ROOT/notify-writes.log" "$XDG_STATE_HOME/hyprchroma/last-stale-notify"
STALE_APPS="Helium" run --force --notify
chk "a --notify run reports a new stale list" "$(notify_writes)" "1"

# -- the same list again, unrelated to the first notification, stays quiet --
STALE_APPS="Helium" run --force --notify
STALE_APPS="Helium" run --force --notify
chk "the same list is not repeated across further --notify runs" \
    "$(notify_writes)" "1"

# -- the list changing is worth saying again ---------------------------------
STALE_APPS="Helium, Nautilus" run --force --notify
chk "a changed list is reported again" "$(notify_writes)" "2"

# -- nothing stale, then the same names again: that is new, not a repeat ----
STALE_APPS="" run --force --notify
STALE_APPS="Helium, Nautilus" run --force --notify
chk "the same names after a quiet gap count as new, not a repeat" \
    "$(notify_writes)" "3"

rm -rf "$ROOT"
