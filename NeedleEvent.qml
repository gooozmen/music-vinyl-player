import QtQuick
import qs.Commons
import qs.Commons as Commons

// "The needle snapped" mini-game, drawn over the record.
//   box      a stylus box slides in and fidgets — click it
//   open     lid flips open, a fresh needle pops up — pull the broken one off
//   removed  drag the new needle onto the tonearm head
//   done     it clicks in, the box leaves, replaced() fires
Item {
  id: ev

  property bool active: false
  property int number: 1                 // printed on the box
  property real headX: 0                 // where a needle hangs off the tonearm
  property real headY: 0
  property string fontFamily: ""

  signal replaced()

  property string stage: "idle"
  onActiveChanged: {
    if (active) {
      stage = "box"
      oldNeedle.reset()
      newNeedle.reset()
    } else {
      stage = "idle"
    }
  }
  Component.onCompleted: if (active) { stage = "box"; oldNeedle.reset(); newNeedle.reset() }

  visible: stage !== "idle"
  // Keep the box and the falling needle inside the record's square.
  clip: true

  readonly property real boxW: Math.round(width * 0.34)
  readonly property real boxH: Math.round(boxW * 0.62)
  readonly property real boxX: Math.round(width * 0.30 - boxW / 2)
  readonly property real boxRestY: Math.round(height * 0.70)

  // ---------- a needle (stylus cartridge) ----------
  component Needle: Item {
    property bool broken: false
    width: 12
    height: 26
    // cartridge body
    Rectangle {
      width: 12; height: 14; radius: 2
      gradient: Gradient {
        GradientStop { position: 0; color: "#e8e8ee" }
        GradientStop { position: 1; color: "#9a9aa4" }
      }
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.35)
      Rectangle { // brand stripe
        width: parent.width; height: 3; y: 4
        color: Commons.Color.accent
      }
    }
    // cantilever + tip
    Rectangle {
      x: 5; y: 13
      width: 2; height: parent.broken ? 7 : 12
      radius: 1
      color: parent.broken ? "#b04a3a" : "#4a4a52"
      transformOrigin: Item.Top
      rotation: parent.broken ? 58 : 0
    }
    Rectangle { // diamond
      visible: !parent.broken
      x: 4.5; y: 24; width: 3; height: 3; radius: 1.5
      color: "#cfefff"
    }
  }

  // ---------- dimming + hint ----------
  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: Qt.rgba(0, 0, 0, ev.stage === "done" ? 0 : 0.35)
    Behavior on color { ColorAnimation { duration: Style.duration(200) } }
  }

  Rectangle {
    id: hint
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round(parent.height * 0.10)
    width: hintText.implicitWidth + Style.space(18)
    height: hintText.implicitHeight + Style.space(8)
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.75)
    border.width: 1
    border.color: ev.stage === "done" ? Commons.Color.accent : "#d0604a"
    Text {
      id: hintText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      font.family: ev.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      color: "white"
      text: ev.stage === "box" ? "Игла сломалась! Открой коробку"
          : ev.stage === "open" ? "Сними сломанную иглу"
          : ev.stage === "removed" ? "Поставь новую иглу на тонарм"
          : "Щёлк! Можно скретчить"
    }
  }

  // ---------- sparks when it snaps ----------
  function burst() { sparks.restart() }
  Repeater {
    id: sparkRep
    model: 9
    Rectangle {
      id: spark
      required property int index
      readonly property real ang: (index / 9) * Math.PI * 2 + 0.3
      width: 3; height: 3; radius: 1.5
      color: index % 2 ? "#ffd27a" : "#ff8a5c"
      x: ev.headX + sparks.t * Math.cos(ang) * 34 - 1.5
      y: ev.headY + sparks.t * Math.sin(ang) * 34 + sparks.t * sparks.t * 18 - 1.5
      opacity: sparks.running ? 1 - sparks.t : 0
    }
  }
  NumberAnimation {
    id: sparks
    target: sparks
    property real t: 0
    property: "t"
    from: 0; to: 1
    duration: Style.duration(420)
    easing.type: Easing.OutCubic
  }

  // ---------- drop target on the tonearm head ----------
  Rectangle {
    id: dropZone
    readonly property bool hot: newDrag.drag.active
      && Math.hypot(newNeedle.x + newNeedle.width / 2 - ev.headX, newNeedle.y - ev.headY) < 30
    x: ev.headX - width / 2
    y: ev.headY - height / 2 + 6
    width: 34; height: 34; radius: 17
    color: "transparent"
    border.width: 2
    border.color: Commons.Color.accent
    visible: ev.stage === "removed"
    opacity: hot ? 1 : 0.45
    scale: hot ? 1.15 : 1
    Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    SequentialAnimation on border.width {
      running: dropZone.visible && !dropZone.hot && !Style.reduceMotion
      loops: Animation.Infinite
      NumberAnimation { to: 3; duration: Style.duration(500) }
      NumberAnimation { to: 1.5; duration: Style.duration(500) }
    }
  }

  // ---------- the box ----------
  Item {
    id: box
    width: ev.boxW
    height: ev.boxH
    x: ev.boxX
    y: ev.stage === "box" || ev.stage === "open" || ev.stage === "removed" ? ev.boxRestY : ev.height + 20
    Behavior on y { NumberAnimation { duration: Style.duration(ev.stage === "done" ? 160 : 260); easing.type: Easing.OutCubic } }
    transformOrigin: Item.Bottom

    // fidget every couple of seconds until opened
    SequentialAnimation on rotation {
      running: ev.stage === "box" && !Style.reduceMotion
      loops: Animation.Infinite
      PauseAnimation { duration: 1400 }
      NumberAnimation { to: -7; duration: Style.duration(70) }
      NumberAnimation { to: 6;  duration: Style.duration(90) }
      NumberAnimation { to: -4; duration: Style.duration(80) }
      NumberAnimation { to: 2;  duration: Style.duration(70) }
      NumberAnimation { to: 0;  duration: Style.duration(60) }
    }

    // inside (visible once open)
    Rectangle {
      x: 4; y: 0
      width: parent.width - 8; height: 10
      color: "#5a3e24"
      visible: ev.stage !== "box"
    }
    // body
    Rectangle {
      anchors.fill: parent
      anchors.topMargin: 4
      radius: 3
      gradient: Gradient {
        GradientStop { position: 0; color: "#d2a678" }
        GradientStop { position: 1; color: "#a97c50" }
      }
      border.width: 1
      border.color: "#6e4c2c"

      Rectangle { // label
        anchors.centerIn: parent
        width: parent.width * 0.78
        height: parent.height * 0.42
        radius: 2
        color: "#f4efe6"
        Column {
          anchors.centerIn: parent
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "STYLUS"
            font.family: ev.fontFamily
            font.pixelSize: 9
            font.bold: true
            font.letterSpacing: 1.5
            color: "#2b2b2b"
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "№ " + ev.number
            font.family: ev.fontFamily
            font.pixelSize: 8
            color: "#b04a3a"
          }
        }
      }
    }
    // lid: hinged at its left end, flips up and back
    Rectangle {
      id: lid
      x: -2; y: -4
      width: parent.width + 4
      height: 10
      radius: 2
      color: "#c0956a"
      border.width: 1
      border.color: "#6e4c2c"
      transformOrigin: Item.BottomLeft
      rotation: ev.stage === "box" ? 0 : -118
      Behavior on rotation { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -6
      enabled: ev.stage === "box"
      cursorShape: Qt.PointingHandCursor
      onClicked: ev.stage = "open"
    }
  }

  // ---------- the broken needle, hanging off the tonearm ----------
  Needle {
    id: oldNeedle
    broken: true
    property bool falling: false
    function reset() {
      falling = false; opacity = 1; rotation = 0
      x = Qt.binding(function() { return ev.headX - width / 2 })
      y = Qt.binding(function() { return ev.headY - 2 })
    }
    visible: ev.stage === "box" || ev.stage === "open" || falling
    z: 5

    MouseArea {
      id: oldDrag
      anchors.fill: parent
      anchors.margins: -8
      enabled: ev.stage === "open"
      cursorShape: enabled ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
      drag.target: oldNeedle
      onPressed: { oldNeedle.x = oldNeedle.x; oldNeedle.y = oldNeedle.y } // break the bindings
      onReleased: {
        var d = Math.hypot(oldNeedle.x + oldNeedle.width / 2 - ev.headX, oldNeedle.y - ev.headY)
        if (d > 45) {
          oldNeedle.falling = true
          ev.stage = "removed"
          fall.restart()
        } else {
          back.restart()
        }
      }
    }
    ParallelAnimation {
      id: fall
      NumberAnimation { target: oldNeedle; property: "y"; to: ev.height + 30; duration: Style.duration(520); easing.type: Easing.InQuad }
      NumberAnimation { target: oldNeedle; property: "rotation"; to: 220; duration: Style.duration(520) }
      NumberAnimation { target: oldNeedle; property: "opacity"; to: 0; duration: Style.duration(520) }
      onFinished: oldNeedle.falling = false
    }
    ParallelAnimation {
      id: back
      NumberAnimation { target: oldNeedle; property: "x"; to: ev.headX - oldNeedle.width / 2; duration: Style.duration(180); easing.type: Easing.OutCubic }
      NumberAnimation { target: oldNeedle; property: "y"; to: ev.headY - 2; duration: Style.duration(180); easing.type: Easing.OutCubic }
    }
  }

  // ---------- the new needle, waiting in the box ----------
  Needle {
    id: newNeedle
    readonly property real homeX: box.x + box.width / 2 - width / 2
    readonly property real homeY: ev.boxRestY - height - 2
    property bool installed: false
    function reset() {
      installed = false
      x = Qt.binding(function() { return newNeedle.homeX })
      y = Qt.binding(function() { return box.y + 4 }) // tucked inside the box
    }
    visible: ev.stage !== "box" && ev.stage !== "idle"
    z: 6

    // pops up out of the box when the lid opens
    Connections {
      target: ev
      function onStageChanged() {
        if (ev.stage === "open") popUp.restart()
      }
    }
    NumberAnimation {
      id: popUp
      target: newNeedle; property: "y"
      to: newNeedle.homeY
      duration: Style.duration(260); easing.type: Easing.OutCubic
    }

    MouseArea {
      id: newDrag
      anchors.fill: parent
      anchors.margins: -8
      enabled: ev.stage === "removed"
      cursorShape: enabled ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
      drag.target: newNeedle
      onPressed: { popUp.stop(); newNeedle.x = newNeedle.x; newNeedle.y = newNeedle.y }
      onReleased: {
        if (dropZone.hot) {
          snapIn.restart()
        } else {
          home.restart()
        }
      }
    }
    ParallelAnimation {
      id: snapIn
      NumberAnimation { target: newNeedle; property: "x"; to: ev.headX - newNeedle.width / 2; duration: Style.duration(120); easing.type: Easing.OutCubic }
      NumberAnimation { target: newNeedle; property: "y"; to: ev.headY - 2; duration: Style.duration(120); easing.type: Easing.OutCubic }
      onFinished: {
        newNeedle.installed = true
        ev.stage = "done"
        flash.restart()
        finish.restart()
      }
    }
    ParallelAnimation {
      id: home
      NumberAnimation { target: newNeedle; property: "x"; to: newNeedle.homeX; duration: Style.duration(180); easing.type: Easing.OutCubic }
      NumberAnimation { target: newNeedle; property: "y"; to: newNeedle.homeY; duration: Style.duration(180); easing.type: Easing.OutCubic }
    }
  }

  // click-in flash
  Rectangle {
    id: flashRing
    x: ev.headX - width / 2
    y: ev.headY - height / 2 + 8
    width: 18 + flash.t * 50
    height: width
    radius: width / 2
    color: "transparent"
    border.width: 3
    border.color: Commons.Color.accent
    opacity: flash.running ? 1 - flash.t : 0
  }
  NumberAnimation {
    id: flash
    target: flash
    property real t: 0
    property: "t"
    from: 0; to: 1
    duration: Style.duration(300)
    easing.type: Easing.OutCubic
  }

  Timer {
    id: finish
    interval: 700
    onTriggered: ev.replaced()
  }
}
