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

echo "45" > "$SANDBOX/cputemp"
rm -f "$SANDBOX/config"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive" "daemon should be running"

declare -a required_params=(
    "MIN_PWM" "MAX_PWM" "MIN_TEMP" "MAX_TEMP" "HYSTERESIS"
    "CHECK_INTERVAL" "TAPER_MINS" "FAN_PWM_AUTODETECT" "FAN_PWM_DEVICE"
    "OPTIMAL_PWM_FILE" "MAX_PWM_STEP" "DEADBAND" "ALPHA" "LEARNING_RATE"
)
for param in "${required_params[@]}"; do
    if ! grep -q "^${param}=" "$SANDBOX/config" 2>/dev/null; then
        fail "Config file missing parameter: $param"
    fi
done

echo "  ✓ Scenario ${scenario}: Fresh config created with all 14 parameters"

stop_daemon
cleanup_sandbox

# ── Scenario 2: corrupt numeric value — clamped to default ───────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" > "$SANDBOX/cputemp"

# Pre-create a valid config but with MIN_TEMP=999 (out of valid range 30-80)
cat > "$SANDBOX/config" <<EOF
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

echo "  ✓ Scenario ${scenario}: Corrupt numeric value clamped to default"

stop_daemon
cleanup_sandbox

# ── Scenario 3: missing parameter — re-appended on restart ───────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" > "$SANDBOX/cputemp"

# Pre-create a config missing DEADBAND and LEARNING_RATE
cat > "$SANDBOX/config" <<EOF
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

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

if ! grep -q "^DEADBAND=" "$SANDBOX/config"; then
    fail "DEADBAND should have been re-appended"
fi
if ! grep -q "^LEARNING_RATE=" "$SANDBOX/config"; then
    fail "LEARNING_RATE should have been re-appended"
fi

echo "  ✓ Scenario ${scenario}: Missing parameters re-appended"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} config bootstrap scenarios passed."
