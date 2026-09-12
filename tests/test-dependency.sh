#!/usr/bin/env bash
# The panel drives hyprchroma; it does not do the theming itself. It has to
# notice three things it cannot fix silently: the package missing, the package
# too old, and its service stopped. All three offer the same key.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
# Comments in Panel.qml explain what the code does and quote the commands, so
# assertions about code must not match the prose describing it.
code(){ sed -e 's#^[[:space:]]*//.*##' "$@"; }
countcode(){ local pat=$1; shift; code "$@" | grep -ohE "$pat" | wc -l; }

# --- the requirement is declared once and agreed on twice ------------------
manifest=$(python3 -c "import json;print(json.load(open('manifest.json'))['hyprchroma']['minimumVersion'])")
panel=$(grep -oP 'readonly property string requiredVersion: "\K[^"]+' Panel.qml)
chk "manifest and panel agree on the required version" "$panel" "$manifest"
chk "the manifest names the package" \
  "$(python3 -c "import json;print(json.load(open('manifest.json'))['hyprchroma']['package'])")" "hyprchroma"

# --- version comparison is numeric, not lexical ----------------------------
# "1.10.0" is newer than "1.9.0". A string compare says otherwise.
if command -v node >/dev/null 2>&1; then
  result=$(python3 - <<'PY'
import pathlib
s = pathlib.Path("Panel.qml").read_text()
start = s.index("function olderThan"); depth = 0; i = s.index("{", start)
for j in range(i, len(s)):
    if s[j] == "{": depth += 1
    elif s[j] == "}":
        depth -= 1
        if depth == 0: end = j + 1; break
pathlib.Path("/tmp/.hc-olderthan.js").write_text(s[start:end] + """
const c=[["1.4.0","1.4.1",true],["1.4.1","1.4.1",false],["1.9.0","1.10.0",true],
["1.10.0","1.9.0",false],["2.0.0","1.4.1",false],["1.4","1.4.1",true],["garbage","1.4.1",true]];
let bad=0; for(const [h,w,e] of c) if(olderThan(h,w)!==e) bad++;
console.log(bad===0?"ok":"wrong");
""")
PY
)
  chk "version comparison is numeric" "$(node /tmp/.hc-olderthan.js; rm -f /tmp/.hc-olderthan.js)" "ok"
else
  echo "  SKIP version comparison (no node)"
fi
chk "an unparseable version does not read as outdated" \
  "$(grep -c 'installedVersion !== ""' Panel.qml)" "1"

# --- all three states, one key ---------------------------------------------
chk "the panel knows it may be outdated" "$(grep -c 'property bool outdated' Panel.qml)" "1"
chk "outdated blocks the toggles like missing does" \
  "$(grep -c 'dependencyPresent && daemonRunning && !outdated' Panel.qml)" "1"
chk "the banner has an install, an update and a start" \
  "$(grep -ohE 'Press i to (install|update|start) it' Panel.qml | sort -u | wc -l)" "3"

# --- installing and updating are the same mechanism ------------------------
chk "one script serves both" "$(grep -c 'readonly property string setupScript' Panel.qml)" "1"
# The build lives in the setup script now, not in a string in the panel.
chk "it builds with makepkg" "$(countcode 'makepkg -si' bin/hyprchroma-setup)" "1"
chk "there is no AUR dependency left" \
  "$(grep -c 'pkg aur add\|yay -S' Panel.qml bin/hyprchroma-setup | grep -v ':0$' | wc -l)" "0"
chk "it runs in a terminal the user can see" \
  "$(grep -c 'launch", "floating", "terminal", "with", "presentation"' Panel.qml)" "1"
# Two: this one, and the Escape handler that has always been there.
chk "the panel closes before the terminal opens" \
  "$(countcode 'root.close\(\)' Panel.qml)" "2"
chk "the service is enabled after building" \
  "$(grep -c 'systemctl --user enable --now hyprchromad.service' bin/hyprchroma-setup)" "1"

# --- nothing predictable is written anywhere ------------------------------
chk "no sentinel files" "$(grep -c 'install.done\|install.failed' Panel.qml)" "0"
chk "nothing is written to /tmp" "$(grep -c 'XDG_RUNTIME_DIR:-/tmp' Panel.qml)" "0"

# --- the plugin itself stays unprivileged ---------------------------------
chk "the plugin runs no privileged command itself" \
  "$(grep -cE '^\s*(sudo|pkexec) ' Panel.qml BarWidget.qml | grep -v ':0$' | wc -l)" "0"

# --- the contract across the repo boundary --------------------------------
# Two repositories move independently, so what this plugin calls in hyprchroma
# is an interface, not an implementation detail. Listed here so changing it is
# a visible diff in review rather than a silent version skew: the plugin once
# declared 1.4.1 while calling a subcommand that only existed from 1.5.0, and
# the panel reported itself ready.
# Panel.qml calls it through a QML argument list; the setup script calls it as
# a shell command. Both are normalized to "<subcommand> <action>" so the set is
# comparable whatever the caller looks like.
calls=$( { grep -ohE '"framework", "[a-z]+"' Panel.qml | tr -d '",' | sed 's/  */ /g'
           grep -ohE 'hyprchroma (framework|palette) [a-z-]+' bin/hyprchroma-setup | sed 's/^hyprchroma //'
         } | sort -u | paste -sd, )
chk "the hyprchroma subcommands this plugin depends on" "$calls" "framework remove,framework restore"
chk "the version it declares covers them" "$panel" "1.5.0"
