#!/usr/bin/env bash
# Safe to run directly as well as through tests/run: never the real XDG
# folders or session bus, whatever the caller's environment holds.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
# Regression cover for the three findings remediated in 1.11.0:
#   1. the sync lock was opened with a truncating, symlink-following redirect
#   2. writes made the temporary name exclusive but resolved the destination
#      directory and the final rename by pathname
#   3. the pinned PATH carried /usr/local/{bin,sbin} unvalidated
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
count(){ grep -rhoE "$1" "${@:2}" 2>/dev/null | wc -l; }
# Comments in these files quote the old, unsafe constructs to explain why they
# went; assertions about code must not match that prose.
code(){ sed -e 's/[[:space:]]*#.*//' -e 's#^[[:space:]]*//.*##' "$@"; }
countcode(){ local pat=$1; shift; code "$@" | grep -ohE "$pat" | wc -l; }

# --- 1. the lock -----------------------------------------------------------
chk "sync never opens the lock for writing" \
  "$(countcode 'exec 9>' bin/hyprchroma)" "0"
chk "sync opens the lock read-only" "$(count 'exec 9<' bin/hyprchroma)" "1"
chk "sync has the helper create the lock first" \
  "$(count 'prepare-lock --path' bin/hyprchroma)" "1"

D=$(mktemp -d "${XDG_RUNTIME_DIR:-$HOME}/safeio-XXXXXX")
trap 'rm -rf "$D"' EXIT
printf 'PRECIOUS\n' > "$D/target"
ln -s "$D/target" "$D/planted.lock"
python3 lib/hyprchroma-state prepare-lock --path "$D/planted.lock" 2>/dev/null
chk "planted lock symlink is replaced" "$([ -L "$D/planted.lock" ] && echo link || echo regular)" "regular"
chk "the symlink's target is not truncated" "$(cat "$D/target")" "PRECIOUS"
chk "lock is private" "$(stat -c%a "$D/planted.lock")" "600"

# --- 2. destination identity ----------------------------------------------
chk "no rename resolves its destination by bare pathname" \
  "$(countcode 'os\.replace\([^,]+, [^,]+\)' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "0"
chk "every rename is relative to a descriptor" \
  "$(count 'src_dir_fd=descriptor, dst_dir_fd=descriptor' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
chk "temporaries are created relative to a descriptor" \
  "$(count 'O_EXCL \| os\.O_NOFOLLOW' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
chk "directories are walked with O_NOFOLLOW" \
  "$(count 'flags \| os\.O_NOFOLLOW' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "4"
chk "tempfile.mkstemp is gone from both helpers" \
  "$(count 'mkstemp' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "0"

chk "the safe-io core is identical in both helpers" "$(python3 - <<'PY'
import pathlib
def core(n):
    s = pathlib.Path(n).read_text()
    return s[s.index("# ------"):s.index("def prepare_lock")]
print("same" if core("lib/hyprchroma-state") == core("lib/hyprchroma-dark-reader") else "drifted")
PY
)" "same"

chk "a destination that is a symlink is replaced, not followed" "$(python3 - "$D" <<'PY'
import subprocess, sys, pathlib
d = pathlib.Path(sys.argv[1])
(d / "bystander").write_text("UNTOUCHED")
link = d / "dest"
link.symlink_to(d / "bystander")
subprocess.run(["python3", "lib/hyprchroma-state", "write-file", "--path", str(link)],
               input=b"new", check=True)
print("intact" if (d / "bystander").read_text() == "UNTOUCHED" else "clobbered")
PY
)" "intact"

chk "a foreign-owned ancestor is refused" "$(python3 - <<'PY'
import subprocess
# /proc is root-owned and not ours; a write below it must be refused outright
# rather than attempted.
r = subprocess.run(["python3", "lib/hyprchroma-state", "write-file",
                    "--path", "/proc/hyprchroma-probe/x"],
                   input=b"x", capture_output=True)
print("refused" if r.returncode != 0 else "allowed")
PY
)" "refused"

# --- 3. PATH ---------------------------------------------------------------
# /usr/local/share/themes is a place GTK looks for a theme, not a place a
# command is resolved from; the concern was PATH, so the check is scoped to it.
chk "no /usr/local in any command-resolution path" \
  "$(countcode '/usr/local/s?bin' bin/hyprchroma lib/hyprchroma-state lib/hyprchroma-dark-reader \
       lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma)" "0"
chk "shell entry points validate their PATH" \
  "$(grep -l 'hyprchroma_trusted_path' bin/hyprchroma lib/sync-gtk-theme \
       lib/sync-qt-kde-theme share/hooks/hyprchroma | wc -l)" "4"
chk "python helpers validate their PATH" \
  "$(count 'def trusted_path' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
chk "the validator demands root ownership" \
  "$(count 'owner == 0' bin/hyprchroma)" "1"
chk "the validator rejects group- and world-writable" \
  "$(count '8#022' bin/hyprchroma)" "1"
chk "a user-owned directory is rejected by the validator" "$(
  source <(sed -n '/^hyprchroma_trusted_path/,/^}/p' bin/hyprchroma)
  mine=$(mktemp -d "$HOME/pathprobe-XXXXXX"); chmod 755 "$mine"
  f=$(declare -f hyprchroma_trusted_path | sed "s#/usr/bin /usr/share/omarchy/bin#$mine#")
  eval "$f"; out=$(hyprchroma_trusted_path); rmdir "$mine"
  [[ $out == *"$mine"* ]] && echo accepted || echo rejected)" "rejected"

# --- 4. the same defect on a second directory list -------------------------
# XDG_DATA_DIRS is inherited too, and the Exec= it leads to was run unattended.
chk "service files are read through the verified reader" \
  "$(countcode 'safe_read\(root' lib/hyprchroma-state)" "1"
chk "an Exec= binary is checked before it is run" \
  "$(countcode 'trusted_executable\(candidate\)' lib/hyprchroma-state)" "1"
# Two "!= 0" remain in trusted_executable, for the binary and its parents;
# the PATH check now spells it "not in (0, _OVERFLOW_UID)" so an unmapped
# owner under systemd's sandboxing is accepted too.
chk "root ownership is demanded of the binary and its parents" \
  "$(countcode 'st_uid != 0' lib/hyprchroma-state)" "2"
chk "the PATH check accepts an unmapped owner" \
  "$(countcode 'st_uid not in \(0, _OVERFLOW_UID\)' lib/hyprchroma-state)" "1"
chk "a binary this account can write is refused" "$(python3 - <<'PY'
import os, pathlib
ns = {}
exec(compile(open("lib/hyprchroma-state").read().split("if __name__")[0], "s", "exec"), ns)
mine = pathlib.Path(os.environ["HOME"]) / ".hyprchroma-exec-probe"
mine.write_text("#!/bin/sh\n"); mine.chmod(0o755)
verdict = "refused" if not ns["trusted_executable"](str(mine)) else "allowed"
mine.unlink()
print(verdict)
PY
)" "refused"
chk "a root-owned system binary is still allowed" "$(python3 - <<'PY'
ns = {}
exec(compile(open("lib/hyprchroma-state").read().split("if __name__")[0], "s", "exec"), ns)
print("allowed" if ns["trusted_executable"]("/usr/bin/env") else "refused")
PY
)" "allowed"

# --- 6. the instances the first pass missed --------------------------------
chk "no lock is opened for writing anywhere" \
  "$(countcode 'open\([^)]*\.lock", "w"\)' lib/hyprchroma-state)" "0"
# Ten: the definition, the subcommand that exposes it, the four watcher
# locks that now go through it, the sync lock a browsers waiter takes, the
# same lock for the Thunderbird waiter, try_lock, through which the daemon
# takes the sync lock and asks whether a waiter is alive, and the
# color-scheme lock a detached re-send holds.
chk "every watcher lock is prepared first" \
  "$(countcode 'prepare_lock\(' lib/hyprchroma-state)" "10"
# Scoped to bin/ only before, which is why a fifth copy sat in the Qt/KDE
# generator writing kdeglobals by pathname and went unnoticed for a release.
chk "no generator embeds a writer of its own" \
  "$(countcode 'tempfile\.mkstemp\(|os\.replace\(temporary' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "0"
# Seventeen: fifteen in bin/hyprchroma (nine embedded Python writers, the
# theme hook, a captured palette, the Pear stylesheet, the browsers' palette,
# the Thunderbird palette, and the last-stale-notify record, and the three
# writers added for Additional Apps: the saved switch state, the removed-row
# list, and the restore), one in the GTK generator, a write-files request for
# both its stylesheets when they change, and one in the Qt/KDE generator, the
# write-files request carrying the color scheme, the Omarchroma icon theme's
# index and directory keeper, and kdeglobals.
chk "every generator write goes through the helper" \
  "$(countcode 'write-file", "--path"|hyprchroma-state" write-file|HELPER, "write-files"' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme)" "17"
# Nine: settings on a toggle, status, the Dark Reader theme, the Pear config,
# the removed-framework list, the restart mode, and the three Additional Apps
# writes (saved switches, the removed row, and the restore).
chk "sync's embedded writers call the helper" \
  "$(countcode 'write-file", "--path"' bin/hyprchroma)" "9"

# --- write-files: several files in one start ----------
# The same atomic_write per file as write-file, and a request that is wrong in
# any part writes nothing at all.
wf=$(mktemp -d); trap 'rm -rf "$wf"' EXIT
H=$PWD/lib/hyprchroma-state
mkdir -p "$wf/a" "$wf/b"; echo outside > "$wf/victim"; ln -s "$wf/victim" "$wf/b/linked"
printf '%s\0' "$wf/a/one" 644 "first" "$wf/b/two" 4755 "second" "$wf/b/linked" 600 "third" "$wf/a/empty" "" "" | "$H" write-files
chk "write-files writes each file it is given" \
  "$(cat "$wf/a/one"),$(cat "$wf/b/two"),$(cat "$wf/b/linked"),$(stat -c %s "$wf/a/empty")" "first,second,third,0"
chk "...modes masked to the permission bits, as write-file does" "$(stat -c %a "$wf/b/two")" "755"
chk "...and a link in the way is replaced, not written through" \
  "$([[ -L $wf/b/linked ]] && echo link || echo file),$(cat "$wf/victim")" "file,outside"
for bad in "relative-path|$wf/a/x 644 x rel 644 y" "bad-mode|$wf/a/x 644 x $wf/a/y 9z9 y" "short|$wf/a/x 644 x $wf/a/y 644"; do
  label=${bad%%|*}; read -r -a fields <<<"${bad#*|}"
  "$H" write-files < <(printf '%s\0' "${fields[@]}") 2>/dev/null; rc=$?
  chk "a request with a $label writes nothing" "$rc,$([[ -e $wf/a/x ]] && echo written || echo nothing)" "1,nothing"
done
chk "the generators use it, once each" \
  "$(grep -c 'hyprchroma-state" write-files$' lib/sync-gtk-theme),$(grep -c '\[HELPER, "write-files"\]' lib/sync-qt-kde-theme)" "1,1"
