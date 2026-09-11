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

## Showcase

Omarchroma carries one Omarchy palette across desktop applications, browser
content, toolkit widgets, and app-specific styles.

![Tokyo Night theme synchronized across browser, Files, terminal, and KDE Connect](screenshots/tokyo-night.png)

The bar widget exposes each integration as a toggle. Turning a framework on
refreshes it immediately. Turning one off reverts it: that framework goes back
to the values captured before Omarchroma first changed it, rather than keeping
Omarchroma's colours in place with synchronization merely stopped. The snapshot
is kept, so switching the framework back on re-syncs from the same baseline.
Both deferrals the sync path observes apply to reverting too: Qt/KDE waits for
open KDE applications to close before rewriting `kdeglobals`, and Dark Reader
waits for the browser to exit.

| Theme | What it shows |
|---|---|
| ![Custom theme synchronized across desktop apps](screenshots/custom-theme.png) | GTK/libadwaita, Qt/KDE surfaces, Dark Reader, and Pear styling following a custom Omarchy palette. |
| ![Nord theme synchronized across desktop apps](screenshots/nord.png) | The same app set following a Nord palette after an Omarchy theme change. |

## Install

```bash
omarchy plugin add https://github.com/NobleDoodle/omarchroma
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/install.sh --enable
```

The first command installs the plugin through Omarchy. The second installs its
commands and native `theme-set` hook, adds missing dependencies, configures
Dark Reader for the default browser, enables the service, and places the
palette icon in the right bar section immediately before the power widget. If
Dark Reader is already installed in the active browser profile on first
install, Omarchroma leaves extension installation unmanaged and only
synchronizes its settings.

Before changing files, `install.sh` prints an explicit consent notice and
requires typing `I understand`. The notice explains that the installer may:

- install the outside packages `adw-gtk-theme` and `python-plyvel`
- copy the plugin into `~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma`
- overwrite Omarchroma command shims in `~/.local/bin`
- install the Omarchy `theme-set` and `font-set` hooks
- snapshot original state in `~/.local/state/omarchroma/original/`
- configure Dark Reader browser policy when Omarchroma needs to install it,
  keeping a root-owned backup of each replaced policy file under
  `/var/lib/omarchroma/policy-backup/`
- clear per-application KDE color scheme pins (`[UiSettings] ColorScheme` in
  `~/.config/*rc`), recording each original value for the uninstaller, and
  skipping any application that is running so its configuration is untouched
- run the initial sync for enabled GTK/GNOME, Qt/KDE, Dark Reader, and Pear
  Desktop integrations
- enable the bar widget when `--enable` is used

The shell hot-reloads; no restart is required. To install without adding the
bar icon:

```bash
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/install.sh
```

## Removal

```bash
~/.config/omarchy/plugins/io.github.nobledoodle.omarchroma/uninstall.sh
```

The uninstaller removes the plugin, commands, hook, and bar integration, and
asks how to put your theming back:

- **stock** returns each framework to Omarchy's own defaults. Files Omarchy
  never creates -- `gtk.css`, `kdeglobals`, the generated colour scheme -- are
  deleted, the two interface keys only Omarchroma sets (`accent-color` and
  `monospace-font-name`) are reset, and Omarchy re-authors the three it owns.
- **captured** replays what was on disk before Omarchroma first ran. This is
  the default, and what earlier versions always did.

Re-run `install.sh` to upgrade. It detects an existing install, says it is
upgrading, and skips both the consent prompt and re-authenticating a browser
policy that is already current -- so an upgrade needs no password unless the
policy actually changed. `--reinstall` forces the first-install path.

Capture happens once per file, so upgrading never overwrites a baseline that
was already recorded. A snapshot taken while Omarchroma output
was already on disk -- which can happen if a previous install's state directory
was lost -- is detected and marked, and the uninstaller then recommends stock
and says why.

A backup never holds Omarchroma's own output. A file Omarchroma writes whole is
recorded as absent rather than copied, which is also its correct stock value
since Omarchy writes none of them. `kdeglobals` is the one file shared with its
owner, so what Omarchroma wrote is removed from the copy and the rest of your
KDE settings are kept; if nothing of yours is left, it is recorded as absent
too. Without this a restore would put back the colours it was meant to remove,
and the next capture would carry them forward again.

Pass `--stock` or `--captured` to skip the question; without a terminal the
default is `--captured`. Either way the browser policy is restored the same
way. If Dark Reader was already installed when Omarchroma was
installed, uninstall restores its original settings and does not remove the
extension. Dark Reader restore requires the target browser to be closed,
matching the sync path's LevelDB safety rule.

The system browser policy is restored by a fixed privileged helper that
rederives each policy path from the built-in browser allowlist and replays the
root-owned backup under `/var/lib/omarchroma/policy-backup/` only after
verifying its digest; it prompts for administrator authentication and never
runs a user-writable script. One backup is recorded per policy destination, so
if the default browser changed while Omarchroma was installed, every policy
file it wrote is restored or removed, with the permissions and ownership it
had before Omarchroma replaced it. The backup directory is removed once the
restore succeeds. If the backup record is missing the uninstaller does not
guess: it names the policy files it left in place so they can be reviewed.

## Requirements

| Dependency | Why | Where it comes from |
|---|---|---|
| `adw-gtk-theme` | GTK 3 compatibility with GTK 4/libadwaita | Arch package; installed by `install.sh` |
| `python-plyvel` | safe Chromium Dark Reader LevelDB updates | Arch package; installed by `install.sh` |
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
| KDE Frameworks | generated `Omarchroma.colors`, applied `kdeglobals` color groups, and `[UiSettings] ColorScheme` set globally so `KColorSchemeManager` stops overriding KDE apps with its built-in defaults; per-application pins are cleared so no app opts out, the same `icons.theme` GTK uses is set so both toolkits draw from one icon set. A `KConfigWatcher` notification is sent, but it is not known to reach anything outside a Plasma session, so already-running KDE apps may need a restart |
| Dark Reader | dynamic theme, selection, focus, scrollbar colors, and custom CSS applied by default without dark-site detection |
| Pear Desktop | generated and registered YouTube Music stylesheet |

`kdeglobals` and the generated color scheme are read by every running KDE
application, so they are only rewritten when no process that has `KColorScheme`
mapped *and a window on screen* is running. A process with no window has nothing
to redraw, so a background daemon, or the remains of an application that crashed,
does not hold the palette back. While one is open both files are left exactly as they
are, that application is named in the restart list, and a helper applies the
palette once no KDE window is holding the files. It waits on Hyprland's event
stream and wakes on a window closing, which is the condition that matters:
closing a KDE application frequently leaves its process running with no window,
so waiting for the process to end waits for something that may never happen.
Where that stream is unavailable it falls back to waiting on the processes
themselves; it costs nothing while it sleeps, only one runs at a time, and the
deferral is also recorded so the recovery service still catches the case where
the helper never ran. The check is that
predicate rather than a list of KDE applications, so it covers ones this plugin
has never heard of.

Everything else is written to disk as soon as the theme changes, so any
application started afterwards comes up with the new palette. A window already open cannot
be restyled in place, and nothing here signals, quits or restarts it, nor edits
the configuration of a running application. Instead the sync lists the open
applications still showing the previous theme, so restarting them is the user's
choice. Anything Omarchy re-themes on its own is left out: the shell hot-reloads
over IPC, and terminals, TUIs and the compositor are told to reread their config
by Omarchy's own restart helpers, so naming them would send someone to restart
nothing. That set is read from Omarchy rather than listed here, so it follows
along as Omarchy gains more. The list is identified by window class rather than
window title, so it names the same applications every run.

Setting an Omarchy theme is the trigger: the native `theme-set` and `font-set`
hooks apply GTK, Qt/KDE, Dark Reader and Pear Desktop immediately. Everything
after that is event driven rather than polled. A helper watches Hyprland's event
stream and re-syncs when a window opens or closes, which is when most of the
remaining work becomes possible: a KDE application closing that the palette was
deferred for, a changed default browser, a newly installed Pear Desktop.

Dark Reader is waited for differently, because what it needs is different. Its
settings live inside the browser's own database, so it has to wait for the
browser's processes to end rather than for its window to close -- and a browser
leaves a good many running for a while after the last window goes. By then the
window event has been and gone, so a second helper waits on those processes
directly and applies Dark Reader the moment the last one exits. A timer remains
only as a rare safety net for a change that surfaces as neither. A runtime lock
prevents overlapping hook, service, and manual runs.

GTK 4 and libadwaita read the user stylesheet once, at startup, so an
application left resident with no window would hand its next window the previous
palette and look as though restarting it changed nothing. After writing, the
sync closes those idle services so the next launch reads the new stylesheet --
the approach `omarchy-nautilus-theme` takes with `nautilus -q`, generalised.
An application qualifies only on what is observable about it: D-Bus activatable,
so quitting is a no-op the next launch undoes; started before the current theme;
showing no window, so nothing on screen is touched; and exposing its own quit
action, which is activated rather than the process being signalled.

Inside `org.gnome.` the application's own `--quit` is used instead, because
activating the quit action leaves GApplication to time out before it releases
the bus name -- ten seconds for Nautilus, against under half a second for
`nautilus -q`, which reaches `g_application_quit()`. The binary comes from the
application's D-Bus service file rather than from a list here, `--quit` is only
assumed in that namespace where it is the convention, and anything still running
a moment later falls back to the action.

## Browser support

Omarchroma detects the current default browser through XDG settings and
supports:

- Helium
- Chromium
- Google Chrome
- Brave
- Vivaldi
- Microsoft Edge
- Firefox
- Firefox Developer Edition
- LibreWolf
- Waterfox
- Floorp
- Zen Browser

For Chromium-family browsers, Omarchroma installs Dark Reader through the
browser's managed-extension policy and updates the extension's active profile
LevelDB. For Firefox-family browsers, it installs Dark Reader through the
browser's `policies.json` when needed and updates the active profile's
`storage-sync-v2.sqlite` settings for `addon@darkreader.org`. Browser extension
settings are never modified while the target browser is running; the update is
marked `pending-browser-exit` and retried after the browser closes.

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
/var/lib/omarchroma/policy-backup/   (root-owned; only when a browser policy is installed)
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
| `Esc` | close the panel |
| `Tab` / `Shift-Tab` | move to the next or previous bar panel |

Each row shows the digit that toggles it, so the shortcuts are readable off the
panel itself. Digits rather than initials because the shell's panel key handler
takes `h`, `j`, `k` and `l` for cursor movement and `x` for delete before a
panel sees them -- `k` can never reach this panel to mean KDE -- and because `q`
reads as "quit" nearly everywhere, which is the wrong key to attach to a toggle
that reverts the framework it switches off.

A toggle or refresh is ignored while one is still running, so holding a key down
cannot stack them up.

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

Pick combinations that are free on your system -- `omarchy menu keybindings
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
