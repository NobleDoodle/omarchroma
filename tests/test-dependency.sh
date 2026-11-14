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
  "$(grep -A1 'var manifest = JSON.parse(text())' Panel.qml | grep -c 'String(manifest.version')" "1"
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
  "$(grep -ohE '"(Install|Update|Start)  \(i\)"' Panel.qml | sort -u | wc -l)" "3"
chk "\"i\" is still the key for all three, not just named in the button" \
  "$(grep -c 'root.installDependency' Panel.qml)" "2"

# --- nothing else renders until hyprchroma is ready ------------------------
# The separator and the refresh/close-apps buttons once checked only
# !guideOpen, so with no service installed they still drew over an otherwise
# empty panel -- controls for a framework list that had nothing in it.
for control in 'text: "Refresh enabled' 'to close  (/)"'; do
  chk "gated on root.ready: $control" \
    "$(code Panel.qml | grep -B3 -A2 "$control" | grep -c 'visible:.*root\.ready')" "1"
done
# Two: the one above those buttons and the one under the header. The others sit
# inside views that are themselves only reachable once it is ready.
chk "gated on root.ready: PanelSeparator {" \
  "$(code Panel.qml | grep -B3 -A2 'PanelSeparator {' | grep -c 'visible:.*root\.ready')" "2"
# "/" used to flip the guide open regardless of readiness, showing an
# always-empty "Nothing to close" screen with no framework list behind it.
chk "the guide key is refused before the ready check, not after" \
  "$(python3 -c "
import re
s = open('Panel.qml').read()
start = s.index('function handleKey')
body = s[start:s.index('function ', start + 10)]
ready_at = body.index('if (!root.ready) return')
slash_at = body.index('key === \"/\"')
print('ok' if ready_at < slash_at else 'wrong-order')
")" "ok"

# --- installing and updating are the same mechanism ------------------------
chk "one script serves both" "$(grep -c 'readonly property string setupScript' Panel.qml)" "1"
# The build lives in the setup script now, not in a string in the panel --
# and it runs in the sandbox, never as makepkg -si:
# installing is a separate pacman -U, after the package has been checked.
chk "it builds with makepkg, in the sandbox" \
  "$(countcode 'in_sandbox "\$work_dir" "\$here/packaging" makepkg' bin/hyprchroma-setup)" "1"
chk "...and installs with pacman -U, never makepkg -i" \
  "$(countcode 'makepkg -si' bin/hyprchroma-setup),$(countcode '^run_sudo pacman -U --needed -- "\$built_package"' bin/hyprchroma-setup)" "0,1"
# hyprchroma itself still builds only from the checkout -- no AUR dependency
# for the thing this project ships.
chk "hyprchroma itself has no AUR dependency" \
  "$(countcode 'pkg aur add|yay -S' Panel.qml)" "0"
# Setup fetches and builds the two AUR packages it
# offers itself -- Pear Desktop and Reversal, never hyprchroma -- and
# tests/test-aur-build.sh runs that against fake repositories.
chk "no AUR helper is used" \
  "$(countcode 'pkg aur add|yay |paru ' bin/hyprchroma-setup)" "0"
chk "the AUR is reached for exactly two packages, by fixed URLs" \
  "$(grep -c '^REVERSAL_AUR_URL=https://aur.archlinux.org/reversal-icon-theme-git.git$' bin/hyprchroma-setup),$(grep -c '^PEAR_AUR_URL=https://aur.archlinux.org/pear-desktop-bin.git$' bin/hyprchroma-setup),$(countcode 'aur\.archlinux\.org/[a-z-]+\.git' bin/hyprchroma-setup)" "1,1,2"
# The password comes before anything is fetched from the AUR, not at the end
# of a build.
chk "sudo is asked for before each AUR download" \
  "$(sed -n '/^offer_reversal()/,/^}/p' bin/hyprchroma-setup | awk '/authenticate_for/{a=NR} /build_reversal/{b=NR} END{print (a && b && a < b) ? "first" : "after"}'),$(sed -n '/^if \[\[ \$want_pear == yes \]\]/,/^fi$/p' bin/hyprchroma-setup | awk '/authenticate_for/{a=NR} /build_pear/{b=NR} END{print (a && b && a < b) ? "first" : "after"}')" "first,first"
chk "authenticating is sudo -v, through the keepalive" \
  "$(grep -A3 '^authenticate_for()' bin/hyprchroma-setup | grep -c 'run_sudo -v')" "1"
chk "an AUR install is checked with pacman afterwards" \
  "$(grep -A6 '^install_built()' bin/hyprchroma-setup | grep -c 'pacman -Qq "\$package"')" "1"
# Install, Uninstall and the Reversal install: all in a terminal the user can see.
chk "it runs in a terminal the user can see" \
  "$(grep -c 'launch", "floating", "terminal", "with", "presentation"' Panel.qml)" "3"
# Seven: this one, the uninstaller's, the Reversal install's, the Escape
# handler that has always been there, the restart, which closes the panel out
# of the way of the windows it reopens, Dismiss, which ends the matter as a
# restart does, and Help, which hands over to the browser.
chk "the panel closes before the terminal opens" \
  "$(countcode 'root.close\(\)' Panel.qml)" "7"
chk "the service is enabled after building" \
  "$(grep -c '^systemctl --user enable hyprchromad.service' bin/hyprchroma-setup)" "1"
# Restarted, so an update runs at once: "enable --now" left a running service
# on the version it had loaded until the next login.
chk "...and restarted, so an update takes effect now" \
  "$(grep -c '^systemctl --user restart hyprchromad.service' bin/hyprchroma-setup)" "1"

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

# The marketplace refuses a community manifest whose description is over 500
# characters (its manifestFieldLimits); 4.0.0's first one was 513.
chk "the manifest description fits the marketplace's 500-character limit" \
  "$(jq -r '(.description | length) <= 500 and (.name | length) <= 120 and (.author | length) <= 120' manifest.json)" "true"
