import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property string batteryPath: ""
  property bool present: false
  property int capacity: -1
  property string status: ""
  property int cycleCount: -1
  property real full: -1
  property real fullDesign: -1
  property string capacityUnit: "Wh"
  readonly property real healthPct: (full > 0 && fullDesign > 0) ? (full / fullDesign * 100) : -1

  property bool supported: false
  property int limit: 100
  signal limitSyncRequired(int limit)
  property bool applying: false
  property bool justApplied: false
  readonly property string tmpfilesPath: "/etc/tmpfiles.d/90-power-advanced-limit.conf"

  property string lastLogDate: ""
  property var healthHistory: []

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/kurisu-null.power-advanced"
  readonly property string healthLog: stateDir + "/health-log.tsv"

  function refresh() { if (!probe.running) probe.running = true }

  function validPath(p) {
    return /^\/sys\/class\/power_supply\/[A-Za-z0-9_][A-Za-z0-9_.:@-]*$/.test(p)
  }

  function parseProbe(raw) {
    var path = "", vals = {}
    var lines = raw.split("\n")
    for (var j = 0; j < lines.length; j++) {
      var eq = lines[j].indexOf("=")
      if (eq <= 0) continue
      vals[lines[j].slice(0, eq)] = lines[j].slice(eq + 1).trim()
    }
    path = vals.path || ""
    if (!root.validPath(path)) {
      root.present = false
      root.batteryPath = ""
      return
    }
    var num = function(key) {
      var n = parseInt(vals[key], 10)
      return isNaN(n) ? -1 : n
    }
    root.batteryPath = path
    root.present = true
    root.supported = "limit" in vals
    
    var oldLimit = root.limit
    if (num("limit") >= 1 && num("limit") <= 100) root.limit = num("limit")
    
    if (root.justApplied) {
      root.justApplied = false
      if (root.limit === oldLimit) root.limitSyncRequired(root.limit)
    }

    root.capacity = num("capacity")
    root.status = (vals.status || "").slice(0, 32)
    root.cycleCount = num("cycle_count")
    
    var energy = num("energy_full") > 0 && num("energy_full_design") > 0
    root.capacityUnit = energy ? "Wh" : "Ah"
    root.full = energy ? num("energy_full") : num("charge_full")
    root.fullDesign = energy ? num("energy_full_design") : num("charge_full_design")
    root.logHealth()
  }

  function setLimit(pct) {
    pct = parseInt(pct, 10)
    console.log("setLimit called with pct:", pct)
    if (isNaN(pct) || pct < 50 || pct > 100) return
    console.log("root.supported:", root.supported, "batteryPath:", root.batteryPath, "applyProc.running:", applyProc.running)
    if (!root.supported || !root.validPath(root.batteryPath) || applyProc.running) return
    root.applying = true
    applyProc.pct = pct
    applyProc.command = ["pkexec", "/usr/local/libexec/omarchy-power-advanced/power-advanced-limit", String(pct), root.batteryPath, root.tmpfilesPath]
    console.log("Executing command:", applyProc.command)
    applyProc.running = true
  }


  function logHealth() {
    if (root.healthPct <= 0 || appendProc.running) return
    var today = new Date().toISOString().slice(0, 10)
    if (root.lastLogDate === today) return
    root.lastLogDate = today
    appendProc.command = ["sh", "-c",
      "d=\"${1%/*}\"; mkdir -p \"$d\" 2>/dev/null || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 1 \"$1\" | grep -q \"^$2\"; } && exit 0; " +
      "tmp=$(mktemp \"$d/.health-XXXXXX\") || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\"; " +
      "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\"; } > \"$tmp\" " +
      "&& mv -f \"$tmp\" \"$1\" || rm -f \"$tmp\"",
      "sh", root.healthLog, today, root.healthPct.toFixed(1),
      String(root.cycleCount), String(root.full), String(root.fullDesign), root.capacityUnit]
    appendProc.running = true
  }

  function parseHistory(raw) {
    var out = []
    var lines = raw.split("\n")
    for (var j = 0; j < lines.length && out.length < 400; j++) {
      var p = lines[j].split("\t")
      if (p.length < 3 || !/^\d{4}-\d{2}-\d{2}$/.test(p[0])) continue
      var h = parseFloat(p[1])
      var c = parseInt(p[2], 10)
      if (!(h > 0 && h <= 200)) continue
      out.push({ date: p[0], health: h, cycles: isNaN(c) ? -1 : c })
    }
    root.healthHistory = out
  }

  Component.onCompleted: {
    historyProc.running = true
    refresh()
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: probe
    command: ["sh", "-c",
      "{ b=''; for d in /sys/class/power_supply/*; do [ -f \"$d/charge_control_end_threshold\" ] && b=\"$d\" && break; done; " +
      "if [ -z \"$b\" ]; then for d in /sys/class/power_supply/*; do { [ -f \"$d/energy_full_design\" ] || [ -f \"$d/charge_full_design\" ]; } && b=\"$d\" && break; done; fi; " +
      "[ -z \"$b\" ] && exit 0; echo \"path=$b\"; " +
      "[ -f \"$b/charge_control_end_threshold\" ] && echo \"limit=$(cat \"$b/charge_control_end_threshold\")\"; " +
      "for k in capacity status cycle_count energy_full energy_full_design charge_full charge_full_design; do " +
      "[ -f \"$b/$k\" ] && echo \"$k=$(cat \"$b/$k\")\"; done; true; } | head -c 4096"]
    stdout: StdioCollector {
      onStreamFinished: root.parseProbe(text.slice(0, 4096))
    }
  }

  Process {
    id: appendProc
    onExited: function(code, status) { historyProc.running = true }
  }

  Process {
    id: historyProc
    command: ["sh", "-c", "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\" || true; } | head -c 32768", "sh", root.healthLog]
    stdout: StdioCollector {
      onStreamFinished: root.parseHistory(text)
    }
  }

  Process {
    id: applyProc
    property int pct: 100
    onExited: function(code, status) {
      console.log("applyProc exited with code:", code, "status:", status)
      root.applying = false
      root.justApplied = true
      root.refresh()
      if (code === 0) {
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
          "Power Advanced", applyProc.pct === 100
            ? "Charge limit removed — stock behavior restored"
            : "Charge limit set to " + applyProc.pct + "%"])
      } else if (code !== 126) {
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
          "Power Advanced", "Could not set the charge limit (exit " + code + ")"])
      }
    }
  }
}
