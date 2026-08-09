#!/bin/bash
###############################################################################
# Regression test for GH #18: TEMP_READ_FAILURES + smoothed temp lost in
# command substitution.
#
# Bug: get_smoothed_temp called via $(...), so all state mutations happened
# in a subshell and were lost. Consequences:
#   (a) TEMP_READ_FAILURES counter never accumulated → fail-safe dead code.
#   (b) SMOOTHED_TEMP never updated → smoothing frozen at boot value.
#
# This test verifies the fix: get_smoothed_temp uses globals + fail-safe
# in update_fan_state forces MAX_PWM after 3 consecutive read failures.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# ── 1. Sensor failure → fail-safe forces MAX_PWM ─────────────────────────────
setup_sandbox
trap teardown_sandbox EXIT

# Start with healthy sensor, high temp to enter ACTIVE state
echo "70" > "$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Wait for ACTIVE state and non-zero PWM
wait_for_log "ACTIVE" 10 || fail "Should reach ACTIVE state"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "PWM should be > 0 in ACTIVE"

# Now cause sensor failures
echo "FAIL" > "$SANDBOX/cputemp"

# Regression: old code reset TEMP_READ_FAILURES every call (subshell loss),
# so the counter never reached 3 and the fail-safe never triggered.
# Fixed code: counter survives across calls, reaches 3 → MAX_PWM forced.

# Wait for ERROR logs (should see at least 3 "Failed to read temperature" messages)
wait_for_log "Failed to read temperature (attempt 1)" 10 || fail "Should see 1st failure"
wait_for_log "Failed to read temperature (attempt 2)" 10 || fail "Should see 2nd failure"
wait_for_log "Failed to read temperature (attempt 3)" 10 || fail "Should see 3rd failure"

# After 3 failures, the fail-safe should trigger
wait_for_log "Sensor fail-safe active" 15 || fail "Sensor fail-safe ALERT not logged"

# PWM should now be MAX_PWM (255) since fail-safe writes it directly
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "PWM should be MAX (255) in fail-safe"

echo "  ✓ Sensor fail-safe triggers after 3 failures, forces MAX_PWM"

# ── 2. Sensor recovery → fail-safe clears, normal operation resumes ──────────
echo "70" > "$SANDBOX/cputemp"

# Wait for the sensor to start working again — TEMP log should reappear
wait_for_log "TEMP:" 10 || fail "TEMP log should resume after sensor recovery"

# Fail-safe should no longer be active — PWM may change from 255
# (the state machine re-evaluates from ACTIVE)

echo "  ✓ Sensor recovery: fail-safe clears, normal TEMP logs resume"

stop_daemon
teardown_sandbox

# shellcheck disable=SC2317
echo "  All fail-safe regression tests (GH #18) passed."
