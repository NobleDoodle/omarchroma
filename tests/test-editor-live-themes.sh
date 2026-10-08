#!/usr/bin/env bash
# VS Code (and Insiders, VSCodium, Cursor) kept an Omarchy theme's old colors
# after a switch, for most themes: Omarchy regenerates the colors of one theme
# always named "Omarchy", the setting naming it never changes, and the editor
# reuses the copy of the theme file it read first. "_watch": true on the theme
# entry has the editor's own theme watcher re-read the file when it changes.
# Omarchy writes that package.json afresh on every switch, without it, so the
# sync puts it back. Run against a scratch HOME, never the real editors.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT
state(){ python3 "$REPO/lib/hyprchroma-state" --state-dir "$ROOT/state" --data-dir "$ROOT/data" "$@"; }

# Exactly what omarchy-theme-set-vscode's install_generated_extension writes.
omarchy_manifest(){
  mkdir -p "$1/themes"
  cat > "$1/package.json" <<'EOF'
{
    "name": "omarchy-theme",
    "displayName": "Omarchy",
    "description": "Omarchy color theme",
    "publisher": "local",
    "version": "1.0.0",
    "engines": { "vscode": "^1.70.0" },
    "categories": ["Themes"],
    "contributes": {
        "themes": [{
            "label": "Omarchy",
            "uiTheme": "vs-dark",
            "path": "./themes/omarchy-color-theme.json"
        }]
    }
}
EOF
}
watch_of(){ jq -r '.contributes.themes[0]._watch // "unset"' "$1/package.json"; }

CODE=$ROOT/.vscode/extensions/omarchy-theme
CURSOR=$ROOT/.cursor/extensions/omarchy-theme
omarchy_manifest "$CODE"
omarchy_manifest "$CURSOR"

out=$(state editor-live-themes)
chk "Omarchy's generated VS Code theme is marked for the editor to watch" "$(watch_of "$CODE")" "true"
chk "...and Cursor's, the same extension in Cursor's own directory" "$(watch_of "$CURSOR")" "true"
chk "...each reported once" "$(grep -c '^live ' <<<"$out")" "2"
chk "nothing else in the manifest changes" \
  "$(jq -c '{name, publisher, version, label: .contributes.themes[0].label, path: .contributes.themes[0].path, ui: .contributes.themes[0].uiTheme}' "$CODE/package.json")" \
  '{"name":"omarchy-theme","publisher":"local","version":"1.0.0","label":"Omarchy","path":"./themes/omarchy-color-theme.json","ui":"vs-dark"}'

before=$(stat -c %Y.%i "$CODE/package.json")
sleep 1
chk "a manifest already marked is left alone, not rewritten every pass" \
  "$(state editor-live-themes | wc -l),$(stat -c %Y.%i "$CODE/package.json")" "0,$before"

# Omarchy's next theme switch writes the file afresh, without the flag.
omarchy_manifest "$CODE"
state editor-live-themes >/dev/null
chk "after Omarchy rewrites it on a switch, the next sync puts the flag back" "$(watch_of "$CODE")" "true"

# Not Omarchy's: someone else's extension that happens to sit at that path.
OSS=$ROOT/.vscode-oss/extensions/omarchy-theme
mkdir -p "$OSS"
printf '{"name":"something-else","publisher":"someone","contributes":{"themes":[{"label":"X","path":"./x.json"}]}}\n' > "$OSS/package.json"
cp "$OSS/package.json" "$ROOT/oss.orig"
printf '{ not json' > "$ROOT/.vscode-insiders-broken.json"
mkdir -p "$ROOT/.vscode-insiders/extensions/omarchy-theme"
cp "$ROOT/.vscode-insiders-broken.json" "$ROOT/.vscode-insiders/extensions/omarchy-theme/package.json"
state editor-live-themes >/dev/null 2>&1; rc=$?
chk "an extension that is not Omarchy's is never touched" "$(cmp -s "$OSS/package.json" "$ROOT/oss.orig" && echo same || echo changed)" "same"
chk "...nor a manifest that does not parse, and that is not an error" \
  "$(cmp -s "$ROOT/.vscode-insiders/extensions/omarchy-theme/package.json" "$ROOT/.vscode-insiders-broken.json" && echo same || echo changed),$rc" "same,0"

# A planted symlink at the manifest is replaced, never written through.
rm "$CODE/package.json"
printf 'PRECIOUS\n' > "$ROOT/precious"
omarchy_manifest "$ROOT/elsewhere"
ln -s "$ROOT/elsewhere/package.json" "$CODE/package.json"
cp "$ROOT/elsewhere/package.json" "$ROOT/elsewhere.orig"
state editor-live-themes >/dev/null 2>&1
chk "a symlinked manifest's target is not written through" \
  "$(cmp -s "$ROOT/elsewhere/package.json" "$ROOT/elsewhere.orig" && echo intact || echo written)" "intact"

chk "no editors installed at all is not an error" \
  "$(HOME=$(mktemp -d) python3 "$REPO/lib/hyprchroma-state" --state-dir "$ROOT/s2" --data-dir "$ROOT/d2" editor-live-themes; echo $?)" "0"

# Wired into every sync, ahead of the early exit an unchanged palette takes.
chk "every sync pass runs it, before the unchanged-palette early exit" \
  "$(awk '/editor-live-themes/{found=NR} /colors are already synchronized/{print (found && found < NR) ? "before" : "after"; exit}' "$REPO/bin/hyprchroma")" "before"
chk "...on a forced sync (Omarchy's theme hook) or a palette change, not every quiet pass" \
  "$(grep -c 'if (( force )) || \[\[ $fingerprint != "$previous_fingerprint" \]\]; then' "$REPO/bin/hyprchroma")" "1"
