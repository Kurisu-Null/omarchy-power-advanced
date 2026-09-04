#!/bin/bash
#
# Test suite for the Power Advanced backend scripts.
#
#   tests/run.sh            run everything
#   tests/run.sh limit      run only cases whose name matches "limit"
#
# Deliberately dependency-free: no bats, no shunit2, nothing to install. It has
# to run on a stock Omarchy box, and `jq` is all it needs beyond bash.
#
# Nothing here touches the real system. Every script honours env overrides for
# the paths it writes -- OMARCHY_POWER_CONF, OMARCHY_UDEV_DIR,
# OMARCHY_SYSTEMD_LOGIND_DIR, OMARCHY_SYSTEMD_SLEEP_DIR and
# OMARCHY_POWER_SUPPLY_PATH -- so each case runs against a fake sysfs tree and
# a temp directory, as a normal user.
set -uo pipefail

ROOT=$(cd "$(dirname "$(realpath "$0")")/.." && pwd)
SCRIPTS="$ROOT/scripts"
FILTER=${1:-}

PASS=0; FAIL=0; SKIP=0
CURRENT=""
FAILURES=()

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

it() {
  CURRENT=$1
  if [ -n "$FILTER" ] && [[ $CURRENT != *"$FILTER"* ]]; then
    CURRENT=""
    return 1
  fi
  SANDBOX=$(mktemp -d)
  return 0
}

done_it() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
  CURRENT=""
}

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(green ✓)" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$CURRENT: $1"); printf '  %s %s\n    %s\n' "$(red ✗)" "$CURRENT" "$(red "$1")"; }
skip() { SKIP=$((SKIP+1)); printf '  %s %s %s\n' "$(dim −)" "$CURRENT" "$(dim "($1)")"; }

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$CURRENT${3:+ — $3}"; else
    bad "expected [$2] got [$1]${3:+ ($3)}"
  fi
}

assert_contains() {
  if [[ $1 == *"$2"* ]]; then ok "$CURRENT${3:+ — $3}"; else
    bad "expected to contain [$2] in [$1]${3:+ ($3)}"
  fi
}

assert_json() {   # assert_json <json> <jq filter> <expected> [label]
  local got
  got=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)
  assert_eq "$got" "$3" "${4:-$2}"
}

# --- fixtures ---------------------------------------------------------------

# fake_supply <name> <type> [key=value ...]
fake_supply() {
  local dir="$SANDBOX/sys/$1"; shift
  local type=$1; shift
  mkdir -p "$dir"
  printf '%s\n' "$type" >"$dir/type"
  local kv
  for kv in "$@"; do printf '%s\n' "${kv#*=}" >"$dir/${kv%%=*}"; done
}

write_config() { printf '%s\n' "$1" >"$SANDBOX/config.json"; }

# Runs a backend script with every write redirected into the sandbox.
run_script() {
  local script=$1; shift
  env \
    OMARCHY_POWER_CONF="$SANDBOX/config.json" \
    OMARCHY_POWER_SUPPLY_PATH="$SANDBOX/sys" \
    OMARCHY_UDEV_DIR="$SANDBOX/udev" \
    OMARCHY_SYSTEMD_LOGIND_DIR="$SANDBOX/logind" \
    OMARCHY_SYSTEMD_SLEEP_DIR="$SANDBOX/sleep" \
    XDG_STATE_HOME="$SANDBOX/state" \
    OMARCHY_PLUGIN_MARKER="$SANDBOX/plugin-dir" \
    HOME="$SANDBOX/home" \
    PATH="$SANDBOX/bin:$PATH" \
    "$SCRIPTS/$script" "$@" 2>"$SANDBOX/stderr"
}

stderr_of() { cat "$SANDBOX/stderr" 2>/dev/null; }

# Puts a fake executable on PATH so a case can assert what got called without
# touching the real powerprofilesctl or brightnessctl.
stub() {
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/$1" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$SANDBOX/calls-$1"
${2:-exit 0}
STUB
  chmod +x "$SANDBOX/bin/$1"
}

calls_to() { cat "$SANDBOX/calls-$1" 2>/dev/null; }

CONFIG_MINIMAL='{
  "enabled": true,
  "batteryThreshold": 20,
  "profiles":   { "ac": "performance", "batteryHigh": "balanced", "batteryLow": "power-saver" },
  "brightness": { "auto": false, "ac": 80, "batteryHigh": 50, "batteryLow": 20 },
  "hibernateAfterMinutes": 45,
  "lid":        { "ignoreLidClose": false,
                  "ac": { "action": "ignore" },
                  "batteryHigh": { "action": "suspend" },
                  "batteryLow": { "action": "hibernate" } }
}'

printf '\n%s\n' "$(dim "Power Advanced — backend tests")"
printf '%s\n\n' "$(dim "scripts: $SCRIPTS")"
# ===========================================================================
printf '%s\n' "state selection — which ruleset applies"
# ===========================================================================

if it "AC online picks the ac ruleset"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state ac
  done_it
fi

if it "on battery above the threshold picks batteryHigh"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state batteryHigh
  done_it
fi

if it "on battery at or below the threshold picks batteryLow"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=20
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state batteryLow
  done_it
fi

if it "a desktop with no battery is treated as ac"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state ac
  done_it
fi

if it "capacity is averaged across multiple batteries"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=10
  fake_supply BAT1 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state batteryHigh "mean 30 is above the threshold of 20"
  done_it
fi

# ===========================================================================
printf '\n%s\n' "profile switching"
# ===========================================================================

if it "sets the configured profile for the state"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=5
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  assert_eq "$(calls_to powerprofilesctl | tail -1)" "set power-saver"
  done_it
fi

if it "enabled:false changes nothing"; then
  write_config "${CONFIG_MINIMAL/\"enabled\": true/\"enabled\": false}"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=5
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .reason disabled
  # Reading the current profile is fine and expected; what must not happen is
  # a `set`.
  if [ -z "$(calls_to powerprofilesctl | grep '^set ' || true)" ]; then
    ok "$CURRENT — profile read but never set"
  else
    bad "powerprofilesctl set was called despite enabled:false"
  fi
  done_it
fi

if it "a failing powerprofilesctl is reported, not swallowed"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  fake_supply BAT0 Battery capacity=90
  stub powerprofilesctl 'exit 1'
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .success true "still applies the rest"
  assert_contains "$(stderr_of)" "powerprofilesctl set performance failed" "logged to stderr"
  done_it
fi

# ===========================================================================
printf '\n%s\n' "lid rules — the logind drop-in"
# ===========================================================================

if it "writes the lid actions for the current state"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  conf=$(cat "$SANDBOX/logind/90-power-advanced.conf")
  assert_contains "$conf" "HandleLidSwitch=suspend" "battery action"
  assert_contains "$conf" "HandleLidSwitchExternalPower=ignore" "ac action"
  done_it
fi

if it "batteryLow gets its own lid action"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=5
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  assert_contains "$(cat "$SANDBOX/logind/90-power-advanced.conf")" "HandleLidSwitch=hibernate"
  done_it
fi

if it "ignoreLidClose overrides both actions"; then
  write_config "${CONFIG_MINIMAL/\"ignoreLidClose\": false/\"ignoreLidClose\": true}"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  conf=$(cat "$SANDBOX/logind/90-power-advanced.conf")
  assert_contains "$conf" "HandleLidSwitch=ignore" "battery forced to ignore"
  assert_contains "$conf" "HandleLidSwitchExternalPower=ignore" "ac forced to ignore"
  done_it
fi

if it "never writes IdleAction, which cannot fire under Hyprland"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  if grep -q IdleAction "$SANDBOX/logind/90-power-advanced.conf"; then
    bad "IdleAction was written back into the logind drop-in"
  else
    ok "$CURRENT"
  fi
  done_it
fi

if it "rejects a lid action logind would not understand"; then
  write_config "${CONFIG_MINIMAL/\"action\": \"suspend\"/\"action\": \"explode\"}"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch); status=$?
  assert_json "$out" .success false
  assert_eq "$status" 1 "exits non-zero"
  done_it
fi

if it "hibernate delay comes from the global key"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  stub powerprofilesctl
  run_script power-advanced-profile-switch >/dev/null
  assert_contains "$(cat "$SANDBOX/sleep/90-power-advanced.conf")" "HibernateDelaySec=2700" "45 min"
  done_it
fi

# ===========================================================================
printf '\n%s\n' "brightness"
# ===========================================================================

if it "is not touched unless auto is on"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  stub powerprofilesctl; stub brightnessctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .brightness "" "reported as unset"
  done_it
fi

if it "applies the per-state value when auto is on"; then
  write_config "${CONFIG_MINIMAL/\"auto\": false/\"auto\": true}"
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl; stub brightnessctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .brightness "50%" "batteryHigh value"
  done_it
fi

if it "treats 0 as leave-alone rather than go-dark"; then
  cfg=${CONFIG_MINIMAL/\"auto\": false/\"auto\": true}
  write_config "${cfg/\"ac\": 80/\"ac\": 0}"
  fake_supply AC Mains online=1
  stub powerprofilesctl; stub brightnessctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .brightness "" "no brightness applied"
  if [ -z "$(calls_to brightnessctl)" ]; then ok "$CURRENT — backend not invoked"; else
    bad "brightnessctl was called with 0"
  fi
  done_it
fi

# ===========================================================================
printf '\n%s\n' "config handling"
# ===========================================================================

if it "a missing config fails loudly instead of guessing"; then
  fake_supply AC Mains online=1
  out=$(env OMARCHY_POWER_CONF="$SANDBOX/nope.json" OMARCHY_POWER_SUPPLY_PATH="$SANDBOX/sys" \
        HOME="$SANDBOX/home" "$SCRIPTS/power-advanced-profile-switch" 2>/dev/null); status=$?
  assert_json "$out" .success false
  assert_eq "$status" 1 "exits non-zero"
  done_it
fi

if it "malformed JSON is rejected"; then
  write_config '{ this is not json'
  fake_supply AC Mains online=1
  out=$(run_script power-advanced-profile-switch); status=$?
  assert_json "$out" .success false
  assert_eq "$status" 1 "exits non-zero"
  done_it
fi

if it "missing keys fall back to documented defaults"; then
  write_config '{}'
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state batteryHigh "default threshold 30 < 50"
  assert_eq "$(calls_to powerprofilesctl | tail -1)" "set balanced" "default batteryHigh profile"
  done_it
fi

if it "a wrongly-typed value falls back rather than breaking arithmetic"; then
  write_config '{"batteryThreshold": "twenty"}'
  fake_supply AC Mains online=0
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .success true "survives a string where a number belongs"
  done_it
fi

# ===========================================================================
printf '\n%s\n' "apply — udev rule and error propagation"
# ===========================================================================

if it "writes a udev rule pointing at the profile switcher"; then
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  stub powerprofilesctl
  out=$(run_script power-advanced-apply)
  assert_json "$out" .success true
  rule=$(cat "$SANDBOX/udev/90-power-advanced.rules")
  assert_contains "$rule" 'SUBSYSTEM=="power_supply"' "matches power supply changes"
  assert_contains "$rule" "power-advanced-profile-switch" "invokes the switcher"
  done_it
fi

if it "reports a profile-switch failure instead of claiming success"; then
  # An invalid lid action makes the switcher exit non-zero. The old apply piped
  # it to /dev/null with `|| true` and printed success:true regardless.
  write_config "${CONFIG_MINIMAL/\"action\": \"ignore\"/\"action\": \"explode\"}"
  fake_supply AC Mains online=1
  stub powerprofilesctl
  out=$(run_script power-advanced-apply); status=$?
  assert_json "$out" .success false "no longer reports a false success"
  assert_eq "$status" 1 "exits non-zero"
  assert_contains "$out" "profile switch failed" "names what went wrong"
  done_it
fi

# ===========================================================================
printf '\n%s\n' "limit — argument validation on a root-executed script"
# ===========================================================================

run_limit() { env HOME="$SANDBOX/home" "$SCRIPTS/power-advanced-limit" "$@" 2>/dev/null; }

if [ "$(id -u)" -eq 0 ]; then
  it "limit: refuses to run unprivileged" && { skip "running as root"; done_it; }
else
  if it "limit: refuses to run unprivileged"; then
    out=$(run_limit 80 /sys/class/power_supply/BAT0 /etc/tmpfiles.d/90-power-advanced-limit.conf)
    assert_json "$out" .success false
    assert_contains "$out" "must be run as root"
    done_it
  fi
fi

# The validation below is reachable without root only when the root check is
# not the first thing that fires, so assert on the message rather than the
# exit path: as a normal user we can still prove the script never *writes*.
if it "limit: rejects a non-numeric limit"; then
  out=$(run_limit abc /sys/class/power_supply/BAT0 /etc/tmpfiles.d/x.conf)
  assert_json "$out" .success false
  done_it
fi

if it "limit: rejects paths outside /sys/class/power_supply"; then
  # This is the important one: the script runs as root via pkexec with
  # auth_admin_keep, so an unvalidated path argument would be an arbitrary
  # root write. The panel validating first is not a guarantee.
  for bad_path in /etc/passwd "/sys/class/power_supply/../../../etc" "/tmp/evil"; do
    out=$(run_limit 80 "$bad_path" /etc/tmpfiles.d/x.conf)
    if [ "$(printf '%s' "$out" | jq -r .success 2>/dev/null)" = "false" ]; then
      ok "$CURRENT — rejected $bad_path"
    else
      bad "accepted battery path $bad_path"
    fi
  done
  done_it
fi

if it "limit: rejects a tmpfiles path outside /etc/tmpfiles.d"; then
  for bad_path in /etc/passwd /etc/tmpfiles.d/../shadow "relative.conf"; do
    out=$(run_limit 80 /sys/class/power_supply/BAT0 "$bad_path")
    if [ "$(printf '%s' "$out" | jq -r .success 2>/dev/null)" = "false" ]; then
      ok "$CURRENT — rejected $bad_path"
    else
      bad "accepted tmpfiles path $bad_path"
    fi
  done
  done_it
fi

if it "limit: rejects a limit outside 50-100"; then
  for value in 0 10 49 101 999; do
    out=$(run_limit "$value" /sys/class/power_supply/BAT0 /etc/tmpfiles.d/x.conf)
    if [ "$(printf '%s' "$out" | jq -r .success 2>/dev/null)" = "false" ]; then
      ok "$CURRENT — rejected $value"
    else
      bad "accepted out-of-range limit $value"
    fi
  done
  done_it
fi

# ===========================================================================
printf '\n%s\n' "hygiene"
# ===========================================================================

if it "every script parses and is executable"; then
  for f in "$SCRIPTS"/power-advanced-*; do
    name=${f##*/}
    if ! bash -n "$f" 2>/dev/null; then bad "$name does not parse"; continue; fi
    if [ ! -x "$f" ]; then bad "$name is not executable"; continue; fi
    ok "$CURRENT — $name"
  done
  done_it
fi

if it "no script silences stderr into /dev/null"; then
  # The habit this suite exists to prevent: `2>&1` into /dev/null threw away
  # the error messages that make failures diagnosable.
  # `command -v x >/dev/null 2>&1` is a probe, not work being silenced, and
  # `2>&1 >/dev/null` is the deliberate capture-stderr idiom. What must never
  # come back is silencing a command that actually does something.
  hits=$(grep -nE '2>&1' "$SCRIPTS"/power-advanced-* "$SCRIPTS/lib.sh" \
    | grep -vE '^\S+:[0-9]+: *#' \
    | grep -vE 'command -v|systemctl cat|jq -e' \
    | grep -vE '2>&1 >/dev/null' || true)
  if [ -z "$hits" ]; then ok "$CURRENT"; else bad "stderr silenced on real work: $hits"; fi
  done_it
fi

if it "no script swallows a failure with || true on a real command"; then
  # Strip comments first -- apply documents the old `|| true` bug in prose.
  hits=$(sed 's/#.*//' "$SCRIPTS"/power-advanced-apply "$SCRIPTS"/power-advanced-limit \
    | grep -nE '\|\| *true' || true)
  if [ -z "$hits" ]; then ok "$CURRENT"; else bad "failures swallowed: $hits"; fi

  # And specifically: the delegation call must not be silenced or ignored.
  call=$(grep -n '"\$SWITCH" "\$CONFIG_FILE"' "$SCRIPTS/power-advanced-apply" | head -1)
  if [[ $call == *"|| true"* || $call == *">/dev/null 2>&1"* ]]; then
    bad "apply still silences the profile-switch call: $call"
  else
    ok "$CURRENT — delegation call reports failures"
  fi
  done_it
fi

# ===========================================================================
printf '\n%s\n' "orphan detection — plugin removed without uninstalling"
# ===========================================================================

orphan_fixture() {
  write_config "$CONFIG_MINIMAL"
  fake_supply AC Mains online=1
  fake_supply BAT0 Battery capacity=50
  stub powerprofilesctl
}

if it "runs normally when no marker was recorded"; then
  orphan_fixture
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state ac
  done_it
fi

if it "runs normally when the recorded plugin directory still exists"; then
  orphan_fixture
  mkdir -p "$SANDBOX/plugin"
  printf '%s\n' "$SANDBOX/plugin" >"$SANDBOX/plugin-dir"
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state ac
  done_it
fi

if it "stands down when the recorded plugin directory is gone"; then
  orphan_fixture
  printf '%s\n' "$SANDBOX/deleted" >"$SANDBOX/plugin-dir"
  out=$(run_script power-advanced-profile-switch)
  assert_eq "$out" "" "produces no output"
  done_it
fi

if it "exits 0 when orphaned so udev logs no failure"; then
  orphan_fixture
  printf '%s\n' "$SANDBOX/deleted" >"$SANDBOX/plugin-dir"
  code=0; run_script power-advanced-profile-switch >/dev/null || code=$?
  assert_eq "$code" 0 "exit status"
  done_it
fi

if it "does not switch the profile when orphaned"; then
  orphan_fixture
  printf '%s\n' "$SANDBOX/deleted" >"$SANDBOX/plugin-dir"
  run_script power-advanced-profile-switch >/dev/null || true
  assert_eq "$(calls_to powerprofilesctl)" "" "powerprofilesctl never called"
  done_it
fi

if it "says why it stood down"; then
  orphan_fixture
  printf '%s\n' "$SANDBOX/deleted" >"$SANDBOX/plugin-dir"
  run_script power-advanced-profile-switch >/dev/null || true
  assert_contains "$(stderr_of)" "uninstall.sh" "points at the fix"
  done_it
fi

if it "keeps running on an empty marker rather than standing down"; then
  orphan_fixture
  : >"$SANDBOX/plugin-dir"
  out=$(run_script power-advanced-profile-switch)
  assert_json "$out" .state ac "a corrupt marker must not disable the backend"
  done_it
fi

# ===========================================================================

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%s  %d passed' "$(green "PASS")" "$PASS"
else
  printf '%s  %d passed, %d failed' "$(red "FAIL")" "$PASS" "$FAIL"
fi
[ "$SKIP" -gt 0 ] && printf ', %d skipped' "$SKIP"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n%s\n' "$(red "failures:")"
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
fi
printf '\n'
exit $(( FAIL > 0 ? 1 : 0 ))
