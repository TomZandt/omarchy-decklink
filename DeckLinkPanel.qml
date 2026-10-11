import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// DeckLink: a Blackmagic DeckLink capture card as a webcam, from the Omarchy bar.
//
// All the work is done by backend.sh (GStreamer -> v4l2loopback, run as a
// transient systemd user unit). Nothing starts by itself: the card serves one
// app at a time, so the camera only runs when you start it.
//
// Click map:
//   left   start / stop the camera   right  open the settings panel
//   middle refresh
Panel {
  id: root
  manageIpc: false

  property string state: "off"        // off | live | nosignal
  property string holder: ""          // another app that has the card (obs, resolve)
  property string connection: "auto"
  property string mode: "auto"
  property string format: "auto"
  property string sink: ""
  property string message: ""
  property bool messageIsError: false
  property bool busy: false

  readonly property string backend: decodeURIComponent(Qt.resolvedUrl("backend.sh").toString().replace("file://", ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool running: state === "live" || state === "nosignal"

  readonly property var connectionOptions: [
    { value: "auto", label: "Auto" }, { value: "hdmi", label: "HDMI" }, { value: "sdi", label: "SDI" },
    { value: "component", label: "Component" }, { value: "composite", label: "Composite" }, { value: "svideo", label: "S-Video" }
  ]
  readonly property var modeOptions: [
    { value: "auto", label: "Auto" },
    { value: "ntsc", label: "525i59.94 NTSC" }, { value: "pal", label: "625i50 PAL" },
    { value: "ntsc-p", label: "525p59.94 NTSC" }, { value: "pal-p", label: "625p50 PAL" },
    { value: "1080p2398", label: "1080p23.98" }, { value: "1080p24", label: "1080p24" },
    { value: "1080p25", label: "1080p25" }, { value: "1080p2997", label: "1080p29.97" },
    { value: "1080p30", label: "1080p30" }, { value: "1080i50", label: "1080i50" },
    { value: "1080i5994", label: "1080i59.94" }, { value: "1080i60", label: "1080i60" },
    { value: "720p50", label: "720p50" }, { value: "720p5994", label: "720p59.94" },
    { value: "720p60", label: "720p60" }
  ]
  readonly property var formatOptions: [
    { value: "auto", label: "Auto" }, { value: "8bit-yuv", label: "8-bit YUV" },
    { value: "10bit-yuv", label: "10-bit YUV" }, { value: "8bit-bgra", label: "8-bit BGRA" }
  ]

  function say(text, isError) { message = text; messageIsError = !!isError }

  function parseStatus(text) {
    var o
    try { o = JSON.parse(String(text).trim().split("\n").pop()) } catch (e) { return }
    state = o.state; holder = o.holder; connection = o.connection
    mode = o.mode; format = o.format; sink = o.sink
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function run(args) {
    if (actionProcess.running) return
    busy = true
    actionProcess.command = ["bash", backend].concat(args)
    actionProcess.running = true
  }

  function toggleCamera() { run([running ? "stop" : "start"]) }
  function setSetting(key, value) { run(["set", key, value]) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (opened) { say("", false); refresh() }
  }

  Timer {
    interval: Math.max(2, Number(root.setting("refreshIntervalSec", 5))) * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    command: ["bash", root.backend, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseStatus(text) }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector {
      id: actionOut
      waitForEnd: true
      onStreamFinished: {
        var line = String(text).trim().split("\n").pop()
        root.say(line.replace(/^(ok|error): /, ""), line.indexOf("error:") === 0)
      }
    }
    onRunningChanged: if (!running) { root.busy = false; root.refresh() }
  }

  // ---- bar icon --------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.running ? "󰕧" : "󰗃"
    useActiveColor: false
    foreground: root.state === "live" ? root.barForeground
      : root.state === "nosignal" ? root.urgent
      : Qt.darker(root.barForeground, 1.6)
    tooltipText: root.busy ? "DeckLink: working…"
      : root.state === "live" ? "DeckLink camera: live (" + root.connection + " " + root.mode + ")\nLeft-click to stop · right-click for settings"
      : root.state === "nosignal" ? "DeckLink camera: NO SIGNAL (" + root.connection + " " + root.mode + ")\nStreaming black. Check the source or try another mode\nRight-click for settings"
      : root.holder !== "" ? "DeckLink camera: off\n" + root.holder + " is running and may hold the card\nLeft-click to start anyway · right-click for settings"
      : "DeckLink camera: off\nLeft-click to start · right-click for settings"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggleCamera()
    }
  }

  // ---- panel -----------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.toggleCamera()
        else if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "DeckLink camera"
          meta: root.busy ? "Working…"
            : root.state === "live" ? "Live"
            : root.state === "nosignal" ? "Running, no signal"
            : "Off"
          detail: root.sink
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.running ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰕧"
              color: root.state === "nosignal" ? root.urgent : (root.running ? root.foreground : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.running
              busy: root.busy
              foreground: hero.foreground
              onToggled: root.toggleCamera()
            }
          }
        }

        Text {
          visible: root.message !== ""
          width: parent.width
          text: root.message
          textFormat: Text.PlainText
          color: root.messageIsError ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !root.running && root.holder !== ""
          width: parent.width
          text: root.holder + " is running and may be holding the card. Starting the camera will fail until it lets go."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader { text: "INPUT"; foreground: root.foreground; fontFamily: root.fontFamily }

        Dropdown {
          width: parent.width
          label: "Connection"
          value: root.connection
          options: root.connectionOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(v) { root.setSetting("connection", v) }
        }

        Dropdown {
          width: parent.width
          label: "Video mode"
          value: root.mode
          options: root.modeOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(v) { root.setSetting("mode", v) }
        }

        Dropdown {
          width: parent.width
          label: "Pixel format"
          value: root.format
          options: root.formatOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(v) { root.setSetting("format", v) }
        }

        Text {
          width: parent.width
          text: "Changing a setting restarts the camera if it is running. The camera never starts on its own, so OBS and Resolve can use the card."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
