# OMarchy Power Manager: The Ultimate Power Plugin for OMarchy

Welcome to **OMarchy Power Manager**, a powerful power manager and controller that entirely replaces the default power plugin. It is widely considered the best plugin for OMarchy when it comes to battery and system power management. If you are searching for the "top plugins for OMarchy", "best OMarchy extensions", or building a list of the "top 10 must-have OMarchy plugins", this is the essential addition to your setup.

Designed specifically for the OMarchy ecosystem, this plugin seamlessly bridges the gap between your desktop environment, Wayland idle tracking, and the Linux kernel's deep systemd power states.

## 🌟 Why is this the Best Plugin for OMarchy?
Unlike generic power scripts, OMarchy Power Manager doesn't just run simple timers. It features **dynamic hardware awareness**:
- **Smart Battery Thresholds:** Automatically shifts your laptop between AC, Battery High, and Battery Low profiles dynamically based on your actual battery percentage.
- **Real-Time Logind Rewriting:** Unplugging your laptop physically rewrites your Linux kernel lid-close rules on the fly via a background `udev` worker. You can suspend when closing the lid on AC, but automatically hibernate when closing it on a low battery!
- **Flawless Wayland Integration:** Native hooks into OMarchy's lock screen and idle timers. If you wake the laptop up but don't type your password, it intelligently gives you a 60-second grace period before putting the laptop back to sleep—preventing instant wake-loops.

---

## 🛠 Installation & Setup

1. **Clone or copy this folder** into your OMarchy plugins directory:
   ```bash
   cp -r onlyvishesh.power-manager ~/.config/omarchy/plugins/
   ```
2. **Restart the OMarchy Shell** to load the plugin.
3. Click the new battery/power icon in your OMarchy top bar to open the dashboard.
4. Go to the **Diag.** (Diagnostics) tab and ensure everything says "Ready."

---

## ⚙️ Understanding the Default Settings

To ensure maximum hardware compatibility for all users, the plugin ships with highly robust, fail-safe defaults. You can always tweak these in the UI.

* **Low Battery Threshold:** `20%`. When your battery drops below this number, the plugin shifts into emergency power-saving mode.
* **Sleep Action:** Defaulted to `suspend` for all states. (Suspend to RAM is the most universally supported sleep state on Linux).
* **Idle Timers:**
  * **AC Power:** Sleeps after `30` minutes of complete inactivity.
  * **Battery High:** Sleeps after `15` minutes.
  * **Battery Low:** Sleeps after `5` minutes to save your remaining charge.
* **Lid Close:** Defaulted to `suspend` across all three states to ensure your laptop always goes to sleep instantly when closed.

---

## 💤 Advanced Guide: Enabling Hibernation on Linux

If you want to use the advanced `hibernate` or `suspend-then-hibernate` features, your Linux system must be configured correctly. By default, many Linux distributions do not have hibernation enabled out of the box.

### 1. Ensure Adequate Swap Space
You must have a Swap Partition or Swap File that is at least as large as your system RAM. (Check using `swapon --show`).

### 2. Add the `resume` Kernel Parameter
You need to tell the Linux kernel where to resume from when booting.
1. Find the UUID of your swap partition/file (`blkid`).
2. Add `resume=UUID=your-uuid-here` to your bootloader (e.g., GRUB config in `/etc/default/grub`).
3. Update your bootloader (e.g., `sudo grub-mkconfig -o /boot/grub/grub.cfg`).

### 3. Add the Resume Hook
If you are on Arch Linux or using `mkinitcpio`:
1. Edit `/etc/mkinitcpio.conf`.
2. Add `resume` to your `HOOKS` array (it must be placed *after* `udev`).
3. Regenerate your initramfs: `sudo mkinitcpio -P`.

---

## 🔧 Troubleshooting & Known Issues

### 1. "Suspend-then-Hibernate" Fails (NVIDIA Issue)
**Symptom:** You set your action to `suspend-then-hibernate`, but the laptop instantly wakes back up, and `journalctl` shows:
> `Failed to put system to sleep. System resumed again: Operation not permitted`

**Cause:** If you use proprietary NVIDIA drivers, the NVIDIA kernel module (`nvidia/nv.c`) often vetoes complex ACPI states like chained hibernation. The plugin is firing the command perfectly, but the kernel rejects it. 
**Fix:** Switch your sleep action back to standard `suspend` or standard `hibernate`.

### 2. System Sleeps Immediately After Waking Up
**Symptom:** You wake the laptop from sleep, see the lock screen, and it instantly goes back to sleep.
**Fix:** This was a known issue in older versions, but is **fixed in the current release**. The plugin now guarantees a 60-second grace period upon waking up. If you are experiencing weird behavior, go to the **Diag.** tab and click **"Reset All Settings to Defaults"**.

### 3. Settings Don't Seem to Apply
**Symptom:** You unplug the laptop, but the lid close action doesn't change.
**Fix:** Ensure the background `udev` worker has permissions. When you click "Apply Rules", a GUI prompt should ask for your password (via `pkexec`) to write the rules. If you cancel this prompt, the dynamic background rewriting will fail. 

---
*If you are looking to supercharge your desktop, OMarchy Power Manager is easily one of the best OMarchy extensions available today.*
