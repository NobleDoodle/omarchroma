import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.nobledoodle.omarchroma"
  ipcTarget: "io.github.nobledoodle.omarchroma"
  manageIpc: false

  property var hostWidget: null
  property var anchorItem: null
  readonly property var barIdentity: hostWidget || root
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") !== ""
    ? Quickshell.env("XDG_STATE_HOME") + "/hyprchroma"
    : Quickshell.env("HOME") + "/.local/state/hyprchroma"
  readonly property string dataDir: Quickshell.env("XDG_DATA_HOME") !== ""
    ? Quickshell.env("XDG_DATA_HOME") + "/hyprchroma"
    : Quickshell.env("HOME") + "/.local/share/hyprchroma"
  // Commands these run resolve from here, not from the PATH the shell happened
  // to inherit. They start unattended -- at login, and on every window event --
  // so a directory earlier in the ambient PATH holding something called jq or
  // hyprctl would be executed with nobody watching. Everything they call lives
  // in a root-owned system directory; the last entry is Omarchy's own. The
  // rest of the environment is preserved, so HOME and the session bus survive.
  // Fixed absolute identities. /usr/local/* is excluded because nothing
  // this plugin invokes lives there and it is the entry most often left
  // group-writable; the helpers launched below re-derive and verify their
  // own PATH regardless, so this is a floor rather than the whole defense.
  readonly property string trustedPath: "/usr/bin:/usr/share/omarchy/bin"

  FileView {
    id: themeNameFile
    path: root.omarchyCurrent + "/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.themeName = String(text() || "").trim()
      themeColorsFile.reload()
    }
    onFileChanged: reload()
  }

  FileView {
    id: themeColorsFile
    path: root.omarchyCurrent + "/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.readThemeColors(text())
    onFileChanged: reload()
  }

  readonly property string settingsPath: stateDir + "/settings.json"
  readonly property string statusPath: stateDir + "/status.json"
  // The running Omarchy theme. theme.name is rewritten in place; colors.toml
  // is replaced with the theme directory, so a name change reloads the colors.
  readonly property string omarchyCurrent: (Quickshell.env("XDG_STATE_HOME") !== ""
    ? Quickshell.env("XDG_STATE_HOME")
    : Quickshell.env("HOME") + "/.local/state") + "/omarchy/current"
  property string themeName: ""
  property var themeSwatches: []

  function readThemeColors(text) {
    var wanted = ["background", "dark_background", "foreground", "accent", "selection"]
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      var eq = line.indexOf("=")
      if (eq < 1) continue
      var key = line.slice(0, eq).trim()
      var raw = line.slice(eq + 1).trim().replace(/^["']|["']$/g, "")
      if (wanted.indexOf(key) !== -1 && /^#[0-9A-Fa-f]{6}$/.test(raw))
        found[key] = raw
    }
    var swatches = []
    for (var j = 0; j < wanted.length; j++) {
      if (found[wanted[j]]) swatches.push(found[wanted[j]])
    }
    root.themeSwatches = swatches
  }

  function themeStatus() {
    var name = String(root.themeName || "").replace(/[^A-Za-z0-9 _.-]/g, "").trim()
    if (!name) return ""
    return name.replace(/[-_.]+/g, " ").toUpperCase()
  }

  // hyprchroma is a separate package and does all the actual work; this panel
  // only drives it. Without it every toggle would fail quietly and the panel
  // would look broken, so the state is checked on open and the panel offers to
  // install it instead of pretending it can do anything.
  property bool dependencyChecked: false
  property bool dependencyPresent: false
  property bool daemonRunning: false
  property bool installing: false
  readonly property bool ready: dependencyPresent && daemonRunning && !outdated

  // The service and this panel ship from one repository, so what the panel
  // expects is simply its own version -- read from the manifest beside it
  // rather than written down twice. They are still installed by different
  // things, "omarchy plugin update" and makepkg, so the installed service can
  // lag behind the checkout and this is what notices.
  property string expectedVersion: ""
  property string installedVersion: ""
  // For About, from the same manifest, so it cannot disagree with it.
  property string pluginLicense: ""
  property string pluginAuthor: ""
  readonly property bool outdated: dependencyPresent && installedVersion !== ""
    && expectedVersion !== "" && root.olderThan(installedVersion, expectedVersion)
  // The service not installed at all: the same alert as an update, since the
  // same button clears it. Only once the check has run, so the bar does not
  // flash an alert while the panel is still finding out.
  readonly property bool installPending: dependencyChecked && !dependencyPresent
  readonly property bool serviceAlert: root.outdated || root.installPending

  FileView {
    id: manifestFile
    path: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName + "/manifest.json"
    printErrors: false
    // Watched, so "omarchy plugin update" lights the bar icon as soon as the
    // checkout moves ahead of the installed service, not at the next login.
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        root.expectedVersion = String(manifest.version || "")
        root.pluginLicense = String(manifest.license || "")
        root.pluginAuthor = String(manifest.author || "")
      } catch (error) {
        root.expectedVersion = ""
      }
    }
  }

  // And the other side: pacman replacing the service's binary -- an update run
  // from a terminal rather than from here -- asks the version again, so the
  // alert clears without the panel having to be opened.
  FileView {
    id: serviceBinary
    path: "/usr/bin/hyprchroma"
    printErrors: false
    watchChanges: true
    onFileChanged: {
      reload()
      presenceProcess.running = true
    }
  }

  // Asked once as the shell starts, not only when the panel opens: the bar icon
  // shows a pending update, so it has to know about one without being clicked.
  Component.onCompleted: presenceProcess.running = true

  // Numeric compare, field by field. "1.10.0" is newer than "1.9.0", which a
  // string compare gets backwards.
  function olderThan(have, want) {
    var a = String(have).split("."), b = String(want).split(".")
    for (var i = 0; i < Math.max(a.length, b.length); i++) {
      var x = parseInt(a[i] || "0", 10), y = parseInt(b[i] || "0", 10)
      if (isNaN(x)) x = 0
      if (isNaN(y)) y = 0
      if (x !== y) return x < y
    }
    return false
  }

  // Asking hyprchroma its version cannot answer "is hyprchroma installed":
  // when the binary is absent the process never starts, and Quickshell emits
  // no started, runningChanged or exited signal for a process that never ran.
  // Nothing set dependencyChecked, so the panel that offers to install it
  // stayed hidden in exactly the case it exists for -- a machine without the
  // service. This asks a binary that is always there instead, and only runs
  // the version probe once it has said yes.
  Process {
    id: presenceProcess
    command: [ "/usr/bin/test", "-x", "/usr/bin/hyprchroma" ]
    environment: ({ PATH: root.trustedPath })
    onExited: function(code) {
      if (code === 0) {
        versionProcess.running = true
      } else {
        root.dependencyPresent = false
        root.dependencyChecked = true
        root.daemonRunning = false
        root.installedVersion = ""
        root.staleWindows = ({})
        root.staleApps = []
      }
    }
  }

  Process {
    id: versionProcess
    command: [ "/usr/bin/hyprchroma", "--version" ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      // "hyprchroma 1.4.1" -> "1.4.1"
      onStreamFinished: {
        var match = /([0-9]+(?:\.[0-9]+)*)/.exec(String(text))
        root.installedVersion = match ? match[1] : ""
      }
    }
    onExited: function(code) {
      root.dependencyPresent = (code === 0)
      root.dependencyChecked = true
      if (root.dependencyPresent) {
        daemonProcess.running = true
        // Asked here rather than when the panel opens: the stale list comes
        // from the same binary, so it can only be asked once presence is
        // settled, and presence is settled asynchronously.
        root.refreshStaleApps()
      } else {
        root.daemonRunning = false
        root.installedVersion = ""
      }
    }
  }

  Process {
    id: daemonProcess
    command: [ "systemctl", "--user", "is-active", "--quiet", "hyprchromad.service" ]
    environment: ({ PATH: root.trustedPath })
    onExited: function(code) { root.daemonRunning = (code === 0) }
  }

  // Run in Omarchy's presented terminal, never inside omarchy-shell: this
  // authenticates, and a password prompt with nowhere to type is a hang. The
  // panel closes first so the terminal has the keyboard. Sentinels in the
  // runtime directory let the result be picked up after the panel is gone.
  // Installing and updating both run the same setup script, shipped with this
  // plugin, in Omarchy's presented terminal. It has to be a terminal: it asks
  // which optional frameworks you want, offers to install what those need, and
  // makepkg asks for a password -- none of which has anywhere to happen inside
  // omarchy-shell. The panel closes first so the terminal takes the keyboard.
  //
  // No sentinel files. An earlier version wrote .done/.failed markers into
  // $XDG_RUNTIME_DIR, falling back to /tmp -- a predictable name in a
  // world-writable directory, truncated with ":>", which is a symlink target
  // another account can plant. Nothing ever read them: onExited says when the
  // terminal finished and the version check that follows says whether it
  // worked.
  readonly property string setupScript:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName
      + "/bin/hyprchroma-setup"

  Process {
    id: installProcess
    command: [ "omarchy", "launch", "floating", "terminal", "with", "presentation", root.setupScript ]
    environment: ({ PATH: root.trustedPath })
    onExited: { root.installing = false; presenceProcess.running = true }
  }

  // Uninstalling is the same kind of job: it asks before each step and needs
  // a password for the package steps, so it runs in the presented terminal
  // too, from the script shipped beside setup.
  readonly property string uninstallScript:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName
      + "/bin/hyprchroma-uninstall"

  Process {
    id: uninstallProcess
    command: [ "omarchy", "launch", "floating", "terminal", "with", "presentation", root.uninstallScript ]
    environment: ({ PATH: root.trustedPath })
    onExited: presenceProcess.running = true
  }

  function openUninstall() {
    if (uninstallProcess.running || root.installing) return
    root.settingsOpen = false
    root.close()
    uninstallProcess.running = true
  }

  Process {
    id: restoreProcess
    environment: ({ PATH: root.trustedPath })
    onExited: settingsFile.reload()
  }

  // Putting one back is a single command, and it syncs on the way in, so the
  // framework is styled again by the time its row reappears.
  function restoreFramework(target) {
    if (restoreProcess.running) return
    restoreProcess.command = [ "/usr/bin/hyprchroma", "framework", "restore", target ]
    restoreProcess.running = true
  }

  // The mirror of restoreFramework: the service reverts it first, while it is
  // still listed, then takes it out of the panel.
  function removeFramework(target) {
    if (restoreProcess.running) return
    restoreProcess.command = [ "/usr/bin/hyprchroma", "framework", "remove", target ]
    restoreProcess.running = true
  }

  function toggleRestartMode() {
    root.setRestartMode(root.restartMode === "confirm" ? "off" : "confirm")
  }

  // The bar's urgent color and count. On unless this widget's shell.json entry
  // says otherwise, so an existing layout keeps the display it already had.
  // The panel's own list does not follow this: hiding the badge is not hiding
  // the applications.
  readonly property bool barAlert: setting("barAlert", true) !== false

  function setBarAlert(shown) {
    var next = shown === true
    if (next === root.barAlert) return
    var entry = { id: root.moduleName }
    var existing
    for (existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.barAlert = next
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleBarAlert() {
    root.setBarAlert(!root.barAlert)
  }

  function frameworkRemoved(target) {
    return root.removedTargets.indexOf(root.targetKey(target)) !== -1
  }

  // Remove or add back, by the same key in Settings: one list, one action that
  // flips, so taking a framework out and putting it back are the same gesture.
  function toggleRemoved(target) {
    if (root.frameworkRemoved(target)) root.restoreFramework(target)
    else root.removeFramework(target)
  }

  readonly property string issuesUrl: "https://github.com/NobleDoodle/omarchroma/issues/new/choose"
  readonly property string coffeeUrl: "https://buymeacoffee.com/nobledoodle"
  readonly property string repoUrl: "https://github.com/NobleDoodle/omarchroma"

  // About, on "?" and the help icon: what is installed and under what
  // license, then the links -- an issue or question, the source, a coffee.
  property bool aboutOpen: false
  // Additional Apps: Thunderbird and Pear Desktop, in a drop-down under its
  // row on the main list. Its row has no switch of its own: it only opens this.
  property bool appsOpen: false
  // Icons: a view of its own, like Settings, opened from its row on the main
  // list: the switch, the folder color, the icon set and app covers.
  property bool iconsOpen: false
  readonly property bool mainShown: !root.guideOpen && !root.settingsOpen && !root.aboutOpen
                                    && !root.confirmRestartOpen && !root.iconsOpen

  function openAbout() {
    root.guideOpen = false
    root.settingsOpen = false
    root.appsOpen = false
    root.iconsOpen = false
    root.aboutOpen = true
  }

  // Opens a link in the browser and gets the panel out of its way.
  function openLink(url) {
    Qt.openUrlExternally(url)
    root.aboutOpen = false
    root.close()
  }

  Process {
    id: startDaemonProcess
    command: [ "systemctl", "--user", "enable", "--now", "hyprchromad.service" ]
    environment: ({ PATH: root.trustedPath })
    onExited: { root.installing = false; presenceProcess.running = true }
  }

  function installDependency() {
    if (root.installing) return
    root.installing = true
    if (root.dependencyPresent && !root.outdated && !root.daemonRunning) {
      // Only the service needs starting; that takes no password and no terminal.
      startDaemonProcess.running = true
      return
    }
    // Missing or too old: the same build either way.
    root.close()
    installProcess.running = true
  }

  // Applications with a window open that started before the palette was last
  // written, so they are still drawing the previous theme. Kept in the panel
  // rather than only in a notification: a notification is gone in seconds, and
  // this is a list you work through at your own pace.
  property var staleApps: []
  // How many windows each has open, since that is what there is to close. An
  // app missing from it -- a service older than the counts -- has one.
  property var staleWindows: ({})
  readonly property int staleWindowCount: {
    var counts = root.staleWindows
    var total = 0
    for (var i = 0; i < root.staleApps.length; i++) total += root.windowsOf(root.staleApps[i], counts)
    return total
  }

  function windowsOf(name, counts) {
    var count = (counts || root.staleWindows)[name]
    return (typeof count === "number" && count >= 1 && count <= 999 && count === Math.floor(count))
      ? count : 1
  }

  // The service keeps only letters, digits and " .+-_" in a name, but status.json
  // can be written by anything this account runs -- a Flatpak app granted
  // ~/.local/state among them -- so what is shown is checked again here, and
  // drawn as plain text: as rich text, an <img> in a planted name had the shell
  // fetch whatever address it gave.
  readonly property int staleListed: 256

  function validStaleName(name) {
    return typeof name === "string" && name.length > 0 && name.length <= 64
      && !/[\u0000-\u001f\u007f<>&]/.test(name)
  }

  function windowsPhrase(count) {
    return count === 1 ? "1 window" : count + " windows"
  }

  // The guide replaces the panel body rather than sitting inside it: the list
  // is as long as the user has windows open, and growing the panel by one row
  // per application would push the frameworks off the screen.
  property bool guideOpen: false
  // Settings is a view of its own, on "s" with a gear, apart from the list of
  // windows to close on "/": each is the whole panel body while showing.
  property bool settingsOpen: false

  // What happens once a theme change leaves applications on the old theme:
  // open the confirmation on its own ("confirm"), or nothing, leaving the
  // guide's Restart All as the way in ("off", the default -- restarting a
  // window is exactly the kind of thing an install or an update may not decide
  // on the user's behalf). There is no mode that restarts without asking: a
  // restart can lose unsaved work, and only the user can say it is safe.
  property string restartMode: "off"
  readonly property var restartModes: ["confirm", "off"]

  // The same confirmation the global hotkey opens, reachable with the panel
  // already open too -- there is no reason the one reachable from outside it
  // should be the only way in. Mutually exclusive with the guide: each is the
  // whole panel body while it is showing, the way the guide already is.
  property bool confirmRestartOpen: false
  // Ctrl+Enter both opens the confirmation from the list and confirms it, so
  // the confirmation ignores it until it has been on screen a moment: a
  // double press must not skip the list of what will close.
  property bool restartArmed: false
  onConfirmRestartOpenChanged: {
    root.restartArmed = false
    if (root.confirmRestartOpen) restartArmTimer.restart()
  }
  Timer {
    id: restartArmTimer
    interval: 600
    onTriggered: root.restartArmed = true
  }

  // However many are open, the panel stays a readable size and says how many
  // it did not name.
  readonly property int staleShown: 8

  property string activeTarget: ""

  // One list drives both the rows and the keyboard shortcuts, so the digit a
  // row shows is always the digit that toggles it.
  //
  // Digits rather than initials: PanelKeyCatcher already consumes h/j/k/l for
  // cursor movement and x for delete, so "k" cannot reach this panel to mean
  // KDE; and "q" reads as quit in almost every keyboard UI, which is a poor
  // thing to wire to a toggle that reverts the framework it switches off.
  property var removedTargets: []

  // Every framework this knows about, and the ones left after the user's
  // removals. Rows are numbered by position in the visible list, so removing
  // one renumbers the rest rather than leaving a gap.
  readonly property var visibleFrameworks:
    allFrameworks.filter(function(entry) {
      return root.removedTargets.indexOf(root.targetKey(entry.target)) === -1
    })
  readonly property var hiddenFrameworks:
    allFrameworks.filter(function(entry) {
      return root.removedTargets.indexOf(root.targetKey(entry.target)) !== -1
    })
  // What Settings offers to remove or add back: the optional frameworks, and
  // any other that was removed anyway (the CLI can remove GTK too), so whatever
  // is gone can always be brought back from here. Numbered in this order.
  readonly property var settingsFrameworks:
    allFrameworks.filter(function(entry) {
      return entry.optional === true || root.frameworkRemoved(entry.target)
    })

  readonly property var allFrameworks: [
    { target: "gtk", label: "GTK and GNOME", icon: "󰍛" },
    { target: "qt-kde", label: "Qt and KDE", icon: "󰖯" },
    { target: "dark-reader", label: "Dark Reader", icon: "󰈈", optional: true },
    { target: "flatpak", label: "Flatpak apps", icon: "󰏗", optional: true },
    { target: "browsers", label: "Additional browsers", icon: "󰖟", optional: true },
    { target: "icons", label: "Icons", icon: "\uf07b", optional: true, view: true },
    { target: "apps", label: "Additional Apps", icon: "󰀻", optional: true, menu: true }
  ]

  // Under the Additional Apps row. Thunderbird is opt-in: it writes
  // into mail profiles. Pear stays on unless settings say otherwise.
  // Open, and its row still there: Settings can remove the row while it is open.
  readonly property bool appsListShown: root.appsOpen && root.visibleFrameworks.some(function(entry) {
    return entry.menu === true
  })
  readonly property var appFrameworks: [
    { target: "thunderbird", label: "Thunderbird", icon: "󰇮" },
    { target: "pear", label: "Pear Desktop (YouTube Music)", icon: "󰎆" }
  ]

  // Flatpak, additional browsers and Thunderbird are opt-in -- one widens
  // what every sandboxed app may read, the others write into profiles -- so
  // they are off unless settings record them on.
  property var enabledTargets: ({
    gtk: true,
    qtKde: true,
    darkReader: true,
    pear: true,
    flatpak: false,
    browsers: false,
    thunderbird: false,
    icons: false
  })

  function targetKey(target) {
    if (target === "qt-kde") return "qtKde"
    if (target === "dark-reader") return "darkReader"
    return target
  }

  function targetEnabled(target) {
    var key = targetKey(target)
    if (key === "flatpak" || key === "browsers" || key === "thunderbird" || key === "icons")
      return enabledTargets[key] === true
    return enabledTargets[key] !== false
  }

  function setTargetEnabled(target, enabled) {
    if (refreshProcess.running) return
    var key = targetKey(target)
    var next = {
      gtk: enabledTargets.gtk !== false,
      qtKde: enabledTargets.qtKde !== false,
      darkReader: enabledTargets.darkReader !== false,
      pear: enabledTargets.pear !== false,
      flatpak: enabledTargets.flatpak === true,
      browsers: enabledTargets.browsers === true,
      thunderbird: enabledTargets.thunderbird === true,
      icons: enabledTargets.icons === true
    }
    next[key] = enabled
    enabledTargets = next
    activeTarget = target
    refreshProcess.command = [
      "/usr/bin/hyprchroma",
      "--target=" + target,
      "--set-enabled=" + (enabled ? "true" : "false"),
      "--notify"
    ]
    refreshProcess.running = true
  }

  function refresh(target) {
    if (refreshProcess.running) return
    activeTarget = target
    refreshProcess.command = [
      "/usr/bin/hyprchroma",
      "--target=" + target,
      "--force",
      "--notify"
    ]
    refreshProcess.running = true
  }

  // A write of its own, not a sync -- modeProcess rather than refreshProcess,
  // so choosing a mode is never blocked behind, or seen to be, a sync already
  // running, and setting it does not show as "Synchronizing all...".
  function setRestartMode(mode) {
    if (restartModes.indexOf(mode) === -1 || modeProcess.running) return
    modeProcess.command = [ "/usr/bin/hyprchroma", "--restart-mode=" + mode ]
    modeProcess.running = true
  }

  Process {
    id: modeProcess
    environment: ({ PATH: root.trustedPath })
    onExited: settingsFile.reload()
  }

  // ---- Icons -------------------------------------------------------------
  // What the Icons view shows comes from the service's icons/status.json,
  // rewritten after every folder recolor and around every apply, so a theme
  // change repaints this without polling. Anything in it is drawn as plain
  // text and every color is checked before it is used.
  property var iconStatus: ({})
  property string iconsError: ""
  readonly property bool iconsBusy: iconsProcess.running || iconStatus.applying === true
    || (refreshProcess.running && (root.activeTarget === "icons" || root.activeTarget === "all"))
  readonly property string folderMode: ["background", "accent", "border", "yaru"].indexOf(String(iconStatus.mode)) !== -1
    ? String(iconStatus.mode) : "background"
  readonly property string iconSet: iconStatus.icon_set === "yaru" ? "yaru" : "reversal"
  readonly property bool iconCovers: iconStatus.covers !== false
  readonly property bool coversApply: root.iconSet === "reversal"
  readonly property var folderModes: [
    { id: "background", label: "Sidebar highlight", key: "1" },
    { id: "accent", label: "Accent", key: "2" },
    { id: "border", label: "Window border", key: "3" },
    { id: "yaru", label: "Theme's Yaru color", key: "4" }
  ]
  // Its row's number on the main list, which also takes the view back.
  readonly property int iconsRowNumber: {
    for (var i = 0; i < root.visibleFrameworks.length; i++)
      if (root.visibleFrameworks[i].view === true) return i + 1
    return 0
  }

  function validHex(value) { return /^#[0-9a-fA-F]{6}$/.test(String(value || "")) }
  function folderFace() {
    return root.validHex(root.iconStatus.face) ? root.iconStatus.face
      : (root.bar ? root.bar.foreground : Commons.Color.popups.text)
  }
  function setInstalled(name) {
    var sets = root.iconStatus.sets || {}
    return !!(sets[name] && sets[name].installed === true)
  }

  function openIcons() {
    root.guideOpen = false
    root.settingsOpen = false
    root.aboutOpen = false
    root.appsOpen = false
    root.iconsOpen = true
    iconsStatusProcess.running = true
  }

  function runIcons(args) {
    if (iconsProcess.running || !root.dependencyPresent) return
    root.iconsError = ""
    iconsProcess.command = [ "/usr/bin/hyprchroma", "icons" ].concat(args)
    iconsProcess.running = true
  }

  function setFolderMode(mode) { if (mode !== root.folderMode) root.runIcons(["folders", mode]) }
  function nextFolderMode() { root.runIcons(["folders", "next"]) }
  // Reversal not installed yet: choosing it offers the install instead, in the
  // same terminal setup uses, which switches to it once it is there.
  function setIconSet(name) {
    if (name === "reversal" && root.iconStatusKnown && !root.setInstalled("reversal")) {
      root.installReversal()
      return
    }
    if (name !== root.iconSet && root.setInstalled(name)) root.runIcons(["set", name])
  }
  readonly property bool iconStatusKnown: root.iconStatus.sets !== undefined

  Process {
    id: reversalProcess
    command: [ "omarchy", "launch", "floating", "terminal", "with", "presentation", root.setupScript, "--reversal" ]
    environment: ({ PATH: root.trustedPath })
    onExited: iconsStatusProcess.running = true
  }

  function installReversal() {
    if (reversalProcess.running || !root.dependencyPresent) return
    root.close()
    reversalProcess.running = true
  }
  // Plates are Reversal's shape; with Yaru every app keeps its own icon.
  function toggleCovers() {
    if (root.coversApply) root.runIcons(["covers", root.iconCovers ? "off" : "on"])
  }
  function reapplyIcons() { if (root.targetEnabled("icons")) root.runIcons(["apply"]) }

  Process {
    id: iconsProcess
    environment: ({ PATH: root.trustedPath })
    stderr: StdioCollector {
      id: iconsStderr
      waitForEnd: true
    }
    onExited: function(code) {
      var lines = String(iconsStderr.text || "").trim().split("\n")
      root.iconsError = code === 0 ? "" : lines[lines.length - 1].replace(/^Hyprchroma: /, "").slice(0, 160)
      iconsStatusProcess.running = true
      root.refreshStaleApps()
    }
  }

  Process {
    id: iconsStatusProcess
    command: [ "/usr/bin/hyprchroma", "icons", "status" ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readIconStatus(text)
    }
  }

  function readIconStatus(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (data && typeof data === "object" && !Array.isArray(data) && data.mode)
        root.iconStatus = data
    } catch (error) {
      // A partial write; the next change notice brings the whole file.
    }
  }

  FileView {
    id: iconsStatusFile
    path: root.stateDir + "/icons/status.json"
    printErrors: false
    watchChanges: true
    onLoaded: root.readIconStatus(text())
    onFileChanged: reload()
  }

  function iconsCoversText() {
    var last = root.iconStatus.last_apply || {}
    if (last.clip === undefined) return "not applied yet"
    var drawn = (last.clip || 0) + (last.plate || 0) + (last.plain || 0)
    if (root.iconSet === "yaru") return drawn + " as Yaru or the app's own"
    if (!root.iconCovers) return (last.plain || 0) + " drawn as they are"
    return drawn + " (" + (last.plate || 0) + " on a plate, " + (last.clip || 0) + " clipped)"
  }

  function iconsAppliedText() {
    var last = root.iconStatus.last_apply || {}
    if (!root.targetEnabled("icons")) return "off"
    if (!last.applied_at) return "never"
    var seconds = Math.max(0, Math.round(Date.now() / 1000 - last.applied_at))
    if (seconds < 60) return "just now"
    if (seconds < 3600) return Math.round(seconds / 60) + " min ago"
    if (seconds < 86400) return Math.round(seconds / 3600) + " h ago"
    return Math.round(seconds / 86400) + " d ago"
  }

  // Closes and relaunches every application the guide lists, the one
  // mechanism behind the guide's own button, the confirmation popup's "yes",
  // and (from the service's side, on its own) restartMode=force. Always
  // --notify: whichever of those called it, this is the only report of an
  // action that just happened out of sight.
  function runRestart() {
    if (restartProcess.running) return
    restartProcess.running = true
    // Out of the way of what is about to close and reopen: the restart runs
    // on without the panel, and reports through its notification.
    root.guideOpen = false
    root.settingsOpen = false
    root.aboutOpen = false
    root.appsOpen = false
    root.iconsOpen = false
    root.close()
  }

  // What the popup's "yes" does: close it, then restart, in that order, so a
  // restart that takes a moment is not shown behind a popup still claiming to
  // be asking.
  function confirmRestart() {
    if (!root.confirmRestartOpen || !root.restartArmed || root.staleWindowCount === 0) return
    root.confirmRestartOpen = false
    root.runRestart()
  }

  // Every way to a restart leads here first -- the guide's Restart All, its
  // Ctrl+Enter, the global hotkey and Confirm mode alike -- so nothing restarts
  // without the user having seen what will close and what it can cost.
  function openRestartConfirm() {
    root.refreshStaleApps()
    root.guideOpen = false
    root.settingsOpen = false
    root.aboutOpen = false
    root.appsOpen = false
    root.iconsOpen = false
    root.confirmRestartOpen = true
  }

  Process {
    id: restartProcess
    command: [ "/usr/bin/hyprchroma", "restart-stale", "--notify" ]
    environment: ({ PATH: root.trustedPath })
    onExited: root.refreshStaleApps()
  }

  // "r" matches the convention PanelKeyCatcher documents for refresh; the
  // digits match each row's position, which the row displays.
  function handleKey(text) {
    var key = (text || "").toLowerCase()
    // "i" only does anything while the panel is offering it, so it cannot be
    // pressed by accident into an install nobody asked for.
    if (key === "i" && root.dependencyChecked && !root.ready) {
      root.installDependency()
      return
    }
    // Nothing below this can work without hyprchroma: the guide lists
    // applications a framework toggle left stale, and there is no framework
    // toggle without the service. A key that would open it is ignored rather
    // than opening an always-empty screen.
    if (!root.ready) return
    // The confirmation takes no single key as a yes -- only Ctrl+Enter (the
    // Shortcut beside it), so a stray keypress can never close the user's
    // applications. Every other key is ignored while it is up.
    if (root.confirmRestartOpen) return
    // "/" rather than "?" so no shift is needed, and rather than "h" because
    // PanelKeyCatcher consumes h/j/k/l before a panel sees them -- the same
    // reason the framework rows are numbered.
    if (key === "/") {
      root.settingsOpen = false
      root.aboutOpen = false
      root.appsOpen = false
      root.iconsOpen = false
      root.guideOpen = !root.guideOpen
      if (root.guideOpen) root.refreshStaleApps()
      return
    }
    if (key === "s") {
      root.guideOpen = false
      root.aboutOpen = false
      root.appsOpen = false
      root.iconsOpen = false
      root.settingsOpen = !root.settingsOpen
      return
    }
    // While the guide is up, its only key is Ctrl+Enter (the Shortcut), which
    // opens the confirmation; letters and digits do nothing there.
    if (root.guideOpen) return
    // Settings: c flips the restart mode, b the bar alert, u opens the
    // uninstaller, and a digit removes or adds back the framework beside it.
    if (root.settingsOpen) {
      if (key === "c") { root.toggleRestartMode(); return }
      if (key === "b") { root.toggleBarAlert(); return }
      if (key === "u") { root.openUninstall(); return }
      var back = parseInt(key, 10) - 1
      if (back >= 0 && back < root.settingsFrameworks.length) {
        root.toggleRemoved(root.settingsFrameworks[back].target)
      }
      return
    }
    // Icons: i switches it, 1-4 pick where folders take their color, r and y
    // the icon set, c covers, a applies again; its own row's number goes back.
    // "?" still opens About, which credits the icon sets.
    if (root.iconsOpen) {
      if (key === "i") { root.setTargetEnabled("icons", !root.targetEnabled("icons")); return }
      if (key === "1") { root.setFolderMode("background"); return }
      if (key === "2") { root.setFolderMode("accent"); return }
      if (key === "3") { root.setFolderMode("border"); return }
      if (key === "4") { root.setFolderMode("yaru"); return }
      if (key === "r") { root.setIconSet("reversal"); return }
      if (key === "y") { root.setIconSet("yaru"); return }
      if (key === "c") { root.toggleCovers(); return }
      if (key === "a") { root.reapplyIcons(); return }
      if (key === String(root.iconsRowNumber)) { root.iconsOpen = false; return }
      if (key !== "?") return
    }
    // About: i for an issue or question, g for the source, b for a coffee, ? back.
    if (root.aboutOpen) {
      if (key === "i") root.openLink(root.issuesUrl)
      else if (key === "g") root.openLink(root.repoUrl)
      else if (key === "b") root.openLink(root.coffeeUrl)
      else if (key === "?") root.aboutOpen = false
      return
    }
    if (key === "?") {
      root.openAbout()
      return
    }
    if (key === "r") {
      root.refresh("all")
      return
    }
    var index = parseInt(key, 10) - 1
    if (index >= 0 && index < root.visibleFrameworks.length) {
      var entry = root.visibleFrameworks[index]
      if (entry.menu === true) root.appsOpen = !root.appsOpen
      else if (entry.view === true) root.openIcons()
      else root.setTargetEnabled(entry.target, !root.targetEnabled(entry.target))
    } else if (root.appsListShown) {
      // The drop-down's rows are numbered on from the list above them, and
      // those keys do nothing while it is closed.
      var appIndex = index - root.visibleFrameworks.length
      if (appIndex >= 0 && appIndex < root.appFrameworks.length) {
        var appTarget = root.appFrameworks[appIndex].target
        root.setTargetEnabled(appTarget, !root.targetEnabled(appTarget))
      }
    }
  }

  function refreshStaleApps() {
    // Same absent binary, same silent non-start. Nothing to ask until the
    // presence probe has said the service is there.
    if (!root.dependencyPresent) { root.staleWindows = ({}); root.staleApps = []; return }
    if (!staleProcess.running) staleProcess.running = true
  }

  // One app per line, "Vivaldi (2 windows)" where it has more than one.
  function applyStaleApps(output) {
    var names = []
    var counts = {}
    var lines = (output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var match = /^(.*\S) \(([0-9]+) windows\)$/.exec(line)
      var name = match ? match[1] : line
      if (!root.validStaleName(name) || names.length >= root.staleListed) continue
      names.push(name)
      counts[name] = match ? parseInt(match[2], 10) : 1
    }
    root.staleWindows = counts
    root.staleApps = names
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: refreshProcess
    environment: ({ PATH: root.trustedPath })
    onExited: function() {
      root.activeTarget = ""
      settingsFile.reload()
      root.refreshStaleApps()
    }
  }

  // Measured against the last recorded sync rather than the last theme switch:
  // the question this answers is "did this application start before the palette
  // it is drawing was written", which a toggle changes just as a theme does.
  Process {
    id: staleProcess
    command: [ "/usr/bin/hyprchroma", "stale-apps" ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStaleApps(text)
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      presenceProcess.running = true
      if (root.dependencyPresent) iconsStatusProcess.running = true
    } else {
      root.iconsOpen = false
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        var frameworks = parsed.frameworks || {}
        // Frameworks the user said they did not want. Off is a toggle; removed
        // takes the row out of the panel entirely.
        root.removedTargets = Array.isArray(parsed.removed) ? parsed.removed : []
        root.enabledTargets = {
          gtk: frameworks.gtk !== false,
          qtKde: frameworks.qtKde !== false,
          darkReader: frameworks.darkReader !== false,
          pear: frameworks.pear !== false,
          flatpak: frameworks.flatpak === true,
          browsers: frameworks.browsers === true,
          thunderbird: frameworks.thunderbird === true,
          icons: frameworks.icons === true
        }
        // "force", from before it was removed, now means the confirmation.
        var mode = parsed.restartMode === "force" ? "confirm" : parsed.restartMode
        root.restartMode = root.restartModes.indexOf(mode) !== -1 ? mode : "off"
      } catch (error) {
        root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false, thunderbird: false, icons: false }
        root.restartMode = "off"
      }
    }
    onLoadFailed: {
      root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false, thunderbird: false, icons: false }
      root.restartMode = "off"
    }
    onFileChanged: reload()
  }

  // The applications still showing the previous theme, as the service keeps
  // them: after each sync, and each time a window opens or closes. Watched
  // rather than asked for, so the bar icon's count follows an application
  // being closed without anything here polling.
  FileView {
    id: statusFile
    path: root.statusPath
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var status = JSON.parse(text())
        var names = status.staleApps
        if (Array.isArray(names)) {
          var counts = status.staleWindows
          root.staleWindows = (counts && typeof counts === "object" && !Array.isArray(counts)) ? counts : ({})
          root.staleApps = names.filter(root.validStaleName).slice(0, root.staleListed)
        }
      } catch (error) {
        // A partly written or foreign file: keep the last list rather than
        // flicker the count to zero.
      }
    }
    onFileChanged: reload()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough for the settings rows to stay one line: "Restart apps at
    // theme change" is the longest, beside its icon, key and switch.
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Escape leaves the nearest view first -- the popup, then the guide --
      // so it never strands the user on one they cannot back out of.
      onCloseRequested: {
        if (root.confirmRestartOpen) root.confirmRestartOpen = false
        else if (root.guideOpen) root.guideOpen = false
        else if (root.settingsOpen) root.settingsOpen = false
        else if (root.aboutOpen) root.aboutOpen = false
        else if (root.iconsOpen) root.iconsOpen = false
        else if (root.appsOpen) root.appsOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleKey(text) }
      // Restart All is always Ctrl+Enter: from the list it opens the
      // confirmation, and there it confirms -- a combination, so it cannot be
      // pressed by accident. PanelKeyCatcher reports Enter the same with or
      // without Ctrl held, so this is a Shortcut, which Qt matches before key
      // handling. No auto-repeat, so holding it cannot run both steps.
      Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        autoRepeat: false
        enabled: (root.confirmRestartOpen || root.guideOpen) && root.staleWindowCount > 0
        onActivated: root.confirmRestartOpen ? root.confirmRestart() : root.openRestartConfirm()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(4)

        // Main view matches the fan panel's header: a large mark, a bold
        // title, and a small tracked line under it. Other views keep a title
        // only. Settings and Help stay at the right of the main header.
        Item {
          id: header
          readonly property bool hero: root.mainShown
          width: content.width
          height: header.hero
                  ? Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)
                  : Math.max(heading.implicitHeight, headerIcons.visible ? headerIcons.implicitHeight : 0)

          Text {
            id: heroIcon
            visible: header.hero
            text: "\udb80\udfd8"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Commons.Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            visible: header.hero
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: headerIcons.visible ? headerIcons.left : parent.right
            anchors.rightMargin: headerIcons.visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Omarchroma"
              textFormat: Text.PlainText
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              visible: root.themeStatus() !== ""
              text: root.themeStatus()
              textFormat: Text.PlainText
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }

            Row {
              id: swatchRow
              spacing: Style.space(4)
              visible: root.themeSwatches.length > 0
              // Fade in on each open. Cleared on close, so the next open does
              // not flash the cells that were already showing.
              property bool reveal: root.opened && header.hero
              onRevealChanged: {
                for (var i = 0; i < swatchRepeater.count; i++) {
                  var cell = swatchRepeater.itemAt(i)
                  if (!cell) continue
                  if (reveal) cell.playReveal()
                  else cell.hideSwatch()
                }
              }
              Repeater {
                id: swatchRepeater
                model: root.themeSwatches
                Rectangle {
                  id: swatch
                  required property string modelData
                  required property int index
                  function playReveal() {
                    opacity = 0
                    revealAnim.restart()
                  }
                  function hideSwatch() {
                    revealAnim.stop()
                    opacity = 0
                  }
                  Component.onCompleted: if (swatchRow.reveal) playReveal()
                  width: Style.space(16)
                  height: Style.space(8)
                  radius: Style.space(2)
                  color: modelData
                  opacity: 0
                  border.width: 1
                  border.color: Qt.rgba(root.bar ? root.bar.foreground.r : 1,
                                        root.bar ? root.bar.foreground.g : 1,
                                        root.bar ? root.bar.foreground.b : 1, 0.28)

                  SequentialAnimation {
                    id: revealAnim
                    PauseAnimation { duration: swatch.index * 120 }
                    NumberAnimation {
                      target: swatch
                      property: "opacity"
                      from: 0
                      to: 1
                      duration: 280
                      easing.type: Easing.OutCubic
                    }
                  }
                }
              }
            }
          }

          Text {
            id: heading
            visible: !header.hero
            text: root.confirmRestartOpen
              ? (root.staleWindowCount > 0 ? "Save your work first" : "Nothing to restart")
                : root.settingsOpen
                ? "Settings"
                : root.aboutOpen
                ? "About"
                : root.iconsOpen
                ? "Icons"
                : root.guideOpen
                  ? (root.staleWindowCount > 0 ? root.windowsPhrase(root.staleWindowCount) + " to close"
                                              : "Nothing to close")
                  : ""
            color: root.bar ? root.bar.foreground : Commons.Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
          }

          Row {
            id: headerIcons
            visible: header.hero && root.ready
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(2)

            Button {
              iconText: "\udb81\udc93"
              tooltipText: "Settings  (s)"
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              onClicked: root.settingsOpen = true
            }

            Button {
              iconText: "\udb81\ude25"
              tooltipText: "About and help  (?)"
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              onClicked: root.openAbout()
            }
          }
        }

        // The same confirmation the global hotkey opens -- bound to a key of
        // the user's own choosing in bindings.lua, matching every other
        // hotkey this plugin exposes -- so it works whether the panel was
        // already open or not. Its own small view rather than a dialog of its
        // own kind: the panel is already the one popup this plugin shows.
        Column {
          id: confirmRestart
          visible: root.confirmRestartOpen
          width: content.width
          spacing: Style.space(6)

          Text {
            width: confirmRestart.width
            text: root.staleWindowCount > 0
              ? "These will be closed and reopened on the new theme:"
              : "Nothing is showing the previous theme."
            color: root.bar ? root.bar.foreground : Commons.Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Exactly what will close, by application and window count -- the
          // same list the guide shows, so nothing closes unnamed.
          Repeater {
            model: root.confirmRestartOpen ? root.staleApps : []
            delegate: Text {
              required property var modelData
              width: confirmRestart.width
              text: "\u2022 " + modelData + " \u2014 " + root.windowsPhrase(root.windowsOf(modelData))
              textFormat: Text.PlainText
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // The risks, stated plainly rather than played down: nothing here
          // can promise an application will ask before discarding work.
          Text {
            visible: root.staleWindowCount > 0
            width: confirmRestart.width
            topPadding: Style.space(4)
            text: "\u2022 Unsaved work may be lost\n"
              + "\u2022 Save prompts are up to each app\n"
              + "\u2022 Multi-window apps close without asking"
            color: root.bar ? root.bar.urgent : Commons.Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.staleWindowCount > 0
            width: confirmRestart.width
            text: "Restart  (Ctrl+Enter)"
            iconText: "\udb81\udf09"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.confirmRestart()
          }

          Button {
            width: confirmRestart.width
            text: "Cancel  (Esc)"
            iconText: "󰌍"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.confirmRestartOpen = false
          }
        }

        Column {
          id: guide
          visible: root.guideOpen && !root.confirmRestartOpen
          width: content.width
          spacing: Style.space(6)

          // The heading already says what the list is, so nothing is said twice.
          // Only the empty case needs a word, because an empty list says nothing.
          Text {
            visible: root.staleApps.length === 0
            width: guide.width
            text: "Nothing to close."
            color: Commons.Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.staleApps.slice(0, root.staleShown)

            // Each app with how many of its windows are open, spelled out so it
            // is not taken for a key like the numbers beside removed frameworks.
            delegate: Item {
              id: staleRow
              required property string modelData
              width: guide.width
              height: Math.max(staleName.implicitHeight, staleRowWindows.implicitHeight)

              Text {
                id: staleName
                text: "\u2022  " + staleRow.modelData
                textFormat: Text.PlainText
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.right: staleRowWindows.left
                anchors.rightMargin: Style.space(10)
                elide: Text.ElideRight
              }

              Text {
                id: staleRowWindows
                text: root.windowsPhrase(root.windowsOf(staleRow.modelData))
                // The name's color, dimmed: Commons.Color.muted all but vanishes on some
                // themes' panels, and this is a count to read, not a hint.
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                opacity: 0.7
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
              }
            }
          }

          Text {
            visible: root.staleApps.length > root.staleShown
            width: guide.width
            text: "and " + (root.staleApps.length - root.staleShown) + " more"
            color: Commons.Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Both toggles live here rather than beside the framework list: this
          // is the one place that already talks about applications left on
          // the previous theme, and the only place the user ever sees them.
          PanelSeparator {
            visible: root.staleApps.length > 0 || root.hiddenFrameworks.length > 0
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          }

          // Present in every mode, not only "off": restartMode decides what
          // happens on its own, never whether this still works by hand.
          Button {
            visible: root.staleWindowCount > 0
            width: guide.width
            text: "Restart All\u2026  (Ctrl+Enter)"
            iconText: "\udb81\udf09"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.openRestartConfirm()
          }

          Button {
            width: guide.width
            text: "Back  (/)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.guideOpen = false
          }
        }

        // Settings: the restart switch and which optional frameworks the panel
        // shows. Its own view, on "s", so the list of windows to close on "/"
        // stays just that.
        Column {
          id: settings
          visible: root.settingsOpen && !root.confirmRestartOpen
          width: content.width
          spacing: Style.space(6)

          // Settings, drawn like the framework rows in the panel itself --
          // icon, label, the key that flips it, a switch -- so it reads as the
          // same kind of thing rather than a page of buttons and prose.

          Item {
            width: settings.width
            height: Math.max(Style.spacing.controlHeight, askLabel.implicitHeight)

            Text {
              id: askIcon
              text: "\udb81\udf09"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: askLabel
              text: "Restart apps at theme change"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: askIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: askKey.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            Text {
              id: askKey
              text: "c"
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: askSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: askSwitch
              checked: root.restartMode === "confirm"
              busy: modeProcess.running
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleRestartMode()
            }
          }

          Item {
            width: settings.width
            height: Math.max(Style.spacing.controlHeight, barAlertLabel.implicitHeight)

            Text {
              id: barAlertIcon
              text: "\udb80\udfd8"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: barAlertLabel
              text: "Show alerts on the bar"
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: barAlertIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: barAlertKey.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: barAlertKey
              text: "b"
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: barAlertSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: barAlertSwitch
              checked: root.barAlert
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleBarAlert()
            }
          }

          Text {
            text: "Show in panel"
            color: Commons.Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            topPadding: Style.space(8)
          }

          // Off removes the framework from the panel (reverting it), on puts it
          // back: the same switch and the same key both ways.
          Repeater {
            model: root.settingsFrameworks
            delegate: Item {
              id: shown
              required property var modelData
              required property int index
              width: settings.width
              height: Math.max(Style.spacing.controlHeight, shownLabel.implicitHeight)

              Text {
                id: shownIcon
                text: shown.modelData.icon
                color: root.frameworkRemoved(shown.modelData.target) ? Commons.Color.muted : (root.bar ? root.bar.foreground : Commons.Color.popups.text)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: shownLabel
                text: shown.modelData.label
                color: root.frameworkRemoved(shown.modelData.target) ? Commons.Color.muted : (root.bar ? root.bar.foreground : Commons.Color.popups.text)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: shownIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: shownKey.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }

              Text {
                id: shownKey
                text: String(shown.index + 1)
                color: Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: shownSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              ToggleSwitch {
                id: shownSwitch
                checked: !root.frameworkRemoved(shown.modelData.target)
                busy: restoreProcess.running
                foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.toggleRemoved(shown.modelData.target)
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          }

          // Opens a terminal that asks before each step; nothing is removed
          // from here.
          Button {
            width: settings.width
            text: "Uninstall Omarchroma...  (u)"
            iconText: "\udb80\uddb4"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.openUninstall()
          }

          Button {
            width: settings.width
            text: "Back  (s)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.settingsOpen = false
          }
        }

        // About: versions and license as plain read-outs, then the links as
        // buttons, each with its key.
        Column {
          id: about
          visible: root.aboutOpen && !root.confirmRestartOpen
          width: content.width
          spacing: Style.space(4)

          Repeater {
            model: [
              { label: "Plugin", value: root.expectedVersion ? root.expectedVersion : "unknown" },
              { label: "Service", value: root.installedVersion ? "hyprchroma " + root.installedVersion : "not installed" },
              { label: "License", value: (root.pluginLicense !== "" ? root.pluginLicense : "MIT")
                  + (root.pluginAuthor !== "" ? " \u00b7 \u00a9 " + root.pluginAuthor : "") },
              { label: "Reversal icons", value: "yeyushengfan258 \u00b7 GPL-3.0" },
              { label: "Yaru icons", value: "Ubuntu community \u00b7 CC BY-SA 4.0" }
            ]
            delegate: Item {
              id: fact
              required property var modelData
              width: about.width
              height: Math.max(factLabel.implicitHeight, factValue.implicitHeight)

              Text {
                id: factLabel
                text: fact.modelData.label
                color: Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: factValue
                text: fact.modelData.value
                textFormat: Text.PlainText
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
                anchors.left: factLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideLeft
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          }

          Button {
            width: about.width
            text: "Open issue/ask for help  (i)"
            iconText: "\udb81\ude25"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.openLink(root.issuesUrl)
          }

          Button {
            width: about.width
            text: "Source on GitHub  (g)"
            iconText: "\udb80\udea4"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.openLink(root.repoUrl)
          }

          Button {
            width: about.width
            text: "Buy me a coffee  (b)"
            iconText: "\udb80\udd76"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.openLink(root.coffeeUrl)
          }

          Button {
            width: about.width
            text: "Back  (?)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.aboutOpen = false
          }
        }

        // Icons: the framework's switch, then where folders take their color,
        // the icon set, and app covers. Choices made while it is off are kept
        // and applied once it is switched on.
        Column {
          id: iconsView
          visible: root.iconsOpen && !root.confirmRestartOpen
          width: content.width
          spacing: Style.space(4)

          Item {
            width: iconsView.width
            height: Math.max(Style.spacing.controlHeight, iconsSwitchLabel.implicitHeight)

            Text {
              id: iconsSwitchIcon
              text: ""
              color: root.targetEnabled("icons") ? root.folderFace() : Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Behavior on color { ColorAnimation { duration: 220 } }
            }

            Text {
              id: iconsSwitchLabel
              text: "Icons follow the theme"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: iconsSwitchIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: iconsSwitchKey.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            Text {
              id: iconsSwitchKey
              text: "i"
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: iconsSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: iconsSwitch
              checked: root.targetEnabled("icons")
              busy: refreshProcess.running && root.activeTarget === "icons"
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setTargetEnabled("icons", !checked)
            }
          }

          Text {
            width: iconsView.width
            text: refreshProcess.running && root.activeTarget === "icons"
              ? (root.targetEnabled("icons") ? "Applying icons..." : "Restoring each theme's own icons...")
              : root.targetEnabled("icons")
                ? "Every Omarchy theme uses these; a theme change recolors them."
                : "Off: each theme keeps its own icons. Choices below apply once on."
            textFormat: Text.PlainText
            color: Commons.Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Item { width: iconsView.width; height: Style.space(4) }

          PanelSectionHeader {
            text: "Folder color"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Repeater {
            model: root.folderModes
            delegate: Item {
              id: modeRow
              required property var modelData
              readonly property bool selected: root.folderMode === modelData.id
              readonly property var info: (root.iconStatus.modes || {})[modelData.id] || {}
              readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.popups.text
              width: iconsView.width
              height: Style.spacing.controlHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Qt.rgba(modeRow.fg.r, modeRow.fg.g, modeRow.fg.b,
                               modeRow.selected ? 0.10 : (modeMouse.containsMouse ? 0.05 : 0))
              }

              Rectangle {
                id: modeSwatch
                width: Style.space(18)
                height: Style.space(14)
                radius: Math.min(Style.cornerRadius, Style.space(3))
                color: root.validHex(modeRow.info.face) ? modeRow.info.face : "transparent"
                border.width: 1
                border.color: Qt.rgba(modeRow.fg.r, modeRow.fg.g, modeRow.fg.b, 0.28)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: modeRow.modelData.label
                textFormat: Text.PlainText
                color: modeRow.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: modeRow.selected
                anchors.left: modeSwatch.right
                anchors.leftMargin: Style.space(10)
                anchors.right: modeHex.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }

              Text {
                id: modeHex
                text: root.validHex(modeRow.info.face) ? modeRow.info.face : ""
                textFormat: Text.PlainText
                color: Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: modeKey.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modeKey
                text: modeRow.selected ? "" : modeRow.modelData.key
                textFormat: Text.PlainText
                color: modeRow.selected ? modeRow.fg : Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                width: Style.space(12)
                horizontalAlignment: Text.AlignHCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                id: modeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFolderMode(modeRow.modelData.id)
              }
            }
          }

          Item { width: iconsView.width; height: Style.space(6) }

          PanelSectionHeader {
            text: "Icon set  (r / y)"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          ButtonGroup {
            width: iconsView.width
            value: root.iconSet
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            focusable: false
            options: [
              { value: "reversal", label: "Reversal" + (root.setInstalled("reversal") ? "" : " (not installed)"),
                tooltip: root.setInstalled("reversal") ? "" : "Not installed: press r to install it from the AUR (reversal-icon-theme-git)" },
              { value: "yaru", label: "Yaru" + (root.setInstalled("yaru") ? "" : " (missing)"),
                tooltip: root.setInstalled("yaru") ? "" : "Not installed (Omarchy normally ships it): sudo pacman -S yaru-icon-theme" }
            ]
            onChanged: function(value) { root.setIconSet(value) }
          }

          Item { width: iconsView.width; height: Style.space(2) }

          Item {
            width: iconsView.width
            height: Math.max(Style.spacing.controlHeight, coversLabel.implicitHeight)
            opacity: root.coversApply ? 1 : 0.45

            Text {
              id: coversIcon
              text: "󰁝"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: coversLabel
              text: root.coversApply ? "Cover missing app icons" : "Covers: Reversal only"
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: coversIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: coversKey.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            Text {
              id: coversKey
              text: "c"
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: coversSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: coversSwitch
              checked: root.iconCovers && root.coversApply
              interactive: root.coversApply
              busy: root.iconsBusy
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleCovers()
            }
          }

          Item { width: iconsView.width; height: Style.space(4) }
          PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text }
          Item { width: iconsView.width; height: Style.space(4) }

          Repeater {
            model: [
              { label: "Inherits", value: root.targetEnabled("icons") ? String(root.iconStatus.base || "") : "off" },
              { label: "Folder source", value: root.validHex(root.iconStatus.source) ? root.iconStatus.source : "" },
              { label: "App covers", value: root.iconsCoversText() },
              { label: "Last applied", value: root.iconsAppliedText() }
            ]
            delegate: Item {
              id: iconFact
              required property var modelData
              width: iconsView.width
              height: Math.max(iconFactLabel.implicitHeight, iconFactValue.implicitHeight) + Style.space(2)

              Text {
                id: iconFactLabel
                text: iconFact.modelData.label
                color: Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: iconFactValue
                text: iconFact.modelData.value
                textFormat: Text.PlainText
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                anchors.left: iconFactLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideLeft
              }
            }
          }

          Text {
            readonly property string problem: root.iconsError !== "" ? root.iconsError
              : (root.targetEnabled("icons") ? String(root.iconStatus.error || "").slice(0, 160) : "")
            visible: root.iconsBusy || problem !== ""
            width: iconsView.width
            topPadding: Style.space(4)
            text: root.iconsBusy ? "Applying..." : problem
            textFormat: Text.PlainText
            color: root.iconsBusy ? Commons.Color.muted : (root.bar ? root.bar.urgent : Commons.Color.urgent)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text }

          // Reversal is the default pack; until it is installed, Icons uses
          // Yaru and this offers it.
          Button {
            width: iconsView.width
            visible: root.iconStatusKnown && !root.setInstalled("reversal")
            enabled: !reversalProcess.running
            text: "Install Reversal...  (r)"
            iconText: "\udb80\uddda"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.installReversal()
          }

          Button {
            width: iconsView.width
            visible: root.targetEnabled("icons")
            enabled: !root.iconsBusy
            text: root.iconsBusy ? "Applying..." : "Apply again  (a)"
            iconText: "󰑐"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.reapplyIcons()
          }

          Button {
            width: iconsView.width
            text: "Back  (" + root.iconsRowNumber + ")"
            iconText: "󰌍"
            foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
            onClicked: root.iconsOpen = false
          }
        }

        // Same break the fan panel uses between its header and its controls:
        // a gap, a rule, and a gap. It sits above the status line.
        Item {
          visible: header.hero && root.ready
          width: parent.width
          height: Style.space(10)
        }

        PanelSeparator {
          visible: header.hero && root.ready
          foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
        }

        Item {
          visible: header.hero && root.ready
          width: parent.width
          height: Style.space(10)
        }

        Text {
          visible: root.mainShown && root.ready
          text: refreshProcess.running
            ? (root.targetEnabled(root.activeTarget)
                ? "Synchronizing " + root.activeTarget + "..."
                : "Reverting " + root.activeTarget + "...")
            : "Off restores the pre-Omarchroma look."
          color: Commons.Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        // Until hyprchroma exists there is exactly one thing to do from this
        // panel, so it gets exactly one control: the header above already
        // says what panel this is, and this button says the one action
        // available, in the same "Label  (key)" shape as the buttons below
        // it once the service is ready. Everything below this block -- the
        // framework toggles, the separator, refresh, the close-apps count --
        // is real only once the service is; each is gated on root.ready for
        // the same reason this replaces the old descriptive sentence.
        Button {
          visible: root.mainShown && root.dependencyChecked && !root.ready
          width: content.width
          enabled: !root.installing
          text: root.installing
            ? "Working..."
            : (!root.dependencyPresent
                ? "Install  (i)"
                : root.outdated ? "Update  (i)" : "Start  (i)")
          // Lit in the theme's alert color while the service is behind this
          // panel -- the color the bar icon takes, since this is what clears
          // it: a fill and a solid border of it, under the panel's own text,
          // which stays readable where a theme's alert color is a muted one.
          // Drawn here rather than through the kit's "selected" state, which a
          // theme may fix to a color of its own.
          readonly property color alertColor: root.bar ? root.bar.urgent : Commons.Color.urgent
          foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          background: root.serviceAlert ? Util.alpha(alertColor, 0.30) : "transparent"

          Rectangle {
            anchors.fill: parent
            visible: root.serviceAlert
            color: "transparent"
            radius: parent.radius
            border.width: 1
            border.color: parent.alertColor
          }
          onClicked: root.installDependency()
        }

        Repeater {
          model: root.visibleFrameworks

          delegate: Item {
            id: row
            visible: root.mainShown && root.ready
            required property var modelData
            required property int index
            width: content.width
            height: Math.max(Style.spacing.controlHeight, label.implicitHeight)

            // The whole row opens the drop-down; there is no switch to aim at.
            MouseArea {
              visible: row.modelData.menu === true
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.appsOpen = !root.appsOpen
            }

            // Icons: the row opens its view; the switch is inside it.
            MouseArea {
              visible: row.modelData.view === true
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openIcons()
            }

            Text {
              id: icon
              text: row.modelData.icon
              // The Icons row's folder is drawn in the folder color itself.
              color: row.modelData.view === true && root.targetEnabled("icons")
                ? root.folderFace()
                : (root.bar ? root.bar.foreground : Commons.Color.popups.text)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: label
              text: row.modelData.label
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: icon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: rowState.visible ? rowState.left : keyHint.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            // A view row has no switch to show its state, so it says it.
            Text {
              id: rowState
              visible: row.modelData.view === true
              text: root.targetEnabled("icons") ? (root.iconSet === "yaru" ? "Yaru" : "Reversal") : "Off"
              textFormat: Text.PlainText
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: keyHint.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            // The key that toggles this row, shown so the shortcut is
            // discoverable without reading the README.
            Text {
              id: keyHint
              text: String(row.index + 1)
              color: Commons.Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: toggle.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: toggle
              visible: row.modelData.menu !== true && row.modelData.view !== true
              checked: root.targetEnabled(row.modelData.target)
              busy: refreshProcess.running
              foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setTargetEnabled(row.modelData.target, !checked)
            }

            // Where the others have their switch, so the keys stay in a column.
            Text {
              visible: row.modelData.menu === true || row.modelData.view === true
              text: row.modelData.view === true ? "\udb80\udd42"
                : (root.appsOpen ? "\udb80\udd43" : "\udb80\udd40")
              color: root.bar ? root.bar.foreground : Commons.Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              // Larger and bold, to hold its own beside the switches above it.
              font.pixelSize: Math.round(Style.font.body * 1.6)
              font.bold: true
              anchors.centerIn: toggle
            }
          }
        }

        // The Additional Apps drop-down: Thunderbird and Pear Desktop, the two
        // frameworks behind that row. It is the last row, so this sits under it.
        Column {
          id: apps
          visible: root.appsListShown && root.mainShown && root.ready
          width: content.width
          leftPadding: Style.space(16)
          spacing: Style.space(4)

          Repeater {
            model: root.appFrameworks
            delegate: Item {
              id: appRow
              required property var modelData
              required property int index
              width: apps.width - apps.leftPadding
              height: Math.max(Style.spacing.controlHeight, appLabel.implicitHeight)

              Text {
                id: appIcon
                text: appRow.modelData.icon
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: appLabel
                text: appRow.modelData.label
                color: root.bar ? root.bar.foreground : Commons.Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: appIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: appKey.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }

              Text {
                id: appKey
                text: String(root.visibleFrameworks.length + appRow.index + 1)
                color: Commons.Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: appSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              ToggleSwitch {
                id: appSwitch
                checked: root.targetEnabled(appRow.modelData.target)
                busy: refreshProcess.running
                foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.setTargetEnabled(appRow.modelData.target, !checked)
              }
            }
          }
        }

        // Gated on root.ready, not just !guideOpen: these act on a running
        // service, and with none installed they were showing "Refresh
        // enabled" and "Nothing to close" over an otherwise empty panel --
        // controls for a thing that does not exist yet.
        PanelSeparator {
          visible: root.mainShown && root.ready
          foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
        }


        Button {
          visible: root.mainShown && root.ready
          width: content.width
          text: "Refresh enabled  (r)"
          iconText: "󰑐"
          foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          enabled: !refreshProcess.running
          onClicked: root.refresh("all")
        }

        // Reachable by mouse as well as by "/", and carries the count so the
        // number of windows waiting is visible without opening it.
        Button {
          visible: root.mainShown && root.ready
          width: content.width
          text: root.staleWindowCount > 0
            ? "View " + root.windowsPhrase(root.staleWindowCount) + " to close  (/)"
            : "Nothing to close  (/)"
          iconText: "󰖯"
          foreground: root.bar ? root.bar.foreground : Commons.Color.popups.text
          onClicked: {
            root.refreshStaleApps()
            root.guideOpen = true
          }
        }
      }
    }
  }
}
