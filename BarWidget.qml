import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.nobledoodle.omarchroma"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  // Keep theme status inside the panel; the bar stays neutral.
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function togglePanel() { root.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Driving the panel's own functions rather than shelling out again keeps one
  // implementation of "what does toggling this mean": the panel holds the
  // current state, guards against a run already in progress, and reloads
  // settings when the run finishes. The panel is loaded eagerly, so these work
  // whether or not it has ever been opened.
  function toggleFramework(target) {
    var panel = panelLoader.item
    if (!panel) return
    panel.setTargetEnabled(target, !panel.targetEnabled(target))
  }

  function refreshEnabled() {
    if (panelLoader.item) panelLoader.item.refresh("all")
  }

  function injectPanel() {
    var panel = panelLoader.item
    if (!panel) return
    if ("hostWidget" in panel) panel.hostWidget = root
    if ("anchorItem" in panel) panel.anchorItem = button
    if ("bar" in panel) panel.bar = root.bar
    if ("settings" in panel) panel.settings = root.settings
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.nobledoodle.omarchroma"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Named for what it does. This opened the panel while being called
    // "refresh", which reads as "synchronize now" over IPC -- that is the
    // service's sync method, not this one.
    function openPanel(): void { root.open() }

    // Bind these to keys in your own bindings.lua; the plugin ships the
    // capability and never writes a binding itself. Status stays in the panel.
    function toggleGtk(): void { root.toggleFramework("gtk") }
    function toggleQtKde(): void { root.toggleFramework("qt-kde") }
    function toggleDarkReader(): void { root.toggleFramework("dark-reader") }
    function togglePear(): void { root.toggleFramework("pear") }
    function toggleFlatpak(): void { root.toggleFramework("flatpak") }
    function toggleBrowsers(): void { root.toggleFramework("browsers") }
    function refresh(): void { root.refreshEnabled() }
    // Opens the same confirmation the guide's own "Restart All" button leads
    // to, for a key of your own in bindings.lua. Opens the panel too: unlike a
    // toggle, this has something to show.
    function restartStaleApps(): void {
      var panel = panelLoader.item
      if (!panel) return
      panel.confirmRestartOpen = true
      // Asked afresh, not trusted from status.json: opened right after a
      // sync records the list, the file's change notice can land a moment
      // after this.
      panel.refreshStaleApps()
      root.open()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb80\udfd8"
    active: false
    tooltipText: root.opened ? "Close Omarchroma" : "Open Omarchroma"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }

}
