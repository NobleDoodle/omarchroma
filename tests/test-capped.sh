#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$REPO" <<'PY'
import json, pathlib, tempfile, types
import sys
def load(name):
    m = types.ModuleType(name)
    src = pathlib.Path(f"{sys.argv[1]}/lib/{name}").read_text() \
        .replace('if __name__ == "__main__":\n    raise SystemExit(main())','')
    exec(compile(src, name, "exec"), m.__dict__); return m
st, dr = load("hyprchroma-state"), load("hyprchroma-dark-reader")
d = pathlib.Path(tempfile.mkdtemp())
def chk(n, got, want): print(f"  {'PASS' if got==want else 'FAIL'} {n}" + ("" if got==want else f"  got={got!r}"))

small = d / "small.json"; small.write_text(json.dumps({"a": 1}))
chk("small file reads normally", dr.read_capped_json(small), {"a": 1})

big = d / "big.json"; big.write_text("[" + "0," * (9 * 1024 * 1024) + "0]")
chk("oversized file refused, not parsed", dr.read_capped_json(big), {})
chk("oversized file refused by state helper too", st.read_capped(big), None)

binary = d / "binary.rc"; binary.write_bytes(b"\xff\xfe\x00\x01not utf8")
chk("undecodable file returns None", st.read_capped(binary), None)
chk("missing file returns None", st.read_capped(d / "absent"), None)

# The cap must bound what is read, not just what is returned.
import resource, os
chk("cap is under the 8 MiB limit", dr.MAX_FOREIGN_FILE, 8 * 1024 * 1024)
PY
