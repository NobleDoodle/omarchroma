#!/usr/bin/env bash
# How this behaves where it does not belong. The daemon is for Omarchy; on a
# system without it the only correct outcome is to say so and change nothing.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
countcode(){ local pat=$1; shift; code "$@" | grep -ohE "$pat" | wc -l; }

STAGE=$(mktemp -d "$HOME/portability-XXXXXX"); trap 'rm -rf "$STAGE"' EXIT
make install DESTDIR="$STAGE/root" >/dev/null 2>&1
H="$STAGE/home"; mkdir -p "$H/.config" "$H/.local/state" "$H/.local/share"

# No palette readable: whether omarchy is missing entirely or installed with no
# theme set, there is nothing to follow and nothing should be written.
out=$(timeout 20 systemd-run --user --collect --wait --pipe \
  --property=TemporaryFileSystem=/usr/share/omarchy \
  --property=RestartPreventExitStatus=78 \
  --setenv=HOME="$H" --setenv=XDG_CONFIG_HOME="$H/.config" \
  --setenv=XDG_STATE_HOME="$H/.local/state" --setenv=XDG_DATA_HOME="$H/.local/share" \
  "$STAGE/root/usr/bin/hyprchroma" daemon 2>&1)
chk "refuses with EX_CONFIG when no palette can be read" \
  "$(grep -oE 'status=78/CONFIG' <<<"$out" | head -1)" "status=78/CONFIG"
# Two shapes, both correct: "no palette" when nothing can provide one, and
# "no usable <key>" when a source is present but cannot answer.
chk "says why, in words" \
  "$(grep -cE 'no palette|no usable' <<<"$out" | head -1)" "1"
chk "writes nothing into a home that has no Omarchy" \
  "$(find "$H/.config" -mindepth 1 2>/dev/null | wc -l)" "0"
chk "the refusal happens before any hook directory is made" \
  "$([ -d "$H/.config/omarchy" ] && echo made || echo none)" "none"

# The guard asks the resolver for a real color: Omarchy is one source among
# others now, and a binary that exists but cannot produce a color is not a
# working source either way.
# Three: the daemon's guard, the message it prints on failure, and the
# top-level check the sync path makes.
chk "the guard asks the resolver for a color" \
  "$(countcode 'hyprchroma-palette" background' bin/hyprchroma)" "3"
chk "no hard requirement on omarchy remains" \
  "$(countcode 'command -v omarchy .*\|\| fail' bin/hyprchroma)" "0"

# --- the unit must survive Hyprland not being up yet -----------------------
# watch-events returns 0 when there is no event stream, which is the ordinary
# case at login; on-failure would leave the daemon stopped for the session.
unit=packaging/systemd/hyprchromad.service
chk "unit restarts on a clean exit" "$(grep -c '^Restart=always' $unit)" "1"
chk "unit does not use Restart=on-failure" "$(grep -c '^Restart=on-failure' $unit)" "0"
chk "unit does not restart into a missing Omarchy" \
  "$(grep -c '^RestartPreventExitStatus=78' $unit)" "1"

# --- the requirement is stated where someone would look --------------------
chk "PKGBUILD names omarchy" "$(grep -c 'omarchy: first-class' packaging/PKGBUILD)" "1"
chk "README documents a palette file for non-Omarchy systems" "$(grep -c 'palette --template' README.md)" "1"

# --- no promises of a fallback that no longer exists -----------------------
# Nothing runs a fallback timer; the daemon's own sync covers that gap.
# Only claims that one exists; the comments explaining its absence are fine.
chk "nothing still claims a fallback timer exists" \
  "$(grep -rhoE "(service's|a) fallback timer" bin/ lib/ packaging/ README.md 2>/dev/null \
     | grep -v 'no fallback timer' | wc -l)" "0"

# --- the CLI the bar widget depends on -------------------------------------
# The panel and the setup script call these. They are interface, not
# implementation: renaming one breaks the widget. Pinned so that is deliberate.
# Each is a case label in the dispatch; --version carries an alias, so the
# match allows one.
for sub in framework stale-apps palette restore --version; do
  chk "the CLI still dispatches: $sub" \
    "$(grep -cE "^  ${sub}[|)]" bin/hyprchroma)" "1"
done
for action in list remove restore; do
  chk "framework still takes: $action" \
    "$(grep -cE "^      (list|remove\\|restore)\\)" bin/hyprchroma)" "2"
done
chk "hyprchroma-dark-reader still answers --info" \
  "$(grep -c '"--info"' lib/hyprchroma-dark-reader | awk '{print ($1>0)?1:0}')" "1"
