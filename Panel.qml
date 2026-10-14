import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.gunz0blazin.thinkpad-fan"
  ipcTarget: "io.github.gunz0blazin.thinkpad-fan"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "")
  readonly property string fanBin: pluginDir + "/bin/omarchy-fan"
  readonly property string helper: "/usr/lib/omarchy-fan/helper"
  // ready | unsupported (not a ThinkPad) | no-thinkfan | no-helper | needs-enable
  readonly property string setupState: info.setup || "ready"
  readonly property bool supported: setupState !== "unsupported"
  property var info: ({})
  property var history: []
  readonly property int maxSamples: 60
  property string activeProfile: info.profile || ""
  property int profileIndex: 1
  property bool cursorActive: false
  readonly property var profiles: Model.profiles
  readonly property bool serviceUp: info.service === "active"
  readonly property real rpm: Number(info.rpm || 0)

  function refresh() {
    if (!statsProc.running) statsProc.running = true
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    pendingLevel = -1
    actionProc.command = [root.fanBin, profile]
    actionProc.running = true
  }

  // Slider position: the pinned level in manual mode, otherwise whatever
  // level the curve is currently running at.
  // Holds the level you just picked until thinkfan confirms it, so the knob
  // doesn't snap back to stale readings while the daemon restarts.
  property int pendingLevel: -1
  property int queuedLevel: -1
  readonly property real sliderValue: pendingLevel >= 0 ? pendingLevel
    : (activeProfile === "manual" ? Number(info.manual || 0) : Model.levelFromProc(info.level))

  onInfoChanged: {
    if (pendingLevel >= 0 && info.profile === "manual" && Number(info.manual) === pendingLevel) {
      pendingLevel = -1
      pendingTimer.stop()
    }
  }

  Timer { id: pendingTimer; interval: 8000; onTriggered: root.pendingLevel = -1 }

  readonly property bool followPower: info.follow !== "off"

  function setFollow(on) {
    if (actionProc.running) return
    actionProc.command = [root.fanBin, "follow", on ? "on" : "off"]
    actionProc.running = true
  }

  function setManualLevel(n) {
    pendingLevel = Math.round(n)
    pendingTimer.restart()
    if (actionProc.running) { queuedLevel = pendingLevel; return }
    actionProc.command = [root.fanBin, "manual", String(pendingLevel)]
    actionProc.running = true
  }

  function activateSelectedProfile() {
    setProfile(profiles[profileIndex])
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 1
      cursorActive = false
    }
  }

  Process {
    id: statsProc
    command: [root.fanBin, "stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) {
          // an empty rpm is "no reading" (the controller glitches while the fan changes speed):
          // keep the last good value and don't plot it
          var good = next.rpm !== undefined && next.rpm !== ""
          if (!good) next.rpm = root.info.rpm
          root.info = next
          if (good) {
            var h = root.history.concat([Number(next.rpm)])
            while (h.length > root.maxSamples) h.shift()
            root.history = h
            graph.requestPaint()
          }
        }
      }
    }
  }

  Process {
    id: actionProc
    onExited: {
      if (root.queuedLevel >= 0) {
        var n = root.queuedLevel
        root.queuedLevel = -1
        actionProc.command = [root.fanBin, "manual", String(n)]
        actionProc.running = true
      } else {
        root.refresh()
      }
    }
  }

  // Keeps the fan in step with power-profile changes while the shell is up.
  Process {
    id: followProc
    running: root.supported
    command: ["bash", root.pluginDir + "/bin/omarchy-fan-follow"]
    onExited: followRestart.restart()
  }
  Timer { id: followRestart; interval: 5000; onTriggered: followProc.running = root.supported }

  // Setup: installing the root helper opens a terminal (it builds a small package),
  // enabling it afterwards is one polkit-authorized call.
  Process {
    id: setupProc
    onExited: root.refresh()
  }

  function runSetup() {
    if (setupProc.running) return
    if (setupState === "needs-enable") {
      setupProc.command = ["pkexec", root.helper, "enable"]
      setupProc.running = true
    } else if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation bash " + Util.shellQuote(root.pluginDir + "/install-helper.sh"))
    }
  }

  Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  visible: supported
  implicitWidth: supported ? button.implicitWidth : 0
  implicitHeight: supported ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    text: "󰈐"
    tooltipText: "Fan"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.profileIndex = Model.selectProfileIndex(root.profileIndex, dx !== 0 ? dx : dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · title/status · RPM ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroRpm.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰈐"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroRpm.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Fan"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: (root.serviceUp ? (root.rpm > 0 ? "Spinning" : "Idle") : "Thinkfan stopped").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              width: parent.width
              elide: Text.ElideRight
            }
          }

          Text {
            id: heroRpm
            textFormat: Text.PlainText
            text: root.rpm > 0 ? root.rpm : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Setup needed ----------
        Column {
          visible: root.setupState !== "ready"
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: root.setupState === "no-thinkfan"
              ? "thinkfan isn't installed, so the fan stays on firmware control."
              : (root.setupState === "needs-enable"
                 ? "The fan helper is installed. Enable it once to take over the fan."
                 : "Fan control needs a small root helper (a package built from this plugin).")
            color: root.bar.foreground
            opacity: 0.75
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Button {
            width: parent.width
            text: root.setupState === "needs-enable" ? "Enable fan control" : "Install fan control"
            iconText: "󰈐"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.runSetup()
          }
        }

        // ---------- RPM history ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Canvas {
            id: graph
            width: parent.width
            height: Style.space(56)
            renderTarget: Canvas.Image
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height, list = root.history
              var fg = root.bar.foreground
              // faint baseline
              ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
              ctx.lineWidth = 1
              ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke()
              if (list.length < 2) return
              var max = 6000
              var step = w / (root.maxSamples - 1)
              var x0 = w - (list.length - 1) * step
              var pink = Color.accent
              ctx.beginPath()
              for (var i = 0; i < list.length; i++) {
                var x = x0 + i * step
                var y = h - 2 - Math.max(0, Math.min(1, list[i] / max)) * (h - 4)
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
              }
              ctx.strokeStyle = pink.toString()
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.stroke()
              ctx.lineTo(w, h); ctx.lineTo(x0, h); ctx.closePath()
              var g = ctx.createLinearGradient(0, 0, 0, h)
              g.addColorStop(0, Qt.rgba(pink.r, pink.g, pink.b, 0.55))
              g.addColorStop(1, Qt.rgba(pink.r, pink.g, pink.b, 0.02))
              ctx.fillStyle = g
              ctx.fill()
            }
          }

          Row {
            width: parent.width
            InfoLabel { text: "LAST 2 MIN"; font.letterSpacing: 1.2 }
            Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
            InfoLabel { text: root.history.length > 0 ? "peak " + Math.max.apply(null, root.history) + " rpm" : "" }
          }
        }

        // ---------- Fan profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "FAN PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing * (root.profiles.length - 1)) / root.profiles.length

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: Model.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: root.cursorActive ? Model.profileHint(root.profiles[root.profileIndex]) : (root.activeProfile === "manual" ? "Fixed level, no curve" : Model.profileHint(root.activeProfile))
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }
        }

        // ---------- Manual level ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(manualHeader.implicitHeight, manualValue.implicitHeight)

            PanelSectionHeader {
              id: manualHeader
              text: "MANUAL"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: manualValue
              textFormat: Text.PlainText
              text: Model.levelLabel(manualSlider.dragging ? manualSlider.liveValue : root.sliderValue).toUpperCase()
              color: root.activeProfile === "manual" ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            width: parent.width
            height: manualSlider.implicitHeight + Style.spacing.controlGap
            hasCursor: false
            foreground: root.bar.foreground
            outline: true

            PanelSlider {
              id: manualSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: 0
              maximum: 8
              step: 1
              integer: true
              tickCount: 9
              value: root.sliderValue
              onReleased: function(v) { root.setManualLevel(v) }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Drag to pin a fixed fan level"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }
          Item {
            width: parent.width
            implicitHeight: Math.max(followLabels.implicitHeight, followSwitch.implicitHeight)

            Column {
              id: followLabels
              anchors.left: parent.left
              anchors.right: followSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Follow power profile"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                text: root.followPower ? "Power profile changes reset the fan" : "Fan setting stays until you change it"
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }
            }

            ToggleSwitch {
              id: followSwitch
              checked: root.followPower
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setFollow(!root.followPower)
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
