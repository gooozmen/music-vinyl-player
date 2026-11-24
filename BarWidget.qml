import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import qs.Commons as Commons

BarWidget {
  id: root
  moduleName: "gooozmen.music"

  // Third-party plugins can't reach omarchy.media, so read MPRIS directly.
  readonly property var players: Mpris.players ? Mpris.players.values : []

  // The chosen source is kept by app name ("spotify", "chromium", ...), so it
  // survives the app restarting. "" means auto: whatever is playing.
  property string sourceKey: ""
  function playerKey(p) { return p ? String(p.desktopEntry || p.identity || "").toLowerCase() : "" }
  function playerName(p) { return p ? String(p.identity || p.desktopEntry || "Player") : "" }
  function hasTrack(p) { return !!p && !!(p.trackTitle || p.trackArtist) }

  readonly property var lockedPlayer: {
    if (sourceKey === "") return null
    for (var i = 0; i < players.length; i++)
      if (playerKey(players[i]) === sourceKey) return players[i]
    return null
  }
  readonly property var player: {
    // A chosen source is strict: if it isn't running, show nothing rather
    // than another app's track.
    if (sourceKey !== "") return lockedPlayer
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!hasTrack(p)) continue
      if (p.isPlaying) return p
      if (!fallback) fallback = p
    }
    return fallback
  }

  function setSource(key) {
    sourceKey = key
    sourceFile.setText(key)
  }

  FileView {
    id: sourceFile
    path: Quickshell.env("HOME") + "/.local/state/gooozmen-music/source"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.sourceKey = text().trim().toLowerCase()
  }

  readonly property bool hasMedia: player !== null && !!(player.trackTitle || player.trackArtist)
  readonly property bool isPlaying: !!player && !!player.isPlaying
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player && player.trackAlbum ? player.trackAlbum : ""
  readonly property string artUrl: player && player.trackArtUrl ? player.trackArtUrl : ""
  readonly property real length: player && player.length > 0 ? player.length : 0
  readonly property real position: player ? player.position : 0
  readonly property real progress: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0
  // In the card, time follows the record (exact while scratching).
  readonly property real shownPosition: vinylView ? vinylView.displayPosition : position
  readonly property real shownProgress: length > 0 ? Math.max(0, Math.min(1, shownPosition / length)) : 0

  property bool popupOpen: false
  function close() { popupOpen = false }

  function act(name) {
    if (!player) return
    if (name === "playPause" && player.canTogglePlaying) player.togglePlaying()
    else if (name === "next" && player.canGoNext) player.next()
    else if (name === "previous" && player.canGoPrevious) player.previous()
  }

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(sec / 60), s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Always on the bar, so it is there after a reboot before any player
  // has started; the buttons just dim until something plays.
  readonly property bool shown: true
  visible: shown
  implicitWidth: shown ? row.implicitWidth : 0
  implicitHeight: barSize

  // Keep the position moving while a track plays.
  Timer {
    interval: 1000
    repeat: true
    running: root.isPlaying && root.visible
    onTriggered: if (root.player && root.player.positionSupported) root.player.positionChanged()
  }

  // The bar routes clicks itself: to our buttons by geometry, and anything
  // that misses them (gaps, the edges of the small "next") to this.
  function triggerPress(button) {
    if (button === Qt.RightButton) popupOpen = !popupOpen
    else if (button === Qt.MiddleButton) act("next")
  }

  function barPress(button, action) {
    if (button === Qt.RightButton) root.popupOpen = !root.popupOpen
    else if (button === Qt.MiddleButton) root.act("next")
    else root.act(action)
  }

  // Right click anywhere on the widget (both buttons and the gaps) opens the
  // card. Only the right button is taken; left clicks fall through.
  MouseArea {
    anchors.fill: parent
    z: 100
    acceptedButtons: Qt.RightButton
    onClicked: root.popupOpen = !root.popupOpen
  }

  // ---- Compact bar view: play/pause + next only ----
  // BarIconButton fits every glyph to the theme's bar icon size, so both
  // buttons match each other and the rest of the bar.
  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0
    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    BarIconButton {
      id: playBtn
      bar: root.bar
      height: root.barSize
      slotSize: Style.bar.iconSlot
      scale: 1.0
      // Playing: a little equalizer that turns into pause on hover.
      readonly property bool showEq: root.isPlaying && !tooltipHovered
      text: root.isPlaying ? "󰏤" : "󰐊"
      dimmed: !root.player
      iconComponent: showEq ? eqComponent : null
      tooltipText: !root.player ? "Ничего не играет" : root.title + (root.artist ? " — " + root.artist : "") + "  [" + root.playerName(root.player) + "]"
      onPressed: function(b) { root.barPress(b, "playPause") }
      onWheelMoved: function(d) { root.act(d > 0 ? "previous" : "next") }
    }

    BarIconButton {
      bar: root.bar
      height: root.barSize
      // Deliberately small next to the big play button.
      slotSize: Math.round(Style.bar.iconSlot * 0.62)
      scale: 0.58
      text: "󰒭"
      dimmed: !root.player || !root.player.canGoNext
      onPressed: function(b) { root.barPress(b, "next") }
      onWheelMoved: function(d) { root.act(d > 0 ? "previous" : "next") }
    }
  }

  Component {
    id: eqComponent
    Item {
      width: 15
      height: 15
      Row {
        anchors.centerIn: parent
        spacing: 2
        Repeater {
          model: [0.55, 1.0, 0.75]
          Rectangle {
            id: barRect
            required property var modelData
            required property int index
            width: 3
            radius: 1.5
            anchors.bottom: parent.bottom
            color: Commons.Color.accent
            height: 15 * modelData
            SequentialAnimation on height {
              running: root.isPlaying && root.visible && !root.bar.barHidden && !Style.reduceMotion
              loops: Animation.Infinite
              NumberAnimation { to: 15 * (0.25 + 0.2 * barRect.index); duration: Style.duration(280 + 90 * barRect.index); easing.type: Easing.InOutSine }
              NumberAnimation { to: 15; duration: Style.duration(320 + 70 * barRect.index); easing.type: Easing.InOutSine }
              NumberAnimation { to: 15 * barRect.modelData; duration: Style.duration(260 + 60 * barRect.index); easing.type: Easing.InOutSine }
            }
          }
        }
      }
    }
  }

  // ---- Full card on right click ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(card.implicitHeight)

    Column {
      id: card
      anchors.fill: parent
      spacing: Style.space(12)

      // Source picker
      Dropdown {
        id: sourcePicker
        width: parent.width
        z: 10
        showLabel: false
        fontFamily: root.bar.fontFamily
        visible: root.players.length > 0
        options: {
          var opts = [{ value: "", label: "󰒝  Авто — что играет" }]
          var seen = {}
          for (var i = 0; i < root.players.length; i++) {
            var p = root.players[i]
            var k = root.playerKey(p)
            if (!k || seen[k]) continue
            seen[k] = true
            var track = p.trackTitle ? "  ·  " + p.trackTitle : ""
            opts.push({ value: k, label: (p.isPlaying ? "󰎆  " : "󰏤  ") + root.playerName(p) + track })
          }
          return opts
        }
        value: root.sourceKey
        onChanged: function(v) { root.setSource(v) }
      }

      // Spinning record — drag it to scratch through the track
      Vinyl {
        id: vinylView
        width: parent.width
        height: width
        player: root.player
        artUrl: root.artUrl
        running: root.popupOpen
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      // Title / artist / album
      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: root.title !== "" ? root.title : "Ничего не играет"
          width: parent.width
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          text: root.artist + (root.album ? "  ·  " + root.album : "")
          width: parent.width
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
          visible: root.artist !== "" || root.album !== ""
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Progress + times (click to seek)
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.length > 0

        Item {
          width: parent.width
          height: Style.space(12)

          Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: 2
            color: Qt.rgba(1, 1, 1, 0.12)

            Rectangle {
              height: parent.height
              radius: 2
              width: parent.width * root.shownProgress
              color: Commons.Color.accent
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: root.player && root.player.canSeek ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: function(mouse) {
              if (!root.player || !root.player.canSeek) return
              root.player.position = root.length * Math.max(0, Math.min(1, mouse.x / width))
            }
          }
        }

        Item {
          width: parent.width
          height: posText.implicitHeight
          Text {
            id: posText
            textFormat: Text.PlainText
            text: root.fmt(root.shownPosition)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.fmt(root.length)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Transport: one big round play button, small skip buttons.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(22)
        LayoutMirroring.enabled: false
        LayoutMirroring.childrenInherit: true

        Repeater {
          model: [
            { icon: "󰒮", action: "previous", big: false },
            { icon: root.isPlaying ? "󰏤" : "󰐊", action: "playPause", big: true },
            { icon: "󰒭", action: "next", big: false }
          ]
          Item {
            id: tbtn
            required property var modelData
            readonly property bool big: modelData.big
            readonly property bool can: !root.player ? false
              : modelData.action === "previous" ? root.player.canGoPrevious
              : modelData.action === "next" ? root.player.canGoNext
              : root.player.canTogglePlaying
            width: big ? Style.space(58) : Style.space(30)
            height: Style.space(58)
            opacity: can ? 1 : 0.35

            Rectangle {
              anchors.centerIn: parent
              width: parent.width
              height: width
              radius: width / 2
              visible: tbtn.big
              color: tma.containsMouse ? Qt.lighter(Commons.Color.accent, 1.12) : Commons.Color.accent
              scale: tma.pressed ? 0.93 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: Style.duration(120) } }
            }
            Text {
              anchors.centerIn: parent
              // the play triangle reads off-centre; nudge it right
              anchors.horizontalCenterOffset: tbtn.big && !root.isPlaying ? Style.space(2) : 0
              textFormat: Text.PlainText
              text: tbtn.modelData.icon
              font.family: root.bar.fontFamily
              font.pixelSize: tbtn.big ? Style.space(30) : Style.space(16)
              color: tbtn.big ? Commons.Color.background
                   : (tma.containsMouse ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.25))
              scale: !tbtn.big && tma.pressed ? 0.88 : 1
              Behavior on color { ColorAnimation { duration: Style.duration(120) } }
              Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
            }
            MouseArea {
              id: tma
              anchors.fill: parent
              hoverEnabled: true
              enabled: tbtn.can
              cursorShape: Qt.PointingHandCursor
              onClicked: root.act(tbtn.modelData.action)
            }
          }
        }
      }

    }
  }
}
