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

# --- one version, in one place ---------------------------------------------
# The service and the plugin ship together now, so there is no minimum to
# maintain by hand -- the plugin expects its own version. These three must
# agree or the package, the manifest and the panel disagree about what this is.
version=$(cat VERSION)
chk "manifest version matches VERSION" \
  "$(python3 -c "import json;print(json.load(open('manifest.json'))['version'])")" "$version"
chk "PKGBUILD pkgver matches VERSION" \
  "$(grep -oP '^pkgver=\K.*' packaging/PKGBUILD)" "$version"
chk "the service reports that version" \
  "$(./bin/hyprchroma --version | awk '{print $2}')" "$version"
chk "the panel reads the manifest rather than hardcoding a number" \
  "$(grep -c 'JSON.parse(text()).version' Panel.qml)" "1"
chk "no hand-maintained minimum is left" \
  "$(grep -c 'minimumVersion\|requiredVersion' Panel.qml manifest.json | grep -v ':0$' | wc -l)" "0"

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

# --- the panel still only calls what the service offers --------------------
# One repository now, so this can check the actual dispatch rather than a
# version number standing in for it.
for sub in $(grep -ohE '"framework", "[a-z]+"' Panel.qml | tr -d '",' | awk '{print $2}' | sort -u); do
  chk "the service still offers: framework $sub" \
    "$(grep -cE "^      (list|remove\\|restore)\\)" bin/hyprchroma)" "2"
done
# Expand the case labels into the set of actions the dispatch accepts, so an
# alternation like "remove|restore)" counts as both rather than neither.
accepted=$(grep -oE '^      [a-z|]+\)' bin/hyprchroma | tr -d ' )' | tr '|' '\n' | sort -u)
missing=0
for called in $(grep -ohE 'hyprchroma framework [a-z-]+' bin/hyprchroma-setup | awk '{print $3}' | sort -u); do
  grep -qx "$called" <<<"$accepted" || missing=$((missing + 1))
done
chk "the setup script only calls actions the service accepts" "$missing" "0"
chk "and the panel does too" "$(
  missing=0
  for called in $(grep -ohE '"framework", "[a-z]+"' Panel.qml | tr -d '",' | awk '{print $2}' | sort -u); do
    grep -qx "$called" <<<"$accepted" || missing=$((missing + 1))
  done
  echo $missing)" "0"
