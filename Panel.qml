import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Power Manager — an Omarchy bar panel.
//
// The visual contract is the shell's own: every surface is a kit component
// (Button, Dropdown, NumberField, ToggleSwitch, PanelSlider, CursorSurface),
// every corner is `Style.cornerRadius` so the panel follows Hyprland's
// rounding instead of inventing its own, and every fill/border comes from the
// Style state tokens so themes reach it. Nothing here hard-codes a radius, a
// tint, or a color that isn't derived from the bar foreground or the theme.
//
// Three tabs, split by how often you touch them:
//   Battery — the live view plus the two controls worth one click (power
//             profile, charge limit). Both act immediately.
//   Rules   — the automation form. One power state at a time, so the nine
//             idle/lid fields read as three coherent rulesets instead of a
//             wall. Edits are staged and land on Apply.
//   System  — hibernation readiness, sleep states, appearance, reset.
Panel {
  id: root
  moduleName: "kurisu-null.power-manager"
  ipcTarget: "kurisu-null.power-manager"
  manageIpc: true

  // Same contract as the shell's own power panel: a machine with no battery has
  // no business carrying a battery icon.
  visible: batteryPresent
  implicitWidth: batteryPresent ? barBtn.implicitWidth : 0
  implicitHeight: batteryPresent ? barBtn.implicitHeight : 0
  onBatteryPresentChanged: if (!batteryPresent) close()

  // ── Theme shorthands ──────────────────────────────────────────────────────
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string uiFont: bar ? bar.fontFamily : Style.font.family
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  // Panel geometry. 380 is the width every first-party panel uses; the form
  // controls take a fixed trailing column so labels and controls line up down
  // the whole Rules tab.
  readonly property int panelWidth: Style.space(380)
  readonly property int windowWidth: Style.space(420)
  readonly property int formControlWidth: Style.space(180)

  // ── Panel state ───────────────────────────────────────────────────────────
  property bool openedFromMenu: false
  property string currentTab: "battery"
  property string ruleState: "ac"
  readonly property var tabs: [
    { value: "battery", label: "Battery", icon: "󰂄" },
    { value: "rules", label: "Rules", icon: "󰒓" },
    { value: "system", label: "System", icon: "󰋽" }
  ]

  // The two surfaces the switcher offers: whichever ones you are not on.
  readonly property var otherTabs: {
    var out = []
    for (var i = 0; i < tabs.length; i++) if (tabs[i].value !== currentTab) out.push(tabs[i])
    return out
  }

  function tabIndexOf(value) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].value === value) return i
    return -1
  }

  // Open dropdown popups own j/k while they are up; the key catcher stands
  // down for as long as at least one is open.
  property int dropdownOpen: 0

  // ── Live system state ─────────────────────────────────────────────────────
  property var batteryInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int currentBrightness: 50
  property var diagnosticsData: ({})

  BatteryTracker {
    id: tracker
    onLimitChanged: root.pendingLimit = limit
    onLimitSyncRequired: function(l) { root.pendingLimit = l }
  }

  // Optimistic charge limit: the pills paint from this the instant they are
  // clicked, and the tracker's next probe confirms or corrects it.
  property int pendingLimit: 100

  // ── Config state ──────────────────────────────────────────────────────────
  property var config: Model.defaultConfig()
  property var editConfig: Model.defaultConfig()
  readonly property bool configDirty: JSON.stringify(config) !== JSON.stringify(editConfig)

  // ── Display-plugin awareness ──────────────────────────────────────────────
  //
  // Some plugins already own screen brightness. While one of them is present
  // this plugin stays out of the way: the manual slider disappears entirely,
  // and the automatic-brightness rules only surface if they are already
  // switched on — so a setting that is actively doing something never becomes
  // unreachable.
  //
  // Which plugins count is `brightness.deferToPlugins` in the config file, not
  // a list baked into the code. The shell.json side is watched, so adding or
  // removing a display plugin from the bar takes effect immediately; the
  // pattern list itself is re-read with the rest of the config, which happens
  // on load and every time the panel opens.
  property var shellEntryIds: []
  readonly property var brightnessDeferList: {
    var _ = root.config
    return Model.deferToPlugins(root.config)
  }
  // The matching id rather than a bool, so the System tab can name who took over.
  readonly property string displayPluginMatch: Model.matchingDisplayPlugin(shellEntryIds, brightnessDeferList)
  readonly property bool displayPluginPresent: displayPluginMatch !== ""
  readonly property bool showBrightness: !displayPluginPresent
  readonly property bool showAutoBrightness: {
    var _ = root.editConfig
    return !displayPluginPresent || getVal("brightness.auto", false) === true
  }

  FileView {
    id: shellConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readShellConfig()
    onLoadFailed: root.shellEntryIds = []
  }

  function readShellConfig() {
    try {
      root.shellEntryIds = Model.shellEntryIds(JSON.parse(shellConfigFile.text() || "{}"))
    } catch (e) {
      root.shellEntryIds = []
    }
  }

  // ── UPower ────────────────────────────────────────────────────────────────
  readonly property var upowerStates: ({
    Charging: UPowerDeviceState.Charging,
    Discharging: UPowerDeviceState.Discharging,
    FullyCharged: UPowerDeviceState.FullyCharged,
    PendingCharge: UPowerDeviceState.PendingCharge
  })
  readonly property bool batteryPresent: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent)
  }
  readonly property bool discharging: batteryPresent && UPower.onBattery
  readonly property real batteryFrac: Model.batteryFraction(UPower.displayDevice)
  readonly property bool chargeThresholdActive: Model.chargeThresholdActive(UPower.displayDevice, discharging, upowerStates)
  readonly property bool fullyCharged: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent && d.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive)
  }
  readonly property bool batteryFull: fullyCharged || (!discharging && batteryFrac >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive
  readonly property bool charging: batteryPresent && !UPower.onBattery && !batteryFlowIdle

  function batteryIcon() {
    return Model.batteryIcon(UPower.displayDevice, root.discharging, root.upowerStates) || "󰂄"
  }

  // Rotating status line, same idiom as the shell's own power panel.
  readonly property var chargingPhrases: [
    "Hoarding electrons", "Sucking watts", "Drinking juice", "Stockpiling volts",
    "Gulping amps", "Inhaling power", "Consuming energy"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power", "Spending joules", "Draining watts", "Burning electrons",
    "Sipping juice", "Spending coulombs", "Bleeding amps", "Guzzling volts"
  ]
  property int phraseIndex: 0
  readonly property var activePhrases: {
    if (!batteryPresent) return []
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0
  readonly property string heroStatusText: {
    if (!batteryPresent) return "No battery"
    if (chargeThresholdActive) return tracker.limit < 100 ? "Holding at " + tracker.limit + "%" : "Not charging"
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return Model.modeLabel(UPower.displayDevice, discharging, upowerStates)
  }

  Timer {
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: root.phraseIndex++
  }

  // ── Low-battery warning ───────────────────────────────────────────────────
  //
  // Fires once as the battery falls past the configured threshold — the same
  // crossing that flips the backend into its batteryLow ruleset, so the
  // notification explains a profile change you would otherwise just feel.
  property bool lowBatteryNotified: false
  readonly property real lowBatteryFraction: Math.max(0, Math.min(1, configVal("batteryThreshold", 20) / 100))

  function checkLowBattery() {
    if (!batteryPresent || !discharging) {
      lowBatteryNotified = false
      return
    }
    // Rearm only well clear of the line, so a battery hovering on the boundary
    // cannot notify twice.
    if (batteryFrac > lowBatteryFraction + 0.03) {
      lowBatteryNotified = false
      return
    }
    if (lowBatteryNotified || batteryFrac > lowBatteryFraction) return
    lowBatteryNotified = true
    if (configVal("notifications.thresholdCrossing", true) !== true) return
    Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
      "Battery low",
      Math.round(batteryFrac * 100) + "% remaining · "
        + Model.profileLabel(configVal("profiles.batteryLow", "power-saver")) + " rules now in effect"])
  }

  onBatteryFracChanged: checkLowBattery()
  onDischargingChanged: checkLowBattery()

  // ── Config helpers ────────────────────────────────────────────────────────
  function getVal(key, def) {
    if (!editConfig) return def
    var parts = String(key).split('.')
    var obj = editConfig
    for (var i = 0; i < parts.length; i++) {
      if (!obj || obj[parts[i]] === undefined) return def
      obj = obj[parts[i]]
    }
    return obj
  }

  // Background behaviour must read the *applied* config, never the staged one:
  // typing "5" into a sleep timeout should not put the machine to sleep in five
  // minutes before you have pressed Apply.
  function configVal(key, def) {
    if (!config) return def
    var parts = String(key).split('.')
    var obj = config
    for (var i = 0; i < parts.length; i++) {
      if (!obj || obj[parts[i]] === undefined) return def
      obj = obj[parts[i]]
    }
    return obj
  }

  function setVal(key, value) {
    var c = JSON.parse(JSON.stringify(editConfig))
    var parts = String(key).split('.')
    var obj = c
    for (var i = 0; i < parts.length - 1; i++) {
      if (!obj[parts[i]] || typeof obj[parts[i]] !== 'object') obj[parts[i]] = {}
      obj = obj[parts[i]]
    }
    obj[parts[parts.length - 1]] = value
    editConfig = c
  }

  function revertChanges() {
    root.editConfig = JSON.parse(JSON.stringify(root.config))
  }

  function applyChanges() {
    root.forceActiveFocus()
    root.applyState = "writing"
    root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2))
    configWriteProc.running = true
  }

  function resetToDefaults() {
    root.editConfig = Model.defaultConfig()
    applyChanges()
  }

  function confirmReset() {
    root.resetPending = false
    resetToDefaults()
  }

  // ── Bar appearance ────────────────────────────────────────────────────────
  //
  // The percentage lives in this widget's inline shell.json entry, not in the
  // plugin's own config: it is pure chrome, and routing it through the config
  // file would mean a polkit prompt every time someone toggled it.
  readonly property bool showPercentage: {
    var fallback = !!(config && config.appearance && config.appearance.showPercentage !== false)
    return setting("showPercentage", fallback) === true
  }
  readonly property real openPanelIndicatorWidth: showPercentage && !barBtn.vertical ? barBtn.glyphPaintedWidth : 0

  // Anything that is pure chrome goes here rather than into the plugin config,
  // for the same reason: the config file write is gated behind polkit, and no
  // view preference is worth a password prompt.
  function setSetting(name, value) {
    var next = {}
    next[name] = value
    root.settings = Object.assign({}, root.settings, next)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function togglePercentage() { setSetting("showPercentage", !root.showPercentage) }

  // ── Stat disclosure ───────────────────────────────────────────────────────
  //
  // Three of the stat rows are doors rather than readouts: Health opens its
  // history, Charge limit opens the cut-off picker, and Discharging opens the
  // power-draw trace. The row itself is the affordance, so the value you came
  // to read is never hidden behind the control that sets it.
  //
  // One at a time — an accordion. Two graphs stacked under a six-row grid is
  // the wall of panel this redesign exists to avoid.
  readonly property string expandedStat: {
    var key = String(setting("expandedStat", ""))
    return statExpandable(key) ? key : ""
  }

  function statExpandable(key) {
    if (key === "health") return tracker.healthPct > 0
    if (key === "limit") return tracker.supported
    if (key === "power") return batteryPresent
    return false
  }

  function toggleStat(key) {
    if (!statExpandable(key)) return
    setSetting("expandedStat", root.expandedStat === key ? "" : key)
  }

  // ── Power draw history ────────────────────────────────────────────────────
  //
  // A rolling ten-minute trace of draw, sampled from UPower's changeRate — a
  // DBus property that is already live, so this costs no process spawn and no
  // file read. Deliberately in memory only: it answers "what is this machine
  // doing right now", which is a question that stops mattering the moment the
  // shell restarts. Nothing to persist, nothing to migrate, nothing to prune.
  readonly property int powerSampleSeconds: 5
  readonly property int powerWindowMinutes: 10
  readonly property int powerMaxSamples: powerWindowMinutes * 60 / powerSampleSeconds
  property var powerSamples: []

  // UPower reports the magnitude; direction comes from the charge state.
  readonly property real powerDraw: {
    var d = UPower.displayDevice
    return d && d.isPresent ? Math.max(0, d.changeRate) : 0
  }
  function formatDuration(seconds) {
    var total = Math.round(Number(seconds) || 0)
    if (total <= 0) return ""
    var h = Math.floor(total / 3600)
    var m = Math.round((total % 3600) / 60)
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
    return m + "m"
  }

  // omarchy-battery-status leaves this blank whenever the kernel has not
  // settled on an estimate, which is most of the first few minutes after a
  // plug or unplug. UPower carries its own estimate, so fall through to it
  // rather than showing a dash.
  readonly property string batteryTimeLabel: {
    if (!batteryPresent || batteryFlowIdle) return "—"
    var fromShell = String(batteryInfo.time || "").trim()
    if (fromShell !== "") return fromShell
    var d = UPower.displayDevice
    if (!d) return "—"
    return formatDuration(discharging ? d.timeToEmpty : d.timeToFull) || "—"
  }

  readonly property string powerDrawLabel: {
    if (!batteryPresent || batteryFlowIdle) return "—"
    if (powerDraw > 0) return powerDraw.toFixed(1) + "W"
    return batteryInfo.rate || "—"
  }

  // Runs whether or not the panel is open, so the trace has history to show
  // the first time you look at it rather than starting from blank.
  Timer {
    interval: root.powerSampleSeconds * 1000
    running: root.batteryPresent
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var next = root.powerSamples.slice(root.powerSamples.length >= root.powerMaxSamples ? 1 : 0)
      next.push(root.powerDraw)
      root.powerSamples = next
    }
  }


  // ── Profiles & charge limit (immediate actions) ───────────────────────────
  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, 0)
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
  }

  function setSystemProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", discharging ? "battery" : "ac", profile]
    actionProc.running = true
    activeProfile = profile
  }

  function setChargeLimit(pct) {
    if (!tracker.supported || tracker.applying) return
    root.pendingLimit = pct
    tracker.setLimit(pct)
  }

  // ── Keyboard cursor ───────────────────────────────────────────────────────
  //
  // The shell summons panels from the keyboard (SUPER+CTRL+W), so every
  // first-party panel carries a cursor model. Sections are walked with j/k,
  // options within a section with h/l, Enter activates, 1/2/3 switch tabs.
  // Mouse hover writes into the same state, so there is only ever one
  // highlight on screen no matter which input you used last.
  property bool cursorActive: false
  property string focusSection: ""
  property int selectedIndex: 0

  // The stat rows that are doors, in the order j/k walks them.
  function statDoors() {
    var out = []
    if (statExpandable("health")) out.push("health")
    if (statExpandable("power")) out.push("power")
    if (statExpandable("limit")) out.push("limit")
    return out
  }

  readonly property var cursorSections: {
    if (currentTab === "rules") return ["states", "switcher"]
    if (currentTab === "system") return ["reset", "switcher"]
    var list = []
    if (statDoors().length > 0) list.push("stats")
    if (expandedStat === "limit") list.push("limitpills")
    if (profiles.length > 0) list.push("profiles")
    if (showBrightness) list.push("brightness")
    list.push("switcher")
    return list
  }

  function sectionCount(section) {
    if (section === "stats") return statDoors().length
    if (section === "limitpills") return Model.chargeLimitOptions().length
    if (section === "profiles") return profiles.length
    if (section === "states") return Model.powerStates().length
    if (section === "switcher") return otherTabs.length
    return 1
  }

  // Sections whose options sit side by side, so h/l walks them.
  function sectionIsRow(section) {
    return section === "limitpills" || section === "profiles"
      || section === "states" || section === "switcher"
  }

  function cursorOn(section, index) {
    return cursorActive && focusSection === section && selectedIndex === index
  }

  function pointCursor(section, index) {
    cursorActive = true
    focusSection = section
    selectedIndex = index
  }

  onCursorSectionsChanged: {
    if (cursorSections.indexOf(focusSection) === -1) {
      focusSection = cursorSections.length > 0 ? cursorSections[0] : ""
      selectedIndex = 0
    } else if (selectedIndex >= sectionCount(focusSection)) {
      selectedIndex = Math.max(0, sectionCount(focusSection) - 1)
    }
  }

  // Returns false when the cursor is already against the end, so the caller can
  // fall through to scrolling the view instead of swallowing the key.
  function moveCursor(delta) {
    var secs = cursorSections
    if (secs.length === 0) return false
    var si = secs.indexOf(focusSection)
    if (si < 0) {
      focusSection = secs[0]
      selectedIndex = 0
      return true
    }
    var vertical = focusSection === "stats"
    if (delta > 0) {
      if (vertical && selectedIndex < sectionCount(focusSection) - 1) { selectedIndex++; return true }
      if (si >= secs.length - 1) return false
      focusSection = secs[si + 1]
      selectedIndex = 0
      return true
    }
    if (vertical && selectedIndex > 0) { selectedIndex--; return true }
    if (si <= 0) return false
    var prev = secs[si - 1]
    focusSection = prev
    selectedIndex = prev === "stats" ? sectionCount(prev) - 1 : 0
    return true
  }

  function moveCursorH(delta) {
    if (focusSection === "brightness") {
      setBrightness(currentBrightness + delta * 5)
      return
    }
    if (!sectionIsRow(focusSection)) return
    var n = sectionCount(focusSection)
    if (n === 0) return
    selectedIndex = Math.max(0, Math.min(n - 1, selectedIndex + delta))
  }

  function activateCursor() {
    if (!cursorActive) return
    if (focusSection === "stats") {
      var doors = statDoors()
      if (selectedIndex < doors.length) toggleStat(doors[selectedIndex])
    } else if (focusSection === "limitpills") {
      var opts = Model.chargeLimitOptions()
      if (selectedIndex < opts.length) setChargeLimit(Number(opts[selectedIndex]))
    } else if (focusSection === "profiles") {
      if (selectedIndex < profiles.length) setSystemProfile(profiles[selectedIndex])
    } else if (focusSection === "states") {
      var states = Model.powerStates()
      if (selectedIndex < states.length) ruleState = states[selectedIndex].key
    } else if (focusSection === "reset") {
      resetPending = true
    } else if (focusSection === "switcher") {
      if (selectedIndex < otherTabs.length) selectTab(otherTabs[selectedIndex].value)
    }
  }

  function setBrightness(pct) {
    var next = Math.max(1, Math.min(100, Math.round(pct)))
    if (next === currentBrightness) return
    currentBrightness = next
    brightnessSetProc.command = ["omarchy-brightness-display", "--no-osd", next + "%"]
    brightnessSetProc.running = true
  }

  // ── Tabs ──────────────────────────────────────────────────────────────────
  function selectTab(value) {
    if (value === currentTab) return
    currentTab = value
    focusSection = ""
    selectedIndex = 0
    if (value === "system" && !diagnosticsProc.running) diagnosticsProc.running = true
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  Component.onCompleted: {
    configReadProc.running = true
    backendProbe.running = true
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }
      dropdownOpen = 0
      cursorActive = false
      focusSection = ""
      selectedIndex = 0
      applyState = "idle"
      backendProbe.running = true
      currentTab = "battery"
      ruleState = root.currentStateKey
      revertChanges()
      configReadProc.running = true
      refresh()
      refreshTimer.restart()
    } else {
      refreshTimer.stop()
    }
  }

  function refresh() {
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (showBrightness && !brightnessReadProc.running) brightnessReadProc.running = true
  }

  // ── Native idle suspend worker ────────────────────────────────────────────
  readonly property string currentStateKey: Model.currentStateKey(root.discharging, root.batteryFrac, root.configVal("batteryThreshold", 30))
  readonly property int idleSleepMins: root.configVal("idle." + currentStateKey + ".sleepAfterMinutes", 0)
  readonly property string idleAction: root.configVal("idle." + currentStateKey + ".afterSleep", "ignore")

  property bool wasIdle: false
  property int idleCountdown: 0

  Process {
    id: idleStatusProc
    command: ["sh", "-c", "WAYLAND_DISPLAY= echo \"$(qs ipc --any-display -p /usr/share/omarchy/shell call idle status 2>/dev/null)\" \"|||\" \"$(qs ipc --any-display -p /usr/share/omarchy/shell call lock status 2>/dev/null)\""]
    stdout: SplitParser {
      onRead: function(line) {
        var res = String(line).trim()
        if (res === "" || res.indexOf("|||") === -1) return
        try {
          var parts = res.split("|||")
          var idleSt = JSON.parse(parts[0].trim())
          var lockSt = JSON.parse(parts[1].trim())

          var isSleepable = (idleSt.inIdleCycle === true || lockSt.locked === true)
          var isTyping = (lockSt.locked === true && (lockSt.authenticating || lockSt.unlocking || lockSt.previewTyped > 0))

          if (!isSleepable) {
            root.wasIdle = false
            return
          }

          if (!root.wasIdle) {
            root.wasIdle = true
            var elapsed = 0
            if (lockSt.locked) elapsed = idleSt.lock
            else if (idleSt.inIdleCycle) elapsed = idleSt.screensaver
            root.idleCountdown = (root.idleSleepMins * 60) - elapsed
            // Always leave a minute on the clock after a wake so a tight
            // timeout can't put the machine straight back to sleep.
            if (root.idleCountdown < 60) root.idleCountdown = 60
            return
          }

          if (isTyping) {
            root.idleCountdown = 60
            return
          }

          root.idleCountdown -= 5
          if (root.idleCountdown > 0) return

          var cmd = ""
          if (root.idleAction === "suspend") cmd = "systemctl suspend"
          else if (root.idleAction === "hibernate") cmd = "systemctl hibernate"
          else if (root.idleAction === "suspend-then-hibernate") cmd = "systemctl suspend-then-hibernate"
          else if (root.idleAction === "hybrid-sleep") cmd = "systemctl hybrid-sleep"
          else if (root.idleAction === "poweroff") cmd = "systemctl poweroff"
          if (cmd !== "") {
            idleActionProc.command = ["bash", "-c", cmd]
            idleActionProc.running = true
          }
          root.wasIdle = false
        } catch (e) {}
      }
    }
  }

  // Each tick costs three processes (sh plus two `qs ipc` clients), so the
  // fine five-second cadence is reserved for when a countdown is actually
  // running. While the machine is in use, checking twice a minute is plenty —
  // the countdown is computed from elapsed idle time on the first tick that
  // sees idle, so nothing is lost by having noticed it late.
  Timer {
    running: !!root.bar && root.configVal("enabled", true) && root.idleSleepMins > 0 && root.idleAction !== "ignore"
    repeat: true
    interval: root.wasIdle ? 5000 : 30000
    onTriggered: idleStatusProc.running = true
  }

  Process { id: idleActionProc }

  // ── IPC ───────────────────────────────────────────────────────────────────
  IpcHandler {
    target: "power-manager"
    function open() { root.openedFromMenu = true; root.open() }
    function toggle() { root.openedFromMenu = true; root.toggle() }
    function close() { root.close() }
    function togglePercentage() { root.togglePercentage() }
  }

  // ── Processes ─────────────────────────────────────────────────────────────
  Process {
    id: configReadProc
    // Falls back to the upstream plugin's path so anyone arriving from
    // onlyvishesh.power-manager keeps their settings. Writes always go to the
    // new path, so the fallback stops mattering after the first Apply.
    command: ["bash", "-c",
      "cat \"$HOME/.config/kurisu-null.power-manager.json\" 2>/dev/null"
      + " || cat \"$HOME/.config/onlyvishesh.power-manager.json\" 2>/dev/null"
      + " || echo '{}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var merged = Model.mergeWithDefaults(JSON.parse(text))
          // Never stomp on edits the user is in the middle of making.
          if (root.configDirty && JSON.stringify(merged) === JSON.stringify(root.config)) return
          root.config = merged
          root.editConfig = JSON.parse(JSON.stringify(merged))
        } catch (e) {}
      }
    }
  }

  // ── Backend state ─────────────────────────────────────────────────────────
  //
  // Everything that touches the system goes through pkexec into
  // /usr/local/libexec, which extras/install.sh puts there. Until that has been
  // run, applying rules and setting a charge limit cannot work — so say so up
  // front rather than letting every attempt fail silently.
  readonly property string backendPath: "/usr/local/libexec/omarchy-power-manager"
  property bool backendChecked: false
  property bool backendInstalled: false

  Process {
    id: backendProbe
    command: ["sh", "-c", "test -x \"$1/power-manager-apply\" && test -x \"$1/power-manager-limit\" && echo yes", "sh", root.backendPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.backendInstalled = String(text).trim() === "yes"
        root.backendChecked = true
      }
    }
  }

  // Outcome of the last apply. The config write and the privileged step fail
  // for different reasons and want different words, so they are one state
  // machine rather than a bare boolean.
  //   idle | writing | applying | ok | write-failed | cancelled | missing | failed
  property string applyState: "idle"
  readonly property bool applyBusy: applyState === "writing" || applyState === "applying"
  readonly property bool applyFailed: ["write-failed", "cancelled", "missing", "failed"].indexOf(applyState) !== -1
  readonly property string applyMessage: {
    if (applyState === "writing") return "Saving…"
    if (applyState === "applying") return "Applying…"
    if (applyState === "ok") return "Applied"
    if (applyState === "write-failed") return "Could not write the config file — nothing was changed."
    if (applyState === "cancelled") return "Saved, but not applied — the password prompt was dismissed."
    if (applyState === "missing") return "Saved, but not applied — the backend is not installed."
    if (applyState === "failed") return "Saved, but the system was not updated."
    return ""
  }

  // A success badge should not linger; a failure should stay until acted on.
  Timer {
    id: applyOkTimer
    interval: 2500
    onTriggered: if (root.applyState === "ok") root.applyState = "idle"
  }

  property string pendingWrite: ""
  Process {
    id: configWriteProc
    command: ["sh", "-c", "echo \"$1\" | base64 -d > \"$HOME/.config/kurisu-null.power-manager.json\"", "sh", root.pendingWrite]
    onExited: function(code) {
      // Only claim the edit landed if the file actually took it; otherwise the
      // footer would clear and the panel would report a save that never was.
      if (code !== 0) {
        root.applyState = "write-failed"
        return
      }
      root.config = JSON.parse(JSON.stringify(root.editConfig))
      root.applyState = "applying"
      applyProc.running = true
    }
  }

  Process {
    id: applyProc
    command: ["pkexec", root.backendPath + "/power-manager-apply"]
    onExited: function(code) {
      // pkexec: 126 = the user dismissed the prompt, 127 = nothing to run.
      if (code === 0) {
        root.applyState = "ok"
        applyOkTimer.restart()
      } else if (code === 126) {
        root.applyState = "cancelled"
      } else if (code === 127 || !root.backendInstalled) {
        root.applyState = "missing"
      } else {
        root.applyState = "failed"
      }
      backendProbe.running = true
      diagnosticsProc.running = true
      profilesProc.running = true
    }
  }

  Process {
    id: actionProc
    onExited: if (!profilesProc.running) profilesProc.running = true
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
    onExited: if (!brightnessReadProc.running) brightnessReadProc.running = true
  }

  Process {
    id: diagnosticsProc
    command: ["bash", "-c", "\"$HOME/.config/omarchy/plugins/kurisu-null.power-manager/scripts/power-manager-diagnostics\" --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && typeof parsed === 'object') root.diagnosticsData = parsed
        } catch (e) {}
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: 3000
    repeat: true
    running: false
    onTriggered: root.refresh()
  }

  // ── Bar button ────────────────────────────────────────────────────────────
  BarIconButton {
    id: barBtn
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFrac * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    // Every other bar widget answers on hover; this one used to stay mute.
    tooltipText: {
      if (!root.batteryPresent) return "No battery"
      var parts = [Math.round(root.batteryFrac * 100) + "%"]
      if (root.powerDrawLabel !== "—") parts.push(root.powerDrawLabel)
      if (root.batteryTimeLabel !== "—") {
        parts.push(root.batteryTimeLabel + (root.discharging ? " left" : " to full"))
      } else if (root.batteryFull) {
        parts.push("fully charged")
      }
      if (tracker.supported && root.pendingLimit < 100) parts.push("limit " + root.pendingLimit + "%")
      return parts.join("  ·  ")
    }
    onPressed: function(b) {
      root.openedFromMenu = false
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Panel body — tab strip, scrolling content, dirty-state footer.
  // Shared verbatim by the bar popup and the standalone window.
  // ══════════════════════════════════════════════════════════════════════════
  Component {
    id: panelBody

    Item {
      id: body

      // What the host should size itself to, before it clamps to the screen.
      readonly property real bodyImplicitHeight:
        (tabLoader.item ? tabLoader.item.implicitHeight : Style.space(200))
        + bottomChrome.implicitHeight + Style.space(12)

      function scrollBy(dy) {
        var flick = scrollArea.contentItem
        if (!flick || flick.contentY === undefined) return
        var max = Math.max(0, flick.contentHeight - flick.height)
        flick.contentY = Math.max(0, Math.min(max, flick.contentY + dy))
      }

      // ---------- Scrolling content ----------
      ScrollView {
        id: scrollArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bottomChrome.top
        anchors.bottomMargin: Style.space(12)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: tabLoader.height > scrollArea.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: tabLoader.height > scrollArea.height
        }

        Loader {
          id: tabLoader
          width: scrollArea.availableWidth
          height: item ? item.implicitHeight : 0
          sourceComponent: root.currentTab === "rules" ? rulesTab
            : root.currentTab === "system" ? systemTab
            : batteryTab
        }
      }

      // ---------- Bottom chrome ----------
      //
      // Actions, then whatever went wrong, then navigation — in that order, so
      // the explanation of a failed Apply sits directly under the button that
      // caused it and the switcher stays pinned at the very foot.
      Column {
        id: bottomChrome
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

      // ---------- Dirty-state footer ----------
      //
      // Only the Rules form stages edits; everything else acts immediately.
      // So the footer is the single place changes are committed, and it is
      // only in the way while there is something to commit.
      Item {
        id: footer
        width: parent.width
        visible: root.configDirty
        implicitHeight: footerRow.implicitHeight + Style.space(11)

        PanelSeparator {
          anchors.top: parent.top
          foreground: root.fg
        }

        Row {
          id: footerRow
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.md
          layoutDirection: Qt.RightToLeft

          Button {
            width: Style.space(130)
            text: "Apply changes"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.uiFont
            verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
            bordered: true
            selected: true
            onClicked: root.applyChanges()
          }

          Button {
            width: Style.space(80)
            text: "Revert"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.uiFont
            verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
            bordered: true
            onClicked: root.revertChanges()
          }

          Text {
            textFormat: Text.PlainText
            width: Math.max(0, parent.width - Style.space(130) - Style.space(80) - Style.spacing.md * 2)
            text: root.applyBusy ? root.applyMessage : "Unsaved changes"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      // ---------- Backend / apply status ----------
      //
      // The one place the panel admits something went wrong. It has to live
      // outside the scroll area: an error you have to scroll to find is an
      // error you do not see.
      Item {
        id: statusStrip
        width: parent.width
        visible: root.applyFailed || (root.backendChecked && !root.backendInstalled)
        implicitHeight: visible ? statusText.implicitHeight + Style.space(10) : 0

        readonly property bool blocking: root.backendChecked && !root.backendInstalled

        BorderSurface {
          anchors.fill: parent
          color: Util.alpha(root.urgent, 0.10)
          borderSpec: Border.flat(Util.alpha(root.urgent, 0.5), Style.normalBorderWidth)
          radius: Style.cornerRadius
        }

        Text {
          id: statusText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: retryButton.visible ? retryButton.left : parent.right
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: statusStrip.blocking
            ? "Backend not installed — rules and charge limits cannot be applied.\nRun: sudo ~/.config/omarchy/plugins/" + root.moduleName + "/extras/install.sh"
            : root.applyMessage
          color: root.fg
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          id: retryButton
          visible: root.applyState === "cancelled" || root.applyState === "write-failed"
          text: "Retry"
          fontSize: Style.font.caption
          foreground: root.fg
          fontFamily: root.uiFont
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xs
          bordered: true
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.applyChanges()
        }
      }

      // ---------- Surface switcher ----------
      //
      // Always lists the two surfaces you are *not* on. That is what keeps it
      // from being a tab bar: there is no "you are here" to highlight, so it
      // reads as chrome at the foot rather than navigation at the head, and
      // the top of the panel stays pure content — the way every first-party
      // Omarchy panel opens.
      Column {
        id: switcher
        width: parent.width
        spacing: Style.space(10)

        PanelSeparator { foreground: root.fg }

        Item {
          width: parent.width
          implicitHeight: Math.max(switchLeft.implicitHeight, switchRight.implicitHeight)

          SwitchLink {
            id: switchLeft
            slot: 0
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          SwitchLink {
            id: switchRight
            slot: 1
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
      }

      // ---------- Reset confirmation ----------
      ConfirmDialog {
        id: resetDialog
        anchors.fill: parent
        opened: root.resetPending
        message: "Reset every Power Manager setting to its default?"
        confirmText: "Reset"
        foreground: root.fg
        fontFamily: root.uiFont
        onCanceled: root.resetPending = false
        onConfirmed: root.confirmReset()
      }
    }
  }

  property bool resetPending: false

  // ══════════════════════════════════════════════════════════════════════════
  // Tab: Battery
  // ══════════════════════════════════════════════════════════════════════════
  Component {
    id: batteryTab

    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      // ---------- Hero ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

        Text {
          id: heroIcon
          textFormat: Text.PlainText
          text: root.batteryIcon()
          color: root.fg
          font.family: root.uiFont
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: heroPercent.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "Battery"
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          // Cross-faded so the rotating phrase reads as one line changing its
          // mind rather than a hard cut every few seconds.
          Text {
            id: heroStatus
            textFormat: Text.PlainText
            property string pending: root.heroStatusText.toUpperCase()
            onPendingChanged: phraseSwap.restart()
            Component.onCompleted: text = pending
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            width: parent.width

            SequentialAnimation {
              id: phraseSwap
              NumberAnimation { target: heroStatus; property: "opacity"; to: 0.0; duration: 160; easing.type: Easing.OutQuad }
              ScriptAction { script: heroStatus.text = heroStatus.pending }
              NumberAnimation { target: heroStatus; property: "opacity"; to: 1.0; duration: 240; easing.type: Easing.InQuad }
            }
          }
        }

        Text {
          id: heroPercent
          textFormat: Text.PlainText
          text: root.batteryPresent ? Math.round(root.batteryFrac * 100) + "%" : "—"
          color: root.fg
          font.family: root.uiFont
          font.pixelSize: Style.font.displayLarge
          font.bold: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // ---------- Charge bar ----------
      Item {
        width: parent.width
        implicitHeight: Style.space(8)
        visible: root.batteryPresent

        Rectangle {
          id: barTrack
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Style.selectedFillFor(root.fg, Color.accent)
        }

        Rectangle {
          anchors.left: barTrack.left
          anchors.verticalCenter: barTrack.verticalCenter
          height: barTrack.height
          radius: barTrack.radius
          color: root.fg
          width: Math.max(barTrack.height, barTrack.width * root.batteryFrac)

          Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

          SequentialAnimation on opacity {
            running: root.charging && root.opened
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
          }
        }

        // The configured cut-off, marked on the track so the bar explains
        // itself when charging stops short of full.
        Rectangle {
          visible: tracker.supported && root.pendingLimit < 100
          width: Math.max(1, Style.space(2))
          height: barTrack.height + Style.space(4)
          color: root.dim
          anchors.verticalCenter: barTrack.verticalCenter
          x: Math.max(0, Math.min(barTrack.width - width, barTrack.width * (root.pendingLimit / 100) - width / 2))
        }
      }

      // ---------- Stats ----------
      //
      // Six readouts; three of them are also the panel's disclosure triggers.
      // Every row reserves the chevron slot so the values stay aligned down
      // both columns whether or not a given row opens anything.
      Row {
        visible: root.batteryPresent
        width: parent.width
        spacing: Style.space(20)

        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.spacing.hairline
          StatRow { label: "Battery size"; value: root.batteryInfo.size || "—" }
          StatRow { label: "Charge cycles"; value: tracker.cycleCount > 0 ? String(tracker.cycleCount) : "—" }
          StatRow {
            label: "Health"
            value: tracker.healthPct > 0 ? tracker.healthPct.toFixed(0) + "%" : "—"
            statKey: "health"
          }
        }

        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.spacing.hairline
          StatRow {
            label: root.discharging ? "Time left" : "Time to full"
            value: root.batteryTimeLabel
          }
          StatRow {
            label: root.discharging ? "Discharging" : "Charging"
            value: root.powerDrawLabel
            statKey: "power"
          }
          StatRow {
            label: "Charge limit"
            value: tracker.supported ? (tracker.applying ? "…" : Model.chargeLimitLabel(root.pendingLimit)) : "n/a"
            statKey: "limit"
          }
        }
      }

      // ---------- Whichever stat is open ----------
      //
      // One slot, directly under the grid, for whichever row was clicked.
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.expandedStat !== ""

        PanelSeparator { foreground: root.fg }

        // Charge limit — pills, applied on click.
        Grid {
          id: limitRow
          width: parent.width
          visible: root.expandedStat === "limit"
          columns: Model.chargeLimitOptions().length
          spacing: Style.spacing.xs

          readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

          Repeater {
            model: Model.chargeLimitOptions()

            Button {
              required property var modelData
              required property int index
              readonly property int limitValue: Number(modelData)
              width: limitRow.cellWidth
              text: Model.chargeLimitLabel(limitValue)
              fontSize: Style.font.caption
              foreground: root.fg
              fontFamily: root.uiFont
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              active: root.pendingLimit === limitValue
              hasCursor: root.cursorOn("limitpills", index)
              onClicked: root.setChargeLimit(limitValue)
              onHovered: function(h) { if (h) root.pointCursor("limitpills", index) }
            }
          }
        }

        // Health — one point per day, so the axis is calendar time.
        Sparkline {
          width: parent.width
          visible: root.expandedStat === "health" && tracker.healthHistory.length >= 2
          points: {
            var out = []
            var h = tracker.healthHistory
            for (var i = 0; i < h.length; i++) out.push({ x: Date.parse(h[i].date), y: h[i].health })
            return out
          }
          // Wear moves by fractions of a percent, so a zero-based axis would
          // draw every battery as the same flat line at the top.
          zeroBased: false
        }

        // Power draw — one point per sample, so the axis is just sample order.
        Sparkline {
          width: parent.width
          visible: root.expandedStat === "power" && root.powerSamples.length >= 2
          points: {
            var out = []
            var p = root.powerSamples
            for (var i = 0; i < p.length; i++) out.push({ x: i, y: p[i] })
            return out
          }
          // Watts are a magnitude: anchoring at zero keeps the height of the
          // trace honest instead of magnifying noise around a steady draw.
          zeroBased: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.expandedStat !== "" && text !== ""
          text: {
            if (root.expandedStat === "limit") {
              return root.pendingLimit >= 100
                ? "No limit — the battery charges to full."
                : "Charging stops at " + root.pendingLimit + "%, set in the battery firmware."
            }
            if (root.expandedStat === "health") {
              var h = tracker.healthHistory
              if (h.length < 2) {
                return h.length === 1
                  ? "Logging started today — a trend needs a few more days."
                  : "Waiting for the first health reading."
              }
              var a = h[0], b = h[h.length - 1]
              var dh = b.health - a.health
              var span = Math.round((Date.parse(b.date) - Date.parse(a.date)) / 86400000)
              var out = (dh >= 0 ? "+" : "") + dh.toFixed(1) + "% over " + span + " day" + (span === 1 ? "" : "s")
              if (a.cycles >= 0 && b.cycles >= a.cycles) out += " · +" + (b.cycles - a.cycles) + " cycles"
              return out
            }
            if (root.expandedStat === "power") {
              var p = root.powerSamples
              if (p.length < 2) return "Collecting — the trace fills in over the next few minutes."
              var sum = 0, peak = 0
              for (var i = 0; i < p.length; i++) { sum += p[i]; if (p[i] > peak) peak = p[i] }
              var mins = Math.round(p.length * root.powerSampleSeconds / 60)
              return "avg " + (sum / p.length).toFixed(1) + "W · peak " + peak.toFixed(1) + "W · last "
                + (mins < 1 ? "minute" : mins + " min")
            }
            return ""
          }
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.expandedStat === "health" && tracker.cycleCount === 0
          text: "Cycle count is not reported by this battery's firmware."
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---------- Power profile ----------
      PanelSeparator { foreground: root.fg; visible: root.profiles.length > 0 }

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.profiles.length > 0

        PanelSectionHeader {
          text: "POWER PROFILE"
          foreground: root.fg
          fontFamily: root.uiFont
        }

        Grid {
          id: profileRow
          width: parent.width
          columns: Math.max(1, root.profiles.length)
          spacing: Style.spacing.xs

          readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

          Repeater {
            model: root.profiles

            Button {
              required property var modelData
              required property int index
              width: profileRow.cellWidth
              iconText: Model.profileIcon(String(modelData))
              iconSize: Style.font.title
              text: Model.profileLabel(modelData)
              fontSize: Style.font.caption
              foreground: root.fg
              fontFamily: root.uiFont
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.activeProfile === modelData
              hasCursor: root.cursorOn("profiles", index)
              onClicked: root.setSystemProfile(modelData)
              onHovered: function(h) { if (h) root.pointCursor("profiles", index) }
            }
          }
        }
      }

      // ---------- Brightness (only when nothing else owns it) ----------
      PanelSeparator { foreground: root.fg; visible: root.showBrightness }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.showBrightness

        Item {
          width: parent.width
          implicitHeight: brightnessHeader.implicitHeight

          PanelSectionHeader {
            id: brightnessHeader
            text: "BRIGHTNESS"
            foreground: root.fg
            fontFamily: root.uiFont
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.currentBrightness) + "%"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          height: brightnessSlider.implicitHeight + Style.spacing.controlGap
          hasCursor: root.cursorOn("brightness", 0)
          foreground: root.fg
          outline: true

          PanelSlider {
            id: brightnessSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 1
            maximum: 100
            step: 1
            integer: true
            value: root.currentBrightness
            onMoved: function(v) { root.setBrightness(v) }
            onReleased: function(v) { brightnessReadProc.running = true }
          }

          HoverHandler {
            onHoveredChanged: if (hovered) root.pointCursor("brightness", 0)
          }
        }
      }

      Item { width: 1; height: Style.space(2) }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Tab: Rules
  //
  // The backend keeps three parallel rulesets (AC / battery / low battery).
  // Showing all three at once produced fifteen rows of near-identical labels,
  // so the tab shows one state at a time and the chips carry the comparison.
  // ══════════════════════════════════════════════════════════════════════════
  Component {
    id: rulesTab

    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      // ---------- State picker ----------
      Column {
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: stateHeader.implicitHeight

          PanelSectionHeader {
            id: stateHeader
            text: "WHEN RUNNING ON"
            foreground: root.fg
            fontFamily: root.uiFont
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: "NOW"
            visible: root.ruleState === root.currentStateKey
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Grid {
          id: stateRow
          width: parent.width
          columns: Model.powerStates().length
          spacing: Style.spacing.xs

          readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

          Repeater {
            model: Model.powerStates()

            Button {
              required property var modelData
              required property int index
              width: stateRow.cellWidth
              iconText: modelData.icon
              iconSize: Style.font.body
              text: modelData.label
              fontSize: Style.font.caption
              foreground: root.fg
              fontFamily: root.uiFont
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
              bordered: true
              selected: root.ruleState === modelData.key
              hasCursor: root.cursorOn("states", index)
              onClicked: root.ruleState = modelData.key
              onHovered: function(h) { if (h) root.pointCursor("states", index) }
            }
          }
        }
      }

      PanelSeparator { foreground: root.fg }

      // ---------- Per-state rules ----------
      Column {
        width: parent.width
        spacing: Style.space(6)

        SelectRow {
          label: "Power profile"
          options: Model.profileOptions()
          configKey: "profiles." + root.ruleState
        }

        NumberRow {
          label: "Screen brightness (%)"
          visible: root.showAutoBrightness
          from: 0
          to: 100
          configKey: "brightness." + root.ruleState
        }

        NumberRow {
          label: "Sleep after (min)"
          from: 0
          to: 600
          configKey: "idle." + root.ruleState + ".sleepAfterMinutes"
        }

        SelectRow {
          label: "Then"
          options: Model.actionOptions()
          configKey: "idle." + root.ruleState + ".afterSleep"
        }

        // Only means anything for suspend-then-hibernate, which is the one
        // action that reads HibernateDelaySec.
        NumberRow {
          label: "Hibernate after (min)"
          visible: {
            var _ = root.editConfig
            return root.getVal("idle." + root.ruleState + ".afterSleep", "") === "suspend-then-hibernate"
          }
          from: 1
          to: 1440
          configKey: "idle." + root.ruleState + ".hibernateAfterMinutes"
        }

        SelectRow {
          label: "Closing the lid"
          enabled: {
            var _ = root.editConfig
            return root.getVal("lid.ignoreLidClose", false) !== true
          }
          options: Model.actionOptions()
          configKey: "lid." + root.ruleState + ".action"
        }
      }

      PanelSeparator { foreground: root.fg }

      // ---------- Global ----------
      Column {
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "EVERY STATE"
          foreground: root.fg
          fontFamily: root.uiFont
        }

        Item { width: 1; height: Style.space(2) }

        SwitchRow {
          label: "Automatic management"
          description: "Switch profiles and rules as power changes"
          configKey: "enabled"
        }

        NumberRow {
          label: "Low battery below (%)"
          from: 5
          to: 95
          configKey: "batteryThreshold"
        }

        SwitchRow {
          label: "Ignore the lid"
          description: "Never sleep on lid close, on any power source"
          configKey: "lid.ignoreLidClose"
        }

        SwitchRow {
          label: "Automatic brightness"
          description: "Apply the per-state brightness above"
          visible: root.showAutoBrightness
          configKey: "brightness.auto"
        }
      }

      Item { width: 1; height: Style.space(2) }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Tab: System
  // ══════════════════════════════════════════════════════════════════════════
  Component {
    id: systemTab

    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      Component.onCompleted: if (!diagnosticsProc.running) diagnosticsProc.running = true

      // ---------- Hibernation ----------
      Column {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: parent.width
          implicitHeight: hibHeader.implicitHeight

          PanelSectionHeader {
            id: hibHeader
            text: "HIBERNATION"
            foreground: root.fg
            fontFamily: root.uiFont
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: Model.hibernationReady(root.diagnosticsData) ? "READY" : "NOT READY"
            color: Model.hibernationReady(root.diagnosticsData) ? root.dim : root.urgent
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        DiagRow {
          ok: !!(root.diagnosticsData.swap && root.diagnosticsData.swap.adequate_for_hibernate)
          label: "Swap space"
          detail: ok ? "Adequate" : "Too small"
        }
        DiagRow {
          ok: !!root.diagnosticsData.hibernate_available
          label: "Hibernate service"
          detail: ok ? "Available" : "Missing"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.resume && root.diagnosticsData.resume.kernel_cmdline_has_resume)
          label: "Kernel resume="
          detail: ok ? "Configured" : "Not in cmdline"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.resume_hook_present)
          label: "Initramfs hook"
          detail: ok ? "Present" : "Missing"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.hook_order_correct)
          label: "Hook order"
          detail: ok ? "Correct" : "Wrong order"
        }
      }

      PanelSeparator { foreground: root.fg }

      // ---------- Sleep states ----------
      Column {
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "SLEEP STATES"
          foreground: root.fg
          fontFamily: root.uiFont
        }

        DiagRow {
          ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.freeze)
          label: "Freeze"
          detail: "Idle standby"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.mem)
          label: "Suspend"
          detail: "RAM stays powered"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.disk)
          label: "Hibernate"
          detail: "Written to disk"
        }
        DiagRow {
          ok: !!root.diagnosticsData.suspend_then_hibernate_available
          label: "Suspend → hibernate"
          detail: "Chained sleep"
        }
      }

      PanelSeparator { foreground: root.fg }

      // ---------- Backend ----------
      Column {
        width: parent.width
        spacing: Style.spacing.labelGap

        PanelSectionHeader {
          text: "BACKEND"
          foreground: root.fg
          fontFamily: root.uiFont
        }

        Item { width: 1; height: Style.space(2) }

        InfoPair {
          label: "Profile backend"
          value: (root.diagnosticsData.power_profiles && root.diagnosticsData.power_profiles.backend) || "—"
        }
        InfoPair {
          label: "Active profile"
          value: root.activeProfile || "—"
        }
        InfoPair {
          label: "Lid switch"
          value: (root.diagnosticsData.logind && root.diagnosticsData.logind.handle_lid_switch) || "—"
        }
        InfoPair {
          label: "Lid switch (AC)"
          value: (root.diagnosticsData.logind && root.diagnosticsData.logind.handle_lid_switch_external_power) || "—"
        }
        InfoPair {
          label: "Brightness owner"
          value: root.displayPluginMatch || "This plugin"
        }
        InfoPair {
          label: "Privileged backend"
          value: !root.backendChecked ? "…" : (root.backendInstalled ? "Installed" : "Not installed")
        }
      }

      PanelSeparator { foreground: root.fg }

      // ---------- Appearance ----------
      Column {
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "APPEARANCE"
          foreground: root.fg
          fontFamily: root.uiFont
        }

        Item { width: 1; height: Style.space(2) }

        Item {
          width: parent.width
          implicitHeight: Math.max(pctLabel.implicitHeight, pctSwitch.implicitHeight)

          Column {
            id: pctLabel
            anchors.left: parent.left
            anchors.right: pctSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Percentage in the bar"
              color: root.fg
              font.family: root.uiFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Right-click the bar icon to toggle"
              color: root.dim
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          ToggleSwitch {
            id: pctSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.fg
            checked: root.showPercentage
            onToggled: root.togglePercentage()
          }
        }
      }

      PanelSeparator { foreground: root.fg }

      Button {
        width: parent.width
        text: "Reset all settings"
        iconText: "󰦛"
        iconSize: Style.font.body
        fontSize: Style.font.bodySmall
        foreground: root.urgent
        accent: root.urgent
        fontFamily: root.uiFont
        verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
        bordered: true
        hasCursor: root.cursorOn("reset", 0)
        onClicked: root.resetPending = true
        onHovered: function(h) { if (h) root.pointCursor("reset", 0) }
      }

      Item { width: 1; height: Style.space(2) }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Reusable rows
  // ══════════════════════════════════════════════════════════════════════════

  // A stat readout that may also be a door. Non-expandable rows are plain
  // text; expandable ones take the shared hover-cursor fill, a pointing
  // cursor, and a chevron after the value that rotates when open.
  //
  // Every row reserves the chevron slot whether or not it uses it, so values
  // stay aligned down the column.
  component StatRow: Item {
    id: statRow
    property string label: ""
    property string value: ""
    // Empty means "just a readout". Otherwise it is the accordion key.
    property string statKey: ""

    readonly property bool expandable: statKey !== "" && root.statExpandable(statKey)
    readonly property bool open: expandable && root.expandedStat === statKey
    readonly property bool cursored: expandable
      && root.cursorActive && root.focusSection === "stats"
      && root.statDoors()[root.selectedIndex] === statKey
    readonly property bool hot: expandable && (statMouse.containsMouse || cursored)

    width: parent ? parent.width : 0
    implicitHeight: statValue.implicitHeight + Style.space(5)

    CursorSurface {
      anchors.fill: parent
      visible: statRow.expandable
      hasCursor: statRow.hot
      foreground: root.fg
    }

    Text {
      id: statLabel
      textFormat: Text.PlainText
      text: statRow.label
      color: root.fg
      // Plain readouts stay recessive at 0.6; a door sits at full strength so
      // the three clickable rows separate from the three that just report.
      // No underline: it collides with the descenders in "Discharging" and
      // "Charge limit", and it would be the only hyperlink idiom in the panel.
      opacity: statRow.expandable ? 1.0 : 0.6
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3)
      anchors.right: statValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight

      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Text {
      id: statValue
      textFormat: Text.PlainText
      text: statRow.value
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
      anchors.right: statChevron.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: statChevron
      textFormat: Text.PlainText
      text: "󰅀"
      visible: statRow.expandable
      color: statRow.hot || statRow.open
        ? Style.hoverStateColor(root.fg, Color.accent)
        : root.dim
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
      width: Style.space(12)
      horizontalAlignment: Text.AlignHCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      rotation: statRow.open ? 180 : 0

      Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    MouseArea {
      id: statMouse
      anchors.fill: parent
      enabled: statRow.expandable
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: {
        if (!containsMouse || !statRow.expandable) return
        var idx = root.statDoors().indexOf(statRow.statKey)
        if (idx >= 0) root.pointCursor("stats", idx)
      }
      onClicked: root.toggleStat(statRow.statKey)
    }
  }

  // Shared line chart for the two traces. `points` is [{x, y}]; x is only used
  // for spacing, so callers can pass timestamps (health, one point per day) or
  // plain indices (power, one point per sample) without the component caring.
  component Sparkline: Canvas {
    id: spark
    property var points: []
    property bool zeroBased: false
    property color lineColor: root.fg
    property color fillColor: Util.alpha(lineColor, 0.10)

    height: Style.space(48)

    onPointsChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var p = spark.points
      if (!p || p.length < 2) return

      var lo = spark.zeroBased ? 0 : p[0].y
      var hi = p[0].y
      for (var i = 1; i < p.length; i++) {
        if (p[i].y < lo && !spark.zeroBased) lo = p[i].y
        if (p[i].y > hi) hi = p[i].y
      }
      // Headroom so the trace never rides flat against an edge.
      if (spark.zeroBased) hi = hi * 1.15 + 0.001
      else { lo -= 0.5; hi += 0.5 }
      var span = Math.max(0.0001, hi - lo)

      var x0 = p[0].x
      var dx = Math.max(1, p[p.length - 1].x - x0)
      var pad = 2
      function px(i) { return (p[i].x - x0) / dx * (spark.width - pad * 2) + pad }
      function py(i) { return spark.height - 3 - (p[i].y - lo) / span * (spark.height - 6) }

      // Fill under the line first, so the stroke sits on top of its own edge.
      ctx.beginPath()
      ctx.moveTo(px(0), spark.height)
      for (var a = 0; a < p.length; a++) ctx.lineTo(px(a), py(a))
      ctx.lineTo(px(p.length - 1), spark.height)
      ctx.closePath()
      ctx.fillStyle = String(spark.fillColor)
      ctx.fill()

      ctx.strokeStyle = String(spark.lineColor)
      ctx.lineWidth = Math.max(1, Style.space(2) / 2)
      ctx.lineJoin = "round"
      ctx.beginPath()
      for (var b = 0; b < p.length; b++) {
        if (b === 0) ctx.moveTo(px(b), py(b))
        else ctx.lineTo(px(b), py(b))
      }
      ctx.stroke()
    }
  }

  // One entry in the foot-of-panel switcher. Dim at rest so it reads as chrome;
  // Button's own `hot` covers mouse hover and the keyboard cursor together.
  component SwitchLink: Button {
    property int slot: 0
    readonly property var entry: slot < root.otherTabs.length ? root.otherTabs[slot] : null

    visible: !!entry
    text: entry ? entry.label : ""
    iconText: entry ? entry.icon : ""
    tooltipText: entry ? entry.label + "  (" + (root.tabIndexOf(entry.value) + 1) + ")" : ""
    iconSize: Style.font.body
    fontSize: Style.font.caption
    foreground: hot ? root.fg : root.dim
    fontFamily: root.uiFont
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.xs
    hasCursor: root.cursorOn("switcher", slot)
    onClicked: if (entry) root.selectTab(entry.value)
    onHovered: function(isHovered) { if (isHovered) root.pointCursor("switcher", slot) }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.fg
      opacity: 0.6
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      id: pairValue
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
    }
  }

  // One diagnostic check: state glyph, what it is, what it says. Failures are
  // the only place urgent shows up in the panel.
  component DiagRow: Item {
    id: diagRow
    property bool ok: false
    property string label: ""
    property string detail: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(diagGlyph.implicitHeight, diagLabel.implicitHeight)

    Text {
      id: diagGlyph
      textFormat: Text.PlainText
      text: diagRow.ok ? "󰄬" : "󰅖"
      color: diagRow.ok ? root.fg : root.urgent
      opacity: diagRow.ok ? 0.7 : 1.0
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
      width: Style.space(18)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: diagLabel
      textFormat: Text.PlainText
      text: diagRow.label
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
      anchors.left: diagGlyph.right
      anchors.right: diagDetail.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Text {
      id: diagDetail
      textFormat: Text.PlainText
      text: diagRow.detail
      color: diagRow.ok ? root.dim : root.urgent
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Form rows. Each one owns a config key and stages its edit into editConfig;
  // nothing here writes to disk. The trailing control column is a fixed width
  // so every control on the tab lines up.
  component SelectRow: Item {
    id: selectRow
    property string label: ""
    property string configKey: ""
    property var options: []
    readonly property string currentValue: {
      var _ = root.editConfig
      return String(root.getVal(selectRow.configKey, ""))
    }

    width: parent ? parent.width : 0
    implicitHeight: Style.spacing.controlHeight + Style.space(4)
    opacity: enabled ? 1.0 : 0.45

    Text {
      textFormat: Text.PlainText
      text: selectRow.label
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.right: selectDropdown.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Dropdown {
      id: selectDropdown
      width: root.formControlWidth
      height: Style.spacing.controlHeight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      showLabel: false
      enabled: selectRow.enabled
      rowHeight: Style.spacing.controlHeight
      foreground: root.fg
      fontFamily: root.uiFont
      options: selectRow.options
      onChanged: function(v) { root.setVal(selectRow.configKey, v) }
      onPopupOpenChanged: root.dropdownOpen = Math.max(0, root.dropdownOpen + (popupOpen ? 1 : -1))
      Component.onDestruction: if (popupOpen) root.dropdownOpen = Math.max(0, root.dropdownOpen - 1)
    }

    // Dropdown assigns its own `value` on selection, which would clobber a
    // plain binding. A Binding object re-asserts whenever the config changes
    // underneath — a revert, a reset, or a switch to another power state.
    Binding {
      target: selectDropdown
      property: "value"
      value: selectRow.currentValue
    }
  }

  component NumberRow: Item {
    id: numberRow
    property string label: ""
    property string configKey: ""
    property int from: 0
    property int to: 100
    readonly property int currentValue: {
      var _ = root.editConfig
      return parseInt(root.getVal(numberRow.configKey, 0)) || 0
    }

    width: parent ? parent.width : 0
    implicitHeight: Style.spacing.controlHeight + Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: numberRow.label
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.right: numberField.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    NumberField {
      id: numberField
      width: root.formControlWidth
      fieldWidth: root.formControlWidth
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      from: numberRow.from
      to: numberRow.to
      foreground: root.fg
      fontFamily: root.uiFont
      fontSize: Style.font.bodySmall
      onModified: function(v) { root.setVal(numberRow.configKey, v) }
    }

    // Same reason as SelectRow: the SpinBox writes its own value while the
    // user types, so the outside world reaches it through a Binding.
    Binding {
      target: numberField.field
      property: "value"
      value: numberRow.currentValue
    }
  }

  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string description: ""
    property string configKey: ""
    readonly property bool currentValue: {
      var _ = root.editConfig
      return root.getVal(switchRow.configKey, false) === true
    }

    width: parent ? parent.width : 0
    implicitHeight: Math.max(switchLabels.implicitHeight, switchControl.implicitHeight) + Style.space(4)

    Column {
      id: switchLabels
      anchors.left: parent.left
      anchors.right: switchControl.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: switchRow.label
        color: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: switchRow.description !== ""
        text: switchRow.description
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: switchControl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.fg
      checked: switchRow.currentValue
      onToggled: root.setVal(switchRow.configKey, !switchRow.currentValue)
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Hosts
  // ══════════════════════════════════════════════════════════════════════════

  // A text field or an open dropdown owns the keyboard while it is active; the
  // panel's own h/j/k/l handling stands down so typing works.
  function isTextEditor(item) {
    if (!item) return false
    return item.cursorPosition !== undefined && item.selectedText !== undefined
  }

  // ---------- Bar popup ----------
  KeyboardPanel {
    id: popupPanel
    anchorItem: barBtn
    owner: root
    bar: root.bar
    open: root.opened && !root.openedFromMenu
    focusTarget: popupKeys
    contentWidth: popupPanel.fittedContentWidth(root.panelWidth)
    contentHeight: popupPanel.fittedContentHeight(popupBody.item ? popupBody.item.bodyImplicitHeight : Style.space(320), Style.space(600))

    PanelKeyCatcher {
      id: popupKeys
      anchors.fill: parent
      blocked: root.dropdownOpen > 0 || root.isTextEditor(popupPanel.activeFocusItem)
      onMoveRequested: function(dx, dy) {
        if (root.resetPending) return
        // The first keypress only reveals the cursor, so you can see where you
        // are before you start walking.
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) { root.moveCursorH(dx); return }
        // moveCursor reports false at the ends; the key then scrolls instead of
        // being swallowed, so a tab taller than the panel stays reachable.
        if (dy !== 0 && !root.moveCursor(dy) && popupBody.item) popupBody.item.scrollBy(dy * Style.space(56))
      }
      onCloseRequested: root.resetPending ? root.resetPending = false : root.close()
      onActivateRequested: root.resetPending ? root.confirmReset() : root.activateCursor()
      onTabRequested: function(direction) { if (!root.resetPending) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.resetPending) return
        // h/l belongs to the cursor now, so tabs moved to the number row.
        var tabIndex = ["1", "2", "3"].indexOf(t)
        if (tabIndex >= 0 && tabIndex < root.tabs.length) {
          root.selectTab(root.tabs[tabIndex].value)
          return
        }
        if (t === "a" && root.configDirty) root.applyChanges()
      }

      Loader {
        id: popupBody
        anchors.fill: parent
        sourceComponent: panelBody
      }
    }
  }

  // ---------- Standalone window (summoned from the Omarchy menu) ----------
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

    BorderSurface {
      id: windowCard
      anchors.centerIn: parent
      width: Math.min(root.windowWidth, windowPanel.width - Style.space(32))
      height: Math.min(
        (windowBody.item ? windowBody.item.bodyImplicitHeight : Style.space(320)) + windowCard.contentTopInset + windowCard.contentBottomInset,
        windowPanel.height - Style.space(64))
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: windowKeys
        anchors.fill: parent
        anchors.topMargin: windowCard.contentTopInset
        anchors.rightMargin: windowCard.contentRightInset
        anchors.bottomMargin: windowCard.contentBottomInset
        anchors.leftMargin: windowCard.contentLeftInset
        blocked: root.dropdownOpen > 0 || root.isTextEditor(windowPanel.activeFocusItem)
        onMoveRequested: function(dx, dy) {
          if (root.resetPending) return
          // The first keypress only reveals the cursor, so you can see where you
          // are before you start walking.
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dx !== 0) { root.moveCursorH(dx); return }
          // moveCursor reports false at the ends; the key then scrolls instead of
          // being swallowed, so a tab taller than the panel stays reachable.
          if (dy !== 0 && !root.moveCursor(dy) && windowBody.item) windowBody.item.scrollBy(dy * Style.space(56))
        }
        onCloseRequested: root.resetPending ? root.resetPending = false : root.close()
        onActivateRequested: root.resetPending ? root.confirmReset() : root.activateCursor()
        onTextKey: function(t) {
          if (root.resetPending) return
          // h/l belongs to the cursor now, so tabs moved to the number row.
          var tabIndex = ["1", "2", "3"].indexOf(t)
          if (tabIndex >= 0 && tabIndex < root.tabs.length) {
            root.selectTab(root.tabs[tabIndex].value)
            return
          }
          if (t === "a" && root.configDirty) root.applyChanges()
        }

        Loader {
          id: windowBody
          anchors.fill: parent
          sourceComponent: panelBody
        }
      }
    }
  }

}
