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
//   left   open the settings panel   right  start / stop the camera
//   middle refresh
Panel {
  id: root
  manageIpc: false

  property string camState: "off"    // off | live | nosignal | error
  property string holder: ""          // another app that has the card (obs, resolve)
  property var cfg: ({ device: "0", connection: "auto", mode: "auto", format: "auto", profile: "default" })
  property var options: ({ model: "", connection: [], mode: [], format: [], profile: [] })   // from backend.sh options, filtered to the selected card
  property var devices: []            // capture cards found, from backend.sh devices
  property string sink: ""
  property string message: ""
  property bool messageIsError: false
  property bool busy: false

  readonly property string backend: decodeURIComponent(Qt.resolvedUrl("backend.sh").toString().replace("file://", ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool running: camState === "live" || camState === "nosignal"
  readonly property string summary: cfg.connection + " " + cfg.mode

  function say(text, isError) { message = text; messageIsError = !!isError }

  function parseJson(text) {
    try { return JSON.parse(String(text).trim().split("\n").pop()) } catch (e) { return null }
  }

  function parseStatus(text) {
    var o = parseJson(text)
    if (!o) { camState = "error"; return }
    camState = o.state
    holder = o.holder
    sink = o.sink
    cfg = { device: o.device, connection: o.connection, mode: o.mode, format: o.format, profile: o.profile }
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function loadChoices() {
    if (!optionsProcess.running) optionsProcess.running = true
    if (!devicesProcess.running) devicesProcess.running = true
  }

  function runBackend(args) {
    if (actionProcess.running) return
    busy = true
    say("", false)
    actionProcess.command = ["bash", backend].concat(args)
    actionProcess.running = true
  }

  function toggleCamera() { runBackend([running ? "stop" : "start"]) }
  function setSetting(key, value) { runBackend(["set", key, value]) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: { refresh(); loadChoices() }
  // A different card has different inputs and modes.
  onCurrentDeviceChanged: if (!optionsProcess.running) optionsProcess.running = true
  readonly property string currentDevice: String(cfg.device)
  onOpenedChanged: {
    if (opened) { say("", false); refresh(); loadChoices() }
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
    id: optionsProcess
    command: ["bash", root.backend, "options", String(root.cfg.device)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { var o = root.parseJson(text); if (o) root.options = o }
    }
  }

  Process {
    id: devicesProcess
    command: ["bash", root.backend, "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { var o = root.parseJson(text); if (o) root.devices = o }
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text).trim().split("\n").pop()
        root.say(line.replace(/^(ok|error): /, ""), line.indexOf("error:") === 0)
      }
    }
    onExited: function(code) {
      if (code !== 0 && root.message === "") root.say("The DeckLink backend failed (exit " + code + ").", true)
      root.busy = false
      root.refresh()
    }
  }

  // ---- bar icon --------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.running ? "󰕧" : "󰗃"
    useActiveColor: false
    foreground: root.camState === "live" ? root.barForeground
      : (root.camState === "nosignal" || root.camState === "error") ? root.urgent
      : Qt.darker(root.barForeground, 1.6)
    tooltipText: root.busy ? "DeckLink: working…"
      : root.camState === "error" ? "DeckLink: backend not responding"
      : root.camState === "live" ? "DeckLink camera: live (" + root.summary + ")\nLeft-click for settings · right-click to stop"
      : root.camState === "nosignal" ? "DeckLink camera: NO SIGNAL (" + root.summary + ")\nStreaming black. Check the source or try another mode\nLeft-click for settings · right-click to stop"
      : root.holder !== "" ? "DeckLink camera: off\n" + root.holder + " is running and may hold the card\nLeft-click for settings · right-click to start anyway"
      : "DeckLink camera: off\nLeft-click for settings · right-click to start"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleCamera()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
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
            : root.camState === "error" ? "Backend not responding"
            : root.camState === "live" ? "Live"
            : root.camState === "nosignal" ? "Running, no signal"
            : "Off"
          detail: root.sink
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.running ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰕧"
              color: root.camState === "nosignal" ? root.urgent : (root.running ? root.foreground : root.dim)
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
          visible: root.devices.length > 1
          width: parent.width
          label: "Card"
          value: root.cfg.device
          options: root.devices
          enabled: !root.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(v) { root.setSetting("device", v) }
        }

        Repeater {
          model: [
            { key: "connection", label: "Connection" },
            { key: "mode", label: "Video mode" },
            { key: "format", label: "Pixel format" },
            { key: "profile", label: "Sub-device profile" }
          ]
          delegate: Dropdown {
            required property var modelData
            // Only the Duo 2, Quad 2 and 8K Pro offer more than "default".
            visible: root.options[modelData.key].length > 1
            width: column.width
            label: modelData.label
            value: root.cfg[modelData.key]
            options: root.options[modelData.key]
            enabled: !root.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setSetting(modelData.key, v) }
          }
        }

        Text {
          visible: root.options.model !== ""
          width: parent.width
          text: "Modes and inputs are filtered to what " + root.options.model + " reports."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.cfg.format === "auto" && root.cfg.mode !== "auto"
          width: parent.width
          text: "With a fixed video mode, Pixel format Auto uses 8-bit YUV."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Changing a setting restarts the camera if it is running. The camera never starts on its own, so OBS and Resolve can use the card.\n\nTested on a DeckLink Mini Recorder only. Other cards may need other settings; see the README."
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
