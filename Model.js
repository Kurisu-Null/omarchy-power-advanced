// Model.js — Power Advanced helpers

function defaultConfig() {
  return {
    version: 1,
    enabled: true,
    batteryThreshold: 20,
    // HibernateDelaySec in /etc/systemd/sleep.conf.d is a single system-wide
    // value, so this is deliberately not per-state: logind reads the same
    // number whether suspend-then-hibernate was triggered by an idle timeout
    // or by the lid.
    hibernateAfterMinutes: 30,
    profiles: {
      ac: "performance",
      batteryHigh: "balanced",
      batteryLow: "power-saver"
    },
    brightness: {
      auto: false,
      ac: 80,
      batteryHigh: 50,
      batteryLow: 30,
      // Plugins that already own screen brightness. While any of these is in
      // the bar (or in shell.json's plugins[]), this plugin hides its own
      // brightness controls. Exact ids or `*.suffix` wildcards; [] disables
      // the behavior entirely. See "Display-plugin detection" below.
      deferToPlugins: ["omarchy.monitor", "*.hyprmoncfg"]
    },
    idle: {
      ac: {
        sleepAfterMinutes: 30,
        afterSleep: "suspend"
      },
      batteryHigh: {
        sleepAfterMinutes: 15,
        afterSleep: "suspend"
      },
      batteryLow: {
        sleepAfterMinutes: 5,
        afterSleep: "suspend"
      }
    },
    lid: {
      ignoreLidClose: false,
      ac: { action: "suspend" },
      batteryHigh: { action: "suspend" },
      batteryLow: { action: "suspend" }
    },
    appearance: {
      showPercentage: true
    },
    notifications: {
      // Fired by the panel when the battery falls past batteryThreshold.
      // The other keys that used to live here were never read by anything.
      thresholdCrossing: true
    }
  };
}

function deepMerge(target, source) {
  if (!source || typeof source !== 'object') return target;
  var result = {};
  var keys = Object.keys(target);
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    if (source.hasOwnProperty(k)) {
      if (target[k] && typeof target[k] === 'object' && !Array.isArray(target[k])
          && source[k] && typeof source[k] === 'object' && !Array.isArray(source[k])) {
        result[k] = deepMerge(target[k], source[k]);
      } else {
        result[k] = source[k];
      }
    } else {
      result[k] = target[k];
    }
  }
  var srcKeys = Object.keys(source);
  for (var j = 0; j < srcKeys.length; j++) {
    if (!target.hasOwnProperty(srcKeys[j])) {
      result[srcKeys[j]] = source[srcKeys[j]];
    }
  }
  return result;
}

function mergeWithDefaults(config) {
  return deepMerge(defaultConfig(), config || {});
}

function validateConfig(config) {
  var errors = [];
  if (!config) return { valid: false, errors: ["Config is null"] };
  if (config.batteryThreshold && (config.batteryThreshold < 5 || config.batteryThreshold > 95)) {
    errors.push("Battery threshold must be between 5 and 95");
  }
  return { valid: errors.length === 0, errors: errors };
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0;
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {};
  var s = states || {};
  if (!d.isPresent || onBattery) return false;
  var fraction = batteryFraction(d);
  if (d.state === s.Discharging) return false;
  if (d.state === s.PendingCharge) return true;
  if (d.state === s.FullyCharged && fraction < 0.99) return true;
  if (d.state !== s.Charging || fraction >= 0.99) return false;
  return false;
}

function batteryIcon(device, onBattery, states) {
  var d = device || {};
  if (!d.isPresent) return "";
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"];
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"];
  var index = Math.max(0, Math.min(9, Math.floor(batteryFraction(d) * 10)));
  var threshold = chargeThresholdActive(d, onBattery, states);
  if (threshold) return defaultIcons[index];
  if (d.state === states.FullyCharged) return "󰂅";
  if (!onBattery) return chargingIcons[index];
  return defaultIcons[index];
}

function modeLabel(device, onBattery, states) {
  var d = device || {};
  if (!d.isPresent) return "";
  var fraction = batteryFraction(d);
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold";
  if (onBattery) return "On battery";
  if (!onBattery && fraction >= 1) return "Fully charged";
  return "Charging";
}

function clampIndex(idx, len) {
  if (len === 0) return 0;
  if (idx < 0) return 0;
  if (idx >= len) return len - 1;
  return idx;
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n");
  var list = [];
  var active = "";
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    var parts = line.split("\t");
    list.push(parts[0]);
    if (parts[1] === "1") active = parts[0];
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  };
}

function selectProfileIndex(current, delta, profiles) {
  if (!profiles || profiles.length === 0) return 0;
  var next = current + delta;
  return clampIndex(next, profiles.length);
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪";
  if (name === "balanced") return "󰊚";
  if (name === "performance") return "󰓅";
  return "󰂄";
}

function parseKeyValue(raw) {
  var next = {};
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t");
    if (idx <= 0) continue;
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim();
  }
  return next;
}

function hibernationReady(diag) {
  if (!diag || typeof diag !== 'object') return false;
  var swap = diag.swap || {};
  var resume = diag.resume || {};
  var initramfs = diag.initramfs || {};
  return !!(swap.adequate_for_hibernate
    && diag.hibernate_available
    && resume.kernel_cmdline_has_resume
    && initramfs.resume_hook_present
    && initramfs.hook_order_correct);
}

function hibernationIssues(diag) {
  if (!diag || typeof diag !== 'object') return ["Diagnostics not loaded"];
  var issues = [];
  var swap = diag.swap || {};
  var resume = diag.resume || {};
  var initramfs = diag.initramfs || {};
  if (!swap.adequate_for_hibernate) issues.push("Swap insufficient for hibernation");
  if (!diag.hibernate_available) issues.push("Hibernate service not available");
  if (!resume.kernel_cmdline_has_resume) issues.push("Missing resume= in kernel cmdline");
  if (!initramfs.resume_hook_present) issues.push("Resume hook not in initramfs");
  if (!initramfs.hook_order_correct) issues.push("Initramfs hook order incorrect");
  return issues;
}

// ─────────────────────────────────────────────────────────────────────────────
// UI vocabulary
//
// The panel renders option lists straight from here so labels stay consistent
// between the Rules form, the tooltips, and any future surface. Values are the
// literal strings the backend scripts and systemd expect — only the labels are
// ours to prettify.
// ─────────────────────────────────────────────────────────────────────────────

function actionOptions() {
  return [
    { value: "ignore", label: "Do nothing" },
    { value: "suspend", label: "Suspend" },
    { value: "hybrid-sleep", label: "Hybrid sleep" },
    { value: "hibernate", label: "Hibernate" },
    { value: "suspend-then-hibernate", label: "Suspend → hibernate" },
    { value: "poweroff", label: "Power off" }
  ];
}

function profileOptions() {
  return [
    { value: "power-saver", label: "Power saver" },
    { value: "balanced", label: "Balanced" },
    { value: "performance", label: "Performance" }
  ];
}

function profileLabel(name) {
  var s = String(name || "");
  if (s === "") return "";
  return s.charAt(0).toUpperCase() + s.slice(1).replace(/-/g, " ");
}

// The three power states the backend switches between, in the order the state
// picker shows them. `key` indexes into config.profiles / config.idle / config.lid.
function powerStates() {
  return [
    { key: "ac", label: "AC", icon: "󰚥" },
    { key: "batteryHigh", label: "Battery", icon: "󰁹" },
    { key: "batteryLow", label: "Low", icon: "󰁻" }
  ];
}

function stateLabel(key) {
  var states = powerStates();
  for (var i = 0; i < states.length; i++) {
    if (states[i].key === key) return states[i].label;
  }
  return key;
}

// Which state the machine is in right now, given live UPower readings and the
// configured low-battery threshold. Mirrors power-advanced-profile-switch.
function currentStateKey(onBattery, fraction, thresholdPercent) {
  if (!onBattery) return "ac";
  var threshold = (Number(thresholdPercent) || 0) / 100.0;
  return fraction <= threshold ? "batteryLow" : "batteryHigh";
}

// Charge cut-offs offered as pills. 100 means "no limit" — the value the
// kernel wants when the limit is removed.
function chargeLimitOptions() {
  return [100, 60, 70, 80, 90];
}

function chargeLimitLabel(pct) {
  return pct >= 100 ? "Off" : pct + "%";
}

// ─────────────────────────────────────────────────────────────────────────────
// Display-plugin detection
//
// Some plugins already own screen brightness — Omarchy's own display panel,
// hyprmoncfg. When one of them is present this plugin hides its brightness
// controls rather than shipping a second, competing slider.
//
// Which plugins count is config, not code: `brightness.deferToPlugins` in
// ~/.config/kurisu-null.power-advanced.json holds the patterns. Each entry is
// either an exact plugin id ("omarchy.monitor") or a `*.suffix` wildcard
// ("*.hyprmoncfg") that also catches local clones and forks. An empty array
// switches the whole behavior off and the brightness controls always show.
// ─────────────────────────────────────────────────────────────────────────────

function defaultDisplayPlugins() {
  return ["omarchy.monitor", "*.hyprmoncfg"];
}

// Omarchy suffixes cloned widget instances with "@<n>"; match on the base id.
function canonicalPluginId(id) {
  return String(id === null || id === undefined ? "" : id).replace(/@.*$/, "").trim();
}

function matchesPluginPattern(id, pattern) {
  var key = canonicalPluginId(id);
  var pat = String(pattern || "").trim();
  if (key === "" || pat === "") return false;
  if (pat.indexOf("*.") === 0) {
    var suffix = pat.slice(1); // keep the dot: "*.hyprmoncfg" -> ".hyprmoncfg"
    return key.length > suffix.length && key.slice(-suffix.length) === suffix;
  }
  return key === pat;
}

// Every plugin id referenced by a parsed shell.json — bar layout entries in any
// section, plus top-level plugins[]. Entries may be objects or bare strings.
function shellEntryIds(shellConfig) {
  var ids = [];
  if (!shellConfig || typeof shellConfig !== 'object') return ids;

  function push(entry) {
    var id = canonicalPluginId(entry && typeof entry === 'object' ? entry.id : entry);
    if (id !== "" && ids.indexOf(id) === -1) ids.push(id);
  }

  var layout = shellConfig.bar && shellConfig.bar.layout ? shellConfig.bar.layout : {};
  var sections = ["left", "center", "right"];
  for (var s = 0; s < sections.length; s++) {
    var entries = layout[sections[s]];
    if (!Array.isArray(entries)) continue;
    for (var i = 0; i < entries.length; i++) push(entries[i]);
  }
  if (Array.isArray(shellConfig.plugins)) {
    for (var j = 0; j < shellConfig.plugins.length; j++) push(shellConfig.plugins[j]);
  }
  return ids;
}

// The first present plugin that matches a configured pattern, or "" if none do.
// Returning the id rather than a bool lets the System tab name who took over.
function matchingDisplayPlugin(entryIds, patterns) {
  if (!Array.isArray(entryIds) || !Array.isArray(patterns)) return "";
  for (var i = 0; i < entryIds.length; i++) {
    for (var j = 0; j < patterns.length; j++) {
      if (matchesPluginPattern(entryIds[i], patterns[j])) return entryIds[i];
    }
  }
  return "";
}

// Read the pattern list out of a merged plugin config, falling back to the
// defaults if the key is missing or has been replaced by something non-array.
function deferToPlugins(config) {
  var brightness = config && typeof config === 'object' ? config.brightness : null;
  var list = brightness ? brightness.deferToPlugins : null;
  if (!Array.isArray(list)) return defaultDisplayPlugins();
  return list;
}
