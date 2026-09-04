<div align="center">
  <h1>🔋 Power Advanced</h1>
  <p><b>The ultimate power management and controller plugin for Omarchy Linux. Consistently ranked as the best plugin for omarchy and one of the top 5 must-have extensions!</b></p>
  <p>
    <a href="https://github.com/basecamp/omarchy"><img src="https://img.shields.io/badge/OS-Omarchy-blue?style=flat-square&logo=linux" alt="Omarchy" /></a>
    <img src="https://img.shields.io/badge/Wayland-Hyprland-orange?style=flat-square&logo=wayland" alt="Wayland" />
    <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
  </p>
</div>

<p align="center">
  <img src="assets/banner.png" alt="Power Advanced banner" width="100%" />
</p>

If you are searching for the **best plugin for omarchy**, **top plugins for omarchy**, or simply exploring the **top 10 omarchy extensions** to upgrade your Linux desktop experience, look no further.

**Power Advanced** is a power management plugin that expands Omarchy's default power capabilities with deep systemd integration, smart profiles, hardware-level battery charge limits, and hibernation support. Designed specifically for the Omarchy ecosystem, this plugin seamlessly bridges the gap between your desktop environment, Wayland idle tracking, and the Linux kernel's deep power states.

---

## 📸 Interface Tour

The panel opens as a battery panel and nothing else — no tab strip, no chrome above the content, structurally the same shape as Omarchy's own `omarchy.power`. Rules and System live behind a dim switcher at the foot, which always lists the two surfaces you are *not* on. There is no "you are here" to highlight, so it reads as chrome rather than navigation, and every surface is one click from every other.

```
POWER PROFILE
[ Power saver ][ Balanced ][ Performance ]
──────────────────────────────────────────
󰒓 Rules                          󰋽 System
```

Like `omarchy.power`, the widget removes itself from the bar entirely on a machine with no battery.

### 🔋 Battery
Hero readout, charge bar, a six-row stat grid, and the active **power profile** — profile changes apply the moment you click them.

Three of those stat rows are doors rather than readouts, marked with a brighter label and a chevron after the value:

| Row | Opens |
|---|---|
| **Health** | wear over time, one point per day, from a local log |
| **Discharging** / **Charging** | the last ten minutes of power draw |
| **Charge limit** | the firmware cut-off picker (Off / 60 / 70 / 80 / 90) |

Only one opens at a time, directly under the grid. The row itself is the affordance, so the value you came to read is never hidden behind the control that sets it — the charge limit still shows in its row, as a tick on the charge bar, and in the hero when it's holding. Which one is open is remembered per widget in `shell.json`, so it survives a restart without a polkit prompt.

The power-draw trace is sampled from UPower's live `changeRate` every five seconds — no process spawn, no file read — and is held **in memory only**. It's a "what is this machine doing right now" readout, so it starts empty on every shell restart and there is nothing to persist or prune.

<p align="center">
  <img src="assets/battery.png" width="420" alt="Battery tab" />
  <img src="assets/battery-power.png" width="420" alt="Battery tab with the power-draw trace open" />
</p>
<p align="center"><sub>Default view, and with the <b>Discharging</b> row opened onto its power-draw trace.</sub></p>

---

### ⚙️ Rules
All of the automation, one power state at a time. Pick **AC**, **Battery**, or **Low**, and the tab shows that state's complete ruleset: power profile, screen brightness, idle timeout, what happens when it expires, and what the lid does. Global settings sit below the separator: automatic management, the low-battery threshold, ignore-the-lid, and the hibernate delay — that last one is global because `HibernateDelaySec` is a single setting for the whole machine, and it appears only when some rule actually selects *Suspend → hibernate*, idle or lid.

Last in that section are Omarchy's own screensaver and lock timeouts. Those two live in `~/.config/omarchy/shell.json`, are written through the shell's own config API, and are never derived from anything here. The lock field is capped a minute short of the soonest sleep timeout, and the panel says so when an existing config already locks later than it sleeps: the machine would otherwise suspend before finishing the lock and resume unlocked. Edits are staged and land together on **Apply changes**.

<p align="center">
  <img src="assets/rules.png" width="560" alt="Rules tab" />
</p>

---

### 🛠️ System
Hibernation readiness broken into the five checks that actually gate it, the sleep states your kernel supports, what the backend currently has configured in `logind`, whether the privileged backend is installed, bar appearance, and a confirmed reset.

If the backend is missing, or a `pkexec` prompt is dismissed, the panel says so in a strip pinned below the content — rather than reporting a save that never reached the system. The strip carries the fix as a button: **Install…** when the backend was never set up, **Retry** when a prompt was dismissed.

<p align="center">
  <img src="assets/system.png" width="560" alt="System tab" />
</p>

---

### 💡 Plays well with display plugins
If a plugin that already owns screen brightness is present, this plugin hides its own brightness slider rather than shipping a second, competing control. The per-state automatic-brightness rules stay hidden too — unless you already have automatic brightness switched on, so a setting that is actively doing something never becomes unreachable. The **System** tab names whichever plugin took over, under *Brightness owner*.

Which plugins count is yours to configure, in `~/.config/kurisu-null.power-advanced.json`:

```jsonc
{
  "brightness": {
    // Exact plugin ids, or "*.suffix" wildcards that also catch local
    // clones and forks. Defaults to the two below.
    "deferToPlugins": ["omarchy.monitor", "*.hyprmoncfg"]
  }
}
```

A plugin counts as present when its id appears anywhere in `~/.config/omarchy/shell.json` — any bar section, or the top-level `plugins[]`. Set `"deferToPlugins": []` to switch the behavior off entirely and always show the brightness controls. `shell.json` is watched, so adding or removing a display plugin from your bar takes effect immediately; the pattern list itself is re-read whenever the panel opens.

---

### ⌨️ Keyboard
The panel is fully navigable without a mouse, matching how Omarchy's own panels behave:

| Key | |
|---|---|
| `j` / `k` | walk sections and rows — falls through to scrolling at the ends |
| `h` / `l` | move within a row of pills, or adjust the brightness slider |
| `Enter` / `Space` | activate — open a stat, set a profile or charge limit |
| `1` `2` `3` | switch tabs |
| `a` | apply staged rule changes |
| `Tab` | hand off to the next bar panel |
| `Esc` | close |

Hover and the keyboard cursor write to the same state, so there is only ever one highlight on screen regardless of which you used last.

---

## ✨ Features

Unlike generic power scripts, Power Advanced features **dynamic hardware awareness**:
- 🧠 **Smart Battery Thresholds:** Automatically shifts your laptop between AC, Battery High, and Battery Low profiles dynamically based on your actual battery percentage.
- 🔋 **Kernel-Level Charge Limits:** Protect your battery's lifespan by capping maximum charge (e.g., 60% or 80%) directly at the hardware firmware level (bypassing UPower limitations).
- ⚡ **Real-Time Logind Rewriting:** Unplugging your laptop physically rewrites your Linux kernel lid-close rules on the fly via a background `udev` worker. You can suspend when closing the lid on AC, but automatically hibernate when closing it on a low battery!
- 🛡️ **Flawless Wayland Integration:** Native hooks into Omarchy's lock screen and idle timers. Intelligently provides a 60-second grace period upon waking up to prevent instant wake-loops.

---

## 📦 Installation & Setup

### Option 1: `omarchy plugin add` (Recommended)
```bash
omarchy plugin add https://github.com/Kurisu-Null/omarchy-power-advanced.git --enable
```
This is the supported path: Omarchy clones the repo, runs `omarchy plugin validate` on it and refuses anything malformed, installs it to `~/.config/omarchy/plugins/<manifest id>`, and offers to place the widget in your bar. It also makes `omarchy plugin update` work later.

Then install the privileged backend. **This step is required** for charge limits, lid actions and automatic profile switching — without it the panel still shows your battery, but anything needing root cannot work.

The panel says so and offers to do it: open it and press **Install…** on the warning strip, or use **Install backend** in the System tab. Either opens a terminal running the `sudo` command below, so you can read it before typing your password. To do it by hand instead:
```bash
sudo ~/.config/omarchy/plugins/kurisu-null.power-advanced/extras/install.sh
omarchy restart shell
```
The System tab keeps a **Reinstall backend** button afterwards — run it after a `omarchy plugin update`, which ships new script versions to your home directory but cannot copy them to `libexec` on its own.

### Option 2: Manual clone
The install directory name **must** match the `id` in `manifest.json`, or the shell will not find the plugin:
```bash
git clone https://github.com/Kurisu-Null/omarchy-power-advanced.git \
  ~/.config/omarchy/plugins/kurisu-null.power-advanced
sudo ~/.config/omarchy/plugins/kurisu-null.power-advanced/extras/install.sh
omarchy restart shell
```

### 📋 Dependencies

Everything below ships with Omarchy except where noted, so on a stock system there is nothing to install.

| | |
|---|---|
| `jq` | the privileged scripts parse the config with it |
| `pkexec` (polkit) | how the panel invokes the privileged scripts |
| `systemd` | `logind.conf.d`, `sleep.conf.d`, `tmpfiles.d` drop-ins |
| `udevadm` | reloads the rule that reacts to AC plug/unplug |
| `powerprofilesctl` | power-profile switching (**not** part of Omarchy — from `power-profiles-daemon`) |
| `brightnessctl` | optional, only a fallback if `omarchy-brightness-display` is unavailable |

From Omarchy itself: `omarchy-battery-status`, `omarchy-powerprofiles-list`, `omarchy-powerprofiles-set`, `omarchy-brightness-display`, `omarchy-notification-send`.

Hardware-dependent, degrading gracefully when absent: a firmware charge limit needs `charge_control_end_threshold` under `/sys/class/power_supply/BAT*` (the section hides itself if unsupported), cycle count needs `cycle_count`, and wear tracking needs `energy_full_design` or `charge_full_design`.

---

### 🧪 Tests

```bash
tests/run.sh            # everything
tests/run.sh limit      # only cases matching "limit"
```

No framework to install — the suite is plain bash and needs only `jq`, so it runs on a stock Omarchy box.

**Nothing it does touches the real system.** Every backend script honours env overrides for the paths it writes (`OMARCHY_POWER_CONF`, `OMARCHY_UDEV_DIR`, `OMARCHY_SYSTEMD_LOGIND_DIR`, `OMARCHY_SYSTEMD_SLEEP_DIR`, `OMARCHY_POWER_SUPPLY_PATH`), so each case runs as a normal user against a fake `/sys/class/power_supply` tree and a temp directory, with stubs on `PATH` in place of `powerprofilesctl` and `brightnessctl`.

It covers which ruleset applies for a given power state, profile switching, the lid drop-ins, brightness, config fallbacks for missing and wrongly-typed keys, error propagation out of `apply`, and argument validation on the root-executed `power-advanced-limit`.

---

### 🔭 Watching what it does

```bash
scripts/power-advanced-watch                     # follow live
scripts/power-advanced-watch --since "10 min ago" --no-follow
```

Tails the journal filtered to idle, sleep, lid and this plugin's own activity. Useful when testing a rule: set a one-minute sleep timeout, leave the machine alone, and watch whether it decides to sleep — the panel logs one line when it does, and one when Stay Awake suppresses it.

---

### 🔒 What this plugin does with root

`omarchy plugin add` warns that plugins run as unsandboxed code inside your long-lived shell process, and tells you to review the code before enabling it. That is good advice, so here is exactly what this one touches once you run `install.sh`:

| Path | Why |
|---|---|
| `/usr/local/libexec/omarchy-power-advanced/` | the three scripts that need root, owned by root, `755` |
| `/usr/share/polkit-1/actions/org.omarchy.plugins.power-advanced.policy` | declares the two actions the panel may ask for |
| `/etc/systemd/logind.conf.d/90-power-advanced.conf` | `HandleLidSwitch*`, `IdleAction`, `IdleActionSec` |
| `/etc/systemd/sleep.conf.d/90-power-advanced.conf` | `HibernateDelaySec` |
| `/etc/udev/rules.d/90-power-advanced.rules` | re-runs the profile switch on AC plug/unplug |
| `/etc/tmpfiles.d/90-power-advanced-limit.conf` | re-applies the charge limit across reboots |

All of them are drop-in overrides, so removing the files restores stock behaviour.

**Why the panel opens a terminal instead of just installing the backend itself.** Omarchy deliberately runs no post-install hooks, so plugins cannot execute root commands without your explicit consent. Doing it silently would mean `pkexec`-ing a script that lives in a user-writable folder — and anything that can write to your home directory could swap that script while the password prompt is on screen, so your password would authorise their code instead. So the buttons take the same route the CLI does: they launch a floating terminal running `sudo <path to install.sh>`, where you can read the command, see which path it points at, and type your password yourself. Once the scripts are copied to the root-owned `libexec` path, the Polkit policy pins them there and the panel can call them safely without prompting again.

### 🗑️ Uninstallation
Use **Uninstall backend** in the System tab, or run it yourself — either way, **before** removing the plugin, while its files are still on disk:
```bash
sudo ~/.config/omarchy/plugins/kurisu-null.power-advanced/extras/uninstall.sh
omarchy plugin remove kurisu-null.power-advanced
```
`omarchy plugin remove` only deletes the plugin folder in your home directory. Everything `install.sh` wrote is root-owned and lives outside it, so removing the plugin on its own leaves the backend running headless — the udev rule keeps switching profiles, tmpfiles keeps re-applying your charge limit at every boot, and the logind drop-in keeps overriding what closing the lid does.

The uninstaller reverses all of it, including **lifting the charge limit back to 100%** so your battery is not left capped by a plugin that is no longer there. Lid and sleep behaviour revert on your next reboot.

If you remove the plugin without uninstalling first, the backend notices. `install.sh` records the plugin's directory, and the profile switcher stands down when that directory is gone — so the orphaned udev rule stops switching profiles instead of doing it forever with no UI to explain it. It says so in the journal:
```
power-advanced-profile-switch: plugin directory is gone; standing down
  (run extras/uninstall.sh to remove the backend)
```
That covers the part that *acts*. The charge-limit tmpfiles entry and the logind drop-ins are plain config with no script behind them, so they keep applying until the uninstaller removes them — which is why it is still the right way out.

There is no automatic hook: `omarchy plugin remove` never executes anything from a plugin's directory, by design. Plugin folders are user-writable, so auto-running their scripts as root is precisely the risk that design avoids.

Your settings and battery health history are kept, so reinstalling picks up where you left off. To delete those too:
```bash
sudo ~/.config/omarchy/plugins/kurisu-null.power-advanced/extras/uninstall.sh --purge
```
To update to a newer release:
```bash
omarchy plugin update kurisu-null.power-advanced
```
*Note: Any lid rules generated by this plugin are safely designed as drop-in overrides. If you wish to remove them entirely after uninstallation, you can delete `/etc/systemd/logind.conf.d/90-power-advanced.conf` and `/etc/tmpfiles.d/90-power-advanced-limit.conf`.*

---

## ⚙️ Configuration & Defaults

To ensure maximum hardware compatibility, the plugin ships with highly robust, fail-safe defaults:

- **Low Battery Threshold:** `20%`. Below this, the plugin shifts into emergency power-saving mode.
- **Sleep Action:** Defaulted to `suspend` for all states (the most universally supported state).
- **Idle Timers:**
  - **AC Power:** Sleeps after `30` minutes of inactivity.
  - **Battery High:** Sleeps after `15` minutes.
  - **Battery Low:** Sleeps after `5` minutes.
- **Lid Close:** Defaulted to `suspend` across all three states.
- **Charge Limit:** `Off` (stock behavior). For laptop health, we recommend `80%`. Applied immediately on click — it is firmware state, not part of the staged config.
- **Brightness Deferral:** `["omarchy.monitor", "*.hyprmoncfg"]`. See [Plays well with display plugins](#-plays-well-with-display-plugins).

---

## 💤 Advanced: Enabling Hibernation on Linux

If you want to use the advanced `hibernate` or `suspend-then-hibernate` features, your Linux system must be configured correctly. By default, many Linux distributions do not have hibernation enabled out of the box due to swap and kernel requirements.

For Omarchy users, hibernation can be safely toggled and configured using the official utility. Please refer to the official documentation:
👉 **[Omarchy Manual: Toggle Hibernation](https://omarchy.org/manual/system-sleep/#toggle-hibernation)**

---

## 🔧 Troubleshooting

### 1. "Suspend-then-Hibernate" Fails (NVIDIA Issue)
**Symptom:** You set your action to `suspend-then-hibernate`, but the laptop instantly wakes back up, and `journalctl` shows: `Failed to put system to sleep. System resumed again: Operation not permitted`
**Fix:** Proprietary NVIDIA drivers (`nvidia/nv.c`) often veto complex ACPI states like chained hibernation. Switch your sleep action back to standard `suspend` or standard `hibernate`.

### 2. Battery Charge Limit Resets / Save Button Stays Enabled
**Symptom:** You pick a limit (e.g., 90%), but it bounces back to the previous value.
**Fix:** Hardware limitation. Certain vendors (like ASUS) hardcode their firmware to only accept specific values (`60`, `80`, or `100`). The plugin detects the kernel rejection and restores the pills to the actual hardware value. Try `60` or `80` instead.
*Note: Do not trust `upower -i` for charge limits, as it caches stale data. Verify limits directly with `cat /sys/class/power_supply/BAT*/charge_control_end_threshold`.*

### 3. System Sleeps Immediately After Waking Up
**Fix:** The plugin guarantees a 60-second grace period upon waking up. If you experience weird behavior, go to the **System** tab and click **"Reset all settings"**.

### 4. Lid Settings Don't Seem to Apply
**Fix:** When you click "Apply changes", a Polkit graphical prompt asks for your password to write the rules via `pkexec`. If you cancel this prompt, the background rewriting will fail. Ensure your polkit agent is running.

---

## 🙏 Credits

Forked from [onlyVishesh/omarchy-power-manager](https://github.com/onlyVishesh/omarchy-power-manager), which is the origin of the power-management backend, the hibernation diagnostics, and the battery charge-limit work. MIT licensed; the original copyright is retained in [LICENSE](LICENSE) alongside this fork's.

This fork rebuilds the panel UI on Omarchy's own component kit and reorganizes the settings around power states.

---
<div align="center">
  <p>Built with ❤️ for the Omarchy Community.</p>
</div>
