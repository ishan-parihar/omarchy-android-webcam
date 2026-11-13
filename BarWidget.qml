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

  // The phone connection, from the same CLI. The camera cannot work
  // without it, so "idle" and "idle because there is no phone" are two
  // different things to say and the icon cannot tell them apart from the
  // webcam status alone.
  property var deviceStatus: ({})
  readonly property var device: Model.deviceState(deviceStatus)

  readonly property bool live: state.state === "live"
  readonly property bool broken: state.state === "no-signal"

  // The icon's colour. The urgent colour is not decoration: it marks the one
  // state where the user believes they have a webcam and do not.
  readonly property color iconColor: broken
    ? Commons.Color.urgent
    : (live ? Commons.Color.accent : foreground)

  // Who owns the camera.
  //
  // The durable service is the right owner when it is installed: it
  // restarts the stream when the phone sleeps, and it reads the same
  // settings file the panel writes.  When it is not installed, the bar
  // drives the CLI directly.  One decision, made once, so the icon and
  // the panel cannot disagree about who is in charge.
  property bool serviceInstalled: false

  Process {
    id: serviceQuery
    command: ["systemctl", "--user", "is-enabled", "android-webcam.service"]
    stdout: StdioCollector {
      onStreamFinished: {
        var answer = text.trim();
        root.serviceInstalled = (answer === "enabled" || answer === "static"
                                 || answer === "enabled-runtime");
      }
    }
    onExited: function(exitCode) {
      // A missing or disabled unit exits nonzero.  That is an answer:
      // there is no service to own the camera, so the CLI is the owner.
      if (exitCode !== 0) root.serviceInstalled = false;
    }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!serviceQuery.running) serviceQuery.running = true;
      // A slower read than the webcam status: a phone that swapped ports
      // is worth noticing, but not every few seconds.
      if (!deviceProc.running) deviceProc.running = true;
    }
  }

  // `android status` is the CLI's own answer about the phone, which is what
  // the panel's discover and connect controls need to show.
  Process {
    id: deviceProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.deviceStatus = Model.parseJsonObject(text)
    }
  }

  // Read the phone's state now rather than at the next tick of the slow
  // timer.  Called after a connect, and when the panel opens.
  function refreshDevice() {
    if (!deviceProc.running) deviceProc.running = true;
  }

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

  // The base Panel registers the target's IpcHandler itself, so
  // manageIpc stays true and its open/close/show/hide/toggle reach the
  // KeyboardPanel through the base's own panelController.
  //
  // This was `manageIpc: false` with no replacement, which meant nothing
  // registered the target at all: omarchy-shell reported "Target not
  // found" and the panel could only be opened by clicking the icon.
  manageIpc: true

  // The bar host sizes each widget from its implicit size. A Panel is an
  // empty Item with neither, and pill-bar mounts widgets in its centered
  // cluster by that size, so without these the widget is instantiated and
  // registered for IPC but measures 0x0 and paints nothing.
  //
  // It is laid out from the button, the way the first-party bar widgets do
  // it, so the slot is exactly as wide and as tall as the icon needs and no
  // wider.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // U+F0102 (md-camera_front) is the camera.  The glyph that was here
    // before, U+F010A, is md-candycane: a candy cane, not a camera, which
    // is what made the icon look wrong to anyone who knew what they were
    // looking at.
    text: "󰄂"
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
        : (root.device.connected
          ? "Phone camera: idle"
          : "Phone camera: idle — no phone connected"))

    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        root.open();
        return;
      }
      // Left toggles.  Both paths go through the same functions the
      // panel uses, so the icon and the panel cannot disagree about who
      // owns the camera.
      if (root.state.streaming) root.stopStream();
      else root.startStream([]);
    }
  }

  // --- start and stop --------------------------------------------------------
  //
  // The service is the owner when it is installed: it restarts the stream
  // when the phone sleeps, and it reads the same settings file the panel
  // writes.  Starting a second stream beside it is the failure this
  // avoids -- two camera clients, and the phone refuses the second one.
  //
  // When there is no service, the CLI is the owner.  The settings file is
  // passed explicitly because the CLI does not read it unless asked, and
  // an icon that started with defaults while the panel showed something
  // else would be a lie the user only notices in a call.
  function startStream(args) {
    if (root.serviceInstalled) {
      serviceAction.verb = "start";
      serviceAction.running = true;
      return;
    }
    startProc.args = args || [];
    startProc.running = true;
  }

  function stopStream() {
    if (root.serviceInstalled) {
      serviceAction.verb = "stop";
      serviceAction.running = true;
      return;
    }
    stopProc.running = true;
  }

  // New settings under a running stream, which means a restart: a stream is
  // doing what its argv says, so changing a size or a facing has to end this
  // one and start the new one for the change to be real.
  //
  // The service restart is one systemd call and it is atomic, so there is no
  // window where the device is held by a half-dead stream. The CLI path has
  // to sequence it, because `webcam stop` lets go of the loopback device as
  // it exits and the next start needs the device free.
  function restartStream(args) {
    restartProc.args = args || [];
    if (root.serviceInstalled) {
      serviceAction.verb = "restart";
      serviceAction.running = true;
      return;
    }
    restartPending = true;
    stopProc.running = true;
    // The stop's exit is what starts the new one.
  }

  Process {
    id: restartProc
    property var args: []
    onExited: function(exitCode) {
      if (!statusProc.running) statusProc.running = true;
    }
  }

  readonly property string settingsPath:
      Quickshell.env("XDG_STATE_HOME") + "/android-scrcpy-control/webcam-settings.json"

  Process {
    id: startProc
    property var args: []
    command: [root.cli, "webcam", "start", "--background",
              "--settings", root.settingsPath].concat(startProc.args)
    onExited: function(exitCode) {
      if (!statusProc.running) statusProc.running = true;
    }
  }

  Process {
    id: stopProc
    command: [root.cli, "webcam", "stop"]
    stdout: StdioCollector {
      onStreamFinished: if (!statusProc.running) statusProc.running = true
    }
    onExited: function(exitCode) {
      // A restart in flight, not just a stop: the device is free now, so
      // start the stream the new settings describe.
      if (restartPending && !startProc.running) {
        restartPending = false;
        startProc.args = restartProc.args.slice();
        startProc.running = true;
      }
    }
  }

  // Whether the last stop is the first half of a restart.  A plain stop
  // never starts anything, and a restart never leaves it behind.
  property bool restartPending: false

  Process {
    id: serviceAction
    property string verb: "start"
    command: ["systemctl", "--user", verb, "android-webcam.service"]
    onExited: function(exitCode) {
      if (!statusProc.running) statusProc.running = true;
      if (!serviceQuery.running) serviceQuery.running = true;
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The panel's content takes keyboard focus when the panel opens, the way
    // the first-party panels do. Without this the surface maps but no
    // descendant has active focus, so Qt never delivers a key to it.
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    // The panel's content is built the first time it opens, not at bar
    // startup. A bar widget exists on every monitor, and the settings
    // surface is the largest thing in this plugin.
    content: PanelKeyCatcher {
      id: keyCatcher
      // The height comes from the content below, not from the panel: the
      // panel measures the content to decide how tall the card is, so
      // anchoring the height here would close the loop on itself and the
      // card would never grow.
      implicitHeight: column.implicitHeight
      width: parent.width

      // The panel's own keys. Without a handler for close the surface eats
      // Escape, because PanelKeyCatcher claims every key it is given.
      onCloseRequested: root.close()
      // Tab moves between the bar's panels, the way the first-party panels
      // do it.
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // The settings surface has no cursor of its own, so the arrow keys
      // are left alone rather than pretending to move something.
      onMoveRequested: function(dx, dy) {}

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
          // The phone connection, read by the widget on the slow timer.  The
          // panel's discover and connect controls show this, and the icon's
          // tooltip uses the same object so the two cannot disagree about
          // whether there is a phone.
          deviceStatus: root.deviceStatus
          // One owner decision, made by the bar widget, so the panel's
          // button and the icon cannot fight over the camera.
          serviceOwns: root.serviceInstalled
          // The panel's primary action routes through the same two
          // functions the icon uses, so the service-vs-CLI decision is
          // made once and the two surfaces cannot fight over the camera.
          onRequestStart: function(args) { root.startStream(args) }
          // A function, not a call.  `onRequestStop: root.stopStream()` would
          // invoke stopStream() the moment the panel's content is built -- which
          // stopped the camera every time the panel was opened for the first
          // time in a shell session -- and then leave the property holding the
          // call's return value, undefined, so the button did nothing after that.
          onRequestStop: function() { root.stopStream() }
          // A function, not a call, for the same reason as onRequestStop.
          onRequestRestart: function(settings) { root.restartStream(Model.argvFrom(settings)) }
          // Re-checked on every open: the CLI can be installed or removed
          // while the shell keeps running, the phone can connect or drop
          // while the shell is running, and the phone is the one input a
          // stale answer costs the user most.
          //
          // A function, not a call: `onRefreshDevice: root.refreshDevice()`
          // would run once when the panel's content is built and leave the
          // property holding undefined, which is the bug onRequestStop had.
          onRefreshDevice: function() {
            if (!deviceProc.running) deviceProc.running = true;
          }
          // Driven from here rather than from the panel's own `visible`,
          // because the panel's content is built once and kept: an
          // already-built panel reopening does not change `visible`, so a
          // handler on it never fires.  `opened` is readonly, so it has no
          // change handler of its own; the controller's `open` does.
          Connections {
            target: root.controller
            function onOpenChanged() {
              if (root.controller.open && settings) settings.refreshOnOpen();
            }
          }
        }
      }
    }
  }
}
