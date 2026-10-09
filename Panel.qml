import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
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

  readonly property string settingsPath: stateDir + "/settings.json"
  readonly property string statusPath: stateDir + "/status.json"

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
  readonly property bool outdated: dependencyPresent && installedVersion !== ""
    && expectedVersion !== "" && root.olderThan(installedVersion, expectedVersion)

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
        root.expectedVersion = String(JSON.parse(text()).version || "")
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

  function frameworkRemoved(target) {
    return root.removedTargets.indexOf(root.targetKey(target)) !== -1
  }

  // Remove or add back, by the same key in Settings: one list, one action that
  // flips, so taking a framework out and putting it back are the same gesture.
  function toggleRemoved(target) {
    if (root.frameworkRemoved(target)) root.restoreFramework(target)
    else root.removeFramework(target)
  }

  readonly property string issuesUrl: "https://github.com/NobleDoodle/omarchroma/issues"

  function openHelp() {
    Qt.openUrlExternally(root.issuesUrl)
    root.guideOpen = false
    root.settingsOpen = false
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
    { target: "pear", label: "Pear Desktop", icon: "󰎆", optional: true },
    { target: "flatpak", label: "Flatpak apps", icon: "󰏗", optional: true },
    { target: "browsers", label: "Additional browsers", icon: "󰖟", optional: true }
  ]

  // Flatpak and additional browsers are opt-in -- one widens what every
  // sandboxed app may read, the other writes into browser profiles -- so they
  // alone are off unless settings record them on.
  property var enabledTargets: ({
    gtk: true,
    qtKde: true,
    darkReader: true,
    pear: true,
    flatpak: false,
    browsers: false
  })

  function targetKey(target) {
    if (target === "qt-kde") return "qtKde"
    if (target === "dark-reader") return "darkReader"
    return target
  }

  function targetEnabled(target) {
    var key = targetKey(target)
    if (key === "flatpak" || key === "browsers") return enabledTargets[key] === true
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
      browsers: enabledTargets.browsers === true
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
    root.close()
  }

  // What the popup's "yes" does: close it, then restart, in that order, so a
  // restart that takes a moment is not shown behind a popup still claiming to
  // be asking.
  function confirmRestart() {
    if (!root.confirmRestartOpen || root.staleWindowCount === 0) return
    root.confirmRestartOpen = false
    root.runRestart()
  }

  // Every way to a restart leads here first -- the guide's Restart All, its
  // "a", the global hotkey and Confirm mode alike -- so nothing restarts
  // without the user having seen what will close and what it can cost.
  function openRestartConfirm() {
    root.refreshStaleApps()
    root.guideOpen = false
    root.settingsOpen = false
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
      root.guideOpen = !root.guideOpen
      if (root.guideOpen) root.refreshStaleApps()
      return
    }
    if (key === "s") {
      root.guideOpen = false
      root.settingsOpen = !root.settingsOpen
      return
    }
    // While the guide is up, a digit means one of the removed frameworks listed
    // there -- not one of the toggles, whose rows are not on screen.
    if (root.guideOpen) {
      // Opens the confirmation, never restarts on its own.
      if (key === "a" && root.staleWindowCount > 0) {
        root.openRestartConfirm()
        return
      }
      return
    }
    // Settings: c flips the restart mode, and a digit removes or adds back the
    // framework shown beside it.
    if (root.settingsOpen) {
      if (key === "c") { root.toggleRestartMode(); return }
      var back = parseInt(key, 10) - 1
      if (back >= 0 && back < root.settingsFrameworks.length) {
        root.toggleRemoved(root.settingsFrameworks[back].target)
      }
      return
    }
    if (key === "?") {
      root.openHelp()
      return
    }
    if (key === "r") {
      root.refresh("all")
      return
    }
    var index = parseInt(key, 10) - 1
    if (index >= 0 && index < root.visibleFrameworks.length) {
      var target = root.visibleFrameworks[index].target
      root.setTargetEnabled(target, !root.targetEnabled(target))
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

  onOpenedChanged: if (root.opened) presenceProcess.running = true

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
          browsers: frameworks.browsers === true
        }
        // "force", from before it was removed, now means the confirmation.
        var mode = parsed.restartMode === "force" ? "confirm" : parsed.restartMode
        root.restartMode = root.restartModes.indexOf(mode) !== -1 ? mode : "off"
      } catch (error) {
        root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false }
        root.restartMode = "off"
      }
    }
    onLoadFailed: {
      root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false }
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
    contentWidth: panel.fittedContentWidth(Style.space(300))
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
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleKey(text) }
      // The only key that confirms a restart: a combination, so it cannot be
      // pressed by accident. PanelKeyCatcher reports Enter the same with or
      // without Ctrl held, so this is a Shortcut, which Qt matches before key
      // handling -- and only while the confirmation is up, with something to
      // restart.
      Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        enabled: root.confirmRestartOpen && root.staleWindowCount > 0
        onActivated: root.confirmRestart()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(4)

        Text {
          text: root.confirmRestartOpen
            ? (root.staleWindowCount > 0 ? "Save your work first" : "Nothing to restart")
            : root.settingsOpen
              ? "Settings"
              : root.guideOpen
              ? (root.staleWindowCount > 0 ? root.windowsPhrase(root.staleWindowCount) + " to close"
                                          : "Nothing to close")

              : "Omarchroma"
          color: root.bar ? root.bar.foreground : Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
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
            color: root.bar ? root.bar.foreground : Color.popups.text
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
              color: root.bar ? root.bar.foreground : Color.popups.text
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
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.staleWindowCount > 0
            width: confirmRestart.width
            text: "Restart  (Ctrl+Enter)"
            iconText: "\udb81\udf09"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.confirmRestart()
          }

          Button {
            width: confirmRestart.width
            text: "Cancel  (Esc)"
            iconText: "󰌍"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
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
            color: Color.muted
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
                color: root.bar ? root.bar.foreground : Color.popups.text
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
                // The name's color, dimmed: Color.muted all but vanishes on some
                // themes' panels, and this is a count to read, not a hint.
                color: root.bar ? root.bar.foreground : Color.popups.text
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
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Both toggles live here rather than beside the framework list: this
          // is the one place that already talks about applications left on
          // the previous theme, and the only place the user ever sees them.
          PanelSeparator {
            visible: root.staleApps.length > 0 || root.hiddenFrameworks.length > 0
            foreground: root.bar ? root.bar.foreground : Color.popups.text
          }

          // Present in every mode, not only "off": restartMode decides what
          // happens on its own, never whether this still works by hand.
          Button {
            visible: root.staleWindowCount > 0
            width: guide.width
            text: "Restart All\u2026  (a)"
            iconText: "\udb81\udf09"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.openRestartConfirm()
          }

          Button {
            width: guide.width
            text: "Back  (/)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
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
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: askLabel
              text: "Restart apps at\ntheme change"
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: askIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: askKey.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              // Two lines, broken by hand: wider than the panel in its own
              // font, and a word wrap left "change" alone on the second.
            }

            Text {
              id: askKey
              text: "c"
              color: Color.muted
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
              foreground: root.bar ? root.bar.foreground : Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleRestartMode()
            }
          }

          Text {
            text: "Show in panel"
            color: Color.muted
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
                color: root.frameworkRemoved(shown.modelData.target) ? Color.muted : (root.bar ? root.bar.foreground : Color.popups.text)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: shownLabel
                text: shown.modelData.label
                color: root.frameworkRemoved(shown.modelData.target) ? Color.muted : (root.bar ? root.bar.foreground : Color.popups.text)
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
                color: Color.muted
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
                foreground: root.bar ? root.bar.foreground : Color.popups.text
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.toggleRemoved(shown.modelData.target)
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Color.popups.text
          }

          Button {
            width: settings.width
            text: "Back  (s)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.settingsOpen = false
          }
        }

        Text {
          visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
          text: refreshProcess.running
            ? (root.targetEnabled(root.activeTarget)
                ? "Synchronizing " + root.activeTarget + "..."
                : "Reverting " + root.activeTarget + "...")
            : "Off restores the pre-Omarchroma look."
          color: Color.muted
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
          visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.dependencyChecked && !root.ready
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
          readonly property color alertColor: root.bar ? root.bar.urgent : Color.urgent
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          background: root.outdated ? Util.alpha(alertColor, 0.30) : "transparent"

          Rectangle {
            anchors.fill: parent
            visible: root.outdated
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
            visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
            required property var modelData
            required property int index
            width: content.width
            height: Math.max(Style.spacing.controlHeight, label.implicitHeight)

            Text {
              id: icon
              text: row.modelData.icon
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: label
              text: row.modelData.label
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: icon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: keyHint.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            // The key that toggles this row, shown so the shortcut is
            // discoverable without reading the README.
            Text {
              id: keyHint
              text: String(row.index + 1)
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: toggle.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: toggle
              checked: root.targetEnabled(row.modelData.target)
              busy: refreshProcess.running
              foreground: root.bar ? root.bar.foreground : Color.popups.text
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setTargetEnabled(row.modelData.target, !checked)
            }
          }
        }

        // Gated on root.ready, not just !guideOpen: these act on a running
        // service, and with none installed they were showing "Refresh
        // enabled" and "Nothing to close" over an otherwise empty panel --
        // controls for a thing that does not exist yet.
        PanelSeparator {
          visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
          foreground: root.bar ? root.bar.foreground : Color.popups.text
        }


        Button {
          visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
          width: content.width
          text: "Refresh enabled  (r)"
          iconText: "󰑐"
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          enabled: !refreshProcess.running
          onClicked: root.refresh("all")
        }

        // The list on "/", with Settings and Help beside it as icons alone --
        // one row, not three. Reachable by mouse as well as by key; each icon
        // names itself and its key in its tooltip.
        Row {
          id: bottomRow
          visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
          width: content.width
          spacing: Style.space(4)
          readonly property real iconWidth: Style.spacing.controlHeight

          Button {
            visible: !root.guideOpen && !root.settingsOpen && !root.confirmRestartOpen && root.ready
            width: bottomRow.width - 2 * (bottomRow.iconWidth + bottomRow.spacing)
            text: root.staleWindowCount > 0
              ? "View " + root.windowsPhrase(root.staleWindowCount) + " to close  (/)"
              : "Nothing to close  (/)"
            iconText: "󰖯"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: {
              root.refreshStaleApps()
              root.guideOpen = true
            }
          }

          Button {
            width: bottomRow.iconWidth
            iconText: "\udb81\udc93"
            tooltipText: "Settings  (s)"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.settingsOpen = true
          }

          Button {
            width: bottomRow.iconWidth
            iconText: "\udb81\ude25"
            tooltipText: "Help: report an issue or ask a question  (?)"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.openHelp()
          }
        }
      }
    }
  }
}
