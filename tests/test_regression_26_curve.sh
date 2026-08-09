#!/bin/bash
###############################################################################
# Regression test for #26: sub-activation temperatures must not re-inflate PWM.
###############################################################################
set -euo pipefail

source "$(dirname "$0")/lib/harness.sh"

eval "$(sed -n '/^calculate_speed()/,/^}/p' "$FAN_CONTROL_SCRIPT")"

logger() { :; }

MIN_PWM=91
MAX_PWM=255
MIN_TEMP=60
MAX_TEMP=85
HYSTERESIS=5
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS))

assert_eq "$(calculate_speed 60)" "91" "60C should stay at minimum PWM: "
assert_eq "$(calculate_speed 63)" "91" "63C should stay at minimum PWM: "
assert_eq "$(calculate_speed 64)" "91" "64C boundary should stay at minimum PWM: "

for temp in 60 61 62 63 64 65; do
    assert_eq "$(calculate_speed "$temp")" "$MIN_PWM" "${temp}C should be flat at minimum PWM: "
done

assert_eq "$(calculate_speed 68)" "98" "68C curve value changed: "
assert_eq "$(calculate_speed 70)" "111" "70C curve value changed: "
assert_eq "$(calculate_speed 75)" "173" "75C curve value changed: "
assert_eq "$(calculate_speed 80)" "255" "80C curve value changed: "

previous=$MIN_PWM
for ((temp = 61; temp <= 85; temp++)); do
    current=$(calculate_speed "$temp")
    if (( current < previous )); then
        fail "curve decreased from ${temp}C-1 (${previous}) to ${temp}C (${current})"
    fi
    previous=$current
done

echo "  ✓ Regression #26: quadratic curve stays flat below activation and monotonic above it."
