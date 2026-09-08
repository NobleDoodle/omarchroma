import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  function syncColors() {
    if (!syncProcess.running) syncProcess.running = true
  }

  Process {
    id: syncProcess
    command: [
      Quickshell.env("HOME") + "/.local/bin/omarchroma-sync",
      "--quiet"
    ]
  }

  Timer {
    interval: 60000
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
  }
}
