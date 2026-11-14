#!/usr/bin/env node
// Tests for Model.js, the plain functions the panel and the bar widget
// both read.  No framework: node runs this file directly.
//
//   scripts/test-model.js
//
// It exists because the two bugs that cost the most time in this plugin
// were both in plain functions: a settings object rebuilt from the wrong
// source lost a click, and an argv built a second way produced a stream
// nobody asked for.  Both are one assert away.

'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8');
// The module is written for the QML engine's CommonJS-ish loader: the
// functions are declared at the top level and nothing is exported, so a
// Function wrapper around it and a return statement is the whole adapter.
const lib = new Function(source + '\nreturn {parseJsonObject, parseJsonArray, ' +
  'isPlainObject, isPlainArray, streamState, deviceState, runningSettings, ' +
  'settingsFromArgv, argvFrom, statePath, facingChoices, practicalSizes, ' +
  'fpsChoices, bitRateChoices, hostCameras, markDefaultSource, phoneCameras};')();

let passed = 0;
let failed = 0;

function check(name, got, want) {
  const a = JSON.stringify(got);
  const b = JSON.stringify(want);
  if (a === b) {
    passed += 1;
  } else {
    failed += 1;
    console.log(`FAIL ${name}\n  got  ${a}\n  want ${b}`);
  }
}

function ok(name, condition) {
  if (condition) {
    passed += 1;
  } else {
    failed += 1;
    console.log(`FAIL ${name}`);
  }
}

// --- argvFrom: the one way a stream is described to the CLI -------------
// A second builder is how two streams get described two ways, so every
// branch is pinned here.
check('argvFrom: defaults', lib.argvFrom({}),
      ['--facing', 'front', '--size', '1280x720', '--fps', '30', '--bit-rate', '8M']);
check('argvFrom: everything', lib.argvFrom({
  facing: 'back', size: '1920x1080', fps: '15', bitRate: '16M', torch: true, audio: true
}), ['--facing', 'back', '--size', '1920x1080', '--fps', '15', '--bit-rate', '16M',
      '--torch', '--with-audio']);
check('argvFrom: junk is the defaults', lib.argvFrom(null), lib.argvFrom({}));
check('argvFrom: flags off', lib.argvFrom({ torch: false, audio: false }).includes('--torch'), false);

// --- runningSettings: read the stream's own argv ------------------------
check('runningSettings: from argv', lib.runningSettings({
  signal: { streaming: true },
  streams: [{ argv: ['scrcpy', '--video-source=camera', '--camera-facing=back',
                     '--camera-size=1920x1080', '--camera-fps=15',
                     '--video-bit-rate=12M', '--camera-high-speed'] }]
}), {
  facing: 'back', size: '1920x1080', fps: '15', bitRate: '12M',
  sink: '', torch: false, audio: false
});
check('runningSettings: no stream', lib.runningSettings({ signal: {} }), null);

// --- deviceState: three different "no phone" ---------------------------
check('deviceState: connected', lib.deviceState({
  authorized: { serial: 's', state: 'device', attrs: { model: 'Redmi', device: 'begonia' } }
}).connected, true);
check('deviceState: unauthorized is not connected', (() => {
  const d = lib.deviceState({ adb_devices: { s: 'unauthorized' } });
  return d.connected === false && d.anyDevice === true;
})(), true);
check('deviceState: nothing', lib.deviceState({}).connected, false);

// --- streamState: live, running-with-no-picture, idle ------------------
check('streamState: live', lib.streamState({
  signal: { streaming: true, frame: true }, host: { sink: '/dev/video0' }
}).state, 'live');
check('streamState: running but flat', lib.streamState({
  signal: { streaming: true, frame: false }, host: {}
}).state, 'no-signal');
check('streamState: not running', lib.streamState({ signal: {} }).state, 'idle');

// --- parseJsonObject: a broken answer is {} not a crash -----------------
check('parseJsonObject: garbage', lib.parseJsonObject('not json'), {});
check('parseJsonObject: empty', lib.parseJsonObject(''), {});
check('parseJsonObject: object', lib.parseJsonObject('{"a":1}'), { a: 1 });

// --- statePath: one owner for the plugin's own files --------------------
check('statePath: settings', lib.statePath('/state', 'webcam-settings.json'),
      '/state/android-scrcpy-control/webcam-settings.json');
check('statePath: frame', lib.statePath('/state', 'frame.png'),
      '/state/android-scrcpy-control/frame.png');

console.log(`Model.js: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);