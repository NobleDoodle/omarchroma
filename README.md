# Omarchroma

![Omarchroma showcase banner](preview.png)

**Change your Omarchy theme once and let the rest of your desktop follow.**

Omarchroma is an Omarchy service and bar widget that carries the active
Omarchy palette into applications that do not otherwise follow it completely.
It synchronizes GTK and GNOME, Qt and KDE Frameworks, Dark Reader in the
default Chromium- or Firefox-family browser, and Pear Desktop/YouTube Music.

In the bar it stays simple: one palette icon. Click it to open a compact
framework menu with per-framework on/off toggles and a refresh-enabled action;
automatic synchronization happens in the background whenever the Omarchy theme
changes for frameworks that are switched on.

## Install

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/install.sh --enable
```

The first command installs the plugin through Omarchy. The second installs
Omarchroma's commands and native `theme-set`/`font-set` hooks, and enables the
bar widget's palette icon before the power widget. It asks for no privileges
and runs no privileged command; before writing anything it prints a full
consent notice and requires typing `I understand`. Drop `--enable` to install
without the bar icon.

Two packages and Dark Reader are worth having, and `install.sh` reports either
as missing rather than installing them:

```bash
sudo pacman -S --needed adw-gtk-theme python-plyvel
```

- `adw-gtk-theme` — without it, GTK 3 apps won't follow the theme
- `python-plyvel` — without it, Dark Reader can't be themed in Chromium browsers
- **Dark Reader** — install it yourself, from the [Chrome Web
  Store](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh)
  or [Firefox Add-ons](https://addons.mozilla.org/firefox/addon/darkreader/).
  Omarchroma never installs it — earlier versions force-installed it through a
  browser policy; that mechanism is gone.

Re-run `install.sh` to upgrade — it detects the existing install and skips the
consent prompt. `--reinstall` forces the first-install path.

### Upgrading from before 1.6.0

If you ran a version before 1.6.0, a root-owned Dark Reader policy file may
still be on your system; nothing removes it automatically. Run this once — it
only removes, never writes:

```bash
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/bin/omarchroma-policy-cleanup
```

`install.sh` tells you if it's still needed. The helper will be dropped once
this upgrade path is no longer plausible.

## Showcase

Omarchroma carries one Omarchy palette across desktop applications, browser
content, toolkit widgets, and app-specific styles.

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear styling following a custom Omarchy palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after an Omarchy theme change. |

## Removal

```bash
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/uninstall.sh
```

Removes the plugin, commands, hook, and bar integration, and asks how to put
your theming back:

- **stock** — Omarchy's own defaults. Files Omarchy never creates (`gtk.css`,
  `kdeglobals`, the generated colour scheme) are deleted, the two interface
  keys only Omarchroma sets (`accent-color`, `monospace-font-name`) are reset,
  and Omarchy re-authors the three it owns.
- **captured** — replays what was on disk before Omarchroma first ran. This is
  the default.

Pass `--stock` or `--captured` to skip the question; without a terminal the
default is `--captured`. If the snapshot itself was contaminated by an earlier
Omarchroma install, stock is recommended automatically and it says why.

Dark Reader's own settings are restored and the extension is never removed —
installing it was always your choice. Restore requires the target browser to
be closed.

A backup never holds Omarchroma's own generated output, so a restore can't
reinstate colours it was meant to remove.

## Security

`install.sh` and `uninstall.sh` take no privileged action. Neither installs
packages, writes a browser policy, or touches anything outside your home
directory.

If a browser policy from a version before 1.6.0 is still on the system,
`install.sh` reports it and prints the command to remove it — see "Upgrading
from before 1.6.0" above. Nothing runs that command automatically.

## Requirements

| Dependency | Why | Where it comes from |
|---|---|---|
| `adw-gtk-theme` | GTK 3 compatibility with GTK 4/libadwaita | Arch package; **you install it** |
| `python-plyvel` | safe Chromium Dark Reader LevelDB updates | Arch package; **you install it** |
| Dark Reader | browser page theming | browser extension; **you install it** |
| `jq` | reading the settings, status, and browser-detection JSON | ships with Omarchy |
| `python3` | the state and Dark Reader helpers, and every JSON write | ships with Omarchy |

Everything else Omarchroma uses ships with Omarchy or the base system it
provides.

Omarchroma does not install Kvantum, `qt5ct`, or `qt6ct`. Omarchy intentionally
uses `QT_QPA_PLATFORMTHEME=gtk3` so ordinary Qt 5 and Qt 6 widgets inherit the
synchronized GTK palette.

## Layout

```text
manifest.json                    service + bar-widget plugin manifest
BarWidget.qml                    palette button and manual sync action
Panel.qml                        framework toggle panel opened by the widget
Service.qml                      startup sync and Hyprland event watcher
bin/omarchroma-sync              synchronization orchestrator
bin/omarchroma-dark-reader       browser/profile detection and Dark Reader updater
bin/omarchroma-state             snapshot and restore helper
bin/omarchroma-policy-cleanup    removes a browser policy left by an earlier version
hooks/omarchroma                 native theme-set hook
lib/sync-gtk-theme               GTK 3/4 and libadwaita palette generator
lib/sync-qt-kde-theme            Qt/KDE color-scheme generator
assets/pear-theme.css.template   Pear Desktop stylesheet template
install.sh                       standalone installer
uninstall.sh                     integration cleanup
```

## What synchronization does

| Target | Result |
|---|---|
| GTK 3 | complete widget, surface, selection, and semantic palette |
| GTK 4/libadwaita | matching CSS variables, surfaces, cards, dialogs, and controls |
| GNOME settings | dark/light mode, `adw-gtk3`, the icon theme named by the active Omarchy theme's `icons.theme`, the monospace font Omarchy is using, and nearest accent |
| Qt 5/Qt 6 | follows the generated GTK palette through Omarchy's platform-theme bridge |
| KDE Frameworks | generated `Omarchroma.colors`, applied `kdeglobals` color groups, and `[UiSettings] ColorScheme` set globally so `KColorSchemeManager` stops overriding KDE apps with its built-in defaults; per-application pins are cleared so no app opts out, and the same `icons.theme` GTK uses is set so both toolkits draw from one icon set |
| Dark Reader | dynamic theme, selection, focus, scrollbar colors, and custom CSS applied by default without dark-site detection |
| Pear Desktop | generated and registered YouTube Music stylesheet |

Everything is written to disk as soon as the theme changes, so anything
started afterwards comes up themed. A window already open is never restyled,
signalled, or restarted — the panel lists what's still showing the old theme
so restarting it is your choice. Apps Omarchy re-themes on its own (terminals,
the shell) are left off that list.

`kdeglobals` and the generated KDE colour scheme are the one exception: they
are left untouched while any KDE app has a window open, and applied the moment
it closes, so a running KDE application is never rewritten underneath itself.
Dark Reader waits similarly, but for the browser to fully exit rather than its
window to close, since its settings live in the browser's own database.

A few idle GNOME background services (Nautilus and the like) are quit and
relaunched after a sync, since GTK 4/libadwaita only reads the stylesheet at
startup — otherwise a resident service would hand its next window the old
palette, and restarting it would appear to do nothing.

## Browser support

Omarchroma detects the current default browser through XDG settings and
supports Helium, Chromium, Google Chrome, Brave, Vivaldi, Microsoft Edge,
Firefox, Firefox Developer Edition, LibreWolf, Waterfox, Floorp, and Zen
Browser.

For Chromium-family browsers, Omarchroma updates the extension's active
profile LevelDB once you have installed Dark Reader yourself. For
Firefox-family browsers, it updates the active profile's
`storage-sync-v2.sqlite` for `addon@darkreader.org`. Either way, settings are
never touched while the browser is running; the update waits for it to close.

## Files written

```text
~/.config/gtk-3.0/
~/.config/gtk-4.0/
~/.config/kdeglobals
~/.config/YouTube Music/omarchroma.css
~/.local/share/color-schemes/Omarchroma.colors
~/.local/share/omarchroma/dark-reader-theme.json
~/.local/state/omarchroma/original/
~/.local/state/omarchroma/settings.json
~/.local/state/omarchroma/status.json
~/.config/*rc                        (only the [UiSettings] ColorScheme key, removed)
/var/lib/omarchroma/policy-backup/   (root-owned; only if an earlier version left one)
```

Unrelated GTK, KDE, Pear Desktop, and browser settings are preserved.

## Interactions

| Input | Action |
|---|---|
| left click palette icon | open or close the framework refresh menu |
| GTK and GNOME toggle on | enable and refresh GTK 3/4, libadwaita, and GNOME settings |
| Qt and KDE toggle on | enable and refresh the Qt/KDE palette |
| Dark Reader toggle on | enable and refresh the selected browser's Dark Reader theme |
| Pear Desktop toggle on | enable and refresh Pear Desktop's stylesheet |
| any framework toggle off | revert that framework to its captured values and stop syncing it |
| Refresh enabled | refresh every currently enabled supported framework |
| `/` in the menu, or the button under Refresh | list the applications still drawing the previous theme |
| `omarchy-shell io.github.nobledoodle.omarchroma open` | open the framework panel over IPC |
| `omarchy-shell io.github.nobledoodle.omarchroma openPanel` | open the framework panel over IPC |
| `omarchy-shell io.github.nobledoodle.omarchroma close` | close the framework panel over IPC |
| `omarchy-shell io.github.nobledoodle.omarchroma show` | alias of `open` |
| `omarchy-shell io.github.nobledoodle.omarchroma hide` | alias of `close` |
| `omarchy-shell io.github.nobledoodle.omarchroma toggle` | open or close the framework panel over IPC |
| `omarchy-shell io.github.nobledoodle.omarchroma toggleGtk` | toggle GTK and GNOME without opening the panel |
| `omarchy-shell io.github.nobledoodle.omarchroma toggleQtKde` | toggle Qt and KDE without opening the panel |
| `omarchy-shell io.github.nobledoodle.omarchroma toggleDarkReader` | toggle Dark Reader without opening the panel |
| `omarchy-shell io.github.nobledoodle.omarchroma togglePear` | toggle Pear Desktop without opening the panel |
| `omarchy-shell io.github.nobledoodle.omarchroma refresh` | refresh every enabled framework |
| `omarchy-shell io.github.nobledoodle.omarchroma-service sync` | synchronize if anything changed, in the background service |
| `omarchy-shell io.github.nobledoodle.omarchroma-service refresh` | force a refresh, with the bar widget absent |

### Keyboard

With the panel open:

| Key | Action |
|---|---|
| `1` | toggle GTK and GNOME |
| `2` | toggle Qt and KDE |
| `3` | toggle Dark Reader |
| `4` | toggle Pear Desktop |
| `r` | refresh every enabled framework |
| `/` | show or hide the applications still to close |
| `Esc` | leave that view, or close the panel |
| `Tab` / `Shift-Tab` | move to the next or previous bar panel |

Each row shows the digit that toggles it. Digits rather than letters because
the panel's key handler already uses `h`/`j`/`k`/`l`/`x` for navigation and `q`
reads as "quit" everywhere, which would be the wrong key for a toggle that
reverts the framework it switches off. A toggle or refresh is ignored while
one is already running.

The count on the button under Refresh is how many applications are still
showing the old theme; `/` or a click opens the list (capped at eight, with
the rest counted). It updates on every sync, not just a theme change.

### Binding keys globally

Omarchroma ships no keybindings and never edits your Hyprland configuration.
What it ships is the IPC surface above, so you can bind whichever keys you want
in your own `~/.config/hypr/bindings.lua`:

```lua
local om = "omarchy-shell io.github.nobledoodle.omarchroma"

o.bind("SUPER + ALT + G", "Omarchroma: toggle GTK", om .. " toggleGtk")
o.bind("SUPER + ALT + K", "Omarchroma: toggle Qt/KDE", om .. " toggleQtKde")
o.bind("SUPER + ALT + D", "Omarchroma: toggle Dark Reader", om .. " toggleDarkReader")
o.bind("SUPER + ALT + P", "Omarchroma: toggle Pear Desktop", om .. " togglePear")
o.bind("SUPER + ALT + R", "Omarchroma: refresh", om .. " refresh")
```

Pick combinations that are free on your system — `omarchy menu keybindings
--print` lists what is already taken. Unlike the in-panel digits, a global
binding is yours to name, so `K` can mean KDE here.

These notify, since a key pressed with the panel closed has nothing else to
report through. The toggles live on the bar widget, so they need it on the bar;
`...omarchroma-service refresh` works without it, the service being always
loaded.

## CLI

```bash
omarchroma-sync                   # sync only when state changed
omarchroma-sync --force           # force all generators to run
omarchroma-sync --force --notify  # force sync and show a desktop notification
omarchroma-sync --target=gtk --force
omarchroma-sync --target=qt-kde --force
omarchroma-sync --target=dark-reader --force
omarchroma-sync --target=pear --force
omarchroma-sync --target=dark-reader --set-enabled=true
omarchroma-sync --target=dark-reader --set-enabled=false
omarchroma-sync --quiet           # suppress normal command output
omarchroma-dark-reader --info     # show detected browser and policy path as JSON
```

## License

[MIT](LICENSE)
