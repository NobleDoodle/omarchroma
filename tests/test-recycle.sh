#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
REPO=$REPO
ROOT=$(mktemp -d); export HOME=$ROOT XDG_STATE_HOME=$ROOT/state
mkdir -p "$XDG_STATE_HOME/omarchy/current"
# theme.name mtime = "last theme switch"; set it well in the past.
touch -d '2 hours ago' "$XDG_STATE_HOME/omarchy/current/theme.name"

python3 - "$REPO" <<'E'
import importlib.util, sys, time, types
spec = importlib.util.spec_from_loader("st", loader=None)
st = types.ModuleType("st")
src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''), "st", "exec"), st.__dict__)

now = int(time.time())
started_30m_ago = now - 1800          # after the theme switch, before now
theme_time = st.theme_switched_at()
print(f"  theme switched at : {now - theme_time}s ago")
print(f"  app started       : {now - started_30m_ago}s ago (after that switch)")

# The exact comparison refresh_idle_apps makes.
def stale(newer_than): return not (started_30m_ago >= newer_than)

print()
print("  event-driven run (baseline = theme switch):")
print(f"    recycled? {stale(theme_time)}   <- was the bug: nothing recycled")
print("  forced run (baseline = now, minus launch grace):")
print(f"    recycled? {stale(now - st.LAUNCH_GRACE_SECONDS)}")

just_launched = now - 2
print()
print(f"  app launched {now - just_launched}s ago, still windowless:")
print(f"    recycled on a forced run? {not (just_launched >= now - st.LAUNCH_GRACE_SECONDS)}"
      f"   <- grace protects it")
E
rm -rf "$ROOT"
