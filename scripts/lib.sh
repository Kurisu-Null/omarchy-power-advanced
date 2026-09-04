# shellcheck shell=bash
#
# Shared helpers for the Power Advanced backend scripts.
#
# Sourced, never executed. Everything here is prefixed pa_ so it cannot collide
# with the callers' variables. The point of this file is that config resolution,
# config reading, JSON replies and path validation each exist exactly once --
# they used to be copy-pasted across four scripts, which is how a rename ended
# up touching five files.

# Config file basenames, in preference order. The upstream name is kept as a
# fallback so a config from onlyvishesh.power-manager still works.
readonly PA_CONFIG_NAMES=(
  "kurisu-null.power-advanced.json"
  "onlyvishesh.power-manager.json"
)

# Basename shared by every drop-in this plugin installs.
readonly PA_UNIT="90-power-advanced"

# --- output -----------------------------------------------------------------
#
# Callers are machine-read by the panel, so stdout is strictly one JSON object.
# Diagnostics go to stderr, which the panel forwards to the journal and udev
# captures -- that is the whole reason not to redirect stderr to /dev/null.

pa_log() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

pa_fail() {
  jq -cn --arg e "$1" '{success: false, errors: [$e]}'
  exit "${2:-1}"
}

# pa_ok '{"applied":["udev"]}'  ->  {"success":true,"applied":["udev"]}
pa_ok() {
  jq -cn --argjson extra "${1:-\{\}}" '{success: true} + $extra'
}

pa_require() {
  command -v "$1" >/dev/null 2>&1 || pa_fail "required command not found: $1"
}

# --- config -----------------------------------------------------------------

# Echo the first config file that exists, or nothing. $1 may be an explicit
# path (from argv or OMARCHY_POWER_CONF) which wins outright.
pa_resolve_config() {
  local explicit=${1:-}
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  local name home
  for name in "${PA_CONFIG_NAMES[@]}"; do
    # Running under sudo, $HOME is root's; the config belongs to the caller.
    if [ -n "${SUDO_USER:-}" ]; then
      home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
      [ -n "$home" ] && [ -f "$home/.config/$name" ] && { printf '%s\n' "$home/.config/$name"; return 0; }
    fi
    [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/$name" ] && { printf '%s\n' "$XDG_CONFIG_HOME/$name"; return 0; }
    [ -n "${HOME:-}" ] && [ -f "$HOME/.config/$name" ] && { printf '%s\n' "$HOME/.config/$name"; return 0; }
    # Invoked from udev there is no user context at all, so fall back to a scan.
    for home in /home/*; do
      [ -f "$home/.config/$name" ] && { printf '%s\n' "$home/.config/$name"; return 0; }
    done
  done
  return 1
}

# Read every value the backend needs in ONE jq call and assign them to
# PA_* globals. The old code ran sixteen separate jq processes per invocation,
# and this script runs from udev on every AC plug and unplug.
#
# jq applies the defaults, so a malformed or absent key yields the documented
# fallback rather than an empty string that later fails an arithmetic test.
pa_read_config() {
  local file=$1 line
  jq empty "$file" 2>/dev/null || return 1

  line=$(jq -r '
    def num(v; dflt): (v | if type == "number" then floor else dflt end);
    def str(v; dflt): (v | if type == "string" and length > 0 then . else dflt end);
    [
      (if (has("enabled") and .enabled == false) then "false" else "true" end),
      str(.profiles.ac;           "performance"),
      str(.profiles.batteryHigh;  "balanced"),
      str(.profiles.batteryLow;   "power-saver"),
      num(.batteryThreshold;      30),
      (if .brightness.auto == true then "true" else "false" end),
      num(.brightness.ac;          80),
      num(.brightness.batteryHigh; 50),
      num(.brightness.batteryLow;  20),
      # One system-wide HibernateDelaySec, so one key.
      num(.hibernateAfterMinutes; 30),
      (if .lid.ignoreLidClose == true then "true" else "false" end),
      str(.lid.ac.action;          "suspend"),
      str(.lid.batteryHigh.action; "suspend"),
      str(.lid.batteryLow.action;  "suspend")
    ] | @tsv' "$file") || return 1

  IFS=$'\t' read -r \
    PA_ENABLED \
    PA_PROF_AC PA_PROF_BAT_HIGH PA_PROF_BAT_LOW \
    PA_BAT_THRESHOLD \
    PA_BRIGHT_AUTO PA_BRIGHT_AC PA_BRIGHT_BAT_HIGH PA_BRIGHT_BAT_LOW \
    PA_HIB_MINUTES \
    PA_LID_IGNORE PA_LID_AC PA_LID_BAT_HIGH PA_LID_BAT_LOW \
    <<<"$line"
}

# --- power source -----------------------------------------------------------

# True when the plugin directory recorded at install time no longer exists.
#
# Omarchy has no plugin-remove hook, so `omarchy plugin remove` can delete the
# panel while leaving this root-owned backend behind. The udev rule would then go
# on switching profiles forever on behalf of a plugin that is not installed, with
# no UI to explain it. install.sh records the directory it was run from; if that
# is gone, we treat ourselves as orphaned and stand down.
pa_orphaned() {
  local marker=${OMARCHY_PLUGIN_MARKER:-$1/plugin-dir}
  local dir
  [ -f "$marker" ] || return 1
  dir=$(cat "$marker" 2>/dev/null) || return 1
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] && return 1
  return 0
}


# Sets PA_AC_ONLINE, PA_BATTERY_PRESENT, PA_BATTERY_CAPACITY (mean %, 100 if
# unknown). Overridable root for tests.
pa_read_power_supply() {
  local root=${OMARCHY_POWER_SUPPLY_PATH:-/sys/class/power_supply}
  local supply type cap count=0 sum=0

  PA_AC_ONLINE=false
  PA_BATTERY_PRESENT=false
  PA_BATTERY_CAPACITY=100
  [ -d "$root" ] || return 0

  for supply in "$root"/*; do
    [ -d "$supply" ] || continue
    type=$(cat "$supply/type" 2>/dev/null || true)

    case $type in
      Mains | USB | USB_PD | USB_C)
        if [ "$(tr -d '[:space:]' <"$supply/online" 2>/dev/null)" = "1" ]; then
          PA_AC_ONLINE=true
        fi
        continue
        ;;
    esac

    if [ "$type" = "Battery" ] || [[ ${supply##*/} =~ ^BAT[0-9]+$ ]]; then
      PA_BATTERY_PRESENT=true
      cap=$(tr -d '[:space:]' <"$supply/capacity" 2>/dev/null || true)
      if [[ $cap =~ ^[0-9]+$ ]]; then
        sum=$((sum + cap))
        count=$((count + 1))
      fi
    fi
  done

  [ "$count" -gt 0 ] && PA_BATTERY_CAPACITY=$((sum / count))
  return 0
}

# Which ruleset applies: ac | batteryHigh | batteryLow. Mirrors
# Model.currentStateKey() in the panel, and the two must agree.
pa_state_key() {
  if [ "$PA_AC_ONLINE" = true ] || [ "$PA_BATTERY_PRESENT" = false ]; then
    printf 'ac\n'
  elif [ "$PA_BATTERY_CAPACITY" -le "$PA_BAT_THRESHOLD" ]; then
    printf 'batteryLow\n'
  else
    printf 'batteryHigh\n'
  fi
}

# --- validation -------------------------------------------------------------
#
# These scripts run as root through polkit, so every value that arrives from
# argv is untrusted -- the panel validating it first is not a guarantee, and
# auth_admin_keep means any local process can invoke the action once the
# password has been cached.

pa_valid_battery_path() {
  [[ $1 =~ ^/sys/class/power_supply/[A-Za-z0-9_][A-Za-z0-9_.:@-]*$ ]] && [ -d "$1" ]
}

pa_valid_tmpfiles_path() {
  [[ $1 =~ ^/etc/tmpfiles\.d/[A-Za-z0-9_.-]+\.conf$ ]]
}

# A path safe to interpolate into a udev RUN+= directive: no quotes, no
# newlines, no backslashes, nothing that could close the string and inject
# another directive.
pa_valid_udev_arg() {
  [[ $1 =~ ^[A-Za-z0-9_./@:+-]+$ ]]
}

pa_valid_lid_action() {
  case $1 in
    ignore | poweroff | reboot | halt | kexec | suspend | hibernate | \
      hybrid-sleep | suspend-then-hibernate | lock | factory-reset) return 0 ;;
    *) return 1 ;;
  esac
}
