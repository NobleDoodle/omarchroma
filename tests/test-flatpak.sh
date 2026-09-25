#!/usr/bin/env bash
# Flatpak apps read their configuration from a directory of their own, so the
# theme files the other frameworks write never reach them. This framework
# grants every Flatpak app read access to exactly those files, through
# flatpak's own global override -- a permission change for every sandboxed
# app, so it is opt-in, grants nothing beyond what theming reads, and reverses
# to exactly what was there before. Run against the real flatpak binary in a
# throwaway FLATPAK_USER_DIR, since its file format is what the reverse edits.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

if ! command -v flatpak >/dev/null; then
  echo "  PASS flatpak is not installed here; its behavior is covered where it is"
  exit 0
fi

ROOT=$(mktemp -d)
export HOME=$ROOT FLATPAK_USER_DIR=$ROOT/fp XDG_DATA_HOME=$ROOT/data
S=$ROOT/state D=$ROOT/share
O=$FLATPAK_USER_DIR/overrides/global
mkdir -p "$S" "$D" "$FLATPAK_USER_DIR"
state() { "$REPO/lib/hyprchroma-state" --state-dir "$S" --data-dir "$D" "$@"; }
fresh() { rm -rf "$S" "$FLATPAK_USER_DIR"; mkdir -p "$S" "$FLATPAK_USER_DIR"; }
filesystems() { sed -n 's/^filesystems=//p' "$O"; }
ours='xdg-config/gtk-3.0:ro;xdg-config/gtk-4.0:ro;xdg-config/kdeglobals:ro;xdg-data/color-schemes:ro;'

# -- what gets granted -------------------------------------------------------
fresh
chk "switching it on reports it synchronized" "$(state sync-flatpak)" "synchronized"
chk "exactly the four read-only theme grants" "$(filesystems)" "$ours"
chk "GTK_THEME is kept out of the sandbox" "$(sed -n 's/^unset-environment=//p' "$O")" "GTK_THEME;"
chk "nothing of hyprchroma's own state or data is granted" \
  "$(grep -c 'hyprchroma' "$O")" "0"
chk "every grant is read-only" "$(filesystems | tr ';' '\n' | grep -v '^$' | grep -vc ':ro$')" "0"
before=$(cat "$O")
state sync-flatpak >/dev/null
chk "syncing again changes nothing" "$(cat "$O")" "$before"

# -- reversing takes back exactly what it added ------------------------------
state restore --target flatpak --mode captured >/dev/null
chk "a captured revert of a fresh grant leaves no filesystem entry" "$(grep -c '^filesystems=' "$O")" "0"
chk "...no unset-environment" "$(grep -c '^unset-environment=' "$O")" "0"
chk "...no empty GTK_THEME beside it" "$(grep -c '^GTK_THEME=' "$O")" "0"
chk "...and no denial left behind, as --nofilesystem would" "$(grep -c '!' "$O")" "0"

# -- the user's own overrides are theirs -------------------------------------
fresh
flatpak override --user --filesystem=xdg-download:ro --env=FOO=bar
flatpak override --user --filesystem=xdg-config/gtk-3.0:ro   # already had one of ours
user_before=$(cat "$O")
state sync-flatpak >/dev/null
state restore --target flatpak --mode captured >/dev/null
chk "a captured revert returns the override to exactly what the user had" "$(cat "$O")" "$user_before"

fresh
flatpak override --user --filesystem=xdg-download:ro
state sync-flatpak >/dev/null
# The user widens one of ours afterwards: from then on it is their setting.
sed -i 's#xdg-config/gtk-4.0:ro#xdg-config/gtk-4.0#' "$O"
state restore --target flatpak --mode captured >/dev/null
chk "a grant the user changed since is left as they changed it" \
  "$(filesystems)" "xdg-download:ro;xdg-config/gtk-4.0;"

# Grants identical to these, added by hand before this was ever switched on,
# and never switched on since: nothing here is this project's to take back.
fresh
flatpak override --user --filesystem=xdg-config/gtk-3.0:ro --filesystem=xdg-config/kdeglobals:ro
hand=$(cat "$O")
state restore --target flatpak --mode captured >/dev/null
chk "never switched on: a captured revert takes nothing" "$(cat "$O")" "$hand"

# Stock is Omarchy's own defaults, which grant Flatpak apps none of these.
flatpak override --user --filesystem=xdg-download:ro
state restore --target flatpak --mode stock >/dev/null
chk "a stock revert removes every one of these, and nothing else" \
  "$(filesystems)" "xdg-download:ro;"

# -- a full uninstall reverts it too -----------------------------------------
fresh
state sync-flatpak >/dev/null
state restore --mode captured >/dev/null
chk "reverting everything includes Flatpak" "$(grep -c '^filesystems=' "$O")" "0"
rm -rf "$ROOT"

# -- no flatpak, no change -----------------------------------------------------
python3 - "$REPO" <<'E'
import sys, tempfile, types
from pathlib import Path
src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)
def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))
st.shutil.which = lambda *a, **k: None
ran = []
st.subprocess.run = lambda *a, **k: ran.append(a)
with tempfile.TemporaryDirectory() as work:
    chk("without flatpak it reports not installed", st.sync_flatpak(Path(work), Path(work)), "not-installed")
chk("...and runs nothing", ran, [])
E

# -- opt-in: only a recorded true turns it on --------------------------------
T=$(mktemp -d)
enabled() {
  printf '%s' "$1" > "$T/settings.json"
  ( SETTINGS_FILE=$T/settings.json
    source <(awk '/^target_key\(\) \{/,/^\}/' "$REPO/bin/hyprchroma")
    source <(awk '/^target_enabled\(\) \{/,/^\}/' "$REPO/bin/hyprchroma")
    target_enabled "$2" && echo on || echo off )
}
chk "no setting recorded: Flatpak is off" "$(enabled '{}' flatpak)" "off"
chk "...while the others default on" "$(enabled '{}' gtk)" "on"
chk "a recorded true turns it on" "$(enabled '{"frameworks":{"flatpak":true}}' flatpak)" "on"
chk "a recorded false keeps it off" "$(enabled '{"frameworks":{"flatpak":false}}' flatpak)" "off"
chk "switching another framework records Flatpak as off, never on" \
  "$(grep -c 'frameworks.setdefault("flatpak", False)' "$REPO/bin/hyprchroma")" "1"
rm -rf "$T"

# -- the panel and setup agree ---------------------------------------------------
P=$REPO/Panel.qml
chk "the panel lists it as a fifth framework" "$(grep -c 'target: "flatpak", label: "Flatpak apps"' "$P")" "1"
chk "the panel reads it as off unless settings say true" "$(grep -c 'flatpak: frameworks.flatpak === true' "$P")" "1"
chk "...and treats a missing value as off" \
  "$(grep -c 'if (key === "flatpak" || key === "browsers") return enabledTargets\[key\] === true' "$P")" "1"
chk "it can be toggled over IPC like the others" \
  "$(grep -c 'function toggleFlatpak(): void { root.toggleFramework("flatpak") }' "$REPO/BarWidget.qml")" "1"
U=$REPO/bin/hyprchroma-setup
chk "setup asks only where Flatpak is installed" "$(grep -c '^if command -v flatpak >/dev/null; then' "$U")" "1"
chk "declining is the default" "$(grep -c '^want_flatpak=no$' "$U")" "1"
chk "the question says what it grants" "$(grep -c 'four read-only permissions' "$U")" "1"
chk "a yes switches it on; anything else keeps it out of the panel" \
  "$(grep -cE 'hyprchroma framework (restore|remove) flatpak' "$U")" "2"

# -- the sync script's wiring, against a stubbed state helper ---------------
# The layout is derived from the binary's own location, so the fake tree is a
# real one: a copy of the binary with a helper beside it that logs its calls.
ROOT=$(mktemp -d); export HOME=$ROOT
export XDG_STATE_HOME=$ROOT/state XDG_DATA_HOME=$ROOT/data XDG_RUNTIME_DIR=$ROOT/run
source "$(dirname "$0")/lib-omarchy.sh"
seed_omarchy_theme
mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/lib" "$ROOT/bin" "$XDG_STATE_HOME/hyprchroma"
cp "$REPO"/lib/hyprchroma-* "$REPO"/lib/sync-* "$ROOT/lib/"
cp "$REPO/bin/hyprchroma" "$ROOT/bin/hyprchroma"
cp -r "$REPO/share" "$ROOT/share"
cat > "$ROOT/lib/hyprchroma-state" <<'E'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case $a in prepare-lock) lock=1 ;; write-file) writing=1 ;; esac
  case $prev in
    --path) [[ ${lock:-0} == 1 ]] && : > "$a"
            [[ ${writing:-0} == 1 ]] && cat > "$a" ;;
  esac
  prev=$a
done
[[ ${lock:-0} == 1 || ${writing:-0} == 1 ]] && exit 0
for a in "$@"; do
  case $a in
    sync-flatpak) echo "sync-flatpak" >> "$HOME/calls.log"; echo synchronized; exit 0 ;;
    restore) line="$*"; echo "restore ${line##*restore }" >> "$HOME/calls.log"; exit 0 ;;
  esac
done
exit 0
E
chmod +x "$ROOT/lib/hyprchroma-state"
printf '#!/usr/bin/env bash\n[[ $1 == --info ]] && echo "{}"\nexit 0\n' > "$ROOT/lib/hyprchroma-dark-reader"
chmod +x "$ROOT/lib/hyprchroma-dark-reader"
run() { : > "$HOME/calls.log"; bash "$ROOT/bin/hyprchroma" "$@" >/dev/null 2>&1; cat "$HOME/calls.log"; }
settings=$XDG_STATE_HOME/hyprchroma/settings.json

chk "a full sync with nothing recorded grants nothing" "$(run --force --quiet)" ""
chk "switching another framework on does not switch Flatpak on" \
  "$(run --target=gtk --set-enabled=true --quiet; jq -r '.frameworks.flatpak' "$settings")" "false"
chk "switching Flatpak on grants access" "$(run --target=flatpak --set-enabled=true --quiet)" "sync-flatpak"
chk "...and records it on" "$(jq -r '.frameworks.flatpak' "$settings")" "true"
chk "a full sync keeps it granted once on" "$(run --force --quiet)" "sync-flatpak"
chk "switching it off reverts to what was captured" \
  "$(run --target=flatpak --set-enabled=false --quiet)" "restore --target flatpak --mode captured"
chk "...and a full sync then leaves it alone" "$(run --force --quiet)" ""
rm -rf "$ROOT"
