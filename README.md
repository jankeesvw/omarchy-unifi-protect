# UniFi Protect

An [Omarchy](https://omarchy.org) bar widget for [UniFi
Protect](https://ui.com/protect) cameras: one small icon in the bar, and the
pictures in a panel behind it.

![The panel open: one camera large, the others as thumbnails, and the frames filed the last time something moved](preview.jpg)

The bar shows a camera glyph and nothing else. It lights up, and the name of
the camera slides in beside it, while Protect reports motion — so a camera
that sees something is noticeable out of the corner of your eye without a
video feed sitting in the bar all day.

Everything you would actually look at lives in the panel: the selected camera
large and playing live, the other cameras as thumbnails underneath, and below
those the frames your cameras filed the last time they saw something. Clicking
any picture opens that camera in Protect's own detection browser, which is
where you go when a glance is not enough.

## Install

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-unifi-protect.git --enable
```

Then give it a key, pin your console's certificate, and tell it where the
console is — the three sections below. The widget lands in the right section
of the bar; move it with `omarchy bar move`, or from the bar's own settings
panel.

A fresh Omarchy install does not have a Protect console at the default
address (`192.168.1.1`). Set `host` before you expect the icon to do
anything, or the first list talks to the wrong gateway.

## The API key

Everything goes through Protect's integration API, which takes a plain
`X-API-KEY` header. Make a key at `https://<your-console>/unifi-api/protect`.

> ⚠️ UniFi hands a key the full rights of the account that created it, and
> there is no way to scope it down to Protect over the API. A key made on your
> own admin login is your whole console in a file on your laptop.
>
> Make a local user for it instead. Under **Settings → Admins & Users → Add
> User**, choose a local account, give it **Protect: View Only** and nothing
> else, and make the key while signed in as that user. The widget only ever
> lists cameras, pulls stills and reads stream urls, so view-only is all it
> needs — and a key that leaks is then a key that can look at your cameras
> rather than one that can reconfigure your network.

The widget looks for the key in two places, in this order:

1. `UNIFI_API_KEY` in the environment.
2. A file, by default `~/.config/unifi-protect/api-key`. Set
   `UNIFI_API_KEY_FILE` to put it somewhere else.

The file is the one that works straight away, because a variable exported into
your session does not reach a shell that is already running:

```bash
mkdir -p ~/.config/unifi-protect
(umask 077; printf '%s\n' "paste-your-key-here" > ~/.config/unifi-protect/api-key)
```

The first line with something on it is the key, trimmed. Nothing else in the
file is parsed, and the widget never writes to it.

## Pinning the console

Your console signs its own certificate. There is no authority that can vouch
for it, so there is nothing to check it against — and the key above travels on
every one of these connections. Pin it once:

```bash
~/.config/omarchy/plugins/jankeesvw.unifi-protect/bin/unifi-protect \
  --host 192.168.1.1 trust
```

It prints the fingerprint of whatever answered on that address and waits.
Compare it against the one the console shows under **Settings → System →
Advanced** before you agree — that comparison is the whole of the security
here, and it is the one moment you get to make it. Then the certificate is
filed in `~/.config/unifi-protect/gateway.pem` and every later connection has
to present that same key or be dropped before the API key goes out.

Until you have done this the widget refuses to talk to anything, and says so.
Run it again after a console reset or a certificate renewal, which is the only
other time the fingerprint should change.

## Settings

All of it is configurable from the bar's settings panel, or by hand in the
widget's entry in `~/.config/omarchy/shell.json`:

| Setting | Default | What it does |
|---|---|---|
| `host` | `192.168.1.1` | The console running Protect — a UDM, a Cloud Key, whatever answers on your network. Address or hostname, no scheme. |
| `alertCameras` | *(empty)* | Camera names, comma separated, that may light the icon and file frames. Empty means all of them. |
| `notify` | `true` | Raise a desktop notification, with the frame in it, on motion. |
| `viewerCommand` | `xdg-open {path}` | What clicking that notification runs, to see the frame full size. |
| `panelWidth` | `800` | Panel width in the shell's spacing units. Trimmed to fit a small screen. |
| `motionHoldMs` | `45000` | How long the icon stays lit after motion. |
| `refreshMs` | `1000` | How often the large view gets a fresh still while the stream is connecting. |
| `captureThrottleMs` | `25000` | How long a camera that just filed a frame files nothing more. |
| `archiveKeep` | `60` | Frames kept per camera. |
| `rtspPort` | `7447` | The plain RTSP port on the console. |
| `eventsUrl` | *(see below)* | Where clicking a picture takes you. |

`alertCameras` is worth setting. The camera aimed at your own desk reports
motion all day, and an icon that is always lit is an icon you stop reading:

```json
{ "id": "jankeesvw.unifi-protect", "host": "10.0.0.1", "alertCameras": "Front door, Shed" }
```

Names are matched against what Protect calls the cameras, ignoring case. The
setting gates the bar icon and the archive both; every camera stays visible in
the panel regardless.

The notification carries the frame as its icon, which is a thumbnail; clicking
it opens the same picture full size. `viewerCommand` is what runs, with
`{path}` standing in for the frame:

```json
{ "id": "jankeesvw.unifi-protect", "viewerCommand": "imv {path}" }
```

The default hands the file to whatever your desktop opens a JPEG with. Name a
viewer to be sure of which one, or leave it empty for a popup that does
nothing. The command goes out as the `omarchy-exec` hint, which the shell's
notification server keeps with the toast, so a frame is still one click away
after the popup has moved into the notification history.

`eventsUrl` is Protect's detection browser filtered to one camera. `{host}` is
the console and `{camera}` the camera id, and the default is:

```
https://{host}/protect/detections/find-anything?grade=all&labels=camera%3A{camera}&minConfidence=30
```

It is a setting rather than a constant because Protect is a single-page app:
that route cannot be read off the console, it was taken from the address bar,
and a UniFi update is free to move it.

## What it costs to run

The large view plays the camera's real RTSP stream, and only while the panel
is open. A stream left running behind a closed panel is a decoder and a few
megabits a second spent on a picture nobody is looking at.

The thumbnails stay stills, refreshed one camera at a time: three decoders
running so you can see which camera to click is a lot of CPU for a picture the
size of a stamp. A still is also what fills the large view for the second or
two the stream takes to connect, so opening the panel never starts on black.

With the panel closed, the widget holds one websocket open for motion events
and does nothing else. There is no polling.

## The archive

Every burst of motion on a camera you listed files one frame, whether or not
the panel happens to be open, in
`~/.local/state/unifi-protect/events/<camera-id>-<unix-time>.jpg`. The newest
four show up under the panel; clicking one puts it in the large view with how
long ago it was, and clicking it again goes back to live.

Frames are stored around 960px wide, so `archiveKeep` at its default of 60 per
camera is a few megabytes and covers a busy day. Protect keeps the actual
recordings; this is the shortcut that answers "was somebody at the door"
without opening anything.

## The command line

The widget shells out to `bin/unifi-protect` in this repo for everything, and
that script is usable on its own:

```bash
cd ~/.config/omarchy/plugins/jankeesvw.unifi-protect

./bin/unifi-protect list                  # cameras, as JSON
./bin/unifi-protect snapshot <camera-id>  # writes a JPEG, prints its path
./bin/unifi-protect events                # the archive, newest first
./bin/unifi-protect stream <camera-id>    # the RTSP url
./bin/unifi-protect live <camera-id>      # opens the stream in mpv
./bin/unifi-protect watch                 # motion as NDJSON, until killed
```

`--host`, `--rtsp-port` and `--archive-keep` go before the command. It is also
the first place to look when the bar icon stays dim: run `list` by hand and the
error comes back as JSON instead of disappearing into the shell's log.

To see what the widget thinks is going on, or to exercise the icon without
waiting for somebody to walk past a camera:

```bash
omarchy-shell jankeesvw.unifi-protect.test status
omarchy-shell jankeesvw.unifi-protect.test motion "Front door"
omarchy-shell jankeesvw.unifi-protect.test clear
```

`status` prints the host it is calling, whether the last list succeeded, and
the cameras it has. If that host is still `192.168.1.1` after you set a
different one, restart the shell (`omarchy restart shell`) so the widget
picks the setting up.

## Requirements

Omarchy with `omarchy-shell` (the Quickshell-based bar), and:

| | |
|---|---|
| `curl`, `jq` | talking to Protect |
| `python3` + [`websockets`](https://pypi.org/project/websockets/) | motion events. The system package is used if present; otherwise a user venv is created on first watch, so a fresh install does not need sudo. Without either, everything works except the icon lighting up. |
| `imagemagick` | shrinking archived frames. Without it they are stored full size. |
| `libnotify` | the notification on motion |
| `mpv` | only for `unifi-protect live` |

On Arch, the tidy way is the system package. Omarchy's `omarchy pkg add`
installs it if you want that; `watch` will also create
`~/.local/share/unifi-protect/venv` and put `websockets` there the first
time it needs it.

```bash
omarchy pkg add python-websockets
# or
sudo pacman -S --needed curl jq python python-websockets imagemagick libnotify mpv
```

Chain and hostname checking are off for calls to the console — its
certificate names the console, not the address you reach it on, and nothing on
your network can build a chain to it. What replaces them is the certificate
you pinned: curl is given `--pinnedpubkey`, which it enforces regardless, and
the motion websocket loads the pinned certificate as its only trust root. A
connection that presents anything else is dropped before the API key is sent.

Camera ids come off those connections and end up in filenames, so they are
checked against `[A-Za-z0-9]{1,64}` — Protect's own format — and anything else
is refused rather than escaped.

The live view reads the stream off the plain RTSP port rather than the
encrypted one, because Qt Multimedia gives no way to trust a self-signed
certificate; `unifi-protect live` keeps the encrypted URL, since mpv can be
told to accept it. Neither carries the API key: Protect hands back a
per-camera stream alias and that is all that travels.

## Remove

```bash
omarchy plugin remove jankeesvw.unifi-protect
```

The archived frames are yours, not the plugin's, so they stay in
`~/.local/state/unifi-protect/`. Delete that directory, and
`~/.config/unifi-protect/` with the key and the pinned certificate in it, if
you want them gone too.

## License

MIT
