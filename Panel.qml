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
  readonly property string settingsPath: stateDir + "/settings.json"

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

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: refreshProcess
    onExited: function() {
      root.activeTarget = ""
      settingsFile.reload()
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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleKey(text) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "Omarchroma"
          color: root.bar ? root.bar.foreground : Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          text: refreshProcess.running
            ? (root.targetEnabled(root.activeTarget)
                ? "Synchronizing " + root.activeTarget + "..."
                : "Reverting " + root.activeTarget + "...")
            : "Press a number to toggle, r to refresh. Switching one off "
              + "restores how it looked before Omarchroma."
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
          foreground: root.bar ? root.bar.foreground : Color.popups.text
        }

        Button {
          width: content.width
          text: "Refresh enabled  (r)"
          iconText: "󰑐"
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          enabled: !refreshProcess.running
          onClicked: root.refresh("all")
        }
      }
    }
  }
}
