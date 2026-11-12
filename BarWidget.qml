import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

import "Model.js" as Model

// The bar widget.
//
// The icon is a camera glyph whose colour tells the truth about the stream:
// the bar's own colour when idle, the accent colour when frames are
// arriving, the urgent colour when the process is alive but the picture is
// not.
//
// The last case is the one that matters. On this phone the camera HAL
// releases the camera when the screen sleeps, which leaves a scrcpy process
// running and a black buffer. A single "streaming" dot could not tell those
// apart, so a dot that said "streaming" while the phone was asleep was
// lying. Three states can.
Panel {
  id: root
  moduleName: "ishanp.android-webcam-pro"
  ipcTarget: "ishanp.android-webcam-pro"

  readonly property color foreground: barForeground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The last status the CLI reported. Kept as a plain object so the icon and
  // the panel read the same thing rather than each polling separately.
  property var status: ({})
  readonly property var state: Model.streamState(status)

  readonly property bool live: state.state === "live"
  readonly property bool broken: state.state === "no-signal"

  // The icon's colour. The urgent colour is not decoration: it marks the one
  // state where the user believes they have a webcam and do not.
  readonly property color iconColor: broken
    ? Commons.Color.urgent
    : (live ? Commons.Color.accent : foreground)

  // --- the CLI ---------------------------------------------------------------
  //
  // `android` is the skill's CLI. Every call is an argv array, never a shell
  // string, so no value that came from a device or a config file can be
  // interpreted as shell syntax.
  readonly property string cli: "android"

  Process {
    id: statusProc
    command: [root.cli, "webcam", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.status = Model.parseJsonObject(text)
    }
  }

  // A slow poll. A phone that goes to sleep is worth noticing within a few
  // seconds, but not every second.
  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  // The bar widget owns the single IPC target, so nothing else may register
  // a handler for it.
  manageIpc: false

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰇮"
    // The glyph alone cannot carry the state, so the colour does. A glyph
    // change would mean the user had to learn which shape meant what.
    active: root.live
    useActiveColor: true
    activeColor: root.iconColor
    foreground: root.iconColor
    tooltipText: root.broken
      ? "Phone camera: running but no frames"
      : (root.live
        ? "Phone camera: live on " + (root.state.sink || "the loopback device")
        : "Phone camera: idle")

    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        root.open();
        return;
      }
      // Left toggles. The read and the write go through the same CLI, so the
      // icon and the action can never disagree about what "streaming" means.
      if (root.state.streaming) {
        stopProc.running = true;
      } else {
        startProc.args = [];
        startProc.running = true;
      }
    }
  }

  // Start and stop live here rather than in the panel, so the bar icon and
  // the panel's button run exactly the same code.
  Process {
    id: startProc
    property var args: []
    command: [root.cli, "webcam", "start", "--background"].concat(root.args)
  }

  Process {
    id: stopProc
    command: [root.cli, "webcam", "stop"]
    stdout: StdioCollector {
      onStreamFinished: if (!statusProc.running) statusProc.running = true
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    // The panel's content is built the first time it opens, not at bar
    // startup. A bar widget exists on every monitor, and the settings
    // surface is the largest thing in this plugin.
    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: column.implicitHeight
      anchors.fill: parent

      Column {
        id: column
        width: parent.width

        // Sibling QML files in a plugin directory are types in the same
        // scope, so the settings surface is named directly rather than
        // imported. No qmldir and no module name is needed.
        AndroidWebcamSettings {
          id: settings
          width: parent.width
          bar: root.bar
          foreground: root.foreground
          fontFamily: root.fontFamily
          cli: root.cli
          status: root.status
          // The panel's primary action routes through the bar widget's
          // processes, so there is one start path and one stop path.
          onRequestStart: function(args) {
            startProc.args = args;
            startProc.running = true;
          }
          onRequestStop: stopProc.running = true
          // Re-checked on every open: the CLI can be installed or removed
          // while the shell keeps running.
          onVisibleChanged: if (visible) settings.recheckCli()
        }
      }
    }
  }
}
