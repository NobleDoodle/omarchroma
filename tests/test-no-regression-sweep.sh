#!/usr/bin/env bash
# A sweep for the defect classes this project has actually had, run across the
# whole tree rather than the files that had them. Every earlier assertion was
# scoped to where the bug was found, and twice that let the same defect sit
# undetected somewhere else: a fifth embedded writer in the Qt/KDE generator,
# and an environment override that reintroduced arbitrary code execution after
# the PATH work had closed it.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

# Comments quote the old, unsafe constructs to explain why they went, so the
# sweep must read code only. Shell and Python both comment with "#".
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
ALL=(bin/hyprchroma bin/hyprchroma-setup lib/hyprchroma-state lib/hyprchroma-dark-reader
     lib/hyprchroma-palette lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma)
sweep(){ code "${ALL[@]}" | grep -ohE "$1" | wc -l; }

# Predictable temporaries, and writers that rolled their own.
chk "nothing creates its own temporary"        "$(sweep 'tempfile\.mkstemp|mktemp ')" "0"
chk "no rename resolves its target by pathname" "$(sweep 'os\.replace\([^,]+, [^,]+\)')" "0"
chk "no truncating open of a fixed path"       "$(sweep 'open\([^)]*, *"w"\)|exec [0-9]+>[^&]')" "0"

# Command resolution.
chk "no /usr/local in any command path"        "$(sweep '/usr/local/s?bin')" "0"
chk "no executable location comes from the environment" \
  "$(sweep 'HYPRCHROMA_(LIB|SHARE):-|environ\[.HYPRCHROMA_(LIB|SHARE).\]')" "0"
chk "every shell entry point pins PATH" \
  "$(grep -l 'PATH=$(\(hyprchroma\|omarchroma\)_trusted_path)' \
      bin/hyprchroma bin/hyprchroma-setup lib/sync-gtk-theme lib/sync-qt-kde-theme \
      share/hooks/hyprchroma 2>/dev/null | wc -l)" "5"
chk "every python helper pins PATH" \
  "$(grep -l 'os.environ\["PATH"\] = trusted_path()' \
      lib/hyprchroma-state lib/hyprchroma-dark-reader lib/hyprchroma-palette | wc -l)" "3"

# Privilege. The setup script is the only thing that may ask for any: a
# direct sudo pacman for two named packages the user was shown and agreed to,
# and one indirect path -- omarchy pkg aur add, which asks pacman the same
# way any other AUR install does -- for Pear Desktop, a third-party
# application, never for hyprchroma itself (see test-dependency.sh).
chk "the service itself runs nothing privileged" \
  "$(code bin/hyprchroma lib/* | grep -cE '^[[:space:]]*(sudo|pkexec) ')" "0"
chk "setup's only direct privileged call is pacman" \
  "$(code bin/hyprchroma-setup | grep -ohE '^[[:space:]]*(sudo|pkexec) [a-z]+' | awk '{print $2}' | sort -u | paste -sd,)" "pacman"
chk "and its package list is literal, not built from input" \
  "$(grep -cE 'missing\+=\((adw-gtk-theme|python-plyvel)\)' bin/hyprchroma-setup)" "2"
chk "the one indirect privileged call names a literal package too" \
  "$(grep -c 'pkg aur add pear-desktop-bin' bin/hyprchroma-setup)" "2"

# Nothing is fetched and then executed: the build runs on the checkout.
chk "setup downloads nothing to run" "$(code bin/hyprchroma-setup | grep -cE 'curl|wget|git clone')" "0"
chk "it builds from its own location" \
  "$(grep -c 'realpath -- "\${BASH_SOURCE\[0\]}"' bin/hyprchroma-setup)" "1"

# The writer of record.
chk "one implementation of atomic_write, shared verbatim" "$(python3 - <<'PY'
import pathlib
def core(n):
    s = pathlib.Path(n).read_text()
    return s[s.index("# ------"):s.index("def prepare_lock")]
a, b = core("lib/hyprchroma-state"), core("lib/hyprchroma-dark-reader")
print("same" if a == b else "drifted")
PY
)" "same"
