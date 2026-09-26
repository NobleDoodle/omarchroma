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

  // Applications still showing the previous theme: the ones to close. The icon
  // takes the theme's urgent color, as Omarchy's agents widget does when a
  // limit is near, and a small raised count says how many.
  readonly property int staleCount: panelLoader.item && panelLoader.item.staleApps
    ? panelLoader.item.staleApps.length : 0

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
    // capability and never writes a binding itself. They notify, since a key
    // pressed with the panel closed has nothing else to report through.
    function toggleGtk(): void { root.toggleFramework("gtk") }
    function toggleQtKde(): void { root.toggleFramework("qt-kde") }
    function toggleDarkReader(): void { root.toggleFramework("dark-reader") }
    function togglePear(): void { root.toggleFramework("pear") }
    function toggleFlatpak(): void { root.toggleFramework("flatpak") }
    function toggleBrowsers(): void { root.toggleFramework("browsers") }
    function refresh(): void { root.refreshEnabled() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb80\udfd8"
    active: root.staleCount > 0
    tooltipText: root.opened ? "Close Omarchroma"
      : root.staleCount === 1 ? "Open Omarchroma: 1 app to close for the new theme"
      : root.staleCount > 1 ? "Open Omarchroma: " + root.staleCount + " apps to close for the new theme"
      : "Open Omarchroma"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }

  // Raised to the icon's top right, like an exponent, in the same urgent color.
  Text {
    id: staleBadge
    visible: root.staleCount > 0
    text: root.staleCount > 9 ? "9+" : String(root.staleCount)
    color: button.activeColor
    font.family: button.fontFamily
    font.pixelSize: Math.max(7, Math.round(Style.bar.iconFont * 0.62))
    font.bold: true
    renderType: Text.NativeRendering  // as the shell draws the glyph beside it
    x: Math.round(button.x + (button.width + Style.bar.iconCanvas) / 2 - implicitWidth * 0.3)
    y: Math.round(button.y + (button.height - Style.bar.iconCanvas) / 2 - implicitHeight * 0.35)
    z: 2
  }
}
