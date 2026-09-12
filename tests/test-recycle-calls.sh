#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
REPO=$REPO
ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
# The layout is derived from the binary's own location, so the fake tree is
# a real one: a copy of the binary in bin/ with stubbed helpers beside it.
source "$(dirname "$0")/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR"

mkdir -p "$ROOT/lib" "$ROOT/bin" "$ROOT/share/hooks"
cp "$REPO"/lib/* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp "$REPO/share/hooks/hyprchroma" "$ROOT/share/hooks/hyprchroma"
cp "$REPO/share/pear-theme.css.template" "$ROOT/share/"
cat > "$ROOT/lib/hyprchroma-state" <<'E'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case $a in
    prepare-lock) lock=1 ;;
    write-file) writing=1 ;;
  esac
  case $prev in
    --path) [[ ${lock:-0} == 1 ]] && : > "$a"
            [[ ${writing:-0} == 1 ]] && cat > "$a" ;;
  esac
  prev=$a
done
[[ ${lock:-0} == 1 || ${writing:-0} == 1 ]] && exit 0
for a in "$@"; do
  case $a in
    refresh-idle-apps) echo "IDLE $*" | grep -o 'refresh-idle-apps.*' >> "$HOME/calls.log"; exit 0 ;;
    kde-color-clients|report-stale-apps|clear-app-color-schemes|snapshot) exit 0 ;;
  esac
done
exit 0
E
chmod +x "$ROOT/lib/hyprchroma-state"
printf '#!/usr/bin/env bash\n[[ $1 == --info ]] && echo "{}"\nexit 0\n' > "$ROOT/lib/hyprchroma-dark-reader"
chmod +x "$ROOT/lib/hyprchroma-dark-reader"
mkdir -p "$XDG_STATE_HOME/hyprchroma"

run() { : > "$HOME/calls.log"; bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; cat "$HOME/calls.log"; }
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

chk "forced run uses --written-now" "$(run --force --quiet)" "refresh-idle-apps --written-now"
chk "forced run calls it once"      "$(run --force --quiet | wc -l)" "1"
chk "event run uses theme baseline" "$(run --quiet)" "refresh-idle-apps"
chk "event run calls it once"       "$(run --quiet | wc -l)" "1"
chk "toggle on uses --written-now"  "$(run --target=gtk --set-enabled=true --quiet)" "refresh-idle-apps --written-now"
rm -rf "$ROOT"
