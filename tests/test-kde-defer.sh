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

# Copy the plugin so kde-color-clients can be stubbed without touching the repo.
mkdir -p "$ROOT/lib" "$ROOT/bin" "$ROOT/share/hooks"
cp "$REPO"/lib/* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp "$REPO/share/hooks/hyprchroma" "$ROOT/share/hooks/hyprchroma"
cp "$REPO/share/pear-theme.css.template" "$ROOT/share/"
cat > "$ROOT/lib/hyprchroma-state" <<'E'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [[ $a == prepare-lock ]] && lock=1
  [[ $a == write-file ]] && writing=1
  if [[ $prev == --path ]]; then
    [[ ${lock:-0} == 1 ]] && { : > "$a"; exit 0; }
    [[ ${writing:-0} == 1 ]] && { cat > "$a"; exit 0; }
  fi
  prev=$a
done
for a in "$@"; do
  if [[ $a == kde-color-clients ]]; then [[ -n ${FAKE_KDE:-} ]] && echo "$FAKE_KDE"; exit 0; fi
  if [[ $a == restore ]]; then echo "REVERT-RAN" >> "$HOME/actions.log"; exit 0; fi
  if [[ $a == watch-kde-exit ]]; then echo "WATCHER-ARMED $*" >> "$HOME/actions.log"; exit 0; fi
done
exit 0
E
chmod +x "$ROOT/lib/hyprchroma-state"
S=$XDG_STATE_HOME/hyprchroma; mkdir -p "$S"

echo "--- KDE app running: must defer, must NOT write ---"
: > "$HOME/actions.log"
FAKE_KDE="kdenlive" bash "$ROOT/bin/hyprchroma" --target=qt-kde --set-enabled=false
sleep 0.3
grep -q "WATCHER-ARMED.*--action revert" "$HOME/actions.log" && echo "  PASS deferred watcher armed" || echo "  FAIL no revert watcher"
grep -q "REVERT-RAN" "$HOME/actions.log" && echo "  FAIL wrote kdeglobals under a running app" || echo "  PASS no immediate write"

echo "--- no KDE app: must revert immediately ---"
: > "$HOME/actions.log"
bash "$ROOT/bin/hyprchroma" --target=qt-kde --set-enabled=false
sleep 0.3
grep -q "REVERT-RAN" "$HOME/actions.log" && echo "  PASS reverted immediately" || echo "  FAIL did not revert"
grep -q "WATCHER-ARMED" "$HOME/actions.log" && echo "  FAIL armed watcher unnecessarily" || echo "  PASS no watcher needed"

echo "--- gtk is unaffected by the KDE guard ---"
: > "$HOME/actions.log"
FAKE_KDE="kdenlive" bash "$ROOT/bin/hyprchroma" --target=gtk --set-enabled=false
sleep 0.3
grep -q "REVERT-RAN" "$HOME/actions.log" && echo "  PASS gtk reverted immediately" || echo "  FAIL gtk blocked"
rm -rf "$ROOT"
