#!/usr/bin/env bash
# The installed Python helpers run
# from bytecode compiled when the package is built, instead of compiling their
# source on every start (the state helper alone, a dozen times a sync). Each
# helper is installed as a module beside a launcher of its name. Bytecode may
# come only from that root-owned package directory and is never written at
# run time. Run against a staged "make install", like the package.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

STAGE=$(mktemp -d "$HOME/bytecode-XXXXXX"); trap 'rm -rf "$STAGE"' EXIT
make install DESTDIR="$STAGE/root" >/dev/null 2>&1
L=$STAGE/root/usr/lib/hyprchroma
HELPERS=(hyprchroma-state hyprchroma-dark-reader hyprchroma-palette hyprchroma-icons)

layout=""
for helper in "${HELPERS[@]}"; do
  module=${helper//-/_}
  layout+="$(stat -c %a "$L/$helper") $(stat -c %a "$L/$module.py") $(cmp -s "lib/$helper" "$L/$module.py" && echo same)"
  layout+=" $(grep -c "runpy.run_module(\"$module\", run_name=\"__main__\"" "$L/$helper");"
done
chk "each helper is a launcher of its name, its code the module beside it" \
  "$layout" "755 644 same 1;755 644 same 1;755 644 same 1;755 644 same 1;"
chk "...compiled with the package, checked against the source by hash" "$(/usr/bin/python3 -I - "$L" <<'PY'
import importlib.util, pathlib, sys
flags = set()
for module in ("hyprchroma_state", "hyprchroma_dark_reader", "hyprchroma_palette", "hyprchroma_icons"):
    cached = pathlib.Path(importlib.util.cache_from_source(f"{sys.argv[1]}/{module}.py"))
    flags.add(int.from_bytes(cached.read_bytes()[4:8], "little") if cached.is_file() else -1)
print(sorted(flags))
PY
)" "[3]"
chk "the launchers start Python isolated and write no bytecode" \
  "$(head -1 "$L/hyprchroma-state"),$(grep -c '^sys.dont_write_bytecode = True$' "$L/hyprchroma-state")" "#!/usr/bin/python3 -I,1"

# --- they work, and run nothing planted --------------------------------------
H=$STAGE/home; mkdir -p "$H" "$STAGE/run" "$STAGE/cwd" "$STAGE/pp"
marker=$STAGE/ran
plant() { printf 'import pathlib\npathlib.Path(%s).open("a").write("%s\\n")\n' "'$marker'" "$1" > "$2"; }
user_site=$(HOME=$H /usr/bin/python3 -c 'import site; print(site.getusersitepackages())'); mkdir -p "$user_site"
plant usercustomize "$user_site/usercustomize.py"
# A module of the helper's own name, ahead of the package on every path an
# unisolated Python would search, must not be what runs.
for where in "$STAGE/cwd" "$STAGE/pp" "$user_site"; do
  for module in hyprchroma_state hyprchroma_palette json; do plant "$where:$module" "$where/$module.py"; done
done
fingerprint() { find "$L" "$H" "$STAGE/cwd" -name '*.pyc' -printf '%p %s %T@\n' | sort | sha256sum; }
before=$(fingerprint)
out=$( cd "$STAGE/cwd" && export HOME=$H XDG_RUNTIME_DIR=$STAGE/run PYTHONPATH=$STAGE/pp HYPRCHROMA_ICONS_ISOLATED=1
       unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME DBUS_SESSION_BUS_ADDRESS
       printf 'ok' | "$L/hyprchroma-state" write-file --path "$STAGE/written" && printf 'state:%s ' "$(cat "$STAGE/written")"
       "$L/hyprchroma-palette" --template | grep -c '^background' | sed 's/^/palette:/'
       "$L/hyprchroma-icons" status >/dev/null && printf 'icons:ok '
       "$L/hyprchroma-dark-reader" --info >/dev/null && printf 'dark-reader:ok' )
chk "the installed helpers run" "$(tr '\n' ' ' <<<"$out" | tr -s ' ' | sed 's/ *$//')" "state:ok palette:1 icons:ok dark-reader:ok"
chk "...and run nothing planted in the user's site-packages, PYTHONPATH or the folder they start in" \
  "$(sort -u "$marker" 2>/dev/null | paste -sd, -)" ""
chk "...and write no bytecode anywhere" "$(fingerprint)" "$before"

# Bytecode that no longer matches its source (or is gone) is not used, nor
# replaced: the source is compiled in memory and nothing is written.
printf '\n# changed\n' >> "$L/hyprchroma_palette.py"
rm -f "$L/__pycache__/hyprchroma_icons".*.pyc
before=$(fingerprint)
( export HOME=$H HYPRCHROMA_ICONS_ISOLATED=1; "$L/hyprchroma-palette" --template >/dev/null; "$L/hyprchroma-icons" status >/dev/null )
chk "stale or missing bytecode is neither used nor rewritten" "$? $(fingerprint)" "0 $before"

# --- the state helper finds itself and Dark Reader where it is installed ------
chk "the state helper starts itself again through its launcher, not its module" \
  "$(/usr/bin/python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import hyprchroma_state as s; print(s.own_helper())' "$L")" "$L/hyprchroma-state"
chk "...and loads Dark Reader's code from its module, with its bytecode" \
  "$(HOME=$H /usr/bin/python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import hyprchroma_state as s; m = s.dark_reader_module(); print(m.__file__ == sys.argv[1] + "/hyprchroma_dark_reader.py", hasattr(m, "dark_reader_targets"))' "$L")" "True True"
chk "in a checkout, both are still the helpers themselves" \
  "$(/usr/bin/python3 -I -B - "$REPO/lib/hyprchroma-state" <<'PY'
import sys, types
st = types.ModuleType("st"); st.__dict__["__file__"] = sys.argv[1]
exec(compile(open(sys.argv[1]).read().split('if __name__ == "__main__"')[0], sys.argv[1], "exec"), st.__dict__)
print(st.own_helper() == sys.argv[1], hasattr(st.dark_reader_module(), "dark_reader_targets"))
PY
)" "True True"
