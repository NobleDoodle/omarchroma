#!/usr/bin/env bash
# The uninstaller the panel opens from Settings: it asks before every step,
# says what each changes, needs a password only to remove packages, and with
# every answer no removes nothing. Runs against a throwaway HOME, with the
# machine's own package and service checks replaced, so nothing real is read
# as "installed" and nothing real is removed.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
U=$REPO/bin/hyprchroma-uninstall
P=$REPO/Panel.qml
code(){ grep -vE '^[[:space:]]*#' "$@"; }

# --- the panel opens it -----------------------------------------------------
chk "Settings has an Uninstall button" \
  "$(grep -c 'text: "Uninstall Omarchroma...  (u)"' "$P"),$(grep -A4 'text: "Uninstall Omarchroma' "$P" | grep -c 'onClicked: root.openUninstall()')" "1,1"
chk "u opens it from Settings" \
  "$(grep -A6 '^    if (root.settingsOpen) {' "$P" | grep -c 'if (key === "u") { root.openUninstall(); return }')" "1"
chk "it runs the shipped script in the presented terminal" \
  "$(grep -c '+ "/bin/hyprchroma-uninstall"' "$P"),$(grep -A2 'id: uninstallProcess' "$P" | grep -c '"terminal", "with", "presentation", root.uninstallScript')" "1,1"
chk "the panel closes first, so the terminal has the keyboard" \
  "$(grep -A5 'function openUninstall()' "$P" | grep -c 'root.close()')" "1"

# --- the script's shape -----------------------------------------------------
chk "it is executable and parses" "$([[ -x $U ]] && bash -n "$U" && echo ok)" "ok"
chk "its PATH is the same verified set as setup's" \
  "$(diff <(sed -n '/^omarchroma_trusted_path()/,/^}$/p' "$REPO/bin/hyprchroma-setup") \
          <(sed -n '/^omarchroma_trusted_path()/,/^}$/p' "$U") >/dev/null && echo same)" "same"
chk "it runs whole from main(), so removing the plugin folder last is safe" \
  "$(tail -2 "$U" | paste -sd' ')" 'main "$@" exit'
chk "every question defaults to no" "$(grep -c '^ask() {' "$U"),$(code "$U" | grep -cE 'ask "[^"]*" yes|ask "[^"]*" "yes"')" "1,0"
chk "sudo only ever runs pacman -R" \
  "$(code "$U" | grep -oE 'run_sudo [a-z-]+ [-A-Za-z]+' | sort -u | paste -sd,)" "run_sudo pacman -R"
chk "nothing is downloaded" "$(code "$U" | grep -cE 'curl|wget|git clone|pkg aur|pacman -S')" "0"
chk "Omarchy's own packages are never offered" \
  "$(grep '^helper_packages=' "$U" | grep -cE 'yaru-icon-theme|jq')" "0"
chk "adw-gtk-theme is, since Omarchy does not ship it, and with what it was for" \
  "$(grep '^helper_packages=' "$U" | grep -c 'adw-gtk-theme'),$(grep -cxF -- adw-gtk-theme /usr/share/omarchy/install/*.packages 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}'),$(grep -c '    adw-gtk-theme) printf' "$U")" "1,0,1"
chk "...with a warning when GTK still uses it" \
  "$(grep -c 'gtk_now == adw-gtk3\*' "$U")" "1"
chk "a helper is offered only if explicit, unneeded and not Omarchy's" \
  "$(sed -n '/^removable_helper()/,/^}$/p' "$U" | grep -cE "Explicitly installed|Required By \*: None|omarchy/install/\*\.packages")" "3"
chk "the plugin is removed through Omarchy, after our own confirmation" \
  "$(code "$U" | grep -c 'omarchy plugin remove "\$plugin_id" --yes')" "1"
chk "the service stops before anything is put back" \
  "$(code "$U" | grep -n -E 'disable --now hyprchromad|restore --captured' | cut -d: -f1 | paste -sd' ' | awk '{print ($1 < $2) ? "first" : "after"}')" "first"
chk "each step says what it changes before it asks" \
  "$(grep -c '^ *step "' "$U")" "8"

# --- a run against a throwaway home ------------------------------------------
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/bin" "$work/repo/share/hooks" "$work/home"
cp "$REPO/share/hooks/hyprchroma" "$work/repo/share/hooks/hyprchroma"
# The machine's own answers replaced: no package installed, no Reversal, no
# helper to offer, and our hook judged against this copy, not /usr/share.
sed -e 's|^  package_version=\$(pacman -Q hyprchroma.*|  package_version=""|' \
    -e 's|^helper_packages=(.*|helper_packages=()|' \
    -e 's|pacman -Qq "\$reversal_package"|false|g' \
    -e 's|/usr/share/hyprchroma/hooks/hyprchroma|/nonexistent/hook|g' \
    -e 's|-x /usr/bin/hyprchroma ]]|-x /nonexistent/hyprchroma ]]|' \
    "$U" > "$work/repo/bin/hyprchroma-uninstall"
chmod +x "$work/repo/bin/hyprchroma-uninstall"
# A stand-in hyprchroma, found the way a checkout's own copy is: it records
# what it was asked to do and does nothing.
mkdir -p "$work/repo/lib"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$work" > "$work/repo/bin/hyprchroma"
chmod +x "$work/repo/bin/hyprchroma"
chk "the probe replaced the machine checks" \
  "$(grep -c '^  package_version=""$' "$work/repo/bin/hyprchroma-uninstall"),$(grep -c '/nonexistent/hyprchroma' "$work/repo/bin/hyprchroma-uninstall"),$(grep -c 'pacman -Qq "\$reversal_package"' "$work/repo/bin/hyprchroma-uninstall")" "1,1,0"

H=$work/home
stage() {
  rm -rf "$H"; mkdir -p "$H/.config/omarchy/hooks/theme-set.d" "$H/.config/omarchy/hooks/font-set.d" \
    "$H/.local/state/hyprchroma" "$H/.local/share/hyprchroma"
  cp "$REPO/share/hooks/hyprchroma" "$H/.config/omarchy/hooks/theme-set.d/hyprchroma"
  cp "$REPO/share/hooks/hyprchroma" "$H/.config/omarchy/hooks/font-set.d/hyprchroma"
  printf '#!/bin/sh\necho mine\n' > "$H/.config/omarchy/hooks/theme-set.d/someone-else"
  printf '{}' > "$H/.local/state/hyprchroma/settings.json"
}
run() {
  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
    export HOME=$H XDG_RUNTIME_DIR=$work/run
    mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
    printf "$1" | timeout 30 "$work/repo/bin/hyprchroma-uninstall" 2>&1 )
}
calls() { cat "$work/calls" 2>/dev/null | paste -sd';'; }
count_left() {
  find "$H/.config/omarchy/hooks" -name hyprchroma | wc -l
}

stage; rm -f "$work/calls"
out=$(run '\n\n\n\n\n\n')
chk "return at the restore step puts theming back, from the snapshot" "$(calls)" "restore --captured"
chk "holding return removes nothing" \
  "$(count_left),$([[ -f $H/.local/state/hyprchroma/settings.json ]] && echo kept)" "2,kept"
chk "it says up front that every step asks, and nothing is downloaded" \
  "$(grep -c 'Each step says' <<<"$out"),$(grep -c 'Nothing is downloaded' <<<"$out")" "1,1"
chk "it lists what it found" "$(grep -c 'Theme hooks             2 of 2' <<<"$out")" "1"
chk "the restore step names what it puts back" \
  "$(grep -c 'stylesheets in your browser and Thunderbird profiles' <<<"$out")" "1"
chk "return at the restore step means 1" \
  "$(grep -c 'Choice (1, 2 or 3) \[1\]' "$U"),$(grep -c 'case ${choice:-1} in' "$U")" "1,1"
chk "a skipped step says so" "$(grep -c 'Skipped' <<<"$out")" "2"
chk "and the panel is left alone when it is not in this home" \
  "$(grep -c 'Not installed in your Omarchy plugins' <<<"$out")" "1"

stage; rm -f "$work/calls"
out=$(run '1\n\n\n\n')
chk "1 puts things back from the snapshot" "$(calls)" "restore --captured"
stage; rm -f "$work/calls"
out=$(run '2\n\n\n\n')
chk "2 puts back Omarchy's defaults" "$(calls)" "restore --stock"

stage; rm -f "$work/calls"
# 3: leave theming as it is. y: remove the hooks. y: delete settings.
out=$(run '3\ny\ny\n\n')
chk "deleting the settings after leaving theming still puts it back first" \
  "$(calls),$(grep -c 'step 2 was skipped' <<<"$out")" "restore --captured,1"
chk "yes removes exactly our two hooks, and no other" \
  "$(count_left),$([[ -f $H/.config/omarchy/hooks/theme-set.d/someone-else ]] && echo kept)" "0,kept"
chk "yes deletes the settings and snapshots" \
  "$([[ -e $H/.local/state/hyprchroma || -e $H/.local/share/hyprchroma ]] && echo left || echo gone)" "gone"
chk "steps are numbered as they are shown" \
  "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | grep -oE '^[0-9]\. (Put|Remove the theme|Delete|Remove the Omarchroma)' | cut -c1 | paste -sd,)" "1,2,3,4"

stage
printf '#!/bin/sh\nmy own hook\n' > "$H/.config/omarchy/hooks/font-set.d/hyprchroma"
out=$(run '3\ny\n\n\n')
chk "a hook named hyprchroma that is not ours is left" \
  "$([[ -f $H/.config/omarchy/hooks/font-set.d/hyprchroma ]] && echo kept),$(grep -c 'Theme hooks             1 of 2' <<<"$out")" "kept,1"

chk "removing hyprchroma, Reversal or the helpers puts theming back first too" \
  "$(grep -A1 -E 'if ask "(Remove the hyprchroma package|Remove the Reversal icons|Remove them|Delete them)"' "$U" | grep -c '^      ensure_restored$')" "4"
chk "hyprchroma restore runs every part even when one fails" \
  "$(awk '/^  restore\)/,/^    ;;/' "$REPO/bin/hyprchroma" | grep -c '|| exit \$?'),$(awk '/^  restore\)/,/^    ;;/' "$REPO/bin/hyprchroma" | grep -c '|| restore_status=\$?')" "0,3"

# --- icons left pointing at Omarchroma-Icons with no record go back to Yaru --
stage; rm -f "$work/calls"
T=$H/.config/omarchy/themes
stock_slug=$(ls /usr/share/omarchy/themes 2>/dev/null | head -1)
mkdir -p "$T/mine" "$T/$stock_slug" "$H/.local/state/omarchy/current/theme" "$H/.icons/Omarchroma-Icons" "$H/.local/share/icons"
printf 'Omarchroma-Icons\n' > "$T/mine/icons.theme"; printf 'x\n' > "$T/mine/colors.toml"
printf 'Omarchroma-Icons\n' > "$T/$stock_slug/icons.theme"
printf 'Omarchroma-Icons\n' > "$H/.local/state/omarchy/current/theme/icons.theme"
printf 'mine\n' > "$H/.local/state/omarchy/current/theme.name"
ln -s ../../../.icons/Omarchroma-Icons "$H/.local/share/icons/Omarchroma-Icons"
out=$(run '\n\n\n\n\n')
chk "a theme of your own goes back to Yaru" "$(cat "$T/mine/icons.theme"),$([[ -f $T/mine/colors.toml ]] && echo kept)" "Yaru,kept"
chk "an overlay made for a stock theme is removed, so the stock setting applies" \
  "$([[ -n $stock_slug && ! -e $T/$stock_slug ]] && echo gone)" "gone"
chk "the current theme's setting is staged again" "$(cat "$H/.local/state/omarchy/current/theme/icons.theme")" "Yaru"
chk "and the generated icon theme is gone" \
  "$([[ -e $H/.icons/Omarchroma-Icons || -L $H/.local/share/icons/Omarchroma-Icons ]] && echo left || echo gone)" "gone"
chk "it says so" "$(grep -c 'they use Yaru now' <<<"$out")" "1"
