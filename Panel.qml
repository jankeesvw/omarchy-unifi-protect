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
  readonly property string iconGear: "\u2699"
  readonly property string iconBack: "\u2190"

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
  // "cameras" or "settings". Setup that is still missing a key lands on
  // settings instead of the dead "Protect unreachable" text.
  property string view: "settings"
  property bool hasKey: false
  // Whether the gateway's certificate has been pinned. Until it has, no
  // request carries the key: the console signs its own certificate, so a
  // person comparing the fingerprint against the one it shows under
  // Settings -> System is the only thing separating it from anything else
  // that can answer at that address.
  property bool trusted: false
  // What `trust show` last reported: fingerprint, subject, expiry, and the
  // fingerprint already on file if there is one.
  property var trustInfo: null
  property string trustError: ""
  readonly property bool needsSetup: !hasKey
  readonly property bool needsTrust: hasKey && !trusted
  // True only after the user opened settings on purpose, so a successful
  // status check does not yank them back to cameras mid-edit.
  property bool userWantsSettings: false
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

  // Repeater rebuilds every delegate when the model is replaced, which blanks
  // the thumbnails. The list barely changes, so keep the existing array when
  // nothing in it moved.
  function sameCameras(next) {
    if (!next || next.length !== cameras.length) return false
    for (var i = 0; i < next.length; i++) {
      if (cameras[i].id !== next[i].id) return false
      if (cameras[i].name !== next[i].name) return false
      if (cameras[i].connected !== next[i].connected) return false
    }
    return true
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
          var next = data.cameras || []
          if (!root.sameCameras(next)) root.cameras = next
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
    onTriggered: {
      if (!listProc.running) listProc.running = true
      root.refreshStatus()
    }
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
    running: root.opened && root.view === "cameras" && root.selectedId !== ""
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
    running: root.opened && root.view === "cameras" && root.cameras.length > 1
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
      if (root.needsSetup) root.showSettings()
      else if (root.needsTrust) root.showTrust()
      else if (!root.userWantsSettings) root.showCameras()
      root.refreshStatus()
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

  // Runtime on/off, flipped from the panel's own switch rather than the
  // settings form. Starts from the persisted default but the panel does not
  // write shell.json, so a flip here lasts for the life of the shell rather
  // than surviving a restart -- closer to muting an alert than to changing a
  // setting.
  property bool notifyEnabled: notify

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
    captureProc.command = notifyEnabled
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

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveHost(value) {
    var next = String(value === undefined || value === null ? "" : value).trim()
    if (next === "") next = "192.168.1.1"
    if (next !== root.host) {
      persistSettings({ host: next })
      refreshStatus()
      if (!listProc.running) listProc.running = true
      restartWatch()
    }
    if (hostField) hostField.text = next
  }

  function saveKey() {
    var k = keyField ? String(keyField.text).trim() : ""
    if (k === "" || setKeyProc.running) return
    setKeyProc.pending = k
    setKeyProc.command = root.cmd(["set-key"])
    setKeyProc.running = true
  }

  function pasteKey() {
    if (pasteKeyProc.running) return
    pasteKeyProc.command = ["wl-paste", "--no-newline", "--type", "text"]
    pasteKeyProc.running = true
  }

  function focusField(field) {
    if (field) field.forceActiveFocus()
  }

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = root.cmd(["status"])
    statusProc.running = true
  }

  function refreshAfterCredential() {
    refreshStatus()
    if (!listProc.running) listProc.running = true
    restartWatch()
  }

  function restartWatch() {
    watchProc.running = false
    Qt.callLater(function() { watchProc.running = true })
  }

  function showSettings() {
    view = "settings"
    if (hostField) hostField.text = root.host
    Qt.callLater(function() { root.focusField(keyField) })
  }

  function showCameras() {
    userWantsSettings = false
    view = "cameras"
  }

  function showTrust() {
    view = "trust"
    trustError = ""
    trustInfo = null
    if (!trustShowProc.running) {
      trustShowProc.command = root.cmd(["trust", "show"])
      trustShowProc.running = true
    }
  }

  // Pins what `trust show` put on screen, and only that: `trust accept`
  // re-fetches the chain and refuses if the fingerprint has changed since,
  // so agreeing to one certificate cannot pin a different one.
  function acceptTrust() {
    if (!trustInfo || trustAcceptProc.running) return
    trustError = ""
    trustAcceptProc.command = root.cmd(["trust", "accept", String(trustInfo.fingerprint)])
    trustAcceptProc.running = true
  }

  function toggleAlertCamera(name) {
    var want = String(name).toLowerCase()
    var allOn = alertCameras.length === 0
    var checked = []
    for (var i = 0; i < cameras.length; i++) {
      var n = String(cameras[i].name)
      var on = allOn
      if (!allOn) {
        on = false
        for (var j = 0; j < alertCameras.length; j++) {
          if (alertCameras[j] === n.toLowerCase()) { on = true; break }
        }
      }
      if (n.toLowerCase() === want) on = !on
      if (on) checked.push(n)
    }
    var value
    if (checked.length === 0) value = "\u2014"
    else if (checked.length === cameras.length) value = ""
    else value = checked.join(", ")
    persistSettings({ alertCameras: value })
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

  // ----------------------------------------------------------------- setup

  Process {
    id: trustShowProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) {
            root.trustInfo = data
            root.trustError = ""
          } else {
            root.trustInfo = null
            root.trustError = root.plain(data.error || "could not read the certificate")
          }
        } catch (e) {
          root.trustInfo = null
          root.trustError = "could not read the certificate"
        }
      }
    }
  }

  Process {
    id: trustAcceptProc
    stdout: StdioCollector {
      onStreamFinished: {
        var ok = false
        try { ok = JSON.parse(text).ok === true } catch (e) { ok = false }
        if (ok) {
          root.trusted = true
          root.trustInfo = null
          root.showCameras()
          root.refresh()
        } else {
          // The certificate moved between showing it and agreeing to it, or
          // the console stopped answering. Either way nothing was pinned, so
          // go round again on what is there now.
          root.trustError = "that certificate is no longer the one answering"
          root.showTrust()
        }
      }
    }
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.hasKey = data.hasKey === true
          root.trusted = data.trusted === true
          if (root.opened && root.needsSetup) {
            if (root.view !== "settings") root.showSettings()
          } else if (root.opened && root.needsTrust) {
            // A key with nothing pinned yet: the fingerprint has to be looked
            // at before the key is allowed anywhere near the wire.
            if (root.view !== "trust") root.showTrust()
          } else if (root.opened && !root.userWantsSettings) {
            root.showCameras()
          }
        } catch (e) {
        }
      }
    }
  }

  Process {
    id: setKeyProc
    stdinEnabled: true
    property string pending: ""
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) {
            if (keyField) keyField.text = ""
            root.hasKey = true
            root.refreshAfterCredential()
          }
        } catch (e) {
        }
      }
    }
    onStarted: {
      write(pending + "\n")
      pending = ""
      stdinEnabled = false
    }
    onExited: {
      pending = ""
      stdinEnabled = true
    }
  }

  Process {
    id: pasteKeyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text).replace(/^\s+|\s+$/g, "")
        if (t !== "" && keyField) {
          keyField.text = t
          root.focusField(keyField)
        }
      }
    }
  }

  readonly property int settingsBodyMax: {
    var avail = popup.availableCardHeight
    if (!(avail > 0)) return Style.space(520)
    return Math.max(Style.space(200), avail - Style.space(100))
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
    dimmed: root.motionId === "" || !root.reachable || root.needsSetup
    tooltipText: root.needsSetup
      ? "Needs setup"
      : (!root.reachable
         ? "Protect unreachable"
         : (root.motionCamera
            ? root.plain("Motion at " + root.motionCamera.name)
            : "Cameras"))

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

  // KeyboardPanel, not PopupCard: xdg-popups in this shell only get keys
  // after a click routes focus through the parent surface, which is why
  // the API key field would not take a left-click. Layer-shell primes
  // focus the same way the clock and network panels do.
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough that the live view is worth looking at rather than merely
    // present. The certificate step has no picture in it, only a sentence and
    // a fingerprint, and at full width that reads as a banner rather than as a
    // question: narrow it to something a person actually scans.
    //
    // Plain property reads rather than `fittedContentWidth`, because the width
    // changes while the panel is already open. That helper resolves once on
    // opening and never re-evaluates, so the card would stay whatever width it
    // was when it appeared.
    readonly property int desiredWidth:
      Style.space(root.view === "trust" ? 430 : root.panelWidth)
    contentWidth: Math.min(desiredWidth,
                           popup.availableCardWidth > 0 ? popup.availableCardWidth
                                                        : desiredWidth)
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (hostField && hostField.activeFocus) || (keyField && keyField.activeFocus)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

      Item {
        width: parent.width
        visible: root.view === "cameras"
        height: Math.max(camerasHeader.implicitHeight, gearBtn.implicitHeight,
                         notifySwitch.implicitHeight)

        PanelSectionHeader {
          id: camerasHeader
          anchors.left: parent.left
          anchors.right: notifySwitch.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.reviewing
            ? root.plain(root.nameOf(root.reviewCamera).toUpperCase() + "  \u00b7  "
                         + root.agoLongOf(root.reviewTs))
            : (root.selected ? root.plain(root.selected.name.toUpperCase()) : "CAMERAS")
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Quick mute for the desktop popups without a trip to the settings
        // form. The bar icon still lights up on motion either way: this
        // switch is about being interrupted, not about missing it entirely.
        //
        // Declared before the gear so Tab reaches it first: the ring walks
        // declaration order, not the order things sit on screen.
        ToggleSwitch {
          id: notifySwitch
          anchors.right: gearBtn.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          checked: root.notifyEnabled
          trackHeight: Math.max(Style.space(18),
                                Math.round(camerasHeader.implicitHeight * 0.9))
          foreground: root.foreground
          onToggled: root.notifyEnabled = !root.notifyEnabled

          PanelToolTip {
            visible: notifySwitch.containsMouse
            text: root.notifyEnabled ? "Notifications on motion: on"
                                     : "Notifications on motion: off"
            fontFamily: root.fontFamily
          }
        }

        PanelActionButton {
          id: gearBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.iconGear
          tooltipText: "Settings"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: {
            root.userWantsSettings = true
            root.showSettings()
          }
        }
      }

      Item {
        width: parent.width
        visible: root.view === "settings"
        height: Math.max(settingsHeader.implicitHeight, backBtn.implicitHeight)

        PanelActionButton {
          id: backBtn
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.iconBack
          tooltipText: "Back"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.showCameras()
        }

        PanelSectionHeader {
          id: settingsHeader
          anchors.left: backBtn.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "SETTINGS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
      }

      Column {
        id: camerasView
        visible: root.view === "cameras"
        width: parent.width
        spacing: Style.space(8)

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
          // Keep the last frame up while the stream buffers. Hiding this the
          // moment playbackState is not Playing is a flash of the still
          // underneath, or of "Connecting", once a second on a jittery RTSP
          // link.
          visible: !root.reviewing && player.showingVideo
        }

        // Playing only while the panel is open. A camera stream left running
        // behind a closed panel is a decoder and a few megabits a second for
        // a picture nobody is looking at.
        MediaPlayer {
          id: player
          videoOutput: video
          source: root.opened && root.view === "cameras" && !root.reviewing ? root.selectedStream : ""
          // No AudioOutput is attached on purpose: without one Qt plays the
          // video and drops the audio track, which is what a bar panel wants.

          property bool showingVideo: false

          onSourceChanged: {
            showingVideo = false
            if (source != "") play()
          }
          onPlaybackStateChanged: {
            if (playbackState === MediaPlayer.PlayingState) showingVideo = true
          }
          onErrorOccurred: function(err, str) {
            // Falling back to the stills is better than an empty rectangle;
            // they keep refreshing regardless of what the stream does.
            showingVideo = false
            console.log("jankeesvw.unifi-protect: stream error", err, str)
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !mainImage.visible && !video.visible
          text: root.needsSetup ? "Needs setup" : (root.reachable ? "Connecting" : "Protect unreachable")
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
        text: root.needsSetup ? "Needs setup" : (root.reachable ? "No cameras found" : "Protect unreachable")
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.6
      }
      }

      // The certificate step. Between having a key and using it: the console
      // signs its own certificate, so nothing but this comparison separates it
      // from anything else that can answer at that address. Deliberately not a
      // step the widget takes on your behalf.
      Column {
        visible: root.view === "trust"
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Check the console before trusting it"
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.trustInfo
            ? "This is what answers at " + root.plain(root.host)
              + ". Hold the fingerprint against the one your console shows "
              + "under Settings, System. They have to match."
            : (root.trustError !== "" ? root.trustError : "Reading the certificate...")
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.trustError !== "" ? (bar ? bar.urgent : Color.urgent) : root.foreground
          opacity: root.trustError !== "" ? 1 : 0.7
        }

        // Wrapped rather than elided: half a fingerprint cannot be compared,
        // and a fingerprint that looks right for the first eight characters is
        // exactly the trap this screen exists to close.
        Text {
          width: parent.width
          visible: root.trustInfo !== null
          textFormat: Text.PlainText
          text: root.trustInfo ? root.plain(root.trustInfo.fingerprint) : ""
          wrapMode: Text.WrapAnywhere
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
        }

        Text {
          width: parent.width
          visible: root.trustInfo !== null
          textFormat: Text.PlainText
          text: root.trustInfo
            ? root.plain(root.trustInfo.subject) + ", expires "
              + root.plain(root.trustInfo.expires)
            : ""
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.6
        }

        Row {
          spacing: Style.space(8)

          Button {
            text: "Pin and connect"
            enabled: root.trustInfo !== null && !trustAcceptProc.running
            focusable: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.acceptTrust()
          }

          Button {
            text: "Settings"
            focusable: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { root.userWantsSettings = true; root.showSettings() }
          }
        }
      }

      Flickable {
        id: settingsFlick
        visible: root.view === "settings"
        width: parent.width
        height: Math.min(settingsCol.implicitHeight, root.settingsBodyMax)
        contentWidth: width
        contentHeight: settingsCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        pressDelay: 200

        Column {
          id: settingsCol
          width: settingsFlick.width
          spacing: Style.space(10)

          Text {
            visible: root.needsSetup
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Needs an API key before it can talk to Protect."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            text: "CONSOLE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: hostField
            width: parent.width
            text: root.host
            placeholderText: "192.168.1.1"
            foreground: root.foreground
            font.family: root.fontFamily
            onEditingFinished: root.saveHost(text)
            onAccepted: root.saveHost(text)

            MouseArea {
              anchors.fill: parent
              enabled: !hostField.activeFocus
              cursorShape: Qt.IBeamCursor
              propagateComposedEvents: true
              onPressed: function(mouse) {
                root.focusField(hostField)
                mouse.accepted = false
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Address of the console running Protect, without the scheme."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6
          }

          PanelSectionHeader {
            width: parent.width
            text: "API KEY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width - saveKeyBtn.implicitWidth - parent.spacing
              height: Math.max(keyField.implicitHeight, pasteKeyBtn.implicitHeight)

              TextField {
                id: keyField
                anchors.fill: parent
                password: true
                // Never the key itself, not even masked: it is written and
                // never read back, so the field can only say whether there is
                // one. "Saved" rather than "on file", which is a filing
                // cabinet's word for it.
                placeholderText: root.hasKey ? "Key saved" : "Paste API key"
                foreground: root.foreground
                font.family: root.fontFamily
                rightPadding: pasteKeyBtn.implicitWidth + Style.space(10)
                onAccepted: root.saveKey()

                MouseArea {
                  anchors.fill: parent
                  anchors.rightMargin: pasteKeyBtn.width + Style.space(4)
                  enabled: !keyField.activeFocus
                  cursorShape: Qt.IBeamCursor
                  propagateComposedEvents: true
                  onPressed: function(mouse) {
                    root.focusField(keyField)
                    mouse.accepted = false
                  }
                }
              }

              Button {
                id: pasteKeyBtn
                z: 1
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                text: "Paste"
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.pasteKey()
              }
            }

            Button {
              id: saveKeyBtn
              text: "Save"
              enabled: keyField.text.trim() !== "" && !setKeyProc.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.saveKey()
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.hasKey
              ? "A key is saved. Paste another to replace it."
              : "Make a key at https://" + root.host + "/unifi-api/protect. Prefer a view-only local user."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.hasCameras
            text: "CAMERAS THAT MAY INTERRUPT YOU"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.hasCameras
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Which cameras may light the icon and file frames. Leave them all on to hear about every camera, including ones added later."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6
          }

          Repeater {
            model: root.hasCameras ? root.cameras : []

            Toggle {
              required property var modelData
              width: settingsCol.width
              label: root.plain(modelData.name)
              checked: root.alerts(modelData.id)
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleAlertCamera(modelData.name)
            }
          }

          Toggle {
            width: parent.width
            label: "Raise a notification on motion"
            description: "A desktop notification with the frame in it, so motion reaches you when the bar is not where you are looking."
            checked: root.notify
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.persistSettings({ notify: !root.notify })
          }
        }
      }
    }
    }
  }
}
