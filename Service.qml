import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") !== ""
    ? Quickshell.env("XDG_STATE_HOME") : home + "/.local/state") + "/omarchroma"
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") !== ""
    ? Quickshell.env("XDG_DATA_HOME") : home + "/.local/share") + "/omarchroma"

  function syncColors() {
    if (!syncProcess.running) syncProcess.running = true
  }

  // Forced, unlike syncColors: a refresh asked for by name should rewrite the
  // palette and recycle idle applications even when nothing looks changed.
  function refreshColors() {
    if (!refreshProcess.running) refreshProcess.running = true
  }

  Process {
    id: syncProcess
    command: [ root.home + "/.local/bin/omarchroma-sync", "--quiet" ]
  }

  Process {
    id: refreshProcess
    command: [ root.home + "/.local/bin/omarchroma-sync", "--force", "--notify" ]
  }

  // Setting an Omarchy theme is the trigger, through the theme-set hook. What
  // this service covers is everything after it: a browser or KDE application
  // closing that a deferred write was waiting on, a changed default browser, a
  // newly installed Pear Desktop. All of those surface on Hyprland's event
  // stream as a window opening or closing, so a helper watches that stream and
  // syncs when a burst settles, rather than this polling on a fixed interval.
  Process {
    id: eventWatcher
    running: true
    command: [
      root.home + "/.local/bin/omarchroma-state",
      "--state-dir", root.stateDir,
      "--data-dir", root.dataDir,
      "watch-events"
    ]
    onExited: relaunch.restart()
  }

  // The watcher returns when the stream closes, which is what happens if
  // Hyprland restarts. Pick it back up rather than leaving the service deaf.
  Timer {
    id: relaunch
    interval: 3000
    repeat: false
    onTriggered: if (!eventWatcher.running) eventWatcher.running = true
  }

  // One sync at startup, then a rare safety net for a change that never shows
  // up as a window event at all. Not the mechanism this relies on.
  Timer {
    interval: 900000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncColors()
  }

  IpcHandler {
    target: "io.github.nobledoodle.omarchroma-service"

    function sync(): void {
      root.syncColors()
    }

    // Works with the bar widget absent, the service being keepLoaded.
    function refresh(): void {
      root.refreshColors()
    }
  }
}
