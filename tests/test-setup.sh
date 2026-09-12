#!/usr/bin/env bash
# The setup script is the only place a user is asked anything, so it is the
# only place that can get consent, explain what the optional frameworks are,
# and decide what to install. It runs in a terminal because every one of those
# needs somewhere to happen.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
S=bin/hyprchroma-setup

chk "the setup script ships and is executable" "$([ -x $S ] && echo yes || echo no)" "yes"
chk "it parses" "$(bash -n $S 2>&1 && echo ok)" "ok"

# --- nothing is built without the consent we had before --------------------
out=$(printf 'n\nn\nno\n' | timeout 30 ./$S 2>&1)
chk "it asks for the exact acknowledgement" "$(grep -c 'Type "I understand" to continue' <<<"$out")" "1"
chk "a wrong answer cancels" "$(grep -c 'Setup cancelled; nothing was changed' <<<"$out")" "1"
# The consent text names makepkg because it explains what will happen; what
# must not appear is makepkg's own output.
chk "and nothing was built" "$(grep -cE '==> Making package|Finished making' <<<"$out")" "0"
chk "makepkg only runs after the check" \
  "$(awk '/acknowledgement != "I understand"/{seen=1} /makepkg -si/{print (seen?"after":"before")}' $S)" "after"

# --- both optional frameworks are explained, not just named ---------------
chk "Pear is explained" "$(grep -c 'desktop app for YouTube Music' <<<"$out")" "1"
chk "Dark Reader is explained" "$(grep -c 'browser extension that darkens web pages' <<<"$out")" "1"
chk "it says it will not install the extension" \
  "$(grep -c 'does not install the extension' <<<"$out")" "1"
chk "both are asked about" "$(grep -cE 'Include (Pear Desktop|Dark Reader)' <<<"$out")" "0"
chk "declining is the default" "$(grep -c '\[y/N\]' $S)" "1"

# --- dependencies are scanned, explained, and optional --------------------
probe=$(mktemp); trap 'rm -f "$probe"' EXIT
sed 's/adw-gtk-theme/definitely-not-a-package/g; s/python-plyvel/also-not-a-package/g' $S > "$probe"
chmod +x "$probe"
want=$(printf 'n\ny\nn\nno\n' | timeout 30 "$probe" 2>&1)
chk "a missing dependency is named" "$(grep -c 'These are missing' <<<"$want")" "1"
chk "with what it is for" "$(grep -c 'GTK 3 apps follow the theme' <<<"$want")" "1"
chk "and the command to get it" "$(grep -c 'sudo pacman -S --needed' <<<"$want")" "1"
chk "declining leaves it uninstalled and says so" \
  "$(grep -c 'installs and runs without them' <<<"$want")" "1"

# Dark Reader's dependency is only relevant if Dark Reader was wanted.
skip=$(printf 'n\nn\nno\n' | timeout 30 "$probe" 2>&1)
chk "the Dark Reader dependency is not raised when it was declined" \
  "$(grep -c 'also-not-a-package' <<<"$skip")" "0"
# Twice: once in the list of what is missing, once in the command to get it.
chk "it is raised when it was wanted" "$(grep -c 'also-not-a-package' <<<"$want")" "2"

# --- Dark Reader's own check reads its installed location, not a guess ----
# hyprchroma-dark-reader is installed to /usr/lib/hyprchroma, deliberately
# left off the trusted PATH above since it is a private helper -- a bare call
# here always failed silently and read as "not installed" regardless of the
# truth.
chk "Dark Reader's info is never read as a bare command" \
  "$(grep -c 'hyprchroma-dark-reader --info' $S)" "0"
chk "the check happens right where the question is answered, not after the build" \
  "$(awk '/"\$here\/lib\/hyprchroma-dark-reader" --info/{seen=1} /makepkg -si --needed/{print (seen?"before":"after"); exit}' $S)" "before"
# Isolated HOME: darkReaderInstalled is judged from files under $HOME, so a
# fresh one deterministically reads as "not installed" regardless of which
# browser happens to be this machine's actual default.
dr_home=$(mktemp -d); trap 'rm -rf "$dr_home"' EXIT
dr_out=$(export HOME="$dr_home"
         printf 'n\ny\nno\n' | timeout 30 "./$S" 2>&1)
chk "the store links appear live, at the point Dark Reader is chosen" \
  "$(grep -c 'Chrome Web Store' <<<"$dr_out")" "1"
chk "before the build even starts" \
  "$(grep -cE '==> Making package|Finished making' <<<"$dr_out")" "0"
chk "it is read from where it is actually installed, twice" \
  "$(grep -c '"\$here/lib/hyprchroma-dark-reader" --info' $S)" "2"

# --- Pear Desktop is offered for install when wanted and missing ---------
# A real machine may already have pear-desktop, or a ~/.config/YouTube Music
# from before -- this one running the suite does, in fact, have both -- so
# both the command name and HOME are substituted, the same way the
# dependency probe above fakes a missing adw-gtk-theme.
pear_probe=$(mktemp); trap 'rm -f "$pear_probe"' EXIT
sed 's/command -v pear-desktop/command -v definitely-not-pear/' $S > "$pear_probe"
chmod +x "$pear_probe"
pear_home=$(mktemp -d); trap 'rm -rf "$pear_home"' EXIT
# y: include Pear. n: decline Dark Reader, so its dependency never enters it.
# n: decline the install offer below -- answering yes here would really try
# to run "omarchy pkg aur add" against this machine. no: cancel before build.
pear_out=$(export HOME="$pear_home"
           printf 'y\nn\nn\nno\n' | timeout 30 "$pear_probe" 2>&1)
chk "a missing, wanted Pear Desktop is named" \
  "$(grep -c 'Pear Desktop is not installed' <<<"$pear_out")" "1"
chk "with the AUR command to get it" \
  "$(grep -c 'omarchy pkg aur add pear-desktop-bin' <<<"$pear_out")" "1"
chk "declining leaves it uninstalled and says so" \
  "$(grep -c 'still offer Pear Desktop once you install it yourself' <<<"$pear_out")" "1"
# Reuses $out from the top of this file, where Pear was declined outright:
# nothing about its install state should be checked or printed at all.
chk "Pear's own check is skipped entirely when it was not wanted" \
  "$(grep -c 'Pear Desktop is not installed' <<<"$out")" "0"

# --- finishing restarts what would otherwise keep running stale code -----
chk "the restart offer comes after the build, not before" \
  "$(awk '/makepkg -si --needed/{seen=1} /Restart hyprchromad.service and the Omarchy shell now/{print (seen?"after":"before")}' $S)" "after"
chk "declining is not the default here, unlike every other question" \
  "$(grep -c 'ask_default_yes' $S)" "2"
chk "it restarts the service rather than only re-enabling it" \
  "$(grep -c 'systemctl --user restart hyprchromad.service' $S)" "2"
chk "and restarts the Omarchy shell too" "$(grep -c 'omarchy restart shell' $S)" "2"

# --- the panel hands off to it -------------------------------------------
chk "the panel runs the setup script" "$(grep -c 'bin/hyprchroma-setup' Panel.qml)" "1"
chk "in a terminal the user can see" \
  "$(grep -c 'launch", "floating", "terminal", "with", "presentation"' Panel.qml)" "1"
# The panel's comment mentions makepkg to explain why a terminal is needed;
# what it must not contain is a build command.
chk "the panel embeds no build command of its own" \
  "$(sed -e 's#^[[:space:]]*//.*##' Panel.qml | grep -c 'makepkg')" "0"

# --- removed frameworks leave the panel, and can come back ---------------
chk "the panel renders only what was not removed" \
  "$(grep -c 'model: root.visibleFrameworks' Panel.qml)" "1"
chk "removals are read from settings" "$(grep -c 'parsed.removed' Panel.qml)" "1"
chk "the guide lists what was removed" "$(grep -c 'model: root.hiddenFrameworks' Panel.qml)" "1"
chk "with a key to put it back" "$(grep -c 'press the number to put one back' Panel.qml)" "1"
chk "and an action behind it" "$(grep -c 'framework", "restore"' Panel.qml)" "1"
