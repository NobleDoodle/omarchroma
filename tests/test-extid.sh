#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$REPO" <<'PY'
import json, pathlib, tempfile, types
import os
import sys
os.environ["HOME"] = tempfile.mkdtemp()  # never the real home, whatever is stubbed
st = types.ModuleType("st")
src = pathlib.Path(f"{sys.argv[1]}/lib/hyprchroma-dark-reader").read_text() \
    .replace('if __name__ == "__main__":\n    raise SystemExit(main())','')
exec(compile(src,"st","exec"), st.__dict__)
STORE = st.CHROMIUM_STORE_EXTENSION_ID

def profile(**kw):
    d = pathlib.Path(tempfile.mkdtemp())
    for ext_id, name in kw.get("extensions", {}).items():
        m = d / "Extensions" / ext_id / "1.0_0"
        m.mkdir(parents=True)
        (m / "manifest.json").write_text(json.dumps(
            {"name": name, "version": "1.0", "permissions": ["storage"]}))
    if "prefs" in kw:
        (d / "Preferences").write_text(json.dumps({"extensions": {"settings": kw["prefs"]}}))
    return d

def chk(n, got, want): print(f"  {'PASS' if got==want else 'FAIL'} {n}" + ("" if got==want else f"  got={got} want={want}"))

chk("empty profile falls back to store id", st.chromium_extension_id(profile()), STORE)
chk("store install found", st.chromium_extension_id(profile(extensions={STORE: "Dark Reader"})), STORE)
chk("side-loaded build found by name",
    st.chromium_extension_id(profile(extensions={"abcdefghijklmnopabcdefghijklmnop": "Dark Reader"})),
    "abcdefghijklmnopabcdefghijklmnop")
chk("other extensions ignored",
    st.chromium_extension_id(profile(extensions={"mmmmnnnnooooppppmmmmnnnnoooopppp": "uBlock Origin"})), STORE)
chk("store id wins when both present",
    st.chromium_extension_id(profile(extensions={STORE: "Dark Reader", "abcdefghijklmnopabcdefghijklmnop": "Dark Reader"})),
    STORE)
chk("unpacked found via Preferences manifest",
    st.chromium_extension_id(profile(prefs={"ponmlkjihgfedcbaponmlkjihgfedcba": {"manifest": {"name": "Dark Reader", "permissions": ["storage"]}}})),
    "ponmlkjihgfedcbaponmlkjihgfedcba")
chk("id outside the a-p alphabet rejected",
    st.chromium_extension_id(profile(prefs={"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz": {"manifest": {"name": "Dark Reader", "permissions": ["storage"]}}})), STORE)
chk("traversal key rejected",
    st.chromium_extension_id(profile(prefs={"../../../../tmp/evil": {"manifest": {"name": "Dark Reader", "permissions": ["storage"]}}})), STORE)
chk("empty policy stub is not mistaken for an install",
    st.chromium_extension_id(profile(prefs={STORE: {}})), STORE)
PY
python3 - "$REPO" <<'PY'
import json, pathlib, tempfile, types
import sys
st = types.ModuleType("st")
src = pathlib.Path(f"{sys.argv[1]}/lib/hyprchroma-dark-reader").read_text() \
    .replace('if __name__ == "__main__":\n    raise SystemExit(main())','')
exec(compile(src,"st","exec"), st.__dict__)
STORE = st.CHROMIUM_STORE_EXTENSION_ID

def prof(exts):
    d = pathlib.Path(tempfile.mkdtemp())
    for eid, manifest in exts.items():
        m = d / "Extensions" / eid / "1.0_0"; m.mkdir(parents=True)
        (m / "manifest.json").write_text(json.dumps(manifest))
    return d

def chk(n, got, want): print(f"  {'PASS' if got==want else 'FAIL'} {n}" + ("" if got==want else f"  got={got}"))

DR = {"name": "Dark Reader", "permissions": ["alarms", "fontSettings", "scripting", "storage"]}
A, B = "abcdefghijklmnopabcdefghijklmnop", "ponmlkjihgfedcbaponmlkjihgfedcba"

chk("one claimant is used", st.chromium_extension_id(prof({A: DR})), A)
chk("two claimants -> refuses to choose", st.chromium_extension_id(prof({A: DR, B: DR})), STORE)
chk("named Dark Reader but no storage permission is ignored",
    st.chromium_extension_id(prof({A: {"name": "Dark Reader", "permissions": ["tabs"]}})), STORE)
chk("no permissions key at all is ignored",
    st.chromium_extension_id(prof({A: {"name": "Dark Reader"}})), STORE)
chk("store install still wins over a claimant",
    st.chromium_extension_id(prof({STORE: DR, A: DR})), STORE)
PY
