#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - <<'PY'
import pathlib, types
st = types.ModuleType("st")
src = pathlib.Path("$REPO/lib/hyprchroma-state").read_text() \
    .replace('if __name__ == "__main__":\n    raise SystemExit(main())','')
exec(compile(src,"st","exec"), st.__dict__)
cases = [
    ("Google Maps",     "chrome-maps.google.com__-Default", "Google Maps"),
    ("ChatGPT",         "chrome-chatgpt.com__-Default",     "ChatGPT"),
    ("Pictures",        "org.gnome.Nautilus",               "Nautilus"),
    ("proj - Kdenlive", "kdenlive",                         "kdenlive"),
    ("YouTube Music",   "com.github.th-ch.youtube-music",   "youtube-music"),
    ("New tab",         "helium",                           "helium"),
    ("Only a title",    "",                                 "Only a title"),
    ("",                "",                                 "?"),
    ("<b>evil</b>",     "chrome-x.com__-Default",           "bevilb"),
]
for title, klass, want in cases:
    got = st.window_display_name(title, klass)
    print(f"  {'PASS' if got==want else 'FAIL'} class={klass or '(none)':34} -> {got!r}")
PY
python3 - <<'PY'
import pathlib, types
st = types.ModuleType("st")
src = pathlib.Path("$REPO/lib/hyprchroma-state").read_text() \
    .replace('if __name__ == "__main__":\n    raise SystemExit(main())','')
exec(compile(src,"st","exec"), st.__dict__)
cases = [
  ("web app takes the current page name",
   {"class":"chrome-maps.google.com__-Default","initialTitle":"maps.google.com_/","title":"Google Maps"},
   "Google Maps"),
  ("normal app keeps its stable initial title",
   {"class":"org.gnome.Nautilus","initialTitle":"Files","title":"Pictures"}, "Files"),
  ("web app falls back when there is no title",
   {"class":"chrome-x.com__-Default","initialTitle":"x.com_/","title":""}, "x.com_/"),
  ("class is the last resort",
   {"class":"kdenlive","initialTitle":"","title":""}, "kdenlive"),
]
for name, client, want in cases:
    got = st.window_title(client)
    print(f"  {'PASS' if got==want else 'FAIL'} {name} -> {got!r}")
PY
