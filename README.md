# Omarchroma

![Omarchroma showcase banner](preview.png)

**Change your Omarchy theme once and let the rest of your desktop follow.**

Omarchroma carries the active palette into applications that do not follow it
on their own: GTK 3/4 and libadwaita, GNOME settings, Qt and KDE Frameworks,
Dark Reader in the default browser, and Pear Desktop / YouTube Music.

It is a user service, `hyprchroma`, plus an **optional** Omarchy bar widget.
The service needs no bar widget and no Omarchy shell; the widget is a
convenience on top of it.

## Install

**With the bar widget:**

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma --enable
```

Open the panel and press **i**. A setup terminal asks which optional
frameworks you want, checks what they need, and waits for you to type
`I understand` before building anything. It builds from the checkout Omarchy
just cloned, so what runs is what you have.

**Without it:**

```bash
git clone --depth 1 https://github.com/NobleDoodle/omarchroma
cd omarchroma/packaging && makepkg -si
systemctl --user enable --now hyprchromad.service
```

`makepkg` builds only the service. No QML is installed.

## Showcase

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear styling following a custom palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after a theme change. |

## Use

```bash
hyprchroma                        # sync only what changed
hyprchroma --force                # rewrite everything
hyprchroma --target=gtk --force   # gtk | qt-kde | dark-reader | pear
hyprchroma framework remove pear  # take one out of the panel and revert it
hyprchroma framework restore pear # put it back and sync it
hyprchroma palette --capture      # pin the current palette to a file
hyprchroma restore --stock        # hand everything back to Omarchy's defaults
```

With the bar widget:

| Input | Action |
|---|---|
| left click the palette icon | open or close the panel |
| `1` – `4` | toggle the frameworks you kept |
| `r` | refresh every enabled framework |
| `/` | applications still showing the old theme, and anything you removed |
| `i` | install, update or start hyprchroma when the panel offers it |
| `Esc` | leave that view, or close the panel |

Turning a framework **off** reverts it to how it looked before Omarchroma first
touched it. **Removing** one also takes its row out of the panel — press `/`
and its number to put it back.

GTK and Qt/KDE are always included. Dark Reader and Pear Desktop are optional,
and setup asks about both. Dark Reader itself is never installed for you: add
it from your browser's store and it is themed from the next sync.

## Where the palette comes from

**On Omarchy**, automatically — the daemon installs the `theme-set` and
`font-set` hooks, and Omarchy's own resolver answers, so derived shades match
what Omarchy computes.

**Anywhere else** — plain Hyprland, Quickshell, whatever you have built:

```bash
hyprchroma palette --template > ~/.config/hyprchroma/palette.toml
$EDITOR ~/.config/hyprchroma/palette.toml
hyprchroma --force
```

Twenty `#rrggbb` keys, all required and named in the template; `mode` is
inferred from the background. The file wins over Omarchy when both exist, so it
doubles as an override. `palette --capture` writes the resolved palette into
it, and `palette --source` says which is in use.

## Requirements

A palette source — Omarchy, or the file above. Without either the daemon says
so and stops, changing nothing.

| | Needed for | Without it |
|---|---|---|
| `hyprland` | the event stream the daemon watches | it restarts until Hyprland appears |
| `jq`, `python3` | every JSON read and write | required |
| `adw-gtk-theme` | GTK 3 applications | GTK 3 apps keep the system default |
| `python-plyvel` | Dark Reader in Chromium browsers | Chromium browsers are skipped |
| [Dark Reader](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh) | browser page theming | nothing to theme there |

## What it changes

No privileged command runs at any point. The daemon runs as your user and
writes only inside your home directory; installing the package is the one step
needing root, and that is `pacman`.

`gtk.css` is yours, so it is not taken over — the colors go in
`hyprchroma.css` beside it and `gtk.css` gets one `@import` line, placed first
so anything you write below overrides the theme. `kdeglobals` has no import
mechanism, so it is edited in place, touching only the sections Omarchroma
owns. Backups never contain generated output.

```text
~/.config/gtk-{3,4}.0/hyprchroma.css   the generated colors
~/.config/gtk-{3,4}.0/gtk.css          one @import line added, nothing else
~/.config/kdeglobals                   only the color sections
~/.config/*rc                          only [UiSettings] ColorScheme
~/.config/YouTube Music/hyprchroma.css
~/.local/share/color-schemes/Hyprchroma.colors
~/.local/{share,state}/hyprchroma/
~/.config/omarchy/hooks/{theme-set,font-set}.d/hyprchroma
```

## Binding keys globally

Omarchroma ships no keybindings and never edits your Hyprland configuration.
Bind what you want in `~/.config/hypr/bindings.lua`:

```lua
local om = "omarchy-shell io.github.nobledoodle.omarchroma"

o.bind("SUPER + ALT + G", "Omarchroma: toggle GTK", om .. " toggleGtk")
o.bind("SUPER + ALT + K", "Omarchroma: toggle Qt/KDE", om .. " toggleQtKde")
o.bind("SUPER + ALT + D", "Omarchroma: toggle Dark Reader", om .. " toggleDarkReader")
o.bind("SUPER + ALT + P", "Omarchroma: toggle Pear Desktop", om .. " togglePear")
o.bind("SUPER + ALT + R", "Omarchroma: refresh", om .. " refresh")
```

These drive the bar widget, so they need it; `hyprchroma --force` does the same
without it.

## Remove

```bash
hyprchroma restore --stock        # or --captured — do this first
systemctl --user disable --now hyprchromad.service
sudo pacman -R hyprchroma
omarchy plugin remove io.github.nobledoodle.omarchroma
```

## License

[MIT](LICENSE)
