#!/usr/bin/env bash
# quit_application used to fire an application's own --quit, wait 1.5s, and if
# that did not work, fire the generic action and return regardless -- so a
# quit that GApplication itself documents as taking up to ten seconds was
# reported as done immediately. A version of an app whose fast path never
# actually reaches g_application_quit() then gets logged as recycled while
# still running, and a window reopened in that gap lands on the stale
# instance instead of a fresh one.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 - "$REPO" <<'E'
import importlib.util, sys, time, types

src = open(sys.argv[1] + "/lib/hyprchroma-state").read()
st = types.ModuleType("st")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "st", "exec"), st.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# Both waits are shortened for the test; the logic under test is "wait until
# gone, up to a bound" -- the bound's exact length is not what is being
# checked here.
st.QUIT_GRACE_SECONDS = 0.2
st.QUIT_ACTION_TIMEOUT_SECONDS = 0.4
st.GNOME_NAMESPACE = "test."

st.bus_call = lambda *a, **k: None
st.subprocess.run = lambda *a, **k: None

# -- the app's own --quit works, inside the fast grace period --------------
gone_at = time.monotonic() + 0.05
st.name_has_owner = lambda name: time.monotonic() < gone_at
st.service_file_exec = lambda name: "/usr/bin/test-app"
chk("fast --quit reported as success once the name actually drops",
    st.quit_application("test.App", "/test/App"), True)

# -- the fast path never lands; the fallback action does, later ------------
gone_at = time.monotonic() + 0.3
st.name_has_owner = lambda name: time.monotonic() < gone_at
chk("a slow fallback within its own timeout still counts as success",
    st.quit_application("test.App", "/test/App"), True)

# -- neither path ever releases the name ------------------------------------
st.name_has_owner = lambda name: True
chk("still owning the name after both budgets is reported as failure",
    st.quit_application("test.App", "/test/App"), False)

# -- a non-GNOME name skips the --quit flag and goes straight to the action -
calls = []
st.service_file_exec = lambda name: (_ for _ in ()).throw(
    AssertionError("service_file_exec should not be consulted outside org.gnome."))
gone_at = time.monotonic() + 0.05
st.name_has_owner = lambda name: time.monotonic() < gone_at
chk("a non-GNOME name never has a --quit flag guessed at it",
    st.quit_application("io.other.App", "/io/other/App"), True)

# -- refresh_idle_apps only reports what quit_application actually confirmed
import contextlib, io
st.bus_names = lambda method: {"test.Stale", "test.Kept"}
st.connection_pid = lambda name: {"test.Stale": 111, "test.Kept": 222}[name]
st.process_started_at = lambda pid: 0
st.open_windows = lambda: []
st.has_quit_action = lambda name, path: True
st.quit_application = lambda name, path: name == "test.Stale"
out = io.StringIO()
with contextlib.redirect_stdout(out):
    st.refresh_idle_apps(since=10**9)
text = out.getvalue()
chk("a confirmed quit is reported as closed",
    "closed idle test.Stale" in text, True)
chk("an unconfirmed quit is reported as not done, not as closed",
    "test.Kept did not quit" in text and "closed idle test.Kept" not in text, True)
E
