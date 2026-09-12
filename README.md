# Omarchroma

![Omarchroma showcase banner](preview.png)

**Change your Omarchy theme once and let your desktop follow.**

Omarchroma applies your active palette to GTK 3/4, libadwaita, GNOME settings,
Qt/KDE Frameworks, Dark Reader, and Pear Desktop (YouTube Music).

It runs as a standalone user service (`hyprchroma`) with an optional Omarchy
bar widget for convenience.

## Install

**With the bar widget:**

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma --enable
```

Open the panel and press **i**. A setup terminal will prompt you to select
optional frameworks, then verify the dependencies those need. Type
`I understand` to build.

**Standalone (service only):**

```bash
git clone --depth 1 https://github.com/NobleDoodle/omarchroma
cd omarchroma/packaging && makepkg -si
systemctl --user enable --now hyprchromad.service
```

Updating this way, re-run the same three commands. `enable --now` only starts
the service if it was not already running, so on an update it keeps executing
whatever it had already loaded — add `systemctl --user restart hyprchromad.service`
afterward to pick up the new build. The bar widget's setup terminal offers
this restart, and the Omarchy shell's own, automatically.

## Showcase

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear Desktop following a custom palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after a theme change. |

## Use

```bash
hyprchroma                        # sync only what changed
hyprchroma --force                # rewrite everything
hyprchroma --target=gtk --force   # gtk | qt-kde | dark-reader | pear
hyprchroma framework remove pear  # remove from the panel and revert
hyprchroma framework restore pear # put it back and sync
hyprchroma palette --capture      # pin the current palette to a file
hyprchroma restore --stock        # revert everything to stock defaults
```

With the bar widget:

| Input | Action |
|---|---|
| Left click palette icon | Open/close the panel |
| `1` – `4` | Toggle kept frameworks |
| `r` | Refresh every enabled framework |
| `/` | Show apps still using the old theme, and any removed frameworks |
| `i` | Install, update, or start hyprchroma when prompted |
| `Esc` | Go back or close the panel |

* Turning a framework off reverts it to its original state.
* Removing one hides it from the panel entirely (press `/` and its number to restore).
* GTK and Qt/KDE are always included; Dark Reader and Pear Desktop are optional.
  Install the Dark Reader browser extension manually for it to theme on the next sync.

## Palette Sources

**Omarchy:** The daemon installs `theme-set` and `font-set` hooks. Omarchy's own
resolver answers, so derived shades match what Omarchy computes.

**Standalone (plain Hyprland, Quickshell, etc.):**

```bash
hyprchroma palette --template > ~/.config/hyprchroma/palette.toml
$EDITOR ~/.config/hyprchroma/palette.toml
hyprchroma --force
```

Requires twenty named `#rrggbb` keys (`mode` is inferred from the background).
This file overrides Omarchy if present. Use `palette --capture` to save the
active palette and `palette --source` to verify the active source.

## Requirements

Requires a palette source (Omarchy or the TOML file). Without one, the daemon
stops and changes nothing.

| Dependency | Needed for | If missing |
|---|---|---|
| `hyprland` | Event stream | Restarts until Hyprland appears |
| `jq`, `python3` | JSON I/O | Required |
| `adw-gtk-theme` | GTK 3 applications | GTK 3 apps keep system defaults |
| `python-plyvel` | Dark Reader in Chromium | Chromium browsers are skipped |
| [Dark Reader](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh) | Browser page theming | Web pages won't be themed |
| [Pear Desktop](https://aur.archlinux.org/packages/pear-desktop-bin) | YouTube Music theming | Setup offers to install it from the AUR |

## What it changes

The daemon runs rootless, modifying only files in your home directory (only
pacman installation requires sudo).

* **GTK:** Injects a single `@import` line at the top of `gtk.css` to load
  generated colors from `hyprchroma.css`. Custom overrides remain intact.
* **KDE:** Edits `kdeglobals` in place, touching only the color sections
  Omarchroma manages.

Generated output is never included in backups.

```text
~/.config/gtk-{3,4}.0/hyprchroma.css   generated colors
~/.config/gtk-{3,4}.0/gtk.css          one @import line, nothing else
~/.config/kdeglobals                   only the color sections
~/.config/*rc                          only [UiSettings] ColorScheme
~/.config/YouTube Music/hyprchroma.css
~/.local/share/color-schemes/Hyprchroma.colors
~/.local/{share,state}/hyprchroma/
~/.config/omarchy/hooks/{theme-set,font-set}.d/hyprchroma
```

## Global Keybindings

Omarchroma does not edit your Hyprland config. Bind your own keys in
`~/.config/hypr/bindings.lua`:

```lua
local om = "omarchy-shell io.github.nobledoodle.omarchroma"

o.bind("SUPER + ALT + G", "Omarchroma: toggle GTK", om .. " toggleGtk")
o.bind("SUPER + ALT + K", "Omarchroma: toggle Qt/KDE", om .. " toggleQtKde")
o.bind("SUPER + ALT + D", "Omarchroma: toggle Dark Reader", om .. " toggleDarkReader")
o.bind("SUPER + ALT + P", "Omarchroma: toggle Pear Desktop", om .. " togglePear")
o.bind("SUPER + ALT + R", "Omarchroma: refresh", om .. " refresh")
```

These drive the bar widget. If running standalone, map to `hyprchroma --force`
instead.

## Remove

```bash
hyprchroma restore --stock        # Do this first (or use --captured)
systemctl --user disable --now hyprchromad.service
sudo pacman -R hyprchroma
omarchy plugin remove io.github.nobledoodle.omarchroma
```

## License

[MIT](LICENSE)
