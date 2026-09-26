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
    onLoaded: {
      try {
        root.expectedVersion = String(JSON.parse(text()).version || "")
      } catch (error) {
        root.expectedVersion = ""
      }
    }
  }

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

  // The guide replaces the panel body rather than sitting inside it: the list
  // is as long as the user has windows open, and growing the panel by one row
  // per application would push the frameworks off the screen.
  property bool guideOpen: false

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

  readonly property var allFrameworks: [
    { target: "gtk", label: "GTK and GNOME", icon: "󰍛" },
    { target: "qt-kde", label: "Qt and KDE", icon: "󰖯" },
    { target: "dark-reader", label: "Dark Reader", icon: "󰈈" },
    { target: "pear", label: "Pear Desktop", icon: "󰎆" },
    { target: "flatpak", label: "Flatpak apps", icon: "󰏗" },
    { target: "browsers", label: "Additional browsers", icon: "󰖟" }
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
    // "/" rather than "?" so no shift is needed, and rather than "h" because
    // PanelKeyCatcher consumes h/j/k/l before a panel sees them -- the same
    // reason the framework rows are numbered.
    if (key === "/") {
      root.guideOpen = !root.guideOpen
      if (root.guideOpen) root.refreshStaleApps()
      return
    }
    // While the guide is up, a digit means one of the removed frameworks listed
    // there -- not one of the toggles, whose rows are not on screen.
    if (root.guideOpen) {
      var back = parseInt(key, 10) - 1
      if (back >= 0 && back < root.hiddenFrameworks.length) {
        root.restoreFramework(root.hiddenFrameworks[back].target)
      }
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
    if (!root.dependencyPresent) { root.staleApps = []; return }
    if (!staleProcess.running) staleProcess.running = true
  }

  function applyStaleApps(output) {
    var names = []
    var lines = (output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name !== "") names.push(name)
    }
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
      } catch (error) {
        root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false }
      }
    }
    onLoadFailed: root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true, flatpak: false, browsers: false }
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
        var names = JSON.parse(text()).staleApps
        if (Array.isArray(names))
          root.staleApps = names.filter(function(name) { return typeof name === "string" && name !== "" })
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
      // Escape leaves the guide first, so it never strands the user on a view
      // they cannot back out of.
      onCloseRequested: {
        if (root.guideOpen) root.guideOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleKey(text) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: root.guideOpen
            ? (root.hiddenFrameworks.length > 0
                ? "Applications to close, and what you removed"
                : "Applications to close")
            : "Omarchroma"
          color: root.bar ? root.bar.foreground : Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Column {
          id: guide
          visible: root.guideOpen
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

          // Removing a framework takes its row out of the panel, so this is the only
          // place it still exists to be put back. Kept behind the same key as the
          // close list rather than given a view of its own: both are things you deal
          // with occasionally, and neither belongs in the panel body.
          Text {
            visible: root.hiddenFrameworks.length > 0
            width: guide.width
            text: "Removed — press the number to put one back"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            topPadding: Style.space(6)
          }

          Repeater {
            model: root.hiddenFrameworks
            delegate: Item {
              id: gone
              required property var modelData
              required property int index
              width: guide.width
              height: Math.max(Style.spacing.controlHeight, goneLabel.implicitHeight)

              Text {
                id: goneIcon
                text: gone.modelData.icon
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: goneLabel
                text: gone.modelData.label
                color: root.bar ? root.bar.foreground : Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.left: goneIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: goneKey.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }

              Text {
                id: goneKey
                text: String(gone.index + 1)
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.restoreFramework(gone.modelData.target)
              }
            }
          }

          Repeater {
            model: root.staleApps.slice(0, root.staleShown)

            delegate: Text {
              required property string modelData
              width: guide.width
              text: "\u2022  " + modelData
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
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

          Button {
            width: guide.width
            text: "Back  (/)"
            iconText: "\udb80\udf0d"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: root.guideOpen = false
          }
        }

        Text {
          visible: !root.guideOpen && root.ready
          text: refreshProcess.running
            ? (root.targetEnabled(root.activeTarget)
                ? "Synchronizing " + root.activeTarget + "..."
                : "Reverting " + root.activeTarget + "...")
            : "Switching one off restores how it looked before Omarchroma."
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
          visible: !root.guideOpen && root.dependencyChecked && !root.ready
          width: content.width
          enabled: !root.installing
          text: root.installing
            ? "Working..."
            : (!root.dependencyPresent
                ? "Install  (i)"
                : root.outdated ? "Update  (i)" : "Start  (i)")
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          onClicked: root.installDependency()
        }

        Repeater {
          model: root.visibleFrameworks

          delegate: Item {
            id: row
            visible: !root.guideOpen && root.ready
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
          visible: !root.guideOpen && root.ready
          foreground: root.bar ? root.bar.foreground : Color.popups.text
        }


        Button {
          visible: !root.guideOpen && root.ready
          width: content.width
          text: "Refresh enabled  (r)"
          iconText: "󰑐"
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          enabled: !refreshProcess.running
          onClicked: root.refresh("all")
        }

        // Reachable by mouse as well as by "/", and carries the count so the
        // number of applications waiting is visible without opening it.
        Button {
          visible: !root.guideOpen && root.ready
          width: content.width
          text: root.staleApps.length > 0
            ? root.staleApps.length + " to close  (/)"
            : "Nothing to close  (/)"
          iconText: "󰖯"
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          onClicked: {
            root.refreshStaleApps()
            root.guideOpen = true
          }
        }
      }
    }
  }
}
