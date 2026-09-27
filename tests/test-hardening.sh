#!/usr/bin/env bash
# Cover for defects that were live rather than hypothetical: an environment
# variable that chose which executables the daemon ran, the same variable
# planting an Omarchy hook, an unbounded write mode, and an unlink that took
# any path. Each was found by attacking the built package, not by reading it,
# so several of these run the attack rather than grepping for its fix.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
countcode(){ local pat=$1; shift; code "$@" | grep -ohE "$pat" | wc -l; }

# --- 1. the layout must not be selectable from the environment -------------
# HYPRCHROMA_LIB chose which executables ran; a line in ~/.config/environment.d
# is read by systemd --user at login, so it was code execution on a variable.
chk "no environment override for the helper directory" \
  "$(countcode 'HYPRCHROMA_LIB:-|HYPRCHROMA_SHARE:-' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "0"
chk "the layout is derived from the binary's own path" \
  "$(countcode 'realpath -- "\$\{BASH_SOURCE\[0\]\}"' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "3"

STAGE=$(mktemp -d "$HOME/hardening-XXXXXX"); trap 'rm -rf "$STAGE"' EXIT
make install DESTDIR="$STAGE/root" >/dev/null 2>&1
EVIL="$STAGE/evil"; mkdir -p "$EVIL/hooks"
printf '#!/bin/sh\ntouch "%s/RAN"\nexit 0\n' "$EVIL" > "$EVIL/hyprchroma-state"
printf '#!/bin/sh\necho PAYLOAD\n' > "$EVIL/hooks/hyprchroma"
chmod +x "$EVIL/hyprchroma-state" "$EVIL/hooks/hyprchroma"
H="$STAGE/home"; mkdir -p "$H/.config" "$H/.local/state" "$H/.local/share"

HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
  XDG_DATA_HOME="$H/.local/share" HYPRCHROMA_LIB="$EVIL" HYPRCHROMA_SHARE="$EVIL" \
  "$STAGE/root/usr/bin/hyprchroma" stale-apps >/dev/null 2>&1
chk "a planted helper directory is not executed" \
  "$([ -e "$EVIL/RAN" ] && echo executed || echo ignored)" "ignored"

HOME="$H" XDG_CONFIG_HOME="$H/.config" HYPRCHROMA_SHARE="$EVIL" \
  "$STAGE/root/usr/bin/hyprchroma" install-hooks >/dev/null 2>&1
chk "a planted hook source is not installed" \
  "$(grep -c PAYLOAD "$H/.config/omarchy/hooks/theme-set.d/hyprchroma" 2>/dev/null | head -1)" "0"
chk "the real hook is installed instead" \
  "$([ -x "$H/.config/omarchy/hooks/theme-set.d/hyprchroma" ] && echo yes || echo no)" "yes"

# --- 2. the write primitive is bounded -------------------------------------
printf 'x' | ./lib/hyprchroma-state write-file --path "$STAGE/m" --mode 4755 2>/dev/null
chk "write-file cannot set setuid" "$(stat -c%a "$STAGE/m" 2>/dev/null)" "755"
printf 'x' | ./lib/hyprchroma-state write-file --path "$STAGE/m2" --mode 2755 2>/dev/null
chk "write-file cannot set setgid" "$(stat -c%a "$STAGE/m2" 2>/dev/null)" "755"
chk "the mask is in the source, not just the result" \
  "$(countcode '& 0o777' lib/hyprchroma-state)" "1"

# --- 3. the unlink primitive is confined -----------------------------------
mkfifo "$STAGE/victim.fifo"
./lib/hyprchroma-state prepare-lock --path "$STAGE/victim.fifo" >/dev/null 2>&1
chk "prepare-lock will not unlink a non-lock path" \
  "$([ -p "$STAGE/victim.fifo" ] && echo kept || echo removed)" "kept"
ln -s "$STAGE/victim.fifo" "$STAGE/real.lock"
./lib/hyprchroma-state prepare-lock --path "$STAGE/real.lock" >/dev/null 2>&1
chk "a planted symlink at a real lock is still replaced" \
  "$([ -L "$STAGE/real.lock" ] && echo link || echo regular)" "regular"

# --- 4. the hook is written through the verified writer --------------------
chk "install_hooks does not use mkdir plus install" \
  "$(countcode 'mkdir -p -- "\$directory"|install -m 755 "\$source"' bin/hyprchroma)" "0"
# Five: the hook, the Pear stylesheet, a captured palette, the browsers'
# palette, and the last-stale-notify record a --notify run leaves behind to
# dedupe against.
chk "every write in the entry point routes through the state helper" \
  "$(countcode 'hyprchroma-state" write-file' bin/hyprchroma)" "5"

# --- 5. an unmapped owner is trusted, and PATH never comes back empty ------
# Under systemd's sandboxing /usr reports the overflow uid, not root. Rejecting
# it left the daemon with an empty PATH and no command resolved at all.
# One definition, plus the PATH check and the directory check that use it.
chk "the directory and PATH checks accept an unmapped owner" \
  "$(countcode '_OVERFLOW_UID' lib/hyprchroma-state)" "3"
chk "an empty PATH falls back to fixed identities" \
  "$(countcode 'if keep else ":".join\(PATH_CANDIDATES\)' lib/hyprchroma-state)" "1"
chk "the shell check accepts it too" \
  "$(countcode 'overflowuid' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma)" "4"

# --- 6. the unit is hardened, and only in ways that were tested ------------
unit=packaging/systemd/hyprchromad.service
for directive in NoNewPrivileges RestrictSUIDSGID RestrictRealtime RestrictNamespaces \
                 RestrictAddressFamilies SystemCallArchitectures SystemCallFilter \
                 LockPersonality; do
  chk "unit sets $directive" "$(grep -c "^$directive=" $unit)" "1"
done
# These break it: it writes $HOME, and it reads other processes to know which
# applications still hold the previous theme.
chk "unit does not set ProtectHome" "$(grep -c '^ProtectHome=' $unit)" "0"
chk "unit does not set ProtectProc" "$(grep -c '^ProtectProc=' $unit)" "0"
chk "unit does not set ProtectSystem" "$(grep -c '^ProtectSystem=' $unit)" "0"
# And so does anything that needs a mount namespace. A user's service manager
# can only make one inside a user namespace of the service's own, and from
# there no other process's executable or memory map can be read: the daemon
# counted every window as still on the previous theme, and could not see which
# browsers were open. PrivateTmp and six others like it shipped that way.
chk "unit sets nothing that needs a mount namespace" \
  "$(grep -cE '^(Private(Tmp|Devices|Mounts|Users|IPC|PIDs)|Protect(KernelTunables|KernelModules|KernelLogs|ControlGroups|Hostname|Clock)|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|ExecPaths|NoExecPaths|TemporaryFileSystem|Bind(ReadOnly)?Paths|MountAPIVFS|RootDirectory|RootImage)=' $unit)" "0"
# The claim itself, run: a probe under exactly the unit's settings reads a
# process started outside it, as the daemon must. Needs the real user manager,
# which tests/run hands over for this alone.
bus=${HYPRCHROMA_TEST_SESSION_BUS:-${DBUS_SESSION_BUS_ADDRESS:-}}
if [[ -n $bus ]] && command -v systemd-run >/dev/null; then
  props=()
  while IFS= read -r line; do props+=(--property="$line"); done < <(
    sed -n '/^\[Service\]/,/^\[/p' $unit |
      grep -E '^[A-Za-z]+=' | grep -vE '^(Type|ExecStart|Restart|RestartSec|RestartPreventExitStatus)=')
  sleep 30 & outside=$!
  # Until it has exec'd, the child is still this shell.
  for _ in {1..40}; do
    program=$(readlink /proc/$outside/exe); [[ $program == */sleep ]] && break; sleep 0.05
  done
  probe=$(DBUS_SESSION_BUS_ADDRESS=$bus timeout 20 systemd-run --user --collect --wait --pipe --quiet \
    "${props[@]}" /usr/bin/bash -c \
    "readlink /proc/self/ns/user; readlink /proc/$outside/exe; head -c1 /proc/$outside/maps >/dev/null && echo maps" 2>&1)
  kill "$outside" 2>/dev/null; wait "$outside" 2>/dev/null
  chk "under the unit's settings the daemon shares the session's user namespace" \
    "$(sed -n 1p <<<"$probe")" "$(readlink /proc/self/ns/user)"
  chk "...reads which program another of the user's processes runs" \
    "$(sed -n 2p <<<"$probe")" "$program"
  chk "...and its memory map, which is how KDE applications are recognized" \
    "$(sed -n 3p <<<"$probe")" "maps"
else
  echo "  SKIP the unit probe: no user service manager to run it under"
fi

# --- 7. the daemon does what its comment claims ----------------------------
chk "the daemon syncs before it watches" \
  "$(countcode '"\$HYPRCHROMA_SELF" --quiet' bin/hyprchroma)" "1"
