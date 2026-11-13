# Android Webcam

Manage the Android phone's camera as a host webcam from the Omarchy bar.

The bar icon tells the truth about the stream: grey when nothing is running,
the accent colour when frames are arriving, and the urgent colour when the
process is alive but the picture is not. The last state is the one that
matters, because on this phone the camera HAL releases the camera when the
screen sleeps, which leaves a working process and a black buffer.

One click on the icon starts or stops the stream. A right click opens the
settings, where the camera, the resolution, the frame rate, the bit rate,
the torch and the phone's microphone are all picked from what the phone
actually supports, and where the camera your apps use can be chosen.

The panel also opens a window onto the stream, so the picture can be seen
rather than inferred from numbers. And if there is no phone, the panel finds
it: one button, no address to pick, because the CLI's own search already does
that and the panel reports what it said.

Changing a camera, size, frame rate, bit rate, torch or the microphone while
the stream is running restarts the stream with the new setting. A panel that
accepted the click and changed nothing under a live picture would be a
control that lies.

## What it needs

The plugin drives one command, the skill's own CLI:

    android                       # the android-scrcpy-control skill

Everything else it uses is installed on an Omarchy box already:

| Dependency | What for | Installed by |
|---|---|---|
| `android` | the CLI that does the work | the `android-scrcpy-control` skill |
| `v4l2loopback` | the host camera the stream feeds | `v4l2loopback-dkms` |
| `pw-dump`, `wpctl` | listing and picking the host's camera | `pipewire` |
| `android-tools` | `adb` | `android-tools` |
| `scrcpy` | the stream itself | `scrcpy` |
| `ffmpeg` | measuring the frame | `ffmpeg` |

Without `android` the icon stays grey and the panel says the CLI is missing,
which is the honest answer rather than a row of controls that does nothing.

## Install

```bash
omarchy plugin add https://github.com/ishan-parihar/omarchy-android-webcam.git
omarchy plugin enable ishanp.android-webcam-pro
```

From a checkout of this repository, `scripts/deploy` copies the working tree
into `~/.config/omarchy/plugins/ishanp.android-webcam-pro`, validates it and
restarts the shell. That is the path used while developing, because the
installed copy has no `.git` for `omarchy plugin update` to pull into.

Then place it in the bar, on the right by default:

```bash
omarchy bar move ishanp.android-webcam-pro --section right
```

## What the panel shows

### The preview window

A window, not a picture inside the panel. The plugin cannot draw video
itself — Quickshell blackholes the QtMultimedia import at load time, with no
error shown in the panel — so the preview is `ffplay` over the loopback
device: the frames a conferencing app gets, at the rate the phone sends
them, with no timer in between. A still refreshed on a timer is what this
was first, and it stuttered, because a timer is not a frame clock.

The video driver has to be named (`SDL_VIDEODRIVER=wayland`) or SDL looks
for X11, finds none, and exits before it draws anything. `WAYLAND_DISPLAY`
is inherited from the shell. The button is enabled only while something is
streaming, because a loopback with no writer has no frames and the window
would be a rectangle of nothing.

### The phone

No phone, nothing else works, so this is the panel's other job. One button
runs `android connect`, which already does the whole search: it asks the mDNS
group, remembers the last address that worked, and sweeps the neighborhood
for the port the phone drew this time. The panel does not offer addresses to
pick, because the only thing that could decide between them is the CLI, and
offering them gives the user a wrong click for every endpoint that no longer
answers.

A connect runs when the panel opens with no phone, and again every 90 seconds
while the panel stays open with none. When it fails, the CLI's own reason is
shown, which names what it tried and what it heard, rather than "failed".

### The stream

A running process is not proof, so the panel reports four things
separately, and they are read from the CLI rather than remembered from what
was last clicked:

- a stream running, which is the process
- a writer attached, which is the loopback's sysfs `buffers` count
- a frame that can be read back out of the device
- a picture in that frame, measured as the spread of its luma plane

The last two are different facts. A phone whose camera HAL released the
camera keeps its writer and produces a valid, completely flat frame. That is
`signal: true, frame: false`, and it is shown as a failure with the reason,
because it is exactly the state where a user believes they have a webcam and
do not. `live` requires a real picture, not just a writer.

### The camera on this PC

The point of the plugin. A phone that streams but is not the camera the
system picks is a webcam no app will use, so the host's own cameras are
listed from the PipeWire graph, the one that will be chosen is marked, and
picking a row makes it the default.

The graph is parsed from `pw-dump`, which is JSON with named fields, rather
than scraped out of `wpctl status`. A presentation that changes shape gives
a wrong answer with no error; a missing field does not.

### The phone's camera

Facing, resolution and frame rate are read back from the running stream's
argv when one is running, and from the saved settings when it is not. So the
panel always shows what a start would actually use, and never a choice the
GUI app has since changed.

Changing one of them while the stream runs restarts the stream with the new
value: the service restart is a single systemd call, and the CLI path is a
stop whose exit starts the new one. Nothing is written that is not applied,
and nothing is applied that was not written.

The size and the rate are filtered to what the chosen camera reports, so an
unsupported value is never offered. The higher bit rates are offered with a
note that they cost battery and heat, because above 8 Mbps the phone's
encoder works hard for detail no conferencing app shows.

### Proof

"Save a frame" reads a frame back out of the device and measures it. A black
frame is reported as a failure, not a success, because a valid 1280x720 frame
with nothing in it is exactly what this device's back camera produces, and
every check that counts bytes says the camera works. The saved-frame check
reports mean brightness out of 255 and the range across the frame; the live
status check reports the luma spread, where a flat fill is below 2.0 and a
real picture, even a dark one, is well above it.

## One owner of the camera

The stream is kept up by a systemd user unit, so it restarts when the phone's
camera goes away. That makes two possible owners of one camera, which is a
real failure: the phone refuses a second stream with "the system-wide limit
for number of open cameras has been reached".

So the plugin asks the service whether it owns the camera, and drives the
service when it does. Both read one settings file, which is what keeps a
restart from coming back with the camera the user changed away from:

    ~/.local/state/android-scrcpy-control/webcam-settings.json

The unit, if you want it:

```ini
# ~/.config/systemd/user/android-webcam.service
[Unit]
Description=Android camera as a host webcam (/dev/video0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/android webcam start --settings %h/.local/state/android-scrcpy-control/webcam-settings.json
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=20

[Install]
WantedBy=default.target
```

Two details matter. The stream runs in the foreground here, because
`--background` detaches a child and the unit would exit as soon as the child
was detached. And `KillMode=control-group` is what makes a stopped stream let
go of the device, so the next start is not told it is busy.

## Removal

```bash
omarchy plugin remove ishanp.android-webcam-pro
rm -f ~/.config/systemd/user/android-webcam.service
```

No settings live under `~/.config`, so nothing else is left behind.

## License

MIT. See [LICENSE](LICENSE).

It is a shell plugin, not a reimplementation: the camera path is
`android-scrcpy-control` and `scrcpy`, and the host camera list is PipeWire's.
The plugin is the bar surface, and it drives them.
