#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - <<'PY'
import pathlib, tempfile, types
st = types.ModuleType("st")
src = pathlib.Path("$REPO/lib/hyprchroma-state").read_text() \
    .replace('if __name__ == "__main__":\n    raise SystemExit(main())', '')
exec(compile(src, "st", "exec"), st.__dict__)
d = pathlib.Path(tempfile.mkdtemp())

def strip(text):
    p = d / "kdeglobals"; p.write_text(text)
    return st.strip_generated_kdeglobals(p)

def chk(name, got, want):
    print(f"  {'PASS' if got == want else 'FAIL'} {name}" + ("" if got == want else f"\n       got={got!r}\n      want={want!r}"))

chk("pure hyprchroma -> nothing kept",
    strip("[General]\nColorScheme=Hyprchroma\nColorSchemeHash=abc\n[Colors:Window]\nBackgroundNormal=1,2,3\n[WM]\nactiveBackground=4,5,6\n"),
    None)

chk("genuine sections survive",
    strip("[Shortcuts]\nAdd=Ctrl+N\n[Colors:View]\nForeground=9,9,9\n"),
    "[Shortcuts]\nAdd=Ctrl+N\n")

chk("genuine keys survive inside shared sections",
    strip("[General]\nColorScheme=Hyprchroma\nColorSchemeHash=x\nBrowserApplication=firefox.desktop\n"),
    "[General]\nBrowserApplication=firefox.desktop\n")

chk("[KDE] keeps its own keys, loses contrast",
    strip("[KDE]\ncontrast=4\nSingleClick=false\n"),
    "[KDE]\nSingleClick=false\n")

chk("[Icons] Theme dropped, rest kept",
    strip("[Icons]\nTheme=Yaru\nSomethingElse=1\n"),
    "[Icons]\nSomethingElse=1\n")

chk("subgroup of an owned section is dropped",
    strip("[Colors:Header][Inactive]\nForeground=1,1,1\n[Locale]\nCountry=us\n"),
    "[Locale]\nCountry=us\n")

chk("section emptied by stripping is removed entirely",
    strip("[UiSettings]\nColorScheme=Hyprchroma\n[Locale]\nCountry=us\n"),
    "[Locale]\nCountry=us\n")

chk("a file with no hyprchroma content is untouched in substance",
    strip("[Shortcuts]\nAdd=Ctrl+N\n"),
    "[Shortcuts]\nAdd=Ctrl+N\n")
PY
