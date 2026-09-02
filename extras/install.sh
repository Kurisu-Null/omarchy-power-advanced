#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Installing OMarchy Power Manager backend..."

LIBEXEC_DIR="/usr/local/libexec/omarchy-power-advanced"
POLKIT_DIR="/usr/share/polkit-1/actions"
SCRIPT_DIR="$(dirname "$(realpath "$0")")/../scripts"
POLICY_FILE="$(dirname "$(realpath "$0")")/org.omarchy.plugins.power-advanced.policy"

# Create directories
mkdir -p "$LIBEXEC_DIR"
mkdir -p "$POLKIT_DIR"

# Install backend scripts
echo "Installing scripts to $LIBEXEC_DIR..."
cp "$SCRIPT_DIR/power-manager-apply" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-manager-profile-switch" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-manager-limit" "$LIBEXEC_DIR/"

# Ensure strict permissions
chown -R root:root "$LIBEXEC_DIR"
chmod 755 "$LIBEXEC_DIR/power-manager-apply"
chmod 755 "$LIBEXEC_DIR/power-manager-profile-switch"
chmod 755 "$LIBEXEC_DIR/power-manager-limit"

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

echo "Backend installation complete!"
