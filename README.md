# Omarchroma

![Omarchroma showcase banner](preview.png)

**Change your Omarchy theme once and let the rest of your desktop follow.**

Omarchroma is the Omarchy bar widget for
[hyprchroma](https://github.com/NobleDoodle/hyprchroma), which carries the
active Omarchy palette into the applications that do not follow it on their
own: GTK 3, GTK 4 and libadwaita, GNOME settings, Qt and KDE Frameworks, Dark
Reader in the default browser, and Pear Desktop / YouTube Music.

One palette icon on the bar. Click it for per-framework toggles, a refresh, and
the list of applications still showing the previous theme.

## Install

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma --enable
```

That is the whole install. The theming itself is done by
[hyprchroma](https://github.com/NobleDoodle/hyprchroma), a separate package. If
it is missing — or older than this panel needs — open the panel and press **i**.

That opens a setup terminal, because everything it needs to do wants one. It
asks which optional frameworks you want and explains what each is, checks for
what those need and offers to install it, then shows what is about to happen
and waits for you to type `I understand` before it builds anything. Nothing is
installed if you answer anything else.

The build is `makepkg`, so pacman owns the result and it can be listed,
upgraded and removed like any other package. There is no AUR entry to install
from.

The panel checks `hyprchroma --version` against the minimum in `manifest.json`
each time it opens, so an out-of-date package is noticed rather than failing
quietly. Toggles stay inactive until the dependency is usable.

Nothing in the plugin runs a privileged command, and nothing is written outside
your own configuration.

### Choosing what you want themed

GTK and Qt/KDE are always included. Dark Reader and Pear Desktop are optional
and setup asks about both:

- **Pear Desktop** is a desktop app for YouTube Music. The sync generates a
  stylesheet so its window follows your theme.
- **Dark Reader** is a browser extension that darkens web pages. The sync
  pushes your palette into it so pages match the desktop. It is never
  installed for you; add it from your browser's store and it is themed from the
  next sync.

Declining one takes its row out of the panel entirely rather than leaving it
switched off, and reverts what it had changed. To put one back, press **/** in
the panel and then its number — everything you removed is listed there. From
the command line:

```bash
hyprchroma framework list
hyprchroma framework remove pear
hyprchroma framework restore pear
```

## Use

| Input | Action |
|---|---|
| left click the palette icon | open or close the panel |
| `1` – `4` | toggle GTK/GNOME, Qt/KDE, Dark Reader, Pear Desktop |
| `r` | refresh every enabled framework |
| `/` | list the applications still showing the previous theme |
| `i` | install hyprchroma, or start its service, when the panel offers it |
| `Esc` | leave that view, or close the panel |

Turning a framework off reverts it to how it looked before hyprchroma first
touched it, rather than leaving its colors in place with syncing merely
stopped. Turning it back on re-syncs from the same baseline.

Each row shows the digit that toggles it. Digits rather than letters because
the panel's key handler already takes `h`/`j`/`k`/`l` for navigation, and `q`
reads as "quit" everywhere.

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

`omarchy menu keybindings --print` lists what is already taken.

These bindings drive the bar widget, so they need it on the bar. Without it,
`hyprchroma --force` from a terminal does the same thing, and the background
service keeps syncing either way.

## Showcase

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear styling following a custom Omarchy palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after an Omarchy theme change. |

## Remove

```bash
omarchy plugin remove io.github.nobledoodle.omarchroma
```

That removes the bar widget only. To put your theming back and remove the
package as well:

```bash
hyprchroma restore --stock        # or --captured
systemctl --user disable --now hyprchromad.service
sudo pacman -R hyprchroma
```

## Upgrading from 1.x

Versions before 2.0.0 shipped the sync engine inside this plugin and installed
it with a shell script. That engine is now
[hyprchroma](https://github.com/NobleDoodle/hyprchroma), a package with a user
service. Press **i** in the panel to install it; it migrates the state
directory the old version captured, so the record of what your desktop looked
like before any of this ran is kept.

If the old plugin's own files are still around, remove them:

```bash
rm -f ~/.local/bin/omarchroma-{sync,state,dark-reader}
rm -f ~/.config/omarchy/hooks/{theme-set,font-set}.d/omarchroma
```

## License

[MIT](LICENSE)
