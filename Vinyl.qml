import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// A spinning record. Drag it around to scratch: the track position follows
// the angle you turn it by, with a scratch sound on each move.
Item {
  id: vinyl

  property var player: null
  property string artUrl: ""
  property bool running: false          // popup open — spin only while visible
  property color foreground: "white"
  property string fontFamily: ""

  // 33⅓ rpm: one turn of the platter is 1.8 s of audio, like a real deck.
  property real secondsPerTurn: 1.8
  readonly property real rpmDegPerSec: 200 // 33⅓ rpm

  readonly property bool playing: !!player && !!player.isPlaying
  readonly property real length: player && player.length > 0 ? player.length : 0
  readonly property bool canSeek: !!player && !!player.canSeek && length > 0

  property real angle: 0
  property bool scratching: false
  property real scratchPos: 0           // position while dragging, seconds
  property bool resumeAfter: false

  // ---- needle wear / breakage mini-event ----
  property bool needleBroken: false
  property real wear: 0                 // turns scratched since the last new needle
  property int needleCount: 0           // needles broken, ever
  property real sessionDeg: 0           // degrees moved in the current scratch
  property int sessionRolled: 0         // full turns already rolled for
  property bool breaking: false         // engine is playing the snap

  // Chance per full turn once a scratch passes 4 turns: small, then growing.
  function rollForBreak() {
    var turns = Math.floor(sessionDeg / 360)
    while (sessionRolled < turns) {
      sessionRolled++
      if (sessionRolled <= 4) continue
      var chance = Math.min(0.04, 0.005 + 0.004 * (sessionRolled - 4) + wear / 2000)
      if (Math.random() < chance) { breakNeedle(); return }
    }
  }

  function breakNeedle() {
    if (needleBroken) return
    needleBroken = true
    needleCount++
    needleEvent.burst()
    if (scratching && engineReady) {
      breaking = true
      send("break")
      releaseWatchdog.restart()
    } else if (scratching) {
      seekThrottle.stop()
      scratching = false
      if (resumeAfter && player && player.canPlay) player.play()
    }
    saveNeedle()
    writeGraveyard()
  }

  function replaceNeedle() {
    needleBroken = false
    wear = 0
    saveNeedle()
  }

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/gooozmen-music"
  property string lastBreak: ""

  function saveNeedle() {
    needleFile.setText(JSON.stringify({ broken: needleBroken, wear: Math.round(wear * 10) / 10,
                                        count: needleCount, last: lastBreak }, null, 2) + "\n")
  }

  function rankFor(n) {
    if (n >= 50) return "Qbert отдыхает"
    if (n >= 30) return "Ненавистник алмазов"
    if (n >= 15) return "Пожиратель стилусов"
    if (n >= 7)  return "Гроза винила"
    if (n >= 3)  return "Подмастерье-вандал"
    return "Аккуратист"
  }

  function writeGraveyard() {
    var when = Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm")
    var track = player && player.trackTitle ? "«" + player.trackTitle + "»" + (player.trackArtist ? " — " + player.trackArtist : "") : "неизвестном треке"
    lastBreak = when + " на " + track
    var epitaphs = [
      "Ты скретчила как могла.",
      "Ушла красиво, на дропе.",
      "Алмаз не вечен. Особенно у тебя.",
      "Не выдержала твоего baby scratch.",
      "Теперь она крутится где-то там, на 45 оборотах.",
      "Сыграла последний трансформер."
    ]
    var text = "🪦 Кладбище игл — gooozmen.music\n"
      + "====================================\n"
      + "Сломано игл: " + needleCount + "\n"
      + "Последняя пала: " + lastBreak + "\n"
      + "Звание: " + rankFor(needleCount) + "\n\n"
      + "Покойся с миром, игла №" + needleCount + ". " + epitaphs[needleCount % epitaphs.length] + "\n"
    graveyardFile.setText(text)
    saveNeedle()
  }

  FileView {
    id: needleFile
    path: vinyl.stateDir + "/needle.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(text())
        vinyl.needleBroken = !!d.broken
        vinyl.wear = Number(d.wear) || 0
        vinyl.needleCount = Math.max(0, Math.floor(Number(d.count) || 0))
        vinyl.lastBreak = String(d.last || "").slice(0, 300)
      } catch (e) { console.warn("[music] needle.json parse failed:", e) }
    }
    onLoadFailed: function(err) { console.warn("[music] needle.json load failed:", err) }
  }
  FileView {
    id: graveyardFile
    path: vinyl.stateDir + "/кладбище-игл.txt"
    printErrors: false
  }

  // Where a needle hangs off the tonearm head, in this item's coordinates.
  readonly property real headX: arm.x + arm.width / 2 - arm.height * Math.sin(arm.rotation * Math.PI / 180)
  readonly property real headY: arm.y + arm.height * Math.cos(arm.rotation * Math.PI / 180)

  implicitWidth: 260
  implicitHeight: 260

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(sec / 60), s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Spin at record speed while playing; ease to a stop on pause.
  // Spins while playing, and while the engine coasts back up after a scratch.
  property real spinSpeed: !needleBroken && ((playing && !scratching) || (scratching && !drag.pressed && engineReady && !breaking)) ? rpmDegPerSec : 0
  Behavior on spinSpeed { NumberAnimation { duration: Style.duration(600); easing.type: Easing.OutCubic } }

  FrameAnimation {
    running: vinyl.running && vinyl.spinSpeed > 0.5 && !Style.reduceMotion
    onTriggered: vinyl.angle = (vinyl.angle + vinyl.spinSpeed * frameTime) % 360
  }

  // ---- the record ----
  Item {
    id: disc
    anchors.fill: parent
    rotation: vinyl.angle
    opacity: vinyl.needleBroken ? 0.6 : 1
    Behavior on opacity { NumberAnimation { duration: Style.duration(240) } }

    // Body
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "#0d0d0f"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.08)
    }

    // Grooves
    Repeater {
      model: 14
      Rectangle {
        required property int index
        readonly property real d: disc.width * (0.94 - index * 0.04)
        width: d; height: d
        anchors.centerIn: parent
        radius: d / 2
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, index % 3 === 0 ? 0.07 : 0.035)
      }
    }

    // Label: the cover art cut into a circle
    Item {
      id: label
      width: disc.width * 0.38
      height: width
      anchors.centerIn: parent

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Commons.Color.accent
      }

      SizedImage {
        id: art
        anchors.fill: parent
        crop: true
        url: vinyl.artUrl
        visible: false
        layer.enabled: true
      }
      Rectangle {
        id: artMask
        anchors.fill: parent
        radius: width / 2
        visible: false
        layer.enabled: true
        layer.smooth: true
      }
      MultiEffect {
        anchors.fill: parent
        source: art
        maskEnabled: true
        maskSource: artMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        visible: vinyl.artUrl !== ""
      }

      // Spindle hole
      Rectangle {
        width: parent.width * 0.09
        height: width
        radius: width / 2
        anchors.centerIn: parent
        color: "#0d0d0f"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.25)
      }
    }
  }

  // Light sheen — doesn't rotate, so the record looks lit from above.
  Shape {
    anchors.fill: parent
    opacity: 0.55
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillGradient: ConicalGradient {
        centerX: vinyl.width / 2
        centerY: vinyl.height / 2
        angle: 45
        GradientStop { position: 0.00; color: Qt.rgba(1, 1, 1, 0.00) }
        GradientStop { position: 0.08; color: Qt.rgba(1, 1, 1, 0.10) }
        GradientStop { position: 0.16; color: Qt.rgba(1, 1, 1, 0.00) }
        GradientStop { position: 0.50; color: Qt.rgba(1, 1, 1, 0.00) }
        GradientStop { position: 0.58; color: Qt.rgba(1, 1, 1, 0.10) }
        GradientStop { position: 0.66; color: Qt.rgba(1, 1, 1, 0.00) }
        GradientStop { position: 1.00; color: Qt.rgba(1, 1, 1, 0.00) }
      }
      // ring between the label and the rim
      PathAngleArc {
        centerX: vinyl.width / 2; centerY: vinyl.height / 2
        radiusX: vinyl.width * 0.485; radiusY: radiusX
        startAngle: 0; sweepAngle: 360
      }
    }
  }

  // ---- tonearm: rests on the record while playing, lifts off on pause ----
  Item {
    id: arm
    width: vinyl.width * 0.08
    height: vinyl.height * 0.62
    x: vinyl.width * 0.92 - width / 2
    y: vinyl.height * 0.05
    transformOrigin: Item.Top
    // Broken: the arm jerks up off the record.
    // Tracks the song like a real stylus: outer groove at the start (1°),
    // the label edge at the end (23.4°). Broken: lifted off to the side.
    rotation: vinyl.needleBroken ? -3
      : (vinyl.length > 0 ? 1 + 22.4 * Math.max(0, Math.min(1, vinyl.displayPosition / vinyl.length)) : -3)
    Behavior on rotation { NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }

    Rectangle { // pivot
      width: parent.width * 1.4; height: width; radius: width / 2
      anchors.horizontalCenter: parent.horizontalCenter
      y: -height / 2
      color: Qt.lighter(Commons.Color.accent, 1.1)
      border.width: 2
      border.color: Qt.rgba(0, 0, 0, 0.4)
    }
    Rectangle { // arm
      width: 3; radius: 1.5
      height: parent.height * 0.92
      anchors.horizontalCenter: parent.horizontalCenter
      color: Qt.rgba(0.85, 0.85, 0.88, 1)
    }
    Rectangle { // head
      width: parent.width * 0.9; height: parent.height * 0.13; radius: 2
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      color: Qt.rgba(0.75, 0.75, 0.78, 1)
    }
  }

  // ---- timecode while scratching ----
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(10)
    width: tc.implicitWidth + Style.space(16)
    height: tc.implicitHeight + Style.space(6)
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.7)
    border.width: 1
    border.color: Commons.Color.accent
    opacity: vinyl.scratching && !vinyl.needleBroken ? 1 : 0
    scale: vinyl.scratching && !vinyl.needleBroken ? 1 : 0.96
    Behavior on opacity { NumberAnimation { duration: Style.duration(vinyl.scratching ? 160 : 120); easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

    Text {
      id: tc
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: vinyl.fmt(vinyl.scratchPos) + " / " + vinyl.fmt(vinyl.length)
      color: "white"
      font.family: vinyl.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // ---- scratch engine (engine/scratchd) ----
  // While you hold the record the player keeps playing into a silent bus and
  // the engine plays the track at your hand's speed; on release it hands the
  // exact position back to the player. See engine/scratchd.c.
  property string appKey: player ? String(player.desktopEntry || player.identity || "").toLowerCase() : ""
  property bool engineReady: false
  property real grabPosition: 0
  property bool routed: false           // player currently moved to the bus
  property string routedApp: ""
  readonly property string engineDir: Qt.resolvedUrl("engine").toString().replace("file://", "")
  // Rough time the player needs to apply a seek; we aim that far ahead.
  property real seekLatency: 0.10

  // Runs while music plays or the card is open (so there is always recent
  // audio to scratch), and a minute after that.
  property bool engineWanted: running || playing || lingering.running
  Timer { id: lingering; interval: 60000 }
  onEngineWantedChanged: syncEngine()
  onRunningChanged: if (!running) lingering.restart()
  onPlayingChanged: if (!playing) lingering.restart()

  function syncEngine() {
    if (engineWanted && !engine.running) engine.running = true
    else if (!engineWanted && engine.running && !scratching) send("quit")
  }

  Process {
    id: engine
    command: ["bash", vinyl.engineDir + "/scratch.sh"]
    stdinEnabled: true
    onRunningChanged: {
      if (running) return
      vinyl.engineReady = false
      vinyl.routeBack()
      vinyl.scratching = false
      vinyl.breaking = false
      // Died on its own (output device changed, etc.): bring it back.
      if (vinyl.engineWanted) restartEngine.restart()
    }
    stdout: SplitParser {
      onRead: function(line) { vinyl.engineEvent(String(line).trim()) }
    }
  }
  Timer { id: restartEngine; interval: 1500; onTriggered: vinyl.syncEngine() }

  // The engine pins itself to the current speakers; follow the output
  // device (headphones plugged in, etc.) by restarting it.
  readonly property string outputName: Pipewire.defaultAudioSink ? String(Pipewire.defaultAudioSink.name) : ""
  property bool restartPending: false
  onOutputNameChanged: {
    if (!engine.running) return
    if (scratching) restartPending = true
    else send("quit")
  }
  Component.onCompleted: syncEngine()

  function send(cmd) { if (engine.running) engine.write(cmd + "\n") }

  function routeToBus() {
    if (appKey === "" || routed) return
    routed = true
    routedApp = appKey
    Quickshell.execDetached(["bash", engineDir + "/route.sh", routedApp, "bus"])
  }
  function routeBack() {
    if (!routed) return
    routed = false
    Quickshell.execDetached(["bash", engineDir + "/route.sh", routedApp, "back"])
    backAgain.restart()
  }

  // Players open new streams on seek/pause; while we hold the record, keep
  // catching them, or they'd play through the speakers on top of the scratch
  // (two copies of the track = it gets louder).
  Timer {
    interval: 300
    repeat: true
    running: vinyl.routed
    onTriggered: Quickshell.execDetached(["bash", vinyl.engineDir + "/route.sh", vinyl.routedApp, "bus"])
  }
  // ...and one more "back" in case a late "bus" call landed after the first.
  Timer {
    id: backAgain
    interval: 400
    onTriggered: if (!vinyl.routed) Quickshell.execDetached(["bash", vinyl.engineDir + "/route.sh", vinyl.routedApp, "back"])
  }

  // After seeking the player, give it a moment before it's audible again.
  Timer {
    id: handback
    interval: 220
    onTriggered: { vinyl.routeBack(); vinyl.send("fade") }
  }

  // Safety net: never leave the player on the silent bus.
  Timer {
    id: releaseWatchdog
    interval: 4000
    onTriggered: if (vinyl.scratching && (!drag.pressed || vinyl.breaking)) {
      vinyl.routeBack(); vinyl.send("fade")
      vinyl.scratching = false; vinyl.breaking = false
    }
  }

  function clampPos(t) { return Math.max(0, Math.min(length > 0 ? length - 0.5 : t, t)) }

  function engineEvent(ev) {
    if (ev.indexOf("pos ") === 0) {
      scratchPos = clampPos(grabPosition + parseFloat(ev.slice(4)))
    } else if (ev === "ready") {
      engineReady = true
    } else if (ev.indexOf("handoff ") === 0) {
      // Player is still playing on the bus: jump it to where the record is.
      var parts = ev.split(" ")
      var at = grabPosition + parseFloat(parts[2])
      if (canSeek) player.position = clampPos(at + seekLatency)
      handback.restart()
    } else if (ev.indexOf("seek ") === 0) {
      // Paused session: just leave the track where the record stopped.
      if (canSeek) player.position = clampPos(grabPosition + parseFloat(ev.slice(5)))
    } else if (ev === "done") {
      scratching = false
      breaking = false
      releaseWatchdog.stop()
      if (!handback.running) routeBack()
      if (restartPending) { restartPending = false; send("quit") }
    } else if (ev.indexOf("error") === 0) {
      console.warn("[music] scratch engine:", ev)
    }
  }

  // Keep the shown time (and the tonearm) moving smoothly while visible.
  Timer {
    interval: 250
    repeat: true
    running: vinyl.running && vinyl.playing && !vinyl.scratching
    onTriggered: if (vinyl.player && vinyl.player.positionSupported) vinyl.player.positionChanged()
  }
  // What the UI should show: the record's position while scratching.
  readonly property real displayPosition: scratching ? scratchPos : (player ? player.position : 0)

  // Fallback when the engine isn't available: plain seeking.
  Timer {
    id: seekThrottle
    interval: 90
    onTriggered: if (vinyl.canSeek) vinyl.player.position = vinyl.scratchPos
  }

  // ---- input ----
  MouseArea {
    id: drag
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: vinyl.needleBroken || !vinyl.canSeek ? Qt.ArrowCursor : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
    property real lastAngle: 0

    function pointerAngle(mx, my) {
      return Math.atan2(my - height / 2, mx - width / 2) * 180 / Math.PI
    }
    function insideDisc(mx, my) {
      var dx = mx - width / 2, dy = my - height / 2
      return Math.sqrt(dx * dx + dy * dy) <= width / 2
    }

    onPressed: function(mouse) {
      if (!insideDisc(mouse.x, mouse.y)) { mouse.accepted = false; return }
      // Shift + right click: snap the needle on purpose (testing / showing off)
      if (mouse.button === Qt.RightButton) {
        if (mouse.modifiers & Qt.ShiftModifier) vinyl.breakNeedle()
        mouse.accepted = false
        return
      }
      if (vinyl.needleBroken || !vinyl.canSeek) { mouse.accepted = false; return }
      vinyl.sessionDeg = 0
      vinyl.sessionRolled = 0
      lastAngle = pointerAngle(mouse.x, mouse.y)
      if (vinyl.engineReady) {
        // Caught mid-handback: keep the session going from where it is.
        if (!vinyl.scratching) {
          vinyl.grabPosition = vinyl.player.position
          vinyl.scratchPos = vinyl.grabPosition
        }
        handback.stop()
        var live = vinyl.playing || vinyl.routed
        vinyl.scratching = true
        vinyl.send("grab " + (live ? 1 : 0))
        if (live) vinyl.routeToBus()
      } else {
        // No engine: pause and scrub by seeking.
        vinyl.grabPosition = vinyl.player.position
        vinyl.scratchPos = vinyl.grabPosition
        if (!vinyl.scratching) vinyl.resumeAfter = vinyl.playing
        vinyl.scratching = true
        if (vinyl.player.canPause && vinyl.playing) vinyl.player.pause()
      }
    }
    onPositionChanged: function(mouse) {
      if (!vinyl.scratching || vinyl.needleBroken) return
      var a = pointerAngle(mouse.x, mouse.y)
      var d = a - lastAngle
      if (d > 180) d -= 360
      if (d < -180) d += 360
      lastAngle = a
      vinyl.angle = (vinyl.angle + d + 360) % 360
      if (vinyl.engineReady) {
        vinyl.send("move " + (d / 360 * vinyl.secondsPerTurn).toFixed(4))   // engine reports "pos"
      } else {
        vinyl.scratchPos = vinyl.clampPos(vinyl.scratchPos + d / 360 * vinyl.secondsPerTurn)
        if (!seekThrottle.running) seekThrottle.start()
      }
      vinyl.sessionDeg += Math.abs(d)
      vinyl.wear += Math.abs(d) / 360
      vinyl.rollForBreak()
    }
    onReleased: vinyl.endScratch()
    onCanceled: vinyl.endScratch()

    // Wheel over the record: coarse ±5 s jumps.
    onWheel: function(w) {
      if (!vinyl.canSeek || vinyl.needleBroken) return
      var step = w.angleDelta.y > 0 ? -5 : 5
      vinyl.player.position = Math.max(0, Math.min(vinyl.length - 0.5, vinyl.player.position + step))
      vinyl.angle = (vinyl.angle + step * 72 + 360) % 360
    }
  }

  function endScratch() {
    if (!scratching || breaking) return
    if (wear > 0) saveNeedle()
    if (engineReady) {
      // The engine coasts back up to speed and tells us when to resume;
      // "done" clears scratching.
      send("release")
      releaseWatchdog.restart()
      return
    }
    seekThrottle.stop()
    if (canSeek) player.position = scratchPos
    scratching = false
    if (resumeAfter && player && player.canPlay) player.play()
  }

  // ---- needle replacement mini-game (above the record's input) ----
  NeedleEvent {
    id: needleEvent
    anchors.fill: parent
    z: 50
    active: vinyl.needleBroken
    number: vinyl.needleCount + 1
    headX: vinyl.headX
    headY: vinyl.headY
    fontFamily: vinyl.fontFamily
    onReplaced: vinyl.replaceNeedle()
  }

  Component.onDestruction: { send("quit"); routeBack() }
}
