#!/bin/bash
###############################################################################
# Config bootstrap tests: creation, validation, and self-healing
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: fresh config creation ────────────────────────────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" >"$SANDBOX/cputemp"
rm -f "$SANDBOX/config"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive" "daemon should be running"
assert_eq "$(stat -c%a "$SANDBOX/config")" "600" "new config mode: "
echo "70" >"$SANDBOX/cputemp"
for _ in {1..20}; do
    [[ -f "$SANDBOX/temp_state" ]] && break
    /bin/sleep 0.1
done
for state_file in "$SANDBOX/temp_state" "$SANDBOX/optimal_pwm" "$SANDBOX/pid"; do
    [[ -f "$state_file" ]] || fail "daemon did not create $state_file"
    assert_eq "$(stat -c%a "$state_file")" "600" "$(basename "$state_file") mode: "
done

declare -a required_params=(
    "MIN_PWM" "MAX_PWM" "MIN_TEMP" "MAX_TEMP" "HYSTERESIS"
    "CHECK_INTERVAL" "TAPER_MINS" "FAN_PWM_AUTODETECT" "FAN_PWM_DEVICE"
    "OPTIMAL_PWM_FILE" "MAX_PWM_STEP" "DEADBAND" "ALPHA" "LEARNING_RATE"
    "DRIVE_TEMP_ENABLED" "DRIVE_MIN_TEMP" "DRIVE_MAX_TEMP" "DRIVE_CHECK_INTERVAL"
)
for param in "${required_params[@]}"; do
    if ! grep -q "^${param}=" "$SANDBOX/config" 2>/dev/null; then
        fail "Config file missing parameter: $param"
    fi
done

echo "  ✓ Scenario ${scenario}: Fresh config created with all 18 parameters"

stop_daemon
cleanup_sandbox

# ── Scenario 2: corrupt numeric value — clamped to default ───────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" >"$SANDBOX/cputemp"

# Pre-create a valid config but with MIN_TEMP=999 (out of valid range 30-80)
cat >"$SANDBOX/config" <<EOF
MIN_PWM=91
MAX_PWM=255
MIN_TEMP=999
MAX_TEMP=85
HYSTERESIS=5
CHECK_INTERVAL=15
TAPER_MINS=90
FAN_PWM_AUTODETECT=true
FAN_PWM_DEVICE="$SANDBOX/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="$SANDBOX/optimal_pwm"
MAX_PWM_STEP=25
DEADBAND=1
ALPHA=20
LEARNING_RATE=5
EOF

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

min_temp=$(grep "^MIN_TEMP=" "$SANDBOX/config" | cut -d= -f2 | awk '{print $1}')
assert_eq "$min_temp" "60" "MIN_TEMP should be clamped to default (60), got "
assert_eq "$(stat -c%a "$SANDBOX/config")" "600" "corrected config mode: "

echo "  ✓ Scenario ${scenario}: Corrupt numeric value clamped to default"

stop_daemon
cleanup_sandbox

# ── Scenario 3: missing parameter — re-appended on restart ───────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" >"$SANDBOX/cputemp"

# Pre-create a config missing DEADBAND and LEARNING_RATE
cat >"$SANDBOX/config" <<EOF
MIN_PWM=91
MAX_PWM=255
MIN_TEMP=60
MAX_TEMP=85
HYSTERESIS=5
CHECK_INTERVAL=15
TAPER_MINS=90
FAN_PWM_AUTODETECT=true
FAN_PWM_DEVICE="$SANDBOX/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="$SANDBOX/optimal_pwm"
MAX_PWM_STEP=25
ALPHA=20
EOF
chmod 600 "$SANDBOX/config"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

if ! grep -q "^DEADBAND=" "$SANDBOX/config"; then
    fail "DEADBAND should have been re-appended"
fi
if ! grep -q "^LEARNING_RATE=" "$SANDBOX/config"; then
    fail "LEARNING_RATE should have been re-appended"
fi
assert_eq "$(stat -c%a "$SANDBOX/config")" "600" "re-appended config mode: "

echo "  ✓ Scenario ${scenario}: Missing parameters re-appended"

stop_daemon
cleanup_sandbox

# ── Scenario 4: migration rewrite preserves drive parameters ─────────────────
scenario=$((scenario + 1))
setup_sandbox

cat >"$SANDBOX/config" <<EOF
MIN_PWM=91
MAX_PWM=255
MIN_TEMP=60
MAX_TEMP=85
HYSTERESIS=5
CHECK_INTERVAL=15
TAPER_MINS=90
FAN_PWM_AUTODETECT=true
FAN_PWM_DEVICE="/stale/raw/pwm1"
OPTIMAL_PWM_FILE="$SANDBOX/optimal_pwm"
MAX_PWM_STEP=25
DEADBAND=1
ALPHA=20
LEARNING_RATE=5
DRIVE_TEMP_ENABLED=auto
DRIVE_MIN_TEMP=50
DRIVE_MAX_TEMP=70
DRIVE_CHECK_INTERVAL=60
EOF

start_daemon
for param in MIN_PWM MAX_PWM MIN_TEMP MAX_TEMP HYSTERESIS CHECK_INTERVAL TAPER_MINS FAN_PWM_AUTODETECT FAN_PWM_DEVICE OPTIMAL_PWM_FILE MAX_PWM_STEP DEADBAND ALPHA LEARNING_RATE DRIVE_TEMP_ENABLED DRIVE_MIN_TEMP DRIVE_MAX_TEMP DRIVE_CHECK_INTERVAL; do
    grep -q "^${param}=" "$SANDBOX/config" || fail "migration rewrite removed ${param}"
done

echo "  ✓ Scenario ${scenario}: Migration rewrite preserves all 18 parameters"

stop_daemon
cleanup_sandbox

# ── Scenario 5: corrected-value rewrite preserves drive parameters ───────────
scenario=$((scenario + 1))
setup_sandbox

cat >"$SANDBOX/config" <<EOF
MIN_PWM=999
MAX_PWM=255
MIN_TEMP=60
MAX_TEMP=85
HYSTERESIS=5
CHECK_INTERVAL=15
TAPER_MINS=90
FAN_PWM_AUTODETECT=true
FAN_PWM_DEVICE="$SANDBOX/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="$SANDBOX/optimal_pwm"
MAX_PWM_STEP=25
DEADBAND=1
ALPHA=20
LEARNING_RATE=5
DRIVE_TEMP_ENABLED=auto
DRIVE_MIN_TEMP=50
DRIVE_MAX_TEMP=70
DRIVE_CHECK_INTERVAL=60
EOF

start_daemon
for param in MIN_PWM MAX_PWM MIN_TEMP MAX_TEMP HYSTERESIS CHECK_INTERVAL TAPER_MINS FAN_PWM_AUTODETECT FAN_PWM_DEVICE OPTIMAL_PWM_FILE MAX_PWM_STEP DEADBAND ALPHA LEARNING_RATE DRIVE_TEMP_ENABLED DRIVE_MIN_TEMP DRIVE_MAX_TEMP DRIVE_CHECK_INTERVAL; do
    grep -q "^${param}=" "$SANDBOX/config" || fail "corrected-value rewrite removed ${param}"
done

echo "  ✓ Scenario ${scenario}: Corrected-value rewrite preserves all 18 parameters"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} config bootstrap scenarios passed."
