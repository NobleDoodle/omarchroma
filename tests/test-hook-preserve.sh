#!/usr/bin/env bash
# Safe to run directly as well as through tests/run: never the real XDG
# folders or session bus, whatever the caller's environment holds.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
# The daemon installs its theme-set and font-set hooks as "hyprchroma" at
# every start. A hook an earlier release installed there is replaced as an
# update; anything else is the user's own and is moved into the state folder,
# kept and no longer run, before this one goes in; and something that cannot
# be moved is left exactly where it is.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT/home XDG_RUNTIME_DIR=$ROOT/run DBUS_SESSION_BUS_ADDRESS=unix:path=$ROOT/no-bus
mkdir -p "$HOME"; mkdir -m 700 "$XDG_RUNTIME_DIR"
source tests/lib-omarchy.sh
seed_omarchy_theme
SHIPPED=$REPO/share/hooks/hyprchroma
T=$HOME/.config/omarchy/hooks/theme-set.d/hyprchroma
F=$HOME/.config/omarchy/hooks/font-set.d/hyprchroma
KEPT=$HOME/.local/state/hyprchroma/replaced-hooks
install() { timeout 20 ./bin/hyprchroma install-hooks >"$ROOT/out" 2>"$ROOT/err"; echo $?; }

# --- the list of shipped hooks --------------------------------------------------
chk "this release's hook is in the shipped list, which holds only SHA-256 values" \
  "$(grep -cxF "$(sha256sum "$SHIPPED" | cut -d' ' -f1)" share/hooks/hyprchroma.sha256),$(grep -v '^#' share/hooks/hyprchroma.sha256 | grep -cvE '^[0-9a-f]{64}$')" "1,0"
chk "...and the package installs it beside the hook" \
  "$(grep -c 'install -Dm644 share/hooks/hyprchroma.sha256 $(SHARE)/hooks/hyprchroma.sha256' Makefile)" "1"

# --- none there: installed --------------------------------------------------------
chk "with no hook there, both are installed" \
  "$(install),$(cmp -s "$SHIPPED" "$T" && cmp -s "$SHIPPED" "$F" && echo same)" "0,same"

# --- an earlier release's hook: replaced as an update ------------------------------
old=$(git log --format=%H -- share/hooks/hyprchroma | while read -r c; do
        git show "$c:share/hooks/hyprchroma" | cmp -s - "$SHIPPED" || { echo "$c"; break; }; done)
if [[ -n $old ]]; then
  git show "$old:share/hooks/hyprchroma" > "$T"
  chk "(the earlier hook is one the list knows)" "$(grep -cxF "$(sha256sum "$T" | cut -d' ' -f1)" share/hooks/hyprchroma.sha256)" "1"
  chk "an earlier release's hook is replaced, and nothing is kept of it" \
    "$(install),$(cmp -s "$SHIPPED" "$T" && echo same),$(ls "$KEPT" 2>/dev/null | wc -l)" "0,same,0"
else
  echo "  SKIP no earlier hook in this checkout's history"
fi

# --- the user's own: kept, never run, and said so -----------------------------------
printf '#!/usr/bin/env bash\necho my own theme hook\n' > "$T"; chmod 755 "$T"
rc=$(install)
kept=$(ls "$KEPT" 2>/dev/null | grep '^theme-set-' | head -1)
chk "a hook of the user's own is moved into the state folder, and this one installed" \
  "$rc,$(cmp -s "$SHIPPED" "$T" && echo same),$(cat "$KEPT/$kept" 2>/dev/null)" "0,same,$(printf '#!/usr/bin/env bash\necho my own theme hook')"
chk "...readable by the user only, out of every hooks folder, and said so" \
  "$(stat -c %a "$KEPT/$kept" 2>/dev/null),$(find "$HOME/.config/omarchy/hooks" -type f | grep -vc '/hyprchroma$'),$(grep -c 'your own theme-set hook named hyprchroma was moved' "$ROOT/err")" "600,0,1"

# --- a symlink: kept as a note of where it pointed ------------------------------------
rm -f "$F"; ln -s /usr/bin/true "$F"
rc=$(install)
chk "a symlink is replaced by the hook, with where it pointed kept" \
  "$rc,$([[ -L $F ]] && echo link || echo file),$(cat "$KEPT"/font-set-* 2>/dev/null)" "0,file,symlink to /usr/bin/true"

# --- a FIFO: left alone, at once ------------------------------------------------------
rm -f "$T"; mkfifo "$T"
started=$SECONDS; rc=$(install)
chk "a FIFO is left exactly where it is, and nothing is installed in its place" \
  "$rc,$([[ -p $T ]] && echo fifo),$(grep -c 'left .* as it is; it is not a hook hyprchroma installed' "$ROOT/err")" "0,fifo,1"
chk "...without waiting on it" "$(( SECONDS - started < 10 ))" "1"
chk "...while the other hook is still kept current" "$(cmp -s "$SHIPPED" "$F" && echo same)" "same"
