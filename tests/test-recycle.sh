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
def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

theme_time = st.theme_switched_at()

# refresh_idle_apps asks whether an application started before the palette it
# is drawing was written. Which baseline it compares against decides the answer.
def stale(newer_than): return not (started_30m_ago >= newer_than)

# An app started after the last theme switch is not stale by that measure, so
# an event-driven run leaves it alone -- correct, it already has the palette.
chk("started after the theme switch is not recycled on an event run",
    stale(theme_time), False)

# A forced run rewrites the palette now, so anything older than this moment is
# holding the previous one and has to go.
chk("the same app is recycled on a forced run",
    stale(now - st.LAUNCH_GRACE_SECONDS), True)

# Except something launched a second ago, which has not had time to show a
# window yet and must not be mistaken for an idle leftover.
just_launched = now - 2
chk("an app launched moments ago is protected by the grace period",
    not (just_launched >= now - st.LAUNCH_GRACE_SECONDS), False)
E
rm -rf "$ROOT"
