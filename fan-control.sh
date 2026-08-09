#!/bin/bash
###############################################################################
# UniFi Intelligent Fan Controller
###############################################################################

umask 077

###[ CONFIGURATION ]###########################################################
CONFIG_FILE="${FAN_CONTROL_CONFIG_FILE:-/data/fan-control/config}"
TEMP_STATE_FILE="${FAN_CONTROL_TEMP_STATE_FILE:-/data/fan-control/temp_state}"
HWMON_BASE="${FAN_CONTROL_HWMON_BASE:-/sys/class/hwmon}"
VERSION_FILE="${FAN_CONTROL_VERSION_FILE:-/data/fan-control/VERSION}"
DRIVE_DEV_DIR="${FAN_CONTROL_DRIVE_DEV_DIR:-/dev}"

# Define default configuration values
DEFAULT_MIN_PWM=91                                    # Minimum active fan speed (0-255)
DEFAULT_MAX_PWM=255                                   # Maximum fan speed (0-255)
DEFAULT_MIN_TEMP=60                                   # Base threshold (°C)
DEFAULT_MAX_TEMP=85                                   # Critical temperature (°C)
DEFAULT_HYSTERESIS=5                                  # Temperature buffer (°C)
DEFAULT_CHECK_INTERVAL=15                             # Base check interval (seconds)
DEFAULT_TAPER_MINS=90                                 # Cool-down duration (minutes)
DEFAULT_FAN_PWM_AUTODETECT=true                       # Auto-detect all active fan PWM channels
DEFAULT_FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1" # Only used when FAN_PWM_AUTODETECT=false
DEFAULT_OPTIMAL_PWM_FILE="${FAN_CONTROL_OPTIMAL_PWM_FILE:-/data/fan-control/optimal_pwm}"
DEFAULT_MAX_PWM_STEP=25 # Max PWM change per adjustment
DEFAULT_DEADBAND=1      # Temp stability threshold (°C)
DEFAULT_ALPHA=20        # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
DEFAULT_LEARNING_RATE=5 # PWM optimization step size
DEFAULT_DRIVE_TEMP_ENABLED=auto
DEFAULT_DRIVE_MIN_TEMP=50
DEFAULT_DRIVE_MAX_TEMP=70
DEFAULT_DRIVE_CHECK_INTERVAL=60

# Create config file if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t fan-control "CONFIG: Creating new config file"

    # Create directory if it doesn't exist
    config_dir=$(dirname "$CONFIG_FILE")
    if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir" 2>/dev/null; then
            logger -t fan-control "FATAL: Failed to create config directory: $config_dir"
            exit 1
        fi
    fi

    # Use a temporary file and atomic move to prevent partial writes
    temp_config="${CONFIG_FILE}.tmp"
    if ! cat >"$temp_config" <<-DEFAULTS 2>/dev/null; then
MIN_PWM=$DEFAULT_MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$DEFAULT_MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$DEFAULT_MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$DEFAULT_MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$DEFAULT_HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$DEFAULT_TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$DEFAULT_FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$DEFAULT_OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$DEFAULT_MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEFAULT_DEADBAND             # Temp stability threshold (°C)
ALPHA=$DEFAULT_ALPHA               # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
LEARNING_RATE=$DEFAULT_LEARNING_RATE        # PWM optimization step size
DRIVE_TEMP_ENABLED=$DEFAULT_DRIVE_TEMP_ENABLED
DRIVE_MIN_TEMP=$DEFAULT_DRIVE_MIN_TEMP
DRIVE_MAX_TEMP=$DEFAULT_DRIVE_MAX_TEMP
DRIVE_CHECK_INTERVAL=$DEFAULT_DRIVE_CHECK_INTERVAL
DEFAULTS
        logger -t fan-control "FATAL: Failed to write to temporary config file"
        exit 1
    elif ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "FATAL: Failed to create config file"
        rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
        exit 1
    else
        logger -t fan-control "CONFIG: New configuration file created successfully"
    fi
fi

# Source the config file
# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null

# Check if each required parameter is defined, and add missing ones
missing_params=()
missing_values=()
missing_comments=()

check_param() {
    local param=$1
    local default_value=$2
    local comment=$3

    if ! grep -q "^${param}=" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "CONFIG: Missing parameter detected: $param"
        missing_params+=("$param")
        missing_values+=("$default_value")
        missing_comments+=("$comment")
        # Set the value in the current environment
        eval "${param}=${default_value}"
    fi
}

# Check each parameter
check_param "MIN_PWM" "$DEFAULT_MIN_PWM" "# Minimum active fan speed (0-255)"
check_param "MAX_PWM" "$DEFAULT_MAX_PWM" "# Maximum fan speed (0-255)"
check_param "MIN_TEMP" "$DEFAULT_MIN_TEMP" "# Base threshold (°C)"
check_param "MAX_TEMP" "$DEFAULT_MAX_TEMP" "# Critical temperature (°C)"
check_param "HYSTERESIS" "$DEFAULT_HYSTERESIS" "# Temperature buffer (°C)"
check_param "CHECK_INTERVAL" "$DEFAULT_CHECK_INTERVAL" "# Base check interval (seconds)"
check_param "TAPER_MINS" "$DEFAULT_TAPER_MINS" "# Cool-down duration (minutes)"
check_param "FAN_PWM_AUTODETECT" "$DEFAULT_FAN_PWM_AUTODETECT" "# Auto-detect all active fan PWM channels"
check_param "FAN_PWM_DEVICE" "\"$DEFAULT_FAN_PWM_DEVICE\"" "# Fan PWM device path (only used when FAN_PWM_AUTODETECT=false)"
check_param "OPTIMAL_PWM_FILE" "\"$DEFAULT_OPTIMAL_PWM_FILE\"" "# Optimal PWM file path"
check_param "MAX_PWM_STEP" "$DEFAULT_MAX_PWM_STEP" "# Max PWM change per adjustment"
check_param "DEADBAND" "$DEFAULT_DEADBAND" "# Temp stability threshold (°C)"
check_param "ALPHA" "$DEFAULT_ALPHA" "# Smoothing factor (0-100)"
check_param "LEARNING_RATE" "$DEFAULT_LEARNING_RATE" "# PWM optimization step size"
check_param "DRIVE_TEMP_ENABLED" "$DEFAULT_DRIVE_TEMP_ENABLED" "# Enable drive temperature PWM floor (auto, true, false)"
check_param "DRIVE_MIN_TEMP" "$DEFAULT_DRIVE_MIN_TEMP" "# Drive temperature where PWM floor begins (°C)"
check_param "DRIVE_MAX_TEMP" "$DEFAULT_DRIVE_MAX_TEMP" "# Drive temperature where PWM floor reaches maximum (°C)"
check_param "DRIVE_CHECK_INTERVAL" "$DEFAULT_DRIVE_CHECK_INTERVAL" "# Drive temperature polling interval (seconds)"

# If missing parameters were found, update the config file atomically
if [ ${#missing_params[@]} -gt 0 ]; then
    logger -t fan-control "CONFIG: Updating configuration file with ${#missing_params[@]} missing parameters"

    # Create a temporary file
    temp_config="${CONFIG_FILE}.tmp"

    # Copy existing config to temp file
    if ! cp "$CONFIG_FILE" "$temp_config" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to create temporary config file for update"
        # Continue with current in-memory values, but don't update the file
    else
        # Add each missing parameter
        update_failed=false
        for i in "${!missing_params[@]}"; do
            if ! echo "${missing_params[$i]}=${missing_values[$i]}        ${missing_comments[$i]}" >>"$temp_config" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to add parameter ${missing_params[$i]} to config file"
                update_failed=true
                break
            fi
        done

        if [ "$update_failed" = true ]; then
            logger -t fan-control "ERROR: Config file update failed"
            rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
        else
            # Replace the original file with the updated one
            if ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to update config file"
                rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
            else
                logger -t fan-control "CONFIG: Configuration file updated successfully"
            fi
        fi
    fi
fi

###[ CONFIG MIGRATION ]########################################################
# Migrate configs from older versions of fan-control
# This block runs once per upgrade and rewrites the config file with updated
# parameter names, comments, and structure. It is idempotent.
migrate_config() {
    local needs_migration=false
    local migration_reasons=()

    # Migration 1: FAN_PWM_DEVICE pointing to a raw sysfs device path
    # Older versions on UDM-SE required manually setting the raw path.
    # With auto-detection, this is no longer needed — reset to the standard default
    # so users aren't confused by a stale raw path when FAN_PWM_AUTODETECT=true.
    if [[ "$FAN_PWM_AUTODETECT" != "false" ]] &&
        [[ "$FAN_PWM_DEVICE" != "$DEFAULT_FAN_PWM_DEVICE" ]] &&
        [[ "$FAN_PWM_DEVICE" != "/sys/class/hwmon/hwmon0/pwm1" ]]; then
        migration_reasons+=("FAN_PWM_DEVICE reset to default (was: $FAN_PWM_DEVICE)")
        FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"
        needs_migration=true
    fi

    [[ "$needs_migration" = false ]] && return 0

    for reason in "${migration_reasons[@]}"; do
        logger -t fan-control "MIGRATE: $reason"
    done

    # Rewrite config with migrated values atomically
    local temp_config="${CONFIG_FILE}.tmp"
    if cat >"$temp_config" <<-CONFIG 2>/dev/null; then
MIN_PWM=$MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEADBAND             # Temp stability threshold (°C)
ALPHA=$ALPHA               # Smoothing factor (0-100)
LEARNING_RATE=$LEARNING_RATE        # PWM optimization step size
DRIVE_TEMP_ENABLED=$DRIVE_TEMP_ENABLED
DRIVE_MIN_TEMP=$DRIVE_MIN_TEMP
DRIVE_MAX_TEMP=$DRIVE_MAX_TEMP
DRIVE_CHECK_INTERVAL=$DRIVE_CHECK_INTERVAL
CONFIG
        if mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
            logger -t fan-control "MIGRATE: Config file updated successfully"
        else
            logger -t fan-control "MIGRATE: Failed to update config file"
            rm -f "$temp_config" 2>/dev/null
        fi
    else
        logger -t fan-control "MIGRATE: Failed to write temporary config file"
        rm -f "$temp_config" 2>/dev/null
    fi
}

migrate_config

# Validate configuration parameters
validate_config() {
    local param=$1
    local value=$2
    local min=$3
    local max=$4
    local default=$5

    if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < min || value > max)); then
        logger -t fan-control "CONFIG: Invalid $param value: $value (should be between $min and $max), using default: $default"
        eval "${param}=${default}"
        return 1
    fi
    return 0
}

# Validate numeric parameters
config_changed=false

validate_config "MIN_PWM" "$MIN_PWM" 0 255 "$DEFAULT_MIN_PWM" || config_changed=true
validate_config "MAX_PWM" "$MAX_PWM" "${MIN_PWM:-$DEFAULT_MIN_PWM}" 255 "$DEFAULT_MAX_PWM" || config_changed=true
validate_config "MIN_TEMP" "$MIN_TEMP" 30 80 "$DEFAULT_MIN_TEMP" || config_changed=true
validate_config "MAX_TEMP" "$MAX_TEMP" "$MIN_TEMP" 100 "$DEFAULT_MAX_TEMP" || config_changed=true
validate_config "HYSTERESIS" "$HYSTERESIS" 1 15 "$DEFAULT_HYSTERESIS" || config_changed=true
validate_config "CHECK_INTERVAL" "$CHECK_INTERVAL" 5 60 "$DEFAULT_CHECK_INTERVAL" || config_changed=true
validate_config "TAPER_MINS" "$TAPER_MINS" 1 240 "$DEFAULT_TAPER_MINS" || config_changed=true
validate_config "MAX_PWM_STEP" "$MAX_PWM_STEP" 1 50 "$DEFAULT_MAX_PWM_STEP" || config_changed=true
validate_config "DEADBAND" "$DEADBAND" 0 10 "$DEFAULT_DEADBAND" || config_changed=true
validate_config "ALPHA" "$ALPHA" 1 99 "$DEFAULT_ALPHA" || config_changed=true
validate_config "LEARNING_RATE" "$LEARNING_RATE" 1 20 "$DEFAULT_LEARNING_RATE" || config_changed=true
validate_config "DRIVE_MIN_TEMP" "$DRIVE_MIN_TEMP" 30 90 "$DEFAULT_DRIVE_MIN_TEMP" || config_changed=true
validate_config "DRIVE_MAX_TEMP" "$DRIVE_MAX_TEMP" 40 95 "$DEFAULT_DRIVE_MAX_TEMP" || config_changed=true
validate_config "DRIVE_CHECK_INTERVAL" "$DRIVE_CHECK_INTERVAL" 15 600 "$DEFAULT_DRIVE_CHECK_INTERVAL" || config_changed=true
if [[ "$DRIVE_TEMP_ENABLED" != "auto" && "$DRIVE_TEMP_ENABLED" != "true" && "$DRIVE_TEMP_ENABLED" != "false" ]]; then
    logger -t fan-control "CONFIG: Invalid DRIVE_TEMP_ENABLED value: $DRIVE_TEMP_ENABLED, using default: $DEFAULT_DRIVE_TEMP_ENABLED"
    DRIVE_TEMP_ENABLED=$DEFAULT_DRIVE_TEMP_ENABLED
    config_changed=true
fi
if ((DRIVE_MAX_TEMP <= DRIVE_MIN_TEMP)); then
    logger -t fan-control "CONFIG: DRIVE_MAX_TEMP must exceed DRIVE_MIN_TEMP, using defaults"
    DRIVE_MIN_TEMP=$DEFAULT_DRIVE_MIN_TEMP
    DRIVE_MAX_TEMP=$DEFAULT_DRIVE_MAX_TEMP
    config_changed=true
fi

# If any config values were corrected, update the config file
if [ "$config_changed" = true ]; then
    logger -t fan-control "CONFIG: Updating configuration file with corrected values"

    # Create a temporary file
    temp_config="${CONFIG_FILE}.tmp"

    # Write corrected values to temp file
    if ! cat >"$temp_config" <<-CONFIG 2>/dev/null; then
MIN_PWM=$MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEADBAND             # Temp stability threshold (°C)
ALPHA=$ALPHA               # Smoothing factor (0-100)
LEARNING_RATE=$LEARNING_RATE        # PWM optimization step size
DRIVE_TEMP_ENABLED=$DRIVE_TEMP_ENABLED
DRIVE_MIN_TEMP=$DRIVE_MIN_TEMP
DRIVE_MAX_TEMP=$DRIVE_MAX_TEMP
DRIVE_CHECK_INTERVAL=$DRIVE_CHECK_INTERVAL
CONFIG
        logger -t fan-control "ERROR: Failed to write to temporary config file"
        # Continue with current in-memory values, but don't update the file
    elif ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to update config file with corrected values"
        rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
    else
        logger -t fan-control "CONFIG: Configuration file updated with corrected values"
    fi
fi

# Derived values
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS))
TAPER_DURATION=$((TAPER_MINS * 60))

###[ RUNTIME CHECKS ]##########################################################
# Check for ubnt-systool availability
if ! command -v ubnt-systool >/dev/null 2>&1; then
    logger -t fan-control "FATAL: ubnt-systool command not found"
    exit 1
fi

###[ PWM DEVICE DETECTION ]####################################################
# Detect all active fan PWM channels
# Populates the FAN_PWM_DEVICES array with writable PWM paths that have spinning fans
detect_pwm_devices() {
    local candidates=()
    local detected=()
    local writable=()

    # Strategy 1: look for pwm files directly in hwmon class directories
    # Works on: UCG-Max (lm63 driver), UNVR (adt7475, kernel exposes class symlinks)
    for pwm_file in "$HWMON_BASE"/hwmon*/pwm[1-9]; do
        [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
    done

    # Strategy 2: if no class-level pwm files found, resolve via raw device paths
    # Needed for UDM-SE where adt7475 driver does not expose pwm in the class dir
    if [[ ${#candidates[@]} -eq 0 ]]; then
        logger -t fan-control "DETECT: No pwm in hwmon class dirs, falling back to raw device paths"
        for hwmon_dir in "$HWMON_BASE"/hwmon*; do
            local dev_path
            dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
            for pwm_file in "$dev_path"/pwm[1-9]; do
                [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
            done
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        logger -t fan-control "FATAL: No PWM devices found in /sys"
        exit 1
    fi

    # Filter candidates to channels that are writable and have a spinning fan
    for pwm_file in "${candidates[@]}"; do
        local pwm_dir
        pwm_dir=$(dirname "$pwm_file")
        local pwm_name
        pwm_name=$(basename "$pwm_file")
        local fan_num="${pwm_name#pwm}"
        local fan_input="${pwm_dir}/fan${fan_num}_input"
        local rpm=0

        [[ -f "$fan_input" ]] && rpm=$(cat "$fan_input" 2>/dev/null || echo 0)

        # Test actual writability by writing the current value back
        # (sysfs file permissions are unreliable — a file may show 644 but still be writable by root)
        local current_val
        current_val=$(cat "$pwm_file" 2>/dev/null) || continue
        if ! echo "$current_val" >"$pwm_file" 2>/dev/null; then
            logger -t fan-control "DETECT: ${pwm_file} not writable, skipping"
            continue
        fi
        writable+=("$pwm_file")

        if ((rpm > 0)); then
            detected+=("$pwm_file")
            logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = ${rpm} RPM (active)"
        else
            logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = 0 RPM (skipped)"
        fi
    done

    # If no fans were spinning, fall back to all writable PWM channels
    # (handles cold boot or devices where fans only spin when PWM > 0)
    if [[ ${#detected[@]} -eq 0 ]]; then
        logger -t fan-control "DETECT: No spinning fans found, using all writable PWM channels"
        for pwm_file in "${writable[@]}"; do
            detected+=("$pwm_file")
        done
    fi

    if [[ ${#detected[@]} -eq 0 ]]; then
        logger -t fan-control "FATAL: No writable PWM devices found"
        exit 1
    fi

    FAN_PWM_DEVICES=("${detected[@]}")
    logger -t fan-control "DETECT: Controlling ${#FAN_PWM_DEVICES[@]} fan(s): ${FAN_PWM_DEVICES[*]}"

    for pwm_file in "${writable[@]}"; do
        local controlled=false
        local controlled_pwm
        local current_val

        for controlled_pwm in "${FAN_PWM_DEVICES[@]}"; do
            if [[ "$pwm_file" == "$controlled_pwm" ]]; then
                controlled=true
                break
            fi
        done

        if [[ "$controlled" == false ]]; then
            current_val=$(cat "$pwm_file" 2>/dev/null) || continue
            if [[ "$current_val" != 0 ]]; then
                logger -t fan-control "DETECT: ${pwm_file} = ${current_val} (not controlled)"
            fi
        fi
    done
}

# Determine PWM devices to control
FAN_PWM_DEVICES=()
if [[ "$FAN_PWM_AUTODETECT" != "false" ]]; then
    detect_pwm_devices
else
    # Manual override — validate the configured single device
    logger -t fan-control "DETECT: Auto-detect disabled, using configured device: $FAN_PWM_DEVICE"
    _current_val=$(cat "$FAN_PWM_DEVICE" 2>/dev/null) || {
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not readable"
        exit 1
    }
    if ! echo "$_current_val" >"$FAN_PWM_DEVICE" 2>/dev/null; then
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not writable"
        exit 1
    fi
    unset _current_val
    FAN_PWM_DEVICES=("$FAN_PWM_DEVICE")
fi

# Ensure directories for state files exist
mkdir -p "$(dirname "$TEMP_STATE_FILE")" "$(dirname "$OPTIMAL_PWM_FILE")" || {
    logger -t fan-control "FATAL: Failed to create required directories"
    exit 1
}

# Single instance lock + cleanup — FD held for the daemon's lifetime
# flock is the authoritative guard; stale PID ps-checks can false-positive on PID reuse.
PID_FILE="${FAN_CONTROL_PID_FILE:-/var/run/fan-control.pid}"

cleanup() {
    for _d in "${FAN_PWM_DEVICES[@]}"; do
        echo 0 >"$_d" 2>/dev/null
    done
    rm -f "$PID_FILE" 2>/dev/null
}

# Open the lock FD WITHOUT truncating (>>) so a running instance's PID isn't clobbered
exec 200>>"$PID_FILE"
if ! flock -n 200; then
    logger -t fan-control "ALERT: Another instance already holds the lock (PID $(cat "$PID_FILE" 2>/dev/null))"
    exit 1
fi
echo $$ >"$PID_FILE"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

###[ CORE FUNCTIONALITY ]######################################################
# State definitions
STATE_OFF=0       # Fan completely off
STATE_TAPER=1     # Cooling down period before turning off
STATE_ACTIVE=2    # Normal operation with temperature-based fan speed
STATE_EMERGENCY=3 # Critical temperature, maximum fan speed

# Runtime variables
CURRENT_STATE=$STATE_OFF
TAPER_START=0        # Timestamp when taper mode started
LAST_PWM=-1          # Last PWM value set
SMOOTHED_TEMP=50     # Current smoothed temperature
LAST_ADJUSTMENT=0    # Timestamp of last PWM optimization
LAST_AVG_TEMP=0      # Previous temperature (for deadband calculations)
TEMP_READ_FAILURES=0 # Track consecutive temperature reading failures
DRIVE_TEMP_AVAILABLE=false
DRIVE_DEVICES=()
DRIVE_METHODS=()
DRIVE_READ_FAILURE_LOGGED=()
DRIVE_STANDBY_LOGGED=()
DRIVE_TEMP=0
DRIVE_WARNING_TEMP="unknown"
DRIVE_READ_STATE="failed"
DRIVE_PWM_FLOOR=0
DRIVE_FLOOR_DEVICE=""
DRIVE_LAST_FLOOR_DEVICE=""
DRIVE_LAST_FLOOR_TEMP=0
DRIVE_LAST_FLOOR_PWM=0
DRIVE_LAST_CHECK=0
DRIVE_ALL_READ_FAILURE_LOGGED=false

# Function to safely write to a file using atomic operations
atomic_write_file() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp"

    if ! echo "$content" >"$temp_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to write to temporary file for $target_file"
        return 1
    elif ! mv "$temp_file" "$target_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to update file $target_file"
        rm -f "$temp_file" 2>/dev/null # Clean up the temporary file
        return 1
    fi
    return 0
}

# Initialize smoothed temp from state file or raw temp
raw_temp=$(ubnt-systool cputemp | awk '{print int($1)}' || echo 50)
if [[ -f "$TEMP_STATE_FILE" ]]; then
    saved_temp=$(cat "$TEMP_STATE_FILE" 2>/dev/null)
    # Validate saved temperature is a number and within reasonable range
    if [[ "$saved_temp" =~ ^[0-9]+$ ]] && ((saved_temp >= 20 && saved_temp <= 100)); then
        # Don't use saved temp if it's too far from current raw temp (prevents large jumps)
        # Compute the real absolute difference |saved - raw| — the previous
        # `${saved_temp#-} - ${raw_temp#-}` form only stripped a leading minus
        # from each operand independently and did NOT take |saved - raw|, so a
        # hot restart with a stale low saved temp (raw > saved) always passed
        # the < 15 guard and re-initialised SMOOTHED_TEMP to the stale value,
        # potentially keeping the fan OFF on a hot boot until the next loop tick.
        init_delta=$((saved_temp - raw_temp))
        ((init_delta < 0)) && init_delta=$((-init_delta))
        if ((init_delta < 15)); then
            SMOOTHED_TEMP=$saved_temp
            logger -t fan-control "INIT: Loaded saved temp=${SMOOTHED_TEMP}°C | Raw=${raw_temp}°C"
        else
            SMOOTHED_TEMP=$raw_temp
            logger -t fan-control "INIT: Discarded saved temp=${saved_temp}°C (too far from raw=${raw_temp}°C)"
        fi
    else
        SMOOTHED_TEMP=$raw_temp
        logger -t fan-control "INIT: Invalid saved temp=${saved_temp}°C, using raw=${raw_temp}°C"
    fi
else
    SMOOTHED_TEMP=$raw_temp
    logger -t fan-control "INIT: No saved temp, using raw=${raw_temp}°C"
fi

# MUST be called directly, never via $(...) — state must persist in the parent shell.
get_smoothed_temp() {
    local raw_temp_output
    raw_temp_output=$(ubnt-systool cputemp 2>/dev/null)
    local raw_temp

    # Check if we got valid output
    if [[ -z "$raw_temp_output" ]] || ! [[ "$raw_temp_output" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        TEMP_READ_FAILURES=$((TEMP_READ_FAILURES + 1))
        logger -t fan-control "ERROR: Failed to read temperature (attempt $TEMP_READ_FAILURES)"
        # Use last known temperature — fail-safe decision is in update_fan_state
        raw_temp=$SMOOTHED_TEMP
    else
        # Reset failure counter on successful read
        TEMP_READ_FAILURES=0
        raw_temp=$(echo "$raw_temp_output" | awk '{print int($1)}')
    fi

    # Ensure we have a valid temperature value
    raw_temp=${raw_temp:-50}
    local previous=$SMOOTHED_TEMP

    # Calculate new smoothed temperature using exponential smoothing formula:
    # smoothed_temp = (α × previous_smooth + (100 - α) × raw_temp) / 100
    # where α (ALPHA) controls how much weight to give to previous vs. new readings
    # Use awk for floating-point arithmetic to prevent drift from integer rounding
    SMOOTHED_TEMP=$(awk "BEGIN { printf \"%.0f\", ($ALPHA * $SMOOTHED_TEMP + (100 - $ALPHA) * $raw_temp) / 100 }")

    # Safety check: If raw and smoothed temps differ by more than 20°C, reset smoothed temp
    local temp_diff=$((raw_temp - SMOOTHED_TEMP))
    if ((${temp_diff#-} > 20)); then
        logger -t fan-control "ALERT: Large temp difference detected (${temp_diff}°C) - resetting smoothed temp"
        SMOOTHED_TEMP=$raw_temp
    fi

    # Save smoothed temp to state file (only if it changed significantly)
    if ((${SMOOTHED_TEMP#-} - ${previous#-} != 0)); then
        atomic_write_file "$TEMP_STATE_FILE" "$SMOOTHED_TEMP"
    fi

    logger -t fan-control "TEMP:  RAW=${raw_temp}°C | SMOOTH=${SMOOTHED_TEMP}°C | DELTA=$((raw_temp - SMOOTHED_TEMP))°C"
}

calculate_speed() {
    local avg_temp=$1
    local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
    local temp_diff=$((avg_temp - FAN_ACTIVATION_TEMP))

    # Clamp to zero below the activation temperature: temp_diff is squared below,
    # which discards the sign, so a negative diff would otherwise re-inflate PWM
    # symmetrically with heating — making the fan speed up as the device cools (#26).
    if ((temp_diff < 0)); then
        temp_diff=0
    fi

    # Prevent division by zero
    ((temp_range > 0)) || temp_range=1

    # Quadratic response curve calculation:
    # PWM = MIN_PWM + (temp_diff²/temp_range²) * (MAX_PWM - MIN_PWM)
    # The formula is multiplied by 20 and divided by 10 to improve integer math precision
    local speed=$(((temp_diff * temp_diff * (MAX_PWM - MIN_PWM) * 20) / (temp_range * temp_range * 10)))
    speed=$((speed + MIN_PWM))

    # Ensure speed doesn't exceed MAX_PWM
    speed=$((speed > MAX_PWM ? MAX_PWM : speed))

    logger -t fan-control "CALC: temp_diff=${temp_diff}°C | range=${temp_range}°C | speed=${speed}pwm"
    echo $speed
}

json_number() {
    local json="$1"
    local field="$2"

    printf '%s\n' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | sed -n '1p'
}

json_object_number() {
    local json="$1"
    local object="$2"
    local field="$3"

    printf '%s\n' "$json" | sed -n "/\"${object}\"[[:space:]]*:[[:space:]]*{/,/}/ { s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p; }" | sed -n '1p'
}

read_nvme_temperature() {
    local device="$1"
    local smart_log
    local raw_temp
    local controller
    local warning_temp

    DRIVE_READ_STATE="failed"
    smart_log=$(nvme smart-log -o json "$device" 2>/dev/null) || return 1
    raw_temp=$(json_number "$smart_log" "temperature")
    [[ "$raw_temp" =~ ^[0-9]+$ ]] || return 1

    # nvme-cli reports SMART temperatures in Kelvin; smartctl uses Celsius.
    DRIVE_READ_TEMP=$((raw_temp - 273))
    ((DRIVE_READ_TEMP >= 0 && DRIVE_READ_TEMP <= 120)) || return 1

    controller=$(nvme id-ctrl -o json "$device" 2>/dev/null || true)
    warning_temp=$(json_number "$controller" "wctemp")
    if [[ "$warning_temp" =~ ^[0-9]+$ ]]; then
        if ((warning_temp >= 273)); then
            warning_temp=$((warning_temp - 273))
        fi
        DRIVE_WARNING_TEMP=$warning_temp
    else
        DRIVE_WARNING_TEMP="unknown"
    fi
    DRIVE_READ_STATE="readable"
}

read_smartctl_temperature() {
    local device="$1"
    local smart_log
    local raw_temp
    local warning_temp
    local smartctl_status

    DRIVE_READ_STATE="failed"
    if [[ "$device" == "$DRIVE_DEV_DIR"/sd? ]]; then
        # smartctl's standby exit is an expected idle state, not a broken thermal input.
        if smart_log=$(smartctl -n standby -j -a "$device" 2>/dev/null); then
            :
        else
            smartctl_status=$?
            if ((smartctl_status == 2)); then
                DRIVE_READ_STATE="asleep"
                return 2
            fi
            return 1
        fi
    elif ! smart_log=$(smartctl -j -a "$device" 2>/dev/null); then
        return 1
    fi
    raw_temp=$(json_number "$smart_log" "current")
    [[ "$raw_temp" =~ ^[0-9]+$ ]] || return 1
    ((raw_temp >= 0 && raw_temp <= 120)) || return 1

    DRIVE_READ_TEMP=$raw_temp
    warning_temp=$(json_object_number "$smart_log" "nvme_composite_temperature_threshold" "warning")
    if [[ "$warning_temp" =~ ^[0-9]+$ ]]; then
        DRIVE_WARNING_TEMP=$warning_temp
    else
        DRIVE_WARNING_TEMP="unknown"
    fi
    DRIVE_READ_STATE="readable"
}

calculate_drive_pwm_floor() {
    local drive_range=$((DRIVE_MAX_TEMP - DRIVE_MIN_TEMP))

    if ((DRIVE_TEMP <= DRIVE_MIN_TEMP)); then
        DRIVE_PWM_FLOOR=0
    elif ((DRIVE_TEMP >= DRIVE_MAX_TEMP)); then
        DRIVE_PWM_FLOOR=$MAX_PWM
    else
        DRIVE_PWM_FLOOR=$((MIN_PWM + ((DRIVE_TEMP - DRIVE_MIN_TEMP) * (MAX_PWM - MIN_PWM) / drive_range)))
    fi
}

detect_drive_temperature() {
    local device
    local device_found=false
    local warning_temp_display
    local method
    local hottest_index=-1
    local index

    [[ "$DRIVE_TEMP_ENABLED" != "false" ]] || return

    for device in "$DRIVE_DEV_DIR"/nvme?n? "$DRIVE_DEV_DIR"/sd?; do
        [[ -e "$device" ]] || continue
        device_found=true
        method="smartctl"

        if [[ "$device" == "$DRIVE_DEV_DIR"/nvme?n? ]]; then
            method="nvme"
            if read_nvme_temperature "$device"; then
                :
            elif read_smartctl_temperature "$device"; then
                method="smartctl"
            fi
        else
            read_smartctl_temperature "$device" || true
        fi

        DRIVE_DEVICES+=("$device")
        DRIVE_METHODS+=("$method")
        DRIVE_READ_FAILURE_LOGGED+=(false)
        DRIVE_STANDBY_LOGGED+=(false)
        index=$((${#DRIVE_DEVICES[@]} - 1))
        if [[ "$DRIVE_READ_STATE" = "readable" ]]; then
            warning_temp_display="not reported"
            if [[ "$DRIVE_WARNING_TEMP" =~ ^[0-9]+$ ]]; then
                warning_temp_display="${DRIVE_WARNING_TEMP}°C"
            fi
            logger -t fan-control "DRIVE: Detected ${device} via ${method} | Temp=${DRIVE_READ_TEMP}°C | wctemp=${warning_temp_display}"

            if ((hottest_index < 0 || DRIVE_READ_TEMP > DRIVE_TEMP)); then
                hottest_index=$index
                DRIVE_TEMP=$DRIVE_READ_TEMP
            fi
        elif [[ "$DRIVE_READ_STATE" = "asleep" ]]; then
            logger -t fan-control "DRIVE: ${device} is asleep; excluded from floor"
            DRIVE_STANDBY_LOGGED[index]=true
        else
            logger -t fan-control "DRIVE: ${device} read failed; excluding it from floor"
            DRIVE_READ_FAILURE_LOGGED[index]=true
        fi
    done

    if [[ "$device_found" = true ]]; then
        DRIVE_TEMP_AVAILABLE=true
        DRIVE_LAST_CHECK=$(date +%s)
    fi

    if ((hottest_index >= 0)); then
        DRIVE_FLOOR_DEVICE="${DRIVE_DEVICES[$hottest_index]}"
        calculate_drive_pwm_floor
        DRIVE_LAST_FLOOR_DEVICE=$DRIVE_FLOOR_DEVICE
        DRIVE_LAST_FLOOR_TEMP=$DRIVE_TEMP
        DRIVE_LAST_FLOOR_PWM=$DRIVE_PWM_FLOOR
        logger -t fan-control "DRIVE: ${DRIVE_FLOOR_DEVICE} drives floor | Temp=${DRIVE_TEMP}°C | Floor=${DRIVE_PWM_FLOOR}pwm"
    fi
}

update_drive_temperature() {
    local now
    local index
    local drive_read_ok=false
    local hottest_index=-1
    local any_asleep=false
    local any_failed=false

    [[ "$DRIVE_TEMP_AVAILABLE" = true ]] || return
    now=$(date +%s)
    if ((now - DRIVE_LAST_CHECK < DRIVE_CHECK_INTERVAL)); then
        return
    fi
    DRIVE_LAST_CHECK=$now

    for index in "${!DRIVE_DEVICES[@]}"; do
        drive_read_ok=false
        if [[ "${DRIVE_METHODS[$index]}" = "nvme" ]]; then
            if read_nvme_temperature "${DRIVE_DEVICES[$index]}"; then
                drive_read_ok=true
            fi
        fi

        if [[ "${DRIVE_METHODS[$index]}" = "smartctl" ]]; then
            if read_smartctl_temperature "${DRIVE_DEVICES[$index]}"; then
                drive_read_ok=true
            fi
        fi

        if [[ "$drive_read_ok" = true ]]; then
            if [[ "${DRIVE_STANDBY_LOGGED[$index]}" = true ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} woke; included in floor"
            elif [[ "${DRIVE_READ_FAILURE_LOGGED[$index]}" = true ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} read recovered"
            fi
            DRIVE_READ_FAILURE_LOGGED[index]=false
            DRIVE_STANDBY_LOGGED[index]=false

            if ((hottest_index < 0 || DRIVE_READ_TEMP > DRIVE_TEMP)); then
                hottest_index=$index
                DRIVE_TEMP=$DRIVE_READ_TEMP
            fi
        elif [[ "$DRIVE_READ_STATE" = "asleep" ]]; then
            any_asleep=true
            DRIVE_READ_FAILURE_LOGGED[index]=false
            if [[ "${DRIVE_STANDBY_LOGGED[$index]}" = false ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} is asleep; excluded from floor"
                DRIVE_STANDBY_LOGGED[index]=true
            fi
        else
            any_failed=true
            DRIVE_STANDBY_LOGGED[index]=false
            if [[ "${DRIVE_READ_FAILURE_LOGGED[$index]}" = false ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} read failed; excluding it from floor"
                DRIVE_READ_FAILURE_LOGGED[index]=true
            fi
        fi
    done

    if ((hottest_index >= 0)); then
        DRIVE_FLOOR_DEVICE="${DRIVE_DEVICES[$hottest_index]}"
        calculate_drive_pwm_floor
        DRIVE_ALL_READ_FAILURE_LOGGED=false
        if [[ "$DRIVE_FLOOR_DEVICE" != "$DRIVE_LAST_FLOOR_DEVICE" || "$DRIVE_TEMP" -ne "$DRIVE_LAST_FLOOR_TEMP" || "$DRIVE_PWM_FLOOR" -ne "$DRIVE_LAST_FLOOR_PWM" ]]; then
            logger -t fan-control "DRIVE: ${DRIVE_FLOOR_DEVICE} drives floor | Temp=${DRIVE_TEMP}°C | Floor=${DRIVE_PWM_FLOOR}pwm"
            DRIVE_LAST_FLOOR_DEVICE=$DRIVE_FLOOR_DEVICE
            DRIVE_LAST_FLOOR_TEMP=$DRIVE_TEMP
            DRIVE_LAST_FLOOR_PWM=$DRIVE_PWM_FLOOR
        fi
    else
        DRIVE_PWM_FLOOR=0
        DRIVE_FLOOR_DEVICE=""
        if [[ "$any_failed" = true && "$any_asleep" = false && "$DRIVE_ALL_READ_FAILURE_LOGGED" = false ]]; then
            logger -t fan-control "DRIVE: All cached drives unreadable; floor disabled"
            DRIVE_ALL_READ_FAILURE_LOGGED=true
        elif [[ "$any_asleep" = true ]]; then
            DRIVE_ALL_READ_FAILURE_LOGGED=false
        fi
    fi
}

# Speed control with logging
set_fan_speed() {
    local new_speed=$1
    local current_temp=$SMOOTHED_TEMP
    local reason="Normal operation"

    # Emergency override
    if ((current_temp >= MAX_TEMP)); then
        new_speed=$MAX_PWM
        reason="EMERGENCY: Temp ${current_temp}°C ≥ ${MAX_TEMP}°C"
    fi

    # Special handling for OFF state
    if ((CURRENT_STATE == STATE_OFF)); then
        new_speed=0 # Force 0 PWM regardless of other logic
        reason="OFF state override"
    else
        # Apply ramp limits only in non-OFF states
        if ((new_speed > LAST_PWM + MAX_PWM_STEP)); then
            reason="Ramp-up limited: ${LAST_PWM}→$((LAST_PWM + MAX_PWM_STEP))pwm"
            new_speed=$((LAST_PWM + MAX_PWM_STEP))
        elif ((new_speed < LAST_PWM - MAX_PWM_STEP)); then
            reason="Ramp-down limited: ${LAST_PWM}→$((LAST_PWM - MAX_PWM_STEP))pwm"
            new_speed=$((LAST_PWM - MAX_PWM_STEP))
        fi

        # Enforce MIN/MAX only in active states
        new_speed=$((new_speed > MAX_PWM ? MAX_PWM : new_speed))
        new_speed=$((new_speed < MIN_PWM ? MIN_PWM : new_speed))
    fi

    # The floor follows the OFF override so a hot drive can still start a cool CPU's fan.
    if ((DRIVE_PWM_FLOOR > new_speed)); then
        if ((DRIVE_PWM_FLOOR > LAST_PWM + MAX_PWM_STEP)); then
            new_speed=$((LAST_PWM + MAX_PWM_STEP))
            reason="Drive floor ramp-up: ${LAST_PWM}→${new_speed}pwm"
        else
            new_speed=$DRIVE_PWM_FLOOR
            reason="Drive temperature floor: ${DRIVE_TEMP}°C"
        fi
    fi

    if [[ "$new_speed" -ne "$LAST_PWM" ]]; then
        # Note: Due to hardware limitations, the actual PWM value applied may differ from the requested value
        # (e.g., setting 50 might result in ~48, or 100 might result in ~92)
        local write_ok=true
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            if ! echo "$new_speed" >"$pwm_dev" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to write to PWM device $pwm_dev"
                if [[ ! -e "$pwm_dev" ]]; then
                    logger -t fan-control "FATAL: PWM device $pwm_dev no longer exists"
                fi
                write_ok=false
            fi
        done
        if [[ "$write_ok" = true ]]; then
            logger -t fan-control "SET: ${LAST_PWM}→${new_speed}pwm | Reason: ${reason}"
            LAST_PWM=$new_speed
            LAST_AVG_TEMP=$current_temp # Reset deadband tracking on change
        fi

        if ((CURRENT_STATE == STATE_ACTIVE)); then
            local now
            now=$(date +%s)
            # More frequent learning for better adaptation (30 minutes instead of 1 hour)
            # Check if it's time to adjust the optimal PWM value (every 30 minutes)
            if ((now - LAST_ADJUSTMENT > 1800)); then
                local optimal
                optimal=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$MIN_PWM")
                # Validate optimal PWM value
                if ! [[ "$optimal" =~ ^[0-9]+$ ]] || ((optimal < MIN_PWM || optimal > MAX_PWM)); then
                    logger -t fan-control "WARNING: Invalid optimal PWM value: ${optimal}, using MIN_PWM"
                    optimal=$MIN_PWM
                fi
                local original_optimal=$optimal
                local adjustment=""
                local adaptive_rate=$LEARNING_RATE

                # Calculate temperature change and stability over time
                local temp_delta=$((current_temp - LAST_AVG_TEMP))
                local temp_stability=${temp_delta#-} # Use absolute value of temp_delta

                # Adjust learning rate based on temperature stability
                # More stable temperatures allow for more aggressive learning
                if ((temp_stability < DEADBAND)); then
                    # Temperature is stable, can use higher learning rate
                    adaptive_rate=$((LEARNING_RATE + 2))
                elif ((temp_stability > DEADBAND * 3)); then
                    # Temperature is fluctuating a lot, use lower learning rate
                    adaptive_rate=$((LEARNING_RATE - 1))
                    adaptive_rate=$((adaptive_rate < 1 ? 1 : adaptive_rate))
                fi

                # Enhanced learning logic with more responsive adjustments
                # 1. If we're at optimal speed but temp is rising, increase PWM
                # 2. If we're at optimal speed but temp is stable below MIN_TEMP, decrease PWM
                # 3. If we're above optimal speed but temp is stable, try to decrease PWM
                # 4. If temperature is rising rapidly, make larger adjustments
                if ((new_speed == optimal)); then
                    if ((temp_delta > 0 && current_temp > MIN_TEMP)); then
                        # Temperature rising, increase PWM proactively
                        # Scale adjustment based on how quickly temperature is rising
                        local rise_factor=$((temp_delta > 2 ? 2 : 1))
                        local adj_amount=$((adaptive_rate * rise_factor))
                        adjustment="+${adj_amount} (rising temp ${temp_delta}°C)"
                        optimal=$((optimal + adj_amount))
                    elif ((current_temp < MIN_TEMP && temp_stability < DEADBAND * 2)); then
                        # Temperature below threshold and stable, can reduce PWM
                        adjustment="-${adaptive_rate} (stable below threshold)"
                        optimal=$((optimal - adaptive_rate))
                    fi
                elif ((new_speed > optimal && temp_stability < DEADBAND && current_temp < MIN_TEMP + HYSTERESIS)); then
                    # We're running faster than optimal but temp is stable and not too high
                    # Try to gradually reduce optimal PWM to find the most efficient setting
                    adjustment="-1 (efficiency optimization)"
                    optimal=$((optimal - 1))
                # If we're below optimal speed but temperature is rising quickly
                elif ((new_speed < optimal && temp_delta > DEADBAND * 2)); then
                    # Temperature rising quickly while below optimal speed - increase optimal
                    adjustment="+${adaptive_rate} (rapid temp increase ${temp_delta}°C)"
                    optimal=$((optimal + adaptive_rate))
                fi

                if [[ -n "$adjustment" ]]; then
                    # Ensure optimal PWM stays within valid range
                    optimal=$((optimal > MAX_PWM ? MAX_PWM : optimal))
                    optimal=$((optimal < MIN_PWM ? MIN_PWM : optimal))

                    # Use atomic write function to update the optimal PWM file
                    if atomic_write_file "$OPTIMAL_PWM_FILE" "$optimal"; then
                        LAST_ADJUSTMENT=$now
                        logger -t fan-control "LEARNING: ${original_optimal}→${optimal}pwm (${adjustment}) [Rate=${adaptive_rate}]"
                    fi
                fi
            fi
        fi
    fi
}

###[ STATE MANAGEMENT ]########################################################
update_fan_state() {
    get_smoothed_temp
    update_drive_temperature
    local avg_temp=$SMOOTHED_TEMP
    local now
    now=$(date +%s)
    local state_transition=""

    # Sensor fail-safe: write MAX_PWM directly, bypassing state machine and ramp
    # limits (the OFF-state override in set_fan_speed would force 0).
    if ((TEMP_READ_FAILURES >= 3)); then
        if ((LAST_PWM != MAX_PWM)); then
            logger -t fan-control "ALERT: Sensor fail-safe active (${TEMP_READ_FAILURES} consecutive read failures) - forcing MAX_PWM"
        fi
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            echo "$MAX_PWM" >"$pwm_dev" 2>/dev/null
        done
        LAST_PWM=$MAX_PWM
        CURRENT_STATE=$STATE_ACTIVE # so recovery re-evaluates from a sane state
        return
    fi

    # Check for emergency condition first
    if ((avg_temp >= MAX_TEMP)); then
        if ((CURRENT_STATE != STATE_EMERGENCY)); then
            state_transition="→EMERGENCY (${avg_temp}°C ≥ ${MAX_TEMP}°C)"
            CURRENT_STATE=$STATE_EMERGENCY
            set_fan_speed "$MAX_PWM"
        else
            # Already in emergency state, ensure max fan speed
            set_fan_speed "$MAX_PWM"
        fi
    else
        # Normal state machine when not in emergency
        case $CURRENT_STATE in
            "$STATE_EMERGENCY")
                # Exit emergency mode only when temperature drops significantly below MAX_TEMP
                if ((avg_temp <= MAX_TEMP - HYSTERESIS)); then
                    state_transition="EMERGENCY→ACTIVE (${avg_temp}°C ≤ $((MAX_TEMP - HYSTERESIS))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    local calculated_speed
                    calculated_speed=$(calculate_speed "$avg_temp")
                    set_fan_speed "$calculated_speed"
                else
                    # Stay in emergency mode
                    set_fan_speed "$MAX_PWM"
                fi
                ;;

            "$STATE_OFF")
                if ((avg_temp >= FAN_ACTIVATION_TEMP)); then
                    state_transition="OFF→ACTIVE (${avg_temp}°C ≥ ${FAN_ACTIVATION_TEMP}°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed "$OPTIMAL_PWM"
                else
                    set_fan_speed 0
                fi
                ;;

            "$STATE_TAPER")
                if ((avg_temp >= FAN_ACTIVATION_TEMP + 2)); then # Added 2°C buffer to prevent oscillation
                    state_transition="TAPER→ACTIVE (${avg_temp}°C ≥ $((FAN_ACTIVATION_TEMP + 2))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed "$OPTIMAL_PWM"
                elif ((now - TAPER_START >= TAPER_DURATION)); then
                    state_transition="TAPER→OFF (${TAPER_MINS}min elapsed)"
                    CURRENT_STATE=$STATE_OFF
                    set_fan_speed 0
                else
                    local remaining=$((TAPER_DURATION - (now - TAPER_START)))
                    logger -t fan-control "TAPER: Remaining $((remaining / 60))m | Current: ${avg_temp}°C"
                    set_fan_speed "$MIN_PWM"
                fi
                ;;

            "$STATE_ACTIVE")
                if ((avg_temp <= MIN_TEMP)); then
                    state_transition="ACTIVE→TAPER (${avg_temp}°C ≤ ${MIN_TEMP}°C)"
                    CURRENT_STATE=$STATE_TAPER
                    TAPER_START=$now
                    set_fan_speed "$MIN_PWM"
                else
                    local temp_delta=$((avg_temp - LAST_AVG_TEMP))
                    if ((${temp_delta#-} > DEADBAND)); then
                        logger -t fan-control "DEADBAND:  DELTA=${temp_delta}°C | THRESHOLD=${DEADBAND}°C"
                        local speed
                        speed=$(calculate_speed "$avg_temp")
                        set_fan_speed "$speed"
                    else
                        # Force adjustment if we're below target PWM
                        local target_speed
                        target_speed=$(calculate_speed "$avg_temp")
                        if ((LAST_PWM < target_speed)); then
                            logger -t fan-control "DEADBAND:  Forcing adjustment (current ${LAST_PWM}pwm < target ${target_speed}pwm)"
                            set_fan_speed "$target_speed"
                        else
                            logger -t fan-control "DEADBAND:  No change | DELTA=${temp_delta}°C"
                        fi
                    fi
                fi
                ;;
        esac
    fi

    [[ -n "$state_transition" ]] && logger -t fan-control "STATE: ${state_transition}"
}

###[ MAIN EXECUTION ]##########################################################
# Initialize optimal PWM file if it doesn't exist
[[ -f "$OPTIMAL_PWM_FILE" ]] || {
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$MIN_PWM"; then
        logger -t fan-control "INIT: Created optimal PWM file with ${MIN_PWM}pwm"
    fi
}

# Read and validate optimal PWM value
OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$MIN_PWM")
if ! [[ "$OPTIMAL_PWM" =~ ^[0-9]+$ ]] || ((OPTIMAL_PWM < MIN_PWM || OPTIMAL_PWM > MAX_PWM)); then
    logger -t fan-control "WARNING: Invalid optimal PWM value: ${OPTIMAL_PWM}, using MIN_PWM"
    OPTIMAL_PWM=$MIN_PWM

    # Write corrected value back to file
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$OPTIMAL_PWM"; then
        logger -t fan-control "FIXED: Updated optimal PWM file with corrected value ${OPTIMAL_PWM}pwm"
    fi
fi
FAN_CONTROL_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
if ! [[ "$FAN_CONTROL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    FAN_CONTROL_VERSION="unknown"
fi
logger -t fan-control "CONFIG: fan-control v${FAN_CONTROL_VERSION} starting"
logger -t fan-control "START: Optimal=${OPTIMAL_PWM}pwm | Config: MIN=${MIN_TEMP}°C, MAX=${MAX_TEMP}°C, HYST=${HYSTERESIS}°C"

detect_drive_temperature
get_smoothed_temp
if ((SMOOTHED_TEMP >= FAN_ACTIVATION_TEMP)); then
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C ≥ ${FAN_ACTIVATION_TEMP}°C"
    CURRENT_STATE=$STATE_ACTIVE
    set_fan_speed "$OPTIMAL_PWM"
else
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C - Fans off"
    set_fan_speed 0
fi

# Define state names for more readable logging
get_state_name() {
    case $1 in
        "$STATE_OFF") echo "OFF" ;;
        "$STATE_TAPER") echo "TAPER" ;;
        "$STATE_ACTIVE") echo "ACTIVE" ;;
        "$STATE_EMERGENCY") echo "EMERGENCY" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Main loop
declare -i loop_counter=0
while true; do
    update_fan_state

    # Log status every 10 iterations
    ((loop_counter++ % 10 == 0)) && {
        state_name=$(get_state_name $CURRENT_STATE)
        current_temp=$SMOOTHED_TEMP
        logger -t fan-control "STATUS: State=${state_name} | PWM=${LAST_PWM} | Temp=${current_temp}°C"
    }

    sleep "$CHECK_INTERVAL"
done
