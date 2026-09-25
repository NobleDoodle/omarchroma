#!/usr/bin/env bash
# Standing check that previously-closed security fixes are still in place.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
count(){ grep -hoE "$1" "${@:2}" 2>/dev/null | wc -l; }

# Six checks were removed here, not because the properties stopped
# mattering, but because each only asked "does this function still
# exist" -- and a behavioral suite elsewhere already exercises the same
# function and would fail, with a clearer message, the moment it broke:
#   capped reads            -> test-capped
#   extension id validation -> test-extid
#   rival-claimant refusal  -> test-extid
#   notification sanitising -> test-winname
#   target_enabled's // fix -> test-enabled
#   backups exclude our own output -> test-capture, test-kdestrip
# Kept here are only the checks nothing else would catch.


chk "PATH validated in every shell entry point" \
  "$(grep -l 'PATH=$(hyprchroma_trusted_path)' bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma 2>/dev/null | wc -l)" "4"
chk "PATH validated in both python helpers" \
  "$(grep -l 'os.environ\["PATH"\] = trusted_path()' lib/hyprchroma-state lib/hyprchroma-dark-reader | wc -l)" "2"

chk "no predictable .tmp writers remain" \
  "$(count 'with_suffix\("\.tmp"\)|hyprchroma-tmp' lib/hyprchroma-state lib/hyprchroma-dark-reader bin/hyprchroma lib/sync-qt-kde-theme)" "0"
# One writer per helper: atomic_write_at does the work, and atomic_write, for a
# path, only opens the verified parent and hands it over. One rename apiece
# means no second writer has grown up beside it.
chk "atomic_write_at is the writer, once per helper" \
  "$(count 'def atomic_write_at\(' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
chk "...atomic_write only delegates to it" \
  "$(count 'def atomic_write\(' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
chk "...and it holds the only rename in either helper" \
  "$(count 'os\.replace\(' lib/hyprchroma-state lib/hyprchroma-dark-reader)" "2"
# Shell no longer creates temporaries of its own at all: every write it makes
# goes through the state helper, which does it under a verified descriptor.
chk "no shell script creates its own temporary" \
  "$(count 'mktemp' bin/hyprchroma lib/sync-qt-kde-theme lib/sync-gtk-theme)" "0"
chk "shell writes route through the audited helper" \
  "$(count 'hyprchroma-state\" write-file' bin/hyprchroma lib/sync-qt-kde-theme lib/sync-gtk-theme)" "8"

chk "restore_file no longer uses copy2" "$(count 'shutil\.copy2\(snapshot_dir' lib/hyprchroma-state)" "0"
chk "privileged block reads with O_NOFOLLOW" "$(count 'read_text\(\)' install.sh)" "0"
chk "no shell=True / eval / os.system" \
  "$(grep -rhoE 'shell=True|os\.system|\beval\b' bin/ lib/ install.sh uninstall.sh 2>/dev/null | wc -l)" "0"
