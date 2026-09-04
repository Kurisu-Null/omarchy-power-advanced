#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Installing Power Advanced backend..."

LIBEXEC_DIR="/usr/local/libexec/omarchy-power-advanced"
POLKIT_DIR="/usr/share/polkit-1/actions"
PLUGIN_DIR="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
SCRIPT_DIR="$PLUGIN_DIR/scripts"
POLICY_FILE="$(dirname "$(realpath "$0")")/org.omarchy.plugins.power-advanced.policy"

# Create directories
mkdir -p "$LIBEXEC_DIR"
mkdir -p "$POLKIT_DIR"

# Install backend scripts
echo "Installing scripts to $LIBEXEC_DIR..."
# Clear anything a previous install left here. The scripts were once named
# power-manager-*, and stale copies alongside the current ones would be
# confusing at best and, since the directory is root-owned and on the polkit
# exec path, worth not keeping around.
rm -f "$LIBEXEC_DIR"/power-manager-* "$LIBEXEC_DIR"/power-advanced-* "$LIBEXEC_DIR/lib.sh" "$LIBEXEC_DIR/plugin-dir"

# lib.sh is sourced by all three, so it has to live beside them.
cp "$SCRIPT_DIR/lib.sh" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-advanced-apply" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-advanced-profile-switch" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-advanced-limit" "$LIBEXEC_DIR/"

# Ensure strict permissions
chown -R root:root "$LIBEXEC_DIR"
chmod 644 "$LIBEXEC_DIR/lib.sh"
chmod 755 "$LIBEXEC_DIR/power-advanced-apply"
chmod 755 "$LIBEXEC_DIR/power-advanced-profile-switch"
chmod 755 "$LIBEXEC_DIR/power-advanced-limit"

# Record where the plugin lives. Omarchy has no plugin-remove hook, so this is how
# the backend later notices it was orphaned by `omarchy plugin remove` and stops
# switching profiles for a plugin that is no longer installed.
printf '%s\n' "$PLUGIN_DIR" > "$LIBEXEC_DIR/plugin-dir"
chmod 644 "$LIBEXEC_DIR/plugin-dir"

# Install Polkit policy
echo "Installing Polkit policy to $POLKIT_DIR..."
if [ -f "$POLICY_FILE" ]; then
    cp "$POLICY_FILE" "$POLKIT_DIR/"
    chown root:root "$POLKIT_DIR/org.omarchy.plugins.power-advanced.policy"
    chmod 644 "$POLKIT_DIR/org.omarchy.plugins.power-advanced.policy"
else
    echo "Warning: Polkit policy file not found at $POLICY_FILE"
fi

# Earlier releases installed under vendor-neutral names that would collide with
# upstream's plugin, and a pre-release build used "battery-advanced". Clear both
# so a machine never ends up with two copies of the backend and two polkit
# actions racing for the same scripts.
for legacy in \
  /usr/local/libexec/omarchy-power-manager \
  /usr/local/libexec/omarchy-battery-advanced \
  /usr/share/polkit-1/actions/org.omarchy.plugins.power-manager.policy \
  /usr/share/polkit-1/actions/org.omarchy.plugins.battery-advanced.policy \
  /etc/tmpfiles.d/battery-limiter.conf \
  /etc/tmpfiles.d/90-battery-advanced-limit.conf \
  /etc/udev/rules.d/90-omarchy-power-manager.rules \
  /etc/udev/rules.d/90-battery-advanced.rules \
  /etc/systemd/logind.conf.d/90-power-manager.conf \
  /etc/systemd/logind.conf.d/90-battery-advanced.conf \
  /etc/systemd/sleep.conf.d/90-power-manager.conf \
  /etc/systemd/sleep.conf.d/90-battery-advanced.conf; do
    if [ -e "$legacy" ]; then
        echo "Removing legacy $legacy"
        rm -rf "$legacy"
    fi
done

# The udev rule keeps its filename across renames but embeds the absolute path of
# the profile-switch script, so a rule written by an earlier generation now points
# at a script this install just deleted. udev fails that RUN+= silently, which
# would leave AC plug/unplug switching dead with nothing in the UI to show for it.
# Repoint it rather than deleting it, so switching survives the upgrade without
# the user having to know to press Apply.
RULE="/etc/udev/rules.d/90-power-advanced.rules"
if [ -f "$RULE" ] && grep -q 'profile-switch' "$RULE"; then
    if ! grep -q "$LIBEXEC_DIR/power-advanced-profile-switch " "$RULE"; then
        echo "Repointing $RULE at the current backend path"
        sed -i "s#RUN+=\"[^ ]*profile-switch #RUN+=\"$LIBEXEC_DIR/power-advanced-profile-switch #" "$RULE"
    fi
fi

# Pick up the policy and rule changes without waiting for a reboot.
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
fi

echo "Backend installation complete!"
