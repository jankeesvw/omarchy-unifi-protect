import QtQuick
import QtMultimedia
import Quickshell.Io
import qs.Commons
import qs.Ui

// UniFi Protect cameras: one icon in the bar, the pictures in the panel.
//
// The bar shows nothing but a camera glyph, lit while Protect reports motion,
// so a camera that sees something is noticeable out of the corner of your eye
// without a video feed sitting in the bar all day. Everything you would
// actually look at lives in the panel: the selected camera large, the rest as
// thumbnails underneath.
//
// The selected camera plays as real video, straight off the RTSP stream, and
// only while the panel is open. The thumbnails stay stills refreshed every
// few seconds: three decoders running so you can see which camera to click is
// a lot of CPU for a picture the size of a stamp.
//
// A still is also what fills the large view while the stream connects, which
// takes a second or two. Without it the panel would open on a black rectangle
// every time.
//
// All the talking to Protect is in `bin/unifi-protect`, which uses an API key
// rather than a login session. Nothing here knows a credential.
//
// Glyphs are \u escapes rather than literal characters, so the source
// survives editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.unifi-protect"
  ipcTarget: "jankeesvw.unifi-protect"

  readonly property string iconCamera: "\uf03d"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/unifi-protect").toString().replace(/^file:\/\//, "")

  // Address of the console running Protect. Everything the script needs to
  // reach it is passed on the command line rather than read from the
  // environment, so a setting changed in the panel lands on the next tick
  // instead of at the next login.
  readonly property string host: setting("host", "192.168.1.1")
  readonly property int rtspPort: setting("rtspPort", 7447)
  readonly property int archiveKeep: setting("archiveKeep", 60)
  // What a click on the motion notification runs, {path} standing in for the
  // frame. A setting because an image viewer is a matter of taste, and empty
  // for anybody who would rather the popup did nothing.
  readonly property string viewerCommand: setting("viewerCommand", "xdg-open {path}")

  function cmd(args) {
    return [root.script,
            "--host", root.host,
            "--rtsp-port", String(root.rtspPort),
            "--archive-keep", String(root.archiveKeep),
            "--viewer", root.viewerCommand].concat(args)
  }

  // The bar assigns `settings` from a Qt.callLater, one event-loop turn after
  // it constructs the widget, so anything started at completion runs against
  // the fallbacks above rather than the shell.json entry. listProc recovers on
  // its next tick ten minutes on; watchProc is started once and never
  // restarts, so on any console that isn't 192.168.1.1 motion never reaches
  // the bar for the life of the shell. Restarting on a changed command covers
  // that first turn and a setting edited later both — which is what the
  // comment above the host property promises.
  readonly property var watchCommand: root.cmd(["watch"])

  onWatchCommandChanged: {
    // The in-flight list ran against the old settings; letting it finish would
    // leave the widget marked unreachable until the timer comes back around.
    watchProc.running = false
    listProc.running = false
    Qt.callLater(function() {
      watchProc.running = true
      listProc.running = true
    })
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Width of the panel, in the shell's spacing units. The live view is this
  // wide and everything else is measured off it, so this one number sizes the
  // whole panel.
  readonly property int panelWidth: setting("panelWidth", 800)

  // How often the selected camera gets a fresh frame while the panel is open.
  readonly property int refreshMs: setting("refreshMs", 1000)
  // How long the bar icon stays lit after motion. Protect sends a start and,
  // later, an end; this is the floor under a burst that ends immediately.
  readonly property int motionHoldMs: setting("motionHoldMs", 45000)

  property var cameras: []
  property bool reachable: true
  // What the motion watcher last complained about, which is a different thing
  // from the console being unreachable: the cameras can list perfectly well
  // while motion is off because the watcher could not start. It said so on
  // stdout all along and nothing here was listening, so a fresh install where
  // python-websockets is missing showed a widget that simply never lit up.
  property string motionNotice: ""
  property string selectedId: ""
  // Camera id -> path of the newest frame on disk.
  property var frames: ({})
  // Camera id -> rtsp url. Fetched once per camera and kept: the url only
  // changes if the camera is re-adopted.
  property var streams: ({})
  // Snapshots filed at motion, newest first, from `unifi-protect events`.
  property var events: []
  // Path of the archived frame being reviewed, empty while watching live.
  property string reviewPath: ""
  // Camera id -> when it was last filed, to keep a busy camera from filling
  // the archive with near-identical frames.
  property var lastCapture: ({})
  // Camera id of the most recent motion, empty once it has gone quiet.
  property string motionId: ""

  // Which cameras you actually want to hear about, by name. Empty means all
  // of them. This gates the bar icon and the archive both: the camera aimed
  // at your own desk reports motion all day, and an icon that is always lit
  // is an icon you stop reading.
  //
  // A comma-separated line is what the settings panel can offer; a JSON list
  // is what somebody editing shell.json by hand will reach for. Both are read,
  // so neither way of writing it is wrong.
  readonly property var alertCameras: {
    var raw = setting("alertCameras", "")
    var parts = Array.isArray(raw) ? raw : String(raw).split(",")
    var names = []
    for (var i = 0; i < parts.length; i++) {
      var name = String(parts[i]).trim()
      if (name !== "") names.push(name.toLowerCase())
    }
    return names
  }

  // Matched without regard to case: this is a name you typed into a settings
  // field, not one the gateway handed over.
  function alerts(id) {
    if (alertCameras.length === 0) return true
    var name = nameOf(id).toLowerCase()
    for (var i = 0; i < alertCameras.length; i++)
      if (alertCameras[i] === name) return true
    return false
  }

  readonly property bool hasCameras: cameras.length > 0

  function cameraById(id) {
    for (var i = 0; i < cameras.length; i++) if (cameras[i].id === id) return cameras[i]
    return null
  }

  readonly property var selected: cameraById(selectedId)
  readonly property var motionCamera: cameraById(motionId)

  readonly property bool reviewing: reviewPath !== ""
  readonly property var reviewEvent: {
    for (var i = 0; i < events.length; i++)
      if (events[i].path === reviewPath) return events[i]
    return null
  }
  readonly property string reviewCamera: reviewEvent ? reviewEvent.camera : ""
  readonly property int reviewTs: reviewEvent ? reviewEvent.ts : 0

  function frameFor(id) {
    var p = frames[id]
    return p ? "file://" + p : ""
  }

  // Replaced rather than mutated: QML does not notice a key being written
  // into an existing object, so the bindings would keep the first frame.
  function setFrame(id, path) {
    var next = {}
    for (var k in frames) next[k] = frames[k]
    next[id] = path
    frames = next
  }

  // Merges a whole batch of frames in one go, rather than one setFrame per
  // key: cachedProc hands back every camera's frame at once, and replacing
  // `frames` once means one binding update instead of one per camera.
  function mergeFrames(map) {
    var next = {}
    for (var k in frames) next[k] = frames[k]
    for (var k in map) next[k] = map[k]
    frames = next
  }

  function setStream(id, url) {
    var next = {}
    for (var k in streams) next[k] = streams[k]
    next[id] = url
    streams = next
  }

  readonly property string selectedStream: selectedId !== "" && streams[selectedId]
    ? streams[selectedId] : ""

  Process {
    id: streamProc
    property string cameraId: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var url = text.trim()
        if (url.indexOf("rtsp://") === 0) root.setStream(streamProc.cameraId, url)
      }
    }
  }

  function resolveStream(id) {
    if (id === "" || streams[id] || streamProc.running) return
    streamProc.cameraId = id
    streamProc.command = root.cmd(["stream", id])
    streamProc.running = true
  }

  // The icon alone, until a camera sees something: then the name slides in
  // beside it and the bar visibly makes room. A colour change on a glyph this
  // size is easy to miss in a bar this full; a bar that moves is not, and it
  // says which camera in the same gesture.
  implicitWidth: button.implicitWidth + (hasAlert ? label.implicitWidth + Style.space(6) : 0)
  implicitHeight: button.implicitHeight

  readonly property bool hasAlert: motionId !== "" && motionCamera !== null

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  // ---------------------------------------------------------------- cameras

  Process {
    id: listProc
    command: root.cmd(["list"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.reachable = data.ok === true
          root.cameras = data.cameras || []
          if (root.selectedId === "" && root.cameras.length > 0)
            root.selectedId = root.cameras[0].id
        } catch (e) {
          root.reachable = false
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reachable = false
    }
  }

  // The camera list barely changes, so this is about noticing one that was
  // added or unplugged, not about keeping up with anything.
  Timer {
    interval: 600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!listProc.running) listProc.running = true
  }

  // --------------------------------------------------------------- snapshots

  // Two fetchers, because the selected camera wants a new frame every second
  // and the thumbnails are happy with one every few. Sharing a single process
  // would make the large picture wait behind the small ones.
  Process {
    id: mainShot
    property string cameraId: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var path = text.trim()
        if (path !== "" && path.charAt(0) === "/") root.setFrame(mainShot.cameraId, path)
      }
    }
  }

  Process {
    id: thumbShot
    property string cameraId: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var path = text.trim()
        if (path !== "" && path.charAt(0) === "/") root.setFrame(thumbShot.cameraId, path)
      }
    }
  }

  function grab(proc, id) {
    if (id === "" || proc.running) return
    proc.cameraId = id
    proc.command = root.cmd(["snapshot", id])
    proc.running = true
  }

  // Whatever `snapshot` left on disk from before this Panel instance existed
  // -- last run, last quickshell reload -- so the thumbnails open on the last
  // live view of each camera instead of a blank rectangle with just a name on
  // it until the first round of snapshots lands. Run once, at startup: this
  // is only ever a backfill for the gap before real frames arrive.
  Process {
    id: cachedProc
    command: root.cmd(["cached"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok && data.frames) root.mergeFrames(data.frames)
        } catch (e) {}
      }
    }
  }

  Component.onCompleted: cachedProc.running = true

  // Slow, because this only feeds the still behind the video: a fresh one
  // matters when the stream is still connecting or has dropped out, not while
  // it is playing.
  Timer {
    id: mainTimer
    interval: root.refreshMs
    running: root.opened && root.selectedId !== ""
      && player.playbackState !== MediaPlayer.PlayingState
    repeat: true
    triggeredOnStart: true
    onTriggered: root.grab(mainShot, root.selectedId)
  }

  // Walks the list one camera at a time so the thumbnails fill in staggered
  // rather than all at once, which keeps three snapshot requests off the
  // gateway in the same instant.
  Timer {
    id: thumbTimer
    property int cursor: 0
    interval: 1500
    running: root.opened && root.cameras.length > 1
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.cameras.length === 0) return
      cursor = (cursor + 1) % root.cameras.length
      var id = root.cameras[cursor].id
      // The selected one is already being refreshed every second.
      if (id !== root.selectedId) root.grab(thumbShot, id)
    }
  }

  // Opening should not show the frame from the last time the panel was up, so
  // the selected camera is refetched immediately and the rest follow.
  onOpenedChanged: {
    if (opened) {
      thumbTimer.cursor = 0
      root.grab(mainShot, root.selectedId)
      root.resolveStream(root.selectedId)
      root.refreshEvents()
    } else {
      // Next opening starts on live rather than on whatever was being
      // reviewed when the panel was dismissed.
      root.reviewPath = ""
    }
  }

  // ------------------------------------------------------------------ motion

  // Runs for as long as the shell does. `unifi-protect watch` holds a websocket
  // open and reconnects on its own, so there is nothing to poll and motion
  // shows up in the bar the moment Protect sees it.
  Process {
    id: watchProc
    running: true
    command: root.watchCommand
    stdout: SplitParser {
      onRead: function(line) {
        var event
        try {
          event = JSON.parse(line)
        } catch (e) {
          return
        }
        if (event.type === "error") {
          root.motionNotice = root.plain(event.error || "")
          return
        }
        if (event.type === "motion" && event.camera) root.motionNotice = ""
        if (event.type !== "motion" || !event.camera) return
        if (!root.alerts(event.camera)) return
        if (event.ended) {
          // Protect repeats the event with an end time once the movement
          // stops. Only the camera currently lit is cleared: an older camera
          // finishing should not take the light off a newer one.
          if (root.motionId === event.camera) {
            root.motionId = ""
            motionTimer.stop()
          }
          return
        }
        root.onMotion(event.camera)
      }
    }
  }

  Timer {
    id: motionTimer
    interval: root.motionHoldMs
    onTriggered: root.motionId = ""
  }

  // Everything that happens when a camera sees something, in one place: the
  // websocket and the test hook both come through here.
  function onMotion(id) {
    motionId = id
    motionTimer.restart()
    // File a frame straight away, so there is something to look back at
    // whether or not the panel happens to be open.
    capture(id)
    // Only worth reloading the list if it is on screen.
    if (opened) archiveTimer.restart()
  }

  // The capture is a second or two behind the event, so the list is reloaded
  // after the snapshot has had time to land rather than immediately.
  Timer {
    id: archiveTimer
    interval: 4000
    onTriggered: root.refreshEvents()
  }

  // ----------------------------------------------------------------- archive

  // How long after filing a frame the same camera is left alone. Protect can
  // report a dozen starts while one person walks past the door.
  readonly property int captureThrottleMs: setting("captureThrottleMs", 25000)



  Process {
    id: captureProc
  }

  // Popups on motion. On by default: the whole point of the bar icon is that
  // you might not be looking at it.
  readonly property bool notify: setting("notify", true)

  function capture(id) {
    var now = Date.now()
    if (lastCapture[id] && now - lastCapture[id] < captureThrottleMs) return
    if (captureProc.running) return

    var next = {}
    for (var k in lastCapture) next[k] = lastCapture[k]
    next[id] = now
    lastCapture = next

    // The name comes along so the script can put it in the notification.
    // Whether one is raised at all is the script's call: it files a frame per
    // burst of motion, and only a filed frame is worth a popup.
    captureProc.command = notify
      ? root.cmd(["capture", id, nameOf(id)])
      : root.cmd(["capture", id])
    captureProc.running = true
  }

  Process {
    id: eventsProc
    command: root.cmd(["events", "12"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.events = data.events || []
        } catch (e) {
          root.events = []
        }
      }
    }
  }

  function refreshEvents() {
    if (!eventsProc.running) eventsProc.running = true
  }

  // Ticks so the labels below age on screen instead of freezing at whatever
  // they said when the panel opened. Only while it is open: nobody is reading
  // a closed panel.
  property double now: Date.now()

  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // "5m" rather than "08:02": with the archive read at a glance, how long ago
  // is the question, not what the clock said.
  function agoOf(ts) {
    var secs = Math.max(0, Math.round((now - ts * 1000) / 1000))
    if (secs < 60) return secs + "s"
    if (secs < 3600) return Math.floor(secs / 60) + "m"
    if (secs < 86400) return Math.floor(secs / 3600) + "h"
    return Math.floor(secs / 86400) + "d"
  }

  // The long form, for the header where there is room for words.
  function agoLongOf(ts) {
    var secs = Math.max(0, Math.round((now - ts * 1000) / 1000))
    if (secs < 10) return "just now"
    if (secs < 60) return secs + " seconds ago"
    if (secs < 120) return "a minute ago"
    if (secs < 3600) return Math.floor(secs / 60) + " minutes ago"
    if (secs < 7200) return "an hour ago"
    if (secs < 86400) return Math.floor(secs / 3600) + " hours ago"
    if (secs < 172800) return "yesterday"
    return Math.floor(secs / 86400) + " days ago"
  }

  function nameOf(id) {
    var c = cameraById(id)
    return c ? c.name : "?"
  }

  // Qt decides for itself whether a string is markup, and a Text or tooltip in
  // that mode fetches `<img src="http://...">` for real, from inside the shell
  // process. Camera names, detection types and error text are all Protect's
  // words rather than ours, so none of them is ours to vouch for. The panel's
  // own Text elements are pinned to PlainText; the bar tooltip and the section
  // header are the shell's components and not ours to set, so anything heading
  // that way has its angle brackets taken off first -- without a `<` there is
  // nothing for Qt to mistake for a tag.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[<>]/g, "")
  }

  // Lets the icon be exercised without waiting for a person to walk past a
  // camera:  omarchy-shell jankeesvw.unifi-protect.test motion "Front door"
  // The name is matched against the camera list, so a typo does nothing
  // rather than lighting up an id nobody recognises.
  IpcHandler {
    target: "jankeesvw.unifi-protect.test"

    function motion(name: string): string {
      for (var i = 0; i < root.cameras.length; i++) {
        if (root.cameras[i].name.toLowerCase() !== name.toLowerCase()) continue
        var id = root.cameras[i].id
        // Through the same filter a real event goes through, so this reports
        // what the bar would actually do rather than what it can be made to
        // do.
        if (!root.alerts(id)) return root.cameras[i].name + " is not in alertCameras"
        root.onMotion(id)
        return "motion on " + root.cameras[i].name
      }
      return "no camera named " + name
    }

    function clear(): string {
      root.motionId = ""
      motionTimer.stop()
      return "off"
    }
  }

  // ------------------------------------------------------------------ protect

  // Where clicking a camera takes you: Protect's detection browser, filtered
  // to that camera. Protect is a single-page app, so this route cannot be read
  // off the gateway; it was taken from the address bar. A setting rather than
  // a constant, because a UniFi update is free to move it.
  //   {host}   the gateway
  //   {camera} the camera id
  // The %3A is an encoded colon: the filter reads "camera:<id>".
  readonly property string eventsUrl: setting("eventsUrl",
    "https://{host}/protect/detections/find-anything?grade=all&labels=camera%3A{camera}&minConfidence=30")

  Process {
    id: browserProc
  }

  function openProtect(id) {
    if (id === "") return
    var url = eventsUrl.replace("{host}", host).replace("{camera}", id)
    browserProc.command = ["xdg-open", url]
    browserProc.running = true
    root.close()
  }

  // --------------------------------------------------------------------- bar

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: root.iconCamera
    // Lit while a camera is seeing something, which is the one thing worth
    // interrupting you for; the rest of the time it sits back, dimmed.
    //
    // `dimmed` rather than setting opacity directly: WidgetButton drives its
    // own opacity and puts a Behavior on it, so a second binding on the same
    // property fights the animation instead of replacing it.
    active: root.motionId !== ""
    dimmed: root.motionId === "" || !root.reachable
    tooltipText: !root.reachable
      ? "Protect unreachable"
      : (root.motionCamera
         ? root.plain("Motion at " + root.motionCamera.name)
         : "Cameras")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        // Straight to Protect for whatever is moving, or the selected camera
        // when nothing is, without going through the panel.
        root.openProtect(root.motionId !== "" ? root.motionId : root.selectedId)
        return
      }
      // A camera that just saw something is the one you opened the panel for.
      if (!root.opened && root.motionId !== "") root.selectedId = root.motionId
      root.toggle()
    }
  }

  Text {
    id: label
    textFormat: Text.PlainText
    anchors.left: button.right
    anchors.leftMargin: Style.space(2)
    anchors.verticalCenter: parent.verticalCenter
    visible: root.hasAlert
    text: root.hasAlert ? root.motionCamera.name : ""
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: root.bar ? root.bar.urgent : Color.urgent

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.selectedId = root.motionId
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------------- panel

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    // Click, not hover: a panel that pulls three camera feeds should open
    // because you meant it, not because the cursor crossed the bar.
    triggerMode: "click"
    // Wide enough that the live view is worth looking at rather than merely
    // present. `fittedContentWidth` caps it to the screen, so a number too
    // large for a small display is trimmed rather than clipped.
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      spacing: Style.space(8)

      PanelSectionHeader {
        width: parent.width
        text: root.reviewing
          ? root.plain(root.nameOf(root.reviewCamera).toUpperCase() + "  \u00b7  "
                       + root.agoLongOf(root.reviewTs))
          : (root.selected ? root.plain(root.selected.name.toUpperCase()) : "CAMERAS")
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      // Large view of the selected camera.
      Rectangle {
        width: parent.width
        height: Math.round(width * 9 / 16)
        radius: Style.space(6)
        color: Qt.rgba(0, 0, 0, 0.35)
        clip: true

        // The still sits underneath and shows through until the stream has
        // its first frame, so opening the panel never starts on black.
        SmoothFrame {
          id: mainImage
          anchors.fill: parent
          source: root.reviewing
            ? "file://" + root.reviewPath
            : (root.selected ? root.frameFor(root.selected.id) : "")
          visible: ready
        }

        VideoOutput {
          id: video
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectCrop
          visible: !root.reviewing && player.playbackState === MediaPlayer.PlayingState
        }

        // Playing only while the panel is open. A camera stream left running
        // behind a closed panel is a decoder and a few megabits a second for
        // a picture nobody is looking at.
        MediaPlayer {
          id: player
          videoOutput: video
          source: root.opened && !root.reviewing ? root.selectedStream : ""
          // No AudioOutput is attached on purpose: without one Qt plays the
          // video and drops the audio track, which is what a bar panel wants.

          onSourceChanged: if (source != "") play()
          onErrorOccurred: function(err, str) {
            // Falling back to the stills is better than an empty rectangle;
            // they keep refreshing regardless of what the stream does.
            console.log("jankeesvw.unifi-protect: stream error", err, str)
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !mainImage.visible && !video.visible
          text: root.reachable ? "Connecting" : "Protect unreachable"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.6
        }

        // The picture is the link. A camera you are looking at and want to know
        // more about is the same camera, so there is nothing to aim at but
        // what is already on screen.
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openProtect(root.reviewing ? root.reviewCamera : root.selectedId)
        }

        // Reviewing a frame needs a way out that is where your eye already is,
        // rather than a button somewhere below the picture.
        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: Style.space(6)
          visible: root.reviewing
          width: backLabel.implicitWidth + Style.space(12)
          height: backLabel.implicitHeight + Style.space(6)
          radius: height / 2
          color: Qt.rgba(0, 0, 0, 0.6)

          Text {
            id: backLabel
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "\u2190 live"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.reviewPath = ""
          }
        }

        // Only while the panel is open, so it reads as "this is live now"
        // rather than decoration.
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(6)
          visible: !root.reviewing && root.motionId !== "" && root.selected
            && root.motionId === root.selected.id
          width: motionLabel.implicitWidth + Style.space(10)
          height: motionLabel.implicitHeight + Style.space(4)
          radius: height / 2
          color: Qt.rgba(0, 0, 0, 0.55)

          Text {
            id: motionLabel
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "motion"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
          }
        }
      }

      // Thumbnails, one per camera, to switch the large view.
      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: root.cameras.length > 1

        Repeater {
          model: root.cameras

          Rectangle {
            required property var modelData

            readonly property bool isSelected: modelData.id === root.selectedId
            readonly property bool hasMotion: modelData.id === root.motionId

            width: Math.floor((content.width - Style.space(6) * (root.cameras.length - 1)) / root.cameras.length)
            height: Math.round(width * 9 / 16)
            radius: Style.space(4)
            color: Qt.rgba(0, 0, 0, 0.35)
            clip: true

            // The selected camera is outlined, one with motion is outlined
            // thicker. Nothing blinks: the bar icon already did the job of
            // getting your attention.
            border.width: hasMotion ? Style.space(2) : (isSelected ? Style.space(1) : 0)
            border.color: root.foreground
            opacity: isSelected || hasMotion ? 1 : 0.55

            SmoothFrame {
              anchors.fill: parent
              anchors.margins: parent.border.width
              source: root.frameFor(modelData.id)
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              text: modelData.name
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              style: Text.Outline
              styleColor: Qt.rgba(0, 0, 0, 0.7)
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.selectedId = modelData.id
                root.grab(mainShot, modelData.id)
                root.resolveStream(modelData.id)
              }
            }
          }
        }
      }

      // What the cameras saw, newest first. Stills rather than video: Protect
      // keeps the recordings and this is the shortcut that answers "was
      // somebody at the door" without opening anything.
      PanelSectionHeader {
        width: parent.width
        visible: root.events.length > 0
        text: "RECENTLY SEEN"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: root.events.length > 0

        Repeater {
          // Four across at the panel's width leaves them readable; the rest of
          // the archive is on disk for anything that needs more than a glance.
          model: root.events.slice(0, 4)

          Rectangle {
            required property var modelData

            readonly property bool isReviewed: modelData.path === root.reviewPath

            width: Math.floor((content.width - Style.space(6) * 3) / 4)
            height: Math.round(width * 9 / 16)
            radius: Style.space(4)
            color: Qt.rgba(0, 0, 0, 0.35)
            clip: true

            border.width: isReviewed ? Style.space(1) : 0
            border.color: root.foreground
            opacity: isReviewed ? 1 : 0.75

            SmoothFrame {
              anchors.fill: parent
              anchors.margins: parent.border.width
              source: "file://" + modelData.path
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              text: root.agoOf(modelData.ts) + "  " + root.nameOf(modelData.camera)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              style: Text.Outline
              styleColor: Qt.rgba(0, 0, 0, 0.7)
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              // Clicking the one already up puts the live picture back, so the
              // same click both enters and leaves the archive.
              onClicked: root.reviewPath = isReviewed ? "" : modelData.path
            }
          }
        }
      }

      // Motion being off is worth saying even when the cameras are fine, so
      // this sits outside the no-cameras notice rather than inside it.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.motionNotice !== ""
        text: root.motionNotice
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.6
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !root.hasCameras
        text: root.reachable ? "No cameras found" : "Protect unreachable"
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.6
      }
    }
  }
}
