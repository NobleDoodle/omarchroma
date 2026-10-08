#!/usr/bin/env bash
# VS Code and its relatives are listed for restart like any other application.
# Omarchy's theme scripts name them, but only write their settings: an open
# editor keeps the colors it already loaded until it is restarted.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
chk "the editors are never treated as re-themed live, so they are listed for restart" "$(python3 - "$REPO" <<'PY'
import sys, types
st = types.ModuleType("st")
exec(compile(open(sys.argv[1] + "/lib/hyprchroma-state").read().split("if __name__")[0], "st", "exec"), st.__dict__)
st.running_executables = lambda: {"code", "codium", "cursor", "code-insiders", "kitty"}
print(",".join(sorted(st.omarchy_reloaded_executables() & st.OMARCHY_EDITORS)) or "none")
PY
)" "none"
