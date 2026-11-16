#!/usr/bin/env bash
# Safe to run directly as well as through tests/run: never the real XDG
# folders or session bus, whatever the caller's environment holds.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
# The panel reads files other programs running as this user can write --
# status.json, settings.json, Icons' status, Omarchy's theme name and colors --
# inside the desktop shell, which every panel and the bar share. None is
# loaded whole: a watcher that never loads says when one changed, and head
# reads at most a cap of it, under a time limit, in a process of its own.
# Checked on the source, then for real: CappedFile is taken from Panel.qml
# as it stands and run in an offscreen Quickshell.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
P=$REPO/Panel.qml

chk "no FileView in the panel loads a file: the reader's watcher and the binary's are watch-only" \
  "$(grep -c 'FileView {' "$P"),$(grep -c 'preload: false' "$P"),$(grep -c 'text()' "$P")" "2,2,0"
chk "every state and theme file is read through CappedFile" \
  "$(for id in themeNameFile themeColorsFile manifestFile iconsStatusFile settingsFile statusFile; do grep -B1 "id: $id\$" "$P" | grep -q 'CappedFile {' && printf 1 || printf 0; done)" "111111"
chk "...which reads with head, capped and under a time limit, on a fixed PATH" \
  "$(awk '/component CappedFile/,/^  }$/' "$P" | grep -cE '"/usr/bin/timeout", "-k", "1", "5", "/usr/bin/head", "-c", String\(capped.limit \+ 1\)|PATH: "/usr/bin"')" "2"

QS=$(command -v qs || true)
if [[ -z $QS ]]; then echo "  SKIP the offscreen run: no qs"; exit 0; fi
ROOT=$(mktemp -d); trap 'pkill -P $$ 2>/dev/null; rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/cfg" "$ROOT/run" "$ROOT/a"; chmod 700 "$ROOT/run"
{
  printf 'import QtQuick\nimport Quickshell\nimport Quickshell.Io\nScope {\n  id: root\n'
  awk '/^  component CappedFile: Item \{/,/^  }$/' "$P"
  cat <<EOF
  CappedFile {
    id: probe; path: "$ROOT/a/status.json"; limit: 100
    onLoaded: (text) => console.warn("READ " + JSON.stringify(text))
    onLoadFailed: console.warn("REFUSED")
  }
  Timer { interval: 1500; repeat: true; running: true; onTriggered: probe.reload() }
}
EOF
} > "$ROOT/cfg/shell.qml"
( cd "$ROOT" && env -i PATH=/usr/bin LANG=C.UTF-8 HOME="$ROOT" XDG_RUNTIME_DIR="$ROOT/run" QT_QPA_PLATFORM=offscreen \
    QT_FORCE_STDERR_LOGGING=1 timeout 30 "$QS" -p "$ROOT/cfg" >"$ROOT/log" 2>&1 ) &
next() { sleep "$1"; grep -oE 'READ .*|REFUSED' "$ROOT/log" | tail -1; }
sleep 3
printf '{"n":1}\n' > "$ROOT/a/tmp"; mv "$ROOT/a/tmp" "$ROOT/a/status.json"
chk "a file in a folder made later is read once it appears" "$(next 3)" 'READ "{\"n\":1}\n"'
printf '{"n":2,"é":1}\n' > "$ROOT/a/tmp"; mv "$ROOT/a/tmp" "$ROOT/a/status.json"
chk "...and again when it is replaced, UTF-8 and all" "$(next 2)" 'READ "{\"n\":2,\"é\":1}\n"'
head -c 5000 /dev/zero | tr '\0' x > "$ROOT/a/tmp"; mv "$ROOT/a/tmp" "$ROOT/a/status.json"
chk "a file over the cap is refused, never handed to the panel" "$(next 2)" "REFUSED"
rm "$ROOT/a/status.json"; mkfifo "$ROOT/a/status.json"
# The panel asks again every couple of seconds while a file has not loaded.
# Each read is one head under one timeout (two processes for pgrep -f), ended
# by its time limit -- so however long the FIFO stays, they never pile up.
most=0
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  n=$(pgrep -fc -- "head -c 101 -- $ROOT/a/status.json" || true)
  (( n > most )) && most=$n
done
chk "a FIFO in its place is refused, and reads of it never pile up" \
  "$(grep -oE 'READ .*|REFUSED' "$ROOT/log" | tail -1),$(( most <= 2 ))" "REFUSED,1"
rm "$ROOT/a/status.json"; printf '{"n":3}\n' > "$ROOT/a/status.json"
chk "...and the file is read again once it is a file" "$(next 3)" 'READ "{\"n\":3}\n"'
