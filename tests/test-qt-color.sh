#!/usr/bin/env bash
# Qt 6.12 adds a QtQuick type named Color, which shadows the qs.Commons Color
# singleton: a bare `Color.muted` evaluates to undefined and the panel draws
# in black. The QML reaches the singleton through the module alias instead.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

for f in *.qml; do
  chk "$f: no bare Color." "$(grep -cE '(^|[^A-Za-z0-9_.])Color\.' "$f")" "0"
  if grep -q 'Commons\.Color\.' "$f"; then
    chk "$f: imports qs.Commons as Commons" "$(grep -cx 'import qs.Commons as Commons' "$f")" "1"
  fi
done
