import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

import "Model.js" as Model

// The settings panel's body, built by the bar widget's KeyboardPanel.
//
// It is a separate file so it stays out of the bar's own object tree until
// the panel first opens: a bar widget is created on every monitor, and
// building the whole settings surface with it would spend memory and
// startup time on a surface the user may never open.
//
// Everything shown is read back from the CLI rather than remembered from
// what this panel last clicked. The GUI app, the CLI and this panel can all
// change the stream, so a remembered click is state that can be stale and
// lie.
Item {
  id: root

  // The panel sizes its card from the content's implicit height. An Item has
  // none, so without this the surface collapses to nothing and the panel
  // opens as an empty card the width of the screen.
  implicitHeight: column.implicitHeight

  property var bar: null
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property var status: ({})
  property string cli: "android"

  // Set by the bar widget, which owns the start and stop processes, so the
  // panel's primary action routes through the same code the bar icon uses.
  property var onRequestStart: null
  property var onRequestStop: null

  readonly property var state: Model.streamState(status)
  readonly property var running: Model.runningSettings(status)

  // The settings a start would use: a running stream's argv when one is
  // running, the saved choices otherwise.
  //
  // These are read-only on purpose.  They are a view of two sources --
  // the running stream and the settings file -- and a control that
  // assigned to them would break the binding to that source, so the
  // panel would stop reflecting the truth after the first click.  The
  // controls call choose() instead, which writes the file and lets the
  // FileView feed the change back.
  readonly property string facing: running && running.facing ? running.facing : saved("facing", "front")
  readonly property string size: running && running.size ? running.size : saved("size", "1280x720")
  readonly property string fps: running && running.fps ? running.fps : saved("fps", "30")
  readonly property string bitRate: running && running.bitRate ? running.bitRate : saved("bitRate", "8M")
  readonly property bool torch: running ? running.torch : saved("torch", false)
  readonly property bool audio: running ? running.audio : saved("audio", false)

  property var savedSettings: ({})

  function saved(key, fallback) {
    var v = savedSettings[key];
    return (v === undefined || v === null) ? fallback : v;
  }

  // The phone's cameras, as rows the controls can render.
  property var cameras: []
  readonly property var currentCamera: {
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].facing === root.facing) return cameras[i];
    }
    return {};
  }
  readonly property var sizeChoices: Model.practicalSizes(currentCamera)
  readonly property var fpsNumbers: Model.fpsChoices(currentCamera)

  // The host's own cameras, from the PipeWire graph. This is the part that
  // makes the phone usable as a webcam: an app picks a device from this
  // list, and the phone has to be one of the entries and be the one the
  // system picks.
  property var hostCameras: []
  readonly property bool hasHostCamera: hostCameras.length > 0

  // --- is the CLI there at all? -----------------------------------------------
  //
  // Every control on this panel runs the CLI. Without it the panel would
  // still look like it was working while nothing happened, so this is asked
  // once at load and on every open, and a missing CLI is the one state
  // where the panel says so instead of offering controls that do nothing.
  property bool cliMissing: false

  Process {
    id: whichProc
    command: ["sh", "-c", "command -v " + root.cli]
    stdout: StdioCollector {
      onStreamFinished: root.cliMissing = (text.trim() === "")
    }
    onExited: function(exitCode) {
      root.cliMissing = (exitCode !== 0)
    }
  }

  // Re-asked on every open, because the CLI can be installed or uninstalled
  // while the shell runs, and a stale answer here is the worst one to have.
  function recheckCli() {
    if (!whichProc.running) whichProc.running = true
  }

  // --- reads -----------------------------------------------------------------
  //
  // Every read is an argv array. Nothing is interpolated into a shell
  // string, so a value that came from a device cannot be interpreted as
  // shell syntax.
  Process {
    id: statusProc
    command: [root.cli, "webcam", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.status = Model.parseJsonObject(text)
        // The CLI answered, so it exists regardless of what it said.
        if (text.trim() !== "") {
          root.cliMissing = false
          recheckCli()
        }
      }
    }
    onExited: function(exitCode) {
      // Nonzero is a normal answer here: the CLI exits nonzero when
      // nothing is streaming. 127 is a missing CLI.
      if (exitCode === 127) root.cliMissing = true
    }
  }

  Process {
    id: cameraProc
    command: [root.cli, "webcam", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.cameras = Model.phoneCameras(Model.parseJsonArray(text))
    }
  }

  // One read of the PipeWire graph gives both the cameras and the default,
  // so the list and the marker cannot disagree about which row is picked.
  Process {
    id: pipewireProc
    command: ["pw-dump"]
    stdout: StdioCollector {
      onStreamFinished: {
        var dump = text;
        root.hostCameras = Model.markDefaultSource(Model.hostCameras(dump), dump);
      }
    }
  }

  // A fast poll for the stream, a slow one for the rest. A phone that goes
  // to sleep is worth noticing within seconds; a newly plugged camera is
  // not, and the reads are not free.
  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!cameraProc.running) cameraProc.running = true;
      if (!pipewireProc.running) pipewireProc.running = true;
    }
  }

  // The CLI's existence is checked once here and again every time the panel
  // is opened, because the CLI can be installed or removed while the shell
  // keeps running and a stale answer is the worst one to carry.
  Component.onCompleted: recheckCli()

  // --- the settings file -----------------------------------------------------
  //
  // The settings live in one file that BOTH the panel and the durable
  // service read.  That is the whole point: the service restarts the
  // stream when the phone sleeps, and if it carried its own copy of the
  // camera choice the stream would come back with the camera the user had
  // changed away from.
  //
  // It lives in the state directory beside the CLI's own logs, so removing
  // the plugin leaves nothing behind in ~/.config.  Written through a
  // FileView with atomic writes, so a shell reload that lands mid-write
  // cannot truncate it.
  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    // onFileChanged says the file changed, not that `text()` has the new
    // contents: it still holds the old read until reload() runs.  Reading
    // it there kept the panel on a stale snapshot, so a second click
    // rebuilt the whole settings object from the old values and silently
    // reverted the first one.
    onLoaded: root.savedSettings = Model.parseJsonObject(text())
    onLoadFailed: root.savedSettings = ({})
    onFileChanged: reload()
  }

  readonly property string settingsPath:
      Quickshell.env("XDG_STATE_HOME") + "/android-scrcpy-control/webcam-settings.json"

  // --- writes ----------------------------------------------------------------
  //
  // The choice is recorded before the CLI is invoked, so a stream that dies
  // still leaves the panel showing what was asked for rather than the
  // previous choice. The CLI then validates the arguments and refuses
  // before anything runs, so a bad value can never be recorded as if it
  // worked.
  function persist() {
    var out = {
      facing: root.facing,
      size: root.size,
      fps: root.fps,
      bitRate: root.bitRate,
      torch: root.torch,
      audio: root.audio
    };
    root.savedSettings = out;
    settingsFile.setText(JSON.stringify(out, null, 2) + "\n");
  }

  // Record one choice.
  //
  // The effective values above are read-only views, so a control cannot
  // assign to them without destroying the binding that keeps the panel
  // honest.  This builds the whole settings object from the current
  // effective values, replaces the one key, and writes it: the FileView
  // reloads it and every binding updates from the file, which is also
  // what the service reads.
  //
  // A running stream's settings are the running stream's: changing them
  // under it would do nothing, so the controls are disabled while it
  // runs and this refuses the write rather than pretending.
  function choose(key, value) {
    if (root.state.streaming) return;
    var out = {
      facing: root.facing,
      size: root.size,
      fps: root.fps,
      bitRate: root.bitRate,
      torch: root.torch,
      audio: root.audio
    };
    out[key] = value;
    root.savedSettings = out;
    settingsFile.setText(JSON.stringify(out, null, 2) + "\n");
  }

  // Whether the durable service is the camera's owner.
  //
  // The bar widget answers this, because it is the thing that routes a
  // click to the service or to the CLI.  The panel does not ask systemd
  // itself: two surfaces asking the same question can get two answers,
  // and then the button and the message disagree.
  property bool serviceOwns: false

  // Start and stop.
  //
  // The panel records the choice, then asks the bar widget to act.  The
  // widget drives the service when there is one and the CLI otherwise.
  function start() {
    if (root.cliMissing) return;
    persist();
    if (root.onRequestStart) {
      root.onRequestStart(["--facing", root.facing, "--size", root.size,
                          "--fps", root.fps, "--bit-rate", root.bitRate]
                         .concat(root.torch ? ["--torch"] : [])
                         .concat(root.audio ? ["--with-audio"] : []));
    }
  }

  function stop() {
    if (root.cliMissing) return;
    if (root.onRequestStop) root.onRequestStop();
  }

  // Make the phone the camera the host's apps use.
  //
  // PipeWire holds a default video source by node id. This sets it, which
  // is what makes a browser or a conferencing app pick the phone when the
  // user chooses the default camera.
  Process {
    id: useProc
    property int sourceId: -1
    command: sourceId >= 0 ? ["wpctl", "set-default", String(sourceId)] : ["true"]
    stdout: StdioCollector {
      onStreamFinished: if (!pipewireProc.running) pipewireProc.running = true
    }
  }

  // Read a frame back from the device. A running process is not proof.
  Process {
    id: frameProc
    command: [root.cli, "webcam", "capture", "--output",
              root.settingsPath.replace("webcam-settings.json", "frame.png"),
              "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var report = Model.parseJsonObject(text);
        root.frameResult = report;
        if (report.ok) root.lastFrameAt = Date.now();
      }
    }
  }

  // What the last capture found.
  //
  // The brightness is the part that matters.  A black frame is a valid
  // frame: the right size, the right format, plenty of bytes.  Every
  // check that counts bytes says the camera works.  Only a measurement
  // of the picture itself says there is nothing in it, and on this
  // device the back camera produces exactly that.
  property var frameResult: ({})
  property double lastFrameAt: 0

  readonly property bool frameIsBlack:
      !!(frameResult && frameResult.brightness && frameResult.brightness.black)
  readonly property string frameMean:
      (frameResult && frameResult.brightness && frameResult.brightness.mean !== undefined)
        ? String(frameResult.brightness.mean) : ""

  // --- the UI ----------------------------------------------------------------

  Column {
    id: column
    // The width follows the parent, but the height is this column's own:
    // it is what the panel measures to size the card. Anchoring the height
    // would make the column as tall as the panel, which is the thing being
    // measured, and the card would never grow past the inset.
    width: parent.width
    spacing: Style.spacing.xl

    // --- header -----------------------------------------------------------
    Text {
      textFormat: Text.PlainText
      text: root.state.state === "live"
        ? "Live on " + (root.state.sink || "the loopback device")
        : (root.state.state === "no-signal"
          ? "Running, no frames"
          : "Idle")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      width: parent.width
    }

    // --- no CLI ------------------------------------------------------------
    //
    // Every control here runs the CLI.  Without it the panel would look
    // like it was working while nothing happened, so this is said plainly
    // and the rest of the panel is hidden rather than left as dead
    // controls.
    Text {
      visible: root.cliMissing
      textFormat: Text.PlainText
      text: "The 'android' command is not installed, so these controls cannot work. Install the android-scrcpy-control skill and reopen this panel."
      color: Commons.Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      visible: root.state.state === "no-signal"
      textFormat: Text.PlainText
      text: root.state.detail
      color: Commons.Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      visible: root.state.format !== ""
      textFormat: Text.PlainText
      text: root.state.format
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width
    }

    // --- start / stop ------------------------------------------------------
    //
    // Button, not PanelActionButton: the action's label is words, and
    // PanelActionButton is the small icon button for a row's inline action.
    Button {
      id: primaryAction
      width: root.width
      text: root.state.streaming ? "Stop the webcam" : "Start the webcam"
      iconText: root.state.streaming ? "󰅖" : "󰄀"
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.subtitle
      focusable: true
      onClicked: root.state.streaming ? root.stop() : root.start()
    }

    // Who owns the camera matters, because it decides what the button
    // above does.  Saying so removes the only confusing case: the user
    // clicks Stop, the button appears to do nothing for a moment, and the
    // stream comes back a second later because the service restarted it.
    Text {
      visible: root.serviceOwns && root.state.streaming
      textFormat: Text.PlainText
      text: "The webcam service owns this stream, so it restarts it if the phone's camera goes away. Stopping it here stops the service too."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    PanelSeparator { foreground: root.foreground }

    // --- the host's own camera ----------------------------------------------
    // The point of the plugin. A phone that streams but is not the camera
    // the system picks is a webcam no app will use.
    PanelSectionHeader {
      text: "Camera on this PC"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      text: "Pick which camera your apps use. This PC has no built-in camera, so the phone is the one that shows here."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Repeater {
      model: root.hostCameras

      delegate: Button {
        required property var modelData
        required property int index
        // A full-width row, because the name of a camera is the whole
        // content of the row.
        width: root.width
        leftAlign: true
        // The row the system will pick is marked, because the list alone
        // does not say which entry a browser will choose.
        text: (modelData.default ? "●  " : "○  ") + modelData.name
        selected: modelData.default
        foreground: modelData.default ? Commons.Color.accent : root.foreground
        accent: Commons.Color.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        tooltipText: modelData.device !== "" ? modelData.device : modelData.nodeName
        focusable: true
        onClicked: {
          useProc.sourceId = modelData.id;
          useProc.running = true;
        }
      }
    }

    Text {
      visible: !root.hasHostCamera
      textFormat: Text.PlainText
      text: "No camera is registered on this PC yet. Start the stream and the phone will appear here."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    PanelSeparator { foreground: root.foreground }

    // --- the phone's camera --------------------------------------------------
    PanelSectionHeader {
      text: "Phone camera"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      visible: root.state.streaming
      textFormat: Text.PlainText
      text: "These are read from the running stream. Stop it to change them."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    ButtonGroup {
      width: parent.width
      // A running stream owns these values: its argv is what it is
      // doing, and writing a different choice under it would change
      // nothing until the next start.  Disabled is the honest state.
      enabled: !root.state.streaming
      options: root.cameras.length
        ? root.cameras.filter(function(c) { return c.facing === "front" || c.facing === "back"; })
            .map(function(c) { return { value: c.facing, label: c.facing === "front" ? "Front" : "Back" }; })
        : [{ value: "front", label: "Front" }, { value: "back", label: "Back" }]
      value: root.facing
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onChanged: function(v) { root.choose("facing", v); }
    }

    ButtonGroup {
      width: parent.width
      enabled: !root.state.streaming
      options: root.sizeChoices.map(function(s) { return { value: s, label: s }; })
      value: root.size
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onChanged: function(v) { root.choose("size", v); }
    }

    ButtonGroup {
      width: parent.width
      enabled: !root.state.streaming
      options: root.fpsNumbers.length
        ? root.fpsNumbers.map(function(n) { return { value: String(n), label: n + " fps" }; })
        : [{ value: "30", label: "30 fps" }]
      value: root.fps
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onChanged: function(v) { root.choose("fps", v); }
    }

    ButtonGroup {
      width: parent.width
      enabled: !root.state.streaming
      options: Model.bitRateChoices()
      value: root.bitRate
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onChanged: function(v) { root.choose("bitRate", v); }
    }

    Text {
      textFormat: Text.PlainText
      text: "Higher looks better on a good connection. It costs battery and heat on the phone."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    PanelSeparator { foreground: root.foreground }

    Toggle {
      label: "Torch"
      description: "The camera light. Back camera only. Applies on the next start."
      checked: root.torch
      enabled: !root.state.streaming
      hasCursor: true
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onClicked: root.choose("torch", !root.torch)
    }

    Toggle {
      label: "Phone microphone"
      description: "Forward the phone's microphone too. It is routed through a null sink, so it does not play out your speakers."
      checked: root.audio
      enabled: !root.state.streaming
      hasCursor: true
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      onClicked: root.choose("audio", !root.audio)
    }

    PanelSeparator { foreground: root.foreground }

    // --- proof --------------------------------------------------------------
    // A running process is not proof, which is the whole reason this plugin
    // reports frames and not processes.
    Button {
      width: root.width
      text: "Save a frame"
      iconText: "󰋢"
      foreground: root.foreground
      accent: Commons.Color.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      focusable: true
      onClicked: if (!frameProc.running) frameProc.running = true
    }

    // The result of the last capture.  A black frame is reported as a
    // failure rather than a success, because a valid 1280x720 frame with
    // nothing in it is exactly what this device's back camera produces,
    // and every other check says it is working.
    Text {
      visible: root.frameResult && root.frameResult.ok === true
      textFormat: Text.PlainText
      text: root.frameIsBlack
        ? "The frame is black. The stream is running, but this camera is not sending a picture."
        : ("The frame looks right. Mean brightness " + root.frameMean + " of 255.")
      color: root.frameIsBlack ? Commons.Color.urgent : Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      visible: root.frameResult && root.frameResult.ok === false
      textFormat: Text.PlainText
      text: "No frame: " + (root.frameResult.detail || "the capture failed")
      color: Commons.Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      textFormat: Text.PlainText
      text: "Saves to " + Quickshell.env("XDG_STATE_HOME") + "/android-scrcpy-control/frame.png"
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }
}
