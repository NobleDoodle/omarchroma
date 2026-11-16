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

# Predictable temporaries, and writers that rolled their own. One documented
# exception: new_work_dir in hyprchroma-setup makes the directory a package
# build runs in -- handed to makepkg and git inside the build sandbox, never
# read or written by this project's own code except to remove it -- so it
# carries none of the risk a homegrown temp writer would: mktemp's own naming
# is already unpredictable and its creation already atomic, which is what
# every other write here achieves a different way. It exists to keep build
# scratch space out of the plugin tree Omarchy's shell watches for changes,
# and it is created under the user's own cache directory, not /tmp -- a first
# version of this used bare mktemp -d, which defaults to /tmp and was caught
# as inconsistent with every other directory this project touches living
# under $HOME. Filtered out by exact text before the sweep, then asserted to
# be the only such line, so a second, undocumented one is still caught.
chk "nothing creates its own temporary, aside from that one exception" \
  "$(code "${ALL[@]}" | grep -v 'work_dir=\$(mktemp -d -p "\$build_cache")' | grep -ohE 'tempfile\.mkstemp|mktemp ' | wc -l)" "0"
chk "and that exception is exactly the one expected line" \
  "$(grep -c 'work_dir=\$(mktemp -d -p "\$build_cache")' bin/hyprchroma-setup)" "1"
chk "and it is not /tmp" \
  "$(grep -c 'build_cache=\"\${XDG_CACHE_HOME:-\$HOME/.cache}/hyprchroma-setup\"' bin/hyprchroma-setup)" "1"
chk "no rename resolves its target by pathname" "$(sweep 'os\.replace\([^,]+, [^,]+\)')" "0"
# shutil.copy* opens its destination by name too, following a symlink there:
# the capture's backup was written that way while this looked only for open().
chk "no truncating open of a fixed path"       "$(sweep 'open\([^)]*, *"w"\)|exec [0-9]+>[^&]|shutil\.(copy|move)')" "0"
chk "the Python helpers create and delete only through a verified descriptor" \
  "$(code lib/hyprchroma-state lib/hyprchroma-dark-reader lib/hyprchroma-palette |
     grep -E '(mkdir|unlink|rmdir)\(' | grep -v 'dir_fd' | grep -vc 'safe_unlink')" "0"

# Command resolution.
chk "no /usr/local in any command path"        "$(sweep '/usr/local/s?bin')" "0"
# environ.get as well as environ[...]: six helper calls built their path from
# os.environ.get("HYPRCHROMA_LIB", ...) while this matched only the bracket form.
chk "no executable location comes from the environment" \
  "$(sweep 'HYPRCHROMA_(LIB|SHARE):-|environ(\[|\.get\().HYPRCHROMA_(LIB|SHARE)')" "0"
# Nor from the home directory. The browser-exit waiter ran its helper out of
# ~/.local/bin, where the pre-package installer left shims: once they were gone
# it failed on every run, silently, and a file anyone as this user could plant
# there would have been run unattended by the daemon.
chk "no helper is run from the home directory" "$(sweep '\.local/bin')" "0"
chk "every shell entry point pins PATH" \
  "$(grep -l 'PATH=$(\(hyprchroma\|omarchroma\)_trusted_path)' \
      bin/hyprchroma bin/hyprchroma-setup lib/sync-gtk-theme lib/sync-qt-kde-theme \
      share/hooks/hyprchroma 2>/dev/null | wc -l)" "5"
chk "every python helper pins PATH" \
  "$(grep -l 'os.environ\["PATH"\] = trusted_path()' \
      lib/hyprchroma-state lib/hyprchroma-dark-reader lib/hyprchroma-palette | wc -l)" "3"

# Privilege. The setup script is the only thing that may ask for any, and
# only through pacman: -S for packages the user was shown and agreed to, and
# -U for a package setup built in its sandbox and then checked -- Reversal,
# Pear Desktop, and hyprchroma itself. No AUR helper
# runs with the ticket any more. Every call site in setup goes through
# run_sudo, not bare sudo -- the only bare sudo lines left are run_sudo's own
# "sudo "$@"", the keep-alive loop's credential refresh, and finish()'s
# "sudo -k" ending the ticket, none of which names a command of its own to
# run, so they are filtered out by exact text rather than trusted to stay
# harmless just because they exist today.
chk "the service itself runs nothing privileged" \
  "$(code bin/hyprchroma lib/* | grep -cE '^[[:space:]]*(sudo|pkexec) ')" "0"
chk "setup's own sudo calls all go through run_sudo, not bare sudo/pkexec" \
  "$(code bin/hyprchroma-setup | grep -E '^[[:space:]]*(sudo|pkexec) ' \
      | grep -vE 'sudo "\$@"|sudo -n true|^  sudo -k 2>/dev/null$' | wc -l)" "0"
chk "and every run_sudo call site either warms the credential or names pacman" \
  "$(code bin/hyprchroma-setup | grep -E '^[[:space:]]*run_sudo ' \
      | grep -vE '^[[:space:]]*run_sudo pacman |^[[:space:]]*run_sudo -v' | wc -l)" "0"
chk "and where it does name a command, that command is pacman" \
  "$(code bin/hyprchroma-setup | grep -ohE '^[[:space:]]*run_sudo [a-z]+' | awk '{print $2}' | sort -u | paste -sd,)" "pacman"
chk "and its package list is literal, not built from input" \
  "$(grep -cE 'missing\+=\((adw-gtk-theme|python-plyvel)\)' bin/hyprchroma-setup)" "2"
chk "pacman is only asked to sync named packages, or install the checked build" \
  "$(code bin/hyprchroma-setup | grep -ohE 'run_sudo pacman -[SU][^"]*' | LC_ALL=C sort -u | paste -sd'|')" \
  'run_sudo pacman -S --needed |run_sudo pacman -S --needed --asdeps -- |run_sudo pacman -U -- |run_sudo pacman -U --needed -- '
chk "...and every -U installs the package that was just checked" \
  "$(code bin/hyprchroma-setup | grep -E 'run_sudo pacman -U' | grep -vc '"\$built_package"')" "0"
chk "...Reversal's name is fixed, and nothing else is built from the AUR" \
  "$(grep -c '^REVERSAL_AUR=reversal-icon-theme-git$' bin/hyprchroma-setup),$(grep -c 'PEAR_AUR\|build_pear' bin/hyprchroma-setup),$(grep 'pear-desktop-bin' bin/hyprchroma-setup | grep -cv '^  note "')" "1,0,0"

# Nothing is fetched outside the build sandbox, and nothing fetched runs
# outside it: Reversal's AUR recipe and its source are fetched by git in the
# sandbox, and every build runs there offline. hyprchroma builds from the
# checkout.
chk "setup has no downloader of its own" "$(code bin/hyprchroma-setup | grep -cE 'curl|wget')" "0"
chk "every networked step is one of Reversal's two downloads, in the sandbox" \
  "$(code bin/hyprchroma-setup | grep -cE 'in_sandbox --net ')" "2"
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
