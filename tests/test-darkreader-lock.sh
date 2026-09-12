#!/usr/bin/env bash
# apply_theme checked browser_running() before opening the browser's
# extension-settings database, then opened it unguarded. That check is not
# atomic with the open: the browser can grab the database's own lock in the
# gap between them, or browser_running()'s process-name match can simply miss
# it, and the open then raised plyvel.IOError -- an unhandled traceback in the
# daemon's log on every sync, instead of the same deferred outcome the check
# was there to produce.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail

python3 -c "import plyvel" 2>/dev/null || { echo "  SKIP (python-plyvel not installed)"; exit 0; }

python3 - "$REPO" <<'E'
import importlib.util, sys, types, json, tempfile, shutil
from pathlib import Path

src = open(sys.argv[1] + "/lib/hyprchroma-dark-reader").read()
dr = types.ModuleType("dr")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "dr", "exec"), dr.__dict__)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

root = Path(tempfile.mkdtemp())
try:
    profile = root / "profile"
    database = profile / "Sync Extension Settings" / ("a" * 32)
    database.mkdir(parents=True)

    # Held open by this same process for the whole test, exactly like a live
    # browser holding its own extension-settings database open.
    import plyvel
    holder = plyvel.DB(str(database), create_if_missing=True)

    dr.browser_info = lambda: {
        "supported": True, "name": "Test Browser", "desktop": "test.desktop",
        "family": "chromium", "executables": ["definitely-not-running"],
        "config": str(profile),
    }
    dr.active_profile = lambda info: profile
    dr.chromium_extension_id = lambda profile: "a" * 32

    theme_file = root / "theme.json"
    theme_file.write_text(json.dumps({"stylesheet": ""}))
    status_file = root / "status.json"

    # browser_running() sees no matching process name, so this reaches the
    # open the way a name-detection miss or a genuine race would.
    try:
        result = dr.apply_theme(theme_file, None, status_file)
        raised = None
    except Exception as error:  # noqa: BLE001 -- the failure mode itself
        result, raised = None, error
    chk("does not raise on a locked database", raised, None)
    chk("returns the same deferred code as the upfront check", result, 2)

    status = json.loads(status_file.read_text())
    chk("status records the same deferred outcome as the upfront check",
        status.get("darkReader"), "pending-browser-exit")

    holder.close()
finally:
    shutil.rmtree(root, ignore_errors=True)
E
