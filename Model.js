// Pure helpers for the Android webcam plugin.
//
// Everything here is a plain function over plain data, so it can be unit
// tested without QML and without a phone. No QML types, no side effects.

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isPlainArray(value) {
  return Array.isArray(value);
}

// Parse a JSON object. Returns {} for anything that is not a JSON object, so
// a truncated or unexpected payload degrades to "unknown" rather than
// throwing inside a binding.
function parseJsonObject(text) {
  if (typeof text !== "string") return {};
  var trimmed = text.trim();
  if (trimmed === "") return {};
  try {
    var parsed = JSON.parse(trimmed);
    return isPlainObject(parsed) ? parsed : {};
  } catch (e) {
    return {};
  }
}

// Parse a JSON array. Returns [] for anything that is not a JSON array.
function parseJsonArray(text) {
  if (typeof text !== "string") return [];
  var trimmed = text.trim();
  if (trimmed === "") return [];
  try {
    var parsed = JSON.parse(trimmed);
    return isPlainArray(parsed) ? parsed : [];
  } catch (e) {
    return [];
  }
}

// The stream state the bar icon and the panel both read.
//
// The CLI reports these separately:
//   signal.streaming  a scrcpy process holds the sink
//   signal.signal     the loopback has a writer attached to it
//   signal.frame      a frame was read and it has a picture in it
//
// The last two are different questions, and treating them as one was a
// real bug: the loopback has a writer while the phone's camera HAL has
// dropped the camera, and that writer fills the device with flat black
// frames.  "A writer is attached" is true there; "there is a picture" is
// not.  The icon must not say "streaming" in that state, because the
// user would believe they have a webcam and do not.
function streamState(status) {
  var signal = isPlainObject(status.signal) ? status.signal : {};
  var host = isPlainObject(status.host) ? status.host : {};

  var streaming = signal.streaming === true;
  var carrying = signal.signal === true;
  var frame = signal.frame === true;

  // Live needs all three.  Anything else that still has a stream process
  // is the failure state the icon exists to surface.
  var state = "idle";
  if (streaming && frame) state = "live";
  else if (streaming) state = "no-signal";

  return {
    state: state,
    streaming: streaming,
    signal: carrying,
    frame: frame,
    sink: typeof signal.sink === "string" ? signal.sink
      : (typeof host.sink === "string" ? host.sink : ""),
    format: typeof host.sink_format === "string" ? host.sink_format : "",
    problems: isPlainArray(host.problems) ? host.problems : [],
    // A stream running with no picture is the state worth surfacing,
    // because the process list still shows scrcpy and the user has no
    // other clue.  Which half failed decides what to tell them.
    detail: state === "no-signal"
      ? (carrying
        ? "The stream is running and the loopback is being written to, but the picture is flat. The phone may have gone to sleep, or another app took the camera."
        : "The stream process is running but nothing is writing frames into the loopback.")
      : ""
  };
}

// The phone's own cameras, with their supported sizes.
//
// The CLI's `webcam list --json` reports one entry per camera, with the
// sizes it supports only when they were queried. The list form has no
// `sizes` key, so the camera rows carry whatever is there.
function phoneCameras(cameras) {
  var list = isPlainArray(cameras) ? cameras : [];
  var rows = [];
  for (var i = 0; i < list.length; i++) {
    var c = isPlainObject(list[i]) ? list[i] : {};
    rows.push({
      id: String(c.id === undefined ? "" : c.id),
      facing: typeof c.facing === "string" ? c.facing : "",
      size: typeof c.size === "string" ? c.size : "",
      fps: typeof c.fps === "string" ? c.fps : "",
      zoom: typeof c.zoom_range === "string" ? c.zoom_range : "",
      sizes: isPlainArray(c.sizes) ? c.sizes : []
    });
  }
  return rows;
}

// The front/back choices, one per facing.
//
// The phone reports several physical cameras with the same facing -- wide,
// ultrawide and macro all report "back" -- so mapping every camera row
// produced duplicate pills.  A facing is the choice; which physical camera
// serves it is the CLI's job to pick.
function facingChoices(cameras) {
  var list = isPlainArray(cameras) ? cameras : [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var facing = isPlainObject(list[i]) ? list[i].facing : "";
    if (facing !== "front" && facing !== "back") continue;
    var seen = false;
    for (var j = 0; j < out.length; j++) {
      if (out[j].value === facing) seen = true;
    }
    if (!seen) {
      out.push({ value: facing, label: facing === "front" ? "Front" : "Back" });
    }
  }
  if (out.length === 0) {
    out.push({ value: "front", label: "Front" });
    out.push({ value: "back", label: "Back" });
  }
  // Front first, so the order does not depend on the phone's enumeration.
  out.sort(function(a, b) {
    var order = { front: 0, back: 1 };
    return order[a.value] - order[b.value];
  });
  return out;
}

// The sizes worth offering for a camera.
//
// The phone reports dozens of raw sizes. A webcam is used in calls, so the
// useful set is the handful of sizes apps actually ask for, filtered to the
// ones the camera really supports.
//
// The CLI's list form reports each camera's largest size but not the full
// set, so an empty `sizes` means "not known", not "none supported". The
// preferred list is offered then, and the CLI refuses the ones the camera
// cannot do if it turns out it cannot do them.
function practicalSizes(camera) {
  var preferred = ["640x480", "1280x720", "1920x1080"];
  if (!isPlainObject(camera)) return preferred.slice();
  var supported = isPlainArray(camera.sizes) ? camera.sizes : [];
  if (supported.length === 0) return preferred.slice();

  var out = [];
  for (var i = 0; i < preferred.length; i++) {
    if (supported.indexOf(preferred[i]) !== -1) out.push(preferred[i]);
  }
  // Nothing practical matched, so offer what the camera does have rather
  // than an empty list that leaves the user with no choice.
  if (out.length === 0) {
    for (var j = 0; j < supported.length && out.length < 4; j++) {
      if (typeof supported[j] === "string" && supported[j].indexOf("x") > 0) {
        out.push(supported[j]);
      }
    }
  }
  return out;
}

// The frame rates a camera supports, as plain numbers.
//
// The phone reports them as a set literal, "{10, 15, 20, 30, 60}". Parsing
// that into numbers is what lets the panel show a real choice instead of
// asking the user to type a number that may be refused.
function fpsChoices(camera) {
  if (!isPlainObject(camera)) return [];
  var raw = typeof camera.fps === "string" ? camera.fps : "";
  var out = [];
  var re = /\d+(?:\.\d+)?/g;
  var match;
  while ((match = re.exec(raw)) !== null) {
    var value = parseFloat(match[0]);
    if (isFinite(value) && out.indexOf(value) === -1) out.push(value);
  }
  out.sort(function(a, b) { return a - b; });
  return out;
}

// Read the settings a start would use out of a running stream's argv.
//
// The CLI reports the exact argv it ran. Reading the arguments back is how
// the panel shows the truth rather than what it last clicked.
function settingsFromArgv(argv) {
  var out = { facing: "", size: "", fps: "", bitRate: "", sink: "", torch: false, audio: false };
  if (!isPlainArray(argv)) return out;

  for (var i = 0; i < argv.length; i++) {
    var arg = String(argv[i]);
    if (arg.indexOf("--camera-facing=") === 0) out.facing = arg.slice("--camera-facing=".length);
    else if (arg.indexOf("--camera-size=") === 0) out.size = arg.slice("--camera-size=".length);
    else if (arg.indexOf("--camera-fps=") === 0) out.fps = arg.slice("--camera-fps=".length);
    else if (arg.indexOf("--video-bit-rate=") === 0) out.bitRate = arg.slice("--video-bit-rate=".length);
    else if (arg.indexOf("--v4l2-sink=") === 0) out.sink = arg.slice("--v4l2-sink=".length);
    else if (arg === "--torch") out.torch = true;
    else if (arg === "--no-audio") out.audio = false;
    else if (arg === "--audio-source=mic" || arg === "--with-audio") out.audio = true;
  }
  return out;
}

// The running stream's settings, or null when nothing is running.
function runningSettings(status) {
  var streams = isPlainArray(status.streams) ? status.streams : [];
  for (var i = 0; i < streams.length; i++) {
    var s = isPlainObject(streams[i]) ? streams[i] : {};
    if (isPlainArray(s.argv)) return settingsFromArgv(s.argv);
  }
  return null;
}

// The host's cameras, read out of the PipeWire graph dump.
//
// The dump is JSON with named fields, which is why it is parsed rather than
// scraped out of `wpctl status`: the status output is a presentation, and a
// presentation that changes shape gives a wrong answer with no error.
//
// A source is a node whose media.class is Video/Source. Its name is what
// PipeWire's default-video-source setting refers to, so both are needed:
// the name to identify the default, the id to change it.
function hostCameras(dumpText) {
  var objects = parseJsonArray(dumpText);
  var sources = [];

  for (var i = 0; i < objects.length; i++) {
    var o = isPlainObject(objects[i]) ? objects[i] : {};
    if (o.type !== "PipeWire:Interface:Node") continue;
    var info = isPlainObject(o.info) ? o.info : {};
    var props = isPlainObject(info.props) ? info.props : {};
    if (props["media.class"] !== "Video/Source") continue;

    sources.push({
      id: typeof o.id === "number" ? o.id : -1,
      name: typeof props["node.description"] === "string" && props["node.description"] !== ""
        ? props["node.description"]
        : (typeof props["node.name"] === "string" ? props["node.name"] : "Camera"),
      nodeName: typeof props["node.name"] === "string" ? props["node.name"] : "",
      device: typeof props["api.v4l2.path"] === "string" ? props["api.v4l2.path"]
        : (typeof props["device.name"] === "string" ? props["device.name"] : ""),
      default: false
    });
  }
  return sources;
}

// Mark the source the system will pick.
//
// PipeWire stores the default video source as a node name in its settings
// metadata, so the default is found by matching the name, not by guessing.
function markDefaultSource(cameras, dumpText) {
  var list = isPlainArray(cameras) ? cameras : [];
  var objects = parseJsonArray(dumpText);
  var defaultName = "";

  for (var i = 0; i < objects.length; i++) {
    var o = isPlainObject(objects[i]) ? objects[i] : {};
    if (o.type !== "PipeWire:Interface:Metadata") continue;
    var meta = isPlainArray(o.metadata) ? o.metadata : [];
    for (var m = 0; m < meta.length; m++) {
      var entry = isPlainObject(meta[m]) ? meta[m] : {};
      if (entry.key !== "default.video.source") continue;
      var value = isPlainObject(entry.value) ? entry.value : {};
      if (typeof value.name === "string") defaultName = value.name;
    }
  }

  var out = [];
  for (var c = 0; c < list.length; c++) {
    var row = list[c];
    out.push({
      id: row.id,
      name: row.name,
      nodeName: row.nodeName,
      device: row.device,
      default: defaultName !== "" && row.nodeName === defaultName
    });
  }
  return out;
}

// The bit rates worth offering. Above 8M the phone's encoder burns battery
// and heat for detail no conferencing app shows.
function bitRateChoices() {
  return [
    { value: "2M", label: "2 Mbps" },
    { value: "4M", label: "4 Mbps" },
    { value: "8M", label: "8 Mbps" },
    { value: "16M", label: "16 Mbps" }
  ];
}

// What the phone connection looks like, from `android status --json`.
//
// The two halves the panel needs are separate: whether anything is
// connected at all, and what the connected thing calls itself.  A phone
// that is connected but unauthorized has a serial and no model, and its
// row has to say so rather than look connected.
function deviceState(status) {
  var root = isPlainObject(status) ? status : {};
  var authorized = isPlainObject(root.authorized) ? root.authorized : {};
  var attrs = isPlainObject(authorized.attrs) ? authorized.attrs : {};
  var devices = isPlainObject(root.adb_devices) ? root.adb_devices : {};
  var any = false;
  for (var k in devices) any = true;
  return {
    connected: authorized.state === "device",
    model: typeof attrs.model === "string" ? attrs.model : "",
    device: typeof attrs.device === "string" ? attrs.device : "",
    serial: typeof authorized.serial === "string" ? authorized.serial : "",
    anyDevice: any,
    // The host the CLI will try first.  `last_known` is the last thing that
    // worked, which is the best default a connect button can have.
    lastKnown: typeof root.last_known === "string" ? root.last_known : ""
  };
}

// The argv a start or a restart needs, from a settings object.
//
// Both the panel and the bar widget build this, so a value the panel shows
// and the value the CLI is told are produced by the same code. A stream is
// what its argv says, so two different ways to build one argv is two
// different streams.
function argvFrom(settings) {
  var s = isPlainObject(settings) ? settings : {};
  var args = ["--facing", typeof s.facing === "string" && s.facing !== "" ? s.facing : "front",
              "--size", typeof s.size === "string" && s.size !== "" ? s.size : "1280x720",
              "--fps", String(s.fps === undefined || s.fps === null || s.fps === "" ? 30 : s.fps),
              "--bit-rate", typeof s.bitRate === "string" && s.bitRate !== "" ? s.bitRate : "8M"];
  if (s.torch) args.push("--torch");
  if (s.audio) args.push("--with-audio");
  return args;
}
