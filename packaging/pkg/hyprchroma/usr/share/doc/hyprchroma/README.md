# Omarchroma

![Omarchroma showcase banner](preview.png)

**Change your Omarchy theme once and let the rest of your desktop follow.**

Omarchroma carries the active Omarchy palette into applications that do not
follow it on their own: GTK 3, GTK 4 and libadwaita, GNOME settings, Qt and KDE
Frameworks, Dark Reader in the default browser, and Pear Desktop / YouTube
Music.

It is two things in one repository:

- **hyprchroma**, a user service that does the theming. It needs no bar widget
  and no Omarchy shell, and works on any Arch system with a palette to follow.
- **the Omarchy plugin**, an optional bar widget — one palette icon with
  per-framework toggles, a refresh, and the list of applications still showing
  the previous theme.

The service is the product; the plugin is a convenience on top of it. Either
can be installed without the other.

## Install

### With the Omarchy bar widget

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma --enable
```

Open the panel and press **i**. That opens a setup terminal, because
everything it needs to do wants one: it asks which optional frameworks you
want and explains what each is, checks what those need and offers to install
it, then shows what is about to happen and waits for you to type
`I understand` before it builds anything.

It builds from the checkout Omarchy just cloned — not from a fresh download —
so what runs is what you have, and on a published listing, what was reviewed.

### Without it

```bash
git clone --depth 1 https://github.com/NobleDoodle/omarchroma
cd omarchroma/packaging && makepkg -si
systemctl --user enable --now hyprchromad.service
```

`makepkg` builds only the service. No QML is installed, and the plugin is not
required at any point.

## Use

The service is `hyprchroma`:

```bash
hyprchroma                        # sync only what changed
hyprchroma --force                # rewrite everything
hyprchroma --target=gtk --force   # gtk | qt-kde | dark-reader | pear
hyprchroma --target=pear --set-enabled=false   # turn one off and revert it
hyprchroma framework list         # what you have removed
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
| `/` | applications still showing the previous theme, and anything you removed |
| `i` | install, update or start hyprchroma when the panel offers it |
| `Esc` | leave that view, or close the panel |

Turning a framework off reverts it to the values captured before Omarchroma
first touched it. Removing one goes further: it reverts the framework and takes
its row out of the panel entirely. Press **/** and then its number to put it
back.

### Choosing what you want themed

GTK and Qt/KDE are always included. The other two are optional, and setup asks:

- **Pear Desktop** is a desktop app for YouTube Music. The sync generates a
  stylesheet so its window follows your theme.
- **Dark Reader** is a browser extension that darkens web pages. The sync
  pushes your palette into it. It is never installed for you; add it from your
  browser's store and it is themed from the next sync.

### Keeping the two in step

The plugin and the service are installed by different things — `omarchy plugin
update` and `makepkg` — so they can drift even from one repository. The panel
compares `hyprchroma --version` against its own version each time it opens and
offers the same **i** to fix a mismatch as it does a missing install.

## Where the palette comes from

hyprchroma needs a palette. It does not care who provides one.

**On Omarchy** it is first class and automatic: the daemon installs Omarchy's
`theme-set` and `font-set` hooks, and `omarchy theme set` applies everything at
once. Omarchy's own resolver answers, so its alias cascade and derived shades
are exactly what Omarchy computes rather than an approximation made here.

**Anywhere else** — plain Hyprland, a Quickshell setup, whatever you have
built — write a palette file and sync when you want to:

```bash
hyprchroma palette --template > ~/.config/hyprchroma/palette.toml
$EDITOR ~/.config/hyprchroma/palette.toml
hyprchroma --force
```

Twenty `#rrggbb` keys, all required, named in the template. `mode` is optional
and inferred from the background's luminance. The file wins over Omarchy when
both are present, so it is also how you override a theme you otherwise like.

`hyprchroma palette --capture` writes the currently resolved palette into that
file. On Omarchy that is the way to pin a theme, or to carry one to a machine
without Omarchy: Omarchy derives several keys rather than storing them, so a
theme's own `colors.toml` copied across would be missing some, and capturing
resolves them first.

`hyprchroma palette --source` says which is in use.
## Requirements

**A palette source.** Omarchy, or a palette file as above. The daemon says so
and stops without changing anything when there is neither.

| | Needed for | Without it |
|---|---|---|
| `hyprland` | the event stream the daemon watches | the daemon restarts until it appears |
| `jq`, `python3` | settings, status and every JSON write | required |
| `adw-gtk-theme` | GTK 3 applications | GTK 3 apps will not follow the theme |
| `python-plyvel` | Dark Reader in Chromium browsers | Dark Reader is not themed there |
| Dark Reader | browser page theming | nothing to theme; everything else works |

**hyprchroma never installs Dark Reader.** Install it yourself from the
[Chrome Web Store](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh)
or [Firefox Add-ons](https://addons.mozilla.org/firefox/addon/darkreader/); it
is themed from the next sync once it is there.
## Privileges

None. The daemon runs as your user, writes only inside your own home
directory, and runs no privileged command. Installing the package is the only
step that needs root, and that is `pacman` doing it, not this code.

Commands are resolved from a fixed set of directories checked to be root-owned
and unwritable by anyone else, and every file it writes is created and renamed
relative to a directory descriptor it has verified, so nothing on the path can
be redirected between the check and the write.
## What it does to your own files

GTK is the one place a user reasonably keeps their own rules, so hyprchroma
does not take `gtk.css` over. The colors go in `hyprchroma.css` beside it, and
`gtk.css` gets one line:

```css
@import url("hyprchroma.css");
```

It goes first, not last: in GTK's CSS a later `@define-color` replaces an
earlier one, so anything you write below the import wins over the theme. That
is the point — the palette is the default, your file is the override. Removing
the framework takes the line back out and leaves the rest of your file alone,
and a backup never contains that line either.

`kdeglobals` is different: KDE has no import mechanism, so it is edited in
place, and only the sections hyprchroma owns. What was yours is kept, and a
backup is stripped of anything generated before it is stored.
## Files written

```text
~/.config/gtk-3.0/hyprchroma.css      ~/.local/share/color-schemes/Hyprchroma.colors
~/.config/gtk-4.0/hyprchroma.css      ~/.local/share/hyprchroma/
~/.config/gtk-{3,4}.0/gtk.css         (one @import line added, nothing else)
~/.config/kdeglobals          ~/.local/state/hyprchroma/
~/.config/*rc                 (only the [UiSettings] ColorScheme key)
~/.config/YouTube Music/hyprchroma.css
~/.config/omarchy/hooks/{theme-set,font-set}.d/hyprchroma
```

Unrelated GTK, KDE, Pear Desktop and browser settings are preserved. A state
directory left by Omarchroma, the single-repo predecessor, is migrated on first
start so the captured baseline is not lost.
## Binding keys globally

Omarchroma ships no keybindings and never edits your Hyprland configuration.
Bind whichever keys you want in your own `~/.config/hypr/bindings.lua`:

```lua
local om = "omarchy-shell io.github.nobledoodle.omarchroma"

o.bind("SUPER + ALT + G", "Omarchroma: toggle GTK", om .. " toggleGtk")
o.bind("SUPER + ALT + K", "Omarchroma: toggle Qt/KDE", om .. " toggleQtKde")
o.bind("SUPER + ALT + D", "Omarchroma: toggle Dark Reader", om .. " toggleDarkReader")
o.bind("SUPER + ALT + P", "Omarchroma: toggle Pear Desktop", om .. " togglePear")
o.bind("SUPER + ALT + R", "Omarchroma: refresh", om .. " refresh")
```

`omarchy menu keybindings --print` lists what is already taken. These drive the
bar widget, so they need it; `hyprchroma --force` does the same without it.

## Showcase

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear styling following a custom Omarchy palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after an Omarchy theme change. |

## Remove

```bash
hyprchroma restore --stock        # or --captured
systemctl --user disable --now hyprchromad.service
sudo pacman -R hyprchroma
omarchy plugin remove io.github.nobledoodle.omarchroma
```

The first line is the one that matters: it hands your theming back before
anything is uninstalled.

## License

[MIT](LICENSE)
