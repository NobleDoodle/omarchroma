#!/usr/bin/env bash
# Every Python start is isolated (-I): no usercustomize, sitecustomize or
# .pth files from the user's site-packages, no PYTHONPATH or PYTHONSTARTUP,
# and for "python3 -" no current directory on sys.path. Run for real: the code is planted, then every helper and generator is started,
# and nothing planted may run.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home XDG_RUNTIME_DIR=$ROOT/run
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$ROOT/cwd" "$ROOT/pythonpath"
marker=$ROOT/ran
plant() { printf 'import pathlib\npathlib.Path(%s).open("a").write("%s\\n")\n' "'$marker'" "$1" > "$2"; }
user_site=$(HOME=$HOME /usr/bin/python3 -c 'import site; print(site.getusersitepackages())')
mkdir -p "$user_site"
plant usercustomize "$user_site/usercustomize.py"
printf 'import pathlib; pathlib.Path(%s).open("a").write("pth\\n")\n' "'$marker'" > "$user_site/planted.pth"
for module in json argparse hashlib subprocess pathlib; do plant "cwd-$module" "$ROOT/cwd/$module.py"; done
plant pythonpath "$ROOT/pythonpath/sitecustomize.py"
export PYTHONPATH=$ROOT/pythonpath PYTHONSTARTUP=$ROOT/pythonpath/sitecustomize.py

# The plant itself works: a Python started without -I runs it.
( cd "$ROOT/cwd" && /usr/bin/python3 - <<<'import json' )
chk "(the planted code runs in a Python that is not isolated)" "$([[ -s $marker ]] && echo ran || echo not)" "ran"
: > "$marker"

cd "$ROOT/cwd" || exit 1
HYPRCHROMA_ICONS_ISOLATED=1 "$REPO/lib/hyprchroma-icons" status >/dev/null 2>&1
"$REPO/lib/hyprchroma-palette" --template >/dev/null 2>&1
"$REPO/lib/hyprchroma-dark-reader" --info >/dev/null 2>&1
"$REPO/lib/hyprchroma-state" prepare-lock --path "$ROOT/run/x.lock" >/dev/null 2>&1
printf 'x' | "$REPO/lib/hyprchroma-state" write-file --path "$ROOT/out" >/dev/null 2>&1
chk "no helper runs code from the user's site-packages, PYTHONPATH or the folder it starts in" \
  "$(sort -u "$marker" | paste -sd, -)" ""

# The generators' and the sync script's inline blocks, started from a folder
# holding a json.py, hashlib.py and the rest.
palette=$(printf '%s\t#%06x\n' background 1 dark_background 2 darker_background 3 lighter_background 4 \
  foreground 5 dark_foreground 6 light_foreground 7 bright_foreground 8 accent 9 selection 10 \
  selection_foreground 11 muted 12 red 13 bright_red 14 green 15 bright_green 16 yellow 17 \
  bright_yellow 18 blue 19 magenta 20; printf 'mode\tdark\n')
HYPRCHROMA_PALETTE_TSV=$palette "$REPO/lib/sync-qt-kde-theme" >/dev/null 2>&1
chk "the Qt/KDE generator wrote kdeglobals" "$([[ -s $HOME/.config/kdeglobals ]] && echo yes)" "yes"
"$REPO/bin/hyprchroma" --restart-mode=off >/dev/null 2>&1
chk "...and the sync script recorded a setting through its inline Python" \
  "$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["restartMode"])' "$HOME/.local/state/hyprchroma/settings.json" 2>/dev/null)" "off"
chk "neither ran anything planted" "$(sort -u "$marker" | paste -sd, -)" ""

# And it stays that way: every start, in every shipped file.
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
chk "every helper's shebang isolates Python" \
  "$(head -qn1 "$REPO"/lib/hyprchroma-{state,icons,dark-reader,palette} "$REPO/packaging/check-package" | sort -u)" "#!/usr/bin/python3 -I"
chk "every inline block does too" \
  "$(code "$REPO/bin/hyprchroma" "$REPO/bin/hyprchroma-setup" "$REPO/bin/hyprchroma-uninstall" "$REPO"/lib/sync-* "$REPO/share/hooks/hyprchroma" |
     grep -E '(^|[^[:alnum:]_/-])python3?( |$)' | grep -v -- '/usr/bin/python3 -I' | grep -vc 'command -v python3')" "0"
