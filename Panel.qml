import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  implicitWidth: barBtn.implicitWidth
  implicitHeight: barBtn.implicitHeight
  moduleName: "onlyvishesh.power-manager"
  ipcTarget: "onlyvishesh.power-manager"
  manageIpc: true

  property bool openedFromMenu: false
  property string currentTab: "overview"

  // ── Live system state ──
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  property int currentBrightness: 50
  property var diagnosticsData: ({})

  // ── Config state ──
  property var config: Model.defaultConfig()
  property var editConfig: Model.defaultConfig()
  property bool configDirty: JSON.stringify(config) !== JSON.stringify(editConfig)

  // ── UPower convenience ──
  readonly property var upowerStates: ({ Charging: 1, Discharging: 2, FullyCharged: 4, PendingCharge: 3 })
  readonly property bool discharging: {
    var d = UPower.displayDevice
    return ! (d && d.isPresent && UPower.onBattery)
  }
  readonly property real batteryFrac: Model.batteryFraction(UPower.displayDevice)
  readonly property bool fullyCharged: {
    var d = UPower.displayDevice
    return d && d.isPresent && d.state === 4 && !Model.chargeThresholdActive(d, discharging, upowerStates)
  }
  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !fullyCharged
  }
  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (discharging) return "On battery"
    return "Charging"
  }
  readonly property color batteryFillColor: root.bar ? root.bar.foreground : Color.foreground

  // ── Config helpers ──
  function getVal(key, def) {
    if (!editConfig) return def
    var parts = key.split('.')
    var obj = editConfig
    for (var i = 0; i < parts.length; i++) {
      if (!obj || obj[parts[i]] === undefined) return def
      obj = obj[parts[i]]
    }
    return obj
  }

  function setVal(key, value) {
    var c = JSON.parse(JSON.stringify(editConfig))
    var parts = key.split('.')
    var obj = c
    for (var i = 0; i < parts.length - 1; i++) {
      if (!obj[parts[i]] || typeof obj[parts[i]] !== 'object') obj[parts[i]] = {}
      obj = obj[parts[i]]
    }
    obj[parts[parts.length - 1]] = value
    editConfig = c
  }

  // ── Profile control ──
  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
  }

  function setSystemProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", discharging ? "battery" : "ac", profile]
    actionProc.running = true
    activeProfile = profile
  }

  // ── Lifecycle ──
  Component.onCompleted: configReadProc.running = true

  onOpenedChanged: {
    if (opened) {
      currentTab = "overview"
      root.editConfig = JSON.parse(JSON.stringify(root.config))
      refresh()
      refreshTimer.restart()
    } else {
      refreshTimer.stop()
    }
  }

  function refresh() {
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    if (!brightnessReadProc.running) brightnessReadProc.running = true
  }

  // ── Processes ──
  Process {
    id: configReadProc
    command: ["bash", "-c", "cat $HOME/.config/onlyvishesh.power-manager.json 2>/dev/null || echo '{}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          var merged = Model.mergeWithDefaults(parsed)
          root.config = merged
          root.editConfig = JSON.parse(JSON.stringify(merged))
        } catch(e) {}
      }
    }
  }

  Process {
    id: actionProc
    onExited: { if (!profilesProc.running) profilesProc.running = true }
  }

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.batteryInfo = next
      }
    }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.systemInfo = next
      }
    }
  }

  Process {
    id: brightnessReadProc
    command: ["omarchy-brightness-display", "--no-osd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var val = parseInt(String(text).trim())
        if (!isNaN(val) && val >= 1 && val <= 100) root.currentBrightness = val
      }
    }
  }

  Process {
    id: brightnessSetProc
    onExited: { if (!brightnessReadProc.running) brightnessReadProc.running = true }
  }

  Timer {
    id: refreshTimer
    interval: 3000
    repeat: true
    running: false
    onTriggered: root.refresh()
  }

  property var tabOptions: [
    { value: "overview", label: "Overview", icon: "󰂄" },
    { value: "profiles", label: "Profiles", icon: "󰓅" },
    { value: "advanced", label: "Advanced", icon: "󰒓" },
    { value: "diagnostics", label: "Diag.", icon: "󰋽" }
  ]

  // ── Bar button ──
  BarIconButton {
    id: barBtn
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot * 2
    text: (UPower.displayDevice.percentage * 100 > 0 ? Math.round(UPower.displayDevice.percentage * 100) + "% " : "") + Model.batteryIcon(UPower.displayDevice, UPower.onBattery, root.upowerStates) || "󰂄"
    onPressed: { root.openedFromMenu = false; root.toggle() }
  }

  // ── Shared UI content ──
  Component {
    id: panelContent
    Column {
      id: contentCol
      width: parent.width
      spacing: Style.space(12)

      // Tab bar
      ButtonGroup {
        width: parent.width
        options: root.tabOptions
        value: root.currentTab
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.font.bodySmall
        onChanged: function(v) { 
          if (root.configDirty) {
             root.editConfig = JSON.parse(JSON.stringify(root.config));
          }
          root.currentTab = v; 
        }
      }

      // ═══════════ OVERVIEW TAB ═══════════
      Column {
        width: parent.width
        spacing: Style.space(14)
        visible: root.currentTab === "overview"

        // Hero
        PanelHero {
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "Battery"
          meta: root.heroStatusText
          detail: root.batteryInfo.percentage || (Math.round(root.batteryFrac * 100) + "%")
          iconComponent: Component {
            Text {
              text: Model.batteryIcon(UPower.displayDevice, UPower.onBattery, root.upowerStates) || "󰂄"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }
          }
        }

        // Battery bar
        Item {
          width: parent.width
          implicitHeight: Style.space(8)
          Rectangle {
            id: batTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.batteryFillColor.r, root.batteryFillColor.g, root.batteryFillColor.b, 0.12)
          }
          Rectangle {
            anchors.left: batTrack.left
            anchors.verticalCenter: batTrack.verticalCenter
            height: batTrack.height
            radius: batTrack.radius
            color: root.batteryFillColor
            width: Math.max(batTrack.height, batTrack.width * root.batteryFrac)
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            SequentialAnimation on opacity {
              running: root.charging && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // Stats
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)
          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }
          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.discharging ? "Time left" : (root.fullyCharged ? "Status" : "Time to full")
              value: root.fullyCharged ? "Full" : (root.batteryInfo.time || "—")
            }
            InfoPair {
              label: root.discharging ? "Discharging" : "Charging"
              value: root.fullyCharged ? "—" : (root.batteryInfo.rate || "")
            }
          }
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Brightness
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "BRIGHTNESS"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              text: "󰃠"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }
            PanelSlider {
              id: brightnessSlider
              bar: root.bar
              width: parent.width - Style.space(80)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 1
              maximum: 100
              integer: true
              step: 1
              value: root.currentBrightness
              onMoved: function(val) {
                var pct = Math.round(val)
                brightnessSetProc.command = ["omarchy-brightness-display", "--no-osd", pct + "%"]
                brightnessSetProc.running = true
              }
              onReleased: function(val) {
                brightnessReadProc.running = true
              }
            }
            Text {
              text: root.currentBrightness + "%"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
            }
          }
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Profile picker
        Column {
          width: parent.width
          spacing: Style.space(10)
          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length : 0
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
                foreground: root.bar ? root.bar.foreground : Color.foreground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                onClicked: root.setSystemProfile(modelData)
              }
            }
          }
        }
      }
    }
  }

  // ── Bar popup mode ──
  KeyboardPanel {
    id: popupPanel
    anchorItem: barBtn
    owner: root
    bar: root.bar
    open: root.opened && !root.openedFromMenu
    contentWidth: popupPanel.fittedContentWidth(Style.space(480))
    contentHeight: popupPanel.fittedContentHeight(popupFlick.contentHeight + Style.space(32))

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: popupFlick
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentHeight: popupLoader.item ? popupLoader.item.implicitHeight : 0
        contentWidth: width
        clip: true

        Loader {
          id: popupLoader
          sourceComponent: panelContent
          width: parent.width
        }
      }
    }
  }

  // ── Standalone app window mode ──
  PanelWindow {
    id: windowPanel
    visible: root.opened && root.openedFromMenu
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-power-manager"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(Style.space(480), windowPanel.width - Style.space(32))
      height: Math.min(windowLoader.item ? windowLoader.item.implicitHeight + Style.space(32) : Style.space(400), windowPanel.height - Style.space(64))
      color: Color.popups.background
      radius: Style.cornerRadius
      border.color: Color.popups.border
      border.width: 1

      MouseArea { anchors.fill: parent }

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentHeight: windowLoader.item ? windowLoader.item.implicitHeight : 0
        contentWidth: width
        clip: true

        Loader {
          id: windowLoader
          sourceComponent: panelContent
          width: parent.width
        }
      }
    }
  }
}
