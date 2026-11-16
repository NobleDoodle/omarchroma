#!/usr/bin/env bash
# Setup's AUR builds, run for real.
#
# Setup builds Reversal itself: the AUR recipe at a pinned commit (and
# PKGBUILD hash), the icons' source at a pinned commit, built offline in a
# bubblewrap sandbox with no new privileges, then the package checked before
# pacman -U. This runs setup's real --reversal path against a fake AUR
# repository and a fake upstream -- plain git repositories on disk, reached
# by file:// only here -- with real git, bwrap and makepkg, and sudo and the
# final pacman replaced by a log. Every attack below must stop before pacman.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

for tool in bwrap makepkg git bsdtar fakeroot; do
  command -v "$tool" >/dev/null || { echo "  FAIL $tool is needed to run this suite"; exit 0; }
done
if ! bwrap --ro-bind / / --unshare-all --new-session -- /usr/bin/true 2>/dev/null; then
  echo "  FAIL bubblewrap cannot start a sandbox here (unprivileged user namespaces?)"
  exit 0
fi

T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
FAKE=$T/remote
G=(git -c init.defaultBranch=master -c user.name=t -c user.email=t@example.invalid
   -c advice.detachedHead=false)
mkdir -p "$FAKE"

# --- the fake upstream --------------------------------------------------------
# Commit A is "the one reviewed". It also carries probe.sh, which the fake
# recipe's build() runs: everything it prints is what code inside the build
# can see and do. Commit B, the head, is upstream gone bad: its install.sh
# also writes a sudoers file into the package.
up=$T/up-work
"${G[@]}" init -q "$up"
cat >"$up/install.sh" <<'EOF'
#!/bin/bash
set -e
d=$1/usr/share/icons
mkdir -p "$d/Reversal/apps" "$d/Reversal-dark"
printf '[Icon Theme]\nName=Reversal\n' >"$d/Reversal/index.theme"
printf '[Icon Theme]\nName=Reversal-dark\n' >"$d/Reversal-dark/index.theme"
ln -s ../Reversal/apps "$d/Reversal-dark/apps"
ln -s ./index.theme "$d/Reversal/same.theme"
# Upstream's own install.sh writes one absolute link into the build directory.
ln -s "$d/Reversal/index.theme" "$d/Reversal/apps/absolute"
EOF
cat >"$up/probe.sh" <<EOF
#!/bin/bash
echo "PROBE nnp=\$(awk '/^NoNewPrivs/{print \$2}' /proc/self/status)"
echo "PROBE sudo-blocked=\$(sudo -n true 2>&1 | grep -c 'no new privileges')"
if (exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null; then echo "PROBE net=yes"; else echo "PROBE net=no"; fi
[ -e '$HOME/probe-secret' ] && echo "PROBE home=visible" || echo "PROBE home=hidden"
echo "PROBE run=\$(ls -A /run | wc -l)"
echo "PROBE ssh=\${SSH_AUTH_SOCK:-unset}"
echo "PROBE stdin=\$(readlink /proc/self/fd/0)"
touch '$T/probe/bin/planted' 2>/dev/null && echo "PROBE checkout=writable" || echo "PROBE checkout=readonly"
touch '$T/outside' 2>/dev/null || true
EOF
chmod +x "$up/install.sh" "$up/probe.sh"
"${G[@]}" -C "$up" add -A && "${G[@]}" -C "$up" commit -qm reviewed
SRC_A=$("${G[@]}" -C "$up" rev-parse HEAD)
printf 'mkdir -p "$1/etc/sudoers.d"; echo "ALL ALL=(ALL) NOPASSWD: ALL" >"$1/etc/sudoers.d/evil"\n' >>"$up/install.sh"
"${G[@]}" -C "$up" commit -qam "gone bad"
SRC_B=$("${G[@]}" -C "$up" rev-parse HEAD)
"${G[@]}" clone -q --bare "$up" "$FAKE/Reversal-icon-theme.git"

# --- the fake AUR -------------------------------------------------------------
# P1 is the reviewed recipe. P3 and P4 are recipes that pass the pins (they
# are pinned in their cases) but make a package that must still be refused:
# one with a file outside the icon folders, one with an install script. P2,
# the head, is the AUR gone bad.
aur=$T/aur-work
"${G[@]}" init -q "$aur"
recipe() {
  cat <<EOF
pkgname=reversal-icon-theme-git
_gitname=Reversal-icon-theme
pkgver=r1.0000000
pkgrel=1
pkgdesc="fake Reversal for the test"
arch=('any')
makedepends=('git')
license=('GPL3')
source=("git+file://$FAKE/Reversal-icon-theme.git")
sha256sums=('SKIP')
$1
pkgver() {
  cd "\${srcdir}/\${_gitname}"
  printf "r%s.%s" "\$(git rev-list --count HEAD)" "\$(git rev-parse --short HEAD)"
}
build() {
  cd "\${srcdir}/\${_gitname}"
  ./probe.sh
}
package() {
  cd "\${srcdir}/\${_gitname}"
  ./install.sh "\${pkgdir}"
  $2
}
EOF
}
aur_commit() { # PKGBUILD-text message -> sets c and s
  printf '%s\n' "$1" >"$aur/PKGBUILD"
  "${G[@]}" -C "$aur" add -A && "${G[@]}" -C "$aur" commit -qm "$2"
  c=$("${G[@]}" -C "$aur" rev-parse HEAD); s=$(sha256sum <"$aur/PKGBUILD"); s=${s%% *}
}
aur_commit "$(recipe '' '')" reviewed;                              AUR_P1=$c SUM_P1=$s
aur_commit "$(recipe '' 'install -Dm755 /dev/null "$pkgdir/usr/bin/evil"')" extra; AUR_P3=$c SUM_P3=$s
printf 'post_install() { :; }\n' >"$aur/evil.install"
aur_commit "$(recipe "install=evil.install" '')" script;            AUR_P4=$c SUM_P4=$s
rm "$aur/evil.install"
aur_commit "$(recipe '' 'install -Dm644 /dev/null "$pkgdir/etc/sudoers.d/aur"')" "gone bad"; AUR_P2=$c
"${G[@]}" clone -q --bare "$aur" "$FAKE/aur.git"

# --- setup, pointed at them ---------------------------------------------------
# Only the pins, the URLs and the transport change (file:// instead of
# https, and the fake remotes visible read-only inside the sandbox so git can
# reach them). sudo and pacman -U are a log, and pacman -U keeps the package
# it was given so its contents can be read afterwards.
probe=$T/probe
mkdir -p "$probe/bin" "$probe/keep"
cp -r "$REPO/lib" "$REPO/packaging" "$REPO/WHATSNEW.md" "$probe/"
make_setup() { # aur-commit pkgbuild-sum source-commit
  sed -e "s|^REVERSAL_AUR_URL=.*|REVERSAL_AUR_URL=file://$FAKE/aur.git|" \
      -e "s|^REVERSAL_AUR_COMMIT=.*|REVERSAL_AUR_COMMIT=$1|" \
      -e "s|^REVERSAL_PKGBUILD_SHA256=.*|REVERSAL_PKGBUILD_SHA256=$2|" \
      -e "s|^REVERSAL_SOURCE_URL=.*|REVERSAL_SOURCE_URL=file://$FAKE/Reversal-icon-theme.git|" \
      -e "s|^REVERSAL_SOURCE_COMMIT=.*|REVERSAL_SOURCE_COMMIT=$3|" \
      -e 's|protocol.https.allow=always|protocol.file.allow=always|' \
      -e "s|--ro-bind \"\$here\" \"\$here\" --bind|--ro-bind \"\$here\" \"\$here\" --ro-bind $FAKE $FAKE --bind|" \
      -e 's|pacman -Qq "$REVERSAL_AUR"|false|' \
      -e 's|if pacman -Qq "$package" &>/dev/null; then|if false; then|' \
      -e 's|^  sudo "\$@" && start_sudo_keepalive$|  printf "STUB-SUDO %s\\n" "$*"; [[ $1 == pacman \&\& $2 == -U ]] \&\& cp -- "${@: -1}" "'"$probe/keep/"'"; return 0|' \
      "$REPO/bin/hyprchroma-setup" >"$probe/bin/hyprchroma-setup"
  chmod +x "$probe/bin/hyprchroma-setup"
}
run_setup() {
  rm -rf "$probe/keep"/* "$T/outside"
  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
    export SSH_AUTH_SOCK=$T/agent.sock
    printf 'y\n\n' | timeout 300 "$probe/bin/hyprchroma-setup" --reversal 2>&1 ) |
    sed 's/\x1b\[[0-9;]*m//g'
}
mkdir -p "$HOME"; : >"$HOME/probe-secret"
pacman_calls() { grep -c '^STUB-SUDO pacman -U' <<<"$out"; }

make_setup "$AUR_P1" "$SUM_P1" "$SRC_A"
grep -q "REVERSAL_AUR_COMMIT=$AUR_P1" "$probe/bin/hyprchroma-setup" &&
  grep -q "file://$FAKE/aur.git" "$probe/bin/hyprchroma-setup" &&
  grep -q 'STUB-SUDO' "$probe/bin/hyprchroma-setup" &&
  grep -q -- "--ro-bind $FAKE $FAKE" "$probe/bin/hyprchroma-setup"
substituted=$?
chk "the probe copy of setup took every substitution" "$substituted" "0"
# A copy that did not take them would reach the real AUR, sudo and pacman, so
# then none of the runs below happen.
if (( substituted == 0 )); then

# --- 1. both heads gone bad; the pins still build what was reviewed -----------
out=$(run_setup)
chk "the reviewed recipe and source are built, though both heads moved" \
  "$(grep -c '^Recipe: AUR commit' <<<"$out"),$(grep -c '^Source: commit' <<<"$out"),$(grep -c '^Checked: only Reversal and Reversal-dark' <<<"$out")" "1,1,1"
chk "...and only then handed to pacman -U" "$(pacman_calls)" "1"
pkg=$(ls "$probe/keep"/*.pkg.tar.* 2>/dev/null | head -1)
chk "the package is the reviewed commit's" \
  "$(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null | grep -c "^pkgver = r1\.${SRC_A:0:7}")" "1"
chk "...with nothing from either bad head in it" \
  "$(bsdtar -tf "$pkg" 2>/dev/null | grep -cE '^(etc|usr/bin)/')" "0"
chk "the password is asked for before anything is downloaded" \
  "$(awk '/^STUB-SUDO -v/{a=NR} /^Downloading the AUR recipe/{b=NR} END{print (a && b && a < b) ? "first" : "after"}' <<<"$out")" "first"
chk "the build directory is gone afterwards" \
  "$(ls -A "$HOME/.cache/hyprchroma-setup" 2>/dev/null | wc -l)" "0"

# What the build itself can do.
chk "the build runs with no new privileges" "$(grep -c '^PROBE nnp=1$' <<<"$out")" "1"
chk "...so sudo -n inside it is refused for that reason" "$(grep -c '^PROBE sudo-blocked=1$' <<<"$out")" "1"
chk "the build has no network" "$(grep -c '^PROBE net=no$' <<<"$out")" "1"
chk "the build cannot see the home folder" "$(grep -c '^PROBE home=hidden$' <<<"$out")" "1"
chk "...nor anything in /run (session bus, sockets)" "$(grep -c '^PROBE run=0$' <<<"$out")" "1"
chk "...nor the caller's environment" "$(grep -c '^PROBE ssh=unset$' <<<"$out")" "1"
chk "...nor the terminal's input" "$(grep -c '^PROBE stdin=/dev/null$' <<<"$out")" "1"
chk "the checkout is read-only to it" \
  "$(grep -c '^PROBE checkout=readonly$' <<<"$out"),$([[ -e $probe/bin/planted ]] && echo planted || echo clean)" "1,clean"
chk "what it writes outside its build directory never reaches the system" \
  "$([[ -e $T/outside ]] && echo reached || echo contained)" "contained"

# --- 2. the reviewed AUR commit is gone ----------------------------------------
make_setup 0123456789abcdef0123456789abcdef01234567 "$SUM_P1" "$SRC_A"
out=$(run_setup)
chk "a missing AUR commit stops it before the source is downloaded" \
  "$(grep -c 'The AUR recipe no longer has the version reviewed' <<<"$out"),$(grep -c "Downloading the icons' source" <<<"$out"),$(pacman_calls)" "1,0,0"

# --- 3. the pinned commit's PKGBUILD does not hash as recorded -----------------
make_setup "$AUR_P1" 0000000000000000000000000000000000000000000000000000000000000000 "$SRC_A"
out=$(run_setup)
chk "a PKGBUILD that does not match its hash is not built" \
  "$(grep -c 'The AUR recipe no longer has the version reviewed' <<<"$out"),$(grep -c '^Building the package' <<<"$out"),$(pacman_calls)" "1,0,0"

# --- 4. the reviewed upstream commit is gone ------------------------------------
make_setup "$AUR_P1" "$SUM_P1" fedcba9876543210fedcba9876543210fedcba98
out=$(run_setup)
chk "a missing upstream commit stops it before the build" \
  "$(grep -c 'could not be downloaded at the reviewed commit' <<<"$out"),$(grep -c '^Building the package' <<<"$out"),$(pacman_calls)" "1,0,0"

# --- 5. a pinned recipe whose package reaches outside the icon folders ----------
make_setup "$AUR_P3" "$SUM_P3" "$SRC_A"
out=$(run_setup)
chk "a package with a path outside the two icon folders is refused" \
  "$(grep -c 'usr/bin/evil: outside' <<<"$out"),$(grep -c 'holds more than the two icon folders' <<<"$out"),$(pacman_calls)" "1,1,0"

# --- 6. a pinned recipe whose package has an install script ---------------------
make_setup "$AUR_P4" "$SUM_P4" "$SRC_A"
out=$(run_setup)
chk "a package with an install script is refused" \
  "$(grep -c '\.INSTALL: an install script' <<<"$out"),$(pacman_calls)" "1,0"

# --- 7. the AUR head itself is never what is built -------------------------------
make_setup "$AUR_P2" "$SUM_P1" "$SRC_A"
out=$(run_setup)
chk "pinning the bad head with the reviewed hash is refused too" \
  "$(grep -c 'The AUR recipe no longer has the version reviewed' <<<"$out"),$(pacman_calls)" "1,0"

fi

# --- the package check, entry by entry ------------------------------------------
# Packages made directly from an mtree description, so owners, modes and
# types can be anything a hostile build could produce.
C=$REPO/packaging/check-package
pk=$T/pk
mkdir -p "$pk"
printf 'pkgname = reversal-icon-theme-git\npkgbase = reversal-icon-theme-git\npkgver = r9.%s-1\narch = any\n' "${SRC_A:0:8}" >"$pk/PKGINFO"
printf 'x\n' >"$pk/file"
make_pkg() { # name extra-mtree-lines...
  local name=$1; shift
  { echo '#mtree'
    echo "./.PKGINFO type=file mode=644 uid=0 gid=0 contents=$pk/PKGINFO"
    echo './usr type=dir mode=755 uid=0 gid=0'
    echo './usr/share type=dir mode=755 uid=0 gid=0'
    echo './usr/share/icons type=dir mode=755 uid=0 gid=0'
    echo './usr/share/icons/Reversal type=dir mode=755 uid=0 gid=0'
    echo "./usr/share/icons/Reversal/index.theme type=file mode=644 uid=0 gid=0 contents=$pk/file"
    printf '%s\n' "$@"
  } >"$pk/$name.mtree"
  bsdtar --zstd -cf "$pk/$name.pkg.tar.zst" "@$pk/$name.mtree" ||
    echo "  FAIL the $name test package could not be made"
}
verdict() { # name -> accepted / refused
  if "$C" "$pk/$1.pkg.tar.zst" --name reversal-icon-theme-git --commit "$SRC_A" \
       --root usr/share/icons/Reversal --root usr/share/icons/Reversal-dark >/dev/null; then
    echo accepted
  else
    echo refused
  fi
}
make_pkg plain
chk "a plain package is accepted" "$(verdict plain)" "accepted"
make_pkg setuid "./usr/share/icons/Reversal/x type=file mode=4755 uid=0 gid=0 contents=$pk/file"
chk "a setuid file is refused" "$(verdict setuid)" "refused"
make_pkg writable "./usr/share/icons/Reversal/x type=file mode=666 uid=0 gid=0 contents=$pk/file"
chk "a file writable by others is refused" "$(verdict writable)" "refused"
make_pkg owner "./usr/share/icons/Reversal/x type=file mode=644 uid=1000 gid=1000 contents=$pk/file"
chk "a file not owned by root is refused" "$(verdict owner)" "refused"
make_pkg device "./usr/share/icons/Reversal/x type=char mode=644 uid=0 gid=0 device=native,1,3"
chk "a device node is refused" "$(verdict device)" "refused"
make_pkg fifo "./usr/share/icons/Reversal/x type=fifo mode=644 uid=0 gid=0"
chk "a FIFO is refused" "$(verdict fifo)" "refused"
make_pkg climb "./usr/share/icons/Reversal/x type=link mode=777 uid=0 gid=0 link=../../../../etc/shadow"
chk "a link that climbs out is refused" "$(verdict climb)" "refused"
make_pkg absolute "./usr/share/icons/Reversal/x type=link mode=777 uid=0 gid=0 link=/etc/shadow"
chk "an absolute link is refused" "$(verdict absolute)" "refused"
make_pkg midway "./usr/share/icons/Reversal/x type=link mode=777 uid=0 gid=0 link=apps/../../../../../etc"
chk "a link with .. after its first name is refused" "$(verdict midway)" "refused"
make_pkg through "./usr/share/icons/Reversal/d type=link mode=777 uid=0 gid=0 link=." \
                 "./usr/share/icons/Reversal/d/x type=file mode=644 uid=0 gid=0 contents=$pk/file"
chk "an entry under the package's own link is refused" "$(verdict through)" "refused"
make_pkg sudoers './etc type=dir mode=755 uid=0 gid=0' './etc/sudoers.d type=dir mode=750 uid=0 gid=0' \
                 "./etc/sudoers.d/evil type=file mode=440 uid=0 gid=0 contents=$pk/file"
chk "a sudoers file is refused" "$(verdict sudoers)" "refused"
make_pkg hook "./.INSTALL type=file mode=644 uid=0 gid=0 contents=$pk/file"
chk "an install script is refused" "$(verdict hook)" "refused"
printf 'backup = etc/x\n' >>"$pk/PKGINFO"; make_pkg backup
chk "metadata beyond the plain keys is refused" "$(verdict backup)" "refused"
printf 'pkgname = reversal-icon-theme-git\npkgver = r9.0000000-1\n' >"$pk/PKGINFO"; make_pkg version
chk "a version not built from the pinned commit is refused" "$(verdict version)" "refused"
printf 'pkgname = something-else\npkgver = r9.%s-1\n' "${SRC_A:0:8}" >"$pk/PKGINFO"; make_pkg name
chk "another package's name is refused" "$(verdict name)" "refused"
# A hard link cannot be described in mtree; this one is a real one.
printf 'pkgname = reversal-icon-theme-git\npkgver = r9.%s-1\n' "${SRC_A:0:8}" >"$pk/PKGINFO"
mkdir -p "$pk/tree/usr/share/icons/Reversal" && cp "$pk/PKGINFO" "$pk/tree/.PKGINFO"
printf 'x\n' >"$pk/tree/usr/share/icons/Reversal/a"; ln "$pk/tree/usr/share/icons/Reversal/a" "$pk/tree/usr/share/icons/Reversal/b"
bsdtar --zstd --uid 0 --gid 0 -cf "$pk/hard.pkg.tar.zst" -C "$pk/tree" .PKGINFO usr
chk "a hard link is refused" "$(verdict hard)" "refused"
chk "...and the same tree without it is accepted" \
  "$(rm "$pk/tree/usr/share/icons/Reversal/b"; bsdtar --zstd --uid 0 --gid 0 -cf "$pk/soft.pkg.tar.zst" -C "$pk/tree" .PKGINFO usr; verdict soft)" "accepted"
# There is no mode that checks the name alone: an install script is refused
# whatever the package is called.
printf 'pkgname = pear-desktop-bin\npkgver = 1-1\n' >"$pk/PKGINFO"
printf 'post_install() { echo hello; }\n' >"$pk/script"
make_pkg pear "./.INSTALL type=file mode=644 uid=0 gid=0 contents=$pk/script"
"$C" "$pk/pear.pkg.tar.zst" --name pear-desktop-bin --any-content >/dev/null 2>&1; any=$?
"$C" "$pk/pear.pkg.tar.zst" --name pear-desktop-bin >/dev/null 2>&1; named=$?
chk "an install script is refused for any package name, and --any-content no longer exists" \
  "$named,$any,$(grep -c 'any.content' "$REPO/packaging/check-package")" "1,2,0"

# --- what setup is made of --------------------------------------------------------
S=$REPO/bin/hyprchroma-setup
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
chk "no AUR helper is used any more" "$(code "$S" | grep -cE 'pkg aur add|yay |paru ')" "0"
chk "makepkg runs only inside the sandbox, or with no new privileges" \
  "$(code "$S" | grep -E '(^|[^-])makepkg ' | grep -vE 'in_sandbox .*makepkg|setpriv --no-new-privs -- makepkg' | wc -l)" "0"
chk "makepkg never installs (-i) or syncs dependencies (-s) itself" \
  "$(code "$S" | grep -E 'makepkg ' | grep -cE ' -[a-zA-Z]*[si]')" "0"
chk "every git command runs in the sandbox" \
  "$(code "$S" | grep -E '(^|[[:space:]])git ' | grep -vc 'SANDBOX_GIT=(git ')" "0"
chk "the sandbox has no new privileges, no network and its own session" \
  "$(sed -n '/^in_sandbox()/,/^}/p' "$S" | grep -c -- '--unshare-all "${share\[@\]}" --new-session --die-with-parent --cap-drop ALL')" "1"
chk "...with /home, /run and /tmp hidden" \
  "$(sed -n '/^in_sandbox()/,/^}/p' "$S" | grep -c -- '--tmpfs /tmp --tmpfs /var/tmp --tmpfs /run "${hide\[@\]}"')" "1"
chk "the ticket is ended when setup exits" \
  "$(sed -n '/^finish()/,/^}/p' "$S" | grep -c '^  sudo -k'),$(grep -c '^trap finish EXIT$' "$S")" "1,1"
chk "both pins are full commit hashes" \
  "$(grep -cE '^REVERSAL_(AUR|SOURCE)_COMMIT=[0-9a-f]{40}$' "$S")" "2"
chk "Reversal is installed only after it is built and checked" \
  "$(grep -c 'elif build_reversal && install_built "$REVERSAL_AUR"; then' "$S")" "1"
chk "hyprchroma itself: built in the sandbox, checked, then pacman -U" \
  "$(awk '/shown in_sandbox "\$work_dir" "\$here\/packaging" makepkg/{a=NR} /check_built --name hyprchroma/{b=NR} /^run_sudo pacman -U --needed -- "\$built_package"/{c=NR} END{print (a && b && c && a < b && b < c) ? "in order" : "out of order"}' "$S")" "in order"
