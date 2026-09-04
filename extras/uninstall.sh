#!/bin/bash
set -euo pipefail

# Counterpart to install.sh. `omarchy plugin remove` deletes the plugin folder in
# your home directory, but every file install.sh wrote is root-owned and outside
# it, so removing the plugin alone leaves the backend running headless: the udev
# rule keeps switching profiles, tmpfiles keeps re-applying the charge limit at
# boot, and the logind drop-in keeps overriding what the lid does. This undoes all
# of it.

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            echo "Usage: uninstall.sh [--purge]"
            echo "  --purge  also delete your settings and battery health history"
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Removing Power Advanced backend..."

# Lift the charge limit FIRST, while the tmpfiles entry is still around to show
# what was set. Leaving the battery capped at 80% with nothing left to manage or
# explain it is the one uninstall failure a user would not think to look for.
for thresh in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
    [ -w "$thresh" ] || continue
    if [ "$(cat "$thresh" 2>/dev/null || echo 100)" != "100" ]; then
        echo "Lifting charge limit back to 100% ($thresh)"
        echo 100 > "$thresh" 2>/dev/null || echo "  warning: could not write $thresh"
    fi
done

# Current paths, plus the names used by earlier generations of this plugin, so a
# machine that upgraded through the renames ends up fully clean either way.
for target in \
  /usr/local/libexec/omarchy-power-advanced \
  /usr/local/libexec/omarchy-power-manager \
  /usr/local/libexec/omarchy-battery-advanced \
  /usr/share/polkit-1/actions/org.omarchy.plugins.power-advanced.policy \
  /usr/share/polkit-1/actions/org.omarchy.plugins.power-manager.policy \
  /usr/share/polkit-1/actions/org.omarchy.plugins.battery-advanced.policy \
  /etc/udev/rules.d/90-power-advanced.rules \
  /etc/udev/rules.d/90-omarchy-power-manager.rules \
  /etc/udev/rules.d/90-battery-advanced.rules \
  /etc/tmpfiles.d/90-power-advanced-limit.conf \
  /etc/tmpfiles.d/90-battery-advanced-limit.conf \
  /etc/tmpfiles.d/battery-limiter.conf \
  /etc/systemd/logind.conf.d/90-power-advanced.conf \
  /etc/systemd/logind.conf.d/90-power-manager.conf \
  /etc/systemd/logind.conf.d/90-battery-advanced.conf \
  /etc/systemd/sleep.conf.d/90-power-advanced.conf \
  /etc/systemd/sleep.conf.d/90-power-manager.conf \
  /etc/systemd/sleep.conf.d/90-battery-advanced.conf; do
    if [ -e "$target" ]; then
        echo "Removing $target"
        rm -rf "$target"
    fi
done

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
fi

# Settings and health history are yours, not system state, so they survive a
# plain uninstall — reinstalling picks up where you left off.
if [ "$PURGE" -eq 1 ]; then
    USER_HOME=""
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi
    if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
        # The upstream name is in lib.sh's fallback list, so leaving it behind
        # means a purge followed by a reinstall silently restores old settings.
        for personal in \
          "$USER_HOME/.config/kurisu-null.power-advanced.json" \
          "$USER_HOME/.config/onlyvishesh.power-manager.json" \
          "$USER_HOME/.local/state/omarchy/kurisu-null.power-advanced" \
          "$USER_HOME/.local/state/omarchy/onlyvishesh.power-manager" \
          "$USER_HOME/.local/state/omarchy/power-advanced"; do
            if [ -e "$personal" ]; then
                echo "Purging $personal"
                rm -rf "$personal"
            fi
        done
    else
        echo "Warning: --purge needs SUDO_USER to locate your home directory; skipped."
    fi
fi

echo
echo "Backend removed."
echo "Lid and sleep behaviour revert on reboot, or now with:"
echo "  sudo systemctl restart systemd-logind    # note: this ends your session"
if [ "$PURGE" -eq 0 ]; then
    echo "Your settings and battery health history were kept. Delete them with --purge."
fi
echo "To remove the panel itself:  omarchy plugin remove kurisu-null.power-advanced"
