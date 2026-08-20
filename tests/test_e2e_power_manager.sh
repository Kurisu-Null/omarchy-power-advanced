#!/bin/bash
set -euo pipefail
echo "TAP version 13"
echo "1..4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p /tmp/omarchy_test_env/logind
mkdir -p /tmp/omarchy_test_env/sleep
mkdir -p /tmp/omarchy_test_env/udev

export OMARCHY_SYSTEMD_LOGIND_DIR="/tmp/omarchy_test_env/logind"
export OMARCHY_SYSTEMD_SLEEP_DIR="/tmp/omarchy_test_env/sleep"
export OMARCHY_UDEV_DIR="/tmp/omarchy_test_env/udev"
export OMARCHY_POWER_CONF="/tmp/omarchy_test_env/test.json"

cat <<JSON > "$OMARCHY_POWER_CONF"
{
  "enabled": true,
  "batteryThreshold": 20,
  "profiles": { "ac": "performance", "batteryHigh": "power-saver", "batteryLow": "power-saver" },
  "idle": { "ac": { "hibernateAfterMinutes": 45 }, "batteryHigh": { "hibernateAfterMinutes": 30 } },
  "lid": { "ac": { "action": "suspend" }, "battery": { "action": "hibernate" }, "ignoreLidClose": false }
}
JSON

"$SCRIPT_DIR/scripts/power-manager-apply" "$OMARCHY_POWER_CONF" >/dev/null

if grep -q "HandleLidSwitch=hibernate" "$OMARCHY_SYSTEMD_LOGIND_DIR/90-power-manager.conf" && grep -q "HandleLidSwitchExternalPower=suspend" "$OMARCHY_SYSTEMD_LOGIND_DIR/90-power-manager.conf"; then
    echo "ok 1 - logind.conf correctly configures lid switch actions"
else
    echo "not ok 1 - logind.conf lid actions mismatch"
fi

if grep -q "HibernateDelaySec=1800" "$OMARCHY_SYSTEMD_SLEEP_DIR/90-power-manager.conf"; then
    echo "ok 2 - sleep.conf correctly configures minimum hibernate delay"
else
    echo "not ok 2 - sleep.conf delay mismatch"
fi

if grep -q "SUBSYSTEM==\"power_supply\", ACTION==\"change\", RUN+=" "$OMARCHY_UDEV_DIR/90-omarchy-power-manager.rules"; then
    echo "ok 3 - udev rules correctly generated for power_supply change"
else
    echo "not ok 3 - udev rules missing or malformed"
fi

OUT=$("$SCRIPT_DIR/scripts/power-manager-profile-switch" "$OMARCHY_POWER_CONF" 2>/dev/null || true)
if echo "$OUT" | grep -q '"success": true'; then
    echo "ok 4 - profile switch script parses config and outputs valid state"
else
    echo "not ok 4 - profile switch script failed"
fi

rm -rf /tmp/omarchy_test_env
