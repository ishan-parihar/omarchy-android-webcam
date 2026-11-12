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
//   signal.signal      the loopback is carrying frames
//   signal.frame       a frame was read back from the device
//
// A process can be alive while the phone's camera HAL has dropped the
// camera, which is the failure that kept happening here: the stream
// survived, the picture did not. The icon must not say "streaming" in that
// state, because the user would believe they have a webcam and do not.
function streamState(status) {
  var signal = isPlainObject(status.signal) ? status.signal : {};
  var host = isPlainObject(status.host) ? status.host : {};

  var streaming = signal.streaming === true;
  var carrying = signal.signal === true;
  var frame = signal.frame === true;

  var state = "idle";
  if (streaming && carrying && frame) state = "live";
  else if (streaming && carrying) state = "streaming";
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
    // A stream running with no picture is the state worth surfacing, because
    // the process list still shows scrcpy and the user has no other clue.
    detail: state === "no-signal"
      ? "The stream is running but no frames are arriving. The phone may have gone to sleep, or another app took the camera."
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
