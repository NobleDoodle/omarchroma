#!/usr/bin/env bash
# Two writes took their destination from a file anything able to write the
# state directory could change -- not a privilege boundary for this account,
# but one for anything less trusted that can write there, a sandboxed app with
# access to ~/.local/state among them.
#
# The capture wrote each backup with shutil.copy2, which opened it by name and
# followed a symlink planted in its place: the user's config, copied over
# whatever the link pointed at. And the Dark Reader restore opened whatever
# database the snapshot named and wrote whatever keys it listed, so an edited
# snapshot could rewrite any extension's storage this account owns. These run
# each attack for real rather than checking the fix is still spelled the same.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); export HOME=$ROOT
S=$ROOT/state
mkdir -p "$S/original/files" "$HOME/.config/gtk-3.0"

# -- a symlink planted where the capture writes its backup -------------------
printf 'user rule\n' > "$HOME/.config/gtk-3.0/gtk.css"
printf 'canary\n' > "$HOME/canary"
ln -s "$HOME/canary" "$S/original/files/gtk3_css"
"$REPO/lib/hyprchroma-state" --state-dir "$S" --data-dir "$ROOT/data" snapshot --target gtk >/dev/null 2>&1
chk "a symlink planted at the backup path does not redirect the capture" \
  "$(cat "$HOME/canary")" "canary"
chk "...the link is replaced by a real file" \
  "$([[ -f $S/original/files/gtk3_css && ! -L $S/original/files/gtk3_css ]] && echo file)" "file"
chk "...holding the user's config" "$(cat "$S/original/files/gtk3_css")" "user rule"
rm -rf "$ROOT"

python3 -c "import plyvel" 2>/dev/null || { echo "  SKIP (python-plyvel not installed)"; exit 0; }

# -- an edited Dark Reader snapshot ------------------------------------------
python3 - "$REPO" <<'E'
import json, os, sys, tempfile, types
from pathlib import Path
import plyvel

home = Path(tempfile.mkdtemp())
os.environ["HOME"] = str(home)
src = open(sys.argv[1] + "/lib/hyprchroma-dark-reader").read()
dr = types.ModuleType("dr")
exec(compile(src.replace('if __name__ == "__main__":\n    raise SystemExit(main())', ''),
             "dr", "exec"), dr.__dict__)
# Whatever runs on this machine is not the point here.
dr.browser_running = lambda executables: False

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}"
          + ("" if got == want else f": got [{got}] want [{want}]"))

# A real profile layout, so the destination is derived the way it is live.
config = home / ".config/chromium"
profile = config / "Default"
(profile / "Extensions" / dr.CHROMIUM_STORE_EXTENSION_ID).mkdir(parents=True)
(config / "Local State").write_text(json.dumps({"profile": {"last_used": "Default"}}))
own = profile / "Sync Extension Settings" / dr.CHROMIUM_STORE_EXTENSION_ID

# Some other extension's storage -- the target of the attack.
victim = profile / "Local Extension Settings" / ("p" * 32)
victim.mkdir(parents=True)
with plyvel.DB(str(victim), create_if_missing=True) as db:
    db.put(b"vault", b"untouched")

state = home / "state"
(state / "original").mkdir(parents=True)
snap = state / "original/dark-reader.json"
def snapshot(database, entries):
    snap.write_text(json.dumps({"browser": "Chromium", "browserDesktop": "chromium.desktop",
                                "browserFamily": "chromium", "browserProfile": str(profile),
                                "database": str(database), "entries": entries}))
enc = lambda value: {"existed": True, "value": __import__("base64").b64encode(value).decode()}

snapshot(victim, {"vault": enc(b"attacker"), "enabled": enc(b"true")})
chk("a snapshot naming another database is refused", dr.restore_theme(state, None), 1)
with plyvel.DB(str(victim)) as db:
    chk("...and that database is left exactly as it was",
        (db.get(b"vault"), db.get(b"enabled")), (b"untouched", None))

snapshot(own, {"enabled": enc(b"false"), "vault": enc(b"attacker")})
chk("the browser's own database is restored", dr.restore_theme(state, None), 0)
with plyvel.DB(str(own)) as db:
    chk("...its managed keys put back", db.get(b"enabled"), b"false")
    chk("...and nothing the capture never takes written into it", db.get(b"vault"), None)

snap.write_text("not json")
chk("an unreadable snapshot is refused, not guessed at", dr.restore_theme(state, None), 1)
E
