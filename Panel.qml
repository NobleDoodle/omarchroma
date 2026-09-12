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
    ? Quickshell.env("XDG_STATE_HOME") + "/omarchroma"
    : Quickshell.env("HOME") + "/.local/state/omarchroma"
  readonly property string dataDir: Quickshell.env("XDG_DATA_HOME") !== ""
    ? Quickshell.env("XDG_DATA_HOME") + "/omarchroma"
    : Quickshell.env("HOME") + "/.local/share/omarchroma"
  // Commands these run resolve from here, not from the PATH the shell happened
  // to inherit. They start unattended -- at login, and on every window event --
  // so a directory earlier in the ambient PATH holding something called jq or
  // hyprctl would be executed with nobody watching. Everything they call lives
  // in a root-owned system directory; the last entry is Omarchy's own. The
  // rest of the environment is preserved, so HOME and the session bus survive.
  // Fixed absolute identities. /usr/local/* is excluded because nothing
  // this plugin invokes lives there and it is the entry most often left
  // group-writable; the helpers launched below re-derive and verify their
  // own PATH regardless, so this is a floor rather than the whole defence.
  readonly property string trustedPath: "/usr/bin:/usr/share/omarchy/bin"

  readonly property string settingsPath: stateDir + "/settings.json"

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
  readonly property var frameworks: [
    { target: "gtk", label: "GTK and GNOME", icon: "󰍛" },
    { target: "qt-kde", label: "Qt and KDE", icon: "󰖯" },
    { target: "dark-reader", label: "Dark Reader", icon: "󰈈" },
    { target: "pear", label: "Pear Desktop", icon: "󰎆" }
  ]

  property var enabledTargets: ({
    gtk: true,
    qtKde: true,
    darkReader: true,
    pear: true
  })

  function targetKey(target) {
    if (target === "qt-kde") return "qtKde"
    if (target === "dark-reader") return "darkReader"
    return target
  }

  function targetEnabled(target) {
    var key = targetKey(target)
    return enabledTargets[key] !== false
  }

  function setTargetEnabled(target, enabled) {
    if (refreshProcess.running) return
    var key = targetKey(target)
    var next = {
      gtk: enabledTargets.gtk !== false,
      qtKde: enabledTargets.qtKde !== false,
      darkReader: enabledTargets.darkReader !== false,
      pear: enabledTargets.pear !== false
    }
    next[key] = enabled
    enabledTargets = next
    activeTarget = target
    refreshProcess.command = [
      Quickshell.env("HOME") + "/.local/bin/omarchroma-sync",
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
      Quickshell.env("HOME") + "/.local/bin/omarchroma-sync",
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
    // "/" rather than "?" so no shift is needed, and rather than "h" because
    // PanelKeyCatcher consumes h/j/k/l before a panel sees them -- the same
    // reason the framework rows are numbered.
    if (key === "/") {
      root.guideOpen = !root.guideOpen
      if (root.guideOpen) root.refreshStaleApps()
      return
    }
    // While the guide is up its contents are being read, not acted on; a digit
    // would otherwise toggle a framework whose row is not on screen.
    if (root.guideOpen) return
    if (key === "r") {
      root.refresh("all")
      return
    }
    var index = parseInt(key, 10) - 1
    if (index >= 0 && index < root.frameworks.length) {
      var target = root.frameworks[index].target
      root.setTargetEnabled(target, !root.targetEnabled(target))
    }
  }

  function refreshStaleApps() {
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
    command: [
      Quickshell.env("HOME") + "/.local/bin/omarchroma-state",
      "--state-dir", root.stateDir,
      "--data-dir", root.dataDir,
      "report-stale-apps", "--since-last-sync"
    ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStaleApps(text)
    }
  }

  onOpenedChanged: if (root.opened) root.refreshStaleApps()

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        var frameworks = parsed.frameworks || {}
        root.enabledTargets = {
          gtk: frameworks.gtk !== false,
          qtKde: frameworks.qtKde !== false,
          darkReader: frameworks.darkReader !== false,
          pear: frameworks.pear !== false
        }
      } catch (error) {
        root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true }
      }
    }
    onLoadFailed: root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, pear: true }
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
          text: root.guideOpen ? "Applications to close" : "Omarchroma"
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
          visible: !root.guideOpen
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

        Repeater {
          model: root.frameworks

          delegate: Item {
            id: row
            visible: !root.guideOpen
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

        PanelSeparator {
          visible: !root.guideOpen
          foreground: root.bar ? root.bar.foreground : Color.popups.text
        }


        Button {
          visible: !root.guideOpen
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
          visible: !root.guideOpen
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
